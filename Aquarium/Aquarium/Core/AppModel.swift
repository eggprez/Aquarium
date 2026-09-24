//  Shell state: which section is showing, what's on the navigation stack, the
//  libraries in the sidebar, and the transient messages the Linux build showed
//  as toasts.

import Foundation
#if os(iOS) || os(macOS)
import CoreSpotlight
#endif
import Observation
import SwiftUI

/// A destination that can be pushed onto a navigation stack.
enum Route: Hashable, Sendable {
    case item(String)
    /// `collectionType` decides what a library lists — a television library
    /// shows series, not the seasons and episodes underneath them — so it
    /// travels with the route rather than being rediscovered at the far end.
    case library(id: String, name: String, collectionType: String?)
    case search(String)
    /// A downloaded show, by the key `DownloadGroups` gives it. Reachable only
    /// from Downloads, which tvOS doesn't have.
    case downloadedSeries(String)
    /// Someone from a cast list: who they are and what of theirs is in the
    /// library. The name travels with the id so the page has a title before
    /// the server has answered.
    case person(id: String, name: String)
    /// A whole section, opened from the phone's More list. See `AppSection.more`.
    case section(AppSection)
    /// A page inside the Music tab — an artist, an album, a genre, one of the
    /// library's lists. See `MusicRoute`.
    case music(MusicRoute)
}

/// Where the Music tab can go. Its own enum rather than more cases on
/// `Route`, because there are a dozen of them and none of them means anything
/// to the video side of the app.
enum MusicRoute: Hashable, Sendable {
    case artist(String)
    case album(String)
    case genre(id: String, name: String)
    case playlist(String)
    /// A rule-based playlist kept on this device — see `SmartPlaylist`.
    case smartPlaylist(UUID)
    case audiobook(String)
    /// An author's books, from the Audiobooks tab. An author is a
    /// `MusicArtist` on the server, but their page is not the artist page:
    /// that one lists albums, and an author has none.
    case author(id: String, name: String)
    case artists
    case albums
    case songs
    case genres
    case playlists
    case audiobooks
    case downloaded
    case downloadedBooks
    /// A route answered from what is on this device, whatever the connection:
    /// the pages behind Library → Downloaded. Without it an artist opened
    /// from the downloaded list was the server's artist, with every album
    /// they ever made, the moment there was a server to ask.
    indirect case onDevice(MusicRoute)
    case recentlyAdded
    case favorites
    /// The songs behind one Discover shelf, as a full page.
    case songList(title: String, kind: SongListKind)
    case search

    /// Which songs a `songList` page shows.
    enum SongListKind: Hashable, Sendable {
        case recentlyPlayed, mostPlayed, favorites
    }
}

/// The top-level sections. Which of them exist depends on the platform and on
/// what the server actually has — a Live TV entry on a server with no tuner can
/// never say anything but "no channels".
enum AppSection: Hashable, Identifiable, Sendable {
    case home
    /// Music: Discover, the library, search. Only where the server has a
    /// music or audiobook library, and only on iPhone and iPad for now.
    case music
    /// Audiobooks: their own tab, deliberately apart from music — a book is
    /// not a song that happens to be long. Same player underneath.
    case books
    /// Every library on the server, in one place — the phone's third tab, so
    /// browsing doesn't start with a trip through More.
    case libraries
    case library(id: String, name: String, collectionType: String?)
    case favorites
    case liveTV
    case downloads
    case search
    case settings
    /// The phone's overflow tab. Not a screen of its own on any other platform
    /// — a sidebar lists everything at once and a television's strip is not
    /// width-limited — so nothing but the phone's tab bar ever produces it.
    case more

    var id: String {
        switch self {
        case .home: "home"
        case .music: "music"
        case .books: "books"
        case .libraries: "libraries"
        case .library(let id, _, _): "lib-\(id)"
        case .favorites: "favorites"
        case .liveTV: "livetv"
        case .downloads: "downloads"
        case .search: "search"
        case .settings: "settings"
        case .more: "more"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .music: "Music"
        case .books: "Audiobooks"
        case .libraries: "Library"
        case .library(_, let name, _): name
        case .favorites: "Favorites"
        case .liveTV: "Live TV"
        case .downloads: "Downloads"
        case .search: "Search"
        case .settings: "Settings"
        case .more: "More"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .music: "music.note"
        case .books: "book"
        case .libraries: "books.vertical"
        case .library(_, _, let type):
            switch type {
            case "movies": "film"
            case "tvshows": "tv"
            default: "folder"
            }
        case .favorites: "star"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        case .more: "ellipsis"
        }
    }
}

struct Toast: Identifiable, Equatable, Sendable {
    enum Tone: Sendable { case info, ok, error }
    let id = UUID()
    var text: String
    var tone: Tone = .info
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var libraries: [BaseItem] = []
    private(set) var serverHasLiveTV = false
    private(set) var isLoadingLibraries = false
    /// The music libraries and the audiobook libraries, kept apart from the
    /// video ones: they are browsed by the Music tab, not by Library.
    private(set) var musicLibraries: [BaseItem] = []
    private(set) var audiobookLibraries: [BaseItem] = []

    /// Whether there is anything for a Music tab to show. iPhone and iPad
    /// only for now — the Mac and the television get theirs in a later pass.
    var hasMusic: Bool {
        #if os(iOS)
        return !musicLibraries.isEmpty || (librariesUnknown && remembered("had_music_library", downloaded: "Audio"))
        #else
        return false
        #endif
    }

    var hasBooks: Bool {
        #if os(iOS)
        return !audiobookLibraries.isEmpty || (librariesUnknown && remembered("had_books_library", downloaded: "AudioBook"))
        #else
        return false
        #endif
    }

    /// The server couldn't be asked what libraries there are — a launch with
    /// no network, the case offline music exists for. The Music and
    /// Audiobooks tabs are then shown on the strength of what was there last
    /// time, or of there being something downloaded to play in them; without
    /// this the tab itself was missing exactly when its offline mode was
    /// wanted.
    ///
    /// True from the start, too: a launch hasn't asked yet, and that is the
    /// same not-knowing. Left false until the answer came, the first second
    /// of every launch drew a tab bar with no Music, Audiobooks or Live TV in
    /// it — and someone who had put those first in their own order (Settings
    /// → Tab Bar) watched a different bar flash up and then rearrange itself.
    private var librariesUnknown = true

