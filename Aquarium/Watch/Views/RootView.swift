//  The shell: one navigation stack. The library is the root; a book, an
//  album or a list is a page; the player is a page too, pushed on top the
//  moment something starts playing, and backed out of like any other.

import SwiftUI

/// Every page the root stack can show. All pushes go by value: a link with
/// a view of its own is dropped from the path the moment the path is
/// written to, and the player is pushed by writing to it.
enum WatchRoute: Hashable {
    case player
    case onWatch
    case books, music, playlists, albums, artists, songs, genres, search, settings
    case book(BaseItem)
    case collection(BaseItem)
    case artist(BaseItem)

    @ViewBuilder var page: some View {
        switch self {
        case .player: NowPlayingScreen()
        case .onWatch: OnWatchView()
        case .books: BooksView()
        case .music: MusicMenu()
        case .playlists: PlaylistsView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .songs: SongsView()
        case .genres: GenresView()
        case .search: SearchView()
        case .settings: WatchSettingsView()
        case .book(let item): BookDetail(item: item)
        case .collection(let item): CollectionDetail(item: item)
        case .artist(let item): ArtistDetail(artist: item)
        }
    }
}

@Observable
final class WatchNavigator {
    var path = NavigationPath()
    /// The player page is on the stack. Cleared by the page when it is popped.
    private(set) var playerShown = false
    private var playerDepth = 0

    func showPlayer() {
        guard !playerShown else { return }
        playerShown = true
        path.append(WatchRoute.player)
        playerDepth = path.count
    }

    /// The player page disappeared: popped, or covered. Only a pop counts.
    func playerLeft() {
        if path.count < playerDepth { playerShown = false; playerDepth = 0 }
    }

    func popToRoot() {
        path = NavigationPath()
        playerShown = false
        playerDepth = 0
    }
}

struct RootView: View {
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchNavigator.self) private var nav

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.path) {
            LibraryHome()
                .navigationDestination(for: WatchRoute.self) { $0.page }
        }
        .onChange(of: player.playRequests) { _, _ in nav.showPlayer() }
    }
}

// MARK: - Home

struct LibraryHome: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchNavigator.self) private var nav

    @State private var inProgress: [BaseItem] = []
    @State private var loaded = false

    private var serverAvailable: Bool { client.isSignedIn && !client.isOffline }

    var body: some View {
        List {
            if player.isActive, let item = player.current {
                Button { nav.showPlayer() } label: { NowPlayingRow(item: item) }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(WatchTheme.accent.opacity(0.28))
                    )
            }

            if !downloads.inFlight.isEmpty {
                NavigationLink(value: WatchRoute.onWatch) { DownloadingRow() }
            }

            if !client.isSignedIn {
                signInNote
            } else if client.isOffline {
                Label("Server out of reach — showing what's on the watch", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.dim)
                    .listRowBackground(Color.clear)
            }

            if !continueRows.isEmpty {
                Section("Continue") {
                    ForEach(Array(continueRows.prefix(3))) { book in
                        Button { player.play([book], title: book.title) } label: {
                            BookRow(item: book)
                        }
                    }
                }
            }

            Section {
                NavigationLink(value: WatchRoute.books) { Door("Audiobooks", symbol: "book.fill", tint: Color(hex: 0xF59E0B)) }
                NavigationLink(value: WatchRoute.music) { Door("Music", symbol: "music.note", tint: Color(hex: 0xEC4899)) }
                NavigationLink(value: WatchRoute.playlists) { Door("Playlists", symbol: "music.note.list", tint: Color(hex: 0x22C55E)) }
                NavigationLink(value: WatchRoute.onWatch) {
                    Door("On Watch", symbol: "applewatch", tint: WatchTheme.accent, detail: onWatchDetail)
                }
                if serverAvailable {
                    NavigationLink(value: WatchRoute.search) { Door("Search", symbol: "magnifyingglass", tint: Color(hex: 0x38BDF8)) }
                }
                NavigationLink(value: WatchRoute.settings) { Door("Settings", symbol: "gearshape.fill", tint: .gray) }
            }
        }
        .navigationTitle("Aquarium")
        .task(id: serverAvailable) { await load() }
    }

    private var onWatchDetail: String? {
        let arriving = downloads.inFlight.count
        if arriving > 0 { return "Downloading \(arriving)" }
        let n = downloads.complete.count
        guard n > 0 else { return nil }
        return "\(n) item\(n == 1 ? "" : "s")"
    }

    /// Books part-way through: the server's list, with the watch's own
    /// filling in when the server is away.
    private var continueRows: [BaseItem] {
        if serverAvailable, !inProgress.isEmpty { return inProgress }
        return downloads.booksInProgress.map(\.asItem)
    }

    private var signInNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not signed in", systemImage: "iphone.and.arrow.forward")
                .font(.headline)
            Text("Open Aquarium on your iPhone. The watch signs in by itself once the phone has the app open.")
                .font(.footnote)
                .foregroundStyle(WatchTheme.dim)
        }
        .listRowBackground(Color.clear)
    }

    private func load(force: Bool = false) async {
        guard serverAvailable, force || !loaded else { return }
        if let books = try? await client.resumeAudio(limit: 12) {
            inProgress = books.filter(\.isAudiobook)
            loaded = true
        }
    }
}

