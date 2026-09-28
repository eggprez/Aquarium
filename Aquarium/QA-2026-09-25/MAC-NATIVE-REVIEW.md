# Aquarium for Mac — making it a Mac app, not an iPad port (2026-09-25)

Nothing was changed. This is a catalogue of everything in the macOS build that reads as iPad, tvOS or web, with a concrete Mac alternative for each, grouped so it can be worked through as a series of PRs. Line numbers refer to the source as of today; paths are under `Aquarium/Aquarium/`.

Gathered by reading every view that builds for macOS (RootView, MacSidebar, MacCommands, ItemWindow, PlayerWindow, HomeView, Components, LibraryView, ItemDetailView, PersonView, SearchView, ItemContextMenu, TVGuideView, LiveTVView, DownloadsView, DownloadedSeriesView, LibrariesView, FavoritesView, LoginView, SettingsView, PlayerScreen, TransportBarExtras, the tvOS-only player panels, ImageLoader, Theme). I could not take screenshots of the running app: the Xcode debug session (PID 37609) has no open window, and a second instance I launched could not be captured without a screen-takeover approval. Everything below is from the code.

**What already is Mac-native and should stay:** the Settings scene with a tab per pane, `MacCommands` (⌘1–9, Go, Item menus), `PlaybackCommands`, the player in its own window with aspect-fitted resizing, "Open in New Window" title windows, the sidebar grouped under headings with an account menu in the footer, `.searchable(placement: .toolbar)` with scopes and ⌘F focus in Search, LibraryView's toolbar Picker/Menu with `.help` and `.navigationSubtitle`, Refresh ⌘R on Home. Build on these.

---

## 0. The five things that make it read as a port

1. **A fixed web palette instead of system colours and materials.** `Theme.swift:22-35` are hex values carried over from `styles.css`. The window is painted `Theme.background`, the sidebar is a `Theme.raised` card, every grey is a hex, and the purple accent is hard-coded everywhere. Nothing picks up the window background, the sidebar material, vibrancy or the user's accent colour. This alone makes the app look "not from here".
2. **Tap = go.** Nearly every tile, row and cell is a `.plain`/`PosterButtonStyle` Button that acts on a single click. There is no selection, no hover highlight on rows, no double-click, no Return-to-open, no arrow-key navigation, no ⌘A. The app has a pointer but behaves like a touchscreen.
3. **Page-drawn chrome instead of window chrome.** Actions, filters, arrows, status counts and "See all" live inside the scrolling page (capsule pills, chips, cards, sticky headers) rather than in the toolbar, the window subtitle, the menu bar or context menus.
4. **iOS feedback idioms.** Bottom toasts, shimmer skeletons, custom empty/error states, haptics, press-to-shrink animations, iOS 26 "glass pills", 44-pt hit targets, 12-pt card corners, 60-pt guide rows.
5. **Features the Mac simply doesn't get.** Music/Books rows, the hero carousel, the stream-info panel, audio-delay control, music search results, downloaded audio, the richer player extras menu are all `#if os(iOS)` or `#if os(tvOS)`, so macOS falls into the "else" branch.

---

## 1. App-wide fixes (each one touches every screen)

