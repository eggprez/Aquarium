use crate::{config, jellyfin};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, Runtime};
use tokio::io::AsyncWriteExt;

#[derive(Deserialize)]
pub struct DownloadRequest {
    pub item_id: String,
    pub url: String,
    pub file_name: String,
    #[serde(default)]
    pub image_url: Option<String>,
    /// Portrait series poster for episodes (the episode's own image is a still).
    #[serde(default)]
    pub series_image_url: Option<String>,
    /// Portrait season poster for episodes (used on season cards).
    #[serde(default)]
    pub season_image_url: Option<String>,
    /// Frontend estimate for transcoded downloads, where the server streams
    /// chunked with no Content-Length.
    #[serde(default)]
    pub estimated_bytes: Option<u64>,
    /// Opaque item metadata from the frontend (name, series, runtime, quality label…).
    pub meta: Value,
}

/// What a running transfer has been asked to do, read on every chunk.
const RUN: u8 = 0;
/// Stop and throw away what arrived.
const CANCEL: u8 = 1;
/// Stop and keep the `.part` file, so the queue can carry on from it later.
const PAUSE: u8 = 2;

#[derive(Default)]
pub struct DlManager {
    cancels: Mutex<HashMap<String, Arc<AtomicU8>>>,
    /// Held while anything is transferring and Settings' "Keep the laptop
    /// awake" is on, so an idle suspend doesn't cut a season off half way.
    /// Separate from the player's screen inhibitor: a download needs the
    /// machine running, not the screen lit.
    awake: Mutex<Option<crate::idle::SuspendInhibitor>>,
}

/// How many times a failed transfer is put back in the queue on its own before
/// it is left in Failed for someone to look at, and how long each wait is.
/// The count goes back to zero whenever an attempt gets somewhere, so a long
/// download over a link that keeps dropping isn't bounded by it: only one that
/// fails the same way from the same place is. Apple's numbers.
const MAX_AUTO_RETRIES: u64 = 5;
const RETRY_DELAYS: [u64; 5] = [5, 15, 45, 120, 300];
/// What an attempt has to fetch before it counts as having got somewhere.
const PROGRESS_WORTH_RESETTING: u64 = 4 << 20;

/// How long to wait on a single poll of the byte stream.
const STALL_POLL: std::time::Duration = std::time::Duration::from_secs(5);
/// Total silence from the server before the download is declared stalled.
const STALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(90);

/// The folder a download lives in, for an id that is safe to use as one.
///
/// The id arrives over IPC and is joined straight onto the downloads folder,
/// so `..` (or anything with a slash, or an absolute path, which `join` would
/// take in place of the base) would point `delete` at the data folder or
/// beyond. Jellyfin item ids are GUIDs, so anything that isn't a short run of
/// letters, digits, `-` and `_` is refused rather than cleaned up.
pub(crate) fn item_dir(item_id: &str) -> Result<PathBuf, String> {
    let ok = !item_id.is_empty()
        && item_id.len() <= 64
        && item_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !ok {
        return Err(format!("not a valid item id: {:?}", item_id.chars().take(70).collect::<String>()));
    }
    Ok(config::downloads_dir().join(item_id))
}

/// Files in an item's folder that the app owns. A title called "meta" in a
/// "json" container would otherwise replace the record with the server's bytes.
const RESERVED_FILE_NAMES: [&str; 4] =
    ["meta.json", "poster.jpg", "series_poster.jpg", "season_poster.jpg"];

/// Fields of a record that `list` works out from the folder each time. Whatever
/// is stored under these names is ignored: `path` goes straight to mpv.
const COMPUTED_PATHS: [&str; 4] =
    ["path", "poster_path", "series_poster_path", "season_poster_path"];

/// The same guard for the file name a download is saved under, which is
/// joined onto the item's folder. The frontend already replaces anything
/// unusual in it; this stops it leaving the folder or replacing the app's files.
fn check_file_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\0')
        || RESERVED_FILE_NAMES.contains(&name)
    {
        return Err(format!("not a valid file name: {name:?}"));
    }
    Ok(())
}

/// Read an item's record. Anything but a JSON object counts as no record:
/// assigning a field on any other JSON value panics.
fn read_meta(path: &std::path::Path) -> Option<Value> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str::<Value>(&text)
        .ok()
        .filter(Value::is_object)
}

/// Replace a record's paths with what is actually in its folder.
fn refresh_paths(meta: &mut Value, dir: &std::path::Path) {
    let Some(fields) = meta.as_object_mut() else {
        return;
    };
    for key in COMPUTED_PATHS {
        fields.remove(key);
    }
    let file = meta.get("file").and_then(|v| v.as_str()).unwrap_or("");
    if check_file_name(file).is_ok() {
        let fpath = dir.join(file);
        if fpath.is_file() {
            meta["path"] = json!(fpath.to_string_lossy());
            meta["size_bytes"] = json!(fpath.metadata().map(|m| m.len()).unwrap_or(0));
        }
    }
    for (name, key) in [
        ("poster.jpg", "poster_path"),
        ("series_poster.jpg", "series_poster_path"),
        ("season_poster.jpg", "season_poster_path"),
    ] {
        let poster = dir.join(name);
        if poster.exists() {
            meta[key] = json!(poster.to_string_lossy());
        }
    }
}

/// Bytes an unprivileged process can still write to the filesystem holding the
/// downloads directory, or `None` when the platform won't say.
///
/// Queueing a season used to be unconditional: forty episodes at original
/// quality went onto a disk with fifteen gigabytes free and the user found out
/// four episodes in, as a row that had turned red.
pub fn free_space() -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;

    // On a fresh install nothing under the data directory exists yet, and
    // statvfs on a missing path just fails — walk up to something real.
    let mut dir = config::downloads_dir();
    while !dir.exists() {
        if !dir.pop() {
            return None;
        }
    }

    let path = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `path` is a valid NUL-terminated string and `st` is a live
    // statvfs the call is allowed to fill in.
    if unsafe { libc::statvfs(path.as_ptr(), &mut st) } != 0 {
        return None;
    }
    // f_bavail, not f_bfree: the difference is the root reserve, which this
    // process can't touch.
    (st.f_bavail as u64).checked_mul(st.f_frsize as u64)
}

fn write_meta(dir: &PathBuf, meta: &Value) {
    if let Ok(s) = serde_json::to_string_pretty(meta) {
        let _ = std::fs::write(dir.join("meta.json"), s);
    }
}

// Generic over the runtime only so the tests can drive it with tauri's
// MockRuntime; the app always passes its Wry handle.
fn emit<R: Runtime>(app: &AppHandle<R>, payload: Value) {
    let _ = app.emit("download-progress", payload);
}

impl DlManager {
    pub fn cancel(&self, item_id: &str) {
        if let Some(flag) = self.cancels.lock().unwrap().get(item_id) {
            flag.store(CANCEL, Ordering::SeqCst);
        }
    }

    /// Stop a transfer but keep what it fetched. It ends with a `paused`
    /// event and `status: "paused"` in meta.json; the frontend queue, which
    /// asked, has already put it back in line to carry on from the `.part`.
    pub fn pause(&self, item_id: &str) {
        if let Some(flag) = self.cancels.lock().unwrap().get(item_id) {
            flag.store(PAUSE, Ordering::SeqCst);
        }
    }

    /// Take or drop the suspend inhibitor to match what is running now.
    /// Read from config each time, so flipping the setting mid-season only
    /// needs a call here.
    pub fn sync_keep_awake(&self) {
        let want = self.active_count() > 0
            && config::load().get("downloads_keep_awake").and_then(|v| v.as_bool()) != Some(false);
        let mut held = self.awake.lock().unwrap();
        if want == held.is_some() {
            return;
        }
        if want {
            match crate::idle::SuspendInhibitor::new("Downloading") {
                Ok(i) => *held = Some(i),
                Err(e) => crate::debug_log_line(&format!("downloads: suspend inhibit failed: {e}")),
            }
        } else {
            *held = None;
        }
    }

    pub fn is_active(&self, item_id: &str) -> bool {
        self.cancels.lock().unwrap().contains_key(item_id)
    }

    /// Transfers currently running. Read at quit time: closing the window
    /// silently kills them mid-file, so the user gets asked first.
    pub fn active_count(&self) -> usize {
        self.cancels.lock().unwrap().len()
    }

    pub fn start<R: Runtime>(&self, app: AppHandle<R>, req: DownloadRequest) -> Result<(), String> {
        {
            let cancels = self.cancels.lock().unwrap();
            if cancels.contains_key(&req.item_id) {
                return Err("download already in progress for this item".into());
            }
        }

        let dir = item_dir(&req.item_id)?;
        check_file_name(&req.file_name)?;
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

        let mut meta = if req.meta.is_object() { req.meta.clone() } else { json!({}) };
        if let Some(o) = meta.as_object_mut() {
            o.remove("error"); // stale from a failed run being retried
        }
        meta["item_id"] = json!(req.item_id);
        meta["file"] = json!(req.file_name);
        meta["status"] = json!("downloading");
        if let Some(est) = req.estimated_bytes {
            meta["estimated_bytes"] = json!(est);
        }
        // Everything needed to restart this download after an interruption
        // (app closed mid-transfer, network drop).
        meta["request"] = json!({
            "url": strip_api_key(&req.url),
            "image_url": req.image_url,
            "series_image_url": req.series_image_url,
            "season_image_url": req.season_image_url,
            "estimated_bytes": req.estimated_bytes,
        });
        write_meta(&dir, &meta);

        let flag = Arc::new(AtomicU8::new(RUN));
        self.cancels
            .lock()
            .unwrap()
            .insert(req.item_id.clone(), flag.clone());
        self.sync_keep_awake();

        crate::debug_log_line(&format!(
            "download start {} ({})",
            req.item_id,
            meta.get("title").and_then(|v| v.as_str()).unwrap_or("")
        ));

        let cancels_key = req.item_id.clone();
        // Self is managed state (alive for the app's lifetime); use a raw
        // pointer-free approach: clean the map entry via a clone of the Arc map.
        let app2 = app.clone();
        tauri::async_runtime::spawn(async move {
            let fetched = AtomicU64::new(0);
            let result = run_download(&app2, &req, &dir, flag.clone(), &fetched).await;

            let mut meta = read_meta(&dir.join("meta.json")).unwrap_or_else(|| json!({}));

            crate::debug_log_line(&format!(
                "download {} -> {}",
                req.item_id,
                match &result {
                    Ok(()) => "complete".to_string(),
                    Err(e) => e.clone(),
                }
            ));

            // Off the map before anything is announced: the frontend queue
            // reacts to the event by starting the next one, and a retry of
            // this same item would otherwise be refused as still running.
            if let Some(mgr) = app2.try_state::<DlManager>() {
                mgr.cancels.lock().unwrap().remove(&cancels_key);
                mgr.sync_keep_awake();
            }

            match result {
                Ok(()) => {
                    meta["status"] = json!("complete");
                    if let Some(o) = meta.as_object_mut() {
                        o.remove("error");
                        o.remove("auto_retries");
                        o.remove("verify_failures");
                    }
                    write_meta(&dir, &meta);
                    emit(
                        &app2,
                        json!({ "item_id": req.item_id, "state": "complete" }),
                    );
                    // Best effort and after the fact: a download without its
                    // subtitles is still a download.
                    let original = is_original_url(&req.url);
                    let item_id = req.item_id.clone();
                    tauri::async_runtime::spawn(async move {
                        crate::download_extras::fetch_subtitles(&item_id, original).await;
                    });
                }
                Err(e) if e == "canceled" => {
                    let _ = std::fs::remove_dir_all(&dir);
                    emit(
                        &app2,
                        json!({ "item_id": req.item_id, "state": "canceled" }),
                    );
                }
                Err(e) if e == "paused" => {
                    meta["status"] = json!("paused");
                    write_meta(&dir, &meta);
                    emit(&app2, json!({ "item_id": req.item_id, "state": "paused" }));
                }
                Err(e) => {
                    let (message, retry_in) =
                        after_failure(&mut meta, &e, fetched.load(Ordering::SeqCst));
                    if e.starts_with("incomplete") {
                        // Nothing of the short copy is worth resuming from.
                        let _ = std::fs::remove_file(dir.join(format!("{}.part", req.file_name)));
                        let _ = std::fs::remove_file(dir.join(&req.file_name));
                    }
                    meta["status"] = json!("error");
                    meta["error"] = json!(message);
                    write_meta(&dir, &meta);
                    emit(
                        &app2,
                        json!({
                            "item_id": req.item_id,
                            "state": "error",
                            "message": message,
                            "retry_in": retry_in,
                        }),
                    );
                }
            }
        });

        Ok(())
    }
}

