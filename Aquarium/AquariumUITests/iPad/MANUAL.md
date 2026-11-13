# iPad: what only hardware (or a person) can show

The automated iPad suite (`Tools/run-tests.sh ipad`, the `Pad*` classes in this
folder and in `AquariumTests/iPad/`) runs on the "Aquarium Test iPad Air 11"
simulator. Everything below is out of its reach: either the simulator cannot
do it, XCUITest cannot drive it, or the result is a look or a feel rather than
a state a test can read. Each item says what to do and what should happen.
Where it guards a past bug, the source is named.

Run these on a real iPad (ideally an 11-inch and a 13-inch, one with a Magic
Keyboard or trackpad, one with an Apple Pencil), signed in to the QA server or
a real server, in both orientations and both themes.

## Stage Manager, windows and Split View

The test simulator shows the app full screen (its multitasking mode does not
put apps in windows), so `PadWindowSizeTests` skips, and Split View beside
another app cannot be set up from XCUITest at all.

| Check | What should happen | Source |
|---|---|---|
| Narrow a Stage Manager window (or a Split View third) to phone width, then widen it again | Below compact width the tab bar replaces the sidebar and the page you were on stays; widened, the sidebar comes back with its row lit. **Known open bug on main:** the sidebar does not come back, and Settings, Music, Live TV and Downloads become unreachable until relaunch | ipad-qa-findings.md bug 4; fix 3e83bd4 is only on `claude/qa-fix-list-cb0b58` |
| Narrow straight to a medium width (about 700 pt) | Sidebar stays | ipad-qa-findings.md |
| In a window smaller than the screen, look at the top-leading corner on Home, a title page, Settings and the player | The window's close / minimise / full-screen buttons never sit on Back, the sidebar toggle or the account avatar; a tap just right of them goes Back | master-fix-list "Window controls sit on the back button"; player fixed a6fcf5c (QA W1, 52 pt inset); bars fixed 4775e86 (not on main) |
| Resize a window while a video plays, down to about 375 × 500 | Playback continues, pills drop to glyphs, Quality / More / Up Next cards and Info fit | qa-2026-11-11-player REPORT, "Resized iPad window" |
| Two Aquarium windows side by side (Stage Manager, or drag a title to the edge) | Each window keeps its own section and stack; playing in one does not break the other | not designed for; record what happens |
| Settings in a window between 610 and 720 pt wide | One column (the phone's list); at 720 pt and more, the list and the page side by side | 6344432 |
| Rotate during each of the above | No black band over the lower page after the first rotation | ipad-qa-findings.md bug 12 (not reproduced since) |

## External display

| Check | What should happen |
|---|---|
| Connect a display (USB-C or AirPlay mirroring) and play a film | The video goes full screen on the display; the iPad shows the controls or mirrors, without the picture stretched |
| Stage Manager on an external display: an Aquarium window there | Sidebar, hero and grids lay out for that window's size (hero 2.4:1, capped at 560 pt tall) |
| Disconnect mid-play | Playback continues on the iPad |

## Keyboard (Magic Keyboard, Smart Keyboard)

The app defines no iPad keyboard shortcuts of its own (its shortcuts are
macOS-only); `PadKeyboardTests` covers Return, Tab and Escape.

| Check | What should happen |
|---|---|
| Hold ⌘ on Home, a title page and in the player | The system's shortcut overlay lists only system commands; nothing the app promises is missing |
| Space, arrows in the player | Not implemented on iOS (no shortcut). Record whether anything happens |
| Tab / arrow-key focus through the sidebar rows (Full Keyboard Access on) | Every row, the Search row and the gear can be reached and opened |

## Trackpad and mouse (pointer)

XCUITest cannot hover on iOS, so none of this is automated.

| Check | What should happen |
|---|---|
| Hover over sidebar rows, poster cards, the hero's thumbnails and the player's pills | The pointer takes each control's shape and a highlight; nothing is unreachable by pointer |
| Secondary click (two-finger click) on a card, a season chip, a song | The same press-and-hold menu as a long press (`PadContextMenuTests` covers the long press) |
| Move the pointer over the playing picture | The controls come up; they hide again after 4 s still (the Mac's pointer clock is macOS-only, so check the iPad's behaviour is sensible) |
| Two-finger scroll on Home's shelves and the hero | Shelves scroll sideways; the hero pages |
| Drag the timeline with the pointer | Scrubs with the trickplay thumbnail and the chapter name above the thumb |

## Apple Pencil

| Check | What should happen |
|---|---|
| Tap sidebar rows, cards, pills, the timeline with the Pencil | Same as a finger |
| Hover with an M2-or-later iPad and Pencil 2 / Pro | Same highlights as the pointer |
| Scribble into Search, the library's name filter, the sign-in fields | Handwriting becomes text; Search runs on Return |

## The mpv engine

mpv cannot be chosen on an iPad: `Preferences.pinSettingsNotOfferedHere` sets
the engine back to Automatic at every launch, so a simulator run is always
AVFoundation (`PadPlayerInfoTests.testMpvPreferenceIsPinnedToTheAppleEngineOnIPad`
checks that pin). On a real iPad, mpv is reached only through the engine
policy, by a file AVPlayer cannot play.

| Check | What should happen | Source |
|---|---|---|
| Play `film.dts_mkv` and `film.truehd_mkv` (QA server) | Info's Engine row reads "mpv · hardware decoding (videotoolbox)"; sound plays | ipad-qa-driving.md |
| An ASS subtitle (`film.long_multitrack`, French ASS) on a server transcode | Shows on first pick, at the foot of the picture | QA 2026-11-11 N3 |
| Picture in Picture on mpv with Fill on | A 16:9 window with the subtitle in it; Fill comes back when PiP closes | QA 2026-11-11 N2 |
| Connection drop on mpv (turn Wi-Fi off past the buffer) | "Can't reach" card over the right episode; Try again resumes where it stopped; the episode is not marked watched | master-fix-list "Dropout as end of episode" (TV); iPad not run |

## Picture in Picture, deeper

`PadPictureInPictureTests` starts and stops PiP from the button and checks
playback continues in the background. By hand:

| Check | What should happen | Source |
|---|---|---|
| PiP window position | It does not land on the AirPlay / PiP / "…" buttons | QA 2026-11-11 smaller issues |
| Return to the app while PiP is up | The video comes back into the player (today it stays in PiP until "Leave Picture in Picture"; recorded as a design choice) | QA 2026-11-11 |
| Close PiP with its own close button | Returns to the player paused, position saved | ipad-qa-findings.md |

## Timing-dependent player checks

| Check | How | Source |
|---|---|---|
| A tap on a pill or "…" just as the controls fade still works | Tap the picture, wait about 4.45 s, tap a pill: the card opens rather than the controls coming back | player-fade-dead-buttons.md, 58f77cf |
| Sleep timer firing while the Up Next card is up | 15-minute timer on an episode near its end: the player closes without a crash | ipad-qa-findings.md bug 1 (route not run since the fix) |
| Hold for 2× | Long-press the picture: 2× badge; release returns to the speed set | |
| Pinch to fill | Pinch the picture: Fill toggles both ways | QA 2026-11-11 (scripted pinch did not register) |

## Look and feel (visual checks)

| Check | Source |
|---|---|
| Hero backdrop cropped from near the top, faces not cut at the brow | c643527 (hero-crop-focus) |
| Hero art present offline (library copy saved the backdrop at the hero's width) | 6344432 |
| Light theme: the "FEATURED" eyebrow reads over bright artwork | master-fix-list iPad |
| Largest Dynamic Type: sidebar rows, hero search/refresh, title actions do not overlap or truncate to "Fa…" | master-fix-list iPad (fix 4775e86 not on main) |
| No empty poster tiles for items with no art; cast without a photo gets a figure | master-fix-list iPad |
| Ambient colour wash under a title page's header; glass bars over content; no card hairline | ipad-design-scheme.md |
| Info popover readable over a bright picture | QA 2026-11-11 |
| Settings' two columns: the page heading pinned, rows never slide under a see-through bar | 6344432, 30cbbc2 |
| Portrait episodes on a 13-inch: one across or two (design record says two) | master-fix-list "user's call" |

## Hardware-only services

AirPlay (no route picker in the simulator), SharePlay in a FaceTime call,
Handoff to and from a Mac or iPhone, Siri and Shortcuts, Control Centre and the
lock screen's Now Playing (skip and scrub), haptics, and real network loss
(Wi-Fi off rather than a killed proxy).