### 1.1 Colours, materials, accent
- **Map `Theme` to semantic colours on macOS** (`Views/Theme.swift:28-35`): `background` → `Color(nsColor: .windowBackgroundColor)`, `raised` → `.controlBackgroundColor`/`.textBackgroundColor`, `text`/`textBody`/`textDim` → `.primary`/`.secondary`/`.tertiary`, `border` → `.separatorColor`, `hover` → `Color.primary.opacity(0.06)`. Keep the brand hexes for iOS/tvOS if you like, but the Mac should look like the Mac.
- **Stop painting the shell** (`Views/RootView.swift:53, 207, 521, 586`, `Views/LoginView.swift:98`): remove `.background(Theme.background)` on macOS and let the window background and the split view's sidebar material show. Consider `.containerBackground(.thinMaterial, for: .window)` on the login window.
- **Sidebar material** (`Views/MacSidebar.swift:150`): the Now Playing strip is a `Theme.raised` rounded rect; on a sidebar that should be vibrant. Use `.background(.quaternary, in: RoundedRectangle(...))` or no fill at all.
- **Respect the user's accent colour**: `AquariumApp.swift:87` forces `.tint(Theme.accent)` on the Settings window; `Components.swift:950-961` tints every prominent button `Theme.accentStrong`; `DownloadsView.swift:811` tints progress bars; `TVGuideView.swift:914` uses `Theme.accentSoft` for "now airing"; `FavoritesView.swift:40-41`; `DownloadsView.swift:725-735` badges. Put the purple in the asset catalog as `AccentColor` and use `Color.accentColor`/default tint on macOS so System Settings ▸ Appearance ▸ Accent colour works.
- **Toolbar**: `ItemDetailView.swift:107-112` paints the window toolbar `Theme.background`. Use `.toolbarBackground(.hidden, for: .windowToolbar)` on hero pages so the artwork runs under a translucent title bar (TV app), and the default material elsewhere.
- **Hero fades into a hex** (`HomeView.swift:890-909`): fade into the window background colour so the seam disappears once the shell uses system colours.
- Status colours: `Theme.danger/ok/warn` → `.red/.green/.orange` on macOS.

### 1.2 Pointer, selection and keyboard
- **Hover on every clickable thing.** `RowPressStyle` (`Components.swift:799-815`) only fills while pressed; it's used by episode rows, cast, recents, breadcrumbs, login rows. Add an `.onHover` fill on macOS. Poster tiles get `PosterHover` (`Components.swift:728-743`) but it scales only the art, draws a white stroke that's invisible in light mode, and is clipped by shelves (see 3.2). Download posters and library tiles get no hover at all (`DownloadsView.swift:666-740`, `LibrariesView.swift:57-66`).
- **Selection model for grids and lists.** Single click selects, double-click or Return opens/plays, arrows move, ⌘A selects all, context menus act on the selection (`.contextMenu(forSelectionType:menu:primaryAction:)`). Applies to `MediaGrid`, `PosterGrid`, episodes (`ItemDetailView.swift:838-866`), TV guide channels/programmes (`TVGuideView.swift:361, 898-924`), downloads (`DownloadsView.swift:233-295`), favorites, login server/account rows.
- **Keyboard focus is off on the Mac.** `focusRegion()` (`Components.swift:1031-1037`) calls `focusSection()` only on tvOS; it's available on macOS 13+. Tiles are not `.focusable()`. The TV guide's `@FocusState` is bound only on tvOS (`TVGuideView.swift:230-234, 363-365, 858-878`). Turn these on and handle ←/→/↑/↓/Return with `.onKeyPress`.
- **No press-to-shrink on a Mac.** `PosterButtonStyle` (`Components.swift:746-752`) scales to 0.96 on press; replace with a brightness dip or a selection ring on macOS.
- **Tooltips everywhere.** Not a single `.help()` in ItemDetailView; none on icon-only buttons in Downloads (`:132-138, :400-410, :449-499`), the player overlays, the guide arrows, cast tiles, truncated titles (`Components.swift:314-327`, `TVGuideView.swift:798-807`). Add `.help` to every icon button and every `lineLimit(1)` title.
- **Type-to-select** in the guide and library lists (`.onKeyPress(characters:)` or `.searchable`).
- **Drag and drop and sharing**: nothing is `.draggable`; no `ShareLink` anywhere. Add `.draggable(webURL)` on tiles/rows and a ShareLink in the toolbar and context menu.