/// The way back to the player from the top of the library.
struct NowPlayingRow: View {
    let item: BaseItem
    @Environment(WatchPlayer.self) private var player

    var body: some View {
        HStack(spacing: 8) {
            Artwork(item: item, size: 34, corner: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.isPlaying ? "Now Playing" : "Paused")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchTheme.link)
                Text(item.title).font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                .font(.footnote)
                .foregroundStyle(WatchTheme.link)
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
        }
    }
}

/// What is arriving, in one line, for the top of the library.
struct DownloadingRow: View {
    @Environment(WatchDownloads.self) private var downloads

    var body: some View {
        let p = downloads.progress(of: downloads.inFlight.map(\.itemId) + downloads.complete.map(\.itemId))
        let arriving = downloads.inFlight.count
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Downloading", systemImage: "arrow.down.circle")
                    .font(.footnote.weight(.medium))
                Spacer()
                Text("\(arriving) left").font(.caption2).foregroundStyle(WatchTheme.dim)
            }
            ProgressBar(fraction: p.fraction)
        }
    }
}

/// One of the home list's ways in.
struct Door: View {
    let title: String
    let symbol: String
    let tint: Color
    var detail: String?

    init(_ title: String, symbol: String, tint: Color, detail: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let detail { Text(detail).font(.caption2).foregroundStyle(WatchTheme.dim) }
            }
        }
    }
}

// MARK: - Rows

struct BookRow: View {
    let item: BaseItem
    var progress: Double?

    var body: some View {
        HStack(spacing: 8) {
            Artwork(item: item, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.footnote.weight(.medium)).lineLimit(2)
                if !item.artistLine.isEmpty {
                    Text(item.artistLine).font(.caption2).foregroundStyle(WatchTheme.dim).lineLimit(1)
                }
                if let f = progress ?? item.progressFraction {
                    ProgressBar(fraction: f)
                }
            }
            Spacer(minLength: 0)
            DownloadButton(item: item)
        }
    }
}

struct SongRow: View {
    let item: BaseItem
    var showsArt = true
    var number: Int?
    var isCurrent = false

