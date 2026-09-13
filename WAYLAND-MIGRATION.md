# Native Wayland migration plan

Status: **All five phases done (2 Sep 2026), one real-use crash found and
fixed the same day.** The spike answered all three of its unknowns
positively, so the architecture below stands as written; the corrections it
turned up are folded into the phases, and the spike itself is kept at
[`wayland-spike/`](wayland-spike/). Every phase from 1 on found at least one
more thing the plan had wrong — see their sections, including Phase 1's,
where a crash reported from a real logged-in session (any click outside the
video froze the app) traced back three phases to `overlay.add(&webview)`.

**Where the app is right now:** it runs as a native Wayland client by
default — confirmed with no environment overrides at all, `GdkWaylandDisplay`
in the render log — with `FELLYJIN_GDK_BACKEND=x11` kept as a debug escape
hatch back to the old path. Real playback goes through the video surface and
the in-process libmpv adapter end to end — `player.rs` no longer spawns an
external mpv, and nothing in the app reaches for an external mpv *binary* any
more either, at build or run time. Native Wayland reports
`hwdec-current=vaapi` with no XWayland client for FellyJin, natural
end-of-file and a mid-playback quality switch both tear down and rebuild the
render context cleanly. Mouse and keyboard input on the video surface is
translated GTK event → mpv command by `surface.rs`, exercised with real
synthetic input (XTest events scripted at the running window — this box has
no Wayland input-injection tool, but the app was still forced onto XWayland
during that pass, so X11's `XTestFakeKeyEvent`/`XWarpPointer` reached it like
real hardware would) rather than only built: motion, click/drag,
double-click→fullscreen, scroll, and the full advertised keyboard set all land
exactly as intended. What no pass here covers: native-Wayland input
specifically (XTest only reaches an XWayland client) and uosc's own on-screen
reactions to hover/drag, which need eyes on a real screen — see §8.

Goal: run FellyJin as a native Wayland client instead of forcing the whole app
onto XWayland, while keeping video embedded in the window and keeping the look
and behaviour of the player **exactly** as it is today.

---

## 1. Why there is no "just rebuild it for Wayland" option

The app forces `GDK_BACKEND=x11` in [`main.rs`](src-tauri/src/main.rs) and strips
`WAYLAND_DISPLAY` from mpv's environment in [`player.rs`](src-tauri/src/player.rs)
for one reason: embedding is done by creating an X11 child window and handing
its id to mpv as `--wid` (`embed.rs`, replaced in Phase 1 and parked at
`src-tauri/src/embed.rs.x11-backup`).

