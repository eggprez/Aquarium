//! MPRIS — the desktop's standard media-player interface, over D-Bus.
//!
//! This is what makes the keyboard's play/pause key work, puts the episode on
//! the GNOME lock screen and in the shell's audio menu, and lets the volume
//! popover show what's playing. mpv could expose its own MPRIS interface, but it
//! would advertise a bare file with no episode title, no duration from server
//! metadata, and no idea that a "next track" is a different Jellyfin item — so
//! the app serves it instead, and mpv stays an implementation detail.
//!
//! The whole thing lives on its own thread with a blocking connection. Control
//! requests are handed to the async runtime; state is read straight out of the
//! player's status mutex, which is already the app's single source of truth.
//!
//! State changes are pushed, not polled: the player calls `notify` when it
//! changes something the shell is told about, and this thread otherwise sleeps
//! on D-Bus's own socket. An idle Aquarium costs no wakeups at all.

use crate::player::{Player, Status};
use dbus::arg::{RefArg, Variant};
use dbus::blocking::LocalConnection;
use dbus::channel::{BusType, Channel, MatchingReceiver, Sender};
use dbus::message::MatchRule;
use dbus::Message;
use dbus_crossroads::Crossroads;
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};

const PATH: &str = "/org/mpris/MediaPlayer2";
const PLAYER_IFACE: &str = "org.mpris.MediaPlayer2.Player";
/// Everything after the well-known prefix is ours to choose; it has to match
/// the desktop-entry name for the shell to find our icon.
const BUS_NAME: &str = "org.mpris.MediaPlayer2.aquarium";

type Metadata = HashMap<String, Variant<Box<dyn RefArg>>>;

/// The four values the shell is told about. Position isn't among them: MPRIS
/// treats it as something clients poll (or infer from Rate), and announcing it
/// would wake every listener on the bus once a second for nothing.
type Announced = (String, String, f64, bool);

/// Wakes the serving thread when there's something new to announce. An eventfd
/// rather than a channel because the thread's wait is a `poll` over this and
/// D-Bus's own socket at the same time; -1 until the bus is up.
///
/// The signal itself is deliberately not sent from the calling thread. libdbus
/// would take the message but leave it in the outgoing queue — flushing it
/// needs the I/O path, which the serving thread holds while parked — so it
/// would sit there unsent until the next inbound message, and a pause would
/// reach the lock screen minutes late or not at all.
static WAKE: AtomicI32 = AtomicI32::new(-1);

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        if let Err(e) = serve(app) {
            // A machine with no session bus is a legitimate configuration; the
            // app just doesn't appear in the shell's media controls.
            crate::debug_log_line(&format!("mpris: not available: {}", e));
        }
    });
}

/// Send a command to mpv from the D-Bus thread. Fire-and-forget: MPRIS has no
/// way to report that a play/pause didn't take, and the caller is a keyboard
/// key, not something waiting on a result.
fn dispatch(app: &AppHandle, cmd: serde_json::Value) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Some(player) = app.try_state::<Player>() {
            let _ = player.send(cmd).await;
        }
    });
}

fn status_of(app: &AppHandle) -> crate::player::Status {
    app.try_state::<Player>()
        .map(|p| p.status())
        .unwrap_or_default()
}

fn playback_status_of(st: &Status) -> String {
    if !st.active {
        "Stopped"
    } else if st.paused {
        "Paused"
    } else {
        "Playing"
    }
    .to_string()
}

fn playback_status(app: &AppHandle) -> String {
    playback_status_of(&status_of(app))
}

fn next_available(app: &AppHandle) -> bool {
    app.try_state::<Player>()
        .map(|p| p.next_available())
        .unwrap_or(false)
}

/// Tell the D-Bus thread that the player's state may have moved.
///
/// Safe to call on every status update and as cheap as an 8-byte write: the
/// thread that wakes does the diffing and sends nothing when nothing changed,
/// so callers never have to work out whether the shell cares. A no-op before
/// the bus is up, and on a machine that has no session bus at all.
pub fn notify() {
    let fd = WAKE.load(Ordering::Relaxed);
    if fd < 0 {
        return;
    }
    let one: u64 = 1;
    // Non-blocking, and a counter that's already non-zero means a wakeup is
    // pending — which is exactly what this call wanted. Nothing to handle.
    unsafe {
        libc::write(fd, &one as *const u64 as *const libc::c_void, 8);
    }
}

