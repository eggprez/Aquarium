# Aquarium for iOS, iPadOS, tvOS, macOS and watchOS

A native SwiftUI port of [Aquarium](../README.md), the Linux Jellyfin client.
Everything under this directory belongs to the Apple build; nothing in it is
shared with, or read by, the Linux/Tauri project in the parent directory.

> Built with AI assistance (Claude), like the Linux original. Personal project,
> shared as-is, no guarantee of updates or support.

One Xcode target builds all four systems (`SDKROOT = auto` with a multiplatform
`SUPPORTED_PLATFORMS`), so the core is compiled once and only the shell differs:
a tab bar on iPhone, a sidebar on iPad and Mac, and the top tab strip on Apple
TV. A second target, `TopShelf`, is the Apple TV home screen extension; it is
built and embedded on tvOS only, through a platform filter on the dependency,
so an iPhone or Mac build never sees it. The Apple Watch app is a target of
its own, `AquariumWatch` (with `WatchWidgets` for its Smart Stack card),
embedded in the iPhone build the same way — see *Apple Watch* below.

## Building

Requires Xcode 26 or later. Open `Aquarium.xcodeproj`, pick a destination and
run — there are no package dependencies to resolve and nothing to install first.

```sh
xcodebuild -project Aquarium.xcodeproj -scheme Aquarium \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Deployment targets are iOS/iPadOS 17, tvOS 17, macOS 14 and watchOS 10.

**Apple TV note:** compiling the tvOS asset catalogue needs a tvOS simulator
runtime matching the SDK installed, even for device builds. If the build stops
with *"No simulator runtime version … available to use with appletvsimulator
SDK"*, install it from Xcode → Settings → Components, or:

```sh
xcodebuild -downloadPlatform tvOS
```

## What carried over

Everything the Linux build does, with the exceptions listed further down.

- **Streaming** — direct play when this device can open the file, and Jellyfin's
  HLS otherwise, at rungs of 20 / 10 / 4 / 1.5 Mbps.
- **Adaptive quality** — the same policy as `adaptive.ts`, thresholds included:
  it drops a rung when a stream keeps stalling or frames are being dropped,
  climbs back after five clean minutes with a healthy read-ahead, never goes
  above the quality you chose, never touches downloads or Live TV, and never
  retries a rung that failed on the way up. Switchable per session from the
  player and for good in Settings.
- **Downloads** (iPhone, iPad, Mac) — original or transcoded, whole seasons and
  whole series, a concurrency limit, retry and bulk retry, resume across
  relaunches, and the disk-space check that tells you what a season would need
  and offers the rungs that would fit.
- **Offline progress sync** — watching a downloaded file records position and
  watched state locally and pushes it back to Jellyfin when the server is
  reachable, at launch, after local playback, or on demand.
- **Live TV** — the channel list with current-programme info, played through
  `PlaybackInfo` + `AutoOpenLiveStream`.
- **Detail pages** — cast (each name searches for itself), "More like this" from
  the server's own recommendations, and the line describing what the source file
  actually is (`1080p · HEVC · EAC3 · 5.1 · 8.4 GiB`).
- **Skip intro / skip credits** from Jellyfin's media segments, and the **Up
  Next** card over the closing stretch of an episode with autoplay behind it.
- **Shuffle** over a downloaded series, drawing without repeats until the pool
  is spent.
- **Sleep timer** — 15/30/60/90 minutes, or "stop after this episode".
- **Per-series track memory** — override the audio or subtitle language for one
  show and the next episode opens the same way.
- **Security** — the token lives in the keychain, is sent as a header and never
  in a URL, and the server's identity is pinned at sign-in: if the saved address
  ever answers as a different Jellyfin install, the app stops rather than signing
  in to it.
- Home, with a media bar across the top rotating through films and shows drawn
  at random from the library — a fresh draw every time you return to the Home
  tab or come back to the app — then Continue Watching, Next Up and what's new
  in each library. Plus library browsing with sorting/filtering/paging, search
  with recent terms, favourites, watched toggles, light/dark/auto theme
  (everywhere but Apple TV, which is dark and only dark), offline mode with a
  backing-off reconnect probe, and progress reported to the server every 10 s.

## What is different on Apple TV

A remote is not a finger, and the differences that follow from that are the
whole of it — nothing here is a reduced version of a feature:

- **An episode row is one control.** A row can hold exactly one action on tvOS,
  because the focus engine gives the whole row a single focus target and a
  button drawn inside it could never be reached. Pressing a row plays the
  episode, which is what the play glyph on it promises; holding it opens the
  episode's own page.
- **Search and the channel filter have their own field** on the page, rather
  than the `searchable` box the other platforms put in a toolbar. A search is
  remembered once you open one of its results — a search that fires on every
  letter typed would otherwise fill the recent list with prefixes.
- **Screens reload when the player closes** instead of when you pull them down.
  There is nothing to pull, and a tab keeps its view alive when you switch away
  from it, so Home would otherwise still be offering the episode you just
  finished.
- **Focus is drawn from this app's own palette** — rows and tiles lift and take
  an accent border rather than the system's light focus background, which would
  put white text on a white field.
- **No Downloads and no theme setting**, for the reasons in the table below.
- **The home screen's top shelf is Next Up** — the same list Home shows, as
  series posters, with a progress bar on anything part-watched. Selecting one
  opens its page; pressing Play on a focused poster starts it.
- **Signing in is two presses** where the server allows it: the server from
  the list under the address field, then a Quick Connect code approved from
  a phone. The password form is a link away for a server without it.

## What Apple platforms add

None of this was possible on the Linux build, and all of it comes from using
AVFoundation rather than an embedded mpv window:

- **Quick Connect and finding the server.** The sign-in screen lists the
  Jellyfin servers that answer on the local network (the same UDP question
  Jellyfin's own apps ask), so the address is a press rather than a URL typed
  on a remote. A server with Quick Connect turned on offers a six-digit code
  instead of a password: the code is approved from any device already signed
  in — Settings → Server → Quick Connect in this app on a phone or a Mac, or
  the Jellyfin web app — and the screen signs itself in the moment it is. An
  Apple TV leads with the code; a phone keeps the password first and offers
  the code beside it. On a physical iPhone or Apple TV the network probe needs
  Apple's `com.apple.developer.networking.multicast` entitlement, which is
  granted on request; without it the list simply stays empty and the typed
  address works as before.
- **Spotlight, Siri and the home screen** (iPhone, iPad, Mac). Every film,
  show and episode the app has seen is in the system's search and opens its
  page from there; "Continue watching in Aquarium", "Play <title> in
  Aquarium" and "Show <title> in Aquarium" work by voice and in Shortcuts with
  nothing to set up; and the app icon's press-and-hold menu leads with
  whatever Continue Watching would. Something playing on the phone can be
  picked up on the iPad or the Mac through Handoff, at the same point.
- Picture in Picture, and AirPlay to another device.
- The lock screen, Control Centre and Now Playing transport, plus media keys on
  a Mac keyboard and the Siri Remote on Apple TV — the counterpart to MPRIS.
- Background audio, and downloads that keep running with the app suspended.
- Hardware decoding with nothing to configure.

## Music and Audiobooks (iPhone and iPad)

A Music tab appears whenever the server has a music library, and an
Audiobooks tab whenever it has a books library. They are the Apple Music shape
in this app's palette, kept deliberately apart from each other — a book never
turns up in a music row, list or search, and the other way round — and none of
it exists on the Linux build.

- **Listen Now** — what you were in the middle of (audiobooks), the covers you
  played last, stations the server builds from the artists and genres you play
  most (Jellyfin's Instant Mix), your top songs, what was added, what you have
  starred, and a random draw from the shelves.
- **Library** — playlists, artists, albums, songs, genres, favourites and
  what is downloaded, each with a filter field and a sort menu; then the
  covers most recently added.
- **Playlists** — made, renamed and deleted on the server from the app;
  songs, albums, artists and genres go in from any press-and-hold ("Add to
  Playlist", or "New Playlist…" with them in it); a playlist's Edit mode
  drags to reorder and swipes to remove, each change saved as it is made.
- **Smart playlists** — rules rather than lists: genres, artists, a year
  range, added in the last so many days, played or never played, a play-count
  floor, favourites only, an order and a limit. Jellyfin has no such thing, so
  they live in this app's settings (and travel with them over iCloud), are
  answered from the library each time they are opened, and can be frozen into
  a real playlist on the server at any moment.
- **Lyrics** — in Now Playing, where the server has an .lrc beside the file
  or words in the tags. Timed lyrics light the line being sung and keep it in
  view; tapping a line goes there.
- **Pages** — an album with its tracks by disc and "More by"; an artist with a
  backdrop, top songs, albums, "Appears On", a biography and similar artists;
  a genre; a playlist.
- **Audiobooks** — its own tab: what you are partway through with the time
  left, what was added, the authors as a row of names (the server's artist
  pictures are wrong for authors more often than not), every book by title,
  author, date added or last played, and a search of its own. A book's page
  has its chapters, resume point, speed and an author page behind it; the
  player skips fifteen and thirty seconds rather than tracks, and the mini
  player names the chapter.
- **Playing** — a mini player above the tab bar on every screen, opening into
  Now Playing: blurred cover, scrubber, previous/play/next, the system volume
  slider, AirPlay, shuffle, repeat, a reorderable Up Next, a sleep timer, and
  Play Next / Play Later / Start Station on every press-and-hold. Tracks join
  gaplessly; when the queue runs out it carries on with songs like the last one
  unless told not to in Settings. Starting a film stops the music and the other
  way round.
- **Streaming** — the original file (FLAC, ALAC, MP3, AAC, WAV, AIFF, CAF)
  whenever this device can read it, AAC from the server when it can't (Ogg,
  WMA, and the rest). On cellular a lossless file is sent as 256 kbps AAC
  unless "Lossless on cellular" is on. Play counts, "recently played" and an
  audiobook's position are reported to the server the same way video is.
- **Downloads** — songs, whole albums and audiobooks, always the original
  file, through the same queue as video downloads; they play from Library →
  Downloaded with no server, and the audiobook's position syncs back later.
- **Background** — songs, audiobooks, films and Live TV all carry on with
  the screen locked or the app behind another: the video player keeps its
  sound and drops the picture, and the lock screen shows what is playing.
- **Everywhere else** — Home gains "Recently Played" and "New Music" rows, and
  the Search tab shows artists, albums, songs and audiobooks above the films.
- **CarPlay** — Listen Now, Library and Audiobooks as CarPlay lists over the
  system's Now Playing screen. The scene is declared but needs Apple's
  `com.apple.developer.carplay-audio` entitlement on the App ID and in the
  provisioning profile before a car will show it.

With both libraries the tab bar becomes Home, Music, Audiobooks, Search, More;
the video Library, Live TV and Downloads move into More. With one of the two
the Library keeps its place. The Mac and Apple TV hide the tabs until they get
a pass of their own.

## Apple Watch

Audiobooks and music on the wrist, from the same server, with the phone doing
the signing in. `Watch/` is the app and `WatchWidgets/` its Smart Stack card;
`Shared/WatchSyncTypes.swift` is what the two devices say to each other and is
compiled into both the iPhone app and the watch app.

- **Signing in is nothing.** The iPhone hands the watch the server, the
  account and the token over WatchConnectivity (`Core/WatchLink.swift` on the
  phone, `Watch/WatchLink.swift` on the watch) as the application context, so
  it is waiting for the watch whenever it next wakes. Signing out on the phone
  signs the watch out too. The watch keeps the token in its own keychain and
  uses a device id of its own, so the server sees it as its own session.
- **It talks to the server itself.** With Wi‑Fi, cellular or the phone's
  connection, the watch browses the library — audiobooks; music by playlist,
  album, artist, song and genre; search — and streams from it, through a
  `PlaybackInfo` with a watch-sized profile: MP3, AAC and ALAC as they are,
  anything else as an AAC transcode over HLS. `Watch/WatchClient.swift` is
  the client, small on purpose; it shares only `Core/Models.swift` and
  `Core/Formatting.swift` with the phone.
- **Downloads are AAC at 128 kbps**, one file per song or book. On Wi‑Fi of
  its own the watch fetches on a background `URLSession`, so a book keeps
  arriving with the wrist down. Through the phone's Bluetooth link a
  background session is throttled to a crawl, so there the watch asks the
  phone instead: the phone fetches the file on a background session of its
  own (`WatchLink`'s relay), measures it, and hands it across as a
  WatchConnectivity file transfer, which runs in the background on both ends
  whether or not they are in reach at the time. The server's progressive
  transcode has no length it can promise, so every file that lands is opened
  and measured against the item's runtime before it is believed, and asked
  for again if it came up short. Songs, albums, playlists and audiobooks can
  each be kept; a playlist kept is saved with its order.
- **Two things are kept on the watch without asking**: audiobooks the account
  is part-way through, and the playlists picked for the watch on the phone
  under Settings → Apple Watch. The phone sends the ids; the watch fetches
  the rest, and the phone carries them when the watch has no Wi‑Fi. Nothing
  is ever removed automatically.
- **Listening goes back the way the phone's offline sync goes.** Where a book
  was left, and each song heard to its end, is queued on the watch
  (`WatchSyncQueue`) and sent to the phone when it is in reach, which tells
  the server — a stopped report for a position, the played-items route with a
  date for a play, so play counts and "recently played" move. With the phone
  away and a network of its own, the watch tells the server directly. A
  streamed play was counted by the server when the stream started and is only
  told where it stopped.
- **Storage is managed from either end.** On the watch, On Watch lists what
  is there by book, playlist and album with a swipe to remove, and the room
  left. On the phone, Settings → Apple Watch shows the same list as the watch
  last reported it, removes any of it, and can clear the watch. Every
  album, playlist, song and book in the phone's press-and-hold menu has a
  *Download to Apple Watch*.
- **Now Playing** is the system's: the crown, the Now Playing app on the
  watch face, AirPods. Books get 15 back and 30 forward, a speed and their
  chapters; songs get previous and next. A Smart Stack widget shows what is
  playing or the book last left, and opens it.
- **Siri**, on the watch and on the phone alike: "Resume my audiobook in
  Aquarium", "Play *book* in Aquarium", "Play *album or playlist* in
  Aquarium", "Shuffle my music in Aquarium" — and on the phone, iPad and Mac
  also "Play some *genre*". `Core/MusicIntents.swift` has the phone's,
  `Watch/WatchIntents.swift` the watch's.
- **The icon** is the same mark composed for a circle — `circleIcon` in
  `Tools/IconGenerator/brand.swift` — since watchOS masks every icon into one.

The watch app is `WKRunsIndependentlyWithCompanionApp`: it runs, browses and
plays with the phone switched off, as long as it has been signed in once.

## What did not carry over, and why

The Linux build drives mpv, which can open essentially anything and exposes
every knob it has. AVFoundation is narrower, and rather than ship controls that
would quietly do nothing, these are absent:

| Linux | Apple | Why |
|---|---|---|
| MKV direct play | Server remuxes to HLS | AVFoundation cannot open Matroska at all. When the video and audio codecs are ones it can decode the server **rewraps** the same bitstream — no re-encode, no quality loss. Only DTS, TrueHD, VP9 and similar make it do real work. |
| Brightness / contrast / saturation / gamma | — | No API adjusts the picture of a stream. |
| Aspect-ratio override, zoom slider | Fit / Fill | `videoGravity` is the whole of the picture control AVPlayer has. Fill still solves the case the zoom slider existed for: a 2.35:1 film on a 16:9 screen. |
| Night mode (dynamic range compression) | — | No equivalent for AVPlayer. |
| Audio output device picker | AirPlay picker / system output | Route selection belongs to the system here. |
| `hwdec` choice, mpv binary path | — | Nothing to choose; decoding is hardware by default. |
| Subtitle position | Size and background only | `AVTextStyleRule` styles the WebVTT tracks HLS carries, but has no vertical position. |
| Downloads on Apple TV | Not offered | tvOS has no storage a large file can be kept in — the system evicts app data whenever it likes. |
| Light / dark theme on Apple TV | Always dark | A television is a dark room by definition and the focus engine assumes it, so the palette there is fixed. A control offering a light mode that the app's own colours would ignore is worse than no control. |
| Subtitle size slider on Apple TV | Six steps | There is no slider a remote can drive; the steps span the same 60–180%. |
| Downmix to stereo (client-side) | Asked of the server | Implemented through `MaxAudioChannels` in the device profile instead. |

## Layout

```
Aquarium/
  Core/        Jellyfin API, models, preferences, keychain, downloads,
               offline progress, image loading, BlurHash, shell state
  Player/      AVPlayer model, adaptive-quality policy, Now Playing, the
               player screen and its AVKit surface
  Views/       Login, Home, Library, Search, Item detail, Favorites,
               Live TV, Downloads, Settings, shared components, theme
