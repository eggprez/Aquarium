# Player QA on iPhone and iPad simulators, 2026-11-11

**Build:** `claude/instant-mix` at b5c81c7, plus another session's untracked `Core/DownloadAudioList.swift` that was in the checkout when it was built.
**Devices:** iPhone 18 Pro simulator (iOS 27.0, account `qa-18pro`, direct to the QA server) and iPad Pro 11-inch M5 simulator (iOS 27.0, account `autoqa`, through the 8098 proxy). The iPhone 17 simulator was in use by another session, so it was left alone.
**Server:** the permanent QA Jellyfin server on 8196.

## Where it stands now (second pass, same day)

All seven bugs from the first pass are fixed or resolved and re-tested on the simulators, along with five of the smaller issues. The areas that were untested were then tried; that turned up three new problems, which are fixed and re-tested too (third pass, below). The fixes are committed on `claude/instant-mix` (not pushed). The app builds for iPhone/iPad, Apple TV and Mac, and the 98 unit tests pass.

**One correction to the first pass:** B7 was misdiagnosed. It is not caused by pre-loading the next episode. It happens on any server re-encode of a file whose subtitle track runs longer than its picture (QA Show E06: picture 5:59.98, subtitles 6:01). The server lists a last segment it never produces and AVPlayer fails the whole stream when it reads ahead to it. A clean episode (E04) at the same 5 Mbps rung rolled on to the next one without trouble.

### Fixes

| # | Fix | Re-test |
|---|---|---|
| B7 | A server encode that fails inside its last two minutes is reopened once with an 8-second read-ahead, and a failure within 20 s of the end is taken as the end (`recoverFromMissingTail`, `PlayerModel+Playback.swift`). On such a file the last few seconds are skipped instead of the episode ending in an error loop. | iPhone, E06 at 5 Mbps: failed 41 s from the end, reopened, played to 8 s from the end, rolled on to E07 |
| B3 | Markers are requested with one `includeSegmentTypes` parameter per type. | iPhone: "Skip credits" shows at 2:48 on Cosmos Laundromat and ends the film |
| B2 | A same-title reopen (quality, track) keeps the pause. | iPhone and iPad: paused through 5 → 2.5 → 5 Mbps, position unchanged; a frame is shown |
| B6 | A same-title reopen keeps "Stop after this episode". | iPhone and iPad (`combo-t-fixed.txt`) |
| B5 | The Up Next card shows with autoplay off, reading "Up next" with no countdown; nothing starts by itself. | iPhone: card shown, "Play now" works, player closes at the end |
| B1 | Already fixed by commit ca154f3 from another session (PlaybackInfo now names the media source). | iPhone: Spring with ASS on, Spanish picked, stream address says track 2 |
| B4 | The message was being shown, but underneath the player: toasts are drawn by the app's root view and the player is a full-screen cover above it. Toasts are now drawn over the player on iPhone and iPad, which also uncovers every other player message ("Asking the server to re-encode…", the Auto quality notes). | iPhone: "Start a FaceTime call first, then choose Watch Together" appears |

Smaller issues fixed: the dead "CC" row (kept for live channels); the contradictory Quality wording (now "Original, converted by the server" when the server is repackaging or re-encoding); Info's "Audio track: Unknown" (Info now uses the same names as the cards, for subtitles too); the download subtitle rows no longer say "Drawn by the server"; the iPad's "Nor…" speed chip.

Left as they are: subtitles behind the controls in landscape; a downloaded film reopening with the subtitle the server had as its default when it was downloaded; a second embedded MP4 subtitle forcing a transcode; the differing subtitle styles; hold-for-2× resuming a paused title; the iPad Info popover's legibility; PiP staying up when the app returns; raw error text. Each is a design choice or a larger change than a bug fix.

### Newly tested areas

- **mpv engine.** It does run in the simulator, with hardware decoding, when the stream is a server transcode (pick a rung, then an ASS subtitle). On iPhone: 1× and 2×, pause, skip, double-tap, hold, Fill, landscape, audio switch, quality change, background (picture decode off, sound continues) and return all work; Info reads "mpv · hardware decoding (videotoolbox)". On iPad: PiP starts natively on mpv and pause/skip work in it.
- **Slow network (iPad, through the proxy, 5 Mbps limit on a 15.6 Mbps episode).** Auto stepped down once, to 10 Mbps. See N1.
- **Offline (iPhone).** Three episodes downloaded from their title pages; a downloaded episode rolls on to the next downloaded one; Shuffle plays and rolls on in shuffled order; Up Next lists downloads.
- **iPad pinch to fill:** works both ways (scripted pinch on the video).

### New findings, now fixed (third pass)

