mod config;
mod downloads;
mod embed;
mod idle;
mod jellyfin;
mod player;
mod progress;

use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use tauri::{AppHandle, Manager, State};

/// Append a line to ~/.local/share/fellyjin/debug.log — used to diagnose
/// "button does nothing" reports where errors are otherwise invisible.
pub(crate) fn debug_log_line(msg: &str) {
    use std::io::Write;
    let _ = std::fs::create_dir_all(config::data_dir());
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(config::data_dir().join("debug.log"))
    {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "[{}] {}", ts, msg);
    }
}

#[tauri::command]
fn ui_log(msg: String) {
    debug_log_line(&format!("ui: {}", msg));
}

#[tauri::command]
fn config_load() -> Value {
    config::load()
}

#[tauri::command]
fn config_save(cfg: Value) -> Result<(), String> {
    config::save(&cfg)
}

#[tauri::command]
fn app_info() -> Value {
    let cfg = config::load();
    let mpv_override = cfg.get("mpv_path").and_then(|v| v.as_str());
    json!({
        "version": jellyfin::CLIENT_VERSION,
        "mpv": player::resolve_mpv_binary(mpv_override),
        "downloads_dir": config::downloads_dir().to_string_lossy(),
    })
}

#[tauri::command]
async fn player_play(
    app: AppHandle,
    player: State<'_, player::Player>,
    req: player::PlayRequest,
) -> Result<(), String> {
    let cfg = config::load();
    let mpv = player::resolve_mpv_binary(cfg.get("mpv_path").and_then(|v| v.as_str()));
    player.play(app, req, mpv).await
}

#[tauri::command]
async fn player_stop(player: State<'_, player::Player>) -> Result<(), String> {
    debug_log_line("cmd stop");
    player.stop().await;
    Ok(())
}

#[tauri::command]
async fn player_pause_toggle(player: State<'_, player::Player>) -> Result<(), String> {
    let r = player.send(json!(["cycle", "pause"])).await;
    debug_log_line(&format!("cmd pause_toggle -> {:?}", r));
    r
}

#[tauri::command]
async fn player_seek(
    player: State<'_, player::Player>,
    seconds: f64,
    absolute: bool,
) -> Result<(), String> {
    let mode = if absolute { "absolute" } else { "relative" };
    let r = player.send(json!(["seek", seconds, mode])).await;
    debug_log_line(&format!("cmd seek {} {} -> {:?}", seconds, mode, r));
    r
}

#[tauri::command]
async fn player_set_track(
    player: State<'_, player::Player>,
    kind: String,
    track: Value,
) -> Result<(), String> {
    let prop = match kind.as_str() {
        "audio" => "aid",
        "sub" => "sid",
        _ => return Err("unknown track kind".into()),
    };
    player.send(json!(["set_property", prop, track])).await
}

#[tauri::command]
fn player_status(player: State<'_, player::Player>) -> player::Status {
    player.status()
}

/// Escape hatch: send a raw command to mpv (used for uosc menu JSON, etc.).
#[tauri::command]
async fn player_mpv_command(
    player: State<'_, player::Player>,
    cmd: Vec<Value>,
) -> Result<(), String> {
    let name = cmd.first().cloned().unwrap_or_default();
    let r = player.send(Value::Array(cmd)).await;
    debug_log_line(&format!("cmd mpv {:?} -> {:?}", name, r));
    r
}

/// Switch the embedded video between bar mode (player bar visible) and full
/// mode (video covers the whole window, for fullscreen). In full mode, `bar`
/// temporarily shrinks the video by the bar height so the auto-hiding
/// fullscreen controls (the real player bar) are visible and clickable.
#[tauri::command]
fn player_set_viewport(
    app: AppHandle,
    player: State<'_, player::Player>,
    full: bool,
    bar: Option<bool>,
) -> Result<(), String> {
    player.viewport_full.store(full, Ordering::SeqCst);
    player
        .bar_reveal
        .store(bar.unwrap_or(false), Ordering::SeqCst);
    resize_video_surface(&app);
    Ok(())
}

fn resize_video_surface(app: &AppHandle) {
    let Some(shared) = app.try_state::<embed::EmbedShared>() else { return };
    let Some(e) = shared.0.clone() else { return };
    if !e.has_surface() {
        return;
    }
    let Some(win) = app.get_webview_window("main") else { return };
    let player = app.state::<player::Player>();
    let full = player.viewport_full.load(Ordering::SeqCst);
    let reveal = player.bar_reveal.load(Ordering::SeqCst);
    let size = win.inner_size().unwrap_or(tauri::PhysicalSize {
        width: 1280,
        height: 800,
    });
    let scale = win.scale_factor().unwrap_or(1.0);
    let (x, y, w, h) = embed::geometry(size, scale, !full || reveal);
    e.resize(x, y, w, h);
}

