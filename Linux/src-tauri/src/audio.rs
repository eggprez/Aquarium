//! Music and audiobooks: a second mpv core, audio only.
//!
//! Video playback (`player.rs`) is built around one core per file, a video
//! surface it can't start without, and a supervisor that quits mpv at the end
//! of the file. Music wants the opposite of each: no surface, one core that
//! outlives the track, and the next file already queued inside mpv so
//! `gapless-audio` and `prefetch-playlist` can join them without a gap. Bending
//! the video player into that shape would touch every path it has, so music
//! gets a core of its own here and the two never run at once — starting one
//! stops the other (`play` below, and `player_play` in lib.rs).
//!
//! The queue itself (shuffle, repeat, Up Next, stations) belongs to the
//! frontend. mpv only ever holds a window of two: the song playing and the one
//! after it. When mpv moves on, the frontend is told (`audio-track`) and hands
//! down the next one (`set_next`).
//!
//! Plays are reported to Jellyfin from here, the same three calls video makes,
//! so a song's play count and an audiobook's resume point are recorded even
//! when the webview is busy or the app is closing.

use crate::{jellyfin, mpv, progress};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::Mutex;

const TICKS_PER_SECOND: f64 = 10_000_000.0;

/// One song or audiobook, as the frontend describes it. Everything past `url`
/// is for the shell's media controls and the play reports.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct AudioTrack {
    pub item_id: String,
    pub url: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default)]
    pub album_artist: String,
    /// An image URL on the Jellyfin server. Image routes need no token, so the
    /// shell can fetch it itself for the lock screen.
    #[serde(default)]
    pub art_url: Option<String>,
    /// Seconds, from server metadata.
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub track_number: Option<i64>,
    /// A downloaded file: progress is queued locally and synced later.
    #[serde(default)]
    pub is_local: bool,
}

#[derive(Deserialize)]
pub struct PlayRequest {
    pub track: AudioTrack,
    #[serde(default)]
    pub next: Option<AudioTrack>,
    #[serde(default)]
    pub start_seconds: Option<f64>,
    #[serde(default)]
    pub volume: Option<f64>,
    #[serde(default)]
    pub speed: Option<f64>,
    /// mpv's `replaygain`: "no", "track" or "album" (Sound Check).
    #[serde(default)]
    pub replaygain: Option<String>,
    /// Repeat One: mpv loops the file itself, so the gapless join still holds.
    #[serde(default)]
    pub loop_file: bool,
    #[serde(default)]
    pub server_url: Option<String>,
    #[serde(default)]
    pub user_id: Option<String>,
    #[serde(default)]
    pub device_id: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct AudioStatus {
    pub active: bool,
    pub paused: bool,
    pub position: f64,
    pub duration: f64,
    pub item_id: String,
    pub volume: f64,
    pub mute: bool,
    pub speed: f64,
    pub buffering: bool,
}

#[derive(Clone, Default)]
struct Reporting {
    server_url: Option<String>,
    user_id: Option<String>,
    device_id: Option<String>,
}

#[derive(Default)]
struct Tracks {
    /// What each address in mpv's playlist is, for the reports and MPRIS.
    by_url: HashMap<String, AudioTrack>,
    current: Option<AudioTrack>,
    /// The entry queued behind `current`, if any.
    next: Option<AudioTrack>,
}

struct Core {
    session: Arc<mpv::Session>,
    epoch: u64,
}

/// The frontend's queue, as MPRIS's track list shows it.
#[derive(Clone, Default)]
pub struct QueueView {
    pub entries: Vec<AudioTrack>,
    pub index: usize,
}

pub struct AudioPlayer {
    core: Mutex<Option<Core>>,
    /// One start or stop at a time; see the same field on `Player`.
    transition: Mutex<()>,
    status: Arc<StdMutex<AudioStatus>>,
    tracks: Arc<StdMutex<Tracks>>,
    reporting: Arc<StdMutex<Reporting>>,
    queue: StdMutex<QueueView>,
    can_next: AtomicBool,
    can_prev: AtomicBool,
    epoch: Arc<AtomicU64>,
    /// Bumped per `play`, so a URL used twice in a row is still two entries.
    serial: AtomicU64,
}

impl Default for AudioPlayer {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioPlayer {
    pub fn new() -> Self {
        Self {
            core: Mutex::new(None),
            transition: Mutex::new(()),
            status: Arc::new(StdMutex::new(AudioStatus::default())),
            tracks: Arc::new(StdMutex::new(Tracks::default())),
            reporting: Arc::new(StdMutex::new(Reporting::default())),
            queue: StdMutex::new(QueueView::default()),
            can_next: AtomicBool::new(false),
            can_prev: AtomicBool::new(false),
            epoch: Arc::new(AtomicU64::new(0)),
            serial: AtomicU64::new(0),
        }
    }

