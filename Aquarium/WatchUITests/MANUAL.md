# Apple Watch: what only real hardware shows

The automated suite (`WatchTests/`, `WatchUITests/`, `AquariumTests/Shared/WatchPhoneLinkTests.swift`)
runs on simulators. These checks need a real iPhone and Apple Watch, because the
simulator either cannot do them or does them differently from a wrist. Each says
why, what to do, and what passing looks like. Write the date, build and result
beside the check when you run it.

Before starting: install the same build on the iPhone and the watch (from Xcode,
or TestFlight), sign the iPhone in to the QA server as `suite-watch`
(`~/Library/Application Support/AquariumQA/suite-accounts.txt`), and run
`python3 -I suite-reset.py suite-watch` in the QA folder. Logs: on the iPhone,
Settings › Apple Watch › Diagnostics › Fetch Log from Watch; pull them with
`xcrun devicectl device copy from … --domain-identifier scottai.FellyJin --source Documents/WatchLogs/<file>`
(see the memory note `watch-network-reality.md`).

## 1. Phone-to-watch file transfer (the main Download to Watch route)

**Why not automated:** in the paired simulator `WCSession.transferFile` never
reaches the watch app: the phone logs the file delivered, `wcd` on the watch logs
the bytes, and `session(_:didReceive:)` never fires (0 of 33 in the 2026-11-02
pass). Messages, application context and replies do work in the simulator, and
the unit tests cover what the watch does with a file once it has one
(`WatchDownloadsTests.testAFileFromThePhoneTakesTheAudioFilesPlace`,
`WatchLinkTests.testPiecesJoinInOrderWhicheverOrderTheyArrive`).

1. On the iPhone, open FX Compilation and choose Download to Apple Watch.
   Expect: Settings › Apple Watch › Kept on the Watch lists it as "Waiting for the
   watch", then "0 of 4 on the watch", then "On the watch".
2. Watch: On Watch shows FX Compilation, 4 songs; each song's corner shows the
   green tick. Play one with the phone in another room: it plays from the watch.
