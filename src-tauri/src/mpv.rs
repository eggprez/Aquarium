//! libmpv in place of an mpv process, shaped like the JSON IPC it replaces.
//!
//! Playback used to be a child process reached over a unix socket: commands
//! went out as `{"command": [...]}` lines and events came back as JSON. That
//! socket is gone — mpv now runs inside this process, because a render context
//! (see [`render.rs`](crate::render)) can only be built on a handle we own.
//! Everything above this module still speaks the same JSON, though, which is
//! deliberate: [`player.rs`](crate::player) has ~270 lines of event handling
//! that are worth keeping exactly as they are, and the frontend's uosc escape
//! hatch passes mpv command arrays straight through from JavaScript.
//!
//! So this is an adapter, not a wrapper. [`Session::command`] takes the same
//! array the socket took, and the event thread emits the same objects the
//! socket emitted — `mpv_event_to_node` is in fact the very call mpv's own IPC
//! server makes before serialising, so the shapes are not merely similar.
//!
//! `libmpv2`'s safe API is not enough on its own here: its `PropertyData`
//! panics on `MPV_FORMAT_NODE` (`unimplemented!()`), and `track-list`,
//! `chapter-list` and `mouse-pos` are all node-typed. The event loop and the
//! command path are therefore hand-rolled on `libmpv2-sys`, the same way
//! `render.rs` hand-rolls the render context.
//!
//! Threading: the handle is `Send + Sync` and every mpv call except
//! `mpv_wait_event` is thread-safe, so commands come from wherever the caller
//! happens to be (tokio, the D-Bus thread) while one dedicated OS thread stays
//! parked in `mpv_wait_event`. That thread holds an `Arc<Mpv>` of its own, so
//! the handle cannot be destroyed out from under it.

use libmpv2::Mpv;
use serde_json::{Map, Value};
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::mpsc;

// --------------------------------------------------------------- config dirs

/// mpv config dir shipped with the package (uosc UI + our control layout).
/// Installed at /usr/share/aquarium/mpv, found relative to the executable.
pub fn resolve_mpv_config_dir() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("AQUARIUM_MPV_CONFIG") {
        let p = PathBuf::from(p);
        if p.is_dir() {
            return Some(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let cand = dir.join("../share/aquarium/mpv");
            if cand.is_dir() {
                return cand.canonicalize().ok();
            }
        }
    }
    None
}

/// Per-session mpv debug log under the app data dir; keeps the last few so
/// "video didn't show" reports can be diagnosed after the fact.
pub fn mpv_log_path() -> Option<PathBuf> {
    let dir = crate::config::data_dir().join("mpv-logs");
    std::fs::create_dir_all(&dir).ok()?;
    // Prune: keep the 5 newest logs.
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let mut logs: Vec<_> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().ends_with(".log"))
            .collect();
        logs.sort_by_key(|e| {
            e.metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH)
        });
        while logs.len() > 5 {
            let old = logs.remove(0);
            let _ = std::fs::remove_file(old.path());
        }
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    Some(dir.join(format!("mpv-{}.log", ts)))
}

// -------------------------------------------------------------- throwaway probes
//
// Two things the Settings page wants that aren't playback: what mpv build is
// actually running, and what audio outputs it can see. Both used to shell out
// to the standalone `mpv` binary Aquarium depended on for exactly this; there
// is no such binary any more (see WAYLAND-MIGRATION.md Phase 5), so both spin
// up a throwaway core — `Mpv::new()` already gives the isolated, no-config,
// no-terminal handle these want — read one property, and drop it.

/// The mpv core's own version string (e.g. `"mpv 0.41.0"`), for diagnostics —
/// Settings and bug reports want to know what's actually running, not just
/// that *some* libmpv is linked in. `None` if the throwaway core couldn't be
/// created at all, which the caller should treat as "unknown", not an error.
pub fn runtime_version() -> Option<String> {
    unsafe {
        libc::setlocale(libc::LC_NUMERIC, c"C".as_ptr());
    }
    let mpv = Mpv::new().ok()?;
    mpv.get_property::<String>("mpv-version").ok()
}

