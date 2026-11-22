//  Music and audiobooks in the main app: the Music tab, the mini player, Now
//  Playing, lyrics, playlists, smart playlists, stations and the Audiobooks
//  tab. See TestID.swift for the naming rule.
//
//  The music screens are built for iPhone, iPad and the Mac's iPad-shaped
//  build (`#if os(iOS)`); Apple TV has no music UI. CarPlay's templates are
//  not SwiftUI views and carry no identifiers.
//
//  KEYS
//  - Cards, rows and songs are keyed by the Jellyfin item id.
//  - A shelf is keyed by its English heading made safe with `TestID.key`
//    ("Recently Played" is `recently-played`): the shelf components are
//    generic and the heading is the only thing they know. Headings are
//    literals in the code, not translated.

import Foundation

extension TestID {

    // MARK: - Music tab, library, detail pages, search, on-device pages

    enum Music {
        // The tab
        static let root = "music.root"
        /// The Discover / Library segmented switch in the navigation bar.
        static let pagePicker = "music.tab.pagePicker"
        /// One segment of the switch: `discover` or `library`.
        static func page(_ key: String) -> String { "music.tab.page.\(key)" }

        // States, the same on every music page
        /// A skeleton standing in for a page or list that is loading.
        static let loading = "music.state.loading"
        /// The spinner at the foot of a paged list while the next page loads.
        static let loadingMore = "music.state.loadingMore"
        static let empty = "music.state.empty"
        static let error = "music.state.error"

        // Discover (Listen Now)
        static let listenNow = "music.listenNow.root"
        /// "Good Morning" / "Good Afternoon" / "Good Evening".
        static let greeting = "music.listenNow.greeting"
        /// Shuffle the whole library (or, offline, everything downloaded).
        static let shuffleAll = "music.listenNow.shuffleAll"

        // Shelves
        /// A shelf (heading plus its row or list). Key: the heading through
        /// `TestID.key`, e.g. `recently-played`, `your-top-songs`,
        /// `new-in-your-library`, `favorite-albums`, `favorite-artists`,
        /// `something-different`, `top-songs`, `albums`, `appears-on`,
        /// `similar-artists`, `artists`, `songs`, `playlists`, `about`.
        /// The album page's "More by …" shelf also answers to `moreByArtist`.
        static func shelf(_ key: String) -> String { "music.shelf.\(key)" }
        static func shelfTitle(_ key: String) -> String { "music.shelf.title.\(key)" }
        static func shelfSeeAll(_ key: String) -> String { "music.shelf.seeAll.\(key)" }

        // Cards and rows
        /// An album, artist, playlist or genre tile on a shelf or in a grid.
        /// An audiobook's tile is `TestID.Books.card`.
        static func card(_ id: String) -> String { "music.card.\(id)" }
        /// A grid of tiles.
        static let grid = "music.grid"
        /// An artist / album / playlist row in a list (picture, two lines, chevron).
        static func row(_ id: String) -> String { "music.row.\(id)" }
        /// A song's row: tap to play.
        static func song(_ id: String) -> String { "music.song.\(id)" }
        /// The "…" menu at the end of a song's row.
        static func songMore(_ id: String) -> String { "music.song.more.\(id)" }

        // Play bar (the wide Play and round Shuffle at the top of a page of songs)
        static let playBarPlay = "music.playBar.play"
        static let playBarShuffle = "music.playBar.shuffle"

        // Page header (album, playlist, smart playlist, audiobook, on-device collection)
        static let header = "music.header"
        static let headerKicker = "music.header.kicker"
        static let headerTitle = "music.header.title"
        static let headerFacts = "music.header.facts"

