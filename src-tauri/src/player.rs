use crate::surface::{self, Surface, SurfaceShared};
use crate::{jellyfin, mpv, progress};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::Mutex;

const TICKS_PER_SECOND: f64 = 10_000_000.0;

#[derive(Clone, Debug, Default, Serialize)]
pub struct Status {
    pub active: bool,
    pub position: f64,
    pub duration: f64,
    pub paused: bool,
    pub title: String,
    pub item_id: String,
    pub embedded: bool,
    /// mpv's own audio scale, 0–130. Mirrored here (rather than tracked in the
    /// frontend) because mpv is also driven by its uosc overlay and its own key
    /// bindings, so the UI can't assume it owns these values.
    pub volume: f64,
    pub mute: bool,
    pub speed: f64,
    /// Subtitle timing offset in seconds; negative shows subtitles earlier.
    pub sub_delay: f64,
    /// Absolute position, in seconds, that the demuxer cache has read up to —
    /// the end of the buffered region drawn behind the scrubber. Zero means mpv
    /// hasn't reported one yet (or isn't caching, as with a local file).
    pub buffered: f64,
    /// Chapter marks for the scrubber. Empty for media without chapters, which
    /// is most of it.
    pub chapters: Vec<Chapter>,
    /// True while mpv has stopped the picture to refill its cache. A stream the
    /// connection can't carry stalls here long before it fails outright, which
    /// is what makes this worth reporting rather than just drawing.
    pub buffering: bool,
    /// Frames the decoder gave up on because it couldn't keep pace, and frames
    /// the video output threw away for the same reason. Counted separately by
    /// mpv (which of the two rises depends on `--framedrop`), so both are kept
    /// and the sum is what anyone downstream cares about: the machine, not the
    /// network, is the thing falling behind.
    pub drops_decoder: u64,
    pub drops_vo: u64,
    /// The decoder mpv actually ended up using ("vaapi", "nvdec", "no", …).
    /// Asking for hardware decoding and getting it are different things: mpv
    /// falls back to software silently, and the only symptom is a warm laptop.
    /// Empty until mpv has opened the file and reported one.
    pub hwdec: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Chapter {
    /// Start time in seconds.
    pub time: f64,
    /// mpv's chapter title, empty when the container only stores times.
    pub title: String,
}

/// Everything needed to report playback state back to Jellyfin.
#[derive(Clone, Serialize, Deserialize)]
pub struct PlayContext {
    pub item_id: String,
    #[serde(default)]
    pub media_source_id: Option<String>,
    #[serde(default)]
    pub play_session_id: Option<String>,
    #[serde(default)]
    pub play_method: Option<String>,
    #[serde(default)]
    pub server_url: Option<String>,
    // No token here. The frontend doesn't have one to send any more — it comes
    // from the keyring at the moment each request goes out (see `secret.rs`).
    #[serde(default)]
    pub user_id: Option<String>,
    #[serde(default)]
    pub device_id: Option<String>,
    #[serde(default)]
    pub is_local: bool,
    #[serde(default)]
    pub live: bool,
}

#[derive(Deserialize)]
pub struct PlayRequest {
    pub url: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub start_seconds: Option<f64>,
    /// Real runtime from server metadata. Transcoded downloads are saved from
    /// a live mux with no duration in the container, so mpv can only estimate
    /// (and the estimate grows during playback); when this is set it wins over
    /// whatever mpv reports.
    #[serde(default)]
    pub known_duration_seconds: Option<f64>,
    /// Starting audio level (0–130). Passed on mpv's command line rather than
    /// set over IPC afterwards, so a session the user left quiet doesn't open
    /// with a burst at full volume.
    #[serde(default)]
    pub volume: Option<f64>,
    #[serde(default)]
    pub ctx: Option<PlayContext>,
}

struct SessionHandle {
    session: Arc<mpv::Session>,
    stop: Arc<AtomicBool>,
    /// Signalled by the supervisor once mpv has fully shut down.
    exited: Arc<tokio::sync::Notify>,
    exited_flag: Arc<AtomicBool>,
}

pub struct Player {
    session: Mutex<Option<SessionHandle>>,
    status: Arc<StdMutex<Status>>,
    /// Fullscreen viewport: video covers the player bar too.
    pub viewport_full: AtomicBool,
    /// In fullscreen: the auto-hiding player bar is currently revealed, so
    /// the video is shrunk by the bar height to keep the bar clickable
    /// (HTML can never draw over the X11 video child window).
    pub bar_reveal: AtomicBool,
    /// Bumped on every play(); lets a finished session detect it has been
    /// superseded so it doesn't clobber the replacement's state.
    epoch: Arc<AtomicU64>,
    /// Held while an mpv session is active so the screen doesn't sleep.
    /// mpv can't inhibit for itself here — it has no window of its own to
    /// hook the built-in mechanism through (see idle.rs).
    idle: StdMutex<Option<crate::idle::IdleInhibitor>>,
    /// Whether something follows the current item. Only the frontend knows —
    /// it's a question about the series, not about the file mpv has open — so
    /// it's pushed down here for MPRIS's `CanGoNext` to report.
    next_available: AtomicBool,
}

/// The `Authorization` header mpv should send for this stream, if any. Skipped
/// for local files and when there's no stored token.
///
/// The token is only ever sent to the Jellyfin server it belongs to. A custom
/// Live TV playlist streams from whatever hosts the user's provider names, and
/// handing our credential to one of those would leak it to a third party — so
/// the stream URL has to sit under the server URL this context carries.
fn http_auth_header(req: &PlayRequest) -> Option<String> {
    if !req.url.starts_with("http://") && !req.url.starts_with("https://") {
        return None;
    }
    let ctx = req.ctx.as_ref()?;
    let server = ctx.server_url.as_deref()?.trim_end_matches('/');
    if server.is_empty() || !req.url.starts_with(server) {
        return None;
    }
    let token = crate::secret::token()?;
    let device = ctx.device_id.as_deref().unwrap_or("fellyjin");
    Some(jellyfin::auth_header(&token, device))
}

impl Player {
    pub fn new() -> Self {
        Self {
            session: Mutex::new(None),
            status: Arc::new(StdMutex::new(Status::default())),
            viewport_full: AtomicBool::new(false),
            bar_reveal: AtomicBool::new(false),
            epoch: Arc::new(AtomicU64::new(0)),
            idle: StdMutex::new(None),
            next_available: AtomicBool::new(false),
        }
    }

