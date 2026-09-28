//  Home: the application's own bar, a media bar rotating through films and
//  shows drawn at random from the library — a different set every time you
//  arrive here — and under it the rows of the user's *Jellyfin* home screen, in
//  the order they arranged them there.
//
//  That order is not this app's to invent. Jellyfin keeps it in the account's
//  display preferences and every one of its clients reads the same seven slots,
//  so a home screen rearranged in a browser is rearranged here too — which is
//  the whole point: this is meant to be the same home screen, on a television.
//  See `JellyfinClient.homeSections` and `HomeSection`. A server that can't be
//  asked falls back to Jellyfin's own default order, which is what an untouched
//  account would have got anyway.

import Combine
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player

    @Environment(\.scenePhase) private var scenePhase

    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var latest: [(library: BaseItem, items: [BaseItem])] = []
    /// The two music rows: the covers last played, and what was added.
    /// Only on a server with a music library, and only where the Music tab
    /// exists to open them into.
    @State private var musicRecent: [BaseItem] = []
    @State private var musicNew: [BaseItem] = []
    /// Which rows to draw and in what order, as the server has them. Starts on
    /// Jellyfin's defaults so the first frame is already the right shape, and is
    /// replaced by the account's own arrangement when it lands.
    @State private var sections: [HomeSection] = HomeSection.fallback
    /// What the media bar is showing. Settled when a load or a re-roll finishes
    /// rather than worked out in `body`: the bar is not allowed to change what
    /// it is showing because the page redrew.
    @State private var heroItems: [BaseItem] = []
    /// A fingerprint of the page as it was last saved and indexed. See `load`.
    @State private var lastPublished: Int?
    /// When the media bar last drew a new set. See `load`.
    @State private var heroDrawnAt = Date.distantPast
    @State private var isLoading = true
    /// A reload running underneath a page that already has something on it.
    /// Nothing but the refresh button is told; see `reload`.
    @State private var isRefreshing = false
    /// The one pass over the server this page has in flight, so that the several
    /// things which all mean "you are back on Home" produce one. See `reload`.
    @State private var inFlight: Task<Void, Never>?
    /// The Latest pass running, and which libraries it is for.
    @State private var latestInFlight: (key: [String], task: Task<Void, Never>)?
    /// Whether the app has been put down since this screen was built — what
    /// separates being opened from merely becoming active. See the scene-phase
    /// handler below.
    @State private var wasBackgrounded = false
    @State private var error: String?
    #if os(macOS)
    /// The title the media bar is showing right now, which is what the
    /// toolbar's Play Featured starts. The carousel keeps it current as it
    /// turns; see `HeroCarousel` in HomeView+Mac.swift.
    @State private var featured: BaseItem?
    #endif

    private var hero: BaseItem? { heroItems.first ?? resume.first ?? nextUp.first }
    private var isBare: Bool {
        resume.isEmpty && nextUp.isEmpty && latest.isEmpty && heroItems.isEmpty
            && !(sections.contains(.libraries) && !app.libraries.isEmpty)
    }

    /// What the media bar falls back to when the random draw comes back empty —
    /// an older server that won't sort at random, a library of things without
    /// backdrops: where you left off, what's next, and one new thing from each
    /// library.
    ///
    /// Only things the server has a backdrop for, since a portrait poster
    /// stretched across a 16:9 band is worse than not being featured at all;
    /// if that leaves nothing, the first item stands on its own as before.
    private func fallbackHeroItems() -> [BaseItem] {
        var seen = Set<String>()
        var out: [BaseItem] = []

        func take(_ items: [BaseItem], limit: Int) {
            var taken = 0
            for item in items where taken < limit {
                guard !seen.contains(item.Id) else { continue }
                guard Artwork.url(item, type: "Backdrop") != nil else { continue }
                seen.insert(item.Id)
                out.append(item)
                taken += 1
            }
        }

        take(resume, limit: 2)
        take(nextUp, limit: 2)
        for entry in latest { take(entry.items, limit: 1) }

        if out.isEmpty, let first = resume.first ?? nextUp.first { return [first] }
        return Array(out.prefix(6))
    }

    /// Whether Home is the thing you are actually looking at: its tab selected,
    /// nothing pushed on top of it, and on a television no title screen up over
    /// the shell. Coming back to this — from another tab, from a show, from the
    /// player — is what asks the server again.
    private var isFrontmost: Bool {
        guard app.selection == .home else { return false }
        #if os(tvOS)
        if app.detailRoot != nil { return false }
        #endif
        return app.homeDepth == 0
    }

    /// The whole page again, without taking the current one down first.
    ///
    /// `load` is already written to leave what is on screen alone until the new
    /// answer lands — the skeletons and the error state are drawn only when the
    /// page has nothing on it at all, each shelf keeps what it had when its own
    /// request fails, and the media bar keeps its titles. So a refresh is a load
    /// nobody is told about, except by the button, which spins until it lands.
    ///
    /// Everything that reloads this page comes through here, and a second caller
    /// joins the pass already running rather than starting another. It has to:
    /// arriving back at Home trips more than one trigger at once. Switching away
    /// from the tab takes this screen off-screen and coming back puts it on
    /// again, which re-runs the `.task` below — while the page also notices, by
    /// its own reckoning, that it is in front of you again. Both are right, and
    /// unguarded both ran, so every return to Home cost two passes over five
    /// endpoints and put two sets of answers into the same shelves.
    ///
    /// The task is unstructured on purpose. The `.task` that starts a refresh is
    /// cancelled the moment the tab goes away, and a reload that abandons itself
    /// half-done leaves the page holding some of the old answer and some of the
    /// new; this one finishes what it started.
    private func reload(fresh: Bool = false) async {
        guard client.isSignedIn else { return }
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await load(fresh: fresh) }
        inFlight = task
        isRefreshing = true
        await task.value
        inFlight = nil
        isRefreshing = false
    }

    /// Built again from where it was left. Switching sections throws this
    /// view away, and with it everything it had loaded, so each return to Home
    /// drew skeletons and let the shelves arrive one at a time — or, with the
    /// library copy off or just wiped, came up as My Media and On Now alone
    /// until the rest landed. The last page shown for this account is kept in
    /// memory (see `HomeMemo`) and is the first frame; `load` then brings it up
    /// to date underneath, as it does for the copy.
    init() {
        guard let memo = HomeMemo.current else { return }
        _resume = State(initialValue: memo.resume)
        _nextUp = State(initialValue: memo.nextUp)
        _latest = State(initialValue: memo.latest)
        _musicRecent = State(initialValue: memo.musicRecent)
        _musicNew = State(initialValue: memo.musicNew)
        _sections = State(initialValue: memo.sections)
        _heroItems = State(initialValue: memo.heroItems)
        _heroDrawnAt = State(initialValue: memo.heroDrawnAt)
    }

    private func rememberPage() {
        HomeMemo.save(HomeMemo(
            account: client.session?.accountKey,
            resume: resume, nextUp: nextUp, latest: latest,
            musicRecent: musicRecent, musicNew: musicNew,
            sections: sections, heroItems: heroItems, heroDrawnAt: heroDrawnAt
        ))
    }

    var body: some View {
        #if os(iOS)
        // No navigation bar: this screen's own bar is the one at the top of the
        // scroll view, and it carries the application's name rather than the
        // page's — "Home" above a hard-edged backdrop is the seam that made the
        // top of this page look bolted on.
        scroll()
            .toolbar(.hidden, for: .navigationBar)
        #elseif os(tvOS)
        // The media bar is meant to be the top of the screen, not a picture
        // sitting in the middle of one: edge to edge across, and up behind the
        // tab strip rather than starting below it.
        //
        // That can't be done from inside the scroll view. A television's window
        // carries a title-safe inset — ninety points down each side, sixty top
        // and bottom, plus however tall the strip is — and a scroll view honours
        // it by insetting its content, then clips anything that tries to
        // overflow back out again. So the scroll view is the thing that has to
        // ignore the safe area, and everything on the page that *isn't* the
        // media bar gets the inset put back by hand.
        //
        // Reading the insets from a `GeometryReader` that is itself ignoring
        // them is how the number gets here: the proxy reports the safe area of
        // the region it was given, which is the one being ignored, so it is the
        // exact amount the page has to make up.
        GeometryReader { proxy in
            scroll(bleed: proxy.safeAreaInsets)
        }
        .ignoresSafeArea()
        #else
        // The media bar runs up under the window's toolbar, the way the TV
        // app's does: the toolbar keeps its title and its buttons but loses
        // its own surface, and the top of the hero fades in from the window
        // colour beneath them (see `HeroHeader.toolbarBlend`) so the controls
        // stay legible in either appearance and there is no hard edge where
        // the chrome used to stop and the picture used to start.
        scroll()
            .screenTitle("Home")
            .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await reload(fresh: true) }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            // No key equivalent of its own: View ▸ Refresh owns ⌘R, and this
            // page answers it through `MacCommandRequests.refresh` below.
            .disabled(isRefreshing)
            .help("Refresh (⌘R)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                guard let featured else { return }
                Task { await HeroHeader.start(featured, app: app, player: player, client: client) }
            } label: {
                Label("Play Featured", systemImage: "play.fill")
            }
            .disabled(featured == nil)
            .help(featured.map { "Play \(HeroHeader.displayTitle(of: $0))" } ?? "Play Featured")
        }
    }
    #endif

    #if os(tvOS)
    private var refreshControl: some View {
        RefreshButton(
            isRefreshing: isRefreshing,
            overArtwork: !heroItems.isEmpty
        ) {
            Task { await reload(fresh: true) }
        }
    }

    /// The refresh button in the media bar's top corner: over the artwork,
    /// inside the title-safe area, clear of the tab strip the bar reaches up
    /// behind.
    ///
    /// Full width and its own focus section, which is what makes it reachable.
    /// The button alone sits in the top right with the bar's own buttons in the
    /// bottom left, sharing neither a row nor a column, and the focus engine
    /// moves by overlap — pressing up from Play would step straight past it to
    /// the tab strip and nothing else on the page points at it at all. A section
    /// spanning the width is a target the whole bar can move up into, so the
    /// order from the bar is Play, up to Refresh, up to the tabs.
    ///
    /// The insets are the larger of what the page was told and what the strip
    /// actually needs, because `bleed` cannot be trusted for this. It comes from
    /// a geometry proxy that is itself inside an `ignoresSafeArea` — the trick
    /// `AppTopBar` already documents as reporting zero as often as not — and on
    /// this simulator it reports zero on every edge, which put the button off
    /// the top of the screen and through the tab strip. Everything else on the
    /// page survived that: the shelves have `Metrics.gutter` of their own, and a
    /// hero told to bleed by zero is simply a hero that doesn't.
    private func refreshOverHero(_ bleed: EdgeInsets) -> some View {
        HStack {
            Spacer()
            refreshControl
        }
        .padding(.top, max(bleed.top, Self.tabStripClearance))
        .padding(.horizontal, max(bleed.leading, Metrics.gutter))
        .focusSection()
    }

    /// How far down the media bar the tab strip reaches, plus a gap. Measured
    /// rather than published: tvOS gives no way to ask a `TabView` how tall its
    /// strip is, and the strip is drawn over this page rather than above it.
    ///
    /// The gap has to hold a *focused* button, not a resting one. At 124 the
    /// capsule cleared the strip by about a dozen points, and the focus
    /// treatment grows it by 8% — so the one moment the button matters was the
    /// one moment it looked wedged under the navigation above it.
    private static let tabStripClearance: CGFloat = 150
    #endif

    @ViewBuilder
    private func scroll(bleed: EdgeInsets = EdgeInsets()) -> some View {
        ScrollView {
            if isLoading, isBare {
                // The page this is about to become, rather than a spinner in the
                // middle of an empty screen: the hero and the first two shelves
                // are in their own places from the first frame, so nothing jumps
                // when the answer lands.
                VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    SkeletonHero()
                    SkeletonShelf(wide: true)
                    SkeletonShelf()
                }
                .padding(.bottom, 24)
                .insetForBleed(bleed)
            } else if let error, isBare {
                ErrorState(error: error) { Task { await load() } }
                    .insetForBleed(bleed)
            } else if isBare {
                EmptyState(
                    symbol: "film.stack",
                    title: "Nothing here yet",
                    message: "Once your Jellyfin libraries have been scanned, what's new and what you've started will show up here."
                )
                .insetForBleed(bleed)
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    #if os(iOS)
                    if !heroItems.isEmpty {
                        HeroCarousel(items: heroItems)
                    }
                    #elseif os(tvOS)
                    if heroItems.isEmpty {
                        // Nothing to hover over. Rare — the bar falls back to
                        // the shelves' own titles — but the page still needs
                        // the button, so it gets a line of its own.
                        refreshControl
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, bleed.top)
                            .padding(.horizontal, bleed.leading)
                    } else {
                        HeroCarousel(items: heroItems, topBleed: bleed.top)
                            .overlay(alignment: .top) { refreshOverHero(bleed) }
                    }
                    #else
                    if !heroItems.isEmpty {
                        HeroCarousel(items: heroItems, featured: $featured)
                    } else if let hero {
                        HeroHeader(item: hero)
                            .onAppear { featured = hero }
                            .onChange(of: hero.Id) { _, _ in featured = hero }
                    }
                    #endif
                    // Eager rather than lazy on a television, and inset back
                    // inside the title-safe area the scroll view is no longer
                    // applying for itself.
                    //
                    // The eagerness is not cosmetic: the selector can only move
                    // to a view that exists, and a shelf a lazy stack hasn't
                    // built yet is not one — which on a page whose first screen
                    // is nothing but the media bar means pressing down does
                    // nothing at all, and nothing scrolls, so the shelf is never
                    // built. See `ItemDetailView`, where the same thing was
                    // happening.
                    #if os(tvOS)
                    VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                        shelves
                    }
                    .padding(.horizontal, bleed.leading)
                    #else
                    shelves
                    #endif
                }
                // The hero starts at the bar; without one the first shelf's
                // heading would sit against it.
                #if os(tvOS)
                .padding(.top, heroItems.isEmpty ? bleed.top + 12 : 0)
                #elseif os(iOS)
                .padding(.top, heroItems.isEmpty ? 12 : 0)
                #else
                .padding(.top, hero == nil ? 12 : 0)
                #endif
                .padding(.bottom, 24 + bleed.bottom)
            }
        }
        .reloadWhenPlaybackEnds { await reload() }
        #if os(macOS)
        .toolbar { macToolbar }
        // View ▸ Refresh (⌘R), the sidebar row's Refresh, and the app coming
        // back to the front after a while away all arrive here as one
        // counter — see `MacCommandRequests.refresh`. Only while Home is the
        // page in front: a title pushed over it answers its own ⌘R.
        .onChange(of: MacCommandRequests.shared.refresh) { _, _ in
            guard isFrontmost else { return }
            Task { await reload(fresh: true) }
        }
        #endif
        // A press-and-hold menu anywhere can change what these shelves say —
        // Continue Watching and Next Up are both derived from watched state.
        //
        // Only while Home is in front. On a television a title opens over the
        // shell without taking this page off screen, so the modifier alone
        // can't tell it is hidden; and coming back to the front reloads it
        // anyway (see `isFrontmost` below), so a change made while it was
        // covered is picked up then, once, instead of twice.
        .reloadWhenItemsChange { if isFrontmost { await reload() } }
        .task { await reload() }
        .task(id: app.libraries.map(\.Id)) { await loadLatest() }
        .onDisappear { rememberPage() }
        // Coming back to Home is what asks the server again. Without it, what
        // you finished half an hour ago is still sitting in Continue Watching.
        //
        // One condition covers every way back — another tab, a show you were
        // reading about, a television's title screen closing — because they are
        // the same event as far as this page is concerned: it is in front of you
        // again, and what it says may be out of date. See `isFrontmost`.
        //
        // It overlaps with the `.task` above, which re-runs whenever a tab goes
        // off screen and comes back, and it has to: that is a phone's way back,
        // not a television's, where a title opens over the shell and closing it
        // never takes the tab away at all. `reload` is what makes the overlap
        // harmless.
        .onChange(of: isFrontmost) { wasFrontmost, nowFrontmost in
            guard !wasFrontmost, nowFrontmost else { return }
            Task { await reload() }
        }
        // Opening the app again, which is the same question asked from further
        // away.
        //
        // Gated on the app having actually been away, because becoming active is
        // not the same event as being opened: a launch passes through `.active`
        // too, and so does dismissing Control Center or an alert. Only a trip
        // through `.background` says the app was put down and picked back up,
        // which is the one worth five requests.
        //
        // A page left showing a failure it collected on the way out is the first
        // thing you see on the way back in, and that failure is almost never
        // true — the requests in flight when the app was put away failed because
        // the system took the network away from them. Asking again settles it.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasBackgrounded = true; return }
            guard phase == .active, wasBackgrounded, isFrontmost else { return }
            wasBackgrounded = false
            Task { await reload() }
        }
        #if os(iOS)
        // The bar is part of the screen rather than something drawn over it:
        // everything that scrolls arrives underneath it and is gone, and the
        // page starts where the bar ends.
        .safeAreaInset(edge: .top, spacing: 0) {
            AppTopBar {
                HStack(spacing: 0) {
                    BrandMark()
                    Spacer(minLength: 12)
                    RefreshButton(isRefreshing: isRefreshing) {
                        Task { await reload(fresh: true) }
                    }
                }
            }
        }
        #endif
    }

    /// What's below the media bar: the user's own Jellyfin home rows, in the
    /// order the server keeps them. See `sections`.
    @ViewBuilder
    private var shelves: some View {
        // A phone puts refresh in its top bar and a television over the corner
        // of the media bar. A Mac puts it in the window's toolbar, answering
        // View ▸ Refresh — see `macToolbar` — rather than a row of its own
        // here, which left a band of empty page between the media bar and the
        // first shelf.
        ForEach(sections, id: \.self) { section in
            shelf(section)
        }
        // The music rows are the phone's for now: `AlbumShelf` and everything
        // it opens into live inside the Music tab's `#if os(iOS)`, and
        // `AppModel.hasMusic` is false on the Mac until that tab is built for
        // it. Nothing to enable here until then.
        #if os(iOS)
        if app.hasMusic {
            AlbumShelf(title: "Recently Played", items: musicRecent) { album in
                app.show(.music)
                app.push(.music(.album(album.Id)))
            } seeAll: {
                app.show(.music)
                app.push(.music(.songList(title: "Recently Played", kind: .recentlyPlayed)))
            }
            AlbumShelf(title: "New Music", items: musicNew) { album in
                app.show(.music)
                app.push(.music(.album(album.Id)))
            } seeAll: {
                app.show(.music)
                app.push(.music(.recentlyAdded))
            }
        }
        #endif
    }

    @ViewBuilder
    private func shelf(_ section: HomeSection) -> some View {
        switch section {
        case .libraries:
            LibraryTilesRow(libraries: app.libraries) { library in
                app.push(.library(
                    id: library.Id,
                    name: library.title,
                    collectionType: library.CollectionType
                ))
            }
        case .resume:
            MediaShelf(title: "Continue Watching", items: resume, wide: true) { open($0) }
        case .nextUp:
            // Portrait, and a picture of the *season* rather than of the
            // episode. Continue Watching is a row of stills because it points
            // at a moment you were in the middle of; Next Up points at the next
            // thing in a show, and a frame from an episode nobody has seen yet
            // is a picture of nothing in particular. See `Artwork.seasonArt`.
            MediaShelf(
                title: "Next Up",
                items: nextUp,
                art: .season,
                menuOpensDetails: true
            ) { openNextUp($0) }
        case .latest:
            // One row per library, which is how Jellyfin draws this slot too —
            // it is a single setting that expands into as many rows as the
            // account can see.
            ForEach(latest, id: \.library.Id) { entry in
                MediaShelf(
                    title: "Latest in \(entry.library.title)",
                    items: entry.items
                ) {
                    open($0)
                } seeAll: {
                    app.push(.library(
                        id: entry.library.Id,
                        name: entry.library.title,
                        collectionType: entry.library.CollectionType
                    ))
                }
            }
        case .liveTV:
            // Drawn from the channel list the app already warms at launch
            // rather than from a request of its own, so a home screen with this
            // row costs nothing extra to open. Empty until that lands, and
            // `MediaShelf` draws nothing for an empty row.
            MediaShelf(
                title: "On Now",
                items: onNow,
                wide: true,
                subtitleFor: { $0.CurrentProgram?.Name }
            ) { channel in
                play(channel)
            } seeAll: {
                app.show(.liveTV)
            }
        }
    }

    /// The channels with something on them, for the Live TV row. Capped: this
    /// is a shelf on the home screen, not the guide.
    private var onNow: [BaseItem] {
        guard sections.contains(.liveTV) else { return [] }
        return Array(LiveTVStore.shared.channels.prefix(20))
    }

    /// Same two roads as the guide's own play button — a playlist channel goes
    /// straight to AVPlayer, a Jellyfin one tunes through PlaybackInfo. See
    /// `TVGuideView.play`.
    private func play(_ channel: BaseItem) {
        if let raw = channel.ExternalStreamURL, let url = URL(string: raw) {
            player.playExternal(
                title: channel.title,
                subtitle: "",
                artworkURL: Artwork.channelLogo(channel, width: 600),
                streamURL: url,
                channel: channel
            )
        } else {
            Task { await player.play(item: channel, options: StreamOptions(resume: false, live: true)) }
        }
    }

    private func open(_ item: BaseItem) {
        app.push(.item(item.Id))
    }

    /// Next Up names an episode, but an episode page on its own hides where it
    /// sits — which season, what came before it, what follows. So this opens the
    /// show and its season instead, with the episode picked out in the list:
    /// one press still plays it, and everything around it is there.
    ///
    /// The television did this first and the phone didn't, which made the same
    /// row on the same screen lead somewhere else depending on what you were
    /// holding. It is the same journey now; only the emphasis differs, because
    /// a remote has a selector to place and a finger does not — see
    /// `ItemDetailView`.
    private func openNextUp(_ item: BaseItem) {
        if item.isEpisode, let seriesId = item.SeriesId, let seasonId = item.SeasonId {
            app.openNextUp(seriesId: seriesId, seasonId: seasonId, episodeId: item.Id)
            return
        }
        open(item)
    }

    /// `fresh` is the Refresh button: everything is asked for again, the
    /// layout included (see `JellyfinClient.homeSections`).
    private func load(fresh: Bool = false) async {
        error = nil
        isLoading = true
        defer { isLoading = false }

        // With the library copy on, Home opens on what it showed last time —
        // brought up to date with what has been watched since — and the
        // server's answers replace it row by row as they arrive. With the
        // server out of reach, that is the page.
        let index = LibraryIndex.shared
        // At launch this page starts loading alongside the shell, which is
        // still reading the copy off disk; waiting for that is what makes the
        // first frame of Home the saved one rather than an empty one. Returns
        // at once when the copy is off or already read.
        await index.prepare()
        var drewFromCopy = false
        if isBare, let saved = index.homeCopy() {
            let savedSections = saved.sections.compactMap(HomeSection.init(rawValue:))
            if !savedSections.isEmpty { sections = savedSections }
            resume = saved.resume
            nextUp = saved.nextUp
            latest = saved.latest.map { (library: $0.library, items: $0.items) }
            heroItems = client.isOffline
                // Backdrops are saved as they are seen, so offline the bar
                // shows the titles it showed before, whose pictures are here.
                ? saved.hero
                : (index.spotlight(limit: 6) ?? saved.hero)
            drewFromCopy = true
        }

        async let resumeTask = client.resume()
        async let nextUpTask = client.nextUp()
        // The media bar's random draw comes from the copy when there is one:
        // it is the same draw, without a request.
        //
        // Not redrawn when the set on screen is under a minute old: every
        // return to Home reloads it, and a fresh draw is a request for twelve
        // titles and then six backdrops and six wordmarks to go with them —
        // for someone who went to a detail page and came straight back. The
        // Refresh button draws again regardless.
        let redrawHero = fresh || heroItems.isEmpty || Date().timeIntervalSince(heroDrawnAt) >= 60
        let localPicks = redrawHero ? index.spotlight(limit: 6) : nil
        async let spotlightTask: [BaseItem] = {
            guard redrawHero else { return [] }
            if let localPicks { return localPicks }
            return try await client.spotlight()
        }()
        // The layout, asked for at the same time as the things that fill it.
        // It answers for itself — `homeSections` never throws, it falls back —
        // so it is not part of the failure bookkeeping below.
        async let sectionsTask = client.homeSections(fresh: fresh)

        // Each shelf answers for itself. One of these failing is one shelf
        // missing, not a page that didn't load — and the whole page reading as
        // broken because a single request lost a race is exactly what this
        // screen was doing. The error state is kept for the case it was meant
        // for: nothing came back at all.
        var failure: (any Error)?
        sections = await sectionsTask
        do { resume = try await resumeTask } catch { failure = error }
        do { nextUp = try await nextUpTask } catch { failure = failure ?? error }

        #if os(iOS)
        // The home screen icon's press-and-hold menu leads with the same
        // title this page does.
        if failure == nil { QuickActions.update(resume: resume, nextUp: nextUp) }
        #elseif os(macOS)
        // The Dock icon's menu is the same list: what was left part-watched,
        // then what is next.
        if failure == nil { app.updateDockMenu(resume: resume, nextUp: nextUp) }
        #endif

        // The Apple TV home screen shows the same list, and this is the only
        // moment the app has it. Detached because it fetches a poster per
        // title: the rest of Home must not wait on artwork for a shelf that is
        // somewhere else entirely.
        #if os(tvOS)
        let published = nextUp
        Task.detached { await TopShelf.publish(published) }
        #endif

        // The bar is settled here rather than at the end: it has everything
        // it needs, and waiting for a Latest row per library would leave the
        // top of the page a grey box for as long as that takes.
        // The Live TV row draws from the shared channel store, which only warms
        // itself at launch for a custom playlist — a server tuner is normally
        // asked for when the tab is opened. A home screen carrying this row is
        // that moment instead.
        if sections.contains(.liveTV), app.hasLiveTV {
            Task { await LiveTVStore.shared.ensureLoaded() }
        }

        let picks = (try? await spotlightTask) ?? []
        // Already drawn from the copy on this load: a second draw a moment
        // later would swap the titles out from under whoever is reading them.
        if !picks.isEmpty, !drewFromCopy {
            heroItems = picks
            heroDrawnAt = Date()
        }

        // The fallback is for a bar that has nothing in it, not for a draw that
        // came back empty. Now that every return to this page reloads it, those
        // two had to be told apart: a refresh whose spotlight request lost the
        // network was swapping the titles across the top of Home for the
        // Continue Watching entry directly below them, every time you came back
        // to the tab. A bar showing what it was already showing is better than
        // one that emptied itself because the network blinked.
        await loadLatest()
        if picks.isEmpty, heroItems.isEmpty { heroItems = fallbackHeroItems() }
        await loadMusic()

        if let failure, isBare { error = failure.localizedDescription }
        // Saving the page and telling Spotlight about it are skipped when the
        // page is what it was last time: every return to Home reloads it, and
        // most returns change nothing — each one was an encode and a disk
        // write, and a batch handed to the system's search index, for the same
        // hundred titles.
        var hasher = Hasher()
        hasher.combine(sections.map(\.rawValue))
        hasher.combine(resume)
        hasher.combine(nextUp)
        for row in latest {
            hasher.combine(row.library.Id)
            hasher.combine(row.items)
        }
        hasher.combine(heroItems)
        let shown = hasher.finalize()
        guard shown != lastPublished else { return }
        if failure == nil {
            index.keepHome(sections: sections, resume: resume, nextUp: nextUp, latest: latest, hero: heroItems)
            lastPublished = shown
        }
        #if os(iOS) || os(macOS)
        // With no library copy this is all the system's search ever learns
        // about; with one it is a harmless refresh of a few dozen titles.
        SpotlightIndexer.shared.update(changed: resume + nextUp + heroItems + latest.flatMap(\.items))
        #endif
    }

    /// The music rows. Best effort, like a Latest row: a failure leaves what
    /// was there.
    private func loadMusic() async {
        guard app.hasMusic else {
            musicRecent = []
            musicNew = []
            return
        }
        async let recent = client.recentlyPlayedSongs(limit: 30)
        async let added = client.music(.init(types: "MusicAlbum", sort: .recentlyAdded, limit: 16))
        if let songs = try? await recent { musicRecent = songs.albumsInOrder() }
        if let albums = try? await added.items { musicNew = albums }
    }

    /// What's new in each library.
    ///
    /// Its own step, and driven by the shell's library list rather than folded
    /// into `load`, because the two do not arrive together: the shell is still
    /// fetching the libraries when this screen first loads, so at that moment
    /// there is nothing to ask about and every Latest shelf came out empty. On
    /// a phone the page is never rebuilt afterwards — it sits in its tab with
    /// its state intact — so those shelves stayed missing for the rest of the
    /// session, with Continue Watching and Next Up there beside them to make it
    /// look deliberate. Keyed on the libraries, it fills in the moment they land.
    ///
    /// Two things ask for it at launch — the page's own load and the library
    /// list arriving — and usually at the same moment, so a second caller for
    /// the same set of libraries joins the pass already running rather than
    /// asking every library twice. And the libraries are asked side by side,
    /// not one after another: the page waited on the sum of them.
    private func loadLatest() async {
        // Nothing to ask for if the account's home screen doesn't have this row
        // on it: this is one request per library, and they were all being made
        // for a set of shelves that would never be drawn.
        guard sections.contains(.latest) else {
            latest = []
            return
        }
        let libraries = app.libraries
        let key = libraries.map(\.Id)
        if let running = latestInFlight, running.key == key {
            await running.task.value
            return
        }
        let task = Task { await fetchLatest(libraries) }
        latestInFlight = (key, task)
        await task.value
        if latestInFlight?.key == key { latestInFlight = nil }
    }

    private func fetchLatest(_ libraries: [BaseItem]) async {
        let found = await withTaskGroup(of: (Int, [BaseItem]).self) { group in
            for (position, library) in libraries.enumerated() {
                group.addTask { (position, (try? await client.latest(parentId: library.Id)) ?? []) }
            }
            var byPosition: [Int: [BaseItem]] = [:]
            for await (position, items) in group { byPosition[position] = items }
            return byPosition
        }
        // In the order the libraries are in, whichever answered first.
        let rows = libraries.enumerated().compactMap { position, library -> (library: BaseItem, items: [BaseItem])? in
            guard let items = found[position], !items.isEmpty else { return nil }
            return (library: library, items: items)
        }
        // Nothing replaces something: a blink on the network shouldn't empty
        // shelves that are already on screen.
        if !rows.isEmpty || latest.isEmpty { latest = rows }
    }
}

