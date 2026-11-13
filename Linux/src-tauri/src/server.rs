//! Everything between the app and the Jellyfin server's front door: validating
//! the address the user typed, preferring TLS over plaintext, pinning the
//! server's identity, and holding the access token on this side of the IPC
//! boundary.
//!
//! The webview used to do all of this itself with the HTTP plugin, which meant
//! the password and then the access token both lived in JavaScript, and the
//! plugin was scoped to `http://**` — everything needed to hand the token to
//! any host on the internet, if anything ever managed to run a script in the
//! window. Requests now go out from here; the frontend sends a path and gets
//! back a status and a body.
//!
//! Errors are `"<kind>|<message>"`. The frontend needs to tell "the network is
//! down" (go to offline mode) apart from "this is not the server you signed in
//! to" (stop, loudly), and a bare string can't carry that.

use crate::{config, jellyfin, secret};
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;

const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

fn err(kind: &str, msg: impl std::fmt::Display) -> String {
    format!("{}|{}", kind, msg)
}

/// A transport failure — no HTTP response came back at all.
fn offline_err(e: &reqwest::Error) -> String {
    crate::debug_log_line(&format!("server: request failed: {}", e));
    err("offline", "Server unreachable — you appear to be offline")
}

/// Parse and normalize a server address.
///
/// Rejects everything that isn't a plain http(s) origin: no `file://`, no
/// credentials baked into the URL, no query or fragment. config.json is just a
/// file on disk, and this is what stands between a tampered `server` value and
/// the app cheerfully sending an access token to it.
pub fn normalize(raw: &str) -> Result<String, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(err("config", "Enter your server address"));
    }
    let url = reqwest::Url::parse(raw)
        .map_err(|_| err("config", format!("\"{}\" is not a valid server address", raw)))?;

    match url.scheme() {
        "http" | "https" => {}
        s => {
            return Err(err(
                "config",
                format!("Unsupported address scheme \"{}\" — use http:// or https://", s),
            ))
        }
    }
    let host = match url.host_str() {
        Some(h) if !h.is_empty() => h.to_string(),
        _ => return Err(err("config", "That address has no server name in it")),
    };
    if !url.username().is_empty() || url.password().is_some() {
        return Err(err(
            "config",
            "Don't put a username or password in the server address",
        ));
    }

    let mut out = format!("{}://{}", url.scheme(), host);
    if let Some(port) = url.port() {
        out.push_str(&format!(":{}", port));
    }
    // Reverse proxies commonly mount Jellyfin under a sub-path, so the path is
    // kept — but only the path.
    let path = url.path().trim_end_matches('/');
    if !path.is_empty() {
        out.push_str(path);
    }
    Ok(out)
}

pub fn is_secure(server: &str) -> bool {
    server.starts_with("https://")
}

/// `/System/Info/Public` — the one endpoint that answers without a token, and
/// the one that says which Jellyfin install is on the other end.
async fn public_info(server: &str) -> Result<Value, String> {
    let resp = jellyfin::http()
        .get(format!("{}/System/Info/Public", server))
        .timeout(PROBE_TIMEOUT)
        .send()
        .await
        .map_err(|e| offline_err(&e))?;
    if !resp.status().is_success() {
        return Err(err(
            "server",
            format!("Server responded with {}", resp.status().as_u16()),
        ));
    }
    resp.json::<Value>().await.map_err(|_| {
        err(
            "server",
            "That address answered, but not like a Jellyfin server",
        )
    })
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v.get(key)
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// Resolve what the user typed into a reachable server URL, preferring TLS.
///
/// A bare `media.example.com` used to be turned into `http://media.example.com`
/// without comment, which puts the password on the wire in the clear and every
/// later request's token with it. HTTPS is tried first now; plaintext is only
/// the fallback, and the caller is told which one answered so it can say so.
pub async fn probe(raw: &str) -> Result<Value, String> {
    let typed = raw.trim();
    // Any scheme typed goes to normalize as it is, which accepts only http
    // and https: "file:///x" is a config error, not a host called "file".
    let has_scheme = typed.split_once("://").is_some_and(|(scheme, _)| {
        !scheme.is_empty() && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
    });
    let candidates: Vec<String> = if has_scheme {
        vec![normalize(typed)?]
    } else {
        vec![
            normalize(&format!("https://{}", typed))?,
            normalize(&format!("http://{}", typed))?,
        ]
    };

    let mut last = err("offline", "Server unreachable — you appear to be offline");
    for cand in &candidates {
        match public_info(cand).await {
            Ok(info) => {
                return Ok(json!({
                    "server": cand,
                    "secure": is_secure(cand),
                    "server_id": str_field(&info, "Id"),
                    "server_name": str_field(&info, "ServerName"),
                    "version": str_field(&info, "Version"),
                }))
            }
            Err(e) => last = e,
        }
    }
    Err(last)
}

// ---------- Server identity pinning ----------

/// The server URL whose identity has been checked in this process.
static VERIFIED: Mutex<Option<String>> = Mutex::new(None);

/// Test hook: forget which server this process has verified.
#[cfg(test)]
pub fn reset_for_tests() {
    *VERIFIED.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

/// Confirm the address in the config still points at the Jellyfin install the
/// user signed in to, before anything authenticated goes out over it.
///
/// The app reads its server URL out of config.json on every launch and starts
/// sending the access token there; nothing checked that the address still led
/// anywhere the user had ever agreed to. The server's own id is recorded at
/// sign-in and re-checked here, once per session.
pub async fn ensure_verified(server: &str) -> Result<(), String> {
    verify(server, false).await
}

/// The check itself. `force` skips the cache: a caller that wants to know
/// whether the server is reachable *now* (see `ping`) must not be answered
/// from memory.
async fn verify(server: &str, force: bool) -> Result<(), String> {
    if !force && VERIFIED.lock().unwrap().as_deref() == Some(server) {
        return Ok(());
    }
    let info = public_info(server).await?;
    let seen = str_field(&info, "Id");
    let pinned = config::load()
        .get("server_id")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_owned);

    match (pinned, seen) {
        (Some(pin), Some(now)) if pin != now => {
            crate::debug_log_line("server: identity mismatch — refusing to authenticate");
            return Err(err(
                "identity",
                "This address is answering as a different Jellyfin server than the one you signed in to. Check your settings and sign in again.",
            ));
        }
        // Trust on first use: an install that predates pinning, or a server too
        // old to report an id.
        (None, Some(now)) => {
            let _ = config::merge(json!({ "server_id": now }));
        }
        _ => {}
    }
    *VERIFIED.lock().unwrap() = Some(server.to_string());
    Ok(())
}

/// Forget the verification cache — used on sign-out, so the next sign-in
/// re-checks rather than inheriting the last session's answer.
fn forget_verification() {
    *VERIFIED.lock().unwrap() = None;
}

/// The validated server URL from the config, if there is one.
fn configured_server() -> Result<String, String> {
    let cfg = config::load();
    let raw = cfg
        .get("server")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| err("config", "Not connected to a server"))?;
    normalize(raw)
}

/// Scheme, host and port, for http(s) URLs only. Refuses backslashes and control
/// characters: this parser and FFmpeg's read those differently, so
/// `https://jf.example.com\@evil.net` is a different host to each of them.
fn origin(url: &str) -> Option<(String, String, u16)> {
    if url.contains('\\') || url.chars().any(char::is_control) {
        return None;
    }
    let u = reqwest::Url::parse(url).ok()?;
    if !matches!(u.scheme(), "http" | "https") {
        return None;
    }
    Some((
        u.scheme().to_string(),
        u.host_str()?.to_string(),
        u.port_or_known_default()?,
    ))
}

fn same_origin(a: &str, b: &str) -> bool {
    matches!((origin(a), origin(b)), (Some(x), Some(y)) if x == y)
}

/// Whether a URL is on the server this install is signed in to. Checked before
/// the token goes anywhere whose address came from a stored download record or
/// from the webview, either of which can name somewhere else.
pub fn is_session_origin(url: &str) -> bool {
    configured_server().is_ok_and(|server| same_origin(url, &server))
}

// ---------- Authenticated requests ----------

/// One Jellyfin API call, made from Rust with the token added here.
pub async fn request(path: &str, method: Option<String>, body: Option<Value>) -> Result<Value, String> {
    if !path.starts_with('/') {
        return Err(err("config", "API path must start with /"));
    }
    let server = configured_server()?;
    ensure_verified(&server).await?;

    let token = secret::token().ok_or_else(|| err("auth", "Not signed in"))?;
    let device_id = config::device_id();
    let method = method.unwrap_or_else(|| "GET".into());
    let verb = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|_| err("config", format!("Unsupported method {}", method)))?;

    let mut req = jellyfin::http()
        .request(verb, format!("{}{}", server, path))
        .header("Authorization", jellyfin::auth_header(&token, &device_id));
    if let Some(b) = body {
        req = req.json(&b);
    }

    let resp = req.send().await.map_err(|e| offline_err(&e))?;
    let status = resp.status().as_u16();
    let text = without_token(&resp.text().await.unwrap_or_default(), &token);
    let parsed: Option<Value> = if text.trim().is_empty() {
        None
    } else {
        serde_json::from_str(&text).ok()
    };
    Ok(json!({ "status": status, "body": parsed }))
}

/// A reply with the access token taken out before it reaches the webview.
/// Jellyfin writes it into the addresses it builds (`ApiKey=<token>` in a
/// transcode's `TranscodingUrl` and a subtitle's `DeliveryUrl`); those
/// parameters go, and the token anywhere else is blanked. Every stream the app
/// opens on the server authenticates with the Authorization header instead.
fn without_token(text: &str, token: &str) -> String {
    if token.is_empty() || !text.contains(token) {
        return text.to_string();
    }
    let mut out = text.to_string();
    for key in ["ApiKey", "api_key"] {
        let param = format!("{key}={token}");
        out = out
            .replace(&format!("{param}&"), "")
            .replace(&format!("&{param}"), "")
            .replace(&format!("?{param}"), "");
    }
    out.replace(token, "")
}