| # | Problem | Fix | Re-test |
|---|---|---|---|
| N1 | **Auto quality on a sustained slow link froze for minutes.** At a 5 Mbps limit it stepped one rung, to 10 Mbps, took about two minutes to show a picture and then sat frozen for about 100 s more. | Three changes, all from the "While playing" part of `AUTO-QUALITY-PLAN.md`, not the whole plan. A stall step-down is sized by the throughput the engine is seeing whether or not the Speed check is on. A watch counts a picture that has stopped with nothing reported as a stall. A stream Auto stepped down to that has no picture after 25 s steps down again without waiting out the cooldown. Two unit tests added. | iPad, same limit: one step straight to 2.5 Mbps, picture back in 15 s, smooth afterwards; climbed a rung 5 minutes after the limit was lifted. A 25 s pause, a slow scrub and autoplay raised no false stall on iPhone. |
| N2 | **PiP on mpv with Fill on had the wrong shape** (a portrait window with a slice of the picture). | While the PiP window is starting or up, mpv's picture is framed to fit; Fill comes back when it closes. | iPad: 16:9 window with the subtitle in it, over the app and over Settings; inline picture filled again after restoring. `shots/fixed-mpv-pip-fill-ipad.png` |
| N3 | **ASS subtitle on mpv over a transcode did not show** while the card ticked it. The server delivers the track as a separate file on a transcode, and the reopen for a chosen subtitle only looked for a track inside the stream. (The small, raised text seen once on iPhone was the normal lift while the controls are up.) | The reopen now loads a subtitle the server delivers as a file. | iPhone and iPad: shows on first pick, at the foot of the picture. `shots/fixed-mpv-ass-iphone.png` |

The first attempt at N2 (stopping mpv cropping frames for Fill) did not change the result and was reverted.

Not done from the Auto quality plan: the moving-average estimate, the early drop before a stall, the faster climb, and telling a slow server from a slow network. Auto still climbs one rung per five steady minutes.

### Fourth pass: more of the untested areas

| Area | Result |
|---|---|
| **Lock screen (iPhone)** | Playback continues with the phone locked. The Now Playing card shows the title, series, artwork and a moving scrubber; pause and resume from it work. Its skip buttons are not drawn in the simulator, so skip and scrub from the lock screen are unconfirmed. `shots/lock-screen-iphone.png` |
| **Sleep-timer Live Activity (iPhone)** | Appears on the lock screen with the time left. "+15 min" extends the timer (30 to 44 min), pause/play acts on the player, "Turn off" cancels the timer and removes the activity. |
| **Server unreachable mid-play (iPad)** | The proxy was frozen for 96 s. The buffer played for a minute, then the player showed "Loading", stepped down a rung and waited; the picture was back 6 s after the server returned, with no error card. Killing the proxy outright was not tried (blocked by the permission system). |
| **Resized iPad window** | Dragged to about 374 x 514 pt. Playback continues, the chrome drops to glyph-only pills, and the Quality, More and Up Next cards and the Info sheet open and fit. `shots/small-window-ipad.png` |

Two more problems found and fixed in this pass:

| # | Problem | Fix | Re-test |
|---|---|---|---|
| W1 | **In a resized iPad window the system's window controls covered the Back button.** | The title row starts 52 pt further in when the window is smaller than the screen. | iPad: Back sits beside the controls; unchanged at full size. `shots/fixed-small-window-back-ipad.png` |
| W2 | **A quality change sometimes ended in "This didn't play" (error -19602).** Seen on 3 changes on the 15.6 Mbps episode, each going from the 10 Mbps rung back up to the original. The server starts one encode for the playlist and replaces it with another at the position asked for; the player was still reading the first when it was deleted. | A stream that fails within 10 s of a same-title reopen is quietly reopened, within the existing budget of two recoveries. | Not observed firing: the race did not recur in 36 further quality changes, which showed no error. |

### Still not tested

PiP on iPhone, AirPlay, SharePlay in a call, Handoff, Siri and Shortcuts, the Watch remote, skip and scrub from the lock screen, Control Centre, a hand-made queue of several videos, a hard server drop, and real hardware.

---

# First pass

## What is broken