/// Home as it was last left, for the next `HomeView` to open on — see
/// `HomeView.init`. In memory only and for one account: another account's
/// page is never the first frame of this one's.
struct HomeMemo {
    var account: String?
    var resume: [BaseItem]
    var nextUp: [BaseItem]
    var latest: [(library: BaseItem, items: [BaseItem])]
    var musicRecent: [BaseItem]
    var musicNew: [BaseItem]
    var sections: [HomeSection]
    var heroItems: [BaseItem]
    var heroDrawnAt: Date

    @MainActor private static var saved: HomeMemo?

    @MainActor static var current: HomeMemo? {
        guard let saved, saved.account != nil, saved.account == JellyfinClient.shared.session?.accountKey else { return nil }
        return saved
    }

    @MainActor static func save(_ memo: HomeMemo) {
        saved = memo
    }
}

private extension View {
    /// Puts back the safe area a full-bleed scroll view is no longer applying,
    /// for the states that have no media bar to bleed. Nothing anywhere but a
    /// television, where the insets are non-zero to begin with.
    func insetForBleed(_ bleed: EdgeInsets) -> some View {
        padding(.top, bleed.top)
            .padding(.horizontal, bleed.leading)
    }
}

/// The wide artwork at the top of Home and of a detail page: backdrop, the
/// title's own wordmark where the server has one, and — on Home — where you got
/// to and the buttons that carry on.
struct HeroHeader: View {
    /// What the artwork is being asked to do, which is not the same thing on the
    /// two screens that draw it.
    enum Style {
        /// Home. The artwork is the page's one way in, so it carries the title,
        /// how far through you are, and the buttons that start it.
        case home
        /// A series, season or episode page. Everything those buttons would do
        /// is spelled out in the block directly below — Resume, the quality
        /// rungs, favourite, download — and the page you would be sent to by a
        /// "Details" button is the one you are already on. So here the artwork
        /// is artwork, with the title over it and nothing else.
        case detail
    }