    pub fn is_active(&self) -> bool {
        self.status.lock().unwrap().active
    }

    pub fn status(&self) -> AudioStatus {
        self.status.lock().unwrap().clone()
    }

    pub fn current(&self) -> Option<AudioTrack> {
        self.tracks.lock().unwrap().current.clone()
    }

    pub fn queue(&self) -> QueueView {
        self.queue.lock().unwrap().clone()
    }

    pub fn can_next(&self) -> bool {
        self.can_next.load(Ordering::SeqCst)
    }

    pub fn can_prev(&self) -> bool {
        self.can_prev.load(Ordering::SeqCst)
    }

    pub fn set_queue(&self, entries: Vec<AudioTrack>, index: usize, can_next: bool, can_prev: bool) {
        *self.queue.lock().unwrap() = QueueView { entries, index };
        self.can_next.store(can_next, Ordering::SeqCst);
        self.can_prev.store(can_prev, Ordering::SeqCst);
        crate::mpris::notify();
    }

    pub async fn send(&self, cmd: Value) -> Result<(), String> {
        let guard = self.core.lock().await;
        match guard.as_ref() {
            Some(c) => c.session.command(cmd),
            None => Err("nothing is playing".into()),
        }
    }

    /// Start `req.track` now, with `req.next` queued behind it. Reuses the
    /// running core when there is one, so moving through an album or skipping
    /// around the queue doesn't reopen the audio device each time.
    pub async fn play(&self, app: AppHandle, req: PlayRequest) -> Result<(), String> {
        let _transition = self.transition.lock().await;
        // Music and video never play over each other.
        if let Some(p) = app.try_state::<crate::player::Player>() {
            if p.is_active() {
                p.stop().await;
            }
        }
        *self.reporting.lock().unwrap() = Reporting {
            server_url: req.server_url.clone(),
            user_id: req.user_id.clone(),
            device_id: req.device_id.clone(),
        };

        let mut guard = self.core.lock().await;
        if guard.is_none() {
            *guard = Some(self.start_core(&app, &req)?);
        }
        let session = guard.as_ref().unwrap().session.clone();
        drop(guard);

        // What was playing stops here, not at mpv's end-file for it: that
        // arrives with reason "stop", which is ignored, so this is the one
        // place the server hears about it.
        let previous = {
            let mut t = self.tracks.lock().unwrap();
            let prev = t.current.take();
            t.by_url.clear();
            let mut track = req.track.clone();
            track.url = self.unique(&track.url);
            t.by_url.insert(track.url.clone(), track.clone());
            t.current = Some(track);
            t.next = req.next.clone().map(|mut n| {
                n.url = self.unique(&n.url);
                t.by_url.insert(n.url.clone(), n.clone());
                n
            });
            prev
        };
        if let Some(prev) = previous {
            let pos = { self.status.lock().unwrap().position };
            let rep = self.reporting.lock().unwrap().clone();
            tokio::spawn(async move { report_stopped(&rep, &prev, pos, false).await });
        }

        let (url, next_url) = {
            let t = self.tracks.lock().unwrap();
            (
                t.current.as_ref().map(|c| c.url.clone()).unwrap_or_default(),
                t.next.as_ref().map(|n| n.url.clone()),
            )
        };

        let _ = session.command(json!(["set_property", "speed", req.speed.unwrap_or(1.0).clamp(0.25, 4.0)]));
        if let Some(rg) = &req.replaygain {
            let _ = session.command(json!(["set_property", "replaygain", rg]));
        }
        let _ = session.command(json!(["set_property", "loop-file", if req.loop_file { "inf" } else { "no" }]));
        let start = req.start_seconds.filter(|s| *s > 1.0);
        let load = match start {
            Some(s) => json!(["loadfile", url, "replace", -1, format!("start=+{:.1}", s)]),
            None => json!(["loadfile", url, "replace"]),
        };
        session.command(load).map_err(|e| format!("Could not load the track: {e}"))?;
        if let Some(n) = next_url {
            let _ = session.command(json!(["loadfile", n, "append"]));
        }
        let _ = session.command(json!(["set_property", "pause", false]));

        {
            let mut st = self.status.lock().unwrap();
            st.active = true;
            st.paused = false;
            st.position = start.unwrap_or(0.0);
            st.duration = req.track.duration;
            st.item_id = req.track.item_id.clone();
            st.buffering = false;
        }
        let rep = self.reporting.lock().unwrap().clone();
        let track = req.track.clone();
        let st = self.status();
        tokio::spawn(async move { report_start(&rep, &track, &st).await });
        emit_status(&app, &self.status);
        let _ = app.emit("audio-track", json!({ "item_id": req.track.item_id }));
        Ok(())
    }

