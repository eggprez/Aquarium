//  Names for the browsing screens: a title's page, a person's, the libraries
//  and one library, Favorites, Search, and Downloads.
//
//  See TestID.swift for the naming rule. Keys are Jellyfin item ids unless a
//  name says otherwise.

import Foundation

extension TestID {
    // MARK: - A title's page (ItemDetailView, EpisodeRow, MacEpisodeList, RouteWindow)

    enum Detail {
        /// Any title page, whichever title it shows.
        static let root = "detail.root"
        /// The same page, keyed by the item it was opened for.
        static func page(_ itemId: String) -> String { "detail.page.\(itemId)" }
        /// The skeleton shown before the item has arrived.
        static let loading = "detail.loading"
        static let error = "detail.error"

        // The page's own bar (iPhone, iPad) and the Mac's toolbar.
        static let back = "detail.bar.back"
        static let showSidebar = "detail.bar.showSidebar"
        /// The title that fades into the bar once the artwork has scrolled past.
        static let barTitle = "detail.bar.title"
        static let openInNewWindow = "detail.toolbar.openInNewWindow"

        // The top of the page.
        /// The hero band (iPhone, Apple TV) or the poster-and-facts header (iPad, Mac).
        static let hero = "detail.hero"
        /// The poster or episode still beside the facts (iPad, Mac).
        static let artwork = "detail.hero.artwork"
        /// The two halves of a half-folded page.
        static let foldUpper = "detail.fold.upper"
        static let foldLower = "detail.fold.lower"
        /// The "Show › Season" trail above an episode's or a season's name.
        static let ancestors = "detail.header.ancestors"
        static let title = "detail.header.title"
        static let tagline = "detail.header.tagline"
        /// Year, runtime, rating.
        static let facts = "detail.header.facts"
        static let genres = "detail.header.genres"
        static let studios = "detail.header.studios"
        /// The synopsis. On an iPad a tap on it unfolds or folds it.
        static let overview = "detail.header.overview"
        /// "Up next · Season 2: Episode 4 · …": which episode Play would start.
        static let upNext = "detail.header.upNext"
        /// The bar-and-time line saying how far through Play's target is.
        static let resumeProgress = "detail.header.resumeProgress"
        /// "23m left".
        static let remaining = "detail.header.remaining"
        /// The line describing the file: resolution, codecs, audio, subtitles.
        static let sourceInfo = "detail.header.sourceInfo"

        // The actions. The same name wherever the action is drawn: a button in
        // the row, a disc under the title, or an entry in the phone's More menu.
        static let actions = "detail.actions"
        /// Play or Resume: one button, whose label says which.
        static let play = "detail.action.play"
        /// The quality menu (a dialog on Apple TV; inside Play's own menu on the Mac's split button).
        static let quality = "detail.action.quality"
        /// One rung of the quality menu, keyed by its bitrate; "original" for direct play.
        static func qualityOption(_ maxBitrate: Int?) -> String {
            "detail.action.quality.\(maxBitrate.map(String.init) ?? "original")"
        }
        /// Apple TV's quality dialog only.
        static let qualityCancel = "detail.action.quality.cancel"
        /// The version choice, on a title with several (a dialog on Apple TV;
        /// a section of the quality menu elsewhere).
        static let version = "detail.action.version"
        /// One version, keyed by its media source id.
        static func versionOption(_ mediaSourceId: String) -> String { "detail.action.version.\(mediaSourceId)" }
        /// Apple TV's version dialog only.
        static let versionCancel = "detail.action.version.cancel"
        static let favorite = "detail.action.favorite"
        static let watched = "detail.action.watched"
        static let addToNextUp = "detail.action.addToNextUp"
        static let trailer = "detail.action.trailer"
        /// The phone's overflow menu.
        static let more = "detail.action.more"

        // The download menu.
        static let download = "detail.action.download"
        /// A quality for this film, this episode or this season. Keyed by the
        /// quality's label, which is fixed text ("original-quality", "1080p-9-mbps-transcoded").
        static func downloadQuality(_ label: String) -> String { "detail.download.quality.\(TestID.key(label))" }
        /// The "Whole Series" submenu and its qualities.
        static let downloadSeries = "detail.download.series"
        static func downloadSeriesQuality(_ label: String) -> String {
            "detail.download.series.quality.\(TestID.key(label))"
        }
        /// One season's submenu on a series page, and its qualities.
        static func downloadSeason(_ seasonId: String) -> String { "detail.download.season.\(seasonId)" }
        static func downloadSeasonQuality(_ seasonId: String, _ label: String) -> String {
            "detail.download.season.\(seasonId).quality.\(TestID.key(label))"
        }
        /// "All N episodes are downloaded", in place of the qualities.
        static let downloadAllHere = "detail.download.allHere"
        static let downloadShowInDownloads = "detail.download.showInDownloads"
        static let downloadShowInFinder = "detail.download.showInFinder"
        static let downloadDelete = "detail.download.delete"

