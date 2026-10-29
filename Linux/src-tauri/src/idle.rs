//! Keeps the screen awake during playback.
//!
//! mpv can't do this itself in Aquarium: it runs in-process and renders
//! through libmpv's render API into a GtkGLArea we own (see
//! WAYLAND-MIGRATION.md), so it has no window or VO of its own for its
//! built-in screensaver suspension to hook — that mechanism assumes mpv owns
//! a real window on the display server, which here it never does. The
//! inhibition must come from the app instead, via the
//! org.freedesktop.ScreenSaver D-Bus interface (implemented by GNOME's
//! gsd-screensaver, KDE, XFCE, …).
//!
//! The inhibition lives only as long as the D-Bus *connection* that took it
//! (compositors drop it when the peer disconnects), so the connection is
//! held for the inhibitor's lifetime; dropping the struct releases both.

use dbus::blocking::Connection;
use std::time::Duration;

const BUS: &str = "org.freedesktop.ScreenSaver";
const PATH: &str = "/org/freedesktop/ScreenSaver";
const TIMEOUT: Duration = Duration::from_secs(2);

pub struct IdleInhibitor {
    conn: Connection,
    cookie: u32,
}

impl IdleInhibitor {
    pub fn new() -> Result<Self, dbus::Error> {
        let conn = Connection::new_session()?;
        let (cookie,): (u32,) = conn
            .with_proxy(BUS, PATH, TIMEOUT)
            .method_call(BUS, "Inhibit", ("Aquarium", "Video playback"))?;
        Ok(Self { conn, cookie })
    }
}

impl Drop for IdleInhibitor {
    fn drop(&mut self) {
        let _: Result<(), _> = self
            .conn
            .with_proxy(BUS, PATH, TIMEOUT)
            .method_call(BUS, "UnInhibit", (self.cookie,));
    }
}

/// Keeps the machine from suspending on idle while downloads run, without
/// keeping the screen on: the screen can blank and lock, the transfer goes on.
///
/// GNOME's power daemon decides idle suspend and asks gnome-session whether
/// anything objects, so the session manager's "suspend" flag is the one it
/// honours. Elsewhere logind's own sleep lock does the job; its lock is a file
/// descriptor, released when the descriptor closes.
pub enum SuspendInhibitor {
    Gnome { conn: Connection, cookie: u32 },
    Logind { _fd: dbus::arg::OwnedFd },
}

const GSM_BUS: &str = "org.gnome.SessionManager";
const GSM_PATH: &str = "/org/gnome/SessionManager";
/// GSM_INHIBITOR_FLAG_SUSPEND.
const GSM_SUSPEND: u32 = 4;

impl SuspendInhibitor {
    pub fn new(why: &str) -> Result<Self, dbus::Error> {
        let gnome = Connection::new_session().and_then(|conn| {
            let (cookie,): (u32,) = conn.with_proxy(GSM_BUS, GSM_PATH, TIMEOUT).method_call(
                GSM_BUS,
                "Inhibit",
                ("aquarium", 0u32, why, GSM_SUSPEND),
            )?;
            Ok(Self::Gnome { conn, cookie })
        });
        if gnome.is_ok() {
            return gnome;
        }
        let conn = Connection::new_system()?;
        let (fd,): (dbus::arg::OwnedFd,) = conn
            .with_proxy("org.freedesktop.login1", "/org/freedesktop/login1", TIMEOUT)
            .method_call(
                "org.freedesktop.login1.Manager",
                "Inhibit",
                ("sleep", "Aquarium", why, "block"),
            )?;
        Ok(Self::Logind { _fd: fd })
    }
}

impl Drop for SuspendInhibitor {
    fn drop(&mut self) {
        if let Self::Gnome { conn, cookie } = self {
            let _: Result<(), _> = conn
                .with_proxy(GSM_BUS, GSM_PATH, TIMEOUT)
                .method_call(GSM_BUS, "Uninhibit", (*cookie,));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Playback now takes and releases the inhibitor repeatedly as the stream
    /// pauses and resumes, where it used to be taken once per mpv session.
    /// Check the round trip survives being cycled: a stale cookie or a
    /// connection that can't be re-established would leave the screen either
    /// permanently awake or never inhibited at all.
    ///
    /// Needs a session bus with org.freedesktop.ScreenSaver, so it's opt-in:
    ///   cargo test --lib idle -- --ignored --nocapture
    #[test]
    #[ignore]
    fn inhibitor_cycles() {
        for round in 0..3 {
            let inhibitor = IdleInhibitor::new()
                .unwrap_or_else(|e| panic!("round {}: Inhibit failed: {}", round, e));
            assert_ne!(inhibitor.cookie, 0, "round {}: no cookie returned", round);
            drop(inhibitor); // UnInhibit runs here
        }
    }

    /// The download inhibitor takes and gives back the session's suspend
    /// lock. Opt-in for the same reason as above:
    ///   cargo test --lib idle -- --ignored --nocapture
    #[test]
    #[ignore]
    fn suspend_inhibitor_round_trip() {
        let inhibitor = SuspendInhibitor::new("test").expect("inhibit");
        assert!(matches!(inhibitor, SuspendInhibitor::Gnome { .. }), "expected GNOME's session manager");
        drop(inhibitor);
    }
}
