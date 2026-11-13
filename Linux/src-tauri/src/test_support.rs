//! Shared by the unit and integration tests of the back end. Test-only: this
//! file is compiled under `#[cfg(test)]` by the app crate (`lib.rs`) and by
//! `portable-tests/lib.rs`, and is never part of a build that ships.
//!
//! Three things live here:
//!
//! 1. The sandbox. Before any test runs, `HOME` and the XDG directories are
//!    pointed at a fresh temporary folder, and on Linux the D-Bus addresses
//!    are pointed at a socket that does not exist. No test can then read or
//!    write the developer's real config, downloads or keyring, whether or not
//!    it asks for the sandbox. `sandbox()` additionally takes a process-wide
//!    lock and empties the folder, so tests that touch config, secrets or
//!    downloads run one at a time, each from an empty config.
//! 2. `FakeServer`, a small HTTP server on 127.0.0.1 that plays the part of a
//!    Jellyfin server: it records what it was asked and answers with whatever
//!    the test told it to.
//! 3. `qa()`, the connection details of the live QA Jellyfin server for the
//!    `qa_tests` modules, or `None` (after printing why) when it is not there.
#![allow(dead_code)]

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

// ---------- The sandbox ----------

struct Roots {
    /// Everything the tests write is under here; removed when the process exits.
    root: PathBuf,
    home: PathBuf,
    /// The developer's own home and data folder, kept only to find the QA
    /// server's folder (which is read, never written).
    real_home: Option<PathBuf>,
    real_data_home: Option<PathBuf>,
    /// `AQUARIUM_TEST_REAL_DBUS=1`: the D-Bus addresses were left alone, for
    /// the opt-in `#[ignore]` tests that need a real session bus.
    real_dbus: bool,
}

static ROOTS: OnceLock<Roots> = OnceLock::new();

/// A well-formed address nothing listens on, so every D-Bus connection fails
/// at once: the Secret Service (the desktop keyring), the screen-saver and
/// session-manager inhibitors, the portal, logind, UPower.
const DEAD_BUS: &str = "unix:path=/nonexistent/aquarium-tests-have-no-bus";

fn roots() -> &'static Roots {
    ROOTS.get_or_init(|| {
        let real_home = std::env::var_os("HOME").map(PathBuf::from);
        let real_data_home = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let root = std::env::temp_dir().join(format!("aquarium-tests-{}-{}", std::process::id(), nanos));
        let home = root.join("home");
        std::fs::create_dir_all(&home).expect("could not create the test sandbox");
        // `dirs` reads $HOME/Library/Application Support on macOS and the XDG
        // variables (falling back to $HOME) on Linux.
        std::env::set_var("HOME", &home);
        std::env::set_var("XDG_CONFIG_HOME", home.join(".config"));
        std::env::set_var("XDG_DATA_HOME", home.join(".local/share"));
        std::env::set_var("XDG_CACHE_HOME", home.join(".cache"));
        let real_dbus = std::env::var("AQUARIUM_TEST_REAL_DBUS").as_deref() == Ok("1");
        if !real_dbus {
            std::env::set_var("DBUS_SESSION_BUS_ADDRESS", DEAD_BUS);
            std::env::set_var("DBUS_SYSTEM_BUS_ADDRESS", DEAD_BUS);
        }
        // SAFETY: registering a plain function with no captured state.
        unsafe {
            libc::atexit(remove_sandbox);
        }
        Roots { root, home, real_home, real_data_home, real_dbus }
    })
}

extern "C" fn remove_sandbox() {
    if let Some(r) = ROOTS.get() {
        let _ = std::fs::remove_dir_all(&r.root);
    }
}

/// Runs when the test binary is loaded, before the harness starts a single
/// test thread, so the environment is already redirected for tests that never
/// call `sandbox()` (and for other modules' tests in the same binary).
#[used]
#[cfg_attr(any(target_os = "linux", target_os = "android"), link_section = ".init_array")]
#[cfg_attr(target_os = "macos", link_section = "__DATA,__mod_init_func")]
static SANDBOX_AT_LOAD: extern "C" fn() = {
    extern "C" fn at_load() {
        roots();
    }
    at_load
};

