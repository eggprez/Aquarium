use serde_json::{json, Value};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

/// config.json holds the server URL, the user id, and — whenever the desktop
/// keyring is unavailable — the access token itself. `std::fs::write` creates
/// it 0644 under the usual umask, readable by every account on the machine, so
/// it is written through a 0600 temp file and renamed into place: the
/// permissions are right before any content exists at the final path.
const FILE_MODE: u32 = 0o600;
const DIR_MODE: u32 = 0o700;

pub fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("aquarium")
}

pub fn data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("aquarium")
}

/// The app was called FellyJin before it was renamed to Aquarium. Its config,
/// downloads, window state and webview storage (localStorage, IndexedDB) all
/// sat under directories named after the old name and identifier; move each
/// one across on first launch so an upgrade keeps the user signed in, keeps
/// their downloads and doesn't reset their preferences. Must run before the
/// webview starts, which is when WebKit opens its storage under the new name.
pub fn migrate_legacy_dirs() {
    let pairs = [
        (dirs::config_dir(), "fellyjin", "aquarium"),
        (dirs::data_dir(), "fellyjin", "aquarium"),
        (dirs::config_dir(), "dev.fellyjin.app", "dev.aquarium.app"),
        (dirs::data_dir(), "dev.fellyjin.app", "dev.aquarium.app"),
        (dirs::cache_dir(), "dev.fellyjin.app", "dev.aquarium.app"),
    ];
    for (base, old, new) in pairs {
        let Some(base) = base else { continue };
        let (from, to) = (base.join(old), base.join(new));
        // Never merge into or clobber a directory the new build already made.
        if from.is_dir() && !to.exists() {
            if let Err(e) = std::fs::rename(&from, &to) {
                eprintln!("aquarium: couldn't move {} to {}: {e}", from.display(), to.display());
            }
        }
    }
}

pub fn downloads_dir() -> PathBuf {
    data_dir().join("downloads")
}

fn config_path() -> PathBuf {
    config_dir().join("config.json")
}

/// Tighten permissions on something that already exists. Applied on every load
/// as well as every save, so installs that predate this get fixed on next
/// launch rather than only on next write.
fn harden(path: &Path, mode: u32) {
    let Ok(meta) = std::fs::metadata(path) else { return };
    let mut perms = meta.permissions();
    if perms.mode() & 0o777 != mode {
        perms.set_mode(mode);
        let _ = std::fs::set_permissions(path, perms);
    }
}

/// The data folder holds logs, download records and downloaded media, none of
/// which other accounts on the machine have any business reading.
pub fn harden_data_dir() {
    harden(&data_dir(), DIR_MODE);
}

pub fn load() -> Value {
    harden(&config_dir(), DIR_MODE);
    harden(&config_path(), FILE_MODE);
    let cfg = match std::fs::read_to_string(config_path()) {
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(v) if v.is_object() => Some(v),
            Ok(_) => {
                quarantine("is not a JSON object");
                None
            }
            Err(e) => {
                quarantine(&e.to_string());
                None
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            quarantine(&e.to_string());
            None
        }
    };
    let mut cfg = cfg.unwrap_or_else(|| json!({}));
    // Ensure a persistent device id exists; Jellyfin uses it to identify this install.
    if cfg.get("device_id").and_then(|v| v.as_str()).is_none() {
        cfg["device_id"] = json!(uuid::Uuid::new_v4().to_string());
        let _ = save(&cfg);
    }
    cfg
}

/// Set when a config.json that couldn't be read also couldn't be set aside;
/// see `quarantine`.
static SAVE_BLOCKED: AtomicBool = AtomicBool::new(false);

/// Test hook: forget a blocked save from an earlier test.
#[cfg(test)]
pub fn reset_for_tests() {
    SAVE_BLOCKED.store(false, Ordering::SeqCst);
}

/// Move a config.json that can't be read aside before anything writes over it.
///
/// Starting from defaults is the only way forward, but the first save after
/// that (the device id below, or any setting) would replace the file, and with
/// it every setting, the pinned server, the user and, where there is no
/// keyring, the access token. Kept as `config.json.corrupt-<unix time>` it can
/// still be repaired by hand. If it can't be moved, it is copied, so the save
/// that follows still leaves the original intact; if it can't be copied
/// either, saving is refused for the rest of the session instead.
fn quarantine(why: &str) {
    let path = config_path();
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let aside = config_dir().join(format!("config.json.corrupt-{ts}"));
    let kept = std::fs::rename(&path, &aside)
        .or_else(|_| std::fs::copy(&path, &aside).map(|_| ()));
    let msg = match kept {
        Ok(()) => format!(
            "config: {} couldn't be read ({why}); kept it as {} and started from defaults",
            path.display(),
            aside.display()
        ),
        Err(e) => {
            SAVE_BLOCKED.store(true, Ordering::SeqCst);
            format!(
                "config: {} couldn't be read ({why}) and couldn't be set aside ({e}); \
                 started from defaults and won't save over it",
                path.display()
            )
        }
    };
    eprintln!("aquarium: {msg}");
    crate::debug_log_line(&msg);
}

