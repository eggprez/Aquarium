//  One music search, offered in three places: the Search page the whole
//  app shares, the Music tab's own field, and the Music door under
//  Downloads. The same engine answers all three and the same view draws
//  what it found, so a term reads the same wherever it was typed.
//
//  With a server in reach the library is searched; with it gone, or lost
//  mid-search, what is downloaded answers instead. The Downloads page asks
//  for the downloads alone even while online: that page is what is on the
//  device, and a hit that would have to stream would be a lie there.

import SwiftUI

#if os(iOS)

// MARK: - The engine

@MainActor
enum MusicSearch {
    /// What is searched: the library (falling back to the downloads with
    /// the server gone), or the downloads alone.
    enum Scope: Hashable { case library, downloads }

    /// The results and where they came from. `fromDevice` results open the
    /// on-device pages, whose Ids may be the local `local-artist:` kind.
    struct Answer {
        var results = JellyfinClient.MusicSearchResults()
        var fromDevice = false
    }

    /// Whether this term can be answered from memory, with no request.
    static func answersLocally(scope: Scope, client: JellyfinClient) -> Bool {
        scope == .downloads || client.showsOffline
    }

    /// The downloads' answer, in one pass over the songs on the device.
    static func onDevice(_ query: String, limit: Int = 24) -> Answer {
        Answer(results: OfflineMusic.search(query, limit: limit), fromDevice: true)
    }

    /// The answer for `query`. Throws only when the server failed *and* the
    /// downloads had nothing to say for the term.
    static func run(_ query: String, scope: Scope, client: JellyfinClient, limit: Int = 24) async throws -> Answer {
        if answersLocally(scope: scope, client: client) { return onDevice(query, limit: limit) }
        do {
            var found = try await client.searchMusic(query, limit: limit)
            found.audiobooks = []
            return Answer(results: found, fromDevice: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The server went away mid-search: what is here still counts.
            let local = onDevice(query, limit: limit)
            if local.results.isEmpty { throw error }
            return local
        }
    }

    /// What an empty result says, in each place.
    static func noMatchesMessage(for query: String, fromDevice: Bool, scope: Scope) -> String {
        switch (scope, fromDevice) {
        case (.downloads, _): "Nothing downloaded matches “\(query)”."
        case (.library, true): "Nothing downloaded matches “\(query)”. The rest of the library is searched once you're back online."
        case (.library, false): "Nothing in your music matches “\(query)”."
        }
    }
}

// MARK: - The results

/// Artists, albums, songs and playlists a term found, each opening its own
/// page. Drawn full-length on the music pages and abridged on the Search
/// page, where films and shows follow underneath.
struct MusicSearchResultsView: View {
    let results: JellyfinClient.MusicSearchResults
    /// The results came from the downloads, so they open the on-device pages.
    var fromDevice = false
    /// The Search page: a few of each, and every tap goes to the Music tab
    /// first, which is where the rest of it lives.
    var abridged = false
    /// Said once above the shelves when the downloads answered for the
    /// library — nil where the page's own field already says so.
    var footnote: String? = nil
    /// Called as a result opens or plays — the Search page keeps the term.
    var onOpen: (() -> Void)? = nil

    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var music

    private var artists: [BaseItem] { abridged ? Array(results.artists.prefix(12)) : results.artists }
    private var albums: [BaseItem] { abridged ? Array(results.albums.prefix(12)) : results.albums }
    private var songs: [BaseItem] { abridged ? Array(results.songs.prefix(5)) : results.songs }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
            if let footnote {
                Label(footnote, systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, Metrics.gutter)
            }
            ArtistShelf(title: "Artists", items: artists) { open(.artist($0.Id)) }
            AlbumShelf(title: "Albums", items: albums) { open(.album($0.Id)) }
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                    if abridged {
                        ShelfHeading(title: "Songs") {
                            onOpen?()
                            app.show(.music)
                        }
                    } else {
                        ShelfHeading(title: "Songs")
                    }
                    ForEach(songs) { song in
                        SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                            onOpen?()
                            music.play(results.songs, startingAt: results.songs.position(of: song) ?? 0, title: "Search")
                        }
                    }
                }
            }
            AlbumShelf(title: "Playlists", items: results.playlists) { open(.playlist($0.Id)) }
        }
    }

    private func open(_ route: MusicRoute) {
        onOpen?()
        if abridged { app.show(.music) }
        if fromDevice { app.pushOnDevice(route) } else { app.push(.music(route)) }
    }
}

// MARK: - The page

/// Everything matching a term, grouped by what it is: the Music tab's
/// search, and the Downloads page's over the downloads alone. Debounced
/// like the video search: one request per pause in typing, not per
/// keystroke; the downloads answer at once, with no pause.
struct MusicSearchView: View {
    let term: String
    var scope: MusicSearch.Scope = .library

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var answer = MusicSearch.Answer()
    @State private var isSearching = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            let query = term.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: scope == .downloads ? "Search your downloads" : "Search your music",
                    message: scope == .downloads
                        ? "Artists, albums, songs and playlists on this device, by name."
                        : "Artists, albums, songs and playlists, by name."
                )
            } else if isSearching, answer.results.isEmpty {
                SkeletonList(count: 8)
            } else if let error {
                ErrorState(error: error) { schedule(query, immediate: true) }
            } else if answer.results.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass", title: "No matches",
                    message: MusicSearch.noMatchesMessage(for: query, fromDevice: answer.fromDevice, scope: scope)
                )
            } else {
                MusicSearchResultsView(
                    results: answer.results,
                    fromDevice: answer.fromDevice,
                    // The field's own prompt says "Downloaded music" when the
                    // server is known to be gone; this covers the server
                    // that went while the search was out.
                    footnote: scope == .library && answer.fromDevice && !client.showsOffline
                        ? "From this device: the server stopped answering." : nil
                )
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
            answer = .init()
            error = nil
            return
        }
        // The downloads are already in memory: no pause, no request.
        if MusicSearch.answersLocally(scope: scope, client: client) {
            error = nil
            answer = MusicSearch.onDevice(query)
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
                let found = try await MusicSearch.run(query, scope: scope, client: client)
                guard !Task.isCancelled else { return }
                answer = found
            } catch is CancellationError {
                // Overtaken by the next keystroke; that search will answer.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

#endif
