//  The pieces the music screens are built from: a square album tile, a round
//  artist tile, a song row, the shelves that hold them, and the press-and-hold
//  menu every one of them carries.
//
//  Aquarium's own cards, cut square. The tiles are the same corner radius and
//  border as the poster cards on the video side; only the aspect ratio
//  changes, because a record sleeve is square and a face is round. What opens
//  a page — the header, the play bar, the library's doors — is drawn the way
//  the rest of the app draws things: raised cards, accent kickers, artwork
//  washing the top of the page.

import SwiftUI

#if os(iOS)

// MARK: - Sizing

enum MusicMetrics {
    /// A cover on a shelf. Wider than a poster: a square at poster width
    /// reads as a thumbnail, and the cover is the whole picture.
    static var tileWidth: CGFloat { 148 }
    /// Album art in a page's loading skeleton and the symbol-only headers.
    static var heroArt: CGFloat { 220 }
    /// The cover beside the title in a `CollectionHeader`.
    static var headerArt: CGFloat { 136 }
    static let tileRadius: CGFloat = 8
    static let rowArt: CGFloat = 52
}

// MARK: - Artwork

/// A square piece of music artwork with the blur underneath and a note where
/// there is nothing at all.
struct MusicArtwork: View {
    let item: BaseItem?
    var width: Int = 400
    var radius: CGFloat = MusicMetrics.tileRadius
    var placeholderSymbol: String = "music.note"

    var body: some View {
        ZStack {
            Theme.placeholderFill
            if let item {
                RemoteImage(url: MusicArt.url(item, width: width), blurHash: MusicArt.hash(item))
            }
            if item.flatMap({ MusicArt.url($0, width: 40) }) == nil {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.5)
        )
    }
}

/// A round artist picture.
struct ArtistArtwork: View {
    let item: BaseItem?
    var width: Int = 400

