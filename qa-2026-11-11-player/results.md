# Player QA 2026-11-11 running notes (iPhone 18 Pro sim iOS 27.0 = p, qa-18pro; iPad Pro 11 M5 sim = t, autoqa)
Build: HEAD b5c81c7 (claude/instant-mix) + another session's untracked DownloadAudioList.swift; copy in scratchpad/Aquarium.app
Tools: scratchpad/q (driver), srv (server state), mont (montage), probe (XCUITest), results here.
## iPhone PASS
- open E04 (MKV remux, AVFoundation), first frame 1.4 s
- pause/play buttons, position holds while paused, controls stay while paused
- Back10/Fwd10 buttons exact; double-tap right +10, 2x double-tap left -20, badge "+10 s" shown
- hold 2x (5 s hold ~ +10 s), returns to prior speed
- timeline tap seeks; scrub drag seeks, time bubble shows (no trickplay thumb on QA Show E04 - check a film)
- Remaining <-> Total length toggle
- Back closes, finish logged pos 435; replay resumes at 7:15
- speed 1.5x measured (11 s in 7.3 s); Up Next card at 25 s left ("Up next · in 24s", Play now / Not now); autoplay to E05; prefetch logged
- speed 1.5x carries into next episode (chip SEL, measured) - by design per code
## iPhone observations / possible bugs
- O1 Quality card wording contradicts itself on MKV remux: Auto row "Playing now · Direct", Direct row "Playing now · transcoding", pill a11y "playing Direct Play (original)", Info "Transcoding · Original". Server: Transcode, video direct (remux).
- O2 Subtitles card on E04 (no subtitle streams) lists a "CC" row.
- O3 Info sheet content not in accessibility snapshot (XCUITest sees none of its rows) - maybe VoiceOver can't read it; unverified.
- O4 Up Next countdown said 24 s while at 1.5x (real time ~16 s) - check whether countdown is content-time.
- all 7 speeds measured OK (0.5: 5s/9.4s, 0.75: 7, 1.25: 11, 1.75: 16, 2: 19, Normal: 9)
- Spring: audio switch English->Spanish with subs Off: reopens, URL AudioStreamIndex=2 AudioCodec=ac3, position kept (PASS). Subtitles Off works, position kept.
- Skip intro pill appears on Spring at 8 s.
- B1 (bug) Spring with ASS subtitle selected, pick Spanish audio: reopen goes to mpv ("opening on mpv: original"), mpv decodes in software in the sim -> "reopening on AVPlayer with the server transcoding" -> URL has AudioStreamIndex=1 (English) while model/log says "audio: selected Spanish" and progress reports aud 2. ffmpeg log -map 0:0 -map 0:1. Picked audio lost in the software-decode fallback. (10:28:38 sim clock)
- O5 first open of Spring with ASS default-selected chose AVFoundation+transcode (server burns in, SubtitleMethod=Encode); the reopen chose mpv. Inconsistent engine choice for same state.
- LIMIT: mpv always software-decodes in the simulator, so every mpv route falls back to AVPlayer; mpv-drawn ASS/PGS, DTS can't be tested in sim.
- Big Buck Bunny is a DOWNLOAD on the phone sim: opens "download ... on AVFoundation", pill "Downloaded copy". Sidecar files Spanish/Forced/SDH/English all drawn by the app with correct timing (PASS). Off works.
- O2 confirmed: "CC" row selectable on the download too, shows nothing.
- O6 download's Subtitles card rows say "Drawn by the server · reopens the stream" though they are local files drawn by the app.
- B2 (bug) paused + quality change (Auto->5 Mbps) resumes playback by itself; speed 1.5x, French subs, position all kept. Subtitles from HLS: embedded SubRip EN/FR correct timing incl. at 1.5x, after skip, while paused+skip. O7: stream subs drawn in grey box, download subs outline (style differs).
- paused + subtitle switch (in-manifest, no reopen) stays paused (PASS)
- every quality rung selectable from the card; 2.5 Mbps -> 480p transcode 2.56 Mbps, 5 Mbps -> 720p, 10 Mbps on a 5.8 Mbps file -> remux; Direct, Auto; position continuous through 7 switches, subs kept (PASS)
- sleep timer set/cancel from More card (PASS, log). Stop after this episode: row flips to 'Nothing plays after this one', no Up Next card in last 25 s, player closes at end with finish: ended (PASS)
- Up Next card "Not now": card goes, player closes at end (PASS). "Play now": next episode opens at once (PASS). Subtitle choice (English) carried E06 -> E07.
- E07 MP4 mov_text: English shows on direct play? (shown after reopen as transcode), French shows; picking French on a direct-played MP4 reopens as a server transcode ("Drawn by the server · reopens the stream") though both tracks are in the file (O8); going back to English stays on the transcode.
- Fill pill toggles (a11y value On/Off), portrait fill zooms to full height; rotate to landscape works, fill/fit both right; subs follow.
- O9 with controls up in landscape the subtitle line sits behind the pill row.
- all 11 formats open+advance on AVFoundation: HEVC/EAC3, 4K HDR10 (server transcodes h264 44 Mbps), AV1, MPEG-2 TS, VP9 webm, AVI, 2-version film, 4K60/vertical/120fps HEVC clips direct, music video (PASS). O1b: pill a11y says 'Auto, playing Direct Play (original)' even when the server is re-encoding video (AV1, HDR).
- Skip intro works (8 -> 16 s, pill leaves). Film scrub shows trickplay thumbnail + time bubble (Cosmos). End of film closes player (finish: ended), replay starts from 0.
- B3 (bug, root cause found) "Skip credits" never shows on streamed titles: Core/JellyfinClient.swift:1903 requests /MediaSegments/<id>?includeSegmentTypes=Intro,Outro and this server (Jellyfin 12.2) answers with the Intro only; repeated params (includeSegmentTypes=Intro&includeSegmentTypes=Outro) return both. Seen on Cosmos Laundromat at 2:48 (Outro 165-180 s): no pill, no credits mark on timeline.
- Live TV (from Home > On Now): LIVE badge, programme timeline '14 min left · ends 11:00 AM', Previous/Next channel wrap, Channels pill + sheet tunes, More card has only Sleep + Change channel, no Quality/Up Next pills, double-tap and hold do nothing, pause/resume OK (PASS). O10: aquarium://play/<channelId> debug link plays a channel as a 3-min non-live title (debug route only). O3 again: Channels sheet not in a11y snapshot.
- Live: when the channel's source ran out (~2 min in) log 'bitrate down: 5 Mbps · 720p (Connection slowed)' and reopened, kept playing (recovery OK; reason text is a guess).
- iPad: 15-min sleep timer survived 3 autoplay hops (E01>E02>E03>E04) and closed the player on time (finish: sleep timer) (PASS)
- combos: hold-2x while at 1.5x returns to 1.5x (measured). paused + double-tap: stays paused, +10. paused + hold: starts playing and KEEPS playing after release (by design in code; arguably should re-pause) (O11).
- pinch out -> Fill On, pinch in -> Fill Off (real two-finger gesture; PASS)
- Up Next card: tapping Episode 6 from E04 jumps straight to E06, speed kept, list updates (PASS)
- Info sheet rows all present and live (Engine, Position, Speed 1.5x, Subtitles English, Sleep timer 30 min left, After this Stop) (PASS). O12: 'Audio track: Unknown' on E06 (AAC eng, single track).
- landscape: all five cards open/close and fit (Quality and More scroll); Info sheet is full-screen in landscape, swipe down dismisses. Sleep row counts down (29 min).
- Watch Together with no FaceTime call: card closes and nothing else happens, no toast (code promises 'Start a FaceTime call first…') (B4, sim; confirm on device). AirPlay button: tap shows no picker in the simulator (untestable). PiP button not offered on iPhone sim (sim reports PiP unsupported).
- background: with Settings in front playback keeps going (server position advances at 1.5x), returns to the player intact (PASS)
- episode page More > Play at a set quality > 5 Mbps: plays 720p 5 Mbps, stays there 45 s; card ticks Auto 'Playing now · 720p' rather than the rung (O13, wording). Continue Watching card long-press via XCUITest opened the page (context menu not verified).
- Settings > Video: Resume off -> E04 (had a resume point) starts from 0 (PASS). 
- B5 (bug/mismatch) Autoplay off: no Up Next card in the last 25 s (checked 6 times from 9:40), player just closes at the end; Settings text says "The Up Next card appears ... either way". Code: upNextIsDue requires autoplay_next (PlayerModel+Extras.swift:38).
- error card: 'This didn't play' + raw 'Server error 400 on /Items/<id>/PlaybackInfo', buttons Try again / Try a smaller stream / Close all respond; Close leaves the player (finish: error card closed) (PASS; wording is raw, O14)
## iPhone combination matrix (E06; speed 1.5x + French subs + Fill on + sleep 30 + 5 Mbps all on at once; output in scratchpad/combo-p.txt)
- playing and paused: skip button, double-tap, timeline tap, rotate landscape/portrait, Info open/close, subtitle EN->FR, background+return, quality 5->2.5->5, hold-2x: speed, subtitles, fill, sleep timer, quality all survive every action; pause state survives all but quality change (B2 again).
- B6 (bug) "Stop after this episode" is silently cleared by a quality change (stream reopen): row goes from 'Nothing plays after this one' back to 'Otherwise next: …'. Survives skip and in-manifest subtitle switch. Code: autoplayCancelled reset in play() PlayerModel+Playback.swift:202.
## iPad (Pro 11 M5 sim, autoqa)
- auto-PiP on backgrounding works; subtitles show in the PiP window; coming back to the app leaves the video in PiP with a placeholder until "Leave Picture in Picture" (O15). PiP button starts/stops PiP. With PiP active: pause/play/skip, all five cards and the Info popover work (PASS). O16: the PiP window lands on top of the AirPlay / PiP / … buttons (top right), so a tap there hits the PiP window.
- combo-t.txt: first 8 playing-mode actions all OK on iPad (speed, subs, fill, sleep, quality survive skip, double-tap, timeline, rotate both ways, info, subtitle switch); later rows were derailed by auto-PiP covering the buttons (driver, not app).
- B7 (bug, major, both devices) Fixed quality rung (5 Mbps = server re-encode) + autoplay: ~3 s after "prefetched next <id> transcode=true" in the last 90 s, the current stream fails with CoreMediaErrorDomain -12971, error card "This didn't play"; Try again reopens, prefetches, fails again 0.7 s later; episode can never finish or autoplay. Seen iPad (PiP, 1.5x, 11:12:42 and 11:14:00) and iPhone (no PiP, 1x, 11:14:43). Control at Auto (prefetch transcode=false, E07 direct MP4): fine, autoplays. Earlier Auto remux->remux (prefetch transcode=true) also fine. Likely: the prefetch's transcode request makes Jellyfin kill this device's running encode (server started a fresh ffmpeg -ss 5:56 for segment 120).
- iPad transport: pause/play, ±10 buttons, double-tap ±10, hold 2x, timeline tap, Remaining/Total toggle (PASS)
- iPad cards + Info popover open/close in portrait and landscape, anchored to their pills; Up Next lists E05-E07 (PASS). O17: speed chip "Normal" truncated to "Nor…" on iPad. O18: Info popover glass is hard to read over a bright picture. O2 again ("CC" on E04).
- iPhone download (Big Buck Bunny): opens from Downloads, Skip intro, Quality card shows only "Downloaded · Original quality / Playing from this device", 2x measured, scrub (time bubble only, no thumbnail offline), ends and closes (PASS). No Skip credits at 2:48 either (B3 applies to downloads). O19: download reopens with the Spanish subtitle file every time, whatever was last picked (Off / English / CC). Fill choice persists across titles.
- Play Later from a poster's long-press menu with nothing playing starts the film (menu: Play / Play Next / Play Later / Download). Time-label choice persists to the next title. Rotating with a card open keeps the card. Upside-down is refused (stays landscape).
- iPad combo-t2.txt: subtitles(French)/fill/quality survive all 11 actions in playing and paused mode; pause survives all but quality change (B2 on iPad); stop-after held through 8 actions then cleared by the quality change (B6 on iPad). Speed+sleep were verified in combo-t.txt rows 1-8 (setup missed them in run 2: driver).
- iPad landscape: French subs fill/fit OK; speeds 0.5/2/1 measured OK; subtitle line overlapped by the scrub bar when controls are up (O9 on iPad).
- iPad streamed Big Buck Bunny: the four sidecar SRTs (English, Spanish, Forced, SDH) each show with right timing; first pick reopens the stream, later picks switch in place (PASS). HDR 4K, AV1, vertical clip, Spring open (PASS).
- iPad live TV: tune from Home, Next channel, Channels popover picks a channel, live in PiP (PASS). Back while in PiP closes the player and PiP together (finish: player dismissed), so the library can't be browsed with a video playing; a multi-item hand-made queue could not be built by touch on either device.
