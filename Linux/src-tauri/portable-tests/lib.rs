//! The app's platform-neutral modules, built from the same source files as the
//! app (`../src/*.rs`) so their `#[cfg(test)]` tests run without GTK, WebKit,
//! Wayland or libmpv. Nothing here is shipped.
//!
//! What a module needs from the crate root (`debug_log_line`, `now_ms`) and
//! from modules that can't be built here (`mpv`) is supplied below with the
//! same signatures.
#![allow(dead_code)]

#[path = "../src/config.rs"]
mod config;
#[path = "../src/discovery.rs"]
mod discovery;
#[path = "../src/download_extras.rs"]
mod download_extras;
#[path = "../src/downloads.rs"]
mod downloads;
#[cfg(target_os = "linux")]
#[path = "../src/idle.rs"]
mod idle;
#[path = "../src/jellyfin.rs"]
mod jellyfin;
#[path = "../src/prefs.rs"]
mod prefs;
#[path = "../src/progress.rs"]
mod progress;
#[cfg(target_os = "linux")]
#[path = "../src/secret.rs"]
mod secret;
#[path = "../src/server.rs"]
mod server;

#[cfg(not(target_os = "linux"))]
mod stubs;
#[cfg(not(target_os = "linux"))]
use stubs::{idle, secret};

/// Stand-in for the one thing `server.rs` asks of `mpv.rs`.
mod mpv {
    pub fn remove_logs() {
        let _ = std::fs::remove_dir_all(crate::config::data_dir().join("mpv-logs"));
    }
}

/// Same contract as the app's: append a line to `<data dir>/debug.log`.
pub(crate) fn debug_log_line(msg: &str) {
    use std::io::Write;
    let _ = std::fs::create_dir_all(config::data_dir());
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(config::data_dir().join("debug.log"))
    {
        let _ = writeln!(f, "{}", msg);
    }
}

pub(crate) fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}
