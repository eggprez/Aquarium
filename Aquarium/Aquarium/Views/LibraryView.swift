//  A library: a grid with sorting, filtering and paging, the same controls the
//  Linux build put in its filter bar.
//
//  The filter bar is not drawn on tvOS. Every chip in it is a menu or a toggle
//  that has to be reached with a directional pad before the grid can be, and it
//  sits between the page's heading and the first row of posters — so arriving
//  at a library meant pressing down past four controls nobody had asked for.
//  The state behind it stays where it is, defaulted, so `filterKey` and
//  `query` are unchanged and the bar can come back a chip at a time.

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

    private static let pageSize = 60

    enum SortOption: String, CaseIterable, Identifiable {
        case name, dateAdded, releaseDate, rating, runtime, random
        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Recently added"
            case .releaseDate: "Release date"
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
        #endif
        // The filter bar is the one place in the app where a tap changes what
        // the whole page says without moving anything under your finger.
        .sensoryFeedback(.selection, trigger: filterKey)
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
            genre = nil
            sort = .name
            reversed = false
            unwatchedOnly = false
            favouritesOnly = false
        }
    }

    @ViewBuilder
    private var page: some View {
        #if os(macOS)
        if layout == .list, !items.isEmpty {
            LibraryTable(
                items: items,
                sort: $sort,
                reversed: $reversed,
                onOpen: { app.push(.item($0.Id)) },
                onReachEnd: { Task { await loadMore() } }
            )
        } else {
            grid
        }
        #else
        grid
        #endif
    }

    private var grid: some View {
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
                    EmptyState(
                        symbol: emptySymbol,
                        title: "Nothing here",
                        message: emptyMessage,
                        actionTitle: hasFilters ? "Clear Filters" : nil
                    ) {
                        unwatchedOnly = false
                        favouritesOnly = false
                        genre = nil
                    }
                } else {
                    MediaGrid(items: items, pendingCount: isPaging ? pendingTileCount : 0) { item in
                        app.push(.item(item.Id))
                    } onReachEnd: {
                        Task { await loadMore() }
                    }
                    Text("\(items.count) of \(total)")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                }
            }
            .padding(.top, 8)
        }
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
        #if os(tvOS)
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
        "\(parentId)|\(includeTypes ?? "")|\(sort.rawValue)|\(reversed)|\(unwatchedOnly)|\(favouritesOnly)|\(genre ?? "")"
    }

    private var hasFilters: Bool { unwatchedOnly || favouritesOnly || genre != nil }

    #if os(macOS)
    enum LibraryLayout: String { case grid, list }

    /// The filter bar, as the window's toolbar: the view switch, sorting, the
    /// two filters as toggles, and the genre menu.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Show as posters or as a list")
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
                    Button("All Genres") { genre = nil }
                    Divider()
                    ForEach(genres, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { genre == name },
                            set: { genre = $0 ? name : nil }
                        ))
                    }
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
                knownTotal = try await client.libraryItems(
                    parentId: parentId, query: query(startIndex: 0, limit: 1)
                ).total
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
            let response = try await client.libraryItems(
                parentId: parentId, query: query(startIndex: page * Self.pageSize)
            )
            return (response.items, response.total)
        }
        let pageCount = max(1, (total + Self.pageSize - 1) / Self.pageSize)
        var order = SeededGenerator(seed: shuffleSeed)
        let pages = Array(0..<pageCount).shuffled(using: &order)
        let source = pages[min(page, pageCount - 1)]
        var q = query(startIndex: source * Self.pageSize)
        q.sortBy = SortOption.name.field
        q.sortOrder = SortOption.name.order
        let response = try await client.libraryItems(parentId: parentId, query: q)
        var within = SeededGenerator(seed: shuffleSeed &+ UInt64(source) &+ 1)
        return (response.items.shuffled(using: &within), response.total)
    }

    private func query(startIndex: Int, limit: Int = LibraryView.pageSize) -> JellyfinClient.LibraryQuery {
        .init(
            startIndex: startIndex,
            limit: limit,
            includeTypes: includeTypes,
            sortBy: sort.field,
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
