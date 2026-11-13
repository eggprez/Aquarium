//  A folder or a photo album, opened: what is inside it, in a grid. And a
//  single photo, as a photo. Neither has a film to play, so the title page,
//  with a Play that could only fail and nothing of the contents, is no use
//  for them. `ItemDetailView` hands them here once it knows what it loaded,
//  so every way in — a library grid, Search, a link — lands the same.

import SwiftUI

struct ContainerPage: View {
    let item: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var children: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(tvOS)
                // No navigation bar worth using on a television (see
                // `screenTitle`): the name heads the page, as a library's does.
                PageHeading(title: item.title)
                #endif
                if isLoading, children.isEmpty {
                    SkeletonGrid(count: 12)
                        .testAnchor(TestID.Library.loading)
                } else if let error, children.isEmpty {
                    ErrorState(error: error) { Task { await load() } }
                        .testAnchor(TestID.Library.error)
                } else if children.isEmpty {
                    EmptyState(symbol: "photo.on.rectangle", title: "Nothing here",
                               message: "There's nothing in this folder that this app can show.")
                        .testAnchor(TestID.Library.empty)
                } else {
                    MediaGrid(items: children, onSelect: { app.push(.item($0.Id)) })
                        .testAnchor(TestID.Library.grid)
                }
            }
            .padding(.top, 8)
        }
        .screenTitle(item.title)
        .paletteBar()
        .testAnchor(TestID.Detail.page(item.Id))
        .task(id: item.Id) { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            children = try await client.children(of: item.Id)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One photo, as large as the screen allows.
struct PhotoPage: View {
    let item: BaseItem

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteImage(url: Artwork.url(item, type: "Primary", width: 2400), contentMode: .fit)
                .accessibilityLabel(item.title)
                #if os(tvOS)
                // Something on the page to hold the selector, so Menu goes
                // back a level rather than out to the tab strip.
                .focusable()
                #endif
        }
        .screenTitle(item.title)
        .testAnchor(TestID.Detail.page(item.Id))
    }
}
