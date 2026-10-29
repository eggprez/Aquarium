# iPhone Duo audit — 2026-10-22

**Update, same day:** the findings below were acted on; see "What changed" at the end. The graphic and `shots/` were refreshed with the fixed build.

Working tree on `main` at c08deb9 plus the uncommitted changes present that morning. iPhone Duo simulator (iOS 27.1, Xcode 27.1), app built with Xcode's default signing into DerivedData `Aquarium-ferbluovvhzbflargdoegnkbrswj`.

Graphic: `duo-modes.png` (modes across, pages down). Every capture is in `shots/`.

## How the poses were reached

Device Hub (the only way to move the simulator's hinge) was not available to this session, and the iPhone Duo simulator cannot be rotated by `XCUIDevice` either: it accepts the orientation but the app's window never turns. So:

- **Front** is the real thing: the Duo's outer screen, closed, 466×678 pt.
- **Tent** and **Laptop** were held with Settings › Appearance › Layout (`layout_override` = `tent` / `halfFolded`) on the outer screen, in portrait. The layouts are the ones the code picks for those poses, drawn on the wrong screen and the wrong way up: the real tent is the outer screen in landscape, the real laptop is the inner screen (951×669 pt, split at the hinge).
- **Inside** was stood in for by an iPad mini (A17 Pro) simulator, 744×1133 pt, signed in to a local test Jellyfin (`test-server.md`). The code's definition of the inside pose is "the iPad layout", so the stand-in shows the right shell, but the Duo's inner screen is 669×951 pt, about 10% narrower.
- **Book** has no pose in the code, so there was nothing to capture.

The Duo itself was signed in to the real server (the account was already on the device's keychain; the earlier unsigned build could not read it). Captures were driven by an XCUITest probe (`/private/tmp/claude-501/…/6be8f850…/scratchpad/duoprobe`, `run.sh "<script>"`), which can type, tap by label, rotate and screenshot without any UI grant.

## What each pose is for, as the code has it

| Pose | Screen | What the app becomes | Where it is decided |
| --- | --- | --- | --- |
| Front | outer, closed | a phone: tab bar, phone metrics, portrait except the guide and the player | `DevicePose.resolve` → `.front`; `RootView.adaptiveShell`; `OrientationLock.mask` |
| Inside | inner, open flat | an iPad: sidebar shell, iPad guide widths, free rotation, guide restarted on the new screen | `.inside` via hinge `fullyOpen` or regular×regular on the phone idiom; `Metrics.phoneLayout`; `TVGuideView .id(pose.usesInnerDisplay)` |
| Tent | outer, part-open, landscape | a television on a table: a cover with Continue Watching, the music that is on, and a Browse button; anything played covers it with the player; Browse lasts for the pose | `.tent` needs the hinge `partiallyOpen` and compact height; `TentIdleView`; `RootView.tentShowing` / `AppModel.tentBrowsing` |
| Laptop (half-folded) | inner, part-open, flat | picture above the crease, controls below: player (`PlayerFoldPanel`), Now Playing (art up, controls down), item pages (hero up, body down) | `.halfFolded` = `partiallyOpen` + regular width; `FoldSplit` reads `reservedRegions(kind: .division)` |
| Book | inner, part-open, upright | nothing: it resolves to half-folded | see finding 1 |

## Findings

1. **Book mode is unhandled and would break the player.** (High, code) With the hinge part-open and the inner screen on, `resolve` returns `.halfFolded` whatever way the phone is held. `FoldSplit` then stacks *upper* and *lower* vertically, taking `fold.minY` as the picture's height and `fold.height` as the crease. Held like a book the crease is vertical: `minY` is 0 and `height` is the full screen, so the picture gets no height, the crease fills the screen and the controls are pushed off it. Player, Now Playing and every item page are affected. Smallest fix: in `FoldSplit.foldRect` treat a region taller than it is wide as "no split" (fall through to the plain layout), and in `resolve` keep `.halfFolded` only when the division is horizontal. A real book layout (two pages side by side) can come later. Not verified on the simulator, which cannot be posed.
2. **Half-folded Now Playing does not split.** (Medium, observed) With the pose held at `halfFolded`, the video player and the show page split at the crease (`fold-player-chrome.jpg`, `fold-show.jpg`) but Now Playing opened as the ordinary single column (`fold-nowplaying.jpg`). `NowPlayingView` has the `pose == .halfFolded` branch, so the pose is not reaching the sheet. Worth checking whether `NowPlayingPresenter`'s `.sheet` (compact width) and `.fullScreenCover` (regular width) both carry `devicePose`.
3. **The tent cover turns dark after a video.** (Medium, observed) `tent-idle.jpg` is light; `tent-after-player.jpg`, the same cover after closing the player, is dark. The cover and the player share one `fullScreenCover`, and `PlayerScreen`'s `.preferredColorScheme(.dark)` outlives the swap to `TentIdleView`. Give `TentIdleView` an explicit `.preferredColorScheme(nil)` or scope the dark scheme to the player.
4. **Tent browsing was never seen in landscape.** (Untested) The real tent frees the outer screen to landscape, so Home, Music and item pages are shown as landscape phone pages, something the app does nowhere else. The simulator would not turn, so none of those layouts were checked.
5. **Half-folded panel clips its content at the transport.** (Low) In `fold-player-chrome.jpg` the "UP NEXT" heading is cut in half where the scroll view meets the timeline band. A bottom inset or a fade on the scroll view would make the boundary read as deliberate.
6. **The Now Playing sheet leaves a strip of the page showing along the right edge of the outer screen** (`front-nowplaying.jpg`, `fold-nowplaying.jpg`). This coincides with the simulator's status pill region on the cover display; check on hardware whether the sheet is really narrower than the screen.
7. **Live TV is two taps away on the front screen** (More › Live TV). On a cover-screen-sized phone the tab bar has Home, Music, Audiobooks, Library, More; the guide is the one page the phone is allowed to turn for, and it is the one not on the bar. Design question, not a bug.
8. **Mini player's Next button is read as "Go To Start".** (Low, any device) The forward button's accessibility label is wrong (`forward.end.fill` → "Go To Start"), seen on the iPad mini's Home with music playing.
9. **Inside: fine at iPad mini size.** Sidebar shell, guide, season page, album page, player and Now Playing all laid out correctly at 744 pt. The Duo's 669 pt is untested; the three-across shelf rows on Home are the most likely thing to wrap differently.

What worked as designed: the front pose is a normal phone; the tent cover appears only when signed in, swaps to the player when something plays and comes back when it stops; Browse leaves the cover for the rest of the pose; the half-folded player keeps the surface in place and moves the transport under the hands; the show page opens on the episode in progress in every pose.

## Fixtures left behind

- Local Jellyfin 12.2 on 127.0.0.1:8096 (data in this session's scratchpad `jf/`), user `qa`, password in `test-server.md`; libraries point at the 2026-10-18 test media plus two generated albums.
- Live TV playlist and guide served by `ruby -run -e httpd` on 127.0.0.1:8765 (`channels.m3u`, `guide.xml`, `channel.mp4`).
- The iPad mini (A17 Pro) simulator carries the signed build, signed in to the local server with the custom playlist as its Live TV source.
- The Duo's `layout_override` was put back to `automatic`.

## What changed (same day, uncommitted on `main`)

- **Book posture**: `FoldState.creaseIsVertical` is read at the root from the system's division region (`CreaseObserver` in `DevicePose.swift`); part-open with a vertical crease resolves to `.inside`, and `FoldSplit` refuses to split on a vertical crease. No two-page book layout yet.
- **Tent cover appearance**: the cover is told the app's own colour scheme once the player is gone (`RootView`), so it no longer comes back dark.
- **Half-folded Now Playing**: not a bug. A log inside the sheet showed `halfFolded`; on a tall portrait screen the split's halves coincide with the single column.
- **Half-folded panel**: the scrolling half fades into the transport band (`PlayerFoldPanel`).
- **Hero edge to edge**: `HeroHeader`'s artwork ignores the horizontal safe area on iOS and `HeroCarousel` is laid out over it (the page view keeps the safe area to itself), with the insets it covers measured and handed to the title, buttons and page dots. Shelves already scrolled under the side column; text blocks keep the safe area. Applies to Home and every item page.
- **Sideways phone hero**: on a phone wider than it is tall (the tent, browsing) the hero is 62% of the short side instead of 300 pt, so the tab bar no longer sits on Play/Details (`HeroHeader.height(forWidth:)`).
- **Inside screen = phone shell**: `RootView.adaptiveShell` gives the sidebar to the iPad idiom only. `Metrics.phoneLayout` is now "phone design language" (true on both Duo screens); new `Metrics.wideScreen` (iPad or Duo inner screen) decides the guide scale (5.5 pt/min), the channel column (172) and the hero-by-width rule. Posters stay the phone's 112 pt, so rows hold more. **Unverified on the inner screen**: Device Hub access was refused every time, so where iOS puts the tab bar on the Duo's inner screen is unknown.
- **Mini player / Now Playing forward button**: accessibility label "Next" (or "Skip forward 30 seconds").
- **Debug builds honour the Layout override without a hinge** (`DevicePose.overrideWithoutHinge`), which is how the tent was held on an iPhone SE simulator in landscape. Launch arguments work where `simctl spawn defaults` does not: `simctl launch <udid> scottai.FellyJin -layout_override tent -livetv_source custom …`.
- Builds: iOS, macOS, tvOS; `AquariumTests` 44 tests pass.

Still open: the Now Playing sheet's right-edge strip on the cover screen (check on hardware); a real book layout; the inner-screen tab bar placement.

## 2026-10-23: inner screen seen, four more changes

The Duo was opened in Device Hub, so the inner screen (951×669 pt landscape) could be captured with `simctl io <udid> screenshot --display=49F9A0CF-6780-4CF1-AA24-B61A11B4C2A3` (`shots/inner-home.jpg`, `shots/inner-player-chrome.jpg`). The phone shell is what the user wanted: iOS puts the tab bar as a vertical pill at the bottom right of the inner screen, and the hero and shelves run under it.

- **Home top bar edge to edge**: `AppTopBar`'s fill and hairline ignore the horizontal safe area, so the bar no longer stops where the page does on the cover screen.
- **Corner room on the inner screen**: `Metrics.cornerClearance` adds 12 pt to the bar's side padding when the inner screen is on, so the wordmark and the search/refresh buttons sit clear of the rounder corners and the Control Centre pill.
- **Player title row clear of the pill**: `PlayerTransport.foldableCornerClearance` (92 pt) keeps AirPlay, Picture in Picture and "…" out from under the camera pill on the cover screen and the Control Centre pill on the inner one; both had sat on the buttons.
- **Brightness rail**: `BrightnessRail` (PlayerOverlays) is a draggable vertical screen-brightness control in that trailing column, shown with the controls on a foldable only; it sets the same `ScreenLevels.brightness` the left-edge drag does and is VoiceOver-adjustable.

Not verified: the cover screen with these changes (the device was open), and the exact clearance on hardware. Reinstalling the app while the Duo was open left it unlaunchable ("Launchd job spawn failed") until `simctl uninstall` + `install`.
