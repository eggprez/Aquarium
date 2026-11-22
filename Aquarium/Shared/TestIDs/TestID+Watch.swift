//  The Apple Watch app's names. See TestID.swift for the rule.
//
//  One enum, nested by screen in the string: `watch.root.…` is the top of
//  the library, `watch.library.…` the lists, `watch.book.…`,
//  `watch.collection.…` and `watch.artist.…` the pages behind a row,
//  `watch.detail.…` what those pages share (Play, Shuffle, the On Watch
//  rows), `watch.onWatch.…` and `watch.queue.…` the downloads,
//  `watch.nowPlaying.…` the watch's own player, `watch.phone.…` the remote
//  for the phone's, and `watch.settings.…` the settings page.

import Foundation

extension TestID {
    enum Watch {
        // MARK: The shell

        /// The navigation stack itself: there for as long as the app is up,
        /// whatever page is on top.
        static let appRoot = "watch.app.root"

        // MARK: Home (the top of the library)

        /// The home list.
        static let root = "watch.root"
        /// A second mark on the home list that says which state it is in:
        /// `signedOut` (waiting for the phone), `offline`, or `signedIn`.
        static func rootState(_ state: String) -> String { "watch.root.state.\(state)" }
        /// A second mark on the home list for the source it shows: `watch` or `phone`.
        static func rootMode(_ source: String) -> String { "watch.root.mode.\(source)" }
        /// The Watch / iPhone switch as a whole.
        static let rootSourceSwitch = "watch.root.sourceSwitch"
        /// One side of the switch: `watch` or `phone` (WatchSource's raw value).
        static func rootSource(_ source: String) -> String { "watch.root.source.\(source)" }
        /// The "Not signed in" note.
        static let rootSignedOut = "watch.root.signedOut"
        /// The "Server out of reach" line.
        static let rootOffline = "watch.root.offline"
        /// The row back to the watch's own player.
        static let rootNowPlaying = "watch.root.nowPlaying"
        /// "Now Playing" or "Paused" in that row.
        static let rootNowPlayingStatus = "watch.root.nowPlaying.status"
        static let rootNowPlayingTitle = "watch.root.nowPlaying.title"
        /// The "Downloading" row that opens the queue.
        static let rootDownloading = "watch.root.downloading"
        /// "N left", inside any Downloading row (home and On Watch).
        static let downloadingLeft = "watch.downloading.left"
        /// iPhone mode: the row that opens the remote.
        static let rootPhoneNowPlaying = "watch.root.phoneNowPlaying"
        static let rootPhoneNowPlayingStatus = "watch.root.phoneNowPlaying.status"
        static let rootPhoneNowPlayingTitle = "watch.root.phoneNowPlaying.title"
        /// iPhone mode: the row when the phone has nothing on or is away.
        static let rootPhoneIdle = "watch.root.phoneIdle"
        /// A book in the Continue section; a tap plays it.
        static func rootContinue(_ itemId: String) -> String { "watch.root.continue.\(itemId)" }
        /// A way in from the home list: `books`, `music`, `playlists`,
        /// `onWatch`, `search`, `settings`.
        static func rootDoor(_ name: String) -> String { "watch.root.door.\(name)" }

        // MARK: Shared rows and states

        /// The corner glyph on a book or song row that downloads, cancels or retries.
        static func itemDownload(_ itemId: String) -> String { "watch.item.download.\(itemId)" }
        /// Swipe actions on a song row.
        static func itemSwipeRemove(_ itemId: String) -> String { "watch.item.swipe.remove.\(itemId)" }
        static func itemSwipeDownload(_ itemId: String) -> String { "watch.item.swipe.download.\(itemId)" }
        /// A list's spinner, error line or empty note (one at a time; the
        /// screen's root says which list).
        static let statusLoading = "watch.status.loading"
        static let statusError = "watch.status.error"
        static let statusEmpty = "watch.status.empty"

        // MARK: Library lists

        static let booksRoot = "watch.library.books.root"
        /// The row at the head of the list that steps through the sort orders.
        static let booksSort = "watch.library.books.sort"
        /// A book row, wherever it opens the book's page (Audiobooks, Search).
        static func book(_ itemId: String) -> String { "watch.library.book.\(itemId)" }

        static let musicRoot = "watch.library.music.root"
        /// A row of the Music menu: `playlists`, `albums`, `artists`, `songs`, `genres`.
        static func musicDoor(_ name: String) -> String { "watch.library.music.door.\(name)" }
        static let musicShuffleAll = "watch.library.music.shuffleAll"

        static let playlistsRoot = "watch.library.playlists.root"
        /// A playlist row (Playlists, Search).
        static func playlist(_ itemId: String) -> String { "watch.library.playlist.\(itemId)" }

        static let albumsRoot = "watch.library.albums.root"
        static let albumsSort = "watch.library.albums.sort"
        static let albumsMore = "watch.library.albums.more"
        /// An album row (Albums, an artist's page, Search).
        static func album(_ itemId: String) -> String { "watch.library.album.\(itemId)" }

        static let artistsRoot = "watch.library.artists.root"
        static func artist(_ itemId: String) -> String { "watch.library.artist.\(itemId)" }

