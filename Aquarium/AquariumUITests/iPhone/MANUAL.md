# iPhone: what only hardware (or a person) can check

The automated iPhone suite (this folder and `AquariumTests/iPhone/`) runs on
the four test simulators. What follows cannot be driven from XCUITest on a
simulator, or cannot be judged there. Each entry says what to do and what to
expect. Sources are in brackets.

## CarPlay

The CarPlay scene (`Music/CarPlayScene.swift`) is CPTemplates, which carry no
accessibility identifiers and have no simulator driver in XCUITest.

1. Connect to a CarPlay head unit (or Xcode's CarPlay Simulator window).
2. Open Aquarium: the Music, Audiobooks and (dormant) Video tabs appear.
   Video stays off: the `carplay-video` entitlement blanks the CarPlay screen
   (iOS bug, memory `carplay-video-blank-screen`). Check the app is signed
   **without** that entitlement and CarPlay is not blank.
3. Play an album, a station and an audiobook; Now Playing shows the title,
   art and a running clock; the clock stops while buffering
   [R-f72bd13c: `nowPlayingRate` 0 while buffering].
4. Next on the last song of an album stops or moves to the mix, never
   repeats the last song [R-f72bd13a].

## The real iPhone Duo

Simulator coverage is in `DuoPoseTests` (front screen; tent and laptop held by
`-layout_override`). The hinge itself is moved only in Device Hub or by hand.

- **Fold and unfold mid-use.** Open, scroll Home's hero, close, reopen:
  the inner screen must rotate freely and not stay portrait
  [memory `duo-orientation-rules`, PR 34, a8604d2].
- **Fresh launch closed, then open**: the inner screen comes up in the
  orientation it is held and rotates [ffa3cce].
- **Front camera clearance**: on the front screen in landscape, "…",
  Picture in Picture and AirPlay sit just clear of the lens, not shoved left
  by the 84 pt column [memory `duo-front-camera-clearance`; 89c1c6c].
- **Book pose** (part open, upright): title page and player are not split
  [db310b3].
- **Laptop pose** on the inner screen: player above, fold panel below,
  chapter pills work [memory `duo-simulator-poses`].
- **Tent**: the idle cover is landscape, keeps the app's appearance after a
  video [db310b3], and Browse leaves it.
- **Hold-for-2× through a fold**: hold the picture, fold; playback returns to
  normal speed [6c8b98f].
- **Keyboard on fold**: search, fold; the keyboard does not rise on the
  other screen [811adab].
- **Dead touch strip**: on the front screen, a tap 14–22 pt from the top
  does nothing; every bar's buttons sit below 24 pt [memory
  `duo-inner-status-strip`].
- **Fading controls**: tap "…" or AirPlay just as the controls fade (4 s after
  the last touch) on the front screen in landscape; the card opens
  [memory `player-fade-dead-buttons`, 58f77cf: confirmed on the simulator
  only].

## AirPlay

The route picker is system UI with no identifiers (TESTING.md known gaps).

1. Play a film, tap AirPlay, choose an Apple TV: the picture moves, the
   phone shows the AirPlay placeholder, pause and seek work from the phone.
2. Same for a song from Now Playing.
3. Picture in Picture and SharePlay both need AVFoundation: an mpv title
   switches engine first (`EnginePolicyTests.testPictureInPictureAirPlayAndSharePlayNeedApple`).

## Picture in Picture

The iPhone simulator reports PiP unsupported (memory
`pip-simulator-testing`); `PhonePlayerTests.testPictureInPictureButtonFollowsSupport`
skips there. On a phone: play, swipe home, the PiP window plays on; return,
the player is back where it was.

## Real network loss

`PhoneOfflineTests` and `PhoneDownloadQueueTests` take the server away, slow
it and make it refuse downloads through `Tools/qa-switch-proxy.py`; a real
drop behaves differently (timeouts, half-finished segments), and these still
want a person:

- Wi-Fi off mid-film (direct play and transcode): the stream stalls, the
  error card offers Try again and Try a smaller stream; Try again after the
  network returns plays [R-tryAgain: open on main, `PlayerModel.retry`
  leaves a paused player paused].
- Server unplugged while browsing: the strip appears only once a request
  fails (the tests press Home's reload to make one); check how long an idle
  page takes to notice, and that the strip's own Retry recovers (the strip is
  one combined element to XCUITest, so its button cannot be pressed alone).
- A download cut mid-transfer by the network (not refused): it goes back to
  the queue with "trying again" and its wait, five times at 5 s to 5 min,
  before it is listed as failed. Too slow for the suite; the failed rows are
  tested with a refusal (410) instead.
- A transfer's "The first copy arrived incomplete" and "Waiting for the
  server to encode the start" notes.
- The "Delete …?" question on a phone is a popover with one button and no
  Cancel; check that tapping outside it is an obvious enough way to say no.
- The Downloads page's Apple Watch door and its Sync (needs a paired watch).
- Slow link through the throttle proxy (8098 at ~2 Mbps; it hangs below
  ~2.6 Mbps, memory `qa-rproxy-low-rate-hang`): Auto steps down and the
  bitrate badge shows [5095d5e]; a direct-play file that cannot keep up says
  so [aa2c9b3: open on main].

