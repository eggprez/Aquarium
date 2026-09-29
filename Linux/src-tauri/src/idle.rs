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
}
