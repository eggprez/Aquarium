use crate::embed::{self, Embed, EmbedShared};
use crate::{jellyfin, progress};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex};

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
    #[serde(default)]
    pub token: Option<String>,
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
    #[serde(default)]
    pub ctx: Option<PlayContext>,
}

struct SessionHandle {
    cmd_tx: mpsc::UnboundedSender<Value>,
    stop: Arc<AtomicBool>,
    /// mpv process id, for a hard kill if it ignores "quit".
    pid: Option<u32>,
    /// Signalled by the supervisor once mpv has fully exited.
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
    /// mpv can't inhibit for itself here — it runs on XWayland, invisible
    /// to the Wayland compositor's idle timer (see idle.rs).
    idle: StdMutex<Option<crate::idle::IdleInhibitor>>,
}

/// mpv config dir bundled in the AppImage (uosc UI + our control layout).
fn resolve_mpv_config_dir() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("FELLYJIN_MPV_CONFIG") {
        let p = std::path::PathBuf::from(p);
        if p.is_dir() {
            return Some(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let cand = dir.join("../share/fellyjin/mpv");
            if cand.is_dir() {
                return cand.canonicalize().ok();
            }
        }
    }
    None
}

/// Per-session mpv debug log under the app data dir; keeps the last few so
/// "video didn't show" reports can be diagnosed after the fact.
fn mpv_log_path() -> Option<std::path::PathBuf> {
    let dir = crate::config::data_dir().join("mpv-logs");
    std::fs::create_dir_all(&dir).ok()?;
    // Prune: keep the 5 newest logs.
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let mut logs: Vec<_> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().ends_with(".log"))
            .collect();
        logs.sort_by_key(|e| {
            e.metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH)
        });
        while logs.len() > 5 {
            let old = logs.remove(0);
            let _ = std::fs::remove_file(old.path());
        }
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    Some(dir.join(format!("mpv-{}.log", ts)))
}

