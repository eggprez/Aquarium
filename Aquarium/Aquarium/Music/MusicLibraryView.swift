//  The library: the lists a music collection is browsed by, and the pages
//  behind each of them.
//
//  Playlists, Artists, Albums, Songs, Genres, Favorites, Downloaded — a grid
//  of doors, drawn as the cards the rest of the app is made of — and under
//  them the covers most recently added, so the page is never just a menu.

import SwiftUI

#if os(iOS)

struct MusicLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var recent: [BaseItem] = []
    @State private var isLoading = true

    private typealias Door = LibraryDoors.Door

    private var doors: [Door] {
        [
            Door(title: "Playlists", symbol: "music.note.list", route: .playlists),
            Door(title: "Artists", symbol: "music.mic", route: .artists),
            Door(title: "Albums", symbol: "square.stack", route: .albums),
            Door(title: "Songs", symbol: "music.note", route: .songs),
            Door(title: "Genres", symbol: "guitars", route: .genres),
            Door(title: "Favorites", symbol: "star", route: .favorites),
            Door(title: "Downloaded", symbol: "arrow.down.circle", route: .downloaded),
        ]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                LibraryDoors(doors: doors) { app.push(.music($0)) }
                    .padding(.top, 12)

                if !recent.isEmpty || isLoading {
                    Text("Recently Added")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    AlbumGrid(items: recent, pendingCount: recent.isEmpty && isLoading ? 6 : 0) {
                        app.push(.music(.album($0.Id)))
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let albums = try? await client.music(.init(types: "MusicAlbum", sort: .recentlyAdded, limit: 24)).items {
            recent = albums
        }
    }
}

// MARK: - Paged lists

/// The paging every long list here shares: ask for a page, ask for the next
/// when the last row shows, don't ask twice.
@MainActor
@Observable
final class PagedItems {
    private(set) var items: [BaseItem] = []
    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private var generation = 0
    private let pageSize: Int
    private let fetch: (Int, Int) async throws -> ItemsResponse

    init(pageSize: Int = 100, fetch: @escaping (Int, Int) async throws -> ItemsResponse) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    var hasMore: Bool { items.count < total }

    func reload() async {
        generation &+= 1
        let mine = generation
        isLoading = true
        error = nil
        defer { if generation == mine { isLoading = false } }
        do {
            let page = try await fetch(0, pageSize)
            guard generation == mine else { return }
            items = page.items
            total = page.total
        } catch {
            guard generation == mine else { return }
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        let mine = generation
        isLoading = true
        defer { if generation == mine { isLoading = false } }
        guard let page = try? await fetch(items.count, pageSize), generation == mine else { return }
        let known = Set(items.map(\.Id))
        items += page.items.filter { !known.contains($0.Id) }
        total = page.total
    }
}

/// A sort menu in the bar, for the lists that have more than one order.
struct SortMenu: View {
    @Binding var sort: MusicSort
    var choices: [MusicSort]

    var body: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(choices) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var paged: PagedItems?
    @State private var filter = ""
    @State private var sort: MusicSort = .name

    var body: some View {
        ScrollView {
            if let paged {
                if paged.isLoading, paged.items.isEmpty {
                    SkeletonList(count: 12)
                } else if let error = paged.error, paged.items.isEmpty {
                    ErrorState(error: error) { Task { await paged.reload() } }
                } else if paged.items.isEmpty {
                    EmptyState(symbol: "music.mic", title: "No artists", message: "Nothing matches.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(paged.items) { artist in
                            MusicListRow(item: artist, subtitle: Self.subtitle(artist)) {
                                app.push(.music(.artist(artist.Id)))
                            }
                            .onAppear { if artist.Id == paged.items.last?.Id { Task { await paged.loadMore() } } }
                        }
                        if paged.isLoading { ProgressView().padding() }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Artists")
        .paletteBar()
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter artists")
        .toolbar { SortMenu(sort: $sort, choices: [.name, .recentlyAdded, .random]) }
        .task(id: "\(filter)|\(sort.rawValue)") {
            let term = filter.trimmingCharacters(in: .whitespaces)
            let sort = sort
            let p = PagedItems(pageSize: 200) { start, limit in
                try await client.albumArtists(startIndex: start, limit: limit, searchTerm: term.isEmpty ? nil : term, sort: sort)
            }
            paged = p
            await p.reload()
        }
    }

    static func subtitle(_ artist: BaseItem) -> String? {
        if let genres = artist.Genres, !genres.isEmpty { return genres.prefix(2).joined(separator: ", ") }
        return nil
    }
}

struct AlbumsView: View {
    enum Mode { case all, recentlyAdded }
    let mode: Mode

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var paged: PagedItems?
    @State private var filter = ""
    @State private var sort: MusicSort = .name

    var body: some View {
        ScrollView {
            if let paged {
                if paged.isLoading, paged.items.isEmpty {
                    AlbumGrid(items: [], pendingCount: 8) { _ in }
                        .padding(.top, 12)
                } else if let error = paged.error, paged.items.isEmpty {
                    ErrorState(error: error) { Task { await paged.reload() } }
                } else if paged.items.isEmpty {
                    EmptyState(symbol: "square.stack", title: "No albums", message: "Nothing matches.")
                } else {
                    AlbumGrid(items: paged.items, pendingCount: paged.isLoading ? 4 : 0) {
                        app.push(.music(.album($0.Id)))
                    } onReachEnd: {
                        Task { await paged.loadMore() }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle(mode == .all ? "Albums" : "Recently Added")
        .paletteBar()
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter albums")
        .toolbar {
            if mode == .all {
                SortMenu(sort: $sort, choices: [.name, .artist, .recentlyAdded, .year, .random])
            }
        }
        .task(id: "\(filter)|\(sort.rawValue)") {
            let term = filter.trimmingCharacters(in: .whitespaces)
            let sort = mode == .all ? sort : .recentlyAdded
            let p = PagedItems(pageSize: 60) { start, limit in
                var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: sort, startIndex: start, limit: limit)
                q.searchTerm = term.isEmpty ? nil : term
                return try await client.music(q)
            }
            paged = p
            await p.reload()
        }
    }
}

struct SongsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var paged: PagedItems?
    @State private var filter = ""
    @State private var sort: MusicSort = .name

    var body: some View {
        ScrollView {
            if let paged {
                if paged.isLoading, paged.items.isEmpty {
                    SkeletonList(count: 14)
                } else if let error = paged.error, paged.items.isEmpty {
                    ErrorState(error: error) { Task { await paged.reload() } }
                } else if paged.items.isEmpty {
                    EmptyState(symbol: "music.note", title: "No songs", message: "Nothing matches.")
                } else {
                    LazyVStack(spacing: 0) {
                        PlayShuffleBar {
                            music.play(paged.items, title: "Songs")
                        } onShuffle: {
                            music.play(paged.items, shuffle: true, title: "Songs")
                        }
                        .padding(.vertical, 8)
                        ForEach(paged.items) { song in
                            SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                                music.play(paged.items, startingAt: paged.items.position(of: song) ?? 0, title: "Songs")
                            }
                            .onAppear { if song.Id == paged.items.last?.Id { Task { await paged.loadMore() } } }
                        }
                        if paged.isLoading { ProgressView().padding() }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Songs")
        .paletteBar()
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter songs")
        .toolbar { SortMenu(sort: $sort, choices: [.name, .artist, .recentlyAdded, .recentlyPlayed, .mostPlayed, .random]) }
        .task(id: "\(filter)|\(sort.rawValue)") {
            let term = filter.trimmingCharacters(in: .whitespaces)
            let sort = sort
            let p = PagedItems(pageSize: 150) { start, limit in
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: sort, startIndex: start, limit: limit)
                q.searchTerm = term.isEmpty ? nil : term
                return try await client.music(q)
            }
            paged = p
            await p.reload()
        }
    }
}

/// The songs behind a Discover shelf, as a page of their own.
struct SongListView: View {
    let title: String
    let kind: MusicRoute.SongListKind

    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var songs: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            if isLoading, songs.isEmpty {
                SkeletonList(count: 12)
            } else if let error, songs.isEmpty {
                ErrorState(error: error) { Task { await load() } }
            } else if songs.isEmpty {
                EmptyState(symbol: "music.note", title: "Nothing here yet", message: "Play a few things and this fills in.")
            } else {
                LazyVStack(spacing: 0) {
                    PlayShuffleBar {
                        music.play(songs, title: title)
                    } onShuffle: {
                        music.play(songs, shuffle: true, title: title)
                    }
                    .padding(.vertical, 8)
                    ForEach(songs) { song in
                        SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                            music.play(songs, startingAt: songs.position(of: song) ?? 0, title: title)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(title)
        .paletteBar()
        .task { await load() }
        .reloadWhenItemsChange { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        if client.showsOffline {
            switch kind {
            case .recentlyPlayed: songs = OfflineMusic.recentlyPlayed(limit: 100)
            case .mostPlayed: songs = OfflineMusic.mostPlayed(limit: 100)
            case .favorites: songs = OfflineMusic.favorites()
            }
            return
        }
        do {
            switch kind {
            case .recentlyPlayed: songs = try await client.recentlyPlayedSongs(limit: 100)
            case .mostPlayed: songs = try await client.mostPlayedSongs(limit: 100)
            case .favorites:
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .name, limit: 300)
                q.favorites = true
                songs = try await client.music(q).items
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GenresView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var genres: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var filter = ""

    private var shown: [BaseItem] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return genres }
        return genres.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        ScrollView {
            if isLoading, genres.isEmpty {
                AlbumGrid(items: [], pendingCount: 8) { _ in }.padding(.top, 12)
            } else if let error, genres.isEmpty {
                ErrorState(error: error) { Task { await load() } }
            } else if shown.isEmpty {
                EmptyState(symbol: "guitars", title: "No genres", message: "Nothing matches.")
            } else {
                AlbumGrid(items: shown, subtitleFor: { _ in "Genre" }) {
                    app.push(.music(.genre(id: $0.Id, name: $0.title)))
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Genres")
        .paletteBar()
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter genres")
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { genres = try await client.musicGenres().items } catch { self.error = error.localizedDescription }
    }
}

struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var store = PlaylistStore.shared
    @State private var smart = SmartPlaylistStore.shared
    @State private var newName = ""
    @State private var isNaming = false
    @State private var renaming: BaseItem?
    @State private var renameText = ""
    @State private var editingSmart: SmartPlaylist?
    @State private var deleting: BaseItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isLoading, store.playlists.isEmpty {
                    SkeletonList(count: 6)
                } else if let error = store.lastError, store.playlists.isEmpty {
                    ErrorState(error: error) { Task { await store.refresh() } }
                } else if store.playlists.isEmpty {
                    EmptyState(
                        symbol: "music.note.list",
                        title: "No playlists yet",
                        message: "Make one with the + above, or press and hold any song and choose Add to Playlist."
                    )
                } else {
                    ForEach(store.playlists) { list in
                        MusicListRow(item: list, subtitle: Self.count(list)) {
                            app.push(.music(.playlist(list.Id)))
                        }
                        .contextMenu {
                            MusicItemMenu(item: list)
                            Divider()
                            Button {
                                renameText = list.title
                                renaming = list
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) { deleting = list } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Smart Playlists")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Button {
                            editingSmart = SmartPlaylist()
                        } label: {
                            Label("New", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    Text("Rules, answered from the library every time they're opened. Kept on your devices, not the server.")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 28)
                .padding(.bottom, 8)

                if smart.playlists.isEmpty {
                    Text("None yet. Try “Rock, added in the last 90 days, most played first”.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 12)
                } else {
                    ForEach(smart.playlists) { list in
                        Button {
                            app.push(.music(.smartPlaylist(list.id)))
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.accentSoft)
                                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                                }
                                .frame(width: MusicMetrics.rowArt, height: MusicMetrics.rowArt)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name).font(.body).lineLimit(1).foregroundStyle(Theme.text)
                                    Text(list.summary).font(.caption).lineLimit(2).foregroundStyle(Theme.textDim)
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
                        .contextMenu {
                            Button { editingSmart = list } label: { Label("Edit Rules", systemImage: "slider.horizontal.3") }
                            Button(role: .destructive) { smart.delete(list.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 24)
        }
        .navigationTitle("Playlists")
        .paletteBar()
        .toolbar {
            Button {
                newName = ""
                isNaming = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .task { await store.ensureLoaded() }
        .refreshable { await store.refresh() }
        .alert("New Playlist", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An empty playlist on the server. Add songs from any song's menu.")
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from the server", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every other Jellyfin client loses it too. The songs themselves stay.")
        }
        .sheet(item: $editingSmart) { list in
            SmartPlaylistEditor(playlist: list) { saved in
                smart.upsert(saved)
            }
        }
    }

    static func count(_ list: BaseItem) -> String? {
        guard let n = list.ChildCount else { return nil }
        return "\(n) song\(n == 1 ? "" : "s")"
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let id = try await store.create(name: name, itemIds: [])
            app.toast("Created \(name)", tone: .ok)
            app.push(.music(.playlist(id)))
        } catch {
            app.toast("Couldn't create the playlist: \(error.localizedDescription)", tone: .error)
        }
    }

    private func rename() async {
        guard let list = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, name != list.title else { return }
        do {
            try await store.rename(list.Id, to: name)
        } catch {
            app.toast("Couldn't rename it: \(error.localizedDescription)", tone: .error)
        }
    }

    private func delete() async {
        guard let list = deleting else { return }
        deleting = nil
        do {
            try await store.delete(list.Id)
            app.toast("Deleted \(list.title)", tone: .ok)
        } catch {
            app.toast("Couldn't delete it: \(error.localizedDescription)", tone: .error)
        }
    }
}

struct AudiobooksView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var paged: PagedItems?
    @State private var filter = ""
    @State private var sort: MusicSort = .name

    var body: some View {
        ScrollView {
            if let paged {
                if paged.isLoading, paged.items.isEmpty {
                    AlbumGrid(items: [], pendingCount: 6) { _ in }.padding(.top, 12)
                } else if let error = paged.error, paged.items.isEmpty {
                    ErrorState(error: error) { Task { await paged.reload() } }
                } else if paged.items.isEmpty {
                    EmptyState(symbol: "book", title: "No audiobooks", message: "Nothing matches.")
                } else {
                    AlbumGrid(items: paged.items, pendingCount: paged.isLoading ? 2 : 0, subtitleFor: { $0.AlbumArtist ?? $0.artistLine }) {
                        app.push(.music(.audiobook($0.Id)))
                    } onReachEnd: {
                        Task { await paged.loadMore() }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("Audiobooks")
        .paletteBar()
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter audiobooks")
        .toolbar { SortMenu(sort: $sort, choices: [.name, .artist, .recentlyAdded, .recentlyPlayed]) }
        .task(id: "\(filter)|\(sort.rawValue)") {
            let term = filter.trimmingCharacters(in: .whitespaces)
            let sort = sort
            let p = PagedItems(pageSize: 60) { start, limit in
                var q = JellyfinClient.MusicQuery(types: "AudioBook", sort: sort, startIndex: start, limit: limit)
                q.searchTerm = term.isEmpty ? nil : term
                return try await client.music(q)
            }
            paged = p
            await p.reload()
        }
    }
}

/// Starred albums, artists and songs on one page.
struct MusicFavoritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var albums: [BaseItem] = []
    @State private var artists: [BaseItem] = []
    @State private var songs: [BaseItem] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            if isLoading, albums.isEmpty, artists.isEmpty, songs.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.shelfSpacing) { SkeletonShelf(); SkeletonShelf() }.padding(.top, 12)
            } else if albums.isEmpty, artists.isEmpty, songs.isEmpty {
                EmptyState(symbol: "star", title: "No favorites yet", message: "Press and hold anything in your music to star it.")
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    ArtistShelf(title: "Artists", items: artists) { app.push(.music(.artist($0.Id))) }
                    AlbumShelf(title: "Albums", items: albums) { app.push(.music(.album($0.Id))) }
                    if !songs.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "Songs") {
                                app.push(.music(.songList(title: "Favorite Songs", kind: .favorites)))
                            }
                            PlayShuffleBar {
                                music.play(songs, title: "Favorite Songs")
                            } onShuffle: {
                                music.play(songs, shuffle: true, title: "Favorite Songs")
                            }
                            ForEach(songs.prefix(25)) { song in
                                SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                                    music.play(songs, startingAt: songs.position(of: song) ?? 0, title: "Favorite Songs")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Favorites")
        .paletteBar()
        .task { await load() }
        .reloadWhenItemsChange { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let albumQuery: JellyfinClient.MusicQuery = {
            var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: .name, limit: 60)
            q.favorites = true
            return q
        }()
        let songQuery: JellyfinClient.MusicQuery = {
            var q = JellyfinClient.MusicQuery(types: "Audio", sort: .name, limit: 300)
            q.favorites = true
            return q
        }()
        async let a = client.music(albumQuery)
        async let r = client.albumArtists(limit: 60, favorites: true)
        async let s = client.music(songQuery)
        albums = (try? await a.items) ?? []
        artists = (try? await r.items) ?? []
        songs = (try? await s.items) ?? []
    }
}

// MARK: - Downloaded

/// What is on this device, grouped into the albums it came from. Works with
/// no server at all, which is the point of it.
struct DownloadedMusicView: View {
    /// Songs by default; the Books tab asks for its own.
    var books = false

    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var music

    @State private var downloads = DownloadManager.shared

    private var records: [DownloadRecord] {
        downloads.records.filter { $0.isAudio && $0.status == .complete && ($0.type == "AudioBook") == books }
    }

    private var albums: [DownloadedAlbum] { DownloadedAlbum.group(records) }

    var body: some View {
        ScrollView {
            if records.isEmpty {
                EmptyState(
                    symbol: "arrow.down.circle",
                    title: "Nothing downloaded",
                    message: books
                        ? "Press and hold an audiobook and choose Download. It then plays here with no server at all."
                        : "Press and hold a song or an album and choose Download. It then plays here with no server at all."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !books {
                        PlayShuffleBar {
                            music.play(records.map(\.asItem), title: "Downloaded")
                        } onShuffle: {
                            music.play(records.map(\.asItem), shuffle: true, title: "Downloaded")
                        }
                    }
                    ForEach(albums) { album in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                MusicArtwork(item: album.tracks.first?.asItem, width: 200, radius: 6, placeholderSymbol: album.isBook ? "book" : "music.note")
                                    .frame(width: 64, height: 64)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                                    Text(album.subtitle).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    music.play(album.tracks.map(\.asItem), title: album.title)
                                } label: {
                                    Image(systemName: "play.circle.fill").font(.title)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                            }
                            .padding(.horizontal, Metrics.gutter)
                            .contextMenu {
                                Button(role: .destructive) {
                                    let n = downloads.delete(album.tracks.map(\.itemId))
                                    app.toast("Deleted \(n) download\(n == 1 ? "" : "s")", tone: .ok)
                                } label: {
                                    Label("Remove download", systemImage: "trash")
                                }
                            }
                            ForEach(album.tracks) { record in
                                let item = record.asItem
                                SongRow(
                                    song: item, style: .album, number: record.track ?? 0,
                                    isCurrent: music.current?.Id == item.Id, isPlaying: music.isPlaying
                                ) {
                                    let items = album.tracks.map(\.asItem)
                                    music.play(items, startingAt: items.position(of: item) ?? 0, title: album.title)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(books ? "Downloaded Audiobooks" : "Downloaded")
        .paletteBar()
    }
}

/// Downloaded songs, grouped by album.
struct DownloadedAlbum: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var isBook: Bool
    var tracks: [DownloadRecord]

    static func group(_ records: [DownloadRecord]) -> [DownloadedAlbum] {
        var byKey: [String: [DownloadRecord]] = [:]
        var order: [String] = []
        for record in records {
            let key = record.albumId ?? record.album ?? record.itemId
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(record)
        }
        return order.compactMap { key in
            guard var tracks = byKey[key], let first = tracks.first else { return nil }
            tracks.sort { ($0.disc ?? 1, $0.track ?? 0) < ($1.disc ?? 1, $1.track ?? 0) }
            let isBook = first.type == "AudioBook"
            let count = tracks.count
            let subtitle = [first.artist, isBook ? "Audiobook" : "\(count) song\(count == 1 ? "" : "s")"]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return DownloadedAlbum(
                id: key, title: first.album ?? first.title, subtitle: subtitle, isBook: isBook, tracks: tracks
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

#endif