    /// Whether the server had Live TV the last time it was asked; what the
    /// tab bar goes on until it has been asked again.
    private var rememberedLiveTV = UserDefaults.standard.bool(forKey: "had_server_live_tv")

    #if os(iOS)
    /// Worked out once per change to the downloads. The tab bar asks this
    /// through several derived lists on every redraw of the shell, and each
    /// time it was a defaults read and a pass over every download. The
    /// records are still read, so the bar still hears about a change.
    private func remembered(_ key: String, downloaded type: String) -> Bool {
        let downloads = DownloadManager.shared
        let records = downloads.records
        if let kept = rememberedAnswers[key], kept.revision == downloads.recordsRevision { return kept.value }
        let value = UserDefaults.standard.bool(forKey: key)
            || records.contains { $0.type == type && $0.status == .complete }
        rememberedAnswers[key] = (downloads.recordsRevision, value)
        return value
    }

    @ObservationIgnored private var rememberedAnswers: [String: (revision: Int, value: Bool)] = [:]
    #endif

    /// Either of the two audio tabs: what decides whether the music player's
    /// settings, the mini player and the audio search are wanted at all.
    var hasAudio: Bool { hasMusic || hasBooks }

    /// A tuner on the server is one way in; a custom M3U/XMLTV source
    /// configured in Settings is the other, and it works "whether or not this
    /// server has Live TV set up at all" — see the Settings copy — so it has
    /// to open the tab on its own rather than waiting on `serverHasLiveTV`.
    var hasLiveTV: Bool {
        serverHasLiveTV || (librariesUnknown && rememberedLiveTV) || Preferences.shared.liveTVSource == .custom
    }

    /// Which section the shell is showing. Always Home at launch.
    ///
    /// It used to be restored from `lastRoute` once the libraries came back,
    /// so opening the app dropped you wherever you happened to have closed it
    /// — including straight into a tab you were only passing through. Launching
    /// is its own moment and Home is what it should show; getting anywhere else
    /// is one tap.
    var selection: AppSection = .home

    // MARK: - Where a page zooms out of

    /// Set by a poster tile just before it pushes, moved by `push` to
    /// `pendingZoomSource`, and read by the page as it is built — see
    /// `ZoomedDestination` in RootView. Anything else that pushes leaves it
    /// nil, and that page slides in the ordinary way.
    @ObservationIgnored var zoomSource: String?
    @ObservationIgnored private(set) var pendingZoomSource: String?
    @ObservationIgnored private var lastActivity: (id: ObjectIdentifier, at: Date)?
    @ObservationIgnored private var lastLink: (url: URL, at: Date)?

    /// One stack per section, so switching away and back keeps your place —
    /// going back to a library you were forty rows deep in and landing at the
    /// top of it is the single most annoying thing a media browser can do.
    var paths: [String: NavigationPath] = [:] {
        didSet {
            let depth = paths[AppSection.home.id]?.count ?? 0
            if depth != homeDepth { homeDepth = depth }
        }
    }

    /// How many pages are pushed on Home's stack, kept apart from `paths` for
    /// the one screen that asks. Home reads it to know whether it is in front;
    /// reading `paths` itself made Home a reader of every tab's stack, redrawn
    /// on every push and pop anywhere in the app.
    private(set) var homeDepth = 0

    /// What is on each stack, in order.
    ///
    /// `NavigationPath` will say how many pages it is holding and nothing about
    /// what they are, and the one question a breadcrumb has to ask is exactly
    /// that: is the page I point at already behind me? So the routes are kept
    /// alongside the path, pushed and popped with it. See `navigate(to:)`.
    private var routeStacks: [String: [Route]] = [:]

    #if os(tvOS)
    /// The title page a television opens over everything else, and the stack of
    /// pages reached from it.
    ///
    /// On a phone a detail page is pushed into the tab it was opened from, and
    /// the tab bar stays where it is because that is what a phone's tab bar
    /// does. A television's is a strip of words across the top of the screen,
    /// and a page pushed underneath it is a page with something else's
    /// navigation over it — which is both how it looked ("an overlay of the home
    /// page") and, worse, where the selector kept going: up out of the page and
    /// onto the strip, from where the Menu button quits the application rather
    /// than going back a level.
    ///
    /// So a title opens as its own screen instead. No strip, no tab underneath,
    /// and the focus engine has nothing to reach but the page — which is the
    /// whole point.
    var detailRoot: Route?

    /// `routeStacks` for the television's own stack, kept the same way and for
    /// the same reason. The root is `detailRoot` and is not in here.
    private(set) var detailRoutes: [Route] = []

    private var detailPathStorage = NavigationPath()
    var detailPath: NavigationPath {
        get { detailPathStorage }
        set {
            detailPathStorage = newValue
            // The Menu button pops without going through `push`, so the list
            // follows the path's length rather than trying to watch for it.
            if newValue.count < detailRoutes.count {
                detailRoutes.removeLast(detailRoutes.count - newValue.count)
            }
        }
    }

    func closeDetail() {
        detailPath = NavigationPath()
        detailRoutes = []
        detailRoot = nil
        pendingEpisodeHighlight = nil
    }
    #endif

    /// One episode on one season's page, for the page to land on when it opens
    /// — the selector on a television, the scroll position and a moment's
    /// emphasis everywhere else. Read once, by the page it names.
    struct EpisodeHighlight: Hashable, Sendable {
        var seasonId: String
        var episodeId: String
    }

    /// Set by whatever opened a season page out of order — Next Up, which knows
    /// the episode but sends you to the list it lives in.
    ///
    /// Deliberately not part of the `Route`. A route is an identity: the season
    /// page reached from Next Up and the same page reached from a breadcrumb are
    /// the same page, and `navigate(to:)` decides whether to pop or push by
    /// comparing routes. Folding an arrival detail into that would make one page
    /// look like two.
    var pendingEpisodeHighlight: EpisodeHighlight?