static LOCK: Mutex<()> = Mutex::new(());

/// Held by a test for as long as it uses config, secrets or downloads.
pub struct Sandbox {
    _guard: MutexGuard<'static, ()>,
}

/// Take the sandbox: wait for any other test that holds it, then start from
/// an empty home folder, an unblocked config, no verified server and no
/// cached secrets.
pub fn sandbox() -> Sandbox {
    let guard = LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let r = roots();
    assert_eq!(
        std::env::var_os("HOME").map(PathBuf::from).as_deref(),
        Some(r.home.as_path()),
        "HOME no longer points at the test sandbox"
    );
    assert!(crate::config::config_dir().starts_with(&r.root), "config dir is outside the sandbox");
    assert!(crate::config::data_dir().starts_with(&r.root), "data dir is outside the sandbox");
    assert!(
        !(cfg!(target_os = "linux") && r.real_dbus),
        "AQUARIUM_TEST_REAL_DBUS=1 is only for the #[ignore]d D-Bus tests, run by name: \
         a test that stores a token would write to the real keyring"
    );
    let _ = std::fs::remove_dir_all(&r.home);
    std::fs::create_dir_all(&r.home).expect("could not empty the test sandbox");
    crate::config::reset_for_tests();
    crate::server::reset_for_tests();
    crate::secret::reset_for_tests();
    Sandbox { _guard: guard }
}

impl Sandbox {
    pub fn home(&self) -> PathBuf {
        roots().home.clone()
    }
}

/// True when this process was started with `AQUARIUM_TEST_REAL_DBUS=1`.
pub fn real_dbus() -> bool {
    roots().real_dbus
}

/// The token `sign_in` stores. Not a secret: it only ever reaches `FakeServer`.
pub const TEST_TOKEN: &str = "test-token-0123456789";
pub const TEST_USER: &str = "user-1";

/// Put the sandbox in the state of an install signed in to `server`.
pub fn sign_in(server: &str) {
    crate::config::merge(json!({
        "server": server,
        "user_id": TEST_USER,
        "user_name": "Tester",
    }))
    .expect("config");
    crate::secret::store(TEST_TOKEN).expect("token");
}