### 1.3 Feedback idioms
- **Toasts** (`Components.swift:1597-1657`, `AppModel.swift:153-158, 1253-1264`, callers at `AppModel.swift:994, 1151, 1288, 1306, 1313, 1336`, `ItemDetailView.swift:764, 1055, 1059, 1111, 1149, 1155`, `DownloadsView.swift:110, 150, 156, 203, 383-388`, `ItemContextMenu.swift:356-390`). Not a Mac idiom. Errors → `.alert`; background completions → `UNUserNotificationCenter` when the window isn't key; connectivity → persistent sidebar footer status (already exists) and no toast; "Removed 3 items" → nothing, the list visibly changed. If a toast must stay: ✕ on hover, pause timer on hover, no auto-dismiss for errors, no `.sensoryFeedback`.
- **Haptics** (`.sensoryFeedback` in `LibraryView.swift:121-124`, `FavoritesView.swift:70`, `Components.swift:1632-1640`, `PlayerScreen.swift:153-156`, `ItemDetailView.swift:298-305`): gate with `#if os(iOS)`.
- **Shimmer skeletons** (`ImageLoader.swift:785-816`, `Components.swift:1119-1224`, used by Home, Library, Person, Search, Live TV, Favorites): a web/iOS loading idiom. On macOS use `.redacted(reason: .placeholder)` on real layouts or a small `ProgressView()`; `SkeletonShelf` draws exactly 4 cards then a Spacer, so a wide window shows four grey posters and empty page. Skeleton "buttons" are 108×34 capsules (`Components.swift:1190-1191`).
- **Custom empty/error/offline states** (`Components.swift:1446-1539`): replace with `ContentUnavailableView` (macOS 14+), including `.search` for filtered-empty.
- **Artwork fade-in** (`ImageLoader.swift:683, 741-743`): 0.25 s on every load reads as flicker on a fast-scrolling Mac grid; skip when cached, shorten on macOS.
- **Offline strip** (`Components.swift:1545-1578`) is a floating rounded "above the tab bar" banner; there is no tab bar. Use a full-width `.bar`-material bottom strip or the window subtitle.

### 1.4 Density, type and shape
- **Card corners and stroke** (`Theme.swift:69`, `Components.swift:304`): 12-pt continuous corners plus a hairline border on every poster reads as iOS/web cards. Mac TV/Photos use ~6–8 pt and no stroke.
- **Small text over artwork**: `.subheadline`/`.caption` were tuned for iOS (15/12 pt) and are 11/10 pt on macOS. Hero meta (`HomeView.swift:984-996, 1105-1107`), card titles/subtitles with `minimumScaleFactor(0.8)` (`Components.swift:314-327`), cast captions. Use `.body`/`.callout` and no scale factor on Mac.
- **Touch metrics on Mac**: `guideRowHeight` 60 (`Components.swift:223-229`; Mac ≈ 40), episode rows >90 pt with 148×83 stills (`ItemDetailView.swift:1204-1222`), 44-pt ellipsis targets (`DownloadsView.swift:905`), `Metrics.gutter` 28 (`Components.swift:109-117`; Mac ≈ 20), `spacing: 24` sections in Downloads. `cardTextSpacing`, `shelfTitleSpacing` fall through to iOS values (`Components.swift:76-83, 101-107`).
- **Fixed sizes that ignore the window**: hero 340 pt tall (`HomeView.swift:820-828`), logo 300×76 (`:1049-1053`), hero text column 620 (`:967-973`), shelf cards 168 pt (`Components.swift:16-24`). Derive from width.
- **Title Case for buttons and menus.** Sentence case throughout: `ItemContextMenu.swift:158, 170, 219, 239, 257-259, 278-279, 287, 328, 334, 346`; `PlayerScreen.swift:289, 299, 407, 451, 455, 558-575`; `SettingsView.swift:230, 391, 989`; `LoginView.swift:538, 622, 683, 693`; `DownloadedSeriesView.swift:109-133`; "See all"; "Retry connection". Also "…" on anything that opens a dialog ("Sign Out…", "Delete Show…").
- **Pills and chips**: `MetaChip` genres (`Components.swift:1844-1861`), `StatusPill` (`Theme.swift:134-159`, used in Settings and Downloads), filter capsules (`FavoritesView.swift:30-47`), glass "Details" pill (`HomeView.swift:1164-1173`). Mac equivalents: secondary text joined with " · ", `Label` with a symbol, segmented/menu Pickers in the toolbar, bordered buttons.