/// The original file (`/Items/{id}/Download`) rather than a transcode.
pub(crate) fn is_original_url(url: &str) -> bool {
    url.split('?').next().unwrap_or("").ends_with("/Download")
}

/// Whether a transcode that reached `got` seconds stopped short of an item
/// `runtime` seconds long. Generous on purpose: the encoder's last cluster
/// starts a few seconds before the end, and runtimes are rounded. Short items
/// (trailers, extras) aren't judged at all.
fn is_short(got: f64, runtime: f64) -> bool {
    runtime >= 120.0 && got < runtime - (runtime * 0.05).max(60.0)
}

/// Whether a failure is worth trying again unasked. The network and the
/// server's own troubles are; a 404, a refused token or a full disk are not
/// going to change in five seconds.
fn is_retryable(e: &str) -> bool {
    if let Some(code) = e.strip_prefix("server returned ") {
        let n: u16 = code.split_whitespace().next().and_then(|c| c.parse().ok()).unwrap_or(0);
        return n >= 500 || n == 408 || n == 429;
    }
    e.starts_with("request failed") || e.starts_with("stream error") || e.starts_with("stalled")
}

/// Book-keep a failed attempt in its meta and decide what happens next:
/// the message for the row, and how many seconds until the frontend queue
/// tries it again by itself (`None` leaves it in Failed).
fn after_failure(meta: &mut Value, e: &str, fetched: u64) -> (String, Option<u64>) {
    if e.starts_with("incomplete") {
        let n = meta.get("verify_failures").and_then(|v| v.as_u64()).unwrap_or(0) + 1;
        meta["verify_failures"] = json!(n);
        return if n <= 1 {
            ("The first copy arrived incomplete — fetching it again".into(), Some(2))
        } else {
            ("The file arrived incomplete twice".into(), None)
        };
    }
    if !is_retryable(e) {
        return (e.to_string(), None);
    }
    let mut n = meta.get("auto_retries").and_then(|v| v.as_u64()).unwrap_or(0);
    if fetched >= PROGRESS_WORTH_RESETTING {
        n = 0;
    }
    n += 1;
    meta["auto_retries"] = json!(n);
    if n > MAX_AUTO_RETRIES {
        return (format!("{e} — stopped after {MAX_AUTO_RETRIES} attempts"), None);
    }
    let delay = RETRY_DELAYS[(n as usize - 1).min(RETRY_DELAYS.len() - 1)];
    (format!("{e} — trying again"), Some(delay))
}

/// How far into the picture a Matroska file gets, from the timestamp of its
/// last cluster. Jellyfin's transcode is muxed live, so the header carries no
/// duration to read; the clusters are the only record of how much arrived.
/// `None` for anything that isn't Matroska or can't be read.
pub(crate) fn mkv_duration_secs(path: &std::path::Path) -> Option<f64> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let mut head = vec![0u8; len.min(64 << 10) as usize];
    f.read_exact(&mut head).ok()?;
    if head.get(..4)? != [0x1A, 0x45, 0xDF, 0xA3] {
        return None;
    }
    let tail_len = len.min(16 << 20);
    f.seek(SeekFrom::Start(len - tail_len)).ok()?;
    let mut tail = vec![0u8; tail_len as usize];
    f.read_exact(&mut tail).ok()?;
    mkv_duration_from(&head, &tail)
}

/// The arithmetic behind `mkv_duration_secs`, over the first and last bytes of
/// the file.
fn mkv_duration_from(head: &[u8], tail: &[u8]) -> Option<f64> {
    // TimestampScale (0x2AD7B1) in Info, nanoseconds per tick; 1 ms if absent.
    let scale = find_all(head, &[0x2A, 0xD7, 0xB1])
        .find_map(|i| read_uint_element(head, i + 3))
        .unwrap_or(1_000_000);
    // The last Cluster (0x1F43B675) whose first child is its Timestamp (0xE7).
    let ts = find_all(tail, &[0x1F, 0x43, 0xB6, 0x75])
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .find_map(|i| {
            let (_, n) = read_vint(tail, i + 4)?;
            let mut at = i + 4 + n;
            // ffmpeg puts a CRC-32 (0xBF) ahead of the timestamp.
            if *tail.get(at)? == 0xBF {
                let (len, m) = read_vint(tail, at + 1)?;
                at += 1 + m + len as usize;
            }
            (*tail.get(at)? == 0xE7).then_some(())?;
            read_uint_element(tail, at + 1)
        })?;
    Some(ts as f64 * scale as f64 / 1e9)
}

fn find_all<'a>(hay: &'a [u8], needle: &'a [u8]) -> impl Iterator<Item = usize> + 'a {
    hay.windows(needle.len()).enumerate().filter(move |(_, w)| *w == needle).map(|(i, _)| i)
}

/// An EBML variable-length size at `at`: (value, bytes used).
fn read_vint(buf: &[u8], at: usize) -> Option<(u64, usize)> {
    let first = *buf.get(at)?;
    let n = first.leading_zeros() as usize + 1;
    if n > 8 {
        return None;
    }
    let mut v = (first as u64) & (0xFF >> n);
    for k in 1..n {
        v = (v << 8) | *buf.get(at + k)? as u64;
    }
    Some((v, n))
}

/// The size and then the big-endian unsigned value of an element whose id
/// ends just before `at`.
fn read_uint_element(buf: &[u8], at: usize) -> Option<u64> {
    let (size, n) = read_vint(buf, at)?;
    if size == 0 || size > 8 {
        return None;
    }
    let bytes = buf.get(at + n..at + n + size as usize)?;
    Some(bytes.iter().fold(0u64, |v, &b| (v << 8) | b as u64))
}

/// Remove an `api_key=` parameter from a URL. Applied to every URL on its way
/// into meta.json, which is a plain file in the downloads folder and outlives
/// the transfer that created it.
fn strip_api_key(url: &str) -> String {
    let Some((base, query)) = url.split_once('?') else {
        return url.to_string();
    };
    let kept: Vec<&str> = query
        .split('&')
        .filter(|p| !p.starts_with("api_key=") && !p.starts_with("ApiKey="))
        .collect();
    if kept.is_empty() {
        base.to_string()
    } else {
        format!("{}?{}", base, kept.join("&"))
    }
}

/// Current credentials as an `Authorization` header value. Rebuilt per request
/// from the keyring rather than stored alongside the download, so a resumed
/// transfer picks up the token in force today and no copy of it is written to
/// meta.json.
fn auth_header_now() -> Option<String> {
    let token = crate::secret::token()?;
    let cfg = config::load();
    let device = cfg
        .get("device_id")
        .and_then(|v| v.as_str())
        .unwrap_or("aquarium");
    Some(jellyfin::auth_header(&token, device))
}

/// Best-effort image fetch, skipped if already on disk from a previous run.
async fn fetch_image(url: &Option<String>, path: PathBuf) {
    let Some(img) = url.as_ref().filter(|_| !path.exists()) else {
        return;
    };
    if let Ok(resp) = jellyfin::http().get(img).send().await {
        if resp.status().is_success() {
            if let Ok(bytes) = resp.bytes().await {
                let _ = std::fs::write(path, &bytes);
            }
        }
    }
}

