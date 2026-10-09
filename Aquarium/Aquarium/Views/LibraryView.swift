//  A library: a grid with sorting, filtering and paging, the same controls the
//  Linux build put in its filter bar.
//
//  The filter bar is not drawn on tvOS. Every chip in it is a menu or a toggle
//  that has to be reached with a directional pad before the grid can be, and it
//  sits between the page's heading and the first row of posters — so arriving
//  at a library meant pressing down past four controls nobody had asked for.
//  The state behind it stays where it is, defaulted, so `filterKey` and
//  `query` are unchanged and the bar can come back a chip at a time.
//
//  On the Mac the controls are the window's toolbar, the filters are
//  remembered per library, the toolbar's search field narrows the library,
//  and the grid is a selection that the toolbar can act on — see
//  `LibraryView+Mac.swift` for the parts that only exist there.

import SwiftUI

struct LibraryView: View {
    let parentId: String
    let title: String
    var collectionType: String?

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var genres: [String] = []
    /// Which type filter `genres` was fetched under.
    @State private var genresType: String?
    @State private var isLoading = false
    @State private var isPaging = false
    @State private var error: String?

    @State private var sort: SortOption = .name
    @State private var unwatchedOnly = false
    @State private var favouritesOnly = false
    @State private var genre: String?
    /// The sort run the other way from its natural direction — set by clicking
    /// a column heading twice in the Mac's list view.
    @State private var reversed = false
    #if os(macOS)
    /// Posters or a list; remembered across libraries and launches.
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .grid
    /// What is typed in the toolbar's search field, and the copy of it the
    /// query is made from: the field changes on every keystroke, the query
    /// a moment after the last one, so a name typed out is one request and
    /// not one per letter.
    @State private var searchTerm = ""
    @State private var activeSearchTerm = ""
    /// The tiles or rows selected, shared by the grid and the table so a
    /// selection survives switching between them. The toolbar acts on it.
    @State private var selection: Set<String> = []
    @Environment(PlayerModel.self) private var player
    @Environment(\.openWindow) private var openWindow
    #endif

    #if os(macOS)
    /// What the Item menu does to the selection when it is one title. Several
    /// have the toolbar's selection menu instead.
    private var selectedItemActions: ItemMenuActions? {
        guard selection.count == 1, let item = items.first(where: { selection.contains($0.Id) }) else { return nil }
        // A show or a season has nothing of its own to play; its page does
        // the working out of which episode is next.
        let playable = !item.isFolderLike
        return ItemMenuActions(
            title: item.title,
            canPlay: playable,
            playLabel: item.progressFraction != nil ? "Resume" : "Play",
            isFavorite: item.userData.isFavorite,
            isWatched: item.isSeries ? nil : item.userData.played,
            play: {
                guard playable else { return }
                Task { await player.play(item: item) }
            },
            toggleFavorite: {
                Task {
                    do {
                        try await client.setFavorite(item.Id, favorite: !item.userData.isFavorite)
                        ItemMutations.shared.changed()
                    } catch {
                        app.toast("Couldn't update favorites", tone: .error)
                    }
                }
            },
            toggleWatched: {
                Task {
                    do {
                        try await client.markPlayed(item.Id, played: !item.userData.played)
                        ItemMutations.shared.changed()
                    } catch {
                        app.toast("Couldn't update watched state", tone: .error)
                    }
                }
            },
            openInNewWindow: { openWindow(id: ItemWindow.id, value: item.Id) }
        )
    }
    #endif

    /// Pages asked for so far. This, not the item count, is what ends paging:
    /// a page that adds nothing new would never move the count to the total.
    @State private var pagesLoaded = 0
    /// Bumped by every reload, so an answer to an older one — a late page, or a
    /// reload that was cancelled — can tell it has been overtaken.
    @State private var generation = 0
    /// What "Random" is shuffled by until the list is asked for again. The
    /// server's own random sort reshuffles on every page, which repeated items
    /// and left others unreachable; instead the pages come in a fixed order,
    /// visited in a shuffled sequence and each shuffled within itself.
    @State private var shuffleSeed: UInt64 = 0
    #if os(iOS)
    /// The letter index's jump under way: a drag along the strip lands on
    /// several letters, and only the last one's is wanted.
    @State private var jumpTask: Task<Void, Never>?
    #endif