/// Send a PropertiesChanged for whatever differs from `last`. Runs only on the
/// serving thread, which owns the connection and can actually flush it.
fn announce(app: &AppHandle, c: &LocalConnection, last: &mut Option<Announced>) {
    let st = status_of(app);
    let now: Announced = (
        playback_status_of(&st),
        st.title.clone(),
        st.volume,
        next_available(app),
    );

    let changed_keys: Vec<&str> = match last.as_ref() {
        None => vec!["PlaybackStatus", "Metadata", "Volume", "CanGoNext"],
        Some(prev) => {
            let mut keys = Vec::new();
            if prev.0 != now.0 {
                keys.push("PlaybackStatus");
            }
            if prev.1 != now.1 {
                keys.push("Metadata");
            }
            if (prev.2 - now.2).abs() > 0.5 {
                keys.push("Volume");
            }
            if prev.3 != now.3 {
                keys.push("CanGoNext");
            }
            keys
        }
    };
    if changed_keys.is_empty() {
        return;
    }

    let mut changed: Metadata = HashMap::new();
    for key in &changed_keys {
        match *key {
            "PlaybackStatus" => {
                changed.insert(key.to_string(), Variant(Box::new(now.0.clone())));
            }
            "Metadata" => {
                changed.insert(key.to_string(), Variant(Box::new(metadata(app))));
            }
            "Volume" => {
                changed.insert(key.to_string(), Variant(Box::new(now.2 / 100.0)));
            }
            "CanGoNext" => {
                changed.insert(key.to_string(), Variant(Box::new(now.3)));
            }
            _ => {}
        }
    }
    if let Ok(path) = dbus::Path::new(PATH) {
        let msg = Message::signal(
            &path,
            &"org.freedesktop.DBus.Properties".into(),
            &"PropertiesChanged".into(),
        )
        .append3(PLAYER_IFACE, changed, Vec::<String>::new());
        let _ = c.send(msg);
        // `send` only queues; this is what puts it on the wire before the
        // thread parks again.
        c.channel().flush();
    }
    *last = Some(now);
}