Shared/        The one file the app and the TopShelf extension both compile
TopShelf/      The Apple TV home screen extension (tvOS only)
```

`Core/` has no UI in it and no platform conditionals beyond the download
manager; `Views/` and `Player/` branch on platform where the systems genuinely
differ.

## Storage

- Session, preferences, download queue: `UserDefaults`
- Access token: the system keychain (`kSecAttrAccessibleAfterFirstUnlock`, so
  background downloads and progress sync still work with the screen locked)
- Downloads: `Application Support/Aquarium/Downloads/<itemId>/`, each with a
  `meta.json` beside the media file and excluded from backup
- Top shelf (tvOS): `group.<bundle id>/TopShelf/` — a small JSON manifest
  and one poster JPEG per Next Up entry, rewritten each time Home refreshes and
  deleted on sign-out. The extension is given no server address and no token; it
  reads these files and nothing else.

## Signing

The project is set to automatic signing. To run on your own hardware, set
`PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` in the target's build
settings to your own; nothing else in the tree hard-codes either.

The tvOS build additionally needs a `group.<bundle id>` app group, which
the app and the `TopShelf` extension use to pass the shelf between them
(`Aquarium-tvOS.entitlements` and `TopShelf/TopShelf.entitlements`). Automatic
signing registers it the first time it builds for a device; changing the bundle
identifier means changing the group id in both files and in `TopShelfPaths` to
match. Nothing outside tvOS uses it — the other platforms keep
`Aquarium.entitlements` as it was.
