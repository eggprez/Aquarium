//  Search, with the recent terms panel the Linux build kept under its search
//  box. Typing is debounced rather than firing a request per keystroke.

import SwiftUI

struct SearchView: View {
    var initialTerm: String = ""

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(Preferences.self) private var prefs

    @State private var term = ""
    @State private var results: [BaseItem] = []
    @State private var total = 0
    /// What the music libraries had to say about the same term. Drawn above
    /// the video grid; empty on a server with no music.
    @State private var music = JellyfinClient.MusicSearchResults()
    @State private var isSearching = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    /// The term the results on screen answer. Until a typed term has been
    /// searched for — the debounce is still running — it counts as searching,
    /// not as having found nothing.
    @State private var searchedTerm: String?
    /// A further page is on its way; the end of the grid can ask more than once.
    @State private var isLoadingPage = false

    private static let debounce = Duration.milliseconds(320)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(tvOS)
                // tvOS has no searchable modifier worth using inside a tab, so
                // the field is part of the page — and now that Search has a
                // place of its own in the tab strip, this is the first thing
                // the selector meets coming down off it, which is what makes
                // the whole tab one press from anywhere.
                //
                // The results underneath are live: `onChange(of: term)` fires
                // on every character the on-screen keyboard commits, debounced
                // by `schedule()`, so the grid fills in as the word is spelled
                // out rather than waiting for the keyboard to be dismissed.
                // Submitting only adds the term to the recents list and skips
                // the debounce.
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                    TextField("Search films, shows and episodes", text: $term)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            prefs.rememberSearch(term)
                            schedule(immediate: true)
                        }
                    if isSearching {
                        ProgressView()
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .focusSection()
                #endif

                if term.trimmingCharacters(in: .whitespaces).isEmpty {
                    recents
                } else if isSearching || isPending, results.isEmpty {
                    SkeletonGrid(count: 9)
                } else if let error, !isPending {
                    ErrorState(error: error) { schedule(immediate: true) }
                } else if results.isEmpty, music.isEmpty {
                    EmptyState(
                        symbol: "magnifyingglass",
                        title: "No matches",
                        message: "Nothing in your libraries matches “\(term)”."
                    )
                } else {
                    #if os(iOS)
                    musicResults
                    #endif
                    if !results.isEmpty {
                    Text("\(total) result\(total == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, Metrics.gutter)
                    }
                    if !results.isEmpty {
                    MediaGrid(items: results) { item in
                        // Opening a result is the one unambiguous sign that a
                        // term was worth keeping — a debounced search fires on
                        // every prefix typed, and "b", "br", "bre" are not
                        // searches anyone wants offered back to them.
                        prefs.rememberSearch(term)
                        app.push(.item(item.Id))
                    } onReachEnd: {
                        Task { await loadMore() }
                    }
                    .padding(.bottom, 24)
                    }
                }
            }
            .padding(.top, 8)
        }
        .screenTitle("Search")
        .paletteBar()
        #if os(iOS)
        // Always showing, not tucked under the title until the page is pulled
        // down. That tuck is the system's default for a field in a pushed
        // page's bar, and Search is a pushed page whenever it lives in More —
        // which is where it lives unless someone has made it a tab. A search
        // screen that opens without anywhere to type reads as broken.
        .searchable(
            text: $term,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: app.hasAudio ? "Movies, shows, music, books" : "Movies, shows, episodes"
        )
        #elseif !os(tvOS)
        .searchable(text: $term, placement: .toolbar, prompt: app.hasAudio ? "Movies, shows, music, books" : "Movies, shows, episodes")
        #endif
        #if !os(tvOS)
        .onSubmit(of: .search) {
            prefs.rememberSearch(term)
            schedule(immediate: true)
        }
        #endif
        .onChange(of: term) { _, _ in schedule() }
        // A watched tick or a star set from a result's own press-and-hold menu
        // is drawn on the card it was set from, and the card is a copy of what
        // the server said a moment ago.
        .reloadWhenItemsChange { schedule(immediate: true) }
        #if os(tvOS)
        // Leaving the tab empties the field.
        //
        // A television's tabs are all alive at once — the strip is a `TabView`
        // and nothing is torn down when you move along it — so a search left
        // half-typed was still sitting there, results and all, whenever you
        // came back, however long later. Worse, it is the first thing the
        // selector meets coming down off the strip, so the way back into Search
        // ran straight through somebody else's half-finished word. A phone's
        // field is in the navigation bar and dismisses itself; this is the same
        // ending, said explicitly.
        //
        // On the way out rather than on the way in, so the tab is already empty
        // the moment it is opened rather than clearing itself in front of you.
        // Opening a result doesn't count: a title on this platform is presented
        // over the shell (see `AppModel.detailRoot`) and the selection stays on
        // Search the whole time, which is exactly right — going back from a
        // film you searched for should land on the search that found it.
        .onChange(of: app.selection) { previous, _ in
            guard previous == .search else { return }
            reset()
        }
        #endif
        .onAppear {
            if term.isEmpty, !initialTerm.isEmpty {
                term = initialTerm
                schedule(immediate: true)
            }
        }
    }

    @ViewBuilder
    private var recents: some View {
        if prefs.recentSearches.isEmpty {
            EmptyState(
                symbol: "magnifyingglass",
                title: "Search your libraries",
                message: app.hasAudio
                    ? "Find a film, a show, an episode, an artist, an album, a song or an audiobook by name."
                    : "Find a film, a show or a single episode by name."
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent searches")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Clear") { prefs.clearRecentSearches() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                ForEach(prefs.recentSearches, id: \.self) { recent in
                    Button {
                        term = recent
                        schedule(immediate: true)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Theme.textDim)
                            Text(recent).foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .rowButtonStyle()
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    #if os(iOS)
    /// Artists, albums and a few songs, ahead of the films and shows. Each
    /// opens into the Music tab, which is where the rest of it lives.
    @ViewBuilder
    private var musicResults: some View {
        if !music.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                ArtistShelf(title: "Artists", items: Array(music.artists.prefix(12))) { artist in
                    prefs.rememberSearch(term)
                    app.show(.music)
                    app.push(.music(.artist(artist.Id)))
                }
                AlbumShelf(title: "Albums", items: Array(music.albums.prefix(12))) { album in
                    prefs.rememberSearch(term)
                    app.show(.music)
                    app.push(.music(.album(album.Id)))
                }
                if !music.songs.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                        ShelfHeading(title: "Songs") {
                            prefs.rememberSearch(term)
                            app.show(.music)
                        }
                        ForEach(music.songs.prefix(5)) { song in
                            SongRow(song: song) {
                                prefs.rememberSearch(term)
                                MusicPlayer.shared.play(music.songs, startingAt: music.songs.position(of: song) ?? 0, title: "Search")
                            }
                        }
                    }
                }
                AlbumShelf(title: "Audiobooks", items: Array(music.audiobooks.prefix(12)), subtitleFor: { $0.AlbumArtist }) { book in
                    prefs.rememberSearch(term)
                    app.show(.books)
                    app.push(.music(.audiobook(book.Id)))
                }
            }
            .padding(.bottom, 8)
        }
    }
    #endif

    #if os(tvOS)
    /// Back to an empty field and the recents list under it.
    private func reset() {
        searchTask?.cancel()
        searchTask = nil
        term = ""
        results = []
        total = 0
        error = nil
        isSearching = false
        searchedTerm = nil
    }
    #endif

    /// A term has been typed that hasn't been searched for yet.
    private var isPending: Bool {
        term.trimmingCharacters(in: .whitespaces) != searchedTerm
    }

    /// One search in flight at a time; a query typed a letter at a time costs
    /// one request, not eleven.
    private func schedule(immediate: Bool = false) {
        searchTask?.cancel()
        let query = term.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = []
            total = 0
            music = .init()
            error = nil
            isSearching = false
            searchedTerm = nil
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
            }
            await run(query)
        }
    }

    private func run(_ query: String) async {
        isSearching = true
        error = nil
        // A search overtaken by the next one leaves the flag to that one.
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            async let musicTask: JellyfinClient.MusicSearchResults? = app.hasAudio ? client.searchMusic(query, limit: 12) : nil
            let response = try await client.search(query)
            let found = (try? await musicTask) ?? nil
            guard !Task.isCancelled else { return }
            results = response.items
            total = response.total
            music = found ?? .init()
            searchedTerm = query
        } catch is CancellationError {
            // Overtaken by the next keystroke; that search will answer.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            results = []
            searchedTerm = query
        }
    }

    private func loadMore() async {
        let query = term.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, query == searchedTerm, results.count < total,
              !isSearching, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        guard let response = try? await client.search(query, startIndex: results.count) else { return }
        // The term may have changed while this page was on its way, and these
        // would be the old term's results.
        guard term.trimmingCharacters(in: .whitespaces) == query, searchedTerm == query else { return }
        let known = Set(results.map(\.Id))
        results += response.items.filter { !known.contains($0.Id) }
    }
}
