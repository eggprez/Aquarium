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
                .posterFocus()

            VStack(alignment: .leading, spacing: 1) {
                Text(library.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                Text(kindLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
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

    private var kindLabel: String {
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

    var body: some View {
        if !libraries.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                Text("My Media")
                    .font(titleFont)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                        ForEach(libraries) { library in
                            Button { onSelect(library) } label: {
                                LibraryTile(library: library, width: Metrics.stillWidth)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PosterButtonStyle())
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.shelfCardPadding)
                }
                .focusRegion()
            }
        }
    }

    /// Matched to `MediaShelf`, so a heading is a heading whichever row it sits
    /// above.
    private var titleFont: Font {
        #if os(iOS)
        return .headline
        #else
        return .title3.weight(.semibold)
        #endif
    }
}