/// Audio outputs this machine has, as mpv sees them: `(name, description)`.
/// Asked of mpv rather than of PulseAudio/PipeWire directly, because the name
/// in the first half is the string that has to go back to mpv as
/// `--audio-device`, and only mpv knows how it spells its own devices.
///
/// `audio-device-list` is node-typed (an array of `{name, description}`
/// maps), which is exactly what `libmpv2`'s safe API can't read — see the
/// module docs — so this is hand-rolled on `libmpv2-sys` the same way the
/// event loop and command path are.
pub fn audio_devices() -> Vec<(String, String)> {
    unsafe {
        libc::setlocale(libc::LC_NUMERIC, c"C".as_ptr());
    }
    let Ok(mpv) = Mpv::new() else {
        return Vec::new();
    };
    let Ok(cname) = CString::new("audio-device-list") else {
        return Vec::new();
    };
    let mut node = empty_node();
    let err = unsafe {
        libmpv2_sys::mpv_get_property(
            mpv.ctx.as_ptr(),
            cname.as_ptr(),
            libmpv2_sys::mpv_format_MPV_FORMAT_NODE,
            &mut node as *mut libmpv2_sys::mpv_node as *mut c_void,
        )
    };
    if err < 0 {
        return Vec::new();
    }
    let value = node_to_json(&node);
    unsafe { libmpv2_sys::mpv_free_node_contents(&mut node) };
    value
        .as_array()
        .map(|devices| {
            devices
                .iter()
                .filter_map(|d| {
                    let name = d.get("name")?.as_str()?.to_string();
                    let description = d
                        .get("description")
                        .and_then(|v| v.as_str())
                        .filter(|s| !s.is_empty())
                        .unwrap_or(&name)
                        .to_string();
                    Some((name, description))
                })
                .collect()
        })
        .unwrap_or_default()
}

// ------------------------------------------------------------------- options

/// The per-stream half of mpv's configuration — everything the old command
/// line carried that isn't a user preference. The rest (decoding, languages,
/// subtitle appearance, audio, picture) arrives in `prefs` already formatted
/// as `--name=value`, straight from [`crate::prefs::Prefs::args`].
#[derive(Default)]
pub struct Options {
    /// Shown by uosc and reported to MPRIS; the container's own title is
    /// usually a transcoder artefact, so the server's wins.
    pub title: String,
    /// 0–130. Applied as an option rather than a command after startup, so a
    /// session the user left quiet doesn't open with a burst at full volume.
    pub volume: f64,
    /// Resume point in seconds. `None` for live streams and for a file that
    /// starts at the beginning.
    pub start: Option<f64>,
    /// `Authorization:` for the stream, when it goes to the Jellyfin server
    /// this token belongs to. See `player::http_auth_header`.
    pub auth_header: Option<String>,
    /// `--name=value` strings from the Settings page.
    pub prefs: Vec<String>,
}

// ------------------------------------------------------------------- session

/// A running mpv core and the thread draining its event queue.
pub struct Session {
    mpv: Arc<Mpv>,
}