| # | Problem | Where seen | Evidence |
|---|---|---|---|
| B7 | **Fixed quality + autoplay kills the stream at the end of an episode.** *(Cause corrected above: a missing last segment, not the pre-load.)* With a rung such as 5 Mbps picked, about 3 s after the next episode is pre-loaded (last 90 s) the current stream fails with `CoreMediaErrorDomain -12971` and the "This didn't play" card. "Try again" reopens, pre-loads again and fails again within a second, so the episode can never finish or roll on. | iPhone and iPad, 3 runs | Log: `prefetched next … transcode=true` then `stream failure … -12971`. The server started a fresh ffmpeg at `-ss 5:56` for the last segment, which suggests the pre-load's transcode request stopped this device's running encode. At Auto (pre-load `transcode=false`) the same episode and seek rolled on normally. `shots/error-end-of-episode-ipad.png` |
| B3 | **"Skip credits" never shows.** `Core/JellyfinClient.swift:1903` asks for `includeSegmentTypes=Intro,Outro`; this server answers with the Intro only. Asking with the parameter repeated (`…=Intro&…=Outro`) returns both. | iPhone stream and download | Cosmos Laundromat at 2:48, inside its 2:45–3:00 credits marker: no button. `shots/no-skip-credits-iphone.png` |
| B2 | **Changing quality while paused starts playback.** Speed, subtitles, position, fill and sleep timer all survive the change; the pause does not. | iPhone and iPad | `combo-p.txt`, `combo-t2.txt` rows "[paused] quality ->" |
| B6 | **A quality change silently turns off "Stop after this episode".** The row goes from "Nothing plays after this one" back to "Otherwise next: …". It survives skips and subtitle switches. | iPhone and iPad | Likely `autoplayCancelled` being reset in `play()` (`PlayerModel+Playback.swift:202`) |
| B5 | **With autoplay off, the Up Next card never appears**, and the player just closes at the end. Settings › Video says the card "appears … either way". | iPhone | `upNextIsDue` requires `autoplay_next` (`PlayerModel+Extras.swift:38`) |
| B1 | **Audio choice lost on the mpv fallback.** On Spring with its ASS subtitle on, picking Spanish audio reopened on mpv, mpv fell back to AVPlayer, and the stream was requested with the English track while the card and the server report said Spanish. | iPhone | Stream address had `AudioStreamIndex=1`; ffmpeg mapped `0:1`. With subtitles off the same switch requested track 2 correctly. The fallback fires here because mpv cannot hardware-decode in the simulator; on a device it would need a file mpv has to decode in software. |
| B4 | **Watch Together with no FaceTime call does nothing.** The card closes; no message appears. The code promises "Start a FaceTime call first…". | iPhone simulator | Needs a check on a real device |

## Smaller things noticed

- **A dead "CC" row** in the Subtitles card on titles with no subtitles (QA Show E04) and on the downloaded film. Selecting it ticks it and shows nothing.
- **Quality wording contradicts itself** on a remuxed MKV: Auto row "Playing now · Direct", Direct row "Playing now · transcoding", Info "Transcoding · Original". The pill's VoiceOver label says "playing Direct Play (original)" even when the server is re-encoding video (AV1, 4K HDR).
- **Info sheet "Audio track: Unknown"** on a single-track AAC episode.
- **Subtitles sit behind the controls** when they are up in landscape (pill row on iPhone, scrub bar on iPad).
- **Downloaded film reopens with Spanish subtitles every time**, whatever was last chosen (Off, English).
- **Download subtitle rows say "Drawn by the server · reopens the stream"** although they are local files the app draws.
- **Second embedded subtitle on a direct-played MP4** (French on E07) reopens the stream as a server transcode, though both tracks are in the file.
- **Subtitle style differs:** streamed subtitles are in a grey box, a download's are outlined text.
- **Holding for 2× on a paused title** leaves it playing after release (the code does this on purpose).
- **iPad:** the "Normal" speed chip is cut to "Nor…"; the Info popover's glass is hard to read over a bright picture; the PiP window lands on top of the AirPlay / PiP / "…" buttons; returning to the app leaves the video in PiP until "Leave Picture in Picture" is pressed.
- **Error text is raw** ("Server error 400 on /Items/…/PlaybackInfo").
- **The Info and Channels sheets on iPhone are invisible to the accessibility snapshot** the test driver reads. Whether VoiceOver can read them was not checked.

## What works

Checked on both devices unless marked.

**Transport and gestures**
- Play, pause, back/forward 10 s buttons, double-tap skips with the "+10 s" badge.
- Hold for 2×, returning to the speed that was set (checked at 1.5×).
- Timeline tap and drag; time bubble; trickplay thumbnail on films (iPhone).
- Remaining / total length toggle, and the choice carrying to the next title (iPhone).
- Pinch to fill and back (iPhone only; see gaps). Fill pill in portrait and landscape.
- Back closes and saves the position; the next open resumes there.