#[tauri::command]
fn download_start(
    app: AppHandle,
    mgr: State<'_, downloads::DlManager>,
    req: downloads::DownloadRequest,
) -> Result<(), String> {
    mgr.start(app, req)
}

#[tauri::command]
fn download_cancel(mgr: State<'_, downloads::DlManager>, item_id: String) {
    mgr.cancel(&item_id);
}

#[tauri::command]
fn download_retry(
    app: AppHandle,
    mgr: State<'_, downloads::DlManager>,
    item_id: String,
) -> Result<(), String> {
    downloads::restart(app.clone(), &mgr, &item_id)
}

#[tauri::command]
fn download_delete(item_id: String) -> Result<(), String> {
    downloads::delete(&item_id)
}

#[tauri::command]
fn downloads_list(mgr: State<'_, downloads::DlManager>) -> Vec<Value> {
    downloads::list(&mgr)
}

#[tauri::command]
fn download_set_watch_state(item_id: String, position_ticks: u64, played: bool) {
    downloads::set_watch_state(&item_id, position_ticks, played)
}

#[tauri::command]
async fn progress_sync(
    server: String,
    token: String,
    device_id: String,
    user_id: String,
) -> Result<Value, String> {
    Ok(progress::sync(&server, &token, &device_id, &user_id).await)
}

#[tauri::command]
fn progress_pending() -> usize {
    progress::pending_count()
}

#[tauri::command]
fn progress_pending_ids() -> Vec<String> {
    progress::pending_item_ids()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_http::init())
        .manage(player::Player::new())
        .manage(downloads::DlManager::default())
        .setup(|app| {
            // Grab the toplevel X11 window id (main thread) for mpv embedding.
            let shared = app
                .get_webview_window("main")
                .and_then(|w| embed::window_xid(&w).ok())
                .and_then(|xid| embed::Embed::new(xid).ok())
                .map(std::sync::Arc::new);
            if shared.is_none() {
                eprintln!("fellyjin: X11 embedding unavailable; mpv will use its own window");
            }
            app.manage(embed::EmbedShared(shared));

            // Pick up downloads that were mid-transfer when the app last
            // closed (meta.json still says "downloading" but nothing runs).
            downloads::resume_interrupted(app.handle());

            // Dev/test hook: FELLYJIN_TEST_PLAY=<path|url> auto-plays a file
            // shortly after startup so playback can be exercised standalone.
            if let Ok(test_url) = std::env::var("FELLYJIN_TEST_PLAY") {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    let player = handle.state::<player::Player>();
                    let mpv = player::resolve_mpv_binary(None);
                    let req = player::PlayRequest {
                        url: test_url,
                        title: Some("FellyJin test playback".into()),
                        start_seconds: None,
                        known_duration_seconds: None,
                        ctx: None,
                    };
                    if let Err(e) = player.play(handle.clone(), req, mpv.clone()).await {
                        eprintln!("fellyjin: test playback failed: {e}");
                    }
                    // FELLYJIN_TEST_REPLAY restarts playback mid-stream —
                    // exercises the same path as an in-player quality switch.
                    // Value: "1" replays the same URL at +5s, or "<url>|<start>"
                    // to switch to a different stream/position.
                    if let Ok(replay) = std::env::var("FELLYJIN_TEST_REPLAY") {
                        tokio::time::sleep(std::time::Duration::from_secs(6)).await;
                        let (url2, start2) = match replay.rsplit_once('|') {
                            Some((u, s)) => (u.to_string(), s.parse::<f64>().unwrap_or(5.0)),
                            None => (
                                std::env::var("FELLYJIN_TEST_PLAY").unwrap_or_default(),
                                5.0,
                            ),
                        };
                        let req2 = player::PlayRequest {
                            url: url2,
                            title: Some("FellyJin replay test".into()),
                            start_seconds: Some(start2),
                            known_duration_seconds: None,
                            ctx: None,
                        };
                        if let Err(e) = player.play(handle.clone(), req2, mpv).await {
                            eprintln!("fellyjin: replay test failed: {e}");
                        }
                    }
                });
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Resized(_)) {
                resize_video_surface(window.app_handle());
            }
        })
        .invoke_handler(tauri::generate_handler![
            ui_log,
            config_load,
            config_save,
            app_info,
            player_play,
            player_stop,
            player_pause_toggle,
            player_seek,
            player_set_track,
            player_status,
            player_set_viewport,
            player_mpv_command,
            download_start,
            download_cancel,
            download_retry,
            download_delete,
            downloads_list,
            download_set_watch_state,
            progress_sync,
            progress_pending,
            progress_pending_ids,
        ])
        .build(tauri::generate_context!())
        .expect("error while building FellyJin")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                app.state::<player::Player>().stop_sync();
            }
        });
}
