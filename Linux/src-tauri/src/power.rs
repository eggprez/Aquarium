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

#[cfg(test)]
mod tests {
    use super::*;
    use dbus::arg::{RefArg, Variant};

    /// The two flags are process-wide; these tests take turns with them.
    static FLAGS: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn props(key: &str, value: Box<dyn RefArg>) -> PropMap {
        let mut m = PropMap::new();
        m.insert(key.to_string(), Variant(value));
        m
    }

    fn reset() {
        ON_BATTERY.store(false, Ordering::SeqCst);
        POWER_SAVER.store(false, Ordering::SeqCst);
    }

    #[test]
    fn battery_or_power_saver_is_low_power() {
        let _g = FLAGS.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        assert!(!low_power());
        apply(UPOWER, &props("OnBattery", Box::new(true)));
        assert!(low_power());
        apply(UPOWER, &props("OnBattery", Box::new(false)));
        assert!(!low_power());
        for (name, _) in PROFILES {
            apply(name, &props("ActiveProfile", Box::new("power-saver".to_string())));
            assert!(low_power(), "{name}");
            apply(name, &props("ActiveProfile", Box::new("balanced".to_string())));
            assert!(!low_power(), "{name}");
        }
        reset();
    }

    /// A change that doesn't carry the property, or comes from some other
    /// interface, leaves the answer as it was.
    #[test]
    fn unrelated_changes_change_nothing() {
        let _g = FLAGS.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        apply(UPOWER, &props("OnBattery", Box::new(true)));
        apply(UPOWER, &props("Percentage", Box::new(50.0f64)));
        assert!(low_power());
        apply("org.example.Other", &props("OnBattery", Box::new(false)));
        assert!(low_power());
        // A profile name on the UPower interface is not a profile change.
        apply(UPOWER, &props("ActiveProfile", Box::new("performance".to_string())));
        assert!(ON_BATTERY.load(Ordering::SeqCst) && !POWER_SAVER.load(Ordering::SeqCst));
        // A wrongly typed value is ignored.
        apply(UPOWER, &props("OnBattery", Box::new("no".to_string())));
        assert!(low_power());
        reset();
    }

    #[test]
    fn both_power_profiles_daemon_names_are_watched() {
        let names: Vec<&str> = PROFILES.iter().map(|(n, _)| *n).collect();
        assert_eq!(names, ["org.freedesktop.UPower.PowerProfiles", "net.hadess.PowerProfiles"]);
        assert_eq!(UPOWER_PATH, "/org/freedesktop/UPower");
    }

    /// Without a system bus (the test sandbox has none) the watcher thread
    /// gives up quietly and nothing reads as low-power.
    #[test]
    fn no_system_bus_is_not_low_power() {
        let _g = FLAGS.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        assert!(Connection::new_system().is_err() || crate::test_support::real_dbus());
        assert!(!low_power());
    }
}
