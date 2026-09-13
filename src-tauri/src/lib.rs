mod config;
mod downloads;
mod egl;
mod gl;
mod render;
mod surface;
mod idle;
mod jellyfin;
mod mpris;
mod mpv;
mod player;
mod prefs;
mod progress;
mod secret;
mod server;
mod theme;
mod video_thread;
mod wl;

use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Emitter, Manager, State};

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

/// Wall-clock milliseconds, for lining up diagnostics from different threads
/// (the video thread's frame gaps against the supervisor's activity).
pub(crate) fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

#[tauri::command]
fn ui_log(msg: String) {
    debug_log_line(&format!("ui: {}", msg));
}

#[tauri::command]
fn config_load() -> Value {
    secret::hydrate(config::load())
}

/// Merged rather than written whole: the backend now owns config keys the
/// frontend never sees (the pinned `server_id`, in particular), and a full
/// overwrite from a webview holding a stale copy would silently drop them.
#[tauri::command]
fn config_save(cfg: Value) -> Result<(), String> {
    config::merge(secret::dehydrate(cfg))
}

/// Read a Live TV source — an M3U playlist or an XMLTV guide — as text.
///
/// Goes through the backend rather than `fetch()` in the webview for two
/// reasons: the page has no business making cross-origin requests to whatever
/// host a user's playlist lives on, and a guide is just as often a path on disk
/// as a URL. Gzip is unwrapped here because XMLTV is very commonly published as
/// `.xml.gz`, and asking the user to notice that would be a poor trade.
#[tauri::command]
async fn fetch_source(url: String) -> Result<String, String> {
    // An XMLTV guide for a few hundred channels runs to tens of megabytes;
    // this is a stop against a wrong URL pointing at something enormous, not a
    // limit anyone should meet in normal use.
    const MAX_BYTES: u64 = 192 * 1024 * 1024;

    let url = url.trim();
    if url.is_empty() {
        return Err("No address given".into());
    }

    let raw: Vec<u8> = if url.starts_with("http://") || url.starts_with("https://") {
        let res = jellyfin::http()
            .get(url)
            .send()
            .await
            .map_err(|e| format!("Couldn't reach {}: {}", url, e))?;
        if !res.status().is_success() {
            return Err(format!("{} answered {}", url, res.status()));
        }
        if let Some(len) = res.content_length() {
            if len > MAX_BYTES {
                return Err(format!("That source is {} MB — too large to load", len / 1_048_576));
            }
        }
        res.bytes()
            .await
            .map_err(|e| format!("Couldn't read {}: {}", url, e))?
            .to_vec()
    } else {
        let path = url.strip_prefix("file://").unwrap_or(url);
        let meta = tokio::fs::metadata(path)
            .await
            .map_err(|e| format!("Couldn't open {}: {}", path, e))?;
        if meta.len() > MAX_BYTES {
            return Err(format!("{} is too large to load", path));
        }
        tokio::fs::read(path)
            .await
            .map_err(|e| format!("Couldn't read {}: {}", path, e))?
    };

    // Sniff the gzip magic rather than trusting the extension or the served
    // content type; plenty of hosts get both wrong.
    let text = if raw.starts_with(&[0x1f, 0x8b]) {
        use std::io::Read;
        let mut out = String::new();
        flate2::read::GzDecoder::new(&raw[..])
            .take(MAX_BYTES)
            .read_to_string(&mut out)
            .map_err(|e| format!("Couldn't decompress {}: {}", url, e))?;
        out
    } else {
        String::from_utf8_lossy(&raw).into_owned()
    };

    if text.trim().is_empty() {
        return Err(format!("{} returned nothing", url));
    }
    Ok(text)
}

#[tauri::command]
fn app_info() -> Value {
    let cfg = config::load();
    let server = cfg.get("server").and_then(|v| v.as_str()).unwrap_or("");
    json!({
        "version": jellyfin::CLIENT_VERSION,
        "mpv": mpv::runtime_version().unwrap_or_else(|| "libmpv2".into()),
        "downloads_dir": config::downloads_dir().to_string_lossy(),
        "token_storage": secret::backend_name(),
        "server_secure": !server.is_empty() && server::is_secure(server),
        "server_pinned": cfg.get("server_id").and_then(|v| v.as_str()).is_some(),
        "revocation_pending": server::revocation_pending(),
    })
}

// ---------- Jellyfin, from this side of the IPC boundary ----------
// The webview holds no token and makes no outbound requests of its own; it
// asks for a path and gets a status and a body back.