    /// Where Next Up leads: the show, with the season on top of it and the
    /// episode already picked out.
    ///
    /// The same journey on every platform, built two different ways because the
    /// two shells keep their pages in different places — a television's title
    /// screen has a stack of its own (see `detailRoot`), a phone pushes into the
    /// tab it was opened from. Either way the stack is built whole rather than
    /// pushed a page at a time: two pushes would present the show and then slide
    /// the season over it, and the show is scenery here, not somewhere you were.
    func openNextUp(seriesId: String, seasonId: String, episodeId: String) {
        pendingEpisodeHighlight = EpisodeHighlight(seasonId: seasonId, episodeId: episodeId)
        #if os(tvOS)
        let season = Route.item(seasonId)
        var path = NavigationPath()
        path.append(season)
        detailRoot = .item(seriesId)
        detailRoutes = [season]
        detailPath = path
        #else
        let key = selection.id
        let added: [Route] = [.item(seriesId), .item(seasonId)]
        var path = paths[key] ?? NavigationPath()
        for route in added { path.append(route) }
        paths[key] = path
        routeStacks[key, default: []].append(contentsOf: added)
        #endif
    }

    var toasts: [Toast] = []

    /// Raised when something needs the whole screen to explain itself — a
    /// server identity change, an expired session.
    var blockingMessage: String?

    private let client = JellyfinClient.shared
    private var retryTask: Task<Void, Never>?
    /// Which loop `retryTask` holds, so one that ends clears only its own.
    private var retryGeneration: UUID?
    /// The connectivity probe currently in flight, so two callers asking at
    /// once share one answer rather than racing — see `refreshConnectivity`.
    private var connectivityTask: Task<Void, Never>?
    /// Whether the server has been probed at least once this launch — see
    /// `performConnectivityRefresh`.
    private var hasProbedOnce = false

    /// False until the launch's first question to the server has an answer.
    /// The shell waits for it (see `RootView`), so an app opened offline goes
    /// straight to the offline tabs instead of first drawing the online ones
    /// with Home failing to load — the same tabs, reached the same way, as an
    /// app that loses the server while open. Once per launch: a later sign-in
    /// doesn't wait again.
    private(set) var launchSettled = false

    private init() {
        // The network changing under the app, or a page's request finding
        // nothing there, is asked about at once, by the same probe a launch
        // uses — so "offline" means one thing however it came about.
        client.onNetworkChanged = { [weak self] in
            guard let self else { return }
            Task {
                if self.client.isOffline { await self.retryNow() } else { await self.refreshConnectivity() }
            }
        }
        client.onRequestUnreachable = { [weak self] in
            guard let self, !self.client.isOffline else { return }
            // No connection reset: that would cancel every other page's
            // requests still in flight on a guess.
            Task { await self.refreshConnectivity(resettingConnections: false) }
        }
    }

    // MARK: - Sections

    /// The sidebar's list: every library spelled out, since there is room for
    /// them.
    ///
    /// A television's is five entries and no more. tvOS draws its sections as a
    /// row of words across the top of the screen, and every one of them costs a
    /// press to get past — a server with five libraries put nine things up
    /// there, most of which were the same screen with a different filter on it.
    /// Home, the libraries behind one entry, Search, Live TV where the server
    /// has a tuner, and Settings. Favorites stays out: it is a filter the
    /// library screen already carries.
    ///
    /// Search earns its permanent place where the others don't. On a phone it
    /// is a field in the navigation bar of whatever page you are on; a
    /// television has no navigation bar and no keyboard, so a search that isn't
    /// in the strip is a search reached by going somewhere else first — and
    /// naming a title is the fastest way through a library of thousands when
    /// the alternative is a grid and a directional pad.
    var sections: [AppSection] {
        #if os(tvOS)
        var out: [AppSection] = [.home, .libraries, .search]
        if hasLiveTV { out.append(.liveTV) }
        out.append(.settings)
        return out
        #else
        if isOfflineShell { return offlineSections }
        var out: [AppSection] = [.home]
        for kind in customOrder ?? customizableSections {
            switch kind {
            case .search:
                // A phone never lists it here: there Search is a tab or it is
                // in More — see `overflowSections`. A sidebar does. It once
                // left Search out on the grounds that each page had a field
                // of its own, and the library pages don't: on an iPad there
                // was no way to search films and shows at all.
                if Self.usesSidebar { out.append(.search) }
            case .libraries:
                for library in libraries {
                    out.append(.library(id: library.Id, name: library.title, collectionType: library.CollectionType))
                }
            default:
                out.append(kind)
            }
        }
        out.append(.settings)
        return out
        #endif
    }

    // MARK: - Offline

    /// With the server out of reach the app is what is on this device and
    /// nothing else.
    ///
    /// It used to be more than that: Home, the libraries and Favorites were
    /// drawn from the saved library copy, artwork came out of the image cache,
    /// and the result looked exactly like an app with a server behind it —
    /// until something was pressed and nothing played. So the copy is for
    /// bridging a load, not for standing in for the server. Offline the shell
    /// is Downloads and More (with Settings in it) — see `offlineSections`.
    ///
    /// `showsOffline` rather than `isOffline`, so the shell changes when the
    /// offline screen would have — not during a foreground recheck.
    var isOfflineShell: Bool {
        #if os(tvOS)
        // Nothing can be downloaded to a television, so there is no smaller
        // app to fall back to; its tabs stay and say the server is offline.
        false
        #else
        client.showsOffline
        #endif
    }

    #if !os(tvOS)
    /// Downloads, and More with Settings in it. That's all: the user's call,
    /// after the offline tabs came and went with what happened to be
    /// downloaded (an Audiobooks tab for one book). Downloaded music and
    /// audiobooks are rows on the Downloads page. The same list whether the
    /// app was opened offline or lost the server while open.
    private var offlineSections: [AppSection] { [.downloads, .settings] }
    #endif

    /// The section the shell is actually showing: `selection`, unless that
    /// names somewhere the shell hasn't got just now — Home with the server
    /// gone, say. The shells bind to this rather than to `selection`, because
    /// a tab bar told to select a tab it doesn't have shows nothing at all,
    /// and the frame in which the sections change is drawn before anything
    /// has had a chance to move the selection. See `reconcileSelection`.
    var shownSelection: AppSection {
        #if os(tvOS)
        return selection
        #else
        guard isOfflineShell else { return selection }
        let shown = Self.usesSidebar ? sections : tabSections
        return shown.contains(selection) ? selection : .downloads
        #endif
    }

