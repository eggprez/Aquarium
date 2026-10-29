//! Whether the connection is metered, for Settings' "Download only on
//! unmetered connections" (the Apple app's "Wi-Fi only").
//!
//! GNetworkMonitor answers from NetworkManager, which marks a connection
//! metered when it's a phone hotspot, a mobile modem, or one the user flagged
//! in GNOME's network settings. The monitor is a GObject living on the main
//! context, so it is created there once and its answer kept in an atomic for
//! commands on any thread; each change is also sent to the frontend queue as
//! `network-metered`, which holds or releases downloads.

use gtk::gio;
use gtk::gio::prelude::*;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Emitter};

static METERED: AtomicBool = AtomicBool::new(false);

pub fn is_metered() -> bool {
    METERED.load(Ordering::SeqCst)
}

/// Call once on the main thread, from setup.
pub fn watch(app: &AppHandle) {
    let monitor = gio::NetworkMonitor::default();
    METERED.store(monitor.is_network_metered(), Ordering::SeqCst);
    crate::debug_log_line(&format!("network: metered={}", is_metered()));
    let app = app.clone();
    monitor.connect_network_metered_notify(move |m| {
        let metered = m.is_network_metered();
        if METERED.swap(metered, Ordering::SeqCst) != metered {
            crate::debug_log_line(&format!("network: metered={metered}"));
            let _ = app.emit("network-metered", metered);
        }
    });
    // The default monitor is a singleton the process keeps; the handler stays
    // connected for the app's lifetime.
}
