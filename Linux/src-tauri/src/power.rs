//! Whether the machine is asking to save power: on battery (UPower's
//! `OnBattery`) or in the power-saver profile (power-profiles-daemon's
//! `ActiveProfile`). Settings' Automatic battery rendering follows this.
//!
//! Both live on the system bus and announce changes with `PropertiesChanged`,
//! so one thread parked in `process` keeps the answer current without polling;
//! a machine without either service simply never reads as low-power.

use dbus::arg::{prop_cast, PropMap};
use dbus::blocking::stdintf::org_freedesktop_dbus::{Properties, PropertiesPropertiesChanged};
use dbus::blocking::Connection;
use dbus::message::MatchRule;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::AppHandle;

const TIMEOUT: Duration = Duration::from_secs(2);

const UPOWER: &str = "org.freedesktop.UPower";
const UPOWER_PATH: &str = "/org/freedesktop/UPower";

/// power-profiles-daemon under its current name and the one it had before
/// joining UPower (0.20 and later answer to both; older ones only the second).
const PROFILES: [(&str, &str); 2] = [
    ("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles"),
    ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles"),
];

static ON_BATTERY: AtomicBool = AtomicBool::new(false);
static POWER_SAVER: AtomicBool = AtomicBool::new(false);

/// True while the desktop says power matters more than the last bit of
/// picture quality.
pub fn low_power() -> bool {
    ON_BATTERY.load(Ordering::SeqCst) || POWER_SAVER.load(Ordering::SeqCst)
}

/// Read the current state, then follow it for the life of the app, calling
/// into the player whenever the answer to [`low_power`] flips.
pub fn watch(app: AppHandle) {
    std::thread::Builder::new()
        .name("power-watch".into())
        .spawn(move || {
            let Ok(conn) = Connection::new_system() else {
                crate::debug_log_line("power: no system bus; battery rendering stays manual");
                return;
            };
            read_initial(&conn);
            crate::debug_log_line(&format!(
                "power: on battery {}, power saver {}",
                ON_BATTERY.load(Ordering::SeqCst),
                POWER_SAVER.load(Ordering::SeqCst)
            ));

            let mut paths = vec![UPOWER_PATH];
            paths.extend(PROFILES.iter().map(|(_, p)| *p));
            for path in paths {
                let mut rule = MatchRule::new_signal("org.freedesktop.DBus.Properties", "PropertiesChanged");
                rule.path = Some(path.into());
                let app = app.clone();
                let added = conn.add_match(rule, move |sig: PropertiesPropertiesChanged, _, _| {
                    let before = low_power();
                    apply(&sig.interface_name, &sig.changed_properties);
                    let after = low_power();
                    if after != before {
                        crate::debug_log_line(&format!("power: low-power {after}"));
                        crate::player::power_changed(&app);
                    }
                    true
                });
                if added.is_err() {
                    return;
                }
            }
            loop {
                if conn.process(Duration::from_secs(3600)).is_err() {
                    return;
                }
            }
        })
        .ok();
}

fn read_initial(conn: &Connection) {
    if let Ok(v) = conn.with_proxy(UPOWER, UPOWER_PATH, TIMEOUT).get::<bool>(UPOWER, "OnBattery") {
        ON_BATTERY.store(v, Ordering::SeqCst);
    }
    for (name, path) in PROFILES {
        if let Ok(p) = conn.with_proxy(name, path, TIMEOUT).get::<String>(name, "ActiveProfile") {
            POWER_SAVER.store(p == "power-saver", Ordering::SeqCst);
            break;
        }
    }
}

fn apply(interface: &str, changed: &PropMap) {
    if interface == UPOWER {
        if let Some(v) = prop_cast::<bool>(changed, "OnBattery") {
            ON_BATTERY.store(*v, Ordering::SeqCst);
        }
    } else if PROFILES.iter().any(|(name, _)| *name == interface) {
        if let Some(p) = prop_cast::<String>(changed, "ActiveProfile") {
            POWER_SAVER.store(p == "power-saver", Ordering::SeqCst);
        }
    }
}