/// The config file as it is on disk, without `load`'s side effects.
pub fn config_on_disk() -> Value {
    std::fs::read_to_string(crate::config::config_dir().join("config.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

pub fn debug_log() -> String {
    std::fs::read_to_string(crate::config::data_dir().join("debug.log")).unwrap_or_default()
}

/// Wait for something another thread or task does. The time limit only
/// decides when to give up and fail; nothing is asserted about how long it took.
pub async fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(started.elapsed() < Duration::from_secs(30), "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

// ---------- A mock Tauri app ----------

/// An app with no window and no webview, with the download manager as state:
/// enough for the code that only wants an `AppHandle` to emit events through.
pub fn mock_app() -> tauri::App<tauri::test::MockRuntime> {
    tauri::test::mock_builder()
        .manage(crate::downloads::DlManager::default())
        .build(tauri::test::mock_context(tauri::test::noop_assets()))
        .expect("mock app")
}

/// Every payload of one event, in the order emitted.
#[derive(Clone)]
pub struct Events(Arc<Mutex<Vec<Value>>>);

impl Events {
    pub fn all(&self) -> Vec<Value> {
        self.0.lock().unwrap().clone()
    }
    /// The `state` field of each `download-progress` payload, repeats folded.
    pub fn states(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for e in self.all() {
            let s = e["state"].as_str().unwrap_or("").to_string();
            if out.last() != Some(&s) {
                out.push(s);
            }
        }
        out
    }
    pub fn last(&self) -> Value {
        self.all().last().cloned().unwrap_or(Value::Null)
    }
}

pub fn capture_events<R: tauri::Runtime>(app: &tauri::AppHandle<R>, name: &str) -> Events {
    use tauri::Listener;
    let events = Events(Arc::new(Mutex::new(Vec::new())));
    let sink = events.0.clone();
    app.listen_any(name, move |e| {
        let v = serde_json::from_str::<Value>(e.payload()).unwrap_or(Value::Null);
        sink.lock().unwrap().push(v);
    });
    events
}

// ---------- A stand-in Jellyfin server ----------

/// One request the fake server received.
#[derive(Clone, Debug)]
pub struct Req {
    pub method: String,
    /// Path and query, as sent.
    pub target: String,
    /// Names in lower case.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Req {
    /// The path without its query.
    pub fn path(&self) -> &str {
        self.target.split('?').next().unwrap_or("")
    }
    pub fn query(&self) -> &str {
        self.target.split_once('?').map(|(_, q)| q).unwrap_or("")
    }
    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers.iter().find(|(k, _)| *k == name).map(|(_, v)| v.as_str())
    }
    pub fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }
}

/// Lets a test hold a response half way and let go of it later.
#[derive(Clone, Default)]
pub struct Gate(Arc<AtomicBool>);

impl Gate {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn open(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    fn wait(&self, stop: &AtomicBool) -> bool {
        let started = Instant::now();
        while !self.0.load(Ordering::SeqCst) {
            if stop.load(Ordering::SeqCst) || started.elapsed() > Duration::from_secs(60) {
                return false;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        true
    }
}

pub enum Body {
    /// Sent whole, with a Content-Length.
    Bytes(Vec<u8>),
    /// Sent with chunked transfer encoding and no length, the way Jellyfin
    /// streams a transcode.
    Chunked(Vec<Vec<u8>>),
    /// Promises `declared` bytes, sends fewer, and closes.
    Short { declared: u64, sent: Vec<u8> },
    /// Sends `first`, waits for the gate, then sends `rest`. With `sized` the
    /// response carries a Content-Length; without, it is chunked.
    Gated { first: Vec<u8>, rest: Vec<u8>, gate: Gate, sized: bool },
    /// Chunked, and cut off after the first piece with no terminator.
    Cut(Vec<u8>),
}

pub struct Resp {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Body,
}

impl Resp {
    pub fn status(status: u16) -> Self {
        Self { status, headers: Vec::new(), body: Body::Bytes(Vec::new()) }
    }
    pub fn json(status: u16, v: Value) -> Self {
        Self::bytes(status, "application/json", v.to_string().into_bytes())
    }
    pub fn bytes(status: u16, content_type: &str, body: Vec<u8>) -> Self {
        Self {
            status,
            headers: vec![("Content-Type".into(), content_type.into())],
            body: Body::Bytes(body),
        }
    }
    pub fn body(status: u16, body: Body) -> Self {
        Self { status, headers: Vec::new(), body }
    }
    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }
}

type Handler = Arc<dyn Fn(&Req) -> Resp + Send + Sync>;

struct Shared {
    handler: Mutex<Handler>,
    log: Mutex<Vec<Req>>,
    stop: AtomicBool,
}

/// The id `FakeServer::jellyfin` reports in `/System/Info/Public`.
pub const FAKE_SERVER_ID: &str = "fake-server-id";

pub struct FakeServer {
    /// `http://127.0.0.1:<port>`, already in the form `server::normalize` gives.
    pub url: String,
    pub port: u16,
    shared: Arc<Shared>,
}

impl FakeServer {
    /// Answer every request with `handler`.
    pub fn start(handler: impl Fn(&Req) -> Resp + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let shared = Arc::new(Shared {
            handler: Mutex::new(Arc::new(handler)),
            log: Mutex::new(Vec::new()),
            stop: AtomicBool::new(false),
        });
        let for_thread = shared.clone();
        std::thread::spawn(move || {
            for sock in listener.incoming() {
                if for_thread.stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(sock) = sock else { continue };
                let shared = for_thread.clone();
                std::thread::spawn(move || serve(sock, shared));
            }
        });
        Self { url: format!("http://127.0.0.1:{port}"), port, shared }
    }

    /// A server that introduces itself as Jellyfin (`/System/Info/Public`)
    /// and hands everything else to `handler`.
    pub fn jellyfin(handler: impl Fn(&Req) -> Resp + Send + Sync + 'static) -> Self {
        Self::jellyfin_with_id(Some(FAKE_SERVER_ID), handler)
    }

    pub fn jellyfin_with_id(
        id: Option<&str>,
        handler: impl Fn(&Req) -> Resp + Send + Sync + 'static,
    ) -> Self {
        let id = id.map(str::to_owned);
        Self::start(move |req| {
            if req.path().ends_with("/System/Info/Public") {
                let mut info = json!({ "ServerName": "Fake", "Version": "10.10.0" });
                if let Some(id) = &id {
                    info["Id"] = json!(id);
                }
                return Resp::json(200, info);
            }
            handler(req)
        })
    }

    /// A server with nothing on it but its introduction.
    pub fn bare() -> Self {
        Self::jellyfin(|_| Resp::status(404))
    }

    pub fn set_handler(&self, handler: impl Fn(&Req) -> Resp + Send + Sync + 'static) {
        *self.shared.handler.lock().unwrap() = Arc::new(handler);
    }

    /// Everything asked so far, oldest first.
    pub fn requests(&self) -> Vec<Req> {
        self.shared.log.lock().unwrap().clone()
    }

    /// The requests whose path (without query) is `path`.
    pub fn requests_to(&self, path: &str) -> Vec<Req> {
        self.requests().into_iter().filter(|r| r.path() == path).collect()
    }

    pub fn forget_requests(&self) {
        self.shared.log.lock().unwrap().clear();
    }

    /// An address nothing listens on: a port that was free a moment ago.
    pub fn dead_url() -> String {
        let l = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = l.local_addr().expect("addr").port();
        drop(l);
        format!("http://127.0.0.1:{port}")
    }
}

impl Drop for FakeServer {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        // Wake the accept loop so it sees the flag and lets go of the port.
        let _ = TcpStream::connect(("127.0.0.1", self.port));
    }
}

fn serve(mut sock: TcpStream, shared: Arc<Shared>) {
    let _ = sock.set_read_timeout(Some(Duration::from_secs(10)));
    let Some(req) = read_request(&mut sock) else { return };
    shared.log.lock().unwrap().push(req.clone());
    let handler = shared.handler.lock().unwrap().clone();
    let resp = handler(&req);
    let _ = write_response(&mut sock, resp, &shared.stop);
    let _ = sock.shutdown(Shutdown::Both);
}

/// One HTTP/1.1 request, or `None` for anything else (a TLS hello, say, from
/// a client trying https first).
fn read_request(sock: &mut TcpStream) -> Option<Req> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 8192];
    let head_end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        if buf.len() > (1 << 20) {
            return None;
        }
        let n = sock.read(&mut tmp).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
    };
    let head = std::str::from_utf8(&buf[..head_end]).ok()?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next()?.split(' ');
    let method = first.next()?.to_string();
    let target = first.next()?.to_string();
    if !first.next()?.starts_with("HTTP/1.") {
        return None;
    }
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
        .collect();
    let want: usize = headers
        .iter()
        .find(|(k, _)| k == "content-length")
        .and_then(|(_, v)| v.parse().ok())
        .unwrap_or(0);
    let mut body = buf[head_end + 4..].to_vec();
    while body.len() < want {
        let n = sock.read(&mut tmp).ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    Some(Req { method, target, headers, body })
}

fn write_chunk(sock: &mut TcpStream, piece: &[u8]) -> std::io::Result<()> {
    if piece.is_empty() {
        return Ok(());
    }
    sock.write_all(format!("{:x}\r\n", piece.len()).as_bytes())?;
    sock.write_all(piece)?;
    sock.write_all(b"\r\n")?;
    sock.flush()
}

fn write_response(sock: &mut TcpStream, resp: Resp, stop: &AtomicBool) -> std::io::Result<()> {
    let mut head = format!("HTTP/1.1 {} X\r\nConnection: close\r\n", resp.status);
    for (k, v) in &resp.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    match resp.body {
        Body::Bytes(b) => {
            head.push_str(&format!("Content-Length: {}\r\n\r\n", b.len()));
            sock.write_all(head.as_bytes())?;
            sock.write_all(&b)?;
        }
        Body::Chunked(pieces) => {
            head.push_str("Transfer-Encoding: chunked\r\n\r\n");
            sock.write_all(head.as_bytes())?;
            for p in &pieces {
                write_chunk(sock, p)?;
            }
            sock.write_all(b"0\r\n\r\n")?;
        }
        Body::Short { declared, sent } => {
            head.push_str(&format!("Content-Length: {declared}\r\n\r\n"));
            sock.write_all(head.as_bytes())?;
            sock.write_all(&sent)?;
        }
        Body::Gated { first, rest, gate, sized } => {
            if sized {
                head.push_str(&format!("Content-Length: {}\r\n\r\n", first.len() + rest.len()));
                sock.write_all(head.as_bytes())?;
                sock.write_all(&first)?;
                sock.flush()?;
                if gate.wait(stop) {
                    sock.write_all(&rest)?;
                }
            } else {
                head.push_str("Transfer-Encoding: chunked\r\n\r\n");
                sock.write_all(head.as_bytes())?;
                write_chunk(sock, &first)?;
                if gate.wait(stop) {
                    write_chunk(sock, &rest)?;
                    sock.write_all(b"0\r\n\r\n")?;
                }
            }
        }
        Body::Cut(first) => {
            head.push_str("Transfer-Encoding: chunked\r\n\r\n");
            sock.write_all(head.as_bytes())?;
            write_chunk(sock, &first)?;
        }
    }
    sock.flush()
}

// ---------- The live QA Jellyfin server ----------
//
// Nothing about the server is in the repository. The address and the account
// are read at run time, by the same rule as `Linux/tests/helpers/qa.ts`:
//
//   AQUARIUM_QA_SERVER     default http://127.0.0.1:8196
//   AQUARIUM_QA_DIR        default ~/Library/Application Support/AquariumQA
//                          (or $XDG_DATA_HOME/AquariumQA elsewhere)
//   AQUARIUM_QA_USER / AQUARIUM_QA_PASSWORD
//                          the account to sign in as; overrides the files below
//   AQUARIUM_QA_WRITE=1    says the env account may have its state changed
//   AQUARIUM_QA_SKIP=1     skip every QA test
//
// Without the env account, `suite-linux` from `suite-accounts.txt` is used;
// failing that, `fixtures.json` in the QA folder is asked for a
// Linux account (any account whose name contains "linux"), then
// `device-accounts.txt` (`name=password` lines). Only an account whose name
// contains "linux" is written with; any other is used read-only.

#[derive(Clone)]
pub struct QaAccount {
    pub name: String,
    pub password: String,
    /// Tests may change this account's state (and must put it back).
    pub writable: bool,
}

pub struct Qa {
    pub server: String,
    pub account: QaAccount,
}

/// The device id the Rust QA tests sign in under. Its own, so signing out
/// here never ends a session the TypeScript suite is using.
pub const QA_DEVICE_ID: &str = "aquarium-linux-cargo-test";

fn has_linux(name: &str) -> bool {
    name.to_ascii_lowercase().contains("linux")
}

fn qa_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("AQUARIUM_QA_DIR") {
        return PathBuf::from(d);
    }
    let r = roots();
    let home = r.real_home.clone().unwrap_or_default();
    let mac = home.join("Library/Application Support/AquariumQA");
    if mac.exists() {
        return mac;
    }
    r.real_data_home
        .clone()
        .unwrap_or_else(|| home.join(".local/share"))
        .join("AquariumQA")
}

