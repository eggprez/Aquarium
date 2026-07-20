//! Keeps the screen awake during playback.
//!
//! mpv can't do this itself in FellyJin: embedding is X11-only, so mpv runs
//! on XWayland, and its built-in screensaver suspension talks to the X
//! server — the Wayland compositor's idle timer (GNOME, KDE) never sees it
//! and blanks/suspends mid-video. The inhibition must come from the app,
//! via the org.freedesktop.ScreenSaver D-Bus interface (implemented by
//! GNOME's gsd-screensaver, KDE, XFCE, …).
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
            .method_call(BUS, "Inhibit", ("FellyJin", "Video playback"))?;
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
