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

/// Who is signed in, as the `owner` a queue entry carries.
fn current_owner() -> Option<String> {
    let cfg = config::load();
    let server = cfg.get("server")?.as_str()?.trim_end_matches('/');
    let user = cfg.get("user_id")?.as_str()?;
    if server.is_empty() || user.is_empty() {
        return None;
    }
    Some(format!("{server}|{user}"))
}

/// Whether an entry can go to the server under this owner. The server files it
/// under whoever's token it arrives with, so another account's entry waits for
/// that account. Entries from before owners were recorded have none, and go.
fn is_owned(entry: &Value, owner: &str) -> bool {
    match entry.get("owner").and_then(|v| v.as_str()) {
        Some(o) => o == owner,
        None => true,
    }
}

/// Record playback progress of a downloaded item locally. Upserts the sync
/// queue entry and mirrors position into the download's meta.json so the
/// Downloads UI can offer resume. Played signed out, it stays local: nobody's
/// history is the right place for it.
pub fn store_local(item_id: &str, position_ticks: u64, played: bool) {
    // The id becomes a path under the downloads folder below and a server
    // path at sync time, so it gets the same check a download's folder does.
    let dir = match crate::downloads::item_dir(item_id) {
        Ok(dir) => dir,
        Err(e) => {
            crate::debug_log_line(&format!("progress: not stored: {e}"));
            return;
        }
    };
    if let Some(owner) = current_owner() {
        let mut q = read_queue();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let entry = json!({
            "item_id": item_id,
            "owner": owner,
            "position_ticks": if played { 0 } else { position_ticks },
            "played": played,
            "updated_at": now,
        });
        if let Some(e) = q.iter_mut().find(|e| {
            e.get("item_id").and_then(|v| v.as_str()) == Some(item_id) && is_owned(e, &owner)
        }) {
            *e = entry;
        } else {
            q.push(entry);
        }
        write_queue(&q);
    }

    // Mirror into download metadata for the Downloads view.
    let meta_path = dir.join("meta.json");
    if let Ok(s) = std::fs::read_to_string(&meta_path) {
        if let Some(mut meta) = serde_json::from_str::<Value>(&s).ok().filter(Value::is_object) {
            meta["position_ticks"] = json!(if played { 0 } else { position_ticks });
            meta["played"] = json!(played);
            if let Ok(out) = serde_json::to_string_pretty(&meta) {
                let _ = std::fs::write(&meta_path, out);
            }
        }
    }
}

/// The queue entries that belong to whoever is signed in.
fn owned_entries() -> Vec<Value> {
    let Some(owner) = current_owner() else {
        return Vec::new();
    };
    read_queue().into_iter().filter(|e| is_owned(e, &owner)).collect()
}

pub fn pending_count() -> usize {
    owned_entries().len()
}

/// Item ids with offline progress not yet pushed to the server. The Downloads
/// view skips these when refreshing local watch state *from* the server, so an
/// unsynced local watch isn't clobbered by stale server data.
pub fn pending_item_ids() -> Vec<String> {
    owned_entries()
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
    let mut held: Vec<Value> = Vec::new();
    let mut synced = 0usize;
    let owner = current_owner();

    for entry in q {
        if !owner.as_deref().is_some_and(|o| is_owned(&entry, o)) {
            held.push(entry);
            continue;
        }
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
                "PlaySessionId": format!("aquarium-offline-{}", item_id),
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
    remaining.append(&mut held);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_go_only_to_their_own_account() {
        let parent = json!({ "item_id": "a", "owner": "https://jf|parent" });
        assert!(is_owned(&parent, "https://jf|parent"));
        assert!(!is_owned(&parent, "https://jf|child"));
        assert!(!is_owned(&parent, "https://other|parent"));
    }

    #[test]
    fn entries_from_before_owners_were_recorded_still_go() {
        assert!(is_owned(&json!({ "item_id": "a" }), "https://jf|parent"));
    }
}