    /// Replace whatever is queued behind the current track. `None` lets the
    /// queue end after it (the sleep timer's "end of track", the last song).
    pub async fn set_next(&self, next: Option<AudioTrack>) -> Result<(), String> {
        let guard = self.core.lock().await;
        let Some(core) = guard.as_ref() else { return Ok(()) };
        // Everything but the playing entry goes; that includes an entry mpv
        // has already finished, which is still in its playlist.
        core.session.command(json!(["playlist-clear"]))?;
        let next = next.map(|mut n| {
            n.url = self.unique(&n.url);
            n
        });
        {
            let mut t = self.tracks.lock().unwrap();
            let keep = t.current.as_ref().map(|c| c.url.clone());
            t.by_url.retain(|u, _| Some(u) == keep.as_ref());
            if let Some(n) = &next {
                t.by_url.insert(n.url.clone(), n.clone());
            }
            t.next = next.clone();
        }
        if let Some(n) = next {
            core.session.command(json!(["loadfile", n.url, "append"]))?;
        }
        Ok(())
    }

    pub async fn stop(&self, app: &AppHandle) {
        let _transition = self.transition.lock().await;
        let taken = self.core.lock().await.take();
        let current = self.tracks.lock().unwrap().current.take();
        let pos = {
            let mut st = self.status.lock().unwrap();
            st.active = false;
            st.paused = false;
            st.position
        };
        if let Some(track) = current {
            let rep = self.reporting.lock().unwrap().clone();
            report_stopped(&rep, &track, pos, false).await;
        }
        if let Some(core) = taken {
            let _ = core.session.command(json!(["quit"]));
        }
        let _ = app.emit("audio-status", json!({ "active": false, "ended": false }));
        crate::mpris::notify();
    }

    /// Best-effort stop for app shutdown. The report is waited for (briefly):
    /// closing the app mid-chapter is the commonest way an audiobook stops,
    /// and the resume point is the one thing that must reach the server.
    pub fn stop_sync(&self) {
        let current = self.tracks.lock().unwrap().current.take();
        let pos = self.status.lock().unwrap().position;
        if let Ok(mut g) = self.core.try_lock() {
            if let Some(core) = g.take() {
                let _ = core.session.command(json!(["quit"]));
            }
        }
        if let Some(track) = current {
            let rep = self.reporting.lock().unwrap().clone();
            tauri::async_runtime::block_on(async move {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_secs(2),
                    report_stopped(&rep, &track, pos, false),
                )
                .await;
            });
        }
    }

    /// A file address mpv can tell apart from the same song queued again.
    /// Local paths are left alone: a song next to itself is the one case that
    /// can't be told apart, and it reports as one longer play.
    fn unique(&self, url: &str) -> String {
        if !url.starts_with("http") {
            return url.to_string();
        }
        let n = self.serial.fetch_add(1, Ordering::SeqCst);
        let sep = if url.contains('?') { '&' } else { '?' };
        format!("{url}{sep}aqEntry={n}")
    }