/// The raw body of an authenticated GET, for the few things fetched from Rust
/// to be kept as files (a download's subtitles). Fails on any non-2xx.
pub async fn get_bytes(path: &str) -> Result<Vec<u8>, String> {
    if !path.starts_with('/') {
        return Err(err("config", "API path must start with /"));
    }
    let server = configured_server()?;
    ensure_verified(&server).await?;
    let token = secret::token().ok_or_else(|| err("auth", "Not signed in"))?;
    let resp = jellyfin::http()
        .get(format!("{}{}", server, path))
        .header("Authorization", jellyfin::auth_header(&token, &config::device_id()))
        .send()
        .await
        .map_err(|e| offline_err(&e))?;
    if !resp.status().is_success() {
        return Err(err("server", format!("Request failed ({})", resp.status().as_u16())));
    }
    Ok(resp.bytes().await.map_err(|e| offline_err(&e))?.to_vec())
}

/// Base64, so an image fetched here can be handed to the webview as a data URL.
/// Written out rather than pulled in as a dependency: it is twenty lines, and
/// the build stays buildable without reaching the network for a crate.
fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

/// An image from an endpoint that needs the access token, handed back as a data
/// URL. Only trickplay tiles use this: posters and backdrops are served
/// unauthenticated, so the webview fetches those itself with a plain `<img>`.
///
/// The token stays in this process, which is the whole point — the alternative
/// every other Jellyfin client takes is `?api_key=…` on the image URL, putting
/// the credential in the webview, in the page source, and in any log that
/// records a URL.
pub async fn image(path: &str) -> Result<String, String> {
    if !path.starts_with('/') {
        return Err(err("config", "API path must start with /"));
    }
    // Image endpoints only. Without this the command is a general "fetch any
    // authenticated path and hand it back as an opaque blob".
    let file = path.split('?').next().unwrap_or_default().to_ascii_lowercase();
    if !(file.ends_with(".jpg") || file.ends_with(".jpeg") || file.ends_with(".png") || file.ends_with(".webp")) {
        return Err(err("config", "Not an image path"));
    }

    let server = configured_server()?;
    ensure_verified(&server).await?;
    let token = secret::token().ok_or_else(|| err("auth", "Not signed in"))?;
    let device_id = config::device_id();

    let resp = jellyfin::http()
        .get(format!("{}{}", server, path))
        .header("Authorization", jellyfin::auth_header(&token, &device_id))
        .send()
        .await
        .map_err(|e| offline_err(&e))?;
    let status = resp.status().as_u16();
    if !resp.status().is_success() {
        // A title with no trickplay data 404s; the caller treats that as "no
        // previews for this one" rather than as a failure.
        return Err(err("server", format!("Image request failed ({})", status)));
    }
    let mime = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split(';').next())
        .map(|v| v.trim().to_ascii_lowercase())
        .filter(|v| v.starts_with("image/"))
        .unwrap_or_else(|| "image/jpeg".into());

    let bytes = resp.bytes().await.map_err(|e| offline_err(&e))?;
    // A trickplay tile is tens of kilobytes. Anything at this size is not one,
    // and base64 of it would be a multi-megabyte string over the IPC boundary.
    if bytes.len() > (8 << 20) {
        return Err(err("server", "Image too large"));
    }
    Ok(format!("data:{};base64,{}", mime, base64(&bytes)))
}

/// How long the probe download is allowed to run. A connection that can't
/// finish it in this long is already answering the question either way.
const BITRATE_TEST_TIMEOUT: Duration = Duration::from_secs(4);

/// Download `size` bytes of Jellyfin's own bandwidth-test payload and time how
/// long the transfer itself takes, for a starting-bitrate estimate before a
/// stream begins. `/Playback/BitrateTest` exists on the server for exactly
/// this — it's what the official web and Android TV clients use for their own
/// "Auto" quality setting, so nothing here is asking the server for anything
/// it doesn't already expect to serve.
///
/// Only the body transfer is timed, not the request as a whole: connection
/// setup and the TLS handshake are one-time costs that would otherwise make a
/// fast, freshly-opened connection look artificially slow on the first
/// measurement of a session.
///
/// Returns bits per second. Every failure — offline, a server too old to have
/// the endpoint, the timeout — is the caller's cue to skip the estimate
/// entirely rather than something to show anyone; a probe that didn't answer
/// just means playback starts the way it always has.
pub async fn bitrate_test(size: u32) -> Result<f64, String> {
    let server = configured_server()?;
    ensure_verified(&server).await?;
    let token = secret::token().ok_or_else(|| err("auth", "Not signed in"))?;
    let device_id = config::device_id();

    let resp = jellyfin::http()
        .get(format!("{}/Playback/BitrateTest?Size={}", server, size))
        .header("Authorization", jellyfin::auth_header(&token, &device_id))
        .timeout(BITRATE_TEST_TIMEOUT)
        .send()
        .await
        .map_err(|e| offline_err(&e))?;
    if !resp.status().is_success() {
        return Err(err(
            "server",
            format!("Bitrate test failed ({})", resp.status().as_u16()),
        ));
    }
    let started = std::time::Instant::now();
    let bytes = resp.bytes().await.map_err(|e| offline_err(&e))?;
    let elapsed = started.elapsed().as_secs_f64();
    if bytes.is_empty() || elapsed <= 0.0 {
        return Err(err("server", "Bitrate test returned nothing"));
    }
    Ok((bytes.len() as f64 * 8.0) / elapsed)
}

/// Open the next title's stream ahead of time, so the server has it running
/// by the time the current one ends.
///
/// A transcode is the slow part of starting anything: the server only starts
/// ffmpeg when the playlist is first asked for, and the first segments take
/// seconds to appear. Asking for the playlist (and the variant playlist it
/// names) 90 seconds early means mpv later opens a session that is already
/// producing segments — Jellyfin reuses the job for the same play session. A
/// direct file just has its first half-megabyte read, which wakes the disk
/// and fills the server's page cache. Only addresses on the signed-in server
/// get the token.
pub async fn warm(url: &str) -> Result<(), String> {
    let server = configured_server()?;
    if !url.starts_with(&format!("{}/", server)) {
        return Err(err("config", "Not a stream on this server"));
    }
    ensure_verified(&server).await?;
    let token = secret::token().ok_or_else(|| err("auth", "Not signed in"))?;
    let auth = jellyfin::auth_header(&token, &config::device_id());
    let get = |u: String, range: Option<&str>| {
        let mut r = jellyfin::http()
            .get(u)
            .header("Authorization", auth.clone())
            .timeout(Duration::from_secs(30));
        if let Some(range) = range {
            r = r.header(reqwest::header::RANGE, range);
        }
        r
    };

    let resp = get(url.to_string(), None).send().await.map_err(|e| offline_err(&e))?;
    let final_url = resp.url().clone();
    let playlist = final_url.path().ends_with(".m3u8")
        || resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.to_ascii_lowercase().contains("mpegurl"));
    if !playlist {
        // A file: never read it all. Drop the connection after the first part.
        drop(resp);
        let _ = get(url.to_string(), Some("bytes=0-524287"))
            .send()
            .await
            .map_err(|e| offline_err(&e))?
            .bytes()
            .await;
        return Ok(());
    }
    let text = resp.text().await.map_err(|e| offline_err(&e))?;
    // The master playlist names the variant playlist; asking for that is
    // what starts the transcode.
    if let Some(variant) = text.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with('#')) {
        if let Ok(next) = final_url.join(variant) {
            if next.as_str().starts_with(&server) {
                let _ = get(next.to_string(), None).send().await.map(|r| drop(r));
            }
        }
    }
    Ok(())
}