    let item: BaseItem
    var style: Style = .home
    /// Told to the media bar above, which stops rotating while the selector is
    /// inside the artwork. tvOS only; nothing else has a focus engine.
    var onFocusChange: ((Bool) -> Void)?
    /// Extra height on top of `height`, for a hero that starts at the top of
    /// the screen rather than below the chrome — the amount of safe area it is
    /// reaching up through. See `HomeView.scroll`.
    var topBleed: CGFloat = 0
    /// How tall to draw this one. The platform's fixed `height` unless the
    /// caller knows better — the Mac carousel derives it from the window's
    /// width, so a wide window gets a taller picture rather than a strip.
    var heroHeight: CGFloat = Self.height
    /// The width the hero has been given, where the caller has measured it;
    /// zero means "unknown", and the fixed sizes below stand in. On the Mac
    /// the wordmark, the text column and the pixels asked of the server all
    /// follow it.
    var availableWidth: CGFloat = 0

    @Environment(AppModel.self) private var app
    @Environment(PlayerModel.self) private var player
    @Environment(JellyfinClient.self) private var client

    /// Held while a series is being resolved into an episode, so the button
    /// can't be pressed three more times during the round trip.
    @State private var isStarting = false

    /// Set once the title art has been asked for and hasn't got one, which is
    /// what sends the title back to typeset text.
    @State private var logoUnavailable = false