### 1.5 Images
- **Mac grids are blurry.** `PosterGrid.cardWidth` returns nil on macOS so `requestWidth` falls back to 336 px (`Components.swift:299, 1102-1105`) while columns reach 210/360 pt at 2× = 420/720 px. Hero requests 1600 px for a window that needs ~2400 (`HomeView.swift:955-961`). Use measured width × `@Environment(\.displayScale)`.
- **No downsampling/pre-decode on macOS** (`ImageLoader.swift:303-353`): the `CGImageSource` thumbnail path is UIKit-only; the Mac does `NSImage(data:)` and decodes lazily on the main thread. Port the same path with `NSImage(cgImage:size:)`. Cache purge only listens to iOS memory warnings (`:87-96`); add a `DispatchSource` memory-pressure source.

---

## 2. Window, sidebar and menus

- **Search as a sidebar row** (`AppModel.swift:146, 460`): Music.app puts search in the sidebar *field*. Use `.searchable(placement: .sidebar)` on the NavigationSplitView and drop the row; keep ⌘F focusing it. Library pages should filter from the toolbar field too (`LibraryView.swift:111-118`).
- **Sidebar symbols** (`AppModel.swift:131-150`): `book` for Audiobooks → `headphones`; `antenna.radiowaves…` is wide and noisy at sidebar size → `play.tv` or `dot.radiowaves.left.and.right`; `books.vertical` for Libraries → `rectangle.stack`; `folder` for home/music videos → `video` / `music.note.tv`.
- **Sidebar rows have no context menu** (`MacSidebar.swift:27-28`): add "Open in New Window", "Refresh Library".
- **Window title/subtitle**: pages draw their own titles and counts in content (season name at `ItemDetailView.swift:397-399`, show name at `DownloadedSeriesView.swift:45, 69-71`, result count at `SearchView.swift:107-111`, "N of total" footer at `LibraryView.swift:200-205`). Use `.navigationTitle` + `.navigationSubtitle`.
- **Menu bar gaps** (`MacCommands.swift`, `PlayerWindow.swift:159-189`): no View menu (Bigger/Smaller thumbnails ⌘+/⌘−, Sort By, View as Icons/List, Show Sidebar), no guide shortcuts (Earlier ⌘←, Later ⌘→, Now ⌘T), no Playback submenus for Audio/Subtitles/Quality, no Skip Intro, no Fill Screen, no Audio Delay, no Show Downloads in Finder, no About panel (About info currently lives in Settings ▸ General `SettingsView.swift:320-324` → `CommandGroup(replacing: .appInfo)`).
- **Context menus don't show key equivalents** (`ItemContextMenu.swift`) even though MacCommands defines ⌘↩/⌘D/⇧⌘U; add matching `.keyboardShortcut` so the menu displays them. Add Share, Copy Link, Get Info, Show in Finder (completed downloads, `:322-329`).
- **Quality submenu uses phone-short labels** (`ItemContextMenu.swift:338-344`); use the full labels on Mac, ideally an inline Picker. Two-Text menu labels (`:236-242`) may not render as intended on macOS.
- **Dock menu**: Continue Watching is published only to iOS quick actions (`HomeView.swift:610-614`); add `applicationDockMenu`.
- **Return-to-app refresh never fires** on macOS because it waits for `.background` (`HomeView.swift:384-389`); use `NSApplication.didBecomeActiveNotification`.
- **Item windows**: consider double-click on a tile opening a new window (the plumbing exists), and `.inspector` for Get Info.

---

## 3. Home and shelves

### 3.1 Hero
- Mac gets a **still hero**, not the carousel (`HomeView.swift:284-306`); six spotlight items are fetched, five never shown. Build a Mac carousel with hover-revealed ‹ › and ←/→ keys, paused on hover.
- The backdrop **isn't clickable or right-clickable** (`:925-950`); make it open the title and add `.itemContextMenu`.
- Hero **sits below an opaque title bar** (`:172-175`); run it under a hidden-background toolbar like TV.app.
- **Play is a hand-drawn purple capsule** with a drop shadow (`:1133-1179`); Details is an iOS-26 glass pill. Use a proper button style with hover/pressed states, `.keyboardShortcut(.defaultAction)`, `.help`, no shadow.
- Hand-drawn progress bar (`:1089-1110`) → `ProgressView(value:)`.
- Fixed 340 pt height, 300×76 logo, 620-pt text column (see 1.4).