**Cards and Info**
- All five cards and Info open and close in portrait and landscape on both devices; a card survives rotation.
- All seven speeds, measured against the clock (iPhone); 0.5×, 1×, 2× on iPad.
- Every quality rung, Direct and Auto; position stays continuous across seven switches.
- Audio track switch (Spring, English to Spanish, subtitles off).
- Up Next card lists the next episodes; tapping one jumps to it.
- Sleep timer set, cancel and countdown; a 15-minute timer on iPad survived three autoplay hops and closed the player on time.
- Stop after this episode (when quality is left alone): no Up Next card, player closes at the end.
- Info rows are live: engine, position, speed, subtitles, sleep timer, "After this".

**Subtitles**
- Embedded SubRip (MKV) English and French, embedded mov_text (MP4), four sidecar SRTs on a stream (iPad) and as downloaded files (iPhone): all drawn with correct timing.
- Correct after skips, at 1.5×, while paused, in fill, in landscape and in PiP.
- Choice carries to the next episode.

**Overlays and end of title**
- Skip intro; Up Next card with "Play now" and "Not now"; autoplay with the next episode pre-loaded (at Auto); a film ending closes the player.
- Error card: Try again, Try a smaller stream and Close all respond.

**Formats** (all open and play): H.264 MKV remux, 4K H.264, HEVC + E-AC-3, 4K HDR10, AV1, MPEG-2 TS, VP9 WebM, AVI, a two-version film, 4K60 / vertical / 120 fps HEVC clips, a music video.

**Live TV:** LIVE badge, programme timeline, previous/next channel, Channels pill and list, the trimmed More card, no skip or 2× gestures, pause/resume, recovery when the channel's source ran out, PiP (iPad).

**Picture in Picture (iPad):** starts from the button and on backgrounding; pause, skip, every card and Info work while it is active.

**Background (iPhone):** playback continues with another app in front and the player is intact on return.

**Downloads (iPhone):** opens from Downloads, skip intro, 2×, scrub, the single "Downloaded" quality row, end of film.

**Settings:** Resume off starts from the beginning; "Play at a set quality" from a title page; "Play Later" from a poster starts the film.

## Combinations

"Every combination" was covered two ways, not exhaustively:

- **Everything on at once, then each action.** On QA Show E06 with 1.5× speed, French subtitles, Fill, a 30-minute sleep timer, stop-after and a 5 Mbps rung all set, the driver ran skip button, double-tap, timeline tap, rotate to landscape, rotate back, Info open/close, subtitle switch, background and return, quality down, quality up, and hold-for-2×, first playing and then paused, checking every setting after every action. That is 23 action-and-state checks per device (`combo-p.txt`, `combo-t.txt`, `combo-t2.txt`). The only failures are B2 and B6. The "FAIL" on every row of those files is mostly B6 from setup or a driver miss; read the reasons at the end of each row.
- **Targeted pairs** where the code has special handling: speed with autoplay, hold-for-2× with a set speed, pause with skip/double-tap/hold, sleep timer with autoplay, stop-after with the Up Next card, subtitles with audio switch, PiP with cards and with the end of an episode, fixed quality with autoplay.

On the iPad the second run missed setting speed and sleep (a driver tap was swallowed), so those two are covered by the first eight rows of `combo-t.txt` only.

## Not tested, and why

- **Anything on mpv** (ASS/PGS drawn by mpv, DTS/TrueHD, PiP hand-over from mpv): mpv only software-decodes in the simulator, so the app falls back to AVPlayer every time.
- **PiP on iPhone:** the iPhone simulator reports PiP unsupported.
- **AirPlay:** the button is there but the simulator shows no route picker.
- **SharePlay in a call, Handoff, lock screen / Control Centre controls, Live Activity, Siri and Shortcuts, Apple Watch remote, haptics.**
- **Pinch and window resizing (Split View, Stage Manager) on iPad:** the simulator tool had no grant for the iPad, and the scripted pinch does not register.
- **A hand-made queue of several videos:** the player is modal and Back closes it (and PiP), so nothing else can be queued by touch while a video plays. Only "Play Later" starting playback was seen.
- **Brightness/volume edge drags, subtitle style or delay, audio delay, hardware-keyboard shortcuts, pointer:** not offered on iPhone or iPad in this build.
- **Network trouble:** Auto stepping down on a slow link, stalls, server loss.
- **Offline next-episode and shuffle from Downloads:** only one film was downloaded.
- **Real hardware:** everything here is simulator-only.

## Files

- `results.md`: running notes with times and log lines.
- `combo-*.txt`: raw output of the combination runs.
- `shots/`: key screenshots.
- `driver/`: the scripted XCUITest probe (`Probe.swift`, `project.yml`) and its shell helpers (`q`, `combo`, `cue`, `srv`, `reset`, `mont`). `Probe.swift` has the scratchpad path it was built with hard-coded as `base`; change it before reuse.