impl Session {
    /// Create the core, apply `opts`, and start the event thread. The receiver
    /// yields IPC-shaped JSON until mpv shuts down, at which point it closes.
    ///
    /// Nothing is playing yet: the caller loads a file with
    /// `command(json!(["loadfile", url]))` once it has attached the handle to
    /// the video surface, so the first frame has somewhere to go.
    pub fn start(opts: Options) -> Result<(Session, mpsc::UnboundedReceiver<Value>), String> {
        let config_dir = resolve_mpv_config_dir();
        let log_file = mpv_log_path();

        let mpv = Mpv::with_initializer(|init| {
            let set = |name: &str, value: &str| {
                // An option this mpv doesn't have is worth a log line and
                // nothing more: the old command line was filtered against
                // `mpv --list-options` for exactly this reason, and a
                // hard failure here would mean no playback at all.
                if let Err(e) = init.set_property(name, value) {
                    crate::debug_log_line(&format!("mpv: option {}={} rejected: {}", name, value, e));
                }
            };

            // No mpv-owned window exists any more, so no `--force-window` and
            // no `--gpu-context=x11egl` (that workaround existed only for the
            // embedded X11 child). The render API is the video output, and
            // naming it is what makes `mpv_render_context_create` legal.
            set("vo", "libmpv");
            set("terminal", "no");
            set("keep-open", "no");
            set("ytdl", "no");
            set("cache", "yes");
            set("demuxer-max-bytes", "64MiB");

            // libmpv reads no config files at all unless told to, and if told
            // to without a directory it would read the *command line player's*
            // config. Both are init-only options, which is why they are set
            // here rather than after `initialize()`.
            match &config_dir {
                Some(d) => {
                    set("config", "yes");
                    set("config-dir", &d.to_string_lossy());
                    // The bundled config carries uosc, which replaces mpv's
                    // own on-screen controller rather than sitting next to it.
                    set("osc", "no");
                    set("osd-bar", "no");
                    // Also off by default under libmpv, and also init-only:
                    // without them the bundled `input.conf` would load into a
                    // player that ignores key bindings, and `scripts/` — uosc
                    // itself — would not load at all.
                    set("load-scripts", "yes");
                    set("input-default-bindings", "yes");
                }
                None => {
                    set("config", "no");
                    set("osc", "yes");
                }
            }

            // Settings-page options, `--name=value` → `name`, `value`. Applied
            // after the config dir so the file cannot be read as one of them,
            // which is the ordering the command line used for the same reason.
            for arg in &opts.prefs {
                let Some((name, value)) = arg.trim_start_matches('-').split_once('=') else {
                    continue;
                };
                set(name, value);
            }

            if !opts.title.is_empty() {
                set("force-media-title", &opts.title);
            }
            set("volume", &format!("{:.0}", opts.volume.clamp(0.0, 130.0)));
            if let Some(s) = opts.start {
                set("start", &format!("+{:.1}", s));
            }
            if let Some(log) = &log_file {
                set("log-file", &log.to_string_lossy());
            }
            Ok(())
        })
        .map_err(|e| format!("Could not start mpv: {}", e))?;

        let mpv = Arc::new(mpv);
        let (tx, rx) = mpsc::unbounded_channel();
        let thread_mpv = mpv.clone();
        std::thread::Builder::new()
            .name("mpv-events".into())
            .spawn(move || pump_events(thread_mpv, tx))
            .map_err(|e| format!("Could not start the mpv event thread: {}", e))?;
        let session = Session { mpv };

        // Authenticate with a header rather than an `api_key=` query parameter:
        // the token would otherwise be written verbatim into Jellyfin's access
        // log and into our own mpv log for every stream.
        //
        // This is the one option that cannot simply be set. `http-header-fields`
        // is a *list*, and the MediaBrowser scheme is full of commas, so
        // assigning the header as a string splits it into malformed
        // continuation lines and the token never arrives — which is why the
        // command line said `--http-header-fields-append=`. That name does not
        // exist through the option API: setting it is accepted, does nothing,
        // and the only symptom is a 400 from Jellyfin. So the list is appended
        // to with the command that exists for exactly this.
        if let Some(auth) = &opts.auth_header {
            session.command(serde_json::json!([
                "change-list",
                "http-header-fields",
                "append",
                format!("Authorization: {}", auth)
            ]))?;
        }

        crate::debug_log_line(&format!(
            "mpv: core up, config-dir={:?} log={:?}",
            config_dir, log_file
        ));
        Ok((session, rx))
    }

    /// The handle to hand [`crate::surface::Surface::attach`]. Cloning it is
    /// what keeps the core alive while the GLArea still holds a render
    /// context over it — mpv requires the context to be freed first, and the
    /// `Arc` is what enforces that ordering.
    pub fn handle(&self) -> Arc<Mpv> {
        self.mpv.clone()
    }