async fn run_download<R: Runtime>(
    app: &AppHandle<R>,
    req: &DownloadRequest,
    dir: &PathBuf,
    stop: Arc<AtomicU8>,
    fetched: &AtomicU64,
) -> Result<(), String> {
    // A stored download can outlive the sign-in it was started under, and the
    // header below is today's token. Sending it to the address in an old record
    // would hand this server's credential to the previous one.
    if !crate::server::is_session_origin(&req.url) {
        return Err("This download is from a different server. Delete it, or sign in to that server to finish it.".into());
    }

    // Posters first (best effort, small): the item's own image, plus the
    // portrait series/season posters for episodes (used on show/season cards).
    fetch_image(&req.image_url, dir.join("poster.jpg")).await;
    fetch_image(&req.series_image_url, dir.join("series_poster.jpg")).await;
    fetch_image(&req.season_image_url, dir.join("season_poster.jpg")).await;

    let final_path = dir.join(&req.file_name);
    let part_path = dir.join(format!("{}.part", req.file_name));

    // Leftover partial file from an interrupted run: ask the server to resume
    // where it stopped. Only static downloads honor Range; transcodes return
    // 200 and we start over.
    let mut part_len = std::fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0);
    let ask = |from: u64| {
        let mut request = jellyfin::http().get(&req.url);
        // Authenticate by header. The URL is persisted in meta.json so an
        // interrupted transfer can be resumed, and an `api_key=` in it would
        // leave a live credential lying in the downloads folder (as well as in
        // the server's access log).
        if let Some(auth) = auth_header_now() {
            request = request.header("Authorization", auth);
        }
        if from > 0 {
            request = request.header("Range", format!("bytes={}-", from));
        }
        request.send()
    };
    let mut resp = ask(part_len).await.map_err(|e| format!("request failed: {}", e))?;
    // 416: the .part reaches the end of the file or past it. An earlier run
    // stopped between its last byte and the rename leaves the whole file
    // there (the server answers `bytes */<its length>`), and that copy is
    // finished as it is; anything else is not this file, and starts over.
    if part_len > 0 && resp.status().as_u16() == 416 {
        let whole = resp
            .headers()
            .get("content-range")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("bytes */"))
            .and_then(|n| n.trim().parse::<u64>().ok());
        if whole == Some(part_len) {
            return tokio::fs::rename(&part_path, &final_path).await.map_err(|e| e.to_string());
        }
        let _ = tokio::fs::remove_file(&part_path).await;
        part_len = 0;
        resp = ask(0).await.map_err(|e| format!("request failed: {}", e))?;
    }
    if !resp.status().is_success() {
        return Err(format!("server returned {}", resp.status()));
    }
    let resumed = part_len > 0 && resp.status().as_u16() == 206;
    let exact_total = resp
        .content_length()
        .map(|l| if resumed { l + part_len } else { l });
    let total = exact_total.or(req.estimated_bytes);
    let estimated = exact_total.is_none();

    let mut file = if resumed {
        tokio::fs::OpenOptions::new()
            .append(true)
            .open(&part_path)
            .await
            .map_err(|e| e.to_string())?
    } else {
        tokio::fs::File::create(&part_path)
            .await
            .map_err(|e| e.to_string())?
    };
    let mut stream = resp.bytes_stream();
    let mut received: u64 = if resumed { part_len } else { 0 };
    let mut last_emit = std::time::Instant::now();
    let mut last_emit_bytes: u64 = received;
    let mut speed_bps: f64 = 0.0;
    let mut idle = std::time::Duration::ZERO;

    loop {
        match stop.load(Ordering::SeqCst) {
            CANCEL => {
                drop(file);
                let _ = tokio::fs::remove_file(&part_path).await;
                return Err("canceled".into());
            }
            PAUSE => {
                // The .part stays: the next go asks for the rest with Range.
                let _ = file.flush().await;
                return Err("paused".into());
            }
            _ => {}
        }
        // A Jellyfin transcode that dies (or is throttled into oblivion) leaves
        // the connection open and simply stops sending. Without this the task
        // would await forever, never emit a terminal state, and the frontend
        // queue would sit behind it for good. Poll in short ticks so cancel
        // still responds promptly.
        let chunk = match tokio::time::timeout(STALL_POLL, stream.next()).await {
            Ok(Some(c)) => {
                idle = std::time::Duration::ZERO;
                c
            }
            Ok(None) => break,
            Err(_) => {
                idle += STALL_POLL;
                if idle >= STALL_TIMEOUT {
                    // The .part file is left in place: retry resumes from it
                    // for static downloads and restarts cleanly otherwise.
                    return Err(format!(
                        "stalled: no data from the server for {}s",
                        STALL_TIMEOUT.as_secs()
                    ));
                }
                continue;
            }
        };
        let chunk = chunk.map_err(|e| format!("stream error: {}", e))?;
        file.write_all(&chunk).await.map_err(|e| e.to_string())?;
        received += chunk.len() as u64;
        fetched.fetch_add(chunk.len() as u64, Ordering::SeqCst);
        let dt = last_emit.elapsed().as_secs_f64();
        if dt >= 0.4 {
            let inst = (received - last_emit_bytes) as f64 / dt;
            // Smooth the rate so the ETA doesn't jitter.
            speed_bps = if speed_bps == 0.0 { inst } else { 0.3 * inst + 0.7 * speed_bps };
            emit(
                app,
                json!({
                    "item_id": req.item_id,
                    "state": "downloading",
                    "received": received,
                    "total": total,
                    "estimated": estimated,
                    "speed_bps": speed_bps as u64,
                }),
            );
            last_emit = std::time::Instant::now();
            last_emit_bytes = received;
        }
    }
    file.flush().await.map_err(|e| e.to_string())?;
    drop(file);

    // The stream ended cleanly, which on its own proves little. A static file
    // has a length to hold it to. A transcode is chunked and has none, and a
    // server-side encoder that dies part way closes the response as tidily as
    // one that finished, so the copy is held to the item's runtime instead.
    if let Some(t) = exact_total.filter(|&t| received < t) {
        return Err(format!("incomplete: {received} of {t} bytes"));
    }
    if exact_total.is_none() {
        let runtime = req
            .meta
            .get("run_time_ticks")
            .and_then(|v| v.as_u64())
            .map(|t| t as f64 / 10_000_000.0);
        let part = part_path.clone();
        let reached = tokio::task::spawn_blocking(move || mkv_duration_secs(&part))
            .await
            .ok()
            .flatten();
        if let (Some(rt), Some(got)) = (runtime, reached) {
            if is_short(got, rt) {
                return Err(format!("incomplete: {:.0}s of {:.0}s", got, rt));
            }
        }
    }

    tokio::fs::rename(&part_path, &final_path)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Rebuild a DownloadRequest from an item's on-disk meta.json (the "request"