Wayland has no window reparenting. A client cannot hand another process a
surface id and have it draw there. mpv's `--wid` is documented as X11/win32/cocoa
only, and as of mpv 0.41 (Dec 2025) that has not changed — the two upstream
issues asking for it, [#1242](https://github.com/mpv-player/mpv/issues/1242) and
[#9654](https://github.com/mpv-player/mpv/issues/9654), are still open. mpv's own
Wayland backend uses subsurfaces for its video/OSD layers, but it only ever
creates them under *its own* toplevel.

So there is no build flag, no mpv option, and no GTK setting that fixes this.
The embedding mechanism itself has to change.

**The one supported alternative** — and what every GTK mpv frontend on Wayland
uses (Celluloid, Haruna) — is the libmpv **render API**: link libmpv into the
process, give mpv *our* OpenGL context, and have it render video frames into a
framebuffer we own. Upstream explicitly recommends it over window embedding
these days. There is a working GTK reference in
[mpv-examples PR #44](https://github.com/mpv-player/mpv-examples/pull/44/files)
using `GtkGLArea`.

---

## 2. What the machine already has

Checked on this box (Framework, Panther Lake / Arc B390, Ubuntu 26.04):

| Thing | Version | Note |
| --- | --- | --- |
| `libmpv2` | 0.41.0-2ubuntu4 | already installed |
| `libmpv-dev` | 0.41.0-2ubuntu4 | already installed |
| `pkg-config mpv` | 2.5.0 | ABI the crates target |
| mpv binary | v0.41.0 | same core, so behaviour is identical |
| tauri | 2.11.5 | has `gtk_window()` / `default_vbox()` |
| gtk crate | 0.18.2 | GTK3 bindings, already in the tree via tauri |

Nothing needs to be built from source. The Rust side is
[`libmpv2`](https://docs.rs/libmpv2/latest/libmpv2/render/index.html) (v6.0.0,
July 2026), whose `render` module exposes `RenderContext`, `RenderParam`,
`RenderParamApiType`, `OpenGLInitParams` and `FBO`. Its docs coverage is thin
(~31%), so expect to read `libmpv2-sys` and mpv's `render.h` alongside it, and to
drop to the `-sys` crate for any param the safe wrapper doesn't re-export.

---

## 3. The design decision that keeps this faithful

> **Superseded on Wayland (3 Sep 2026).** The `GtkGLArea` described here is now
> the fallback (X11 sessions, compositors without `wp_viewporter`, and the
> `FELLYJIN_VIDEO_BACKEND=gl` override). On a Wayland session the video goes to
> a `wl_subsurface` rendered by a thread of its own, and the widget in the
> overlay is a plain `GtkDrawingArea` — same layout, same input routing, and
> GTK never repaints per video frame. See
> [`WAYLAND-SUBSURFACE-PLAN.md`](WAYLAND-SUBSURFACE-PLAN.md).

There are two ways to place a GL video surface in a GTK window that also
contains a WebKitGTK webview.

### Option A — GLArea *on top* of the webview  ← **recommended**

A `GtkOverlay` with the webview as the main child and the `GtkGLArea` as an
overlay child, given the rectangle `geometry()` already computes — the direct
analogue of today's `configure_window` on the X11 child. In practice that is
`halign=Fill`, `valign=Start` and a height request, not the `get_child_position`
signal this document originally reached for; see Phase 0.

This reproduces today's model exactly, including its limitation (HTML can never
draw over the video, which is why `.pb-panel` is documented in
[`styles.css:1380`](src/styles.css:1380) as living inside the player bar).

Crucially it also keeps **input routing identical**: the pointer lands on the GL
widget over the video region, exactly as it lands on the X11 child today, so
uosc's hover/click/drag behaviour is preserved without round-tripping events
through the webview.

### Option B — GLArea *below* a transparent webview

Architecturally nicer — HTML could finally draw over video, and the whole
fullscreen-clip mechanism could be deleted. But the webview would then cover the
video and swallow every pointer event, so uosc's mouse interaction (hover to
reveal, click, **and timeline dragging**) would have to be forwarded from JS
through IPC into mpv. That is precisely the kind of change that alters how the
player *feels*, which is out of scope here.

**Decision: build Option A.** Revisit B only if you later decide you want HTML
overlaying video, as a separate piece of work.

### Replacing the SHAPE trick

Under Option A, one thing needs a new mechanism. Today, revealing the
auto-hiding bar in fullscreen uses the X11 SHAPE extension to *clip* the bottom
72 CSS px off the video window rather than resize it — because resizing makes
mpv re-fit the picture and the whole frame visibly jumps
(`embed.rs:79`, in the backup). Wayland has no SHAPE equivalent.

With the render API we own the pixels, so the fix is better than the workaround:

1. Render mpv into an **offscreen FBO at the full window size** (so mpv's fit,
   letterboxing and zoom never change).
2. Shrink the *widget* by the bar height.
3. `glBlitFramebuffer` the top `h - bar` rows of that FBO into the widget's
   framebuffer.

The picture stays pinned to the pixel; the strip simply stops being drawn.
~40 lines of GL, fully deterministic, and it removes the `can_clip()` fallback
path entirely. Phase 0 measured this rather than trusting it: the clipped and
unclipped renders of the same paused frame are byte-identical over the rows they
share.

---

## 4. The idea that makes the rest of the app a no-op

[`player.rs`](src-tauri/src/player.rs) is ~1000 lines, and only about a third of
it is actually about *how* mpv is driven. The rest — status tracking, Jellyfin
reporting, idle inhibit, MPRIS, the epoch/supersede logic — is about what mpv
*says*.

mpv's JSON IPC and libmpv's C API are the same commands and the same events in
two encodings. So: **write an adapter that presents the libmpv handle behind the
exact same JSON-shaped interface the Unix socket had.**

- Commands: `["seek", "10"]` → `mpv_command` with the same string array.
  `Player::send()`, [`player_cmd`](src-tauri/src/lib.rs:260) and every frontend
  call site stay byte-for-byte unchanged.
- Events: `MPV_EVENT_PROPERTY_CHANGE` (carrying the same `reply_userdata` ids
  1–16 already registered at [`player.rs:481`](src-tauri/src/player.rs:481)) →
  synthesise `{"event":"property-change","name":…,"data":…}`.
  `MPV_EVENT_CLIENT_MESSAGE` → `{"event":"client-message","args":[…]}`.

Feed those into the existing `apply_event()` / `track_position()` and **they do
not change at all**. Same for `emit_status`, the adaptive-quality policy
([`adaptive.ts`](src/adaptive.ts)), the stall/frame-drop reporting, the scrubber
buffer band, chapters, MPRIS and the whole Jellyfin progress path.

This is what makes "exactly the same function" achievable rather than aspirational:
the surface area that can regress shrinks to the video surface, the process
lifecycle, and input forwarding.

---

## 5. Work plan

### Phase 0 — Spike ✅ done

Standalone binary, no Tauri, kept at [`wayland-spike/`](wayland-spike/). All
three unknowns came back positive on this box (Mesa Intel PTL, GTK 3.24.52,
WebKitGTK 2.52.3, mpv/libmpv 0.41):

- **`GtkGLArea` over a `WebKitWebView` in a `GtkOverlay` composites correctly.**
  Video draws on top; the HTML below it keeps painting and stays visible in the
  strip the video does not cover. This was the risk that could have killed
  Option A, and it is retired.
- **mpv renders into the GLArea through `RenderContext` on native Wayland**, with
  `DISPLAY` unset entirely — no XWayland client, no X11 connection.
- **`hwdec` still resolves to VAAPI**: `VO: [libmpv] 1920x1080 vaapi[nv12]`, and
  `hwdec-current` reads `vaapi`. This does depend on passing
  `MPV_RENDER_PARAM_WL_DISPLAY` (`RenderParam::WaylandDisplay`, from
  `gdk_wayland_display_get_wl_display`) at context creation, exactly as feared —
  and the failure is silent, so keep watching `hwdec-current`
  ([`player.rs:859`](src-tauri/src/player.rs:859)).

The offscreen-FBO clip in §3 was measured rather than assumed: rendering into a
full-height FBO and blitting all but the bottom 72 CSS px produced a frame
**byte-identical** to the unclipped render over the rows they share. The picture
does not move by a pixel when the bar appears.

Six things the spike found that this document had wrong or did not know:

1. **The `epoxy` crate does not build.** It depends on `gl_generator 0.9`, which
   pins a yanked `xml-rs 0.7`, so cargo will not resolve it. Load the entry
   points by hand instead — see [`wayland-spike/src/gl.rs`](wayland-spike/src/gl.rs).
   libepoxy exports GL and EGL as *data* symbols named `epoxy_<name>` holding
   dispatch pointers (the bare `glFoo` names are macros in `epoxy.h`, so
   `dlsym(lib, "glClear")` returns null), and `libloading`'s `Symbol` deref hands
   back the address dlsym returned — so a data symbol needs one more
   indirection to reach the thunk. Getting either of those wrong segfaults
   inside `epoxy_glGetString` with a current context, which reads like a GTK
   bug and is not one.
2. **libmpv refuses to be created under a non-C `LC_NUMERIC`.** `mpv_create()`
   just returns NULL and prints one line to stderr. The mpv *binary* calls
   `setlocale(LC_NUMERIC, "C")` for itself; in-process it is ours to do, after
   `gtk_init`, which sets the locale from the environment.
3. **`get-child-position` is not needed, and is not enough on its own.** gtk-rs
   0.18 does not bind it (out-parameter), and connecting it by hand through
   `g_signal_connect_data` gives the child the right rectangle only on the passes
   where GTK emits it — later passes fall back to the widget's natural size,
   which for a GLArea is zero. `halign=Fill` + `valign=Start` + a height request
   is both sufficient and simpler, and is all this app's geometry ever needs.
   Set the request from an idle, not from inside `size-allocate`, or GTK
   discards the queued resize.
4. **Size the video widget against the overlay, never the toplevel.** Under
   client-side decorations `GtkWindow::allocated_height()` includes the titlebar
   and shadows, which on GNOME come to almost exactly the 72px bar height — so
   the arithmetic looks plausible and the video silently covers the bar.
5. **GTK leaves `GL_INVALID_FRAMEBUFFER_OPERATION` pending on the first frame.**
   mpv reads it back as its own and warns
   (`after creating texture: OpenGL error INVALID_FRAMEBUFFER_OPERATION`).
   Drain `glGetError()` before calling `render()` so mpv's diagnostics mean
   something.
6. **`libmpv2::RenderContext<'a>` borrows the `Mpv`**, which makes the obvious
   "one struct owning both" self-referential. The spike leaks the handle
   (`Box::leak`); Phase 1 needs something better — an `Arc<Mpv>` plus a
   hand-rolled context wrapper over `libmpv2-sys` is the likely answer.

One thing worth knowing but not worth acting on: under `GDK_BACKEND=x11` the
same code path reports `hwdec-current=no`. The debug escape hatch kept in
Phase 5 therefore runs software-decoded, which is fine for finding out whether a
bug is Wayland-specific and useless for judging performance.

### Phase 1 — `embed.rs` → `surface.rs` ✅ done

Three new modules, and `embed.rs` gone (this tree is not under version control,
so the old one is parked at `src-tauri/src/embed.rs.x11-backup`):

| File | What it is |
| --- | --- |
| [`surface.rs`](src-tauri/src/surface.rs) | the widget tree, geometry, fullscreen clip, picture-in-picture, and the render signal |
| [`render.rs`](src-tauri/src/render.rs) | `RenderCtx`, an *owning* `mpv_render_context` over `libmpv2-sys` |
| [`gl.rs`](src-tauri/src/gl.rs) | the GL entry-point loader, carried over from the spike |

`Cargo.toml`: `x11rb` and `raw-window-handle` dropped; `libmpv2`,
`libmpv2-sys`, `libloading` and `gtk` added. Building now needs `libmpv-dev`,
so it went into [`setup-deps.sh`](.build-deps/setup-deps.sh) and
[CI](.github/workflows/release.yml) with this phase rather than waiting for
Phase 5 — without it the build simply breaks.

The public shape came out as planned, so `lib.rs` barely moved:

| Today | Becomes |
| --- | --- |
| `Embed::new(xid)` | `Surface::new(&WebviewWindow)` — walks `default_vbox()`, re-parents the webview into a `GtkOverlay`, adds the `GLArea` |
| `window_xid()` | deleted |
| `create_surface(x,y,w,h)` | `show(x,y,w,h)` — reveals the GLArea, creates the `RenderContext` |
| `enter_pip()` / `leave_pip()` / `is_pip()` / `watch_pip()` | **not covered by the original plan.** X11 reparenting has no Wayland equivalent, so the GLArea widget itself moves between the overlay and a small always-on-top `GtkWindow`. GTK unrealizes it in the process and destroys its `GdkGLContext`, so the `RenderContext` has to be freed and rebuilt on each move — but mpv's playback core is untouched, so the stream still never restarts, which is the whole point of the feature |
| `resize(x,y,w,h)` | stores geometry, sets the GLArea's height request from an idle — but see the sizing note below, `h` is not used as an absolute |
| `set_bottom_clip(w,h,bar)` | stores `bar`; the render callback blits `h - bar` rows out of the full-size FBO |
| `can_clip()` | deleted — always true now |
| `destroy_surface{,_if}()` | `hide()` / `hide_if()`, frees the render context |
| `geometry()`, `BAR_HEIGHT_CSS` | **unchanged** — same maths, same 72.0 |

Two additions the plan did not have: `attach(Arc<Mpv>)` / `detach()`, which is
where Phase 2 plugs in, and a session id. `show()` returns one and `hide_if()`
takes one, replacing the X11 window id that used to serve as the "am I still
the current session" token.

#### What Phase 1 found: `inner_size()` is not the space the video has

Finding 4 below said to size the video against the overlay, never the toplevel.
It is worse than it looked, and it does not only apply to `allocated_height()`.
**`WebviewWindow::inner_size()` is also the wrong number on Wayland.** Under
GNOME's client-side decorations it reports the whole client area including the
47 logical px title bar, while the overlay the video actually lives in gets
none of it:

```
GtkOverlay 1440x881+0+47      inner_size() = 1440x928 logical
```

Sizing the GLArea to `inner_size().height - bar` therefore left 25 px for the
player bar instead of 72, and the video covered the top of it. On X11 the two
numbers agree exactly, so this is invisible until the app becomes a Wayland
client — which is to say, it is a bug the migration creates and has to fix.

The fix keeps `geometry()` and `resize_video_surface()` verbatim, because what
the caller passes is still meaningful — just not as an absolute:

- the **trim** (`window height - requested height`, plus the fullscreen clip)
  comes from the caller, and is reliable because it is a difference;
- the **absolute height** is `overlay.allocated_height() - trim`, re-derived on
  every `size-allocate`, so it is anchored to real space and follows window
  resizes without anyone calling `resize()`.

That is `Layout` in `surface.rs`, and it is the only place the height request
is ever set.

#### Verifying it without a server

`FELLYJIN_SURFACE_TEST=1` runs a self-test: it reveals the surface, reserves
the player bar, takes the fullscreen clip and gives it back, moves the widget
out to picture-in-picture and home again, shrinks the window, and dumps the
widget tree at each step before exiting. No Jellyfin server and no mpv needed,
which is the point — every geometry path Phase 1 owns is exercised before
there is any video to put in it. Measured on both backends at scale 2:

| Step | native Wayland (overlay 881) | XWayland (overlay 891) |
| --- | --- | --- |
| bar reserved | GLArea 809 — 72 clear ✓ | 819 — 72 clear ✓ |
| fullscreen, bar revealed | 809, mpv still rendering 881 into the FBO ✓ | 819 / 891 ✓ |
| fullscreen, bar hidden | 881 ✓ | 891 ✓ |
| picture-in-picture | 480x270 in its own toplevel ✓ | same ✓ |
| back in the app window | 809 ✓ | 819 ✓ |
| window shrunk 200 px | overlay 728, GLArea 656 — 72 clear ✓ | ✓ |

The same flag also makes `player.rs` reveal the surface during real playback,
which is only useful while there is nothing in it; both it and the self-test go
away in Phase 3.

#### Notes for Phase 2

- `RenderCtx` owns an `Arc<Mpv>` and frees the render context before the handle
  drops, which is what finding 6 asked for. It is freed and rebuilt whenever
  the widget moves in or out of the PiP window. (Phase 1 also created it lazily
  on the first `render` signal; Phase 2 found that too late — `attach()` now
  builds it up front and waits, see that phase.)
- `setlocale(LC_NUMERIC, "C")` (finding 2) already happens, in `Surface::new`,
  which is after GTK has set the locale and before anything can call
  `mpv_create()`.
- Phase 2 needs to call `attach()` once the handle exists, and `detach()` when
  it goes.

`resize_video_surface()` in [`lib.rs:289`](src-tauri/src/lib.rs:289) keeps its
logic verbatim; only the type it calls into changes. Drop `x11rb` and
`raw-window-handle` from `Cargo.toml`; add `libmpv2` and `libloading` (**not**
`epoxy` — see Phase 0).

HiDPI: the GLArea must render at physical pixels —
`gtk_widget_get_scale_factor()`, cross-checked against the `scale` already
threaded through `geometry()`. The spike ran at scale 2, which is what this
display is configured for, and the maths held.

Threading: create the render context on the GTK main thread with the GL context
current, and call `render()` only from the `render` signal. "With the context
current" rules out `connect_realize`: GtkGLArea only creates its `GdkGLContext`
in its *own* realize handler, which runs after any handler gtk-rs connects, so
`make_current()` there is a no-op and the first GL call segfaults. Do the setup
lazily on the first `render` instead, which is the earliest point the context is
guaranteed current.
`set_update_callback` fires on mpv's render thread — it must only
`glib::idle_add` a `queue_render()`, never touch GL. Tauri's
`app.run_on_main_thread()` is the bridge from the tokio side.

#### What real use found, three phases later: any click outside the video crashed the app

Reported 2 Sep 2026 against a real, logged-in session: switching tabs from
Downloads froze the app, requiring a manual kill. Reproduced exactly by
scripting a click on any sidebar tab — the crash isn't specific to Downloads,
it's specific to clicking the webview *at all* outside the video region:

```
thread 'main' panicked ... called `Result::unwrap()` on an `Err` value:
Widget { inner: ..., type: GtkBox }
thread caused non-unwinding panic. aborting.
```

The panic is inside `tauri-runtime-wry`'s `undecorated_resizing.rs`, a
click-to-resize-by-dragging feature for undecorated windows (FellyJin uses
ordinary decorations, so the feature itself is dead code for this app — but
its setup crashes before it ever gets to check that). It's connected
unconditionally on every Linux build, on the **webview widget itself**, and
assumes `webview.parent().parent()` is the toplevel `GtkWindow` — true in a
stock Tauri app, where the webview is a direct child of the vbox two hops
from the window. This phase's `overlay.add(&webview)` inserts the `GtkOverlay`
*between* webview and vbox, adding a third hop; wry's hardcoded two-hop walk
now lands on the vbox itself, and `.downcast::<gtk::Window>().unwrap()` panics
on it — for every click that lands on the webview outside the video, which is
most of the app.

This was actually found once already, mid-Phase-4 (an early input test
crashed the same way) — but at the time it looked like it might be caused by
the *new* input-forwarding code, so it got investigated only as far as
confirming Phase 4's own clicks didn't retrigger it, and left there. It didn't
retrigger *in that testing* because every later Phase 4 click landed inside
the video region, which the GLArea now intercepts before it ever reaches the
webview — accidentally avoided, not fixed. Any click that lands outside the
video (the sidebar, any button, literally most of the app's surface) always
went straight to the webview and always hit this.

There's no widget arrangement that avoids it: `GtkWindow` can only ever have
one child, so overlaying the video *anywhere* means inserting a container
between webview and window, and wry's walk is hardcoded to exactly two hops
regardless of where that container goes. The fix instead removes wry's
handler: `remove_wry_resize_handler()` in `surface.rs`, called on the webview
right before it's reparented, disconnects every `button-press-event` handler
connected via ordinary `g_signal_connect` by signal id (via
`g_signal_handlers_disconnect_matched`, `G_SIGNAL_MATCH_ID` only — no need to
name wry's specific closure). This can't affect how clicks reach the actual
page: WebKitGTK handles its own input through a widget-class vfunc override,
a separate mechanism `g_signal_connect` handlers don't touch. Verified against
the real session that reported it — the exact reproduction (click a sidebar
tab from Downloads) — and against five rapid tab switches in a row; also
reconfirmed the full test suite and a clean build.

### Phase 2 — `mpv.rs`, the JSON-shaped adapter ✅ done

One new module, [`mpv.rs`](src-tauri/src/mpv.rs). `Session` owns the `Mpv`
handle as an `Arc` and presents what the socket used to:

- `command(&self, Value) -> Result<(), String>` — the same JSON array the IPC
  socket took, and the `{"command": [...]}` envelope as well, since that is the
  shape the supervisor already queues.
- An event stream of `serde_json::Value` in IPC shape, produced by a dedicated
  OS thread parked in `mpv_wait_event`, pushed into a `tokio::mpsc` the
  supervisor already knows how to read.
- `MPV_EVENT_SHUTDOWN` in place of process exit: the thread breaks, the sender
  drops, and the receiver closing is what `child.wait()` used to be. `end-file`
  arrives as an event like any other — libmpv's idle mode means the core
  outlives the file, so EOF and shutdown are now two different things.
- `handle()`, the `Arc<Mpv>` for [`Surface::attach`](src-tauri/src/surface.rs).

`resolve_mpv_config_dir()` and `mpv_log_path()` moved here verbatim from
`player.rs` — they configure mpv, and after Phase 3 nothing in `player.rs` will
want them.

Options came out as planned: `config=yes` + `config-dir` (libmpv reads no
config at all otherwise, and reads the *command line player's* config if told
`config=yes` without a directory), then `Prefs::load().args()` mapped
one-to-one with the leading `--` stripped, then `terminal=no`, `keep-open=no`,
`ytdl=no`, `cache=yes`, `demuxer-max-bytes=64MiB`, `force-media-title`,
`volume`, `start`, the `Authorization` header and `log-file`. `--force-window`
and `--gpu-context=x11egl` are gone. Three the plan did not have, all
init-only and all silent when missed: `vo=libmpv` (without it
`mpv_render_context_create` is not legal), and `load-scripts=yes` +
`input-default-bindings=yes`, which the `libmpv` profile turns off — so the
bundled `input.conf` would have loaded into a player that ignores bindings, and
uosc would not have loaded at all.

One option cannot simply be set. `http-header-fields` is a *list*, and the
MediaBrowser scheme is full of commas, so assigning the header as a string
splits it into malformed continuation lines — which is why the command line
said `--http-header-fields-append=`. **That name does not exist through the
option API**: setting it is accepted, does nothing, and the only symptom is a
400 from Jellyfin on every authenticated stream. The list is appended to with
`["change-list", "http-header-fields", "append", …]` instead, before the first
`loadfile`.

#### Why `libmpv2`'s safe API is not enough

`PropertyData::from_raw` hits `unimplemented!()` on `MPV_FORMAT_NODE`, and
`track-list`, `chapter-list` and `mouse-pos` are all node-typed. The event loop
and the command path are therefore hand-rolled on `libmpv2-sys`, the same way
`render.rs` hand-rolls the render context — which turned out to cost nothing,
because `mpv_event_to_node` is the very call mpv's own IPC server makes before
serialising. What comes out of the thread is not an approximation of the socket
protocol; it is the same message. Commands go the other way as
`mpv_command_node`, so `["seek", 12.5, "absolute"]` and
`["set_property", "aid", 2]` keep their types instead of being re-parsed out of
decimal text.

`observe_property` and `unobserve_property` are handled before that: they only
ever existed in the IPC layer, and `mpv_command_node` has never heard of them.
Properties are observed as `MPV_FORMAT_NODE`, which is what makes `track-list`
arrive whole rather than as mpv's flattened string rendering.

#### What Phase 2 found: `attach()` has to finish before `loadfile`

Phase 1 built the render context lazily on the first `render` signal, because
that is the earliest point the GL context is guaranteed current. That leaves
the order of two independent things to chance: GTK's first frame, and mpv
opening the file. **mpv initialises `vo=libmpv` while it opens the file, and if
the render context does not exist by then it gives up on video for that file
entirely.** The log says so plainly —

```
[   0.088][f][cplayer] Error opening/initializing the selected video_out (--vo) device.
[   0.088][i][cplayer] Video: no video
```

— and then the audio plays on to EOF as if nothing were wrong, `track-list`
reports the video track `"selected": false`, and `vo-configured` never goes
true. On XWayland the first frame happened to win and everything worked; on
native Wayland it lost. It is exactly the class of failure §7 warns about:
silent, and it looks like nothing happening.

So `Surface::attach` now returns a `Result` and blocks until the context is
really there. It builds it eagerly through `Ui::ensure_render_ctx` — Phase 0's
finding 1 rules out `connect_realize`, but "the context is current" is true
anywhere on the main thread *once the area is realized*, not only inside the
signal — and falls back to asking for a frame and waiting when the GLArea has
not been realized yet. Phase 3 must therefore attach before it loads a file,
and treat a failed attach as a failed play.

#### Verifying it

`cargo test --lib mpv` covers the parts that need no window: JSON survives the
round trip through `mpv_node` in both directions, integers stay integers (mpv's
`aid` takes an integer choice, and `2.0` is not one of its values), a command
that is not an array is refused rather than panicked on, a real core plays a
synthetic `av://lavfi:` source and reports it in IPC shape, and — the one that
found the header bug — every option is read back off a live core and compared.
That last test is worth its length: mpv accepts an option name it does not have
and does nothing with it, so this whole class of failure (no uosc, no hardware
decode, no `Authorization`) presents from outside as "video didn't work".

`FELLYJIN_MPV_TEST=<path|url>` is the rest: it brings a core up in the real
window, reveals the surface, attaches, and prints every event. Together with
Phase 1's self-test — which it suppresses, since the two drive the same widget
— this is the first time the GLArea shows a picture. Both go away in Phase 3.
Measured on this box, playing a 12s H.264 clip:

| | native Wayland | XWayland |
| --- | --- | --- |
| render context | on `GdkWaylandDisplay`, before `start-file` ✓ | on `GdkX11Display` ✓ |
| uosc | `client-message ["uosc-version", "5.12.0"]` ✓ | ✓ |
| `track-list` | node array, video `selected: true` ✓ | ✓ |
| `vo-configured` | true ✓ | true ✓ |
| `hwdec-current` | **`vaapi`** ✓ | `no` — as Phase 0 said it would be |
| end of clip | `end-file` `reason: "eof"`, core idles ✓ | ✓ |

`hwdec-current=vaapi` on the native path is the one that matters: it is the
finding Phase 0 flagged as silent-on-failure, and it holds through the real
widget tree and not just the spike.

### Phase 3 — `player.rs` lifecycle ✅ done

Only the process-shaped parts changed:

- `Command::new(mpv_binary).spawn()` + socket-connect retry loop →
  `mpv::Session::start()`, then `surface.attach(session.handle())`, then
  `observe_property` × 16, then `loadfile` — in that order, and a failed
  `attach()` or `loadfile` is a failed `play()`: the surface is detached and
  hidden and the mpv core is asked to quit before the error goes back to the
  caller.
- The `FELLYJIN_SURFACE_TEST` branch in `play()` is gone, and so are
  `surface::self_test` and `mpv::self_test` (and the `FELLYJIN_MPV_TEST`
  branch that ran the latter from `setup()`): real playback now exercises
  exactly the path those three used to stand in for, so there was nothing
  left for them to cover. `FELLYJIN_SURFACE_TEST`'s diagnostics
  (`debug_enabled()`, the widget-tree dump, the per-frame geometry log) stay —
  Phase 4 still wants them.
- `SessionHandle.pid` and the `kill -9` escape hatch are gone; there is no
  child process to fall back to killing any more. `exited`/`exited_flag` keep
  their meaning but now come from the event thread closing rather than from
  `child.wait()`.
- `status.embedded` stays in the payload — the frontend reads it
  ([`main.ts:1213`](src/main.ts:1213)) — and is now simply always true; `play()`
  returns `Err` before that point if there is no surface to embed into.

Everything from `track_position()` down compiled untouched, as planned.

#### What Phase 3 found: end-of-file does not end anything

The old external process exited by itself at EOF (`--keep-open=no`), and
`child.wait()` completing *was* the "playback over" signal. libmpv's idle mode
means the in-process core does not: Phase 2's own test already had to work
around this (`mpv.rs`, `a_session_plays_and_reports_in_ipc_shape`) by sending
`["quit"]` on the `end-file` event, and Phase 3 needed the same fix in the
supervisor loop itself, or natural end-of-episode playback would just idle
forever with the surface still shown and nothing rewatching for a next-episode
autoplay. The supervisor now sends `quit` on every `end-file`, whether or not
the session is still current, and lets the event thread closing (`rx.recv()`
returning `None`) drive teardown exactly as it did for an explicit `stop()`.

#### Verifying it

Measured on this box (same machine as Phase 0–2), driving real `play()` end to
end via `FELLYJIN_TEST_PLAY=<path>` rather than either self-test — those are
gone, so this is the only path left to exercise:

| | native Wayland | XWayland |
| --- | --- | --- |
| `vo-configured` | true ✓ | true ✓ |
| `hwdec-current` | `vaapi` ✓ | `no`, as Phase 0 said |
| frame loop | continuous through the clip (`render #0`…`#240`) ✓ | ✓ |
| natural EOF | `mpv: event thread finished`, session ends `requested_stop=false`, surface hidden ✓ | — |
| `FELLYJIN_TEST_REPLAY` (mid-playback switch) | old session ends `requested_stop=true`, new session attaches a fresh render context (`hwdec-current=vaapi` again), frame loop continues without a gap ✓ | — |

No black window and no orphaned surface on the replay path — the two things
§7's risk list and the verification checklist both call out by name.

### Phase 4 — Input forwarding (the fiddly one) ✅ done

Keys and clicks used to reach mpv for free, because the X11 child window had
focus. A `GtkGLArea` gets GTK events instead, and [`surface.rs`](src-tauri/src/surface.rs)
now translates them — one new `connect_input()`, wired up in `Surface::new`
alongside `connect_render()`, plus the translation tables it calls:

- `set_can_focus(true)` on the GLArea at construction, and `add_events` with
  `POINTER_MOTION_MASK | BUTTON_PRESS_MASK | BUTTON_RELEASE_MASK | SCROLL_MASK |
  SMOOTH_SCROLL_MASK | KEY_PRESS_MASK | KEY_RELEASE_MASK`. `Surface::show()`
  also grabs focus for the widget, so keys work as soon as playback starts
  rather than only after the user clicks the video — matching the X11 version,
  which had focus for free.
- Motion → `mouse <x> <y>` in physical px (widget-relative position × the
  GLArea's own `scale_factor()`, the same scale the render callback sizes the
  surface by), which is what keeps `mouse-pos` updating — the property the
  frontend already observes to reveal its fullscreen bar
  ([`player.rs:490`](src-tauri/src/player.rs:490)) — and what uosc reads for
  hover.
- Clicks → `keydown MBTN_LEFT` / `keyup MBTN_LEFT` rather than the one-shot
  `mouse … MBTN_LEFT`, so dragging the uosc timeline still works. `MBTN_RIGHT`
  is forwarded like any other button — `input.conf` still binds it to
  `ignore` — and side buttons 8/9 map to `MBTN_BACK`/`MBTN_FORWARD`.
- Scroll → `keypress WHEEL_UP`/`WHEEL_DOWN`/`WHEEL_LEFT`/`WHEEL_RIGHT` for
  discrete wheel events; `GDK_SCROLL_SMOOTH` (touchpads) accumulates fractional
  `delta()` units in a `Cell` until a whole wheel step is owed, then fires the
  same commands — there is no partial-`WHEEL_*` command to send instead.
- Keys → GDK keyval to mpv key-name mapping, sent as `keypress`. Named keys
  (`LEFT`, `ESC`, `SPACE`, `F1`..`F24`, ...) come from an explicit table and
  take `Shift+`/`Ctrl+`/`Alt+`/`Meta+` prefixes; everything else falls back to
  `Key::to_unicode()` — the character GDK already resolved for the active
  modifiers — sent bare, per `man mpv`'s own key-name rule ("the actual
  produced text key name when shift is pressed should be used", e.g. Shift+2 is
  `@`, not `Shift+2`). `EventKey::is_modifier()` filters out bare modifier
  presses before either path runs. The set Settings advertises to the user
  ([`settings.ts:375`](src/views/settings.ts:375)) — Space, ←/→, ↑/↓, `m`,
  `[`/`]`, `z`/`Z`, `f`, Esc — is covered: the named table has the arrows,
  Space and Esc, and `to_unicode()` handles the plain-character keys.

#### What Phase 4 found: don't synthesize `MBTN_LEFT_DBL` — mpv already does

The first version of this phase treated GDK's `GDK_DOUBLE_BUTTON_PRESS` event
as the cue to send an extra `keypress MBTN_LEFT_DBL`, on the theory that mpv's
own click-timer only runs over *hardware* input and would never see a double
click assembled from two separate `keydown`/`keyup MBTN_LEFT` commands. That
theory is wrong: mpv's input core times commands exactly like real button
events, and a real double click under the fixed version's plain
`keydown`/`keyup` forwarding alone already produced

```
[12.681] Run command: keydown, args=[name="MBTN_LEFT"]
[12.681] Run command: script-message, args=[args="fellyjin-fullscreen"]
[12.748] Run command: keyup, args=[name="MBTN_LEFT"]
```

— mpv synthesizing `MBTN_LEFT_DBL` itself and firing `input.conf`'s binding,
with nothing else sent. With the extra `keypress MBTN_LEFT_DBL` still in
place, the same click produced the binding **twice**, back to back at the same
timestamp — which for a fullscreen toggle means "on, then instantly off
again", i.e. it looks like double-click does nothing at all. Exactly the
failure shape §7 warns about: silent, because two toggles in one tick leaves
no visible trace. The fix is the smaller code: `connect_button_press_event`
only needs to act on plain `GDK_BUTTON_PRESS` (grab focus, `keydown`); GTK's
`GDK_DOUBLE_BUTTON_PRESS`/`GDK_TRIPLE_BUTTON_PRESS` need no handling of their
own.

#### Verifying it

Unlike Phases 0–3, this box has no Wayland input-injection tool — no
`xdotool`/`wtype`/`ydotool`. But the app is still forced onto XWayland until
Phase 5 (`GDK_BACKEND=x11` in `main.rs`), which means it is, as far as the X
server is concerned, an ordinary X11 client — so `python-xlib`'s `XTest`
extension (`XTestFakeKeyEvent`/`XTestFakeButtonEvent`) and core
`XWarpPointer`, installed user-local with `pip install --user python-xlib` (no
root needed), drive it exactly as real hardware would. Against a real
`Surface`/`Session` with the bundled `mpv-config` loaded
(`FELLYJIN_MPV_CONFIG=src-tauri/mpv-config`, so uosc and `input.conf` are
actually active — the default dev fallback with no config dir found disables
`input-default-bindings` entirely and every key silently does nothing, a
separate trap worth knowing about but out of Phase 4's scope to fix):

| Input | mpv saw | |
| --- | --- | --- |
| motion to (1440, 700) | `mouse 1440 700` | physical px, exact |
| left click, release | `keydown MBTN_LEFT` then `keyup MBTN_LEFT` | ✓ |
| double click | `keydown`, `script-message fellyjin-fullscreen` (mpv's own `MBTN_LEFT_DBL`), `keyup` | ✓, once, after the fix |
| right click | `keydown`/`keyup MBTN_RIGHT` | ✓ (bound to `ignore`) |
| wheel up / down | `keypress WHEEL_UP` / `WHEEL_DOWN` | ✓ (tested individually — fired back-to-back in one script, the second was lost to GDK coalescing at that pace, a test-harness pacing artifact, not an app bug) |
| ←/→/↑/↓, `m`, `[`, `]` | `keypress LEFT/RIGHT/UP/DOWN/m/[/]` | ✓ |
| `z`, Shift+`z` | `keypress z`, `keypress Z` | ✓ — confirms the shift-normalization rule against a real modifier |
| `f`, Esc | `keypress f`, `keypress ESC` | ✓ |
| Space | `keypress SPACE` → mpv's own `cycle pause` → `Set property: pause` | ✓, symmetric on a second press |
| Esc (fullscreen open) | `script-message fellyjin-fullscreen-exit` | ✓ |

Every row after the fix is exactly one command per input, with no duplicate or
missing firings — confirmed against `mpv`'s own `log-file` output
(`~/.local/share/fellyjin/mpv-logs/`), which records every `Run command:` mpv
actually executed, not just what `surface.rs` sent.

What this pass does **not** cover: native-Wayland input specifically (XTest
only reaches the app because it is still an XWayland client; Phase 5 removes
that), and uosc's own on-screen reactions (does the hover UI actually appear,
does the timeline visibly scrub) — those need eyes on a real screen. See §8.

### Phase 5 — Strip the X11 scaffolding, then packaging ✅ done

- Deleted the `GDK_BACKEND=x11` override in `main.rs` — the app is a plain
  client on whichever backend GDK picks now. Confirmed with no environment
  overrides at all: `fellyjin: video surface on GdkWaylandDisplay` in the
  render log, same as Phase 3's verification but now the *default*, not
  something `GDK_BACKEND=wayland` had to force. `FELLYJIN_GDK_BACKEND` stays
  as the debug escape hatch to compare against the old X11 path.
- `cmd.env_remove("WAYLAND_DISPLAY")` was already gone — it lived on the
  `Command::new(mpv_binary).spawn()` call Phase 3 deleted along with the rest
  of the external-process lifecycle. Nothing to do here.
- `idle.rs` and `player.rs`'s doc comments rewritten: the old text blamed
  XWayland for mpv not being able to inhibit its own idle timer, which was
  already stale after Phase 3 — mpv doesn't run on XWayland *or* X11 any more,
  it has no window of its own at all (render API), which is the real reason
  its built-in inhibition has nothing to hook.
- `tauri.conf.json`: `deb.depends` `["mpv"]` → `["libmpv2"]`.
- `.build-deps/setup-deps.sh` already had `libmpv-dev` — added in Phase 1,
  since the build broke without it well before Phase 5. `release.yml` still
  installed a standalone `mpv` alongside `libmpv-dev`, left over from when
  `prefs.rs` shelled out to it (see below); removed now that nothing does.
- README, `build-deb.sh`, `reinstall.sh`: rewrote every stale mention of the
  IPC socket, X11/XWayland embedding, the mpv child process, and `Depends: mpv`.

#### What Phase 5 found: dropping `Depends: mpv` wasn't safe as written

The plan said to swap the package's `mpv` dependency for `libmpv2`, but two
things still assumed an external `mpv` binary would be on `$PATH`:
`prefs.rs`'s option pre-filter (shelled out to `mpv --list-options` before
building `--option=value` args) and its `audio_devices()` (shelled out to
`mpv --audio-device=help`) — plus a working "mpv binary" override in Settings
that fed both. Swapping the dependency without touching either would have
quietly emptied the audio-device dropdown on any install that happened not to
have a standalone mpv (exactly the kind of regression this migration set out
to avoid at every other step). Fixed properly instead of left as a tradeoff:

- The option pre-filter turned out to be dead weight, not just inconvenient.
  It existed because the old command-line invocation exits with status 2 on
  one bad option and refuses to start at all; `mpv.rs`'s `set()` closure
  (Phase 2) already tolerates a rejected option per-option, one log line and
  nothing more, which the code's own comment at
  [`mpv.rs:130`](src-tauri/src/mpv.rs) has said since Phase 2: "the old
  command line was filtered against `mpv --list-options` for exactly this
  reason." `prefs::args()` now passes every option through unconditionally —
  see [`prefs.rs`](src-tauri/src/prefs.rs)'s rewritten module docs.
- `audio_devices()` moved into `mpv.rs` and became a throwaway-core probe:
  `Mpv::new()`, read `audio-device-list` (node-typed, hand-rolled on
  `libmpv2-sys` the same way the event loop is), drop the handle. Same idea
  for a new `runtime_version()`, reading `mpv-version` off a throwaway core —
  what Settings and bug reports show now that there's no binary path to name.
  Both are covered by new tests (`mpv::tests::audio_devices_lists_at_least_one_output`,
  `runtime_version_reports_something`).
- `resolve_mpv_binary()`, `$FELLYJIN_MPV`, and `Player::play()`'s `mpv_binary`
  parameter are gone — nothing computes an mpv path any more, so nothing
  needed them. The "mpv binary" Settings row (a live override that would have
  gone from doing something to silently doing nothing) is now a plain
  read-only line: "Running mpv 0.41.0, linked in-process."

With that done, `deb.depends: ["libmpv2"]` is genuinely safe — nothing in the
app reaches for an external mpv binary any more, at build time or run time.

#### Verifying it

`cargo build --release`, `cargo test --release --lib` (16 passed, including
the two new probe tests) and `cargo clippy --release` all clean — no new
warnings from this phase. `npx tsc --noEmit` clean after the Settings row
removal. Runtime: launched with no environment overrides at all —
`FELLYJIN_SURFACE_TEST=1 FELLYJIN_TEST_PLAY=...` and nothing else — and the
render log shows `GdkWaylandDisplay`, confirming the app is a native Wayland
client by default for the first time in this migration, not just under a
forced `GDK_BACKEND`.

---

## 6. The one functional casualty — resolved in Phase 5

This section originally predicted that `mpv_path` in Settings, `$FELLYJIN_MPV`,
and `resolve_mpv_binary()` would stop meaning anything once there was no
external binary to point at, and offered a choice: rewrite `prefs::warm()`'s
`mpv --list-options` shell-out to probe in-process and drop `Depends: mpv`
entirely, or skip that and keep the dependency purely for the probe. Phase 5
took the first path — see its "what Phase 5 found" section — so as shipped
there is no casualty: `resolve_mpv_binary()`, `$FELLYJIN_MPV`, and the editable
Settings field are gone rather than left inert, `audio_devices()` and a new
`runtime_version()` probe in-process via a throwaway `Mpv::new()`, and
`Depends: mpv` is genuinely dropped in favour of `libmpv2`.

Everything else — every keybinding, every menu, the uosc layout, the quality
menu, the episode queue, downloads, offline sync, Live TV, MPRIS, theming — is
untouched by design.

---

## 7. Honest risks

1. ~~**GTK3 compositing of GLArea over WebKitGTK.**~~ Retired twice: Phase 0
   showed it works in a standalone binary, and Phase 1 showed Tauri's own
   webview survives being re-parented into a `GtkOverlay` in the real app.
2. **In-process crashes are now fatal.** Today an mpv/FFmpeg/driver fault kills a
   child process and the app survives. Linked in, it takes FellyJin down with it.
   Note that the journal already shows a `corrupted double-linked list` abort
   from 15 Aug — whatever that was, in-process it becomes an app crash. No easy
   mitigation; it is the price of the render API.
3. **hwdec interop** — see Phase 0. Silent, and the symptom looks like the
   problem you set out to fix.
4. **Fractional scaling.** GTK3 only does integer scale factors; if you ever run
   this display at a fractional scale, the GLArea path needs re-testing.
   Phase 1's arithmetic divides a physical trim by an integer scale, so a
   fractional one would lose up to a pixel per frame off the bar reserve.
5. **libmpv ABI.** The deb gains a hard `libmpv2` dependency; a distro bumping
   the soname needs a rebuild, where before any `mpv` on `$PATH` would do.

---

## 8. Verification checklist

Nothing here is "looks fine". Each line is a thing that works today and must
still work, checked against a real Jellyfin server. No phase of this migration
has actually had one available, though — every check so far, including the
2 Sep 2026 pass through this list, has used `FELLYJIN_TEST_PLAY`'s synthetic
`av://lavfi:testsrc` source, which stands in fine for the backend/mpv-level
rows (embedding, geometry, hwdec, input translation, MPRIS) but not for
anything that needs real audio/subtitle tracks, chapters, an unreliable
network, or a login session (the frontend's own player-bar/fullscreen/theme
code is gated behind a real `player-status` event from a logged-in session,
which the backdoor doesn't drive). The 2 Sep pass also hit an environment-level
snag worth knowing about if this list is revisited on the same box: partway
through, XTest-synthesized input (`python-xlib`, used since this box has no
Wayland input-injection tool) stopped reaching any X11 window at all, confirmed
with a control test against a freshly created plain window with no FellyJin
involvement — so a couple of rows that looked like they might be regressions
(uosc's hover UI never appearing) are flagged as unproven rather than broken;
re-test with working synthetic input, or real hardware, before trusting either
verdict.

- [x] the surface composites over the webview and leaves the player bar clear,
      on both backends, at scale 2, across window resizes (Phase 1 self-test)
- [x] `xdpyinfo`-free: `WAYLAND_DISPLAY` set, no XWayland client for FellyJin —
      confirmed via `GdkWaylandDisplay` in the render log with `GDK_BACKEND`
      forced to wayland (Phase 3 verification, §5); "the jitter is gone" is a
      subjective read on real content and wasn't separately assessed
- [x] video appears embedded, correct size, no letterbox change on start —
      confirmed via a real screenshot of the running surface (not just the
      render-log geometry numbers): video content fills exactly to the
      reserved player-bar boundary, pixel-accurate, on a synthetic source
      (§8 verification pass, 2 Sep 2026)
- [x] `hwdec-current` reports VAAPI, not `no` — confirmed real `play()` sets
      it via `mpv::Session`'s `observe_property` on native Wayland, `no` on
      XWayland as Phase 0 predicted (Phase 3 verification, §5); not checked
      through the Settings page itself
- [ ] windowed → fullscreen → windowed, picture does not jump — **attempted,
      blocked**: app-chrome fullscreen is gated in the frontend behind
      `playerActive`/`playerEmbedded`, which only go true once a real
      `player-status` event reaches a JS session that has passed login; the
      `FELLYJIN_TEST_PLAY` backdoor plays real video but never puts the
      webview through that flow. Needs a real Jellyfin login to test.
- [ ] in fullscreen, moving the mouse reveals the bar over the video **with the
      picture pinned to the pixel**, and hides again after 1s (`cursor-autohide`)
      — same blocker as above (this is the app's own `bar_reveal`, JS-driven)
- [ ] uosc: hover shows controls, click seeks, **drag scrubs the timeline**,
      double-click toggles app fullscreen (not WM fullscreen), right-click does
      nothing — double-click→fullscreen and right-click-forwarded-as-`ignore`
      confirmed via synthetic input against mpv's own command log (Phase 4
      verification, still valid). A follow-up pass (2 Sep 2026) tried to
      confirm hover/click-seek/drag visually and found `mouse-pos`'s `hover`
      field permanently `false` and the coordinates never updating — but
      before drawing conclusions from that, the test rig itself turned out to
      be broken: XTest-synthesized input had stopped reaching *any* X11
      window, confirmed with a control test against a freshly created plain
      window with no FellyJin/GTK involved at all. So the `hover` observation
      is unproven, not confirmed — it may be a real render-API limitation
      (there is no VO backend to set it the way a real window's input driver
      would) or may equally have been a casualty of the same broken XTest.
      Needs re-testing with working synthetic input, or real hardware.
- [x] keys: Space, ←/→, ↑/↓, m, [ ], z/Z, f, Esc — confirmed via XTest-scripted
      key events against a real `Surface`/`Session` with `mpv-config` loaded,
      each producing the exact expected `keypress` command and, for Space, the
      resulting `cycle pause` (Phase 4 verification, still valid — that
      session's XTest input was confirmed reaching the app repeatedly); XWayland
      only, and against a synthetic test source rather than a real Jellyfin server
- [ ] subtitle / audio-track / quality menus, episode queue — needs a real
      Jellyfin server: the synthetic test source has no audio/subtitle tracks,
      and the quality menu/episode queue are populated by the app's own JS
      during a real play(), which the test backdoor doesn't drive
- [ ] adaptive quality still steps down on stall and back up after 5 clean min
      — needs a real, unreliable network stream; nothing to stall locally
- [ ] scrubber buffer band and chapter marks still draw — needs real streamed
      content (buffering) and a source with chapters; the synthetic clip has
      neither
- [x] mid-playback quality switch (`FELLYJIN_TEST_REPLAY`) — no black window,
      no orphaned surface (Phase 3 verification, §5)
- [ ] progress reported to Jellyfin every 10s; resume point correct on stop —
      needs a real server to report to
- [x] MPRIS: media keys, lock screen, GNOME shell controls — verified directly
      over D-Bus (§8 verification pass, 2 Sep 2026), bypassing the need for a
      real media key: `org.mpris.MediaPlayer2.fellyjin` is live with correct
      `Metadata`/`PlaybackStatus`; calling `PlayPause` genuinely pauses mpv
      (the render-frame counter measurably freezes, not just a property
      flip) and reports `Paused`, and calling it again resumes and reports
      `Playing`. This is the same code path a hardware media key or the shell's
      media widget drives, so it stands in for them; the shell's own rendering
      of that data (the lock-screen widget, the quick-settings player) is a
      compositor-side UI this box can't screenshot.
- [ ] screen does not blank during playback; *does* blank when paused — not
      directly observed (waiting out a real idle timeout wasn't practical),
      but `sync_idle_inhibit` is driven by the *observed* `pause` property
      (§8 verification pass confirmed this fires the same way whether pause
      comes from MPRIS, uosc, or keyboard) and produced no
      `idle-inhibit failed` log line during a live, playing session — the
      `Inhibit()` D-Bus call is the thing that would fail loudly if broken
- [ ] downloads + offline progress sync — needs a real server and a real
      download queue
- [ ] Live TV — needs a real server or M3U playlist
- [x] HiDPI at scale 2 — every render log across every phase of this
      migration, including today's, reports `scale=2` with physical px
      exactly double logical px; today's screenshot-based pixel check
      (video/bar boundary landing exactly where the scale-2 math predicts)
      is the most direct confirmation yet. This display doesn't offer a
      different scale to cross-check against.
- [ ] light and dark theme, including Auto following the desktop — the
      mechanism is live and correct at the system level (confirmed
      2 Sep 2026: a direct `org.freedesktop.portal.Desktop` `ReadOne` call
      for `color-scheme` returns `1` (dark), matching
      `gsettings get org.gnome.desktop.interface color-scheme` =
      `'prefer-dark'`, and `theme.rs`'s code is unchanged since before this
      migration), but the frontend never called `system_color_scheme()` in
      this session — no `theme:` line ever appeared in `debug.log` — because
      `initTheme()` runs behind the same login-gated boot path as the player
      bar. Needs a real login session to see the UI actually flip.

---

## 9. Alternatives considered (and why mpv stays)

The obvious cost-saving move is to replace mpv with something that embeds more
easily and ship it in the package. It doesn't pay off, because mpv is doing
three jobs here and only one of them is the hard part:

1. decoder and streaming engine (HLS, direct play, hwdec, cache);
2. the on-screen UI — uosc *is* the in-video control layer;
3. the options surface that the whole Settings page drives via
   [`prefs.rs`](src-tauri/src/prefs.rs).

Swapping the player makes job 1's *embedding* easier and jobs 2 and 3 much
harder.

### GStreamer + `gtkwaylandsink` / `gtkglsink`

Available and capable on this machine (GStreamer 1.28.2, VA-API H.264/H.265/AV1
decode on the Intel iGPU). Embedding becomes genuinely trivial: the sink hands
back a real `GtkWidget`, so there is no render API, no offscreen FBO, no GL
proc-address loading, no update-callback marshalling. Phase 0's risky spike
disappears and Phase 1 shrinks to roughly a quarter of its size.

The cost lands everywhere else:

- **uosc is gone.** The timeline, −30s/play-pause/+30s, the subtitle, audio and
  quality menus and the episode queue would all be rebuilt in HTML. The existing
  player bar already covers part of this, but the in-video fullscreen OSD is
  uosc.
- **`prefs.rs` is a rewrite.** Every option there is an mpv option —
  `sub-font-size`, `sub-pos`, `sub-back-color`, `sub-border-size`, `video-sync`,
  `interpolation`, `tscale`, `af=lavfi=[dynaudnorm…]`, `audio-device`,
  `video-aspect-override`, `video-zoom`. Each needs a GStreamer equivalent found,
  written, or dropped.
- **Adaptive quality is re-derived.** [`adaptive.ts`](src/adaptive.ts) is tuned
  against mpv's `demuxer-cache-time`, `paused-for-cache`,
  `decoder-frame-drop-count` and `frame-drop-count`. GStreamer's nearest
  equivalents are queue2 buffering messages and QoS events, with different
  semantics and different thresholds.
- Subtitle rendering moves from libass-under-mpv to `assrender`, and the
  prefs above have to be re-plumbed into it.

One hard, well-understood problem traded for a long tail of medium ones — and the
long tail is the part that breaks "identical".

### HTML5 `<video>` in the webview

The embedding problem vanishes entirely: video becomes a DOM element, HTML draws
over it natively, and the fullscreen clip mechanism is deleted rather than
reimplemented. It fails on three counts:

- **Direct play dies.** WebKitGTK gates `<video>` on container and codec strings;
  an MKV carrying HEVC + EAC3 will not direct-play, and remux-free `static=true`
  streaming is the app's reason to exist. Everything would fall back to
  transcoding.
- **uosc is gone**, as above.
- **It reverses a deliberate security decision.** The webview currently does not
  talk to the network at all ([`lib.rs:427`](src-tauri/src/lib.rs:427)); the CSP
  pins `media-src` to `'self'`, and the access token lives in the keyring and is
  attached as an mpv HTTP header ([`player.rs:150`](src-tauri/src/player.rs:150))
  precisely so it never reaches the page. Playing in the webview means undoing
  all of that.

### libVLC

`libvlc_media_player_set_xwindow` has the same X11 limitation, and libVLC has no
Wayland embedding story at all. Strictly worse than mpv.

### The link between this and §3

Option B in §3 (GL surface below a transparent webview) was rejected because uosc
needs pointer input. If uosc were ever given up in favour of HTML controls, that
objection disappears — so "replace the player" and "restack the layers" are the
same decision seen from two directions. If you ever want to reopen it, reopen
both at once.

---

## 10. Effort

Phase 0 spike is half a day and decides the architecture. Phases 1–3 are two to
three focused days. Phase 4 is a day, most of it in a keymap table and testing.
Phase 5 plus the checklist is another day.

Call it **4–6 focused days**, front-loaded with the one spike that can still
change the design.