### 3.2 Shelves and tiles (`Components.swift`)
- **Horizontal shelves are touch scrollers** (`:598-626`, plus `LibrariesView.swift:177`, `ItemDetailView.swift:813, 905`, `TVGuideView.swift:381`): `showsIndicators: false`, no paging chevrons, no `.scrollTargetBehavior`. A mouse user can't scroll them without Shift. Add hover-revealed ‹ › paging buttons (`.scrollPosition(id:)` + `.scrollTargetLayout()`), show indicators on macOS.
- **Hover lift is clipped**: `shelfCardPadding` is 0 on macOS (`:87-93`) while `PosterHover` scales 1.035 and adds a shadow, so the lift is cut off top and bottom. Give shelves padding or `.scrollClipDisabled()`.
- **Fixed 168-pt cards** regardless of width (`:16-24, 609, 1214`); the last card is always cut mid-poster. Compute the per-page count from the shelf width like TV.app.
- **"See all" is plain 11-pt accent text** (`:658-684`); make the shelf heading itself a link button ("Continue Watching ›") with hover, or `.buttonStyle(.link)`. Headings lack `.accessibilityAddTraits(.isHeader)`.
- **Badges** in `Theme.accentStrong` (`:407-425`) → `Color.accentColor`.
- **No Music/Books rows on Mac** (`HomeView.swift:419-436`, `AppModel.swift:175-181` returns `hasMusic = false`): enable `AlbumShelf` on macOS.
- Home toolbar has only Refresh (`HomeView.swift:187-205`); add Play Featured, a sidebar toggle is fine to leave to the system.

---

## 4. Library, Favorites, Search, Person

- **Library grid**: no thumbnail size control (`LibraryView.swift:195` → `@AppStorage` size + toolbar slider + View menu), no selection/multi-select (bulk Mark Watched), no in-library search, filters reset on library switch (`:128-140` → `@SceneStorage` per library), genre menu uses Toggles for a single choice (`:295-307` → inline Picker), list mode shows poster skeletons while loading (`:146-156`), web-style "N of total" footer (`:200-205`).
- **Favorites**: hand-drawn capsule filter pills in purple (`FavoritesView.swift:30-47`) → segmented Picker in the toolbar (`placement: .principal`) with View-menu shortcuts; no sort or grid/list toggle (`:60`); haptic on filter (`:70`).
- **Search**: **bug — music-only results show a blank page on Mac** (`SearchView.swift:103-105, 380, 96`): music is requested and advertised in the prompt but `musicResults` is iOS-only. Recent searches are a hand-built list in the page (`:249-288`) → `.searchSuggestions` drop-down; result count in content (`:107-111`) → subtitle; 9-tile skeleton on every keystroke (`:92-93`) → keep old results + small spinner; no ↓ from field into results, no Return to open top hit.
- **Person**: filmography as horizontal shelves chosen for the TV remote (`PersonView.swift:45-46`) → grid or Table (Year / Title / Role); "Read more" plain accent text (`:88-108`) → `.link`; no `.textSelection`; skeleton doesn't match layout (`:32`); `NSWorkspace.shared.open` instead of `openURL` (`:219-228`).
- **LibrariesView** never appears on Mac (sections expand per library); its tile row on Home has press-shrink, no hover, no context menu, no `.help` (`:57-66, 180-185`).

---

## 5. Item detail page (`Views/ItemDetailView.swift`)