    var body: some View {
        ZStack {
            Theme.placeholderFill
            if let item {
                RemoteImage(url: MusicArt.url(item, width: width), blurHash: MusicArt.hash(item))
            }
            if item.flatMap({ MusicArt.url($0, width: 40) }) == nil {
                Image(systemName: "music.mic")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - Tiles

/// A cover with the album's name and artist under it.
struct AlbumTile: View {
    let item: BaseItem
    var width: CGFloat? = MusicMetrics.tileWidth
    /// What the second line says; the artist unless told otherwise.
    var subtitle: String? = nil
    var showSubtitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let width {
                    MusicArtwork(item: item).frame(width: width, height: width)
                } else {
                    MusicArtwork(item: item).frame(maxWidth: .infinity)
                }
            }
            // A book is one download, so its cover can say where that is. An
            // album is a dozen, and its songs' rows say it instead.
            .overlay(alignment: .topTrailing) {
                if item.isAudiobook { DownloadStateBadge(itemId: item.Id) }
            }
            // A started book wears how far in it is, the way a half-watched
            // film does on Home.
            .overlay(alignment: .bottom) {
                if item.isAudiobook, let progress = item.progressFraction {
                    CoverProgress(fraction: progress)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                if showSubtitle {
                    Text(subtitle ?? defaultSubtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }

    private var defaultSubtitle: String {
        let artist = item.artistLine
        if !artist.isEmpty { return artist }
        if let year = item.ProductionYear { return String(year) }
        return item.isPlaylist ? "Playlist" : " "
    }
}

/// A round picture with the artist's name under it, centred.
struct ArtistTile: View {
    let item: BaseItem
    var width: CGFloat = MusicMetrics.tileWidth

    var body: some View {
        VStack(spacing: 8) {
            ArtistArtwork(item: item).frame(width: width, height: width)
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(Theme.text)
                .frame(width: width)
        }
    }
}

/// How far into a book the listener is, along the foot of its cover.
struct CoverProgress: View {
    let fraction: Double

    var body: some View {
        Capsule().fill(.black.opacity(0.55))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.accent)
                    .scaleEffect(x: min(1, max(0.02, fraction)), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .padding(6)
            .accessibilityHidden(true)
    }
}

/// A station: a mix built from one thing. A card rather than a cover — the
/// seed's artwork at one end and what the station is at the other — which is
/// enough to say "this is not the album, it is something made from it".
struct MixTile: View {
    let title: String
    let subtitle: String
    let seed: BaseItem?
    var width: CGFloat = 280

    private let height: CGFloat = 92

    var body: some View {
        HStack(spacing: 12) {
            MusicArtwork(item: seed, width: 300, radius: 0, placeholderSymbol: "dot.radiowaves.left.and.right")
                .frame(width: height, height: height)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Theme.accentStrong, in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .padding(6)
                }
            VStack(alignment: .leading, spacing: 3) {
                Label("Station", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.link)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
        }
        .frame(width: width, height: height)
        .background(Theme.raised)
        .cardChrome()
    }
}

// MARK: - Shelves

/// A horizontal row of covers, the shape Discover is made of.
struct AlbumShelf: View {
    let title: String
    var subtitle: String? = nil
    let items: [BaseItem]
    var subtitleFor: ((BaseItem) -> String?)? = nil
    var onSelect: (BaseItem) -> Void
    var seeAll: (() -> Void)? = nil

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                ShelfHeading(title: title, subtitle: subtitle, seeAll: seeAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                        ForEach(items) { item in
                            Button { onSelect(item) } label: {
                                AlbumTile(item: item, subtitle: subtitleFor?(item))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PosterButtonStyle())
                            .musicContextMenu(item)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
            }
        }
    }
}

struct ArtistShelf: View {
    let title: String
    let items: [BaseItem]
    var onSelect: (BaseItem) -> Void
    var seeAll: (() -> Void)? = nil

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                ShelfHeading(title: title, seeAll: seeAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                        ForEach(items) { item in
                            Button { onSelect(item) } label: {
                                ArtistTile(item: item).contentShape(Rectangle())
                            }
                            .buttonStyle(PosterButtonStyle())
                            .musicContextMenu(item)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
            }
        }
    }
}

/// A row of songs laid out in columns of four, scrolling sideways, which
/// shows two dozen songs without spending a screen on them. Ranked, it is a
/// chart: each song wears its place.
struct SongColumnsShelf: View {
    let title: String
    let items: [BaseItem]
    var rows = 4
    var ranked = false
    var onPlay: (BaseItem) -> Void
    var seeAll: (() -> Void)? = nil

    private var columns: [[BaseItem]] {
        stride(from: 0, to: items.count, by: rows).map { Array(items[$0..<min($0 + rows, items.count)]) }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                ShelfHeading(title: title, seeAll: seeAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { c, column in
                            VStack(spacing: 0) {
                                ForEach(Array(column.enumerated()), id: \.element.id) { r, song in
                                    SongRow(song: song, style: .compact, rank: ranked ? c * rows + r + 1 : nil) { onPlay(song) }
                                }
                            }
                            .frame(width: 300)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
            }
        }
    }
}

struct ShelfHeading: View {
    let title: String
    var subtitle: String? = nil
    var seeAll: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            if let seeAll {
                SeeAllButton(action: seeAll)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

// MARK: - Song row

/// One song in a list.
///
/// Two styles: the album page numbers its tracks and shows no artwork, since
/// every track has the same cover and the number is what you scan for; every
/// other list shows the cover, because the songs come from all over.
struct SongRow: View {
    enum Style { case album, compact, full }

    let song: BaseItem
    var style: Style = .full
    /// Album style: the number to show. Nil draws the artwork instead.
    var number: Int? = nil
    /// Its place in a chart, drawn ahead of the artwork.
    var rank: Int? = nil
    /// Whether this is the song playing right now.
    var isCurrent = false
    var isPlaying = false
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let rank {
                    Text("\(rank)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 22)
                }
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    if style != .album || !song.artistLine.isEmpty {
                        Text(secondLine)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Spacer(minLength: 8)
                if style != .compact, song.runtimeSeconds > 0 {
                    Text(Format.clock(song.runtimeSeconds))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                }
                downloadedMark
                Menu {
                    MusicItemMenu(item: song)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, style == .compact ? 0 : Metrics.gutter)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .musicContextMenu(song)
    }

    @ViewBuilder
    private var leading: some View {
        if style == .album, let number {
            ZStack {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("\(number)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(width: 24)
        } else {
            MusicArtwork(item: song, width: 160, radius: 5)
                .frame(width: style == .compact ? 44 : MusicMetrics.rowArt,
                       height: style == .compact ? 44 : MusicMetrics.rowArt)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.45))
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
        }
    }

    private var secondLine: String {
        let artist = song.artistLine
        if style == .album { return artist }
        if let album = song.Album, !album.isEmpty, !artist.isEmpty { return "\(artist) · \(album)" }
        return artist.isEmpty ? (song.Album ?? "") : artist
    }

    /// Downloaded, arriving, or waiting in the queue — see `DownloadStateMark`.
    private var downloadedMark: some View {
        DownloadStateMark(itemId: song.Id)
    }
}

/// A row for an album, artist, playlist or audiobook in a list — a square or
/// round picture, two lines, a chevron.
struct MusicListRow: View {
    let item: BaseItem
    var subtitle: String? = nil
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if item.isArtist {
                    ArtistArtwork(item: item, width: 160)
                        .frame(width: MusicMetrics.rowArt, height: MusicMetrics.rowArt)
                } else {
                    MusicArtwork(item: item, width: 160, radius: 5, placeholderSymbol: item.isAudiobook ? "book" : "music.note")
                        .frame(width: MusicMetrics.rowArt, height: MusicMetrics.rowArt)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(Theme.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Metrics.gutter)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .musicContextMenu(item)
    }
}

// MARK: - Play and shuffle

/// What starts a page of songs: one wide Play in the accent, and Shuffle as
/// the round button beside it.
struct PlayShuffleBar: View {
    var onPlay: () -> Void
    var onShuffle: () -> Void
    var isEnabled = true

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 340)
                    .frame(height: 48)
                    .background(Theme.accentStrong, in: Capsule())
                    .contentShape(Capsule())
            }
            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .frame(width: 48, height: 48)
                    .background(Theme.raised, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .accessibilityLabel("Shuffle")
            Spacer(minLength: 0)
        }
        .buttonStyle(PosterButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .padding(.horizontal, Metrics.gutter)
    }
}

// MARK: - Page header

/// The top of an album, a playlist, a book: the cover at one side, what it is
/// beside it, and the cover's own colours washed across the top of the page —
/// the music side's answer to the backdrop a film's page opens with.
struct CollectionHeader<Art: View, Detail: View>: View {
    /// One word over the title saying what kind of thing this is.
    let kicker: String
    let title: String
    /// Whose artwork colours the top of the page. Nil for the pages whose
    /// picture is a symbol.
    var wash: BaseItem? = nil
    @ViewBuilder var art: () -> Art
    /// Everything under the title: whose it is, how long, how many.
    @ViewBuilder var detail: () -> Detail

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var side: CGFloat { sizeClass == .compact ? MusicMetrics.headerArt : MusicMetrics.heroArt }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            art()
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(Theme.link)
                Text(title)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Theme.text)
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 20)
        .background(alignment: .top) { washLayer }
    }

    @ViewBuilder
    private var washLayer: some View {
        if let wash, MusicArt.url(wash, width: 40) != nil {
            RemoteImage(url: MusicArt.url(wash, width: 200), blurHash: MusicArt.hash(wash))
                .frame(maxWidth: .infinity)
                .frame(height: side + 120)
                .scaleEffect(1.3)
                .blur(radius: 50)
                .clipped()
                .opacity(0.4)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The header's shape while its page loads.
struct CollectionHeaderSkeleton: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            RoundedRectangle(cornerRadius: MusicMetrics.tileRadius, style: .continuous)
                .fill(Theme.placeholderFill)
                .frame(width: MusicMetrics.headerArt, height: MusicMetrics.headerArt)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: 50)
                SkeletonBar(height: 14, width: 150)
                SkeletonBar(width: 100)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 20)
        .accessibilityHidden(true)
    }
}

/// The small grey line of facts under a header's title.
struct HeaderFacts: View {
    let parts: [String]