#[tauri::command]
async fn jf_probe(server: String) -> Result<Value, String> {
    server::probe(&server).await
}

#[tauri::command]
async fn jf_login(server: String, username: String, password: String) -> Result<Value, String> {
    server::login(&server, &username, &password).await
}

#[tauri::command]
async fn jf_logout() -> Result<Value, String> {
    server::logout().await
}

#[tauri::command]
async fn jf_request(
    path: String,
    method: Option<String>,
    body: Option<Value>,
) -> Result<Value, String> {
    server::request(&path, method, body).await
}

#[tauri::command]
async fn jf_image(path: String) -> Result<String, String> {
    server::image(&path).await
}

#[tauri::command]
async fn jf_ping() -> Result<bool, String> {
    server::ping().await
}

#[tauri::command]
async fn jf_bitrate_test(size: u32) -> Result<f64, String> {
    server::bitrate_test(size).await
}

/// Wake a live stream up before mpv is pointed at it.
///
/// A channel from a user's own playlist is very often not a file but a
/// session: the first request makes the server start a transcoder and hold
/// the connection until the playlist exists, which on a cold channel takes
/// well over ten seconds. mpv opens an HLS address twice — once through its
/// stream layer to sniff the format, once more from inside the demuxer — and
/// the second request landing while the server is still bringing the session
/// up has been seen answered with a 500, after which mpv gives up on the
/// spot. So the wait, and the retry, happen here instead, and mpv only ever
/// meets a channel that is already running.
///
/// Returns the address mpv should be given: the final one after redirects
/// when it is a playlist (both of mpv's opens then skip the redirect chain, a
/// second or more each on a distant server), and the original otherwise.
#[tauri::command]
async fn resolve_stream(url: String) -> Result<String, String> {
    const ATTEMPTS: u32 = 4;
    const PER_REQUEST: std::time::Duration = std::time::Duration::from_secs(60);
    const BETWEEN: std::time::Duration = std::time::Duration::from_millis(1500);

    let url = url.trim().to_string();
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Ok(url);
    }
    let host = reqwest::Url::parse(&url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_string))
        .unwrap_or_else(|| url.clone());

    let mut last_err = String::new();
    for attempt in 1..=ATTEMPTS {
        let started = std::time::Instant::now();
        match jellyfin::http().get(&url).timeout(PER_REQUEST).send().await {
            Ok(res) => {
                let status = res.status();
                if status.is_success() {
                    let final_url = res.url().to_string();
                    let content_type = res
                        .headers()
                        .get(reqwest::header::CONTENT_TYPE)
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    let path = final_url.split('?').next().unwrap_or("");
                    let playlist = content_type.contains("mpegurl") || path.ends_with(".m3u8");
                    // The body is deliberately never read: for a raw transport
                    // stream it would not end.
                    drop(res);
                    debug_log_line(&format!(
                        "stream: {} ready after {:.1}s (attempt {}, playlist={}, {} -> {})",
                        host,
                        started.elapsed().as_secs_f64(),
                        attempt,
                        playlist,
                        url.chars().take(90).collect::<String>(),
                        final_url.chars().take(90).collect::<String>()
                    ));
                    return Ok(if playlist { final_url } else { url });
                }
                last_err = format!("{} answered {}", host, status);
                if !status.is_server_error() {
                    // A wrong address or a refused one won't improve by asking again.
                    return Err(last_err);
                }
            }
            Err(e) => {
                if e.is_redirect() || e.is_builder() {
                    return Err(format!("Couldn't open {}: {}", host, e));
                }
                last_err = if e.is_timeout() {
                    format!("{} didn't start the stream within {} seconds", host, PER_REQUEST.as_secs())
                } else {
                    format!("Couldn't reach {}: {}", host, e)
                };
            }
        }
        debug_log_line(&format!(
            "stream: {} attempt {} failed after {:.1}s: {}",
            host,
            attempt,
            started.elapsed().as_secs_f64(),
            last_err
        ));
        if attempt < ATTEMPTS {
            tokio::time::sleep(BETWEEN).await;
        }
    }
    Err(last_err)
}

