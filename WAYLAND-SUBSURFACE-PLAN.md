# Video on a Wayland subsurface — plan

Companion to [`WAYLAND-MIGRATION.md`](WAYLAND-MIGRATION.md). That document moved
video from an X11 child window to a `GtkGLArea` driven through libmpv's render
API. This one describes the next step, which takes GTK out of the per-frame
path entirely.

**Status (4 Sep 2026): all phases done, shipped as v0.1.25. Phases 0–4
re-verified 4 Sep (Phase 3's reparent glitch and Phase 4's frozen-frame-clock
bar bug fixed, see their sections); Phase 5's `FORCE_SHM` re-measurement
came out in favour of keeping the shared-memory default, see its section.**
The app renders video on a Wayland
subsurface from its own thread; the `GtkGLArea` path is kept as the fallback
behind the same `Surface` API (`Backend::Gl`: X11 sessions, compositors
without `wp_viewporter`, or `FELLYJIN_VIDEO_BACKEND=gl`).

| release build, fullscreen 1080p H.264 on the 2880×1920 panel, 10 s | main thread | whole app |
|---|---|---|
| GLArea fallback, same build (= v0.1.23) | 12.3 % | 22.0 % |
| **Wayland subsurface** | **0.7 %** | **11.9 %** (video thread 3.1 %, the rest decode/demux/uosc) |
| Wayland subsurface, v0.1.25 (Phase 5, 4 runs) | 0.6–0.8 % | 11.3–12.3 % |

The main-thread target (≤ 2 %) is met; the whole-app figure is 2 points over
its target because mpv's own render (~3 %) now shows up on the video thread
instead of being folded into the main thread's share. Verified in the app,
not just the spike: windowed, fullscreen, the fullscreen bar reveal (crop,
picture pinned), picture-in-picture out and back (no restart, render context
kept), hwdec `vaapi` with the dmabuf interop line, clean quit mid-playback
through MPRIS `Quit`, and the GLArea fallback still working. The
`FELLYJIN_TEST_SEQUENCE` hook in `lib.rs` drives those window states, since
native Wayland has no input injection.

What landed, by file:

- [`wl.rs`](src-tauri/src/wl.rs), [`egl.rs`](src-tauri/src/egl.rs) — Phase 1,
  dlopen-based like `gl.rs`; `wl::available()` / `egl::available()` are the
  fallback seam's checks.
- [`video_thread.rs`](src-tauri/src/video_thread.rs) — Phase 2: the thread
  that owns EGL, the `wl_egl_window`, and the render context (advanced
  control on, `report_swap` after every swap). Commands: `Surface`, `Attach`,
  `Detach`, `Resize`, `Show`, `Hide`.
- [`surface.rs`](src-tauri/src/surface.rs) — Phase 2: `Backend::Wl` with a
  `GtkDrawingArea` placeholder; `size-allocate` positions the subsurface
  (`translate_coordinates` to the toplevel) and sends the size; PiP (Phase 3)
  is `wl_ensure_subsurface()` noticing the widget's toplevel changed and
  making a new subsurface there, so the thread swaps EGL windows and the
  render context survives; the bar reveal (Phase 4) is a `wp_viewport` crop,
  so `Offscreen` is GLArea-only.
- [`render.rs`](src-tauri/src/render.rs) — `advanced` flag, `report_swap`.

Two things Phase 2 found that the spike had not:

- **`wl_egl_window_resize` is not reliable before a swap.** Mesa allocates the
  back buffer the first time anything validates the drawable (`eglMakeCurrent`
  does), and a resize after that is only applied once that buffer has been
  swapped out. The app creates the EGL window before the widget has a size,
  so the first frame attached a 1×1 buffer under `set_buffer_scale(2)` — a
  protocol error, i.e. the compositor disconnects the app. The video thread
  now recreates the EGL window surface on the next draw after any size change
  (`State::win_stale`); a full-size surface creation per resize is cheap and
  deterministic.
- **The widget's allocation passes are noisy.** GTK hands the placeholder a
  1×1 at (−1,−1) before its first real allocation and a full-width-by-1 on
  the way back from PiP; both are skipped rather than turned into buffers.

The spike
(`wayland-spike/ --subsurface`) answers every unknown in §4 Phase 0 that can
be answered without eyes on the screen:

| measured, windowed 1920×1080 H.264 at scale 2, 24 fps | |
|---|---|
| main thread during playback | **0.5–1.0 %** of a core (0.85 % by `perf`, 341 samples/10 s at 4 kHz) |
| video thread | 3–4 % |
| GTK draws of the placeholder in 6 minutes of playback | 56, all from focus/layout changes — none per frame |
| `perf` on the main thread, idle window | zero `gdk_window_begin_draw_frame`, `cairo_surface_create_similar`, `gdk_cairo_draw_from_gl` samples |
| `WAYLAND_DEBUG=1`, 11 s | 263 `attach`/`commit` on the video `wl_surface`, 6 on GTK's toplevel |
| hwdec | `vaapi`, `Using EGL dmabuf interop via GL_EXT_EGL_image_storage` on the video thread's own context |
| input | real pointer motion and a click landed on the placeholder widget under the subsurface |
| clean quit mid-playback | yes (`--quit-after`): render context freed on the video thread, exit 0, no libepoxy assertion |
| resize (`--wiggle`, 8 resizes) | subsurface position and buffer size follow every allocation; no protocol error |

Findings that change Phases 1–2 (details in the spike's module comments):

- **EGL entry points must not come from libepoxy.** `epoxy_eglGetPlatformDisplay`
  gates on the EGL version, which it probes from the *current* display, and
  the video thread has none yet — it aborts with "No provider of
  eglGetPlatformDisplay found". `egl.rs` dlopens `libEGL.so.1` instead; GL
  still goes through epoxy once a context is current.
- **`wl_egl_window_resize`, `set_buffer_scale`, the opaque region and the
  viewport crop all go through the video thread**, so they land in the same
  commit as the first buffer at the new size (a buffer not a multiple of the
  scale is a protocol error, i.e. the compositor kills the app).
  `set_position` stays on the GTK thread, followed by `queue_draw` of the
  placeholder, which is what makes GTK commit the parent.
- **The main thread still wakes at frame rate, cheaply.** libwayland lets the
  *last* thread with an outstanding `prepare_read` do the socket read, and
  that is GDK's poll loop; Mesa's per-frame buffer-release events therefore
  wake GDK (~50 wakeups/s, `wl_display_read_events` is 20 % of the 0.85 %).
  Not worth fighting.
- **A window resize allocates the placeholder twice** (width first, then the
  idle-hopped height request), so the video thread resizes and re-renders
  twice per resize. Phase 2 should coalesce: post `Resize` from the idle that
  applies the height request, not from `size-allocate`.
- **The fullscreen-bar crop works through `wp_viewporter`** (source +
  destination, committed with the video buffer); `Offscreen` is not needed
  in the spike at all, so Phase 4 can fold into Phase 2.
- Positioning arithmetic: the placeholder at overlay (0,0) maps to subsurface
  position (26,60) in a 1332×809 toplevel surface, i.e. the CSD shadow and
  header bar offsets come out of `translate_coordinates` to the `GtkWindow`
  widget as predicted.

Still to verify **by eye** (the reference machine was in use, with the app
fullscreen over the spike, when Phase 0 ran; GNOME Shell's screenshot D-Bus
is denied to unlisted callers and the portal returns cancelled without a
dialog, but `org.gnome.Mutter.ScreenCast.RecordMonitor` + `pipewiresrc`
captures the monitor fine — see `wayland-spike/README.md`):

- no magenta strip between placeholder and video at (26,60) — position
  coordinates confirmed visually, windowed and fullscreen (`--fullscreen`);
- HiDPI crispness at scale 2;
- whether a resize shows a frame of disagreement between GTK's surface and
  the desync subsurface (`--wiggle`; `--sync` is the switch if it does);
- uosc hover/click reactions on the subsurface.

## 1. Why

Measured on 2026-09-03 (Panther Lake laptop, 2880×1920 @ 120 Hz, scale 2,
GNOME Wayland, fullscreen 1080p HEVC with VAAPI decode), the app's GTK main
thread burned **52% of a core** while a film played. A `perf` profile put the
cost almost entirely in GTK repainting things the video hides. Three releases
(v0.1.21–v0.1.23) removed what could be removed from app code:

| | main thread | whole app |
|---|---|---|
| before | 52% of a core | 61% |
| v0.1.23 | 13% | 21% |

What is left on the main thread is structural. Every video frame invalidates
the `GtkGLArea`'s rectangle, and GTK 3's GL paint path then, per frame:

1. allocates a full-window ARGB cairo surface for the invalidated region and
   zeroes it — 22 MB of `memset` at this resolution, **63%** of what remains;
2. walks the widget tree drawing whatever is under the rectangle (now mostly
   suppressed by `sync_webview_clip` and the `draw` guard in
   [`surface.rs`](src-tauri/src/surface.rs), which are workarounds, not a
   design);
3. blits the GL renderbuffer into the window's back buffer and swaps.

mpv's own render is ~15% of the remainder, i.e. about 2% of a core. That is
the floor this plan aims for: **the main thread does nothing per video frame.**

The mechanism: give mpv its own `wl_surface`, attached to the GTK toplevel as a
**`wl_subsurface`**, with its own EGL window and its own GL context on its own
thread. Frames go from mpv to the compositor as dmabufs, GTK's surface
underneath is never invalidated, and nothing on the main thread runs at frame
rate. This is what GStreamer's `gtkwaylandsink` does inside a GTK3 widget, so
the shape of the solution is proven on exactly this stack.

`WAYLAND-MIGRATION.md` §1 says mpv's `--wid` can't do this on Wayland, and that
is still true: mpv will not adopt a foreign surface. But we are not asking it
to. The render API stays; only the framebuffer it renders into changes from
"GTK's renderbuffer on the main thread" to "our EGL window on our thread".

## 2. Building blocks already in hand

- **The `wl_display`.** `gdk_wayland_display_get_wl_display` is already
  declared and used in `surface.rs` (`make_render_ctx`).
- **The parent `wl_surface`.** `gdk_wayland_window_get_wl_surface(GdkWindow*)`
  is exported by the installed libgdk-3 (checked with `objdump -T`). Called on
  the toplevel's `GdkWindow` it returns the surface the subsurface attaches to.
- **`wl_compositor`.** `gdk_wayland_display_get_wl_compositor` is exported too.
  `wl_subcompositor` and `wp_viewporter` are not; we bind them ourselves from a
  `wl_registry` we create on the shared display. Creating a second registry on
  a display is ordinary Wayland usage.
- **EGL entry points.** [`gl.rs`](src-tauri/src/gl.rs) already resolves GL
  through libepoxy's `epoxy_*` data symbols. The same loader gives
  `eglGetPlatformDisplay`, `eglCreateContext`, `eglCreateWindowSurface`,
  `eglMakeCurrent`, `eglSwapBuffers`, `eglSwapInterval`. `wl_egl_window_create`
  comes from `libwayland-egl.so.1`, which is already mapped in the process.
- **The render context code.** [`render.rs`](src-tauri/src/render.rs) is
  thread-agnostic; only `surface.rs` assumes the GTK thread. `RenderCtx::update`
  (added in v0.1.21) is the hook a render thread wants.
- **The letterbox-clip trick.** `Offscreen` in `surface.rs` renders full-height
  and blits the top rows when the fullscreen bar is up. It survives unchanged,
  or is replaced by `wp_viewport` cropping (§4, Phase 4).
- **Input forwarding.** `connect_input` in `surface.rs` translates GTK pointer
  and key events into mpv commands. It keeps working as-is because the
  subsurface will have an **empty input region**, so the compositor delivers
  pointer events to GTK's surface underneath, where an input-only widget sits
  in the video's rectangle (§3).
- **The spike crate.** [`wayland-spike/`](wayland-spike/) is a standalone
  GTK + libmpv harness with the loader and mpv setup already written. Phase 0
  extends it rather than starting a new one.

## 3. Design

```
GTK toplevel wl_surface  (xdg_toplevel; GTK paints it, rarely)
 ├─ webview (WebKitWebViewBase GdkWindow, child)        ← page, player bar
 ├─ placeholder GtkDrawingArea (overlay child)           ← input only; paints
 │                                                          the app background
 │                                                          once, never again
 └─ [wl_subsurface]  video wl_surface                    ← mpv, own thread
       • place_above(parent)          stacked over GTK's pixels
       • set_input_region(empty)      pointer falls through to GTK
       • set_opaque_region(full)      compositor need not blend (but see §6:
                                       fully covering GTK freezes its clock)
       • set_desync()                 frames present without GTK commits
       • set_buffer_scale(scale)      HiDPI, same integer scale as GDK
       • wl_egl_window + EGLSurface   mpv renders to FBO 0, eglSwapBuffers
```

**Widget side.** The `GtkGLArea` becomes a `GtkDrawingArea` with the same
allocation logic (`Layout::apply`, `apply_geom`, `Geom{win_h,h,bar}` all stay).
Its `draw` handler fills the app background colour and returns; nothing
invalidates it during playback, so it is drawn once per layout change. Its
`size-allocate` handler translates the allocation into toplevel-surface
coordinates and moves the subsurface (§4, Phase 2, "positioning").

**Render side.** A `video` thread owns: the EGL display and context, the
`wl_egl_window` + `EGLSurface`, the mpv `RenderCtx`, and the `Offscreen` FBO.
mpv's update callback wakes the thread (a channel or `Condvar`, not
`glib::idle_add`); the thread calls `mpv_render_context_update`, renders when
`UPDATE_FRAME` is set, swaps, and calls `mpv_render_context_report_swap`.
`MPV_RENDER_PARAM_ADVANCED_CONTROL=1` is set on the context: with a thread of
our own the rules it imposes are easy to honour, and it lets mpv do decoder
texture uploads on the render thread rather than lazily inside `render`.

