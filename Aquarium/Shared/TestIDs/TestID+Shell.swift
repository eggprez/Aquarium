//  The shell, Home, and the components every page shares.
//
//  Keys used here:
//  - a section: `AppSection.id` — "home", "music", "books", "libraries",
//    "lib-<library id>", "favorites", "collections", "livetv", "downloads",
//    "search", "settings", "more".
//  - an item: its Jellyfin id.
//  - a shelf: a row key. Home's are the `row…` names in `Home`; a shelf whose
//    page gave it none is keyed by `TestID.key(<its heading>)`.

import Foundation

extension TestID {
    // MARK: - Shell

    /// RootView's states and what the shell hangs over every page.
    enum Shell {
        /// The signed-in shell: tab bar, sidebar or tvOS tab strip.
        static let root = "shell.root"
        /// No session: the sign-in screen is showing.
        static let signedOut = "shell.signedOut.root"
        /// Signed in, the saved Home still being read off disk (a few ms).
        static let launching = "shell.launching.root"
        /// The "Switching to <user>…" cover.
        static let switchingAccount = "shell.switchingAccount.root"
        static let switchingAccountText = "shell.switchingAccount.text"

        /// The full-page "Server offline" state a section shows.
        static let offlineScreen = "shell.offline.root"
        static let offlineScreenTitle = "shell.offline.title"
        static let offlineScreenRetry = "shell.offline.retry"
        static let offlineScreenDownloads = "shell.offline.downloads"

        /// The "Offline — showing downloads" strip above the tab bar. One
        /// combined element: its Retry button is folded into it, at its
        /// trailing end, and has no identifier of its own.
        static let offlineBanner = "shell.offlineBanner.root"

        /// The stack toasts are drawn in (present even when empty).
        static let toasts = "shell.toast.root"
        /// One toast card, by its position among those showing (0 = oldest).
        static func toast(_ index: Int) -> String { "shell.toast.card.\(index)" }
        /// A toast's words. One per toast showing, all with this name.
        static let toastText = "shell.toast.text"
        /// The Mac's ✕ on a toast. One per toast showing.
        static let toastDismiss = "shell.toast.dismiss"

        /// The phone's More list.
        static let more = "shell.more.root"
        /// A row in the More list, by section.
        static func moreRow(_ section: String) -> String { "shell.more.row.\(section)" }

        /// The page a section shows, by section.
        static func section(_ section: String) -> String { "shell.section.root.\(section)" }

        /// "Add to Next Up" confirmation dialog buttons.
        static let nextUpFromLastWatched = "shell.nextUpDialog.fromLastWatched"
        static let nextUpFromFirstEpisode = "shell.nextUpDialog.fromFirstEpisode"
        static let nextUpCancel = "shell.nextUpDialog.cancel"

        /// The Mac sidebar's sign-out confirmation.
        static let signOutConfirm = "shell.signOutDialog.confirm"
        static let signOutCancel = "shell.signOutDialog.cancel"
    }

    // MARK: - Tab

    /// The tab bar (the system's and the app's own `WideTabBar`) and the
    /// tvOS tab strip.
    enum Tab {
        /// One tab, by section.
        static func item(_ section: String) -> String { "tab.item.\(section)" }
    }

    // MARK: - Sidebar

    /// The iPad's and the Mac's sidebar.
    enum Sidebar {
        static let root = "sidebar.root"
        /// One row, by section.
        static func row(_ section: String) -> String { "sidebar.row.\(section)" }
        /// The iPad's Search row (it pushes Search rather than selecting it).
        static let searchRow = "sidebar.searchRow.button"
        /// The iPad header's "Hide sidebar".
        static let collapse = "sidebar.header.collapse"
        /// The iPad header's name and server, one combined element.
        static let account = "sidebar.header.account"
        /// The gear at the foot of the iPad's sidebar.
        static let settings = "sidebar.footer.settings"
        /// "Synced" / "Offline" / "2 downloads running".
        static let status = "sidebar.footer.status"

        /// The now-playing card at the foot of the sidebar.
        static let nowPlaying = "sidebar.nowPlaying.root"
        static let nowPlayingTitle = "sidebar.nowPlaying.title"
        static let nowPlayingPlayPause = "sidebar.nowPlaying.playPause"

        /// The Mac's account menu at the foot of the sidebar, and what is in it.
        static let accountMenu = "sidebar.accountMenu.root"
        /// One saved account in the menu, by its account key.
        static func accountMenuSwitch(_ accountKey: String) -> String { "sidebar.accountMenu.switch.\(accountKey)" }
        static let accountMenuAdd = "sidebar.accountMenu.add"
        static let accountMenuSettings = "sidebar.accountMenu.settings"
        static let accountMenuSignOut = "sidebar.accountMenu.signOut"

