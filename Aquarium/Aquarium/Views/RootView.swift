//  The shell. Sign-in when there's no session, otherwise the sections — laid
//  out as a tab bar, a sidebar or tvOS's top strip depending on where it's
//  running.

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    /// For the sidebar field's recent-terms drop-down.
    @Environment(Preferences.self) private var prefs
    #endif

    /// Shared by every poster tile and every title page, so a page can zoom
    /// out of the tile that opened it — see `ZoomedDestination`.
    @Namespace private var posterZoom

    /// iPad/Mac sidebar visibility, held explicitly rather than left to
    /// `NavigationSplitView`'s own state: the detail column wraps its own
    /// `NavigationStack`, and that inner stack's toolbar can end up owning
    /// the chrome instead of the split view's, which sometimes drops the
    /// system's automatic sidebar-toggle button once the sidebar is
    /// collapsed — stranding the sidebar with no way back short of force-
    /// quitting. Driving visibility ourselves, with our own toggle in the
    /// detail toolbar, means there is always a button that can bring it back.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    #if os(iOS)
    /// The floating sidebar toggle's circle, and where it sits from the
    /// detail column's leading edge.
    private static let sidebarToggleSize: CGFloat = 36
    private static let sidebarToggleLeading: CGFloat = 12
    /// How much further in than its gutter a page's own top bar has to start
    /// to clear that button, with a little air after it.
    private static var sidebarToggleClearance: CGFloat {
        max(0, sidebarToggleLeading + sidebarToggleSize + 8 - Metrics.gutter)
    }
    #endif

    var body: some View {
        Group {
            if client.isSignedIn {
                if app.launchSettled {
                    // A new shell for each account. Switching emptied the
                    // model (see `AppModel.clearSessionState`), but the pages
                    // hold what they loaded in their own state: Home kept the
                    // last account's hero and Next Up, scrolled where they had
                    // left it, until something happened to reload it.
                    shell
                        .id(client.session?.accountKey)
                } else {
                    // The launch's first question to the server — see
                    // `AppModel.launchSettled`. Under a second against a
                    // server that answers or refuses; the probe's own timeout
                    // (5 s) against one that never replies.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                LoginView()
            }
        }
        #if !os(tvOS)
        .environment(\.posterZoomNamespace, posterZoom)
        #endif
        // Not on a Mac: painted over the whole window it covered the sidebar's
        // material and the toolbar's, and the window has a background of its
        // own that follows the appearance.
        #if !os(macOS)
        .background(Theme.background)
        #endif
        // Keyed on the session, so a sign-in — typed here, or adopted from
        // iCloud after launch (see `Preferences.adoptCloudSession`) — gets the
        // same setup as a launch that found one already saved. Without it an
        // adopted session opened onto a shell with no libraries and no copy.
        .task(id: client.session) {
            // Live TV first, and without waiting for it. A custom playlist is
            // two downloads and an XML file that can run to tens of megabytes,
            // and doing that when the tab is tapped is what made tapping the
            // tab feel like nothing had happened. Started here it is usually
            // already in memory by the time anyone asks. It needs no session,
            // so it goes ahead of the guard.
            LiveTVStore.shared.warm()
            guard client.isSignedIn else { return }
            // Read the saved library copy first, so the libraries can be shown
            // from it if the server turns out not to answer.
            await LibraryIndex.shared.prepare()
            await app.refreshConnectivity()
            await app.loadLibraries()
            Task { await LibraryIndex.shared.sync(force: true) }
            #if !os(tvOS)
            await OfflineProgress.sync()
            await OfflineProgress.refreshFromServer()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background is the moment to find out whether
            // the network changed under us.
            if phase == .active {
                // Both of these run here, synchronously, rather than inside the
                // task below. A `Task` does not start before this handler
                // returns, and SwiftUI is free to draw a frame in between — so
                // an offline flag applied on the way back in gets a frame of
                // the offline screen to itself before anything asynchronous can
                // hold the shell steady. That frame is the flash.
                client.enterForeground()
                client.beginRecheck()
                Task {
                    await app.refreshConnectivity()
                    #if !os(tvOS)
                    // Both ways, each time the app is come back to: what was
                    // watched here goes up, and what was watched elsewhere
                    // comes down onto the downloads while there is still a
                    // server to ask — the next thing may be a flight.
                    if !client.isOffline {
                        await OfflineProgress.sync()
                        await OfflineProgress.refreshFromServer()
                    }
                    #endif
                    await LibraryIndex.shared.sync()
                }
            } else {
                client.enterBackground()
            }
        }
        // Adding an account beside the one in use: the sign-in screen, over
        // the shell rather than instead of it.
        #if os(macOS)
        .sheet(isPresented: addingAccountBinding) {
            // The Mac login content sizes itself (see `LoginView`); a fixed
            // minimum here would only pad the sheet out to iPad proportions.
            LoginView(addingAccount: true)
        }
        #else
        .fullScreenCover(isPresented: addingAccountBinding) {
            LoginView(addingAccount: true)
                .overlay(alignment: .bottom) { ToastOverlay() }
        }
        #endif
        .overlay {
            if let next = app.switchingTo {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    VStack(spacing: 14) {
                        AccountAvatar(account: next, size: 84)
                        Text("Switching to \(next.userName)…")
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                    }
                }
                .transition(.opacity)
            }
        }
        // The shell has just swapped between the whole app and the offline one
        // (see `AppModel.isOfflineShell`); the selection follows it.
        .onChange(of: client.showsOffline) { app.reconcileSelection() }
        // However the server was found to be gone — a probe, or a page whose
        // request failed — the app starts asking again on its own.
        .onChange(of: client.isOffline) { _, offline in
            if offline { app.serverWentOffline() }
        }
        .onChange(of: client.authExpired) { _, expired in
            if expired {
                // The client has dropped the token; the rest of a sign-out's
                // teardown is the app's to do.
                app.sessionExpired()
                app.toast("Your session expired — please sign in again", tone: .error)
                client.clearAuthExpired()
            }
        }
        .onChange(of: client.identityProblem) { _, problem in
            guard let problem else { return }
            app.blockingMessage = problem
        }
        .alert(
            "This isn't the server you signed in to",
            isPresented: Binding(
                get: { app.blockingMessage != nil },
                set: { if !$0 { app.blockingMessage = nil } }
            )
        ) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await app.signOut()
                    client.clearIdentityProblem()
                    app.blockingMessage = nil
                }
            }
        } message: {
            Text(app.blockingMessage ?? "")
        }
        // What an error toast becomes on a Mac — see `AppModel.toast` and
        // `presentAlert`. On the main window, whichever page is in front.
        .alert(
            app.pendingAlert?.title ?? "",
            isPresented: Binding(
                get: { app.pendingAlert != nil },
                set: { if !$0 { app.pendingAlert = nil } }
            ),
            presenting: app.pendingAlert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        // A title opens as its own screen on a television rather than as a page
        // pushed under the tab strip — see `AppModel.detailRoot`.
        #if os(tvOS)
        .fullScreenCover(isPresented: detailBinding) {
            if let root = app.detailRoot { detailScreen(root) }
        }
        #endif
        // On iOS and tvOS the player is a full-screen cover, which is also
        // what enables the system's own gesture handling and Picture in Picture
        // hand-off. On a Mac it is a window of its own, opened here when
        // something starts and closing itself when it stops — see
        // `PlayerWindow`.
        #if os(macOS)
        .onChange(of: player.isActive, initial: true) { _, active in
            if active { openWindow(id: PlayerWindow.id) }
        }
        #else
        .fullScreenCover(isPresented: playerBinding) { PlayerScreen() }
        #endif
    }

    #if os(tvOS)
    private var detailBinding: Binding<Bool> {
        Binding(
            get: { app.detailRoot != nil },
            // Also covers the system dismissing it — the Menu button on the
            // page's first level — which has to leave the stack behind it empty
            // rather than waiting to be reopened onto whatever was there.
            set: { if !$0 { app.closeDetail() } }
        )
    }

    /// The title screen and everything reached from it.
    ///
    /// It carries its own toasts and its own player, because a screen presented
    /// over the shell is not inside the shell any more: the overlay hung off a
    /// tab is behind this, and a view can only present one thing at a time, so
    /// the shell's player cover cannot open from up here. `playerBinding` below
    /// stands down while this is showing and this one takes over.
    private func detailScreen(_ root: Route) -> some View {
        @Bindable var app = app
        return NavigationStack(path: $app.detailPath) {
            destination(root)
                .navigationDestination(for: Route.self) { destination($0) }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { ToastOverlay() }
        .fullScreenCover(
            isPresented: Binding(
                get: { player.isActive },
                set: { if !$0 { player.stop(reason: "title screen's player cover dismissed") } }
            )
        ) { PlayerScreen() }
    }
    #endif

    /// A sidebar's selection is optional on iOS and not on macOS; keeping the
    /// model's non-optional and adapting here suits both.
    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { app.shownSelection },
            set: { new in
                guard let new else { return }
                #if os(macOS)
                if new != app.shownSelection { MacSidebarRows.selectionChangedAt = Date() }
                #endif
                app.selection = new
            }
        )
    }

    /// A section's stack, which only that section, while it is showing, can
    /// write to. A stack being taken down as another section takes its place
    /// sets its path to empty on the way out, and that write landed on the
    /// section being left: a title opened from Home was gone after a look at
    /// Movies — the place `AppModel.paths` exists to keep. Go ▸ Home and the
    /// like reset a path through the model, not through here.
    private func stackPath(for section: AppSection) -> Binding<NavigationPath> {
        let path = app.path(for: section)
        return Binding(
            get: { path.wrappedValue },
            set: { new in
                guard app.shownSelection == section else { return }
                path.wrappedValue = new
            }
        )
    }

    private var addingAccountBinding: Binding<Bool> {
        Binding(get: { app.isAddingAccount }, set: { app.isAddingAccount = $0 })
    }

    private var playerBinding: Binding<Bool> {
        Binding(
            get: {
                #if os(tvOS)
                // The title screen presents its own — see `detailScreen`.
                player.isActive && app.detailRoot == nil
                #else
                player.isActive
                #endif
            },
            set: { if !$0 { player.stop(reason: "player cover dismissed") } }
        )
    }

    // MARK: - Platform shells

    @ViewBuilder
    private var shell: some View {
        #if os(tvOS)
        tvShell
        #elseif os(macOS)
        sidebarShell
        #else
        adaptiveShell
        #endif
    }

    /// Toasts belong to the whole app but have to be *placed* by whatever owns
    /// the bottom of the screen.
    ///
    /// Hung off the shell as a whole they were laid out against the window, and
    /// on a phone that put them squarely on top of the tab bar — a fixed inset
    /// can't know how tall that is, and on this OS it isn't even a bar any more
    /// but a floating capsule. Inside a tab, the safe area already accounts for
    /// it, so the same 28 points of padding measures from above the tab bar on a
    /// phone, from the window edge on a Mac, and from the overscan inset on a
    /// television. It goes on the navigation stack rather than on the screen
    /// inside it so a pushed page doesn't cover it.
    private func withToasts<Content: View>(_ content: Content) -> some View {
        content.overlay(alignment: .bottom) { ToastOverlay() }
    }

    #if !os(tvOS)
    /// The offline strip, on every page of every tab and everything pushed
    /// from them, rather than on the few front pages that remembered to draw
    /// one — see `OfflineStrip`. Inside the mini player, so it sits just above
    /// it; the toasts, laid out in what is left, sit above both.
    private func withOfflineStrip<Content: View>(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if client.showsOffline { OfflineStrip() }
        }
    }
    #endif

    #if os(tvOS)
    /// The tab strip and the page under it, tied together for the focus engine.
    ///
    /// `focusRegion` on each tab's content is what makes the two ends of that
    /// journey work. tvOS moves focus by looking for something in the
    /// direction of the swipe, and a page whose first focusable control is a
    /// row of buttons half a screen down, inside a scroll view, inside a
    /// navigation stack, is nothing the strip can see: pressing down off the
    /// tab bar did nothing at all, which is how a series page could be opened
    /// and then not touched — and, because the Menu button quits the app when
    /// focus is on the tab bar rather than popping the stack you are actually
    /// looking at, how pressing Back on a season page closed Aquarium. Marked
    /// as a region, the page as a whole is the target on the way in, and on the
    /// way out a swipe up from its top row leaves the region and lands back on
    /// the strip instead of being eaten by the scroll view.
    private var tvShell: some View {
        @Bindable var app = app
        return TabView(selection: $app.selection) {
            ForEach(app.sections) { section in
                withToasts(
                    NavigationStack(path: app.path(for: section)) {
                        SectionView(section: section)
                            .navigationDestination(for: Route.self) { destination($0) }
                    }
                )
                .focusRegion()
                .tabItem { Label(section.title, systemImage: section.symbol) }
                .tag(section)
            }
        }
    }
    #endif

    #if os(macOS) || os(iOS)
    private var sidebarShell: some View {
        @Bindable var app = app
        return NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List(selection: sidebarSelection) {
                #if os(macOS)
                MacSidebarRows()
                #else
                ForEach(app.sections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
                #endif
            }
            .navigationTitle("Aquarium")
            // On an iPad as well as a Mac. Left to itself an iPad's sidebar is
            // 320 points, which held upright is two fifths of the screen spent
            // on ten short words — and the page beside it, hero, shelves and
            // grids, laid out in what was left.
            .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            withToasts(
                withOfflineStrip(
                    NavigationStack(path: stackPath(for: app.shownSelection)) {
                        SectionView(section: app.shownSelection)
                            .clearsBottomChrome()
                            .navigationDestination(for: Route.self) { destination($0).clearsBottomChrome() }
                    }
                    // A stack per section, not one stack handed each
                    // section's path in turn — see `stackPath`.
                    .id(app.shownSelection)
                    .measuresBottomChrome()
                )
                .withMiniPlayer()
            )
            #if os(iOS)
            // A floating toggle rather than a `.toolbar` item on the stack
            // above: Home draws its own header and hides the system
            // navigation bar outright (`.toolbar(.hidden, for: .navigationBar)`
            // in `HomeView`), and other sections may do the same, so a
            // toolbar-hosted button would come and go with whatever the
            // current page decides about its own chrome — which is exactly
            // how the sidebar ended up with no way back. This sits outside
            // that NavigationStack entirely, so it is there no matter what
            // page is showing or what that page does with its own toolbar.
            //
            // The pages underneath draw their own bars in that same corner —
            // the wordmark on Home, the back button on a title — so while the
            // button is there, every `AppTopBar` is told to start to the right
            // of it. See `sidebarToggleInset`.
            .overlay(alignment: .topLeading) {
                if sidebarVisibility == .detailOnly {
                    Button {
                        sidebarVisibility = .all
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.body.weight(.semibold))
                            .frame(width: Self.sidebarToggleSize, height: Self.sidebarToggleSize)
                            .background(.thinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Show sidebar")
                    .padding(.top, 8)
                    .padding(.leading, Self.sidebarToggleLeading)
                }
            }
            .environment(
                \.sidebarToggleInset,
                sidebarVisibility == .detailOnly ? Self.sidebarToggleClearance : 0
            )
            #endif
        }
        #if os(macOS)
        // Search is the field at the top of the sidebar, as in Music, rather
        // than a row in it. Typing there and pressing Return shows the Search
        // section with the term; the field's text is the app's, so the page
        // and the field agree whichever section was showing when it was
        // typed. Recent terms drop down from the field — the Mac's place for
        // them, in front of the page rather than on it.
        .searchable(text: $app.sidebarSearchTerm, placement: .sidebar, prompt: "Search")
        .searchSuggestions {
            if app.sidebarSearchTerm.isEmpty {
                ForEach(prefs.recentSearches, id: \.self) { recent in
                    Label(recent, systemImage: "clock.arrow.circlepath")
                        .searchCompletion(recent)
                }
            }
        }
        .onSubmit(of: .search) {
            let term = app.sidebarSearchTerm.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { return }
            prefs.rememberSearch(term)
            app.showSearch(term)
        }
        .modifier(FocusSearchOnRequest())
        #endif
        .nowPlayingSheet()
    }
    #endif

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad gets the sidebar, iPhone the tab bar. Same sections either way.
    ///
    /// The idiom is asked for as well as the size class, and it is not
    /// redundant: a Plus or Pro Max phone is *regular* width in landscape, so
    /// on the size class alone turning one sideways swapped the entire shell
    /// from a tab bar to a split view. That is wrong on its own terms — no
    /// iPhone shows a sidebar — but the damage was worse than cosmetic. The
    /// swap threw away and rebuilt the whole view tree mid-rotation, which
    /// took the TV guide down with it, and the guide is the thing holding the
    /// phone's permission to be in landscape at all: it let go halfway through
    /// the turn, the phone was told to go back to portrait, and the rotation
    /// ended up stuck between the two. See `OrientationLock`.
    @ViewBuilder
    private var adaptiveShell: some View {
        if sizeClass == .regular, UIDevice.current.userInterfaceIdiom != .phone {
            sidebarShell
        } else {
            tabShell
        }
    }

    private var tabShell: some View {
        TabView(selection: app.shownSelectionBinding) {
            ForEach(app.tabSections) { section in
                withToasts(
                    withOfflineStrip(
                        NavigationStack(path: app.path(for: section)) {
                            SectionView(section: section)
                                .clearsBottomChrome()
                                .navigationDestination(for: Route.self) { destination($0).clearsBottomChrome() }
                        }
                        .measuresBottomChrome()
                    )
                    .withMiniPlayer()
                )
                .tabItem { Label(section.title, systemImage: section.symbol) }
                .tag(section)
            }
        }
        // A new tab bar whenever the set of tabs changes, not the old one
        // edited. UIKit's tab bar controller keeps its tabs by position, and
        // SwiftUI moving a tab to a different position hands it a slot that
        // still holds the old occupant: going offline put Downloads first and
        // Home's slot kept Downloads' icon when the server came back, and
        // every page that had changed places — Downloads, Live TV — came up
        // blank and stayed blank. The stacks' paths live in `AppModel`, so
        // rebuilding loses nothing but scroll positions, and only when the
        // bar itself visibly changes.
        .id(app.tabSections.map(\.id).joined(separator: "|"))
        .nowPlayingSheet()
    }
    #endif

    private func destination(_ route: Route) -> some View {
        RouteDestination(route: route)
    }
}