3. A book over 16 MB (a real audiobook; the QA book is 5.6 MB, so add one or use
   your own server): Download to Apple Watch on the iPhone. Expect the transfer
   in pieces (the phone's Transfers page shows the send moving), the book on the
   watch afterwards, and its length right (the watch measures it on arrival).
4. Cancel a transfer by hand on the phone's Transfers page. Expect it gone from
   the watch's queue too, and not asked for again on the next pass.
5. Kill both apps mid-transfer (swipe away), reopen both. Expect the transfer to
   pick up (the wants list and the relay's resume), not start over or vanish.

## 2. The real watch's network

**Why not automated:** on a watch `NWPathMonitor` reports "down" all day even
with Wi-Fi listed, and the path through the phone reports itself as Wi-Fi; the
watch's own requests to the server work for a while, then time out or fail TLS
for hours (memory `watch-network-reality.md`). The simulator's network is always
up through the Mac. The unit tests pin the path monitor's word
(`testWithThePathMonitorDownTheWatchNeverTakesItBack`,
`testThePathMonitorsWordAloneNeverTakesBackFromThePhone`).

1. With the phone app installed, queue 20 songs from the watch's own album page.
   Leave the watch on the wrist for an hour, raising it now and then. Expect
   every song to arrive through the phone; the phone's log has no burst of
   `cancelFetch` (the 1,418-cancel bug, commit 05ce303).
2. Fetch the watch log afterwards. Expect "network: down" lines and no "fetching
   it here" lines while the phone was in reach.
3. Put the phone in another room (out of Bluetooth range) with Wi-Fi on the
   watch. After 20 minutes, expect the watch to take items back and fetch them
   itself ("the phone has been away N min; fetching it here").
4. Settings › Server on the watch: note what it says while the watch's own
   requests are failing. It should say "Out of reach" when they time out or fail
   TLS, "Sign-in expired" when the server answers 401, never "Connected"
   (`WatchClientTests.testSettingsDoesNotSayConnectedWhileTheSignInIsRefused`).
5. Server recovery: with the watch app open on "Server out of reach", bring the
   server back. On this branch the home page stays "out of reach" until the app
   returns to the foreground or Sync Now (master fix list); the fix branch asks
   every 30 s while on screen. Note which you see and how long it takes.

## 3. The path monitor always reporting down

1. Watch log, any day of normal use: expect "network: down via …" on almost
   every launch. Kept playlists (switched on in iPhone Settings › Apple Watch)
   must still arrive: the mirror does not wait on the path monitor (commit
   c08deb9). Switch one on and wait; expect its songs queued on the watch within
   a minute of the watch app next opening.

## 4. Background audio and Bluetooth headphones

**Why not automated:** watchOS long-form audio asks for a Bluetooth route on a
real watch (the route picker); the simulator plays through the Mac.

1. With no headphones paired, press Play on a book. Expect the route picker; if
   dismissed, the player shows "Choose where to play, then try again".
2. With AirPods: play a book, lower the wrist for 10 minutes. Expect it to keep
   playing, and the Now Playing app/complication to show it.
3. Take the AirPods out. Expect a pause (system pause, not counted as a user
   pause). Put them back and press play; it resumes from the same place.
4. A phone call or Siri during playback: expect a pause and a resume after
   (`.shouldResume`).
5. The Digital Crown on Now Playing sets the watch's volume; the level bar shows
   beside the crown only while it moves. On the iPhone remote page the crown
   sets the phone's volume.
6. Book place across a lowered wrist: play to 1:27 (inside the first five
   minutes), lower the wrist, wait a minute, open the book again. Expect 1:27
   (the server stores 0 this early). On this branch the server's 0 can win:
   `WatchBookPlaceTests.testABooksEarlyPlaceSurvivesTheServersZero` (expected
   failure, fixed on `claude/qa-fix-list-cb0b58`).

## 5. Complications and the Smart Stack on a real face

**Why not automated:** the widget extension is drawn by the system on a watch
face; XCUITest cannot reach a face, and the simulator's face editor is unreliable.
The unit tests cover what the app writes for the widget
(`WatchWidgetSnapshotTests`) and what its taps open (`WatchActionsTests`).

1. Add "Aquarium" to a face in each family: rectangular (Smart Stack / Modular),
   circular, corner, inline.
2. Nothing played yet: rectangular shows "Aquarium / Nothing playing"; circular a
   waveform; inline "Aquarium".
3. Play a book, pause it at about a third. Expect: rectangular shows the title,
   the chapter, and a bar about a third along; circular a gauge about a third
   full with a book glyph; corner the gauge with the title; inline the title.
4. Tap each: the app opens and plays that book (`aquarium://play/<id>`); with
   nothing in the snapshot, Resume (`aquarium://resume`).
5. Let a book play for 10 minutes: the card's bar moves in steps (it redraws at
   most once a minute or a hundredth of the book, `worthRedrawing`), not every
   five seconds.

## 6. Battery

1. Charge to 100%. Play a 2-hour downloaded book over AirPods with the wrist down.
   Note the battery afterwards (and the watch log's memory lines).
2. Leave 200 songs queued with the phone in reach overnight. Note the battery in
   the morning; the background refresh is every 30 minutes with work queued,
   2 hours otherwise (`WatchDelegate.scheduleRefresh`).

## 7. Other real-device-only checks

- **Siri and Shortcuts:** "Resume my audiobook in Aquarium", "Play FX Chaptered
  Audiobook in Aquarium", "Play FX Compilation in Aquarium", "Shuffle my music in
  Aquarium". Expect each to open the app and play. With no book in progress,
  "Resume" says "There's no audiobook to resume." The intents' code is unit-tested
  (`WatchIntentsTests`); the phrases need Siri.
- **Background refresh and background URLSession wakes** (`WatchDelegate.handle`):
  queue a download, lower the wrist, wait. Expect the file to arrive without
  raising the wrist, and the log's "background wake let go" lines.
- **Sign-in hand-off:** sign the iPhone out and in again as another account. Expect
  the watch to follow within a minute of opening it (application context), and
  queued listening from the first account not to go under the second.
- **Idle player's Resume Audiobook with no book in progress:** on this branch it
  does nothing and says nothing (master fix list; `WatchActionsTests.testResumeWithNoBookSaysThereIsNone`
  checks the action returns false). The fix branch shows "No audiobook in progress".
- **40 mm layout:** the smallest watch's book player and word breaks (master fix
  list "Layout, 40 mm"). Run the UI suite on a 40 mm simulator for a first look:
  `AQUARIUM_TEST_WATCH="Aquarium Test Watch 40mm"` with a 40 mm device made by hand.