    fn start_core(&self, app: &AppHandle, req: &PlayRequest) -> Result<Core, String> {
        let mut prefs = crate::prefs::Prefs::load().args();
        // After the Settings options, so these win: no picture at all (an
        // album's embedded cover would otherwise open a video track), and the
        // two options gapless playback rests on.
        for opt in [
            "--vo=null",
            "--video=no",
            "--audio-display=no",
            "--gapless-audio=yes",
            "--prefetch-playlist=yes",
            "--idle=yes",
            "--keep-open=no",
            // A song is a few MiB; a whole one buffered up front lets the
            // radio sleep for the rest of it.
            "--demuxer-max-bytes=64MiB",
            "--demuxer-hysteresis-secs=0",
        ] {
            prefs.push(opt.to_string());
        }
        let auth_header = match (&req.server_url, crate::secret::token()) {
            (Some(server), Some(token)) if !server.is_empty() => Some(jellyfin::auth_header(
                &token,
                req.device_id.as_deref().unwrap_or("aquarium"),
            )),
            _ => None,
        };
        let opts = mpv::Options {
            title: String::new(),
            volume: req.volume.unwrap_or(100.0).clamp(0.0, 130.0),
            start: None,
            auth_header,
            user_agent: None,
            prefs,
        };
        let (session, rx) = mpv::Session::start(opts)?;
        let session = Arc::new(session);
        for (id, prop) in [
            (1, "time-pos"),
            (2, "pause"),
            (3, "duration"),
            (4, "volume"),
            (5, "mute"),
            (6, "speed"),
            (7, "paused-for-cache"),
        ] {
            if let Err(e) = session.command(json!(["observe_property", id, prop])) {
                crate::debug_log_line(&format!("audio: observe {prop} failed: {e}"));
            }
        }
        {
            let mut st = self.status.lock().unwrap();
            st.volume = req.volume.unwrap_or(100.0);
            st.speed = 1.0;
            st.mute = false;
        }
        let epoch = self.epoch.fetch_add(1, Ordering::SeqCst) + 1;
        crate::debug_log_line("audio: mpv core up");
        spawn_supervisor(
            app.clone(),
            rx,
            session.clone(),
            epoch,
            self.epoch.clone(),
            self.status.clone(),
            self.tracks.clone(),
            self.reporting.clone(),
        );
        Ok(Core { session, epoch })
    }
}

#[allow(clippy::too_many_arguments)]
fn spawn_supervisor(
    app: AppHandle,
    mut rx: tokio::sync::mpsc::UnboundedReceiver<Value>,
    session: Arc<mpv::Session>,
    my_epoch: u64,
    epoch: Arc<AtomicU64>,
    status: Arc<StdMutex<AudioStatus>>,
    tracks: Arc<StdMutex<Tracks>>,
    reporting: Arc<StdMutex<Reporting>>,
) {
    tauri::async_runtime::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut last_report = std::time::Instant::now();
        let mut last_tick: Option<Value> = None;
        loop {
            tokio::select! {
                msg = rx.recv() => {
                    let Some(msg) = msg else { break };
                    let event = msg.get("event").and_then(|v| v.as_str()).unwrap_or("");
                    match event {
                        "property-change" => {
                            let pause_changed = apply_property(&msg, &status);
                            if pause_changed {
                                emit_status(&app, &status);
                                let rep = reporting.lock().unwrap().clone();
                                let cur = tracks.lock().unwrap().current.clone();
                                if let Some(cur) = cur {
                                    let st = status.lock().unwrap().clone();
                                    report_progress(&rep, &cur, &st).await;
                                }
                                last_report = std::time::Instant::now();
                            }
                        }
                        "end-file" => {
                            let reason = msg.get("reason").and_then(|v| v.as_str()).unwrap_or("");
                            // "stop" is a `loadfile replace` or a playlist
                            // jump, which `play` has already accounted for.
                            if reason != "eof" && reason != "error" {
                                continue;
                            }
                            let (finished, next) = {
                                let mut t = tracks.lock().unwrap();
                                let finished = t.current.take();
                                let next = t.next.take();
                                t.current = next.clone();
                                (finished, next)
                            };
                            let rep = reporting.lock().unwrap().clone();
                            if let Some(done) = &finished {
                                if reason == "error" {
                                    let err = msg.get("file_error").and_then(|v| v.as_str()).unwrap_or("");
                                    crate::debug_log_line(&format!("audio: {} failed: {err}", done.item_id));
                                    let _ = app.emit("audio-error", json!({ "item_id": done.item_id, "error": err }));
                                } else {
                                    let end = done.duration.max(status.lock().unwrap().position);
                                    let rep2 = rep.clone();
                                    let done2 = done.clone();
                                    tokio::spawn(async move { report_stopped(&rep2, &done2, end, true).await });
                                }
                            }
                            match next {
                                Some(n) => {
                                    {
                                        let mut st = status.lock().unwrap();
                                        st.item_id = n.item_id.clone();
                                        st.duration = n.duration;
                                        st.position = 0.0;
                                    }
                                    let st = status.lock().unwrap().clone();
                                    let n2 = n.clone();
                                    tokio::spawn(async move { report_start(&rep, &n2, &st).await });
                                    let _ = app.emit("audio-track", json!({ "item_id": n.item_id }));
                                    emit_status(&app, &status);
                                    last_report = std::time::Instant::now();
                                }
                                None => {
                                    // The end of the queue: let the device go.
                                    status.lock().unwrap().active = false;
                                    let _ = session.command(json!(["quit"]));
                                    let _ = app.emit("audio-status", json!({ "active": false, "ended": true }));
                                    crate::mpris::notify();
                                }
                            }
                        }
                        _ => {}
                    }
                }
                _ = tick.tick() => {
                    if epoch.load(Ordering::SeqCst) != my_epoch { continue; }
                    let payload = status_payload(&status.lock().unwrap());
                    if payload.get("active") != Some(&Value::Bool(true)) { continue; }
                    // A paused book left overnight shouldn't wake the page
                    // every second to redraw the same thing.
                    let unchanged = payload.get("paused") == Some(&Value::Bool(true))
                        && last_tick.as_ref() == Some(&payload);
                    if !unchanged {
                        let _ = app.emit("audio-status", payload.clone());
                        crate::mpris::notify();
                        last_tick = Some(payload);
                    }
                    if last_report.elapsed().as_secs() >= 10 {
                        let st = status.lock().unwrap().clone();
                        if !st.paused {
                            let rep = reporting.lock().unwrap().clone();
                            let cur = tracks.lock().unwrap().current.clone();
                            if let Some(cur) = cur {
                                report_progress(&rep, &cur, &st).await;
                            }
                        }
                        last_report = std::time::Instant::now();
                    }
                }
            }
        }
        crate::debug_log_line("audio: mpv core ended");
        if let Some(p) = app.try_state::<AudioPlayer>() {
            let mut g = p.core.lock().await;
            if g.as_ref().map(|c| c.epoch) == Some(my_epoch) {
                *g = None;
                p.status.lock().unwrap().active = false;
            }
        }
    });
}

