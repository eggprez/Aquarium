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
