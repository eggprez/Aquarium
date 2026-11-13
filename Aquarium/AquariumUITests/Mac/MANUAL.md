# Mac: what a person has to check

What the automated Mac suites (`AquariumTests/Mac`, `AquariumUITests/Mac`) cannot
reach. Each line says what to do and what should happen. Use the QA server
(`http://127.0.0.1:8196`, account `suite-mac`; fixtures in
`~/Library/Application Support/AquariumQA/FIXTURES.md`) and a Debug build launched
from Xcode, or the signed release build where a line says so.

Before starting: `python3 -I suite-reset.py suite-mac` in the QA folder.

## Display and picture

| # | Check | Expect |
|---|---|---|
| D1 | Play F:film.hdr10_mp4 on an HDR (XDR / HDR-capable external) display, AVFoundation engine. | Highlights brighter than the UI white; no washed-out grey. Stream Info (⌘I) says HDR10. |
| D2 | Same on mpv (`Settings ▸ Video ▸ Playback engine ▸ mpv`). | Picture tone-mapped or HDR, not green/purple, not washed out. |
| D3 | F:film.hlg_mkv on both engines. | Plays; colours natural. |
| D4 | Drag the player window between a Retina and a non-Retina display, and between an HDR and an SDR display, while playing. | No black frame that stays; the picture re-sizes to the new screen (the mpv 1×1-drawable bug, commit f420a3e). |
| D5 | Resize the player window quickly by its corner while an MKV plays on mpv. | The picture follows; it never goes black (commit f420a3e). |
| D6 | Full screen (F) on a second display, then Mission Control, then back. | The player stays full screen on that display; Escape leaves full screen, then a second Escape stops. |
| D7 | Unsigned/Debug build vs signed build: play F:film.hevc_mp4 on mpv, open Stream Info. | Signed build: hardware decoding (`hwdec-current` videotoolbox). Debug build reported `no` in 2026-10 (plan, phase 6). |
| D8 | "Deep Water": compare Home, a title page, a library and the guide against the design canvas (memory note ipad-design-scheme.md) in light and dark. | Radius 14 cards, no hairline, grouped sidebar (Libraries / Live / You), hero eyebrow + heavy title + white Play capsule, thumbnails at ≥ 900 pt window width, poster beside the facts, glass filter header with a count. The UI suite attaches these screenshots (`MacDeepWaterUITests.testScreensInLightAndDark`). |
| D9 | Hero Details button over a light backdrop in light mode. | White label on glass, readable (commit 9c6fb8c). |
| D10 | With Settings in front (main window not key), look at the hero. | Play is still a white capsule (commit b723cea). |

## Sleep, wake, power

