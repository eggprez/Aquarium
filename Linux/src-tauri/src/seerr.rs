//! The connection to a Seerr server: asking for films and shows the library
//! doesn't have.
//!
//! Seerr sits beside a Jellyfin server and takes requests for it. This is held
//! to the same rules as the connection to Jellyfin (`server.rs`):
//!
//! - No password is kept, and usually none is typed. The app is already signed
//!   in to Jellyfin, so it signs in to Seerr with Quick Connect: Seerr asks
//!   Jellyfin for a code, this install approves the code with its own Jellyfin
//!   session, and Seerr answers with a session of its own. A typed Jellyfin
//!   password is the fallback for a Seerr with no Quick Connect, and it is
//!   sent once and forgotten.
//! - Seerr's administrator API key is never used. It is one key for the whole
//!   server; a client holding it could approve, delete and reconfigure.
//! - What is kept is Seerr's session cookie (with the address and what Seerr
//!   said about the account), in the keyring beside the Jellyfin token, one
//!   item per Jellyfin account (`secret::store_seerr`).
//! - The cookie never crosses the IPC boundary. The webview names a path
//!   (`request`, and only the paths the app uses) and gets a status and a body.
//! - The cookie is put on requests by hand and only on requests to the Seerr
//!   address it came from. The client keeps no cookie store, and a redirect to
//!   anywhere else is not followed.
//! - https first, and a certificate that fails is never retried over http.
//!
//! Seerr's session runs out (thirty days) where Jellyfin's token does not, so
//! a refused request is followed by one quiet Quick Connect and one retry.
//!
//! Errors are `"<kind>|<message>"`, as in `server.rs`. The kinds here:
//! `notconnected`, `unreachable`, `quickconnect` (no Quick Connect to sign in
//! with: the password form is next), `reconnect` (the session ran out and
//! could not be renewed), `refused` (Seerr said no; the message is in plain
//! words) and `message`.

use crate::{jellyfin, secret, server};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::error::Error as StdError;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);
/// Signing out of Jellyfin waits on this, so it is short.
const LOGOUT_TIMEOUT: Duration = Duration::from_secs(5);

const QUICK_CONNECT_UNAVAILABLE: &str =
    "This Seerr server can't sign in with Quick Connect. Use your Jellyfin user name and password instead.";
const NEEDS_RECONNECT: &str = "The connection to Seerr has run out. Reconnect in Settings.";

fn err(kind: &str, msg: impl std::fmt::Display) -> String {
    format!("{}|{}", kind, msg)
}

// ---------- What is kept ----------

/// The Seerr server a Jellyfin account asks through, and the session on it.
/// The whole of it is one keyring item; see `secret::store_seerr`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct Connection {
    /// Scheme, host and any base path; no trailing slash.
    server: String,
    /// The value of Seerr's `connect.sid` cookie.
    cookie: String,
    #[serde(rename = "userId", default)]
    user_id: i64,
    #[serde(rename = "userName", default)]
    user_name: String,
    #[serde(default)]
    permissions: i64,
    /// `/settings/public`, cut down to the keys the app reads.
    #[serde(default)]
    settings: Option<Value>,
}

/// The Jellyfin account in use.
struct Account {
    key: String,
    user_id: String,
    user_name: String,
}

fn account() -> Option<Account> {
    let (key, user_id, user_name) = server::current_account()?;
    Some(Account { key, user_id, user_name })
}

fn read(key: &str) -> Option<Connection> {
    secret::seerr_session(key).and_then(|raw| serde_json::from_str(&raw).ok())
}

fn current() -> Result<(Account, Connection), String> {
    let acct = account().ok_or_else(|| err("notconnected", "Requests aren't set up"))?;
    let conn = read(&acct.key).ok_or_else(|| err("notconnected", "Requests aren't set up"))?;
    Ok((acct, conn))
}

fn store(key: &str, conn: &Connection) -> bool {
    let Ok(raw) = serde_json::to_string(conn) else { return false };
    // Without a keyring the session is filed in the account's entry on the
    // saved list; asking for the list makes sure the account in use is on it.
    let _ = server::accounts();
    match secret::store_seerr(key, &raw) {
        Ok(()) => {
            set_needs_reconnect(key, false);
            true
        }
        Err(e) => {
            crate::debug_log_line(&format!("seerr: the session could not be stored: {}", e));
            false
        }
    }
}

/// The account whose session ran out and could not be renewed quietly.
/// Settings offers to reconnect; everything else behaves as not connected.
static RECONNECT: Mutex<Option<String>> = Mutex::new(None);

fn needs_reconnect(key: &str) -> bool {
    RECONNECT.lock().unwrap_or_else(|p| p.into_inner()).as_deref() == Some(key)
}

fn set_needs_reconnect(key: &str, needed: bool) {
    let mut slot = RECONNECT.lock().unwrap_or_else(|p| p.into_inner());
    if needed {
        *slot = Some(key.to_owned());
    } else if slot.as_deref() == Some(key) {
        *slot = None;
    }
}

/// Test hook: forget everything held in memory.
#[cfg(test)]
pub fn reset_for_tests() {
    *RECONNECT.lock().unwrap_or_else(|p| p.into_inner()) = None;
    *CSRF.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

/// The address without its scheme, for a line in Settings.
fn host(server: &str) -> String {
    server.trim_start_matches("https://").trim_start_matches("http://").to_string()
}

/// What the webview may know: whether there is a connection, to where, as
/// whom and with what rights. Never the cookie.
pub fn status() -> Value {
    let Some(acct) = account() else { return json!({ "connected": false }) };
    let Some(conn) = read(&acct.key) else { return json!({ "connected": false }) };
    json!({
        "connected": true,
        "server": conn.server,
        "host": host(&conn.server),
        "secure": server::is_secure(&conn.server),
        "user_id": conn.user_id,
        "user_name": conn.user_name,
        "permissions": conn.permissions,
        "settings": conn.settings,
        "needs_reconnect": needs_reconnect(&acct.key),
        "storage": secret::backend_name(),
    })
}

// ---------- Transport ----------

static HTTP: OnceLock<reqwest::Client> = OnceLock::new();

fn same_origin(a: &reqwest::Url, b: &reqwest::Url) -> bool {
    a.scheme() == b.scheme() && a.host_str() == b.host_str() && a.port_or_known_default() == b.port_or_known_default()
}

/// The client every Seerr request goes through. It has no cookie store (the
/// one cookie that matters is attached by hand, to one origin), and it follows
/// a redirect only to where the request was already going: a header set by
/// hand is otherwise carried along to wherever the redirect points.
fn http() -> &'static reqwest::Client {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(format!("{}/{}", jellyfin::CLIENT_NAME, jellyfin::CLIENT_VERSION))
            .connect_timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                let hops = attempt.previous().len();
                let same = attempt
                    .previous()
                    .last()
                    .is_some_and(|from| same_origin(from, attempt.url()));
                if same && hops < 5 {
                    attempt.follow()
                } else {
                    attempt.stop()
                }
            }))
            .build()
            .expect("failed to build the Seerr http client")
    })
}

/// Seerr's optional cross-site protection: with it on, every write has to
/// echo a token the server handed out in a cookie. Kept in memory only, for
/// the one server it came from; any read brings a fresh one.
struct Csrf {
    server: String,
    secret: Option<String>,
    token: Option<String>,
}

static CSRF: Mutex<Option<Csrf>> = Mutex::new(None);

fn csrf_for(base: &str) -> (Option<String>, Option<String>) {
    let held = CSRF.lock().unwrap_or_else(|p| p.into_inner());
    match held.as_ref() {
        Some(c) if c.server == base => (c.secret.clone(), c.token.clone()),
        _ => (None, None),
    }
}

fn remember_csrf(base: &str, cookies: &[(String, String)]) {
    let find = |name: &str| cookies.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
    let (secret, token) = (find("_csrf"), find("XSRF-TOKEN"));
    if secret.is_none() && token.is_none() {
        return;
    }
    let mut held = CSRF.lock().unwrap_or_else(|p| p.into_inner());
    let mut next = match held.take() {
        Some(c) if c.server == base => c,
        _ => Csrf { server: base.to_owned(), secret: None, token: None },
    };
    if secret.is_some() {
        next.secret = secret;
    }
    if token.is_some() {
        next.token = token;
    }
    *held = Some(next);
}