#[tauri::command]
async fn player_play(
    app: AppHandle,
    player: State<'_, player::Player>,
    req: player::PlayRequest,
) -> Result<(), String> {
    player.play(app, req).await
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

/// The frontend telling us whether anything follows the current item, for
/// MPRIS's "next track" button. Only it can know: the answer depends on the
/// series, the download queue and whether a shuffle is running.
#[tauri::command]
fn player_set_next_available(player: State<'_, player::Player>, available: bool) {
    player.set_next_available(available);
    // Nothing polls this any more, so the shell has to be told the Next button
    // just became (un)available.
    mpris::notify();
}

/// Audio outputs to choose between in Settings.
#[tauri::command]
fn audio_devices() -> Vec<Value> {
    mpv::audio_devices()
        .into_iter()
        .map(|(name, description)| json!({ "name": name, "description": description }))
        .collect()
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
/// temporarily clips the bar height off the bottom of the video window so the
/// auto-hiding fullscreen controls (the real player bar) are visible and
/// clickable — without moving the picture.
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

/// Move the running video into a small always-on-top window of its own, or
/// bring it back. Reparents the existing surface, so mpv keeps decoding the
/// same stream at the same position — nothing restarts and nothing buffers.
///
/// Returns the state that actually took effect, which is what the button in
/// the player bar draws itself from.
#[tauri::command]
fn player_set_pip(app: AppHandle, on: bool) -> Result<bool, String> {
    let e = app
        .try_state::<surface::SurfaceShared>()
        .and_then(|s| s.0.clone())
        .ok_or("Picture-in-picture needs the embedded player")?;
    if on {
        if !e.has_surface() {
            return Err("Nothing is playing in the app window".into());
        }
        e.enter_pip()?;
    } else {
        e.leave_pip();
        resize_video_surface(&app);
    }
    let state = e.is_pip();
    let _ = app.emit("player-pip", json!({ "on": state }));
    Ok(state)
}

fn resize_video_surface(app: &AppHandle) {
    let Some(shared) = app.try_state::<surface::SurfaceShared>() else { return };
    let Some(e) = shared.0.clone() else { return };
    if !e.has_surface() {
        return;
    }
    // In picture-in-picture the surface belongs to the floating window and is
    // sized by whatever the user drags it to; the app window's geometry has
    // nothing to say about it.
    if e.is_pip() {
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
    if full {
        // Fullscreen: the surface always covers the window, and the revealed
        // bar is cut out of it, so the picture never moves when the controls
        // come and go. Windowed mode still reserves the strip by resizing —
        // there the bar is permanent, and letterboxing above it is right.
        let (x, y, w, h) = surface::geometry(size, scale, false);
        e.resize(x, y, w, h);
        let bar = if reveal {
            (surface::BAR_HEIGHT_CSS * scale).ceil() as u32
        } else {
            0
        };
        e.set_bottom_clip(w, h, bar);
    } else {
        let (x, y, w, h) = surface::geometry(size, scale, !full || reveal);
        e.set_bottom_clip(w, h, 0);
        e.resize(x, y, w, h);
    }
}

/// The `minWidth`/`minHeight` from tauri.conf.json, in CSS pixels.
const MIN_WIDTH_CSS: f64 = 900.0;
const MIN_HEIGHT_CSS: f64 = 600.0;

/// Remembering the window size is ours, not `tauri-plugin-window-state`'s.
///
/// The plugin saves the window's *inner* size and restores it with
/// `set_size()`, which on GTK sizes the *toplevel* — client-side decorations
/// and drop shadow included. Restoring therefore hands the window its old
/// inner size plus one set of decorations, and the plugin's own resize tracker
/// records that inflated figure from the `Resized` that follows, before
/// `maximize()` lands and stops it recording. Nothing ever subtracts the
/// decorations again, so every clean quit added a fixed 104x198 physical
/// pixels to the stored size, without bound.
///
/// That is not a cosmetic drift. The saved height crosses the 16384px GL
/// texture limit after enough restarts, and the window's backing surface then
/// fails to allocate: the process segfaults during window creation, before
/// `setup()` runs. The app opens no window at all, and — because the only
/// route out of the downloads-in-flight close guard is a button in a window
/// that never appears — the instance that is left behind cannot be quit
/// either. Both halves of that failure trace back to this one number.
///
/// So the plugin keeps position, maximized and fullscreen, and size lives
/// here, where it is clamped to the monitor on the way in. A wrong value
/// cannot persist, and cannot grow.
fn window_size_path() -> std::path::PathBuf {
    config::config_dir().join("window.json")
}

/// Save the windowed size, in GTK's own units.
///
/// Tauri's `inner_size` (the content area, in physical pixels) and its
/// `set_size` (which GTK applies to the *toplevel*, decorations included) are
/// not the same measurement, so a size written through one and read back
/// through the other comes back larger every time. `gtk_window.size()` and
/// `gtk_window.resize()` are two ends of the same measurement and round-trip
/// exactly, which is the whole reason this is done down at the GTK layer
/// rather than through the Tauri window API.
///
/// Skipped while maximized, minimized or fullscreen — those are states, not
/// sizes, and the plugin already records the first.
fn save_window_size(win: &tauri::Window) {
    if win.is_maximized().unwrap_or(false)
        || win.is_minimized().unwrap_or(false)
        || win.is_fullscreen().unwrap_or(false)
    {
        return;
    }
    let Ok(gtk_win) = win.gtk_window() else { return };
    let (w, h) = gtk::prelude::GtkWindowExt::size(&gtk_win);
    if w <= 0 || h <= 0 {
        return;
    }
    let _ = std::fs::create_dir_all(config::config_dir());
    let _ = std::fs::write(
        window_size_path(),
        json!({ "width": w, "height": h }).to_string(),
    );
}

/// Restore the windowed size, clamped to what the monitor can actually show.
/// A window the plugin is about to maximize has no windowed size to apply yet;
/// GTK keeps the figure as the size to return to when it is unmaximized.
fn restore_window_size(win: &tauri::WebviewWindow) {
    let Ok(text) = std::fs::read_to_string(window_size_path()) else { return };
    let Ok(v) = serde_json::from_str::<Value>(&text) else { return };
    let (Some(w), Some(h)) = (
        v.get("width").and_then(|x| x.as_i64()),
        v.get("height").and_then(|x| x.as_i64()),
    ) else {
        return;
    };

    // GTK works in logical pixels; the monitor ceiling and the configured
    // floor have to be expressed the same way before they can be applied.
    let scale = win.scale_factor().unwrap_or(1.0).max(0.1);
    let (max_w, max_h) = match win.current_monitor() {
        Ok(Some(m)) => (
            (m.size().width as f64 / scale).round() as i32,
            (m.size().height as f64 / scale).round() as i32,
        ),
        _ => (i32::MAX, i32::MAX),
    };
    let w = (w as i32).clamp((MIN_WIDTH_CSS as i32).min(max_w), max_w);
    let h = (h as i32).clamp((MIN_HEIGHT_CSS as i32).min(max_h), max_h);

    if let Ok(gtk_win) = win.gtk_window() {
        gtk::prelude::GtkWindowExt::resize(&gtk_win, w, h);
    }
}

/// Set once the user has answered the "downloads are still running" prompt, so
/// the second close attempt goes straight through instead of asking again.
static QUIT_CONFIRMED: AtomicBool = AtomicBool::new(false);

/// The frontend's answer to the quit prompt. `true` closes the window (and
/// abandons the transfers); `false` just re-arms the guard.
#[tauri::command]
fn quit_confirm(app: AppHandle, quit: bool) {
    if !quit {
        return;
    }
    QUIT_CONFIRMED.store(true, Ordering::SeqCst);
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.close();
    }
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

/// Free bytes on the downloads volume, or null if the platform won't say — in
/// which case the frontend queues the download rather than guessing.
#[tauri::command]
fn disk_free() -> Option<u64> {
    downloads::free_space()
}

#[tauri::command]
fn download_set_watch_state(item_id: String, position_ticks: u64, played: bool) {
    downloads::set_watch_state(&item_id, position_ticks, played)
}

/// Push offline progress. Takes no credentials: server and user come from the
/// config, the token from the keyring.
#[tauri::command]
async fn progress_sync() -> Result<Value, String> {
    let cfg = config::load();
    let server = cfg
        .get("server")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or("not connected to a server")?
        .to_string();
    let user_id = cfg
        .get("user_id")
        .and_then(|v| v.as_str())
        .ok_or("not signed in")?
        .to_string();
    let token = secret::token().ok_or("not signed in")?;
    server::ensure_verified(&server).await?;
    Ok(progress::sync(&server, &token, &config::device_id(), &user_id).await)
}

/// Mark a downloaded item watched/unwatched from the Downloads UI: writes
/// meta.json *and* queues the change for the next server sync.
#[tauri::command]
fn progress_store_local(item_id: String, position_ticks: u64, played: bool) {
    progress::store_local(&item_id, position_ticks, played)
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
        // No HTTP plugin: the webview no longer talks to the network at all,
        // so there is nothing there to point at an attacker's host.
        // Reopen where the window was last closed. Size is deliberately not
        // part of this — see `save_window_size`.
        .plugin(
            tauri_plugin_window_state::Builder::default()
                // Everything but the size, which `save_window_size` owns —
                // see its comment for why the plugin cannot be trusted with it
                // — and fullscreen, which here means "video is playing
                // fullscreen", not a window preference. Restoring it after a
                // quit mid-playback opened the next session fullscreen with
                // no video, and no way out: `f`/Esc only act when the
                // frontend thinks a video is fullscreen, and there is no
                // title bar to fall back on.
                .with_state_flags(
                    tauri_plugin_window_state::StateFlags::all()
                        .difference(tauri_plugin_window_state::StateFlags::SIZE)
                        .difference(tauri_plugin_window_state::StateFlags::FULLSCREEN),
                )
                .build(),
        )
        .manage(player::Player::new())
        .manage(downloads::DlManager::default())
        .setup(|app| {
            // Reopen at the size the window was last closed at. Position,
            // maximized and fullscreen come back from the plugin; the size is
            // ours (see `save_window_size`), and has to be applied before the
            // surface is built so it measures the window it will live in.
            if let Some(w) = app.get_webview_window("main") {
                // A state file written by an older build may still carry
                // `fullscreen: true`; the plugin no longer applies it, but
                // never start fullscreen without a video regardless.
                if w.is_fullscreen().unwrap_or(false) {
                    let _ = w.set_fullscreen(false);
                }
                restore_window_size(&w);
            }

            // Build the video surface (main thread): a GtkGLArea overlaid on
            // the webview, which libmpv renders into. See surface.rs.
            let shared = match app.get_webview_window("main") {
                Some(w) => match surface::Surface::new(&w) {
                    Ok(s) => Some(s),
                    Err(e) => {
                        eprintln!("fellyjin: video surface unavailable: {e}");
                        None
                    }
                },
                None => None,
            };
            // The floating picture-in-picture window is the window manager's
            // to resize and close; watch for both. Closing it from the title
            // bar has to put the picture back in the app window *and* tell the
            // frontend, or the bar's button would still read "in PiP".
            if let Some(e) = &shared {
                let handle = app.handle().clone();
                e.watch_pip(move || {
                    resize_video_surface(&handle);
                    let _ = handle.emit("player-pip", json!({ "on": false }));
                });
            }
            app.manage(surface::SurfaceShared(shared));

            // Keep the "Auto" theme setting in step with the desktop.
            theme::watch(app.handle().clone());

            // The desktop's own word on whether there is a network at all.
            // The frontend backs its offline probes off to minutes; a link
            // that comes back (Wi-Fi after a wake) is the moment to ask again,
            // and GNetworkMonitor is how the desktop says so.
            {
                use gtk::gio::prelude::*;
                let handle = app.handle().clone();
                let monitor = gtk::gio::NetworkMonitor::default();
                monitor.connect_network_changed(move |_, available| {
                    let _ = handle.emit("network-changed", json!({ "available": available }));
                });
            }

            // Media keys, the lock screen, and the shell's audio menu.
            mpris::start(app.handle().clone());

            // Pick up downloads that were mid-transfer when the app last
            // closed (meta.json still says "downloading" but nothing runs).
            downloads::resume_interrupted(app.handle());

            // A previous sign-out may have failed to reach the server, leaving
            // a token that is still live over there. Keep trying.
            tauri::async_runtime::spawn(server::retry_pending_revocation());

            // Dev/test hook: FELLYJIN_TEST_PLAY=<path|url> auto-plays a file
            // shortly after startup so playback can be exercised standalone.
            if let Ok(test_url) = std::env::var("FELLYJIN_TEST_PLAY") {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    let player = handle.state::<player::Player>();
                    let req = player::PlayRequest {
                        url: test_url,
                        title: Some("FellyJin test playback".into()),
                        start_seconds: None,
                        known_duration_seconds: None,
                        volume: None,
                        ctx: None,
                    };
                    if let Err(e) = player.play(handle.clone(), req).await {
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
                            volume: None,
                            ctx: None,
                        };
                        if let Err(e) = player.play(handle.clone(), req2).await {
                            eprintln!("fellyjin: replay test failed: {e}");
                        }
                    }
                });
            }

            // Dev/test hook: FELLYJIN_TEST_SEQUENCE="6:fs,9:bar,12:nobar,15:nofs,18:pip,24:nopip"
            // drives the window states the video surface has to follow, at
            // the given seconds after startup, the way the frontend would:
            // fullscreen on/off (`fs`/`nofs`), the fullscreen bar revealed or
            // hidden (`bar`/`nobar`), picture-in-picture on/off
            // (`pip`/`nopip`), and `stop`/`play` to end the session and start
            // another on the FELLYJIN_TEST_PLAY file — the way the next thing
            // opened from the page starts, i.e. windowed, whatever the last
            // session was. Native Wayland has no input injection, so this is
            // how those paths get exercised without a hand on the mouse.
            if let Ok(seq) = std::env::var("FELLYJIN_TEST_SEQUENCE") {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    let mut last = 0u64;
                    for step in seq.split(',') {
                        let Some((t, what)) = step.split_once(':') else { continue };
                        let t: u64 = t.trim().parse().unwrap_or(0);
                        tokio::time::sleep(std::time::Duration::from_secs(t.saturating_sub(last))).await;
                        last = t;
                        let what = what.trim();
                        eprintln!("fellyjin: test sequence: {what}");
                        let player = handle.state::<player::Player>();
                        let win = handle.get_webview_window("main");
                        match what {
                            "fs" | "nofs" => {
                                let on = what == "fs";
                                if let Some(w) = &win {
                                    let _ = w.set_fullscreen(on);
                                }
                                player.viewport_full.store(on, Ordering::SeqCst);
                                player.bar_reveal.store(false, Ordering::SeqCst);
                                resize_video_surface(&handle);
                            }
                            "bar" | "nobar" => {
                                player.bar_reveal.store(what == "bar", Ordering::SeqCst);
                                resize_video_surface(&handle);
                            }
                            "pip" | "nopip" => {
                                if let Err(e) = player_set_pip(handle.clone(), what == "pip") {
                                    eprintln!("fellyjin: test sequence: pip failed: {e}");
                                }
                            }
                            "stop" => player.stop().await,
                            "play" => {
                                let req = player::PlayRequest {
                                    url: std::env::var("FELLYJIN_TEST_PLAY").unwrap_or_default(),
                                    title: Some("FellyJin test playback".into()),
                                    start_seconds: None,
                                    known_duration_seconds: None,
                                    volume: None,
                                    ctx: None,
                                };
                                if let Err(e) = player.play(handle.clone(), req).await {
                                    eprintln!("fellyjin: test sequence: play failed: {e}");
                                }
                            }
                            _ => eprintln!("fellyjin: test sequence: unknown step {what:?}"),
                        }
                    }
                });
            }
            // Dev/test hook: FELLYJIN_TEST_EVAL=<js> runs a script in the main
            // webview 4 s after startup. Used to put a known load on the
            // page (e.g. a full-window CSS animation) when measuring how the
            // WebKit frame path in `main.rs` behaves next to the video
            // surface; nothing in the app itself uses it.
            if let Ok(js) = std::env::var("FELLYJIN_TEST_EVAL") {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(4)).await;
                    if let Some(w) = handle.get_webview_window("main") {
                        if let Err(e) = w.eval(&js) {
                            eprintln!("fellyjin: test eval failed: {e}");
                        }
                    }
                });
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            match event {
                tauri::WindowEvent::Resized(_) => resize_video_surface(window.app_handle()),
                // Closing the window kills every transfer in flight, leaving
                // half-written .part files behind with no warning. Hold the
                // close and let the user decide.
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    if QUIT_CONFIRMED.load(Ordering::SeqCst) {
                        save_window_size(window);
                        return;
                    }
                    let app = window.app_handle();
                    let active = app
                        .try_state::<downloads::DlManager>()
                        .map(|m| m.active_count())
                        .unwrap_or(0);
                    if active == 0 {
                        save_window_size(window);
                        return;
                    }
                    api.prevent_close();
                    let _ = app.emit("quit-requested", json!({ "downloads": active }));
                }
                _ => {}
            }
        })
        .invoke_handler(tauri::generate_handler![
            ui_log,
            config_load,
            config_save,
            fetch_source,
            resolve_stream,
            app_info,
            jf_probe,
            jf_login,
            jf_logout,
            jf_request,
            jf_image,
            jf_ping,
            jf_bitrate_test,
            theme::system_color_scheme,
            player_play,
            player_stop,
            player_pause_toggle,
            player_seek,
            player_set_track,
            player_status,
            player_set_next_available,
            audio_devices,
            player_set_viewport,
            player_set_pip,
            player_mpv_command,
            quit_confirm,
            download_start,
            download_cancel,
            download_retry,
            download_delete,
            downloads_list,
            disk_free,
            download_set_watch_state,
            progress_sync,
            progress_store_local,
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
