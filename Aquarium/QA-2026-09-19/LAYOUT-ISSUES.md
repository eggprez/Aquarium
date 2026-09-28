# FellyJin layout / visual issue catalogue — 2026-09-19

Nothing was fixed. This is a list of what was seen, where the evidence is, and (clearly labelled) guesses at cause.

## How this was gathered

- Build: Debug, current source, iOS 26.5 simulators. Real data from the demo server (`media.bindel.glass`) plus the local mock for the first pass.
- Devices, portrait, shown **left to right** in every composite screenshot unless noted:
  **iPhone 17 Pro · iPhone 17e · iPhone 13 mini (375×812) · iPhone SE 3rd gen (375×667)**.
- iPad Pro 11", iPad mini (A17 Pro), iPad (A16): Home only, portrait (`ipads-home.png`).
- Driven by XCUITest (`tools/ios-ui-probe`-style journeys) + `simctl` screenshots; a few by hand through the simulator tool.
- Screenshots are in `screenshots/`. File names below refer to them.

**Caveats that matter when reading the evidence**

1. The 17 Pro was in **Dark** appearance; the other three were in **Light**. Some differences between "Pro" and "the rest" may be appearance, not size. Worth re-running the four in the same appearance before trusting a Pro-vs-others comparison.
2. Simulator artefacts I'm aware of: the volume slider on Now Playing (`MPVolumeView`) often draws nothing in the simulator; the "Kept in /Users/scott/…" path is simulator-only.
3. iPhone shell is **portrait-locked by design** (`Core/Orientation.swift`); only the player and the TV guide rotate. So "landscape" here means those two screens only.
4. Severity: **H** = broken/unusable, **M** = clearly wrong-looking, **L** = polish.

---

## A. Reported issues — reproduced

### A1. Search field doesn't appear until you pull down (H)
Evidence: `X-27-more-Search.png` (initial), `W-search-pulled.png` (after pull-down).
- Search opened from More → Search. **17 Pro and SE:** no field at all on first show. **17e and 13 mini:** an *empty grey pill* — no magnifier, no placeholder text. After pulling down, all four show the full field ("Movies, shows, music, books").
- So it's not "missing", it's laid out but not visible/positioned until the first scroll/pull.
- Source to look at: `Views/SearchView.swift:107-108` — `.searchable(… placement: .toolbar …)` on a `ScrollView` root, together with `.screenTitle("Search")` (large title) and `.paletteBar()` (opaque `toolbarBackground`). *Guess:* the search bar lives in the large-title nav bar and its first layout is done before the scroll view reports its offset/inset, so the bar starts collapsed.
- Search is only reachable through **More** on the default tab order (5 slots: Home, Downloads, Music, Audiobooks, More), so this is the path most people hit.
- Once focused, results/keyboard behave (`W-search-results.png`); back button and title correctly collapse.

### A2. Press-and-hold menu on TV episodes looks wrong (M–H)
Evidence: `Z-05-ctx-menu.png`, `Z-06-ctx-download-sub.png`, `p-ctx-real.png`, `Y-04-season-episodes.png`.
Long-press on episode 1 of a season (Abbott Elementary, and The Acolyte on the real server):
1. **Menu is not attached to the pressed row.** On the 17 Pro the menu is drawn over episodes 2–4 while the pressed row (Pilot) shows no lift/highlight (`Z-05`, pane 1). On the real Acolyte page the menu sits above the row, on top of the hero art (`p-ctx-real.png`).
2. **"Go to Abbott Elementary" wraps to two lines** on all four devices (long show names will always wrap; the menu width is fixed narrow).
3. **Download submenu is a ghost stack.** Opening "Download ›" leaves the parent menu (Play / Go to …) visible, dimmed, *behind and above* the submenu (`Z-06` panes 1, 2, 4) — two panels overlap and text from both bleeds together (17e: "1440p · 18 Mbps" overlaps the faded "Download" row).
4. **Submenu is taller than the space and collides with the floating tab bar.** On the SE the 480p row is under/behind the tab bar ("Hor…", "…ore" showing through the menu), and the pressed row is pushed up to the very top of the screen, partly under the status area (`Z-06` pane 4).
5. Rows in the menu have inconsistent line heights (two-line entries next to one-line entries), which makes the menu look uneven.
- Source: `Views/ItemContextMenu.swift` (menu + preview), episode row in `Views/ItemDetailView.swift`.

