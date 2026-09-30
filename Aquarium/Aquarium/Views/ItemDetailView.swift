//  The detail page: what this is, what it's made of, and every way to start it.
//
//  Series pages carry their season picker and episode list; films carry the
//  quality and download menus directly. Cast names search for themselves, and
//  "More like this" is the server's own recommendation.

import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(iOS)
/// How far the detail page has been scrolled.
private struct DetailScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
#endif

struct ItemDetailView: View {
    let itemId: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player

    @State private var item: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var episodes: [BaseItem] = []
    @State private var similar: [BaseItem] = []
    /// Which title `similar` was fetched for, so a reload of the same page
    /// doesn't ask again.
    @State private var similarLoadedFor: String?
    @State private var nextUp: BaseItem?
    @State private var isLoading = true
    @State private var error: String?
    /// The item the state below belongs to — so a new id starts clean, while
    /// coming back to the same page keeps what it had.
    @State private var loadedId: String?
    /// Whether the backdrop has gone past the navigation bar, which is when the
    /// bar earns a background and a title.
    @State private var scrolledPastHero = false
    #if !os(tvOS)
    @State private var spacePrompt: SpacePrompt?
    /// The row Next Up sent this page to, while it is still being pointed at.
    /// Separate from `app.pendingEpisodeHighlight`, which is a request and is
    /// spent the moment it is read; this is the state of the row afterwards.
    @State private var episodeHighlight: String?
    #else
    /// Which item the quality dialog is picking a stream for — the television's
    /// stand-in for the quality menu, for the reason given on the button.
    @State private var qualityChoice: BaseItem?

    /// Where the selector goes once this page has something on it.
    ///
    /// A pushed page on tvOS arrives empty — the item is still being fetched —
    /// and an empty page has nothing for the focus engine to hold, so focus
    /// stays on the tab strip above. Nothing moves it down again when the page
    /// fills in a moment later: the engine places focus when a screen appears,
    /// not when it changes. That is the whole of "I opened a series and could
    /// only move around the menu bar", and it is also why Back closed the app
    /// rather than going up a level — the Menu button pops the navigation
    /// stack when focus is inside the page and leaves the app when it is on
    /// the strip. Putting focus on the page's first action as soon as there is
    /// one fixes both.
    private enum DetailFocus: Hashable {
        case play, quality, favorite, watched, trailer, episode(String)

        /// One of the buttons under the artwork, rather than a row further down.
        var isAction: Bool {
            if case .episode = self { return false }
            return true
        }
    }
    @FocusState private var focus: DetailFocus?
    /// Once only — after that the selector is the viewer's to move.
    @State private var placedFocus = false
    #endif