    #if os(tvOS)
    private enum Focus: Hashable { case play, details }
    @FocusState private var focus: Focus?
    #endif

    #if os(macOS)
    @Environment(\.displayScale) private var displayScale
    /// The pointer resting on the picture, which is a button on the Mac.
    @State private var isHoveringBackdrop = false
    #endif

    /// How tall the hero is on this platform. Shared so the skeleton that
    /// stands in for it, and the carousel that pages through several, agree
    /// with the real thing rather than each carrying their own copy of the
    /// number. The status bar is no longer part of it: a solid bar sits above
    /// the artwork now, on Home and on a detail page both.
    ///
    /// A television screen is 1920×1080 points, and the 460 this used to be
    /// there made the hero a 4:1 letterbox — a 16:9 backdrop cropped to a strip,
    /// which is what "thin, and it cuts the picture up" was. Two-thirds of the
    /// screen is the proportion every television app gives its top slot, and at
    /// 2.7:1 it takes the top and bottom off a backdrop rather than the whole
    /// middle of it.
    static var height: CGFloat {
        #if os(tvOS)
        return 720
        #elseif os(macOS)
        return 340
        #else
        return 300
        #endif
    }

    /// The picture is taller by whatever it is bleeding through; the text block
    /// is pinned to the bottom, so it stays exactly where it was.
    private var artHeight: CGFloat { heroHeight + topBleed }

