mod audio;
mod config;
mod desktop;
mod discovery;
mod download_extras;
mod downloads;
mod egl;
mod gl;
mod render;
mod surface;
mod idle;
mod jellyfin;
mod mpris;
mod mpv;
mod network;
mod player;
mod power;
mod prefs;
mod progress;
mod secret;
mod seerr;
mod server;
mod theme;
#[cfg(test)]
mod test_support;
mod video_thread;
mod wl;

use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Emitter, Manager, State};

/// Append a line to ~/.local/share/aquarium/debug.log — used to diagnose
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

/// `async` here and on the other commands that block (keyring and portal
/// D-Bus calls, fsync, a throwaway mpv core): a plain command runs on the GTK
/// main thread, and anything slow there freezes the window, video included.
#[tauri::command(async)]
fn config_load() -> Value {
    secret::hydrate(config::load())
}

/// Merged rather than written whole: the backend now owns config keys the
/// frontend never sees (the pinned `server_id`, in particular), and a full
/// overwrite from a webview holding a stale copy would silently drop them.
#[tauri::command(async)]
fn config_save(cfg: Value) -> Result<(), String> {
    config::merge(secret::dehydrate(cfg))
}

/// The Live TV settings' User-Agent on a request to a playlist's host, in
/// place of the client's own. Jellyfin requests never come through here.
fn with_user_agent(req: reqwest::RequestBuilder, ua: Option<&str>) -> reqwest::RequestBuilder {
    match ua.map(str::trim).filter(|s| !s.is_empty()) {
        Some(ua) => req.header(reqwest::header::USER_AGENT, ua),
        None => req,
    }
}