        // Seasons and episodes.
        /// The shelf of season posters (iPhone, Apple TV).
        static let seasons = "detail.seasons"
        /// The row of season chips over the episode list (iPad, Mac).
        static let seasonPicker = "detail.seasonPicker"
        /// One season: a poster on the shelf or a chip on the picker.
        static func season(_ seasonId: String) -> String { "detail.season.\(seasonId)" }
        /// The episodes section.
        static let episodes = "detail.episodes"
        /// "12 episodes · 3 watched".
        static let episodeSummary = "detail.episodes.summary"
        static let episodesLoading = "detail.episodes.loading"
        static let episodesEmpty = "detail.episodes.empty"
        /// The Mac's list of episode rows.
        static let episodeList = "detail.episodes.list"
        static func episode(_ episodeId: String) -> String { "detail.episode.\(episodeId)" }
        /// The play glyph on a row (iPhone, iPad). On the Mac the row is one element.
        static func episodePlay(_ episodeId: String) -> String { "detail.episode.play.\(episodeId)" }
        /// The Mac list's menu for several selected rows.
        static let episodesMarkWatched = "detail.episodes.selection.markWatched"
        static let episodesMarkUnwatched = "detail.episodes.selection.markUnwatched"

        // Further down.
        static let cast = "detail.cast"
        /// Keyed by the person's id, or their name where the server has no id.
        static func castPerson(_ personId: String) -> String { "detail.cast.person.\(personId)" }
        static let moreLikeThis = "detail.moreLikeThis"

        // The Mac's window for one title or route ("Open in New Window").
        static let window = "detail.window.root"
        static let windowEmpty = "detail.window.empty"
    }

    // MARK: - A person's page (PersonView)

    enum Person {
        static let root = "person.root"
        static func page(_ personId: String) -> String { "person.page.\(personId)" }
        static let loading = "person.loading"
        static let error = "person.error"
        static let empty = "person.empty"
        static let header = "person.header"
        /// Apple TV only: elsewhere the name is the navigation title.
        static let name = "person.header.name"
        /// Born, died, where.
        static let facts = "person.header.facts"
        static let bio = "person.header.bio"
        /// Read More / Show Less.
        static let bioToggle = "person.header.bioToggle"
        static let films = "person.films"
        static let shows = "person.shows"
        static let toolbarLoading = "person.toolbar.loading"
        static let openInNewWindow = "person.toolbar.openInNewWindow"
    }

    // MARK: - Libraries (LibrariesView, LibraryView, LibraryTable)

    enum Library {
        // The list of libraries, and the rows of them drawn on other screens.
        static let listRoot = "library.list.root"
        static let listLoading = "library.list.loading"
        static let listEmpty = "library.list.empty"
        /// One library's tile, in the list or in the "My Media" row.
        static func tile(_ libraryId: String) -> String { "library.tile.\(libraryId)" }
        /// The "My Media" row of tiles.
        static let tilesRow = "library.tilesRow"
        static let tilesPageBack = "library.tilesRow.pageBack"
        static let tilesPageForward = "library.tilesRow.pageForward"
        /// The row of library chips.
        static let chips = "library.chips"
        static func chip(_ libraryId: String) -> String { "library.chip.\(libraryId)" }
        /// A tile's or chip's "Open in New Window" (Mac).
        static func openInNewWindow(_ libraryId: String) -> String { "library.openInNewWindow.\(libraryId)" }

        // One library.
        static let root = "library.root"
        static func page(_ libraryId: String) -> String { "library.page.\(libraryId)" }
        static let loading = "library.loading"
        static let error = "library.error"
        static let empty = "library.empty"
        /// The Mac's "No Results" for a search or filter that matched nothing.
        static let noResults = "library.noResults"
        static let noResultsClear = "library.noResults.clear"
        static let grid = "library.grid"
        /// The Mac's list layout.
        static let table = "library.table"
        /// A row of the table: its title cell.
        static func tableRow(_ itemId: String) -> String { "library.table.row.\(itemId)" }
        /// "120 films" in the filter header, or "60 of 120" under the grid.
        static let count = "library.count"
        /// The spinner shown while a further page loads (Mac toolbar).
        static let paging = "library.paging"