/// Is the saved server reachable — and still the right one? Used for the
/// offline indicator and the startup check.
pub async fn ping() -> Result<bool, String> {
    let server = configured_server()?;
    // Always a real round trip, never the verification cache: this is the
    // call that decides "offline", and the Retry button's answer in
    // particular has to come from the network, not from the process having
    // once seen the server.
    //
    // A probe that fails *instantly* — the resolver with no network under it,
    // a connection refused by a stack still coming up — is what the seconds
    // after a wake or a Wi-Fi hand-off look like, and one such failure used
    // to be enough to put the app in offline mode. Ask again, briefly, before
    // calling it. A timeout is already a wait, and is not repeated.
    const FAST_FAILURE: Duration = Duration::from_millis(1500);
    const ATTEMPTS: u32 = 3;
    for attempt in 1..=ATTEMPTS {
        let started = std::time::Instant::now();
        match verify(&server, true).await {
            Ok(()) => return Ok(true),
            // Unreachable is a "no", not an error worth surfacing; an identity
            // change very much is.
            Err(e) if e.starts_with("offline|") || e.starts_with("server|") => {
                if attempt == ATTEMPTS || started.elapsed() > FAST_FAILURE {
                    return Ok(false);
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            Err(e) => return Err(e),
        }
    }
    Ok(false)
}

// ---------- Sign in / sign out ----------

/// Authenticate and keep the token here. The frontend gets back who it signed
/// in as and over what kind of connection — never the credential itself.
pub async fn login(raw_server: &str, username: &str, password: &str) -> Result<Value, String> {
    let probed = probe(raw_server).await?;
    let server = probed["server"].as_str().unwrap_or_default().to_string();
    let device_id = config::device_id();

    let resp = jellyfin::http()
        .post(format!("{}/Users/AuthenticateByName", server))
        .header("Authorization", jellyfin::auth_header_anon(&device_id))
        .json(&json!({ "Username": username, "Pw": password }))
        .send()
        .await
        .map_err(|e| offline_err(&e))?;

    if resp.status().as_u16() == 401 {
        return Err(err("auth", "Invalid username or password"));
    }
    if !resp.status().is_success() {
        return Err(err(
            "server",
            format!("Login failed ({})", resp.status().as_u16()),
        ));
    }
    let data: Value = resp
        .json()
        .await
        .map_err(|_| err("server", "Login succeeded but the reply made no sense"))?;
    install(&server, &probed, &data)
}

/// Turn an approved Quick Connect code into a session. Only sensible once
/// `/QuickConnect/Connect` has answered `Authenticated: true`; before that the
/// server refuses.
pub async fn login_quick_connect(raw_server: &str, secret_code: &str) -> Result<Value, String> {
    let probed = probe(raw_server).await?;
    let server = probed["server"].as_str().unwrap_or_default().to_string();
    let device_id = config::device_id();
    let resp = jellyfin::http()
        .post(format!("{}/Users/AuthenticateWithQuickConnect", server))
        .header("Authorization", jellyfin::auth_header_anon(&device_id))
        .json(&json!({ "Secret": secret_code }))
        .send()
        .await
        .map_err(|e| offline_err(&e))?;
    if !resp.status().is_success() {
        return Err(err(
            "auth",
            format!("The server didn't accept that code ({})", resp.status().as_u16()),
        ));
    }
    let data: Value = resp
        .json()
        .await
        .map_err(|_| err("server", "Sign-in succeeded but the reply made no sense"))?;
    install(&server, &probed, &data)
}

/// Make the account an authentication reply names the one in use: its token
/// to the keyring (as the active token and in the account's own slot), its
/// identity to the config, and the account to the list this device can switch
/// between. The account being left, if any, keeps its token in its slot.
fn install(server: &str, probed: &Value, data: &Value) -> Result<Value, String> {
    let secure = is_secure(server);
    let device_id = config::device_id();
    let token = str_field(data, "AccessToken")
        .ok_or_else(|| err("server", "Server issued no access token"))?;
    let user_id = data
        .get("User")
        .and_then(|u| str_field(u, "Id"))
        .ok_or_else(|| err("server", "Server returned no user"))?;
    let user_name = data
        .get("User")
        .and_then(|u| str_field(u, "Name"))
        .unwrap_or_default();
    let server_id = str_field(probed, "server_id");
    let server_name = str_field(probed, "server_name");

    stash_current();
    secret::store(&token)?;
    let key = account_key(server_id.as_deref(), server, &user_id);
    // The identity recorded here is what every later launch is checked against.
    config::merge(json!({
        "server": server,
        "server_id": server_id,
        "server_secure": secure,
        "user_id": user_id,
        "user_name": user_name,
        "account_key": key,
    }))?;
    config::upsert_account(json!({
        "key": key,
        "server": server,
        "server_id": server_id,
        "server_name": server_name,
        "server_secure": secure,
        "user_id": user_id,
        "user_name": user_name,
    }))?;
    // After the entry exists: without a keyring the token is filed in it.
    if let Err(e) = secret::store_account(&key, &token) {
        crate::debug_log_line(&format!("server: couldn't file the account's own token: {}", e));
    }
    remember_server(server, server_name.as_deref());
    *VERIFIED.lock().unwrap() = Some(server.to_string());

    Ok(json!({
        "server": server,
        "secure": secure,
        "user_id": user_id,
        "user_name": user_name,
        "device_id": device_id,
        "token_storage": secret::backend_name(),
    }))
}

// ---------- More than one account ----------

/// What identifies one account: the server's own id where it reports one (so
/// a server that moves address is still the same account), its address
/// otherwise, and the user.
fn account_key(server_id: Option<&str>, server: &str, user_id: &str) -> String {
    format!("{}|{}", server_id.filter(|s| !s.is_empty()).unwrap_or(server), user_id)
}

/// The key of the account in use, if one is signed in. Installs from before
/// accounts existed have no `account_key` yet; it is worked out and recorded.
fn current_key(cfg: &Value) -> Option<String> {
    let user_id = str_field(cfg, "user_id")?;
    let server = str_field(cfg, "server")?;
    if let Some(k) = str_field(cfg, "account_key") {
        return Some(k);
    }
    let key = account_key(str_field(cfg, "server_id").as_deref(), &server, &user_id);
    let _ = config::merge(json!({ "account_key": key }));
    Some(key)
}

/// Make sure the account in use is in the saved list with its token in its
/// own slot, before anything replaces the active token.
fn stash_current() {
    let cfg = config::load();
    let Some(key) = current_key(&cfg) else { return };
    let Some(token) = secret::token() else { return };
    let _ = config::upsert_account(json!({
        "key": key,
        "server": cfg.get("server").cloned().unwrap_or(Value::Null),
        "server_id": cfg.get("server_id").cloned().unwrap_or(Value::Null),
        "server_secure": cfg.get("server_secure").cloned().unwrap_or(Value::Null),
        "user_id": cfg.get("user_id").cloned().unwrap_or(Value::Null),
        "user_name": cfg.get("user_name").cloned().unwrap_or(Value::Null),
    }));
    // After the entry exists: without a keyring the token is filed in it.
    if let Err(e) = secret::store_account(&key, &token) {
        crate::debug_log_line(&format!("server: couldn't keep the current account's token: {}", e));
    }
}

/// Servers this device has signed in to, newest first, for the sign-in
/// screen. Kept apart from the accounts so a server stays offered after its
/// last account is signed out.
fn remember_server(server: &str, name: Option<&str>) {
    let cfg = config::load();
    let mut list: Vec<Value> = cfg
        .get("known_servers")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|s| s.get("server").and_then(|v| v.as_str()) != Some(server))
        .collect();
    list.insert(0, json!({ "server": server, "name": name }));
    list.truncate(8);
    let _ = config::merge(json!({ "known_servers": list }));
}

/// Every account on this device, the one in use marked `current`. Tokens are
/// left out; the webview only learns that an account exists.
pub fn accounts() -> Value {
    let cfg = config::load();
    let current = current_key(&cfg);
    // The account in use is always on the list, including on an install that
    // signed in before there was a list.
    if let Some(key) = &current {
        if !config::accounts().iter().any(|a| a.get("key").and_then(|v| v.as_str()) == Some(key)) {
            stash_current();
        }
    }
    let list: Vec<Value> = config::accounts()
        .into_iter()
        .map(|mut a| {
            let is_current = a.get("key").and_then(|v| v.as_str()) == current.as_deref();
            if let Some(obj) = a.as_object_mut() {
                obj.remove("token");
                obj.insert("current".into(), json!(is_current));
            }
            a
        })
        .collect();
    json!(list)
}

/// Become another of this device's accounts. Nothing is revoked: the one being
/// left keeps its token in its own slot, which is the whole of what makes
/// coming back to it a click.
pub fn switch_account(key: &str) -> Result<Value, String> {
    let cfg = config::load();
    if current_key(&cfg).as_deref() == Some(key) {
        return Ok(json!({ "switched": false }));
    }
    let target = config::accounts()
        .into_iter()
        .find(|a| a.get("key").and_then(|v| v.as_str()) == Some(key))
        .ok_or_else(|| err("config", "That account isn't on this device any more"))?;
    let server = normalize(str_field(&target, "server").as_deref().unwrap_or_default())?;
    let Some(token) = secret::account_token(key) else {
        // Its token has gone, so the only way back in is to sign in again.
        secret::clear_account(key);
        let _ = config::remove_account(key);
        return Err(err("auth", "That account's sign-in has gone from this device — sign in to it again"));
    };
    stash_current();
    secret::store(&token)?;
    config::merge(json!({
        "server": server,
        "server_id": target.get("server_id").cloned().unwrap_or(Value::Null),
        "server_secure": is_secure(&server),
        "user_id": target.get("user_id").cloned().unwrap_or(Value::Null),
        "user_name": target.get("user_name").cloned().unwrap_or(Value::Null),
        "account_key": key,
    }))?;
    // The next request checks the pinned identity of *this* account's server.
    forget_verification();
    Ok(json!({ "switched": true }))
}

/// Sign one of the *other* accounts out of this device: its token revoked on
/// its own server, with its own token, and gone from the keyring and the list.
/// The account in use is signed out with `logout()` instead.
pub async fn forget_account(key: &str) -> Result<Value, String> {
    let cfg = config::load();
    if current_key(&cfg).as_deref() == Some(key) {
        return Err(err("config", "That's the account in use — sign out of it instead"));
    }
    let target = config::accounts()
        .into_iter()
        .find(|a| a.get("key").and_then(|v| v.as_str()) == Some(key));
    let mut revoked = true;
    if let (Some(token), Some(server)) = (
        secret::account_token(key),
        target.as_ref().and_then(|t| str_field(t, "server")),
    ) {
        revoked = revoke(&server, &token, &config::device_id()).await;
    }
    secret::clear_account(key);
    config::remove_account(key)?;
    Ok(json!({ "revoked": revoked }))
}

// ---------- Before signing in ----------

/// The unauthenticated calls the sign-in screen makes to a server it has
/// probed: who is on it, and the Quick Connect exchange. Only these paths, so
/// the command can't be turned into a general fetch-anything.
pub async fn public_request(raw_server: &str, path: &str, method: Option<String>) -> Result<Value, String> {
    const ALLOWED: [&str; 4] = [
        "/QuickConnect/Enabled",
        "/QuickConnect/Initiate",
        "/QuickConnect/Connect?secret=",
        "/Users/Public",
    ];
    if !ALLOWED.iter().any(|p| path == *p || (p.ends_with('=') && path.starts_with(p))) {
        return Err(err("config", "Not a public path"));
    }
    let server = normalize(raw_server)?;
    let method = method.unwrap_or_else(|| "GET".into());
    let verb = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|_| err("config", format!("Unsupported method {}", method)))?;
    let resp = jellyfin::http()
        .request(verb, format!("{}{}", server, path))
        .header("Authorization", jellyfin::auth_header_anon(&config::device_id()))
        .timeout(PROBE_TIMEOUT)
        .send()
        .await
        .map_err(|e| offline_err(&e))?;
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    let parsed: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    Ok(json!({ "status": status, "body": parsed }))
}

/// Ask the server to invalidate a token. `true` means it is definitely dead —
/// a 401 counts, since that's what an already-revoked token answers.
async fn revoke(server: &str, token: &str, device_id: &str) -> bool {
    for attempt in 0..3u32 {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_millis(400 * 2u64.pow(attempt))).await;
        }
        match jellyfin::post(server, token, device_id, "/Sessions/Logout", &json!({})).await {
            Ok(status) if status.is_success() || status.as_u16() == 401 => return true,
            Ok(status) => {
                crate::debug_log_line(&format!("server: logout returned {}", status.as_u16()))
            }
            Err(e) => crate::debug_log_line(&format!("server: logout failed: {}", e)),
        }
    }
    false
}