    var body: some View {
        HStack(spacing: 8) {
            if showsArt {
                Artwork(item: item, size: 34, corner: 5)
            } else if let number {
                Text("\(number)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(WatchTheme.dim)
                    .frame(width: 18, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.footnote.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? WatchTheme.link : .primary)
                    .lineLimit(2)
                let sub = showsArt ? item.artistLine : ""
                if !sub.isEmpty { Text(sub).font(.caption2).foregroundStyle(WatchTheme.dim).lineLimit(1) }
            }
            Spacer(minLength: 0)
            DownloadButton(item: item)
        }
    }
}

struct CollectionRow: View {
    let item: BaseItem
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Artwork(item: item, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.footnote.weight(.medium)).lineLimit(2)
                let sub = subtitle ?? item.artistLine
                if !sub.isEmpty { Text(sub).font(.caption2).foregroundStyle(WatchTheme.dim).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A thin bar, drawn by hand: the system's is tall on a watch and its
/// empty track reads as full against black.
struct ProgressBar: View {
    let fraction: Double
    var tint: Color = WatchTheme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Downloading

extension WatchDownloads {
    /// How far a set of items is from all being on the watch.
    struct Progress {
        var total = 0
        var done = 0
        var arriving = 0
        var failed = 0
        /// Done items count as whole, arriving ones by their bytes.
        var fraction: Double = 0

        var all: Bool { total > 0 && done == total }
        var any: Bool { done > 0 || arriving > 0 }
        var percent: Int { Int((fraction * 100).rounded(.down)) }
    }

    func progress(of ids: [String]) -> Progress {
        var p = Progress(total: ids.count)
        guard !ids.isEmpty else { return p }
        var sum = 0.0
        for id in ids {
            guard let r = record(for: id) else { continue }
            switch r.status {
            case .complete: p.done += 1; sum += 1
            case .downloading, .queued: p.arriving += 1; sum += fraction(id) ?? 0
            case .error: p.failed += 1
            }
        }
        p.fraction = sum / Double(ids.count)
        return p
    }
}

/// The glyph on the right of a row that says whether an item is on the
/// watch, arriving, or waiting — and takes the tap that asks for it. A tap
/// on the rest of the row plays or opens; this corner is only ever about
/// downloading.
struct DownloadButton: View {
    let item: BaseItem
    @Environment(WatchDownloads.self) private var downloads
    @Environment(JellyfinClient.self) private var client

    private var record: WatchRecord? { downloads.record(for: item.Id) }
    private var canFetch: Bool { client.isSignedIn && !client.isOffline }

    var body: some View {
        if record != nil || canFetch {
            Button(action: act) { DownloadMark(itemId: item.Id, showsIdle: canFetch) }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .accessibilityLabel(label)
        }
    }

    private var label: String {
        switch record?.status {
        case .complete: "On watch"
        case .downloading, .queued: "Cancel download"
        case .error: "Retry download"
        case nil: "Download to watch"
        }
    }

    private func act() {
        switch record?.status {
        case .complete: break
        case .downloading, .queued: downloads.cancel(item.Id)
        case .error: downloads.retry(item.Id)
        case nil: downloads.enqueue([item], reason: item.isAudiobook ? "book" : "song")
        }
    }
}

/// The glyph itself: check, ring, dots, or the offer to fetch.
struct DownloadMark: View {
    let itemId: String
    var showsIdle = false
    @Environment(WatchDownloads.self) private var downloads

    var body: some View {
        if let record = downloads.record(for: itemId) {
            switch record.status {
            case .complete:
                Image(systemName: "checkmark.circle.fill").font(.body).foregroundStyle(.green)
            case .downloading:
                // A ring drawn by hand: the system's circular progress is a
                // large control on a watch, and a row has no room for it.
                if let f = downloads.fraction(itemId) {
                    ZStack {
                        Circle().stroke(WatchTheme.accent.opacity(0.25), lineWidth: 2.5)
                        Circle().trim(from: 0, to: f)
                            .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill").font(.system(size: 6)).foregroundStyle(WatchTheme.accent)
                    }
                    .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.down.circle.dotted").font(.body).foregroundStyle(WatchTheme.accent)
                        .symbolEffect(.pulse)
                }
            case .queued:
                Image(systemName: "arrow.down.circle.dotted").font(.body).foregroundStyle(WatchTheme.dim)
            case .error:
                Image(systemName: "exclamationmark.circle").font(.body).foregroundStyle(.orange)
            }
        } else if showsIdle {
            Image(systemName: "arrow.down.circle").font(.body).foregroundStyle(WatchTheme.dim)
        }
    }
}

/// The "On Watch" rows of a page: what is here, what is arriving and how
/// far along, and the one button that changes it. Downloading lives here
/// and in the row corner, never behind the play controls.
struct DownloadControl: View {
    let item: BaseItem
    /// The songs (or the one book) the page is about, when it knows them.
    var members: [BaseItem]?
    /// How to fetch them when it doesn't.
    var fetch: (() async -> [BaseItem])?

    @Environment(WatchDownloads.self) private var downloads
    @Environment(JellyfinClient.self) private var client
    @State private var working = false

    private var canFetch: Bool { client.isSignedIn && !client.isOffline }

    private var reason: String {
        if item.isAudiobook { return "book" }
        if item.isSong { return "song" }
        if item.isAlbum { return "album:\(item.Id)" }
        if item.isArtist { return "artist:\(item.Id)" }
        return "song"
    }

    private var memberIds: [String] {
        if let members { return members.map(\.Id) }
        if item.isAudiobook || item.isSong { return [item.Id] }
        if item.isPlaylist { return downloads.playlists.first { $0.id == item.Id }?.itemIds ?? [] }
        return downloads.records.filter { $0.reasons.contains(reason) || (item.isAlbum && $0.albumId == item.Id) }.map(\.itemId)
    }

    var body: some View {
        let ids = memberIds
        let p = downloads.progress(of: ids)

        if p.arriving > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Downloading", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(p.percent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WatchTheme.dim)
                }
                ProgressBar(fraction: p.fraction)
                if p.total > 1 {
                    Text("\(p.done) of \(p.total) on watch")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WatchTheme.dim)
                }
            }
            Button(role: .destructive) { cancel(ids) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else if p.all {
            Label(p.total > 1 ? "\(p.total) songs on watch" : "On watch", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
            Button(role: .destructive) { remove() } label: {
                Label("Remove", systemImage: "trash")
            }
        } else {
            if p.failed > 0 {
                Label("\(p.failed) didn't arrive", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button { for id in ids { downloads.retry(id) } } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            } else if p.done > 0 {
                Label("\(p.done) of \(p.total) on watch", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.dim)
            }
            if canFetch {
                Button {
                    working = true
                    Task {
                        var list = members ?? []
                        if list.isEmpty, let fetch { list = await fetch() }
                        keep(list)
                        working = false
                    }
                } label: {
                    if working {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    } else {
                        Label(p.done > 0 ? "Download the Rest" : "Download to Watch", systemImage: "arrow.down.circle")
                    }
                }
                .tint(WatchTheme.accent)
            } else if p.done > 0 {
                Button(role: .destructive) { remove() } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private func keep(_ list: [BaseItem]) {
        if item.isPlaylist { downloads.keep(playlist: item, songs: list) }
        else { downloads.enqueue(list, reason: reason) }
    }

    private func cancel(_ ids: [String]) {
        for id in ids where downloads.isQueuedOrRunning(id) { downloads.cancel(id) }
    }

    private func remove() {
        if item.isAudiobook { downloads.deleteBook(item.Id) }
        else if item.isSong { downloads.delete(item.Id) }
        else if item.isAlbum { downloads.deleteAlbum(item.Id) }
        else if item.isPlaylist { downloads.deletePlaylist(item.Id) }
        else { for id in memberIds { downloads.delete(id) } }
    }
}

// MARK: - Playing

/// Play and Shuffle, side by side, at the top of a collection.
struct PlayShuffleBar: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
            Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(.bordered)
        }
        .font(.footnote.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

/// A loading spinner, an error, or nothing at all, for the middle of a list.
struct StatusRow: View {
    var loading = false
    var error: String?
    var empty: String?

    var body: some View {
        if loading {
            HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .listRowBackground(Color.clear)
        } else if let empty {
            Text(empty).font(.footnote).foregroundStyle(WatchTheme.dim).listRowBackground(Color.clear)
        }
    }
}