        // Sorting and filtering.
        /// The strip of sort and filter chips.
        static let filters = "library.filters"
        static let sortMenu = "library.sort.menu"
        static let sortPicker = "library.sort.picker"
        /// Keyed by `LibraryView.SortOption`'s raw value.
        static func sortOption(_ rawValue: String) -> String { "library.sort.option.\(rawValue)" }
        static let sortReverse = "library.sort.reverse"
        static let filterUnwatched = "library.filter.unwatched"
        static let filterFavorites = "library.filter.favorites"
        static let genreMenu = "library.filter.genre.menu"
        static let genreAll = "library.filter.genre.all"
        /// Keyed by the genre's name, which is the server's own text.
        static func genre(_ name: String) -> String { "library.filter.genre.option.\(TestID.key(name))" }
        /// The iPad's search field in the filter header.
        static let searchField = "library.search.field"
        static let searchClear = "library.search.clear"

        // The Mac's view options.
        static let layoutPicker = "library.layout.picker"
        /// "grid" or "list".
        static func layout(_ rawValue: String) -> String { "library.layout.\(rawValue)" }
        static let thumbnailSmaller = "library.thumbnail.smaller"
        static let thumbnailSize = "library.thumbnail.size"
        static let thumbnailBigger = "library.thumbnail.bigger"

        // What the Mac offers for several selected items.
        static let selectionMenu = "library.selection.menu"
        static let selectionMarkWatched = "library.selection.markWatched"
        static let selectionMarkUnwatched = "library.selection.markUnwatched"
        static let selectionAddFavorite = "library.selection.addFavorite"
        static let selectionRemoveFavorite = "library.selection.removeFavorite"
    }

    // MARK: - Favorites (FavoritesView)

    enum Favorites {
        static let root = "favorites.root"
        static let loading = "favorites.loading"
        static let error = "favorites.error"
        static let empty = "favorites.empty"
        static let grid = "favorites.grid"
        /// The spinner shown while a further page loads (Mac toolbar).
        static let paging = "favorites.paging"
        /// The row of kind chips (iPhone, iPad, Apple TV).
        static let kinds = "favorites.kinds"
        /// The Mac's segmented control for the same choice.
        static let kindPicker = "favorites.kind.picker"
        /// Keyed by the item types it asks for: "movie-series-episode" (everything), "movie", "series", "episode".
        static func kind(_ types: String) -> String { "favorites.kind.\(TestID.key(types))" }
        static let layoutPicker = "favorites.layout.picker"
        /// "grid" or "list".
        static func layout(_ rawValue: String) -> String { "favorites.layout.\(rawValue)" }
        static let sortMenu = "favorites.sort.menu"
        static let sortPicker = "favorites.sort.picker"
        /// Keyed by `LibraryView.SortOption`'s raw value.
        static func sortOption(_ rawValue: String) -> String { "favorites.sort.option.\(rawValue)" }
        static let sortReverse = "favorites.sort.reverse"
    }

    // MARK: - Search (SearchView)

    enum Search {
        static let root = "search.root"
        static let back = "search.bar.back"
        static let field = "search.field"
        static let clear = "search.field.clear"
        /// The spinner beside the field or in the toolbar while a search runs.
        static let searching = "search.searching"
        /// The Mac's segmented scope control.
        static let scopePicker = "search.scope.picker"
        /// Keyed by `SearchView.Scope`'s raw value: all, films, shows, episodes.
        static func scope(_ rawValue: String) -> String { "search.scope.\(rawValue)" }
        /// What an empty field shows when there is nothing recent.
        static let prompt = "search.prompt"
        static let recents = "search.recents"
        static let recentsClear = "search.recents.clear"
        /// Keyed by the term itself, made safe by `TestID.key`.
        static func recent(_ term: String) -> String { "search.recent.\(TestID.key(term))" }
        static let loading = "search.loading"
        static let error = "search.error"
        /// No matches.
        static let empty = "search.empty"
        /// "12 results".
        static let resultCount = "search.results.count"
        /// The "Films & TV" heading over the grid when music matched too.
        static let videoHeading = "search.results.videoHeading"
        /// The grid of films, shows and episodes.
        static let results = "search.results"
        /// The Mac's grouped results: "films", "shows", "episodes".
        static func section(_ key: String) -> String { "search.results.section.\(key)" }
        static func sectionShowOnly(_ key: String) -> String { "search.results.section.showOnly.\(key)" }
        /// Artists, albums and songs (iPhone, iPad).
        static let musicResults = "search.results.music"
        static let audiobooks = "search.results.audiobooks"
    }

