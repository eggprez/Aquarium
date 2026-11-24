# Apple TV: the manual checklist

What only a real Apple TV, a real Siri Remote and a real television show.
The automated suite (`COVERAGE.md`) runs on the "Aquarium Test Apple TV"
simulator, which has no touch surface, no HDMI, no display modes and no
home-screen shelf worth trusting. Run this list on hardware before a tvOS
release, signed in to the QA server (`suite-tv`, or a spare account) unless a
line says otherwise. Write the date, the Apple TV model, tvOS version, TV and
soundbar/receiver model next to each pass.

Fixtures are the keys in `~/Library/Application Support/AquariumQA/fixtures.json`.

## 1. The Siri Remote's touch surface

The simulator only gets swipes from the debug hook (`aquarium.remote.swipe*`),
which sends ten even steps. A thumb doesn't.

- [ ] Paused, a slow swipe right scrubs: knob ringed, time pill and trickplay
      thumbnail above it (FX Long Direct Play has 320 px trickplay).
- [ ] A full-width swipe moves about an eighth of the title (2:30 on the
      20-minute FX Long Direct Play), never less than a minute on short ones.
- [ ] Playing, a swipe moves nothing. Resting a thumb on the pad moves nothing.
- [ ] After a scrub, a click jumps; the bar says "Menu to go back to …"; Menu
      returns there.
- [ ] Clicking the left/right *edges* of the clickpad skips 10 s (or the
      Settings interval) and shows the running "+30 s" total; clicking the
      centre pauses. Try on both the 2nd-gen (clickpad ring) and 1st-gen
      (glass touch) remotes.
- [ ] Swipe down opens the panel on Info; a swipe up from the tabs puts it
      away; a swipe up from the cards moves focus to the tabs instead.
- [ ] The 1st-gen remote's touch click and the 2nd-gen's ring "jog" (circular
      scrub) feel right; the jog is not handled by the app — note what it does.
- [ ] Play/Pause on the remote works while the panel is open.
- [ ] Holding Select on a Home card opens its menu; the haptic-less remote
      gives no false double action.
- [ ] Menu from the player's top level returns to the page it was opened
      from, and never quits the app (the full-screen cover's own Menu route,
      see the memory note on tvOS simulator testing, 2026-10-11).

## 2. Picture: HDR, Dolby Vision, range and frame-rate matching

Turn on Settings → Video and Audio → Match Content → Match Dynamic Range and
Match Frame Rate on the Apple TV first, then off, and run both ways.

- [ ] FX HDR10 MP4: the TV switches to HDR10; the Info tab's stream line names
      the range (fix-status.md "Info doesn't mention HDR — fixed, unverified").
- [ ] FX HLG MKV: the TV switches to HLG (or HDR with HLG tone mapping).
- [ ] FX HEVC 10bit EAC3 MP4 (SDR 10-bit): stays SDR, no washed-out picture.
- [ ] Dolby Vision: the QA server has no DV file (FIXTURES.md, "Not testable").
      Use a real DV profile 5 and profile 8.1 file from a personal library;
      note whether mpv shows DV, HDR10 fallback, or purple/green.
- [ ] Match Frame Rate: FX Long Remux Multitrack (23.976) switches the TV to
      24p; Clip 2 30 fps and Clip 1 60 fps switch accordingly; the switch
      happens before the first frame (`DisplayMatch`, never seen on the
      simulator, PLAYER-OVERHAUL-PLAN phase 5).
- [ ] Interlaced: FX Interlaced 1080i TS shows no combing.
- [ ] AV1 (FX AV1 MP4): plays on a 4K (3rd gen) box. On the simulator it
      crashes inside the simulator's Metal driver (master-fix-list.md, "try
      once on a real Apple TV").
- [ ] A long film keeps the screensaver off throughout and lets it come back
      when paused for the screensaver's time (bffc9e7).
- [ ] Picture tab: brightness/contrast/gamma steps change the live picture;
      Zoom and Aspect behave on a 2.39:1 film; Fill crops on a 4:3 source.

## 3. Sound: HDMI formats and sync

- [ ] FX Long Remux Multitrack, each audio track in turn: AAC stereo, AC-3
      5.1 (receiver shows Dolby Digital), E-AC-3 5.1 (Dolby Digital Plus),
      DTS 5.1 (decoded by mpv: receiver shows multichannel PCM), FLAC, mono
      commentary.
