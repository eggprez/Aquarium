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