## Background downloads after swipe-away

iOS cancels every background download when the app is swiped away; a
`simctl terminate` does not (memory `swipe-away-cancels-downloads`).

1. Queue a season (transcoded) and six songs.
2. Swipe the app away from the app switcher mid-transfer; reopen.
3. Every row says "Interrupted — picking it back up" and resumes; nothing
   vanishes, nothing stays frozen; with Parallel downloads = 1 the queue
   still moves [ea2920f, `reapGhosts`, `requeueLostRecords`].
4. Lock the phone unplugged while a stream download runs: it keeps fetching
   segments (not only the playlist) [6f48d40: never discretionary]; an
   episode started from the background resumes 4 s after the app comes
   forward [df8f40a, `restartDemotedTransfers`].
5. Stop the system download Live Activity: the queue pauses, it is not
   cancelled [0c55b9a].

## Thermal behaviour

- Play a 4K HEVC title for 20 minutes on a warm phone: when the thermal
  state reaches Serious, Auto quality steps down and the engine draws more
  cheaply (`EnginePolicyTests.testThermalPressureWinsOverEverything` covers
  the rule; the trigger is hardware only).
- Low Power Mode on: an original over the cap is stepped to it
  (`AdaptiveQualityTests.testLowPowerStepsAnOriginalOverTheCapStraightToIt`).

## Lock screen, Live Activities, widgets

The suite unit-tests the snapshot and state the extensions read
(`PhoneWidgetTests`). On a phone:

- Lock while a song plays: the lock-screen card shows title and art; play,
  pause, skip work; the clock does not run while buffering.
- An audiobook with a sleep timer: the Live Activity shows the timer and its
  +15 / cancel buttons work.
- A film with an intro: the activity offers "Skip intro".
- Force-quit while playing: on relaunch the Now Playing widget reads paused
  [f72bd13, `settleStaleNowPlaying`].

## Other hardware-only items

- The player closing at 4:26 on South Park S29E03 (iPhone only, not
  reproduced on any simulator; memory `player-closes-at-426`): play past
  4:26 with `log stream` on and read the `finish:` reason.
- A whole-file download AVFoundation refuses on the phone (10-bit H.264)
  plays on mpv [8f01dba]; the simulator decodes those in software.
- Downloads separated by account [R-18P10, low confidence].
- mpv on a private-CA HTTPS server fails (by design, memory
  `mpv-tls-verification`); on a public certificate it plays.
- SharePlay "Watch Together" with a FaceTime call.

## What the 2026-11-14 logic tests could not reach

- Music: an interruption (a call) and unplugging headphones; the lock-screen
  and CarPlay card and its artwork; ReplayGain levelling; gapless joins on
  streamed tracks; the lossless-on-cellular cap; a followed playlist
  downloading its new song; a real sleep timer running out.
- Downloads on a real phone: Wi-Fi only on actual cellular; a relaunch while
  transfers finish in the background; a stalled transfer (three minutes of
  silence) being restarted.
- The library copy: Home and Search still filled after a relaunch and on an
  offline launch.
- Lock-screen, Control Centre, headphone and media-key commands for video.
- Siri and Shortcuts end to end: the spoken reply and the "carry on or start
  over" question.
- The Follow and Now Playing widgets as drawn, and the widget's Edit picker.
- The seasonal icon offered in Settings on a date inside its window.

## Typing a password on the sign-in form

On the iOS 27.0 simulator XCUITest cannot type into the password field
(neither a tap on it nor the form's own move to it from Sign In gives it the
keyboard), so `PhoneSignInTests` skips the password, wrong-password,
disabled-account and add-account cases there; the app's own sign-in path is
exercised by every test's launch, and the requests by
`PhoneSignInClientTests`. By hand: type a name and password and Sign in
(Home appears); a wrong password and `fx-disabled` show an error and stay;
Settings › Account › Add Account adds `suite-spare1` and the accounts list
switches back. Check also that tapping the password field gives it the
keyboard (if it does not on hardware either, that is a bug).

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
   in Settings. Turn it on, then pull to refresh Requests or run a new
   search: every poster fills in, your requests' and the search row's (seen 2026-11-16 on a real server: the ones
   already seen stayed blank until this was fixed).
3. Request it. Expect "Waiting for approval" (or "On its way" for an
   auto-approved account), and the request in Seerr's own Requests page.
4. With Seerr's "CSRF protection" turned on, repeat step 3: it must still work.
5. With Jellyfin's Quick Connect turned off, connect again: the Jellyfin user
   name and password form appears instead, and signing in with it works.
6. Type the address of a Seerr behind a certificate the device doesn't trust:
   expect the "certificate couldn't be verified" refusal, not a quiet http try.
7. In Seerr, delete this user's session (or wait 30 days), then open Requests:
   it loads without asking anything.
8. A collection whose Jellyfin entry has a TMDB id (the QA library has none):
   its page lists "Missing From This Collection" with the films not yet here.