/// The page a route opens. Shared by every navigation stack there is — each
/// tab's, the television's title screen, and on a Mac each title window's (see
/// `ItemWindow`).
struct RouteDestination: View {
    let route: Route
    @Environment(AppModel.self) private var app

    var body: some View {
        switch route {
        case .item(let id):
            ZoomedDestination(itemId: id, source: app.pendingZoomSource) {
                ItemDetailView(itemId: id)
            }
        case .library(let id, let name, let type):
            LibraryView(parentId: id, title: name, collectionType: type)
        case .search(let term):
            SearchView(initialTerm: term)
        case .downloadedSeries(let key):
            #if os(tvOS)
            EmptyView()
            #else
            DownloadedSeriesView(seriesKey: key)
            #endif
        case .person(let id, let name):
            PersonView(personId: id, name: name)
        case .section(let section):
            SectionView(section: section)
        case .music(let route):
            #if os(iOS)
            MusicDestination(route: route)
            #else
            EmptyView()
            #endif
        }
    }
}

/// Dispatches a section to the screen that draws it, and puts the offline
/// screen in front of everything that can't render without a server.
struct SectionView: View {
    let section: AppSection
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    /// Live TV only needs the server when its channels come from Jellyfin's own
    /// tuner — a custom M3U/XMLTV source bypasses it entirely (see
    /// `IPTVSource`), so gating the tab behind server reachability would block
    /// exactly the case that source exists for: a server that's unreachable, or
    /// was never going to have Live TV configured at all.
    private var needsServer: Bool {
        switch section {
        case .downloads, .settings, .more: false
        // Music draws its own offline page, with what is downloaded on it.
        case .music, .books: false
        case .liveTV: Preferences.shared.liveTVSource != .custom
        // Home, the libraries and Favorites included, saved library copy or
        // not. They were once drawn from the copy with the server gone, and
        // an app full of posters that won't play reads as an app that is
        // online — see `AppModel.isOfflineShell`. Off tvOS the shell doesn't
        // list these offline at all; this is what a route that still reaches
        // one gets, and what every tab of a television shows.
        default: true
        }
    }