**Swap interval 0.** Mesa's Wayland EGL blocks `eglSwapBuffers` on the
compositor's frame callback with the default interval. A subsurface that is
occluded, or a window on a workspace that isn't shown, stops receiving frame
callbacks and the swap would block forever. mpv paces frames itself through
`BLOCK_FOR_TARGET_TIME` (the default) and `report_swap`, so the EGL swap
interval is set to 0 and frame callbacks are only used as a *signal* (an
optional later refinement: pause rendering while none arrive).

**Event queue.** Objects we create on GDK's display get their own
`wl_event_queue`, dispatched on the video thread. Leaving them on the default
queue would have their events dispatched by GDK's main loop on the GTK thread,
which is both the wrong thread and the wrong lock. Mesa's EGL already does this
for its own objects, which is why sharing the display with GTK is safe.

**Thread ownership summary.** GTK thread: widget, geometry, input, subsurface
*position*. Video thread: everything that touches EGL, GL, the mpv render
context, and buffer commits on the video surface. The two communicate through
`Geom` updates (already `Mutex`-guarded on `Surface`) and a small command enum
(`Attach(mpv)`, `Detach`, `Resize`, `Clip(bar)`, `Reparent(surface)`, `Quit`).

## 4. Work plan

### Phase 0 — Spike (in `wayland-spike/`) ✅ done, see status at the top