    /// Going offline or coming back: put the selection somewhere that exists.
    /// Offline that is Downloads. Back online it is wherever they already are
    /// if the full shell still has that as a tab, and Home if it doesn't.
    func reconcileSelection() {
        #if !os(tvOS)
        if isOfflineShell {
            // Always Downloads, wherever they were — the same place an app
            // opened offline starts. More starts at its list, since whatever
            // was pushed in it came from the server.
            selection = .downloads
            paths[AppSection.more.id] = nil
            routeStacks[AppSection.more.id] = nil
            return
        }
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Downloads is a tab of its own offline and, on most setups, a
            // row in More online. Someone on it when the server comes back
            // stays on it — `show` reopens it where it now lives.
            if tabSections.contains(selection) { return }
            if overflowSections.contains(selection) { show(selection) } else { selection = .home }
            return
        }
        #endif
        if !sections.contains(selection), selection != .more { selection = .home }
        #endif
    }

    /// What the tab bar and the sidebar bind their selection to.
    var shownSelectionBinding: Binding<AppSection> {
        Binding(get: { self.shownSelection }, set: { self.selection = $0 })
    }

    /// The sections a person can put in order themselves, in the order they
    /// come in until someone does, and only the ones this setup actually has.
    ///
    /// Home isn't here: it always leads. Neither are the individual libraries
    /// — `.libraries` stands for the lot of them, kept together as a block
    /// rather than scattered through whatever a person picks apart.
    var customizableSections: [AppSection] {
        var out: [AppSection] = []
        if hasMusic { out.append(.music) }
        if hasBooks { out.append(.books) }
        out.append(.search)
        out.append(.libraries)
        out.append(.favorites)
        if hasLiveTV { out.append(.liveTV) }
        out.append(.downloads)
        return out
    }

    /// `Preferences.tabBarOrder` made real against what exists right now:
    /// anything saved that has since gone (a library removed, Live TV turned
    /// off) drops out, and anything newly available goes on the end rather
    /// than being silently left out. Nil until somebody has customized
    /// anything, so every reader falls back to the computed order.
    private var customOrder: [AppSection]? {
        let saved = Preferences.shared.tabBarOrder
        guard !saved.isEmpty else { return nil }
        var remaining = customizableSections
        var out: [AppSection] = []
        for id in saved {
            if let index = remaining.firstIndex(where: { $0.id == id }) {
                out.append(remaining.remove(at: index))
            }
        }
        out.append(contentsOf: remaining)
        return out
    }

    /// The four sections that keep a permanent place in the phone's tab bar:
    /// Home, Search, the libraries, and then whichever of Live TV and Downloads
    /// this setup actually uses. Favorites is a filter you reach for
    /// occasionally rather than a place you live, so it goes into More along
    /// with the individual libraries.
    ///
    /// Live TV takes the fourth slot wherever there is a guide to show — from
    /// the server's own tuner or from a custom playlist, `hasLiveTV` doesn't
    /// care which. A guide is somewhere you go on purpose and go back to;
    /// Downloads is a shelf you visit before a flight, and one trip through
    /// More is the right price for it.
    ///
    /// Music, where the server has any, takes the slot after Home: it is a
    /// whole second application living in this one, and a tab bar has five
    /// places. That costs Live TV and Downloads their permanent place on such
    /// a server — both are still one tap into More.
    ///
    /// Audiobooks take a slot of their own too, when there are any. With both,
    /// the bar is Home, Music, Audiobooks, Search, More, and the video
    /// Library joins Live TV and Downloads in More.
    ///
    /// All of that is what happens until someone puts the bar in an order of
    /// their own (Settings → Tab Bar). Then the first three of their order
    /// take the slots after Home, whatever they are, and the rest go to More.
    var primaryTabs: [AppSection] {
        #if !os(tvOS)
        // Downloads alone; Settings goes in More (see `overflowSections`).
        if isOfflineShell { return [.downloads] }
        #endif
        return [.home] + barAfterHome
    }

    /// The online bar's places after Home, whether or not the shell is
    /// offline just now — what the offline shell takes its tabs from.
    private var barAfterHome: [AppSection] {
        Array((customOrder ?? defaultPrimaryOrder).prefix(Self.slotsAfterHome))
    }

    /// How many sections fit after Home before the fifth place goes to More.
    static let slotsAfterHome = 3

    /// The customizable sections in the order the bar and More are using —
    /// what Settings → Tab Bar shows, and what it writes back reordered.
    var tabOrder: [AppSection] {
        if let customOrder { return customOrder }
        let primary = defaultPrimaryOrder
        return primary + customizableSections.filter { !primary.contains($0) }
    }

    /// The order above, before anyone changed it. The conditions never let
    /// this run past three, which is what keeps the bar to five places.
    private var defaultPrimaryOrder: [AppSection] {
        var out: [AppSection] = []
        if hasMusic { out.append(.music) }
        if hasBooks { out.append(.books) }
        out.append(.search)
        if !(hasMusic && hasBooks) { out.append(.libraries) }
        #if !os(tvOS)
        if !hasAudio { out.append(hasLiveTV ? .liveTV : .downloads) }
        #endif
        return out
    }

    /// What More lists: everything the tab bar has no room for, Settings last.
    ///
    /// Search is added by hand when the bar hasn't got it, because `sections`
    /// never lists it — and a phone with no search anywhere is a phone that
    /// can't find anything.
    var overflowSections: [AppSection] {
        #if !os(tvOS)
        if isOfflineShell { return [.settings] }
        #endif
        let shown = Set(primaryTabs.map(\.id))
        var out = sections.filter { !shown.contains($0.id) && $0 != .settings }
        if !shown.contains(AppSection.search.id), !out.contains(.search) { out.append(.search) }
        out.append(.settings)
        return out
    }

    /// Whether this device's shell is the sidebar rather than the tab bar —
    /// the idiom, not the size class, for the reason `RootView.adaptiveShell`
    /// gives.
    static var usesSidebar: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #elseif os(macOS)
        true
        #else
        false
        #endif
    }

    /// A phone's tab bar, in order.
    ///
    /// The fifth entry is *this app's* More rather than the one `TabView` builds
    /// for itself, and that is not a cosmetic choice. UIKit implements the
    /// automatic More tab as a navigation controller of its own and puts the
    /// overflow tabs inside it — so a `NavigationStack` in one of those tabs is
    /// a second navigation controller nested in the first, and pushing onto it
    /// does nothing at all. Every poster in Downloads, every title in Favorites
    /// and every row of a library that had been pushed into More was a dead tap:
    /// the button lit up, the route went onto the path, and no page ever
    /// appeared. Owning the tab means there is one stack, and pushes land in it.
    var tabSections: [AppSection] {
        var out = primaryTabs
        if !overflowSections.isEmpty { out.append(.more) }
        return out
    }

    /// Go to a section, from anywhere, whether or not it has a tab of its own.
    /// One that lives in More is opened *inside* More, because that is the only
    /// place it exists — selecting it directly would leave the tab bar pointing
    /// at a tab that isn't there, and show nothing.
    func show(_ section: AppSection) {
        #if os(tvOS)
        selection = section
        #else
        if primaryTabs.contains(section) || (Self.usesSidebar && sections.contains(section)) {
            selection = section
            return
        }
        var path = NavigationPath()
        path.append(Route.section(section))
        paths[AppSection.more.id] = path
        routeStacks[AppSection.more.id] = [.section(section)]
        selection = .more
        #endif
    }

    /// Everything the shell can land on, whether or not this platform's chrome
    /// lists it — what `lastRoute` is resolved against.
    ///
    /// On tvOS that is exactly the four sections above and nothing else: the
    /// selection is a `TabView`'s tag there, and restoring one the tab strip no
    /// longer has leaves the shell pointing at a tab that doesn't exist.
    var allSections: [AppSection] {
        #if os(tvOS)
        return sections
        #else
        var out = sections
        for extra in [AppSection.libraries, .search] where !out.contains(extra) {
            out.append(extra)
        }
        return out
        #endif
    }

    func path(for section: AppSection) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[section.id] ?? NavigationPath() },
            set: { new in
                self.paths[section.id] = new
                // A back swipe or a Back button shortens the stack without
                // going through `push`, so the parallel list follows the path's
                // length rather than trying to observe the pop itself.
                let routes = self.routeStacks[section.id] ?? []
                if new.count < routes.count {
                    self.routeStacks[section.id] = Array(routes.prefix(new.count))
                }
            }
        )
    }

    func push(_ route: Route) {
        pendingZoomSource = zoomSource
        zoomSource = nil
        #if os(tvOS)
        // Once the title screen is up it owns everything opened from it — the
        // seasons, the episodes, an actor's name searched for from the cast
        // list. Only the first title goes through the screen's own front door.
        if detailRoot != nil {
            detailPath.append(route)
            detailRoutes.append(route)
            return
        }
        // A library page opens the same way, and for the same reason the
        // comment on `detailRoot` gives. Pushed into the tab's own stack it
        // sat underneath the strip, and the focus engine kept walking up out
        // of the grid and onto the strip — from where Menu quits the
        // application instead of popping the page. So opening Films or TV
        // Shows from the Library tab and pressing Back closed Aquarium rather
        // than going back to the list of libraries.
        switch route {
        case .item, .library:
            detailPath = NavigationPath()
            detailRoutes = []
            detailRoot = route
            return
        default:
            break
        }
        #endif
        var path = paths[selection.id] ?? NavigationPath()
        path.append(route)
        paths[selection.id] = path
        routeStacks[selection.id, default: []].append(route)
    }

    /// Open a page, or go back to it where it is already behind you.
    ///
    /// What the links up from a title page need. They point at the level above
    /// — an episode's season, a season's show — and whether that page is on the
    /// stack depends entirely on how this one was reached. Coming down through
    /// the show it is, and pushing a second copy would leave Back walking the
    /// same three pages twice over; arriving from Home, or from a search, it is
    /// not there at all and the only way to it is forwards. So: pop where we
    /// can, push where we can't, and either way you end up on the page.
    func navigate(to route: Route) {
        #if os(tvOS)
        if let root = detailRoot {
            if route == root {
                if !detailRoutes.isEmpty { detailPath = NavigationPath() }
                return
            }
            if let index = detailRoutes.lastIndex(of: route) {
                let drop = detailRoutes.count - index - 1
                if drop > 0 { detailPath.removeLast(drop) }
                return
            }
        }
        #endif
        let key = selection.id
        let routes = routeStacks[key] ?? []
        if let index = routes.lastIndex(of: route) {
            let drop = routes.count - index - 1
            if drop > 0, var path = paths[key], path.count >= drop {
                path.removeLast(drop)
                paths[key] = path
                routeStacks[key] = Array(routes.prefix(index + 1))
            }
            return
        }
        push(route)
    }

    // MARK: - Links from outside

    /// Open a `aquarium://` link.
    ///
    /// The only source of them today is the Apple TV home screen: selecting a
    /// poster on the top shelf sends `item/<id>`, and pressing Play while one is
    /// focused sends `play/<id>`. The shelf is written from a snapshot that can
    /// be days old, so the id is treated as a claim rather than a fact — an
    /// episode that has since been watched, or a server that no longer has it,
    /// lands on the title page's own error rather than on nothing happening.
    ///
    /// `fromApp` is for a link the app wrote itself — a Home Screen quick
    /// action. Any other app can open a `aquarium://` URL without asking, so
    /// off the Apple TV (where nothing but the top shelf can) a `play` link
    /// from outside shows the title page and leaves pressing Play to the
    /// person: starting it would stop what is playing and move the resume
    /// point on the server, on the say-so of whoever sent the link.
    /// `fellyjin` is the scheme from before the Aquarium rename; links saved
    /// then (a top shelf snapshot, a Shortcut) still carry it.
    static let linkSchemes: Set<String> = ["aquarium", "fellyjin"]

    func handle(_ url: URL, fromApp: Bool = false) {
        guard let scheme = url.scheme, Self.linkSchemes.contains(scheme), client.isSignedIn else { return }
        // On an iPhone the same link can arrive twice — once through the
        // scene delegate and once through SwiftUI's `onOpenURL` — and a
        // Play link acted on twice opens the stream twice.
        if let last = lastLink, last.url == url, Date().timeIntervalSince(last.at) < 2 { return }
        lastLink = (url, Date())

        if url.host == "search" {
            show(.search)
            return
        }
        #if os(iOS)
        // Where a tap on a Live Activity lands: the queue for the download
        // one, Now Playing for the listening one.
        if url.host == "downloads" {
            show(.downloads)
            return
        }
        if url.host == "nowplaying" {
            NowPlayingPresentation.shared.isPresented = true
            return
        }
        #endif
        let id = url.pathComponents.first { $0 != "/" } ?? ""
        // `pathComponents` is percent-decoded, so an id is used only if it
        // is already a single clean segment; anything else is not an item.
        guard !id.isEmpty, JellyfinClient.pathId(id) == id else { return }

        switch url.host {
        case "item":
            open(itemId: id)
        case "play":
            #if os(tvOS)
            Task { await play(itemId: id) }
            #else
            if fromApp {
                Task { await play(itemId: id) }
            } else {
                open(itemId: id)
            }
            #endif
        default:
            break
        }
    }

    /// Start something by id — from a link, a Siri request, a Handoff. A
    /// show plays its first unwatched episode, the way Home's hero does; an
    /// id the server no longer has lands on the title page's own error.
    func play(itemId id: String, at seconds: Double? = nil) async {
        guard client.isSignedIn else { return }
        // These arrive as the app comes to the front, and coming to the front
        // is what resets the URL session — a request in flight at that moment
        // is cancelled, which read here as "the server has no such item".
        // Waiting on the refresh (or joining the one already running) puts
        // the request after the reset instead of under it.
        await refreshConnectivity()
        guard var item = try? await client.item(id) else { return open(itemId: id) }
        if item.isSeries {
            let episodes = (try? await client.episodes(seriesId: item.Id, seasonId: nil)) ?? []
            guard let first = episodes.first(where: { !$0.userData.played }) ?? episodes.first else {
                return open(itemId: id)
            }
            item = first
        }
        var options = StreamOptions()
        if let seconds, seconds > 1 { options.startSeconds = seconds }
        await PlayerModel.shared.play(item: item, options: options)
    }

    /// "Continue watching": the first title Home's Continue Watching row
    /// would show, else the first Next Up episode, else Home itself.
    func continueWatching() async {
        guard client.isSignedIn else { return }
        await refreshConnectivity()  // see play(itemId:)
        if let first = (try? await client.resume())?.first {
            await PlayerModel.shared.play(item: first)
        } else if let first = (try? await client.nextUp())?.first {
            await PlayerModel.shared.play(item: first)
        } else {
            show(.home)
        }
    }

    /// A Spotlight result, or a Handoff from another device. True when it
    /// was something this app knows how to continue.
    @discardableResult
    func continueActivity(_ activity: NSUserActivity) -> Bool {
        // The scene delegate and SwiftUI's own modifier can both be handed
        // the same activity; the second arrival is dropped.
        let stamp = ObjectIdentifier(activity)
        if let last = lastActivity, last.id == stamp, Date().timeIntervalSince(last.at) < 3 { return true }
        lastActivity = (stamp, Date())
        #if os(iOS) || os(macOS)
        if activity.activityType == CSSearchableItemActionType {
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
            open(itemId: id)
            return true
        }
        #endif
        #if !os(tvOS)
        if activity.activityType == PlaybackHandoff.activityType {
            guard let id = activity.userInfo?[PlaybackHandoff.itemKey] as? String else { return false }
            // From another device, so not taken on trust: a position that is
            // not a number, or is further in than anything runs, is no
            // position — and would trap on its way to becoming ticks.
            let position = (activity.userInfo?[PlaybackHandoff.positionKey] as? Double)
                .flatMap { $0.isFinite && $0 >= 0 && $0 < 30 * 86_400 ? $0 : nil }
            Task { await play(itemId: id, at: position) }
            return true
        }
        #endif
        return false
    }

    /// The title page for an id, from outside the app.
    func open(itemId id: String) {
        guard client.isSignedIn else { return }
        // Offline there is no Home to put it on and no server to fill it in
        // from — see `isOfflineShell`. Said, rather than pushed somewhere
        // out of sight to turn up when the server does.
        if isOfflineShell {
            toast("The server can't be reached — only downloads are available", tone: .error)
            return
        }
        selection = .home
        #if os(tvOS)
        // A cold launch has nothing open, but the home screen can also be
        // reached with the app still resident and a title already up — and
        // pushing onto that one would bury the thing the user just chose
        // underneath something they left half an hour ago.
        closeDetail()
        #endif
        push(.item(id))
    }

    // MARK: - Loading

    func loadLibraries() async {
        guard client.isSignedIn else { return }
        isLoadingLibraries = true
        defer { isLoadingLibraries = false }
        // With the server out of reach, the library copy still knows what the
        // libraries were — which is how the shell knows what it goes back to
        // once the server answers. (It is no longer browsed offline: see
        // `isOfflineShell`.)
        guard let views = (try? await client.views()) ?? LibraryIndex.shared.savedViews else {
            librariesUnknown = true
            return
        }
        // Music-type libraries are out of scope for this client, as on Linux.
        // `books` is what Jellyfin calls an audiobook library; the Music tab
        // shows those, and a video grid of m4b files is no use to anyone.
        let excluded = ["boxsets", "playlists", "music", "audiobooks", "books", "podcasts"]
        var video = views.filter {
            guard let type = $0.CollectionType else { return true }
            return type != "livetv" && !excluded.contains(type)
        }
        // An untyped ("mixed content") library can be an audiobook folder
        // in all but name; those are asked about, and left out if so.
        let untyped = video.filter { $0.CollectionType == nil }.map(\.Id)
        if !untyped.isEmpty {
            var audioOnly: Set<String> = []
            await withTaskGroup(of: (String, Bool).self) { group in
                for id in untyped { group.addTask { (id, await self.client.isAudioOnlyLibrary(id)) } }
                for await (id, isAudio) in group where isAudio { audioOnly.insert(id) }
            }
            video.removeAll { audioOnly.contains($0.Id) }
        }
        // Everything the tab bar is made from changes here, together, with
        // nothing awaited in between. `librariesUnknown` used to be cleared
        // above the untyped-library check — and for as long as that took, the
        // libraries were "known" and there were none: the bar was rebuilt with
        // no Music, Audiobooks or Live TV in it, Downloads slid into Music's
        // place, and then it was all put back. On a server with a mixed
        // library that was every launch, and the bar UIKit was left holding
        // showed Downloads' icon over Music's name from the next tap on.
        librariesUnknown = false
        serverHasLiveTV = views.contains { $0.CollectionType == "livetv" }
        libraries = video
        // Music-type libraries are the Music tab's, not Library's. Jellyfin
        // files audiobooks under the `books` library type.
        musicLibraries = views.filter { $0.CollectionType == "music" }
        audiobookLibraries = views.filter { $0.CollectionType == "books" || $0.CollectionType == "audiobooks" }
        UserDefaults.standard.set(!musicLibraries.isEmpty, forKey: "had_music_library")
        UserDefaults.standard.set(!audiobookLibraries.isEmpty, forKey: "had_books_library")
        rememberedLiveTV = serverHasLiveTV
        UserDefaults.standard.set(serverHasLiveTV, forKey: "had_server_live_tv")
        #if os(iOS)
        rememberedAnswers = [:]
        #endif
        // The tab bar may have just gained or lost a Music tab; a selection
        // pointing at a tab that has moved into More shows nothing.
        #if os(iOS)
        if isOfflineShell {
            reconcileSelection()
        } else if !primaryTabs.contains(selection), selection != .more {
            selection = .home
        }
        #endif
    }

    /// Called at launch and whenever the app comes back to the foreground.
    ///
    /// Coalesced, because at launch it is called twice: once by the shell's
    /// own `task`, and once by the scene phase arriving at `.active`. Run
    /// twice over, the second call's `resetConnections()` tore down the
    /// URLSession the first call's probe — and the library fetch behind it —
    /// were still using. Those requests came back as cancellations, which the
    /// client read as "the server is unreachable", and seven seconds after
    /// launching onto a perfectly good network the whole shell dropped into
    /// the offline screen. Tapping Try again then "worked" instantly, because
    /// nothing had ever been wrong. One probe at a time; a second caller waits
    /// on the first one's answer instead of starting a rival.
    func refreshConnectivity(resettingConnections: Bool = true) async {
        if let running = connectivityTask {
            await running.value
            return
        }
        let task = Task { await self.performConnectivityRefresh(resettingConnections: resettingConnections) }
        connectivityTask = task
        await task.value
        connectivityTask = nil
    }

    private func performConnectivityRefresh(resettingConnections: Bool = true) async {
        guard client.isSignedIn else { return }
        // Coming back from the background is exactly when a pooled connection
        // from before the app was suspended is most likely to be dead on the
        // other end — see the comment on `resetConnections()`. Clearing it
        // before the probe below means the probe (and the stream someone is
        // about to start) gets a fresh connection rather than rediscovering the
        // staleness the hard way.
        //
        // Not on the first pass, though: the session made moments ago at launch
        // has no stale connections to clear, and nothing to gain from being
        // replaced while the first page of the app is still loading through it.
        let isLaunchProbe = !hasProbedOnce
        if hasProbedOnce, resettingConnections { client.resetConnections() }
        hasProbedOnce = true
        defer { launchSettled = true }
        let wasOffline = client.isOffline
        // Coming back to a session that was already offline, the shell would
        // otherwise draw the offline screen in the first frame — before this
        // probe has had a chance to say otherwise. See `beginRecheck`.
        client.beginRecheck()
        var online = await client.checkOnline()
        // Then the verdict straight away rather than after the grace — see
        // `confirmOffline`. Every probe, not only the launch's: an app opened
        // offline and one that lost the server while open used to reach the
        // offline shell by different rules and at very different speeds (3 s
        // against 27). Mid-session it takes a second opinion two seconds on,
        // for a radio waking up. At launch it doesn't: the shell is waiting
        // on this answer with nothing on screen (`launchSettled`), and a
        // wrong one costs a single retry — the loop asks again after 5 s.
        if !online, !wasOffline, client.identityProblem == nil {
            if !isLaunchProbe {
                try? await Task.sleep(for: .seconds(2))
                online = await client.checkOnline()
            }
            if !online { client.confirmOffline() }
        }
        client.endRecheck()
        #if !os(tvOS)
        DownloadManager.shared.connectivityChanged(online: online)
        #endif
        if online {
            stopRetrying()
            if wasOffline { await cameBackOnline() }
        } else {
            // No toast: the offline strip on every page says it, and a toast
            // over the strip hid the countdown it was saying it with.
            startRetrying()
        }
    }

    /// What a server coming back is followed by — whichever probe found it,
    /// this one or the retry loop's.
    private func cameBackOnline() async {
        toast("Back online", tone: .ok)
        await loadLibraries()
        #if !os(tvOS)
        await OfflineProgress.sync()
        await OfflineProgress.refreshFromServer()
        // Stars given offline go back, and the offline pages' facts
        // are brought up to date, before the next time they're needed.
        await OfflineMusicIndex.shared.refresh()
        #endif
    }

    // MARK: - Offline retry
    //
    // Offline, the app keeps asking on its own: soon at first, because most
    // outages are a server restarting or a phone between networks, then
    // backing off to once a minute so an evening away from home isn't spent
    // waking the radio every few seconds to hear the same answer. The network
    // coming back (`JellyfinClient.onNetworkReturned`) and the app coming to
    // the foreground both ask straight away, whatever the schedule says.

    /// When the retry loop will next ask the server, for the offline strip's
    /// countdown. Nil when it isn't waiting.
    private(set) var nextRetryAt: Date?

    /// True while a probe from the retry loop or the strip's button is out.
    private(set) var isCheckingConnection = false

    /// The server has just been found unreachable, by whatever request found
    /// it — a probe, or an ordinary page load whose failure served out the
    /// grace (see `JellyfinClient.setOffline`). Only the first ever started
    /// the loop, so an outage noticed by a page load was never retried at all.
    func serverWentOffline() {
        guard client.isSignedIn, client.isOffline else { return }
        startRetrying()
    }

    /// Ask now rather than when the schedule says — the Retry button, the
    /// network coming back.
    func retryNow() async {
        guard client.isSignedIn else { return }
        stopRetrying()
        isCheckingConnection = true
        await refreshConnectivity()
        isCheckingConnection = false
        // A probe that failed without landing the verdict yet (the grace is
        // still running) leaves nothing retrying; `serverWentOffline` picks
        // it up when the verdict lands.
        if client.isOffline { startRetrying() }
    }

    private func startRetrying() {
        guard retryTask == nil else { return }
        let generation = UUID()
        retryGeneration = generation
        retryTask = Task { [weak self] in
            // However the loop ends, it gives up the slot — a loop that
            // returned but still sat in `retryTask` made every later
            // `startRetrying()` a no-op. Only its own slot, though: a stopped
            // loop waking up late must not clear the one that replaced it.
            defer {
                if let self, self.retryGeneration == generation {
                    self.retryTask = nil
                    self.retryGeneration = nil
                    self.nextRetryAt = nil
                }
            }
            var delay: Duration = .seconds(5)
            while !Task.isCancelled {
                self?.nextRetryAt = Date().addingTimeInterval(Double(delay.components.seconds))
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.nextRetryAt = nil
                guard self.client.isSignedIn, self.client.isOffline else { return }
                // `checkOnline()` clears the offline flag on success, so going
                // through `refreshConnectivity()` after it would find nothing
                // to recover from and skip the back-online work. Do that work
                // here instead.
                self.isCheckingConnection = true
                let online = await self.client.checkOnline()
                self.isCheckingConnection = false
                if online {
                    guard !Task.isCancelled else { return }
                    #if !os(tvOS)
                    DownloadManager.shared.connectivityChanged(online: true)
                    #endif
                    await self.cameBackOnline()
                    return
                }
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    private func stopRetrying() {
        retryTask?.cancel()
        retryTask = nil
        retryGeneration = nil
        nextRetryAt = nil
    }

    // MARK: - Toasts

    func toast(_ text: String, tone: Toast.Tone = .info) {
        let toast = Toast(text: text, tone: tone)
        toasts.append(toast)
        Task {
            try? await Task.sleep(for: .seconds(tone == .error ? 5 : 3))
            toasts.removeAll { $0.id == toast.id }
        }
    }

    func dismiss(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }

    // MARK: - Accounts

    /// The sign-in screen, up over the shell, to add an account beside the
    /// one in use. See `LoginView.addingAccount`.
    var isAddingAccount = false

    /// Set while one account is being swapped for another, so the shell can
    /// say so instead of showing the last account's Home for a beat.
    private(set) var switchingTo: SavedSession?

    /// Hand the app to another of this device's accounts.
    ///
    /// A sign-out and a sign-in with the two network calls taken out: the
    /// account being left stays signed in, and the one being entered already
    /// is. Everything else is the same teardown, for the same reason — the
    /// next person doesn't get this one's pages, queue or channels.
    func switchAccount(to account: SavedSession) async {
        guard account.accountKey != client.session?.accountKey, switchingTo == nil else { return }
        // Found out first, before anything is stopped for a switch that
        // can't happen: a token signed out from another device sharing this
        // iCloud Keychain leaves a name on the list with nothing behind it.
        guard client.switchAccount(to: account, dryRun: true) else {
            toast("\(account.userName) has been signed out — sign in again to add them back", tone: .error)
            return
        }
        switchingTo = account
        defer { switchingTo = nil }
        #if !os(tvOS)
        // Downloads belong to the device, not to an account, and so does the
        // progress made watching them offline. What this account watched goes
        // back under its own name now, while it still has one here; left for
        // the usual sync it would be filed under the next person's.
        if !client.isOffline, OfflineProgress.pendingCount > 0 { await OfflineProgress.sync() }
        #endif
        PlayerModel.shared.stop(reason: "switching account")
        stopSessionActivity()
        guard client.switchAccount(to: account) else {
            // The token went in the moment since it was checked. The account
            // in use is untouched; its libraries are asked for again, since
            // the teardown above forgot them.
            toast("\(account.userName) has been signed out — sign in again to add them back", tone: .error)
            await loadLibraries()
            return
        }
        clearSessionState()
        // The rest — connectivity, libraries, the copy — is RootView's task,
        // which is keyed on the session and has just been given a new one.
        toast("Switched to \(account.userName)", tone: .ok)
    }

    /// A sign-in that replaced an account rather than starting from nothing:
    /// the add-account sheet. The client has the new session by now; this is
    /// the teardown of what the old one left in the app.
    func accountChanged() {
        PlayerModel.shared.stop(reason: "signed in to another account")
        stopSessionActivity()
        clearSessionState()
        LibraryIndex.shared.wipe()
        #if os(tvOS)
        TopShelf.clear()
        #endif
        #if os(iOS)
        QuickActions.clear()
        #endif
        isAddingAccount = false
    }

    /// Sign one of the other accounts out of this device.
    func remove(_ account: SavedSession) async {
        await client.forget(account)
        toast("Signed \(account.userName) out of this device")
    }

    // MARK: - Sign out

    func signOut() async {
        stopSessionActivity()
        let revoked = await client.logout()
        clearSessionState()
        if !revoked {
            toast(
                "Signed out here, but the session could not be ended on the server. Revoke this device in Jellyfin → Dashboard → Devices.",
                tone: .error
            )
        }
    }

    /// The server stopped honouring the token. The client has already dropped
    /// the session (see `JellyfinClient.expireSession`); this is the rest of a
    /// sign-out, so the next account doesn't inherit this one's pages,
    /// downloads queue and channels.
    func sessionExpired() {
        stopSessionActivity()
        clearSessionState()
        #if os(iOS)
        QuickActions.clear()
        #endif
    }

    /// The half of a sign-out that has to happen while the session is still
    /// there: whatever is talking to the server on its behalf stops first.
    private func stopSessionActivity() {
        stopRetrying()
        #if !os(tvOS)
        DownloadManager.shared.endSession()
        #endif
        MusicPlayer.shared.stop()
        musicLibraries = []
        audiobookLibraries = []
        librariesUnknown = true
        serverHasLiveTV = false
        rememberedLiveTV = false
        UserDefaults.standard.removeObject(forKey: "had_music_library")
        UserDefaults.standard.removeObject(forKey: "had_books_library")
        UserDefaults.standard.removeObject(forKey: "had_server_live_tv")
        #if os(iOS)
        rememberedAnswers = [:]
        #endif
    }

    /// The other half, once the session is gone: nothing of this account is
    /// left on screen or in memory for the next one to find.
    private func clearSessionState() {
        libraries = []
        serverHasLiveTV = false
        paths.removeAll()
        routeStacks.removeAll()
        #if os(tvOS)
        closeDetail()
        #endif
        selection = .home
        LiveTVStore.shared.reset()
        Preferences.shared.clearRecentSearches()
    }
}