    var body: some View {
        Group {
            if client.showsOffline, needsServer {
                // There is no Downloads section on tvOS, so there is nothing to
                // offer going to — the button has to be absent, not inert.
                #if os(tvOS)
                OfflineState(onRetry: { await app.retryNow() })
                #else
                OfflineState(
                    onRetry: { await app.retryNow() },
                    onDownloads: { app.show(.downloads) }
                )
                #endif
            } else {
                content
            }
        }
        // The window's own background on a Mac — see `RootView.body`.
        #if !os(macOS)
        .background(Theme.background)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .home:
            HomeView()
        case .music:
            #if os(iOS)
            MusicTabView()
            #else
            EmptyView()
            #endif
        case .books:
            #if os(iOS)
            BooksTabView()
            #else
            EmptyView()
            #endif
        case .libraries:
            LibrariesView()
        case .library(let id, let name, let type):
            LibraryView(parentId: id, title: name, collectionType: type)
        case .favorites:
            FavoritesView()
        case .liveTV:
            LiveTVView()
        case .search:
            SearchView(initialTerm: "")
        case .downloads:
            #if os(tvOS)
            EmptyView()
            #else
            DownloadsView()
            #endif
        case .settings:
            SettingsView()
        case .more:
            #if os(tvOS)
            EmptyView()
            #else
            MoreView()
            #endif
        }
    }
}