    var body: some View {
        #if os(iOS)
        // The artwork starts below the bar rather than behind it, which is what
        // Home does too — and, like Home, the bar is this page's own rather
        // than the system's. See `AppTopBar` for why: a navigation bar pushed
        // on top of a large-titled screen opens at *that* screen's height and
        // only takes its own when something else makes the page redraw, which
        // on a page that loads in stages is the moment after it has finished.
        scroll()
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .toolbar(.hidden, for: .navigationBar)
            // Hiding the bar takes the back-swipe with it unless it is asked
            // for again.
            .background { BackSwipe().frame(width: 0, height: 0) }
            .onPreferenceChange(DetailScrollKey.self) { offset in
                // A bar's worth of scrolling, not the height of the hero: an
                // episode page is short enough that its scroll stops before the
                // artwork has cleared the bar, and a threshold measured from the
                // hero's own height would leave that page permanently without
                // its title.
                scrolledPastHero = -offset > 80
            }
        #elseif os(tvOS)
        scroll()
            .screenTitle(navigationTitle)
            .onChange(of: focusTarget) { _, target in
                guard let target, !placedFocus else { return }
                placedFocus = true
                focus = target
                // Spent — but only by the page it was meant for. The show
                // underneath this one is built too, and it settles its own
                // focus first: clearing on every page would throw the request
                // away before the season it names had loaded its episodes.
                if case .episode = target { app.pendingEpisodeHighlight = nil }
            }
        #else
        scroll()
            .screenTitle(navigationTitle)
            // A season's own name goes in the subtitle, under the show's in
            // the title bar — the level and the level above it, the way a
            // document window names the file and the folder. The page itself
            // no longer repeats it; see `details`.
            .navigationSubtitle(navigationSubtitle)
            // The hero runs up under the title bar, the way the TV app's
            // does: the toolbar keeps its controls and loses its background,
            // and the artwork's own scrim keeps the title legible. Painting
            // the bar a colour instead put a hard edge across the top of
            // every photograph.
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let item { toolbarActions(item) }
                }
            }
            .focusedSceneValue(\.itemMenuActions, menuActions)
        #endif
    }

    #if os(macOS)
    /// The season on a season page; nothing anywhere else. The window title
    /// carries the show — see `navigationTitle`.
    private var navigationSubtitle: String {
        guard let item, item.isSeason, let series = item.SeriesName, !series.isEmpty else { return "" }
        return item.title
    }

    /// What the toolbar holds, once there is an item to hold it for: the
    /// state toggles, the download, and the window. Play stays in the page —
    /// it is the one action the page is *for*, and a prominent button beside
    /// the artwork is where the eye expects it. Everything else is a toggle or
    /// a menu, which is what a toolbar is made of.
    @ViewBuilder
    private func toolbarActions(_ item: BaseItem) -> some View {
        Toggle(isOn: Binding(
            get: { item.userData.isFavorite },
            set: { _ in Task { await toggleFavourite(item) } }
        )) {
            Label(
                item.userData.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: item.userData.isFavorite ? "star.fill" : "star"
            )
        }
        .toggleStyle(.button)
        .help(item.userData.isFavorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D)")

        // A show is marked a season at a time — see `ItemMenuActions.isWatched`.
        if !item.isSeries {
            Toggle(isOn: Binding(
                get: { item.userData.played },
                set: { _ in Task { await toggleWatched(item) } }
            )) {
                Label(
                    item.userData.played ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: item.userData.played ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .toggleStyle(.button)
            .help(item.userData.played ? "Mark as Unwatched (⇧⌘U)" : "Mark as Watched (⇧⌘U)")
        }

        downloadMenu(item)
            .help("Download")

        Button {
            openWindow(id: ItemWindow.id, value: item.Id)
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        .help("Open in New Window (⌥⌘O)")
    }
    /// This page's actions, for the Item menu while it is in front.
    private var menuActions: ItemMenuActions? {
        guard let item else { return nil }
        let playable = playable(for: item)
        return ItemMenuActions(
            title: item.title,
            canPlay: playable != nil,
            playLabel: playable.map { playLabel($0) } ?? "Play",
            isFavorite: item.userData.isFavorite,
            isWatched: item.isSeries ? nil : item.userData.played,
            play: {
                guard let playable else { return }
                Task { await player.play(item: playable) }
            },
            toggleFavorite: { Task { await toggleFavourite(item) } },
            toggleWatched: { Task { await toggleWatched(item) } },
            openInNewWindow: { openWindow(id: ItemWindow.id, value: item.Id) }
        )
    }

    @Environment(\.openWindow) private var openWindow
    #endif

    #if os(tvOS)
    /// Which control is worth landing on, once the page knows enough to have
    /// one. Play where there is something to play — a series whose next
    /// episode the server hasn't named yet has nothing, and the favourite
    /// button is then the first thing in the row.
    ///
    /// An episode asked for by name outranks all of that: Next Up opens the
    /// season rather than the episode's own page, and the row it means is where
    /// the selector belongs. It waits for the list, because the focus engine
    /// can only be sent to a view that exists and the episodes arrive a request
    /// after the season does — and landing on the row scrolls it into view,
    /// which is the rest of what this is for.
    private var focusTarget: DetailFocus? {
        guard let item else { return nil }
        if let highlight = app.pendingEpisodeHighlight, highlight.seasonId == itemId {
            if episodes.contains(where: { $0.Id == highlight.episodeId }) {
                return .episode(highlight.episodeId)
            }
            // Still fetching the list, so hold: the row is the whole point.
            // But only until the answer is in — an episode that isn't in the
            // season the server put it in would otherwise leave the page with
            // nothing focused at all, and that is the state the Menu button
            // quits the application from rather than going back a level.
            if isLoading { return nil }
        }
        return playable(for: item) != nil ? .play : .favorite
    }
    #endif

    #if os(iOS)
    @Environment(\.dismiss) private var dismiss

    /// The way back, and — once the artwork carrying it has gone past — what
    /// this page is. Nothing here changes the bar's height, so the title can
    /// come and go without anything moving.
    private var topBar: some View {
        AppTopBar {
            HStack(spacing: 4) {
                BarBackButton { dismiss() }
                if scrolledPastHero {
                    Text(navigationTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: scrolledPastHero)
        }
    }
    #endif

    /// The page, and — where there is one to place — the arrival that put it
    /// there.
    ///
    /// A television answers Next Up by moving the selector; nothing else has a
    /// selector, so here the page scrolls the row into the middle of itself and
    /// lights it for a few seconds. Both are the same promise the row on Home
    /// made: you asked for one episode and here is the list it lives in, with
    /// that episode pointed at.
    ///
    /// The `ScrollViewReader` has to be outside the scroll view it drives, so
    /// this wraps rather than being folded into `scrollCore` — and it is only
    /// built where there is something for it to do.
    @ViewBuilder
    private func scroll() -> some View {
        #if os(tvOS)
        ScrollViewReader { proxy in
            scrollCore()
                // Back to the top whenever the selector arrives on the buttons.
                //
                // The focus engine scrolls only as far as it takes to show what
                // it has just focused, and the buttons are the first thing on
                // the page it can focus — everything above them is artwork and
                // text. Coming back up from the seasons or the cast, the page
                // stopped with the buttons at its top edge and the hero, title
                // and all, still scrolled away, with nothing further up for a
                // press to reach. The buttons are the top of the page as far as
                // the selector goes, so they show it as it opened.
                .onChange(of: focus) { _, now in
                    guard now?.isAction == true else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(Self.topAnchor, anchor: .top)
                    }
                }
        }
        #else
        ScrollViewReader { proxy in
            scrollCore()
                .onChange(of: highlightTarget, initial: true) { _, target in
                    guard let target else { return }
                    // Spent by the page it names, and only by that page: the
                    // show underneath this one is on the stack too and must not
                    // throw the request away before the season it points at has
                    // its episodes.
                    app.pendingEpisodeHighlight = nil
                    #if os(macOS)
                    // A Mac list has a selection, so the row is simply
                    // selected — and stays so, the way a file you were sent
                    // to in Finder stays selected. The list sits inside this
                    // page's scroll view (see `MacEpisodeList`), so the page
                    // brings the list's top into view and the selection does
                    // the pointing.
                    episodeSelection = [target]
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(Self.episodesAnchor, anchor: .top)
                    }
                    #else
                    withAnimation(.easeInOut(duration: 0.35)) {
                        episodeHighlight = target
                        proxy.scrollTo(target, anchor: .center)
                    }
                    // Long enough to be seen and short enough not to become a
                    // selection the list is stuck in. Nothing else clears it,
                    // because nothing else in this list has a state to return to.
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation(.easeOut(duration: 0.6)) { episodeHighlight = nil }
                    }
                    #endif
                }
        }
        #endif
    }

    #if os(macOS)
    /// The episode rows the pointer or the keyboard has picked out. Next Up
    /// arrives as one of these; the context menu acts on all of them.
    @State private var episodeSelection: Set<String> = []
    /// Where the page scrolls to for an arrival — the list's heading, which
    /// is in this scroll view; the rows are in the list's own.
    private static let episodesAnchor = "episodes"
    /// The trailer's address goes to whatever the system opens links with.
    @Environment(\.openURL) private var openURL
    #endif

    #if !os(tvOS)
    /// The episode this page was opened for, once the list it is in has
    /// arrived. Nil until then — and nil for the show underneath, whose own
    /// `itemId` is not the season the request names.
    private var highlightTarget: String? {
        guard let highlight = app.pendingEpisodeHighlight, highlight.seasonId == itemId,
              episodes.contains(where: { $0.Id == highlight.episodeId })
        else { return nil }
        return highlight.episodeId
    }
    #endif

    @ViewBuilder
    private func scrollCore() -> some View {
        ScrollView {
            #if os(iOS)
            scrollProbe
            #endif
            if isLoading, item == nil {
                // The page it is about to be, in the shape it will take.
                VStack(alignment: .leading, spacing: 26) {
                    SkeletonHero()
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBar(height: 20, width: 220)
                        SkeletonBar(height: 11, width: 160)
                        SkeletonBar(height: 38, width: 260)
                        SkeletonBar(height: 10)
                        SkeletonBar(height: 10)
                        SkeletonBar(height: 10, width: 200)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    SkeletonShelf()
                }
                .padding(.bottom, 40)
            } else if let error, item == nil {
                ErrorState(error: error) { Task { await load() } }
            } else if let item {
                // Eager on a television, lazy everywhere else.
                //
                // The selector can only move to a view that exists, and a lazy
                // stack builds nothing it hasn't been scrolled to. The hero here
                // is 720 points of a 1080-point screen, so the first thing below
                // the fold is the row of buttons — and everything after it, the
                // seasons, the episodes, the cast, was unbuilt. Pressing down
                // off the buttons found nothing to move to, so nothing scrolled,
                // so nothing was ever built: the page you could open and then
                // only press Play, Quality or Favorite on. A detail page is a
                // bounded thing — one show's seasons, one season's episodes, two
                // dozen faces — so building all of it is a fair price for being
                // able to reach it.
                detailStack(item)
                    .padding(.bottom, 40)
            }
        }
        .coordinateSpace(name: Self.scrollSpace)
        // Keyed on the item: on tvOS the detail root can go straight from one
        // item to another, and SwiftUI keeps this view rather than making a
        // new one, so an unkeyed task would leave the first item showing.
        .task(id: itemId) {
            if loadedId != itemId { resetForNewItem() }
            await load()
        }
        .reloadWhenPlaybackEnds { await load() }
        .reloadWhenItemsChange { await load() }
        #if !os(macOS)
        // A tap that changed something gets a tick in the hand. A Mac has no
        // hand to tick; the toggle in the toolbar changes state and that is
        // the whole of the feedback.
        .sensoryFeedback(trigger: item?.userData.isFavorite) { was, now in
            guard let was, let now, was != now else { return nil }
            return now ? .success : .impact(weight: .light)
        }
        .sensoryFeedback(trigger: item?.userData.played) { was, now in
            guard let was, let now, was != now else { return nil }
            return .impact(weight: .light)
        }
        #endif
        #if os(macOS)
        // An alert, with the rungs that would fit as its buttons: the first
        // of them is the default, Escape cancels. See `SpaceAlert`.
        .spaceAlert($spacePrompt) { prompt, chosen in
            queue(prompt.items, quality: chosen)
        }
        #elseif !os(tvOS)
        .sheet(item: $spacePrompt) { prompt in
            SpacePromptView(prompt: prompt) { chosen in
                spacePrompt = nil
                guard let chosen else { return }
                queue(prompt.items, quality: chosen)
            }
        }
        #else
        .confirmationDialog(
            "Play at",
            isPresented: Binding(
                get: { qualityChoice != nil },
                set: { if !$0 { qualityChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = qualityChoice {
                qualityMenu(target)
            }
            Button("Cancel", role: .cancel) { qualityChoice = nil }
        }
        #endif
    }

    @ViewBuilder
    private func detailStack(_ item: BaseItem) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 26) { sections(item) }
        #else
        LazyVStack(alignment: .leading, spacing: 26) { sections(item) }
        #endif
    }

    @ViewBuilder
    private func sections(_ item: BaseItem) -> some View {
        HeroHeader(item: item, style: .detail)
            .id(Self.topAnchor)
        details(item)
        // A show is its seasons, and a season is its episodes. The two lists
        // never appear on the same page: mixing them is what made "which season
        // am I looking at" a question.
        if item.isSeries { seasonsSection }
        if item.isSeason { episodesSection }
        castSection(item)
        MediaShelf(title: "More Like This", items: similar) { app.push(.item($0.Id)) }
    }

    private static let scrollSpace = "itemDetailScroll"
    /// The hero, which is where the page starts.
    private static let topAnchor = "itemDetailTop"

    #if os(iOS)
    /// Reports how far the page has been scrolled, which is the only thing the
    /// navigation bar needs to know: whether the artwork is still behind it.
    private var scrollProbe: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: DetailScrollKey.self,
                value: geo.frame(in: .named(Self.scrollSpace)).minY
            )
        }
        .frame(height: 0)
    }
    #endif

    /// A season's own name is "Season 2", which says nothing in a navigation
    /// bar. The show goes there and the season stays as the page's heading, so
    /// the bar reads as the level above — which is what it is.
    private var navigationTitle: String {
        guard let item else { return "" }
        if item.isSeason, let series = item.SeriesName, !series.isEmpty { return series }
        return item.title
    }

    // MARK: - Details block

    @ViewBuilder
    private func details(_ item: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The page's heading. An episode's own name, a season's number, and
            // — since the hero above may be showing nothing but a wordmark, or
            // a backdrop the studio never made one for — a show's name too. A
            // film is the one thing that doesn't get it: its hero is its title
            // and its poster, and there is no level below it to name.
            if showsHeading(item) {
                VStack(alignment: .leading, spacing: 4) {
                    // The way up, above the name of where you are — the levels
                    // read downwards, and this is the level above whatever the
                    // line under it says. Tight against the title rather than a
                    // stack step away, because the two are one heading.
                    #if !os(tvOS)
                    AncestorTrail(item: item)
                    #endif
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.text)
                }
            }
            if let tagline = item.Taglines?.first, !tagline.isEmpty {
                Text(tagline)
                    .font(.subheadline.italic())
                    .foregroundStyle(Theme.textDim)
                    .macSelectable()
            }
            FactsLine(item: item)
                .macSelectable()

            // Which episode Play would start, where that isn't this page's own
            // item — a show plays whatever is next, a season the first thing in
            // it you haven't seen. Spelled out on a line of its own: the button
            // used to carry it as "Play S02E04", which is both a filename and
            // the longest label in the row.
            if let target = playable(for: item), target.Id != item.Id, target.isEpisode {
                Text(upNextLine(target))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(2)
            }

            // Where you got to — in whatever Play would actually start, which on
            // a show or a season is an episode rather than this page's own item.
            // This used to be drawn over the artwork, beside a second Resume
            // button and a "Details" button pointing at this very page; the
            // artwork is artwork now, and the one thing saying what pressing
            // Play will do sits where the Play button is.
            if let target = playable(for: item), let progress = target.progressFraction {
                resumeLine(progress, of: target)
            }

            actionRow(item)

            MediaSummaryLine(item: item)

            if let overview = item.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(Theme.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                    .macSelectable()
            }

            // Genres, the studios and the description of the file were three
            // caption lines in the same grey, one under the other, with nothing
            // saying which was which — "Action · Drama" and "Warner Bros." read
            // as the same kind of fact. Genres are chips because that is what
            // they are, and the studios get a word for themselves.
            if let genres = item.Genres, !genres.isEmpty {
                #if os(macOS)
                // One line of secondary text, the way the TV app lists them.
                // There is no library route that filters by genre, so they
                // are reading matter rather than links.
                Text(genres.prefix(6).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .macSelectable()
                #else
                WrappingRow(spacing: 8, rowSpacing: 8) {
                    ForEach(genres.prefix(6), id: \.self) { genre in
                        MetaChip(text: genre)
                    }
                }
                #endif
            }
            if let studios = item.Studios?.compactMap(\.Name).filter({ !$0.isEmpty }), !studios.isEmpty {
                Label(studios.joined(separator: " · "), systemImage: "building.2")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .macSelectable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.gutter)
    }

    /// Whether the page repeats its own name under the artwork. An episode's
    /// own name, a season's number, and — since the hero above may be showing
    /// nothing but a wordmark — a show's name too. A film doesn't: its hero is
    /// its title. On the Mac a season doesn't either, because the window's
    /// title and subtitle already say "The Bear — Season 2" and a third copy
    /// under the artwork is the duplicate the review objected to.
    private func showsHeading(_ item: BaseItem) -> Bool {
        #if os(macOS)
        if item.isSeason, let series = item.SeriesName, !series.isEmpty { return false }
        #endif
        return item.isEpisode || item.isSeason || item.isSeries
    }

    /// How far through this one is, in the page's own colours — the hero's bar
    /// was white-on-artwork and this one sits on the page.
    private func resumeLine(_ progress: Double, of item: BaseItem) -> some View {
        HStack(spacing: 10) {
            #if os(macOS)
            // The system's bar, at the system's height.
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 168)
            #else
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(4, geo.size.width * progress))
                }
            }
            .frame(width: 168, height: 4)
            #endif

            Text(remainingText(progress, of: item))
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textDim)
                .macSelectable()
        }
    }

    private func remainingText(_ progress: Double, of item: BaseItem) -> String {
        let total = item.runtimeSeconds
        guard total > 0 else { return "" }
        let left = total * (1 - progress)
        return "\(Format.ticks(Int64(left * 10_000_000))) left"
    }

    /// The actions, laid out so a label never has to shrink to fit.
    ///
    /// A phone cannot hold five spelled-out buttons on one line, and squeezing
    /// them is what turned "Mark watched" into two crushed lines. There, only
    /// the three that get pressed keep a place of their own and the rest move
    /// into an overflow menu; anywhere wider they all stay on show, wrapping
    /// onto a second line if the window is narrowed.
    @ViewBuilder
    private func actionRow(_ item: BaseItem) -> some View {
        #if os(macOS)
        // Two buttons at most, so nothing ever wraps: Play, as a split button
        // whose menu holds the quality rungs, and the trailer. Favorite,
        // Watched and Download live in the toolbar — see `toolbarActions`.
        HStack(spacing: 10) {
            if let playable = playable(for: item) {
                Menu {
                    Section("Play At") {
                        qualityMenu(playable)
                    }
                } label: {
                    Label(playLabel(playable), systemImage: "play.fill")
                } primaryAction: {
                    Task { await player.play(item: playable) }
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("\(playLabel(playable)) (⌘↩)")
            }
            if Trailers.has(item) {
                Button {
                    Task { await playTrailer(item) }
                } label: {
                    Label("Play Trailer", systemImage: "film")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Play Trailer")
            }
        }
        #else
        Group {
            if isCompact {
                // A plain row, not `WrappingRow`: the compact row never holds
                // more than four icon-sized buttons, which is never going to
                // wrap on any iPhone width. It matters here because it isn't
                // just tidiness — a `Menu` inside the custom `Layout` opened
                // its pull-down anchored to the row's first button rather
                // than the one actually pressed, so the "More" menu floated
                // up over the title no matter which item it belonged to. A
                // stock `HStack` doesn't confuse UIKit's popover geometry the
                // way the custom layout did.
                HStack(spacing: 10) {
                    compactActions(item, playable: playable(for: item))
                }
            } else {
                WrappingRow(spacing: 10, rowSpacing: 10) {
                    actionButtons(item, playable: playable(for: item))
                }
            }
        }
        // On a television this row is the first thing on the page the selector
        // can hold, and it sits well below the artwork above it — see
        // `focusRegion`. As wide as the page, not as its buttons: a region is
        // its frame, and a row four buttons long left everything to the right
        // of them — the later seasons, most of the cast — with nothing above
        // it to go up to.
        #if os(tvOS)
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .focusRegion()
        #endif
    }

    /// What Play starts. A series plays whatever the server says is next; a
    /// season plays the first episode of its own that hasn't been watched,
    /// since the season page is where you land when you have decided *which*
    /// season to carry on with; anything else plays itself.
    private func playable(for item: BaseItem) -> BaseItem? {
        if item.isSeries { return nextUp }
        if item.isSeason {
            return episodes.first { !$0.userData.played } ?? episodes.first
        }
        return item
    }

    #if !os(macOS)
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    @ViewBuilder
    private func playButton(_ playable: BaseItem) -> some View {
        Button {
            Task { await player.play(item: playable) }
        } label: {
            Label(playLabel(playable), systemImage: "play.fill")
        }
        .appButtonStyle(prominent: true)
        #if os(tvOS)
        .focused($focus, equals: .play)
        #endif
    }
    #endif

    @ViewBuilder
    private func qualityMenu(_ playable: BaseItem) -> some View {
        ForEach(Quality.choices) { choice in
            Button(choice.label) {
                Task {
                    await player.play(
                        item: playable,
                        options: StreamOptions(maxBitrate: choice.maxBitrate)
                    )
                }
            }
        }
    }

    // The row of buttons the phone and the television draw. The Mac's
    // are in `actionRow` and `toolbarActions`.
    #if !os(macOS)
    @ViewBuilder
    private func actionButtons(_ item: BaseItem, playable: BaseItem?) -> some View {
        if let playable {
            playButton(playable)

            #if os(tvOS)
            // A `Menu` on a television is the system's own control, and it
            // brings the system's own colours with it — the same reason the
            // buttons around it are drawn by hand. A button that opens a dialog
            // is the same two presses and looks like the rest of the row.
            Button {
                qualityChoice = playable
            } label: {
                Label("Quality", systemImage: "slider.horizontal.3")
            }
            .appButtonStyle()
            .focused($focus, equals: .quality)
            #else
            Menu {
                qualityMenu(playable)
            } label: {
                Label("Quality", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            #endif
        }

        Button {
            Task { await toggleFavourite(item) }
        } label: {
            Label(
                item.userData.isFavorite ? "Favorited" : "Favorite",
                systemImage: item.userData.isFavorite ? "star.fill" : "star"
            )
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: item.userData.isFavorite)
        }
        .appButtonStyle(highlight: item.userData.isFavorite ? Theme.warn : nil)
        #if os(tvOS)
        .focused($focus, equals: .favorite)
        #endif

        if !item.isSeries {
            Button {
                Task { await toggleWatched(item) }
            } label: {
                Label(
                    item.userData.played ? "Watched" : "Mark watched",
                    systemImage: item.userData.played ? "checkmark.circle.fill" : "checkmark.circle"
                )
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: item.userData.played)
            }
            .appButtonStyle()
            #if os(tvOS)
            .focused($focus, equals: .watched)
            #endif
        }

        if Trailers.has(item) {
            Button {
                Task { await playTrailer(item) }
            } label: {
                Label("Trailer", systemImage: "film")
            }
            .appButtonStyle()
            #if os(tvOS)
            .focused($focus, equals: .trailer)
            #endif
        }

        #if !os(tvOS)
        downloadMenu(item)
            .buttonStyle(.bordered)
        #endif
    }

    /// Phone-width actions: play, favourite, download, and everything else
    /// behind one glyph.
    @ViewBuilder
    private func compactActions(_ item: BaseItem, playable: BaseItem?) -> some View {
        if let playable {
            playButton(playable)
        }

        Button {
            Task { await toggleFavourite(item) }
        } label: {
            Label(
                item.userData.isFavorite ? "Favorited" : "Favorite",
                systemImage: item.userData.isFavorite ? "star.fill" : "star"
            )
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: item.userData.isFavorite)
        }
        .appButtonStyle(highlight: item.userData.isFavorite ? Theme.warn : nil)

        #if !os(tvOS)
        downloadMenu(item)
            .buttonStyle(.bordered)
        #endif

        // Nothing to put behind the glyph on a series whose next episode the
        // server hasn't told us about yet.
        if playable != nil || !item.isSeries || Trailers.has(item) {
            Menu {
                if Trailers.has(item) {
                    Button {
                        Task { await playTrailer(item) }
                    } label: {
                        Label("Watch trailer", systemImage: "film")
                    }
                }
                if let playable {
                    Menu {
                        qualityMenu(playable)
                    } label: {
                        Label("Play at a set quality", systemImage: "slider.horizontal.3")
                    }
                }
                if !item.isSeries {
                    Button {
                        Task { await toggleWatched(item) }
                    } label: {
                        Label(
                            item.userData.played ? "Mark unwatched" : "Mark watched",
                            systemImage: item.userData.played ? "arrow.uturn.backward.circle" : "checkmark.circle"
                        )
                    }
                }
            } label: {
                // Sized by a star it doesn't show. A button is as tall as its
                // glyph, and an ellipsis is three dots on the baseline — a
                // third the height of the star and the arrow beside it — so
                // this was visibly the runt of the row.
                Label {
                    Text("More")
                } icon: {
                    Image(systemName: "star")
                        .hidden()
                        .overlay { Image(systemName: "ellipsis") }
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
        }
    }
    #endif

    private func playLabel(_ item: BaseItem) -> String {
        item.progressFraction != nil ? "Resume" : "Play"
    }

    /// "Up next · Season 2: Episode 4 · Fishes", or "Carry on with" where it has
    /// already been started — the line under the facts that says which episode
    /// the Play button is pointing at.
    private func upNextLine(_ target: BaseItem) -> String {
        var parts: [String] = []
        if let label = target.episodeLabel { parts.append(label) }
        parts.append(target.title)
        let lead = target.progressFraction != nil ? "Carry on with" : "Up next"
        return "\(lead) · " + parts.joined(separator: " · ")
    }

    #if !os(tvOS)
    @ViewBuilder
    private func downloadMenu(_ item: BaseItem) -> some View {
        // The record is read inside `WithDownloadRecord`'s body, not this
        // page's: read here, every change to any download — a transfer
        // starting, finishing, being written to disk — redrew the whole page,
        // hero, cast and episode list, to relabel one button.
        WithDownloadRecord(itemId: item.Id) { existing in
            downloadMenu(item, existing: existing)
        }
    }

    private func downloadMenu(_ item: BaseItem, existing: DownloadRecord?) -> some View {
        Menu {
            if item.isSeries {
                Menu {
                    ForEach(DownloadQualities.all) { quality in
                        Button(quality.label) {
                            Task { await requestSeriesDownload(item, quality: quality) }
                        }
                    }
                } label: {
                    Label("Whole Series", systemImage: "square.stack.3d.down.right")
                }
                // A season at a time is what most people actually want, and
                // going one level down to the season page to get it is a
                // detour — every season this series has is offered here.
                ForEach(seasons) { season in
                    Menu {
                        ForEach(DownloadQualities.all) { quality in
                            Button(quality.label) {
                                Task { await requestSeasonDownload(series: item, season: season, quality: quality) }
                            }
                        }
                    } label: {
                        Label(season.title, systemImage: "rectangle.stack")
                    }
                }
            } else if item.isSeason {
                ForEach(DownloadQualities.all) { quality in
                    Button("This Season · \(quality.label)") {
                        Task { await requestDownload(episodes, quality: quality) }
                    }
                }
            } else {
                if existing?.status == .complete {
                    #if os(macOS)
                    if let existing, let url = DownloadManager.shared.mediaURL(for: existing) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }
                    #endif
                    Button("Delete Download", role: .destructive) {
                        DownloadManager.shared.delete(item.Id)
                        app.toast("Download deleted", tone: .ok)
                    }
                } else {
                    ForEach(DownloadQualities.all) { quality in
                        Button(quality.label) {
                            Task { await requestDownload([item], quality: quality) }
                        }
                    }
                }
            }
        } label: {
            #if os(macOS)
            // While a transfer runs the button is its progress, the way
            // Safari's downloads button fills up: a determinate ring in place
            // of the glyph, and the words in the tooltip.
            if existing?.status == .downloading, let fraction = existing?.fraction {
                Label {
                    Text("Downloading…")
                } icon: {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            } else {
                Label(downloadLabel(existing), systemImage: downloadSymbol(existing))
            }
            #else
            Label(downloadLabel(existing), systemImage: downloadSymbol(existing))
            #endif
        }
    }

    private func downloadLabel(_ record: DownloadRecord?) -> String {
        switch record?.status {
        case .complete: "Downloaded"
        case .downloading: "Downloading…"
        case .error: "Download Failed"
        default: "Download"
        }
    }

    private func downloadSymbol(_ record: DownloadRecord?) -> String {
        switch record?.status {
        case .complete: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle.dotted"
        case .error: "exclamationmark.circle"
        default: "arrow.down.circle"
        }
    }
    #endif

    // MARK: - Seasons and episodes

    /// A show's seasons, each as its own poster and each opening a page of its
    /// own. The chips-and-a-list arrangement this replaces put one season's
    /// episodes on the show's page and hid the rest behind a control that
    /// looked like a filter — with no season artwork anywhere.
    @ViewBuilder
    private var seasonsSection: some View {
        if !seasons.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                Text("Seasons")
                    .font(shelfTitleFont)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal, showsIndicators: Self.showsShelfIndicators) {
                    LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                        ForEach(seasons) { season in
                            Button {
                                app.push(.item(season.Id))
                            } label: {
                                PosterCard(
                                    item: season,
                                    width: Metrics.posterWidth,
                                    subtitle: episodeCount(season)
                                )
                            }
                            .buttonStyle(PosterButtonStyle())
                            .itemContextMenu(season)
                            .macOpensOnReturn { app.push(.item(season.Id)) }
                            .help(season.title)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.shelfCardPadding)
                }
                .focusRegion()
            }
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        #if os(macOS)
        // A list, with everything a list has — see `MacEpisodeList`.
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Episodes")
                    .font(shelfTitleFont)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Metrics.gutter)
                    .id(Self.episodesAnchor)
                MacEpisodeList(episodes: episodes, selection: $episodeSelection) { episode in
                    Task { await player.play(item: episode) }
                } onOpen: { episode in
                    app.push(.item(episode.Id))
                } onMarkWatched: { ids, played in
                    Task { await markWatched(ids, played: played) }
                }
            }
            .focusRegion()
        }
        #else
        episodeStack {
            if !episodes.isEmpty {
                Text("Episodes")
                    .font(shelfTitleFont)
                    .foregroundStyle(Theme.text)
            }
            ForEach(episodes) { episode in
                #if os(tvOS)
                EpisodeRow(episode: episode) {
                    Task { await player.play(item: episode) }
                } onOpen: {
                    app.push(.item(episode.Id))
                }
                .focused($focus, equals: .episode(episode.Id))
                #else
                EpisodeRow(episode: episode, isHighlighted: episodeHighlight == episode.Id) {
                    Task { await player.play(item: episode) }
                } onOpen: {
                    app.push(.item(episode.Id))
                }
                // Named so the arrival can scroll to it — see `scroll`.
                .id(episode.Id)
                #endif
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .focusRegion()
        #endif
    }

    #if os(macOS)
    /// The list's context menu acting on a selection: every row it names,
    /// then one reload for the lot. `toggleWatched` is for the page's own
    /// item and rewrites its copy; the rows are the server's to correct.
    private func markWatched(_ ids: Set<String>, played: Bool) async {
        var failed = false
        for id in ids {
            do {
                try await client.markPlayed(id, played: played)
            } catch {
                failed = true
            }
        }
        if failed {
            app.presentAlert(
                title: "Couldn't Update Watched State",
                message: "The server didn't accept the change for every episode."
            )
        }
        ItemMutations.shared.changed()
    }
    #endif

    /// The Mac shows a shelf's scroller, because a pointer has nothing to
    /// drag with otherwise; a finger and a remote don't need one.
    private static var showsShelfIndicators: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Lazy off the television: a season can be twenty-odd rows, each with a
    /// still, and they were all built — and their pictures all asked for — as
    /// the page opened. A television keeps the eager stack, for the focus
    /// reasons this page's `scroll` gives.
    @ViewBuilder
    private func episodeStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 14, content: content)
        #else
        LazyVStack(alignment: .leading, spacing: 14, content: content)
        #endif
    }

    private var shelfTitleFont: Font {
        #if os(iOS)
        return .headline
        #else
        return .title3.weight(.semibold)
        #endif
    }

    private func episodeCount(_ season: BaseItem) -> String {
        let n = season.ChildCount ?? season.RecursiveItemCount ?? 0
        guard n > 0 else { return "" }
        return "\(n) episode\(n == 1 ? "" : "s")"
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(_ item: BaseItem) -> some View {
        let cast = mergedCast(item.People ?? []).prefix(24)
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cast & Crew")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Metrics.gutter)
                ScrollView(.horizontal, showsIndicators: Self.showsShelfIndicators) {
                    // Lazy, like the season row above it: a film's cast is
                    // two dozen headshots, and only the first few are on
                    // screen until the row is scrolled.
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(cast)) { person in
                            Button {
                                openPerson(person)
                            } label: {
                                VStack(spacing: 6) {
                                    RemoteImage(url: Artwork.person(person, width: 200))
                                        .frame(width: 78, height: 78)
                                        .clipShape(Circle())
                                    Text(person.Name ?? "")
                                        .font(.caption.weight(.medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .foregroundStyle(Theme.text)
                                    Text(person.Role ?? person.type ?? "")
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .foregroundStyle(Theme.textDim)
                                }
                                .frame(width: 108)
                            }
                            .rowButtonStyle()
                            .macOpensOnReturn { openPerson(person) }
                            .help(castHelp(person))
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    #if os(macOS)
                    // Room for the hover fill to sit outside the tile.
                    .padding(.vertical, Metrics.shelfCardPadding)
                    #endif
                }
                .focusRegion()
            }
        }
    }

    /// Their own page where the server knows who they are; a name with no id
    /// behind it can still search for itself, as on Linux.
    private func openPerson(_ person: Person) {
        if let id = person.Id, !id.isEmpty {
            app.push(.person(id: id, name: person.Name ?? ""))
        } else {
            app.push(.search(person.Name ?? ""))
        }
    }

    /// "Jeremy Allen White — Carmy", whole, for the tile that truncates both.
    private func castHelp(_ person: Person) -> String {
        let name = person.Name ?? ""
        guard let role = person.Role ?? person.type, !role.isEmpty else { return name }
        return "\(name) — \(role)"
    }

    /// One entry per person. The same person can be both director and actor,
    /// and two rows with one id break the ForEach, so their parts are joined.
    private func mergedCast(_ people: [Person]) -> [Person] {
        var merged: [Person] = []
        var index: [String: Int] = [:]
        for person in people where person.Name?.isEmpty == false {
            guard let i = index[person.id] else {
                index[person.id] = merged.count
                merged.append(person)
                continue
            }
            let parts = [merged[i].Role ?? merged[i].type, person.Role ?? person.type]
                .compactMap { $0 }.filter { !$0.isEmpty }
            var seen = Set<String>()
            merged[i].Role = parts.filter { seen.insert($0).inserted }.joined(separator: ", ")
        }
        return merged
    }

    // MARK: - Loading

    /// Everything that belonged to the previous item, dropped.
    private func resetForNewItem() {
        loadedId = itemId
        item = nil
        seasons = []
        episodes = []
        similar = []
        similarLoadedFor = nil
        nextUp = nil
        error = nil
        scrolledPastHero = false
        #if !os(tvOS)
        episodeHighlight = nil
        #endif
        #if os(macOS)
        episodeSelection = []
        #endif
        #if os(tvOS)
        qualityChoice = nil
        placedFocus = false
        #endif
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        // Drawn from the library copy straight away where there is one; the
        // server's answer replaces it when it arrives.
        if item == nil, let local = LibraryIndex.shared.item(itemId) {
            item = local
            if local.isSeries {
                seasons = LibraryIndex.shared.seasons(seriesId: itemId) ?? []
            } else if local.isSeason, let seriesId = local.SeriesId ?? local.ParentId {
                episodes = LibraryIndex.shared.episodes(seriesId: seriesId, seasonId: itemId) ?? []
            }
        }
        do {
            let loaded = try await client.item(itemId)
            // A task superseded by another item's must not write over it.
            guard !Task.isCancelled else { return }
            item = loaded
            // The rest side by side, not one after another: none of them
            // depends on another, and the page waited on their sum. More Like
            // This is left alone on a reload of the same title — after playback
            // or a change from a menu — since nothing about it depends on what
            // has been watched.
            async let similarItems = similarIfNeeded(for: itemId)
            if loaded.isSeries {
                async let seasonList = try? client.seasons(seriesId: itemId)
                async let next = try? client.seriesNextUp(seriesId: itemId)
                let (foundSeasons, foundNext) = await (seasonList, next)
                guard !Task.isCancelled else { return }
                seasons = foundSeasons ?? []
                nextUp = foundNext ?? nil
            } else if loaded.isSeason, let seriesId = loaded.SeriesId ?? loaded.ParentId {
                await loadEpisodes(seriesId: seriesId, seasonId: loaded.Id)
            }
            if let found = await similarItems {
                guard !Task.isCancelled else { return }
                similar = found
                similarLoadedFor = itemId
            }
        } catch is CancellationError {
            // Left for another item or page; nothing to report.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Nil when this title's list is already on the page.
    private func similarIfNeeded(for id: String) async -> [BaseItem]? {
        guard similarLoadedFor != id else { return nil }
        return (try? await client.similar(to: id)) ?? []
    }

    private func loadEpisodes(seriesId: String, seasonId: String?) async {
        episodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? []
    }

    // MARK: - Actions

    /// A trailer file on the server plays in the app's own player, like
    /// anything else. One that is only an address on the web is handed to
    /// whatever opens it — see `Trailers.open`.
    private func playTrailer(_ item: BaseItem) async {
        if (item.LocalTrailerCount ?? 0) > 0, let local = await client.localTrailers(for: item.Id).first {
            await player.play(item: local)
            return
        }
        guard let url = Trailers.remote(item) else {
            app.toast("That trailer couldn't be found", tone: .error)
            return
        }
        #if os(macOS)
        // The environment's opener rather than NSWorkspace directly: it is
        // what the rest of SwiftUI's links go through, and a window that
        // wants to intercept links can.
        openURL(url)
        #else
        if await !Trailers.open(url) {
            app.toast("This trailer is on YouTube, and there is nothing here to open it with", tone: .error)
        }
        #endif
    }

    private func toggleFavourite(_ item: BaseItem) async {
        let next = !item.userData.isFavorite
        do {
            try await client.setFavorite(item.Id, favorite: next)
            updateUserData(of: item.Id) { $0.IsFavorite = next }
        } catch {
            app.toast("Couldn't update favorites", tone: .error)
        }
    }

    private func toggleWatched(_ item: BaseItem) async {
        let next = !item.userData.played
        do {
            try await client.markPlayed(item.Id, played: next)
            updateUserData(of: item.Id) {
                $0.Played = next
                $0.PlaybackPositionTicks = 0
            }
        } catch {
            app.toast("Couldn't update watched state", tone: .error)
        }
    }

    /// Applies a change to the page's item as it is *now*, not as it was when
    /// the button was pressed. Each toggle awaits the server; one that wrote
    /// back the copy it started with undid whatever the other had finished in
    /// the meantime — Favorite then Mark watched in quick succession left the
    /// page showing only one of them, although the server had both.
    private func updateUserData(of id: String, _ change: (inout UserData) -> Void) {
        guard var current = self.item, current.Id == id else { return }
        var data = current.userData
        change(&data)
        current.UserData = data
        self.item = current
    }

    // MARK: - Downloads

    #if !os(tvOS)
    /// Gate a download on the disk having room for it. Anything unknowable
    /// queues as before: this exists to catch the obvious failure, not to become
    /// a new way to fail.
    private func requestDownload(_ items: [BaseItem], quality: DownloadQuality) async {
        let fresh = items.filter {
            DownloadManager.shared.record(for: $0.Id)?.status != .complete
                && !DownloadManager.shared.isQueuedOrRunning($0.Id)
        }
        guard !fresh.isEmpty else {
            app.toast("Already downloaded", tone: .ok)
            return
        }
        if let verdict = DownloadManager.checkSpace(for: fresh, quality: quality), !verdict.fits {
            spacePrompt = SpacePrompt(items: fresh, requested: quality, verdict: verdict)
            return
        }
        queue(fresh, quality: quality)
    }

    /// One season of a series, from the show's own download menu — the season
    /// pages have their own, which spends nothing on a request because their
    /// episodes are already on screen.
    private func requestSeasonDownload(series: BaseItem, season: BaseItem, quality: DownloadQuality) async {
        let list = (try? await client.episodes(seriesId: series.Id, seasonId: season.Id)) ?? []
        guard !list.isEmpty else {
            app.toast("No episodes found for \(season.title)", tone: .error)
            return
        }
        await requestDownload(list, quality: quality)
    }

    private func requestSeriesDownload(_ series: BaseItem, quality: DownloadQuality) async {
        var all: [BaseItem] = []
        let allSeasons = seasons.isEmpty ? ((try? await client.seasons(seriesId: series.Id)) ?? []) : seasons
        for season in allSeasons {
            all += (try? await client.episodes(seriesId: series.Id, seasonId: season.Id)) ?? []
        }
        guard !all.isEmpty else {
            app.toast("No episodes found for this series", tone: .error)
            return
        }
        await requestDownload(all, quality: quality)
    }

    private func queue(_ items: [BaseItem], quality: DownloadQuality) {
        let result = DownloadManager.shared.enqueue(items: items, quality: quality)
        if result.queued > 0 {
            app.toast(
                "Queued \(result.queued) item\(result.queued == 1 ? "" : "s") · \(quality.label)"
                    + (result.skipped > 0 ? " (\(result.skipped) already there)" : ""),
                tone: .ok
            )
        } else if result.skipped > 0 {
            app.toast("Everything is already downloaded or queued", tone: .ok)
        }
    }
    #endif
}

// MARK: - Episode row

struct EpisodeRow: View {
    let episode: BaseItem
    /// Marks the one row the page was opened *for* — what Next Up sends you to.
    /// A television places the selector on it instead; this is the same idea for
    /// a screen with no selector to place. See `ItemDetailView.episodeHighlight`.
    var isHighlighted: Bool = false
    var onPlay: () -> Void
    var onOpen: () -> Void

    // A row on tvOS is a single focus target: a button inside it can be drawn
    // but never reached, so the play button that works with a finger is dead
    // weight with a remote. Pressing the row plays the episode there — which is
    // what a play glyph on a television promises anyway — and the detail page
    // moves to the row's own menu.
    var body: some View {
        #if os(tvOS)
        Button(action: onPlay) { rowContent }
            .rowButtonStyle()
            .itemContextMenu(episode, allowsOpen: true)
        #else
        Button(action: onOpen) { rowContent }
            .rowButtonStyle()
            .background { marker }
            .itemContextMenu(episode)
        #endif
    }

    #if !os(tvOS)
    /// The wash behind a row that was pointed at. Drawn behind rather than
    /// around it, and bled out past the row's own bounds, so it reads as the
    /// row being lit rather than as a box that has appeared around it — the
    /// list has no other boxes in it.
    private var marker: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.accentSoft)
            .padding(.horizontal, -10)
            .padding(.vertical, -8)
            .opacity(isHighlighted ? 1 : 0)
    }
    #endif

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottom) {
                RemoteImage(
                    url: Artwork.url(episode, type: "Primary", width: 400),
                    blurHash: Artwork.hash(episode)
                )
                .frame(width: 148, height: 83)
                if let progress = episode.progressFraction {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.45))
                        Rectangle().fill(Theme.accent)
                            .scaleEffect(x: min(1, max(0, progress)), y: 1, anchor: .leading)
                    }
                    .frame(height: 3)
                }
            }
            .frame(width: 148, height: 83)
            .cardChrome(radius: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let number = episode.IndexNumber {
                        Text("\(number).")
                            .foregroundStyle(Theme.textDim)
                    }
                    Text(episode.title)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.text)
                    if episode.userData.played {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .lineLimit(1)

                Text(Format.ticks(episode.RunTimeTicks))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)

                if let overview = episode.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundStyle(Theme.textBody)
                }
            }

            Spacer(minLength: 8)

            playGlyph
        }
        .contentShape(Rectangle())
    }

    /// A control where one can be pressed, and the same shape as a label where
    /// the row itself is the control.
    @ViewBuilder
    private var playGlyph: some View {
        #if os(tvOS)
        Image(systemName: "play.circle.fill")
            .font(.title2)
            .foregroundStyle(Theme.accent)
        #else
        Button(action: onPlay) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Disk space prompt

#if !os(tvOS)
struct SpacePrompt: Identifiable {
    let id = UUID()
    var items: [BaseItem]
    var requested: DownloadQuality
    var verdict: DownloadManager.SpaceVerdict
}

/// "That won't fit, and here is what would." The Linux build showed the same
/// numbers and the same rungs.
struct SpacePromptView: View {
    let prompt: SpacePrompt
    var onChoose: (DownloadQuality?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Not enough disk space")
                .font(.title2.weight(.semibold))
            Text("\(prompt.items.count) item\(prompt.items.count == 1 ? "" : "s") at \(prompt.requested.label) needs about \(Format.bytes(prompt.verdict.needed)), and there is \(Format.bytes(prompt.verdict.free)) free where downloads are kept.")
                .font(.subheadline)
                .foregroundStyle(Theme.textBody)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(prompt.verdict.alternatives) { alternative in
                Button {
                    onChoose(alternative)
                } label: {
                    let size = DownloadManager.estimateTotal(prompt.items, quality: alternative)
                    Text("Use \(alternative.label)" + (size.map { " (~\(Format.bytes($0)))" } ?? ""))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentStrong)
            }

            Button("Download anyway", role: .destructive) { onChoose(prompt.requested) }
            Button("Cancel", role: .cancel) { onChoose(nil) }
        }
        .padding(24)
        .frame(maxWidth: 480)
    }
}
#endif

#if !os(tvOS)
/// Hands its content the download record for one item, reading it in a body
/// of its own so that only this redraws when the downloads change.
private struct WithDownloadRecord<Content: View>: View {
    let itemId: String
    @ViewBuilder let content: (DownloadRecord?) -> Content

    var body: some View {
        content(DownloadManager.shared.record(for: itemId))
    }
}
#endif