fn forget_csrf() {
    *CSRF.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

/// The name and value of one `Set-Cookie` header.
fn cookie_pair(header: &str) -> Option<(String, String)> {
    let first = header.split(';').next()?;
    let (name, value) = first.split_once('=')?;
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    Some((name.to_owned(), value.trim().to_owned()))
}

/// `%41` to `A`. A value that doesn't decode to text is handed back as it was.
fn percent_decode(text: &str) -> String {
    fn hex(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    }
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(hi * 16 + lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// Whether a failed connection failed over the server's certificate. reqwest
/// has no code for it, so the error and its causes are read: rustls words a
/// certificate it won't accept as "invalid peer certificate: ...".
fn names_a_certificate(text: &str) -> bool {
    text.to_ascii_lowercase().contains("certificate")
}

fn is_certificate_failure(e: &reqwest::Error) -> bool {
    let mut text = e.to_string();
    let mut cause = StdError::source(e);
    while let Some(c) = cause {
        text.push_str(" | ");
        text.push_str(&c.to_string());
        cause = c.source();
    }
    names_a_certificate(&text)
}

struct Answer {
    status: u16,
    text: String,
    cookies: Vec<(String, String)>,
}

impl Answer {
    fn json(&self) -> Value {
        if self.text.trim().is_empty() {
            return Value::Null;
        }
        serde_json::from_str(&self.text).unwrap_or(Value::Null)
    }

    fn cookie(&self, name: &str) -> Option<&str> {
        self.cookies.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }
}

enum Failure {
    /// Not something a request can be made to.
    Address,
    /// No HTTP response came back. `certificate`: because the server's
    /// certificate could not be verified.
    Transport { certificate: bool },
}

/// The one place a request to Seerr is made. `path` is below `/api/v1` and
/// already query-encoded.
async fn send(
    base: &str,
    path: &str,
    method: &str,
    body: Option<&Value>,
    cookie: Option<&str>,
    timeout: Duration,
) -> Result<Answer, Failure> {
    if !path.starts_with('/') || path.contains('\\') || path.chars().any(char::is_control) {
        return Err(Failure::Address);
    }
    let origin = reqwest::Url::parse(base).map_err(|_| Failure::Address)?;
    let url = reqwest::Url::parse(&format!("{}/api/v1{}", base, path)).map_err(|_| Failure::Address)?;
    // The cookie goes to the address it came from and nowhere else.
    if !matches!(url.scheme(), "http" | "https") || !same_origin(&origin, &url) {
        return Err(Failure::Address);
    }
    let verb = reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| Failure::Address)?;

    let mut req = http()
        .request(verb, url)
        .header(reqwest::header::ACCEPT, "application/json")
        .timeout(timeout);
    let mut jar: Vec<String> = Vec::new();
    if let Some(c) = cookie.filter(|c| !c.is_empty()) {
        jar.push(format!("connect.sid={}", c));
    }
    if method != "GET" {
        let (secret, token) = csrf_for(base);
        if let Some(secret) = secret {
            jar.push(format!("_csrf={}", secret));
        }
        if let Some(token) = token {
            jar.push(format!("XSRF-TOKEN={}", token));
            req = req.header("X-XSRF-TOKEN", percent_decode(&token));
        }
    }
    if !jar.is_empty() {
        req = req.header(reqwest::header::COOKIE, jar.join("; "));
    }
    if let Some(body) = body {
        req = req.json(body);
    }

    let resp = req.send().await.map_err(|e| {
        // The error can carry the address; never anything that was sent.
        crate::debug_log_line(&format!("seerr: request failed: {}", e));
        Failure::Transport { certificate: is_certificate_failure(&e) }
    })?;
    let status = resp.status().as_u16();
    let cookies: Vec<(String, String)> = resp
        .headers()
        .get_all(reqwest::header::SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .filter_map(cookie_pair)
        .collect();
    remember_csrf(base, &cookies);
    let text = resp.text().await.unwrap_or_default();
    if !(200..300).contains(&status) {
        crate::debug_log_line(&format!(
            "seerr: {} on {}",
            status,
            path.split('?').next().unwrap_or_default()
        ));
    }
    Ok(Answer { status, text, cookies })
}

/// A refusal in words. Seerr's own message is used when it has one worth
/// reading; the common ones are reworded.
pub fn plain_words(status: u16, body: &str) -> String {
    let parsed: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    let said = parsed
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| parsed.get("error").and_then(Value::as_str))
        .unwrap_or_default();
    let lower = said.to_lowercase();
    if lower.contains("quota") {
        return "You've used all your requests for now. More open up as the oldest ones age out.".into();
    }
    if lower.contains("already exists") || status == 409 {
        return "That has already been requested.".into();
    }
    if lower.contains("4k") {
        return "This account can't request 4K versions.".into();
    }
    if lower.contains("blocklist") || lower.contains("blacklist") {
        return "The server's administrator has blocked that title from being requested.".into();
    }
    if lower.contains("no seasons available") || status == 202 {
        return "Every season of that is already in the library or requested.".into();
    }
    match status {
        401 | 403 => "This account isn't allowed to do that on Seerr.".into(),
        404 => "Seerr doesn't know that title.".into(),
        s if s >= 500 => "Seerr ran into a problem. Try again in a moment.".into(),
        _ if said.is_empty() || said.chars().count() > 140 => "Seerr turned that down.".into(),
        _ => said.to_owned(),
    }
}

fn unreachable(conn: &Connection) -> String {
    err("unreachable", format!("Can't reach Seerr at {}", host(&conn.server)))
}

/// Whether Seerr, asked who this cookie belongs to, says nobody.
async fn session_is_gone(conn: &Connection) -> bool {
    match send(&conn.server, "/auth/me", "GET", None, Some(&conn.cookie), REQUEST_TIMEOUT).await {
        Ok(answer) => matches!(answer.status, 401 | 403),
        Err(_) => false,
    }
}

/// A request as the connected account. A refusal is checked before it is
/// believed: Seerr answers 403 both to "you may not" and to "who are you",
/// and only the second is a session to renew.
async fn call(path: &str, method: &str, body: Option<&Value>) -> Result<Answer, String> {
    let (acct, mut conn) = current()?;
    let mut answer = send(&conn.server, path, method, body, Some(&conn.cookie), REQUEST_TIMEOUT)
        .await
        .map_err(|_| unreachable(&conn))?;
    if matches!(answer.status, 401 | 403) && session_is_gone(&conn).await {
        if !renew(&acct, &conn).await {
            set_needs_reconnect(&acct.key, true);
            return Err(err("reconnect", NEEDS_RECONNECT));
        }
        conn = read(&acct.key).ok_or_else(|| err("reconnect", NEEDS_RECONNECT))?;
        answer = send(&conn.server, path, method, body, Some(&conn.cookie), REQUEST_TIMEOUT)
            .await
            .map_err(|_| unreachable(&conn))?;
    }
    if !(200..300).contains(&answer.status) {
        return Err(err("refused", plain_words(answer.status, &answer.text)));
    }
    Ok(answer)
}

/// The Seerr calls the webview may make: what the Requests pages, Search and
/// the library hooks ask, and nothing else. Without this the command would be
/// "do anything on Seerr as this user" for whatever runs in the window.
fn allowed(method: &str, path: &str) -> bool {
    fn id(s: &str) -> bool {
        !s.is_empty() && s.len() <= 12 && s.bytes().all(|b| b.is_ascii_digit())
    }
    let route = path.split('?').next().unwrap_or_default();
    if !route.starts_with('/') {
        return false;
    }
    let parts: Vec<&str> = route[1..].split('/').collect();
    match (method, parts.as_slice()) {
        ("GET", ["search"]) => true,
        ("GET", ["discover", "trending"]) => true,
        ("GET", ["discover", "movies"]) | ("GET", ["discover", "tv"]) => true,
        ("GET", ["discover", "movies", "upcoming"]) | ("GET", ["discover", "tv", "upcoming"]) => true,
        ("GET", ["movie", n]) | ("GET", ["tv", n]) | ("GET", ["collection", n]) => id(n),
        ("GET", ["person", n, "combined_credits"]) => id(n),
        ("GET", ["user", n, "quota"]) => id(n),
        ("GET", ["request"]) | ("POST", ["request"]) => true,
        ("DELETE", ["request", n]) => id(n),
        _ => false,
    }
}

/// One Seerr API call for the webview, made from here with the session added
/// here. `{ status, body }` for anything Seerr accepted; a refusal is an
/// error in plain words.
pub async fn request(path: &str, method: Option<String>, body: Option<Value>) -> Result<Value, String> {
    let method = method.unwrap_or_else(|| "GET".into()).to_ascii_uppercase();
    if !allowed(&method, path) {
        return Err(err("message", "That isn't something this app asks Seerr"));
    }
    let answer = call(path, &method, body.as_ref()).await?;
    Ok(json!({ "status": answer.status, "body": answer.json() }))
}

// ---------- Connecting ----------

/// What an address typed by hand could mean, in the order to try it. A bare
/// host is https first, then http; a typed scheme is taken at its word.
fn candidates(raw: &str) -> Result<Vec<String>, String> {
    let typed = raw.trim().trim_matches('/');
    if typed.is_empty() {
        return Err(err("message", "Enter the Seerr server's address"));
    }
    let has_scheme = typed.split_once("://").is_some_and(|(scheme, _)| {
        !scheme.is_empty() && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
    });
    let tidy = |address: &str| server::normalize(address).map_err(|_| err("message", "That isn't a usable address"));
    if has_scheme {
        Ok(vec![tidy(typed)?])
    } else {
        Ok(vec![tidy(&format!("https://{}", typed))?, tidy(&format!("http://{}", typed))?])
    }
}

/// `/settings/public`, cut down to what the app reads.
fn public_settings(all: &Value) -> Value {
    const KEPT: [&str; 8] = [
        "initialized",
        "applicationTitle",
        "mediaServerType",
        "movie4kEnabled",
        "series4kEnabled",
        "partialRequestsEnabled",
        "cacheImages",
        "mediaServerLogin",
    ];
    let mut out = serde_json::Map::new();
    for key in KEPT {
        if let Some(v) = all.get(key).filter(|v| !v.is_null()) {
            out.insert(key.to_owned(), v.clone());
        }
    }
    Value::Object(out)
}

/// Find out what is at an address before anything is sent to it. A bare host
/// is tried over https, then http; a certificate that fails stops the search
/// rather than dropping to http.
pub async fn probe(raw: &str) -> Result<Value, String> {
    let list = candidates(raw)?;
    let mut answered_as_something_else = false;
    for cand in &list {
        match send(cand, "/settings/public", "GET", None, None, PROBE_TIMEOUT).await {
            Ok(answer) => {
                let settings = answer.json();
                let initialized = match settings.get("initialized").and_then(Value::as_bool) {
                    Some(flag) if answer.status == 200 => flag,
                    _ => {
                        answered_as_something_else = true;
                        continue;
                    }
                };
                let kind = settings.get("mediaServerType").and_then(Value::as_i64);
                if !initialized || kind == Some(4) {
                    return Err(err("message", "That Seerr server hasn't finished its own setup yet."));
                }
                if kind != Some(2) {
                    return Err(err(
                        "message",
                        format!(
                            "That Seerr server is set up for {}, not Jellyfin.",
                            if kind == Some(1) { "Plex" } else { "Emby" }
                        ),
                    ));
                }
                let name = settings
                    .get("applicationTitle")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("Seerr")
                    .to_owned();
                return Ok(json!({
                    "server": cand,
                    "secure": server::is_secure(cand),
                    "fell_back": list.len() > 1 && cand.starts_with("http://"),
                    "name": name,
                    "settings": public_settings(&settings),
                }));
            }
            Err(Failure::Transport { certificate: true }) if list.len() > 1 && cand.starts_with("https://") => {
                return Err(err(
                    "message",
                    "That server's certificate couldn't be verified, so no secure connection was made. To use it without encryption anyway, type the address with http:// in front.",
                ));
            }
            Err(_) => {}
        }
    }
    Err(err(
        "message",
        if answered_as_something_else {
            "That address answered, but not as a Seerr server."
        } else {
            "Couldn't reach a Seerr server at that address."
        },
    ))
}

/// A Jellyfin user id as either server writes it: with or without dashes, in
/// either case.
fn bare(id: &str) -> String {
    id.to_lowercase().replace('-', "")
}

/// The name Seerr knows the account by.
fn user_name(user: &Value) -> String {
    ["displayName", "username", "jellyfinUsername", "email"]
        .iter()
        .filter_map(|k| user.get(*k).and_then(Value::as_str))
        .find(|s| !s.is_empty())
        .unwrap_or_default()
        .to_owned()
}

/// Turn Seerr's answer to a sign-in into a connection, or say why not.
async fn connection_from(answer: &Answer, seerr: &str, acct: &Account) -> Result<Connection, String> {
    if answer.status != 200 {
        return Err(match answer.status {
            403 => err(
                "message",
                "Your Jellyfin account hasn't been let in to this Seerr server. Ask whoever runs it to add you.",
            ),
            404 => err("quickconnect", QUICK_CONNECT_UNAVAILABLE),
            _ => err("message", "Seerr couldn't sign you in. Try again in a moment."),
        });
    }
    let cookie = answer
        .cookie("connect.sid")
        .filter(|c| !c.is_empty())
        .ok_or_else(|| err("message", "Seerr accepted the sign-in but returned no session."))?
        .to_owned();
    let user = answer.json();
    // The session has to be this Jellyfin user's. Seerr names the user it
    // signed in; anyone else's is thrown back.
    let theirs = user.get("jellyfinUserId").and_then(Value::as_str).unwrap_or_default();
    if !theirs.is_empty() && bare(theirs) != bare(&acct.user_id) {
        let _ = send(seerr, "/auth/logout", "POST", None, Some(&cookie), LOGOUT_TIMEOUT).await;
        return Err(err(
            "message",
            "Seerr signed in a different Jellyfin user than the one this app is using.",
        ));
    }
    let name = user_name(&user);
    // What is already known of this server's settings carries over a renewal.
    let settings = read(&acct.key).filter(|old| old.server == seerr).and_then(|old| old.settings);
    Ok(Connection {
        server: seerr.to_owned(),
        cookie,
        user_id: user.get("id").and_then(Value::as_i64).unwrap_or(0),
        user_name: if name.is_empty() { acct.user_name.clone() } else { name },
        permissions: user.get("permissions").and_then(Value::as_i64).unwrap_or(0),
        settings,
    })
}

/// Sign in to Seerr as the Jellyfin user this app is signed in as, with no
/// password: Seerr asks Jellyfin for a Quick Connect code and this install
/// approves it.
///
/// Approving the code gives the Seerr server a Jellyfin session for this
/// user, which is what signing in to Seerr with a password does too. The code
/// can only have come from the Jellyfin server this app is signed in to: any
/// other server's code is one ours has never heard of.
async fn quick_connect(seerr: &str, acct: &Account) -> Result<Connection, String> {
    let gone = |_: Failure| err("unreachable", "Can't reach Seerr at that address");
    let asked = send(seerr, "/auth/jellyfin/quickconnect/initiate", "POST", None, None, REQUEST_TIMEOUT)
        .await
        .map_err(gone)?;
    let start = asked.json();
    // Jellyfin's code is digits in a string; be ready for a number.
    let code = match start.get("code") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    };
    let secret_code = start.get("secret").and_then(Value::as_str).unwrap_or_default().to_owned();
    // The code goes into an address on the Jellyfin server; Seerr doesn't get
    // to put anything but a code there.
    let code_ok = !code.is_empty() && code.len() <= 32 && code.chars().all(|c| c.is_ascii_alphanumeric());
    if asked.status != 200 || !code_ok || secret_code.is_empty() {
        return Err(err("quickconnect", QUICK_CONNECT_UNAVAILABLE));
    }

    let approval = server::request(&format!("/QuickConnect/Authorize?code={}", code), Some("POST".into()), None)
        .await
        .map_err(|_| err("quickconnect", QUICK_CONNECT_UNAVAILABLE))?;
    let approved = match approval["status"].as_u64().unwrap_or(0) {
        // A code Jellyfin has never heard of.
        400 | 404 => false,
        s if (200..300).contains(&s) => approval["body"] == json!(true),
        _ => return Err(err("quickconnect", QUICK_CONNECT_UNAVAILABLE)),
    };
    if !approved {
        return Err(err(
            "message",
            "That Seerr server belongs to a different Jellyfin server than the one you're signed in to.",
        ));
    }

    let done = send(
        seerr,
        "/auth/jellyfin/quickconnect/authenticate",
        "POST",
        Some(&json!({ "secret": secret_code })),
        None,
        REQUEST_TIMEOUT,
    )
    .await
    .map_err(gone)?;
    connection_from(&done, seerr, acct).await
}

fn keep(acct: &Account, conn: &Connection) -> Result<(), String> {
    if store(&acct.key, conn) {
        Ok(())
    } else {
        Err(err(
            "message",
            "Connected, but the keyring would not store the session. Try again.",
        ))
    }
}

fn signed_in() -> Result<Account, String> {
    account().ok_or_else(|| err("message", "Sign in to Jellyfin first"))
}

fn usable(seerr: &str) -> Result<String, String> {
    server::normalize(seerr).map_err(|_| err("message", "That isn't a usable address"))
}

/// Whether signing in without a password is on offer: the Jellyfin server has
/// Quick Connect on. (Whether Seerr is new enough is found by trying.)
async fn jellyfin_quick_connect_on() -> bool {
    match server::request("/QuickConnect/Enabled", None, None).await {
        Ok(out) => out["status"] == json!(200) && out["body"] == json!(true),
        Err(_) => false,
    }
}

/// Connect a probed Seerr server with Quick Connect. A `quickconnect` error
/// means there is none to sign in with, and the password form is next.
pub async fn connect(seerr: &str) -> Result<Value, String> {
    let acct = signed_in()?;
    let seerr = usable(seerr)?;
    if !jellyfin_quick_connect_on().await {
        return Err(err("quickconnect", QUICK_CONNECT_UNAVAILABLE));
    }
    let conn = quick_connect(&seerr, &acct).await?;
    keep(&acct, &conn)?;
    Ok(refresh().await)
}

/// The fallback: the Jellyfin user name and password, sent to Seerr once over
/// this connection and kept nowhere.
pub async fn connect_with_password(seerr: &str, username: &str, password: &str) -> Result<Value, String> {
    let acct = signed_in()?;
    let seerr = usable(seerr)?;
    let done = send(
        &seerr,
        "/auth/jellyfin",
        "POST",
        Some(&json!({ "username": username, "password": password })),
        None,
        REQUEST_TIMEOUT,
    )
    .await
    .map_err(|_| err("unreachable", "Can't reach Seerr at that address"))?;
    if done.status == 401 {
        return Err(err("message", "That user name or password isn't right."));
    }
    let conn = connection_from(&done, &seerr, &acct).await?;
    keep(&acct, &conn)?;
    Ok(refresh().await)
}

/// How many quiet renewals have finished, so the requests that found the
/// session gone together share one.
static RENEWALS: AtomicU64 = AtomicU64::new(0);

fn renewal_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

/// One quiet Quick Connect for however many requests found the session gone
/// at once. `stale` is the connection the caller's request was refused with.
async fn renew(acct: &Account, stale: &Connection) -> bool {
    let renewed_already = |key: &str| read(key).is_some_and(|now| now.cookie != stale.cookie);
    let seen = RENEWALS.load(Ordering::SeqCst);
    let _one_at_a_time = renewal_lock().lock().await;
    if renewed_already(&acct.key) {
        return true;
    }
    // Another request tried while this one waited, and it did not work.
    if RENEWALS.load(Ordering::SeqCst) != seen {
        return false;
    }
    let renewed = match quick_connect(&stale.server, acct).await {
        Ok(mut fresh) => {
            fresh.settings = stale.settings.clone();
            store(&acct.key, &fresh)
        }
        Err(_) => false,
    };
    RENEWALS.fetch_add(1, Ordering::SeqCst);
    renewed
}

/// Reconnect after the session ran out, from Settings.
pub async fn reconnect() -> Result<Value, String> {
    let (acct, conn) = current()?;
    let fresh = quick_connect(&conn.server, &acct).await?;
    keep(&acct, &fresh)?;
    Ok(refresh().await)
}

/// Bring what is remembered about the account and the server up to date:
/// permissions change, and so does whether 4K is on offer. Quiet; answers
/// with `status()` whatever happened.
pub async fn refresh() -> Value {
    let Ok((acct, before)) = current() else { return status() };
    let mut next = before;
    if let Ok(answer) = call("/settings/public", "GET", None).await {
        let settings = answer.json();
        if settings.is_object() {
            next.settings = Some(public_settings(&settings));
        }
    }
    if let Ok(answer) = call("/auth/me", "GET", None).await {
        let user = answer.json();
        if let Some(p) = user.get("permissions").and_then(Value::as_i64) {
            next.permissions = p;
        }
        if let Some(id) = user.get("id").and_then(Value::as_i64) {
            next.user_id = id;
        }
        let name = user_name(&user);
        if !name.is_empty() {
            next.user_name = name;
        }
    }
    // Disconnected in between? Then there is nothing to bring up to date.
    // Renewed in between? Keep the newer cookie.
    if let Some(latest) = read(&acct.key) {
        if latest.server == next.server {
            next.cookie = latest.cookie.clone();
            if next != latest {
                store(&acct.key, &next);
            }
        }
    }
    status()
}

// ---------- Leaving ----------

/// Forget an account's Seerr session on this device.
pub fn forget(key: &str) {
    secret::clear_seerr(key);
    set_needs_reconnect(key, false);
    forget_csrf();
}

/// End an account's Seerr session and forget it. Seerr is told, so the
/// session stops working there too; if it can't be reached the cookie is
/// still gone from here. Called for Disconnect, and by `server.rs` whenever a
/// Jellyfin account is signed out of this device.
pub async fn sign_out(key: &str) {
    if let Some(conn) = read(key) {
        let _ = send(&conn.server, "/auth/logout", "POST", None, Some(&conn.cookie), LOGOUT_TIMEOUT).await;
    }
    forget(key);
}

/// Disconnect the account in use from Seerr.
pub async fn disconnect() -> Value {
    if let Some(acct) = account() {
        sign_out(&acct.key).await;
    }
    status()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{config_on_disk, sandbox, sign_in, FakeServer, Req, Resp, TEST_USER};
    use std::sync::atomic::{AtomicBool, AtomicUsize};
    use std::sync::Arc;

    fn kind_of(e: &str) -> &str {
        e.split('|').next().unwrap_or("")
    }

    fn words(e: &str) -> &str {
        e.split_once('|').map(|(_, m)| m).unwrap_or(e)
    }

    // ---------- Pure logic ----------

    #[test]
    fn a_bare_host_is_tried_over_https_then_http() {
        assert_eq!(
            candidates("  requests.example.com/ ").unwrap(),
            vec!["https://requests.example.com", "http://requests.example.com"]
        );
        assert_eq!(
            candidates("seerr.lan:5055/base/").unwrap(),
            vec!["https://seerr.lan:5055/base", "http://seerr.lan:5055/base"]
        );
    }

    #[test]
    fn a_typed_scheme_is_taken_at_its_word() {
        assert_eq!(candidates("http://seerr.lan:5055").unwrap(), vec!["http://seerr.lan:5055"]);
        assert_eq!(candidates("HTTPS://Seerr.Example.com/").unwrap(), vec!["https://seerr.example.com"]);
    }

    #[test]
    fn an_address_that_cannot_be_one_is_refused_in_words() {
        assert_eq!(candidates("   ").unwrap_err(), "message|Enter the Seerr server's address");
        assert_eq!(candidates("///").unwrap_err(), "message|Enter the Seerr server's address");
        for bad in ["file:///etc/passwd", "ftp://seerr.lan", "https://user:pw@seerr.lan", "https://seerr lan"] {
            assert_eq!(candidates(bad).unwrap_err(), "message|That isn't a usable address", "{bad}");
        }
    }

    #[test]
    fn a_set_cookie_header_gives_its_name_and_value() {
        assert_eq!(
            cookie_pair("connect.sid=s%3Aabc.def; Path=/; HttpOnly; SameSite=Lax"),
            Some(("connect.sid".into(), "s%3Aabc.def".into()))
        );
        // The value may itself hold an equals sign.
        assert_eq!(cookie_pair("XSRF-TOKEN=a=b"), Some(("XSRF-TOKEN".into(), "a=b".into())));
        assert_eq!(cookie_pair(" _csrf = sec ; Path=/"), Some(("_csrf".into(), "sec".into())));
        assert_eq!(cookie_pair("novalue"), None);
        assert_eq!(cookie_pair("=x"), None);
    }

    #[test]
    fn percent_escapes_are_undone_for_the_csrf_header() {
        assert_eq!(percent_decode("tok%2B123%3D"), "tok+123=");
        assert_eq!(percent_decode("plain"), "plain");
        // Not an escape, or cut short: left as it is.
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("a%2"), "a%2");
        assert_eq!(percent_decode("a%zz"), "a%zz");
        // Not text once decoded: handed back untouched.
        assert_eq!(percent_decode("%ff%fe"), "%ff%fe");
    }

    #[test]
    fn a_redirect_is_followed_only_to_the_same_scheme_host_and_port() {
        let url = |s: &str| reqwest::Url::parse(s).unwrap();
        let from = url("https://seerr.example.com/api/v1/request");
        assert!(same_origin(&from, &url("https://seerr.example.com/login")));
        assert!(same_origin(&from, &url("https://seerr.example.com:443/login")));
        assert!(!same_origin(&from, &url("http://seerr.example.com/login")));
        assert!(!same_origin(&from, &url("https://seerr.example.com:8443/login")));
        assert!(!same_origin(&from, &url("https://evil.example.com/api/v1/request")));
        assert!(!same_origin(&from, &url("https://seerr.example.com.evil.net/")));
    }

    #[test]
    fn jellyfin_user_ids_compare_without_dashes_or_case() {
        assert_eq!(bare("0A1B2C3D-0000-4000-8000-ABCDEFABCDEF"), "0a1b2c3d000040008000abcdefabcdef");
        assert_eq!(bare("0A1B2C3D-0000-4000-8000-ABCDEFABCDEF"), bare("0a1b2c3d000040008000abcdefabcdef"));
        assert_ne!(bare("0a1b"), bare("0a1c"));
    }

    #[test]
    fn refusals_are_put_in_plain_words() {
        let say = |status: u16, message: &str| plain_words(status, &json!({ "message": message }).to_string());
        assert_eq!(
            say(403, "Movie Quota exceeded."),
            "You've used all your requests for now. More open up as the oldest ones age out."
        );
        assert_eq!(say(409, "Request for this media already exists."), "That has already been requested.");
        assert_eq!(plain_words(409, ""), "That has already been requested.");
        assert_eq!(say(403, "You do not have permission to make 4K requests."), "This account can't request 4K versions.");
        assert_eq!(
            say(403, "This media is blocklisted."),
            "The server's administrator has blocked that title from being requested."
        );
        assert_eq!(
            say(403, "This media is blacklisted."),
            "The server's administrator has blocked that title from being requested."
        );
        assert_eq!(
            say(202, "No seasons available to request"),
            "Every season of that is already in the library or requested."
        );
        assert_eq!(say(403, "nope"), "This account isn't allowed to do that on Seerr.");
        assert_eq!(say(401, ""), "This account isn't allowed to do that on Seerr.");
        assert_eq!(say(404, "Unable to retrieve movie."), "Seerr doesn't know that title.");
        assert_eq!(plain_words(502, "<html>bad gateway</html>"), "Seerr ran into a problem. Try again in a moment.");
        // Seerr's own words when they are short enough to read...
        assert_eq!(say(400, "Season list is empty."), "Season list is empty.");
        assert_eq!(plain_words(400, &json!({ "error": "Bad thing" }).to_string()), "Bad thing");
        // ...and not otherwise.
        assert_eq!(say(400, &"x".repeat(141)), "Seerr turned that down.");
        assert_eq!(plain_words(400, "not json"), "Seerr turned that down.");
    }

    #[test]
    fn only_a_certificate_failure_stops_the_fallback_to_http() {
        assert!(names_a_certificate(
            "error sending request | client error (Connect) | invalid peer certificate: UnknownIssuer"
        ));
        assert!(names_a_certificate("invalid peer certificate: Expired"));
        assert!(!names_a_certificate("error trying to connect: tcp connect error: Connection refused (os error 111)"));
        assert!(!names_a_certificate("dns error: failed to lookup address information"));
        assert!(!names_a_certificate("received corrupt message of type InvalidContentType"));
        assert!(!names_a_certificate("operation timed out"));
    }

    #[test]
    fn the_webview_may_ask_seerr_only_what_the_app_asks() {
        for (method, path) in [
            ("GET", "/search?query=matrix&page=1"),
            ("GET", "/discover/trending?page=1"),
            ("GET", "/discover/movies?page=1"),
            ("GET", "/discover/tv"),
            ("GET", "/discover/movies/upcoming?page=1"),
            ("GET", "/discover/tv/upcoming"),
            ("GET", "/movie/603"),
            ("GET", "/tv/1396"),
            ("GET", "/collection/2344"),
            ("GET", "/person/71580/combined_credits"),
            ("GET", "/user/3/quota"),
            ("GET", "/request?take=40&skip=0&sort=added&requestedBy=3"),
            ("POST", "/request"),
            ("DELETE", "/request/12"),
        ] {
            assert!(allowed(method, path), "{method} {path}");
        }
        for (method, path) in [
            ("GET", "/auth/me"),
            ("POST", "/auth/logout"),
            ("GET", "/settings/main"),
            ("GET", "/user"),
            ("GET", "/user/3"),
            ("POST", "/user/3/settings/password"),
            ("POST", "/request/12/approve"),
            ("DELETE", "/request"),
            ("DELETE", "/movie/603"),
            ("PUT", "/request/12"),
            ("GET", "/movie/603/../../auth/me"),
            ("GET", "/movie/abc"),
            ("GET", "movie/603"),
            ("GET", "//evil.example.com/movie/603"),
            ("GET", ""),
        ] {
            assert!(!allowed(method, path), "{method} {path}");
        }
    }

    #[test]
    fn public_settings_keep_only_what_the_app_reads() {
        let all = json!({
            "initialized": true, "applicationTitle": "Requests", "mediaServerType": 2,
            "cacheImages": true, "partialRequestsEnabled": false, "vapidPublic": "key", "region": null,
        });
        assert_eq!(
            public_settings(&all),
            json!({
                "initialized": true, "applicationTitle": "Requests", "mediaServerType": 2,
                "cacheImages": true, "partialRequestsEnabled": false,
            })
        );
    }

    #[test]
    fn seerrs_name_for_the_account_is_the_first_it_has() {
        assert_eq!(user_name(&json!({ "displayName": "", "username": "ann", "email": "a@b" })), "ann");
        assert_eq!(user_name(&json!({ "jellyfinUsername": "jf-ann" })), "jf-ann");
        assert_eq!(user_name(&json!({})), "");
    }

    #[test]
    fn a_connection_survives_its_own_encoding() {
        let conn = Connection {
            server: "https://seerr.example.com".into(),
            cookie: "s%3Aabc".into(),
            user_id: 7,
            user_name: "Ann".into(),
            permissions: 32,
            settings: Some(json!({ "cacheImages": true })),
        };
        let raw = serde_json::to_string(&conn).unwrap();
        assert_eq!(serde_json::from_str::<Connection>(&raw).unwrap(), conn);
        // Fields added later are optional in what is already stored.
        let old: Connection = serde_json::from_str(r#"{"server":"http://s","cookie":"c"}"#).unwrap();
        assert_eq!((old.user_id, old.permissions, old.settings), (0, 0, None));
    }

    // ---------- With stand-in servers ----------

    const SETTINGS: &str = "/api/v1/settings/public";
    const INITIATE: &str = "/api/v1/auth/jellyfin/quickconnect/initiate";
    const AUTHENTICATE: &str = "/api/v1/auth/jellyfin/quickconnect/authenticate";
    const PASSWORD: &str = "/api/v1/auth/jellyfin";
    const ME: &str = "/api/v1/auth/me";
    const LOGOUT: &str = "/api/v1/auth/logout";
    const AUTHORIZE: &str = "/QuickConnect/Authorize";

    fn settings() -> Value {
        json!({
            "initialized": true, "applicationTitle": "Requests", "mediaServerType": 2,
            "movie4kEnabled": false, "series4kEnabled": false, "partialRequestsEnabled": true,
            "cacheImages": false,
        })
    }

    fn seerr_user(jellyfin_user: &str) -> Value {
        json!({ "id": 7, "displayName": "Ann", "permissions": 32, "jellyfinUserId": jellyfin_user })
    }

    fn signed_in_reply(cookie: &str, jellyfin_user: &str) -> Resp {
        Resp::json(200, seerr_user(jellyfin_user))
            .header("Set-Cookie", &format!("connect.sid={cookie}; Path=/; HttpOnly; SameSite=Lax"))
    }

    fn cookie_of(req: &Req) -> String {
        req.header("cookie").unwrap_or_default().to_string()
    }

    /// A Jellyfin with Quick Connect on that approves any code.
    fn jellyfin_approving() -> FakeServer {
        FakeServer::jellyfin(|req| match req.path() {
            "/QuickConnect/Enabled" => Resp::json(200, json!(true)),
            AUTHORIZE => Resp::json(200, json!(true)),
            _ => Resp::status(404),
        })
    }

    /// What a Seerr that signs anyone in as `TEST_USER` answers before any
    /// test-specific path: sessions are `s%3A1`, `s%3A2`, ... in the order
    /// handed out, and only the newest is live.
    struct Seerr {
        server: FakeServer,
        sessions: Arc<AtomicUsize>,
    }

    fn seerr_with(extra: impl Fn(&Req, bool) -> Option<Resp> + Send + Sync + 'static) -> Seerr {
        let sessions = Arc::new(AtomicUsize::new(0));
        let count = sessions.clone();
        let server = FakeServer::start(move |req| {
            let live = format!("connect.sid=s%3A{}", count.load(Ordering::SeqCst));
            let known = count.load(Ordering::SeqCst) > 0
                && cookie_of(req).split("; ").any(|c| c == live);
            if let Some(resp) = extra(req, known) {
                return resp;
            }
            match (req.method.as_str(), req.path()) {
                ("GET", SETTINGS) => Resp::json(200, settings()),
                ("POST", INITIATE) => Resp::json(200, json!({ "code": "123456", "secret": "abcdef0123456789" })),
                ("POST", AUTHENTICATE) | ("POST", PASSWORD) => {
                    let n = count.fetch_add(1, Ordering::SeqCst) + 1;
                    signed_in_reply(&format!("s%3A{n}"), TEST_USER)
                }
                ("POST", LOGOUT) => Resp::json(200, json!({ "status": "ok" })),
                (_, ME) if known => Resp::json(200, seerr_user(TEST_USER)),
                _ if !known => Resp::json(403, json!({ "message": "You do not have permission to access this endpoint" })),
                _ => Resp::json(200, json!({ "ok": true })),
            }
        });
        Seerr { server, sessions }
    }

    fn plain_seerr() -> Seerr {
        seerr_with(|_, _| None)
    }

    #[tokio::test]
    async fn probe_tries_https_first_and_marks_the_fallback() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let _s = sandbox();
        // A listener that answers anything, a TLS hello included, with the
        // settings over plain http: the https attempt fails its handshake (no
        // certificate is ever seen) and the http one is answered.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0u8; 2048];
                let _ = sock.read(&mut buf).await;
                let body = settings().to_string();
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.shutdown().await;
            }
        });
        let out = probe(&format!("127.0.0.1:{}/", port)).await.unwrap();
        assert_eq!(out["server"], json!(format!("http://127.0.0.1:{}", port)));
        assert_eq!(out["secure"], json!(false));
        assert_eq!(out["fell_back"], json!(true));
        assert_eq!(out["name"], json!("Requests"));
        assert_eq!(out["settings"]["partialRequestsEnabled"], json!(true));
    }

    #[tokio::test]
    async fn probe_of_a_typed_address_asks_only_for_the_public_settings() {
        let _s = sandbox();
        let seerr = plain_seerr();
        let out = probe(&seerr.server.url).await.unwrap();
        assert_eq!(out["server"], json!(seerr.server.url));
        assert_eq!(out["fell_back"], json!(false));
        let asked = seerr.server.requests();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].path(), SETTINGS);
        assert_eq!(asked[0].header("cookie"), None);
        assert_eq!(asked[0].header("authorization"), None);
    }

    #[tokio::test]
    async fn probe_turns_down_what_is_not_a_jellyfin_seerr() {
        let _s = sandbox();
        let answer = Arc::new(Mutex::new((200u16, json!({ "initialized": false, "mediaServerType": 2 }))));
        let next = answer.clone();
        let server = FakeServer::start(move |_| {
            let (status, body) = next.lock().unwrap().clone();
            Resp::json(status, body)
        });
        let said = |status: u16, body: Value| {
            *answer.lock().unwrap() = (status, body);
        };
        assert_eq!(
            words(&probe(&server.url).await.unwrap_err()),
            "That Seerr server hasn't finished its own setup yet."
        );
        said(200, json!({ "initialized": true, "mediaServerType": 4 }));
        assert_eq!(
            words(&probe(&server.url).await.unwrap_err()),
            "That Seerr server hasn't finished its own setup yet."
        );
        said(200, json!({ "initialized": true, "mediaServerType": 1 }));
        assert_eq!(
            words(&probe(&server.url).await.unwrap_err()),
            "That Seerr server is set up for Plex, not Jellyfin."
        );
        said(200, json!({ "initialized": true, "mediaServerType": 3 }));
        assert_eq!(
            words(&probe(&server.url).await.unwrap_err()),
            "That Seerr server is set up for Emby, not Jellyfin."
        );
        // Something else entirely: a Jellyfin, a router's sign-in page.
        said(200, json!({ "ServerName": "Jellyfin" }));
        assert_eq!(
            words(&probe(&server.url).await.unwrap_err()),
            "That address answered, but not as a Seerr server."
        );
        said(404, json!(null));
        assert_eq!(
            words(&probe(&server.url).await.unwrap_err()),
            "That address answered, but not as a Seerr server."
        );
        assert_eq!(
            words(&probe(&FakeServer::dead_url()).await.unwrap_err()),
            "Couldn't reach a Seerr server at that address."
        );
    }

    #[tokio::test]
    async fn quick_connect_signs_in_without_a_password() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = plain_seerr();

        let out = connect(&seerr.server.url).await.unwrap();
        assert_eq!(out["connected"], json!(true));
        assert_eq!(out["server"], json!(seerr.server.url));
        assert_eq!(out["host"], json!(format!("127.0.0.1:{}", seerr.server.port)));
        assert_eq!(out["secure"], json!(false));
        assert_eq!(out["user_id"], json!(7));
        assert_eq!(out["user_name"], json!("Ann"));
        assert_eq!(out["permissions"], json!(32));
        assert_eq!(out["needs_reconnect"], json!(false));
        // Connecting reads the server's settings, for the pages that need them.
        assert_eq!(out["settings"]["applicationTitle"], json!("Requests"));

        // Jellyfin approved the code Seerr asked for, with the app's own session.
        let approvals = jf.requests_to(AUTHORIZE);
        assert_eq!(approvals.len(), 1);
        assert_eq!(approvals[0].method, "POST");
        assert_eq!(approvals[0].query(), "code=123456");
        assert!(approvals[0].header("authorization").unwrap_or_default().contains("Token=\""));
        // Seerr was handed the secret, and nothing of Jellyfin's.
        let finish = seerr.server.requests_to(AUTHENTICATE);
        assert_eq!(finish[0].json(), json!({ "secret": "abcdef0123456789" }));
        for req in seerr.server.requests() {
            assert_eq!(req.header("authorization"), None, "{}", req.target);
            assert_eq!(req.header("x-api-key"), None, "the admin API key is never used");
        }
    }

    #[tokio::test]
    async fn the_session_stays_on_this_side_of_the_ipc_boundary() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = plain_seerr();
        let out = connect(&seerr.server.url).await.unwrap();

        // Filed under this Jellyfin account, and readable back.
        let (key, _, _) = server::current_account().unwrap();
        let stored = secret::seerr_session(&key).expect("the session was stored");
        assert!(stored.contains("s%3A1"));
        // Nothing the webview is handed carries it.
        assert!(!out.to_string().contains("s%3A1"), "{out}");
        assert!(!status().to_string().contains("s%3A1"));
        assert!(!secret::hydrate(crate::config::load()).to_string().contains("s%3A1"));
        assert!(!server::accounts().to_string().contains("s%3A1"));
        let reply = request("/search?query=x", None, None).await.unwrap();
        assert!(!reply.to_string().contains("s%3A1"));
    }

    #[tokio::test]
    async fn another_jellyfin_users_session_is_refused_and_handed_back() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, _| {
            (req.path() == AUTHENTICATE).then(|| signed_in_reply("s%3Asomeone", "someone-else"))
        });
        let e = connect(&seerr.server.url).await.unwrap_err();
        assert!(words(&e).contains("different Jellyfin user"), "{e}");
        assert_eq!(status(), json!({ "connected": false }));
        // The session Seerr made is ended there rather than left behind.
        let out = seerr.server.requests_to(LOGOUT);
        assert_eq!(out.len(), 1);
        assert_eq!(cookie_of(&out[0]), "connect.sid=s%3Asomeone");
    }

    #[tokio::test]
    async fn a_user_id_seerr_writes_differently_is_still_the_same_user() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        crate::config::merge(json!({ "user_id": "0a1b2c3d00004000800000000000abcd" })).unwrap();
        let seerr = seerr_with(|req, _| {
            (req.path() == AUTHENTICATE)
                .then(|| signed_in_reply("s%3Asame", "0A1B2C3D-0000-4000-8000-00000000ABCD"))
        });
        assert_eq!(connect(&seerr.server.url).await.unwrap()["connected"], json!(true));
    }

    #[tokio::test]
    async fn a_code_jellyfin_does_not_know_means_a_different_jellyfin_server() {
        let _s = sandbox();
        let jf = FakeServer::jellyfin(|req| match req.path() {
            "/QuickConnect/Enabled" => Resp::json(200, json!(true)),
            AUTHORIZE => Resp::status(404),
            _ => Resp::status(404),
        });
        sign_in(&jf.url);
        let seerr = plain_seerr();
        let e = connect(&seerr.server.url).await.unwrap_err();
        assert!(words(&e).contains("different Jellyfin server"), "{e}");
        assert!(seerr.server.requests_to(AUTHENTICATE).is_empty(), "nothing was finished");
        assert_eq!(status(), json!({ "connected": false }));
    }

    #[tokio::test]
    async fn a_code_that_is_not_a_code_never_reaches_jellyfin() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, _| {
            (req.path() == INITIATE)
                .then(|| Resp::json(200, json!({ "code": "1&userId=admin", "secret": "abcdef0123456789" })))
        });
        assert_eq!(kind_of(&connect(&seerr.server.url).await.unwrap_err()), "quickconnect");
        assert!(jf.requests_to(AUTHORIZE).is_empty());
    }

    #[tokio::test]
    async fn a_numeric_code_is_read_too() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, _| {
            (req.path() == INITIATE).then(|| Resp::json(200, json!({ "code": 654321, "secret": "abcdef0123456789" })))
        });
        connect(&seerr.server.url).await.unwrap();
        assert_eq!(jf.requests_to(AUTHORIZE)[0].query(), "code=654321");
    }

    #[tokio::test]
    async fn an_older_seerr_falls_back_to_the_password_which_is_not_kept() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, _| (req.path() == INITIATE).then(|| Resp::status(404)));
        let e = connect(&seerr.server.url).await.unwrap_err();
        assert_eq!(kind_of(&e), "quickconnect");
        assert_eq!(words(&e), QUICK_CONNECT_UNAVAILABLE);

        let out = connect_with_password(&seerr.server.url, "ann", "hunter2").await.unwrap();
        assert_eq!(out["connected"], json!(true));
        let sent = seerr.server.requests_to(PASSWORD);
        assert_eq!(sent[0].json(), json!({ "username": "ann", "password": "hunter2" }));
        let (key, _, _) = server::current_account().unwrap();
        assert!(!secret::seerr_session(&key).unwrap().contains("hunter2"));
        assert!(!config_on_disk().to_string().contains("hunter2"));
        assert!(!crate::test_support::debug_log().contains("hunter2"));
    }

    #[tokio::test]
    async fn quick_connect_turned_off_in_jellyfin_goes_to_the_password_without_asking_seerr() {
        let _s = sandbox();
        let jf = FakeServer::jellyfin(|req| match req.path() {
            "/QuickConnect/Enabled" => Resp::json(200, json!(false)),
            _ => Resp::status(404),
        });
        sign_in(&jf.url);
        let seerr = plain_seerr();
        assert_eq!(kind_of(&connect(&seerr.server.url).await.unwrap_err()), "quickconnect");
        assert!(seerr.server.requests().is_empty());
    }

    #[tokio::test]
    async fn sign_in_failures_say_what_went_wrong() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, _| match req.path() {
            PASSWORD => Some(Resp::json(401, json!({ "message": "INVALID_CREDENTIALS" }))),
            AUTHENTICATE => Some(Resp::json(403, json!({ "message": "Access denied." }))),
            _ => None,
        });
        assert_eq!(
            words(&connect_with_password(&seerr.server.url, "ann", "wrong").await.unwrap_err()),
            "That user name or password isn't right."
        );
        assert!(words(&connect(&seerr.server.url).await.unwrap_err()).contains("hasn't been let in"));
        assert_eq!(status(), json!({ "connected": false }));
        // A sign-in Seerr accepts without handing out a session is no sign-in.
        let seerr = seerr_with(|req, _| (req.path() == AUTHENTICATE).then(|| Resp::json(200, seerr_user(TEST_USER))));
        assert_eq!(
            words(&connect(&seerr.server.url).await.unwrap_err()),
            "Seerr accepted the sign-in but returned no session."
        );
        assert_eq!(
            kind_of(&connect(&FakeServer::dead_url()).await.unwrap_err()),
            "unreachable"
        );
    }

    #[tokio::test]
    async fn connecting_needs_a_jellyfin_session() {
        let _s = sandbox();
        let seerr = plain_seerr();
        assert_eq!(connect(&seerr.server.url).await.unwrap_err(), "message|Sign in to Jellyfin first");
        assert_eq!(
            connect_with_password(&seerr.server.url, "a", "b").await.unwrap_err(),
            "message|Sign in to Jellyfin first"
        );
        assert_eq!(kind_of(&request("/search?query=x", None, None).await.unwrap_err()), "notconnected");
        assert_eq!(kind_of(&reconnect().await.unwrap_err()), "notconnected");
        assert_eq!(status(), json!({ "connected": false }));
        assert!(seerr.server.requests().is_empty());
    }

    #[tokio::test]
    async fn the_cookie_goes_on_requests_to_seerr_and_bodies_go_as_json() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, known| {
            (known && req.path() == "/api/v1/request" && req.method == "POST")
                .then(|| Resp::json(201, json!({ "id": 4, "status": 1 })))
        });
        connect(&seerr.server.url).await.unwrap();
        seerr.server.forget_requests();
        jf.forget_requests();

        let made = request(
            "/request",
            Some("post".into()),
            Some(json!({ "mediaType": "movie", "mediaId": 603, "is4k": false })),
        )
        .await
        .unwrap();
        assert_eq!(made, json!({ "status": 201, "body": { "id": 4, "status": 1 } }));
        let sent = &seerr.server.requests()[0];
        assert_eq!(sent.method, "POST");
        assert_eq!(sent.target, "/api/v1/request");
        assert_eq!(cookie_of(sent), "connect.sid=s%3A1");
        assert_eq!(sent.json(), json!({ "mediaType": "movie", "mediaId": 603, "is4k": false }));
        assert_eq!(sent.header("accept"), Some("application/json"));
        // Jellyfin never sees it.
        assert!(jf.requests().iter().all(|r| r.header("cookie").is_none()));
        // A path outside the app's own is refused before the network.
        seerr.server.forget_requests();
        assert_eq!(kind_of(&request("/auth/me", None, None).await.unwrap_err()), "message");
        assert!(seerr.server.requests().is_empty());
    }

    #[tokio::test]
    async fn a_redirect_to_another_origin_is_not_followed() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let elsewhere = FakeServer::start(|_| Resp::json(200, json!({ "stolen": true })));
        let target = format!("{}/api/v1/search?query=x", elsewhere.url);
        let seerr = seerr_with(move |req, known| {
            if !known {
                return None;
            }
            match req.path() {
                "/api/v1/search" => Some(Resp::status(302).header("Location", &target)),
                "/api/v1/discover/tv" => Some(Resp::status(302).header("Location", "/api/v1/discover/movies")),
                _ => None,
            }
        });
        connect(&seerr.server.url).await.unwrap();

        let e = request("/search?query=x", None, None).await.unwrap_err();
        assert_eq!(kind_of(&e), "refused");
        assert!(elsewhere.requests().is_empty(), "the cookie's request went to another server");
        // The same origin is followed, cookie and all.
        let out = request("/discover/tv", None, None).await.unwrap();
        assert_eq!(out["status"], json!(200));
        let followed = seerr.server.requests_to("/api/v1/discover/movies");
        assert_eq!(followed.len(), 1);
        assert_eq!(cookie_of(&followed[0]), "connect.sid=s%3A1");
    }

    #[tokio::test]
    async fn a_csrf_token_is_echoed_on_writes() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, known| {
            (known && req.path() == "/api/v1/search").then(|| {
                Resp::json(200, json!({ "results": [] }))
                    .header("Set-Cookie", "_csrf=sec456; Path=/; HttpOnly; SameSite=Strict")
                    .header("Set-Cookie", "XSRF-TOKEN=tok%2B123; Path=/")
            })
        });
        connect(&seerr.server.url).await.unwrap();
        request("/search?query=x", None, None).await.unwrap();
        seerr.server.forget_requests();

        request("/request", Some("POST".into()), Some(json!({ "mediaType": "movie", "mediaId": 1 }))).await.unwrap();
        let write = &seerr.server.requests()[0];
        let cookie = cookie_of(write);
        assert!(cookie.contains("connect.sid=s%3A1"), "{cookie}");
        assert!(cookie.contains("_csrf=sec456"), "{cookie}");
        assert!(cookie.contains("XSRF-TOKEN=tok%2B123"), "{cookie}");
        assert_eq!(write.header("x-xsrf-token"), Some("tok+123"));
        // Reads carry the session alone.
        seerr.server.forget_requests();
        request("/movie/603", None, None).await.unwrap();
        let read = &seerr.server.requests()[0];
        assert_eq!(cookie_of(read), "connect.sid=s%3A1");
        assert_eq!(read.header("x-xsrf-token"), None);
    }

    #[tokio::test]
    async fn a_refusal_with_a_dead_session_renews_once_and_retries() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, known| {
            (known && req.path() == "/api/v1/movie/603").then(|| Resp::json(200, json!({ "id": 603 })))
        });
        connect(&seerr.server.url).await.unwrap();
        // Seerr forgets every session: the stored cookie is now nobody's.
        seerr.sessions.store(100, Ordering::SeqCst);
        seerr.server.forget_requests();
        jf.forget_requests();

        let out = request("/movie/603", None, None).await.unwrap();
        assert_eq!(out, json!({ "status": 200, "body": { "id": 603 } }));
        let asked: Vec<String> = seerr.server.requests().iter().map(|r| r.path().to_string()).collect();
        assert_eq!(
            asked,
            vec!["/api/v1/movie/603", ME, INITIATE, AUTHENTICATE, "/api/v1/movie/603"]
        );
        assert_eq!(jf.requests_to(AUTHORIZE).len(), 1);
        let retried = seerr.server.requests_to("/api/v1/movie/603");
        assert_eq!(cookie_of(&retried[0]), "connect.sid=s%3A1");
        assert_eq!(cookie_of(&retried[1]), "connect.sid=s%3A101");
        let now = status();
        assert_eq!(now["needs_reconnect"], json!(false));
        // What was known about the server carried over the renewal.
        assert_eq!(now["settings"]["applicationTitle"], json!("Requests"));
    }

    #[tokio::test]
    async fn requests_that_find_the_session_gone_together_share_one_renewal() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = plain_seerr();
        connect(&seerr.server.url).await.unwrap();
        seerr.sessions.store(100, Ordering::SeqCst);
        seerr.server.forget_requests();

        let (a, b, c) = tokio::join!(
            request("/movie/1", None, None),
            request("/movie/2", None, None),
            request("/tv/3", None, None)
        );
        assert!(a.is_ok() && b.is_ok() && c.is_ok(), "{a:?} {b:?} {c:?}");
        assert_eq!(seerr.server.requests_to(INITIATE).len(), 1);
        assert_eq!(seerr.server.requests_to(AUTHENTICATE).len(), 1);
    }

    #[tokio::test]
    async fn a_real_refusal_is_not_mistaken_for_a_dead_session() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = seerr_with(|req, known| {
            (known && req.path() == "/api/v1/request")
                .then(|| Resp::json(403, json!({ "message": "Movie Quota exceeded." })))
        });
        connect(&seerr.server.url).await.unwrap();
        seerr.server.forget_requests();

        let e = request("/request", Some("POST".into()), Some(json!({ "mediaType": "movie", "mediaId": 603 })))
            .await
            .unwrap_err();
        assert_eq!(kind_of(&e), "refused");
        assert!(words(&e).contains("used all your requests"), "{e}");
        assert!(
            !seerr.server.requests().iter().any(|r| r.path().contains("quickconnect")),
            "no sign-in was attempted"
        );
        assert_eq!(status()["needs_reconnect"], json!(false));
    }

    #[tokio::test]
    async fn when_renewal_fails_settings_is_told_to_reconnect() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let broken = Arc::new(AtomicBool::new(false));
        let flag = broken.clone();
        let seerr = seerr_with(move |req, _| {
            (flag.load(Ordering::SeqCst) && req.path() == INITIATE).then(|| Resp::status(500))
        });
        connect(&seerr.server.url).await.unwrap();
        seerr.sessions.store(100, Ordering::SeqCst);
        broken.store(true, Ordering::SeqCst);

        let e = request("/movie/603", None, None).await.unwrap_err();
        assert_eq!(e, format!("reconnect|{NEEDS_RECONNECT}"));
        let now = status();
        assert_eq!(now["connected"], json!(true), "the connection is kept for Reconnect");
        assert_eq!(now["needs_reconnect"], json!(true));

        // Reconnect, from Settings, once Seerr can sign in again.
        broken.store(false, Ordering::SeqCst);
        let out = reconnect().await.unwrap();
        assert_eq!(out["needs_reconnect"], json!(false));
        assert_eq!(request("/movie/603", None, None).await.unwrap()["status"], json!(200));
    }

    #[tokio::test]
    async fn a_seerr_that_cannot_be_reached_says_where() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let (key, _, _) = server::current_account().unwrap();
        let conn = Connection {
            server: FakeServer::dead_url(),
            cookie: "s%3Agone".into(),
            user_id: 7,
            user_name: "Ann".into(),
            permissions: 32,
            settings: None,
        };
        assert!(store(&key, &conn));
        let e = request("/movie/603", None, None).await.unwrap_err();
        assert_eq!(e, format!("unreachable|Can't reach Seerr at {}", host(&conn.server)));
        assert_eq!(status()["needs_reconnect"], json!(false), "unreachable is not signed out");
    }

    #[tokio::test]
    async fn refresh_picks_up_new_permissions_and_settings() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let promoted = Arc::new(AtomicBool::new(false));
        let flag = promoted.clone();
        let seerr = seerr_with(move |req, known| {
            if !known || !flag.load(Ordering::SeqCst) {
                return None;
            }
            match req.path() {
                ME => Some(Resp::json(200, json!({ "id": 7, "displayName": "Ann B", "permissions": 1056 }))),
                SETTINGS => {
                    let mut s = settings();
                    s["movie4kEnabled"] = json!(true);
                    Some(Resp::json(200, s))
                }
                _ => None,
            }
        });
        assert_eq!(connect(&seerr.server.url).await.unwrap()["permissions"], json!(32));
        promoted.store(true, Ordering::SeqCst);
        let out = refresh().await;
        assert_eq!(out["permissions"], json!(1056));
        assert_eq!(out["user_name"], json!("Ann B"));
        assert_eq!(out["settings"]["movie4kEnabled"], json!(true));
        assert_eq!(status(), out);
    }

    #[tokio::test]
    async fn disconnect_tells_seerr_and_forgets() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = plain_seerr();
        connect(&seerr.server.url).await.unwrap();
        seerr.server.forget_requests();

        assert_eq!(disconnect().await, json!({ "connected": false }));
        let out = seerr.server.requests_to(LOGOUT);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].method, "POST");
        assert_eq!(cookie_of(&out[0]), "connect.sid=s%3A1");
        let (key, _, _) = server::current_account().unwrap();
        assert_eq!(secret::seerr_session(&key), None);
        assert_eq!(kind_of(&request("/movie/603", None, None).await.unwrap_err()), "notconnected");
    }

    #[tokio::test]
    async fn disconnect_forgets_even_when_seerr_cannot_be_told() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let (key, _, _) = server::current_account().unwrap();
        let conn = Connection {
            server: FakeServer::dead_url(),
            cookie: "s%3Agone".into(),
            user_id: 7,
            user_name: "Ann".into(),
            permissions: 32,
            settings: None,
        };
        assert!(store(&key, &conn));
        assert_eq!(status()["connected"], json!(true));
        assert_eq!(disconnect().await, json!({ "connected": false }));
        assert_eq!(secret::seerr_session(&key), None);
    }

    #[tokio::test]
    async fn signing_out_of_jellyfin_takes_the_seerr_session_with_it() {
        let _s = sandbox();
        let jf = FakeServer::jellyfin(|req| match req.path() {
            "/QuickConnect/Enabled" => Resp::json(200, json!(true)),
            AUTHORIZE => Resp::json(200, json!(true)),
            "/Sessions/Logout" => Resp::status(204),
            _ => Resp::status(404),
        });
        sign_in(&jf.url);
        let seerr = plain_seerr();
        connect(&seerr.server.url).await.unwrap();
        let (key, _, _) = server::current_account().unwrap();
        seerr.server.forget_requests();

        server::logout().await.unwrap();
        assert_eq!(secret::seerr_session(&key), None);
        assert_eq!(seerr.server.requests_to(LOGOUT).len(), 1, "Seerr was told too");
        assert!(!config_on_disk().to_string().contains("s%3A1"));
        assert_eq!(status(), json!({ "connected": false }));
    }

    #[tokio::test]
    async fn each_jellyfin_account_has_its_own_seerr_session() {
        let _s = sandbox();
        let jf = jellyfin_approving();
        sign_in(&jf.url);
        let seerr = plain_seerr();
        connect(&seerr.server.url).await.unwrap();
        // Someone else on this device: nothing of the first account's shows.
        crate::config::merge(json!({ "user_id": "user-2", "user_name": "Bo", "account_key": null })).unwrap();
        assert_eq!(status(), json!({ "connected": false }));
        assert_eq!(kind_of(&request("/movie/603", None, None).await.unwrap_err()), "notconnected");
    }
}