        /// A Mac sidebar row's context menu, by section.
        static func rowOpenInNewWindow(_ section: String) -> String { "sidebar.rowMenu.openInNewWindow.\(section)" }
        static func rowRefresh(_ section: String) -> String { "sidebar.rowMenu.refresh.\(section)" }

        /// A recent term under the Mac's sidebar search field, by
        /// `TestID.key(<the term>)`.
        static func searchSuggestion(_ term: String) -> String { "sidebar.search.suggestion.\(term)" }

        /// "Show sidebar", on the pages that draw their own bar.
        static let show = "sidebar.show"
    }

    // MARK: - Home

    enum Home {
        static let root = "home.root"
        /// The skeleton page before anything has loaded.
        static let loading = "home.loading.root"
        static let error = "home.error.root"
        static let empty = "home.empty.root"

        /// Top bar (phone and iPad), Mac toolbar, tvOS corner button.
        static let search = "home.bar.search"
        static let refresh = "home.bar.refresh"
        /// The Mac toolbar's Play Featured.
        static let playFeatured = "home.bar.playFeatured"

        /// The media bar as a whole.
        static let hero = "home.hero.root"
        /// One page of the media bar, by item id. On iPhone, iPad and tvOS
        /// every page exists at once; only one is on screen.
        static func heroPage(_ itemId: String) -> String { "home.hero.page.\(itemId)" }
        /// The typeset title on a page (absent when a logo image is drawn).
        static func heroTitle(_ itemId: String) -> String { "home.hero.title.\(itemId)" }
        static func heroPlay(_ itemId: String) -> String { "home.hero.play.\(itemId)" }
        static func heroDetails(_ itemId: String) -> String { "home.hero.details.\(itemId)" }
        /// The Mac's backdrop, which is a button that opens the title.
        static func heroBackdrop(_ itemId: String) -> String { "home.hero.backdrop.\(itemId)" }
        /// "42 min left" beside the hero's progress bar.
        static func heroRemaining(_ itemId: String) -> String { "home.hero.remaining.\(itemId)" }
        /// A thumbnail in the corner of the bar (iPad landscape, wide Mac window).
        static func heroThumb(_ itemId: String) -> String { "home.hero.thumb.\(itemId)" }
        /// A page dot, by position. Buttons on the Mac only; elsewhere the
        /// dots are hidden from accessibility.
        static func heroDot(_ index: Int) -> String { "home.hero.dot.\(index)" }
        /// Which page the bar is on (0-based): an anchor on the dots or the
        /// thumbnails, renamed as the bar turns. Absent with one page.
        static func heroCurrentPage(_ index: Int) -> String { "home.hero.currentPage.\(index)" }
        /// The Mac's ‹ and › over the bar.
        static let heroPrevious = "home.hero.previous"
        static let heroNext = "home.hero.next"

        // Row keys, for `shelf` and the rest below.
        static let rowLibraries = "home-libraries"
        static let rowResume = "home-resume"
        static let rowNextUp = "home-nextUp"
        /// "Latest in <library>", by the library's id.
        static func rowLatest(_ libraryId: String) -> String { "home-latest-\(libraryId)" }
        static let rowLiveTV = "home-liveTV"
        static let rowMusicRecent = "home-musicRecent"
        static let rowMusicNew = "home-musicNew"

        /// A shelf on Home, by row key. The same identifier as
        /// `Common.shelf`: the shelf is the shared component.
        static func shelf(_ row: String) -> String { Common.shelf(row) }
        static func shelfTitle(_ row: String) -> String { Common.shelfTitle(row) }
        static func shelfSeeAll(_ row: String) -> String { Common.shelfSeeAll(row) }
    }

    // MARK: - Item

    /// The shared cards, and the press-and-hold menu every card carries.
    enum Item {
        /// A poster or still card for one item, wherever it is drawn. The
        /// same item in two rows of a page is two elements with this name.
        static func card(_ itemId: String) -> String { "item.card.\(itemId)" }

