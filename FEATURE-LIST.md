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
- Still not built: SharePlay on the Apple TV (its player is mpv, which
  would need an `AVDelegatingPlaybackCoordinator`).
- Linux: no SharePlay (Apple only).