    // MARK: - Downloads (DownloadsView, DownloadedSeriesView, their Mac variants, SpacePromptView)

    enum Downloads {
        static let root = "downloads.root"
        static let empty = "downloads.empty"
        /// The Mac's one list of transfers and tiles.
        static let list = "downloads.list"

        // The summary card (iPhone, iPad) and the Mac's toolbar.
        static let summary = "downloads.summary"
        /// "12 items on this device".
        static let itemCount = "downloads.summary.itemCount"
        /// "4.2 GB · 31 GB free".
        static let storage = "downloads.summary.storage"
        /// Sends watched progress to the server.
        static let sync = "downloads.sync"
        /// Pause or Resume: one button, whose label says which.
        static let pause = "downloads.pause"
        static let showInFinder = "downloads.showInFinder"
        static let manageMenu = "downloads.manage.menu"
        static let manageDownloadAllMusic = "downloads.manage.downloadAllMusic"
        static let manageRetryAllFailed = "downloads.manage.retryAllFailed"
        static let manageClearQueue = "downloads.manage.clearQueue"
        static let manageDeleteWatched = "downloads.manage.deleteWatched"
        static let manageDeleteAll = "downloads.manage.deleteAll"
        /// "Reading your music library…" while Download All Music counts.
        static let musicSweep = "downloads.summary.musicSweep"
        static let concurrencyPicker = "downloads.settings.concurrency"
        static func concurrency(_ count: Int) -> String { "downloads.settings.concurrency.\(count)" }
        static let transcodeOneAtATime = "downloads.settings.transcodeOneAtATime"
        static let keepAwake = "downloads.settings.keepAwake"

        // The sections of the page (iPhone, iPad; the Mac's grids take the last two).
        static let pausedSection = "downloads.section.paused"
        static let downloadingSection = "downloads.section.downloading"
        static let queueSection = "downloads.section.queue"
        static let failedSection = "downloads.section.failed"
        static let showsSection = "downloads.section.shows"
        static let filmsSection = "downloads.section.films"

        // A transfer under way.
        static func transfer(_ itemId: String) -> String { "downloads.transfer.\(itemId)" }
        /// Cancel on a phone, the stop button on a Mac.
        static func transferCancel(_ itemId: String) -> String { "downloads.transfer.cancel.\(itemId)" }
        static func transferProgress(_ itemId: String) -> String { "downloads.transfer.progress.\(itemId)" }
        /// "42% · 1.1 GB / 2.6 GB".
        static func transferStatus(_ itemId: String) -> String { "downloads.transfer.status.\(itemId)" }
        /// "Fetching it again" or "Waiting for the server to encode".
        static func transferNote(_ itemId: String) -> String { "downloads.transfer.note.\(itemId)" }

        // Waiting in the queue.
        static func queued(_ itemId: String) -> String { "downloads.queued.\(itemId)" }
        static func queuedRemove(_ itemId: String) -> String { "downloads.queued.remove.\(itemId)" }
        /// "and 40 more waiting".
        static let queueMore = "downloads.queue.more"
        static let queueClear = "downloads.queue.clear"

        // Failed.
        static func failed(_ itemId: String) -> String { "downloads.failed.\(itemId)" }
        static func failedMessage(_ itemId: String) -> String { "downloads.failed.message.\(itemId)" }
        static func failedRetry(_ itemId: String) -> String { "downloads.failed.retry.\(itemId)" }
        static func failedDelete(_ itemId: String) -> String { "downloads.failed.delete.\(itemId)" }
        static let failedMore = "downloads.failed.more"
        static let failedRetryAll = "downloads.failed.retryAll"
        static let failedClear = "downloads.failed.clear"

        // The Mac list's menu for selected transfer, queue and failed rows.
        static let selectionStop = "downloads.selection.stop"
        static let selectionRemoveFromQueue = "downloads.selection.removeFromQueue"
        static let selectionRetry = "downloads.selection.retry"
        static let selectionDelete = "downloads.selection.delete"
        static let selectionShowInFinder = "downloads.selection.showInFinder"
        static let selectionOpenInNewWindow = "downloads.selection.openInNewWindow"