    /// The name the hero leads with: the show's for an episode or a season,
    /// the title's own for anything else. Shared with the toolbar's Play
    /// Featured, whose tooltip names the same thing.
    static func displayTitle(of item: BaseItem) -> String {
        item.isEpisode || item.isSeason ? (item.SeriesName ?? item.title) : item.title
    }

    /// What the text sits on, and the reason it can be read.
    ///
    /// This is black rather than the page colour, in both themes, and that is
    /// the whole point: the page colour is nearly white in the light theme, so a
    /// ramp made of it put white titles and white buttons over a white haze and
    /// left them to fight whatever the backdrop was doing underneath. Black is
    /// the only thing white type is legible on, and a backdrop that has been
    /// darkened towards the bottom is what every television app does with one.
    ///
    /// The stops approximate an ease rather than a straight ramp: nothing much
    /// happens through the top half, and the last of the picture goes at close
    /// to the rate it was already going, so there is no line where the fade
    /// starts or stops.
    private var legibilityScrim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .black.opacity(0.10), location: 0.30),
                .init(color: .black.opacity(0.24), location: 0.45),
                .init(color: .black.opacity(0.42), location: 0.58),
                .init(color: .black.opacity(0.60), location: 0.70),
                .init(color: .black.opacity(0.76), location: 0.82),
                .init(color: .black.opacity(0.82), location: 1.00),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// A second, gentler darkening from the leading edge. The title starts at
    /// the gutter, and a backdrop with its bright half on the left — a sky, a
    /// window, a wall of snow — is what the vertical ramp alone can't answer.
    private var edgeScrim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.45), location: 0.00),
                .init(color: .black.opacity(0.18), location: 0.35),
                .init(color: .clear, location: 0.70),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// The join to the page: the artwork arriving at the shelves below without
    /// an edge, starting from nothing so there is no line where it begins.
    ///
    /// Longer on a television, and that is not the same gradient scaled up.
    /// The last seventh of a 300-point hero is forty points, which at reading
    /// distance is a soft join; the same seventh of a 720-point one is a
    /// hundred points seen from across a room, and a hundred points on a
    /// 1080-point screen reads as the picture simply stopping. The ramp there
    /// runs through the bottom third instead, weighted so that almost nothing
    /// happens for the first half of it — the artwork stays artwork under the
    /// title and the buttons, and only the part below them dissolves.
    ///
    /// Either way it starts below where the text stops, so nothing readable
    /// ever has to sit on the light theme's near-white.
    private var pageBlend: LinearGradient {
        #if os(tvOS)
        let stops: [Gradient.Stop] = [
            .init(color: .clear, location: 0.70),
            .init(color: Theme.background.opacity(0.06), location: 0.82),
            .init(color: Theme.background.opacity(0.20), location: 0.89),
            .init(color: Theme.background.opacity(0.45), location: 0.945),
            .init(color: Theme.background.opacity(0.75), location: 0.98),
            .init(color: Theme.background, location: 1.00),
        ]
        #else
        let stops: [Gradient.Stop] = [
            .init(color: .clear, location: 0.86),
            .init(color: Theme.background.opacity(0.25), location: 0.93),
            .init(color: Theme.background.opacity(0.65), location: 0.97),
            .init(color: Theme.background, location: 1.00),
        ]
        #endif
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    /// How far the text block sits above the bottom edge — clear of the ramp
    /// into the page, so nothing readable ever reaches the part of the hero that
    /// has become the page colour.
    private var textInset: CGFloat {
        #if os(tvOS)
        // Raised with the longer ramp above: the buttons used to end about
        // where the join began, and the point of a join you can't see is that
        // nothing is sitting in it.
        return 96
        #else
        return 38
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            #if os(macOS)
            // The picture is the page's way into the title, as a poster is:
            // click it and the title opens, hold it and the title's menu comes
            // up. The scrims ride inside the button so the whole band answers
            // the pointer, brightening a shade under it the way a tile does.
            Button {
                app.push(.item(item.Id))
            } label: {
                backdrop
                    .brightness(isHoveringBackdrop ? 0.05 : 0)
                    .animation(.easeOut(duration: 0.15), value: isHoveringBackdrop)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringBackdrop = $0 }
            .itemContextMenu(item, allowsOpen: true)
            .accessibilityLabel(Self.displayTitle(of: item))
            .accessibilityHint("Opens the title")
            #else
            backdrop
            #endif

            content
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, textInset)
        }
        .frame(height: artHeight)
        .clipped()
        // A sidebar's hero is one view handed a different item rather than a
        // new one per title, so a missing wordmark has to stop being missing
        // when the item under it changes.
        .onChange(of: item.Id) { _, _ in logoUnavailable = false }
    }

    /// The artwork and everything that darkens it, at the hero's full size.
    private var backdrop: some View {
        ZStack {
            RemoteImage(
                url: Artwork.url(item, type: "Backdrop", width: backdropWidth)
                    ?? Artwork.url(item, type: "Primary", width: backdropWidth),
                blurHash: Artwork.hash(item, type: "Backdrop") ?? Artwork.hash(item),
                placeholderFill: Theme.heroPlaceholderFill
            )
            .frame(height: artHeight)
            .frame(maxWidth: .infinity)

            edgeScrim
            legibilityScrim
            pageBlend
            #if os(macOS)
            toolbarBlend
            #endif
        }
        .frame(height: artHeight)
    }

    /// What to ask the server for. A television is a 1920-point canvas, so a
    /// 1600-wide backdrop was being stretched across it before anything cropped
    /// it.
    static var backdropWidth: Int {
        #if os(tvOS)
        return 1920
        #else
        return 1600
        #endif
    }

    /// The pixels this particular hero needs. On the Mac that is the measured
    /// width times the screen's scale — a 1600-pixel picture across a Retina
    /// window twelve hundred points wide was the blur the review found — and
    /// capped at 4K, past which the server is resizing for nothing. Elsewhere
    /// it is the platform's fixed number.
    private var backdropWidth: Int {
        #if os(macOS)
        guard availableWidth > 0 else { return Self.backdropWidth }
        return min(3840, ImageLoader.requestWidth(points: availableWidth, displayScale: displayScale))
        #else
        return Self.backdropWidth
        #endif
    }

    #if os(macOS)
    /// The join to the toolbar, which has no surface of its own over this page
    /// (see `HomeView.body`): the top of the picture rises out of the window
    /// colour, so the title and the buttons in the toolbar sit on something
    /// that is nearly the window in either appearance, and the picture is
    /// fully itself by the time the toolbar ends. Measured in points from the
    /// top rather than as a fraction, because the toolbar is the same height
    /// whatever the hero is.
    private var toolbarBlend: LinearGradient {
        let reach: CGFloat = 96 / max(artHeight, 1)
        return LinearGradient(
            stops: [
                .init(color: Theme.background.opacity(0.92), location: 0.00),
                .init(color: Theme.background.opacity(0.55), location: reach * 0.45),
                .init(color: Theme.background.opacity(0.18), location: reach * 0.75),
                .init(color: .clear, location: reach),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
    #endif

    /// How wide the text block is allowed to get before it wraps. Two-thirds of
    /// the screen on a television — 620 points there is a column narrow enough
    /// to break a film's title across three lines in the middle of a very wide
    /// picture. On the Mac it follows the window: just over half of it, within
    /// reason, so a title on a small window wraps before it reaches the far
    /// side and one on a big window doesn't crowd a column meant for a phone.
    private var textWidth: CGFloat {
        #if os(tvOS)
        return 1000
        #elseif os(macOS)
        guard availableWidth > 0 else { return 620 }
        return min(760, max(440, availableWidth * 0.55))
        #else
        return 620
        #endif
    }

    #if os(macOS)
    /// The wordmark's box, from the window: about a quarter of the width,
    /// and never so small that a wide logo turns into a smudge.
    private var logoBox: CGSize {
        guard availableWidth > 0 else { return CGSize(width: 300, height: 76) }
        let width = min(440, max(260, availableWidth * 0.26))
        return CGSize(width: width, height: width * 0.26)
    }
    #endif

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The title, which episode this is, and what it is called: three
            // things, three lines, close enough together to read as one block.
            // They used to be one line reading "S02E04 · Some Title" under the
            // wordmark, which is a filename with a full stop in the middle.
            VStack(alignment: .leading, spacing: 6) {
                titleBlock

                if item.isEpisode, let label = item.episodeLabel {
                    Text(label)
                        .font(metaFont(strong: true))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(metaFont(strong: false))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
            }
            #if os(macOS)
            // Words over the picture, not a control in front of it: a click
            // on the title goes through to the backdrop underneath, which is
            // the button that opens the title. The buttons below keep their
            // own clicks.
            .allowsHitTesting(false)
            #endif

            if style == .home {
                if let progress = item.progressFraction {
                    resumeBar(progress)
                        #if os(macOS)
                        .allowsHitTesting(false)
                        #endif
                }
                actions
            }
        }
        // Even on a darkened backdrop, type over a photograph needs something
        // holding it off the picture. Two passes rather than one: a tight one
        // that draws the edge of each letter, and a wide, weak one that sinks
        // the area behind the whole block. Either alone is a drop shadow you can
        // see; together they read as the text simply being in front.
        //
        // Flattened first, off the television. Without it each shadow is
        // drawn once per line of text and per control inside the block — a
        // dozen and more blurred passes per page, and a phone's carousel keeps
        // every page alive — where the block as one layer is two. Nothing in
        // it overlaps, so it looks the same. Not on tvOS, where the block holds
        // focusable buttons whose lift is the system's to draw, and the
        // carousel only ever has one page.
        #if !os(tvOS)
        .compositingGroup()
        #endif
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 2)
        .frame(maxWidth: textWidth, alignment: .leading)
    }

    /// The title's own artwork where the server has it, which is what the studio
    /// meant the thing to look like, and typeset text where it doesn't.
    ///
    /// "Where the server has it" is a claim the item's own metadata makes and
    /// the image endpoint doesn't always honour — a tag left behind by an old
    /// scan, a logo that won't render. Trusting the tag alone is what leaves a
    /// hero with no title on it at all, so the fallback answers a failed fetch
    /// as well as a missing tag.
    @ViewBuilder
    private var titleBlock: some View {
        if let logo = Artwork.logo(item, width: 700), !logoUnavailable {
            RemoteImage(
                url: logo,
                contentMode: .fit,
                onResolved: { ok in logoUnavailable = !ok },
                // A wordmark is wider than it is tall. One that isn't is
                // almost always a stray canvas the logo sits in a corner of —
                // American Horror Story's is 800×3904, lettering in the top
                // seventh — and fitted to this frame it shrinks to a speck, so
                // the title is typeset instead.
                accepts: { $0.width >= $0.height }
            )
            #if os(tvOS)
            .frame(maxWidth: 520, maxHeight: 150, alignment: .leading)
            #elseif os(macOS)
            .frame(maxWidth: logoBox.width, maxHeight: logoBox.height, alignment: .leading)
            #else
            .frame(maxWidth: 300, maxHeight: 76, alignment: .leading)
            #endif
        } else {
            // An episode and a season both belong to a show, and the show is
            // what the wordmark would have said; "Season 2" printed over the
            // artwork and again under it says nothing the second time.
            Text(Self.displayTitle(of: item))
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                // A long title shrinks a little rather than wrapping to a third
                // line and pushing the buttons off the artwork.
                .minimumScaleFactor(0.75)
        }
    }

    /// The lines under the title. `.subheadline` was tuned for a phone and is
    /// eleven points on a Mac, which over a photograph is a caption nobody
    /// reads; the Mac gets body text, semibold where the phone was.
    private func metaFont(strong: Bool) -> Font {
        #if os(macOS)
        return strong ? .body.weight(.semibold) : .callout.weight(.medium)
        #else
        return strong ? .subheadline.weight(.semibold) : .subheadline.weight(.medium)
        #endif
    }

    /// The line under the title, for anything that isn't an episode: the year,
    /// how long it runs and what it is rated.
    ///
    /// An episode stops at the line above — the show's name, then which episode
    /// this is. Its own title belongs to the page you open, not to a hero whose
    /// job is to say what the *show* is; three lines of text over a backdrop
    /// with the last one naming a single episode read as clutter rather than as
    /// a thing worth starting.
    private var subtitle: String {
        guard !item.isEpisode, style == .home else { return "" }
        var parts: [String] = []
        if let year = item.ProductionYear { parts.append(String(year)) }
        let runtime = Format.ticks(item.RunTimeTicks)
        if !runtime.isEmpty { parts.append(runtime) }
        if let rating = item.OfficialRating, !rating.isEmpty { parts.append(rating) }
        return parts.joined(separator: " · ")
    }

    /// How far through you are, drawn rather than borrowed: `ProgressView` on a
    /// backdrop is a hairline in the system's grey, and this is the same bar the
    /// cards below use.
    private func resumeBar(_ progress: Double) -> some View {
        HStack(spacing: 10) {
            #if os(macOS)
            // The system's own bar on the Mac, tinted: it is the same control
            // the rest of the window uses for progress, and it sits in the
            // accent colour like everything else that is "yours".
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .frame(width: 168)
            #else
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(4, geo.size.width * progress))
                }
            }
            #if os(tvOS)
            .frame(width: 320, height: 8)
            #else
            .frame(width: 168, height: 4)
            #endif
            #endif

            Text(remainingText(progress))
                #if os(macOS)
                .font(.callout.weight(.medium))
                #else
                .font(.caption.weight(.medium))
                #endif
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.top, 2)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            #if os(tvOS)
            // A custom style, not the system's: `.borderedProminent` and
            // `.bordered` both draw a pale slab with a label the environment is
            // expected to colour, and against this app's dark palette that came
            // out white on white — the buttons said nothing until the selector
            // reached them and inverted the fill. `TVButtonStyle` draws both
            // states itself, and is focusable like any other button style.
            Button {
                Task { await start() }
            } label: {
                Label(item.progressFraction != nil ? "Resume" : "Play", systemImage: "play.fill")
            }
            .appButtonStyle(prominent: true)
            .focused($focus, equals: .play)

            Button("Details") { app.push(.item(item.Id)) }
                .appButtonStyle()
                .focused($focus, equals: .details)
            #elseif os(macOS)
            // A Mac button, in the accent colour, with the hover and the press
            // a Mac button has. Its own style rather than `.borderedProminent`:
            // AppKit takes the fill off a prominent button whenever its window
            // isn't the key one, and what's left — a clear bezel with the label
            // in the text colour — disappears into a dark backdrop. Click into
            // another app and the hero had a Details button and nothing else.
            // See `MacHeroButtonStyle`.
            //
            // No `.keyboardShortcut(.defaultAction)`: this is a page, not a
            // dialog, and Return anywhere in the window starting a film is not
            // what Return means on a page. The Playback menu has Play.
            Button {
                Task { await start() }
            } label: {
                Label(playLabel, systemImage: "play.fill")
                    .frame(minWidth: 84)
            }
            .buttonStyle(MacHeroButtonStyle())
            .controlSize(.large)
            .help("\(playLabel) \(Self.displayTitle(of: item))")

            Button("Details") { app.push(.item(item.Id)) }
                .buttonStyle(MacHeroButtonStyle(prominent: false))
                .controlSize(.large)
                .help("Show details for \(Self.displayTitle(of: item))")
            #else
            Button {
                Task { await start() }
            } label: {
                Label(playLabel, systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentStrong)

            // Not `.bordered`: its fill is drawn for a page background, and over
            // a photograph it is a grey smear with the accent colour written on
            // it. Glass over the darkened artwork is what the player's own
            // buttons do, and it stays legible whatever is behind it.
            Button { app.push(.item(item.Id)) } label: {
                Text("Details")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            #endif
        }
        .padding(.top, 2)
        // The buttons are the one thing here that is meant to look like it sits
        // on top of the picture rather than in it. Not on the Mac, where a
        // button with a drop shadow is a button from somewhere else.
        #if !os(macOS)
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        #endif
        #if os(tvOS)
        .onChange(of: focus) { _, now in onFocusChange?(now != nil) }
        #endif
    }

    private var playLabel: String { item.progressFraction != nil ? "Resume" : "Play" }

    /// What pressing Play starts.
    ///
    /// A film plays itself; a show can't. A series has no media of its own, so
    /// it has to be resolved first — the episode you're up to, else where the
    /// show begins — which is the same thing its own page does with its Play
    /// button, and the reason a series in the media bar isn't a dead end.
    private func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        await Self.start(item, app: app, player: player, client: client)
    }

    /// The same road, for anything else that means "play what the hero is
    /// showing" — the Mac toolbar's Play Featured, which has no hero of its
    /// own to press.
    @MainActor
    static func start(_ item: BaseItem, app: AppModel, player: PlayerModel, client: JellyfinClient) async {
        guard item.isSeries else {
            await player.play(item: item)
            return
        }

        if let next = try? await client.seriesNextUp(seriesId: item.Id) {
            await player.play(item: next)
            return
        }
        // Nothing queued: a show that was never started, or one the server
        // considers finished. Its first unwatched episode, else its opener.
        let episodes = (try? await client.episodes(seriesId: item.Id, seasonId: nil)) ?? []
        if let first = episodes.first(where: { !$0.userData.played }) ?? episodes.first {
            await player.play(item: first)
        } else {
            // A show with no episodes on the server is a page, not a stream.
            app.push(.item(item.Id))
        }
    }

    private func remainingText(_ progress: Double) -> String {
        let total = item.runtimeSeconds
        guard total > 0 else { return "" }
        let left = total * (1 - progress)
        return "\(Format.ticks(Int64(left * 10_000_000))) left"
    }
}