### A3. Media player elements (M) — reported as "elements in the media player"
Evidence: `P-pl-controls.png` (landscape, loading), plus captures from the 17 Pro and SE landscape runs.
1. **Title overlaps the centre transport control while loading.** "Beauty and the Beast" / "Rogue One: A Star Wars Story" is drawn straight across the spinner + pause button; the 10-second skip buttons sit at the same height, so the row reads as a collision. Time labels show `--:--:--` / `--:--` placeholders at the same moment.
2. **Bottom-right cluster is inconsistent.** 17 Pro shows three icons (speed, subtitles, "…"); SE shows two (speed, subtitles). Could be per-title (no subtitles) — needs a like-for-like check.
3. **The extras popover (Audio sync / Sleep / Fill the screen) opens at top-centre**, not next to the button that opened it (top gear is left of centre). SE landscape capture. *Check whether the anchor is being lost on rotate.*
4. **Quality menu** ("Direct Play (original), 36 Mbps 4K …") is a plain list floating over video with no dimming; fine, but it sits under the top row on the SE with very little margin.
5. Portrait player was not captured cleanly (rotation raced my capture) — see "Not covered".

---

## B. New issues found

### B1. Screens open already scrolled ("first row missing") — intermittent (M)
Evidence: `X-17-more-Movies.png` (17e, 13 mini start below the filter chips/first row; 17 Pro, SE at top), `X-25-more-Live_TV.png` (rows start mid-row, time ruler missing on three of four), `X-11-music-top.png` (17e: "Good Evening" cut off by the floating pill, search field scrolled away), `T-music-library.png` (Music → Library opens past the Playlists/Artists/Albums doors on three of four), `U-01-settings-1.png` (Settings opens at "Playback" on 17e/mini/SE, at the top on 17 Pro).
- Same family as A1: first layout puts the scroll content at the wrong offset relative to the large-title bar. Which devices show it varies between screens, so it looks timing-dependent, not size-dependent.
- Worth a manual repro (mine were XCUITest-driven, ~2 s after navigation).

### B2. Detail pages: hero doesn't bleed under the nav bar; hard edge when scrolling (M)
Evidence: `X-06-detail-top.png`, `X-07-detail-2.png`.
- Movie/show/season pages show a flat opaque bar (back chevron only, no title) above the backdrop, so the hero starts with a visible seam at ~y=130 on every device.
- When you scroll, body text is cut off mid-line at that same hard edge (e.g. "…the bloodthirstiness of the / opposition" in `X-07`) rather than fading.
- Source: `paletteBar()` in `Views/Theme.swift:114` sets an opaque `toolbarBackground(Theme.background, …)`.

### B3. Action-button row: "•••" pill is a different size from Play / ★ / Download (L)
Evidence: `X-06-detail-top.png`, `Y-04`/`p-ctx-real.png`. The overflow button is visibly shorter and narrower than its neighbours on every device.

### B4. Live TV guide is cramped (M)
Evidence: `X-25-more-Live_TV.png` (portrait), `G-02-guide-landscape.png`, `G-04-guide-landscape-scrollx.png`.
- Portrait: channel column is so narrow the names truncate to "Ameri…", "Rick a…", "Anima…", "Carto…" on every phone. Short programmes truncate to "Frisky D…", "Bob's B…", "South…".
- Landscape: the "Live TV" title, the time ruler and the floating tab bar eat roughly half the height; only ~3 channel rows are visible at once on the 17 Pro.
- Landscape (13 mini capture): rotation didn't take effect in the capture — the guide stayed a tiny portrait layout. Flaky rotate; check by hand.
- The red "now" line runs through programme titles (expected, but it reads badly over 2-line titles).

### B5. Now Playing (music) (M)
Evidence: `T-nowplaying.png`.
- Track title is truncated hard because the 👎 👍 ★ buttons take ~45 % of the row: "I Hate Myself fo…", "The Ties That Bi…", artist "Bruce Springsteen —…" — on all four devices. No marquee or second line.
- Volume row shows just two speaker glyphs with no visible track (probably the simulator; verify on device).
- Scrubber thumb is a wide pill that looks oversized against the thin track.

### B6. Mini player floats over content without room (L–M)
Evidence: `p-mini.png` / `T-miniplayer.png`. List text ("Two Hearts…") shows through the gap between mini player and tab bar, and the last rows can't scroll clear of the two stacked bars.

### B7. Floating tab bar overlays content everywhere (L)
Evidence: nearly every composite. Text and posters scroll under it with a blur; on SE and 17e the labels are large relative to the bar. Combined with the hard-edged top bar (B2) the content window is small on the SE (667 pt).

### B8. Home hero pager dots invisible in Light appearance (L)
Evidence: `X-01-home-top.png` panes 2–4 — dots fade into the white gradient at the hero's bottom edge; on Dark (pane 1) they read fine.