pub fn resolve_mpv_binary(configured: Option<&str>) -> String {
    if let Some(p) = configured {
        if !p.trim().is_empty() {
            return p.trim().to_string();
        }
    }
    if let Ok(p) = std::env::var("FELLYJIN_MPV") {
        if !p.is_empty() {
            return p;
        }
    }
    // Bundled alongside our executable inside the AppImage.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let cand = dir.join("fellyjin-mpv");
            if cand.exists() {
                return cand.to_string_lossy().into_owned();
            }
        }
    }
    "mpv".into()
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
        }
    }

    pub fn is_active(&self) -> bool {
        self.status.lock().unwrap().active
    }

    pub fn status(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    pub async fn send(&self, cmd: Value) -> Result<(), String> {
        let guard = self.session.lock().await;
        match guard.as_ref() {
            Some(s) => s
                .cmd_tx
                .send(json!({ "command": cmd }))
                .map_err(|e| e.to_string()),
            None => Err("no active playback".into()),
        }
    }

    pub async fn stop(&self) {
        self.idle.lock().unwrap().take();
        let taken = {
            let mut guard = self.session.lock().await;
            guard.take()
        };
        if let Some(s) = taken {
            s.stop.store(true, Ordering::SeqCst);
            let _ = s.cmd_tx.send(json!({ "command": ["quit"] }));
            // Wait for mpv to actually exit before the caller reuses the
            // video surface or starts a replacement instance. Two mpv
            // processes tearing down / bringing up VAAPI and an X surface
            // concurrently is a recipe for a black video window.
            if s.exited_flag.load(Ordering::SeqCst) {
                return;
            }
            let waited =
                tokio::time::timeout(std::time::Duration::from_secs(3), s.exited.notified()).await;
            if waited.is_err() && !s.exited_flag.load(Ordering::SeqCst) {
                if let Some(pid) = s.pid {
                    crate::debug_log_line(&format!(
                        "player: mpv (pid {}) ignored quit for 3s, killing",
                        pid
                    ));
                    let _ = std::process::Command::new("kill")
                        .args(["-9", &pid.to_string()])
                        .status();
                }
                // Give the supervisor a moment to observe the death.
                let _ =
                    tokio::time::timeout(std::time::Duration::from_secs(1), s.exited.notified())
                        .await;
            }
        }
    }

    /// Best-effort synchronous stop for app shutdown.
    pub fn stop_sync(&self) {
        self.idle.lock().unwrap().take();
        if let Ok(mut guard) = self.session.try_lock() {
            if let Some(s) = guard.take() {
                s.stop.store(true, Ordering::SeqCst);
                let _ = s.cmd_tx.send(json!({ "command": ["quit"] }));
            }
        }
    }

    pub async fn play(
        &self,
        app: AppHandle,
        req: PlayRequest,
        mpv_binary: String,
    ) -> Result<(), String> {
        // stop() blocks until the previous mpv has fully exited, so the new
        // instance never overlaps it on the GPU or the embed surface.
        self.stop().await;
        let my_epoch = self.epoch.fetch_add(1, Ordering::SeqCst) + 1;

        let sock = std::env::temp_dir().join(format!("fellyjin-mpv-{}.sock", uuid::Uuid::new_v4()));
        let title = req.title.clone().unwrap_or_else(|| "FellyJin".to_string());
        let is_live = req.ctx.as_ref().map(|c| c.live).unwrap_or(false);

        // Embed the video inside the app window when we're on X11 (or
        // XWayland). Falls back to mpv's own window otherwise.
        self.viewport_full.store(false, Ordering::SeqCst);
        self.bar_reveal.store(false, Ordering::SeqCst);
        let embed_arc: Option<Arc<Embed>> = app
            .try_state::<EmbedShared>()
            .and_then(|s| s.0.clone());
        let mut wid: Option<u32> = None;
        if let Some(e) = &embed_arc {
            if let Some(win) = app.get_webview_window("main") {
                let size = win.inner_size().unwrap_or(tauri::PhysicalSize {
                    width: 1280,
                    height: 800,
                });
                let scale = win.scale_factor().unwrap_or(1.0);
                let (x, y, w, h) = embed::geometry(size, scale, true);
                match e.create_surface(x, y, w, h) {
                    Ok(id) => wid = Some(id),
                    Err(err) => eprintln!("fellyjin: embed failed, using external window: {err}"),
                }
            }
        }

        let mut cmd = Command::new(&mpv_binary);
        cmd.arg(format!("--input-ipc-server={}", sock.display()))
            .arg("--force-window=yes")
            .arg("--keep-open=no")
            .arg("--terminal=no")
            // Prefer the mature decode paths (VAAPI on AMD/Intel, NVDEC on
            // NVIDIA) over Vulkan video decode, which still produces black
            // frames for some content on Mesa. Falls back to software.
            .arg("--hwdec=vaapi,nvdec")
            .arg("--ytdl=no")
            .arg("--cache=yes")
            .arg("--demuxer-max-bytes=64MiB")
            .arg(format!("--title={}", title))
            .arg(format!("--force-media-title={}", title));
        // Bundled mpv config dir carries the uosc on-screen UI.
        if let Some(d) = resolve_mpv_config_dir() {
            cmd.arg(format!("--config-dir={}", d.display()));
            cmd.arg("--osc=no").arg("--osd-bar=no");
        } else {
            cmd.arg("--osc=yes");
        }
        if let Some(id) = wid {
            cmd.arg(format!("--wid={}", id));
            // mpv prefers its Wayland backend when WAYLAND_DISPLAY is set, and
            // that backend ignores --wid and opens a separate window. Embedding
            // is X11-only, so force mpv onto X11/XWayland.
            cmd.env_remove("WAYLAND_DISPLAY");
            // Force the OpenGL/EGL render path. gpu-next's default Vulkan
            // context (x11vk) intermittently fails to create a swapchain into
            // an embedded X11 child window on AMD/Mesa
            // (VK_ERROR_UNKNOWN → OUT_OF_HOST/DEVICE_MEMORY): when it fails the
            // video output never comes up, so audio plays over a black window,
            // and it's a coin-flip per launch. The EGL context has no such
            // problem. This is the fix for the "sound but no video" bug.
            cmd.arg("--gpu-context=x11egl");
        }
        if let Some(s) = req.start_seconds {
            if s > 1.0 && !is_live {
                cmd.arg(format!("--start=+{:.1}", s));
            }
        }
        if let Some(log) = mpv_log_path() {
            cmd.arg(format!("--log-file={}", log.display()));
        }
        cmd.arg("--").arg(&req.url);
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Could not launch mpv ({}): {}", mpv_binary, e))?;
        crate::debug_log_line(&format!(
            "player: spawned mpv pid={:?} wid={:?} url={}",
            child.id(),
            wid,
            req.url.chars().take(90).collect::<String>()
        ));

        // Wait for the IPC socket to come up.
        let mut stream: Option<UnixStream> = None;
        for _ in 0..80 {
            if let Ok(s) = UnixStream::connect(&sock).await {
                stream = Some(s);
                break;
            }
            if let Ok(Some(status)) = child.try_wait() {
                return Err(format!("mpv exited immediately ({})", status));
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
        let stream = stream.ok_or("Timed out waiting for mpv IPC socket")?;
        let (read_half, mut write_half) = stream.into_split();

        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<Value>();
        let stop = Arc::new(AtomicBool::new(false));

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
        ] {
            let _ = cmd_tx.send(json!({ "command": ["observe_property", id, prop] }));
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
                embedded: wid.is_some(),
            };
        }

        // Keep the screen awake for the whole session (best effort — a
        // desktop without org.freedesktop.ScreenSaver just logs and plays on).
        *self.idle.lock().unwrap() = match crate::idle::IdleInhibitor::new() {
            Ok(i) => Some(i),
            Err(e) => {
                crate::debug_log_line(&format!("player: idle-inhibit failed: {}", e));
                None
            }
        };

        let exited = Arc::new(tokio::sync::Notify::new());
        let exited_flag = Arc::new(AtomicBool::new(false));
        *self.session.lock().await = Some(SessionHandle {
            cmd_tx: cmd_tx.clone(),
            stop: stop.clone(),
            pid: child.id(),
            exited: exited.clone(),
            exited_flag: exited_flag.clone(),
        });

        // Writer task: forwards queued JSON commands to the socket.
        tokio::spawn(async move {
            while let Some(v) = cmd_rx.recv().await {
                let line = v.to_string() + "\n";
                if write_half.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
            }
        });

        // Supervisor task: reads events, keeps status fresh, reports to Jellyfin.
        let status = self.status.clone();
        let lock_duration = req.known_duration_seconds.is_some();
        let ctx = req.ctx.clone();
        let sock_path = sock.clone();
        let embed_arc = embed_arc.clone();
        let epoch = self.epoch.clone();
        tokio::spawn(async move {
            report_start(&ctx, &status).await;
            let mut own_final = { status.lock().unwrap().clone() };

            let mut lines = BufReader::new(read_half).lines();
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut last_report = std::time::Instant::now();
            // mouse-pos fires per pixel; throttle what crosses the IPC bridge.
            let mut last_mouse = std::time::Instant::now() - std::time::Duration::from_secs(1);

            loop {
                let superseded = epoch.load(Ordering::SeqCst) != my_epoch;
                tokio::select! {
                    line = lines.next_line() => {
                        match line {
                            Ok(Some(l)) => {
                                if let Ok(msg) = serde_json::from_str::<Value>(&l) {
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
                                        emit_status(&app, &status);
                                        report_progress(&ctx, &status).await;
                                        last_report = std::time::Instant::now();
                                    }
                                }
                            }
                            _ => break,
                        }
                    }
                    _ = tick.tick() => {
                        if superseded { continue; }
                        emit_status(&app, &status);
                        if last_report.elapsed().as_secs() >= 10 {
                            report_progress(&ctx, &status).await;
                            last_report = std::time::Instant::now();
                        }
                    }
                }
            }

            // mpv exited (user closed window, file ended, we sent quit, or a
            // new session replaced us). Only touch shared state if we are
            // still the current session.
            let exit_status = child.wait().await;
            exited_flag.store(true, Ordering::SeqCst);
            exited.notify_one();
            crate::debug_log_line(&format!(
                "player: mpv exited status={:?} pos={:.1} requested_stop={}",
                exit_status.as_ref().map(|s| s.code()).ok(),
                { status.lock().unwrap().position },
                stop.load(Ordering::SeqCst),
            ));
            let current = epoch.load(Ordering::SeqCst) == my_epoch;
            if let (Some(e), Some(id)) = (&embed_arc, wid) {
                e.destroy_surface_if(id);
            }
            if current {
                // Natural EOF / external exit: stop() never ran, so the
                // idle inhibitor is still held — release it here.
                if let Some(p) = app.try_state::<Player>() {
                    p.idle.lock().unwrap().take();
                }
                {
                    let mut st = status.lock().unwrap();
                    st.active = false;
                }
                let _ = app.emit(
                    "player-status",
                    json!({
                        "active": false,
                        "ended": true,
                        // Distinguishes user-initiated stop from natural EOF,
                        // so the frontend only autoplays after a real EOF.
                        "requested_stop": stop.load(Ordering::SeqCst),
                        "position": own_final.position,
                        "duration": own_final.duration,
                        "item_id": own_final.item_id,
                    }),
                );
            }
            report_stopped(&ctx, &own_final).await;

            let _ = std::fs::remove_file(&sock_path);
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
        "vo-configured" => {
            if let Some(v) = data.and_then(|v| v.as_bool()) {
                crate::debug_log_line(&format!("player: vo-configured={}", v));
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
        }),
    );
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
        ctx.token.clone()?,
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
            (&ctx.server_url, &ctx.token, &ctx.user_id)
        {
            let device_id = ctx.device_id.clone().unwrap_or_else(|| "fellyjin".into());
            let _ = progress::sync(server, token, &device_id, user_id).await;
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