pub fn save(cfg: &Value) -> Result<(), String> {
    if SAVE_BLOCKED.load(Ordering::SeqCst) {
        return Err("config.json couldn't be read or set aside, so it isn't being overwritten".into());
    }
    let dir = config_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    harden(&dir, DIR_MODE);

    let body = serde_json::to_string_pretty(cfg).map_err(|e| e.to_string())?;
    let tmp = dir.join("config.json.new");
    // `.mode()` only applies when the file is created, so a temp file left
    // behind by a crashed write would keep whatever mode it had.
    let _ = std::fs::remove_file(&tmp);
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(FILE_MODE)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        f.write_all(body.as_bytes()).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
    }
    std::fs::rename(&tmp, config_path()).map_err(|e| e.to_string())
}

/// Merge top-level keys into the stored config. The Rust-side auth path needs
/// to record the server, the pinned identity and the signed-in user without
/// round-tripping the whole config through the frontend. A `null` value drops
/// the key.
pub fn merge(patch: Value) -> Result<(), String> {
    let mut cfg = load();
    let Some(fields) = patch.as_object() else {
        return Err("config patch must be an object".into());
    };
    let Some(obj) = cfg.as_object_mut() else {
        return Err("config is not an object".into());
    };
    for (k, v) in fields {
        if v.is_null() {
            obj.remove(k);
        } else {
            obj.insert(k.clone(), v.clone());
        }
    }
    save(&cfg)
}

/// The device id Jellyfin knows this install by.
pub fn device_id() -> String {
    load()
        .get("device_id")
        .and_then(|v| v.as_str())
        .unwrap_or("aquarium")
        .to_string()
}

/// The accounts this device can switch between without a password, as stored:
/// `{ key, server, server_id, server_name, server_secure, user_id, user_name }`
/// and, only when there is no keyring, `token`.
pub fn accounts() -> Vec<Value> {
    load()
        .get("accounts")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
}

pub fn save_accounts(list: Vec<Value>) -> Result<(), String> {
    merge(json!({ "accounts": list }))
}

/// Add or update one account, keyed by `key`. Fields already stored and not
/// in `entry` (a file-mode token, say) are kept.
pub fn upsert_account(entry: Value) -> Result<(), String> {
    let key = entry.get("key").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    if key.is_empty() {
        return Err("account has no key".into());
    }
    let mut list = accounts();
    match list.iter_mut().find(|a| a.get("key").and_then(|v| v.as_str()) == Some(&key)) {
        Some(existing) => {
            if let (Some(dst), Some(src)) = (existing.as_object_mut(), entry.as_object()) {
                for (k, v) in src {
                    dst.insert(k.clone(), v.clone());
                }
            }
        }
        None => list.push(entry),
    }
    save_accounts(list)
}

pub fn remove_account(key: &str) -> Result<(), String> {
    let list: Vec<Value> = accounts()
        .into_iter()
        .filter(|a| a.get("key").and_then(|v| v.as_str()) != Some(key))
        .collect();
    save_accounts(list)
}

