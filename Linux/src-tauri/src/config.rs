use serde_json::{json, Value};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

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

pub fn load() -> Value {
    harden(&config_dir(), DIR_MODE);
    harden(&config_path(), FILE_MODE);
    let mut cfg: Value = std::fs::read_to_string(config_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({}));
    if !cfg.is_object() {
        cfg = json!({});
    }
    // Ensure a persistent device id exists; Jellyfin uses it to identify this install.
    if cfg.get("device_id").and_then(|v| v.as_str()).is_none() {
        cfg["device_id"] = json!(uuid::Uuid::new_v4().to_string());
        let _ = save(&cfg);
    }
    cfg
}

pub fn save(cfg: &Value) -> Result<(), String> {
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