/// Fold one property change into `status`. True when pause flipped.
fn apply_property(msg: &Value, status: &Arc<StdMutex<AudioStatus>>) -> bool {
    let name = msg.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let data = msg.get("data");
    let mut st = status.lock().unwrap();
    match name {
        "time-pos" => {
            if let Some(p) = data.and_then(|v| v.as_f64()) {
                st.position = p;
            }
        }
        "duration" => {
            if let Some(d) = data.and_then(|v| v.as_f64()).filter(|d| *d > 0.0) {
                st.duration = d;
            }
        }
        "pause" => {
            let p = data.and_then(|v| v.as_bool()).unwrap_or(false);
            let changed = p != st.paused;
            st.paused = p;
            return changed;
        }
        "volume" => {
            if let Some(v) = data.and_then(|v| v.as_f64()) {
                st.volume = v;
            }
        }
        "mute" => st.mute = data.and_then(|v| v.as_bool()).unwrap_or(false),
        "speed" => {
            if let Some(v) = data.and_then(|v| v.as_f64()) {
                st.speed = v;
            }
        }
        "paused-for-cache" => st.buffering = data.and_then(|v| v.as_bool()).unwrap_or(false),
        _ => {}
    }
    false
}

fn status_payload(st: &AudioStatus) -> Value {
    serde_json::to_value(st).unwrap_or(Value::Null)
}