        // A downloaded show's poster, keyed by `DownloadSeries.id` (the series id,
        // or the show's name where no record carries one), and its menu.
        static func showCard(_ seriesKey: String) -> String { "downloads.show.\(seriesKey)" }
        static func showCardOpen(_ seriesKey: String) -> String { "downloads.show.open.\(seriesKey)" }
        static func showCardPlay(_ seriesKey: String) -> String { "downloads.show.play.\(seriesKey)" }
        static func showCardShuffle(_ seriesKey: String) -> String { "downloads.show.shuffle.\(seriesKey)" }
        static func showCardOpenInNewWindow(_ seriesKey: String) -> String { "downloads.show.openInNewWindow.\(seriesKey)" }
        static func showCardShowInFinder(_ seriesKey: String) -> String { "downloads.show.showInFinder.\(seriesKey)" }
        static func showCardDelete(_ seriesKey: String) -> String { "downloads.show.delete.\(seriesKey)" }

        // A downloaded film's poster and its menu.
        static func filmCard(_ itemId: String) -> String { "downloads.film.\(itemId)" }
        static func filmCardPlay(_ itemId: String) -> String { "downloads.film.play.\(itemId)" }
        static func filmCardToggleWatched(_ itemId: String) -> String { "downloads.film.toggleWatched.\(itemId)" }
        static func filmCardOpenInNewWindow(_ itemId: String) -> String { "downloads.film.openInNewWindow.\(itemId)" }
        static func filmCardShowInFinder(_ itemId: String) -> String { "downloads.film.showInFinder.\(itemId)" }
        static func filmCardDelete(_ itemId: String) -> String { "downloads.film.delete.\(itemId)" }

        // The doors to other downloaded things (iPhone, iPad).
        static let musicDoor = "downloads.door.music"
        static let audiobooksDoor = "downloads.door.audiobooks"
        static let watchDoor = "downloads.door.watch"
        static let watchDetail = "downloads.door.watch.detail"
        static let watchSync = "downloads.door.watch.sync"

        // "Delete …?" (a confirmation dialog on iPhone and iPad; an alert on the Mac, which takes no names).
        static let deletionConfirm = "downloads.deletion.confirm"
        static let deletionCancel = "downloads.deletion.cancel"

        // One downloaded episode's row (DownloadedRow).
        /// The row; on iPhone and iPad a press on it plays.
        static func row(_ itemId: String) -> String { "downloads.row.\(itemId)" }
        /// The Mac's play button on a row, and "Play" in a row's menu.
        static func rowPlay(_ itemId: String) -> String { "downloads.row.play.\(itemId)" }
        /// The ellipsis on a row (iPhone, iPad).
        static func rowMenu(_ itemId: String) -> String { "downloads.row.menu.\(itemId)" }
        static func rowToggleWatched(_ itemId: String) -> String { "downloads.row.toggleWatched.\(itemId)" }
        static func rowDelete(_ itemId: String) -> String { "downloads.row.delete.\(itemId)" }

        // A downloaded show's own page.
        static let seriesRoot = "downloads.series.root"
        static let seriesEmpty = "downloads.series.empty"
        /// The Mac's list of episodes.
        static let seriesList = "downloads.series.list"
        static let seriesTitle = "downloads.series.title"
        /// "2 seasons · 14 episodes".
        static let seriesSubtitle = "downloads.series.subtitle"
        static let seriesSize = "downloads.series.size"
        static let seriesUnwatched = "downloads.series.unwatched"
        static let seriesPlay = "downloads.series.play"
        static let seriesShuffle = "downloads.series.shuffle"
        static let seriesShowInFinder = "downloads.series.showInFinder"
        static let seriesDeleteMenu = "downloads.series.delete.menu"
        /// Keyed by `DownloadSeason.id`.
        static func seriesDeleteSeason(_ seasonKey: String) -> String { "downloads.series.delete.season.\(seasonKey)" }
        static let seriesDeleteWatched = "downloads.series.delete.watched"
        static let seriesDeleteAll = "downloads.series.delete.all"
        /// One season's block (its heading on the Mac), keyed by `DownloadSeason.id`.
        static func season(_ seasonKey: String) -> String { "downloads.series.season.\(seasonKey)" }
        static func seasonMenu(_ seasonKey: String) -> String { "downloads.series.season.menu.\(seasonKey)" }
        static func seasonPlay(_ seasonKey: String) -> String { "downloads.series.season.play.\(seasonKey)" }
        static func seasonShuffle(_ seasonKey: String) -> String { "downloads.series.season.shuffle.\(seasonKey)" }
        static func seasonDelete(_ seasonKey: String) -> String { "downloads.series.season.delete.\(seasonKey)" }
        // The Mac list's menu for selected episodes.
        static let seriesSelectionPlay = "downloads.series.selection.play"
        static let seriesSelectionToggleWatched = "downloads.series.selection.toggleWatched"
        static let seriesSelectionOpenInNewWindow = "downloads.series.selection.openInNewWindow"
        static let seriesSelectionShowInFinder = "downloads.series.selection.showInFinder"
        static let seriesSelectionDelete = "downloads.series.selection.delete"