        static let songsRoot = "watch.library.songs.root"
        static let songsMore = "watch.library.songs.more"
        /// A song row; a tap plays it (Songs, an album or playlist's page, Search).
        static func song(_ itemId: String) -> String { "watch.library.song.\(itemId)" }

        static let genresRoot = "watch.library.genres.root"
        static func genre(_ itemId: String) -> String { "watch.library.genre.\(itemId)" }

        static let searchRoot = "watch.search.root"
        static let searchField = "watch.search.field"

        // MARK: A book's page

        static let bookRoot = "watch.book.root"
        /// Cover, title, author and time.
        static let bookHeader = "watch.book.header"
        static let bookTitle = "watch.book.title"
        static let bookAuthor = "watch.book.author"
        /// "1:02:03 of 9h 4m", or the running time alone.
        static let bookTime = "watch.book.time"
        /// Play, Resume or Pause.
        static let bookPlay = "watch.book.play"
        static let bookStartOver = "watch.book.startOver"
        /// Why its download failed.
        static let bookDownloadError = "watch.book.downloadError"
        static func bookChapter(_ index: Int) -> String { "watch.book.chapter.\(index)" }
        static let bookOverview = "watch.book.overview"

        // MARK: An album, a playlist, a genre

        static let collectionRoot = "watch.collection.root"
        static let collectionHeader = "watch.collection.header"
        static let collectionTitle = "watch.collection.title"
        static let collectionArtist = "watch.collection.artist"

        // MARK: An artist's page

        static let artistRoot = "watch.artist.root"

        // MARK: What the detail pages share

        static let detailPlay = "watch.detail.play"
        static let detailShuffle = "watch.detail.shuffle"
        /// The On Watch rows of a page while something is arriving.
        static let detailDownloadProgress = "watch.detail.download.progress"
        static let detailDownloadPercent = "watch.detail.download.percent"
        /// "2 of 9 on watch" under the bar.
        static let detailDownloadCount = "watch.detail.download.count"
        static let detailDownloadCancel = "watch.detail.download.cancel"
        /// "On watch" / "9 songs on watch": all of it is here.
        static let detailDownloadComplete = "watch.detail.download.complete"
        /// "2 didn't arrive".
        static let detailDownloadFailed = "watch.detail.download.failed"
        /// "2 of 9 on watch", with nothing arriving.
        static let detailDownloadPartial = "watch.detail.download.partial"
        static let detailDownloadRemove = "watch.detail.download.remove"
        static let detailDownloadRetry = "watch.detail.download.retry"
        /// Download to Watch / Download the Rest.
        static let detailDownloadStart = "watch.detail.download.start"

        // MARK: On Watch

        static let onWatchRoot = "watch.onWatch.root"
        /// The "Downloading" row that opens the queue.
        static let onWatchDownloading = "watch.onWatch.downloading"
        /// A book, playlist, album or the loose songs. `kind` is
        /// WatchStorageGroup.Kind's raw value (`book`, `playlist`, `album`,
        /// `songs`); `id` the item id, or `songs` for the loose songs.
        static func onWatchGroup(_ kind: String, _ id: String) -> String { "watch.onWatch.group.\(kind).\(id)" }
        /// A second mark on a group's row while it sits in Didn't Arrive.
        static func onWatchFailed(_ kind: String, _ id: String) -> String { "watch.onWatch.failed.\(kind).\(id)" }
        /// The line under a group's name.
        static func onWatchGroupNote(_ kind: String, _ id: String) -> String { "watch.onWatch.groupNote.\(kind).\(id)" }
        static func onWatchSwipeRetry(_ kind: String, _ id: String) -> String { "watch.onWatch.swipe.retry.\(kind).\(id)" }
        static func onWatchSwipeRemove(_ kind: String, _ id: String) -> String { "watch.onWatch.swipe.remove.\(kind).\(id)" }
        static func onWatchSwipeCancel(_ kind: String, _ id: String) -> String { "watch.onWatch.swipe.cancel.\(kind).\(id)" }
        static let onWatchRetryAll = "watch.onWatch.retryAll"
        static let onWatchRemoveEverything = "watch.onWatch.removeEverything"
        /// The destructive button in the "Remove everything?" dialog.
        static let onWatchConfirmRemoveEverything = "watch.onWatch.confirmRemoveEverything"

        /// The space used and free (On Watch and Settings).
        static let storageRoot = "watch.storage.root"
        static let storageUsed = "watch.storage.used"
        static let storageFree = "watch.storage.free"

        // MARK: The download queue

        static let queueRoot = "watch.queue.root"
        /// One song or book on its way.
        static func queueRow(_ itemId: String) -> String { "watch.queue.row.\(itemId)" }
        /// Its percentage: there only while it is moving.
        static func queuePercent(_ itemId: String) -> String { "watch.queue.percent.\(itemId)" }
        /// Why it isn't moving yet: there only while it waits.
        static func queueNote(_ itemId: String) -> String { "watch.queue.note.\(itemId)" }
        static func queueSwipeCancel(_ itemId: String) -> String { "watch.queue.swipe.cancel.\(itemId)" }
        /// "and N more".
        static let queueMore = "watch.queue.more"
        static let queueCancelAll = "watch.queue.cancelAll"
        /// The destructive button in the "Cancel every download?" dialog.
        static let queueConfirmCancelAll = "watch.queue.confirmCancelAll"