    var body: some View {
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Library doors

/// The ways into the library, as a grid of cards: two across on a phone, as
/// many as fit on anything wider.
struct LibraryDoors: View {
    struct Door: Identifiable {
        let title: String
        let symbol: String
        let route: MusicRoute
        var id: String { title }
    }

    let doors: [Door]
    var onOpen: (MusicRoute) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        if sizeClass == .compact {
            return Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
        }
        return [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(doors) { door in
                Button { onOpen(door.route) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: door.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.link)
                            .frame(width: 34, height: 34)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(door.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Theme.raised)
                    .cardChrome()
                    .contentShape(Rectangle())
                }
                .buttonStyle(PosterButtonStyle())
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

// MARK: - Grid

/// Album covers as a grid, two across on a phone and as many as fit on a
/// larger screen.
struct AlbumGrid: View {
    let items: [BaseItem]
    var pendingCount = 0
    var subtitleFor: ((BaseItem) -> String?)? = nil
    var onSelect: (BaseItem) -> Void
    var onReachEnd: (() -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        if sizeClass == .compact {
            return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2)
        }
        return [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(items) { item in
                Button { onSelect(item) } label: {
                    AlbumTile(item: item, width: nil, subtitle: subtitleFor?(item))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PosterButtonStyle())
                .musicContextMenu(item)
                .onAppear {
                    if item.Id == items.last?.Id { onReachEnd?() }
                }
            }
            if pendingCount > 0 {
                ForEach(0..<pendingCount, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: MusicMetrics.tileRadius, style: .continuous)
                            .fill(Theme.placeholderFill)
                            .aspectRatio(1, contentMode: .fit)
                        SkeletonBar(width: 90)
                        SkeletonBar(width: 60)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

// MARK: - The press-and-hold menu

extension View {
    /// What a song, an album, an artist, a playlist or an audiobook can do
    /// without being opened.
    func musicContextMenu(_ item: BaseItem) -> some View {
        contextMenu { MusicItemMenu(item: item) }
    }
}

/// The actions themselves, ordered the way they are reached for: play it,
/// queue it, go to it, keep it.
struct MusicItemMenu: View {
    let item: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    private var isCollection: Bool { item.isAlbum || item.isArtist || item.isPlaylist || item.isMusicGenre }

    var body: some View {
        Button { Task { await play(shuffle: false) } } label: {
            Label("Play", systemImage: "play.fill")
        }
        if isCollection {
            Button { Task { await play(shuffle: true) } } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
        }
        Button { Task { await queue(next: true) } } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { Task { await queue(next: false) } } label: {
            Label("Play Later", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        if !item.isAudiobook {
            Button { Task { await startMix() } } label: {
                Label("Start Station", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        Divider()
        if item.isSong, let albumId = item.AlbumId, !albumId.isEmpty {
            Button { app.push(.music(.album(albumId))) } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
        if item.isSong || item.isAlbum, let artist = item.ArtistItems?.first ?? item.AlbumArtists?.first,
           let artistId = artist.Id, !artistId.isEmpty {
            Button { app.push(.music(.artist(artistId))) } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
        }
        Divider()
        // Playlists are the server's to change; with it gone the menu would
        // only offer something that fails.
        if !item.isAudiobook, !item.isPlaylist, !client.showsOffline {
            addToPlaylist
        }
        Button { Task { await toggleFavorite() } } label: {
            Label(
                item.userData.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: item.userData.isFavorite ? "star.slash" : "star"
            )
        }
        downloadActions
    }

    /// Every playlist the account has, plus a new one. The list comes from
    /// `PlaylistStore`, which the tab warmed on its first visit — a menu that
    /// has to fetch before it can open is a menu that opens empty.
    private var addToPlaylist: some View {
        Menu {
            Button {
                PlaylistPrompt.shared.ask(for: item)
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
            let lists = PlaylistStore.shared.playlists
            if !lists.isEmpty { Divider() }
            ForEach(lists) { list in
                Button {
                    Task { await add(to: list) }
                } label: {
                    Label(list.title, systemImage: "music.note.list")
                }
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }

    private func add(to list: BaseItem) async {
        let songs = await songs()
        guard !songs.isEmpty else { return app.toast("Nothing to add", tone: .error) }
        do {
            try await PlaylistStore.shared.add(songs.map(\.Id), to: list.Id)
            app.toast("Added \(songs.count == 1 ? songs[0].title : "\(songs.count) songs") to \(list.title)", tone: .ok)
        } catch {
            app.toast("Couldn't add to \(list.title): \(error.localizedDescription)", tone: .error)
        }
    }

    /// Everything this item stands for, as songs. With no server, as the
    /// songs of it that are on this device.
    private func songs() async -> [BaseItem] {
        if item.isSong || item.isAudiobook { return [item] }
        if client.showsOffline { return OfflineMusic.songs(for: item) }
        if item.isAlbum { return (try? await client.albumTracks(albumId: item.Id)) ?? [] }
        if item.isArtist { return (try? await client.allSongs(artistId: item.Id)) ?? [] }
        if item.isPlaylist { return (try? await client.playlistItems(playlistId: item.Id)) ?? [] }
        if item.isMusicGenre { return (try? await client.songs(genreId: item.Id)) ?? [] }
        return []
    }

    private func play(shuffle: Bool) async {
        let list = await songs()
        guard !list.isEmpty else { return app.toast("Nothing to play here", tone: .error) }
        music.play(list, shuffle: shuffle, title: item.isSong ? item.Album : item.title)
    }

    private func queue(next: Bool) async {
        let list = await songs()
        guard !list.isEmpty else { return app.toast("Nothing to queue here", tone: .error) }
        if next { music.playNext(list) } else { music.playLater(list) }
        app.toast(next ? "Playing next" : "Added to the queue", tone: .ok)
    }

    private func startMix() async {
        let title = item.isArtist ? MusicNames.artistName(item.title, sortName: item.SortName) : item.title
        let result = await MusicMixes.startStation(from: item, title: "\(title) Station")
        guard result.started else {
            return app.toast(
                result.isLocal ? "Nothing on this device to build a station from" : "The server couldn't build a station from this",
                tone: .error
            )
        }
    }

    private func toggleFavorite() async {
        let next = !item.userData.isFavorite
        do {
            let outcome = try await MusicFavorites.set(item, favorite: next)
            music.markFavorite(item.Id, next)
            ItemMutations.shared.changed()
            let text = next ? "Added to Favorites" : "Removed from Favorites"
            app.toast(outcome == .keptForLater ? "\(text) — sent when you're back online" : text, tone: .ok)
        } catch {
            app.toast("Couldn't update favorites", tone: .error)
        }
    }

    @ViewBuilder
    private var downloadActions: some View {
        if client.showsOffline, DownloadManager.shared.record(for: item.Id)?.status != .complete {
            // Nothing to download from.
        } else if item.isSong || item.isAudiobook {
            let existing = DownloadManager.shared.record(for: item.Id)
            if existing?.status == .complete {
                Button(role: .destructive) {
                    DownloadManager.shared.delete(item.Id)
                    app.toast("Download deleted", tone: .ok)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            } else if DownloadManager.shared.isQueuedOrRunning(item.Id) {
                Button { app.show(.downloads) } label: {
                    Label("Downloading…", systemImage: "arrow.down.circle.dotted")
                }
            } else {
                Button { Task { await MusicDownloads.download([item]) } } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        } else if item.isAlbum || item.isPlaylist {
            Button {
                Task {
                    let list = await songs()
                    await MusicDownloads.download(list)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        #if os(iOS)
        // The watch fetches it from the server itself, so this needs the
        // server too.
        if WatchLink.shared.isAvailable, !client.showsOffline, !item.isMusicGenre {
            Button {
                WatchLink.shared.download(item)
                app.toast("Sending \(item.title) to the watch", tone: .ok)
            } label: {
                Label("Download to Apple Watch", systemImage: "applewatch")
            }
        }
        #endif
    }
}

// MARK: - Naming a new playlist from a menu

/// A menu is gone by the time its button acts, so the name for a new
/// playlist is asked for by whoever hosts the shell — see `withMiniPlayer`,
/// which attaches the alert once for the whole app.
@MainActor
@Observable
final class PlaylistPrompt {
    static let shared = PlaylistPrompt()
    var item: BaseItem?
    var name = ""
    var isPresented: Bool {
        get { item != nil }
        set { if !newValue { item = nil } }
    }
    private init() {}

    func ask(for item: BaseItem) {
        name = item.isSong ? (item.Album ?? item.title) : item.title
        self.item = item
    }

    /// Resolve the item to songs, make the playlist, put them in.
    func create() async {
        guard let item, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        self.item = nil
        let client = JellyfinClient.shared
        var songs: [BaseItem] = []
        if item.isSong { songs = [item] }
        else if item.isAlbum { songs = (try? await client.albumTracks(albumId: item.Id)) ?? [] }
        else if item.isArtist { songs = (try? await client.allSongs(artistId: item.Id)) ?? [] }
        else if item.isMusicGenre { songs = (try? await client.songs(genreId: item.Id)) ?? [] }
        do {
            _ = try await PlaylistStore.shared.create(name: name.trimmingCharacters(in: .whitespaces), itemIds: songs.map(\.Id))
            AppModel.shared.toast("Created \(name) with \(songs.count) song\(songs.count == 1 ? "" : "s")", tone: .ok)
        } catch {
            AppModel.shared.toast("Couldn't create the playlist: \(error.localizedDescription)", tone: .error)
        }
    }
}

// MARK: - Downloads for music

/// Queueing songs onto the device. Songs are always fetched as the original
/// file — a 30 MB FLAC is not the size problem a 9 GB remux is — unless the
/// file is one this device can't read, which is re-encoded to AAC.
enum MusicDownloads {
    /// Every song the account can see, for Downloads → Download All Music.
    ///
    /// Asked for in the full shape — media sources and all — which the lists
    /// avoid on purpose. Here it is the point: the size of each file is what
    /// the confirmation has to add up, and `download` would only go back for
    /// them fifty at a time otherwise. Audiobooks are a different item type
    /// and are not swept up in this.
    @MainActor
    static func everySong(onProgress: (_ found: Int, _ total: Int) -> Void) async throws -> [BaseItem] {
        var out: [BaseItem] = []
        var total = Int.max
        while out.count < total {
            var q = JellyfinClient.MusicQuery(types: "Audio", sort: .artist, startIndex: out.count, limit: 200)
            q.fields = JellyfinClient.musicDetailFields
            let page = try await JellyfinClient.shared.music(q)
            total = page.total
            if page.items.isEmpty { break }
            out += page.items
            onProgress(out.count, total)
        }
        return out
    }

    @MainActor
    static func download(_ songs: [BaseItem]) async {
        guard !songs.isEmpty else { return }
        // The list query leaves MediaSources out; the download needs the
        // container to decide file-or-encode, so fetch the ones that lack it —
        // fifty to a request rather than a request per song, which for an
        // album was a dozen round trips before anything queued. A song the
        // batch didn't return is asked for on its own, as before.
        let lacking = songs.filter { $0.MediaSources?.isEmpty != false }.map(\.Id)
        var fetched: [String: BaseItem] = [:]
        if !lacking.isEmpty, let batch = try? await JellyfinClient.shared.songs(ids: lacking, detail: true) {
            for item in batch where item.MediaSources?.isEmpty == false { fetched[item.Id] = item }
        }
        var full: [BaseItem] = []
        for song in songs {
            if song.MediaSources?.isEmpty == false {
                full.append(song)
            } else if let found = fetched[song.Id] {
                full.append(found)
            } else if let single = try? await JellyfinClient.shared.musicItem(song.Id) {
                full.append(single)
            } else {
                full.append(song)
            }
        }
        let original = DownloadQualities.all.first { $0.original } ?? DownloadQualities.all[0]
        if let verdict = DownloadManager.checkSpace(for: full, quality: original), !verdict.fits {
            AppModel.shared.toast(
                "Needs about \(Format.bytes(verdict.needed)) and there is \(Format.bytes(verdict.free)) free.",
                tone: .error
            )
            return
        }
        // What the offline pages will want to know about these, while the
        // full items are in hand: genres and stars for songs, chapters for
        // books. See `OfflineMusic`.
        OfflineMusicIndex.shared.note(full)
        for book in full where book.isAudiobook { OfflineBooks.keep(book) }
        let result = DownloadManager.shared.enqueue(items: full, quality: original)
        if result.queued == 0 {
            AppModel.shared.toast("Already downloaded", tone: .info)
        } else {
            AppModel.shared.toast(
                "Downloading \(result.queued) \(result.queued == 1 ? "track" : "tracks")", tone: .ok
            )
        }
    }
}

#endif