/// Set (or, with `null`, drop) one field of one stored account.
pub fn set_account_field(key: &str, field: &str, value: Value) -> Result<(), String> {
    let mut list = accounts();
    let Some(entry) = list
        .iter_mut()
        .find(|a| a.get("key").and_then(|v| v.as_str()) == Some(key))
        .and_then(|a| a.as_object_mut())
    else {
        return Ok(());
    };
    if value.is_null() {
        entry.remove(field);
    } else {
        entry.insert(field.to_string(), value);
    }
    save_accounts(list)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{config_on_disk, debug_log, sandbox};

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    fn write_raw(text: &str) {
        std::fs::create_dir_all(config_dir()).unwrap();
        std::fs::write(config_path(), text).unwrap();
    }

    fn corrupt_copies() -> Vec<PathBuf> {
        std::fs::read_dir(config_dir())
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with("config.json.corrupt-"))
            .collect()
    }

    #[test]
    fn folders_are_named_after_the_app() {
        let _s = sandbox();
        assert!(config_dir().ends_with("aquarium"));
        assert!(data_dir().ends_with("aquarium"));
        assert_eq!(downloads_dir(), data_dir().join("downloads"));
        assert_eq!(config_path(), config_dir().join("config.json"));
    }

    // ---------- The FellyJin migration (an invariant in Linux/CLAUDE.md) ----------

    #[test]
    fn legacy_fellyjin_folders_move_to_the_new_names() {
        let _s = sandbox();
        let cfg_base = dirs::config_dir().unwrap();
        let data_base = dirs::data_dir().unwrap();
        let cache_base = dirs::cache_dir().unwrap();
        std::fs::create_dir_all(cfg_base.join("fellyjin")).unwrap();
        std::fs::write(cfg_base.join("fellyjin/config.json"), r#"{"server":"http://old"}"#).unwrap();
        std::fs::create_dir_all(data_base.join("fellyjin/downloads/item1")).unwrap();
        std::fs::create_dir_all(cfg_base.join("dev.fellyjin.app")).unwrap();
        std::fs::write(cfg_base.join("dev.fellyjin.app/window-state.json"), "{}").unwrap();
        std::fs::create_dir_all(data_base.join("dev.fellyjin.app/localstorage")).unwrap();
        std::fs::create_dir_all(cache_base.join("dev.fellyjin.app/WebKitCache")).unwrap();

        migrate_legacy_dirs();

        assert_eq!(
            std::fs::read_to_string(cfg_base.join("aquarium/config.json")).unwrap(),
            r#"{"server":"http://old"}"#,
            "the signed-in config did not follow the rename"
        );
        assert!(data_base.join("aquarium/downloads/item1").is_dir(), "downloads did not follow");
        assert!(cfg_base.join("dev.aquarium.app/window-state.json").exists());
        assert!(data_base.join("dev.aquarium.app/localstorage").is_dir(), "webview storage did not follow");
        assert!(cache_base.join("dev.aquarium.app/WebKitCache").is_dir());
        for gone in [
            cfg_base.join("fellyjin"),
            data_base.join("fellyjin"),
            cfg_base.join("dev.fellyjin.app"),
            data_base.join("dev.fellyjin.app"),
            cache_base.join("dev.fellyjin.app"),
        ] {
            assert!(!gone.exists(), "{} was left behind", gone.display());
        }
        // The migrated config is what the app now reads.
        assert_eq!(load()["server"], json!("http://old"));
    }

    #[test]
    fn migration_never_overwrites_folders_the_new_build_made() {
        let _s = sandbox();
        let base = dirs::config_dir().unwrap();
        std::fs::create_dir_all(base.join("fellyjin")).unwrap();
        std::fs::write(base.join("fellyjin/config.json"), "old").unwrap();
        std::fs::create_dir_all(base.join("aquarium")).unwrap();
        std::fs::write(base.join("aquarium/config.json"), "new").unwrap();

        migrate_legacy_dirs();

        assert_eq!(std::fs::read_to_string(base.join("aquarium/config.json")).unwrap(), "new");
        assert_eq!(std::fs::read_to_string(base.join("fellyjin/config.json")).unwrap(), "old");
    }

    #[test]
    fn migration_ignores_a_legacy_name_that_is_not_a_folder_and_runs_twice_harmlessly() {
        let _s = sandbox();
        let base = dirs::config_dir().unwrap();
        std::fs::create_dir_all(&base).unwrap();
        std::fs::write(base.join("fellyjin"), "a stray file").unwrap();
        migrate_legacy_dirs();
        migrate_legacy_dirs();
        assert!(base.join("fellyjin").is_file());
        assert!(!base.join("aquarium").exists());
    }

    // ---------- load / save ----------

    #[test]
    fn a_first_load_creates_and_keeps_a_device_id() {
        let _s = sandbox();
        let first = load();
        let id = first["device_id"].as_str().expect("device id").to_string();
        assert!(uuid::Uuid::parse_str(&id).is_ok(), "{id} is not a uuid");
        assert_eq!(config_on_disk()["device_id"], json!(id), "the id was not saved");
        assert_eq!(load()["device_id"], json!(id));
        assert_eq!(device_id(), id);
    }

    #[test]
    fn a_stored_device_id_is_kept() {
        let _s = sandbox();
        write_raw(r#"{"device_id":"mine","server":"http://jf"}"#);
        assert_eq!(device_id(), "mine");
        assert_eq!(load()["server"], json!("http://jf"));
    }

    #[test]
    fn saves_are_private_to_the_user() {
        let _s = sandbox();
        save(&json!({ "token": "t" })).unwrap();
        assert_eq!(mode(&config_path()), 0o600);
        assert_eq!(mode(&config_dir()), 0o700);
        assert!(!config_dir().join("config.json.new").exists(), "the temp file was left behind");
        assert_eq!(config_on_disk(), json!({ "token": "t" }));
    }

    #[test]
    fn a_temp_file_left_by_a_crashed_write_does_not_lend_its_mode() {
        let _s = sandbox();
        std::fs::create_dir_all(config_dir()).unwrap();
        let tmp = config_dir().join("config.json.new");
        std::fs::write(&tmp, "half").unwrap();
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644)).unwrap();
        save(&json!({ "a": 1 })).unwrap();
        assert_eq!(mode(&config_path()), 0o600);
        assert_eq!(config_on_disk(), json!({ "a": 1 }));
    }

    #[test]
    fn loading_tightens_an_older_install() {
        let _s = sandbox();
        write_raw(r#"{"device_id":"d"}"#);
        std::fs::set_permissions(config_path(), std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::set_permissions(config_dir(), std::fs::Permissions::from_mode(0o755)).unwrap();
        load();
        assert_eq!(mode(&config_path()), 0o600);
        assert_eq!(mode(&config_dir()), 0o700);
    }

    #[test]
    fn the_data_folder_is_private_too() {
        // Regression: f1e01de made the data folder (logs with tokens, download
        // records, media) 0700.
        let _s = sandbox();
        std::fs::create_dir_all(data_dir()).unwrap();
        std::fs::set_permissions(data_dir(), std::fs::Permissions::from_mode(0o755)).unwrap();
        harden_data_dir();
        assert_eq!(mode(&data_dir()), 0o700);
        // Nothing there yet is not an error.
        std::fs::remove_dir_all(data_dir()).unwrap();
        harden_data_dir();
        assert!(!data_dir().exists());
    }

    // ---------- An unreadable config.json (regression: 0ead076) ----------

    #[test]
    fn a_corrupt_config_is_set_aside_not_overwritten() {
        // Regression: 0ead076. A config that failed to parse was replaced by
        // one holding only a device id, losing the server, user and token.
        let _s = sandbox();
        let broken = r#"{"server":"http://jf","user_id":"u","token":"t""#;
        write_raw(broken);
        let cfg = load();
        assert!(cfg["device_id"].is_string(), "defaults should still have a device id");
        assert!(cfg.get("server").is_none());
        let aside = corrupt_copies();
        assert_eq!(aside.len(), 1, "expected one config.json.corrupt-<time>");
        assert_eq!(std::fs::read_to_string(&aside[0]).unwrap(), broken);
        assert!(debug_log().contains("couldn't be read"), "{}", debug_log());
        // The new config is a fresh one and saving works.
        merge(json!({ "server": "http://new" })).unwrap();
        assert_eq!(config_on_disk()["server"], json!("http://new"));
    }

    #[test]
    fn a_config_that_is_not_an_object_is_set_aside() {
        let _s = sandbox();
        write_raw("[1, 2, 3]");
        let cfg = load();
        assert!(cfg.is_object());
        assert_eq!(corrupt_copies().len(), 1);
        assert!(debug_log().contains("is not a JSON object"));
    }

    #[test]
    fn a_config_that_cannot_be_read_is_set_aside() {
        let _s = sandbox();
        // A folder where the file should be: reading it fails with something
        // other than "not found".
        std::fs::create_dir_all(config_path()).unwrap();
        let cfg = load();
        assert!(cfg["device_id"].is_string());
        let aside = corrupt_copies();
        assert_eq!(aside.len(), 1);
        // `load` tightened the folder to 0600 on its way past; give it its
        // search bit back so the next sandbox can remove it.
        std::fs::set_permissions(&aside[0], std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn a_corrupt_config_that_cannot_be_set_aside_is_never_saved_over() {
        // Regression: 0ead076. If neither the rename nor the copy works,
        // saving is refused for the rest of the session.
        let _s = sandbox();
        let broken = "{ not json";
        write_raw(broken);
        // Occupy every name the copy could take, for the next minute, with a
        // non-empty folder: a file can be neither renamed nor copied onto one.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        for ts in now.saturating_sub(1)..now + 60 {
            let d = config_dir().join(format!("config.json.corrupt-{ts}"));
            std::fs::create_dir_all(d.join("occupied")).unwrap();
        }
        let cfg = load();
        assert!(cfg["device_id"].is_string());
        assert!(debug_log().contains("won't save over it"), "{}", debug_log());
        assert!(save(&json!({ "a": 1 })).is_err());
        assert!(merge(json!({ "server": "http://x" })).is_err());
        assert_eq!(std::fs::read_to_string(config_path()).unwrap(), broken, "the original was overwritten");
        // The test hook lifts the block.
        reset_for_tests();
        assert!(save(&json!({ "a": 1 })).is_ok());
    }

    // ---------- merge ----------

    #[test]
    fn merge_sets_and_drops_top_level_keys() {
        let _s = sandbox();
        save(&json!({ "device_id": "d", "server": "http://a", "keep": 1 })).unwrap();
        merge(json!({ "server": "http://b", "user_id": "u", "keep": null })).unwrap();
        let disk = config_on_disk();
        assert_eq!(disk["server"], json!("http://b"));
        assert_eq!(disk["user_id"], json!("u"));
        assert_eq!(disk["device_id"], json!("d"));
        assert!(disk.get("keep").is_none(), "null should drop the key");
    }

    #[test]
    fn merge_refuses_a_patch_that_is_not_an_object() {
        let _s = sandbox();
        save(&json!({ "device_id": "d", "server": "http://a" })).unwrap();
        assert!(merge(json!(["server"])).is_err());
        assert!(merge(json!("x")).is_err());
        assert_eq!(config_on_disk()["server"], json!("http://a"));
    }

    // ---------- Saved accounts ----------

    #[test]
    fn accounts_are_added_updated_and_removed_by_key() {
        let _s = sandbox();
        assert!(accounts().is_empty());
        upsert_account(json!({ "key": "a", "user_name": "Ann", "server": "http://jf" })).unwrap();
        upsert_account(json!({ "key": "b", "user_name": "Bob" })).unwrap();
        assert_eq!(accounts().len(), 2);

        // An update keeps the fields it doesn't mention (a file-mode token).
        set_account_field("a", "token", json!("tok")).unwrap();
        upsert_account(json!({ "key": "a", "user_name": "Ann B" })).unwrap();
        let a = accounts().into_iter().find(|x| x["key"] == "a").unwrap();
        assert_eq!(a["user_name"], json!("Ann B"));
        assert_eq!(a["token"], json!("tok"));
        assert_eq!(a["server"], json!("http://jf"));
        assert_eq!(accounts().len(), 2);

        set_account_field("a", "token", Value::Null).unwrap();
        let a = accounts().into_iter().find(|x| x["key"] == "a").unwrap();
        assert!(a.get("token").is_none());

        remove_account("a").unwrap();
        let left = accounts();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0]["key"], json!("b"));
        remove_account("nobody").unwrap();
        assert_eq!(accounts().len(), 1);
    }

    #[test]
    fn an_account_without_a_key_is_refused() {
        let _s = sandbox();
        assert!(upsert_account(json!({ "user_name": "x" })).is_err());
        assert!(upsert_account(json!({ "key": "" })).is_err());
        assert!(accounts().is_empty());
    }

    #[test]
    fn a_field_for_an_account_not_yet_saved_goes_nowhere() {
        // Why 13ea908 had to file the account entry before its token: without
        // a keyring the token goes into the entry, and an entry that doesn't
        // exist yet takes nothing, without an error.
        let _s = sandbox();
        assert!(set_account_field("later", "token", json!("tok")).is_ok());
        assert!(accounts().is_empty());
        upsert_account(json!({ "key": "later" })).unwrap();
        assert!(accounts()[0].get("token").is_none());
    }

    #[test]
    fn save_accounts_replaces_the_list_and_leaves_other_keys() {
        let _s = sandbox();
        save(&json!({ "device_id": "d", "server": "http://a" })).unwrap();
        save_accounts(vec![json!({ "key": "x" })]).unwrap();
        save_accounts(vec![json!({ "key": "y" }), json!({ "key": "z" })]).unwrap();
        let disk = config_on_disk();
        assert_eq!(disk["accounts"], json!([{ "key": "y" }, { "key": "z" }]));
        assert_eq!(disk["server"], json!("http://a"));
        // A stored list that isn't a list reads as none.
        merge(json!({ "accounts": "nonsense" })).unwrap();
        assert!(accounts().is_empty());
    }
}