        // MARK: Settings

        static let settingsRoot = "watch.settings.root"
        static let settingsAccount = "watch.settings.account"
        static let settingsUserName = "watch.settings.userName"
        static let settingsServer = "watch.settings.server"
        /// Server: Connected / Out of reach.
        static let settingsServerStatus = "watch.settings.serverStatus"
        static let settingsSignedOut = "watch.settings.signedOut"
        /// iPhone: In reach / Away.
        static let settingsPhoneReach = "watch.settings.phoneReach"
        static let settingsManage = "watch.settings.manage"
        static let settingsFromPhone = "watch.settings.fromPhone"
        static let settingsMirrorNote = "watch.settings.mirrorNote"
        static let settingsWaitingToSend = "watch.settings.waitingToSend"
        static let settingsLastSent = "watch.settings.lastSent"
        static let settingsSyncNow = "watch.settings.syncNow"
        static let settingsSendLog = "watch.settings.sendLog"
        static let settingsLogNote = "watch.settings.logNote"

        // MARK: Now Playing (the watch's own player)

        static let nowPlayingRoot = "watch.nowPlaying.root"
        /// Nothing playing.
        static let nowPlayingIdle = "watch.nowPlaying.idle"
        static let nowPlayingResumeBook = "watch.nowPlaying.resumeBook"
        /// The controls as laid out: `full` or `compact`.
        static func nowPlayingLayout(_ name: String) -> String { "watch.nowPlaying.layout.\(name)" }
        static let nowPlayingArtwork = "watch.nowPlaying.artwork"
        static let nowPlayingTitle = "watch.nowPlaying.title"
        static let nowPlayingSubtitle = "watch.nowPlaying.subtitle"
        static let nowPlayingProgress = "watch.nowPlaying.progress"
        static let nowPlayingElapsed = "watch.nowPlaying.elapsed"
        static let nowPlayingRemaining = "watch.nowPlaying.remaining"
        static let nowPlayingError = "watch.nowPlaying.error"
        /// The left button on a book: fifteen seconds back.
        static let nowPlayingSkipBack = "watch.nowPlaying.skipBack"
        /// The left button on a song.
        static let nowPlayingPrevious = "watch.nowPlaying.previous"
        static let nowPlayingPlayPause = "watch.nowPlaying.playPause"
        /// The right button on a book: thirty seconds on.
        static let nowPlayingSkipForward = "watch.nowPlaying.skipForward"
        /// The right button on a song.
        static let nowPlayingNext = "watch.nowPlaying.next"
        static let nowPlayingSpeed = "watch.nowPlaying.speed"
        /// Opens the chapter list.
        static let nowPlayingChapters = "watch.nowPlaying.chapters"
        /// "3 up next · On watch".
        static let nowPlayingNotes = "watch.nowPlaying.notes"
        /// Where the level bar shows beside the crown.
        static let nowPlayingVolume = "watch.nowPlaying.volume"
        /// The chapter sheet.
        static let nowPlayingChapterList = "watch.nowPlaying.chapterList.root"
        static func nowPlayingChapter(_ index: Int) -> String { "watch.nowPlaying.chapter.\(index)" }

        // MARK: The phone's player, from here

        static let phoneRoot = "watch.phone.root"
        /// The remote with nothing to show.
        static let phoneIdle = "watch.phone.idle"
        /// Inside the idle note (home row and remote): the headline, any
        /// error, and Check Again.
        static let phoneIdleStatus = "watch.phone.idle.status"
        static let phoneIdleDetail = "watch.phone.idle.detail"
        static let phoneIdleError = "watch.phone.idle.error"
        static let phoneIdleCheckAgain = "watch.phone.idle.checkAgain"
        /// `full` or `compact`.
        static func phoneLayout(_ name: String) -> String { "watch.phone.layout.\(name)" }
        static let phoneArtwork = "watch.phone.artwork"
        static let phoneTitle = "watch.phone.title"
        static let phoneSubtitle = "watch.phone.subtitle"
        static let phoneProgress = "watch.phone.progress"
        static let phoneElapsed = "watch.phone.elapsed"
        static let phoneRemaining = "watch.phone.remaining"
        static let phoneError = "watch.phone.error"
        /// The left button on a book or a video: back fifteen or ten.
        static let phoneSkipBack = "watch.phone.skipBack"
        static let phonePrevious = "watch.phone.previous"
        static let phonePlayPause = "watch.phone.playPause"
        static let phoneSkipForward = "watch.phone.skipForward"
        static let phoneNext = "watch.phone.next"
        static let phoneSpeed = "watch.phone.speed"
        static let phoneInstantMix = "watch.phone.instantMix"
        /// "Offline mix · 3 up next · On iPhone".
        static let phoneNotes = "watch.phone.notes"
        static let phoneVolume = "watch.phone.volume"
    }
}
