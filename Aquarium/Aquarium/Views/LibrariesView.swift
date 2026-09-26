//  The Library tab: every library on the server, as one screen.
//
//  On a phone the sidebar that lists libraries individually doesn't exist, and
//  a tab bar only holds five things — without this, browsing your own films
//  starts by opening More. This is that list, promoted to a tab of its own.

import SwiftUI

struct LibrariesView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// A library tile is 16:9, so on a phone one adaptive column is all that
    /// ever fits and the tab becomes a single very tall list. Two fixed columns
    /// put the whole server on one screen.
    private var isPhone: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    private var columns: [GridItem] {
        if isPhone {
            return Array(
                repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top),
                count: 2
            )
        }
        return [GridItem(.adaptive(minimum: Metrics.stillWidth), spacing: Metrics.gridSpacing, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            if app.isLoadingLibraries, app.libraries.isEmpty {
                LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonCard(width: isPhone ? nil : Metrics.stillWidth, wide: true)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 16)
            } else if app.libraries.isEmpty {
                EmptyState(
                    symbol: "books.vertical",
                    title: "No libraries",
                    message: "This server has no film or television libraries you can see. Anything added in Jellyfin shows up here after the next scan."
                )
            } else {
                LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
                    ForEach(app.libraries) { library in
                        Button {
                            app.push(.library(
                                id: library.Id,
                                name: library.title,
                                collectionType: library.CollectionType
                            ))
                        } label: {
                            LibraryTile(library: library, width: isPhone ? nil : Metrics.stillWidth)
                        }
                        .buttonStyle(PosterButtonStyle())
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 16)
            }
        }
        .screenTitle("Library")
        .paletteBar()
        .task {
            if app.libraries.isEmpty { await app.loadLibraries() }
        }
    }
}