        // Library
        static let library = "music.library.root"
        static let libraryDoors = "music.library.doors"
        /// A door on the Library page: `playlists`, `artists`, `albums`,
        /// `songs`, `genres`, `favorites`, `downloaded`.
        static func libraryDoor(_ key: String) -> String { "music.library.door.\(key)" }
        static let artists = "music.artists.root"
        static let albums = "music.albums.root"
        static let recentlyAdded = "music.recentlyAdded.root"
        static let songs = "music.songs.root"
        static let genres = "music.genres.root"
        static let favorites = "music.favorites.root"
        /// The songs behind a Discover shelf (Recently Played, Most Played, Favorite Songs).
        static let songList = "music.songList.root"

        // Sort menu in the bar (also on the Audiobooks tab and list)
        static let sortMenu = "music.sort.menu"
        static let sortPicker = "music.sort.picker"
        /// Key: `MusicSort.rawValue`.
        static func sortOption(_ rawValue: String) -> String { "music.sort.option.\(rawValue)" }

        // Detail pages
        static let album = "music.album.root"
        static func albumDisc(_ number: Int) -> String { "music.album.disc.\(number)" }
        static let artist = "music.artist.root"
        static let artistHero = "music.artist.hero"
        static let artistName = "music.artist.name"
        static let artistBio = "music.artist.bio"
        /// More / Less under the artist's biography.
        static let artistBioToggle = "music.artist.bioToggle"
        static let genre = "music.genre.root"
        /// The "…" menu in the bar of an album, artist, playlist or on-device page.
        static let detailMore = "music.detail.more"
        /// The artist under an album's title; a link to the artist when the server names one.
        static let detailArtist = "music.detail.artist"
        /// "12 songs, 48 min" under the track list.
        static let detailFooter = "music.detail.footer"

        // The press-and-hold menu (and every "…" menu): one is open at a time
        static let menuPlay = "music.menu.play"
        static let menuShuffle = "music.menu.shuffle"
        static let menuPlayNext = "music.menu.playNext"
        static let menuPlayLater = "music.menu.playLater"
        static let menuStartStation = "music.menu.startStation"
        static let menuGoToAlbum = "music.menu.goToAlbum"
        static let menuGoToArtist = "music.menu.goToArtist"
        static let menuSongInfo = "music.menu.songInfo"
        /// The Add to Playlist submenu.
        static let menuAddToPlaylist = "music.menu.addToPlaylist"
        static let menuNewPlaylist = "music.menu.addToPlaylist.new"
        static func menuPlaylist(_ id: String) -> String { "music.menu.addToPlaylist.\(id)" }
        /// Add to / Remove from Favorites.
        static let menuFavorite = "music.menu.favorite"
        static let menuDownload = "music.menu.download"
        /// "Downloading…": opens Downloads.
        static let menuDownloading = "music.menu.downloading"
        static let menuRemoveDownload = "music.menu.removeDownload"
        static let menuDownloadToWatch = "music.menu.downloadToWatch"

        // Song Info sheet
        static let songInfo = "music.songInfo.root"
        static let songInfoDone = "music.songInfo.done"
        /// A row's value. Key: the row's name through `TestID.key`: `title`,
        /// `artist`, `album-artist`, `album`, `genre`, `year`, `track`, `disc`,
        /// `length`, `plays`, `last-played`, `favourite`, `added`, `format`,
        /// `bitrate`, `bit-depth`, `channels`, `size`.
        static func songInfoValue(_ key: String) -> String { "music.songInfo.value.\(key)" }

        // Search
        static let search = "music.search.root"
        /// The capsule field and its Cancel, under the bar.
        static let searchBar = "music.search.bar"
        static let searchField = "music.search.field"
        static let searchClear = "music.search.clear"
        static let searchCancel = "music.search.cancel"
        /// "Search your music", before anything is typed.
        static let searchPrompt = "music.search.prompt"
        static let searchResults = "music.search.results"
        /// "From this device: the server stopped answering."
        static let searchFootnote = "music.search.footnote"