#if os(tvOS)
/// The media bar: the top of Home as a few things worth starting rather than
/// the one that happened to be first in Continue Watching, moving on by itself
/// if you don't.
///
/// The same idea as the phone's carousel below, built differently because tvOS
/// has no paging `TabView` and no swipe to drive one. One page is drawn at a
/// time and crossfades to the next; the rest are fetched into the image cache up
/// front so a change of page is a fade rather than a blur resolving again.
///
/// It stops rotating while the selector is inside it. A bar that changed title
/// under a focused Play button would start something other than what the button
/// said when you pressed it — and moving focus off it is exactly the moment
/// rotating becomes harmless again.
struct HeroCarousel: View {
    let items: [BaseItem]
    /// Passed straight through to whichever page is on screen.
    var topBleed: CGFloat = 0

    @State private var index = 0
    @State private var isFocused = false
    /// Held in state so it belongs to the view's lifetime rather than being a
    /// fresh countdown on every redraw.
    @State private var ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: BaseItem? {
        items.indices.contains(index) ? items[index] : items.first
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let current {
                HeroHeader(item: current, onFocusChange: { isFocused = $0 }, topBleed: topBleed)
                    .id(current.Id)
                    .transition(.opacity)
            }
            if items.count > 1 { pageDots }
        }
        .frame(height: HeroHeader.height + topBleed)
        .onReceive(ticker) { _ in
            guard !reduceMotion, !isFocused, items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                index = (index + 1) % items.count
            }
        }
        // A fresh draw is a fresh bar: it starts at the first of the new set
        // rather than at wherever the old one had got to — which would also be
        // out of range whenever the new draw is the shorter of the two.
        .onChange(of: items.map(\.Id)) { _, _ in index = 0 }
        .task(id: items.map(\.Id)) { await prefetch() }
    }

    /// Everything but the page on screen, pulled into the image cache. Without
    /// it the first turn of the bar shows a blur resolving, because `RemoteImage`
    /// only skips its placeholder when the artwork is already cached.
    private func prefetch() async {
        for item in items.dropFirst() {
            guard let url = Artwork.url(item, type: "Backdrop", width: HeroHeader.backdropWidth)
            else { continue }
            _ = await ImageLoader.shared.load(url)
            if Task.isCancelled { return }
        }
    }

    /// Where you are in the set, in the corner the text block doesn't reach.
    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { position in
                Capsule()
                    .fill(position == index ? Theme.accent : Color.white.opacity(0.35))
                    .frame(width: position == index ? 34 : 12, height: 12)
            }
        }
        .padding(.trailing, Metrics.gutter)
        .padding(.bottom, 30)
        .animation(.easeOut(duration: 0.25), value: index)
        .accessibilityHidden(true)
    }
}
#endif