#if !os(tvOS)
/// The phone's overflow list. See `AppModel.tabSections` for why this is the
/// app's own screen rather than the one `TabView` would have made.
struct MoreView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            ForEach(app.overflowSections) { section in
                NavigationLink(value: Route.section(section)) {
                    Label(section.title, systemImage: section.symbol)
                        .foregroundStyle(Theme.text)
                }
                .listRowBackground(Theme.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("More")
    }
}
#endif

/// A title page that zooms out of the poster that opened it.
///
/// The tile names itself in `AppModel.zoomSource` as it pushes, `push` files
/// that under `pendingZoomSource`, and this reads it once as the page is
/// built — kept in state so a later push, which files a different source,
/// cannot change where this page thinks it came from. A source naming some
/// other item (a tile whose press never reached `push`) is ignored and the
/// page slides in. Only where the system offers the transition: iOS 18;
/// never the Mac or tvOS.
struct ZoomedDestination<Content: View>: View {
    @Environment(\.posterZoomNamespace) private var namespace
    @State private var source: String?
    private let content: Content

    init(itemId: String, source: String?, @ViewBuilder content: () -> Content) {
        _source = State(initialValue: source.flatMap { $0.hasSuffix("/\(itemId)") ? $0 : nil })
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        if #available(iOS 18.0, *), let source, let namespace {
            content.navigationTransition(.zoom(sourceID: source, in: namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The status line under the sidebar: whether anything is outstanding with
/// the server.
///
/// A view of its own so that it is the only thing observing the downloads: as
/// a pair of properties on `RootView` it made the whole shell — the split
/// view, its stacks, the toasts — a reader of the download list, redrawn
/// whenever a download changed state.
private struct SidebarFooter: View {
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        #if os(macOS)
        MacSidebarFooter(status: status)
        #else
        status
        #endif
    }

    @ViewBuilder
    private var status: some View {
        #if !os(tvOS)
        let running = DownloadManager.shared.records.lazy.filter { $0.status == .downloading }.count
        let pending = DownloadManager.shared.pendingSyncCount
        #else
        let running = 0
        let pending = 0
        #endif
        let line = HStack(spacing: 6) {
            Circle()
                .fill(tone(running: running, pending: pending))
                .frame(width: 7, height: 7)
            Text(text(running: running, pending: pending))
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
        #if os(macOS)
        // Under the account's name in `MacSidebarFooter`, which draws the rule.
        line
        #else
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            line
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        #endif
    }

    private func tone(running: Int, pending: Int) -> Color {
        if client.isOffline { return Theme.warn }
        if running > 0 || pending > 0 { return Theme.accent }
        return Theme.ok
    }

    private func text(running: Int, pending: Int) -> String {
        if client.isOffline { return pending > 0 ? "Offline · \(pending) to sync" : "Offline" }
        if running > 0 { return "\(running) download\(running == 1 ? "" : "s") running" }
        if pending > 0 { return "Syncing \(pending) item\(pending == 1 ? "" : "s")" }
        return "Synced"
    }
}