/// Read a Live TV source — an M3U playlist or an XMLTV guide — as text.
///
/// Goes through the backend rather than `fetch()` in the webview for two
/// reasons: the page has no business making cross-origin requests to whatever
/// host a user's playlist lives on, and a guide is just as often a path on disk
/// as a URL. Gzip is unwrapped here because XMLTV is very commonly published as
/// `.xml.gz`, and asking the user to notice that would be a poor trade.
#[tauri::command]
async fn fetch_source(url: String, user_agent: Option<String>) -> Result<String, String> {
    // An XMLTV guide for a few hundred channels runs to tens of megabytes;
    // this is a stop against a wrong URL pointing at something enormous, not a
    // limit anyone should meet in normal use.
    const MAX_BYTES: u64 = 192 * 1024 * 1024;

    let url = url.trim();
    if url.is_empty() {
        return Err("No address given".into());
    }

    let raw: Vec<u8> = if url.starts_with("http://") || url.starts_with("https://") {
        let mut res = with_user_agent(jellyfin::http().get(url), user_agent.as_deref())
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
        // Counted as it arrives, too: a chunked response has no length to
        // check up front, and would otherwise be read whole however big.
        let mut body: Vec<u8> = Vec::new();
        while let Some(chunk) = res
            .chunk()
            .await
            .map_err(|e| format!("Couldn't read {}: {}", url, e))?
        {
            if (body.len() + chunk.len()) as u64 > MAX_BYTES {
                return Err(format!("That source is over {} MB — too large to load", MAX_BYTES / 1_048_576));
            }
            body.extend_from_slice(&chunk);
        }
        body
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

#[tauri::command(async)]
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
    // The library's titles stop being searchable from the desktop with it.
    desktop::clear_index();
    server::logout().await
}

/// The action the app was launched with (`--action=…`), once.
#[tauri::command]
fn take_launch_action() -> Option<String> {
    desktop::take_pending()
}

/// Write the titles GNOME Shell's search answers from (see `desktop.rs`).
#[tauri::command]
fn search_index_write(items: Vec<Value>) -> Result<usize, String> {
    desktop::write_index(&items)
}

#[tauri::command]
async fn jf_login_quick_connect(server: String, secret: String) -> Result<Value, String> {
    server::login_quick_connect(&server, &secret).await
}

/// The unauthenticated calls the sign-in screen makes: `/Users/Public` and the
/// Quick Connect exchange, nothing else (see `server::public_request`).
#[tauri::command]
async fn jf_public(server: String, path: String, method: Option<String>) -> Result<Value, String> {
    server::public_request(&server, &path, method).await
}

/// Jellyfin servers on the local network, by UDP broadcast.
#[tauri::command]
async fn jf_discover() -> Vec<Value> {
    tokio::task::spawn_blocking(|| discovery::find(std::time::Duration::from_millis(1600)))
        .await
        .unwrap_or_default()
}

/// mpv properties as display strings, for the stream info panel.
#[tauri::command]
async fn player_get_properties(
    player: State<'_, player::Player>,
    names: Vec<String>,
) -> Result<Value, String> {
    Ok(player.properties(&names).await)
}

/// Start the next title's stream on the server before this one ends.
#[tauri::command]
async fn player_warm(url: String) -> Result<(), String> {
    server::warm(&url).await
}

#[tauri::command(async)]
fn accounts_list() -> Value {
    server::accounts()
}

#[tauri::command(async)]
fn account_switch(key: String) -> Result<Value, String> {
    server::switch_account(&key)
}

#[tauri::command]
async fn account_forget(key: String) -> Result<Value, String> {
    server::forget_account(&key).await
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

// ---------- Seerr, from this side of the IPC boundary ----------
// The same arrangement as Jellyfin's: the webview names a path and gets a
// status and a body back. Seerr's session cookie stays in this process (see
// `seerr.rs`); none of these commands returns it.

/// Whether this account has a Seerr server, and what may be shown of it.
#[tauri::command(async)]
fn seerr_status() -> Value {
    seerr::status()
}

#[tauri::command]
async fn seerr_probe(address: String) -> Result<Value, String> {
    seerr::probe(&address).await
}

/// Sign in to Seerr with Quick Connect, as the Jellyfin account in use.
#[tauri::command]
async fn seerr_connect(server: String) -> Result<Value, String> {
    seerr::connect(&server).await
}

/// The fallback for a Seerr with no Quick Connect. The password goes to Seerr
/// once and is kept nowhere.
#[tauri::command]
async fn seerr_connect_password(server: String, username: String, password: String) -> Result<Value, String> {
    seerr::connect_with_password(&server, &username, &password).await
}

#[tauri::command]
async fn seerr_reconnect() -> Result<Value, String> {
    seerr::reconnect().await
}

#[tauri::command]
async fn seerr_disconnect() -> Result<Value, String> {
    Ok(seerr::disconnect().await)
}

/// Bring the remembered permissions and server settings up to date.
#[tauri::command]
async fn seerr_refresh() -> Result<Value, String> {
    Ok(seerr::refresh().await)
}

#[tauri::command]
async fn seerr_request(
    path: String,
    method: Option<String>,
    body: Option<Value>,
) -> Result<Value, String> {
    seerr::request(&path, method, body).await
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
async fn resolve_stream(url: String, user_agent: Option<String>) -> Result<String, String> {
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
        match with_user_agent(jellyfin::http().get(&url), user_agent.as_deref())
            .timeout(PER_REQUEST)
            .send()
            .await
        {
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
    // Here rather than in `Player::play`, so the AQUARIUM_TEST_PLAY hooks can
    // still open a file from anywhere, and so a refused address doesn't stop
    // what is already playing.
    player::check_play_target(&req.url)?;
    // Music and video never play over each other; see audio.rs.
    app.state::<audio::AudioPlayer>().stop(&app).await;
    player.play(app, req).await
}

// ---- Music and audiobooks (audio.rs) ----

#[tauri::command]
async fn audio_play(app: AppHandle, audio: State<'_, audio::AudioPlayer>, req: audio::PlayRequest) -> Result<(), String> {
    audio.play(app, req).await
}

#[tauri::command]
async fn audio_set_next(audio: State<'_, audio::AudioPlayer>, next: Option<audio::AudioTrack>) -> Result<(), String> {
    audio.set_next(next).await
}

#[tauri::command]
async fn audio_command(audio: State<'_, audio::AudioPlayer>, cmd: Vec<Value>) -> Result<(), String> {
    audio.send(Value::Array(cmd)).await
}

#[tauri::command]
async fn audio_stop(app: AppHandle, audio: State<'_, audio::AudioPlayer>) -> Result<(), String> {
    audio.stop(&app).await;
    Ok(())
}

#[tauri::command]
fn audio_status(audio: State<'_, audio::AudioPlayer>) -> audio::AudioStatus {
    audio.status()
}

/// The frontend's queue, for MPRIS's track list and Next/Previous.
#[tauri::command]
fn audio_set_queue(
    audio: State<'_, audio::AudioPlayer>,
    entries: Vec<audio::AudioTrack>,
    index: usize,
    can_next: bool,
    can_prev: bool,
) {
    audio.set_queue(entries, index, can_next, can_prev);
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
    let prop = track_property(&kind)?;
    player.send(json!(["set_property", prop, track])).await
}

/// The mpv property behind a track kind from the frontend.
fn track_property(kind: &str) -> Result<&'static str, String> {
    match kind {
        "audio" => Ok("aid"),
        "sub" => Ok("sid"),
        _ => Err("unknown track kind".into()),
    }
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
#[tauri::command(async)]
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

/// Cut `px` more CSS pixels off the bottom of the video, above the player
/// bar, without moving the picture: the band a player card is drawn in. The
/// page can draw nowhere the video covers, so a card that rises above the bar
/// needs the video taken off that strip first. Zero puts the picture back.
#[tauri::command]
fn player_set_card_band(app: AppHandle, player: State<'_, player::Player>, px: u32) -> Result<(), String> {
    player.card_band.store(px.min(2000), Ordering::SeqCst);
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
    let band = player.card_band.load(Ordering::SeqCst) as f64;
    let size = win.inner_size().unwrap_or(tauri::PhysicalSize {
        width: 1280,
        height: 800,
    });
    let scale = win.scale_factor().unwrap_or(1.0);
    let ((x, y, w, h), bar) = video_layout(size, scale, full, reveal);
    if full {
        e.resize(x, y, w, h);
        // A card is only ever open with the bar up, so its band sits on
        // top of the bar's strip.
        let bar = if reveal { bar + (band * scale).ceil() as u32 } else { 0 };
        e.set_bottom_clip(w, h, bar);
    } else {
        // The bar's own strip is reserved by the size; the card's band is
        // clipped, never more than leaves a sliver of picture.
        let clip = ((band * scale).ceil() as u32).min((h as u32).saturating_sub(1));
        e.set_bottom_clip(w, h, clip);
        e.resize(x, y, w, h);
    }
}

/// The video geometry for a window `size` at `scale`, and the physical px of
/// fullscreen bar to clip off its bottom.
///
/// Fullscreen: the surface always covers the window, and the revealed bar is
/// cut out of it, so the picture never moves when the controls come and go.
/// Windowed mode still reserves the strip by resizing — there the bar is
/// permanent, and letterboxing above it is right.
fn video_layout(
    size: tauri::PhysicalSize<u32>,
    scale: f64,
    full: bool,
    reveal: bool,
) -> ((i16, i16, u16, u16), u32) {
    if full {
        let geom = surface::geometry(size, scale, false);
        let bar = if reveal {
            (surface::BAR_HEIGHT_CSS * scale).ceil() as u32
        } else {
            0
        };
        (geom, bar)
    } else {
        (surface::geometry(size, scale, !full || reveal), 0)
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

    let monitor = match win.current_monitor() {
        Ok(Some(m)) => Some((m.size().width, m.size().height)),
        _ => None,
    };
    let (w, h) = clamp_window_size(w, h, win.scale_factor().unwrap_or(1.0), monitor);

    if let Ok(gtk_win) = win.gtk_window() {
        gtk::prelude::GtkWindowExt::resize(&gtk_win, w, h);
    }
}

/// A saved windowed size, clamped to what a monitor of `monitor` physical px
/// at `scale` can show and to the configured minimum. GTK works in logical
/// pixels; the monitor ceiling and the configured floor have to be expressed
/// the same way before they can be applied.
fn clamp_window_size(w: i64, h: i64, scale: f64, monitor: Option<(u32, u32)>) -> (i32, i32) {
    let scale = scale.max(0.1);
    let (max_w, max_h) = match monitor {
        Some((mw, mh)) => (
            (mw as f64 / scale).round() as i32,
            (mh as f64 / scale).round() as i32,
        ),
        None => (i32::MAX, i32::MAX),
    };
    let w = (w as i32).clamp((MIN_WIDTH_CSS as i32).min(max_w), max_w);
    let h = (h as i32).clamp((MIN_HEIGHT_CSS as i32).min(max_h), max_h);
    (w, h)
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
    manual: Option<bool>,
) -> Result<(), String> {
    downloads::restart(app.clone(), &mgr, &item_id, manual.unwrap_or(true))
}

/// Stop a running download but keep what it fetched (pause, or the network
/// turning metered). See `DlManager::pause`.
#[tauri::command]
fn download_pause(mgr: State<'_, downloads::DlManager>, item_id: String) {
    mgr.pause(&item_id);
}

/// Settings' "Keep the laptop awake while downloading" changed.
#[tauri::command]
fn downloads_sync_keep_awake(mgr: State<'_, downloads::DlManager>) {
    mgr.sync_keep_awake();
}

#[tauri::command]
fn network_metered() -> bool {
    network::is_metered()
}

#[tauri::command]
async fn download_fetch_subtitles(item_id: String) {
    let original = downloads::item_dir(&item_id)
        .ok()
        .and_then(|d| std::fs::read_to_string(d.join("meta.json")).ok())
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|m| m["request"]["url"].as_str().map(downloads::is_original_url))
        .unwrap_or(false);
    download_extras::fetch_subtitles(&item_id, original).await;
}

#[tauri::command]
async fn download_update_details(
    item_id: String,
    patch: Value,
    poster_url: Option<String>,
    series_poster_url: Option<String>,
) -> Result<(), String> {
    download_extras::update_details(&item_id, &patch, poster_url, series_poster_url).await
}

/// Show downloads in the file manager (Files on GNOME), selected.
#[tauri::command]
async fn downloads_reveal(item_ids: Vec<String>) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || download_extras::reveal(&item_ids))
        .await
        .map_err(|e| e.to_string())?
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

/// `AQUARIUM_TEST_REPLAY`: `"<url>|<start>"` switches to that stream at that
/// position (5 s if the position doesn't parse); anything else replays
/// `play_url` (the `AQUARIUM_TEST_PLAY` file) at 5 s.
fn replay_target(replay: &str, play_url: &str) -> (String, f64) {
    match replay.rsplit_once('|') {
        Some((u, s)) => (u.to_string(), s.parse::<f64>().unwrap_or(5.0)),
        None => (play_url.to_string(), 5.0),
    }
}

/// `AQUARIUM_TEST_SEQUENCE` as `(seconds to wait, step)` pairs. Each step is
/// `<seconds after start>:<what>`; one without a colon is skipped, a time that
/// doesn't parse counts as 0, and a time earlier than the one before runs at
/// once.
fn test_sequence(seq: &str) -> Vec<(u64, String)> {
    let mut last = 0u64;
    let mut out = Vec::new();
    for step in seq.split(',') {
        let Some((t, what)) = step.split_once(':') else { continue };
        let t: u64 = t.trim().parse().unwrap_or(0);
        out.push((t.saturating_sub(last), what.trim().to_string()));
        last = t;
    }
    out
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
/// `--search-provider`: answer GNOME Shell's search and leave (no window).
pub fn run_search_provider() {
    if let Err(e) = desktop::run_search_provider() {
        eprintln!("aquarium: search provider: {e}");
    }
}

/// `--action=<name>`: give it to the running app and report whether one took
/// it; otherwise it is kept for this one's page.
pub fn launch_action(action: &str) -> bool {
    if desktop::forward(action) {
        return true;
    }
    desktop::set_pending(action);
    false
}

pub fn run() {
    config::migrate_legacy_dirs();
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
        .manage(audio::AudioPlayer::new())
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
                        eprintln!("aquarium: video surface unavailable: {e}");
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
            // On battery / power saver, for Settings' Automatic battery
            // rendering.
            power::watch(app.handle().clone());

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

            // Metered or not, for "Download only on unmetered connections".
            network::watch(app.handle());

            // Media keys, the lock screen, and the shell's audio menu.
            mpris::start(app.handle().clone());
            desktop::start(app.handle().clone());

            config::harden_data_dir();
            if std::env::var_os("AQUARIUM_MPV_LOG").is_none() {
                mpv::remove_logs();
            }

            // Pick up downloads that were mid-transfer when the app last
            // closed (meta.json still says "downloading" but nothing runs).
            downloads::resume_interrupted(app.handle());

            // A previous sign-out may have failed to reach the server, leaving
            // a token that is still live over there. Keep trying.
            tauri::async_runtime::spawn(server::retry_pending_revocation());

            // Dev/test hook: AQUARIUM_TEST_PLAY=<path|url> auto-plays a file
            // shortly after startup so playback can be exercised standalone.
            if let Ok(test_url) = std::env::var("AQUARIUM_TEST_PLAY") {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    let player = handle.state::<player::Player>();
                    let req = player::PlayRequest {
                        url: test_url,
                        title: Some("Aquarium test playback".into()),
                        start_seconds: None,
                        known_duration_seconds: None,
                        volume: None,
                        ctx: None,
                        user_agent: None,
                        subtitles: Vec::new(),
                    };
                    if let Err(e) = player.play(handle.clone(), req).await {
                        eprintln!("aquarium: test playback failed: {e}");
                    }
                    // AQUARIUM_TEST_REPLAY restarts playback mid-stream —
                    // exercises the same path as an in-player quality switch.
                    // Value: "1" replays the same URL at +5s, or "<url>|<start>"
                    // to switch to a different stream/position.
                    if let Ok(replay) = std::env::var("AQUARIUM_TEST_REPLAY") {
                        tokio::time::sleep(std::time::Duration::from_secs(6)).await;
                        let (url2, start2) = replay_target(
                            &replay,
                            &std::env::var("AQUARIUM_TEST_PLAY").unwrap_or_default(),
                        );
                        let req2 = player::PlayRequest {
                            url: url2,
                            title: Some("Aquarium replay test".into()),
                            start_seconds: Some(start2),
                            known_duration_seconds: None,
                            volume: None,
                            ctx: None,
                            user_agent: None,
                            subtitles: Vec::new(),
                        };
                        if let Err(e) = player.play(handle.clone(), req2).await {
                            eprintln!("aquarium: replay test failed: {e}");
                        }
                    }
                });
            }

            // Dev/test hook: AQUARIUM_TEST_SEQUENCE="6:fs,9:bar,12:nobar,15:nofs,18:pip,24:nopip"
            // drives the window states the video surface has to follow, at
            // the given seconds after startup, the way the frontend would:
            // fullscreen on/off (`fs`/`nofs`), the fullscreen bar revealed or
            // hidden (`bar`/`nobar`), picture-in-picture on/off
            // (`pip`/`nopip`), minimised and restored (`min`/`unmin`), and
            // `stop`/`play` to end the session and start
            // another on the AQUARIUM_TEST_PLAY file — the way the next thing
            // opened from the page starts, i.e. windowed, whatever the last
            // session was. Native Wayland has no input injection, so this is
            // how those paths get exercised without a hand on the mouse.
            if let Ok(seq) = std::env::var("AQUARIUM_TEST_SEQUENCE") {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    for (wait, what) in test_sequence(&seq) {
                        tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
                        let what = what.as_str();
                        eprintln!("aquarium: test sequence: {what}");
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
                                    eprintln!("aquarium: test sequence: pip failed: {e}");
                                }
                            }
                            // Out of sight and back: the video thread's
                            // frame-callback check (wl::FrameClock).
                            "min" | "unmin" => {
                                if let Some(w) = &win {
                                    if what == "min" {
                                        let _ = w.minimize();
                                    } else {
                                        // A Wayland client can't un-minimise
                                        // itself; presenting asks the shell,
                                        // which may or may not oblige.
                                        let _ = w.unminimize();
                                        let _ = w.set_focus();
                                    }
                                }
                            }
                            "stop" => player.stop().await,
                            "play" => {
                                let req = player::PlayRequest {
                                    url: std::env::var("AQUARIUM_TEST_PLAY").unwrap_or_default(),
                                    title: Some("Aquarium test playback".into()),
                                    start_seconds: None,
                                    known_duration_seconds: None,
                                    volume: None,
                                    ctx: None,
                                    user_agent: None,
                                    subtitles: Vec::new(),
                                };
                                if let Err(e) = player.play(handle.clone(), req).await {
                                    eprintln!("aquarium: test sequence: play failed: {e}");
                                }
                            }
                            _ => eprintln!("aquarium: test sequence: unknown step {what:?}"),
                        }
                    }
                });
            }
            // Dev/test hook: AQUARIUM_TEST_EVAL=<js> runs a script in the main
            // webview 4 s after startup. Used to put a known load on the
            // page (e.g. a full-window CSS animation) when measuring how the
            // WebKit frame path in `main.rs` behaves next to the video
            // surface; nothing in the app itself uses it.
            if let Ok(js) = std::env::var("AQUARIUM_TEST_EVAL") {
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(4)).await;
                    if let Some(w) = handle.get_webview_window("main") {
                        if let Err(e) = w.eval(&js) {
                            eprintln!("aquarium: test eval failed: {e}");
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
            jf_login_quick_connect,
            jf_public,
            jf_discover,
            accounts_list,
            account_switch,
            player_get_properties,
            player_warm,
            account_forget,
            jf_request,
            jf_image,
            jf_ping,
            jf_bitrate_test,
            seerr_status,
            seerr_probe,
            seerr_connect,
            seerr_connect_password,
            seerr_reconnect,
            seerr_disconnect,
            seerr_refresh,
            seerr_request,
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
            player_set_card_band,
            take_launch_action,
            search_index_write,
            player_set_pip,
            player_mpv_command,
            audio_play,
            audio_set_next,
            audio_command,
            audio_stop,
            audio_status,
            audio_set_queue,
            quit_confirm,
            download_start,
            download_cancel,
            download_retry,
            download_pause,
            downloads_sync_keep_awake,
            network_metered,
            download_fetch_subtitles,
            download_update_details,
            downloads_reveal,
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
        .expect("error while building Aquarium")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                app.state::<player::Player>().stop_sync();
                app.state::<audio::AudioPlayer>().stop_sync();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{sandbox, sign_in, Body, FakeServer, Resp, TEST_TOKEN};

    fn mock() -> tauri::App<tauri::test::MockRuntime> {
        tauri::test::mock_builder()
            .manage(player::Player::new())
            .manage(audio::AudioPlayer::new())
            .manage(downloads::DlManager::default())
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("mock app")
    }

    fn size(w: u32, h: u32) -> tauri::PhysicalSize<u32> {
        tauri::PhysicalSize { width: w, height: h }
    }

    #[test]
    fn the_debug_log_gets_timestamped_lines() {
        let _s = sandbox();
        debug_log_line("hello from a test");
        ui_log("clicked".into());
        let log = crate::test_support::debug_log();
        let line = log.lines().find(|l| l.ends_with("hello from a test")).expect("line written");
        let ts = line.strip_prefix('[').and_then(|r| r.split_once(']')).map(|(t, _)| t).unwrap();
        assert!(ts.parse::<u64>().unwrap() > 1_700_000_000, "{line}");
        assert!(log.lines().any(|l| l.ends_with("] ui: clicked")));
        assert!(now_ms() > 1_700_000_000_000);
    }

    #[test]
    fn config_saves_merge_and_load_back() {
        let _s = sandbox();
        config_save(json!({ "theme": "dark", "server_id": "pinned" })).unwrap();
        // A stale page without server_id must not drop it.
        config_save(json!({ "theme": "light" })).unwrap();
        let cfg = config_load();
        assert_eq!(cfg["theme"], json!("light"));
        assert_eq!(crate::test_support::config_on_disk()["server_id"], json!("pinned"));
        // The token never reaches the page.
        assert!(cfg.get("token").is_none());
        // Nor can the page write the backend's own keys.
        config_save(json!({ "token": "from-the-page", "accounts": [{ "key": "x" }] })).unwrap();
        let disk = crate::test_support::config_on_disk();
        assert!(disk.get("token").is_none() && disk.get("accounts").is_none(), "{disk}");
    }

    #[test]
    fn app_info_describes_this_install() {
        let _s = sandbox();
        let info = app_info();
        assert_eq!(info["version"], json!(jellyfin::CLIENT_VERSION));
        assert!(info["mpv"].as_str().is_some_and(|s| !s.is_empty()));
        assert!(info["downloads_dir"].as_str().is_some_and(|s| !s.is_empty()));
        assert_eq!(info["server_secure"], json!(false), "no server");
        assert_eq!(info["server_pinned"], json!(false));
        assert!(info["revocation_pending"].is_boolean());
        assert!(info["token_storage"].is_string());
    }

    #[test]
    fn a_user_agent_is_set_only_when_given() {
        let built = |ua: Option<&str>| {
            with_user_agent(jellyfin::http().get("http://example.invalid/x"), ua).build().unwrap()
        };
        assert_eq!(
            built(Some("  VLC/3.0.20 LibVLC/3.0.20 ")).headers().get(reqwest::header::USER_AGENT).unwrap(),
            "VLC/3.0.20 LibVLC/3.0.20"
        );
        // Blank or absent: the request carries none, so the client's own
        // Aquarium/<version> is what goes out.
        assert!(built(Some("   ")).headers().get(reqwest::header::USER_AGENT).is_none());
        assert!(built(None).headers().get(reqwest::header::USER_AGENT).is_none());
    }

    #[tokio::test]
    async fn fetch_source_reads_files_and_unwraps_gzip() {
        let dir = std::env::temp_dir().join(format!("aquarium-src-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let plain = dir.join("list.m3u");
        std::fs::write(&plain, "#EXTM3U\n#EXTINF:-1,One\nhttp://x/1\n").unwrap();
        assert!(fetch_source(plain.to_string_lossy().into(), None).await.unwrap().starts_with("#EXTM3U"));
        let as_url = format!("  file://{}  ", plain.display());
        assert!(fetch_source(as_url, None).await.unwrap().contains("One"));

        // Gzip is sniffed from the bytes, not the name.
        let gz = dir.join("guide.xml");
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        std::io::Write::write_all(&mut enc, b"<tv><channel id=\"a\"/></tv>").unwrap();
        std::fs::write(&gz, enc.finish().unwrap()).unwrap();
        assert_eq!(fetch_source(gz.to_string_lossy().into(), None).await.unwrap(), "<tv><channel id=\"a\"/></tv>");

        let empty = dir.join("empty.m3u");
        std::fs::write(&empty, " \n\t").unwrap();
        assert!(fetch_source(empty.to_string_lossy().into(), None).await.unwrap_err().contains("returned nothing"));
        assert!(fetch_source(dir.join("missing").to_string_lossy().into(), None)
            .await
            .unwrap_err()
            .starts_with("Couldn't open"));
        assert_eq!(fetch_source("   ".into(), None).await, Err("No address given".to_string()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn fetch_source_fetches_over_http_with_the_given_user_agent() {
        let server = FakeServer::start(|r| match r.path() {
            "/list.m3u" => Resp::bytes(200, "audio/x-mpegurl", b"#EXTM3U\n".to_vec()),
            "/huge.xml" => Resp::body(200, Body::Short { declared: 300 * 1024 * 1024, sent: b"<tv>".to_vec() }),
            _ => Resp::status(404),
        });
        let text = fetch_source(format!("{}/list.m3u", server.url), Some("Kodi/20".into())).await.unwrap();
        assert_eq!(text, "#EXTM3U\n");
        assert_eq!(server.requests_to("/list.m3u")[0].header("user-agent"), Some("Kodi/20"));
        let err = fetch_source(format!("{}/nope", server.url), None).await.unwrap_err();
        assert!(err.contains("404"), "{err}");
        // A declared length over the cap is refused before anything is read.
        let err = fetch_source(format!("{}/huge.xml", server.url), None).await.unwrap_err();
        assert!(err.contains("too large"), "{err}");
    }

    #[tokio::test]
    async fn resolve_stream_leaves_non_http_addresses_alone() {
        assert_eq!(resolve_stream("  rtsp://cam/1 ".into(), None).await, Ok("rtsp://cam/1".to_string()));
    }

    /// A playlist is handed to mpv at its final address, so neither of mpv's
    /// two opens repeats the redirect chain.
    #[tokio::test]
    async fn resolve_stream_returns_a_playlists_final_address() {
        let server = FakeServer::start(|r| match r.path() {
            "/live/1" => Resp::status(302).header("Location", "/hls/1/index.m3u8"),
            "/hls/1/index.m3u8" => Resp::bytes(200, "application/vnd.apple.mpegurl", b"#EXTM3U\n".to_vec()),
            "/ts/1" => Resp::bytes(200, "video/mp2t", vec![0x47; 188]),
            _ => Resp::status(404),
        });
        let got = resolve_stream(format!("{}/live/1", server.url), Some("VLC/3".into())).await.unwrap();
        assert_eq!(got, format!("{}/hls/1/index.m3u8", server.url));
        assert_eq!(server.requests_to("/live/1")[0].header("user-agent"), Some("VLC/3"));
        // A raw transport stream keeps the address it was given.
        let ts = format!("{}/ts/1", server.url);
        assert_eq!(resolve_stream(ts.clone(), None).await, Ok(ts));
    }

    /// A refused address won't improve by asking again: one request, then
    /// the error.
    #[tokio::test]
    async fn resolve_stream_gives_up_at_once_on_a_client_error() {
        let server = FakeServer::start(|_| Resp::status(404));
        let err = resolve_stream(format!("{}/live/2", server.url), None).await.unwrap_err();
        assert!(err.contains("404"), "{err}");
        assert_eq!(server.requests().len(), 1);
    }

    /// A cold channel answers 500 while its session comes up; that is
    /// retried rather than handed to mpv.
    #[tokio::test]
    async fn resolve_stream_retries_a_server_error() {
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let c = calls.clone();
        let server = FakeServer::start(move |_| {
            if c.fetch_add(1, Ordering::SeqCst) == 0 {
                Resp::status(500)
            } else {
                Resp::bytes(200, "application/x-mpegurl", b"#EXTM3U\n".to_vec())
            }
        });
        let url = format!("{}/live/3.m3u8", server.url);
        assert_eq!(resolve_stream(url.clone(), None).await, Ok(url));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn track_kinds_map_to_mpv_properties() {
        assert_eq!(track_property("audio"), Ok("aid"));
        assert_eq!(track_property("sub"), Ok("sid"));
        assert_eq!(track_property("video"), Err("unknown track kind".to_string()));
    }

    /// Windowed, the bar is always reserved; fullscreen, the surface covers
    /// the window and the revealed bar is clipped out of it, so the picture
    /// does not move when the controls come and go.
    #[test]
    fn the_video_layout_follows_the_viewport() {
        let s = size(2880, 1920);
        assert_eq!(video_layout(s, 2.0, false, false), ((0, 0, 2880, 1776), 0));
        assert_eq!(video_layout(s, 2.0, false, true), ((0, 0, 2880, 1776), 0));
        assert_eq!(video_layout(s, 2.0, true, false), ((0, 0, 2880, 1920), 0));
        assert_eq!(video_layout(s, 2.0, true, true), ((0, 0, 2880, 1920), 144));
        assert_eq!(video_layout(size(1280, 800), 1.25, true, true), ((0, 0, 1280, 800), 90));
    }

    /// The saved size is clamped to the monitor, so a figure that once grew
    /// on every restart until the window could not be created cannot come
    /// back (regression: the stored size grew by the decorations each quit and
    /// crossed the 16384 px texture limit).
    #[test]
    fn a_saved_window_size_is_clamped_to_the_monitor_and_the_minimum() {
        let monitor = Some((2880, 1920));
        assert_eq!(clamp_window_size(1300, 850, 2.0, monitor), (1300, 850));
        assert_eq!(clamp_window_size(40_000, 17_000, 2.0, monitor), (1440, 960));
        assert_eq!(clamp_window_size(10, 10, 2.0, monitor), (MIN_WIDTH_CSS as i32, MIN_HEIGHT_CSS as i32));
        // A monitor smaller than the minimum wins over the minimum.
        assert_eq!(clamp_window_size(1300, 850, 1.0, Some((800, 500))), (800, 500));
        // No monitor known: only the floor applies.
        assert_eq!(clamp_window_size(1300, 850, 1.0, None), (1300, 850));
        assert_eq!(clamp_window_size(-5, 0, 1.0, None), (900, 600));
        // A nonsense scale is treated as 0.1 rather than dividing by zero.
        assert_eq!(clamp_window_size(100_000, 100_000, 0.0, Some((100, 100))), (1000, 1000));
    }

    #[test]
    fn the_minimum_size_matches_tauri_conf() {
        let conf: Value = serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let win = &conf["app"]["windows"][0];
        assert_eq!(win["minWidth"].as_f64(), Some(MIN_WIDTH_CSS));
        assert_eq!(win["minHeight"].as_f64(), Some(MIN_HEIGHT_CSS));
    }

    #[test]
    fn the_window_size_lives_in_the_config_dir() {
        assert_eq!(window_size_path(), config::config_dir().join("window.json"));
    }

    #[test]
    fn replay_targets() {
        assert_eq!(replay_target("1", "/tmp/a.mkv"), ("/tmp/a.mkv".to_string(), 5.0));
        assert_eq!(replay_target("http://x/b|30", "/tmp/a.mkv"), ("http://x/b".to_string(), 30.0));
        assert_eq!(replay_target("a|b|12.5", ""), ("a|b".to_string(), 12.5));
        assert_eq!(replay_target("http://x/c|soon", ""), ("http://x/c".to_string(), 5.0));
    }

    /// The CLAUDE.md example, as waits between steps.
    #[test]
    fn the_test_sequence_is_absolute_times_turned_into_waits() {
        let steps = test_sequence("7:fs,11:bar,15:nobar,18:nofs,22:pip,29:nopip");
        let want: Vec<(u64, String)> = [(7, "fs"), (4, "bar"), (4, "nobar"), (3, "nofs"), (4, "pip"), (7, "nopip")]
            .iter()
            .map(|(t, s)| (*t, s.to_string()))
            .collect();
        assert_eq!(steps, want);
    }

    #[test]
    fn odd_test_sequence_steps() {
        assert_eq!(test_sequence(""), vec![]);
        assert_eq!(test_sequence("fs,3:bar"), vec![(3, "bar".to_string())], "no colon: skipped");
        assert_eq!(
            test_sequence(" 2 : stop , x:play ,5:min,4:unmin"),
            vec![(2, "stop".to_string()), (0, "play".to_string()), (5, "min".to_string()), (0, "unmin".to_string())]
        );
    }

    #[tokio::test]
    async fn player_commands_with_nothing_playing() {
        let app = mock();
        assert_eq!(player_seek(app.state(), 10.0, true).await, Err("no active playback".to_string()));
        assert_eq!(player_pause_toggle(app.state()).await, Err("no active playback".to_string()));
        assert_eq!(player_mpv_command(app.state(), vec![json!("cycle"), json!("pause")]).await, Err("no active playback".to_string()));
        assert_eq!(player_set_track(app.state(), "video".into(), json!(1)).await, Err("unknown track kind".to_string()));
        assert_eq!(player_set_track(app.state(), "sub".into(), json!("no")).await, Err("no active playback".to_string()));
        assert_eq!(player_get_properties(app.state(), vec!["hwdec-current".into()]).await, Ok(json!({})));
        assert_eq!(player_stop(app.state()).await, Ok(()));
        assert!(!player_status(app.state()).active);
        player_set_next_available(app.state(), true);
        assert!(app.state::<player::Player>().next_available());
    }

    #[tokio::test]
    async fn audio_commands_with_nothing_playing() {
        let app = mock();
        assert_eq!(audio_command(app.state(), vec![json!("cycle"), json!("pause")]).await, Err("nothing is playing".to_string()));
        assert_eq!(audio_set_next(app.state(), None).await, Ok(()));
        assert!(!audio_status(app.state()).active);
        audio_set_queue(app.state(), vec![audio::AudioTrack { item_id: "a".into(), ..Default::default() }], 0, true, false);
        let q = app.state::<audio::AudioPlayer>().queue();
        assert_eq!(q.entries.len(), 1);
        assert!(app.state::<audio::AudioPlayer>().can_next());
    }

    #[test]
    fn audio_devices_are_name_and_description_objects() {
        for d in audio_devices() {
            assert!(d["name"].as_str().is_some_and(|s| !s.is_empty()), "{d}");
            assert!(d["description"].as_str().is_some_and(|s| !s.is_empty()), "{d}");
        }
    }

    #[test]
    fn download_and_progress_commands_on_an_empty_install() {
        let _s = sandbox();
        let app = mock();
        assert!(downloads_list(app.state()).is_empty());
        assert!(download_delete("../escape".into()).is_err(), "ids are checked before use as paths");
        assert_eq!(progress_pending(), 0);
        assert!(progress_pending_ids().is_empty());
        assert!(!network_metered());
        let _ = disk_free();
        download_cancel(app.state(), "nothing".into());
        download_pause(app.state(), "nothing".into());
    }

    #[test]
    fn a_local_watch_state_is_queued_for_the_signed_in_user() {
        let _s = sandbox();
        sign_in("http://127.0.0.1:9");
        progress_store_local("abc".into(), 1234, false);
        assert_eq!(progress_pending(), 1);
        assert_eq!(progress_pending_ids(), vec!["abc".to_string()]);
    }

    #[tokio::test]
    async fn progress_sync_needs_a_server_a_user_and_a_token() {
        let _s = sandbox();
        assert_eq!(progress_sync().await, Err("not connected to a server".to_string()));
        config::merge(json!({ "server": "http://127.0.0.1:9" })).unwrap();
        assert_eq!(progress_sync().await, Err("not signed in".to_string()));
        config::merge(json!({ "user_id": "u" })).unwrap();
        assert_eq!(progress_sync().await, Err("not signed in".to_string()));
        secret::store(TEST_TOKEN).unwrap();
        // Signed in to a server that isn't there: verification fails.
        assert!(progress_sync().await.is_err());
    }

    #[test]
    fn switching_to_an_unknown_account_fails() {
        let _s = sandbox();
        assert!(account_switch("nobody|nowhere".into()).is_err());
        assert!(accounts_list().is_array() || accounts_list().is_object());
    }
}
