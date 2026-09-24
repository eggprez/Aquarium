//  The Music tab: Discover and the library behind one segmented switch,
//  with search in the bar above both.
//
//  A music app spends a tab bar on this; here it is one tab of a larger app,
//  so its own sections are a switch at the top rather than a bar at the
//  bottom. Discover is the default because it is the page that has
//  something to say before you have decided what to look for.

import SwiftUI

#if os(iOS)

struct MusicTabView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    enum Page: String, CaseIterable, Identifiable {
        case listenNow = "Discover"
        case library = "Library"
        var id: String { rawValue }
    }

    @State private var page: Page = .listenNow
    @State private var term = ""
    @State private var isSearchPresented = false

    var body: some View {
        Group {
            if isSearching {
                MusicSearchView(term: term)
            } else if client.showsOffline {
                // The same two pages, from this device. See `OnDeviceViews`.
                switch page {
                case .listenNow: OfflineListenNowView()
                case .library: OnDeviceLibraryView()
                }
            } else {
                switch page {
                case .listenNow: ListenNowView()
                case .library: MusicLibraryView()
                }
            }
        }
        .background(Theme.background)
        // There while songs are downloading, and the way to the queue.
        .safeAreaInset(edge: .top, spacing: 0) { DownloadQueueBanner() }
        .navigationTitle("Music")
        // The switch *is* the title: a large "Music" over "Discover" over
        // a search field was three headings before any content.
        .navigationBarTitleDisplayMode(.inline)
        .paletteBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
        }
        .searchable(
            text: $term, isPresented: $isSearchPresented, placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: client.showsOffline ? "Downloaded music" : "Artists, albums, songs"
        )
        // The Add to Playlist menu reads this list; loaded here so it is
        // there by the time anyone holds a song down.
        .task { await PlaylistStore.shared.ensureLoaded() }
        // What the offline pages are drawn from, topped up while there is a
        // server to ask — see `OfflineMusicIndex.refresh`.
        .task(id: client.showsOffline) { await OfflineMusicIndex.shared.refresh() }
    }

    private var isSearching: Bool {
        isSearchPresented || !term.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Routing

/// The far end of every `Route.music`.
struct MusicDestination: View {
    let route: MusicRoute

    @Environment(JellyfinClient.self) private var client

    var body: some View {
        // The page colour is put here once: a pushed page otherwise sits on
        // the system's black (or white), a step off every other screen.
        page.background(Theme.background)
    }

    @ViewBuilder
    private var page: some View {
        if case .onDevice(let inner) = route {
            // Pinned to this device. A route with no on-device page of its
            // own (a smart playlist, a book) opens as it would anywhere.
            if let local = Self.onDevice(inner) { local } else { MusicDestination(route: inner) }
        } else if client.showsOffline, let local = Self.onDevice(route) {
            local
        } else {
            online
        }
    }

    /// The page this route gets with no server. Every music route has one;
    /// the audiobook pages fall back inside themselves instead, because a
    /// book's page is the same page either way.
    private static func onDevice(_ route: MusicRoute) -> AnyView? {
        switch route {
        case .artist(let id): AnyView(OnDeviceCollectionView(kind: .artist(id)))
        case .album(let id): AnyView(OnDeviceCollectionView(kind: .album(id)))
        case .genre(_, let name): AnyView(OnDeviceCollectionView(kind: .genre(name)))
        case .playlist(let id): AnyView(OnDeviceCollectionView(kind: .playlist(id)))
        case .artists: AnyView(OnDeviceListView(kind: .artists))
        case .albums: AnyView(OnDeviceListView(kind: .albums))
        case .recentlyAdded: AnyView(OnDeviceListView(kind: .recentAlbums))
        case .favorites: AnyView(OnDeviceListView(kind: .favorites))
        case .songs: AnyView(OnDeviceListView(kind: .songs))
        case .genres: AnyView(OnDeviceListView(kind: .genres))
        case .playlists: AnyView(OnDeviceListView(kind: .playlists))
        case .audiobooks: AnyView(DownloadedMusicView(books: true))
        default: nil
        }
    }

    @ViewBuilder
    private var online: some View {
        switch route {
        case .artist(let id): ArtistDetailView(artistId: id)
        case .album(let id): AlbumDetailView(albumId: id)
        case .genre(let id, let name): GenreDetailView(genreId: id, name: name)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .smartPlaylist(let id): SmartPlaylistDetailView(playlistId: id)
        case .audiobook(let id): AudiobookDetailView(bookId: id)
        case .author(let id, let name): AuthorView(authorId: id, name: name)
        case .artists: ArtistsView()
        case .albums: AlbumsView(mode: .all)
        case .recentlyAdded: AlbumsView(mode: .recentlyAdded)
        case .favorites: MusicFavoritesView()
        case .songs: SongsView()
        case .genres: GenresView()
        case .playlists: PlaylistsView()
        case .audiobooks: AudiobooksView()
        case .downloaded: OnDeviceLibraryView(isDownloadedPage: true)
        case .downloadedBooks: DownloadedMusicView(books: true)
        case .onDevice(let inner): MusicDestination(route: inner)
        case .songList(let title, let kind): SongListView(title: title, kind: kind)
        case .search: MusicSearchView(term: "")
        }
    }
}

// MARK: - Search

/// Everything matching a term, grouped by what it is. Debounced like the
/// video search: one request per pause in typing, not per keystroke.
struct MusicSearchView: View {
    let term: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var results = JellyfinClient.MusicSearchResults()
    @State private var isSearching = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            let query = term.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: "Search your music",
                    message: "Artists, albums, songs and playlists, by name."
                )
            } else if isSearching, results.isEmpty {
                SkeletonList(count: 8)
            } else if let error {
                ErrorState(error: error) { schedule(query, immediate: true) }
            } else if results.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass", title: "No matches",
                    message: client.showsOffline
                        ? "Nothing downloaded matches “\(query)”. The rest of the library is searched once you're back online."
                        : "Nothing in your music matches “\(query)”."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    ArtistShelf(title: "Artists", items: results.artists) { app.push(.music(.artist($0.Id))) }
                    AlbumShelf(title: "Albums", items: results.albums) { app.push(.music(.album($0.Id))) }
                    if !results.songs.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "Songs")
                            ForEach(results.songs) { song in
                                SongRow(
                                    song: song,
                                    isCurrent: music.current?.Id == song.Id,
                                    isPlaying: music.isPlaying
                                ) {
                                    music.play(results.songs, startingAt: results.songs.position(of: song) ?? 0, title: "Search")
                                }
                            }
                        }
                    }
                    AlbumShelf(title: "Playlists", items: results.playlists) { app.push(.music(.playlist($0.Id))) }
                }
                .padding(.vertical, 12)
                .padding(.bottom, 24)
            }
        }
        .onChange(of: term, initial: true) { _, new in schedule(new.trimmingCharacters(in: .whitespaces)) }
        .reloadWhenItemsChange { schedule(term.trimmingCharacters(in: .whitespaces), immediate: true) }
    }

    private func schedule(_ query: String, immediate: Bool = false) {
        task?.cancel()
        guard !query.isEmpty else {
            results = .init()
            error = nil
            return
        }
        // Offline the answer is already in memory: no pause, no request.
        if client.showsOffline {
            error = nil
            results = OfflineMusic.search(query)
            return
        }
        task = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
            }
            isSearching = true
            error = nil
            defer { isSearching = false }
            do {
                var found = try await client.searchMusic(query)
                found.audiobooks = []
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                // The server went away mid-search: what is here still counts.
                let local = OfflineMusic.search(query)
                if local.isEmpty { self.error = error.localizedDescription } else { results = local }
            }
        }
    }
}

