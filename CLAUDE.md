# Aquarium

Linux Jellyfin client: Tauri 2 (GTK3 + WebKitGTK 4.1) with a TypeScript/Vite frontend in `src/` and Rust in `src-tauri/src/`. Video is libmpv rendered in-process. On Wayland it draws from the `aquarium-video` thread into a `wl_subsurface` (`video_thread.rs`, `surface.rs` `Backend::Wl`). On X11, when there's no wp_viewporter, or with `AQUARIUM_VIDEO_BACKEND=gl`, it uses the GtkGLArea path (`Backend::Gl`). The project was called FellyJin until 2026-09-23. The local folder still has that name, and so do older notes.

## Build, install, test

- `npm run build` type-checks and builds the frontend. `cargo test` in `src-tauri/` runs the Rust unit tests.
- `./build-deb.sh` produces the release binary (`src-tauri/target/release/aquarium`) and `aquarium.deb`. Use it (or `npx tauri build`) before any run that shows the UI. A plain `cargo build` has no `custom-protocol` feature, so the webview shows "Could not connect to localhost".
- Run `./bump-version.sh` before a build meant for installing. apt skips a package at the version that's already installed.
- Installing needs interactive sudo (`./reinstall.sh --no-build`). Build the .deb and hand that step to the user.
- Run binaries by absolute path, because the Bash cwd resets between calls.

## Test hooks (env vars, read in `lib.rs`/`main.rs`)

- `AQUARIUM_TEST_PLAY=<file|url>` autoplays. It bypasses `resolve_stream`, so to test Live TV, click a channel via TEST_EVAL instead.
- `AQUARIUM_TEST_SEQUENCE="7:fs,11:bar,15:nobar,18:nofs,22:pip,29:nopip"` drives the player. The steps are `fs nofs bar nobar pip nopip stop play`.
- `AQUARIUM_TEST_EVAL=<js>` runs JS in the main webview 4 s after start. The app restores its last route, so the script should set `location.hash` itself. It can call `window.__TAURI_INTERNALS__.invoke("jf_request", {path, method, body})` with the real keyring token. To report results, use `new Image().src="http://127.0.0.1:8765/?m=…"` to reach a small Python receiver (CSP allows http images).
- `AQUARIUM_TEST_INPUT=1` sends a synthetic click and touch, `AQUARIUM_TEST_REPLAY` restarts playback mid-stream, and `AQUARIUM_SURFACE_TEST=1` logs geometry, frame gaps and swap times.
- `AQUARIUM_MPV_CONFIG=<dir>`: point it at a copy of `src-tauri/mpv-config` with `mute=yes` added so test runs stay silent.
- The debug log is `~/.local/share/aquarium/debug.log`. Test instances share the user's config and log.

Working without hands on this machine:
- End test instances with `kill <pid>` and confirm with `kill -0`. MPRIS Quit would close the user's own instance.
- Start a background receiver with `>/dev/null 2>&1`, or the Bash call never returns. Don't `pkill -f receiver.py` (it matches the calling shell); use `pgrep -f "^python3 receiver.py"`.
- Screenshots: `org.gnome.Shell.Screenshot` and the portal are denied. Mutter ScreenCast plus `gst-launch-1.0 pipewiresrc` works; the recipe is in `wayland-spike/README.md`. Frames lag about 3 s.
- `date` here is uutils and mangles `%3N`; use `$EPOCHREALTIME`. perf, strace and gdb need sudo (`perf_event_paranoid=4`), so profile by sampling `/proc/<pid>/task/*/stat`.

## Invariants (each one cost a real investigation)

- Any new video geometry path goes through `surface.rs` `intended_alloc()`, which derives size from the overlay. A hidden widget keeps a stale allocation, and an opaque subsurface covering the toplevel stops Mutter's frame callbacks, which freezes GTK's frame clock.
- Pointer-driven UI over the video must ignore out-of-window or repeated `mousemove`s (`fsPointerMoved` in `main.ts`). WebKitGTK turns enter/leave crossings into mousemoves, which caused a reveal/hide loop.
- Avoid infinite CSS animations on screens that stay visible (pulsing dots, skeleton sweeps, spinners). With `WEBKIT_DMABUF_RENDERER_FORCE_SHM`, one 8 px pulsing dot costs about 60% of the main thread and 1.8 W, because each frame repaints the whole 2880×1920 view.
- The WebKit env defaults in `main.rs` (FORCE_SHM, THROTTLE_FPS=60, FORCE_VBLANK_TIMER) were measured; the reasoning is in the comments there. Re-measure before changing them.
- Keep the GtkOverlay as the window's direct child (Window > Overlay > WebView). With the old layout, wry's touch handler panicked on the first touchscreen tap.
- libmpv's property setter is `mpv_set_property`. `Session::command` maps the IPC name `set_property` to it; keep that mapping.
- Don't remove the legacy `fellyjin` migration code without asking: `config::migrate_legacy_dirs`, `secret::LEGACY_SERVICE`/`adopt_legacy` and the localStorage carry-over in `public/theme-boot.js`. It keeps existing installs logged in.
- Frontend views that fetch server data go through `getCached`/`setCached` (`src/cache.ts`, backed by IndexedDB) with a signature compare, so screens paint instantly and repaint only on change.
- Jellyfin API calls use the `userId=` query routes (`/UserViews`, `/UserItems/Resume`, `/Items?userId=`). Don't send `X-Emby-Token`, because Jellyfin 12 ignores legacy auth by default. The supported range is 10.9–12.x.

## Docs

`WAYLAND-MIGRATION.md` and `WAYLAND-SUBSURFACE-PLAN.md` record completed work: every phase has shipped. Read them for the reasoning, not as a to-do list.

## Environment

Framework laptop with Intel Panther Lake (xe driver), 2880×1920 at scale 2 and 120 Hz, GNOME 50 on Wayland, Mesa 26, libmpv 0.41, GTK 3.24, WebKitGTK 2.52. The ~100 ms stutter every 10 s during playback comes from a gnome-shell main-loop stall, not from the app. While the Claude desktop app is running, gnome-shell CPU numbers are inflated by its repaints.