        // "Not enough disk space": a sheet on iPhone and iPad; on the Mac an
        // alert whose buttons carry the same names (whether AppKit's alert
        // hands them on is not yet confirmed).
        static let spacePrompt = "downloads.spacePrompt.root"
        /// A smaller quality that would fit, keyed by its label through `TestID.key`.
        static func spacePromptUse(_ label: String) -> String { "downloads.spacePrompt.use.\(TestID.key(label))" }
        static let spacePromptAnyway = "downloads.spacePrompt.downloadAnyway"
        static let spacePromptCancel = "downloads.spacePrompt.cancel"
    }
}

// MARK: - Requests (Seerr)
//
// Keys used here:
// - a title Seerr knows: "<movie|tv>-<TMDB id>" (`SeerrResult.id`).
// - a request: Seerr's own request number.
// - a browse row: `SeerrClient.BrowseRow.rawValue`.

extension TestID {
    enum Requests {
        /// The Requests section.
        static let root = "requests.root"
        static let notConnected = "requests.notConnected"
        static let mine = "requests.mine"
        static let mineEmpty = "requests.mine.empty"
        static let mineError = "requests.mine.error"
        /// "No posters from Seerr": its Cache Images setting is off.
        static let postersOff = "requests.postersOff"
        static let settingsPosters = "settings.requests.posters"
        static func row(_ id: Int) -> String { "requests.row.\(id)" }
        static func rowStatus(_ id: Int) -> String { "requests.row.status.\(id)" }
        /// A shelf of titles from Seerr, by row key ("search", "collection",
        /// "person", or a browse row).
        static func shelf(_ key: String) -> String { "requests.shelf.\(key)" }
        static func card(_ key: String) -> String { "requests.card.\(key)" }
        static func cardBadge(_ key: String) -> String { "requests.card.badge.\(key)" }

        // A title's request page.
        static let titleRoot = "requests.title.root"
        static func titlePage(_ key: String) -> String { "requests.title.page.\(key)" }
        static let titleName = "requests.title.name"
        static let titleStanding = "requests.title.standing"
        static let titleRequest = "requests.title.request"
        static let titleCancel = "requests.title.cancel"
        /// The dialog's own "Cancel Request".
        static let titleCancelConfirm = "requests.title.cancel.confirm"
        static let titleOpenInLibrary = "requests.title.openInLibrary"
        static let titleQuota = "requests.title.quota"
        static let title4K = "requests.title.4k"
        static let titleNotAllowed = "requests.title.notAllowed"
        static let titleError = "requests.title.error"
        static let titleLoading = "requests.title.loading"
        static func titleSeason(_ number: Int) -> String { "requests.title.season.\(number)" }

        // What library pages gain.
        static let detailSeasons = "detail.requests.seasons"
        static let detailSeasonsButton = "detail.requests.seasons.request"

        // Settings.
        static let settingsConnect = "settings.requests.connect"
        static let settingsServer = "settings.requests.server"
        static let settingsUser = "settings.requests.user"
        static let settingsConnection = "settings.requests.connection"
        static let settingsSession = "settings.requests.session"
        static let settingsDisconnect = "settings.requests.disconnect"
        static let settingsReconnect = "settings.requests.reconnect"

        // The connect sheet.
        static let connectRoot = "requests.connect.root"
        static let connectAddress = "requests.connect.address"
        static let connectContinue = "requests.connect.continue"
        static let connectCancel = "requests.connect.cancel"
        static let connectError = "requests.connect.error"
        static let connectBusy = "requests.connect.busy"
        static let connectInsecure = "requests.connect.insecure"
        static let connectAnyway = "requests.connect.anyway"
        static let connectUsername = "requests.connect.username"
        static let connectPassword = "requests.connect.password"
        static let connectSignIn = "requests.connect.signIn"
    }
}
