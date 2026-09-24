//  Everything starred, across every library — the server-side equivalent of the
//  per-library favorites toggle, so the two agree on what counts.

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

    private let kinds: [(label: String, value: String)] = [
        ("Everything", "Movie,Series,Episode"),
        ("Films", "Movie"),
        ("Shows", "Series"),
        ("Episodes", "Episode"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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

                if isLoading, items.isEmpty {
                    SkeletonGrid(count: 9)
                } else if let error, items.isEmpty {
                    ErrorState(error: error) { Task { await load() } }
                } else if items.isEmpty {
                    EmptyState(
                        symbol: "star",
                        title: "Nothing starred yet",
                        message: "Anything you mark as a favorite — in Aquarium or anywhere else signed in to this server — shows up here."
                    )
                } else {
                    MediaGrid(items: items) { app.push(.item($0.Id)) } onReachEnd: {
                        Task { await loadMore() }
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding(.top, 8)
        }
        .screenTitle("Favorites")
        .paletteBar()
        .sensoryFeedback(.selection, trigger: kind)
        // Starring something from its card is the one action that can empty or
        // fill this screen outright.
        .reloadWhenItemsChange { await load() }
        .task(id: kind) { await load() }
    }

    private func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        error = nil
        defer { if mine == generation { isLoading = false } }
        do {
            let response = try await client.favorites(includeTypes: kind)
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
        guard let response = try? await client.favorites(startIndex: items.count, includeTypes: kind) else { return }
        // The kind may have changed while this page was on its way.
        guard mine == generation else { return }
        let known = Set(items.map(\.Id))
        items += response.items.filter { !known.contains($0.Id) }
    }
}