- [ ] FX TrueHD MKV: multichannel PCM on the receiver, no dropouts.
- [ ] FX AAC 7.1 MP4: 7.1 PCM reaches a 7.1 receiver (the profile asks for 8
      channels).
- [ ] FX PCM MOV: plays, correct channel count.
- [ ] Settings → Audio → Stereo downmix on: everything above arrives as
      2-channel.
- [ ] Atmos (E-AC-3 JOC / TrueHD Atmos): no QA fixture; use a personal file
      and note what the receiver shows.
- [ ] Audio sync: Settings → Audio → each frame rate's row → the flashing
      warning → the clip. On a soundbar with lag, the iPhone's "Measure Apple
      TV sync" reads the QR code, the flash and the beep; the measured delay
      set in the Sync tab puts the beep on the flash. Check the code is read
      from the sofa at 2–3 m.
- [ ] After setting a 24 fps delay, a 23.976 film uses it and a 60 fps clip
      doesn't (per-rate delays).
- [ ] Night mode: this mpv build has no compressor (PLAYER-OVERHAUL-PLAN
      phase 6). Note whether the Settings row still offers it (the suite
      expects it not to, and records the failure as a bug).

## 4. The Top Shelf on a real home screen

The unit tests cover what the app writes (`TVTopShelfTests`); only a home
screen shows what the extension draws.

- [ ] On hardware the shelf lives in `<group>/Library/Caches/TopShelf` (writes
      elsewhere in the group container fail on a real Apple TV; the
      simulator allows them). After Home loads, check it is there:
      `xcrun devicectl device info files --device <udid> --domain-type
      appGroupDataContainer --domain-identifier group.scottai.FellyJin`
      lists `Library/Caches/TopShelf/nextup.json` and `images/`.
- [ ] Put Aquarium in the top row. After Home loads once, focusing the icon
      shows "Next Up" with series posters, one per show, with progress bars
      on started episodes.
- [ ] Clicking a poster opens that episode's title page; Play/Pause on the
      remote with a poster focused starts it playing.
- [ ] Watch an episode to the end without visiting Home (open it from the
      shelf): after playback the shelf moves on to the next episode
      (`TopShelf.refresh`, f6b43c9).
- [ ] Sign out: the shelf goes back to the static Top Shelf image, which
      shows the icon and the one-word "aquarium" wordmark with the purple
      bubble over the i (regenerated by `Tools/IconGenerator`, 2026-11-20).
- [ ] Reboot the Apple TV without opening the app: the shelf still shows the
      last posters (it reads files, no network).
- [ ] A second Apple TV user (Control Center → switch user) sees their own
      shelf, or the static image if not signed in.

## 5. Other hardware-only paths

- [ ] Second Apple TV user: "Who's watching?" offers the accounts signed in
      under the first user (`Keychain.Household`, user-independent keychain).
      Test mode keeps this in the test defaults, so the suite never sees it.
- [ ] Wi-Fi drop mid-episode: the player says the server can't be reached and
      does not jump to the next episode (master-fix-list "Top priority …
      dropout of about 12 s is treated as end of episode"; verified only
      with the proxy killed).
- [ ] A throttled line (QA proxy 8098 at 3 Mbps): a starved direct play shows
      a notice with a way out rather than a bare spinner.
- [ ] Siri: "Play FX Long Show in Aquarium" and "Continue watching in
      Aquarium" (`PlayerIntents`), if the Apple TV has Siri.
- [ ] YouTube trailer (FX Extras and Trailers has a remote trailer): with the
      YouTube app installed, Trailer opens it; without it, no Trailer button
      for a YouTube-only trailer (the suite records the missing check as a bug).
- [ ] The guide on a 55"+ TV from the sofa: channel names, programme titles
      and times readable, the now-line not crossing text, focus visible.
- [ ] Overscan: with the TV's overscan on, nothing important is cut (60 pt
      margins on Home, the panel, Settings).

## 6. Long waits and failures the suite doesn't force

The automated suite sets and cancels these, but doesn't wait them out or
break the server for them (COVERAGE.md "untested" rows).