/// block written by `start`) and start it again. Any existing .part file is
/// picked up by the Range-resume logic in `run_download`.
///
/// `manual` is a Retry someone pressed: it starts the automatic attempts and
/// the incomplete-copy count over, where the queue's own retries carry on
/// counting.
pub fn restart<R: Runtime>(app: AppHandle<R>, mgr: &DlManager, item_id: &str, manual: bool) -> Result<(), String> {
    let dir = item_dir(item_id)?;
    let mut meta: Value = std::fs::read_to_string(dir.join("meta.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .ok_or("no download metadata for this item")?;
    if manual {
        if let Some(o) = meta.as_object_mut() {
            o.remove("auto_retries");
            o.remove("verify_failures");
        }
    }
    let request = meta
        .get("request")
        .ok_or("download predates resume support; delete and re-download")?;
    let str_of = |v: &Value, k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
    let req = DownloadRequest {
        item_id: item_id.to_string(),
        // Downloads queued by an older build stored the token in the URL; drop
        // it on the way back out so resuming one also stops carrying it.
        url: strip_api_key(&str_of(request, "url").ok_or("stored request has no url")?),
        file_name: str_of(&meta, "file").ok_or("stored meta has no file name")?,
        image_url: str_of(request, "image_url"),
        series_image_url: str_of(request, "series_image_url"),
        season_image_url: str_of(request, "season_image_url"),
        estimated_bytes: request.get("estimated_bytes").and_then(|v| v.as_u64()),
        meta: meta.clone(),
    };
    mgr.start(app, req)
}

/// Called once at startup: restart any download that was mid-transfer when the
/// app last exited (meta still says "downloading" but nothing is running).
pub fn resume_interrupted<R: Runtime>(app: &AppHandle<R>) {
    // Paused from the Downloads page: a pause that lifted itself at the next
    // launch would not have been a pause. The frontend queue starts them when
    // it's lifted.
    if config::load().get("downloads_paused").and_then(|v| v.as_bool()) == Some(true) {
        return;
    }
    let mgr = app.state::<DlManager>();
    let Ok(entries) = std::fs::read_dir(config::downloads_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        let Ok(s) = std::fs::read_to_string(p.join("meta.json")) else {
            continue;
        };
        let Ok(meta) = serde_json::from_str::<Value>(&s) else {
            continue;
        };
        if meta.get("status").and_then(|v| v.as_str()) != Some("downloading") {
            continue;
        }
        let Some(item_id) = meta.get("item_id").and_then(|v| v.as_str()) else {
            continue;
        };
        if mgr.is_active(item_id) {
            continue;
        }
        if let Err(e) = restart(app.clone(), &mgr, item_id, false) {
            crate::debug_log_line(&format!("resume {} failed: {}", item_id, e));
        }
    }
}

pub fn list(mgr: &DlManager) -> Vec<Value> {
    let dir = config::downloads_dir();
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.is_dir() {
            continue;
        }
        let Some(mut meta) = read_meta(&p.join("meta.json")) else {
            continue;
        };
        refresh_paths(&mut meta, &p);
        let subs = crate::download_extras::local_subtitles(&p);
        if !subs.is_empty() {
            meta["subtitles"] = json!(subs);
        }
        if meta.get("status").and_then(|v| v.as_str()) == Some("complete") {
            meta["subtitles_settled"] = json!(crate::download_extras::subtitles_settled(&p));
        }
        let item_id = meta
            .get("item_id")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        if meta.get("status").and_then(|v| v.as_str()) == Some("downloading")
            && !mgr.is_active(item_id)
        {
            // Stale from a previous run that died mid-download.
            meta["status"] = json!("error");
            meta["error"] = json!("interrupted");
        }
        out.push(meta);
    }
    out
}

/// Mirror server-side watch state into a download's meta.json (display only —
/// unlike progress::store_local this does NOT enqueue anything for sync).
pub fn set_watch_state(item_id: &str, position_ticks: u64, played: bool) {
    let Ok(dir) = item_dir(item_id) else {
        return;
    };
    let meta_path = dir.join("meta.json");
    let Some(mut meta) = read_meta(&meta_path) else {
        return;
    };
    meta["position_ticks"] = json!(position_ticks);
    meta["played"] = json!(played);
    if let Ok(out) = serde_json::to_string_pretty(&meta) {
        let _ = std::fs::write(&meta_path, out);
    }
}

pub fn delete(item_id: &str) -> Result<(), String> {
    let dir = item_dir(item_id)?;
    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_item_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("aquarium-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn file_names_cannot_replace_the_apps_own_files() {
        assert!(check_file_name("Some Film (2024).mkv").is_ok());
        for name in ["meta.json", "poster.jpg", "series_poster.jpg", "season_poster.jpg"] {
            assert!(check_file_name(name).is_err(), "{name}");
        }
        for name in ["", ".", "..", "../x.mkv", "/etc/x"] {
            assert!(check_file_name(name).is_err(), "{name}");
        }
    }

    #[test]
    fn stored_paths_are_ignored() {
        let dir = temp_item_dir();
        let mut meta = json!({
            "file": "missing.mkv",
            "path": "av://lavfi:testsrc",
            "poster_path": "/etc/passwd",
        });
        refresh_paths(&mut meta, &dir);
        assert!(meta.get("path").is_none());
        assert!(meta.get("poster_path").is_none());

        std::fs::write(dir.join("film.mkv"), b"x").unwrap();
        let mut meta = json!({ "file": "film.mkv", "path": "/elsewhere" });
        refresh_paths(&mut meta, &dir);
        assert_eq!(meta["path"], json!(dir.join("film.mkv").to_string_lossy()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_record_with_no_usable_file_has_no_path() {
        let dir = temp_item_dir();
        // An empty name would join to the folder itself.
        for file in [json!(""), json!("meta.json"), json!("../../etc/passwd"), json!(7)] {
            let mut meta = json!({ "file": file });
            refresh_paths(&mut meta, &dir);
            assert!(meta.get("path").is_none());
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_record_that_is_not_an_object_is_no_record() {
        let dir = temp_item_dir();
        let path = dir.join("meta.json");
        std::fs::write(&path, "[1, 2, 3]").unwrap();
        assert!(read_meta(&path).is_none());
        std::fs::write(&path, r#"{"status":"complete"}"#).unwrap();
        assert!(read_meta(&path).is_some());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A Matroska head with a TimestampScale, and a tail whose clusters
    /// stop at `last_ms`.
    fn mkv(scale: Option<u32>, clusters_ms: &[u32]) -> (Vec<u8>, Vec<u8>) {
        let mut head = vec![0x1A, 0x45, 0xDF, 0xA3, 0x80];
        if let Some(sc) = scale {
            head.extend([0x2A, 0xD7, 0xB1, 0x84]);
            head.extend(sc.to_be_bytes());
        }
        let mut tail = vec![0u8; 7];
        for &ms in clusters_ms {
            // Unknown-size cluster, as a live mux writes it.
            tail.extend([0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
            // CRC-32, as ffmpeg writes it.
            tail.extend([0xBF, 0x84, 0x12, 0x34, 0x56, 0x78]);
            tail.extend([0xE7, 0x84]);
            tail.extend(ms.to_be_bytes());
            tail.extend([0xA3, 0x81, 0x00, 0x42, 0x1F, 0x43]);
        }
        (head, tail)
    }

    #[test]
    fn reads_the_last_cluster_timestamp() {
        let (h, t) = mkv(None, &[0, 5_000, 2_580_000]);
        assert_eq!(mkv_duration_from(&h, &t), Some(2580.0));
        let (h, t) = mkv(Some(100_000), &[0, 30_000]);
        assert_eq!(mkv_duration_from(&h, &t), Some(3.0));
        let (h, t) = mkv(None, &[]);
        assert_eq!(mkv_duration_from(&h, &t), None);
    }

    #[test]
    fn short_transcodes_are_caught_and_whole_ones_kept() {
        assert!(is_short(1200.0, 2640.0));
        assert!(!is_short(2600.0, 2640.0));
        // Short items aren't judged.
        assert!(!is_short(10.0, 90.0));
    }

    #[test]
    fn failures_back_off_then_stop() {
        let mut meta = json!({});
        let delays: Vec<Option<u64>> = (0..6)
            .map(|_| after_failure(&mut meta, "stalled: no data from the server for 90s", 0).1)
            .collect();
        assert_eq!(delays, vec![Some(5), Some(15), Some(45), Some(120), Some(300), None]);
        // An attempt that got somewhere starts the count again.
        assert_eq!(after_failure(&mut meta, "stream error: reset", 8 << 20).1, Some(5));
        // Not worth retrying unasked.
        assert_eq!(after_failure(&mut json!({}), "server returned 404 Not Found", 0).1, None);
        assert_eq!(after_failure(&mut json!({}), "server returned 503 Service Unavailable", 0).1, Some(5));
    }

    #[test]
    fn an_incomplete_copy_is_fetched_once_more() {
        let mut meta = json!({});
        let (msg, retry) = after_failure(&mut meta, "incomplete: 10 of 20 bytes", 0);
        assert_eq!(msg, "The first copy arrived incomplete — fetching it again");
        assert_eq!(retry, Some(2));
        assert_eq!(after_failure(&mut meta, "incomplete: 10 of 20 bytes", 0).1, None);
    }

    #[test]
    fn original_urls_are_told_from_transcodes() {
        assert!(is_original_url("http://s/Items/abc/Download"));
        assert!(!is_original_url("http://s/Videos/abc/stream.mkv?static=false"));
        assert!(is_original_url("http://s/Items/abc/Download?api_key=x"));
        assert!(!is_original_url("http://s/Items/abc/Download/x"));
    }

    // ---------- Pure helpers ----------

    #[test]
    fn item_ids_that_could_leave_the_downloads_folder_are_refused() {
        let ok = item_dir("9cd94f95847de72cdbda166c37504227").unwrap();
        assert_eq!(ok, config::downloads_dir().join("9cd94f95847de72cdbda166c37504227"));
        assert!(item_dir("a-b_C9").is_ok());
        assert!(item_dir(&"a".repeat(64)).is_ok());
        for bad in ["", ".", "..", "../config", "a/b", "/etc", "a\\b", "a b", "é", "a\0b"] {
            assert!(item_dir(bad).is_err(), "{bad:?}");
        }
        assert!(item_dir(&"a".repeat(65)).is_err());
        // The message quotes the id, cut short.
        let e = item_dir(&"/".repeat(200)).unwrap_err();
        assert!(e.starts_with("not a valid item id:") && e.len() < 100, "{e}");
    }

    #[test]
    fn a_nul_or_a_slash_anywhere_in_a_file_name_is_refused() {
        assert!(check_file_name("a\0.mkv").is_err());
        assert!(check_file_name("dir/a.mkv").is_err());
        // Only the exact reserved names: a film called "meta.json.mkv" is fine.
        assert!(check_file_name("meta.json.mkv").is_ok());
        assert!(check_file_name("..mkv").is_ok());
    }

    #[test]
    fn api_keys_are_taken_out_of_stored_urls() {
        assert_eq!(strip_api_key("http://s/Items/1/Download"), "http://s/Items/1/Download");
        assert_eq!(strip_api_key("http://s/Items/1/Download?api_key=T"), "http://s/Items/1/Download");
        assert_eq!(strip_api_key("http://s/v?static=false&api_key=T&MaxWidth=1"), "http://s/v?static=false&MaxWidth=1");
        assert_eq!(strip_api_key("http://s/v?ApiKey=T&a=1"), "http://s/v?a=1");
        // Only the parameter itself, not one whose name merely contains it.
        assert_eq!(strip_api_key("http://s/v?my_api_key=1"), "http://s/v?my_api_key=1");
    }

    #[test]
    fn only_trouble_that_can_pass_is_retried_unasked() {
        for yes in [
            "server returned 500 Internal Server Error",
            "server returned 503 Service Unavailable",
            "server returned 408 Request Timeout",
            "server returned 429 Too Many Requests",
            "request failed: connection refused",
            "stream error: reset",
            "stalled: no data from the server for 90s",
        ] {
            assert!(is_retryable(yes), "{yes}");
        }
        for no in [
            "server returned 404 Not Found",
            "server returned 401 Unauthorized",
            "server returned 416 Range Not Satisfiable",
            "server returned junk",
            "No space left on device (os error 28)",
            "This download is from a different server. Delete it, or sign in to that server to finish it.",
        ] {
            assert!(!is_retryable(no), "{no}");
        }
    }

    #[test]
    fn a_failure_says_whether_and_when_it_will_be_tried_again() {
        let mut meta = json!({});
        let (msg, retry) = after_failure(&mut meta, "stream error: reset", 0);
        assert_eq!(msg, "stream error: reset — trying again");
        assert_eq!(retry, Some(5));
        assert_eq!(meta["auto_retries"], json!(1));
        let mut meta = json!({ "auto_retries": 5 });
        let (msg, retry) = after_failure(&mut meta, "stream error: reset", 0);
        assert_eq!(msg, "stream error: reset — stopped after 5 attempts");
        assert_eq!(retry, None);
        // Not retried: the message is passed on as it is, and nothing is counted.
        let mut meta = json!({});
        let (msg, retry) = after_failure(&mut meta, "No space left on device (os error 28)", 0);
        assert_eq!((msg.as_str(), retry), ("No space left on device (os error 28)", None));
        assert!(meta.get("auto_retries").is_none());
        // Just under the 4 MB that counts as getting somewhere.
        let mut meta = json!({ "auto_retries": 2 });
        assert_eq!(after_failure(&mut meta, "stream error: x", (4 << 20) - 1).1, Some(45));
        assert_eq!(after_failure(&mut meta, "stream error: x", 4 << 20).1, Some(5));
    }

    #[test]
    fn ebml_numbers_are_read_by_their_length_marker() {
        assert_eq!(read_vint(&[0x81], 0), Some((1, 1)));
        assert_eq!(read_vint(&[0x40, 0x02], 0), Some((2, 2)));
        assert_eq!(read_vint(&[0x01, 0, 0, 0, 0, 0, 0, 0x05], 0), Some((5, 8)));
        // A zero first byte would be a nine-byte length: not EBML.
        assert_eq!(read_vint(&[0x00, 1, 2, 3, 4, 5, 6, 7, 8], 0), None);
        assert_eq!(read_vint(&[0x40], 0), None, "runs off the end");
        assert_eq!(read_vint(&[], 0), None);
        assert_eq!(read_uint_element(&[0x82, 0x01, 0x00], 0), Some(256));
        assert_eq!(read_uint_element(&[0x80], 0), None, "empty");
        assert_eq!(read_uint_element(&[0x89, 0, 0, 0, 0, 0, 0, 0, 0, 0], 0), None, "wider than a u64");
        assert_eq!(read_uint_element(&[0x84, 0x01], 0), None, "runs off the end");
        assert_eq!(find_all(b"abcabc", b"bc").collect::<Vec<_>>(), vec![1, 4]);
    }

    #[test]
    fn a_cluster_without_a_timestamp_first_is_skipped_for_an_earlier_one() {
        let (h, mut t) = mkv(None, &[7_000]);
        // A last cluster whose first child is something else.
        t.extend([0x1F, 0x43, 0xB6, 0x75, 0x81, 0xA3, 0x81, 0x00]);
        assert_eq!(mkv_duration_from(&h, &t), Some(7.0));
    }

    #[test]
    fn mkv_duration_reads_real_files_and_refuses_anything_else() {
        let dir = temp_item_dir();
        let (h, t) = mkv(Some(1_000_000), &[0, 61_500]);
        let file = dir.join("a.mkv");
        std::fs::write(&file, [h, t].concat()).unwrap();
        assert_eq!(mkv_duration_secs(&file), Some(61.5));
        std::fs::write(dir.join("b.mp4"), b"\0\0\0\x18ftypmp42 not matroska").unwrap();
        assert_eq!(mkv_duration_secs(&dir.join("b.mp4")), None);
        std::fs::write(dir.join("c.mkv"), b"").unwrap();
        assert_eq!(mkv_duration_secs(&dir.join("c.mkv")), None);
        assert_eq!(mkv_duration_secs(&dir.join("missing.mkv")), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn free_space_is_known_even_before_the_downloads_folder_exists() {
        let _s = crate::test_support::sandbox();
        assert!(!config::downloads_dir().exists());
        assert!(free_space().is_some_and(|n| n > 0));
        std::fs::create_dir_all(config::downloads_dir()).unwrap();
        assert!(free_space().is_some_and(|n| n > 0));
    }

    // ---------- Records on disk ----------

    fn write_record(id: &str, meta: Value) -> PathBuf {
        let dir = item_dir(id).unwrap();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("meta.json"), meta.to_string()).unwrap();
        dir
    }

    fn record(id: &str) -> Value {
        read_meta(&item_dir(id).unwrap().join("meta.json")).unwrap_or(Value::Null)
    }

    #[test]
    fn list_works_out_paths_from_the_folder_and_flags_stale_downloads() {
        let _s = crate::test_support::sandbox();
        let done = write_record("done", json!({ "item_id": "done", "file": "Film.mkv", "status": "complete", "path": "/elsewhere" }));
        std::fs::write(done.join("Film.mkv"), vec![0u8; 1234]).unwrap();
        std::fs::write(done.join("poster.jpg"), b"jpg").unwrap();
        std::fs::write(done.join("season_poster.jpg"), b"jpg").unwrap();
        std::fs::write(done.join("sub.2.eng.srt"), b"1\n").unwrap();
        std::fs::write(
            done.join("subtitles.json"),
            json!({ "complete": true, "entries": [
                { "index": 2, "file": "sub.2.eng.srt", "lang": "eng" },
                { "index": 3, "file": "sub.3.fre.srt", "lang": "fre" },
            ] })
            .to_string(),
        )
        .unwrap();
        write_record("stale", json!({ "item_id": "stale", "file": "S.mkv", "status": "downloading" }));
        write_record("paused", json!({ "item_id": "paused", "file": "P.mkv", "status": "paused" }));
        write_record("junk", json!([1, 2]));
        std::fs::create_dir_all(item_dir("empty").unwrap()).unwrap();
        std::fs::write(config::downloads_dir().join("stray.txt"), b"x").unwrap();

        let app = crate::test_support::mock_app();
        let mgr = app.state::<DlManager>();
        let mut all = list(&mgr);
        all.sort_by_key(|m| m["item_id"].as_str().unwrap_or("").to_string());
        let ids: Vec<&str> = all.iter().map(|m| m["item_id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["done", "paused", "stale"]);

        let d = &all[0];
        assert_eq!(d["path"], json!(done.join("Film.mkv").to_string_lossy()));
        assert_eq!(d["size_bytes"], json!(1234));
        assert_eq!(d["poster_path"], json!(done.join("poster.jpg").to_string_lossy()));
        assert_eq!(d["season_poster_path"], json!(done.join("season_poster.jpg").to_string_lossy()));
        assert!(d.get("series_poster_path").is_none());
        // Only the subtitle files that are really there.
        let subs = d["subtitles"].as_array().unwrap();
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0]["path"], json!(done.join("sub.2.eng.srt").to_string_lossy()));
        assert_eq!(d["subtitles_settled"], json!(true));

        assert_eq!(all[1]["status"], json!("paused"));
        assert!(all[1].get("subtitles_settled").is_none());
        // Died mid-transfer in an earlier run: shown as failed.
        assert_eq!(all[2]["status"], json!("error"));
        assert_eq!(all[2]["error"], json!("interrupted"));
        assert!(all[2].get("path").is_none());
        // list only reports; the record on disk is unchanged.
        assert_eq!(record("stale")["status"], json!("downloading"));
    }

    #[test]
    fn an_empty_downloads_folder_lists_nothing() {
        let _s = crate::test_support::sandbox();
        let app = crate::test_support::mock_app();
        assert!(list(&app.state::<DlManager>()).is_empty());
    }

    #[test]
    fn watch_state_is_mirrored_into_the_record_only() {
        let _s = crate::test_support::sandbox();
        write_record("w1", json!({ "item_id": "w1", "status": "complete", "file": "f.mkv" }));
        set_watch_state("w1", 12_340_000, true);
        let m = record("w1");
        assert_eq!(m["position_ticks"], json!(12_340_000));
        assert_eq!(m["played"], json!(true));
        assert_eq!(m["status"], json!("complete"));
        // No record, or no usable id: nothing is created.
        set_watch_state("w2", 1, false);
        assert!(!item_dir("w2").unwrap().exists());
        set_watch_state("../w3", 1, false);
        write_record("w4", json!("text"));
        set_watch_state("w4", 1, false);
        assert_eq!(std::fs::read_to_string(item_dir("w4").unwrap().join("meta.json")).unwrap(), "\"text\"");
    }

    #[test]
    fn delete_removes_the_folder_and_is_fine_when_it_is_gone() {
        let _s = crate::test_support::sandbox();
        let dir = write_record("del", json!({}));
        std::fs::write(dir.join("x.mkv.part"), b"x").unwrap();
        delete("del").unwrap();
        assert!(!dir.exists());
        delete("del").unwrap();
    }

    /// Regression: 6210523 (an item id from IPC was joined straight onto the
    /// downloads folder, so ".." deleted the data folder).
    #[test]
    fn delete_with_an_id_that_leaves_the_folder_touches_nothing() {
        let _s = crate::test_support::sandbox();
        write_record("keep", json!({}));
        std::fs::write(config::data_dir().join("precious"), b"x").unwrap();
        for bad in ["..", "../..", "/", "keep/..", ""] {
            assert!(delete(bad).is_err(), "{bad:?}");
        }
        assert!(config::data_dir().join("precious").exists());
        assert!(item_dir("keep").unwrap().exists());
    }

    #[test]
    fn cancel_and_pause_of_something_not_running_do_nothing() {
        let _s = crate::test_support::sandbox();
        let app = crate::test_support::mock_app();
        let mgr = app.state::<DlManager>();
        mgr.cancel("nothing");
        mgr.pause("nothing");
        assert!(!mgr.is_active("nothing"));
        assert_eq!(mgr.active_count(), 0);
        mgr.sync_keep_awake();
        assert!(!crate::test_support::debug_log().contains("suspend inhibit"));
    }

    // ---------- Transfers, against a stand-in server ----------

    use crate::test_support::{capture_events, mock_app, sandbox, sign_in, wait_until, Body, Events, FakeServer, Gate, Req, Resp, TEST_TOKEN};
    use tauri::Listener;

    const ID: &str = "0123abcd";
    const DL: &str = "/Items/0123abcd/Download";
    const TRANSCODE: &str = "/Videos/0123abcd/stream.mkv";
    const ENDS: [&str; 4] = ["complete", "error", "canceled", "paused"];

    fn film(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i % 251) as u8).collect()
    }

    /// A Jellyfin that also answers the item lookup the subtitle step makes
    /// once a download completes (an item with no subtitles), and hands
    /// everything else to `handler`.
    fn dl_server(handler: impl Fn(&Req) -> Resp + Send + Sync + 'static) -> FakeServer {
        FakeServer::jellyfin(move |req| {
            let p = req.path();
            if p.starts_with("/Items/") && p.matches('/').count() == 2 {
                return Resp::json(200, json!({ "MediaSources": [{ "Id": "src", "MediaStreams": [] }] }));
            }
            handler(req)
        })
    }

    /// Serves `body` at `path`, honouring `Range: bytes=N-` with a 206.
    fn ranged(path: &'static str, body: Vec<u8>) -> impl Fn(&Req) -> Resp + Send + Sync + 'static {
        move |req| {
            if req.path() != path {
                return Resp::status(404);
            }
            let from = req
                .header("range")
                .and_then(|r| r.strip_prefix("bytes="))
                .and_then(|r| r.trim_end_matches('-').parse::<usize>().ok());
            match from {
                Some(n) if n < body.len() => Resp::bytes(206, "video/mp4", body[n..].to_vec())
                    .header("Content-Range", &format!("bytes {}-{}/{}", n, body.len() - 1, body.len())),
                // As Jellyfin answers it (checked on the QA server, 12.2).
                Some(_) => Resp::status(416).header("Content-Range", &format!("bytes */{}", body.len())),
                None => Resp::bytes(200, "video/mp4", body.clone()),
            }
        }
    }

    fn dl_request(server: &FakeServer, path_and_query: &str, file: &str) -> DownloadRequest {
        DownloadRequest {
            item_id: ID.into(),
            url: format!("{}{}", server.url, path_and_query),
            file_name: file.into(),
            image_url: None,
            series_image_url: None,
            season_image_url: None,
            estimated_bytes: None,
            meta: json!({ "title": "A Film" }),
        }
    }

    fn terminals(events: &Events) -> Vec<Value> {
        events
            .all()
            .into_iter()
            .filter(|e| ENDS.contains(&e["state"].as_str().unwrap_or("")))
            .collect()
    }

    /// The `n`th (1-based) terminal event of the run.
    async fn nth_end(events: &Events, n: usize) -> Value {
        wait_until("the download to end", || terminals(events).len() >= n).await;
        terminals(events)[n - 1].clone()
    }

    /// Wait for the subtitle step a completed download starts on its own, so
    /// it never runs on into the next test's sandbox.
    async fn subtitles_done(id: &str) {
        let index = item_dir(id).unwrap().join("subtitles.json");
        wait_until("the subtitle step", || index.exists()).await;
    }

    fn part_len(file: &str) -> u64 {
        std::fs::metadata(item_dir(ID).unwrap().join(format!("{file}.part"))).map(|m| m.len()).unwrap_or(0)
    }

    fn token_in(req: &Req) -> Option<String> {
        let h = req.header("authorization")?;
        let start = h.find("Token=\"")? + 7;
        Some(h[start..].split('"').next()?.to_string())
    }

    #[tokio::test]
    async fn a_static_download_is_fetched_whole_with_the_header_and_its_posters() {
        let _s = sandbox();
        let server = dl_server(|req| match req.path() {
            DL => Resp::bytes(200, "video/mp4", film(3000)),
            p if p.starts_with("/img/") => Resp::bytes(200, "image/jpeg", p.as_bytes().to_vec()),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        let mut req = dl_request(&server, &format!("{DL}?api_key=leaked-token&static=true"), "A Film.mp4");
        req.image_url = Some(format!("{}/img/primary", server.url));
        req.series_image_url = Some(format!("{}/img/series", server.url));
        req.season_image_url = Some(format!("{}/img/season", server.url));
        mgr.start(app.handle().clone(), req).unwrap();

        // The record is written before anything is fetched, without the key.
        let m = record(ID);
        assert_eq!(m["status"], json!("downloading"));
        assert_eq!(m["item_id"], json!(ID));
        assert_eq!(m["file"], json!("A Film.mp4"));
        assert_eq!(m["title"], json!("A Film"));
        assert_eq!(m["request"]["url"], json!(format!("{}{DL}?static=true", server.url)));
        assert_eq!(m["request"]["image_url"], json!(format!("{}/img/primary", server.url)));
        assert!(!std::fs::read_to_string(item_dir(ID).unwrap().join("meta.json")).unwrap().contains("leaked-token"));

        assert_eq!(nth_end(&events, 1).await, json!({ "item_id": ID, "state": "complete" }));
        subtitles_done(ID).await;
        let dir = item_dir(ID).unwrap();
        assert_eq!(std::fs::read(dir.join("A Film.mp4")).unwrap(), film(3000));
        assert!(!dir.join("A Film.mp4.part").exists());
        assert_eq!(std::fs::read(dir.join("poster.jpg")).unwrap(), b"/img/primary");
        assert_eq!(std::fs::read(dir.join("series_poster.jpg")).unwrap(), b"/img/series");
        assert_eq!(std::fs::read(dir.join("season_poster.jpg")).unwrap(), b"/img/season");
        assert_eq!(record(ID)["status"], json!("complete"));

        let fetch = server.requests_to(DL).pop().unwrap();
        assert_eq!(token_in(&fetch).as_deref(), Some(TEST_TOKEN));
        assert!(fetch.header("authorization").unwrap().starts_with("MediaBrowser "));
        assert!(fetch.header("x-emby-token").is_none());
        assert!(fetch.header("range").is_none());

        assert!(!mgr.is_active(ID));
        assert_eq!(mgr.active_count(), 0);
        let listed = list(&mgr);
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["size_bytes"], json!(3000));
        assert_eq!(listed[0]["subtitles_settled"], json!(true));
        assert!(listed[0]["series_poster_path"].is_string());
        assert!(crate::test_support::debug_log().contains(&format!("download {ID} -> complete")));
    }

    #[tokio::test]
    async fn progress_reports_bytes_against_the_files_length() {
        let _s = sandbox();
        let gate = Gate::new();
        let g = gate.clone();
        let server = dl_server(move |_| {
            Resp::body(200, Body::Gated { first: film(1000), rest: film(1000), gate: g.clone(), sized: true })
        });
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        app.state::<DlManager>().start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        wait_until("the first half", || part_len("f.mp4") >= 1000).await;
        // Progress goes out at most every 0.4 s; let that pass before the rest.
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        gate.open();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        let progress: Vec<Value> = events.all().into_iter().filter(|e| e["state"] == "downloading").collect();
        let p = progress.last().expect("a progress event");
        assert_eq!(p["item_id"], json!(ID));
        assert_eq!(p["received"], json!(2000));
        assert_eq!(p["total"], json!(2000));
        assert_eq!(p["estimated"], json!(false));
        assert!(p["speed_bps"].as_u64().is_some_and(|s| s > 0));
        assert_eq!(events.states(), ["downloading", "complete"]);
    }

    #[tokio::test]
    async fn a_transcode_with_no_length_reports_the_estimate_as_its_total() {
        let _s = sandbox();
        let gate = Gate::new();
        let g = gate.clone();
        let server = dl_server(move |_| {
            Resp::body(200, Body::Gated { first: film(1000), rest: film(500), gate: g.clone(), sized: false })
        });
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mut req = dl_request(&server, &format!("{TRANSCODE}?static=false"), "f (720p).mkv");
        req.estimated_bytes = Some(5000);
        // A runtime, but no Matroska clusters to read: not judged.
        req.meta = json!({ "run_time_ticks": 26_400_000_000u64 });
        app.state::<DlManager>().start(app.handle().clone(), req).unwrap();
        assert_eq!(record(ID)["estimated_bytes"], json!(5000));
        assert_eq!(record(ID)["request"]["estimated_bytes"], json!(5000));
        wait_until("the first part", || part_len("f (720p).mkv") >= 1000).await;
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        gate.open();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        let p = events.all().into_iter().filter(|e| e["state"] == "downloading").last().expect("progress");
        assert_eq!(p["received"], json!(1500));
        assert_eq!(p["total"], json!(5000));
        assert_eq!(p["estimated"], json!(true));
        assert_eq!(std::fs::read(item_dir(ID).unwrap().join("f (720p).mkv")).unwrap().len(), 1500);
    }

    #[tokio::test]
    async fn pausing_keeps_the_part_and_carrying_on_asks_for_the_rest_with_range() {
        let _s = sandbox();
        let whole = film(2000);
        let gate = Gate::new();
        let g = gate.clone();
        let serve_rest = ranged(DL, whole.clone());
        let first = whole[..1000].to_vec();
        let server = dl_server(move |req| {
            if req.header("range").is_some() {
                return serve_rest(req);
            }
            Resp::body(200, Body::Gated { first: first.clone(), rest: vec![9; 1000], gate: g.clone(), sized: true })
        });
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        mgr.start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        wait_until("the first half", || part_len("f.mp4") >= 1000).await;
        mgr.pause(ID);
        // Noticed on the next poll of a stream that has gone quiet.
        assert_eq!(nth_end(&events, 1).await, json!({ "item_id": ID, "state": "paused" }));
        assert_eq!(record(ID)["status"], json!("paused"));
        assert_eq!(part_len("f.mp4"), 1000);
        assert!(!mgr.is_active(ID));

        restart(app.handle().clone(), &mgr, ID, false).unwrap();
        assert_eq!(nth_end(&events, 2).await["state"], json!("complete"));
        subtitles_done(ID).await;
        let resumed = server.requests_to(DL).pop().unwrap();
        assert_eq!(resumed.header("range"), Some("bytes=1000-"));
        assert_eq!(token_in(&resumed).as_deref(), Some(TEST_TOKEN));
        assert_eq!(std::fs::read(item_dir(ID).unwrap().join("f.mp4")).unwrap(), whole);
        gate.open();
    }

    #[tokio::test]
    async fn cancelling_throws_away_what_arrived() {
        let _s = sandbox();
        let gate = Gate::new();
        let g = gate.clone();
        let server = dl_server(move |_| {
            Resp::body(200, Body::Gated { first: film(1000), rest: film(1000), gate: g.clone(), sized: true })
        });
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        mgr.start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        assert!(mgr.is_active(ID));
        wait_until("the first half", || part_len("f.mp4") >= 1000).await;
        mgr.cancel(ID);
        // The next piece arriving is when the flag is read.
        gate.open();
        assert_eq!(nth_end(&events, 1).await, json!({ "item_id": ID, "state": "canceled" }));
        assert!(!item_dir(ID).unwrap().exists());
        assert!(!mgr.is_active(ID));
        assert!(list(&mgr).is_empty());
    }

    #[tokio::test]
    async fn an_interrupted_file_resumes_from_its_part_at_the_next_launch() {
        let _s = sandbox();
        let whole = film(3000);
        let server = dl_server(ranged(DL, whole.clone()));
        sign_in(&server.url);
        let request = json!({ "url": format!("{}{DL}", server.url) });
        let dir = write_record(ID, json!({ "item_id": ID, "file": "f.mp4", "status": "downloading", "request": request }));
        std::fs::write(dir.join("f.mp4.part"), &whole[..1200]).unwrap();
        // Records that are not to be restarted.
        write_record("done1", json!({ "item_id": "done1", "file": "f.mp4", "status": "complete", "request": request }));
        write_record("paused1", json!({ "item_id": "paused1", "file": "f.mp4", "status": "paused", "request": request }));
        write_record("noid", json!({ "file": "f.mp4", "status": "downloading", "request": request }));
        let junk = item_dir("junk").unwrap();
        std::fs::create_dir_all(&junk).unwrap();
        std::fs::write(junk.join("meta.json"), "{ not json").unwrap();
        // A record from before resume support: logged, not fatal.
        write_record("old1", json!({ "item_id": "old1", "file": "f.mp4", "status": "downloading" }));

        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        resume_interrupted(app.handle());
        assert_eq!(nth_end(&events, 1).await, json!({ "item_id": ID, "state": "complete" }));
        subtitles_done(ID).await;
        let asked = server.requests_to(DL);
        assert_eq!(asked.len(), 1, "only the interrupted download was restarted");
        assert_eq!(asked[0].header("range"), Some("bytes=1200-"));
        assert_eq!(std::fs::read(dir.join("f.mp4")).unwrap(), whole);
        assert!(crate::test_support::debug_log().contains("resume old1 failed: download predates resume support"));
        assert_eq!(terminals(&events).len(), 1);
    }

    #[tokio::test]
    async fn a_part_that_already_holds_the_whole_file_is_finished_not_failed_with_416() {
        let _s = sandbox();
        let whole = film(3000);
        let server = dl_server(ranged(DL, whole.clone()));
        sign_in(&server.url);
        let dir = write_record(ID, json!({ "item_id": ID, "file": "f.mp4", "status": "error", "request": { "url": format!("{}{DL}", server.url) } }));
        std::fs::write(dir.join("f.mp4.part"), &whole).unwrap();
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        restart(app.handle().clone(), &app.state::<DlManager>(), ID, true).unwrap();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        assert_eq!(server.requests_to(DL).len(), 1);
        assert_eq!(std::fs::read(dir.join("f.mp4")).unwrap(), whole);
        assert!(!dir.join("f.mp4.part").exists());
    }

    #[tokio::test]
    async fn a_part_longer_than_the_file_is_dropped_and_the_file_fetched_again() {
        let _s = sandbox();
        let whole = film(3000);
        let server = dl_server(ranged(DL, whole.clone()));
        sign_in(&server.url);
        let dir = write_record(ID, json!({ "item_id": ID, "file": "f.mp4", "status": "error", "request": { "url": format!("{}{DL}", server.url) } }));
        std::fs::write(dir.join("f.mp4.part"), vec![0u8; 4000]).unwrap();
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        restart(app.handle().clone(), &app.state::<DlManager>(), ID, true).unwrap();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        let asked = server.requests_to(DL);
        assert_eq!(asked.iter().map(|r| r.header("range").map(str::to_string)).collect::<Vec<_>>(), vec![Some("bytes=4000-".to_string()), None]);
        assert_eq!(std::fs::read(dir.join("f.mp4")).unwrap(), whole);
    }

    #[tokio::test]
    async fn a_server_that_ignores_range_starts_the_file_over() {
        // A transcode answers a Range with a fresh 200: the old part goes.
        let _s = sandbox();
        let server = dl_server(|_| Resp::body(200, Body::Chunked(vec![b"new ".to_vec(), b"bytes".to_vec()])));
        sign_in(&server.url);
        let url = format!("{}{TRANSCODE}?static=false", server.url);
        let dir = write_record(ID, json!({ "item_id": ID, "file": "t.mkv", "status": "error", "request": { "url": url } }));
        std::fs::write(dir.join("t.mkv.part"), b"OLD PARTIAL CONTENT").unwrap();
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        restart(app.handle().clone(), &app.state::<DlManager>(), ID, true).unwrap();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        assert_eq!(server.requests_to(TRANSCODE)[0].header("range"), Some("bytes=19-"));
        assert_eq!(std::fs::read(dir.join("t.mkv")).unwrap(), b"new bytes");
    }

    #[tokio::test]
    async fn resume_holds_off_while_downloads_are_paused() {
        let _s = sandbox();
        let server = dl_server(ranged(DL, film(10)));
        sign_in(&server.url);
        config::merge(json!({ "downloads_paused": true })).unwrap();
        write_record(ID, json!({ "item_id": ID, "file": "f.mp4", "status": "downloading", "request": { "url": format!("{}{DL}", server.url) } }));
        let app = mock_app();
        resume_interrupted(app.handle());
        assert_eq!(app.state::<DlManager>().active_count(), 0);
        assert!(server.requests_to(DL).is_empty());
        assert_eq!(record(ID)["status"], json!("downloading"));
    }

    /// Regression: 251c55d (the running entry has to be gone by the time the
    /// terminal event goes out: the frontend queue retries on that event, and
    /// the retry was refused as "already in progress").
    #[tokio::test]
    async fn a_retry_started_from_the_failure_event_is_not_refused() {
        let _s = sandbox();
        let server = dl_server(|_| Resp::status(404));
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let handle = app.handle().clone();
        let seen: Arc<Mutex<Vec<(bool, Result<(), String>)>>> = Arc::default();
        let sink = seen.clone();
        app.listen_any("download-progress", move |e| {
            let v: Value = serde_json::from_str(e.payload()).unwrap_or(Value::Null);
            if v["state"] != "error" || !sink.lock().unwrap().is_empty() {
                return;
            }
            let mgr = handle.state::<DlManager>();
            let active = mgr.is_active(ID);
            let retried = restart(handle.clone(), &mgr, ID, true);
            sink.lock().unwrap().push((active, retried));
        });
        app.state::<DlManager>().start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        let first = nth_end(&events, 1).await;
        assert_eq!(first["message"], json!("server returned 404 Not Found"));
        assert_eq!(first["retry_in"], Value::Null);
        nth_end(&events, 2).await;
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert!(!seen[0].0, "still marked running when the event went out");
        assert_eq!(seen[0].1, Ok(()));
        assert_eq!(server.requests_to(DL).len(), 2);
        let m = record(ID);
        assert_eq!(m["status"], json!("error"));
        assert_eq!(m["error"], json!("server returned 404 Not Found"));
    }

    #[tokio::test]
    async fn a_server_error_is_retried_with_a_growing_wait_and_a_manual_retry_starts_over() {
        let _s = sandbox();
        let server = dl_server(|_| Resp::status(503));
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        mgr.start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        let e = nth_end(&events, 1).await;
        assert_eq!(e["state"], json!("error"));
        assert_eq!(e["message"], json!("server returned 503 Service Unavailable — trying again"));
        assert_eq!(e["retry_in"], json!(5));
        assert_eq!(record(ID)["auto_retries"], json!(1));
        // The queue's own retry carries on counting.
        restart(app.handle().clone(), &mgr, ID, false).unwrap();
        assert_eq!(nth_end(&events, 2).await["retry_in"], json!(15));
        assert_eq!(record(ID)["auto_retries"], json!(2));
        // Retry pressed by someone: from the top.
        restart(app.handle().clone(), &mgr, ID, true).unwrap();
        assert_eq!(nth_end(&events, 3).await["retry_in"], json!(5));
        assert_eq!(record(ID)["auto_retries"], json!(1));
    }

    #[tokio::test]
    async fn a_connection_that_drops_mid_file_is_retried_and_keeps_its_part() {
        let _s = sandbox();
        let server = dl_server(|_| Resp::body(200, Body::Short { declared: 5000, sent: film(700) }));
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        app.state::<DlManager>().start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        let e = nth_end(&events, 1).await;
        let msg = e["message"].as_str().unwrap();
        assert!(msg.starts_with("stream error") && msg.ends_with(" — trying again"), "{msg}");
        assert_eq!(e["retry_in"], json!(5));
        let dir = item_dir(ID).unwrap();
        assert!(dir.join("f.mp4.part").exists(), "the part is kept to resume from");
        assert!(!dir.join("f.mp4").exists());
    }

    #[tokio::test]
    async fn a_transcode_cut_off_without_its_terminator_is_retried() {
        let _s = sandbox();
        let server = dl_server(|_| Resp::body(200, Body::Cut(film(300))));
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        app.state::<DlManager>().start(app.handle().clone(), dl_request(&server, TRANSCODE, "t.mkv")).unwrap();
        let e = nth_end(&events, 1).await;
        assert!(e["message"].as_str().unwrap().starts_with("stream error"), "{e}");
        assert_eq!(e["retry_in"], json!(5));
    }

    #[tokio::test]
    async fn an_unreachable_server_is_retried() {
        let _s = sandbox();
        let dead = FakeServer::dead_url();
        sign_in(&dead);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mut req = dl_request(&FakeServer::bare(), DL, "f.mp4");
        req.url = format!("{dead}{DL}");
        app.state::<DlManager>().start(app.handle().clone(), req).unwrap();
        let e = nth_end(&events, 1).await;
        assert!(e["message"].as_str().unwrap().starts_with("request failed"), "{e}");
        assert_eq!(e["retry_in"], json!(5));
    }

    /// Regression: f1e01de (a stored download can outlive its sign-in, and
    /// today's token went to the address in the old record).
    #[tokio::test]
    async fn a_download_from_another_server_is_refused_and_gets_no_token() {
        let _s = sandbox();
        let ours = dl_server(|_| Resp::status(404));
        let theirs = FakeServer::jellyfin(|_| Resp::bytes(200, "video/mp4", film(10)));
        sign_in(&ours.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mut req = dl_request(&theirs, DL, "f.mp4");
        req.image_url = Some(format!("{}/img", theirs.url));
        app.state::<DlManager>().start(app.handle().clone(), req).unwrap();
        let e = nth_end(&events, 1).await;
        assert_eq!(
            e["message"],
            json!("This download is from a different server. Delete it, or sign in to that server to finish it.")
        );
        assert_eq!(e["retry_in"], Value::Null);
        assert!(theirs.requests().is_empty(), "the other server was contacted");
    }

    #[tokio::test]
    async fn without_a_token_the_request_goes_out_with_no_credentials() {
        let _s = sandbox();
        let server = dl_server(|_| Resp::bytes(200, "video/mp4", film(10)));
        config::merge(json!({ "server": server.url })).unwrap();
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        app.state::<DlManager>().start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        assert!(server.requests_to(DL)[0].header("authorization").is_none());
        // The subtitle step stops at "not signed in", before any file is written.
        wait_until("the subtitle step to give up", || {
            crate::test_support::debug_log().contains(&format!("download {ID} -> complete"))
        })
        .await;
    }

    /// The integrity check from 251c55d: a transcode is chunked with no length,
    /// and an encoder that dies part way ends the response as tidily as one
    /// that finished, so the copy is held to the item's runtime.
    #[tokio::test]
    async fn a_short_transcode_is_fetched_once_more_then_left_in_failed() {
        let _s = sandbox();
        let (h, t) = mkv(None, &[0, 600_000, 1_200_000]);
        let body = [h, t].concat();
        let server = dl_server(move |_| Resp::body(200, Body::Chunked(vec![body.clone()])));
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        let mut req = dl_request(&server, &format!("{TRANSCODE}?static=false"), "t.mkv");
        req.meta = json!({ "run_time_ticks": 26_400_000_000u64 });
        mgr.start(app.handle().clone(), req).unwrap();
        let e = nth_end(&events, 1).await;
        assert_eq!(e["message"], json!("The first copy arrived incomplete — fetching it again"));
        assert_eq!(e["retry_in"], json!(2));
        let dir = item_dir(ID).unwrap();
        assert!(!dir.join("t.mkv").exists() && !dir.join("t.mkv.part").exists(), "the short copy is not kept");
        assert_eq!(record(ID)["verify_failures"], json!(1));
        assert!(crate::test_support::debug_log().contains("incomplete: 1200s of 2640s"));

        restart(app.handle().clone(), &mgr, ID, false).unwrap();
        let e = nth_end(&events, 2).await;
        assert_eq!(e["message"], json!("The file arrived incomplete twice"));
        assert_eq!(e["retry_in"], Value::Null);
        assert_eq!(record(ID)["status"], json!("error"));

        restart(app.handle().clone(), &mgr, ID, true).unwrap();
        assert_eq!(nth_end(&events, 3).await["retry_in"], json!(2));
    }

    #[tokio::test]
    async fn a_whole_transcode_is_kept_and_its_counters_cleared() {
        let _s = sandbox();
        let (h, t) = mkv(None, &[0, 2_600_000]);
        let body = [h, t].concat();
        let len = body.len();
        let server = dl_server(move |_| Resp::body(200, Body::Chunked(vec![body.clone()])));
        sign_in(&server.url);
        let dir = write_record(
            ID,
            json!({
                "item_id": ID, "file": "t.mkv", "status": "error", "error": "old",
                "auto_retries": 3, "verify_failures": 1, "run_time_ticks": 26_400_000_000u64,
                "request": { "url": format!("{}{TRANSCODE}", server.url) },
            }),
        );
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        restart(app.handle().clone(), &app.state::<DlManager>(), ID, false).unwrap();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        assert_eq!(std::fs::metadata(dir.join("t.mkv")).unwrap().len(), len as u64);
        let m = record(ID);
        assert_eq!(m["status"], json!("complete"));
        for gone in ["error", "auto_retries", "verify_failures"] {
            assert!(m.get(gone).is_none(), "{gone} kept");
        }
    }

    #[tokio::test]
    async fn starting_again_while_running_is_refused_and_the_list_shows_it_running() {
        let _s = sandbox();
        let gate = Gate::new();
        let g = gate.clone();
        let server = dl_server(move |_| {
            Resp::body(200, Body::Gated { first: film(100), rest: film(100), gate: g.clone(), sized: true })
        });
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        mgr.start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        assert_eq!(
            mgr.start(app.handle().clone(), dl_request(&server, DL, "f.mp4")),
            Err("download already in progress for this item".to_string())
        );
        assert_eq!(restart(app.handle().clone(), &mgr, ID, true), Err("download already in progress for this item".to_string()));
        assert_eq!(mgr.active_count(), 1);
        let listed = list(&mgr);
        assert_eq!(listed[0]["status"], json!("downloading"), "a running download isn't stale");
        // Keep-awake is on by default; the inhibitor can't be had here, and says so.
        assert!(crate::test_support::debug_log().contains("downloads: suspend inhibit failed"));
        wait_until("the first piece", || part_len("f.mp4") >= 100).await;
        mgr.cancel(ID);
        gate.open();
        assert_eq!(nth_end(&events, 1).await["state"], json!("canceled"));
        assert_eq!(server.requests_to(DL).len(), 1);
    }

    #[tokio::test]
    async fn with_keep_awake_off_no_inhibitor_is_asked_for() {
        let _s = sandbox();
        let gate = Gate::new();
        let g = gate.clone();
        let server = dl_server(move |_| {
            Resp::body(200, Body::Gated { first: film(100), rest: film(100), gate: g.clone(), sized: true })
        });
        sign_in(&server.url);
        config::merge(json!({ "downloads_keep_awake": false })).unwrap();
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        mgr.start(app.handle().clone(), dl_request(&server, DL, "f.mp4")).unwrap();
        assert!(!crate::test_support::debug_log().contains("suspend inhibit"));
        // Flipping the setting mid-download only needs a sync.
        config::merge(json!({ "downloads_keep_awake": true })).unwrap();
        mgr.sync_keep_awake();
        assert!(crate::test_support::debug_log().contains("downloads: suspend inhibit failed"));
        wait_until("the first piece", || part_len("f.mp4") >= 100).await;
        mgr.cancel(ID);
        gate.open();
        nth_end(&events, 1).await;
    }

    #[tokio::test]
    async fn start_refuses_bad_ids_and_reserved_file_names_and_creates_nothing() {
        let _s = sandbox();
        let server = FakeServer::bare();
        sign_in(&server.url);
        let app = mock_app();
        let mgr = app.state::<DlManager>();
        let mut req = dl_request(&server, DL, "f.mp4");
        req.item_id = "../escape".into();
        assert!(mgr.start(app.handle().clone(), req).unwrap_err().starts_with("not a valid item id"));
        for name in ["meta.json", "poster.jpg", "..", "a/b.mkv", ""] {
            let e = mgr.start(app.handle().clone(), dl_request(&server, DL, name)).unwrap_err();
            assert!(e.starts_with("not a valid file name"), "{name}: {e}");
        }
        assert!(!config::downloads_dir().join("escape").exists());
        assert!(!item_dir(ID).unwrap().exists());
        assert_eq!(mgr.active_count(), 0);
        assert!(server.requests().is_empty());
    }

    #[tokio::test]
    async fn a_retried_download_starts_from_a_clean_record() {
        let _s = sandbox();
        let ours = FakeServer::bare();
        let elsewhere = FakeServer::bare();
        sign_in(&ours.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        let mut req = dl_request(&elsewhere, DL, "f.mp4");
        req.meta = json!({ "error": "stale from last time", "name": "N", "status": "error" });
        mgr.start(app.handle().clone(), req).unwrap();
        let m = record(ID);
        assert!(m.get("error").is_none());
        assert_eq!(m["status"], json!("downloading"));
        assert_eq!(m["name"], json!("N"));
        nth_end(&events, 1).await;

        // Metadata that isn't an object is replaced, not indexed into.
        let mut req = dl_request(&elsewhere, DL, "g.mp4");
        req.meta = json!("not an object");
        mgr.start(app.handle().clone(), req).unwrap();
        let m = record(ID);
        assert_eq!(m["file"], json!("g.mp4"));
        assert_eq!(m["item_id"], json!(ID));
        nth_end(&events, 2).await;
    }

    #[tokio::test]
    async fn posters_already_on_disk_are_not_fetched_again_and_a_missing_one_is_no_failure() {
        let _s = sandbox();
        let server = dl_server(|req| match req.path() {
            DL => Resp::bytes(200, "video/mp4", film(10)),
            "/img/season" => Resp::bytes(200, "image/jpeg", b"S".to_vec()),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        let dir = item_dir(ID).unwrap();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("poster.jpg"), b"kept").unwrap();
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mut req = dl_request(&server, DL, "f.mp4");
        req.image_url = Some(format!("{}/img/primary", server.url));
        req.series_image_url = Some(format!("{}/img/series", server.url));
        req.season_image_url = Some(format!("{}/img/season", server.url));
        app.state::<DlManager>().start(app.handle().clone(), req).unwrap();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        assert!(server.requests_to("/img/primary").is_empty());
        assert_eq!(std::fs::read(dir.join("poster.jpg")).unwrap(), b"kept");
        assert!(!dir.join("series_poster.jpg").exists());
        assert_eq!(std::fs::read(dir.join("season_poster.jpg")).unwrap(), b"S");
    }

    #[test]
    fn restart_needs_a_record_it_can_rebuild_the_request_from() {
        let _s = sandbox();
        let app = mock_app();
        let mgr = app.state::<DlManager>();
        let go = |id: &str| restart(app.handle().clone(), &mgr, id, false).unwrap_err();
        assert!(go("..").starts_with("not a valid item id"));
        assert_eq!(go("none"), "no download metadata for this item");
        write_record("old", json!({ "file": "f.mp4" }));
        assert_eq!(go("old"), "download predates resume support; delete and re-download");
        write_record("nourl", json!({ "file": "f.mp4", "request": {} }));
        assert_eq!(go("nourl"), "stored request has no url");
        write_record("nofile", json!({ "request": { "url": "http://s/Items/1/Download" } }));
        assert_eq!(go("nofile"), "stored meta has no file name");
        assert_eq!(mgr.active_count(), 0);
    }

    /// Downloads queued by an older build stored the token in the URL.
    #[tokio::test]
    async fn restarting_an_old_record_drops_the_api_key_it_stored() {
        let _s = sandbox();
        let server = dl_server(|_| Resp::bytes(200, "video/mp4", film(10)));
        sign_in(&server.url);
        let dir = write_record(
            ID,
            json!({ "item_id": ID, "file": "f.mp4", "status": "error",
                    "request": { "url": format!("{}{DL}?api_key=OLDTOKEN", server.url), "estimated_bytes": 10 } }),
        );
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        restart(app.handle().clone(), &app.state::<DlManager>(), ID, true).unwrap();
        assert_eq!(nth_end(&events, 1).await["state"], json!("complete"));
        subtitles_done(ID).await;
        let sent = &server.requests_to(DL)[0];
        assert_eq!(sent.query(), "");
        assert_eq!(token_in(sent).as_deref(), Some(TEST_TOKEN));
        assert!(!std::fs::read_to_string(dir.join("meta.json")).unwrap().contains("OLDTOKEN"));
    }

    /// The subtitles step is wired to the kind of download: an original file
    /// keeps its embedded tracks, so only the server's external ones are fetched.
    #[tokio::test]
    async fn a_finished_download_fetches_the_subtitles_its_kind_lacks() {
        let _s = sandbox();
        let server = FakeServer::jellyfin(|req| match req.path() {
            DL | TRANSCODE => Resp::bytes(200, "video/x-matroska", film(10)),
            "/Items/0123abcd" => Resp::json(200, json!({ "MediaSources": [{ "Id": "src", "MediaStreams": [
                { "Type": "Subtitle", "Index": 2, "Codec": "subrip", "Language": "eng", "IsTextSubtitleStream": true, "IsExternal": false },
                { "Type": "Subtitle", "Index": 3, "Codec": "subrip", "Language": "fre", "IsTextSubtitleStream": true, "IsExternal": true },
            ] }] })),
            p if p.contains("/Subtitles/") => Resp::bytes(200, "text/plain", b"1\n00:00:00,000 --> 00:00:01,000\nx\n".to_vec()),
            _ => Resp::status(404),
        });
        sign_in(&server.url);
        let app = mock_app();
        let events = capture_events(app.handle(), "download-progress");
        let mgr = app.state::<DlManager>();
        mgr.start(app.handle().clone(), dl_request(&server, DL, "f.mkv")).unwrap();
        nth_end(&events, 1).await;
        subtitles_done(ID).await;
        let asked: Vec<String> = server.requests().iter().filter(|r| r.path().contains("/Subtitles/")).map(|r| r.path().to_string()).collect();
        assert_eq!(asked, ["/Videos/0123abcd/src/Subtitles/3/0/Stream.srt"]);

        delete(ID).unwrap();
        server.forget_requests();
        mgr.start(app.handle().clone(), dl_request(&server, TRANSCODE, "t.mkv")).unwrap();
        nth_end(&events, 2).await;
        subtitles_done(ID).await;
        let mut asked: Vec<String> = server.requests().iter().filter(|r| r.path().contains("/Subtitles/")).map(|r| r.path().to_string()).collect();
        asked.sort();
        assert_eq!(asked, ["/Videos/0123abcd/src/Subtitles/2/0/Stream.srt", "/Videos/0123abcd/src/Subtitles/3/0/Stream.srt"]);
        assert_eq!(list(&mgr)[0]["subtitles"].as_array().unwrap().len(), 2);
    }
}

/// Real downloads from the live QA Jellyfin (see `test_support::qa`), into the
/// sandbox, deleted afterwards. Skip, saying why, when the server isn't there.
#[cfg(test)]
mod qa_tests {
    use super::*;
    use crate::test_support::{capture_events, mock_app, qa_find_item, with_qa_session, Events};

    /// A twenty-second film, small enough to fetch whole on every run.
    const SHORT_FILM: &str = "FX Rated G";

    async fn finish(events: &Events, id: &str) -> Value {
        let started = std::time::Instant::now();
        loop {
            let last = events.last();
            if ["complete", "error", "canceled", "paused"].contains(&last["state"].as_str().unwrap_or("")) {
                if last["state"] == "complete" {
                    // Let the subtitle step finish before the sandbox goes.
                    let index = item_dir(id).unwrap().join("subtitles.json");
                    while !index.exists() && started.elapsed().as_secs() < 120 {
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                }
                return last;
            }
            assert!(started.elapsed().as_secs() < 180, "the QA download did not finish");
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    }

    fn request_for(item: &Value, url: String, file: &str) -> DownloadRequest {
        DownloadRequest {
            item_id: item["Id"].as_str().unwrap().into(),
            url,
            file_name: file.into(),
            image_url: None,
            series_image_url: None,
            season_image_url: None,
            estimated_bytes: None,
            meta: json!({ "name": item["Name"], "run_time_ticks": item["RunTimeTicks"] }),
        }
    }

    #[tokio::test]
    async fn the_original_file_of_a_short_film_downloads_whole() {
        with_qa_session(|qa, _who| async move {
            let item = qa_find_item("Movie", SHORT_FILM, "MediaSources").await.expect("the short QA film");
            let id = item["Id"].as_str().unwrap().to_string();
            let size = item["MediaSources"][0]["Size"].as_u64().expect("source size");
            let app = mock_app();
            let events = capture_events(app.handle(), "download-progress");
            let mgr = app.state::<DlManager>();
            let req = request_for(&item, format!("{}/Items/{id}/Download", qa.server), "short.mp4");
            mgr.start(app.handle().clone(), req).unwrap();
            let end = finish(&events, &id).await;
            assert_eq!(end["state"], json!("complete"), "{end}");
            let file = item_dir(&id).unwrap().join("short.mp4");
            assert_eq!(std::fs::metadata(&file).unwrap().len(), size);
            let listed = list(&mgr);
            assert_eq!(listed[0]["status"], json!("complete"));
            assert_eq!(listed[0]["size_bytes"], json!(size));
            delete(&id).unwrap();
            assert!(!item_dir(&id).unwrap().exists());
        })
        .await;
    }

    #[tokio::test]
    async fn a_transcode_of_a_short_film_downloads_and_reads_as_matroska() {
        with_qa_session(|qa, _who| async move {
            let item = qa_find_item("Movie", SHORT_FILM, "MediaSources").await.expect("the short QA film");
            let id = item["Id"].as_str().unwrap().to_string();
            let runtime = item["RunTimeTicks"].as_u64().unwrap() as f64 / 1e7;
            let device = config::device_id();
            // As `buildDownload` in src/api.ts asks for it.
            let url = format!(
                "{}/Videos/{id}/stream.mkv?static=false&VideoCodec=h264&AudioCodec=aac&VideoBitrate=1500000&AudioBitrate=128000&MaxWidth=640&deviceId={device}&Context=Static",
                qa.server
            );
            let app = mock_app();
            let events = capture_events(app.handle(), "download-progress");
            let mut req = request_for(&item, url, "short (640w).mkv");
            req.estimated_bytes = Some(4_000_000);
            app.state::<DlManager>().start(app.handle().clone(), req).unwrap();
            let end = finish(&events, &id).await;
            assert_eq!(end["state"], json!("complete"), "{end}");
            let file = item_dir(&id).unwrap().join("short (640w).mkv");
            let reached = mkv_duration_secs(&file).expect("a Matroska file with clusters");
            assert!(reached > runtime - 10.0 && reached <= runtime + 1.0, "{reached} of {runtime}");
            delete(&id).unwrap();
        })
        .await;
    }
}

#[cfg(test)]
mod real_files {
    /// Read the duration of real downloads, each "path<TAB>runtime-seconds" on
    /// a line of the file named by AQUARIUM_MKV_CHECK. Opt-in:
    ///   AQUARIUM_MKV_CHECK=list.tsv cargo test --lib real_files -- --ignored --nocapture
    #[test]
    #[ignore]
    fn durations_match_runtime() {
        let list = std::env::var("AQUARIUM_MKV_CHECK").expect("AQUARIUM_MKV_CHECK");
        for line in std::fs::read_to_string(list).unwrap().lines() {
            let (path, rt) = line.split_once('\t').unwrap();
            let rt: f64 = rt.parse().unwrap();
            let got = super::mkv_duration_secs(std::path::Path::new(path));
            println!("{got:?} of {rt} — {path}");
            let got = got.expect("no duration read");
            assert!(!super::is_short(got, rt), "whole file judged short: {path}");
        }
    }
}