/// Every `{name, password}`-shaped object anywhere in the manifest, and every
/// `{ "<something linux>": "<password>" }` pair.
fn accounts_in(node: &Value, key: &str, out: &mut Vec<QaAccount>) {
    let entries: Vec<(String, &Value)> = match node {
        Value::Object(m) => m.iter().map(|(k, v)| (k.clone(), v)).collect(),
        Value::Array(a) => a.iter().enumerate().map(|(i, v)| (i.to_string(), v)).collect(),
        _ => return,
    };
    let first = |names: &[&str]| -> Option<Value> {
        names.iter().find_map(|n| node.get(*n).filter(|v| !v.is_null()).cloned())
    };
    let password = first(&["password", "pass", "Password"]);
    let name = first(&["name", "username", "user", "Name"])
        .or_else(|| node.get("password").filter(|v| v.is_string()).map(|_| json!(key)));
    if let (Some(n), Some(p)) = (
        name.as_ref().and_then(|v| v.as_str()),
        password.as_ref().and_then(|v| v.as_str()),
    ) {
        out.push(QaAccount { name: n.into(), password: p.into(), writable: has_linux(n) });
    }
    let keyed = node.is_object();
    for (k, v) in entries {
        let pair = v.as_str().filter(|s| !s.contains(['/', '\\', ' ']));
        match pair {
            Some(pw) if keyed && has_linux(&k) && k != "name" => {
                if node.get("name").is_none() && node.get("password").is_none() {
                    out.push(QaAccount { name: k, password: pw.into(), writable: true });
                }
            }
            _ => accounts_in(v, &k, out),
        }
    }
}