        // Downloads in progress
        /// The "Downloading 12 songs" strip at the top of the Music tab.
        static let downloadBanner = "music.download.banner"
        /// The downloaded / downloading / waiting mark at the end of a song's row.
        static func downloadMark(_ id: String) -> String { "music.download.mark.\(id)" }
        /// The same in words, on an audiobook's page.
        static func downloadLine(_ id: String) -> String { "music.download.line.\(id)" }
        /// The same, on the corner of an audiobook's cover.
        static func downloadBadge(_ id: String) -> String { "music.download.badge.\(id)" }

        // On this device (offline, and Library → Downloaded)
        static let onDeviceListenNow = "music.onDevice.listenNow.root"
        /// The Library page drawn from downloads, with the server out of reach.
        static let onDeviceLibrary = "music.onDevice.library.root"
        /// Library → Downloaded, with a server in reach.
        static let downloaded = "music.downloaded.root"
        /// "No music on this device".
        static let onDeviceEmpty = "music.onDevice.empty"
        /// One of the long lists from downloads. Key: `artists`, `albums`,
        /// `recentAlbums`, `songs`, `genres`, `playlists`, `favorites`.
        static func onDeviceList(_ kind: String) -> String { "music.onDevice.list.\(kind)" }
        /// A genre's row in the on-device Genres list. Key: its name through `TestID.key`.
        static func onDeviceGenre(_ key: String) -> String { "music.onDevice.genre.\(key)" }
        /// An album, artist, genre or playlist page drawn from downloads.
        static let onDeviceCollection = "music.onDevice.collection.root"
        /// Downloaded songs grouped by album (the older Downloaded page).
        static let downloadedSongs = "music.downloadedSongs.root"
        /// Key: the album's id, or its name when the download has no album id.
        static func downloadedAlbum(_ key: String) -> String { "music.downloadedSongs.album.\(key)" }
        static func downloadedAlbumPlay(_ key: String) -> String { "music.downloadedSongs.album.play.\(key)" }
        /// "Remove download" in a downloaded album's press-and-hold menu.
        static let downloadedAlbumRemove = "music.downloadedSongs.menu.remove"
    }

    // MARK: - The mini player bar

    enum MiniPlayer {
        static let root = "miniPlayer.root"
        static let artwork = "miniPlayer.artwork"
        static let title = "miniPlayer.title"
        /// The artist, or a book's chapter.
        static let subtitle = "miniPlayer.subtitle"
        static let playPause = "miniPlayer.playPause"
        /// Next song; for an audiobook, forward 30 seconds.
        static let next = "miniPlayer.next"
        /// The bar itself: tap it to open Now Playing.
        static let expand = "miniPlayer.expand"
        static let progress = "miniPlayer.progress"
    }

    // MARK: - Now Playing

    enum NowPlaying {
        static let root = "nowPlaying.root"
        static let close = "nowPlaying.close"
        /// What this is playing from: the queue's title, the album, or "Your Library".
        static let source = "nowPlaying.source"
        /// "Offline — mixed from your downloads".
        static let offlineMix = "nowPlaying.offlineMix"
        /// The "…" menu; its actions are `TestID.Music.menu…`.
        static let more = "nowPlaying.more"
        static let artwork = "nowPlaying.artwork"
        static let title = "nowPlaying.title"
        /// The artist line under the title: a button that goes to the artist.
        static let artist = "nowPlaying.artist"
        static let favorite = "nowPlaying.favorite"
        static let scrubber = "nowPlaying.scrubber"
        static let elapsed = "nowPlaying.elapsed"
        static let remaining = "nowPlaying.remaining"
        /// An audiobook's current chapter, between the two times.
        static let chapter = "nowPlaying.chapter"
        static let shuffle = "nowPlaying.shuffle"
        /// Previous song; for an audiobook, back 15 seconds.
        static let previous = "nowPlaying.previous"
        static let playPause = "nowPlaying.playPause"
        /// Next song; for an audiobook, forward 30 seconds.
        static let next = "nowPlaying.next"
        static let repeatMode = "nowPlaying.repeat"
        /// An audiobook's speed menu, where shuffle is for a song.
        static let speed = "nowPlaying.speed"
        /// Key: the rate as Swift prints it: `0.75`, `1.0`, `1.25`…
        static func speedOption(_ rate: String) -> String { "nowPlaying.speed.option.\(rate)" }
        /// The system volume slider and the speaker glyphs at its ends.
        static let volume = "nowPlaying.volume"
        static let lyrics = "nowPlaying.lyrics"
        static let instantMix = "nowPlaying.instantMix"
        /// "What's leading in the mix": a station only.
        static let leanings = "nowPlaying.leanings"
        static let airPlay = "nowPlaying.airPlay"
        static let sleepTimer = "nowPlaying.sleepTimer"
        static let sleepOff = "nowPlaying.sleepTimer.off"
        static func sleepOption(_ minutes: Int) -> String { "nowPlaying.sleepTimer.option.\(minutes)" }
        static let previousChapter = "nowPlaying.previousChapter"
        static let nextChapter = "nowPlaying.nextChapter"
        /// The button that raises Up Next.
        static let queue = "nowPlaying.queue"