| # | Check | Expect |
|---|---|---|
| S1 | Play a long film (F:film.long_direct), close the lid / Apple menu ▸ Sleep, wake after 2 min. | Paused or resumed cleanly; position on the server (`/UserItems/{id}/UserData`) is where it stopped; no error card. |
| S2 | Sleep with a download running (F:film.versions, 2160p rung), wake. | The download continues or retries by itself; the Dock badge and the sidebar badge agree. |
| S3 | Pull the power on a MacBook while mpv plays; then Low Power Mode on. | The mpv profile moves to battery (cheaper scaling) within a few seconds; picture still fine. Plug back in: quality profile. (Compile-checked only so far: plan phase 6.) |
| S4 | While playing, leave the Mac idle past the display-sleep time. | The display does not sleep while playing; it does once paused. |
| S5 | Leave the app in the background for > 5 min, then click its Dock icon. | The page in front refreshes once (MacAppDelegate's return-to-app refresh). |

## Now Playing, media keys, system UI

| # | Check | Expect |
|---|---|---|
| N1 | Play a film; open Control Centre ▸ Now Playing. | Title, artwork, position; play/pause and ±skip work. |
| N2 | Keyboard media keys (F7/F8/F9) and AirPods/headphone controls. | Play/pause, skip. |
| N3 | Picture in Picture from the Playback menu (P) on AVFoundation, and on mpv (hand-over to AVPlayer). | A floating picture; the player window is put away, not black. Clicking the sidebar's Now Playing strip during PiP does nothing (commit 430f7d6); the PiP window's own button brings the player back. |
| N4 | AirPlay to an Apple TV from the player. | Picture moves; the Mac's window shows the AirPlay placeholder. |
| N5 | SharePlay: "Watch Together with SharePlay" in a FaceTime call. | The session starts; the other side follows play/pause. |
| N6 | Handoff: start a film on the Mac, look at an iPhone's app switcher. | The Aquarium Handoff banner; opening it resumes at the Mac's position. |
| N7 | Spotlight: search for a title Home has shown. | It is listed; choosing it opens the title page. (Test mode does not write Spotlight, so only a normal launch shows this.) |

## Dock and Finder

| # | Check | Expect |
|---|---|---|
| K1 | Right-click the Dock icon after Home has loaded. | "Continue Watching" heading, up to five titles (episodes as "Show — S1E2 · Name"), then Search. Choosing a title plays it; Search focuses the sidebar's field. |
| K2 | Close the main window with a title window open; click the Dock icon. | The main window comes back (commit 9c6fb8c). XCUITest can't click the Dock. |
| K3 | Queue three downloads; watch the Dock icon; close the main window; sign out. | Badge counts transfers left; it stays right with the window closed and clears on sign-out (commit a016c37). |
| K4 | Go ▸ Show Downloads in Finder (⌥⌘R); a downloaded film's "Show in Finder"; a show's. | Finder opens the downloads folder / selects the file / the show's folder. Not automated: it drives Finder. |
| K5 | With the main window closed and only a title window open, cause an error (e.g. stop the QA server and press Favorite). | An NSAlert appears (MacAppDelegate.watchAlerts); OK dismisses it. |

## Network and security

| # | Check | Expect |
|---|---|---|
| T1 | Sign in to an HTTPS server with a valid public certificate; play an MKV on mpv. | Plays. |
| T2 | Same with a self-signed / private-CA certificate. | AVFoundation per the system trust; mpv refuses (tls-verify=yes, bundled roots) — known limitation (memory note mpv-tls-verification.md). |
| T3 | The QA throttle proxy (8098) at 3 Mbps: play F:film.long_multitrack. | Auto quality steps down; no hang (below ~2.6 Mbps the proxy itself can hang — not an app bug). |
| T4 | Kill the network mid-film on mpv (Wi-Fi off 30 s). | Open bug (master fix list, fix fe83c5b unmerged): mpv's EOF on a dropout may be treated as the end of the title — marked watched, next episode starts. Expected: a stall and a retry. |

## Account menu

| # | Check | Expect |
|---|---|---|
| A1 | Click the account row at the foot of the sidebar. | A menu: the saved accounts (with a second one added, "Switch Account"), Add Account…, Settings…, Sign Out…. Sign Out asks first; Cancel keeps you in. XCUITest opens it and chooses from it by typing (`MacSignInUITests.testAccountMenuOffersAddSettingsAndSignOut`) but can't see its items: look at the list itself. |
| A2 | Type a title into the sidebar's search field and press Return; clear the field and look at what drops down. | The Search page with results; the term is listed under the empty field. (Return did nothing until 2026-11-13, fixed on `claude/fix-mac`; the recents list is a pop-up XCUITest can't see.) |
| A3 | Coming from Favorites, click a library row where a title page was left open, then click that row again. | First click: the title page is still there. Second click: the library's top. Automated since 2026-11-13; worth a look with a trackpad's tap-to-click too. |
| A4 | Play a film, click in the player window, press Escape; play again, F, Escape, Escape. | Escape stops playback and the window closes; in full screen the first Escape leaves full screen, the second stops. Automated since 2026-11-13. |
| A5 | Turn VoiceOver on (⌘F5), open the sign-in sheet's Quick Connect, and move over the code. | VoiceOver reads "Quick Connect code" and the digits; the app doesn't crash (it crashed under XCUITest's accessibility queries until 2026-11-13, when the code was a selectable Text). |

## Things the UI runner can't do on a Mac

- Clipboard: guide ▸ Copy Title, item ▸ Copy Title. Paste into TextEdit: the title, nothing else.
- Context menus on the Dock, Finder, the PiP window.
- Window restoration across a real quit/relaunch with the system's "Close windows when quitting" setting off.
- Drag a library window to another Space; ⌘` between windows.
- Accessibility: VoiceOver through Home, a title page and the player; the thumbnail size buttons read "Smaller" and "Bigger" (commit 6704c21).
- See what pop-up menus from buttons in a window list (Download, the account row, Quality): XCUITest on macOS 27 doesn't have their items in its tree, so the tests choose from them by typing and check the result.
- The search field's recent terms: the drop-down list is a pop-up XCUITest can't see.
- Not enough disk space: fill a disk image to near full, set the downloads there, ask for a 2160p download — the alert lists the rungs that fit; Return takes the first.