Goal: a GTK window with a webview and a subsurface playing a file, main thread
idle. Answers the unknowns before any of `surface.rs` changes.

1. Bind `wl_subcompositor` (and `wp_viewporter`) from a fresh `wl_registry` on
   GDK's display. Decide the crate: `wayland-client` 0.31 with
   `wayland-backend`'s `client_system` feature wraps a foreign `*mut wl_display`
   (`Backend::from_foreign_display`); the alternative is hand-written FFI over
   `libwayland-client` like the existing `extern "C"` block, which is ~150
   lines for the handful of requests needed and no new dependency. Prefer the
   FFI if `wayland-client`'s foreign-display path proves awkward with GDK
   owning the display's default queue.
2. Create the subsurface on the toplevel's `wl_surface`, empty input region,
   opaque region, desync, `place_above`.
3. `wl_egl_window_create` + `eglCreateWindowSurface` on an EGL display from
   `eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wl_display)`. Own context,
   *not* shared with GDK's. Swap interval 0.
4. mpv render context on a thread, hwdec on. Confirm `hwdec-current=vaapi` and
   that the mpv log shows the dmabuf interop line (it should be the same as
   today: the interop only needs an EGL context on the same device).
5. Measure: `perf record -t <main thread>` must show essentially nothing at
   frame rate; `WAYLAND_DEBUG=1` should show `zwp_linux_buffer_params` /
   `wl_surface@N.attach` on the video surface only.