fn device_accounts(text: &str) -> Vec<QaAccount> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_once('='))
        .map(|(name, pw)| {
            let name = name.trim();
            QaAccount { name: name.into(), password: pw.trim().into(), writable: has_linux(name) }
        })
        .collect()
}

/// The suite's own account first; otherwise a plain (not parental-limited)
/// device account, read-only.
fn pick_account(
    env_user: Option<String>,
    env_password: Option<String>,
    env_write: bool,
    fixtures: Option<&Value>,
    device_file: &str,
) -> Option<QaAccount> {
    if let Some(name) = env_user.filter(|n| !n.is_empty()) {
        let writable = env_write || has_linux(&name);
        return Some(QaAccount { name, password: env_password.unwrap_or_default(), writable });
    }
    let mut all = Vec::new();
    if let Some(f) = fixtures {
        accounts_in(f, "", &mut all);
    }
    all.extend(device_accounts(device_file));
    all.iter()
        .find(|a| a.writable)
        .or_else(|| all.iter().find(|a| a.name == "qa-se"))
        .or_else(|| all.iter().find(|a| !a.name.to_ascii_lowercase().contains("kid")))
        .cloned()
}

/// The QA server and the account to use on it, or `None` when the tests
/// should skip. Says why on stderr, so a skipped run is visible in the output.
pub async fn qa() -> Option<Qa> {
    if std::env::var("AQUARIUM_QA_SKIP").as_deref() == Ok("1") {
        eprintln!("skipped: AQUARIUM_QA_SKIP=1");
        return None;
    }
    let server = std::env::var("AQUARIUM_QA_SERVER")
        .unwrap_or_else(|_| "http://127.0.0.1:8196".into())
        .trim_end_matches('/')
        .to_string();
    let up = crate::jellyfin::http()
        .get(format!("{server}/System/Info/Public"))
        .timeout(Duration::from_millis(2500))
        .send()
        .await
        .is_ok_and(|r| r.status().is_success());
    if !up {
        eprintln!("skipped: QA server unreachable");
        return None;
    }
    let dir = qa_dir();
    let fixtures: Option<Value> = std::fs::read_to_string(dir.join("fixtures.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok());
    let device_file = std::fs::read_to_string(dir.join("device-accounts.txt")).unwrap_or_default();
    // suite-accounts.txt has one account per test suite; `suite-linux` is
    // this one's, and the only one written with.
    let suite = std::fs::read_to_string(dir.join("suite-accounts.txt")).unwrap_or_default();
    let own = device_accounts(&suite)
        .into_iter()
        .find(|a| a.name == "suite-linux")
        .filter(|_| std::env::var("AQUARIUM_QA_USER").is_err());
    let account = own.or_else(|| pick_account(
        std::env::var("AQUARIUM_QA_USER").ok(),
        std::env::var("AQUARIUM_QA_PASSWORD").ok(),
        std::env::var("AQUARIUM_QA_WRITE").as_deref() == Ok("1"),
        fixtures.as_ref(),
        &device_file,
    ));
    let Some(account) = account else {
        eprintln!("skipped: no QA account known");
        return None;
    };
    Some(Qa { server, account })
}

/// Sign the sandbox in to the QA server through the app's own `login`.
/// `None` (after saying so) if the server refuses the account.
pub async fn qa_login(qa: &Qa) -> Option<Value> {
    crate::config::merge(json!({ "device_id": QA_DEVICE_ID })).expect("config");
    match crate::server::login(&qa.server, &qa.account.name, &qa.account.password).await {
        Ok(v) => Some(v),
        Err(e) => {
            eprintln!("skipped: QA sign-in failed ({})", e.split('|').next().unwrap_or(""));
            None
        }
    }
}

/// Run `body` signed in to the QA server, and sign out (revoking the session
/// on the server) whether it passed or panicked.
pub async fn with_qa_session<F, Fut>(body: F)
where
    F: FnOnce(Qa, Value) -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    use futures_util::FutureExt;
    let _sandbox = sandbox();
    let Some(qa) = qa().await else { return };
    let Some(who) = qa_login(&qa).await else { return };
    let outcome = std::panic::AssertUnwindSafe(body(qa, who)).catch_unwind().await;
    let out = crate::server::logout().await;
    if let Err(panic) = outcome {
        std::panic::resume_unwind(panic);
    }
    assert_eq!(out.expect("logout")["revoked"], json!(true), "the QA session was not revoked");
}

/// One item from the QA library, looked up by name at run time.
pub async fn qa_find_item(types: &str, search: &str, fields: &str) -> Option<Value> {
    let user = crate::config::load()["user_id"].as_str().unwrap_or_default().to_string();
    let path = format!(
        "/Items?userId={user}&Recursive=true&IncludeItemTypes={types}&searchTerm={}&Fields={fields}&Limit=50",
        search.replace(' ', "%20")
    );
    let out = crate::server::request(&path, None, None).await.ok()?;
    out["body"]["Items"]
        .as_array()?
        .iter()
        .find(|i| i["Name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(search)))
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sandbox_is_in_place_before_any_test_asks_for_it() {
        // No call to sandbox() here on purpose: the redirect happens at load.
        let r = ROOTS.get().expect("the load-time hook did not run");
        assert!(crate::config::config_dir().starts_with(&r.root));
        assert!(crate::config::data_dir().starts_with(&r.root));
        assert!(crate::config::downloads_dir().starts_with(&r.root));
        assert_ne!(r.real_home.as_deref(), Some(r.home.as_path()));
        if !r.real_dbus {
            assert_eq!(std::env::var("DBUS_SESSION_BUS_ADDRESS").as_deref(), Ok(DEAD_BUS));
            assert_eq!(std::env::var("DBUS_SYSTEM_BUS_ADDRESS").as_deref(), Ok(DEAD_BUS));
        }
    }

    #[test]
    fn each_sandbox_starts_empty() {
        {
            let _s = sandbox();
            sign_in("http://127.0.0.1:1");
            assert!(crate::secret::token().is_some());
            assert_eq!(config_on_disk()["user_id"], json!(TEST_USER));
        }
        let _s = sandbox();
        assert_eq!(config_on_disk(), Value::Null);
        assert!(crate::secret::token().is_none());
    }

    #[tokio::test]
    async fn the_fake_server_records_and_answers() {
        let server = FakeServer::jellyfin(|req| match req.path() {
            "/echo" => Resp::json(200, json!({ "method": req.method, "q": req.query(), "body": req.json() })),
            "/chunked" => Resp::body(200, Body::Chunked(vec![b"ab".to_vec(), b"cd".to_vec()])),
            _ => Resp::status(404),
        });
        let http = crate::jellyfin::http();
        let info: Value = http
            .get(format!("{}/System/Info/Public", server.url))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(info["Id"], json!(FAKE_SERVER_ID));
        let echo: Value = http
            .post(format!("{}/echo?a=1", server.url))
            .header("X-Test", "yes")
            .json(&json!({ "k": 2 }))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(echo, json!({ "method": "POST", "q": "a=1", "body": { "k": 2 } }));
        let chunked = http.get(format!("{}/chunked", server.url)).send().await.unwrap();
        assert_eq!(chunked.content_length(), None);
        assert_eq!(chunked.text().await.unwrap(), "abcd");
        assert_eq!(http.get(format!("{}/nope", server.url)).send().await.unwrap().status(), 404);

        let seen = server.requests_to("/echo");
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].header("x-test"), Some("yes"));
        assert_eq!(server.requests().len(), 4);
    }

    #[tokio::test]
    async fn a_dead_address_refuses_connections() {
        let url = FakeServer::dead_url();
        assert!(crate::jellyfin::http().get(&url).send().await.is_err());
    }

    fn names(list: &[QaAccount]) -> Vec<(&str, bool)> {
        list.iter().map(|a| (a.name.as_str(), a.writable)).collect()
    }

    #[test]
    fn accounts_are_found_anywhere_in_the_manifest() {
        let manifest = json!({
            "server": "http://127.0.0.1:8196",
            "accounts": [
                { "name": "qa-se", "password": "a" },
                { "username": "qa-linux", "pass": "b" },
            ],
            "nested": { "people": { "qa-kid": { "password": "c" } } },
            "linux": { "qa-linux-2": "d", "path-linux": "/not/a password" },
        });
        let mut out = Vec::new();
        accounts_in(&manifest, "", &mut out);
        let mut got = names(&out);
        got.sort();
        assert_eq!(
            got,
            vec![("qa-kid", false), ("qa-linux", true), ("qa-linux-2", true), ("qa-se", false)]
        );
    }

    #[test]
    fn device_accounts_are_name_equals_password_lines() {
        let list = device_accounts("# comment\nqa-se = one\n\nqa-linux=two=three\nnot a line\n");
        assert_eq!(names(&list), vec![("qa-se", false), ("qa-linux", true)]);
        assert_eq!(list[1].password, "two=three");
    }

    #[test]
    fn the_linux_account_is_preferred_and_is_the_only_one_written_with() {
        let file = "qa-duo=1\nqa-kid=2\nqa-se=3\n";
        // No Linux account: the plain phone account, read-only.
        let a = pick_account(None, None, false, None, file).unwrap();
        assert_eq!((a.name.as_str(), a.writable), ("qa-se", false));
        // Without qa-se: the first that is not parental-limited.
        let a = pick_account(None, None, false, None, "qa-kid=2\nqa-tv=3\n").unwrap();
        assert_eq!(a.name, "qa-tv");
        // A Linux account anywhere wins.
        let fixtures = json!({ "accounts": [{ "name": "qa-linux", "password": "x" }] });
        let a = pick_account(None, None, false, Some(&fixtures), file).unwrap();
        assert_eq!((a.name.as_str(), a.writable), ("qa-linux", true));
        // The environment overrides both files.
        let a = pick_account(Some("someone".into()), Some("pw".into()), false, Some(&fixtures), file).unwrap();
        assert_eq!((a.name.as_str(), a.writable), ("someone", false));
        let a = pick_account(Some("someone".into()), None, true, None, "").unwrap();
        assert!(a.writable);
        assert!(pick_account(None, None, false, None, "").is_none());
    }
}