/// Sign out, and make sure the token is actually dead on the server.
///
/// The old path fired `/Sessions/Logout` best-effort and dropped the local copy
/// regardless. If that call failed — which is exactly what happens when someone
/// signs out *because* they think they've been compromised — the token stayed
/// valid on the server indefinitely, with the only copy of it now deleted. The
/// token is parked in the keyring instead and retried, here and at every
/// launch, until the server confirms it's gone.
pub async fn logout() -> Result<Value, String> {
    let cfg = config::load();
    let server = cfg
        .get("server")
        .and_then(|v| v.as_str())
        .map(str::to_owned)
        .unwrap_or_default();
    let device_id = config::device_id();
    let token = secret::token();

    let mut revoked = true;
    let mut parked = false;
    if let (Some(tok), false) = (token.as_deref(), server.is_empty()) {
        revoked = revoke(&server, tok, &device_id).await;
        if !revoked {
            parked = secret::park_pending_revocation(tok, &server, &device_id).is_ok();
        }
    }

    // Local teardown happens either way: the user asked to be signed out.
    secret::clear();
    forget_verification();
    // Signing out of the account in use takes it off this device's list too:
    // the only way back into it is to sign in again.
    if let Some(key) = current_key(&cfg) {
        secret::clear_account(&key);
        let _ = config::remove_account(&key);
    }
    config::merge(json!({ "user_id": null, "user_name": null, "account_key": null }))?;
    crate::mpv::remove_logs();

    Ok(json!({ "revoked": revoked, "pending": parked }))
}

/// Retry a revocation left over from a sign-out that couldn't reach the server.
/// Runs once at startup; gives up quietly while still offline and tries again
/// next launch.
pub async fn retry_pending_revocation() {
    let Some(pending) = secret::pending_revocation() else { return };
    let (Some(token), Some(server)) = (str_field(&pending, "token"), str_field(&pending, "server"))
    else {
        secret::clear_pending_revocation();
        return;
    };
    let device_id = str_field(&pending, "device_id").unwrap_or_else(config::device_id);
    if revoke(&server, &token, &device_id).await {
        crate::debug_log_line("server: pending token revocation completed");
        secret::clear_pending_revocation();
    }
}

