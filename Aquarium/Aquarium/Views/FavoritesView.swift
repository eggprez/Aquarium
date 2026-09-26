//  Everything starred, across every library — the server-side equivalent of the
//  per-library favorites toggle, so the two agree on what counts.
//
//  On the Mac the kind is a segmented control in the middle of the toolbar,
//  where a Mac window keeps a scope, with a sort menu and the grid/list
//  switch beside it; the pill row stays where a finger can reach it.

import SwiftUI

struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var kind = "Movie,Series,Episode"
    @State private var isLoading = true
    @State private var error: String?
    /// A page is on its way; the end of the grid can ask more than once.
    @State private var isLoadingPage = false
    /// Bumped by every load, so a late answer to an older one can tell.
    @State private var generation = 0
    #if os(macOS)
    /// How the list is ordered. Remembered, like the library's, because a
    /// Mac window's controls are part of the window's state.
    @AppStorage("favoritesSort") private var sort: LibraryView.SortOption = .name
    @AppStorage("favoritesSortReversed") private var reversed = false
    /// Posters or a list; the same switch the library has.
    @AppStorage("favoritesLayout") private var layout: LibraryView.LibraryLayout = .grid
    /// Selected in the grid or the table; the toolbar acts on it.
    @State private var selection: Set<String> = []
    #endif

    private let kinds: [(label: String, value: String)] = [
        ("Everything", "Movie,Series,Episode"),
        ("Films", "Movie"),
        ("Shows", "Series"),
        ("Episodes", "Episode"),
    ]

    var body: some View {
        page
        .screenTitle("Favorites")
        .paletteBar()
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: kind)
        #endif
        #if os(macOS)
        .toolbar { macToolbar }
        .navigationSubtitle(total > 0 ? "\(total) item\(total == 1 ? "" : "s")" : "")
        // View ▸ Refresh (⌘R), and the app coming back to the front.
        .onChange(of: MacCommandRequests.shared.refresh) { _, _ in
            Task { await load() }
        }
        // Starring something off from the selection empties it of that item;
        // nothing stays selected that isn't on the page.
        .onChange(of: items.map(\.Id)) { _, ids in
            let present = Set(ids)
            if !selection.isSubset(of: present) { selection = selection.intersection(present) }
        }
        #endif
        // Starring something from its card is the one action that can empty or
        // fill this screen outright.
        .reloadWhenItemsChange { await load() }
        .task(id: loadKey) { await load() }
    }

    /// Everything the request depends on, as one value for the task.
    private var loadKey: String {
        #if os(macOS)
        "\(kind)|\(sort.rawValue)|\(reversed)"
        #else
        kind
        #endif
    }

    @ViewBuilder
    private var page: some View {
        #if os(macOS)
        if layout == .list {
            if isLoading, items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, items.isEmpty {
                ErrorState(error: error) { Task { await load() } }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if !os(macOS)
                // The Mac has this in the toolbar — see `macToolbar`.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(kinds, id: \.value) { entry in
                            Button {
                                kind = entry.value
                            } label: {
                                Text(entry.label)
                                    .font(.subheadline)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(kind == entry.value ? Theme.accentSoft : Theme.raised, in: Capsule())
                                    .foregroundStyle(kind == entry.value ? Theme.accent : Theme.textBody)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                #endif

                if isLoading, items.isEmpty {
                    #if os(macOS)
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                    #else
                    SkeletonGrid(count: 9)
                    #endif
                } else if let error, items.isEmpty {
                    ErrorState(error: error) { Task { await load() } }
                } else if items.isEmpty {
                    emptyState
                } else {
                    MediaGrid(
                        items: items,
                        onSelect: { app.push(.item($0.Id)) },
                        onReachEnd: { Task { await loadMore() } },
                        selection: gridSelection
                    )
                    .padding(.bottom, 24)
                }
            }
            #if os(macOS)
            .padding(.top, Metrics.gutter)
            #else
            .padding(.top, 8)
            #endif
        }
    }

    private var emptyState: some View {
        EmptyState(
            symbol: "star",
            title: "Nothing Starred Yet",
            message: "Anything you mark as a favorite — in Aquarium or anywhere else signed in to this server — shows up here."
        )
    }

    /// The grid's selection is the page's on the Mac, so the toolbar can act
    /// on it; elsewhere the grid has none.
    private var gridSelection: Binding<Set<String>>? {
        #if os(macOS)
        $selection
        #else
        nil
        #endif
    }

    #if os(macOS)
    /// The sorts that mean something for a list of favorites: everything the
    /// library offers but "Random", which is for picking a film to watch and
    /// not for finding one you starred.
    private var sortOptions: [LibraryView.SortOption] {
        LibraryView.SortOption.allCases.filter { $0 != .random }
    }

    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $kind) {
                ForEach(kinds, id: \.value) { entry in
                    Text(entry.label).tag(entry.value)
                }
            }
            .pickerStyle(.segmented)
            .help("Which kind of favorites to show")
        }
        if isLoading || isLoadingPage, !items.isEmpty {
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
                Label("Grid", systemImage: "square.grid.2x2").tag(LibraryView.LibraryLayout.grid)
                Label("List", systemImage: "list.bullet").tag(LibraryView.LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Show as posters or as a list")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(sortOptions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Reverse Order", isOn: $reversed)
            } label: {
                Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort by \(sort.label.lowercased())")
        }
    }

    /// The direction the server is asked for: the sort's natural one, or the
    /// other way when the column heading was clicked twice.
    private var sortOrder: String {
        reversed ? (sort.order == "Ascending" ? "Descending" : "Ascending") : sort.order
    }
    #endif

    private func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        error = nil
        defer { if mine == generation { isLoading = false } }
        do {
            let response = try await fetch(startIndex: 0)
            guard mine == generation, !Task.isCancelled else { return }
            items = response.items
            total = response.total
        } catch is CancellationError {
            // Overtaken by a newer load, or the screen went away.
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            items = []
        }
    }

    private func loadMore() async {
        guard items.count < total, !isLoading, !isLoadingPage else { return }
        let mine = generation
        isLoadingPage = true
        defer { isLoadingPage = false }
        guard let response = try? await fetch(startIndex: items.count) else { return }
        // The kind may have changed while this page was on its way.
        guard mine == generation else { return }
        let known = Set(items.map(\.Id))
        items += response.items.filter { !known.contains($0.Id) }
    }

    /// One page, in the order the Mac's sort menu asks for; the server's
    /// default order elsewhere.
    private func fetch(startIndex: Int) async throws -> ItemsResponse {
        #if os(macOS)
        try await client.favorites(
            startIndex: startIndex, includeTypes: kind, sortBy: sort.field, sortOrder: sortOrder
        )
        #else
        try await client.favorites(startIndex: startIndex, includeTypes: kind)
        #endif
    }
}