- [ ] Sleep timer: on FX Long Direct Play, swipe down → Info → Sleep 15m. The
      card reads "Sleep: 15 min left" and counts down; after 15 minutes the
      player closes by itself, the resume point is kept, and nothing plays
      next. On an episode, the next one doesn't start either.
- [ ] Guide unavailable: with the guide open, stop the QA server's Live TV
      guide (or the network) and wait for a refresh. The strip over the grid
      says the guide is unavailable, Retry can be reached with the remote,
      and after the server is back Retry fills the grid again.
- [ ] Card menu → Remove from Next Up on a show, and Add to Next Up (both
      answers) on another: Home's Next Up row changes to match, and the
      server's Next Up agrees. Run on a spare account: it changes the
      suite's baseline.

## Requests against a real Seerr server

Every automated Requests test talks to a stand-in built from Seerr 3.5.0's
source (`Tools/seerr-mock.py`). These need a real Seerr (3.4 or later, set up
for the same Jellyfin server), which the test Mac cannot run.

1. Settings → Account → Connect to Seerr…, type the address. Expect: connected
   with no password asked, and the Seerr rows showing the server and HTTPS.
   In Seerr's Users page this Jellyfin user exists and shows a recent sign-in.
2. Search for a film the library lacks: it is offered with its real poster.
   Seerr serves posters only with its "Cache Images" setting on (its
   `/imageproxy` answers 404 otherwise, and the app never asks TMDB). With it
   off, expect the "No posters from Seerr" notice on Requests and Posters: Off
   in Settings; turned on, every poster fills in on the next visit to
   Requests, your requests' included.
   On a film's, a show's, a season's and an episode's page, under More Like
   This: "Like This, Not in Your Library", from Seerr's recommendations for
   the title (for a season or an episode, its show's); titles already here
   are left out.
3. Request it. Expect "Waiting for approval" (or "On its way" for an
   auto-approved account), and the request in Seerr's own Requests page.
4. With Seerr's "CSRF protection" turned on, repeat step 3: it must still work.
5. With Jellyfin's Quick Connect turned off, connect again: the Jellyfin user
   name and password form appears instead, and signing in with it works.
6. Type the address of a Seerr behind a certificate the device doesn't trust:
   expect the "certificate couldn't be verified" refusal, not a quiet http try.
7. In Seerr, delete this user's session (or wait 30 days), then open Requests:
   it loads without asking anything.
8. Apple TV: Settings → Account → Connect to Seerr… opens a full-screen form;
   the address is typed with the on-screen keyboard or dictated, and Menu
   leaves it without connecting.

## Watch Together (SharePlay and SyncPlay)

SharePlay on the Apple TV was built on 2026-11-18 and has never run in a real
session: no simulator has FaceTime. Its orders reach mpv through the same
seam SyncPlay's do, which `TVSyncPlayTests` drives; the session itself needs
these.

1. SharePlay, started here. With a FaceTime call on the Apple TV (or one moved
   to it from an iPhone: Control Centre on the Apple TV), play a film, swipe
   down → Watch Together → Watch Together with SharePlay. Expect: the other
   person's Aquarium opens the film and both start together; the remote's
   play/pause and edge clicks move both; their pause shows "<name> paused"
   here. With no call: a message saying to start one first.
2. SharePlay, joined here. The other person (iPhone or Mac) starts it. Expect:
   the film opens on the Apple TV at their spot, held until it has a picture,
   then in step. Scrub on the Apple TV (pause, swipe, click): both jump.
3. On the starter's device, "Start from whose progress?" lists the Apple
   TV's account; picking it moves both.
4. Menu out of the player on the Apple TV: it has left SharePlay, the other
   device plays on.
5. A slow Apple TV (throttle its network): when it runs dry the others carry
   on or wait as FaceTime decides, and it rejoins where they are.
6. SyncPlay with a second device on the same server: swipe down → Watch
   Together → Watch Together with SyncPlay → Start a New Group; join from the
   other device. Same expectations as 1 and 2, with no call. Also the other
   way round: Settings → Account → SyncPlay… → Join, with nothing playing;
   the group's title opens at its spot.
7. While in a SyncPlay group the panel has no Speed tab choices to drift on
   (speed is normal), and Watch Together shows Leave SyncPlay with the
   group's name.