6. Check pointer events reach the GTK widget under the video (print from a
   `motion-notify` handler on the placeholder).
7. Check HiDPI: `set_buffer_scale(2)` and a 2× EGL window give a crisp frame at
   the right size.

Known unknowns for the spike to settle:
- **Positioning coordinates.** `wl_subsurface.set_position` is in the parent
  surface's coordinate space, which for a GTK3 CSD window *includes the shadow
  margin*. `gtk_widget_translate_coordinates(area, toplevel_widget, 0, 0)`
  should already include that offset because the `GtkWindow` widget is
  allocated the full surface; verify, and verify fullscreen (no shadow) too.
- **Applying a position change.** Subsurface position takes effect on the
  *parent's* next commit. GTK commits when it repaints. Queueing a redraw of
  the placeholder (1 px is enough) after `set_position` is the safe trigger;
  committing GTK's surface ourselves is not, as GDK may have half-built state.
- **Desync vs. resize.** During a resize the video surface and GTK's surface
  update independently and may briefly disagree by a frame. If that is visible,
  switch to `set_sync` around geometry changes only.

### Phase 1 — `wl.rs` and `egl.rs` in `src-tauri` ✅ done

Port the spike's plumbing as two small modules with the same discipline as
`gl.rs` (hand-loaded entry points, no build-time dependency on headers):

- `wl.rs`: registry bind, `Subsurface { surface, subsurface, viewport }` with
  `set_position`, `set_size` (buffer scale + viewport), `set_input_region`,
  `destroy`; own event queue + a `dispatch()` for the video thread.
- `egl.rs`: `EglDisplay`, `EglContext`, `EglWindowSurface` over
  `wl_egl_window`; `make_current`, `swap`, `resize`.

As landed: `wl::Globals::new(wl_display)` binds `wl_compositor`,
`wl_subcompositor` and (if offered) `wp_viewporter` on a private queue;
`wl::Subsurface::new(&globals, parent_wl_surface)` builds the surface with
the empty input region, `place_above`, desync; `set_position` is for the GTK
thread, `set_size(w, full_h, vis_h, scale)` (buffer scale + opaque region +
viewport crop, one commit's worth) and `unmap` are for the video thread.
`egl::EglDisplay::new(wl_display)` → `EglContext::new(&display)` →
`EglWindowSurface::new(&ctx, wl_surface, w_px, h_px)`; the render context is
dropped before the surface, the surface before the context. Phase 2 owns the
ordering.

### Phase 2 — Video thread and the widget swap ✅ done

- New `video_thread.rs` owning the state listed in §3. The mpv update callback
  becomes a channel send. `RenderCtx` moves here; `Offscreen` moves here.
- `surface.rs`: `GtkGLArea` → `GtkDrawingArea` (keep `connect_input`, the
  `Layout`, `apply_geom`, `show`/`hide_if`/`resize`/`set_bottom_clip`). Each of
  those now also posts a command to the video thread. `attach()` no longer
  needs to wait for a `render` signal: the video thread creates the render
  context as soon as it has an EGL surface, and `attach` blocks on its reply.
- Delete `connect_render`, `build_render_ctx`, `make_render_ctx`, the
  `glib::idle_add` redraw path, `sync_webview_clip`, `video_covers` and the
  webview `draw` guard: with no per-frame invalidation there is nothing left
  for them to suppress. Keep the `unrealize` hook's intent (free GL before the
  context goes) — it moves to the video thread's `Detach`/`Quit` handling.
- Keep the frontend's `body.video-covered` animation freeze
  ([`styles.css`](src/styles.css), `reflectCoverage` in
  [`main.ts`](src/main.ts)); it is still the right thing for the web process.

### Phase 3 — Picture-in-picture ✅ done (fell out of Phase 2; finished 4 Sep)

A `wl_subsurface` cannot change parent. Entering PiP therefore: destroy the
video surface and subsurface, create new ones on the PiP `GtkWindow`'s
`wl_surface`, and point the *same* EGL context and mpv render context at the
new `EGLSurface` (`eglMakeCurrent` with a different surface is allowed; the
render context does not care). Playback does not restart and, unlike today, the
render context is not rebuilt. `enter_pip`/`leave_pip`/`restore_from_pip` in
`surface.rs` shrink to widget bookkeeping plus one `Reparent` command.

