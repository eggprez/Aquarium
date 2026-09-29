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
    let has_scheme = typed.starts_with("http://") || typed.starts_with("https://");
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
    let text = resp.text().await.unwrap_or_default();
    let parsed: Option<Value> = if text.trim().is_empty() {
        None
    } else {
        serde_json::from_str(&text).ok()
    };
    Ok(json!({ "status": status, "body": parsed }))
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
    let secure = is_secure(&server);
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

    let token = str_field(&data, "AccessToken")
        .ok_or_else(|| err("server", "Server issued no access token"))?;
    let user_id = data
        .get("User")
        .and_then(|u| str_field(u, "Id"))
        .ok_or_else(|| err("server", "Server returned no user"))?;
    let user_name = data
        .get("User")
        .and_then(|u| str_field(u, "Name"))
        .unwrap_or_default();

    secret::store(&token)?;
    // The identity recorded here is what every later launch is checked against.
    config::merge(json!({
        "server": server,
        "server_id": probed.get("server_id").cloned().unwrap_or(Value::Null),
        "server_secure": secure,
        "user_id": user_id,
        "user_name": user_name,
    }))?;
    *VERIFIED.lock().unwrap() = Some(server.clone());

    Ok(json!({
        "server": server,
        "secure": secure,
        "user_id": user_id,
        "user_name": user_name,
        "device_id": device_id,
        "token_storage": secret::backend_name(),
    }))
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
    config::merge(json!({ "user_id": null, "user_name": null }))?;

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
}