        // Up Next, the card over the player
        static let queueRoot = "nowPlaying.queue.root"
        /// The grabber at the top of the card: tap to put it away.
        static let queueClose = "nowPlaying.queue.close"
        static let queueTitle = "nowPlaying.queue.title"
        /// "From <queue title>".
        static let queueSource = "nowPlaying.queue.source"
        /// "Changes with what you play, skip and rate": a station only.
        static let queueStationNote = "nowPlaying.queue.stationNote"
        static let queueClear = "nowPlaying.queue.clear"
        static let queueList = "nowPlaying.queue.list"
        static let queueEmpty = "nowPlaying.queue.empty"
        /// A song still to come: tap to go to it. Key: the track's id (the
        /// same song queued twice has two rows with one identifier).
        static func queueRow(_ id: String) -> String { "nowPlaying.queue.row.\(id)" }
    }

    // MARK: - Lyrics, in Now Playing

    enum Lyrics {
        static let root = "lyrics.root"
        static let loading = "lyrics.loading"
        /// The scrolling words.
        static let lines = "lyrics.lines"
        /// One line: tap a timed one to go there. Key: the line's place in the song, from 0.
        static func line(_ key: String) -> String { "lyrics.line.\(key)" }
        /// "No lyrics for this song".
        static let empty = "lyrics.empty"
    }

    // MARK: - The server's playlists

    enum Playlists {
        // The list (rows are `TestID.Music.row(<playlist id>)`)
        static let root = "playlists.root"
        static let loading = "playlists.state.loading"
        static let empty = "playlists.state.empty"
        static let error = "playlists.state.error"
        /// The + in the bar. It raises a system alert, whose field and
        /// buttons carry no identifiers.
        static let new = "playlists.new"
        static let menuRename = "playlists.menu.rename"
        static let menuDelete = "playlists.menu.delete"
        /// "Delete from the server" in the confirmation.
        static let deleteConfirm = "playlists.delete.confirm"
        static let deleteCancel = "playlists.delete.cancel"

        // One playlist's page
        static let detail = "playlists.detail.root"
        /// Edit Songs, in the page's "…" menu.
        static let editSongs = "playlists.detail.editSongs"
        static let editDone = "playlists.detail.editDone"
        /// Remove from Playlist, in a song's press-and-hold menu.
        static let removeSong = "playlists.detail.removeSong"
        /// The list with its handles out.
        static let editor = "playlists.detail.editor"
        /// "Drag to reorder, swipe to remove" / "Saving…".
        static let editorStatus = "playlists.detail.editor.status"
        /// Key: the playlist entry's id, or `#<index>` when the server gave none.
        static func editorRow(_ key: String) -> String { "playlists.detail.editor.row.\(key)" }
    }