/// Whether a sign-out is still waiting to be confirmed by the server, for the
/// Settings readout.
pub fn revocation_pending() -> bool {
    secret::pending_revocation().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kind_of(e: &str) -> &str {
        e.split('|').next().unwrap_or("")
    }

    #[test]
    fn same_origin_accepts_only_the_exact_server() {
        let server = "https://jf.example.com";
        assert!(same_origin("https://jf.example.com/Items/1/Download", server));
        assert!(same_origin("https://JF.example.com:443/x", server));
        assert!(same_origin("https://example.com/x", "https://example.com/jellyfin"));
        // The prefix tricks a `starts_with` check lets through.
        assert!(!same_origin("https://jf.example.com.evil.net/x", server));
        assert!(!same_origin("https://jf.example.com@evil.net/x", server));
        assert!(!same_origin("https://jf.example.com:8920/x", server));
        // Same host, weaker scheme: the token would cross the network in clear.
        assert!(!same_origin("http://jf.example.com/x", server));
        // Read differently by this parser and by FFmpeg.
        assert!(!same_origin("https://jf.example.com\\@evil.net/x", server));
        assert!(!same_origin("https://jf.example.com/x\n", server));
        assert!(!same_origin("/home/me/film.mkv", server));
    }

    #[test]
    fn keeps_ordinary_addresses_intact() {
        assert_eq!(normalize("http://192.168.1.10:8096").unwrap(), "http://192.168.1.10:8096");
        assert_eq!(normalize("https://jf.example.com").unwrap(), "https://jf.example.com");
        // Trailing slashes and sub-paths: the path survives, the slash doesn't.
        assert_eq!(normalize("https://example.com/jellyfin/").unwrap(), "https://example.com/jellyfin");
        assert_eq!(normalize("  http://example.com/  ").unwrap(), "http://example.com");
        // Default ports are implied, not repeated.
        assert_eq!(normalize("https://example.com:443").unwrap(), "https://example.com");
    }

    #[test]
    fn strips_query_and_fragment() {
        assert_eq!(
            normalize("https://example.com/jf?api_key=leaked#x").unwrap(),
            "https://example.com/jf"
        );
    }

    #[test]
    fn rejects_non_http_schemes() {
        for bad in ["file:///etc/passwd", "ftp://example.com", "javascript:alert(1)"] {
            let e = normalize(bad).unwrap_err();
            assert_eq!(kind_of(&e), "config", "{} should be rejected", bad);
        }
    }

    #[test]
    fn rejects_credentials_in_the_url() {
        // Would otherwise be sent to the host as basic auth on every request.
        assert!(normalize("http://user:pw@example.com").is_err());
        assert!(normalize("http://user@example.com").is_err());
    }

    /// A bare hostname must be tried over TLS *first*, and only fall back to
    /// plaintext — the old code went straight to http:// with the password in
    /// the body. The stand-in server here speaks plain HTTP, so the https
    /// attempt fails its handshake and the http one answers.
    #[tokio::test]
    async fn prefers_https_then_falls_back_and_reports_it() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0u8; 2048];
                let _ = sock.read(&mut buf).await;
                let body = r#"{"Id":"server-abc","ServerName":"Fake","Version":"10.9.0"}"#;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.shutdown().await;
            }
        });

        let out = probe(&format!("127.0.0.1:{}", port)).await.unwrap();
        assert_eq!(out["server"], json!(format!("http://127.0.0.1:{}", port)));
        assert_eq!(out["secure"], json!(false));
        assert_eq!(out["server_id"], json!("server-abc"));
    }

    #[test]
    fn rejects_empty_and_hostless() {
        assert!(normalize("").is_err());
        assert!(normalize("   ").is_err());
        assert!(normalize("http://").is_err());
        // A bare hostname has no scheme — probe() adds one, normalize doesn't.
        assert!(normalize("example.com").is_err());
    }

    // ---------- With a stand-in server ----------

    use crate::test_support::{sandbox, sign_in, FakeServer, Req, Resp, FAKE_SERVER_ID, TEST_TOKEN, TEST_USER};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    const INFO: &str = "/System/Info/Public";

    fn auth_reply(token: &str, user_id: &str, name: &str) -> Value {
        json!({ "AccessToken": token, "User": { "Id": user_id, "Name": name } })
    }

    /// A Jellyfin that signs anyone in as `user_id` with `token`, accepts a
    /// logout, and answers everything else with `{"ok": true}`.
    fn signing_server(id: &str, token: &'static str, user_id: &'static str) -> FakeServer {
        FakeServer::jellyfin_with_id(Some(id), move |req| match req.path() {
            "/Users/AuthenticateByName" | "/Users/AuthenticateWithQuickConnect" => {
                Resp::json(200, auth_reply(token, user_id, "Ann"))
            }
            "/Sessions/Logout" => Resp::status(204),
            _ => Resp::json(200, json!({ "ok": true })),
        })
    }

    fn info_count(server: &FakeServer) -> usize {
        server.requests_to(INFO).len()
    }

    fn token_in(req: &Req) -> Option<String> {
        let h = req.header("authorization")?;
        let start = h.find("Token=\"")? + 7;
        Some(h[start..].split('"').next()?.to_string())
    }

    #[test]
    fn only_https_counts_as_secure() {
        assert!(is_secure("https://jf.example.com"));
        assert!(!is_secure("http://jf.example.com"));
        assert!(!is_secure("httpsx://jf.example.com"));
    }

    #[test]
    fn normalize_keeps_a_non_default_port_and_a_sub_path() {
        assert_eq!(normalize("https://jf.example.com:8920/media/jf/").unwrap(), "https://jf.example.com:8920/media/jf");
        assert_eq!(normalize("HTTP://JF.Example.com").unwrap(), "http://jf.example.com");
    }

    #[test]
    fn empty_strings_count_as_missing_fields() {
        let v = json!({ "a": "x", "b": "", "c": 3 });
        assert_eq!(str_field(&v, "a").as_deref(), Some("x"));
        assert_eq!(str_field(&v, "b"), None);
        assert_eq!(str_field(&v, "c"), None);
        assert_eq!(str_field(&v, "d"), None);
    }

    #[tokio::test]
    async fn probe_with_a_scheme_asks_only_that_address_and_reports_the_server() {
        let _s = sandbox();
        let server = FakeServer::bare();
        let out = probe(&format!("  {}/  ", server.url)).await.unwrap();
        assert_eq!(out["server"], json!(server.url));
        assert_eq!(out["secure"], json!(false));
        assert_eq!(out["server_id"], json!(FAKE_SERVER_ID));
        assert_eq!(out["server_name"], json!("Fake"));
        assert_eq!(out["version"], json!("10.10.0"));
        assert_eq!(server.requests().len(), 1);
    }

    #[tokio::test]
    async fn probe_reports_empty_or_missing_identity_fields_as_null() {
        let _s = sandbox();
        let server = FakeServer::start(|_| Resp::json(200, json!({ "Id": "", "ServerName": "" })));
        let out = probe(&server.url).await.unwrap();
        assert_eq!(out["server_id"], Value::Null);
        assert_eq!(out["server_name"], Value::Null);
        assert_eq!(out["version"], Value::Null);
    }

    #[tokio::test]
    async fn probe_of_an_address_nobody_answers_is_offline_and_logged() {
        let _s = sandbox();
        let dead = FakeServer::dead_url();
        let e = probe(&dead).await.unwrap_err();
        assert_eq!(kind_of(&e), "offline");
        // Without a scheme both https and http are tried; both fail the same way.
        let e = probe(dead.trim_start_matches("http://")).await.unwrap_err();
        assert_eq!(kind_of(&e), "offline");
        assert!(crate::test_support::debug_log().contains("server: request failed"));
    }

    #[tokio::test]
    async fn probe_of_something_that_is_not_jellyfin_is_a_server_error() {
        let _s = sandbox();
        let html = FakeServer::start(|_| Resp::bytes(200, "text/html", b"<html>router</html>".to_vec()));
        let e = probe(&html.url).await.unwrap_err();
        assert_eq!(kind_of(&e), "server");
        assert!(e.contains("not like a Jellyfin server"), "{e}");

        let broken = FakeServer::start(|_| Resp::status(500));
        let e = probe(&broken.url).await.unwrap_err();
        assert_eq!(e, "server|Server responded with 500");
    }

    #[tokio::test]
    async fn probe_refuses_a_bad_address_before_touching_the_network() {
        let _s = sandbox();
        for bad in ["", "   ", "http://user:pw@example.com", "https://"] {
            assert_eq!(kind_of(&probe(bad).await.unwrap_err()), "config", "{bad:?}");
        }
    }

    #[tokio::test]
    async fn probe_refuses_a_typed_non_http_scheme_as_a_config_error() {
        let _s = sandbox();
        // Regression: "file:///etc/passwd" became https://file///etc/passwd,
        // a DNS lookup of "file" and "you appear to be offline".
        for bad in ["file:///etc/passwd", "ftp://example.com/x"] {
            let e = probe(bad).await.unwrap_err();
            assert_eq!(kind_of(&e), "config", "{bad:?}: {e}");
        }
    }

    // ---------- Identity pinning ----------

    #[tokio::test]
    async fn the_first_check_pins_the_servers_id() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        assert!(config::load().get("server_id").is_none());
        request("/Items", None, None).await.unwrap();
        assert_eq!(config::load()["server_id"], json!(FAKE_SERVER_ID));
    }

    #[tokio::test]
    async fn a_server_answering_as_another_install_never_gets_the_token() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        config::merge(json!({ "server_id": "the-one-signed-in-to" })).unwrap();
        let e = request("/Items", None, None).await.unwrap_err();
        assert_eq!(kind_of(&e), "identity");
        // Only the unauthenticated identity check went out.
        let seen = server.requests();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].path(), INFO);
        assert!(token_in(&seen[0]).is_none());
        // And the pin is not overwritten by the impostor's id.
        assert_eq!(config::load()["server_id"], json!("the-one-signed-in-to"));
        assert!(crate::test_support::debug_log().contains("identity mismatch"));
    }

    #[tokio::test]
    async fn the_identity_is_checked_once_per_session() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        ensure_verified(&server.url).await.unwrap();
        request("/a", None, None).await.unwrap();
        request("/b", None, None).await.unwrap();
        assert_eq!(info_count(&server), 1);
    }

    #[tokio::test]
    async fn a_server_that_reports_no_id_is_let_through_and_nothing_is_pinned() {
        let _s = sandbox();
        let server = FakeServer::jellyfin_with_id(None, |_| Resp::json(200, json!({})));
        sign_in(&server.url);
        request("/Items", None, None).await.unwrap();
        assert!(config::load().get("server_id").is_none());
    }

    // ---------- request ----------

    #[tokio::test]
    async fn requests_carry_the_mediabrowser_header_and_never_x_emby_token() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        request("/UserViews?userId=user-1", None, None).await.unwrap();
        let req = server.requests_to("/UserViews").pop().expect("request reached the server");
        assert_eq!(req.method, "GET");
        let auth = req.header("authorization").expect("Authorization header");
        assert!(auth.starts_with("MediaBrowser Client=\"Aquarium\""), "{auth}");
        assert!(auth.contains(&format!("DeviceId=\"{}\"", config::device_id())), "{auth}");
        assert_eq!(token_in(&req).as_deref(), Some(TEST_TOKEN));
        assert!(req.header("x-emby-token").is_none());
        assert!(!req.target.to_ascii_lowercase().contains("api_key"));
        assert_eq!(req.query(), "userId=user-1");
    }

    #[test]
    fn without_token_drops_api_key_parameters_and_blanks_the_token_elsewhere() {
        let t = "0123abcd";
        assert_eq!(without_token("/v/master.m3u8?A=1&ApiKey=0123abcd&B=2", t), "/v/master.m3u8?A=1&B=2");
        assert_eq!(without_token("/v/master.m3u8?A=1&ApiKey=0123abcd", t), "/v/master.m3u8?A=1");
        assert_eq!(without_token("/s/Stream.srt?ApiKey=0123abcd", t), "/s/Stream.srt");
        assert_eq!(without_token("/s/Stream.srt?api_key=0123abcd&x=1", t), "/s/Stream.srt?x=1");
        assert_eq!(without_token(r#"{"Other":"0123abcd"}"#, t), r#"{"Other":""}"#);
        assert_eq!(without_token("nothing here", t), "nothing here");
        assert_eq!(without_token("nothing here", ""), "nothing here");
    }

    #[tokio::test]
    async fn replies_reach_the_webview_without_the_access_token() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|_| {
            Resp::json(
                200,
                json!({ "MediaSources": [{
                    "TranscodingUrl": format!("/videos/1/master.m3u8?MediaSourceId=1&ApiKey={TEST_TOKEN}&Tag=t"),
                    "MediaStreams": [{ "DeliveryUrl": format!("/Videos/1/1/Subtitles/3/0/Stream.srt?ApiKey={TEST_TOKEN}") }],
                }] }),
            )
        });
        sign_in(&server.url);
        let out = request("/Items/1/PlaybackInfo", Some("POST".into()), Some(json!({}))).await.unwrap();
        assert!(!out.to_string().contains(TEST_TOKEN), "{out}");
        let ms = &out["body"]["MediaSources"][0];
        assert_eq!(ms["TranscodingUrl"], json!("/videos/1/master.m3u8?MediaSourceId=1&Tag=t"));
        assert_eq!(ms["MediaStreams"][0]["DeliveryUrl"], json!("/Videos/1/1/Subtitles/3/0/Stream.srt"));
    }

    #[tokio::test]
    async fn requests_send_json_bodies_and_hand_back_status_and_body() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| {
            Resp::json(201, json!({ "method": req.method, "got": req.json(), "type": req.header("content-type") }))
        });
        sign_in(&server.url);
        let out = request("/Items/1/Favorite", Some("POST".into()), Some(json!({ "a": 1 }))).await.unwrap();
        assert_eq!(out["status"], json!(201));
        assert_eq!(out["body"]["method"], json!("POST"));
        assert_eq!(out["body"]["got"], json!({ "a": 1 }));
        assert_eq!(out["body"]["type"], json!("application/json"));
    }

    #[tokio::test]
    async fn an_empty_or_unreadable_reply_has_a_null_body_and_errors_are_returned_not_raised() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/empty" => Resp::status(204),
            "/text" => Resp::bytes(200, "text/plain", b"hello".to_vec()),
            _ => Resp::bytes(500, "text/plain", b"   ".to_vec()),
        });
        sign_in(&server.url);
        assert_eq!(request("/empty", None, None).await.unwrap(), json!({ "status": 204, "body": null }));
        assert_eq!(request("/text", None, None).await.unwrap(), json!({ "status": 200, "body": null }));
        assert_eq!(request("/boom", None, None).await.unwrap(), json!({ "status": 500, "body": null }));
    }

    #[tokio::test]
    async fn request_refuses_bad_input_with_a_config_error_before_the_network() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        assert_eq!(kind_of(&request("Items", None, None).await.unwrap_err()), "config");
        assert_eq!(server.requests().len(), 0);
        let e = request("/Items", Some("NOT A METHOD".into()), None).await.unwrap_err();
        assert!(e.starts_with("config|Unsupported method"), "{e}");
    }

    #[tokio::test]
    async fn request_without_a_server_is_a_config_error() {
        let _s = sandbox();
        assert_eq!(request("/Items", None, None).await.unwrap_err(), "config|Not connected to a server");
        config::merge(json!({ "server": "" })).unwrap();
        assert_eq!(kind_of(&request("/Items", None, None).await.unwrap_err()), "config");
    }

    /// config.json is a plain file; a `server` value rewritten to something
    /// that isn't an http(s) origin must not be sent the token.
    #[tokio::test]
    async fn a_tampered_server_address_in_the_config_is_refused() {
        let _s = sandbox();
        sign_in("file:///etc/passwd");
        assert_eq!(kind_of(&request("/Items", None, None).await.unwrap_err()), "config");
        config::merge(json!({ "server": "http://me:pw@127.0.0.1:1" })).unwrap();
        assert_eq!(kind_of(&request("/Items", None, None).await.unwrap_err()), "config");
        assert!(!is_session_origin("http://127.0.0.1:1/x"));
    }

    #[tokio::test]
    async fn request_without_a_token_is_an_auth_error() {
        let _s = sandbox();
        let server = FakeServer::bare();
        config::merge(json!({ "server": server.url })).unwrap();
        assert_eq!(request("/Items", None, None).await.unwrap_err(), "auth|Not signed in");
    }

    #[tokio::test]
    async fn request_to_a_server_that_is_gone_is_offline() {
        let _s = sandbox();
        sign_in(&FakeServer::dead_url());
        assert_eq!(kind_of(&request("/Items", None, None).await.unwrap_err()), "offline");
    }

    #[tokio::test]
    async fn session_origin_is_the_configured_server_only() {
        let _s = sandbox();
        assert!(!is_session_origin("http://127.0.0.1:8096/x"), "nothing configured");
        sign_in("https://jf.example.com/jellyfin");
        assert!(is_session_origin("https://jf.example.com/Items/1/Download"));
        assert!(!is_session_origin("http://jf.example.com/Items/1/Download"));
        assert!(!is_session_origin("https://jf.example.com.evil.net/x"));
    }

    // ---------- get_bytes, image, bitrate_test ----------

    #[tokio::test]
    async fn get_bytes_hands_back_the_body_and_fails_on_anything_but_2xx() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/sub.srt" => Resp::bytes(200, "text/plain", b"1\n00:00:01,000 --> 00:00:02,000\nHi\n".to_vec()),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        let bytes = get_bytes("/sub.srt").await.unwrap();
        assert!(bytes.ends_with(b"Hi\n"));
        assert_eq!(token_in(&server.requests_to("/sub.srt")[0]).as_deref(), Some(TEST_TOKEN));
        assert_eq!(get_bytes("/missing").await.unwrap_err(), "server|Request failed (404)");
        assert_eq!(kind_of(&get_bytes("sub.srt").await.unwrap_err()), "config");
    }

    #[test]
    fn base64_matches_the_standard_test_vectors() {
        // RFC 4648, section 10.
        for (plain, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(plain.as_bytes()), encoded);
        }
        assert_eq!(base64(&[0xFF, 0xFE, 0xFD, 0x00]), "//79AA==");
    }

    #[tokio::test]
    async fn an_image_comes_back_as_a_data_url_of_the_servers_type() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/t/0.png" => Resp::bytes(200, "image/PNG; charset=binary", b"foo".to_vec()),
            "/t/0.jpg" => Resp::bytes(200, "application/octet-stream", b"foob".to_vec()),
            "/t/0.webp" => Resp::status(200).header("X-None", "1"),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        assert_eq!(image("/t/0.png").await.unwrap(), "data:image/png;base64,Zm9v");
        // A type that isn't an image's is not passed on.
        assert_eq!(image("/t/0.jpg?fillWidth=320").await.unwrap(), "data:image/jpeg;base64,Zm9vYg==");
        assert_eq!(image("/t/0.webp").await.unwrap(), "data:image/jpeg;base64,");
        assert_eq!(token_in(&server.requests_to("/t/0.png")[0]).as_deref(), Some(TEST_TOKEN));
        // A title with no trickplay 404s, as a server error.
        assert_eq!(image("/t/1.jpg").await.unwrap_err(), "server|Image request failed (404)");
    }

    #[tokio::test]
    async fn image_only_fetches_image_paths() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        for bad in ["/Users/Me", "/Items/1?fake=.jpg", "t/0.jpg", "/t/0.jpg.json"] {
            assert_eq!(kind_of(&image(bad).await.unwrap_err()), "config", "{bad}");
        }
        assert_eq!(server.requests().len(), 0);
    }

    #[tokio::test]
    async fn an_image_over_eight_megabytes_is_refused() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|_| Resp::bytes(200, "image/jpeg", vec![0u8; (8 << 20) + 1]));
        sign_in(&server.url);
        assert_eq!(image("/big.jpg").await.unwrap_err(), "server|Image too large");
    }

    #[tokio::test]
    async fn the_bitrate_test_measures_the_body_in_bits_per_second() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.query() {
            "Size=65536" => Resp::bytes(200, "application/octet-stream", vec![7u8; 65536]),
            "Size=1" => Resp::bytes(200, "application/octet-stream", Vec::new()),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        let bps = bitrate_test(65536).await.unwrap();
        assert!(bps > 0.0 && bps.is_finite(), "{bps}");
        let asked = server.requests_to("/Playback/BitrateTest");
        assert_eq!(token_in(&asked[0]).as_deref(), Some(TEST_TOKEN));
        assert_eq!(bitrate_test(1).await.unwrap_err(), "server|Bitrate test returned nothing");
        assert_eq!(bitrate_test(2).await.unwrap_err(), "server|Bitrate test failed (404)");
    }

    // ---------- warm ----------

    #[tokio::test]
    async fn warm_only_touches_streams_on_the_signed_in_server() {
        let _s = sandbox();
        let ours = FakeServer::bare();
        let other = FakeServer::bare();
        sign_in(&ours.url);
        let e = warm(&format!("{}/Videos/1/stream", other.url)).await.unwrap_err();
        assert_eq!(e, "config|Not a stream on this server");
        // The prefix check includes the slash: a port with one more digit is
        // another server.
        let e = warm(&format!("{}0/Videos/1/stream", ours.url)).await.unwrap_err();
        assert_eq!(kind_of(&e), "config");
        assert_eq!(other.requests().len(), 0);
    }

    #[tokio::test]
    async fn warm_reads_only_the_start_of_a_file() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|_| Resp::bytes(200, "video/x-matroska", vec![1u8; 4096]));
        sign_in(&server.url);
        warm(&format!("{}/Videos/1/stream.mkv?static=true", server.url)).await.unwrap();
        let asked = server.requests_to("/Videos/1/stream.mkv");
        assert_eq!(asked.len(), 2);
        assert_eq!(asked[0].header("range"), None);
        assert_eq!(asked[1].header("range"), Some("bytes=0-524287"));
        assert!(asked.iter().all(|r| token_in(r).as_deref() == Some(TEST_TOKEN)));
    }

    #[tokio::test]
    async fn warm_opens_the_variant_playlist_that_starts_the_transcode() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/Videos/1/master.m3u8" => Resp::bytes(
                200,
                "text/plain",
                b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n\n  main.m3u8?PlaySessionId=p  \n".to_vec(),
            ),
            // Recognised by its type when the path doesn't say.
            "/Videos/2/master" => Resp::bytes(200, "application/vnd.apple.mpegURL", b"#EXTM3U\nvariant/two.m3u8\n".to_vec()),
            _ => Resp::bytes(200, "application/vnd.apple.mpegurl", b"#EXTM3U\n".to_vec()),
        });
        sign_in(&server.url);
        warm(&format!("{}/Videos/1/master.m3u8?x=1", server.url)).await.unwrap();
        let variant = server.requests_to("/Videos/1/main.m3u8");
        assert_eq!(variant.len(), 1);
        assert_eq!(variant[0].query(), "PlaySessionId=p");
        assert_eq!(token_in(&variant[0]).as_deref(), Some(TEST_TOKEN));

        warm(&format!("{}/Videos/2/master", server.url)).await.unwrap();
        assert_eq!(server.requests_to("/Videos/2/variant/two.m3u8").len(), 1);
        // A playlist is never read with a Range.
        assert!(server.requests().iter().all(|r| r.header("range").is_none()));
    }

    #[tokio::test]
    async fn warm_never_follows_a_playlist_to_another_server() {
        let _s = sandbox();
        let other = FakeServer::bare();
        let other_url = other.url.clone();
        let server = FakeServer::jellyfin(move |_| {
            Resp::bytes(200, "application/x-mpegurl", format!("#EXTM3U\n{other_url}/steal.m3u8\n").into_bytes())
        });
        sign_in(&server.url);
        warm(&format!("{}/Videos/1/master.m3u8", server.url)).await.unwrap();
        assert_eq!(other.requests().len(), 0);
    }

    // ---------- ping ----------

    #[tokio::test]
    async fn ping_is_true_for_a_reachable_server_of_the_right_identity() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        assert_eq!(ping().await, Ok(true));
        assert_eq!(config::load()["server_id"], json!(FAKE_SERVER_ID));
    }

    /// The seconds after a wake or a Wi-Fi hand-off fail instantly, and one
    /// such failure used to put the app in offline mode.
    #[tokio::test]
    async fn ping_asks_again_after_a_failure_that_came_back_at_once() {
        let _s = sandbox();
        let calls = Arc::new(AtomicUsize::new(0));
        let c = calls.clone();
        let server = FakeServer::start(move |req| {
            if req.path() == INFO && c.fetch_add(1, Ordering::SeqCst) == 0 {
                return Resp::status(503);
            }
            Resp::json(200, json!({ "Id": FAKE_SERVER_ID }))
        });
        sign_in(&server.url);
        assert_eq!(ping().await, Ok(true));
        assert_eq!(info_count(&server), 2);
    }

    /// Ping decides "offline", and the Retry button's answer has to come from
    /// the network rather than from having once seen the server.
    #[tokio::test]
    async fn ping_is_never_answered_from_the_verification_cache() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        request("/Items", None, None).await.unwrap();
        server.set_handler(|_| Resp::status(503));
        server.forget_requests();
        assert_eq!(ping().await, Ok(false));
        // Three quick failures, three attempts.
        assert_eq!(info_count(&server), 3);
    }

    #[tokio::test]
    async fn ping_of_an_unreachable_server_is_false_not_an_error() {
        let _s = sandbox();
        sign_in(&FakeServer::dead_url());
        assert_eq!(ping().await, Ok(false));
    }

    /// A failure that took its time is already a wait, and is not repeated.
    #[tokio::test]
    async fn ping_does_not_repeat_a_slow_failure() {
        let _s = sandbox();
        let server = FakeServer::start(|_| {
            std::thread::sleep(std::time::Duration::from_millis(1700));
            Resp::status(502)
        });
        sign_in(&server.url);
        assert_eq!(ping().await, Ok(false));
        assert_eq!(info_count(&server), 1);
    }

    #[tokio::test]
    async fn ping_reports_a_changed_identity_as_an_error() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        config::merge(json!({ "server_id": "someone-else" })).unwrap();
        assert_eq!(kind_of(&ping().await.unwrap_err()), "identity");
        assert_eq!(info_count(&server), 1);
    }

    #[tokio::test]
    async fn ping_without_a_server_is_a_config_error() {
        let _s = sandbox();
        assert_eq!(kind_of(&ping().await.unwrap_err()), "config");
    }

    // ---------- Sign in ----------

    #[tokio::test]
    async fn login_keeps_the_token_here_and_records_who_signed_in_where() {
        let _s = sandbox();
        let server = signing_server("srv-1", "tok-ann", "u-ann");
        let out = login(&server.url, "ann", "pw").await.unwrap();
        // The frontend learns who, not the credential.
        assert!(!out.to_string().contains("tok-ann"));
        assert_eq!(out["server"], json!(server.url));
        assert_eq!(out["secure"], json!(false));
        assert_eq!(out["user_id"], json!("u-ann"));
        assert_eq!(out["user_name"], json!("Ann"));
        assert_eq!(out["device_id"], json!(config::device_id()));
        assert_eq!(out["token_storage"], json!(crate::secret::backend_name()));

        assert_eq!(crate::secret::token().as_deref(), Some("tok-ann"));
        let cfg = config::load();
        assert_eq!(cfg["server"], json!(server.url));
        assert_eq!(cfg["server_id"], json!("srv-1"));
        assert_eq!(cfg["server_secure"], json!(false));
        assert_eq!(cfg["user_id"], json!("u-ann"));
        assert_eq!(cfg["account_key"], json!("srv-1|u-ann"));
        assert_eq!(cfg["known_servers"], json!([{ "server": server.url, "name": "Fake" }]));
        let list = accounts();
        assert_eq!(list.as_array().unwrap().len(), 1);
        assert_eq!(list[0]["key"], json!("srv-1|u-ann"));
        assert_eq!(list[0]["server_name"], json!("Fake"));
        assert_eq!(list[0]["current"], json!(true));
        assert!(!list.to_string().contains("tok-ann"));
    }

    #[tokio::test]
    async fn login_sends_the_credentials_under_the_anonymous_header() {
        let _s = sandbox();
        let server = signing_server("srv-1", "tok-ann", "u-ann");
        login(&server.url, "ann", "secret pw").await.unwrap();
        let req = server.requests_to("/Users/AuthenticateByName").pop().unwrap();
        assert_eq!(req.method, "POST");
        assert_eq!(req.json(), json!({ "Username": "ann", "Pw": "secret pw" }));
        let auth = req.header("authorization").unwrap();
        assert!(auth.starts_with("MediaBrowser Client=\"Aquarium\""), "{auth}");
        assert!(!auth.contains("Token="), "{auth}");
        assert!(req.header("x-emby-token").is_none());
    }

    #[tokio::test]
    async fn sign_in_leaves_the_server_verified_for_the_session() {
        let _s = sandbox();
        let server = signing_server("srv-1", "tok-ann", "u-ann");
        login(&server.url, "ann", "pw").await.unwrap();
        request("/Items", None, None).await.unwrap();
        // The probe's check, and no second one before the first request.
        assert_eq!(info_count(&server), 1);
    }

    #[tokio::test]
    async fn login_failures_say_what_kind_they_are() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.json()["Username"].as_str() {
            Some("wrong") => Resp::status(401),
            Some("broken") => Resp::status(500),
            Some("no-token") => Resp::json(200, json!({ "User": { "Id": "u" } })),
            Some("no-user") => Resp::json(200, json!({ "AccessToken": "t" })),
            _ => Resp::bytes(200, "text/html", b"<html>".to_vec()),
        });
        let try_as = |user: &'static str| {
            let url = server.url.clone();
            async move { login(&url, user, "pw").await.unwrap_err() }
        };
        assert_eq!(try_as("wrong").await, "auth|Invalid username or password");
        assert_eq!(try_as("broken").await, "server|Login failed (500)");
        assert_eq!(try_as("no-token").await, "server|Server issued no access token");
        assert_eq!(try_as("no-user").await, "server|Server returned no user");
        assert_eq!(kind_of(&try_as("garbage").await), "server");
        // None of those left anything behind.
        assert!(crate::secret::token().is_none());
        assert!(config::load().get("user_id").is_none());
        assert_eq!(kind_of(&login(&FakeServer::dead_url(), "a", "b").await.unwrap_err()), "offline");
    }

    #[tokio::test]
    async fn quick_connect_turns_an_approved_code_into_a_session() {
        let _s = sandbox();
        let server = signing_server("srv-1", "tok-qc", "u-qc");
        let out = login_quick_connect(&server.url, "code-123").await.unwrap();
        assert_eq!(out["user_id"], json!("u-qc"));
        assert_eq!(crate::secret::token().as_deref(), Some("tok-qc"));
        let req = server.requests_to("/Users/AuthenticateWithQuickConnect").pop().unwrap();
        assert_eq!(req.json(), json!({ "Secret": "code-123" }));
        assert!(!req.header("authorization").unwrap().contains("Token="));

        let refusing = FakeServer::jellyfin(|_| Resp::status(400));
        let e = login_quick_connect(&refusing.url, "code-123").await.unwrap_err();
        assert_eq!(e, "auth|The server didn't accept that code (400)");
        let garbled = FakeServer::jellyfin(|_| Resp::bytes(200, "text/plain", b"ok".to_vec()));
        assert_eq!(kind_of(&login_quick_connect(&garbled.url, "c").await.unwrap_err()), "server");
    }

    // ---------- Several accounts ----------

    #[test]
    fn an_account_is_keyed_by_the_servers_id_where_it_has_one() {
        assert_eq!(account_key(Some("srv"), "http://a", "u"), "srv|u");
        assert_eq!(account_key(Some(""), "http://a", "u"), "http://a|u");
        assert_eq!(account_key(None, "http://a", "u"), "http://a|u");
    }

    #[test]
    fn known_servers_are_newest_first_without_repeats_and_at_most_eight() {
        let _s = sandbox();
        for i in 0..10 {
            remember_server(&format!("http://s{i}"), Some("S"));
        }
        remember_server("http://s5", None);
        let list = config::load()["known_servers"].as_array().cloned().unwrap();
        let names: Vec<&str> = list.iter().map(|s| s["server"].as_str().unwrap()).collect();
        assert_eq!(names, ["http://s5", "http://s9", "http://s8", "http://s7", "http://s6", "http://s4", "http://s3", "http://s2"]);
        assert_eq!(list[0]["name"], Value::Null);
    }

    #[test]
    fn an_install_from_before_accounts_gets_a_key_and_shows_on_the_list() {
        let _s = sandbox();
        sign_in("http://127.0.0.1:1");
        assert!(config::load().get("account_key").is_none());
        let list = accounts();
        let key = format!("http://127.0.0.1:1|{TEST_USER}");
        assert_eq!(list.as_array().unwrap().len(), 1);
        assert_eq!(list[0]["key"], json!(key));
        assert_eq!(list[0]["current"], json!(true));
        assert_eq!(config::load()["account_key"], json!(key));
        // Its token was filed in its own slot, so switching away and back works.
        assert_eq!(crate::secret::account_token(&key).as_deref(), Some(TEST_TOKEN));
    }

    #[test]
    fn the_account_list_never_carries_a_token() {
        let _s = sandbox();
        config::upsert_account(json!({ "key": "k1", "server": "http://a", "user_id": "u", "token": "file-mode-token" })).unwrap();
        let list = accounts();
        assert_eq!(list[0]["key"], json!("k1"));
        assert_eq!(list[0]["current"], json!(false));
        assert!(list[0].get("token").is_none());
        assert!(!list.to_string().contains("file-mode-token"));
    }

    #[tokio::test]
    async fn a_second_sign_in_keeps_the_first_accounts_token_in_its_own_slot() {
        // Regression: 13ea908 (tokens of saved accounts were dropped where
        // there is no keyring, because the token was filed before the
        // account's entry existed).
        let _s = sandbox();
        let a = signing_server("srv-a", "tok-a", "u-a");
        let b = signing_server("srv-b", "tok-b", "u-b");
        login(&a.url, "a", "pw").await.unwrap();
        login(&b.url, "b", "pw").await.unwrap();
        assert_eq!(crate::secret::token().as_deref(), Some("tok-b"));
        assert_eq!(crate::secret::account_token("srv-a|u-a").as_deref(), Some("tok-a"));
        assert_eq!(crate::secret::account_token("srv-b|u-b").as_deref(), Some("tok-b"));
        let list = accounts();
        let current: Vec<(&str, bool)> = list
            .as_array()
            .unwrap()
            .iter()
            .map(|a| (a["key"].as_str().unwrap(), a["current"].as_bool().unwrap()))
            .collect();
        assert_eq!(current, [("srv-a|u-a", false), ("srv-b|u-b", true)]);
    }

    #[tokio::test]
    async fn switching_accounts_moves_the_token_and_rechecks_the_identity() {
        // Regression: d233f84 (identity pinning follows the account switched to).
        let _s = sandbox();
        let a = signing_server("srv-a", "tok-a", "u-a");
        let b = signing_server("srv-b", "tok-b", "u-b");
        login(&a.url, "a", "pw").await.unwrap();
        login(&b.url, "b", "pw").await.unwrap();

        assert_eq!(switch_account("srv-b|u-b").unwrap(), json!({ "switched": false }));
        assert_eq!(switch_account("srv-a|u-a").unwrap(), json!({ "switched": true }));
        assert_eq!(crate::secret::token().as_deref(), Some("tok-a"));
        let cfg = config::load();
        assert_eq!(cfg["server"], json!(a.url));
        assert_eq!(cfg["server_id"], json!("srv-a"));
        assert_eq!(cfg["user_id"], json!("u-a"));
        assert_eq!(cfg["account_key"], json!("srv-a|u-a"));
        // The account left keeps its token for coming back.
        assert_eq!(crate::secret::account_token("srv-b|u-b").as_deref(), Some("tok-b"));

        // The next request checks A's identity again, rather than trusting B's.
        a.forget_requests();
        request("/Items", None, None).await.unwrap();
        assert_eq!(info_count(&a), 1);
        assert_eq!(token_in(&a.requests_to("/Items")[0]).as_deref(), Some("tok-a"));

        // And an A that now answers as someone else is refused.
        switch_account("srv-b|u-b").unwrap();
        config::upsert_account(json!({ "key": "srv-a|u-a", "server_id": "changed" })).unwrap();
        switch_account("srv-a|u-a").unwrap();
        assert_eq!(kind_of(&request("/Items", None, None).await.unwrap_err()), "identity");
    }

    #[test]
    fn switching_to_an_account_that_is_gone_or_has_no_token_fails() {
        let _s = sandbox();
        sign_in("http://127.0.0.1:1");
        let e = switch_account("nobody").unwrap_err();
        assert_eq!(e, "config|That account isn't on this device any more");
        config::upsert_account(json!({ "key": "srv-x|u-x", "server": "http://127.0.0.1:2", "user_id": "u-x" })).unwrap();
        let e = switch_account("srv-x|u-x").unwrap_err();
        assert_eq!(kind_of(&e), "auth");
        // The only way back is to sign in again, so it leaves the list.
        assert!(config::accounts().iter().all(|a| a["key"] != json!("srv-x|u-x")));
        // Nothing about the account in use changed.
        assert_eq!(crate::secret::token().as_deref(), Some(TEST_TOKEN));
        assert_eq!(config::load()["server"], json!("http://127.0.0.1:1"));
    }

    #[tokio::test]
    async fn forgetting_another_account_revokes_it_on_its_own_server_with_its_own_token() {
        let _s = sandbox();
        let a = signing_server("srv-a", "tok-a", "u-a");
        let b = signing_server("srv-b", "tok-b", "u-b");
        login(&a.url, "a", "pw").await.unwrap();
        login(&b.url, "b", "pw").await.unwrap();

        let e = forget_account("srv-b|u-b").await.unwrap_err();
        assert_eq!(kind_of(&e), "config");

        assert_eq!(forget_account("srv-a|u-a").await.unwrap(), json!({ "revoked": true }));
        let out = a.requests_to("/Sessions/Logout");
        assert_eq!(out.len(), 1);
        assert_eq!(token_in(&out[0]).as_deref(), Some("tok-a"));
        assert!(b.requests_to("/Sessions/Logout").is_empty());
        assert!(crate::secret::account_token("srv-a|u-a").is_none());
        assert!(config::accounts().iter().all(|x| x["key"] != json!("srv-a|u-a")));
        // Still signed in as B.
        assert_eq!(crate::secret::token().as_deref(), Some("tok-b"));

        // An account with no token left has nothing to revoke.
        config::upsert_account(json!({ "key": "gone", "server": a.url })).unwrap();
        assert_eq!(forget_account("gone").await.unwrap(), json!({ "revoked": true }));
    }

    #[tokio::test]
    async fn a_token_the_server_already_refuses_counts_as_revoked() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/Sessions/Logout" => Resp::status(401),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        assert_eq!(logout().await.unwrap(), json!({ "revoked": true, "pending": false }));
        assert_eq!(server.requests_to("/Sessions/Logout").len(), 1);
    }

    // ---------- Before signing in ----------

    #[tokio::test]
    async fn public_requests_reach_only_the_sign_in_screens_paths() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/Users/Public" => Resp::json(200, json!([{ "Name": "Ann" }])),
            "/QuickConnect/Initiate" => Resp::json(200, json!({ "Code": "123456", "Secret": "s" })),
            "/QuickConnect/Enabled" => Resp::bytes(200, "text/plain", b"not json".to_vec()),
            _ => Resp::json(200, json!({ "Authenticated": true })),
        });
        let out = public_request(&server.url, "/Users/Public", None).await.unwrap();
        assert_eq!(out, json!({ "status": 200, "body": [{ "Name": "Ann" }] }));
        let out = public_request(&server.url, "/QuickConnect/Initiate", Some("POST".into())).await.unwrap();
        assert_eq!(out["body"]["Code"], json!("123456"));
        let out = public_request(&server.url, "/QuickConnect/Connect?secret=abc", None).await.unwrap();
        assert_eq!(out["body"]["Authenticated"], json!(true));
        assert_eq!(public_request(&server.url, "/QuickConnect/Enabled", None).await.unwrap()["body"], Value::Null);
        assert_eq!(server.requests_to("/QuickConnect/Initiate")[0].method, "POST");
        for r in server.requests() {
            assert!(!r.header("authorization").unwrap_or("").contains("Token="));
        }

        let before = server.requests().len();
        for bad in ["/Users/Me", "/Users/Public/../Me", "/QuickConnect/Connect", "/QuickConnect/Enabledx", "Users/Public"] {
            assert_eq!(public_request(&server.url, bad, None).await.unwrap_err(), "config|Not a public path", "{bad}");
        }
        assert_eq!(server.requests().len(), before);
        assert_eq!(kind_of(&public_request("ftp://x", "/Users/Public", None).await.unwrap_err()), "config");
        let e = public_request(&server.url, "/Users/Public", Some("BAD VERB".into())).await.unwrap_err();
        assert_eq!(kind_of(&e), "config");
        let e = public_request(&FakeServer::dead_url(), "/Users/Public", None).await.unwrap_err();
        assert_eq!(kind_of(&e), "offline");
    }

    // ---------- Sign out ----------

    #[tokio::test]
    async fn logout_revokes_the_token_and_clears_everything_local() {
        let _s = sandbox();
        let server = signing_server("srv-1", "tok-ann", "u-ann");
        login(&server.url, "ann", "pw").await.unwrap();
        let logs = config::data_dir().join("mpv-logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(logs.join("mpv.log"), "Authorization: token").unwrap();

        assert_eq!(logout().await.unwrap(), json!({ "revoked": true, "pending": false }));
        let out = server.requests_to("/Sessions/Logout");
        assert_eq!(out.len(), 1);
        assert_eq!(token_in(&out[0]).as_deref(), Some("tok-ann"));
        assert!(out[0].header("x-emby-token").is_none());

        assert!(crate::secret::token().is_none());
        assert!(crate::secret::account_token("srv-1|u-ann").is_none());
        let cfg = config::load();
        for gone in ["user_id", "user_name", "account_key"] {
            assert!(cfg.get(gone).is_none(), "{gone} survived sign-out");
        }
        // The server stays offered on the sign-in screen.
        assert_eq!(cfg["server"], json!(server.url));
        assert_eq!(cfg["known_servers"][0]["server"], json!(server.url));
        assert!(config::accounts().is_empty());
        assert!(!logs.exists(), "mpv logs hold the token and go at sign-out");
        assert!(!revocation_pending());

        // The next sign-in checks the server again.
        server.forget_requests();
        sign_in(&server.url);
        request("/Items", None, None).await.unwrap();
        assert_eq!(info_count(&server), 1);
    }

    #[tokio::test]
    async fn a_token_the_server_would_not_revoke_is_parked_and_retried() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/Sessions/Logout" => Resp::status(500),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        let device = config::device_id();
        let out = logout().await.unwrap();
        assert_eq!(out["revoked"], json!(false));
        // Three tries before giving up for now.
        assert_eq!(server.requests_to("/Sessions/Logout").len(), 3);
        // Signed out locally either way.
        assert!(crate::secret::token().is_none());
        assert!(config::load().get("user_id").is_none());
        // Parked where the platform can keep it (the keyring); on Linux
        // without a session bus it can't, and says so.
        assert_eq!(out["pending"], json!(crate::secret::pending_revocation().is_some()));
        if out["pending"] != json!(true) {
            eprintln!("skipped the retry half: no keyring to park the token in");
            return;
        }
        assert!(revocation_pending());
        let parked = crate::secret::pending_revocation().unwrap();
        assert_eq!(parked["token"], json!(TEST_TOKEN));
        assert_eq!(parked["server"], json!(server.url));
        assert_eq!(parked["device_id"], json!(device));

        // Next launch, the server answers: the parked token is revoked under
        // the device id it was issued to, and the record goes.
        server.set_handler(|_| Resp::status(204));
        server.forget_requests();
        config::merge(json!({ "device_id": "a-new-device-id" })).unwrap();
        retry_pending_revocation().await;
        let asked = server.requests_to("/Sessions/Logout");
        assert_eq!(asked.len(), 1);
        assert_eq!(token_in(&asked[0]).as_deref(), Some(TEST_TOKEN));
        assert!(asked[0].header("authorization").unwrap().contains(&format!("DeviceId=\"{device}\"")));
        assert!(!revocation_pending());
        assert!(crate::test_support::debug_log().contains("pending token revocation completed"));
    }

    #[tokio::test]
    async fn a_parked_revocation_waits_while_the_server_is_unreachable() {
        let _s = sandbox();
        if crate::secret::park_pending_revocation("tok", &FakeServer::dead_url(), "dev").is_err() {
            eprintln!("skipped: no keyring to park a token in");
            return;
        }
        retry_pending_revocation().await;
        assert!(revocation_pending());
        assert!(crate::test_support::debug_log().contains("server: logout failed"));
    }

    #[tokio::test]
    async fn a_parked_revocation_with_no_server_is_dropped() {
        let _s = sandbox();
        if crate::secret::park_pending_revocation("tok", "", "dev").is_err() {
            eprintln!("skipped: no keyring to park a token in");
            return;
        }
        assert!(revocation_pending());
        retry_pending_revocation().await;
        assert!(!revocation_pending());
        // Nothing parked: nothing to do.
        retry_pending_revocation().await;
    }

    #[tokio::test]
    async fn logout_with_no_server_or_token_still_signs_out() {
        let _s = sandbox();
        config::merge(json!({ "user_id": "u", "user_name": "n" })).unwrap();
        assert_eq!(logout().await.unwrap(), json!({ "revoked": true, "pending": false }));
        assert!(config::load().get("user_id").is_none());
    }
}

