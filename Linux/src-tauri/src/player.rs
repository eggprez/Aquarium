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
    /// Audio timing offset in seconds; positive plays the sound later (for a
    /// Bluetooth headset that runs behind the picture).
    pub audio_delay: f64,
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
    /// HTTP User-Agent for the stream (custom playlist channels only).
    #[serde(default)]
    pub user_agent: Option<String>,
    /// Subtitle files the server sends beside a stream (`StreamSubtitle` in
    /// api.ts), added once it has loaded. See `download_extras::stream_subtitles`.
    #[serde(default)]
    pub subtitles: Vec<Value>,
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
    /// Held for the whole of `play()` and `stop()`. A session is only stored
    /// in `session` at the end of a start that awaits mpv's shutdown and the
    /// surface attach, so two overlapping starts (a double press, or adaptive
    /// quality switching while a play is still coming up) would each find
    /// nothing to stop and the one stored first would be overwritten without
    /// being told to quit: a second live core, still playing audio, with no
    /// handle left to stop it by. A stop landing mid-start would likewise find
    /// nothing and be lost. Queued behind this, each one sees the session the
    /// previous one left.
    transition: Mutex<()>,
    status: Arc<StdMutex<Status>>,
    /// Fullscreen viewport: video covers the player bar too.
    pub viewport_full: AtomicBool,
    /// In fullscreen: the auto-hiding player bar is currently revealed, so
    /// the video is shrunk by the bar height to keep the bar clickable
    /// (HTML can never draw over the X11 video child window).
    pub bar_reveal: AtomicBool,
    /// Extra CSS pixels cut off the bottom of the video, above the bar, for
    /// the card a player pill opens (see `player_set_card_band`). Zero when
    /// no card is open.
    pub card_band: std::sync::atomic::AtomicU32,
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
    /// The `aquarium-battery` mpv profile is on in the current session
    /// (Settings' Automatic battery rendering; see `sync_battery_profile`).
    battery_profile: AtomicBool,
}

/// The machine went on or off battery, or in or out of power saver
/// (`power.rs`): put the running session's picture chain in step.
pub fn power_changed(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Some(p) = app.try_state::<Player>() {
            let guard = p.session.lock().await;
            if let Some(s) = guard.as_ref() {
                p.sync_battery_profile(&s.session);
            }
        }
    });
}

/// Network protocols a stream may use. Matches `LIVE_STREAM_URL` in `iptv.ts`.
const STREAM_SCHEMES: [&str; 8] = ["http", "https", "rtsp", "rtsps", "rtmp", "rtmps", "udp", "rtp"];

/// Refuse an address that isn't a network stream or a downloaded file.
///
/// `loadfile` is the most trusted way into mpv, so it opens `av://lavfi`,
/// `edl://` and any local path without complaint, and on Linux nothing sandboxes
/// what those reach. The address comes from a third-party playlist or a download
/// record, so it is checked here, where the webview can't skip it.
pub fn check_play_target(target: &str) -> Result<(), String> {
    if play_target_allowed(target, &crate::config::downloads_dir()) {
        Ok(())
    } else {
        Err("This isn't an address Aquarium can play.".into())
    }
}

fn play_target_allowed(target: &str, downloads: &std::path::Path) -> bool {
    if target != target.trim() || target.chars().any(char::is_control) {
        return false;
    }
    if target.starts_with('/') {
        // Resolved first, so neither `..` nor a symlink can lead out of the folder.
        let (Ok(file), Ok(root)) = (std::fs::canonicalize(target), std::fs::canonicalize(downloads))
        else {
            return false;
        };
        return file.is_file() && file.starts_with(root);
    }
    reqwest::Url::parse(target).is_ok_and(|u| STREAM_SCHEMES.contains(&u.scheme()))
}

/// The `Authorization` header mpv should send for this stream, if any. Skipped
/// for local files and when there's no stored token.
///
/// The token is only ever sent to the Jellyfin server it belongs to. A custom
/// Live TV playlist streams from whatever hosts the user's provider names, and
/// handing our credential to one of those would leak it to a third party — so
/// the stream URL has to be on the server this install is signed in to.
fn http_auth_header(req: &PlayRequest) -> Option<String> {
    let ctx = req.ctx.as_ref()?;
    if !crate::server::is_session_origin(&req.url) {
        return None;
    }
    let token = crate::secret::token()?;
    let device = ctx.device_id.as_deref().unwrap_or("aquarium");
    Some(jellyfin::auth_header(&token, device))
}

