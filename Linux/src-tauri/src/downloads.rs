use crate::{config, jellyfin};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};
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

/// The same guard for the file name a download is saved under, which is
/// joined onto the item's folder. The frontend already replaces anything
/// unusual in it; this only has to stop it leaving the folder.
fn check_file_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') {
        return Err(format!("not a valid file name: {name:?}"));
    }
    Ok(())
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

fn emit(app: &AppHandle, payload: Value) {
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

    pub fn start(&self, app: AppHandle, req: DownloadRequest) -> Result<(), String> {
        {
            let cancels = self.cancels.lock().unwrap();
            if cancels.contains_key(&req.item_id) {
                return Err("download already in progress for this item".into());
            }
        }

        let dir = item_dir(&req.item_id)?;
        check_file_name(&req.file_name)?;
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

        let mut meta = req.meta.clone();
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

            let mut meta = std::fs::read_to_string(dir.join("meta.json"))
                .ok()
                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                .unwrap_or_else(|| json!({}));

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

async fn run_download(
    app: &AppHandle,
    req: &DownloadRequest,
    dir: &PathBuf,
    stop: Arc<AtomicU8>,
    fetched: &AtomicU64,
) -> Result<(), String> {
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
    let part_len = std::fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0);
    let mut request = jellyfin::http().get(&req.url);
    // Authenticate by header. The URL is persisted in meta.json so an
    // interrupted transfer can be resumed, and an `api_key=` in it would leave
    // a live credential lying in the downloads folder (as well as in the
    // server's access log).
    if let Some(auth) = auth_header_now() {
        request = request.header("Authorization", auth);
    }
    if part_len > 0 {
        request = request.header("Range", format!("bytes={}-", part_len));
    }
    let resp = request
        .send()
        .await
        .map_err(|e| format!("request failed: {}", e))?;
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
pub fn restart(app: AppHandle, mgr: &DlManager, item_id: &str, manual: bool) -> Result<(), String> {
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
pub fn resume_interrupted(app: &AppHandle) {
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
        let Ok(s) = std::fs::read_to_string(p.join("meta.json")) else {
            continue;
        };
        let Ok(mut meta) = serde_json::from_str::<Value>(&s) else {
            continue;
        };
        let file = meta.get("file").and_then(|v| v.as_str()).unwrap_or("");
        let fpath = p.join(file);
        if fpath.exists() {
            meta["path"] = json!(fpath.to_string_lossy());
            meta["size_bytes"] = json!(fpath.metadata().map(|m| m.len()).unwrap_or(0));
        }
        let subs = crate::download_extras::local_subtitles(&p);
        if !subs.is_empty() {
            meta["subtitles"] = json!(subs);
        }
        if meta.get("status").and_then(|v| v.as_str()) == Some("complete") {
            meta["subtitles_settled"] = json!(crate::download_extras::subtitles_settled(&p));
        }
        let poster = p.join("poster.jpg");
        if poster.exists() {
            meta["poster_path"] = json!(poster.to_string_lossy());
        }
        let series_poster = p.join("series_poster.jpg");
        if series_poster.exists() {
            meta["series_poster_path"] = json!(series_poster.to_string_lossy());
        }
        let season_poster = p.join("season_poster.jpg");
        if season_poster.exists() {
            meta["season_poster_path"] = json!(season_poster.to_string_lossy());
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
    let Ok(s) = std::fs::read_to_string(&meta_path) else {
        return;
    };
    let Ok(mut meta) = serde_json::from_str::<Value>(&s) else {
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