/// Against the live QA Jellyfin (see `test_support::qa`). Each test skips,
/// saying why, when the server or its account isn't there.
#[cfg(test)]
mod qa_tests {
    use super::*;
    use crate::test_support::{qa, sandbox, with_qa_session, QA_DEVICE_ID};
    use std::sync::Arc;

    #[tokio::test]
    async fn signing_in_works_and_signing_out_kills_the_token_on_the_server() {
        let seen: Arc<Mutex<Option<(String, String)>>> = Arc::new(Mutex::new(None));
        let keep = seen.clone();
        with_qa_session(|qa, who| async move {
            assert_eq!(who["user_name"], json!(qa.account.name));
            assert_eq!(who["server"], json!(qa.server));
            assert!(!who.to_string().contains("AccessToken"));
            let token = crate::secret::token().expect("token kept in Rust");
            assert!(!who.to_string().contains(&token));
            let me = request(&format!("/Users/{}", who["user_id"].as_str().unwrap()), None, None).await.unwrap();
            assert_eq!(me["status"], json!(200));
            assert_eq!(me["body"]["Name"], json!(qa.account.name));
            let cfg = config::load();
            assert!(cfg["server_id"].as_str().is_some_and(|s| !s.is_empty()));
            *keep.lock().unwrap() = Some((qa.server.clone(), token));
        })
        .await;
        let Some((server, token)) = seen.lock().unwrap().clone() else { return };
        // with_qa_session signed out and asserted `revoked`; the server agrees.
        let status = jellyfin::http()
            .get(format!("{server}/System/Info"))
            .header("Authorization", jellyfin::auth_header(&token, QA_DEVICE_ID))
            .send()
            .await
            .unwrap()
            .status()
            .as_u16();
        assert_eq!(status, 401, "the signed-out token still works");
    }