    /// Run one JSON command array, exactly as the IPC socket did.
    ///
    /// The `{"command": [...]}` envelope is accepted as well as the bare
    /// array, because that is the shape the supervisor already queues.
    pub fn command(&self, cmd: Value) -> Result<(), String> {
        let cmd = match cmd {
            Value::Object(mut o) => o.remove("command").unwrap_or(Value::Null),
            other => other,
        };
        let Some(args) = cmd.as_array() else {
            return Err("mpv command must be an array".into());
        };
        let name = args.first().and_then(|v| v.as_str()).unwrap_or("");

        // Two commands that only ever existed in the IPC layer, not in mpv:
        // `mpv_command_node` has never heard of them, and passing them on
        // would fail every property observation in the supervisor.
        match name {
            "observe_property" | "observe_property_string" => {
                let id = args.get(1).and_then(|v| v.as_u64()).ok_or("observe_property: bad id")?;
                let prop = args.get(2).and_then(|v| v.as_str()).ok_or("observe_property: bad name")?;
                // NODE unless the caller explicitly asked for a string, so
                // `track-list`, `chapter-list` and `mouse-pos` arrive whole
                // rather than as mpv's flattened string rendering.
                let format = if name.ends_with("_string") {
                    libmpv2_sys::mpv_format_MPV_FORMAT_STRING
                } else {
                    libmpv2_sys::mpv_format_MPV_FORMAT_NODE
                };
                let cname = CString::new(prop).map_err(|e| e.to_string())?;
                let err = unsafe {
                    libmpv2_sys::mpv_observe_property(
                        self.mpv.ctx.as_ptr(),
                        id,
                        cname.as_ptr(),
                        format,
                    )
                };
                return check(err);
            }
            // Nor is the IPC server's `set_property` a command: the socket
            // implemented it with `mpv_set_property`, and the frontend, MPRIS
            // and track selection all still speak it. Passed on as a command
            // it got "Command 'set_property' not found" from the core —
            // quietly, for every volume, mute, speed, subtitle-delay and
            // audio/subtitle-track change made from the app since the move
            // off the socket.
            "set_property" => {
                let prop = args.get(1).and_then(|v| v.as_str()).ok_or("set_property: bad name")?;
                let value = args.get(2).cloned().unwrap_or(Value::Null);
                let cname = CString::new(prop).map_err(|e| e.to_string())?;
                let mut arena = Arena::default();
                let mut node = arena.node(&value);
                let mut err = unsafe {
                    libmpv2_sys::mpv_set_property(
                        self.mpv.ctx.as_ptr(),
                        cname.as_ptr(),
                        libmpv2_sys::mpv_format_MPV_FORMAT_NODE,
                        &mut node as *mut libmpv2_sys::mpv_node as *mut std::ffi::c_void,
                    )
                };
                if err == libmpv2_sys::mpv_error_MPV_ERROR_PROPERTY_FORMAT {
                    // A node of a type the property will not take (mpv converts
                    // the obvious cases itself). Text goes through the option
                    // parser, which accepts anything the command line would.
                    let text = match &value {
                        Value::String(s) => s.clone(),
                        Value::Bool(b) => (if *b { "yes" } else { "no" }).to_string(),
                        other => other.to_string(),
                    };
                    let ctext = CString::new(text).map_err(|e| e.to_string())?;
                    let mut p = ctext.as_ptr() as *mut c_char;
                    err = unsafe {
                        libmpv2_sys::mpv_set_property(
                            self.mpv.ctx.as_ptr(),
                            cname.as_ptr(),
                            libmpv2_sys::mpv_format_MPV_FORMAT_STRING,
                            &mut p as *mut *mut c_char as *mut std::ffi::c_void,
                        )
                    };
                }
                return check(err);
            }
            "unobserve_property" => {
                let id = args.get(1).and_then(|v| v.as_u64()).ok_or("unobserve_property: bad id")?;
                let err =
                    unsafe { libmpv2_sys::mpv_unobserve_property(self.mpv.ctx.as_ptr(), id) };
                // This one returns the number of properties it removed, which
                // is a success, not an error code.
                return if err < 0 { check(err) } else { Ok(()) };
            }
            _ => {}
        }

        // Everything else goes through as a node array rather than as strings,
        // so `["seek", 12.5, "absolute"]` and `["set_property", "aid", 2]`
        // keep their types instead of being re-parsed out of decimal text.
        let mut arena = Arena::default();
        let mut node = arena.node(&cmd);
        let mut result = empty_node();
        let err = unsafe {
            libmpv2_sys::mpv_command_node(self.mpv.ctx.as_ptr(), &mut node, &mut result)
        };
        unsafe { libmpv2_sys::mpv_free_node_contents(&mut result) };
        check(err)
    }
}

fn check(err: i32) -> Result<(), String> {
    if err < 0 {
        Err(libmpv2_sys::mpv_error_str(err).to_string())
    } else {
        Ok(())
    }
}

// -------------------------------------------------------------- event thread

