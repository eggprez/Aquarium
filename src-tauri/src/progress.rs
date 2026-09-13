use crate::{config, jellyfin};
use serde_json::{json, Value};
use std::path::PathBuf;

fn queue_path() -> PathBuf {
    config::data_dir().join("progress-queue.json")
}

fn read_queue() -> Vec<Value> {
    std::fs::read_to_string(queue_path())
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<Value>>(&s).ok())
        .unwrap_or_default()
}

fn write_queue(q: &[Value]) {
    let _ = std::fs::create_dir_all(config::data_dir());
    if let Ok(s) = serde_json::to_string_pretty(q) {
        let _ = std::fs::write(queue_path(), s);
    }
}

/// Record playback progress of a downloaded item locally. Upserts the sync
/// queue entry and mirrors position into the download's meta.json so the
/// Downloads UI can offer resume.
pub fn store_local(item_id: &str, position_ticks: u64, played: bool) {
    let mut q = read_queue();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let entry = json!({
        "item_id": item_id,
        "position_ticks": if played { 0 } else { position_ticks },
        "played": played,
        "updated_at": now,
    });
    if let Some(e) = q
        .iter_mut()
        .find(|e| e.get("item_id").and_then(|v| v.as_str()) == Some(item_id))
    {
        *e = entry;
    } else {
        q.push(entry);
    }
    write_queue(&q);

    // Mirror into download metadata for the Downloads view.
    let meta_path = config::downloads_dir().join(item_id).join("meta.json");
    if let Ok(s) = std::fs::read_to_string(&meta_path) {
        if let Ok(mut meta) = serde_json::from_str::<Value>(&s) {
            meta["position_ticks"] = json!(if played { 0 } else { position_ticks });
            meta["played"] = json!(played);
            if let Ok(out) = serde_json::to_string_pretty(&meta) {
                let _ = std::fs::write(&meta_path, out);
            }
        }
    }
}

pub fn pending_count() -> usize {
    read_queue().len()
}

/// Item ids with offline progress not yet pushed to the server. The Downloads
/// view skips these when refreshing local watch state *from* the server, so an
/// unsynced local watch isn't clobbered by stale server data.
pub fn pending_item_ids() -> Vec<String> {
    read_queue()
        .iter()
        .filter_map(|e| e.get("item_id").and_then(|v| v.as_str()).map(String::from))
        .collect()
}

/// Push queued offline progress to the server. Resume positions are reported
/// via a playback-stopped report (which Jellyfin uses to set the resume
/// point); fully-watched items are marked played.
pub async fn sync(server: &str, token: &str, device_id: &str, user_id: &str) -> Value {
    let q = read_queue();
    let mut remaining: Vec<Value> = Vec::new();
    let mut synced = 0usize;

    for entry in q {
        let item_id = entry
            .get("item_id")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let played = entry.get("played").and_then(|v| v.as_bool()).unwrap_or(false);
        let ticks = entry
            .get("position_ticks")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        if item_id.is_empty() {
            continue;
        }

        let ok = if played {
            mark_played(server, token, device_id, user_id, &item_id).await
        } else {
            let body = json!({
                "ItemId": item_id,
                "PositionTicks": ticks,
                "PlaySessionId": format!("fellyjin-offline-{}", item_id),
            });
            matches!(
                jellyfin::post(server, token, device_id, "/Sessions/Playing/Stopped", &body).await,
                Ok(s) if s.is_success()
            )
        };

        if ok {
            synced += 1;
        } else {
            remaining.push(entry);
        }
    }

    let failed = remaining.len();
    write_queue(&remaining);
    json!({ "synced": synced, "failed": failed })
}

async fn mark_played(
    server: &str,
    token: &str,
    device_id: &str,
    user_id: &str,
    item_id: &str,
) -> bool {
    // The 10.9+ route, which is also the only one the rest of the app uses;
    // the `/Users/{userId}/PlayedItems/{itemId}` fallback that used to sit
    // behind it served servers no other request here can talk to any more.
    let path = format!("/UserPlayedItems/{}?userId={}", item_id, user_id);
    matches!(
        jellyfin::post(server, token, device_id, &path, &json!({})).await,
        Ok(s) if s.is_success()
    )
}