// MARK: - Mini player and Now Playing hooks for the shell

extension View {
    /// The bar above the tab bar that shows what is playing, on every tab.
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
            .modifier(PlaylistPromptHost())
    }

    /// The full Now Playing screen, presented over the whole shell.
    func nowPlayingSheet() -> some View {
        modifier(NowPlayingPresenter())
    }
}

/// The "name your new playlist" alert, hung once on each shell so a menu
/// anywhere can raise it. See `PlaylistPrompt`.
private struct PlaylistPromptHost: ViewModifier {
    @State private var prompt = PlaylistPrompt.shared

    func body(content: Content) -> some View {
        @Bindable var prompt = prompt
        content.alert("New Playlist", isPresented: $prompt.isPresented) {
            TextField("Name", text: $prompt.name)
            Button("Create") { Task { await prompt.create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Made on the server, with this in it.")
        }
    }
}

/// Owns the flag the mini player flips. One per shell, so that a tap on the
/// bar in any tab opens the same screen.
private struct NowPlayingPresenter: ViewModifier {
    @Environment(MusicPlayer.self) private var music
    @State private var presenter = NowPlayingPresentation.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { presenter.isPresented && music.isActive },
                set: { presenter.isPresented = $0 }
            )) {
                NowPlayingView()
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.background)
            }
    }
}

/// Whether Now Playing is up. Shared, because the bar that opens it and the
/// modifier that presents it are in different places in the tree.
@MainActor
@Observable
final class NowPlayingPresentation {
    static let shared = NowPlayingPresentation()
    var isPresented = false
    private init() {}
}

#endif

#if !os(iOS)
extension View {
    /// The music player is iPhone and iPad only for now; the other shells
    /// keep their layout unchanged.
    func withMiniPlayer() -> some View { self }
    func nowPlayingSheet() -> some View { self }
}
#endif