/// Sleep until D-Bus has something to read or `notify` pokes us, whichever
/// comes first. The timeout is not a tick — nothing is polled for here — it's
/// how long it takes to notice a bus that has gone away.
fn park(dbus_fd: i32, wake_fd: i32) {
    let mut fds = [
        libc::pollfd {
            fd: dbus_fd,
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: wake_fd,
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    unsafe {
        libc::poll(fds.as_mut_ptr(), 2, 60_000);
        // Drain the counter so the next park doesn't return immediately. A
        // failed read means it was already empty, which is fine.
        let mut sink: u64 = 0;
        libc::read(wake_fd, &mut sink as *mut u64 as *mut libc::c_void, 8);
    }
}

/// D-Bus object paths accept only `[A-Za-z0-9_]` between slashes, and a Jellyfin
/// id that failed that test would make the whole Metadata map unsendable.
fn track_path(item_id: &str) -> dbus::Path<'static> {
    let clean: String = item_id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    let raw = if clean.is_empty() {
        format!("{}/aquarium/notrack", PATH)
    } else {
        format!("{}/aquarium/{}", PATH, clean)
    };
    dbus::Path::new(raw).unwrap_or_else(|_| dbus::Path::from("/org/mpris/MediaPlayer2/aquarium"))
}

fn metadata(app: &AppHandle) -> Metadata {
    let st = status_of(app);
    let mut m: Metadata = HashMap::new();
    m.insert(
        "mpris:trackid".into(),
        Variant(Box::new(track_path(&st.item_id))),
    );
    if st.duration > 0.0 {
        let micros = (st.duration * 1_000_000.0) as i64;
        m.insert("mpris:length".into(), Variant(Box::new(micros)));
    }
    // Episode titles arrive as "Series S01E02 · Episode name". The shell has a
    // title line and an artist line, and that split maps onto them exactly;
    // anything else (a film) is a title on its own.
    let (artist, title) = match st.title.split_once(" · ") {
        Some((show, name)) => (Some(show.to_string()), name.to_string()),
        None => (None, st.title.clone()),
    };
    m.insert("xesam:title".into(), Variant(Box::new(title)));
    if let Some(a) = artist {
        m.insert("xesam:artist".into(), Variant(Box::new(vec![a])));
    }
    m
}

fn serve(app: AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    // Built from a Channel rather than `new_session` so the watch is enabled:
    // that's what exposes the socket's fd, and the fd is what lets this thread
    // wait on the bus and on `notify` in one call.
    let mut channel = Channel::get_private(BusType::Session)?;
    channel.set_watch_enabled(true);
    let dbus_fd = channel.watch().fd;
    let c: LocalConnection = channel.into();
    // `false, true, false` — don't allow replacement, do replace an existing
    // owner, don't queue. A previous instance that died without releasing the
    // name must not stop this one from taking it.
    c.request_name(BUS_NAME, false, true, false)?;

    let mut cr = Crossroads::new();

    let root = cr.register("org.mpris.MediaPlayer2", |b| {
        b.method("Raise", (), (), |_, app: &mut AppHandle, _: ()| {
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.unminimize();
                let _ = win.set_focus();
            }
            Ok(())
        });
        b.method("Quit", (), (), |_, app: &mut AppHandle, _: ()| {
            let app = app.clone();
            // Through the window rather than exit(): closing is what runs the
            // "downloads are still running" guard.
            tauri::async_runtime::spawn(async move {
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.close();
                }
            });
            Ok(())
        });
        b.property("CanQuit").get(|_, _| Ok(true));
        b.property("CanRaise").get(|_, _| Ok(true));
        b.property("HasTrackList").get(|_, _| Ok(false));
        b.property("Identity").get(|_, _| Ok("Aquarium".to_string()));
        // Lets the shell show the app's own icon next to the controls.
        b.property("DesktopEntry")
            .get(|_, _| Ok("aquarium".to_string()));
        b.property("SupportedUriSchemes")
            .get(|_, _| Ok(Vec::<String>::new()));
        b.property("SupportedMimeTypes")
            .get(|_, _| Ok(Vec::<String>::new()));
    });

    let player = cr.register(PLAYER_IFACE, |b| {
        b.method("PlayPause", (), (), |_, app: &mut AppHandle, _: ()| {
            dispatch(app, json!(["cycle", "pause"]));
            Ok(())
        });
        b.method("Play", (), (), |_, app: &mut AppHandle, _: ()| {
            dispatch(app, json!(["set_property", "pause", false]));
            Ok(())
        });
        b.method("Pause", (), (), |_, app: &mut AppHandle, _: ()| {
            dispatch(app, json!(["set_property", "pause", true]));
            Ok(())
        });
        b.method("Stop", (), (), |_, app: &mut AppHandle, _: ()| {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Some(player) = app.try_state::<Player>() {
                    player.stop().await;
                }
            });
            Ok(())
        });
        // Which item comes next is a question about the series, not about the
        // file mpv has open, so the frontend answers it.
        b.method("Next", (), (), |_, app: &mut AppHandle, _: ()| {
            let _ = app.emit("mpris-next", ());
            Ok(())
        });
        b.method("Previous", (), (), |_, app: &mut AppHandle, _: ()| {
            // Restarting the current item is what every player does with
            // Previous when there's no previous track, and it's the one
            // behaviour that can't surprise anyone.
            dispatch(app, json!(["seek", 0, "absolute"]));
            Ok(())
        });
        b.method(
            "Seek",
            ("Offset",),
            (),
            |_, app: &mut AppHandle, (offset,): (i64,)| {
                dispatch(app, json!(["seek", offset as f64 / 1_000_000.0, "relative"]));
                Ok(())
            },
        );
        b.method(
            "SetPosition",
            ("TrackId", "Position"),
            (),
            |_, app: &mut AppHandle, (_track, pos): (dbus::Path, i64)| {
                dispatch(app, json!(["seek", pos as f64 / 1_000_000.0, "absolute"]));
                Ok(())
            },
        );
        b.method("OpenUri", ("Uri",), (), |_, _, _: (String,)| Ok(()));

        b.property("PlaybackStatus")
            .get(|_, app| Ok(playback_status(app)));
        b.property("Metadata").get(|_, app| Ok(metadata(app)));
        b.property("Position")
            .get(|_, app| Ok((status_of(app).position * 1_000_000.0) as i64));
        // MPRIS volume is 0–1 where 1 is "as loud as the source"; mpv's scale is
        // a percentage that runs past it to 130.
        b.property("Volume")
            .get(|_, app| Ok(status_of(app).volume / 100.0))
            .set(|_, app, v: f64| {
                let pct = (v * 100.0).clamp(0.0, 130.0);
                dispatch(app, json!(["set_property", "volume", pct]));
                Ok(Some(v))
            });
        b.property("Rate")
            .get(|_, app| Ok(status_of(app).speed.max(0.01)))
            .set(|_, app, v: f64| {
                dispatch(app, json!(["set_property", "speed", v.clamp(0.25, 4.0)]));
                Ok(Some(v))
            });
        b.property("MinimumRate").get(|_, _| Ok(0.25f64));
        b.property("MaximumRate").get(|_, _| Ok(4.0f64));
        b.property("CanGoNext").get(|_, app| Ok(next_available(app)));
        b.property("CanGoPrevious")
            .get(|_, app| Ok(status_of(app).active));
        b.property("CanPlay").get(|_, app| Ok(status_of(app).active));
        b.property("CanPause").get(|_, app| Ok(status_of(app).active));
        b.property("CanSeek")
            .get(|_, app| Ok(status_of(app).duration > 0.0));
        b.property("CanControl").get(|_, _| Ok(true));
    });

    cr.insert(PATH, &[root, player], app.clone());

    c.start_receive(
        MatchRule::new_method_call(),
        Box::new(move |msg, conn| {
            let _ = cr.handle_message(msg, conn);
            true
        }),
    );

    // An eventfd because it's one fd for both ends and `notify` can write to it
    // from any thread without allocating or blocking. Publishing it is what
    // turns `notify` on.
    let wake_fd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
    if wake_fd < 0 {
        return Err("eventfd failed".into());
    }
    WAKE.store(wake_fd, Ordering::Relaxed);

    let mut last: Option<Announced> = None;
    loop {
        // Dispatch whatever arrived — media keys, property queries from the
        // shell. Before parking, not after: libdbus can already hold a message
        // in its own queue, and no amount of waiting on the socket would ever
        // produce a readable fd for one that has been read.
        while c.process(Duration::ZERO)? {}
        announce(&app, &c, &mut last);
        park(dbus_fd, wake_fd);
    }
}
