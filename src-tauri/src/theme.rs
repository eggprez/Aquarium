//! System light/dark preference.
//!
//! WebKitGTK only reports `prefers-color-scheme: dark` when the *GTK* theme is
//! dark, which on GNOME is not the same thing as the desktop's colour-scheme
//! setting — a user on "Dark style" with a light GTK theme name would still
//! get light from `matchMedia`. So the preference is read from the XDG desktop
//! portal (`org.freedesktop.appearance color-scheme`), which is what GNOME/KDE
//! actually flip, and pushed to the frontend as an event when it changes.
//! The frontend falls back to `matchMedia` if the portal isn't there.

use dbus::arg::Variant;
use dbus::blocking::Connection;
use dbus::message::MatchRule;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const BUS: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const IFACE: &str = "org.freedesktop.portal.Settings";
const NAMESPACE: &str = "org.freedesktop.appearance";
const KEY: &str = "color-scheme";
const TIMEOUT: Duration = Duration::from_secs(2);

/// Portal values: 0 = no preference, 1 = prefer dark, 2 = prefer light.
fn label(v: u32) -> &'static str {
    match v {
        1 => "dark",
        2 => "light",
        _ => "no-preference",
    }
}

fn read(conn: &Connection) -> Option<u32> {
    let proxy = conn.with_proxy(BUS, PATH, TIMEOUT);
    // ReadOne (portal v2+) returns the value directly; the older Read
    // double-wraps it in a variant.
    if let Ok((v,)) = proxy.method_call::<(Variant<u32>,), _, _, _>(IFACE, "ReadOne", (NAMESPACE, KEY))
    {
        return Some(v.0);
    }
    proxy
        .method_call::<(Variant<Variant<u32>>,), _, _, _>(IFACE, "Read", (NAMESPACE, KEY))
        .ok()
        .map(|(v,)| v.0 .0)
}

/// "dark" | "light" | "no-preference" | "unknown" (portal unavailable — the
/// frontend then falls back to matchMedia).
#[tauri::command]
pub fn system_color_scheme() -> String {
    let Ok(conn) = Connection::new_session() else {
        crate::debug_log_line("theme: no session bus; falling back to matchMedia");
        return "unknown".into();
    };
    let scheme = read(&conn).map(label).unwrap_or("unknown");
    crate::debug_log_line(&format!("theme: portal color-scheme = {}", scheme));
    scheme.to_string()
}

/// Watch the portal for colour-scheme changes and re-emit them as the
/// `system-color-scheme` event, so "Auto" follows the desktop live.
pub fn watch(app: AppHandle) {
    std::thread::spawn(move || {
        let Ok(conn) = Connection::new_session() else { return };
        let rule = MatchRule::new_signal(IFACE, "SettingChanged");
        // Signals only; a failure here just means "Auto" won't live-update.
        let Ok(_) = conn.add_match(rule, move |(ns, key, value): (String, String, Variant<u32>), _, _| {
            if ns == NAMESPACE && key == KEY {
                let _ = app.emit("system-color-scheme", label(value.0));
            }
            true
        }) else {
            return;
        };
        loop {
            if conn.process(Duration::from_secs(60)).is_err() {
                return;
            }
        }
    });
}
