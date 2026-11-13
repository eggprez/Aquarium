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

    use crate::test_support::{debug_log, sandbox, sign_in, FakeServer, Resp, TEST_TOKEN, TEST_USER};

    fn queue_on_disk() -> Value {
        std::fs::read_to_string(queue_path())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(Value::Null)
    }

    fn sign_in_as(server: &str, user: &str) {
        config::merge(json!({ "server": server, "user_id": user })).unwrap();
    }

    fn download_with_meta(item: &str, meta: &str) -> PathBuf {
        let dir = config::downloads_dir().join(item);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("meta.json"), meta).unwrap();
        dir
    }

    fn meta(dir: &std::path::Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(dir.join("meta.json")).unwrap()).unwrap()
    }

    #[test]
    fn the_owner_is_server_and_user() {
        let _s = sandbox();
        assert_eq!(current_owner(), None);
        sign_in_as("https://jf.example/", "u1");
        assert_eq!(current_owner().as_deref(), Some("https://jf.example|u1"));
        sign_in_as("https://jf.example", "");
        assert_eq!(current_owner(), None);
        config::merge(json!({ "server": "", "user_id": "u1" })).unwrap();
        assert_eq!(current_owner(), None);
    }

    #[test]
    fn progress_is_queued_under_the_signed_in_account_and_mirrored_into_the_download() {
        let _s = sandbox();
        sign_in_as("http://jf", "u1");
        let dir = download_with_meta("item1", r#"{"name":"Ep 1","status":"done"}"#);

        store_local("item1", 12_345, false);
        let q = queue_on_disk();
        assert_eq!(q.as_array().unwrap().len(), 1);
        assert_eq!(q[0]["item_id"], json!("item1"));
        assert_eq!(q[0]["owner"], json!("http://jf|u1"));
        assert_eq!(q[0]["position_ticks"], json!(12_345));
        assert_eq!(q[0]["played"], json!(false));
        assert!(q[0]["updated_at"].as_u64().unwrap() > 0);
        let m = meta(&dir);
        assert_eq!(m["position_ticks"], json!(12_345));
        assert_eq!(m["played"], json!(false));
        assert_eq!(m["name"], json!("Ep 1"), "other details are kept");
        assert_eq!(m["status"], json!("done"));

        // The same item again replaces its entry; played resets the position.
        store_local("item1", 99_999, true);
        let q = queue_on_disk();
        assert_eq!(q.as_array().unwrap().len(), 1);
        assert_eq!(q[0]["played"], json!(true));
        assert_eq!(q[0]["position_ticks"], json!(0));
        assert_eq!(meta(&dir)["position_ticks"], json!(0));
        assert_eq!(meta(&dir)["played"], json!(true));

        assert_eq!(pending_count(), 1);
        assert_eq!(pending_item_ids(), vec!["item1".to_string()]);
    }

    #[test]
    fn played_signed_out_it_stays_local() {
        // Regression: e929365. Signed out there is nobody to file it under.
        let _s = sandbox();
        let dir = download_with_meta("item1", r#"{"name":"Ep 1"}"#);
        store_local("item1", 500, false);
        assert_eq!(queue_on_disk(), Value::Null, "nothing should be queued");
        assert_eq!(meta(&dir)["position_ticks"], json!(500), "the download still remembers it");
        assert_eq!(pending_count(), 0);
        assert!(pending_item_ids().is_empty());
    }

    #[test]
    fn an_item_id_that_is_not_an_id_is_refused() {
        // Regression: 6210523. The id is joined onto the downloads folder.
        let _s = sandbox();
        sign_in_as("http://jf", "u1");
        std::fs::create_dir_all(config::data_dir()).unwrap();
        std::fs::write(config::data_dir().join("meta.json"), r#"{"keep":true}"#).unwrap();
        for bad in ["..", "../..", "a/b", "", "x y"] {
            store_local(bad, 1, false);
        }
        assert_eq!(queue_on_disk(), Value::Null);
        assert_eq!(
            std::fs::read_to_string(config::data_dir().join("meta.json")).unwrap(),
            r#"{"keep":true}"#
        );
        assert!(debug_log().contains("progress: not stored"), "{}", debug_log());
    }

    #[test]
    fn a_download_record_that_is_not_an_object_is_left_alone() {
        // Regression: f1e01de. Indexing into a non-object Value panics.
        let _s = sandbox();
        sign_in_as("http://jf", "u1");
        let dir = download_with_meta("item1", "[1,2]");
        store_local("item1", 7, false);
        assert_eq!(std::fs::read_to_string(dir.join("meta.json")).unwrap(), "[1,2]");
        let bad_json = download_with_meta("item2", "{oops");
        store_local("item2", 7, false);
        assert_eq!(std::fs::read_to_string(bad_json.join("meta.json")).unwrap(), "{oops");
        // No download at all: only the queue.
        store_local("item3", 7, false);
        assert!(!config::downloads_dir().join("item3").exists());
        assert_eq!(pending_count(), 3);
    }

    #[test]
    fn another_accounts_entry_for_the_same_item_is_kept_apart() {
        // Regression: e929365. One account's watch must not overwrite, or be
        // reported as, another's.
        let _s = sandbox();
        sign_in_as("http://jf", "parent");
        store_local("item1", 100, false);
        sign_in_as("http://jf", "child");
        store_local("item1", 200, false);
        let q = queue_on_disk();
        assert_eq!(q.as_array().unwrap().len(), 2);
        assert_eq!(pending_count(), 1);
        sign_in_as("http://jf", "parent");
        assert_eq!(pending_count(), 1);
        let mine: Vec<Value> = read_queue().into_iter().filter(|e| e["owner"] == "http://jf|parent").collect();
        assert_eq!(mine[0]["position_ticks"], json!(100));
    }

    #[test]
    fn entries_without_an_owner_belong_to_whoever_is_signed_in() {
        let _s = sandbox();
        write_queue(&[
            json!({ "item_id": "old", "position_ticks": 5, "played": false }),
            json!({ "item_id": "theirs", "owner": "http://jf|other", "position_ticks": 5, "played": false }),
        ]);
        assert_eq!(pending_count(), 0, "signed out, nothing is pending");
        sign_in_as("http://jf", "u1");
        assert_eq!(pending_item_ids(), vec!["old".to_string()]);
        // Played now, the old entry is replaced by an owned one.
        store_local("old", 9, false);
        let q = read_queue();
        assert_eq!(q.len(), 2);
        assert!(q.iter().any(|e| e["item_id"] == "old" && e["owner"] == "http://jf|u1"));
    }

    #[test]
    fn an_unreadable_queue_reads_as_empty() {
        let _s = sandbox();
        sign_in_as("http://jf", "u1");
        std::fs::create_dir_all(config::data_dir()).unwrap();
        std::fs::write(queue_path(), "not json").unwrap();
        assert_eq!(pending_count(), 0);
        assert!(read_queue().is_empty());
    }

    // ---------- sync ----------

    #[tokio::test]
    async fn sync_reports_positions_and_marks_played_items() {
        let _s = sandbox();
        let server = FakeServer::start(|_| Resp::status(204));
        sign_in(&server.url);
        store_local("partial", 42_000_000, false);
        store_local("done", 1, true);

        let out = sync(&server.url, TEST_TOKEN, "dev-1", TEST_USER).await;
        assert_eq!(out, json!({ "synced": 2, "failed": 0 }));
        assert!(read_queue().is_empty(), "synced entries leave the queue");

        let stopped = server.requests_to("/Sessions/Playing/Stopped");
        assert_eq!(stopped.len(), 1);
        assert_eq!(
            stopped[0].json(),
            json!({ "ItemId": "partial", "PositionTicks": 42_000_000u64, "PlaySessionId": "aquarium-offline-partial" })
        );
        assert_eq!(
            stopped[0].header("authorization"),
            Some(crate::jellyfin::auth_header(TEST_TOKEN, "dev-1").as_str())
        );
        // The 10.9+ route, with the user as a query parameter.
        let played = server.requests_to("/UserPlayedItems/done");
        assert_eq!(played.len(), 1);
        assert_eq!(played[0].method, "POST");
        assert_eq!(played[0].query(), format!("userId={TEST_USER}"));
        assert!(server.requests_to(&format!("/Users/{TEST_USER}/PlayedItems/done")).is_empty());
    }

    #[tokio::test]
    async fn entries_the_server_refuses_stay_queued() {
        let _s = sandbox();
        let server = FakeServer::start(|req| {
            if req.path().contains("bad") || req.json()["ItemId"] == "bad" {
                Resp::status(500)
            } else {
                Resp::status(204)
            }
        });
        sign_in(&server.url);
        store_local("good", 10, false);
        store_local("bad", 10, false);
        store_local("badplayed", 0, true);
        let out = sync(&server.url, TEST_TOKEN, "dev-1", TEST_USER).await;
        assert_eq!(out, json!({ "synced": 1, "failed": 2 }));
        let mut left = pending_item_ids();
        left.sort();
        assert_eq!(left, vec!["bad".to_string(), "badplayed".to_string()]);
    }

    #[tokio::test]
    async fn an_unreachable_server_keeps_everything() {
        let _s = sandbox();
        let dead = FakeServer::dead_url();
        sign_in(&dead);
        store_local("a", 10, false);
        store_local("b", 0, true);
        let out = sync(&dead, TEST_TOKEN, "dev-1", TEST_USER).await;
        assert_eq!(out, json!({ "synced": 0, "failed": 2 }));
        assert_eq!(pending_count(), 2);
    }

    #[tokio::test]
    async fn other_accounts_entries_wait_for_their_account() {
        // Regression: e929365. The server files a report under whoever's
        // token it arrives with.
        let _s = sandbox();
        let server = FakeServer::start(|_| Resp::status(204));
        sign_in(&server.url);
        write_queue(&[
            json!({ "item_id": "theirs", "owner": format!("{}|someone-else", server.url), "position_ticks": 5, "played": false }),
            json!({ "item_id": "legacy", "position_ticks": 6, "played": false }),
            json!({ "item_id": "", "position_ticks": 6, "played": false }),
        ]);
        let out = sync(&server.url, TEST_TOKEN, "dev-1", TEST_USER).await;
        assert_eq!(out, json!({ "synced": 1, "failed": 0 }));
        let left = read_queue();
        assert_eq!(left.len(), 1, "the other account's entry is held; the id-less one is dropped");
        assert_eq!(left[0]["item_id"], json!("theirs"));
        let sent = server.requests_to("/Sessions/Playing/Stopped");
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].json()["ItemId"], json!("legacy"));
    }

    /// Against the live QA server (Jellyfin 12), as the suite's own account:
    /// a queued position and a queued "played" each land in the item's user
    /// data, and the item is put back as it was. Skips (with a reason on
    /// stderr) when the server isn't there.
    #[tokio::test]
    async fn qa_server_takes_offline_progress() {
        crate::test_support::with_qa_session(|qa, _who| async move {
            assert!(qa.account.writable, "only the suite's own account may be written with");
            // Over 5 minutes long: the server sets short titles back to unplayed at 0 on stop.
            let item = crate::test_support::qa_find_item("Movie", "FX Long Direct Play", "UserData")
                .await
                .expect("the QA library has FX Long Direct Play");
            let id = item["Id"].as_str().unwrap().to_string();
            let before = item["UserData"].clone();
            let cfg = config::load();
            let user = cfg["user_id"].as_str().unwrap().to_string();
            let server = cfg["server"].as_str().unwrap().to_string();
            let token = crate::secret::token().expect("token");
            let device = config::device_id();
            let user_data = || async {
                crate::test_support::qa_find_item("Movie", "FX Long Direct Play", "UserData").await.unwrap()["UserData"].clone()
            };

            let outcome = std::panic::AssertUnwindSafe(async {
                // 7 minutes in, played offline.
                store_local(&id, 4_200_000_000, false);
                assert_eq!(sync(&server, &token, &device, &user).await, json!({ "synced": 1, "failed": 0 }));
                let ud = user_data().await;
                assert_eq!(ud["PlaybackPositionTicks"], json!(4_200_000_000u64), "{ud}");
                // Finished offline.
                store_local(&id, 0, true);
                assert_eq!(sync(&server, &token, &device, &user).await, json!({ "synced": 1, "failed": 0 }));
                assert_eq!(user_data().await["Played"], json!(true));
                assert_eq!(pending_count(), 0);
            });
            let result = futures_util::FutureExt::catch_unwind(outcome).await;

            // Put it back: played state, then position.
            let path = format!("/UserPlayedItems/{id}?userId={user}");
            if before["Played"] == json!(true) {
                let _ = crate::server::request(&path, Some("POST".into()), None).await;
            } else {
                let _ = crate::server::request(&path, Some("DELETE".into()), None).await;
            }
            let ticks = before["PlaybackPositionTicks"].as_u64().unwrap_or(0);
            let body = json!({ "ItemId": id, "PositionTicks": ticks, "PlaySessionId": "aquarium-cargo-test-restore" });
            let _ = crate::jellyfin::post(&server, &token, &device, "/Sessions/Playing/Stopped", &body).await;
            let after = user_data().await;
            assert_eq!(after["Played"], before["Played"], "played state not restored");
            assert_eq!(after["PlaybackPositionTicks"], before["PlaybackPositionTicks"], "position not restored");
            if let Err(p) = result {
                std::panic::resume_unwind(p);
            }
        })
        .await;
    }

    #[tokio::test]
    async fn signed_out_sync_sends_nothing() {
        let _s = sandbox();
        let server = FakeServer::start(|_| Resp::status(204));
        write_queue(&[json!({ "item_id": "legacy", "position_ticks": 6, "played": false })]);
        let out = sync(&server.url, "t", "d", "u").await;
        assert_eq!(out, json!({ "synced": 0, "failed": 0 }));
        assert!(server.requests().is_empty());
        assert_eq!(read_queue().len(), 1);
    }
}
