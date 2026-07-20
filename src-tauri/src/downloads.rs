use crate::{config, jellyfin};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
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

#[derive(Default)]
pub struct DlManager {
    cancels: Mutex<HashMap<String, Arc<AtomicBool>>>,
}

fn item_dir(item_id: &str) -> PathBuf {
    config::downloads_dir().join(item_id)
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
            flag.store(true, Ordering::SeqCst);
        }
    }

    pub fn is_active(&self, item_id: &str) -> bool {
        self.cancels.lock().unwrap().contains_key(item_id)
    }

    pub fn start(&self, app: AppHandle, req: DownloadRequest) -> Result<(), String> {
        {
            let cancels = self.cancels.lock().unwrap();
            if cancels.contains_key(&req.item_id) {
                return Err("download already in progress for this item".into());
            }
        }

        let dir = item_dir(&req.item_id);
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
            "url": req.url,
            "image_url": req.image_url,
            "series_image_url": req.series_image_url,
            "season_image_url": req.season_image_url,
            "estimated_bytes": req.estimated_bytes,
        });
        write_meta(&dir, &meta);

        let flag = Arc::new(AtomicBool::new(false));
        self.cancels
            .lock()
            .unwrap()
            .insert(req.item_id.clone(), flag.clone());

        let cancels_key = req.item_id.clone();
        // Self is managed state (alive for the app's lifetime); use a raw
        // pointer-free approach: clean the map entry via a clone of the Arc map.
        let app2 = app.clone();
        tauri::async_runtime::spawn(async move {
            let result = run_download(&app2, &req, &dir, flag.clone()).await;

            let mut meta = std::fs::read_to_string(dir.join("meta.json"))
                .ok()
                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                .unwrap_or_else(|| json!({}));

            match result {
                Ok(()) => {
                    meta["status"] = json!("complete");
                    write_meta(&dir, &meta);
                    emit(
                        &app2,
                        json!({ "item_id": req.item_id, "state": "complete" }),
                    );
                }
                Err(e) if e == "canceled" => {
                    let _ = std::fs::remove_dir_all(&dir);
                    emit(
                        &app2,
                        json!({ "item_id": req.item_id, "state": "canceled" }),
                    );
                }
                Err(e) => {
                    meta["status"] = json!("error");
                    meta["error"] = json!(e);
                    write_meta(&dir, &meta);
                    emit(
                        &app2,
                        json!({ "item_id": req.item_id, "state": "error", "message": e }),
                    );
                }
            }

            // Remove the cancel flag entry.
            if let Some(mgr) = app2.try_state::<DlManager>() {
                mgr.cancels.lock().unwrap().remove(&cancels_key);
            }
        });

        Ok(())
    }
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
    cancel: Arc<AtomicBool>,
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

    while let Some(chunk) = stream.next().await {
        if cancel.load(Ordering::SeqCst) {
            drop(file);
            let _ = tokio::fs::remove_file(&part_path).await;
            return Err("canceled".into());
        }
        let chunk = chunk.map_err(|e| format!("stream error: {}", e))?;
        file.write_all(&chunk).await.map_err(|e| e.to_string())?;
        received += chunk.len() as u64;
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
    tokio::fs::rename(&part_path, &final_path)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Rebuild a DownloadRequest from an item's on-disk meta.json (the "request"
/// block written by `start`) and start it again. Any existing .part file is
/// picked up by the Range-resume logic in `run_download`.
pub fn restart(app: AppHandle, mgr: &DlManager, item_id: &str) -> Result<(), String> {
    let dir = item_dir(item_id);
    let meta: Value = std::fs::read_to_string(dir.join("meta.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .ok_or("no download metadata for this item")?;
    let request = meta
        .get("request")
        .ok_or("download predates resume support; delete and re-download")?;
    let str_of = |v: &Value, k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
    let req = DownloadRequest {
        item_id: item_id.to_string(),
        url: str_of(request, "url").ok_or("stored request has no url")?,
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
        if let Err(e) = restart(app.clone(), &mgr, item_id) {
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
    let meta_path = item_dir(item_id).join("meta.json");
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
    let dir = item_dir(item_id);
    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    Ok(())
}