/// Drain mpv's event queue for the life of the core.
///
/// The one-second timeout is not a poll: it is how the thread notices that the
/// receiver has been dropped (the supervisor finished) even though mpv itself
/// has nothing to say, so a session that ends without a shutdown still lets go
/// of its `Arc` and lets the handle be destroyed.
fn pump_events(mpv: Arc<Mpv>, tx: mpsc::UnboundedSender<Value>) {
    let ctx = mpv.ctx.as_ptr();
    loop {
        // SAFETY: this is the only thread that ever calls `mpv_wait_event` on
        // this handle, which is the API's sole threading restriction, and the
        // `Arc` we hold keeps the handle alive across the call.
        let ev = unsafe { libmpv2_sys::mpv_wait_event(ctx, 1.0) };
        if ev.is_null() {
            continue;
        }
        let id = unsafe { (*ev).event_id };
        if id == libmpv2_sys::mpv_event_id_MPV_EVENT_NONE {
            // Timed out with nothing queued. Only worth noticing if the far
            // end has gone away.
            if tx.is_closed() {
                break;
            }
            continue;
        }
        // `mpv_event_to_node` is what mpv's own IPC server calls before it
        // serialises, so what comes out here is the message the socket used to
        // carry — "event", "name"/"data" for a property change, "args" for a
        // client-message, "reason" for end-file — and not an approximation of
        // it. The node borrows from the event, so it has to be converted
        // before the next `mpv_wait_event`; it is, immediately below.
        let mut node = empty_node();
        let msg = unsafe {
            let err = libmpv2_sys::mpv_event_to_node(&mut node, ev);
            let v = if err < 0 {
                Value::Null
            } else {
                node_to_json(&node)
            };
            libmpv2_sys::mpv_free_node_contents(&mut node);
            v
        };
        let shutdown = id == libmpv2_sys::mpv_event_id_MPV_EVENT_SHUTDOWN;
        if !msg.is_null() && tx.send(msg).is_err() {
            break;
        }
        if shutdown {
            // The core is gone; nothing further will ever arrive. Dropping
            // `tx` here is what closes the supervisor's receiver, which is
            // what the process exit used to do.
            break;
        }
    }
    crate::debug_log_line("mpv: event thread finished");
    drop(mpv);
}

// -------------------------------------------------------- node <-> JSON

fn empty_node() -> libmpv2_sys::mpv_node {
    libmpv2_sys::mpv_node {
        u: libmpv2_sys::mpv_node__bindgen_ty_1 { int64: 0 },
        format: libmpv2_sys::mpv_format_MPV_FORMAT_NONE,
    }
}

unsafe fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }
}

/// mpv's own JSON writer, in Rust. Byte arrays have no JSON spelling and mpv
/// writes them as null; nothing we observe is one.
fn node_to_json(node: &libmpv2_sys::mpv_node) -> Value {
    unsafe {
        match node.format {
            libmpv2_sys::mpv_format_MPV_FORMAT_STRING => Value::String(cstr(node.u.string)),
            libmpv2_sys::mpv_format_MPV_FORMAT_FLAG => Value::Bool(node.u.flag != 0),
            libmpv2_sys::mpv_format_MPV_FORMAT_INT64 => Value::from(node.u.int64),
            libmpv2_sys::mpv_format_MPV_FORMAT_DOUBLE => {
                // JSON has no NaN or infinity; mpv's writer emits null too.
                serde_json::Number::from_f64(node.u.double_)
                    .map(Value::Number)
                    .unwrap_or(Value::Null)
            }
            libmpv2_sys::mpv_format_MPV_FORMAT_NODE_ARRAY => {
                let list = node.u.list;
                if list.is_null() {
                    return Value::Array(Vec::new());
                }
                let n = (*list).num.max(0) as usize;
                let mut out = Vec::with_capacity(n);
                for i in 0..n {
                    out.push(node_to_json(&*(*list).values.add(i)));
                }
                Value::Array(out)
            }
            libmpv2_sys::mpv_format_MPV_FORMAT_NODE_MAP => {
                let list = node.u.list;
                if list.is_null() {
                    return Value::Object(Map::new());
                }
                let n = (*list).num.max(0) as usize;
                let mut out = Map::with_capacity(n);
                for i in 0..n {
                    let key = if (*list).keys.is_null() {
                        i.to_string()
                    } else {
                        cstr(*(*list).keys.add(i))
                    };
                    out.insert(key, node_to_json(&*(*list).values.add(i)));
                }
                Value::Object(out)
            }
            _ => Value::Null,
        }
    }
}

/// Owns everything an `mpv_node` tree points at for the length of one call.
///
/// mpv reads the tree during `mpv_command_node` and copies out whatever it
/// keeps, so this only has to outlive the call — but every pointer in it has
/// to stay valid *for* the call, which is why the strings and the child arrays
/// are boxed rather than left in a `Vec` that can reallocate mid-build.
#[derive(Default)]
struct Arena {
    strings: Vec<CString>,
    values: Vec<Box<[libmpv2_sys::mpv_node]>>,
    keys: Vec<Box<[*mut c_char]>>,
    lists: Vec<Box<libmpv2_sys::mpv_node_list>>,
}