As landed there is no `Reparent` command: `Ui::wl_ensure_subsurface` compares
the widget's toplevel `wl_surface` with the one the current subsurface hangs
off and, if they differ, makes a new subsurface there and sends it as
`Cmd::Surface`; the video thread rebuilds its EGL window on it and destroys
the old one. `enter_pip` and `restore_from_pip` call it once the widget is in
its new window.

#### What finishing it found: the two directions order things differently

`FELLYJIN_SURFACE_TEST=1` logs on 4 Sep showed that entering PiP the
placeholder's 480×270 allocation reached the video thread *before* the new
subsurface did (GTK allocates a toplevel's children inside `show_all`, before
it maps the window), while leaving PiP the new subsurface arrived first and the
main window's allocation followed a frame later. In the second case the thread
rebuilt the EGL window at the old 960×540 buffer size, at the PiP window's
(26,60) position, and drew straight away — one small frame in the wrong place
before the real allocation replaced it.

Fix, in `video_thread.rs` and `surface.rs`: `Cmd::Resize` now carries the
toplevel `wl_surface` the size was measured against (`Subsurface::parent`
records the one it hangs off). A size for another toplevel is held as
`State::pending`, not applied; `Surface` takes the pending size if it is for
the new parent and otherwise clears `size`, and nothing is drawn while `size`
is `None`. Two GTK details make it work in both directions: GDK creates a
window's `wl_surface` on *map*, so the allocation inside `show_all` has no
parent to be tagged with and is dropped — `wl_ensure_subsurface` therefore
pushes the widget's current geometry once it has made the subsurface; and
`gtk_widget_unparent` resets the allocation to 1×1, so that push sends nothing
stale on the way back. With the fix, the log shows the first buffer on each
new surface at the new toplevel's size, in both directions, twice over
(`6:pip,18:nopip,26:pip,40:nopip`), main thread 0.6 % of a core while in PiP, exit 0,
no protocol error.

Still open, not Phase 3's: `set_keep_above` is ignored on Wayland, so the PiP
window is a normal toplevel; and a single `eglSwapBuffers failed` is logged at
quit, from the video thread's last swap after GTK has torn the toplevel's
surface down (harmless — the thread then detaches normally).

### Phase 4 — Fullscreen bar without the blit ✅ done (on the subsurface backend; verified 4 Sep)

Today the fullscreen bar reveal shrinks the widget and blits the top rows of a
full-height FBO so the picture doesn't re-fit. With `wp_viewporter` bound, the
video surface can keep rendering full height and set
`wp_viewport.set_source(0, 0, w, h - bar)` + `set_destination(w, h - bar)`
instead — the compositor crops, no extra GL pass, and `Offscreen` can be
deleted. Optional; do it only if Phase 2 lands cleanly.

As landed: `Subsurface::set_size(w, full_h, vis_h, scale)` in `wl.rs` sets the
buffer scale, the opaque region and, when `vis_h < full_h`, the viewport
source/destination to `w × vis_h`; otherwise it unsets both. The values are
logical (CSS) pixels: `wp_viewport` applies *after* `buffer_scale` in the
buffer-to-surface transform order the protocol spells out, so its source
rectangle is in surface-local units even at scale 2. The placeholder shrinks
by the bar as before and `Layout::bar_css` adds it back for the fit height
(`Size::full_h_css`). `Offscreen` stays for the GLArea fallback only.

#### Verified 4 Sep (release build, `6:fs,11:bar,17:nobar,22:nofs`)

- Log: fullscreen `size 1440x960 css, shown 960`; bar revealed
  `size 1440x960 css, shown 888` — same fit height, same 2880×1920 buffer,
  crop of 72 CSS px; hidden again `shown 960`.
- Screenshots (Mutter ScreenCast): fullscreen has the 16:9 picture at rows
  150–1769 of 1920; with the bar revealed the picture's top edge is still row
  150 and the video rows are unchanged, while rows 1776–1919 show the page
  underneath instead — the picture is cropped, not re-fitted.
- Main thread with the bar up: 0.4–1.2 % of a core across runs. Exit 0, no
  protocol error.