impl Player {
    pub fn new() -> Self {
        Self {
            session: Mutex::new(None),
            transition: Mutex::new(()),
            status: Arc::new(StdMutex::new(Status::default())),
            viewport_full: AtomicBool::new(false),
            bar_reveal: AtomicBool::new(false),
            card_band: std::sync::atomic::AtomicU32::new(0),
            epoch: Arc::new(AtomicU64::new(0)),
            idle: StdMutex::new(None),
            next_available: AtomicBool::new(false),
            battery_profile: AtomicBool::new(false),
        }
    }

    /// Settings' Automatic battery rendering: the cheap scaler chain while the
    /// desktop is asking to save power, mpv's own otherwise. Applied as a
    /// profile with `profile-restore=copy`, so taking it off mid-film puts
    /// back exactly what was there. Idempotent; called at session start and
    /// whenever `power.rs` sees the answer change.
    fn sync_battery_profile(&self, session: &mpv::Session) {
        let want = crate::prefs::Prefs::load().battery_render() == crate::prefs::BatteryRender::Auto
            && crate::power::low_power();
        if want == self.battery_profile.load(Ordering::SeqCst) {
            return;
        }
        let cmd = if want {
            json!(["apply-profile", crate::prefs::BATTERY_PROFILE])
        } else {
            json!(["apply-profile", crate::prefs::BATTERY_PROFILE, "restore"])
        };
        match session.command(cmd) {
            Ok(()) => {
                self.battery_profile.store(want, Ordering::SeqCst);
                crate::debug_log_line(&format!("player: battery rendering {}", if want { "on" } else { "off" }));
            }
            Err(e) => crate::debug_log_line(&format!("player: battery profile: {e}")),
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

    /// Test hook: the status a running session would leave, without one.
    #[cfg(test)]
    pub(crate) fn set_status_for_tests(&self, st: Status) {
        *self.status.lock().unwrap() = st;
    }

    /// Several properties at once, as display strings, for the stream info
    /// panel. Missing ones are left out rather than reported as errors.
    pub async fn properties(&self, names: &[String]) -> Value {
        let guard = self.session.lock().await;
        let mut out = serde_json::Map::new();
        if let Some(s) = guard.as_ref() {
            for n in names {
                if let Some(v) = s.session.get_string(n) {
                    out.insert(n.clone(), Value::String(v));
                }
            }
        }
        Value::Object(out)
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
        let _transition = self.transition.lock().await;
        self.stop_session().await;
    }

    /// `stop()` without taking `transition`, for `play()`, which already
    /// holds it.
    async fn stop_session(&self) {
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
        // One start (or stop) at a time, until the new session is stored or
        // the start has failed; see `transition`.
        let _transition = self.transition.lock().await;
        // This blocks until the previous mpv session has fully shut down,
        // so the new one never overlaps it on the GPU or the video surface.
        self.stop_session().await;
        let my_epoch = self.epoch.fetch_add(1, Ordering::SeqCst) + 1;

        let title = req.title.clone().unwrap_or_else(|| "Aquarium".to_string());
        let is_live = req.ctx.as_ref().map(|c| c.live).unwrap_or(false);

        self.viewport_full.store(false, Ordering::SeqCst);
        self.bar_reveal.store(false, Ordering::SeqCst);
        self.card_band.store(0, Ordering::SeqCst);

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
            // parameter, so the token never lands in Jellyfin's access log for
            // every stream we open. mpv's own log does record it, which is why
            // that log is off by default; see `mpv_log_path`.
            auth_header: http_auth_header(&req),
            user_agent: req.user_agent.clone(),
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
        // A fresh core has mpv's defaults, whatever the last session had on.
        self.battery_profile.store(false, Ordering::SeqCst);
        self.sync_battery_profile(&session);

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
            // time; logged under AQUARIUM_SURFACE_TEST next to the video
            // thread's frame gaps, to tell a late frame from a held one.
            (17, "vo-delayed-frame-count"),
            (18, "mistimed-frame-count"),
            (19, "audio-delay"),
        ] {
            if let Err(e) = session.command(json!(["observe_property", id, prop])) {
                crate::debug_log_line(&format!("player: observe {} failed: {}", prop, e));
            }
        }

        // A downloaded file brings the subtitles saved beside it (see
        // download_extras.rs), added once the file has loaded: `sub-add` is
        // refused before then, and it is the only way to give each track its
        // language and name (`sub-files` leaves both to the file name).
        let local = req.ctx.as_ref().is_some_and(|c| c.is_local);
        // A stream brings the server's own subtitle files the same way, but
        // only from the signed-in server: mpv sends them its Authorization header.
        let mut local_subs = if local {
            crate::download_extras::subtitles_for(&req.url)
        } else {
            crate::download_extras::stream_subtitles(&req.subtitles, crate::server::is_session_origin)
        };
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
                audio_delay: 0.0,
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
            // What the last tick sent, so a paused tick with nothing new can
            // be skipped.
            let mut last_tick: Option<Value> = None;
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
                                if msg.get("event").and_then(|v| v.as_str()) == Some("file-loaded")
                                    && !local_subs.is_empty()
                                {
                                    let embedded_on = session_task
                                        .handle()
                                        .get_property::<String>("sid")
                                        .is_ok_and(|s| s != "no");
                                    let slang = crate::config::load()["sub_lang"].as_str().unwrap_or("").to_string();
                                    for cmd in crate::download_extras::sub_add_commands(
                                        &std::mem::take(&mut local_subs),
                                        &slang,
                                        embedded_on,
                                    ) {
                                        if let Err(e) = session_task.command(cmd) {
                                            crate::debug_log_line(&format!("player: sub-add failed: {e}"));
                                        }
                                    }
                                }
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
                                wake_ui_for(&msg, &session_task, &app);
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
                        // Paused with nothing new to say: a film left paused
                        // over dinner would otherwise wake the page once a
                        // second, every second, to redraw the same bar. Only
                        // while paused — a stall stands just as still, and
                        // the adaptive-quality policy times stalls off these
                        // ticks, so they must keep coming then.
                        let payload = status_payload(&status.lock().unwrap());
                        let unchanged = payload.get("paused") == Some(&Value::Bool(true))
                            && last_tick.as_ref() == Some(&payload);
                        if !unchanged {
                            last_tick = Some(emit_status(&app, &status));
                        }
                        if diag {
                            eprintln!("aquarium: player: status tick at {} ({} ms)", crate::now_ms(), t0.elapsed().as_millis());
                        }
                        if last_report.elapsed().as_secs() >= 10 {
                            let t1 = std::time::Instant::now();
                            report_progress(&ctx, &status).await;
                            if diag {
                                eprintln!("aquarium: player: progress report at {} ({} ms)", crate::now_ms(), t1.elapsed().as_millis());
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
            // A local file's final position was just queued and (if the server
            // answered) synced; the sidebar's "Syncing N items" reads that queue.
            if ctx.as_ref().is_some_and(|c| c.is_local) {
                let _ = app.emit("progress-queue-changed", ());
            }
        });

        Ok(())
    }
}

/// uosc isn't loaded with the core (see `mpv::Session::ensure_ui`); besides
/// its menus, the two things it draws are a buffering spinner and a flash of
/// the pause icon over the picture. Windowed, the player bar says both, so
/// they only earn uosc its keep in fullscreen with the bar tucked away — load
/// it the first time either happens there. The pause that did the loading
/// missed its flash (uosc starts out already paused), so it's replayed.
fn wake_ui_for(msg: &Value, session: &mpv::Session, app: &AppHandle) {
    if msg.get("event").and_then(|v| v.as_str()) != Some("property-change")
        || msg.get("data") != Some(&Value::Bool(true))
    {
        return;
    }
    let name = msg.get("name").and_then(|v| v.as_str()).unwrap_or("");
    if name != "pause" && name != "paused-for-cache" {
        return;
    }
    let bar_hidden = app
        .try_state::<Player>()
        .map(|p| p.viewport_full.load(Ordering::SeqCst) && !p.bar_reveal.load(Ordering::SeqCst))
        .unwrap_or(false);
    if bar_hidden && session.ensure_ui() && name == "pause" {
        let _ = session.command(json!(["script-binding", "uosc/flash-pause-indicator"]));
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
fn apply_event<R: tauri::Runtime>(
    msg: &Value,
    status: &Arc<StdMutex<Status>>,
    app: &AppHandle<R>,
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
        "audio-delay" => {
            if let Some(d) = data.and_then(|v| v.as_f64()) {
                status.lock().unwrap().audio_delay = d;
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
                    eprintln!("aquarium: player: {name}={n} (at {})", crate::now_ms());
                }
            }
        }
        _ => {}
    }
    pause_changed
}

fn emit_status<R: tauri::Runtime>(app: &AppHandle<R>, status: &Arc<StdMutex<Status>>) -> Value {
    let payload = status_payload(&status.lock().unwrap());
    let _ = app.emit("player-status", payload.clone());
    // The shell's media controls are the same status, told to a different
    // listener. Announced from here rather than polled for, so the D-Bus thread
    // can sleep; the call diffs internally and is a no-op when nothing moved.
    crate::mpris::notify();
    payload
}

/// What `player-status` carries.
fn status_payload(st: &Status) -> Value {
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
            "audio_delay": st.audio_delay,
            // The scrubber's buffer band and chapter marks read these two; they
            // were tracked here but never sent, so the band sat on the playhead
            // and no chapter ever drew.
            "buffered": st.buffered,
            "chapters": st.chapters,
            "buffering": st.buffering,
            "dropped_frames": st.drops_decoder + st.drops_vo,
            "hwdec": st.hwdec,
        })
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
        ctx.server_url
            .clone()
            .filter(|s| crate::server::is_session_origin(s))?,
        crate::secret::token()?,
        ctx.device_id.clone().unwrap_or_else(|| "aquarium".into()),
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
        let server = ctx
            .server_url
            .as_ref()
            .filter(|s| crate::server::is_session_origin(s));
        if let (Some(server), Some(token), Some(user_id)) =
            (server, crate::secret::token(), &ctx.user_id)
        {
            let device_id = ctx.device_id.clone().unwrap_or_else(|| "aquarium".into());
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

#[cfg(test)]
mod play_target_tests {
    use super::*;

    #[test]
    fn network_streams_are_allowed() {
        let root = std::env::temp_dir();
        for url in [
            "https://jf.example.com/Videos/1/stream",
            "HTTP://provider.example/live.m3u8",
            "rtsp://cam.example/1",
            "rtmp://provider.example/live",
            "udp://@239.0.0.1:1234",
        ] {
            assert!(play_target_allowed(url, &root), "{url}");
        }
    }

    #[test]
    fn other_mpv_targets_are_refused() {
        let root = std::env::temp_dir();
        for url in [
            "av://lavfi:testsrc",
            "AV://lavfi:testsrc",
            "edl://a.mkv,0,1",
            "file:///etc/passwd",
            "lavf://file:/etc/passwd",
            "memory://x",
            "fd://0",
            "relative.mkv",
            " http://example.com/x",
            "http://example.com/x\n",
            "",
        ] {
            assert!(!play_target_allowed(url, &root), "{url:?}");
        }
    }

    #[test]
    fn local_files_must_be_inside_downloads() {
        let base = std::env::temp_dir().join(format!("aquarium-test-{}", uuid::Uuid::new_v4()));
        let root = base.join("downloads");
        std::fs::create_dir_all(root.join("item")).unwrap();
        let inside = root.join("item/film.mkv");
        let outside = base.join("secret.mkv");
        std::fs::write(&inside, b"x").unwrap();
        std::fs::write(&outside, b"x").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("item/link.mkv")).unwrap();

        let allowed = |p: &std::path::Path| play_target_allowed(&p.to_string_lossy(), &root);
        assert!(allowed(&inside));
        assert!(!allowed(&outside));
        assert!(!allowed(&root.join("item/link.mkv")));
        assert!(!allowed(&root.join("item/../../secret.mkv")));
        assert!(!allowed(&root.join("item")));
        assert!(!allowed(&root.join("item/missing.mkv")));
        std::fs::remove_dir_all(&base).unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{capture_events, sandbox, sign_in, Events, FakeServer, Resp, TEST_TOKEN, TEST_USER};

    fn mock() -> tauri::App<tauri::test::MockRuntime> {
        tauri::test::mock_builder()
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("mock app")
    }

    fn change(name: &str, data: Value) -> Value {
        json!({ "event": "property-change", "name": name, "data": data })
    }

    /// Events reach `listen_any` handlers from Tauri's dispatch; wait for
    /// `n` of them rather than assume they are already there.
    fn wait_for(events: &Events, n: usize) {
        let started = std::time::Instant::now();
        while events.all().len() < n {
            assert!(started.elapsed() < std::time::Duration::from_secs(10), "expected {n} events, got {:?}", events.all());
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    fn ctx(server: &str) -> PlayContext {
        PlayContext {
            item_id: "item1".into(),
            media_source_id: None,
            play_session_id: None,
            play_method: None,
            server_url: Some(server.into()),
            user_id: None,
            device_id: Some("dev-v".into()),
            is_local: false,
            live: false,
        }
    }

    #[test]
    fn a_new_player_has_nothing_playing() {
        let p = Player::new();
        assert!(!p.is_active());
        assert!(!p.next_available());
        assert!(!p.viewport_full.load(Ordering::SeqCst));
        assert!(!p.bar_reveal.load(Ordering::SeqCst));
        let st = p.status();
        assert!(!st.active && st.item_id.is_empty() && st.chapters.is_empty());
    }

    #[test]
    fn next_available_is_what_the_frontend_last_said() {
        let p = Player::new();
        p.set_next_available(true);
        assert!(p.next_available());
        p.set_next_available(false);
        assert!(!p.next_available());
    }

    #[tokio::test]
    async fn with_no_session_commands_fail_and_properties_are_empty() {
        let p = Player::new();
        assert_eq!(p.send(json!(["cycle", "pause"])).await, Err("no active playback".to_string()));
        assert_eq!(p.properties(&["video-codec".to_string()]).await, json!({}));
    }

    /// Whatever followed the old item says nothing about the new one.
    #[tokio::test]
    async fn stopping_forgets_what_came_next() {
        let p = Player::new();
        p.set_next_available(true);
        p.stop().await;
        assert!(!p.next_available());
        p.stop_sync();
    }

    /// play() and stop() queue behind one lock (regression: 6212677 serialize
    /// player starts and stops): overlapping stops each finish.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn overlapping_stops_each_complete() {
        let p = std::sync::Arc::new(Player::new());
        let a = { let p = p.clone(); tokio::spawn(async move { p.stop().await }) };
        let b = { let p = p.clone(); tokio::spawn(async move { p.stop().await }) };
        a.await.unwrap();
        b.await.unwrap();
        assert!(!p.is_active());
    }

    /// The inhibitor is held only while something plays unpaused; a paused
    /// film must let the laptop sleep.
    #[test]
    fn the_idle_inhibitor_follows_play_and_pause() {
        let _s = sandbox();
        let p = Player::new();
        let status = Arc::new(StdMutex::new(Status::default()));
        p.sync_idle_inhibit(&status);
        assert!(p.idle.lock().unwrap().is_none(), "nothing playing");
        status.lock().unwrap().active = true;
        status.lock().unwrap().paused = true;
        p.sync_idle_inhibit(&status);
        assert!(p.idle.lock().unwrap().is_none(), "paused");
        // Playing: the inhibitor is asked for. The test bus is dead, so the
        // request fails, which is logged and survives.
        status.lock().unwrap().paused = false;
        p.sync_idle_inhibit(&status);
        if p.idle.lock().unwrap().is_none() {
            assert!(crate::test_support::debug_log().contains("player: idle-inhibit failed"));
        }
        status.lock().unwrap().active = false;
        p.sync_idle_inhibit(&status);
        assert!(p.idle.lock().unwrap().is_none(), "stopped");
    }

    #[test]
    fn a_superseded_session_keeps_only_its_own_position() {
        let mut st = Status { duration: 100.0, ..Default::default() };
        track_position(&change("time-pos", json!(42.0)), &mut st, false);
        assert_eq!(st.position, 42.0);
        track_position(&change("duration", json!(120.0)), &mut st, false);
        assert_eq!(st.duration, 120.0);
        // The server's runtime wins over mpv's estimate when it is known.
        track_position(&change("duration", json!(150.0)), &mut st, true);
        assert_eq!(st.duration, 120.0);
        track_position(&change("pause", json!(true)), &mut st, false);
        assert!(!st.paused, "only position and duration are tracked");
        track_position(&json!({ "event": "end-file", "name": "time-pos", "data": 1.0 }), &mut st, false);
        assert_eq!(st.position, 42.0);
        track_position(&change("time-pos", json!(null)), &mut st, false);
        assert_eq!(st.position, 42.0);
    }

    #[test]
    fn property_changes_update_the_shared_status() {
        let app = mock();
        let status = Arc::new(StdMutex::new(Status::default()));
        for (name, data) in [
            ("time-pos", json!(10.0)),
            ("duration", json!(600.0)),
            ("volume", json!(70.0)),
            ("mute", json!(true)),
            ("speed", json!(1.5)),
            ("sub-delay", json!(-0.5)),
            ("audio-delay", json!(0.2)),
            ("decoder-frame-drop-count", json!(3)),
            ("frame-drop-count", json!(4)),
            ("hwdec-current", json!("vaapi")),
            ("vo-configured", json!(true)),
            ("vo-delayed-frame-count", json!(1)),
            ("unknown", json!(1)),
        ] {
            assert!(!apply_event(&change(name, data), &status, app.handle(), false), "{name}");
        }
        let st = status.lock().unwrap().clone();
        assert_eq!(st.position, 10.0);
        assert_eq!(st.duration, 600.0);
        assert_eq!(st.volume, 70.0);
        assert!(st.mute);
        assert_eq!(st.speed, 1.5);
        assert_eq!(st.sub_delay, -0.5);
        assert_eq!(st.audio_delay, 0.2);
        assert_eq!((st.drops_decoder, st.drops_vo), (3, 4));
        assert_eq!(st.hwdec, "vaapi");
    }

    /// Transcoded downloads have no duration in the container; the server's
    /// runtime is locked in and mpv's growing estimate is ignored.
    #[test]
    fn a_known_duration_is_not_overwritten() {
        let app = mock();
        let status = Arc::new(StdMutex::new(Status { duration: 2400.0, ..Default::default() }));
        apply_event(&change("duration", json!(37.0)), &status, app.handle(), true);
        assert_eq!(status.lock().unwrap().duration, 2400.0);
    }

    #[test]
    fn only_a_pause_flip_asks_for_a_report() {
        let app = mock();
        let status = Arc::new(StdMutex::new(Status::default()));
        assert!(apply_event(&change("pause", json!(true)), &status, app.handle(), false));
        assert!(!apply_event(&change("pause", json!(true)), &status, app.handle(), false));
        assert!(apply_event(&change("pause", json!(false)), &status, app.handle(), false));
        assert!(!apply_event(&change("pause", json!(null)), &status, app.handle(), false));
        assert!(!apply_event(&json!({ "event": "start-file" }), &status, app.handle(), false));
        assert!(!apply_event(&json!({}), &status, app.handle(), false));
    }

    /// mpv reports the cache end as a duration on some demuxers and as a
    /// timestamp on others; the further reading wins.
    #[test]
    fn the_buffered_mark_is_never_behind_the_playhead() {
        let app = mock();
        let status = Arc::new(StdMutex::new(Status { position: 300.0, ..Default::default() }));
        apply_event(&change("demuxer-cache-time", json!(20.0)), &status, app.handle(), false);
        assert_eq!(status.lock().unwrap().buffered, 300.0);
        apply_event(&change("demuxer-cache-time", json!(330.0)), &status, app.handle(), false);
        assert_eq!(status.lock().unwrap().buffered, 330.0);
    }

    /// A mark at 0:00 is the start of the file, not a division in it.
    #[test]
    fn chapters_skip_the_opening_mark_and_untimed_entries() {
        let app = mock();
        let status = Arc::new(StdMutex::new(Status::default()));
        apply_event(
            &change(
                "chapter-list",
                json!([
                    { "time": 0.0, "title": "Opening" },
                    { "time": 61.5, "title": "Part 2" },
                    { "title": "No time" },
                    { "time": 120.0 },
                ]),
            ),
            &status,
            app.handle(),
            false,
        );
        let ch = status.lock().unwrap().chapters.clone();
        assert_eq!(ch.len(), 2);
        assert_eq!((ch[0].time, ch[0].title.as_str()), (61.5, "Part 2"));
        assert_eq!((ch[1].time, ch[1].title.as_str()), (120.0, ""));
    }

    /// The stall is sent the moment it starts, once, with where it happened:
    /// the adaptive policy times it from this event.
    #[test]
    fn a_cache_stall_is_announced_once_when_it_starts() {
        let app = mock();
        let stalls = capture_events(app.handle(), "player-stall");
        let status = Arc::new(StdMutex::new(Status { position: 12.0, ..Default::default() }));
        apply_event(&change("paused-for-cache", json!(true)), &status, app.handle(), false);
        apply_event(&change("paused-for-cache", json!(true)), &status, app.handle(), false);
        assert!(status.lock().unwrap().buffering);
        apply_event(&change("paused-for-cache", json!(false)), &status, app.handle(), false);
        assert!(!status.lock().unwrap().buffering);
        apply_event(&change("paused-for-cache", json!(true)), &status, app.handle(), false);
        wait_for(&stalls, 2);
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert_eq!(stalls.all(), vec![json!({ "position": 12.0 }), json!({ "position": 12.0 })]);
    }

    #[test]
    fn script_messages_and_track_lists_go_to_the_frontend() {
        let app = mock();
        let messages = capture_events(app.handle(), "player-message");
        let tracks = capture_events(app.handle(), "player-tracks");
        let status = Arc::new(StdMutex::new(Status::default()));
        let msg = json!({ "event": "client-message", "args": ["aquarium-gesture", "tap"] });
        assert!(!apply_event(&msg, &status, app.handle(), false));
        let list = json!([{ "id": 1, "type": "video" }, { "id": 1, "type": "audio", "lang": "en" }]);
        apply_event(&change("track-list", list.clone()), &status, app.handle(), false);
        wait_for(&messages, 1);
        wait_for(&tracks, 1);
        assert_eq!(messages.last(), json!(["aquarium-gesture", "tap"]));
        assert_eq!(tracks.last(), list);
    }

    /// The scrubber's buffer band and chapter marks read these; they were
    /// once tracked but never sent.
    #[test]
    fn the_status_payload_carries_buffer_chapters_and_drop_total() {
        let st = Status {
            active: true,
            buffered: 90.0,
            chapters: vec![Chapter { time: 30.0, title: "B".into() }],
            drops_decoder: 2,
            drops_vo: 5,
            hwdec: "vaapi".into(),
            title: "T".into(),
            ..Default::default()
        };
        let p = status_payload(&st);
        assert_eq!(p["buffered"], json!(90.0));
        assert_eq!(p["chapters"], json!([{ "time": 30.0, "title": "B" }]));
        assert_eq!(p["dropped_frames"], json!(7));
        assert_eq!(p["hwdec"], json!("vaapi"));
        for key in [
            "active", "position", "duration", "paused", "title", "item_id", "embedded", "volume", "mute",
            "speed", "sub_delay", "audio_delay", "buffering",
        ] {
            assert!(p.get(key).is_some(), "{key} missing");
        }
    }

    #[test]
    fn emit_status_sends_and_returns_the_same_payload() {
        let app = mock();
        let events = capture_events(app.handle(), "player-status");
        let status = Arc::new(StdMutex::new(Status { active: true, item_id: "e1".into(), ..Default::default() }));
        let sent = emit_status(app.handle(), &status);
        wait_for(&events, 1);
        assert_eq!(events.last(), sent);
        assert_eq!(sent["item_id"], json!("e1"));
    }

    #[test]
    fn report_bodies_follow_the_context() {
        let mut c = ctx("http://jf");
        let st = Status { position: 1.5, paused: true, ..Default::default() };
        let b = report_body(&c, &st, None);
        assert_eq!(b["PlayMethod"], json!("DirectStream"));
        assert_eq!(b["CanSeek"], json!(true));
        assert_eq!(b["PositionTicks"], json!(15_000_000u64));
        assert!(b.get("MediaSourceId").is_none() && b.get("PlaySessionId").is_none() && b.get("EventName").is_none());
        c.live = true;
        c.play_method = Some("Transcode".into());
        c.media_source_id = Some("ms".into());
        c.play_session_id = Some("ps".into());
        let b = report_body(&c, &Status { position: -4.0, ..Default::default() }, Some("timeupdate"));
        assert_eq!(b["CanSeek"], json!(false), "a live channel cannot seek");
        assert_eq!(b["PlayMethod"], json!("Transcode"));
        assert_eq!(b["MediaSourceId"], json!("ms"));
        assert_eq!(b["PlaySessionId"], json!("ps"));
        assert_eq!(b["EventName"], json!("timeupdate"));
        assert_eq!(b["PositionTicks"], json!(0));
    }

    /// The token only goes to the signed-in server's own origin (regression:
    /// f1e01de the token only goes to the signed-in server's exact origin).
    #[test]
    fn credentials_are_only_for_the_signed_in_origin() {
        let _s = sandbox();
        sign_in("http://127.0.0.1:9");
        assert_eq!(
            server_creds(&ctx("http://127.0.0.1:9")),
            Some(("http://127.0.0.1:9".to_string(), TEST_TOKEN.to_string(), "dev-v".to_string()))
        );
        assert!(server_creds(&ctx("http://127.0.0.1:10")).is_none(), "another port");
        assert!(server_creds(&ctx("https://127.0.0.1:9")).is_none(), "another scheme");
        let mut c = ctx("http://127.0.0.1:9");
        c.device_id = None;
        assert_eq!(server_creds(&c).unwrap().2, "aquarium");
        c.server_url = None;
        assert!(server_creds(&c).is_none());
    }

    /// A custom Live TV playlist streams from the provider's hosts; the
    /// Jellyfin token must never be sent there.
    #[test]
    fn the_stream_header_is_only_for_the_signed_in_server() {
        let _s = sandbox();
        sign_in("http://127.0.0.1:9");
        let req = |url: &str, with_ctx: bool| PlayRequest {
            url: url.into(),
            title: None,
            start_seconds: None,
            known_duration_seconds: None,
            volume: None,
            ctx: with_ctx.then(|| ctx("http://127.0.0.1:9")),
            user_agent: None,
            subtitles: Vec::new(),
        };
        assert_eq!(
            http_auth_header(&req("http://127.0.0.1:9/Videos/1/stream", true)),
            Some(jellyfin::auth_header(TEST_TOKEN, "dev-v"))
        );
        assert_eq!(http_auth_header(&req("http://provider.example/live.m3u8", true)), None);
        assert_eq!(http_auth_header(&req("http://127.0.0.1:9/Videos/1/stream", false)), None);
        crate::secret::clear();
        assert_eq!(http_auth_header(&req("http://127.0.0.1:9/Videos/1/stream", true)), None);
    }

    #[test]
    fn a_downloaded_file_may_play_but_nothing_else_on_disk() {
        let _s = sandbox();
        let dir = crate::config::downloads_dir().join("item9");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("film.mkv");
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(check_play_target(&file.to_string_lossy()), Ok(()));
        assert!(check_play_target(&crate::config::data_dir().join("debug.log").to_string_lossy()).is_err());
        assert!(check_play_target("http://example.com/x.mkv").is_ok());
        assert!(check_play_target("av://lavfi:testsrc").is_err());
    }

    #[test]
    fn requests_deserialize_with_their_defaults() {
        let r: PlayRequest = serde_json::from_value(json!({ "url": "http://x" })).unwrap();
        assert!(r.title.is_none() && r.start_seconds.is_none() && r.known_duration_seconds.is_none());
        assert!(r.volume.is_none() && r.ctx.is_none() && r.user_agent.is_none());
        let c: PlayContext = serde_json::from_value(json!({ "item_id": "i" })).unwrap();
        assert!(!c.is_local && !c.live && c.server_url.is_none() && c.play_method.is_none());
    }

    #[tokio::test]
    async fn start_progress_and_stop_are_reported_to_the_server() {
        let _s = sandbox();
        let server = FakeServer::start(|_| Resp::status(204));
        sign_in(&server.url);
        let c = Some(ctx(&server.url));
        let status = Arc::new(StdMutex::new(Status { position: 5.0, paused: true, ..Default::default() }));
        report_start(&c, &status).await;
        report_progress(&c, &status).await;
        report_stopped(&c, &status.lock().unwrap().clone()).await;
        let start = server.requests_to("/Sessions/Playing");
        let progress = server.requests_to("/Sessions/Playing/Progress");
        let stopped = server.requests_to("/Sessions/Playing/Stopped");
        assert_eq!((start.len(), progress.len(), stopped.len()), (1, 1, 1));
        assert!(start[0].json().get("EventName").is_none());
        assert_eq!(progress[0].json()["EventName"], json!("timeupdate"));
        assert_eq!(progress[0].json()["IsPaused"], json!(true));
        let s = stopped[0].json();
        assert!(s.get("IsPaused").is_none() && s.get("EventName").is_none());
        assert_eq!(s["PositionTicks"], json!(50_000_000u64));
        assert_eq!(
            stopped[0].header("authorization"),
            Some(jellyfin::auth_header(TEST_TOKEN, "dev-v").as_str())
        );
        // No context: nothing to report.
        report_start(&None, &status).await;
        report_progress(&None, &status).await;
        report_stopped(&None, &Status::default()).await;
        assert_eq!(server.requests().len(), 3);
    }

    #[tokio::test]
    async fn reports_for_another_origin_are_not_sent() {
        let _s = sandbox();
        let server = FakeServer::start(|_| Resp::status(204));
        sign_in(&FakeServer::dead_url());
        let c = Some(ctx(&server.url));
        let status = Arc::new(StdMutex::new(Status::default()));
        report_start(&c, &status).await;
        report_progress(&c, &status).await;
        report_stopped(&c, &Status::default()).await;
        assert!(server.requests().is_empty());
    }

    /// A downloaded file's progress goes to the local queue, played past 92%.
    #[tokio::test]
    async fn a_local_file_is_queued_not_reported() {
        let _s = sandbox();
        let server = FakeServer::start(|_| Resp::status(204));
        sign_in(&server.url);
        let mut local = ctx(&server.url);
        local.is_local = true;
        let c = Some(local);
        let status = Arc::new(StdMutex::new(Status { position: 95.0, duration: 100.0, ..Default::default() }));
        report_start(&c, &status).await;
        report_progress(&c, &status).await;
        assert!(server.requests().is_empty(), "a local file reached the server");
        assert_eq!(crate::progress::pending_item_ids(), vec!["item1".to_string()]);
        // Stopped with a user id: the queue is synced opportunistically.
        let mut with_user = c.clone().unwrap();
        with_user.user_id = Some(TEST_USER.into());
        report_stopped(&Some(with_user), &status.lock().unwrap().clone()).await;
        assert!(!server.requests().is_empty(), "no opportunistic sync");
    }
}
