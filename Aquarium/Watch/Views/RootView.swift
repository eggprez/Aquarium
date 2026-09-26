//  The shell: a page for the library and a page for what is playing, one
//  above the other, the way the watch's own Music app is laid out.

import SwiftUI

struct RootView: View {
    @Environment(WatchPlayer.self) private var player
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            NavigationStack { LibraryHome() }
                .tag(0)
            NowPlayingScreen()
                .tag(1)
        }
        .tabViewStyle(.verticalPage)
        .onChange(of: player.isActive) { was, now in
            if now, !was { page = 1 }
        }
    }
}

// MARK: - Home

struct LibraryHome: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player

    @State private var inProgress: [BaseItem] = []
    @State private var loaded = false

    private var serverAvailable: Bool { client.isSignedIn && !client.isOffline }

    var body: some View {
        List {
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
                    ForEach(continueRows.prefix(3)) { book in
                        Button { player.play([book], title: book.title) } label: {
                            BookRow(item: book)
                        }
                    }
                }
            }

            Section {
                NavigationLink { BooksView() } label: { Door("Audiobooks", symbol: "book.fill", tint: Color(hex: 0xF59E0B)) }
                NavigationLink { MusicMenu() } label: { Door("Music", symbol: "music.note", tint: Color(hex: 0xEC4899)) }
                NavigationLink { PlaylistsView() } label: { Door("Playlists", symbol: "music.note.list", tint: Color(hex: 0x22C55E)) }
                NavigationLink { OnWatchView() } label: {
                    Door("On Watch", symbol: "applewatch", tint: WatchTheme.accent, detail: onWatchDetail)
                }
                if serverAvailable {
                    NavigationLink { SearchView() } label: { Door("Search", symbol: "magnifyingglass", tint: Color(hex: 0x38BDF8)) }
                }
                NavigationLink { WatchSettingsView() } label: { Door("Settings", symbol: "gearshape.fill", tint: .gray) }
            }
        }
        .navigationTitle("Aquarium")
        .task(id: serverAvailable) { await load() }
        .refreshable { await load(force: true) }
    }

    private var onWatchDetail: String? {
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
                    ProgressView(value: f)
                        .tint(WatchTheme.accent)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
            }
            Spacer(minLength: 0)
            DownloadMark(itemId: item.Id)
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
            DownloadMark(itemId: item.Id)
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

/// The small glyph that says whether an item is on the watch, arriving, or
/// waiting.
struct DownloadMark: View {
    let itemId: String
    @Environment(WatchDownloads.self) private var downloads

    var body: some View {
        if let record = downloads.record(for: itemId) {
            switch record.status {
            case .complete:
                Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            case .downloading:
                if let f = downloads.fraction(itemId) {
                    ProgressView(value: f).progressViewStyle(.circular).controlSize(.mini).tint(WatchTheme.accent)
                } else {
                    ProgressView().controlSize(.mini)
                }
            case .queued:
                Image(systemName: "arrow.down.circle.dotted").font(.caption2).foregroundStyle(WatchTheme.dim)
            case .error:
                Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

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

/// Keep on watch / remove, for a whole collection.
struct KeepButton: View {
    let item: BaseItem
    let songs: () async -> [BaseItem]
    @Environment(WatchDownloads.self) private var downloads
    @Environment(JellyfinClient.self) private var client
    @State private var working = false

    private var state: (all: Bool, some: Bool) {
        let ids = memberIds
        guard !ids.isEmpty else { return (false, false) }
        let done = ids.filter { downloads.isComplete($0) || downloads.isQueuedOrRunning($0) }.count
        return (done == ids.count, done > 0)
    }

    private var memberIds: [String] {
        if item.isAudiobook || item.isSong { return [item.Id] }
        if item.isAlbum { return downloads.records.filter { $0.albumId == item.Id }.map(\.itemId) }
        if item.isPlaylist { return downloads.playlists.first { $0.id == item.Id }?.itemIds ?? [] }
        return []
    }

    var body: some View {
        if state.all || (state.some && client.isOffline) {
            Button(role: .destructive) { remove() } label: {
                Label(item.isAudiobook || item.isSong ? "Remove from Watch" : "Remove from Watch", systemImage: "trash")
            }
        } else if !client.isOffline, client.isSignedIn {
            Button {
                working = true
                Task {
                    let list = await songs()
                    keep(list)
                    working = false
                }
            } label: {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Label(state.some ? "Download the Rest" : "Download to Watch", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func keep(_ list: [BaseItem]) {
        if item.isAudiobook { downloads.enqueue(list, reason: "book") }
        else if item.isSong { downloads.enqueue(list, reason: "song") }
        else if item.isAlbum { downloads.enqueue(list, reason: "album:\(item.Id)") }
        else if item.isPlaylist { downloads.keep(playlist: item, songs: list) }
        else { downloads.enqueue(list, reason: "song") }
    }

    private func remove() {
        if item.isAudiobook { downloads.deleteBook(item.Id) }
        else if item.isSong { downloads.delete(item.Id) }
        else if item.isAlbum { downloads.deleteAlbum(item.Id) }
        else if item.isPlaylist { downloads.deletePlaylist(item.Id) }
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