    #[tokio::test]
    async fn the_qa_server_answers_probe_ping_and_the_public_calls() {
        with_qa_session(|qa, _who| async move {
            let probed = probe(&qa.server).await.unwrap();
            assert_eq!(probed["server_id"], config::load()["server_id"]);
            assert!(probed["version"].as_str().is_some_and(|v| !v.is_empty()));
            assert_eq!(ping().await, Ok(true));
            let users = public_request(&qa.server, "/Users/Public", None).await.unwrap();
            assert_eq!(users["status"], json!(200));
            assert!(users["body"].is_array());
            let qc = public_request(&qa.server, "/QuickConnect/Enabled", None).await.unwrap();
            assert_eq!(qc["status"], json!(200));
            assert!(qc["body"].is_boolean());
        })
        .await;
    }

    #[tokio::test]
    async fn the_qa_server_serves_bytes_images_bitrate_tests_and_warms_streams() {
        with_qa_session(|qa, _who| async move {
            let info = get_bytes("/System/Info").await.unwrap();
            let info: Value = serde_json::from_slice(&info).unwrap();
            assert!(info["Id"].is_string());
            let bps = bitrate_test(256 * 1024).await.unwrap();
            assert!(bps > 0.0);
            let item = crate::test_support::qa_find_item("Movie", "FX Long Direct Play", "Trickplay")
                .await
                .expect("FX Long Direct Play in the QA library");
            let id = item["Id"].as_str().unwrap();
            let tile = image(&format!("/Videos/{id}/Trickplay/320/0.jpg")).await.unwrap();
            assert!(tile.starts_with("data:image/jpeg;base64,/9j/"), "{}", &tile[..40.min(tile.len())]);
            warm(&format!("{}/Items/{id}/Download", qa.server)).await.unwrap();
        })
        .await;
    }

    /// A made-up account name, so no real account collects a failed attempt.
    #[tokio::test]
    async fn an_unknown_account_is_refused_as_an_auth_error() {
        let _s = sandbox();
        let Some(qa) = qa().await else { return };
        let e = login(&qa.server, "suite-linux-no-such-user", "wrong").await.unwrap_err();
        assert_eq!(e, "auth|Invalid username or password");
        assert!(crate::secret::token().is_none());
    }
}