One thing tightened: `State::resize` in `video_thread.rs` marked the EGL
window stale on *every* size change, so each bar toggle rebuilt the
`wl_egl_window` and EGL surface (a fresh set of full-size buffers) although
the buffer dimensions had not changed. It now rebuilds only when the buffer
dimensions differ; a crop-only change just commits with the next swap.

#### What verifying it found: the opaque video freezes GTK's frame clock

Repeating the sequence, the bar toggle was lost outright in 2 of 3 runs: no
allocation, no `Resize`, nothing until leaving fullscreen. `WAYLAND_DEBUG=1`
showed why. GTK's last paint of the fullscreen transition committed the
toplevel with a `wl_surface.frame` request; the compositor's `done` for it
arrived **16 s later, immediately after `unset_fullscreen`**. GDK 3 freezes
the frame clock between a commit and its frame callback, and Mutter does not
send frame callbacks to a surface that is fully obscured — which GTK's
toplevel is, once the video subsurface covers it with an opaque buffer of the
window's size. The runs that worked were the ones where the callback happened
to resolve before the video went full-size. Not a test artefact: the webview
cannot paint the revealed bar in that state either, since it draws through
the same frame clock.

The fix keeps the opaque region (it is what lets the compositor skip painting
GTK's surface under the video, and what makes the subsurface a direct-scanout
candidate) and instead sends the crop straight to the video thread:
`Surface::set_bottom_clip` posts `Cmd::Clip { bar_css }` alongside the GTK
layout request, and the thread applies `vis_h = full_h - bar_css` to the size
it has. Cropping exposes the strip under the bar, Mutter paints GTK's surface
again, the pending frame callback fires, GTK thaws and allocates the shrunk
placeholder, and that `Resize` matches what the thread already has. Hiding the
bar clears the crop the same way; GTK's subsequent paint is under the video
and so harmless. With the fix, three repeats of the failing timing
(`6:fs,11:bar,17:nobar,22:nofs`) plus a screenshot run all show the crop
applied and, right after it, `layout: placeholder allocated 1440x888` — GTK
thawed and caught up — and no EGL rebuild on either toggle.
`FELLYJIN_SURFACE_TEST=1` now also logs the layout path
(`layout: …` lines: want/requested, the size request, every placeholder
allocation), which is how a frozen clock shows up without a protocol trace.

### Phase 5 — Cleanup ✅ done (4 Sep)

- Remove the `WEBKIT_DMABUF_RENDERER_FORCE_SHM` default in
  [`main.rs`](src-tauri/src/main.rs) *if* measurement shows the GPU texture
  path is now cheaper: with no per-frame webview repaint the GTK3 readback
  happens only when the page changes, and the SHM path costs the web process
  a CPU copy per page change instead. Measure both; keep the cheaper.

  **Measured, kept.** With the page quiet (which it is in every state the
  app reaches on its own — idle home page, windowed and fullscreen playback,
  bar revealed: the web process used ≤ 1 tick in 10 s in all of them) the two
  settings are indistinguishable, main thread 0.6–0.8 % either way. To see a
  difference the page has to paint, so a `FELLYJIN_TEST_EVAL=<js>` hook was
  added to `lib.rs` and a full-window CSS gradient animation injected
  (worst case for both paths, 2880×1920 at the 30 fps throttle):

  | page animating, 10 s | main thread | web process |
  |---|---|---|
  | idle page, SHM | 23 % | 134 % |
  | idle page, GPU texture | 10 % | 135 % |
  | windowed playback, SHM | 32 % | 165 % |
  | windowed playback, GPU texture | 26 % | 165 % |
  | **fullscreen playback, SHM** | **0.8 %** | **0 %** |
  | fullscreen playback, GPU texture | 27 % | 161 % |

  The GPU path is cheaper only while a large animation is on screen (the
  main thread saves the SHM blit); under the video it is far worse, because
  it puts the web view's GdkWindow in GL paint mode and the `draw` guard in
  `surface.rs` no longer stops anything — the web process is not waiting on
  that draw to release a dmabuf frame, so it keeps compositing and GTK keeps
  allocating its paint surface. With SHM the guard stops the page outright.
  The app's UI has no large animations and playback is where the time goes,
  so the default stays; the `WEBKIT_DMABUF_RENDERER_FORCE_SHM=0` override
  remains for comparison. (Side note for later: the web process's 134 % for
  a plain gradient is `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` rasterising the
  whole window on the CPU; harmless for this UI, first knob to revisit if
  scrolling ever feels slow.)