impl Arena {
    fn cstring(&mut self, s: &str) -> *mut c_char {
        // A NUL inside a command argument can't be passed to mpv at all;
        // truncating at it is what the C API would do anyway.
        let c = CString::new(s).unwrap_or_else(|e| {
            let bytes = e.into_vec();
            let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
            CString::new(&bytes[..end]).unwrap_or_default()
        });
        let p = c.as_ptr() as *mut c_char;
        self.strings.push(c);
        p
    }

    fn node(&mut self, v: &Value) -> libmpv2_sys::mpv_node {
        match v {
            Value::Null => empty_node(),
            Value::Bool(b) => libmpv2_sys::mpv_node {
                u: libmpv2_sys::mpv_node__bindgen_ty_1 { flag: *b as i32 },
                format: libmpv2_sys::mpv_format_MPV_FORMAT_FLAG,
            },
            Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    libmpv2_sys::mpv_node {
                        u: libmpv2_sys::mpv_node__bindgen_ty_1 { int64: i },
                        format: libmpv2_sys::mpv_format_MPV_FORMAT_INT64,
                    }
                } else {
                    libmpv2_sys::mpv_node {
                        u: libmpv2_sys::mpv_node__bindgen_ty_1 {
                            double_: n.as_f64().unwrap_or(0.0),
                        },
                        format: libmpv2_sys::mpv_format_MPV_FORMAT_DOUBLE,
                    }
                }
            }
            Value::String(s) => {
                let p = self.cstring(s);
                libmpv2_sys::mpv_node {
                    u: libmpv2_sys::mpv_node__bindgen_ty_1 { string: p },
                    format: libmpv2_sys::mpv_format_MPV_FORMAT_STRING,
                }
            }
            Value::Array(items) => {
                let values: Vec<_> = items.iter().map(|i| self.node(i)).collect();
                let list = self.list(values, None);
                libmpv2_sys::mpv_node {
                    u: libmpv2_sys::mpv_node__bindgen_ty_1 { list },
                    format: libmpv2_sys::mpv_format_MPV_FORMAT_NODE_ARRAY,
                }
            }
            Value::Object(map) => {
                let mut values = Vec::with_capacity(map.len());
                let mut keys = Vec::with_capacity(map.len());
                for (k, val) in map {
                    keys.push(self.cstring(k));
                    values.push(self.node(val));
                }
                let list = self.list(values, Some(keys));
                libmpv2_sys::mpv_node {
                    u: libmpv2_sys::mpv_node__bindgen_ty_1 { list },
                    format: libmpv2_sys::mpv_format_MPV_FORMAT_NODE_MAP,
                }
            }
        }
    }

    fn list(
        &mut self,
        values: Vec<libmpv2_sys::mpv_node>,
        keys: Option<Vec<*mut c_char>>,
    ) -> *mut libmpv2_sys::mpv_node_list {
        let num = values.len() as i32;
        let mut values = values.into_boxed_slice();
        let values_ptr = values.as_mut_ptr();
        self.values.push(values);
        let keys_ptr = match keys {
            Some(k) => {
                let mut k = k.into_boxed_slice();
                let p = k.as_mut_ptr();
                self.keys.push(k);
                p
            }
            None => std::ptr::null_mut(),
        };
        let mut list = Box::new(libmpv2_sys::mpv_node_list {
            num,
            values: values_ptr,
            keys: keys_ptr,
        });
        let p = list.as_mut() as *mut _;
        self.lists.push(list);
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A real mpv build always reports a version; this is what Settings and
    /// bug reports show now that there's no external binary to name instead.
    #[test]
    fn runtime_version_reports_something() {
        let v = runtime_version().expect("throwaway core should start");
        assert!(v.contains("mpv"), "unexpected version string: {v}");
    }

    /// Every dev box this runs on has at least one audio output — a node-typed
    /// property read straight off a throwaway core, no external binary.
    #[test]
    fn audio_devices_lists_at_least_one_output() {
        let devices = audio_devices();
        assert!(!devices.is_empty(), "no audio devices reported");
        assert!(devices.iter().all(|(name, desc)| !name.is_empty() && !desc.is_empty()));
    }

    /// The two conversions are each other's inverse for everything a command
    /// or an event can carry. Run together because a bug in either one is
    /// invisible from the other side: mpv would take a malformed tree without
    /// complaint and simply do the wrong thing.
    #[test]
    fn json_survives_the_round_trip_through_mpv_nodes() {
        for v in [
            json!(["seek", 12.5, "absolute"]),
            json!(["set_property", "aid", 2]),
            json!(["set_property", "pause", true]),
            json!(["loadfile", "http://example/x", "replace", { "start": "+30.0" }]),
            json!([]),
            json!({ "a": null, "b": [1, 2.5, false, "s"] }),
        ] {
            let mut arena = Arena::default();
            let node = arena.node(&v);
            assert_eq!(node_to_json(&node), v, "round trip failed for {v}");
        }
    }

    /// A JSON integer must not arrive as a double. mpv's `set_property` on a
    /// track id takes an integer choice, and 2.0 is not one of its values.
    #[test]
    fn integers_stay_integers() {
        let mut arena = Arena::default();
        let node = arena.node(&json!(2));
        assert_eq!(node.format, libmpv2_sys::mpv_format_MPV_FORMAT_INT64);
        let node = arena.node(&json!(2.5));
        assert_eq!(node.format, libmpv2_sys::mpv_format_MPV_FORMAT_DOUBLE);
    }

    /// The command path is the frontend's escape hatch, so it is reachable
    /// with whatever JavaScript sends.
    #[test]
    fn a_command_that_is_not_an_array_is_refused_not_panicked_on() {
        let (session, _rx) = Session::start(Options::default()).expect("mpv core");
        assert!(session.command(json!("quit")).is_err());
        assert!(session.command(json!({ "command": "quit" })).is_err());
        let _ = session.command(json!(["quit"]));
    }

    /// `set_property` is the IPC name the app still speaks. libmpv has no
    /// command of that name, so it has to be turned into a property write —
    /// and a JSON integer has to land on a float property (`sub-pos`), which
    /// is what the fullscreen bar sends.
    #[test]
    fn set_property_writes_the_property() {
        let opts = Options {
            prefs: vec!["--ao=null".into(), "--vo=null".into()],
            ..Options::default()
        };
        let (session, mut rx) = Session::start(opts).expect("mpv core");
        session.command(json!(["observe_property", 7, "volume"])).expect("observe");
        session.command(json!(["observe_property", 8, "sub-pos"])).expect("observe");
        session.command(json!(["set_property", "volume", 37])).expect("set volume");
        session
            .command(json!(["set_property", "sub-pos", 93]))
            .expect("set sub-pos from an integer");
        assert!(session.command(json!(["set_property", "no-such-property", 1])).is_err());
        // Something to play, so events keep flowing until the stream closes.
        session
            .command(json!(["loadfile", "av://lavfi:testsrc=size=64x64:rate=25:duration=1"]))
            .expect("loadfile");
        let (mut volume, mut sub_pos) = (None, None);
        while let Some(msg) = rx.blocking_recv() {
            match msg.get("event").and_then(|v| v.as_str()) {
                Some("end-file") => {
                    let _ = session.command(json!(["quit"]));
                }
                Some("property-change") => match msg.get("name").and_then(|v| v.as_str()) {
                    Some("volume") => volume = msg.get("data").and_then(|v| v.as_f64()),
                    Some("sub-pos") => sub_pos = msg.get("data").and_then(|v| v.as_f64()),
                    _ => {}
                },
                _ => {}
            }
        }
        assert_eq!(volume, Some(37.0), "volume never arrived at the core");
        assert_eq!(sub_pos, Some(93.0), "sub-pos never arrived at the core");
    }

    /// End to end, with no window and no surface: the options apply, a file
    /// loads, the observations come back node-shaped, and the stream closes
    /// when mpv shuts down rather than leaving the reader hanging.
    #[test]
    fn a_session_plays_and_reports_in_ipc_shape() {
        let opts = Options {
            title: "round trip".into(),
            volume: 0.0,
            start: None,
            auth_header: None,
            // No audio output in a test runner, and nothing to render into.
            prefs: vec!["--ao=null".into(), "--vo=null".into()],
        };
        let (session, mut rx) = Session::start(opts).expect("mpv core");
        for (id, prop) in [(1u64, "time-pos"), (4, "track-list"), (3, "duration")] {
            session
                .command(json!(["observe_property", id, prop]))
                .expect("observe");
        }
        // A synthetic source, so the test needs no media and no network.
        session
            .command(json!([
                "loadfile",
                "av://lavfi:testsrc=size=320x240:rate=25:duration=2"
            ]))
            .expect("loadfile");

        let mut saw_start = false;
        let mut saw_tracks = false;
        let mut saw_position = false;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        while let Some(msg) = rx.blocking_recv() {
            match msg.get("event").and_then(|v| v.as_str()) {
                Some("start-file") => saw_start = true,
                Some("property-change") => match msg.get("name").and_then(|v| v.as_str()) {
                    // Node-typed: the shape libmpv2's safe API cannot produce.
                    Some("track-list") => {
                        if let Some(list) = msg.get("data").and_then(|v| v.as_array()) {
                            saw_tracks |= list
                                .iter()
                                .any(|t| t.get("type").and_then(|v| v.as_str()) == Some("video"));
                        }
                    }
                    Some("time-pos") => {
                        saw_position |= msg.get("data").and_then(|v| v.as_f64()).is_some()
                    }
                    _ => {}
                },
                Some("end-file") => {
                    // `keep-open=no` plus libmpv's idle mode: the core stays up
                    // after the file, so shutdown has to be asked for.
                    let _ = session.command(json!(["quit"]));
                }
                _ => {}
            }
            if std::time::Instant::now() > deadline {
                let _ = session.command(json!(["quit"]));
            }
        }
        // The receiver closing *is* the "mpv exited" signal Phase 3 replaces
        // `child.wait()` with, so reaching here at all is half the assertion.
        assert!(saw_start, "no start-file event");
        assert!(saw_tracks, "track-list never arrived as a node array");
        assert!(saw_position, "time-pos never arrived");
    }
    /// Every option in [`Session::start`] read back off a live core.
    ///
    /// Worth the length because every failure in here is silent. mpv accepts
    /// an option name it does not have and does nothing with it, so the whole
    /// class of bug — no uosc, no hardware decode, no `Authorization` header
    /// and a 400 from Jellyfin — looks from the outside like "video didn't
    /// work". `http-header-fields` in particular was written as the command
    /// line wrote it, `-append`, which is accepted here and has no effect.
    #[test]
    fn every_option_reaches_the_core() {
        let opts = Options {
            title: "A Title".into(),
            volume: 42.0,
            start: Some(30.0),
            // Full of commas, which is the point: `http-header-fields` is a
            // list option and a plain assignment would split this into
            // malformed continuation lines.
            auth_header: Some("MediaBrowser Token=\"abc\", Device=\"Linux\"".into()),
            prefs: vec![
                "--ao=null".into(),
                "--hwdec=vaapi,nvdec".into(),
                "--sub-font-size=44".into(),
            ],
        };
        let (session, _rx) = Session::start(opts).expect("mpv core");
        let read = |name: &str| -> String {
            session
                .mpv
                .get_property(name)
                .unwrap_or_else(|e| panic!("{name}: {e}"))
        };
        for (name, want) in [
            // Without this the render context cannot be created at all.
            ("vo", "libmpv"),
            ("terminal", "no"),
            ("keep-open", "no"),
            ("ytdl", "no"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "67108864"),
            ("force-media-title", "A Title"),
            ("start", "+30"),
            // From `prefs`, i.e. the Settings page.
            ("hwdec", "vaapi,nvdec"),
            ("ao", "null"),
            ("sub-font-size", "44.000000"),
            ("volume", "42.000000"),
            (
                "http-header-fields",
                "Authorization: MediaBrowser Token=\"abc\", Device=\"Linux\"",
            ),
        ] {
            assert_eq!(read(name), want, "option {name}");
        }
        // The config dir is the machine's, so only its consequences are fixed:
        // whichever branch ran, mpv must not be reading the command line
        // player's configuration, and the on-screen UI must be exactly one of
        // ours or mpv's, never both.
        let config = read("config");
        if config == "yes" {
            assert!(!read("config-dir").is_empty(), "config=yes with no dir");
            assert_eq!(read("osc"), "no", "uosc and mpv's OSC would both draw");
            // Off by default under libmpv, and init-only: without them the
            // bundled input.conf loads into a player that ignores bindings and
            // uosc does not load at all.
            assert_eq!(read("load-scripts"), "yes");
            assert_eq!(read("input-default-bindings"), "yes");
        }
        let _ = session.command(json!(["quit"]));
    }
}