/// A library as a wide tile: its own artwork where Jellyfin has one, its name,
/// and what kind of thing is inside it. Shared with Home's "My Media" row —
/// see `LibraryTilesRow`.
struct LibraryTile: View {
    let library: BaseItem
    /// `nil` takes the width from the grid column, as `PosterCard` does.
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardTextSpacing) {
            artwork
                .cardChrome()
                // Without this the Library tab had no selector at all: focus
                // moved from tile to tile and nothing on screen changed, since
                // `PosterButtonStyle` only draws a press and a library tile —
                // unlike a poster — never had a focus effect of its own.
                //
                // The television's ring, on the artwork. The Mac's hover is
                // drawn round the whole tile instead, name included — see
                // `macTileState` below, and `PosterCard`, which does the same.
                .artworkFocus()

            VStack(alignment: .leading, spacing: 1) {
                Text(library.title)
                    .font(titleFont)
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                Text(kindLabel)
                    .font(kindFont)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
        .macTileState()
    }

    /// `.subheadline` and `.caption` were tuned for a phone and are eleven and
    /// ten points on a Mac; a tile's name there is body text.
    private var titleFont: Font {
        #if os(macOS)
        return .body.weight(.medium)
        #else
        return .subheadline.weight(.medium)
        #endif
    }

    private var kindFont: Font {
        #if os(macOS)
        return .callout
        #else
        return .caption
        #endif
    }

    /// What the tooltip says on a Mac: the name, what kind of library it is,
    /// and how many things are in it where the server said.
    static func summary(of library: BaseItem) -> String {
        var parts = [library.title, kind(of: library)]
        if let count = library.RecursiveItemCount ?? library.ChildCount, count > 0 {
            parts.append("\(count.formatted()) \(count == 1 ? "item" : "items")")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        let picture = ZStack {
            RemoteImage(
                url: Artwork.url(library, type: "Primary", width: Int((width ?? Metrics.stillWidth) * 2)),
                blurHash: Artwork.hash(library)
            )

            // A library with no artwork is a blank rectangle otherwise, and
            // three of those in a row are indistinguishable.
            if Artwork.url(library, type: "Primary") == nil {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.textDim)
            }
        }

        if let width {
            picture.frame(width: width, height: width * 9 / 16)
        } else {
            picture
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }

    private var symbol: String {
        switch library.CollectionType {
        case "movies": "film"
        case "tvshows": "tv"
        default: "folder"
        }
    }

    private var kindLabel: String { Self.kind(of: library) }

    static func kind(of library: BaseItem) -> String {
        switch library.CollectionType {
        case "movies": "Films"
        case "tvshows": "TV shows"
        case "homevideos": "Home videos"
        case "musicvideos": "Music videos"
        default: "Library"
        }
    }
}

/// Every library as one horizontal row, for the top of Home.
///
/// Jellyfin's home screen leads with this — it is `smalllibrarytiles` in the
/// display preferences, and the row most accounts have in slot 0. Drawn as a
/// shelf rather than as the grid the Library tab uses, because on Home it is
/// one row among several and a grid would push everything under it off the
/// screen.
struct LibraryTilesRow: View {
    let libraries: [BaseItem]
    var onSelect: (BaseItem) -> Void

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    /// The row's own width, measured from the heading, which spans it.
    @State private var shelfWidth: CGFloat = 0
    @State private var isHovering = false
    /// The id of the leftmost tile, which is what the paging buttons move.
    @State private var scrolledID: String?
    #endif

    var body: some View {
        if !libraries.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                Text("My Media")
                    .font(titleFont)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Metrics.gutter)
                    #if os(macOS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WidthReader(width: $shelfWidth))
                    #endif

                scroller
                    .focusRegion()
            }
        }
    }

    private func tile(_ library: BaseItem, width: CGFloat) -> some View {
        Button { onSelect(library) } label: {
            LibraryTile(library: library, width: width)
                .contentShape(Rectangle())
        }
        .buttonStyle(PosterButtonStyle())
        #if os(macOS)
        .help(LibraryTile.summary(of: library))
        .contextMenu {
            Button {
                openWindow(id: RouteWindow.id, value: Route.library(
                    id: library.Id,
                    name: library.title,
                    collectionType: library.CollectionType
                ))
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
        #endif
    }

    #if os(macOS)
    /// The same arithmetic as `MediaShelf`'s wide row, so the library tiles
    /// and the stills under them line up: however many tiles of a sensible
    /// minimum fit the width, sharing the remainder, and the row ends on a
    /// whole one.
    private var layout: (count: Int, width: CGFloat) {
        let available = shelfWidth - Metrics.gutter * 2
        guard available > 0 else { return (1, Metrics.stillWidth) }
        let minimum = 150 * 1.62 * PosterGrid.thumbnailScale
        return ShelfLayout.fit(available: available, minimum: minimum, spacing: Metrics.rowSpacing)
    }

    private var scroller: some View {
        let layout = self.layout
        return ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                ForEach(libraries) { library in
                    tile(library, width: layout.width)
                }
            }
            .scrollTargetLayout()
            // Room for the hover ring, which sits outside the tile.
            .padding(.vertical, Metrics.shelfCardPadding)
        }
        // Margins rather than padding inside the stack, so that "aligned to a
        // tile" means the tile's edge lands on the gutter and not on the
        // window's edge.
        .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolledID)
        .overlay(alignment: .leading) {
            ShelfPagingButton(direction: .back) { page(by: -layout.count) }
                .padding(.leading, 4)
                .opacity(isHovering && canPage(by: -1) ? 1 : 0)
        }
        .overlay(alignment: .trailing) {
            ShelfPagingButton(direction: .forward) { page(by: layout.count) }
                .padding(.trailing, 4)
                .opacity(isHovering && canPage(by: layout.count) ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Where the row is, as an index into `libraries`. Nothing scrolled yet
    /// is the first tile.
    private var scrolledIndex: Int {
        guard let scrolledID, let index = libraries.firstIndex(where: { $0.Id == scrolledID }) else { return 0 }
        return index
    }

    private func canPage(by offset: Int) -> Bool {
        offset < 0 ? scrolledIndex > 0 : scrolledIndex + offset < libraries.count
    }

    /// One screenful along. The target is the tile that becomes leftmost;
    /// past the end it is the last one, and the scroll view stops where the
    /// content does.
    private func page(by offset: Int) {
        let target = min(max(0, scrolledIndex + offset), libraries.count - 1)
        withAnimation(.easeInOut(duration: 0.3)) {
            scrolledID = libraries[target].Id
        }
    }
    #else
    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                ForEach(libraries) { library in
                    tile(library, width: Metrics.stillWidth)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.shelfCardPadding)
        }
    }
    #endif

    /// Matched to `MediaShelf`, so a heading is a heading whichever row it sits
    /// above. A phone fits more rows on screen with a heading the weight of a
    /// list header than with one the weight of a page title; a Mac, like a
    /// television, has the room for the shelf heading the other rows use.
    private var titleFont: Font {
        #if os(iOS)
        return .headline
        #else
        return .title3.weight(.semibold)
        #endif
    }
}