- **Actions belong in the toolbar.** Six big buttons in a `WrappingRow` (`:499-511`) wrap to two or three rows in a narrow window; `isCompact` is hard-coded false on macOS (`:525-530`). Keep Play in content as a **split button** (Menu with `primaryAction`, quality in the menu, `:533-543, 576-582`); move Favorite/Watched (as `Toggle(.button)`, `:585-612`), Download (with determinate progress like Safari's downloads button, `:774-776`), Share to `.toolbar`.
- **Toolbar painted a custom colour, hero below it** (`:107-112`) → hidden toolbar background, hero under the title bar, ~260–300 pt on Mac (`:342`).
- **Season title duplicated** (`:369-376, 397-399`) → title + subtitle.
- **Genres as pills** (`:447-453`), **breadcrumbs as press-only rows** (`:394-396`), **no text selection** on overview/tagline/facts (`:402-440`), hand-drawn progress bar (`:466-482`), no `.help` anywhere.
- **Episodes are a hand-built LazyVStack** (`:838-866`): no selection, no ↑/↓, no Return, no multi-select, no alternating rows, rows react only to press (`:1183-1186`), a purple `.title2` play glyph on every row nested inside another button (`:1263-1276`), touch-sized rows (`:1204-1222`), Next Up shown as a 5-second wash (`:1195-1201`). Use `List(selection:)` with `.alternatingRowBackgrounds()` or a `Table`, hover-revealed play, persistent selection for Next Up.
- **Cast strip** (`:897-944`): no hover, no tooltip for truncated names, hidden scroller.
- **Disk-space prompt is an iOS action sheet** (`:307-313, 1291-1322`): stacked full-width buttons, no default/cancel shortcuts → `.alert` or a Mac sheet with right-aligned buttons.
- `Menu` styled with `.buttonStyle(.bordered)` (`:576-582, 623-626`) may not match neighbours on macOS; use `.menuStyle(.button)`.

---

## 6. Live TV guide (`Views/TVGuideView.swift`, `Views/LiveTVView.swift`)

- **Controls are a sticky header inside the page** (`:154-171`) with custom 28-pt circle arrow buttons (`:265-268, 970-985`) and a "Now" button that pops in and out (`:272-278`) → `ControlGroup` ‹ Now › in the toolbar (Calendar pattern), always present, plus ⌘←/⌘→/⌘T and a compact DatePicker.
- **No date after paging** (`:247-252, 718`) → `.navigationSubtitle` with the day.
- **Time ruler scrolls away** (`:331-333, 412`) → pinned header.
- **Hidden horizontal scrollbar**, more hours load only by flick (`:381, 122-125, 726`).
- **Single click tunes**, including future programmes (`:361, 769-819, 898-924`); no programme details, no programme context menu (`:917`), no hover (`:956-962`), no keyboard focus, no type-to-select, no zoom (fixed 6 pt/min, `Components.swift:152-156`). Click selects and shows a popover (title, time, synopsis, Play/Record); double-click tunes.
- 60-pt rows; channel names shrink instead of truncating (`:798-807`); purple "now airing" (`:914`); hand-made ruler styling (`:719-725`); no alternating rows; custom error banner with purple "Retry" text (`:988-1009`); custom "no matches" (`:337-343`); guide resets to now on every appearance (`:193-205`); `.allowsLandscape()` runs on Mac (`:239`); loading spinner in content (`:281-283`).
- **LiveTVView on Mac is the leftover `#else`** (`:41-58`): only a search field; refresh lives in Settings (`:111-120`). Add toolbar (arrows, Now, Refresh ⌘R), subtitle ("124 channels · Custom M3U"), ⌘F to the filter field.

---

## 7. Downloads (`Views/DownloadsView.swift`, `Views/DownloadedSeriesView.swift`)

- **Hand-stacked VStack sections, not a list** (`:53-198`); queue/failed lists cut at 25 (`:36, 74, 95-99, 121, 141-145`) because the stack isn't lazy. → `Table` (Name / Status / Progress / Size / Quality, sortable) or `List` with sections, multi-select, Delete key, context menus.
- **Web-style text links** for Pause/Resume and Clear Queue (`:100-115`), red "Remove"/"Cancel" caption buttons (`:89-92, 805-808`), trash icon without tooltip (`:132-138`), per-row bordered Retry (`:130-131`) → toolbar Pause/Resume, `xmark.circle.fill` stop buttons, context-menu actions.
- **Summary is an inset iOS card** (`:364-443`) holding Sync, Show in Finder (oversized icon `:400-410`), an ellipsis "more" menu (`:449-499`) and a **preference** (Parallel downloads segmented control, `:427-438`) → counts and free space in the subtitle or a Finder-style status bar; actions in the toolbar; the preference in Settings ▸ Downloads.
- `DownloadedRow` is an iOS cell (`:853-965`): 44-pt ellipsis target, `.title2` purple play glyph, `.plain` no-hover button, comments designed around "tap"/"hold". `StatusPill` "To sync" (`:934`). Hand-drawn `IndeterminateBar` (`:751-784`) → `ProgressView()`.
- Single click plays a film (`:233-245`), no hover on download posters (`:666-740`), context menus lack Show in Finder / Open in New Window (`:246-263, 280-295`).
- **Mac has no route to downloaded audio** (`:172-174, 300-359, 504-540` are iOS-only).
- `DownloadedSeriesView`: `.borderedProminent` purple "Play next", red-tinted Delete menu in content (`:87-139`) → toolbar; sentence-case delete items without "…" (`:109-133`); `ellipsis.circle` season menu (`:188-192`); LazyVStack instead of List (`:29-36`); title repeated in page (`:45, 69-71`); no Show in Finder.

---

## 8. Login (`Views/LoginView.swift`, `RootView.swift:102`)

- Custom ~40-pt fields with hand-drawn padding/stroke (`:641-663`) → `Form(.columns)` with labelled `TextField`s and `.roundedBorder`.
- Card panels with 16-pt corners (`:114-182, 231-263`) → `GroupBox` or a plain Form.
- Full-width purple `.borderedProminent` buttons, **no `.keyboardShortcut(.defaultAction)`** (`:666-717`); Cancel is a plain link far away with no `.cancelAction` (`:75-83`, Esc may not close the sheet).
- 76-pt logo + `.largeTitle` wordmark even inside the add-account sheet (`:201-220`); GeometryReader/ScrollView keyboard-avoidance mechanics and `.scrollDismissesKeyboard` (`:69-99`); `.submitLabel(.go/.next)` (`:119, 144, 155`); no `.defaultFocus` (`:184-186`).
- Server and account rows with permanent `Theme.hover` fills, chevrons, no hover, no selection (`:299-320, 411-436, 238-251, 357-372`) → `List(selection:)` or a server Menu beside the field.
- "Who's watching?" / "Already on this Apple TV" copy shown on Mac (`:235`).
- Password ↔ Quick Connect switch is a footnote link (`:525-545`) → segmented Picker; Quick Connect code can't be selected or copied (`:464-470`); connected-server banner with a StatusPill (`:604-639`); hex red error (`:163-168`).
- Add-account sheet is 520×620 minimum (`RootView.swift:102`) → compact sheet with bottom-right buttons.

---

## 9. Settings (`Views/SettingsView.swift`)

- **Fixed 620×560 for every pane** (`:75-82`): General is mostly empty, Playback scrolls. Fix width only and let each pane size its height.
- **`note()` emits separate rows** (`:937-950`) so explanations look like iOS footers or extra settings → two-Text labels (`Toggle { Text(name); Text(summary) }`).
- Bezel-less `.plain` TextFields with placeholder-only labels; the UA field has no name at all (`:200-208`).
- Hand-built Slider row (`:172-182`) → `LabeledContent` with min/max labels; `Stepper("Parallel downloads: N")` (`:267-270`) → `LabeledContent` + Stepper.
- `StatusPill` server facts (`:361-383`) → `Label("HTTPS", systemImage: "lock.fill")` or status dots; `Theme.textDim` throughout (`:177, 223, 290, 295, 316, 357, 396, 948`) → `.secondary`.
- Accounts: single-click switches with no hover/selection, remove only via context menu, copy says "Tap an account" (`:894-929`) → `List(selection:)` with +/− (Users & Groups pattern), "Switch" button/double-click.
- "Sign out" without "…", left-aligned (`:385-394`); "Delete the copy" destructive with no confirmation (`:302-305`); long sentence-case row buttons (`:230, 989`).
- Theme picker as a menu (`:115-120`) → segmented/radio; Framing labels are sentences (`:252-258`) → radio with subtitle.
- No Music pane on Mac (`:238-249`, `:1352-1386` iOS-only) though `music` is injected; "Subtitles" pane holds the audio-language picker (`:152-169`) → "Audio & Subtitles"; About in General (`:320-324`) → About panel; notes present on iOS but missing on Mac (Resume, Signed in as, Status, Refresh; `Copy.artworkProbe` unused); iCloud captions free-floating (`:313-317`); Quick Connect approve button tinted and width-shifting (`QuickConnectApproveView.swift`).

---

## 10. Player (`Player/PlayerScreen.swift`, `Player/PlayerWindow.swift`)

- **Overlay row never hides** (`:418-434`): the quality capsule and ellipsis circle stay on the picture during playback and full screen, and the ellipsis clashes with AVPlayerView's own ⋯. Put quality/audio/subtitles/sleep/fill into `AVPlayerView.actionPopUpButtonMenu`, the right-click menu and the Playback menu; if a button stays, fade it with the HUD via `.onContinuousHover` + idle timer and use a material, not `.black.opacity`.
- **Every overlay is a hand-drawn `.black.opacity(…)` shape** (`:256, 309, 373, 412, 462, 501, 586, 1121`) → `.regularMaterial`/`.ultraThinMaterial` in dark scheme to match the HUD.
- **iOS-tuned geometry**: `.padding(.bottom, 110)` for iOS AVKit's bar (`:434`) overflows the 480×270 minimum window; loading capsule offset −92 to clear iOS centre controls (`:239-261`); error card padding 120 (`:264-324`).
- Quality menu fakes checkmarks with an empty symbol name (`:485-488`) → inline Picker. Mac extras menu lacks the iOS Audio-sync group and track subtitles (`:518-595` vs `TransportBarExtras.swift:480-533`). Sentence-case items; Fill is a relabelled button, not a checked toggle (`:558-575`).
- Skip Intro is a plain capsule with no shortcut or tooltip (`:401-416`) → S key while focused, `.help`. Up Next card: no default/cancel shortcuts, purple tint (`:439-463`). No-video dismiss is a bare ✕ (`:336-376`). Bitrate badge capsule "between AVKit's corner buttons" (`:193-219, 1101-1125`) → subtitle or material.
- **Missing Mac interactions**: no right-click menu on the video (`:602-624`); no scroll-wheel volume or two-finger scrub; no explicit double-click-to-fullscreen; no ↑/↓ volume, M, F, C/S keys; no PiP delegate (window stays black in PiP), no `allowsMagnification`, `allowsVideoFrameAnalysis`; live channels keep the full scrubber on macOS (`:730-739` UIKit-only).
- **Features the Mac doesn't get**: `PlayerInfoPanel.swift:38` (info + stream panel: codec, throughput, stalls, dropped frames) and `AudioDelayOverlay.swift:21` are tvOS-only; `PlayerSettingsPanel.swift:26` tvOS-only; `TransportBarExtras.swift:33` iOS-only. Mac equivalents: ⌘I stream inspector (`.inspector` or a "Stream Info" window with `LabeledContent` rows), Playback ▸ Audio Delay +10/−10/Reset (⌥]/⌥[/⌥0) with a live popover, Audio/Subtitles/Quality submenus.
- Menu bar Playback menu has only play/seek/speed/stop (`PlayerWindow.swift:159-189`).

---

## 11. Suggested order of work

1. **Palette → system colours/materials + accent colour** (1.1). One PR, biggest visual change, unblocks everything else.
2. **Hover, selection, double-click, keyboard focus, tooltips** on tiles, rows, guide cells (1.2). Shared modifiers in Components.
3. **Chrome out of the page**: item-detail actions, guide controls, favorites filter, downloads actions into toolbars/subtitles; Search into the sidebar field (2, 5, 6, 7).
4. **Feedback idioms**: toasts → alerts/notifications; skeletons → redacted/ProgressView; empty states → ContentUnavailableView (1.3).
5. **Shelves**: paging chevrons, indicators, width-derived card sizes, unclipped hover, Mac hero carousel (3).
6. **Episodes, downloads, guide as List/Table** (5, 6, 7).
7. **Player**: HUD-integrated menus, materials, keys, PiP, stream inspector, audio delay (10).
8. **Login and Settings polish** (8, 9).
9. **Title Case sweep, ellipses, images at Retina size, downsampling** (1.4, 1.5).