/// Against the stand-in Seerr (`Aquarium/Tools/seerr-mock.py`, on
/// `AQUARIUM_QA_SEERR`, default `http://127.0.0.1:8197`) and the live QA
/// Jellyfin it signs in through. Skips, saying why, when either isn't there.
#[cfg(test)]
mod qa_tests {
    use super::*;
    use crate::test_support::with_qa_session;

    async fn stand_in() -> Option<String> {
        let base = std::env::var("AQUARIUM_QA_SEERR")
            .unwrap_or_else(|_| "http://127.0.0.1:8197".into())
            .trim_end_matches('/')
            .to_string();
        let up = jellyfin::http()
            .get(format!("{base}/api/v1/settings/public"))
            .timeout(Duration::from_millis(2500))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success());
        if !up {
            eprintln!("skipped: the stand-in Seerr is unreachable");
            return None;
        }
        Some(base)
    }

    async fn control(base: &str, path: &str) {
        let _ = jellyfin::http().post(format!("{base}/__test/{path}")).send().await;
    }

    #[tokio::test]
    async fn the_stand_in_seerr_signs_in_by_quick_connect_and_takes_a_request() {
        with_qa_session(|_qa, who| async move {
            let Some(base) = stand_in().await else { return };
            control(&base, "reset").await;

            let probed = probe(&base).await.unwrap();
            assert_eq!(probed["server"], json!(base));
            assert_eq!(probed["settings"]["mediaServerType"], json!(2));

            let out = match connect(&base).await {
                Ok(out) => out,
                Err(e) if e.starts_with("quickconnect|") => {
                    eprintln!("skipped: Quick Connect is off on the QA Jellyfin");
                    return;
                }
                Err(e) => panic!("connect failed: {e}"),
            };
            assert_eq!(out["connected"], json!(true));
            assert_eq!(out["user_name"], who["user_name"]);
            let me = out["user_id"].as_i64().unwrap();

            // Search finds a title the library lacks; asking for it works once.
            let found = request("/search?query=matrix&page=1", None, None).await.unwrap();
            let hit = found["body"]["results"]
                .as_array()
                .and_then(|r| r.iter().find(|t| t["id"] == json!(603)))
                .cloned()
                .expect("The Matrix in the stand-in's catalogue");
            assert_eq!(hit["mediaType"], json!("movie"));
            let body = json!({ "mediaType": "movie", "mediaId": 603, "is4k": false });
            let made = request("/request", Some("POST".into()), Some(body.clone())).await.unwrap();
            assert_eq!(made["status"], json!(201));
            let id = made["body"]["id"].as_i64().unwrap();
            let again = request("/request", Some("POST".into()), Some(body)).await.unwrap_err();
            assert_eq!(again, "refused|That has already been requested.");

            let mine = request(&format!("/request?take=40&skip=0&sort=added&requestedBy={me}"), None, None)
                .await
                .unwrap();
            assert!(mine["body"]["results"].as_array().unwrap().iter().any(|r| r["id"] == json!(id)));
            let title = request("/movie/603", None, None).await.unwrap();
            assert_eq!(title["body"]["mediaInfo"]["status"], json!(2));

            // A session Seerr has forgotten is renewed without anyone noticing.
            control(&base, "expire").await;
            let quota = request(&format!("/user/{me}/quota"), None, None).await.unwrap();
            assert_eq!(quota["status"], json!(200));
            assert_eq!(status()["needs_reconnect"], json!(false));

            // Withdrawing it, then leaving.
            let gone = request(&format!("/request/{id}"), Some("DELETE".into()), None).await.unwrap();
            assert_eq!(gone["status"], json!(204));
            assert_eq!(disconnect().await, json!({ "connected": false }));
            control(&base, "reset").await;
        })
        .await;
    }
}