    private static let pageSize = 60

    init(parentId: String, title: String, collectionType: String? = nil) {
        self.parentId = parentId
        self.title = title
        self.collectionType = collectionType
        #if os(macOS)
        // The controls the library was left on, if it has been visited
        // before. Set here rather than after the page appears, so the first
        // request is the right one and not the default followed by a second.
        let saved = LibraryFilters.load(for: parentId)
        _sort = State(initialValue: saved.sort)
        _reversed = State(initialValue: saved.reversed)
        _unwatchedOnly = State(initialValue: saved.unwatchedOnly)
        _favouritesOnly = State(initialValue: saved.favouritesOnly)
        _genre = State(initialValue: saved.genre)
        #endif
    }

    enum SortOption: String, CaseIterable, Identifiable, Codable {
        case name, dateAdded, releaseDate, rating, runtime, random
        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Recently Added"
            case .releaseDate: "Release Date"
            case .rating: "Rating"
            case .runtime: "Runtime"
            case .random: "Random"
            }
        }

        var field: String {
            switch self {
            case .name: "SortName"
            case .dateAdded: "DateCreated"
            case .releaseDate: "PremiereDate"
            case .rating: "CommunityRating"
            case .runtime: "Runtime"
            case .random: "Random"
            }
        }

        /// `field` with the name after it, for sorts where many items share a
        /// value — a batch added in the same second, a year of releases, no
        /// rating at all. Without it the server is free to order those
        /// differently for each page, so one page repeats what the last had
        /// and skips others, and the list stops short of its total.
        var tiebroken: String {
            switch self {
            case .name, .random: field
            default: "\(field),SortName"
            }
        }

        var order: String {
            switch self {
            case .name, .runtime: "Ascending"
            default: "Descending"
            }
        }
    }

    /// A library reached from the sidebar knows what kind it is; one pushed onto
    /// a stack used not to carry it, which is what put loose episodes and
    /// seasons in among the shows — a recursive query with no type filter
    /// returns every level of the tree at once. The shell's own list of
    /// libraries is the answer either way, so it is asked whenever the caller
    /// didn't say.
    private var resolvedCollectionType: String? {
        collectionType ?? app.libraries.first { $0.Id == parentId }?.CollectionType
    }

    /// A television library lists shows and nothing else: a season belongs
    /// inside its series and an episode inside its season, which is the path
    /// the detail pages now take you down.
    private var includeTypes: String? {
        switch resolvedCollectionType {
        case "movies": "Movie"
        case "tvshows": "Series"
        default: nil
        }
    }

    var body: some View {
        page
        .screenTitle(title)
        .paletteBar()
        #if os(macOS)
        .toolbar { macToolbar }
        .navigationSubtitle(total > 0 ? "\(total) item\(total == 1 ? "" : "s")" : "")
        // The filter, in the toolbar's own search field — a second one beside
        // the sidebar's, which searches the whole server; this one narrows
        // the library in front of you. Live TV keeps its channel filter the
        // same way.
        .searchable(text: $searchTerm, placement: .toolbar, prompt: "Filter \(title)")
        .task(id: searchTerm) {
            // Wait for the typing to pause before asking.
            if !searchTerm.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            activeSearchTerm = searchTerm
        }
        // View ▸ Refresh (⌘R), and the app coming back to the front.
        .onChange(of: MacCommandRequests.shared.refresh) { _, _ in
            Task { await reload() }
        }
        // The controls are the library's to remember — see `LibraryFilters`.
        .onChange(of: currentFilters) { _, filters in
            filters.save(for: parentId)
        }
        // A page reloaded or filtered: nothing selected that isn't there.
        // The grid does this for its own selection; the table's is ours.
        .onChange(of: items.map(\.Id)) { _, ids in
            let present = Set(ids)
            if !selection.isSubset(of: present) { selection = selection.intersection(present) }
        }
        // The Item menu, for the one title selected. Only a title's own page
        // published it, so with a film picked out in the grid — "1 Selected"
        // in the toolbar — Item ▸ Play, ⌘D and ⌥⌘O were all greyed out.
        .focusedSceneValue(\.itemMenuActions, selectedItemActions)
        #endif
        #if os(iOS)
        // The filter bar is the one place in the app where a tap changes what
        // the whole page says without moving anything under your finger.
        .sensoryFeedback(.selection, trigger: filterKey)
        #endif
        // "Unwatched only" and "Favorites only" are both filters a press-and-
        // hold menu can knock an item out of from the grid itself.
        .reloadWhenItemsChange { await reload() }
        .task(id: filterKey) { await reload() }
        // The sidebar keeps this view and hands it another library, so what was
        // chosen for the last one would otherwise carry over to this one.
        .onChange(of: parentId) {
            items = []
            total = 0
            pagesLoaded = 0
            error = nil
            genres = []
            genresType = nil
            #if os(macOS)
            // The new library's own controls, not the last one's and not the
            // defaults. The search is the one thing that starts over.
            let saved = LibraryFilters.load(for: parentId)
            genre = saved.genre
            sort = saved.sort
            reversed = saved.reversed
            unwatchedOnly = saved.unwatchedOnly
            favouritesOnly = saved.favouritesOnly
            searchTerm = ""
            activeSearchTerm = ""
            selection = []
            #else
            genre = nil
            sort = .name
            reversed = false
            unwatchedOnly = false
            favouritesOnly = false
            #endif
        }
    }

    @ViewBuilder
    private var page: some View {
        #if os(macOS)
        if layout == .list {
            // A list loads behind a spinner, not behind poster skeletons —
            // the shape of what is coming is a table, and a spinner in the
            // toolbar is what a Mac list shows while it fills.
            if isLoading, items.isEmpty {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, items.isEmpty {
                ErrorState(error: error) { Task { await reload() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryTable(
                    items: items,
                    sort: $sort,
                    reversed: $reversed,
                    selection: $selection,
                    onOpen: { app.push(.item($0.Id)) },
                    onReachEnd: { Task { await loadMore() } }
                )
            }
        } else {
            grid
        }
        #else
        grid
        #endif
    }

    private var grid: some View {
        #if os(iOS)
        ScrollViewReader { proxy in
            gridScroll
                .letterIndex(shown: showsLetterIndex) { letter in jump(to: letter, proxy: proxy) }
        }
        #else
        gridScroll
        #endif
    }

    private var gridScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(tvOS)
                // The library's name, which on every other platform is in the
                // navigation bar. There isn't one worth using here — see
                // `screenTitle` — so it is the first thing in the page instead,
                // and scrolls away with the first row of posters.
                PageHeading(title: title)
                #endif
                #if !os(macOS)
                // The Mac has these in the window's toolbar — see `macToolbar`.
                filterBar
                    .hiddenOnTV()
                #endif
                if isLoading, items.isEmpty {
                    // The grid this is about to become, rather than a spinner
                    // in the middle of an empty screen.
                    SkeletonGrid(count: 12)
                } else if let error, items.isEmpty {
                    ErrorState(error: error) { Task { await reload() } }
                } else if items.isEmpty {
                    emptyState
                } else {
                    MediaGrid(
                        items: items,
                        pendingCount: isPaging ? pendingTileCount : 0,
                        onSelect: { app.push(.item($0.Id)) },
                        onReachEnd: { Task { await loadMore() } },
                        selection: gridSelection
                    )
                    #if os(macOS)
                    // The window's subtitle already says how many there are.
                    Color.clear.frame(height: 24)
                    #else
                    Text("\(items.count) of \(total)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    #endif
                }
            }
            .padding(.top, 8)
        }
    }

    #if os(iOS)
    /// The strip is only honest on the name order, and only worth having on
    /// a list too long to flick through.
    private var showsLetterIndex: Bool {
        sort == .name && !reversed && error == nil && items.count >= LetterIndex.minimumCount
    }

    private func jump(to letter: String, proxy: ScrollViewProxy) {
        jumpTask?.cancel()
        jumpTask = Task {
            guard let id = await target(for: letter), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
        }
    }

    /// The item the strip should land on: the first at or after the letter.
    /// Past what is loaded, the server says how many names come before the
    /// letter, and the pages up to there are fetched in one go.
    private func target(for letter: String) async -> String? {
        if let hit = LetterIndex.first(in: items, atOrAfter: letter) { return hit.Id }
        guard items.count < total, !isLoading else { return items.last?.Id }
        var q = query(startIndex: 0, limit: 1)
        q.nameLessThan = letter
        guard let before = try? await fetch(q).total, !Task.isCancelled else { return nil }
        await load(through: before)
        guard !Task.isCancelled else { return nil }
        return LetterIndex.first(in: items, atOrAfter: letter)?.Id ?? items.last?.Id
    }

    /// Everything from the end of what is loaded through the page that holds
    /// `offset`, as one request, so the grid stays one unbroken list.
    private func load(through offset: Int) async {
        guard offset >= items.count, !isPaging else { return }
        let mine = generation
        isPaging = true
        defer { isPaging = false }
        let need = min(total, offset + Self.pageSize) - items.count
        guard need > 0, let response = try? await fetch(query(startIndex: items.count, limit: need)), mine == generation else { return }
        let known = Set(items.map(\.Id))
        items += response.items.filter { !known.contains($0.Id) }
        total = response.total
        // Rounded down: the next page `loadMore` asks for overlaps the tail
        // of this one rather than skipping past it, and repeats are dropped.
        pagesLoaded = max(pagesLoaded, items.count / Self.pageSize)
    }
    #endif

    /// The grid's selection is the page's on the Mac, so the toolbar can act
    /// on it; elsewhere the grid has none.
    private var gridSelection: Binding<Set<String>>? {
        #if os(macOS)
        $selection
        #else
        nil
        #endif
    }

    /// An empty library, or filters and a search that left nothing of it —
    /// two different pages, since one has a way out and the other hasn't.
    @ViewBuilder
    private var emptyState: some View {
        #if os(macOS)
        if hasFilters || !activeSearchTerm.isEmpty {
            LibraryNoResults(searchTerm: activeSearchTerm, hasFilters: hasFilters) {
                clearFilters()
                searchTerm = ""
                activeSearchTerm = ""
            }
        } else {
            EmptyState(symbol: "film.stack", title: "Nothing Here", message: emptyMessage)
        }
        #else
        EmptyState(
            symbol: emptySymbol,
            title: "Nothing here",
            message: emptyMessage,
            actionTitle: hasFilters ? "Clear Filters" : nil
        ) {
            clearFilters()
        }
        #endif
    }

    private func clearFilters() {
        unwatchedOnly = false
        favouritesOnly = false
        genre = nil
    }

    /// A filter glyph would be pointing at a bar that isn't drawn on a
    /// television.
    private var emptySymbol: String {
        #if os(tvOS)
        "film.stack"
        #else
        "line.3.horizontal.decrease.circle"
        #endif
    }

    /// What an empty grid says. There is no filter bar on a television to point
    /// at, so it can't be blamed for the library being empty there.
    private var emptyMessage: String {
        #if os(tvOS) || os(macOS)
        "This library has nothing in it yet."
        #else
        // Only blamed on the filters when one is on; an empty library with
        // none set was told it didn't match them.
        hasFilters
            ? "No items in this library match the filters above."
            : "This library has nothing in it yet."
        #endif
    }

    /// How many ghost tiles a page in flight is worth: what is actually still to
    /// come, capped so a large library doesn't draw a screenful of them.
    private var pendingTileCount: Int {
        min(max(0, total - items.count), 12)
    }

    /// Every control that changes what is asked for, as one value, so the task
    /// re-runs on any of them without a listener per control. The type filter is
    /// in it because it can arrive late — the shell may still be fetching the
    /// libraries when this screen first asks.
    private var filterKey: String {
        var key = "\(parentId)|\(includeTypes ?? "")|\(sort.rawValue)|\(reversed)|\(unwatchedOnly)|\(favouritesOnly)|\(genre ?? "")"
        #if os(macOS)
        key += "|\(activeSearchTerm)"
        #endif
        return key
    }

    private var hasFilters: Bool { unwatchedOnly || favouritesOnly || genre != nil }

    #if os(macOS)
    enum LibraryLayout: String { case grid, list }

    /// The controls as one value, for remembering — see `LibraryFilters`.
    private var currentFilters: LibraryFilters {
        LibraryFilters(
            sort: sort, reversed: reversed, unwatchedOnly: unwatchedOnly,
            favouritesOnly: favouritesOnly, genre: genre
        )
    }

    /// The View menu's thumbnail size, as a slider for the toolbar. Same
    /// value, so Bigger and Smaller in the menu bar move the slider too.
    private var thumbnailSize: Binding<Double> {
        Binding(
            get: { MacViewOptions.shared.thumbnailSize },
            set: { MacViewOptions.shared.thumbnailSize = $0 }
        )
    }

    /// The filter bar, as the window's toolbar: the view switch, the
    /// thumbnail size, sorting, the two filters as toggles, the genre menu,
    /// and — while anything is selected — what can be done to the selection.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        if isLoading || isPaging, !items.isEmpty {
            // Asking again with the page still up: the small spinner a Mac
            // toolbar shows, rather than replacing the page with skeletons.
            ToolbarItem(placement: .status) {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading…")
            }
        }
        if !selection.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                LibrarySelectionToolbarMenu(items: items, selection: selection)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Show as posters or as a list")
        }
        if layout == .grid {
            ToolbarItem(placement: .primaryAction) {
                // The ends are buttons of our own rather than the slider's
                // value labels. AppKit makes those into step buttons too, but
                // SwiftUI named both of them after the first — "Photo", and
                // then "Smaller" twice — so VoiceOver couldn't tell them
                // apart. These say what they do and follow View ▸ Bigger and
                // Smaller, which they are.
                HStack(spacing: 4) {
                    Button { MacViewOptions.shared.smaller() } label: {
                        Image(systemName: "photo").imageScale(.small)
                    }
                    .disabled(!MacViewOptions.shared.canShrink)
                    .help("Smaller (⌘-)")
                    .accessibilityLabel("Smaller")
                    Slider(value: thumbnailSize, in: MacViewOptions.range) {
                        Text("Thumbnail Size")
                    }
                    .labelsHidden()
                    .help("Thumbnail Size")
                    Button { MacViewOptions.shared.bigger() } label: {
                        Image(systemName: "photo").imageScale(.large)
                    }
                    .disabled(!MacViewOptions.shared.canGrow)
                    .help("Bigger (⌘=)")
                    .accessibilityLabel("Bigger")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(width: 150)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortOption.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Reverse Order", isOn: $reversed)
                    .disabled(sort == .random)
            } label: {
                Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort by \(sort.label.lowercased())")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $unwatchedOnly) {
                Label("Unwatched", systemImage: "eye.slash")
            }
            .help("Show only what you haven't watched")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $favouritesOnly) {
                Label("Favorites", systemImage: "star")
            }
            .help("Show only favorites")
        }
        if !genres.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // One genre at a time, so a picker and not a row of
                    // toggles: the check moves rather than adding up.
                    Picker("Genre", selection: $genre) {
                        Text("All Genres").tag(String?.none)
                        Divider()
                        ForEach(genres, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(genre ?? "Genre", systemImage: genre == nil ? "tag" : "tag.fill")
                }
                .help("Filter by genre")
            }
        }
    }
    #endif

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortOption.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    chip(label: "Sort: \(sort.label)", symbol: "arrow.up.arrow.down", active: false)
                }

                Button { unwatchedOnly.toggle() } label: {
                    chip(label: "Unwatched", symbol: "eye.slash", active: unwatchedOnly)
                }
                .chipButtonStyle()

                Button { favouritesOnly.toggle() } label: {
                    chip(label: "Favorites", symbol: "star", active: favouritesOnly)
                }
                .chipButtonStyle()

                if !genres.isEmpty {
                    Menu {
                        Button("All genres") { genre = nil }
                        Divider()
                        ForEach(genres, id: \.self) { name in
                            Button(name) { genre = name }
                        }
                    } label: {
                        chip(label: genre ?? "Genre", symbol: "tag", active: genre != nil)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    private func chip(label: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(label)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(active ? Theme.accentSoft : Theme.raised, in: Capsule())
        .foregroundStyle(active ? Theme.accent : Theme.textBody)
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func reload() async {
        generation += 1
        let mine = generation
        isLoading = true
        error = nil
        defer { if mine == generation { isLoading = false } }
        if sort == .random { shuffleSeed = UInt64.random(in: .min ... .max) }
        // Re-asked when the type filter resolves late, since the genres of a
        // whole tree and the genres of its shows are not the same list. Not
        // asked at all where nothing draws them — see the note at the top.
        #if !os(tvOS)
        let types = includeTypes ?? ""
        if genres.isEmpty || genresType != types {
            genresType = types
            let fetched = (try? await client.genres(parentId: parentId, includeTypes: includeTypes)) ?? []
            guard mine == generation, !Task.isCancelled else { return }
            genres = fetched
        }
        #endif
        do {
            var knownTotal: Int?
            if sort == .random {
                // The shuffled page sequence needs the page count up front.
                knownTotal = try await fetch(query(startIndex: 0, limit: 1)).total
            }
            let response = try await fetchPage(0, total: knownTotal)
            guard mine == generation, !Task.isCancelled else { return }
            items = response.items
            total = response.total
            pagesLoaded = 1
        } catch is CancellationError {
            // Overtaken by a newer reload, or the page went away.
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            items = []
        }
    }

    private func loadMore() async {
        guard !isPaging, !isLoading, pagesLoaded * Self.pageSize < total else { return }
        let mine = generation
        isPaging = true
        defer { isPaging = false }
        guard let response = try? await fetchPage(pagesLoaded, total: total) else { return }
        // A reload — a new filter, or a new library — may have replaced the
        // list underneath us; this page belongs to the old one.
        guard mine == generation else { return }
        pagesLoaded += 1
        let known = Set(items.map(\.Id))
        items += response.items.filter { !known.contains($0.Id) }
    }

    /// One page of the list. For "Random" it is a page of the name order, the
    /// pages taken in an order shuffled by `shuffleSeed` and each page shuffled
    /// too — stable for as long as the seed is, so paging neither repeats nor
    /// skips anything.
    private func fetchPage(_ page: Int, total: Int?) async throws -> (items: [BaseItem], total: Int) {
        guard sort == .random, let total else {
            let response = try await fetch(query(startIndex: page * Self.pageSize))
            return (response.items, response.total)
        }
        let pageCount = max(1, (total + Self.pageSize - 1) / Self.pageSize)
        var order = SeededGenerator(seed: shuffleSeed)
        let pages = Array(0..<pageCount).shuffled(using: &order)
        let source = pages[min(page, pageCount - 1)]
        var q = query(startIndex: source * Self.pageSize)
        q.sortBy = SortOption.name.field
        q.sortOrder = SortOption.name.order
        let response = try await fetch(q)
        var within = SeededGenerator(seed: shuffleSeed &+ UInt64(source) &+ 1)
        return (response.items.shuffled(using: &within), response.total)
    }

    /// The one place the server is asked for a page, so the Mac's search term
    /// rides along with every query — the first page, the later ones, and the
    /// count "Random" needs up front.
    private func fetch(_ q: JellyfinClient.LibraryQuery) async throws -> ItemsResponse {
        #if os(macOS)
        try await client.libraryItems(parentId: parentId, query: q, searchTerm: activeSearchTerm)
        #else
        try await client.libraryItems(parentId: parentId, query: q)
        #endif
    }

    private func query(startIndex: Int, limit: Int = LibraryView.pageSize) -> JellyfinClient.LibraryQuery {
        .init(
            startIndex: startIndex,
            limit: limit,
            includeTypes: includeTypes,
            sortBy: sort.tiebroken,
            sortOrder: reversed ? (sort.order == "Ascending" ? "Descending" : "Ascending") : sort.order,
            unwatched: unwatchedOnly,
            favorites: favouritesOnly,
            genre: genre
        )
    }
}

/// SplitMix64: a small generator that gives the same sequence for the same
/// seed, which is all a repeatable shuffle needs.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