### B9. Filter chip rows are clipped at the right edge with no cue (L)
Evidence: `X-17-more-Movies.png` — "Favorites" chip cut off on every phone (scrolls, but nothing says so). Same on Favorites (`X-23`: "Episodes" touches the edge on 13 mini/SE).

### B10. Downloads list rows (L)
Evidence: `X-10-downloads.png` pane 1 (17 Pro has ~2,957 failed items from earlier sessions). Error text wraps to two short lines beside Retry/trash, leaving dead space; the "Downloads" large title sits ~100 pt below the status bar with nothing above it (also seen on More, Search, Favorites).

### B11. Settings (L)
Evidence: `U-01-settings-1.png`, `U-03-settings-3.png`.
- "Framing: Fit — show the whole frame ⌃⌄" and "Default quality: Direct Play (original) ⌃⌄" put the label and value on two lines while other rows put them side by side (inconsistent row layout).
- Info (ⓘ) icons sit inline with labels and wrap awkwardly on "Play the next episode automatically".

### B12. iPad (M) — Home, portrait only
Evidence: `ipads-home.png` (iPad Pro 11", iPad mini, iPad A16, left to right).
- The sidebar is open by default in portrait and takes ~35–40 % of the width, so the content column is narrow: hero is a small crop, shelves show ~3.5 cards.
- "FellyJin" appears twice (sidebar title and the content header), and the header sits directly under the status bar with no separation.
- Sidebar ends ~⅔ down with empty space beneath; "Synced" badge is alone at the bottom.

---

## C. Passed / looked fine
- Home, Movies/TV grids, show and season pages, Music Discover, Audiobooks, More list, Favorites empty state: no clipping of text or artwork at the four phone sizes beyond the items above.
- Search results (after typing): grids, artists row, keyboard avoidance all fine.
- Music album page and Now Playing artwork scale sensibly to the SE.

## D. Not covered (do these next if useful)
- iPad: landscape, and every screen other than Home (detail, player, Settings, Music).
- iPhone 17 Pro Max / Air, iOS 27 runtime, Display Zoom, Dynamic Type (larger text is the likeliest to break the SE), Dark vs Light on the same device.
- Portrait player, TV guide on 17e/SE landscape, Now Playing queue/lyrics, Person page, playlists, Login/Quick Connect, Live Activities, CarPlay.
- tvOS was not in scope.
- Phone shell in landscape is locked by design; if you want landscape browsing on phones that's a product decision, not a bug.

## E. How to re-run
The XCUITest journeys used live in the session scratchpad (`probe/ProbeUITests/ProbeUITests.swift`: `testTour`, `testEpisodeMenu`, `testSearchSettings`, `testSettings`, `testNowPlaying`, `testGuide`, `testPlayer`); say the word and I'll move them beside `tools/ios-ui-probe`. Simulators created: `QA SE3`, `QA 13mini` (iOS 26.5). The four phones and three iPads are seeded with the demo-server session copied from the 17 Pro.

---

# Addendum — iPad (portrait + landscape), added same day

Devices: **iPad Pro 11" (M5)**, **iPad mini (A17 Pro)**, **iPad (A16)**, iOS 26.5, Light appearance. Composites are left to right: Pro 11", mini, A16. Files: `screenshots/ipad-*.png`. Covered on all three, both orientations: every sidebar destination, movie detail, show → season, episode long-press + Download submenu, Live TV guide, Music library / mini player / Now Playing, player. Landscape = landscape-left.
Unlike iPhone, iPads rotate everywhere (no lock).

## I1. Landscape iPad Home renders blank/half-rendered on mini and A16 (H)
`ipad-I-left-02-Home.png`. On the iPad mini and A16 the hero carousel is missing entirely on first show (Pro 11" shows it), the content starts under a thin dark bar, and "FellyJin" header sits on a stripe with no background. Looks like the same "opens at the wrong scroll offset" problem as B1, here hiding the hero.

## I2. iPad mini landscape: app window floats as a card over a wallpaper (H)
`ipad-I-left-10…` / `ipad-I-left-18-Live_TV.png` (middle panes), and `I-left-22-movie-detail`. On the mini the app is drawn as a rounded, windowed panel (traffic-light dots, wallpaper visible around it) instead of full screen; sidebar's first item ("Home") is clipped behind the window chrome. Likely the simulator's Stage-Manager/windowed mode for that device rather than the app — **verify on a real mini** before treating as a bug.

## I3. Sidebar has no Search entry (M)
The XCUITest could not find "Search" in the sidebar on any iPad (sidebar: Home, Downloads, Music, Audiobooks, Movies, Recordings, TV Shows, Favorites, Live TV, Settings). On iPhone Search is in More; on iPad there is no visible route to it. Confirm whether that is intended (e.g. a search field elsewhere) — I did not find one.

## I4. Sidebar takes a fixed ~⅓ of portrait width; content column cramped (M)
`ipad-I-portrait-02-Home.png`, `…-10-Movies.png`, `…-22-movie-detail.png`. Open sidebar leaves only ~400 pt of content on the 11"/A16, so: Home shelves show ~3.5 cards with a clipped fifth, the Movies grid is 3 columns of small posters, the Genre filter chip is cut off ("Genre" at the edge), and text-heavy pages (movie detail) sit in a narrow column with a large empty band below the sidebar list. Sidebar also leaves ~⅓ screen empty under "Settings".

## I5. Detail pages on iPad (M)
`ipad-I-portrait-22-movie-detail.png`, `ipad-I-portrait-27-season.png`.
- Hero art is cropped very tightly and dark: the poster title sits on the gradient seam and different iPads crop it differently (Pro 11" shows a tiny strip; season page on Pro 11"/A16 shows only "AHSOKA" text or nothing above the title).
- Action buttons wrap onto a second row (Play / Quality / Favorite, then Mark watched / Trailer / Download) even in landscape on the Pro 11" they fit on one row but with a lot of empty space at right — inconsistent.
- "More like this" shows an empty grey placeholder box for a title with no artwork ("Wall Street", `ipad-I-left-22-movie-detail.png`).
- Cast row clips the last portrait at the right edge with no fade.
- Very small type in cast/crew captions and metadata line for a tablet.

## I6. Episode long-press menu on iPad (M)
`ipad-I-left-ctx.png`. Menu is anchored far right, detached from the pressed row (row 1), overlapping the row text of episodes 2–4; the Download submenu opens as a **separate popover further down and left**, with the parent menu still visible above it. Same "not attached to the row" fault as A2, worse on the wider screen. Episode rows also get truncated titles on the mini/A16 in portrait ("Part One: Master and App…").

## I7. Live TV guide on iPad (M)
`ipad-I-portrait-18-Live_TV.png`, `ipad-I-left-18-Live_TV.png`.
- Programme cells are ~60–100 pt wide but titles/times are set at full size, so nearly every cell reads "F…", "Fr…", "T…", "Bo…", "South P…". Timeslot columns are too narrow for the text on all three.
- Portrait: the guide only fills the top half of the screen; the rest is empty white.
- Time ruler is clipped under the header on A16 (portrait) and unreadable on the Pro 11" (portrait: no ruler shown).
- Red now-line cuts through titles.

## I8. Movies / grid pages open scrolled past the title & filters (M)
`ipad-I-portrait-10-Movies.png`: only the Pro 11" shows "Movies" + filter chips; mini and A16 open scrolled with just a small centred "Movies" nav title and the first row half-cut. Same family as B1.

## I9. Music on iPad (M)
`ipad-I-np.png`.
- Now Playing is a **floating card ~½ the screen width** dropped in the middle over the library (both orientations), with a drop shadow but no dimming behind — the library behind still looks live, the tab/sidebar chrome stays, and the mini player below is still tappable-looking. Reads as a phone sheet stretched badly, not an iPad layout.
- In portrait on the Pro 11" the card sits left of centre, partly over the sidebar edge.
- Artwork is small relative to the card; long titles still truncate ("Soul Driver (live at The Shrine, Los Ang…").
- Mini player's bottom bar overlaps the last library row and the floating toolbar with no bottom inset.

## I10. Player on iPad landscape (M)
`ipad-I-left-play.png`.
- Video is letterboxed to a wide strip with thick black bars above and below while the control bar sits in the black area; the top row (close, PiP, AirPlay, Original, gear) is fine but tiny for the screen size.
- The centre transport buttons (−10 / pause / +10) are small relative to a 11–13" screen and the ‑10/+10 are tinted differently from pause when over the green frame.
- Mute glyph at top-right is drawn as a faint icon far from the other controls.
- Bottom-right icons (speed, subtitles) float above the scrubber with no grouping.
- Not captured: iPad portrait player, extras popover placement.

## I11. Settings and Downloads on iPad (L)
Both render in a single narrow centred column with generous empty margins in landscape; Settings rows are the phone layout stretched (label left, value far right ~600 pt away).

## Coverage after this addendum
Done: iPhone 17 Pro / 17e / 13 mini / SE portrait; iPad Pro 11" / mini / A16 portrait + landscape (main screens); phone player + TV guide landscape.
Still not done: iPad Pro 13" / Air, iPhone Pro Max / Air, iOS 27, Dynamic Type, Display Zoom, split-view / Slide Over / Stage Manager resizing on iPad, iPad portrait player, Login/Quick Connect, Person page, playlists.

---

# Fix pass — 2026-09-20

## Correction first: three findings above were my capture's fault, not the app's
**B1, I1 and I8 ("screens open already scrolled", "iPad landscape Home has no hero", "Movies opens past its title") are withdrawn.** My screenshot picker took the first frame ≥0.4 s after each marker; with four simulators running at once frames were ~0.6–1 s apart, so the frame chosen was often *after the test's next swipe had started*. A frame-by-frame replay of Settings on the 17e shows it opening at the top and only moving when my test swiped. With the capture fixed (the test now waits for a frame to be written before it moves) Movies, TV Shows, Live TV, Settings, Music Library and iPad Home (both orientations) all open at the top. The same race also exaggerated A1's "empty grey pill" — but A1 itself is real (hand-driven screenshots on the 17 Pro show it).

## Fixed and verified (17e, SE, iPad Pro 11" portrait + landscape, demo server)
| # | What | Change | File |
|---|---|---|---|
| A1 | Search field hidden until pull-down when Search is opened from More | `.searchable` → `.navigationBarDrawer(displayMode: .always)` on iOS | `Views/SearchView.swift` |
| A2 | Episode press-and-hold menu: wrapped rows, submenu taller than the SE | "Go to the show" + show name as the menu *subtitle* (truncates, doesn't wrap); Download submenu uses new short labels ("1080p · 9 Mbps") — 6 single-line rows now end above the tab bar | `Views/ItemContextMenu.swift`, `Core/Preferences.swift` (`DownloadQuality.menuLabel`; stored `label` untouched) |
| A3.1 | Loading card collided with AVKit's centre transport buttons | One-line capsule, raised 92 pt above centre, hit-testing off | `Player/PlayerScreen.swift` |
| B3 | "•••" button smaller than its neighbours | Icon sized by a hidden star glyph | `Views/ItemDetailView.swift` |
| B4 / I7 | Guide: channel names cut to five letters; iPad cells read "F…" | Channel name gets two lines (iOS/macOS); iPad minute width 3.4 → 5.5 and channel column 124 → 172 | `Views/TVGuideView.swift`, `Views/Components.swift` |
| B5 | Now Playing title truncated by the thumb/star buttons | Title may take two lines (scale 0.8), button spacing 12 → 8 | `Music/NowPlayingView.swift` |
| B8 | Home pager dots invisible in Light | Stronger inactive dots + a translucent page-colour capsule behind them | `Views/HomeView.swift` |
| I3 | No Search anywhere on iPad | Search is listed in the sidebar (and on Mac); `show(.search)` selects it directly there | `Core/AppModel.swift` |
| I4 | iPad sidebar 320 pt wide | `navigationSplitViewColumnWidth(min 200, ideal 232, max 300)` now applies on iPad too — Movies grid goes 3 → 4 columns in portrait | `Views/RootView.swift` |
| I5 (part) | Blank grey tile for items with no artwork | Tile shows an icon + the title once the image is settled as absent | `Views/Components.swift` (`PosterCard`) |

## Left alone, on purpose
- **A2 "menu not attached to the row" / parent menu ghosted behind the submenu** — that is iOS 26's own context-menu and nested-menu rendering; the app uses the stock `.contextMenu`. Replacing it means a hand-built menu, which is a product decision.
- **A3.3 extras popover position, I10 iPad player chrome** — AVKit's own controls and menu placement.
- **B2 opaque top bar on detail pages** — deliberate and documented in `AppTopBar` (a system bar mis-sizes on pages that load in stages). Not a bug.
- **B6/B7 floating tab bar and mini player over content** — system tab bar behaviour on iOS 26; content already insets for it.
- **B9 clipped filter chip** — the half-visible chip *is* the scroll cue; left.
- **B10/B11/I11 Downloads and Settings row polish**, **I9 Now Playing as a form sheet on iPad** — standard iPadOS sheet; changing it is a design call. Not touched.
- **I2 iPad mini "windowed" app** — simulator windowing mode, not the app.

## Known leftovers from the fixes
- Two-line channel names can hyphenate on a phone ("Anima-tion Co…"). Better than five letters; a wider column would cost programme width.
- The Now Playing two-line title was verified with short titles only on this run; long-title wrapping is by construction, not by screenshot.
- Not re-run on 17 Pro / 13 mini / iPad mini / A16 after the fixes; tvOS and macOS were compiled-around (`#if`) but not built.