    pub fn is_active(&self) -> bool {
        self.status.lock().unwrap().active
    }

    pub fn next_available(&self) -> bool {
        self.next_available.load(Ordering::SeqCst)
    }

    pub fn set_next_available(&self, v: bool) {
        self.next_available.store(v, Ordering::SeqCst);
    }

    pub fn status(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    pub async fn send(&self, cmd: Value) -> Result<(), String> {
        let guard = self.session.lock().await;
        match guard.as_ref() {
            Some(s) => s.session.command(cmd),
            None => Err("no active playback".into()),
        }
    }

    /// Hold the screen-wake inhibitor only while video is actually playing.
    ///
    /// Keeping it across a pause is what leaves a laptop awake all night on a
    /// paused episode: nothing else in the session releases it until mpv
    /// exits, so a paused film blocks both blanking and suspend indefinitely.
    ///
    /// The wanted state is read from `status` *under the idle lock* rather
    /// than passed in, so that rapid pause/unpause toggles — which each land
    /// here on their own blocking task, in no guaranteed order — can't settle
    /// on a stale answer. Whichever call takes the lock last sees the truth.
    fn sync_idle_inhibit(&self, status: &Arc<StdMutex<Status>>) {
        let mut guard = self.idle.lock().unwrap();
        let want = {
            let st = status.lock().unwrap();
            st.active && !st.paused
        };
        if want == guard.is_some() {
            return;
        }
        if want {
            *guard = match crate::idle::IdleInhibitor::new() {
                Ok(i) => Some(i),
                Err(e) => {
                    crate::debug_log_line(&format!("player: idle-inhibit failed: {}", e));
                    None
                }
            };
        } else {
            guard.take();
        }
    }

    pub async fn stop(&self) {
        self.idle.lock().unwrap().take();
        // Whatever followed the old item says nothing about the new one; the
        // frontend re-answers once it has resolved what's playing.
        self.next_available.store(false, Ordering::SeqCst);
        let taken = {
            let mut guard = self.session.lock().await;
            guard.take()
        };
        if let Some(s) = taken {
            s.stop.store(true, Ordering::SeqCst);
            let _ = s.session.command(json!(["quit"]));
            // Wait for mpv to actually shut down before the caller reuses the
            // video surface or starts a replacement session. Two mpv cores
            // tearing down / bringing up VAAPI and a render context on the
            // same GLArea concurrently is a recipe for a black video window.
            if s.exited_flag.load(Ordering::SeqCst) {
                return;
            }
            let waited =
                tokio::time::timeout(std::time::Duration::from_secs(3), s.exited.notified()).await;
            if waited.is_err() && !s.exited_flag.load(Ordering::SeqCst) {
                // mpv is linked into this process now, so there is no child
                // to fall back to killing if "quit" is ignored — see
                // WAYLAND-MIGRATION.md §6. Log it and move on; the next
                // play() will still try to attach a fresh session onto the
                // surface.
                crate::debug_log_line("player: mpv did not confirm shutdown within 3s");
            }
        }
    }

    /// Best-effort synchronous stop for app shutdown.
    pub fn stop_sync(&self) {
        self.idle.lock().unwrap().take();
        if let Ok(mut guard) = self.session.try_lock() {
            if let Some(s) = guard.take() {
                s.stop.store(true, Ordering::SeqCst);
                let _ = s.session.command(json!(["quit"]));
            }
        }
    }

    pub async fn play(&self, app: AppHandle, req: PlayRequest) -> Result<(), String> {
        // stop() blocks until the previous mpv session has fully shut down,
        // so the new one never overlaps it on the GPU or the video surface.
        self.stop().await;
        let my_epoch = self.epoch.fetch_add(1, Ordering::SeqCst) + 1;

        let title = req.title.clone().unwrap_or_else(|| "FellyJin".to_string());
        let is_live = req.ctx.as_ref().map(|c| c.live).unwrap_or(false);

        self.viewport_full.store(false, Ordering::SeqCst);
        self.bar_reveal.store(false, Ordering::SeqCst);

        // The video surface is the only video output now — there is no
        // mpv-owned window to fall back to — so playback simply cannot start
        // without it.
        let surface_arc: Arc<Surface> = app
            .try_state::<SurfaceShared>()
            .and_then(|s| s.0.clone())
            .ok_or("Video surface unavailable")?;

        let win = app
            .get_webview_window("main")
            .ok_or("No window to play into")?;
        let size = win.inner_size().unwrap_or(tauri::PhysicalSize {
            width: 1280,
            height: 800,
        });
        let scale = win.scale_factor().unwrap_or(1.0);
        let (x, y, w, h) = surface::geometry(size, scale, true);
        let surface_session = surface_arc.show(x, y, w, h)?;

        let start = req.start_seconds.filter(|s| *s > 1.0 && !is_live);
        let start_volume = req.volume.unwrap_or(100.0).clamp(0.0, 130.0);
        let opts = mpv::Options {
            title: title.clone(),
            volume: start_volume,
            start,
            // Authenticate with a header rather than an `api_key=` query
            // parameter, so the token never lands in Jellyfin's access log or
            // in our own mpv log for every stream we open.
            auth_header: http_auth_header(&req),
            prefs: crate::prefs::Prefs::load().args(),
        };

        let (session, mut rx) = match mpv::Session::start(opts) {
            Ok(s) => s,
            Err(e) => {
                surface_arc.hide_if(surface_session);
                return Err(e);
            }
        };
        let session = Arc::new(session);

        // Hand the surface the handle and wait for the render context to
        // exist before loading anything. mpv initialises `vo=libmpv` while it
        // opens the file, and a render context that isn't there yet means it
        // gives up on video for that file entirely — so a failed attach is a
        // failed play. `attach` blocks the calling thread for up to 2s and
        // must not run on the GTK main thread, so it goes on a blocking task
        // rather than directly in this async fn.
        let handle = session.handle();
        let attach_surface = surface_arc.clone();
        let attached = tokio::task::spawn_blocking(move || attach_surface.attach(handle))
            .await
            .map_err(|e| e.to_string())?;
        if let Err(e) = attached {
            let _ = session.command(json!(["quit"]));
            surface_arc.detach();
            surface_arc.hide_if(surface_session);
            return Err(format!("Video surface failed: {e}"));
        }

        for (id, prop) in [
            (1, "time-pos"),
            (2, "pause"),
            (3, "duration"),
            (4, "track-list"),
            // Diagnostic: false while audio plays means the video output never
            // came up — the "sound but black screen" class of bug.
            (5, "vo-configured"),
            // Mouse motion over the video: mpv owns the pointer there, so the
            // frontend needs this to reveal its auto-hiding fullscreen bar.
            (6, "mouse-pos"),
            // Audio and subtitle-timing state. Observed rather than assumed:
            // mpv's own bindings and the uosc overlay change these too, and the
            // player bar has to keep showing the truth.
            (7, "volume"),
            (8, "mute"),
            (9, "speed"),
            (10, "sub-delay"),
            // How far ahead the stream has been read, and where the chapters
            // are: the two things the scrubber needs to stop being a bare line.
            (11, "demuxer-cache-time"),
            (12, "chapter-list"),
            // The two ways a stream turns out to be more than what's carrying
            // it: the cache running dry (network), and frames being thrown
            // away to keep up (machine). Both feed the adaptive-quality policy.
            (13, "paused-for-cache"),
            (14, "decoder-frame-drop-count"),
            (15, "frame-drop-count"),
            // Which decoder mpv settled on, so Settings can report the truth
            // rather than repeating what was asked for.
            (16, "hwdec-current"),
            // mpv's own accounting of frames shown late or at the wrong
            // time; logged under FELLYJIN_SURFACE_TEST next to the video
            // thread's frame gaps, to tell a late frame from a held one.
            (17, "vo-delayed-frame-count"),
            (18, "mistimed-frame-count"),
        ] {
            if let Err(e) = session.command(json!(["observe_property", id, prop])) {
                crate::debug_log_line(&format!("player: observe {} failed: {}", prop, e));
            }
        }

        if let Err(e) = session.command(json!(["loadfile", &req.url])) {
            let _ = session.command(json!(["quit"]));
            surface_arc.detach();
            surface_arc.hide_if(surface_session);
            return Err(format!("Could not load file: {e}"));
        }

        {
            let mut st = self.status.lock().unwrap();
            *st = Status {
                active: true,
                position: req.start_seconds.unwrap_or(0.0),
                duration: req.known_duration_seconds.unwrap_or(0.0),
                paused: false,
                title: title.clone(),
                item_id: req
                    .ctx
                    .as_ref()
                    .map(|c| c.item_id.clone())
                    .unwrap_or_default(),
                embedded: true,
                volume: start_volume,
                mute: false,
                speed: 1.0,
                sub_delay: 0.0,
                buffered: 0.0,
                chapters: Vec::new(),
                buffering: false,
                drops_decoder: 0,
                drops_vo: 0,
                hwdec: String::new(),
            };
        }

        // Keep the screen awake while playing (best effort — a desktop
        // without org.freedesktop.ScreenSaver just logs and plays on). This is
        // released and re-taken as the stream pauses and resumes; see
        // `sync_idle_inhibit`.
        self.sync_idle_inhibit(&self.status);

        // A new title on the lock screen shouldn't wait for the first status
        // tick a second from now.
        crate::mpris::notify();

        let exited = Arc::new(tokio::sync::Notify::new());
        let exited_flag = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        *self.session.lock().await = Some(SessionHandle {
            session: session.clone(),
            stop: stop.clone(),
            exited: exited.clone(),
            exited_flag: exited_flag.clone(),
        });

        crate::debug_log_line(&format!(
            "player: mpv core up surface={} url={}",
            surface_session,
            req.url.chars().take(90).collect::<String>()
        ));

        // Supervisor task: reads events, keeps status fresh, reports to Jellyfin.
        let status = self.status.clone();
        let lock_duration = req.known_duration_seconds.is_some();
        let ctx = req.ctx.clone();
        let surface_task = surface_arc.clone();
        let epoch = self.epoch.clone();
        let session_task = session.clone();
        tokio::spawn(async move {
            report_start(&ctx, &status).await;
            let mut own_final = { status.lock().unwrap().clone() };

            let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut last_report = std::time::Instant::now();
            // mouse-pos fires per pixel; throttle what crosses the bridge.
            let mut last_mouse = std::time::Instant::now() - std::time::Duration::from_secs(1);
            // Why the file ended, for the frontend to tell "the stream
            // couldn't be opened" from a stop or a natural end. mpv reports
            // it on the end-file event and nowhere else.
            let mut end_reason: Option<String> = None;
            let mut end_error: Option<String> = None;

            loop {
                let superseded = epoch.load(Ordering::SeqCst) != my_epoch;
                tokio::select! {
                    msg = rx.recv() => {
                        match msg {
                            Some(msg) => {
                                // libmpv's idle mode means the core outlives
                                // the file: unlike the old external process,
                                // end-file does not shut anything down by
                                // itself, so ask for real.
                                if msg.get("event").and_then(|v| v.as_str()) == Some("end-file") {
                                    end_reason = msg.get("reason").and_then(|v| v.as_str()).map(str::to_string);
                                    end_error = msg.get("file_error").and_then(|v| v.as_str()).map(str::to_string);
                                    let _ = session_task.command(json!(["quit"]));
                                }
                                if superseded {
                                    // Only remember our final position.
                                    track_position(&msg, &mut own_final, lock_duration);
                                    continue;
                                }
                                if msg.get("event").and_then(|v| v.as_str()) == Some("property-change")
                                    && msg.get("name").and_then(|v| v.as_str()) == Some("mouse-pos")
                                {
                                    if last_mouse.elapsed().as_millis() >= 200 {
                                        last_mouse = std::time::Instant::now();
                                        let _ = app.emit(
                                            "player-mouse",
                                            msg.get("data").cloned().unwrap_or(Value::Null),
                                        );
                                    }
                                    continue;
                                }
                                let pause_changed = apply_event(&msg, &status, &app, lock_duration);
                                own_final = status.lock().unwrap().clone();
                                if pause_changed {
                                    // Release the screen-wake inhibitor while
                                    // paused, re-take it on resume. Off the
                                    // loop: IdleInhibitor's D-Bus round trip
                                    // blocks for up to TIMEOUT (2s), and
                                    // stalling here would stall mpv's event
                                    // stream and the status ticks with it.
                                    let app_idle = app.clone();
                                    let status_idle = status.clone();
                                    tokio::task::spawn_blocking(move || {
                                        if let Some(p) = app_idle.try_state::<Player>() {
                                            p.sync_idle_inhibit(&status_idle);
                                        }
                                    });
                                    emit_status(&app, &status);
                                    report_progress(&ctx, &status).await;
                                    last_report = std::time::Instant::now();
                                }
                            }
                            None => break,
                        }
                    }
                    _ = tick.tick() => {
                        if superseded { continue; }
                        let diag = crate::surface::debug_enabled();
                        let t0 = std::time::Instant::now();
                        emit_status(&app, &status);
                        if diag {
                            eprintln!("fellyjin: player: status tick at {} ({} ms)", crate::now_ms(), t0.elapsed().as_millis());
                        }
                        if last_report.elapsed().as_secs() >= 10 {
                            let t1 = std::time::Instant::now();
                            report_progress(&ctx, &status).await;
                            if diag {
                                eprintln!("fellyjin: player: progress report at {} ({} ms)", crate::now_ms(), t1.elapsed().as_millis());
                            }
                            last_report = std::time::Instant::now();
                        }
                    }
                }
            }

            // mpv shut down (user stopped, the file ended and we asked it to
            // quit, or a new session replaced us). Only touch shared state if
            // we are still the current session.
            exited_flag.store(true, Ordering::SeqCst);
            exited.notify_one();
            crate::debug_log_line(&format!(
                "player: mpv session ended pos={:.1} requested_stop={} reason={:?} error={:?}",
                { status.lock().unwrap().position },
                stop.load(Ordering::SeqCst),
                end_reason,
                end_error,
            ));
            let current = epoch.load(Ordering::SeqCst) == my_epoch;
            surface_task.hide_if(surface_session);
            if current {
                // Clear `active` *before* dropping the inhibitor: a pause
                // toggle racing the exit has a `sync_idle_inhibit` task in
                // flight, and it decides from `active`. Released-then-cleared
                // would let that task re-take the inhibitor into the gap and
                // hold it for the rest of the app's life.
                {
                    let mut st = status.lock().unwrap();
                    st.active = false;
                }
                // Natural EOF / external exit: stop() never ran, so the
                // idle inhibitor is still held — release it here.
                if let Some(p) = app.try_state::<Player>() {
                    p.idle.lock().unwrap().take();
                }
                let _ = app.emit(
                    "player-status",
                    json!({
                        "active": false,
                        "ended": true,
                        // Distinguishes user-initiated stop from natural EOF,
                        // so the frontend only autoplays after a real EOF.
                        "requested_stop": stop.load(Ordering::SeqCst),
                        // mpv's word on how the file ended: "eof", "stop",
                        // "quit", "error" (with `error` filled in), or
                        // "redirect" — the last is mpv having fallen back to
                        // reading the address as a playlist, which for a
                        // stream means the real demuxer refused it.
                        "reason": end_reason,
                        "error": end_error,
                        "position": own_final.position,
                        "duration": own_final.duration,
                        "item_id": own_final.item_id,
                    }),
                );
                // This emit bypasses emit_status, so the shell's controls need
                // telling separately that playback stopped.
                crate::mpris::notify();
            }
            report_stopped(&ctx, &own_final).await;
        });

        Ok(())
    }
}

/// Update a private status copy from a property-change message. Used by a
/// superseded session that may no longer write to the shared status.
fn track_position(msg: &Value, st: &mut Status, lock_duration: bool) {
    if msg.get("event").and_then(|v| v.as_str()) != Some("property-change") {
        return;
    }
    let data = msg.get("data");
    match msg.get("name").and_then(|v| v.as_str()) {
        Some("time-pos") => {
            if let Some(p) = data.and_then(|v| v.as_f64()) {
                st.position = p;
            }
        }
        Some("duration") if !lock_duration => {
            if let Some(d) = data.and_then(|v| v.as_f64()) {
                st.duration = d;
            }
        }
        _ => {}
    }
}

/// Apply one mpv IPC message to shared status. Returns true when the pause
/// state flipped (which warrants an immediate progress report).
fn apply_event(
    msg: &Value,
    status: &Arc<StdMutex<Status>>,
    app: &AppHandle,
    lock_duration: bool,
) -> bool {
    match msg.get("event").and_then(|v| v.as_str()) {
        Some("property-change") => {}
        Some("client-message") => {
            // script-messages from the uosc control layer (quality menu,
            // episode queue, fullscreen…) — handled by the frontend.
            if let Some(args) = msg.get("args") {
                let _ = app.emit("player-message", args.clone());
            }
            return false;
        }
        _ => return false,
    }
    let name = msg.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let data = msg.get("data");
    let mut pause_changed = false;
    match name {
        "time-pos" => {
            if let Some(p) = data.and_then(|v| v.as_f64()) {
                status.lock().unwrap().position = p;
            }
        }
        "duration" if !lock_duration => {
            if let Some(d) = data.and_then(|v| v.as_f64()) {
                status.lock().unwrap().duration = d;
            }
        }
        "pause" => {
            if let Some(p) = data.and_then(|v| v.as_bool()) {
                let mut st = status.lock().unwrap();
                if st.paused != p {
                    st.paused = p;
                    pause_changed = true;
                }
            }
        }
        "track-list" => {
            if let Some(tracks) = data {
                let _ = app.emit("player-tracks", tracks.clone());
            }
        }
        "volume" => {
            if let Some(v) = data.and_then(|v| v.as_f64()) {
                status.lock().unwrap().volume = v;
            }
        }
        "mute" => {
            if let Some(m) = data.and_then(|v| v.as_bool()) {
                status.lock().unwrap().mute = m;
            }
        }
        "speed" => {
            if let Some(s) = data.and_then(|v| v.as_f64()) {
                status.lock().unwrap().speed = s;
            }
        }
        "sub-delay" => {
            if let Some(d) = data.and_then(|v| v.as_f64()) {
                status.lock().unwrap().sub_delay = d;
            }
        }
        // mpv reports the cache as a duration ahead of the play position on
        // some demuxers and as an absolute timestamp on others; both are
        // covered by taking whichever reading is further into the file.
        "demuxer-cache-time" => {
            if let Some(t) = data.and_then(|v| v.as_f64()) {
                let mut st = status.lock().unwrap();
                st.buffered = t.max(st.position);
            }
        }
        "chapter-list" => {
            if let Some(list) = data.and_then(|v| v.as_array()) {
                // A mark at 0:00 is the start of the file, not a division in
                // it; drawing it would just thicken the left edge.
                let marks: Vec<Chapter> = list
                    .iter()
                    .filter_map(|c| {
                        let time = c.get("time").and_then(|t| t.as_f64())?;
                        (time > 0.0).then(|| Chapter {
                            time,
                            title: c
                                .get("title")
                                .and_then(|t| t.as_str())
                                .unwrap_or_default()
                                .to_string(),
                        })
                    })
                    .collect();
                status.lock().unwrap().chapters = marks;
            }
        }
        // Playback has stopped dead waiting for data. Emitted as its own event
        // rather than left for the next status tick: the adaptive policy times
        // how long the stall lasts, and starting that clock up to a second late
        // makes a short stall look like a long one.
        "paused-for-cache" => {
            if let Some(b) = data.and_then(|v| v.as_bool()) {
                let (changed, position) = {
                    let mut st = status.lock().unwrap();
                    let changed = st.buffering != b;
                    st.buffering = b;
                    (changed, st.position)
                };
                if changed && b {
                    crate::debug_log_line(&format!("player: cache stalled at {:.1}s", position));
                    let _ = app.emit("player-stall", json!({ "position": position }));
                }
            }
        }
        "decoder-frame-drop-count" => {
            if let Some(n) = data.and_then(|v| v.as_u64()) {
                status.lock().unwrap().drops_decoder = n;
            }
        }
        "frame-drop-count" => {
            if let Some(n) = data.and_then(|v| v.as_u64()) {
                status.lock().unwrap().drops_vo = n;
            }
        }
        // "no" here after asking for VAAPI means the machine is decoding in
        // software: worth having in the log next to vo-configured, because the
        // two together explain most "it plays badly" reports.
        "hwdec-current" => {
            if let Some(v) = data.and_then(|v| v.as_str()) {
                let mut st = status.lock().unwrap();
                if st.hwdec != v {
                    crate::debug_log_line(&format!("player: hwdec-current={}", v));
                    st.hwdec = v.to_string();
                }
            }
        }
        "vo-configured" => {
            if let Some(v) = data.and_then(|v| v.as_bool()) {
                crate::debug_log_line(&format!("player: vo-configured={}", v));
            }
        }
        "vo-delayed-frame-count" | "mistimed-frame-count" => {
            if crate::surface::debug_enabled() {
                if let Some(n) = data.and_then(|v| v.as_u64()) {
                    eprintln!("fellyjin: player: {name}={n} (at {})", crate::now_ms());
                }
            }
        }
        _ => {}
    }
    pause_changed
}

fn emit_status(app: &AppHandle, status: &Arc<StdMutex<Status>>) {
    let st = status.lock().unwrap().clone();
    let _ = app.emit(
        "player-status",
        json!({
            "active": st.active,
            "position": st.position,
            "duration": st.duration,
            "paused": st.paused,
            "title": st.title,
            "item_id": st.item_id,
            "embedded": st.embedded,
            "volume": st.volume,
            "mute": st.mute,
            "speed": st.speed,
            "sub_delay": st.sub_delay,
            // The scrubber's buffer band and chapter marks read these two; they
            // were tracked here but never sent, so the band sat on the playhead
            // and no chapter ever drew.
            "buffered": st.buffered,
            "chapters": st.chapters,
            "buffering": st.buffering,
            "dropped_frames": st.drops_decoder + st.drops_vo,
            "hwdec": st.hwdec,
        }),
    );
    // The shell's media controls are the same status, told to a different
    // listener. Announced from here rather than polled for, so the D-Bus thread
    // can sleep; the call diffs internally and is a no-op when nothing moved.
    crate::mpris::notify();
}

fn report_body(ctx: &PlayContext, st: &Status, event: Option<&str>) -> Value {
    let mut body = json!({
        "ItemId": ctx.item_id,
        "PositionTicks": (st.position.max(0.0) * TICKS_PER_SECOND) as u64,
        "IsPaused": st.paused,
        "CanSeek": !ctx.live,
        "PlayMethod": ctx.play_method.clone().unwrap_or_else(|| "DirectStream".into()),
    });
    if let Some(ms) = &ctx.media_source_id {
        body["MediaSourceId"] = json!(ms);
    }
    if let Some(ps) = &ctx.play_session_id {
        body["PlaySessionId"] = json!(ps);
    }
    if let Some(ev) = event {
        body["EventName"] = json!(ev);
    }
    body
}

fn server_creds(ctx: &PlayContext) -> Option<(String, String, String)> {
    Some((
        ctx.server_url.clone()?,
        crate::secret::token()?,
        ctx.device_id.clone().unwrap_or_else(|| "fellyjin".into()),
    ))
}

async fn report_start(ctx: &Option<PlayContext>, status: &Arc<StdMutex<Status>>) {
    let Some(ctx) = ctx else { return };
    if ctx.is_local {
        return;
    }
    let Some((server, token, device_id)) = server_creds(ctx) else { return };
    let st = { status.lock().unwrap().clone() };
    let body = report_body(ctx, &st, None);
    let _ = jellyfin::post(&server, &token, &device_id, "/Sessions/Playing", &body).await;
}

async fn report_progress(ctx: &Option<PlayContext>, status: &Arc<StdMutex<Status>>) {
    let Some(ctx) = ctx else { return };
    let st = { status.lock().unwrap().clone() };
    if ctx.is_local {
        let ticks = (st.position.max(0.0) * TICKS_PER_SECOND) as u64;
        let played = st.duration > 0.0 && st.position / st.duration > 0.92;
        progress::store_local(&ctx.item_id, ticks, played);
        return;
    }
    let Some((server, token, device_id)) = server_creds(ctx) else { return };
    let body = report_body(ctx, &st, Some("timeupdate"));
    let _ = jellyfin::post(
        &server,
        &token,
        &device_id,
        "/Sessions/Playing/Progress",
        &body,
    )
    .await;
}

async fn report_stopped(ctx: &Option<PlayContext>, st: &Status) {
    let Some(ctx) = ctx else { return };
    let played = st.duration > 0.0 && st.position / st.duration > 0.92;
    if ctx.is_local {
        let ticks = (st.position.max(0.0) * TICKS_PER_SECOND) as u64;
        progress::store_local(&ctx.item_id, ticks, played);
        // Opportunistic sync — succeeds silently when the server is reachable.
        if let (Some(server), Some(token), Some(user_id)) =
            (&ctx.server_url, crate::secret::token(), &ctx.user_id)
        {
            let device_id = ctx.device_id.clone().unwrap_or_else(|| "fellyjin".into());
            let _ = progress::sync(server, &token, &device_id, user_id).await;
        }
        return;
    }
    let Some((server, token, device_id)) = server_creds(ctx) else { return };
    let mut body = report_body(ctx, st, None);
    body.as_object_mut().map(|o| {
        o.remove("IsPaused");
        o.remove("EventName")
    });
    let _ = jellyfin::post(
        &server,
        &token,
        &device_id,
        "/Sessions/Playing/Stopped",
        &body,
    )
    .await;
}
