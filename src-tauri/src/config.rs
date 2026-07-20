use serde_json::{json, Value};
use std::path::PathBuf;

pub fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("fellyjin")
}

pub fn data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("fellyjin")
}

pub fn downloads_dir() -> PathBuf {
    data_dir().join("downloads")
}

fn config_path() -> PathBuf {
    config_dir().join("config.json")
}

pub fn load() -> Value {
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
    std::fs::write(
        config_path(),
        serde_json::to_string_pretty(cfg).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())
}