    // MARK: - Smart playlists

    enum SmartPlaylists {
        // On the Playlists page and the offline pages
        /// The "Smart Playlists" heading on the Playlists page.
        static let heading = "smartPlaylists.list.heading"
        static let new = "smartPlaylists.list.new"
        /// "None yet. Try …".
        static let listEmpty = "smartPlaylists.list.empty"
        /// Key: the smart playlist's UUID string.
        static func row(_ id: String) -> String { "smartPlaylists.row.\(id)" }
        static let menuEdit = "smartPlaylists.menu.edit"
        static let menuDelete = "smartPlaylists.menu.delete"
        /// The shelf of smart playlists on the offline Discover page.
        static let shelf = "smartPlaylists.shelf"
        static func card(_ id: String) -> String { "smartPlaylists.card.\(id)" }

        // The rule editor
        static let editor = "smartPlaylists.editor.root"
        static let editorName = "smartPlaylists.editor.name"
        /// The row that opens the genre picker.
        static let editorGenres = "smartPlaylists.editor.genres"
        /// A chosen artist's name. Key: the artist's id.
        static func editorArtist(_ id: String) -> String { "smartPlaylists.editor.artist.\(id)" }
        static func editorArtistRemove(_ id: String) -> String { "smartPlaylists.editor.artist.remove.\(id)" }
        static let editorArtistSearch = "smartPlaylists.editor.artistSearch"
        /// An artist the search found: tap to add.
        static func editorArtistMatch(_ id: String) -> String { "smartPlaylists.editor.artistMatch.\(id)" }
        static let editorYearFrom = "smartPlaylists.editor.yearFrom"
        static let editorYearTo = "smartPlaylists.editor.yearTo"
        static let editorAddedWithin = "smartPlaylists.editor.addedWithin"
        /// Key: days; 0 is "Any time".
        static func editorAddedWithinOption(_ days: Int) -> String { "smartPlaylists.editor.addedWithin.\(days)" }
        static let editorPlayed = "smartPlaylists.editor.played"
        /// Key: `SmartPlaylist.PlayedFilter.rawValue`.
        static func editorPlayedOption(_ rawValue: String) -> String { "smartPlaylists.editor.played.\(rawValue)" }
        static let editorMinPlays = "smartPlaylists.editor.minPlays"
        static let editorFavoritesOnly = "smartPlaylists.editor.favoritesOnly"
        static let editorSort = "smartPlaylists.editor.sort"
        /// Key: `MusicSort.rawValue`.
        static func editorSortOption(_ rawValue: String) -> String { "smartPlaylists.editor.sort.\(rawValue)" }
        static let editorLimit = "smartPlaylists.editor.limit"
        static func editorLimitOption(_ count: Int) -> String { "smartPlaylists.editor.limit.\(count)" }
        /// The rule as a sentence, under the form.
        static let editorSummary = "smartPlaylists.editor.summary"
        static let editorCancel = "smartPlaylists.editor.cancel"
        static let editorSave = "smartPlaylists.editor.save"

        // The genre picker pushed from the editor. Keys: the genre's name through `TestID.key`.
        static let genres = "smartPlaylists.genres.root"
        /// A genre under "Chosen": tap to take it out.
        static func genreChosen(_ key: String) -> String { "smartPlaylists.genres.chosen.\(key)" }
        static func genreOption(_ key: String) -> String { "smartPlaylists.genres.option.\(key)" }

        // One smart playlist's page (its songs are `TestID.Music.song`)
        static let detail = "smartPlaylists.detail.root"
        static let detailSummary = "smartPlaylists.detail.summary"
        /// "Offline — answered from your downloads".
        static let detailOffline = "smartPlaylists.detail.offline"
        /// "Gone": the playlist was deleted while its page was open.
        static let detailGone = "smartPlaylists.detail.gone"
        static let detailMore = "smartPlaylists.detail.more"
        static let detailEdit = "smartPlaylists.detail.edit"
        static let detailRefresh = "smartPlaylists.detail.refresh"
        static let detailSaveToServer = "smartPlaylists.detail.saveToServer"
        static let detailDelete = "smartPlaylists.detail.delete"
    }