- Update `README.md`'s playback paragraph and `WAYLAND-MIGRATION.md` §3 with a
  pointer here.
- Re-run the verification list below and record the numbers at the top of
  this file.

## 5. Verification

Same method as the 2026-09-03 measurements so the numbers compare:

```bash
# per-thread CPU over 10 s, main thread vs whole app
PID=$(pgrep -x fellyjin); T=/proc/$PID/task/$PID
a=$(awk '{print $14+$15}' $T/stat); b=$(awk '{print $14+$15}' /proc/$PID/stat); sleep 10
echo "main $(( $(awk '{print $14+$15}' $T/stat)-a ))0 ms/10s  app $(( $(awk '{print $14+$15}' /proc/$PID/stat)-b ))0 ms/10s"
```

Targets, fullscreen 1080p on the 2880×1920 panel:

- main thread **≤ 2%** of a core during playback (was 13% at v0.1.23);
- whole app **≤ 10%** (decode, demux, audio, uosc — unchanged by this work);
- `perf record -t <main>` shows no `cairo_surface_create_similar` or
  `gdk_cairo_draw_from_gl` at frame rate (needs
  `sudo sysctl kernel.perf_event_paranoid=1`; use `perf script --no-inline`,
  `perf report -g` stalls for minutes resolving libwebkit symbols);
- hwdec still `vaapi` in the mpv log, dmabuf interop line present;
- input: hover reveals uosc, click pauses, timeline drag seeks, keys work —
  in window, fullscreen, and PiP;
- fullscreen bar reveal does not re-fit the picture;
- PiP in and out does not restart playback;
- resize, theme change, and a second monitor with a different scale do not
  leave the video offset from its rectangle;
- quitting mid-playback exits cleanly (no libepoxy assertion in
  `journalctl --user`).

## 6. Risks

- **GDK and a surface it doesn't own.** GDK ignores Wayland events for
  surfaces it didn't create, *provided* they never get pointer or keyboard
  focus. The empty input region guarantees that. Do not leave it out even for
  a test.
- **Event-queue mixups.** Any object created without its own queue is
  dispatched on the GTK thread. The spike must check `wl_proxy_get_queue` style
  invariants once, then the `wl.rs` constructor enforces them.
- **`gdk_wayland_window_get_wl_surface` on a child `GdkWindow`** returns the
  toplevel's surface (GTK3 child windows are client-side). Always call it on
  the toplevel's window and position the subsurface in toplevel coordinates.
- **Fractional scaling.** GTK3 only does integer scale; we match it. If the
  desktop uses `scale-monitor-framebuffer` fractional scaling (it does on the
  reference machine, per `gsettings`), GTK3 renders at the next integer scale
  and the compositor downscales — the video surface will be treated the same
  way. Sharper output via `wp_fractional_scale_v1` on the video surface alone is
  possible later; note it, don't do it now.
- **Mutter quirks with desync subsurfaces.** Known to work (Firefox and
  GStreamer use them); if positioning lags a frame behind a window resize,
  Phase 0 item "desync vs. resize" is the switch to flip.
- **An opaque subsurface that covers the toplevel starves GTK.** Mutter sends
  no frame callbacks to a fully obscured surface, and GDK 3 freezes its frame
  clock until the callback arrives, so GTK stops laying out and painting for
  as long as the video covers everything (found in Phase 4 verification, see
  there). Anything GTK must do while fullscreen has to either not need the
  frame clock or first expose part of GTK's surface — the bar crop does the
  latter. Keep this in mind for any future fullscreen UI drawn by GTK/WebKit.
- **X11 session.** None of this applies; keep the `GtkGLArea` path as the
  X11 fallback (`GDK_BACKEND=x11` is already a supported override in
  `main.rs`). The `Surface` API is the seam: two implementations behind it.

## 7. Effort

Roughly two to four working days: a day for the spike, a day for Phases 1–2,
half a day each for PiP and the viewport crop, and the rest for measurement
and the X11 fallback seam. New code ~700 lines, deleted ~300. The frontend does
not change.
