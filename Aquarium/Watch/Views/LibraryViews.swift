//  The lists: audiobooks, the music library by playlist, album, artist,
//  song and genre, and the pages behind each. Every list has two sources —
//  the server, and the watch's own downloads when the server is away — and
//  every page offers the same three things: play it, shuffle it, keep it.

import SwiftUI

// MARK: - Audiobooks

struct BooksView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads

    enum Sort: String, CaseIterable { case title = "Title", author = "Author", recent = "Recently added" }

    @State private var books: [BaseItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var sort: Sort = .title

    private var offline: Bool { client.isOffline || !client.isSignedIn }

    var body: some View {
        List {
            if offline {
                let local = downloads.books.map(\.asItem)
                if local.isEmpty { StatusRow(empty: "No audiobooks on the watch yet") }
                ForEach(local) { book in
                    NavigationLink(value: WatchRoute.book(book)) { BookRow(item: book) }
                }
            } else {
                StatusRow(loading: loading && books.isEmpty, error: error, empty: !loading && books.isEmpty && error == nil ? "No audiobooks on this server" : nil)
                ForEach(books) { book in
                    NavigationLink(value: WatchRoute.book(book)) { BookRow(item: book) }
                }
            }
        }
        .navigationTitle("Audiobooks")
        .toolbar {
            if !offline {
                // No menus on a watch: the button steps through the orders.
                // It sits in the bottom bar: a top-bar item on a pushed page
                // inside the vertical TabView pops the page straight back.
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        let all = Sort.allCases
                        sort = all[(all.firstIndex(of: sort)! + 1) % all.count]
                    } label: {
                        Image(systemName: sort == .title ? "textformat.abc" : (sort == .author ? "person" : "clock"))
                    }
                }
            }
        }
        .task(id: sort) { await load() }
    }

    private func load() async {
        guard !offline else { return }
        loading = true
        defer { loading = false }
        do {
            let page: ItemsResponse
            switch sort {
            case .title: page = try await client.audiobooks(sortBy: "SortName")
            case .author: page = try await client.audiobooks(sortBy: "AlbumArtist,SortName")
            case .recent: page = try await client.audiobooks(sortBy: "DateCreated,SortName", descending: true)
            }
            books = page.items
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct BookDetail: View {
    let item: BaseItem
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player

    @State private var full: BaseItem?

    private var book: BaseItem { full ?? item }
    private var record: WatchRecord? { downloads.record(for: item.Id) }
    private var isCurrent: Bool { player.current?.Id == item.Id }
    private var chapters: [ChapterInfo] { book.Chapters ?? record?.chapters ?? [] }

    /// Where it would open: the watch's note, or the server's.
    private var resumeSeconds: Double {
        if let record, record.status == .complete || record.positionTicks > 0 { return record.resumeSeconds }
        let ticks = book.userData.positionTicks
        guard ticks > 0, let total = book.RunTimeTicks, total > 0, Double(ticks) / Double(total) < 0.98 else { return 0 }
        return Double(ticks) / 10_000_000
    }

    var body: some View {
        List {
            VStack(spacing: 6) {
                Artwork(item: book, size: 88, corner: 10)
                Text(book.title).font(.headline).multilineTextAlignment(.center)
                if !book.artistLine.isEmpty { Text(book.artistLine).font(.caption2).foregroundStyle(WatchTheme.dim) }
                if book.runtimeSeconds > 0 {
                    Text(resumeSeconds > 0 ? "\(Format.clock(resumeSeconds)) of \(Format.ticks(book.RunTimeTicks))" : Format.ticks(book.RunTimeTicks))
                        .font(.caption2).foregroundStyle(WatchTheme.dim)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)

            Button {
                if isCurrent { player.togglePlayPause() } else { player.play([book], title: book.title) }
            } label: {
                Label(isCurrent && player.isPlaying ? "Pause" : (resumeSeconds > 0 ? "Resume" : "Play"),
                      systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if resumeSeconds > 0 {
                Button { player.play([book], title: book.title, at: 0) } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
            }

            Section("On Watch") {
                DownloadControl(item: book, members: [book])
                if let record, record.status == .error, let message = record.errorMessage {
                    Text(message).font(.caption2).foregroundStyle(.orange)
                }
            }

            if !chapters.isEmpty {
                Section("Chapters") {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { i, chapter in
                        Button {
                            player.play([book], title: book.title, at: chapter.startSeconds)
                        } label: {
                            HStack {
                                Text(chapter.Name?.isEmpty == false ? chapter.Name! : "Chapter \(i + 1)")
                                    .font(.footnote)
                                    .lineLimit(2)
                                Spacer()
                                Text(Format.clock(chapter.startSeconds)).font(.caption2.monospacedDigit()).foregroundStyle(WatchTheme.dim)
                            }
                        }
                    }
                }
            }

            if let overview = book.Overview ?? record?.overview, !overview.isEmpty {
                Section("About") {
                    Text(overview).font(.caption2).foregroundStyle(WatchTheme.dim)
                }
            }
        }
        .navigationTitle("Audiobook")
        .task {
            guard !client.isOffline, client.isSignedIn, item.Chapters == nil else { return }
            full = try? await client.item(item.Id)
        }
    }
}

// MARK: - Music

struct MusicMenu: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player

    private var offline: Bool { client.isOffline || !client.isSignedIn }

    var body: some View {
        List {
            NavigationLink(value: WatchRoute.playlists) { Label("Playlists", systemImage: "music.note.list") }
            NavigationLink(value: WatchRoute.albums) { Label("Albums", systemImage: "square.stack") }
            NavigationLink(value: WatchRoute.artists) { Label("Artists", systemImage: "music.mic") }
            NavigationLink(value: WatchRoute.songs) { Label("Songs", systemImage: "music.note") }
            if !offline {
                NavigationLink(value: WatchRoute.genres) { Label("Genres", systemImage: "guitars") }
            }
            Button {
                Task {
                    var songs: [BaseItem] = []
                    if !offline { songs = (try? await client.randomSongs(limit: 200)) ?? [] }
                    if songs.isEmpty { songs = downloads.songs.map(\.asItem) }
                    guard !songs.isEmpty else { return }
                    player.play(songs, shuffle: true, title: "Shuffle")
                }
            } label: {
                Label("Shuffle All", systemImage: "shuffle")
            }
        }
        .navigationTitle("Music")
    }
}

struct PlaylistsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads

    @State private var lists: [BaseItem] = []
    @State private var loading = false
    @State private var error: String?

    private var offline: Bool { client.isOffline || !client.isSignedIn }

    var body: some View {
        List {
            if offline {
                if downloads.playlists.isEmpty { StatusRow(empty: "No playlists on the watch yet") }
                ForEach(downloads.playlists) { list in
                    let item = list.asItem
                    NavigationLink(value: WatchRoute.collection(item)) {
                        CollectionRow(item: item, subtitle: "\(list.itemIds.count) songs")
                    }
                }
            } else {
                StatusRow(loading: loading && lists.isEmpty, error: error, empty: !loading && lists.isEmpty && error == nil ? "No playlists" : nil)
                ForEach(lists) { list in
                    NavigationLink(value: WatchRoute.collection(list)) {
                        CollectionRow(item: list, subtitle: list.ChildCount.map { "\($0) songs" } ?? "Playlist")
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .task {
            guard !offline else { return }
            loading = true
            defer { loading = false }
            do { lists = try await client.playlists(); error = nil } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

extension WatchPlaylist {
    var asItem: BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = name
        item.type = "Playlist"
        item.MediaType = "Audio"
        item.ChildCount = itemIds.count
        if let imageTag { item.ImageTags = ["Primary": imageTag] }
        return item
    }
}

struct AlbumsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads

    @State private var albums: [BaseItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var recentFirst = false

    private var offline: Bool { client.isOffline || !client.isSignedIn }

    var body: some View {
        List {
            if offline {
                let local = downloads.albums
                if local.isEmpty { StatusRow(empty: "No albums on the watch yet") }
                ForEach(local) { album in
                    NavigationLink(value: WatchRoute.collection(album)) { CollectionRow(item: album) }
                }
            } else {
                StatusRow(loading: loading && albums.isEmpty, error: error, empty: !loading && albums.isEmpty && error == nil ? "No albums" : nil)
                ForEach(albums) { album in
                    NavigationLink(value: WatchRoute.collection(album)) { CollectionRow(item: album) }
                }
                if albums.count < total {
                    Button { Task { await load(more: true) } } label: {
                        HStack { Spacer(); if loading { ProgressView() } else { Text("More…") }; Spacer() }
                    }
                }
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            if !offline {
                ToolbarItem(placement: .bottomBar) {
                    Button { recentFirst.toggle() } label: {
                        Image(systemName: recentFirst ? "clock" : "textformat.abc")
                    }
                }
            }
        }
        .task(id: recentFirst) { albums = []; await load() }
    }

    private func load(more: Bool = false) async {
        guard !offline, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await client.albums(
                startIndex: more ? albums.count : 0, limit: 100,
                sortBy: recentFirst ? "DateCreated,SortName" : "SortName", descending: recentFirst
            )
            if more { albums += page.items } else { albums = page.items }
            total = page.total
            error = nil
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

struct ArtistsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads

    @State private var artists: [BaseItem] = []
    @State private var loading = false
    @State private var error: String?

    private var offline: Bool { client.isOffline || !client.isSignedIn }

    var body: some View {
        List {
            if offline {
                let local = downloads.songs.map(\.asItem).localArtists()
                if local.isEmpty { StatusRow(empty: "No music on the watch yet") }
                ForEach(local) { artist in
                    NavigationLink(value: WatchRoute.artist(artist)) { Text(artist.title).font(.footnote) }
                }
            } else {
                StatusRow(loading: loading && artists.isEmpty, error: error, empty: !loading && artists.isEmpty && error == nil ? "No artists" : nil)
                ForEach(artists) { artist in
                    NavigationLink(value: WatchRoute.artist(artist)) { Text(artist.title).font(.footnote) }
                }
            }
        }
        .navigationTitle("Artists")
        .task {
            guard !offline else { return }
            loading = true
            defer { loading = false }
            do { artists = try await client.albumArtists().items; error = nil } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

extension Array where Element == BaseItem {
    /// The artists these songs are by, one entry each, named for the songs.
    func localArtists() -> [BaseItem] {
        var seen = Set<String>()
        var out: [BaseItem] = []
        for song in self {
            let name = song.artistLine
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            var artist = BaseItem()
            artist.Id = "artist:\(name.lowercased())"
            artist.Name = name
            artist.type = "MusicArtist"
            out.append(artist)
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct ArtistDetail: View {
    let artist: BaseItem
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player

    @State private var albums: [BaseItem] = []
    @State private var loading = false

    private var offline: Bool { client.isOffline || !client.isSignedIn || artist.Id.hasPrefix("artist:") }

    private var localAlbums: [BaseItem] {
        downloads.songs.map(\.asItem).filter { $0.artistLine == artist.title }.albumsInOrder()
    }

    var body: some View {
        List {
            PlayShuffleBar(
                play: { Task { await play(shuffle: false) } },
                shuffle: { Task { await play(shuffle: true) } }
            )
            Section("On Watch") {
                DownloadControl(item: artist, fetch: { await WatchActions.songs(of: artist) })
            }
            Section("Albums") {
                let shown = offline ? localAlbums : albums
                if loading, shown.isEmpty { StatusRow(loading: true) }
                ForEach(shown) { album in
                    NavigationLink(value: WatchRoute.collection(album)) {
                        CollectionRow(item: album, subtitle: album.ProductionYear.map(String.init) ?? "")
                    }
                }
            }
        }
        .navigationTitle(artist.title)
        .task {
            guard !offline else { return }
            loading = true
            defer { loading = false }
            albums = (try? await client.albums(artistId: artist.Id)) ?? []
        }
    }

    private func play(shuffle: Bool) async {
        var songs = await WatchActions.songs(of: artist)
        if songs.isEmpty { songs = downloads.songs.map(\.asItem).filter { $0.artistLine == artist.title } }
        guard !songs.isEmpty else { return }
        player.play(songs, shuffle: shuffle, title: artist.title)
    }
}

struct SongsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player

    @State private var songs: [BaseItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    private var offline: Bool { client.isOffline || !client.isSignedIn }

    var body: some View {
        List {
            if offline {
                let local = downloads.songs.map(\.asItem).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                if local.isEmpty { StatusRow(empty: "No songs on the watch yet") }
                ForEach(local) { song in
                    Button { player.play(local, startingAt: local.position(of: song) ?? 0, title: "Songs") } label: {
                        SongRow(item: song, isCurrent: player.current?.Id == song.Id)
                    }
                    .swipeActions { SongSwipe(item: song) }
                }
            } else {
                StatusRow(loading: loading && songs.isEmpty, error: error, empty: !loading && songs.isEmpty && error == nil ? "No songs" : nil)
                ForEach(songs) { song in
                    Button { player.play(songs, startingAt: songs.position(of: song) ?? 0, title: "Songs") } label: {
                        SongRow(item: song, isCurrent: player.current?.Id == song.Id)
                    }
                    .swipeActions { SongSwipe(item: song) }
                }
                if songs.count < total {
                    Button { Task { await load(more: true) } } label: {
                        HStack { Spacer(); if loading { ProgressView() } else { Text("More…") }; Spacer() }
                    }
                }
            }
        }
        .navigationTitle("Songs")
        .task { await load() }
    }

    private func load(more: Bool = false) async {
        guard !offline, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await client.songs(startIndex: more ? songs.count : 0, limit: 100)
            if more { songs += page.items } else { songs = page.items }
            total = page.total
            error = nil
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

/// Download or remove, on a swipe.
struct SongSwipe: View {
    let item: BaseItem
    @Environment(WatchDownloads.self) private var downloads
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        if downloads.isComplete(item.Id) || downloads.isQueuedOrRunning(item.Id) {
            Button(role: .destructive) { downloads.delete(item.Id) } label: { Label("Remove", systemImage: "trash") }
        } else if !client.isOffline, client.isSignedIn {
            Button { downloads.enqueue([item], reason: item.isAudiobook ? "book" : "song") } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(WatchTheme.accent)
        }
    }
}

struct GenresView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var genres: [BaseItem] = []
    @State private var loading = false

    var body: some View {
        List {
            if loading, genres.isEmpty { StatusRow(loading: true) }
            ForEach(genres) { genre in
                NavigationLink(value: WatchRoute.collection(genre)) { Text(genre.title).font(.footnote) }
            }
        }
        .navigationTitle("Genres")
        .task {
            loading = true
            defer { loading = false }
            genres = (try? await client.genres()) ?? []
        }
    }
}

// MARK: - An album, a playlist, a genre

struct CollectionDetail: View {
    let item: BaseItem
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player

    @State private var songs: [BaseItem] = []
    @State private var loading = false
    @State private var error: String?

    private var offline: Bool { client.isOffline || !client.isSignedIn }

    private var localSongs: [BaseItem] {
        if item.isAlbum { return downloads.albumTracks(albumId: item.Id) }
        if item.isPlaylist, let list = downloads.playlists.first(where: { $0.id == item.Id }) { return downloads.playlistSongs(list) }
        return []
    }

    private var shown: [BaseItem] { songs.isEmpty ? localSongs : songs }

    var body: some View {
        List {
            VStack(spacing: 6) {
                Artwork(item: item, size: 72, corner: 8)
                Text(item.title).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                if !item.artistLine.isEmpty { Text(item.artistLine).font(.caption2).foregroundStyle(WatchTheme.dim) }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)

            PlayShuffleBar(
                play: { player.play(shown, title: item.title) },
                shuffle: { player.play(shown, shuffle: true, title: item.title) }
            )

            if !shown.isEmpty {
                Section("On Watch") {
                    DownloadControl(item: item, members: shown)
                }
            }

            Section {
                StatusRow(loading: loading && shown.isEmpty, error: error, empty: !loading && shown.isEmpty && error == nil ? "Nothing here" : nil)
                ForEach(Array(shown.enumerated()), id: \.offset) { i, song in
                    Button { player.play(shown, startingAt: i, title: item.title) } label: {
                        SongRow(item: song, showsArt: !item.isAlbum, number: item.isAlbum ? (song.IndexNumber ?? i + 1) : nil,
                                isCurrent: player.current?.Id == song.Id)
                    }
                    .swipeActions { SongSwipe(item: song) }
                }
            }
        }
        .navigationTitle(item.isPlaylist ? "Playlist" : (item.isMusicGenre ? "Genre" : "Album"))
        .task {
            guard !offline else { return }
            loading = true
            defer { loading = false }
            do {
                if item.isAlbum { songs = try await client.albumTracks(albumId: item.Id) }
                else if item.isPlaylist { songs = try await client.playlistItems(playlistId: item.Id) }
                else if item.isMusicGenre { songs = try await client.songs(genreId: item.Id) }
                error = nil
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchPlayer.self) private var player

    @State private var term = ""
    @State private var results = JellyfinClient.SearchResults()
    @State private var searching = false

    var body: some View {
        List {
            TextField("Search", text: $term)
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await search() } }
            if searching { StatusRow(loading: true) }
            if !results.books.isEmpty {
                Section("Audiobooks") {
                    ForEach(results.books) { book in
                        NavigationLink(value: WatchRoute.book(book)) { BookRow(item: book) }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums) { album in
                        NavigationLink(value: WatchRoute.collection(album)) { CollectionRow(item: album) }
                    }
                }
            }
            if !results.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(results.playlists) { list in
                        NavigationLink(value: WatchRoute.collection(list)) { CollectionRow(item: list, subtitle: "Playlist") }
                    }
                }
            }
            if !results.songs.isEmpty {
                Section("Songs") {
                    ForEach(results.songs) { song in
                        Button { player.play(results.songs, startingAt: results.songs.position(of: song) ?? 0, title: "Search") } label: {
                            SongRow(item: song)
                        }
                        .swipeActions { SongSwipe(item: song) }
                    }
                }
            }
            if !searching, results.isEmpty, !term.isEmpty { StatusRow(empty: "Nothing found") }
        }
        .navigationTitle("Search")
    }

    private func search() async {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        searching = true
        defer { searching = false }
        results = (try? await client.search(t)) ?? JellyfinClient.SearchResults()
    }
}
