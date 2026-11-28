# Feature list

Things the apps should gain, one entry each, with what is there today so a
session can start from the gap rather than rediscover it. Started 2026-11-05.
Each entry names the Apple files it touches; the Linux app follows later
unless the entry says otherwise.

## Music

### Music search, online and offline, from three places

**Wanted:** one music search that works whether or not the server is in
reach, and that is offered in three places:

1. The main Search tab (the search the whole app shares).
2. The Music tab.
3. The music section under Downloads.

Offline it searches what is downloaded; online it searches the server and
shows what is downloaded when the server drops out mid-search. Same results
layout everywhere: artists, albums, songs.

**Today:**

- The Music tab already has this: `MusicSearchView` in
  `Aquarium/Aquarium/Music/MusicTabView.swift` searches the server, falls
  back to `OfflineMusic.search` when the server is unreachable, and keeps
  the local hits if the server dies during a search.
- The main Search tab (`Aquarium/Aquarium/Views/SearchView.swift`) asks the
  server for music above the video grid but has no offline path at all: with
  the server away it finds nothing, downloaded music included.
- The Downloads page's Music door opens `OnDeviceLibraryView(isDownloadedPage:
  true)` in `Aquarium/Aquarium/Music/OnDeviceViews.swift`, which has no
  search field.

**Built 2026-11-06** (branch `claude/music-search-grid`): one engine and one
results view in `Aquarium/Aquarium/Music/MusicSearch.swift`, used by all
three. The Search tab answers from the downloads when the server is out of
reach or stops answering mid-search, and says so under the field. The
Downloaded page (Downloads → Music, and Library → Downloaded) has its own
field that searches the downloads alone, even online, and opens the
on-device pages. The Music tab keeps its field, now on the shared engine.
Not yet: Mac and Apple TV have no music results at all, as before.

**Follow-up 2026-11-06** (branch `claude/music-search-field`): the field
was the system's `.searchable` drawer, which stays folded under an inline
title until the list is pulled down and is not drawn at all on the Duo's
inside screen, so neither the Music tab nor the Downloaded page had a search
anyone could see. Both now draw their own field under the bar
(`MusicSearchField` in `MusicSearch.swift`), in view at every width, with
Cancel beside it while a search is up.

### Artist page: top songs, then every album in a grid, then the rest

**Wanted:** the artist page in this order:

1. Top songs.
2. All albums, as a grid that wraps (not a sideways carousel), so a
   prolific artist's whole discography is on the page.
3. Everything else underneath: Appears On, biography, similar artists.

**Built 2026-11-06** (same branch): `ArtistDetailView` in
`Aquarium/Aquarium/Music/MusicDetails.swift` now draws its albums with
`AlbumGrid` (two across on a phone, as many as fit on an iPad) under Top
Songs, and asks for up to 500 albums rather than 100. The on-device artist
page in `Aquarium/Aquarium/Music/OnDeviceViews.swift` does the same; its
genre page keeps the shelf. Appears On, About and Similar Artists follow,
unchanged.

## Linux parity audit (2026-11-20)

What the Apple app (iPad and Mac layouts) does or shows that the Linux app
does not. Read from both sources, area by area, with a sample of the claims
re-checked by search; nothing here was compared on screen, and sizes,
spacing and the glass look still need Apple screenshots beside the Linux
app. Apple-only work is left out: SharePlay, AirPlay, CarPlay, the Watch,
widgets, Siri, iCloud, alternate icons, the foldable layouts, tvOS.
S / M / L is the rough size of the Linux work. Grouped into the phases the
work is planned in.

Already at parity: sign-in (discovery, saved servers, user list, Quick
Connect, accounts), the dark palette, sidebar width, Next Up and playback
settings, IPTV settings, the speed check before a stream (Linux always runs
it), keyboard and pointer basics in the player.

### Phase 1 — the player over the picture

Apple draws its controls over the video; Linux has one opaque 72 px bar
under it with twelve icon buttons. Files: `Player/Chrome/*.swift` against
`Linux/src/main.ts` (`pb-*`) and `styles.css`.

- **L** Three zones over the picture with scrims: title row (Back, title,
  PiP, "…"), centre skip / play / skip, bottom band (timeline, times,
  pills).
- **M** Labelled pills in order Info, Audio, Subtitles, Quality (showing
  Auto / Direct / rung / Downloaded), Up Next · N, Fill; Quality and Up
  Next hidden when they do not apply.
- **L** Cards (340 pt, header, vertical rows with a detail line and a tick)
  in place of the horizontal strip of buttons.
- **M** "…" card joining Speed, Sleep timer, Stop after this episode and
  Change channel; Linux has three separate buttons.
- **M** Quality card: Auto as the first row, then Downloaded, Direct,
  rungs, a note. Ladders differ: Apple 36/20/16/10/5/2.5 Mbps, Linux
  35/18/10/5/2.5.
- **M** Audio and Subtitles cards list the server's tracks, with the ones
  that reopen the stream marked; Linux lists mpv's current tracks only.
- **M** Info popover: poster, facts, overview, Coming Up ×3 on live, then
  the stream facts in three groups; Linux has a 12-cell fact strip.
- **M** Timeline: intro and credits spans marked, a larger trickplay
  preview riding above the thumb with time and chapter.
- **M** Live: programme progress, start, "N min left · ends HH:MM", a red
  LIVE capsule by the title.
- **M** Skip intro and the Up Next card float over the picture; a bitrate
  badge at the top says when quality moved (Linux toasts may sit under
  fullscreen video — unverified).
- **M** Error card over the picture with the diagnosed cause, and a "No
  picture in this stream" banner (`StreamDiagnosis.swift`).
- **S** Title is the episode name with "Series · S/E" above; Fill is
  remembered; running "+30 s" skip total; spinner in the play button;
  controls stay up while paused; right-click menu gains Quality, Up Next,
  Sleep, Stop After This Episode, Fill; a Stop key; Esc answers Up Next.
- **S** Track memory applied before the stream is asked for; Auto with a
  90 s grace after a manual choice; Up Next lists downloaded episodes when
  offline.

**Built 2026-11-21** (uncommitted, branch `linux-tiers`), within the bar:
the layering was left alone, so nothing is drawn over the picture. The bar
is two rows beside the title (timeline, then transport and labelled pills:
Info, Audio, Subtitles, Quality with its state, Up Next · N, Fill, "…").
A pill opens a card of rows in a band above the bar; the backend clips the
video off that band (`player_set_card_band`) without moving the picture.
Done: the Quality card with Auto first, Audio and Subtitles cards with
codec and layout, the "…" card (speed, sleep, stop after this episode,
change channel, and the ways into chapters, picture and delays), the Info
card (poster, facts, overview, on now / coming up, three fact groups),
intro and credits marked on the timeline, the live programme timeline and
LIVE capsule, the episode name as the title, Fill remembered, a running
skip total, controls up while paused, the right-click entries, Esc
answering Up Next, adaptive changes said in the bar.
Not done: controls over the picture and the centre cluster (needs the
video below a transparent page), server-side track lists that reopen the
stream, the 36/20/16 ladder, the larger trickplay preview, the error card
and no-picture diagnosis, track memory before the stream opens, Auto's 90 s
grace, downloaded episodes in Up Next offline, a Stop key.
Checked in the app on a local clip and on a server episode (Quality card,
pill states, Up Next count, intro mark, the card band windowed and
fullscreen). A live channel and the X11 backend were not run.

Linux keeps what Apple's chrome lacks: Stop, volume and mute on the bar,
Chapters, the Picture panel, subtitle and audio delay, the whole-season Up
Next strip, channel tiles with progress, the `?` sheet.

### Phase 2 — browsing

Files: `Views/{HomeView,LibraryView,SearchView,FavoritesView,ItemDetailView,
PersonView,ItemContextMenu,Components}.swift` against
`Linux/src/views/{home,library,favorites,item}.ts` and `ui.ts`.

- **L** Person page (portrait, dates, bio, Films and Shows); Linux searches
  the name.
- **M** Home hero: a random draw of six with FEATURED / NEXT UP / CONTINUE
  WATCHING, backdrop thumbnails, chevrons, arrow keys; Linux shows the
  first five Next Up with dots.
- **M** Home: Recently Played and New Music shelves; abandoned episodes
  cleared from Continue Watching (and its setting); a Refresh key.
- **M** Library: a name filter field; Runtime sort and Reverse Order;
  multi-select with batch watched / favourite; thumbnail size; a sticky
  header; paging without a button; a list (table) view; the A–Z index.
- **M** Search: scope All / Films / Shows / Episodes, music and audiobook
  results above the films, client-side ranking, Return opens an exact
  match.
- **M** Item page: Favorite button, Trailer button, a season page with its
  episodes and a Show › Season breadcrumb, tagline and studios, a Download
  button that shows its state, "N episodes · M watched".
- **M** Item page look: poster on a blurred wash of the backdrop, one
  accent capsule plus icon discs; Cast & Crew with directors and writers
  as tiles; compact episode rows.
- **S** Cards: year · runtime · rating, unplayed count as a badge.
- **S** Context menu: Play Next Episode, Go to Season, Copy Title, a
  download entry that follows state; Favorites gains two sorts.

**Built 2026-11-21** (uncommitted): the person page (`views/person.ts`,
cast and crew tiles open it); the Home spotlight as a random draw of six
marked Featured, with chevrons and arrow keys; the library name filter,
Runtime sort and Reverse, and "N films / shows"; search scopes and music
results above the films; on the title page a Favorite button, tagline and
studios, Cast & Crew with directors and writers, "N episodes · M watched",
and a season's address opening its show on that season; cards with year ·
runtime · rating and an unplayed badge; Play Next Episode, Go to Season
and Copy Title in the menu.
Not done: Recently Played and New Music on Home, abandoned-episode
clearing, a Refresh key, multi-select, thumbnail size, the sticky header,
the list view, the A–Z index, client-side search ranking, the Trailer
button (the app has no way to open a link or play a remote trailer), the
Download button's state, the blurred-wash header and compact episode rows.

### Phase 3 — music and audiobooks

Files: `Music/*.swift` against `Linux/src/views/{music,musicCommon,
musicPlayer,musicDownloads,books}.ts`, `stations.ts`, `audio.ts`.

- **L** Music with no server: offline Listen Now, on-device artist, album,
  genre and playlist pages, stations from downloads, saved playlists,
  favourites queued for sync. Linux allows only the flat Downloaded page.
- **L** Stations learn during a session (finished, skipped and removed
  songs re-deal the queue), the "What's leading in the mix" sheet, and
  Surprise Me's mood memory.
- **L** Now Playing as one column: source line, cover, title with a star,
  scrubber, transport, volume, a foot row; lyrics replace the cover, the
  queue slides over. Linux is two columns.
- **M** Library landing page of doors over Recently Added; a Favorites
  page; the A–Z index; Play / Shuffle on Songs.
- **M** Download state on every song row and book cover; menus that say
  Remove Download or Downloading…; Download on a playlist; a "Downloading
  N songs" banner.
- **M** Listen Now: greeting title, station cards with the seed's cover
  and a reason, more station kinds (favourite artists, Rediscover, Deep
  Cuts), a ranked Top Songs.
- **M** Search field always in view above Listen Now and Library; offline
  hits grouped as artists, albums, songs, playlists.
- **M** Audiobooks as one page with a Year sort; "42% · 5h 12m left";
  Pause / Resume on the book page; previous / next chapter; an offline
  Audiobooks tab and book page.
- **M** Page headers: colour wash, wide Play plus round Shuffle; artist
  hero with the name over the backdrop; About clamped with More.
- **S** Lyrics kept with downloads; floating mini player card; grouped
  Song Info; smart playlist Refresh and offline answer; genre Artists
  shelf.

**Built 2026-11-21** (uncommitted): downloaded music as a library of its
own (`#/music/downloaded/album/…` and `…/artist/…`, with Artists, Albums
and Songs on the Downloaded page and in offline search); with no server
the Music and Audiobooks sections show what is downloaded instead of the
offline screen; a download mark on song rows and on album and book
covers, and menus that say Download, Downloading… or Remove Download
(playlists can be downloaded); a Favorites tab; Play and Shuffle on Songs;
the greeting title, ranked Top Songs and See all on Listen Now; "47% · 4h
19m left", a Year sort, Pause / Resume on the book page and previous /
next chapter; About clamped with More; a star on Now Playing; an Artists
shelf on the genre page.
Not done: the one-column Now Playing, station learning with its "leading
in the mix" sheet and mood memory, the library landing page of doors, the
A–Z index, the "Downloading N songs" banner, more station kinds and the
station cards, lyrics kept with downloads, the floating mini player.
Checked in the app online: Listen Now, Favorites, Songs, a genre, an
artist, Audiobooks and a book page. Nothing that needs a downloaded song
or the server out of reach was run (this machine has no music downloads).

### Phase 4 — downloads and Live TV

Files: `Views/{DownloadsView,DownloadsView+Mac,DownloadedSeriesView,
TVGuideView,TVGuide+Mac}.swift`, `Core/DownloadSegments.swift` against
`Linux/src/views/{downloads,livetv}.ts`, `src-tauri/src/downloads.rs`.

- **M** Intro and credits markers kept with a download, so Skip works
  offline.
- **M** Picture subtitles burned into a transcoded download when chosen.
- **L** Downloads as one page (Downloading, Up Next, Failed, then Shows
  and Films) with "42 items · 120 GB · 310 GB free"; Linux has three tabs
  and no totals.
- **M** A downloaded show as one episode list under season headers with
  sizes; every delete confirmed with a count and bytes; multi-selection.
- **S** Show the downloads folder; Sync only when something waits; the
  "waiting for the server to encode" hint.
- **M** Guide: click selects, a popover follows, double-click tunes; a
  right-click menu; Linux opens a dialog on a programme and plays on a
  channel click.
- **S** Guide: Refresh on the page, channel count in the subtitle, filter
  matches what is on now, a failed fetch keeps the grid, the schedule
  extends itself, Earlier / Later move three hours, back to now after 30
  minutes away, zebra rows, genres in programme info.

**Built 2026-11-21** (uncommitted): intro and credits markers kept per
download (localStorage `aquarium-dl-segments:<id>`, written when a
download starts and when one is played online, read when the server gives
none, removed with the download); the storage line "268 items · 393 GiB ·
606 GiB free"; sizes on show and season headers; every delete of finished
files confirmed with its count and size; Show in Files for the downloads
folder; in the guide a Refresh button, "Today · 11 channels" and "1 of
11 channels" while filtering, a filter that also matches what is on now,
Earlier / Later by three hours, a banner with Retry on a failed fetch,
zebra rows, genres in programme info, back to now after 30 minutes away,
a right-click menu (Play Channel / Show Info / Copy Title) and
double-click to tune.
Not done: Downloads as one page, multi-selection, picture subtitles
burned into a transcode, the per-channel artwork report.
Checked in the app: the Downloads header and a show's page, the guide's
head, filter by channel name and right-click menu. Not run: Skip offline
from stored markers, a delete and its confirmation, Show in Files, the
fetch banner, double-click to tune, the 30-minute return.

### Phase 5 — settings and the shell

Files: `Views/{SettingsView,MacSidebar,PadSidebar,MacCommands,Theme}.swift`
against `Linux/src/views/settings.ts`, `main.ts`, `index.html`,
`styles.css`.

- **L** Settings in eight panes (General, Account, Video, Audio,
  Subtitles, Music, Live TV, Storage) with switches and segmented
  controls; Linux is one long page of selects.
- **M** Missing settings: power-aware quality, the speed check as a
  choice, Fit / Fill default, audio delay, "Forced only" subtitles, a
  Music pane (autoplay, normalize, romanize, Station Mix), download
  default quality and simultaneous count, a server status row, sign-out
  confirmation. Ranges differ for subtitle size, picture sliders, zoom and
  aspect choices.
- **L** Library Copy: the library kept on the device with Sync Now and
  Delete (`Core/LibraryIndex.swift`); Linux has only its screen cache.
- **M** Sidebar: groups Home / Libraries (Music and Audiobooks among
  them) / Live / You; an account menu with sync status; a now-playing
  strip at the foot; a badge on Downloads; row menus; collapsible.
- **M** Keys: sections by number, Refresh, Home, Live TV, Downloads, Play,
  favourite, watched, thumbnail size. Linux has `/`, `?`, Esc, Alt+←.
- **M** Offline: the sidebar reduces to Downloads and every page carries
  an "Offline — showing downloads" strip with Retry.
- **M** A title, a library or the player in its own window.
- **S** Look: radius 14 against 12; a sidebar colour of its own; 40 pt
  rows with a neutral selected fill and only the icon in accent; the
  light theme's accent and status colours differ from Apple's.

Linux keeps: hardware acceleration and audio device pickers, subtitle
position, Smooth motion, the unmetered / keep-awake download toggles.

**Built 2026-11-21** (uncommitted). Settings: eight panes at
`#/settings/<pane>` (General, Account, Video, Audio, Subtitles, Music,
Live TV, Storage) with the last one remembered, switches for on/off and
segmented controls for Theme and Fit / Fill, in `src/settings.css`; a
sign-out confirmation, a server Status row, the Fit / Fill default, an
audio delay picker, "Forced only" subtitles, the speed check as a switch,
Normalize volume and Station Mix under Music, simultaneous downloads and
Show in Files under Storage; subtitle size as 60–180 %, two more aspect
ratios. Shell: the sidebar as Home / Libraries (Music and Audiobooks
among them) / Live / You, an account control at its foot with a menu
(switch account, Add Account, Settings, Sign Out), a count on Downloads,
an offline strip with Retry over a reduced sidebar, Ctrl shortcuts
(1–9, R / F5, [, Shift+H, F, Shift+L, Alt+J, comma), radius 14, a sidebar
colour of its own, 40 px rows with a neutral selected fill.
Not done: power-aware quality, romanize names, a default download
quality, the Library Copy, separate windows, a collapsible sidebar, row
menus, a now-playing strip in the sidebar, thumbnail-size keys. The light
theme keeps its darker accent and status colours for text (Apple's fail
4.5:1 on white); Apple's values are used for marks only.
Checked in the app: the sidebar groups and metrics, the account menu, the
shortcuts, the panes, the sign-out dialog (cancelled). Not run: the
offline strip and reduced sidebar, the Downloads badge with a transfer in
flight, account switching, "Forced only" against a file, any setting
actually changed.

### Phase 6 — the desktop

No Apple source; these are the Linux counterparts to Spotlight, Siri and
the icon's menu: a GNOME Shell search provider, and launcher actions for
Continue Watching, Shuffle Music and Resume Audiobook.

**Built 2026-11-21** (uncommitted), in `Linux/src-tauri/src/desktop.rs`,
`Linux/src/desktop.ts` and `Linux/src-tauri/desktop/`:

- Launcher actions in the `.desktop` file: Continue Watching, Shuffle
  Music, Resume Audiobook, each `aquarium --action=<name>`. A running app
  takes the action over D-Bus (`dev.aquarium.app`, `Activate`) and comes
  to the front, so no second window opens; with none running the app
  starts and its page takes the action.
- GNOME Shell search: `aquarium --search-provider`, started by D-Bus
  activation, answers `org.gnome.Shell.SearchProvider2` from
  `~/.local/share/aquarium/search-index.json` — the names of the
  library's films and shows, written by the app at most every six hours
  and removed at sign-out. No server and no token in the provider. A
  result opens the title's page; "show more" opens the app's search.

Checked with the built binary: an action at launch, a second launch
handing its action to the running app, the provider's answers over D-Bus,
the files inside the `.deb`. Not seen: the shell itself showing results
or the launcher menu, which need the `.deb` installed; Continue Watching,
Shuffle Music and Resume Audiobook were not run (they start playback).
Episodes, music and audiobooks are not in the index.

## Requests

### Asking for films and shows through Seerr

**Wanted:** Seerr fully part of the app, not a web page inside it, and held
to the same security as the Jellyfin connection.

**Built 2026-11-16** (branch `claude/seerr-requests`), Apple app and Linux
app. `Aquarium/Aquarium/Core/Seerr/` is the client (its header comment has
the security rules: Quick Connect sign-in with the app's own Jellyfin
session, no password kept, no admin API key, session in the keychain, cookie
to one origin, posters through Seerr only). `Aquarium/Aquarium/Views/Seerr/`
is the screens: a "Not in Your Library" row in Search, a request page per
title, a Seerr page (called Requests until 2026-11-16; your requests as one carousel, then Trending /
Popular / Upcoming; a notice when Seerr's Cache Images is off, since Seerr
then serves no posters), a missing-seasons banner on a show, missing films on a collection
and on a person, "Like This, Not in Your Library" on a film's, show's,
season's and episode's page, and Settings → Account → Requests. Linux: `Linux/src/seerr.ts`,
`Linux/src/views/requests.ts`, `Linux/src-tauri/src/seerr.rs`.

**To do:**

- Check against a real Seerr server (the tests use a stand-in; see
  `Aquarium/TESTING.md` and each platform's `MANUAL.md`).
- Build and run the Linux side on the Linux machine: it was written on a Mac
  with no Node or Cargo and has never been compiled.
- Not built, by choice: approving or declining as an administrator, reporting
  a problem with a title, a Home row of requests, notifications, the Watch.
- Apple TV: after Request is pressed, focus goes to the tab strip instead of
  Cancel Request.

## Watching together

### SharePlay: start from whose progress

**Wanted:** on a SharePlay call where each person has their own account
(same Jellyfin server or not), a question asking whose saved spot everyone
starts from.

**Built 2026-11-18**, iPhone, iPad and Mac (`Aquarium/Aquarium/Core/SharePlay.swift`,
the alert in `Player/PlayerScreen.swift`, rows in `Player/Chrome/PlayerMenus.swift`
and `Player/PlayerMacMenus.swift`). Each device sends its account's saved
spot (`SharedProgress`) over the session; the person who put the title on is
asked "Start from whose progress?" (you, each friend with a spot, From the
Beginning); the pick is a seek, which the coordinator makes everyone's.
"…" → Start From Someone's Progress… asks again. A device that joins now
opens at the start and is placed by the coordinator, instead of seeking to
its own spot (which would have moved everyone).

**To do:**

- Try it on a real FaceTime call (iPhone MANUAL.md); no simulator can.
- Fixed the same day: "Start Only for Me" no longer shows an error; no
  `aquarium://` fallback link (the App Store is offered instead); the
  invitation carries the poster; streams are matched by the item id in the
  address (no main-actor read, which could trap); a joiner whose server or
  account can't open the title is told and leaves; an mpv joiner switches
  engine even with Settings set to mpv, and only for the session's title;
  closing the player leaves SharePlay; End SharePlay for Everyone; "Alex
  paused / played / jumped to 23:10" toasts; with no call on, iPhone and iPad
  open the system's SharePlay sheet to start one.
- Linux: no SharePlay (Apple only).

### SharePlay on the Apple TV

**Wanted:** SharePlay on the Apple TV as well.

**Built 2026-11-18** (`Core/SharePlay.swift`, the part at the end;
`Player/PlayerModel+Group.swift`; `Aquarium-tvOS.entitlements`). The Apple
TV's player is mpv, so its session is joined through an
`AVDelegatingPlaybackCoordinator`: the coordinator's orders (play from here
at this moment, pause, seek) are carried out on mpv, and the remote's
play/pause and jumps are asked of the coordinator. Swipe down in the player
→ Watch Together tab. An Apple TV and an iPhone can be in the same session.

**To do:**

- Never run in a real session: no simulator has FaceTime. Check on the Apple
  TV with a call on it, or one moved to it from an iPhone (TV MANUAL.md).
  What SyncPlay shares with it (the player's group seam) is tested.
- The Apple TV has no system sheet to start a call from: with no call on it
  says to start one first.

### "TV shows don't have SharePlay" (reported 2026-11-18)

**Fixed 2026-11-18**, two causes found:

- Watch Together was last in the "…" card, under Speed, Sleep timer and
  After this. An episode is the title with all three, so on a phone held
  sideways it was below the fold. It is first in the card now.
- An episode that is downloaded plays from the download, and Watch Together
  was never offered on a download. It is now: choosing it leaves the
  download for the server's stream at the same moment. A device joining a
  session also opens the server's stream rather than its own download,
  which the coordinator could not match to anyone else's.

**To do:** confirm on the phone which of the two it was.

### SyncPlay (Jellyfin's own watch-together)

**Wanted:** the Jellyfin equivalent, under SharePlay, on iOS and tvOS.

**Built 2026-11-18**, iPhone, iPad, Mac ("…" card) and Apple TV (Watch
Together tab): `Core/SyncPlay.swift`, `Core/SyncPlayWire.swift`,
`Player/Chrome/WatchTogether.swift`, `Player/PlayerModel+Group.swift`.
"Watch Together with SyncPlay" asks which of the server's groups to join, or
starts one named for you with what is playing put on. Everyone in the group
is on the same server; pause, play and jumps are everyone's; a device that
runs dry holds the rest; the next thing anyone plays is put on for the
group. No FaceTime call, and it works with people in a browser or another
Jellyfin client. Settings has a SyncPlay row (Account page on the Apple TV)
for joining with nothing playing. One of SharePlay and SyncPlay at a time.

**To do:**

- Tested against the QA server with a scripted second person
  (`PhoneSyncPlayTests`, `TVSyncPlayTests`). Not yet tried with two real
  devices side by side, or with Jellyfin's web client in the group.
- The group plays at normal speed (the speed chips are hidden in a group).
- Not built: the group's queue beyond one title (add next, reorder), who
  pressed pause (the server doesn't say), a SyncPlay item in the Mac's
  Playback menu (it is in the "…" card), Linux.

## Brand

### One-word wordmark ("aquarium" with a bubble for the i's dot)

**Wanted:** the name drawn as one word. "Aqua·rium", with its two weights and
two colours, came from FellyJin, where the split joined two real words.
Option 03 of the sixty on the wordmark page was picked on 2026-11-20.

**Built 2026-11-20**, every platform. The Apple app has `Shared/Wordmark.swift`
(SF Rounded heavy, lowercase, a dotless i with a purple `WordmarkBubble`
over it, read as "Aquarium"). It is compiled into the app, the watch app and
the watch widgets, and drawn in `BrandMark`, both sign-in headers
(`LoginView`), the tent idle screen, and the watch widget's empty state. The
tvOS Top Shelf images are redrawn by `Tools/IconGenerator` (`drawWordmark`).
Linux has `wordmark()` in `src/ui.ts` and `.wordmark .wm-i::after` in
`styles.css`, used in the sidebar (`index.html`), the sign-in card and
Settings → About.

**To do:**

- Linux has no bundled rounded face, so it uses one only if the system has
  one, otherwise Inter. Bundle Nunito (`@fontsource-variable/nunito`) if Inter
  looks too square next to the Apple app.
- The watch's navigation title and the "Aquarium" storage label stay plain
  text (system title, data label).
- Check the bubble by eye on hardware (iPhone MANUAL.md "The wordmark", Linux
  TESTING.md 29, the Top Shelf in TV MANUAL.md §4).

## Phone layout

### A top bar that floats over the artwork

**Wanted:** the iPhone's solid band at the top looked clunky. Something
modern that fades, or sits on the posters, and hides as little of them as
possible. Ten mock-ups on 2026-11-20; option 6 (a progressive blur) was
picked and then cut down three times until only the clock strip was blurred.

**Built 2026-11-20**, iPhone (`Views/PhoneHeroBar.swift`, used by `HomeView`
and `ItemDetailView`). The hero and a title's artwork run to the top of the
screen; the wordmark with Search and Refresh, or Back, float on it in white.
Behind the clock is a blur with no tint of its own, so it takes the
poster's colours, and it ends at the bottom of the status bar. Once the
artwork has scrolled away the blur reaches past the bar's row, the glyphs
turn the page's colour, and a title page shows its name beside Back.

**Built 2026-11-20, iPad and Mac** (`Views/HeroBarBlur.swift`). The iPad's
floating bar used to gain a tinted band with a hairline once the page scrolled;
it now has the same untinted blur, thin under the clock over artwork and
deeper once the page is under it. On the Mac, Home's hero and a title page's
wash now run up under the window toolbar instead of starting below a band, and
the same two-step blur sits pinned beneath the toolbar (the window-colour wash
across the top of the hero is gone).

**Built 2026-11-21, every solid bar** (`BarBlur` in `Views/HeroBarBlur.swift`,
`TopBarFrame` in `Views/Components.swift`). No page draws a solid band any
more. The iPhone Duo floats `PhoneHeroBar` on Home and title pages too, on
both screens, in the frame its solid bar took — below the front screen's
dead touch strip, on the inside screen's status strip when held upright —
with the artwork reaching up by that much. Search and Live TV keep
`AppTopBar` with the blur under it instead of the band and hairline (Live
TV's header stands above the guide rather than over it, so there the blur
has only the page under it).

**Fixed 2026-11-21, no blur on the Duo until the page scrolled.** Over
artwork the blur covered only what the status bar took above the bar, and on
the Duo's front screen and its inside screen held sideways that is nothing
(the safe area's top is zero), so the bar had no blur until the page had
scrolled past the hero. The blur over artwork is now never shorter than 47
points (`BarBlur.least`, what an iPhone 17 has): there it starts at the top
of the screen and eases out behind the bar's row. Phones with a shorter
status bar come up to the same 47: an iPhone SE had 8 points of blur, a
notched iPhone 35, an iPhone 15 or 16 42. An iPhone 17 and the Pros are
unchanged.

**Changed 2026-11-21, the thin blur is for the top of the page only, and it
grows instead of crossfading.** The blur kept to the strip under the clock
until the hero had scrolled right out from under the bar (420 points on
Home, 330 on a title; 180 and 80 on an iPad; a hero's height on a Mac), and
then crossfaded to the whole one, which stuttered: a system blur that is
partly transparent stops blurring, so the fade passed through a moment of
no blur. Now it is one blur whose reach and strength follow the first 32
points of scrolling (`BarScroll`), under the finger and back again, on
iPhone, the Duo, iPad and Mac. The glyphs still turn from white to the
page's colour, and the wordmark or title still arrives, where they did.
With the strong blur now over artwork, its view also fades out at the foot:
the filter leaves what it does not blur slightly soft, which drew a line
across the picture where the view stopped. Seen on the Duo simulator; the
iPad and the Mac were built and unit-tested but not looked at.

**Changed 2026-11-22, iPhone and Duo: bare at the top, glass discs on
scroll, no blur.** The user first asked for no blur at all (just the logo,
wordmark and buttons); built, uploaded as 1.6 (14) and rejected on sight,
because the bare bar was unreadable once rows scrolled under it. Of five
ideas they picked this one: at the top of the page the bar is bare and white
on the artwork; as the page moves the wordmark fades out and Search, Refresh
and Back each take a disc of the system's glass, the tab bar's material. A
title's name no longer comes into the bar. The system's own scroll-edge blur
under the clock is switched off on these two pages. The iPad, the Mac, Search
and Live TV keep the blur bar for now.

**To do:**

- Decide whether the iPad and the Mac (and Search / Live TV) follow the
  phone's bare-then-discs bar or keep the blur.
- The clock sits straight on whatever scrolls under it on Home and a title.
- The untinted blur is the backdrop's `variableBlur` filter, which UIKit
  does not publish (looked up by name, with a paler masked blur if it ever
  stops answering); on the Mac it goes on `NSVisualEffectView`'s backdrop
  layer, which AppKit builds only after the first layout. Watch App Review.
- Check dark mode and a real iPhone by eye (iPhone MANUAL.md, "The floating
  top bar"), and the Duo's inside screen held upright on hardware (the
  simulator's hinge was checked closed, half-open and open, sideways).

## Delete from Server (2026-11-26)

**Wanted:** a Delete option in the press-and-hold / context menu that asks
which way: delete the file through Jellyfin, or remove the title through Seerr
(Radarr for a film, Sonarr for a show) along with its request. Seerr's way only
when Seerr really has Radarr/Sonarr set up.

**Today:** "Delete from Server…" on films, shows, seasons and episodes, on
iPhone, iPad, Mac, Apple TV and Linux (`Views/ServerDelete.swift`, Linux
`src/ui.ts`). Jellyfin's way follows the server's `CanDelete` for the item.
Seerr's way needs Manage Requests or Admin, a Radarr/Sonarr server in Seerr for
that kind of title, and Seerr's record of the title on one; it removes the
title there (files too), then its requests and Seerr's record. Whole films and
shows only. Downloaded copies are kept.
The dialog's buttons are "Delete from Jellyfin", "Delete from Seerr" and, when
both are open, "Delete from Both" (Seerr's way first, then Jellyfin's; if Seerr
refuses, nothing is deleted).

**To do:**

- Tried against a real Seerr 3.5.2, Radarr 7 and Sonarr 4 on 2026-11-26
  (`AquariumQA/arr`; `PhoneServerDeleteLiveTests`, then the iPad, Mac and
  Apple TV classes and Linux's `tests/integration/seerr-real.test.ts`). That
  found two faults, both fixed: the title page had no entry at all (only the
  press-and-hold menu), and Seerr's way was hidden unless Seerr's record
  linked the title to Radarr/Sonarr, which Seerr itself does not need (it
  removes by TMDB/TVDB id from its default server). All four Apple
  platforms pass, both from the title page and the press-and-hold menu.
  Linux's Seerr code passes against the real Seerr; the Linux app itself
  (Rust, the window) is still never built or run on the Mac.
- After Seerr's way, Jellyfin keeps listing the title until its next library
  scan; the app only hides it from its own copy of the library.
- Music, collections and playlists are not covered.