    // MARK: - Stations

    enum Stations {
        /// The "Your Stations" shelf, on Discover and on the Downloaded page.
        static let shelf = "stations.shelf"
        /// A station's card: tap to start it. Key: the seed's id: an artist
        /// or genre id, `fj-genre:<key>`, `local-genre:<name>`, or
        /// `fj-station:rediscover` / `fj-station:deepCuts`.
        static func card(_ id: String) -> String { "stations.card.\(id)" }
        /// Shuffle All from downloads, beside the shelf on the Downloaded page.
        static let shuffleDownloads = "stations.downloaded.shuffleAll"
        /// Start Station in the header of an on-device album, artist, genre or playlist.
        static let start = "stations.start"

        // "What's leading", the sheet Now Playing raises for a station
        static let leanings = "stations.leanings.root"
        /// "Nothing is ahead yet…".
        static let leaningsEmpty = "stations.leanings.empty"
        /// The station's name under the sheet's title.
        static let leaningsStation = "stations.leanings.station"
        static let leaningsFootnote = "stations.leanings.footnote"
        /// A genre or artist and its points. Key: its name through `TestID.key`.
        static func leaningRow(_ key: String) -> String { "stations.leanings.row.\(key)" }
    }

    // MARK: - Audiobooks

    enum Books {
        // The tab
        static let root = "books.root"
        static let loading = "books.state.loading"
        static let empty = "books.state.empty"
        static let error = "books.state.error"
        /// A shelf or section. Key: `continueListening`, `recentlyAdded`,
        /// `authors`, `allBooks`, `onThisDevice`.
        static func shelf(_ key: String) -> String { "books.shelf.\(key)" }
        /// A book's cover on a shelf or in a grid. Key: the book's id.
        static func card(_ id: String) -> String { "books.card.\(id)" }
        /// An author's chip. Key: the author's id; offline, the name through `TestID.key`.
        static func authorChip(_ key: String) -> String { "books.author.chip.\(key)" }
        /// "Downloaded audiobooks" at the foot of the tab.
        static let downloadedBooks = "books.downloaded.open"
        /// The "Downloading 2 audiobooks" strip.
        static let downloadBanner = "books.download.banner"

        // Other pages
        static let searchRoot = "books.search.root"
        /// "Search your audiobooks", before anything is typed.
        static let searchPrompt = "books.search.prompt"
        static let authorRoot = "books.author.root"
        /// Every audiobook, as a filterable grid.
        static let list = "books.list.root"
        /// Downloaded audiobooks, grouped.
        static let downloaded = "books.downloaded.root"
        /// The tab drawn from downloads, with the server out of reach.
        static let onDeviceRoot = "books.onDevice.root"
        /// "No audiobooks on this device".
        static let onDeviceEmpty = "books.onDevice.empty"

        // One book's page (its header is `TestID.Music.header…`)
        static let detail = "books.detail.root"
        static let detailAuthor = "books.detail.author"
        static let detailProgress = "books.detail.progress"
        /// "42% · 5h 12m left".
        static let detailProgressText = "books.detail.progressText"
        /// Play / Resume / Pause.
        static let detailPlay = "books.detail.play"
        static let detailStartOver = "books.detail.startOver"
        static let detailOverview = "books.detail.overview"
        /// More / Less under the blurb.
        static let detailOverviewToggle = "books.detail.overviewToggle"
        static let detailChapters = "books.detail.chapters"
        /// A chapter's row: tap to play from it. Key: its index, from 0.
        static func chapter(_ index: Int) -> String { "books.detail.chapter.\(index)" }
        static let detailMore = "books.detail.more"
    }
}
