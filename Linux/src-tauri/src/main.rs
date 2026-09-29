#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // No backend override: video is rendered through libmpv's render API into
    // a GtkGLArea we own (see WAYLAND-MIGRATION.md), so the app runs as a
    // plain client on whichever backend GDK picks — native Wayland under a
    // Wayland session, X11 otherwise. AQUARIUM_GDK_BACKEND overrides this for
    // debugging, e.g. `AQUARIUM_GDK_BACKEND=x11` to compare against the old
    // embedding path (hwdec resolves to `no` there — see Phase 0).
    if let Ok(v) = std::env::var("AQUARIUM_GDK_BACKEND") {
        if !v.is_empty() {
            std::env::set_var("GDK_BACKEND", v);
        }
    }
    webkit_defaults();
    aquarium_lib::run()
}

/// WebKitGTK tuning for a mostly static page sitting next to a video surface.
/// These have to be in the environment before wry initialises WebKit, which
/// is why they live here rather than in `lib.rs`. Each is only set when the
/// environment doesn't already say otherwise, so `WEBKIT_FORCE_VBLANK_TIMER=0
/// aquarium` gets the stock behaviour back for comparison, and
/// `AQUARIUM_WEBKIT_DEFAULTS=0` skips all of them at once.
fn webkit_defaults() {
    if std::env::var("AQUARIUM_WEBKIT_DEFAULTS").as_deref() == Ok("0") {
        return;
    }
    let defaults = [
        // `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` — shared-memory web frames —
        // was set here from 4 Sep 2026 until 23 Sep 2026. It was kept for one
        // case: a page animating *under* fullscreen video, where a dmabuf
        // frame puts the web view in GL paint mode and the `draw` guard in
        // `surface.rs` cannot stop it (fullscreen over a synthetic animation:
        // SHM main 0.8 %, dmabuf main 27 % and web process 160 %).
        //
        // That case no longer arises: nothing in the page animates forever
        // any more (styles.css), the finite animations and the Home hero
        // stand down under the video, and the player bar stops redrawing
        // while it's tucked away (main.ts `barOutOfSight`). Re-measured
        // 23 Sep 2026 on the 2880×1920 panel, UI + web process:
        //
        //   scrolling 400 posters:   SHM ~60 % of a core, dmabuf ~32 %,
        //                            both 31 fps, p95 33 ms;
        //   fullscreen playback:     SHM 13.1 %, dmabuf 12.8 %;
        //   windowed playback:       SHM 15.9 %, dmabuf 16.5 %;
        //   idle page:               both ~0.
        //
        // Browsing is where the page spends its CPU, so the stock dmabuf
        // path wins. `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1 aquarium` still
        // selects the old path for comparison.
        // Under the vblank timer below WebKit takes the panel for 60 Hz (a
        // throttle of 120 is rejected as "not a factor of refresh rate
        // 60fps"), and a scrolling frame costs two ticks of whatever rate it
        // runs at — the rAF callback moves the page on one, and the finished
        // frame has to be handed to the UI process and acknowledged from its
        // draw before the next callback is scheduled. Measured 4 Sep 2026
        // scrolling the Home page (80 posters, 1440×881 CSS at scale 2) with
        // the easing loop in `scroll.ts`: a throttle of 30 gave 15 fps with
        // every frame 65 ms — the visibly stuttery scrolling — while 60 gives
        // the same 30 fps stock WebKit lands on for this box. The timer stops
        // when nothing on the page needs a frame, so the throttle only costs
        // anything while something moves; 60 is where that cost buys nothing.
        ("WEBKIT_DISPLAY_REFRESH_THROTTLE_FPS", "60"),
        // `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` — paint tiles on the CPU so the
        // web process never wakes the GPU for a tile upload — was set here
        // until 4 Sep 2026. Same scroll measurement, SHM frames, throttle 60:
        // CPU tiles cost the web process 67 % of a core with a 38 ms
        // 95th-percentile frame; GPU tiles 46 % and 33 ms, the main thread
        // ~10 points higher and the app+web total ~10 points lower. Tighter
        // frames for less CPU. With the page quiet neither path paints, so
        // idle is the same either way.
        // Without this WebKit watches the panel's real vblank through DRM and
        // wakes a thread 120 times a second for as long as the view is
        // visible, whether or not anything on the page moves. A timer honours
        // the throttle above and stops when nothing needs it.
        ("WEBKIT_FORCE_VBLANK_TIMER", "1"),
    ];
    for (key, value) in defaults {
        if std::env::var_os(key).is_none() {
            std::env::set_var(key, value);
        }
    }
}