#if os(iOS)
/// The hero as a rotating carousel rather than one fixed title — the shape
/// Jellyfin's own media bar has, and what the top of a home page is for: a few
/// things worth starting, one at a time, moving on by itself if you don't.
///
/// Each page is the same `HeroHeader` the one-item version was, so what a page
/// says and how it is lit haven't changed; only how many of them there are.
struct HeroCarousel: View {
    let items: [BaseItem]

    @State private var index = 0
    /// Held in state so it belongs to the view's lifetime: built inline it
    /// would be a new publisher, and a fresh countdown, on every redraw.
    @State private var ticker = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    /// Something that moves on its own is exactly what this setting is for.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.Id) { position, item in
                    HeroHeader(item: item)
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: HeroHeader.height)

            if items.count > 1 { pageDots }
        }
        .frame(height: HeroHeader.height)
        .onReceive(ticker) { _ in
            guard !reduceMotion, items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                index = (index + 1) % items.count
            }
        }
        // A fresh draw is a fresh bar: it starts at the first of the new set
        // rather than at wherever the old one had got to — which would also be
        // out of range whenever the new draw is the shorter of the two. Without
        // animation, because this is a new set of titles arriving, not the bar
        // turning: paging back to the first one is not something to watch.
        .onChange(of: items.map(\.Id)) { _, _ in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { index = 0 }
        }
    }

    /// Where you are in the set. The system's own page dots are white on white
    /// half the time and can't be put anywhere but the centre; these are drawn
    /// from the palette, low enough to be over the part of the hero that has
    /// already become the page, which is why they read in both themes.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { position in
                Capsule()
                    .fill(position == index ? Theme.accent : Theme.textDim.opacity(0.75))
                    .frame(width: position == index ? 18 : 6, height: 6)
            }
        }
        // A backing of the page's own colour. The dots sit where the hero is
        // fading into the page, and how far that fade has got depends on the
        // artwork: over a pale backdrop in the light theme the inactive dots
        // were grey on grey and all but gone.
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.background.opacity(0.55), in: Capsule())
        .padding(.trailing, Metrics.gutter)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.25), value: index)
        .accessibilityHidden(true)
    }
}
#endif