        // The context menu. One menu is open at a time, so these need no key.
        static let menuWatchChannel = "item.menu.watchChannel"
        /// Play or Resume.
        static let menuPlay = "item.menu.play"
        static let menuPlayFromBeginning = "item.menu.playFromBeginning"
        static let menuPlayNext = "item.menu.playNext"
        static let menuPlayLater = "item.menu.playLater"
        static let menuPlayNextEpisode = "item.menu.playNextEpisode"
        static let menuPlaySeasonNext = "item.menu.playSeasonNext"
        static let menuPlaySeasonLater = "item.menu.playSeasonLater"
        /// Details / Episode Details / Get Info.
        static let menuDetails = "item.menu.details"
        static let menuOpenInNewWindow = "item.menu.openInNewWindow"
        static let menuCopyTitle = "item.menu.copyTitle"
        static let menuGoToShow = "item.menu.goToShow"
        static let menuGoToSeason = "item.menu.goToSeason"
        static let menuFavorite = "item.menu.favorite"
        static let menuWatched = "item.menu.watched"
        static let menuRemoveFromNextUp = "item.menu.removeFromNextUp"
        static let menuAddToNextUp = "item.menu.addToNextUp"
        static let menuShowInFinder = "item.menu.showInFinder"
        static let menuDeleteDownload = "item.menu.deleteDownload"
        static let menuShowDownloadProgress = "item.menu.showDownloadProgress"
        /// The Download submenu.
        static let menuDownload = "item.menu.download"
        /// One rung in the Download submenu, by `TestID.key(<quality label>)`:
        /// "original-quality", "4k-34-mbps-transcoded",
        /// "1440p-18-mbps-transcoded", "1080p-9-mbps-transcoded",
        /// "720p-4-5-mbps-transcoded", "480p-2-mbps-transcoded".
        static func menuDownloadQuality(_ quality: String) -> String { "item.menu.downloadQuality.\(quality)" }

        /// A crumb above a title (its show, its season), by the id it opens.
        static func ancestor(_ itemId: String) -> String { "item.ancestor.link.\(itemId)" }
    }

    // MARK: - Common

    /// Shared components that are not about one item.
    enum Common {
        /// A horizontal shelf, by row key (see the top of this file).
        static func shelf(_ row: String) -> String { "common.shelf.root.\(row)" }
        static func shelfTitle(_ row: String) -> String { "common.shelf.title.\(row)" }
        /// "See all". On the Mac the heading is a button to the same place:
        /// `shelfHeadingLink`.
        static func shelfSeeAll(_ row: String) -> String { "common.shelf.seeAll.\(row)" }
        static func shelfHeadingLink(_ row: String) -> String { "common.shelf.headingLink.\(row)" }
        /// The Mac's ‹ and › over a shelf.
        static func shelfPrevious(_ row: String) -> String { "common.shelf.previous.\(row)" }
        static func shelfNext(_ row: String) -> String { "common.shelf.next.\(row)" }

        /// The poster grid of a library, search results, and so on.
        static let grid = "common.grid.root"

        static let emptyState = "common.empty.root"
        static let emptyStateTitle = "common.empty.title"
        static let emptyStateAction = "common.empty.action"
        static let errorState = "common.error.root"
        static let errorStateMessage = "common.error.message"
        static let errorStateRetry = "common.error.retry"

        static let skeletonHero = "common.skeleton.hero"
        static let skeletonShelf = "common.skeleton.shelf"
        static let skeletonList = "common.skeleton.list"
        static let skeletonGrid = "common.skeleton.grid"

        /// The "Aquarium" wordmark in a page's own top bar.
        static let brand = "common.bar.brand"
        /// The back button of a page that draws its own bar.
        static let back = "common.bar.back"
        /// The A–Z strip down a list's trailing edge.
        static let letterIndex = "common.letterIndex.root"
        /// tvOS: a pushed page's heading.
        static let pageHeading = "common.pageHeading.title"
    }

    // MARK: - MacMenu

    /// Nothing in the menu bar takes an identifier (see TESTING notes); find
    /// menu items by title. Here so the name is taken.
    enum MacMenu {}

    // MARK: - Tent

    /// The idle screen of a foldable stood up as a tent.
    enum Tent {
        static let root = "tent.root"
        static let browse = "tent.bar.browse"
        static let nowPlaying = "tent.nowPlaying.root"
        static let nowPlayingTitle = "tent.nowPlaying.title"
        static let nowPlayingPlayPause = "tent.nowPlaying.playPause"
        static let nowPlayingNext = "tent.nowPlaying.next"
        /// "Loading…" / "Nothing to continue".
        static let empty = "tent.empty.root"
        static let emptyText = "tent.empty.text"
        static let emptyBrowse = "tent.empty.browse"
        /// The Continue Watching shelf's row key.
        static let rowContinue = "tent-continue"

        /// FoldSplit's halves.
        static let foldUpper = "tent.fold.upper"
        static let foldLower = "tent.fold.lower"
    }
}