fn emit_status(app: &AppHandle, status: &Arc<StdMutex<AudioStatus>>) {
    let payload = status_payload(&status.lock().unwrap());
    let _ = app.emit("audio-status", payload);
    crate::mpris::notify();
}

// ------------------------------------------------------------------ reports

fn report_body(track: &AudioTrack, position: f64, paused: bool) -> Value {
    json!({
        "ItemId": track.item_id,
        "MediaSourceId": track.item_id,
        "PositionTicks": (position.max(0.0) * TICKS_PER_SECOND) as u64,
        "IsPaused": paused,
        "CanSeek": true,
        "PlayMethod": "DirectPlay",
    })
}

fn creds(rep: &Reporting) -> Option<(String, String, String)> {
    Some((
        rep.server_url.clone()?,
        crate::secret::token()?,
        rep.device_id.clone().unwrap_or_else(|| "aquarium".into()),
    ))
}

async fn report_start(rep: &Reporting, track: &AudioTrack, st: &AudioStatus) {
    if track.is_local {
        return;
    }
    let Some((server, token, device)) = creds(rep) else { return };
    let body = report_body(track, st.position, false);
    let _ = jellyfin::post(&server, &token, &device, "/Sessions/Playing", &body).await;
}

async fn report_progress(rep: &Reporting, track: &AudioTrack, st: &AudioStatus) {
    if track.is_local {
        let played = track.duration > 0.0 && st.position / track.duration > 0.92;
        progress::store_local(&track.item_id, (st.position.max(0.0) * TICKS_PER_SECOND) as u64, played);
        return;
    }
    let Some((server, token, device)) = creds(rep) else { return };
    let mut body = report_body(track, st.position, st.paused);
    body["EventName"] = json!("timeupdate");
    let _ = jellyfin::post(&server, &token, &device, "/Sessions/Playing/Progress", &body).await;
}

/// `finished` is a natural end: reported at the end so the server counts it.
async fn report_stopped(rep: &Reporting, track: &AudioTrack, position: f64, finished: bool) {
    let position = if finished && track.duration > 0.0 { track.duration } else { position };
    if track.is_local {
        let played = finished || (track.duration > 0.0 && position / track.duration > 0.92);
        progress::store_local(&track.item_id, (position.max(0.0) * TICKS_PER_SECOND) as u64, played);
        if let (Some(server), Some(token), Some(user)) =
            (&rep.server_url, crate::secret::token(), &rep.user_id)
        {
            let device = rep.device_id.clone().unwrap_or_else(|| "aquarium".into());
            let _ = progress::sync(server, &token, &device, user).await;
        }
        return;
    }
    let Some((server, token, device)) = creds(rep) else { return };
    let mut body = report_body(track, position, false);
    body.as_object_mut().map(|o| o.remove("IsPaused"));
    let _ = jellyfin::post(&server, &token, &device, "/Sessions/Playing/Stopped", &body).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unique_addresses_differ_for_the_same_song() {
        let p = AudioPlayer::new();
        let a = p.unique("http://srv/Audio/1/stream?static=true");
        let b = p.unique("http://srv/Audio/1/stream?static=true");
        assert_ne!(a, b);
        assert!(a.starts_with("http://srv/Audio/1/stream?static=true&aqEntry="));
        assert_eq!(p.unique("/home/x/song.flac"), "/home/x/song.flac");
    }

    #[test]
    fn a_finished_track_reports_its_full_length() {
        let t = AudioTrack { item_id: "a".into(), duration: 200.0, ..Default::default() };
        let body = report_body(&t, 200.0, false);
        assert_eq!(body["PositionTicks"], json!(2_000_000_000u64));
        assert_eq!(body["PlayMethod"], json!("DirectPlay"));
    }

    #[test]
    fn pause_changes_are_noticed() {
        let st = Arc::new(StdMutex::new(AudioStatus::default()));
        let changed = apply_property(&json!({"event":"property-change","name":"pause","data":true}), &st);
        assert!(changed);
        assert!(!apply_property(&json!({"event":"property-change","name":"pause","data":true}), &st));
        apply_property(&json!({"event":"property-change","name":"time-pos","data":12.5}), &st);
        assert_eq!(st.lock().unwrap().position, 12.5);
    }
}
