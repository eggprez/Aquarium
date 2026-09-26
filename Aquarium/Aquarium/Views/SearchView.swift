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
    #if os(macOS)
    /// Return was pressed in the sidebar's field: once the results for that
    /// term land, a title that matches it exactly is opened — the Mac's
    /// "Return opens the top hit", without opening a guess.
    @State private var openExactMatchWhenReady = false
    #endif

    private static let debounce = Duration.milliseconds(320)

    /// What kind of thing to look for — the Mac's scope bar under the field.
    /// Everywhere else it stays on `.all`.
    enum Scope: String, CaseIterable, Identifiable {
        case all, films, shows, episodes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .films: "Films"
            case .shows: "Shows"
            case .episodes: "Episodes"
            }
        }
        var types: String {
            switch self {
            case .all: "Movie,Series,Episode"
            case .films: "Movie"
            case .shows: "Series"
            case .episodes: "Episode"
            }
        }
    }
    @State private var scope: Scope = .all

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
                    #if os(macOS)
                    // The toolbar's spinner says a search is running; the page
                    // itself stays empty rather than flashing nine grey
                    // posters per keystroke. Results already on screen are
                    // kept until the new ones land — see `run`.
                    Color.clear.frame(height: 1)
                    #else
                    SkeletonGrid(count: 9)
                    #endif
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
                    // On a Mac the count is the window's subtitle, not a line
                    // on the page.
                    #if !os(macOS)
                    if !results.isEmpty {
                    Text("\(total) result\(total == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, Metrics.gutter)
                    }
                    #endif
                    #if os(macOS)
                    if !results.isEmpty, scope == .all {
                        groupedResults
                    } else if !results.isEmpty {
                        resultGrid(results, pages: true)
                    }
                    #else
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
                    #endif
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
        #elseif os(macOS)
        // The field is the sidebar's — see `RootView` — and this page mirrors
        // its text. Typing there, whatever section was showing, lands here
        // once Return is pressed; the scopes are a toolbar picker, where a
        // Mac window keeps its filters.
        .onChange(of: app.sidebarSearchTerm, initial: true) { _, new in
            if term != new { term = new }
        }
        // `initial` because the page is usually built *by* the submit — the
        // section wasn't showing until Return brought it up — and a counter
        // bumped before the page existed is one it would never see change.
        // A page reappearing later (⌘3 back to Search) sees a stale stamp
        // and does nothing.
        .onChange(of: app.sidebarSearchSubmitted, initial: true) { _, _ in
            guard let at = app.sidebarSearchSubmittedAt, Date().timeIntervalSince(at) < 1 else { return }
            submittedFromSidebar()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Which kind of title to search for")
            }
            ToolbarItem(placement: .primaryAction) {
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .navigationSubtitle(subtitle)
        .onChange(of: scope) { _, _ in
            // The old scope's results stay up until the new ones land.
            schedule(immediate: true)
        }
        #endif
        #if os(iOS)
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
                #if os(macOS)
                // The sidebar's field shows what this page is searching for.
                app.sidebarSearchTerm = initialTerm
                #endif
                schedule(immediate: true)
            }
        }
    }

    #if os(macOS)
    /// The window's subtitle: how many the term found, while it has found any.
    private var subtitle: String {
        guard !results.isEmpty, searchedTerm != nil else { return "" }
        return "\(total.formatted()) result\(total == 1 ? "" : "s")"
    }

    /// Return in the sidebar's field. The term is searched for at once, and
    /// a title that matches it exactly is opened — now, if the results on
    /// screen already answer this term, or once they land.
    private func submittedFromSidebar() {
        // The field's text, not this page's copy of it: the copy follows a
        // step behind, and a submit that arrives with the page's first draw
        // finds it still empty.
        let query = app.sidebarSearchTerm.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if term != app.sidebarSearchTerm { term = app.sidebarSearchTerm }
        if searchedTerm == query, !isPending {
            openExactMatchWhenReady = false
            openExactMatch(for: query)
            return
        }
        openExactMatchWhenReady = true
        schedule(immediate: true)
    }

    /// One result whose title is the term itself, and no other: two titles
    /// called the same thing — a film and its remake — are a choice to make,
    /// not one to have made.
    private func openExactMatch(for query: String) {
        let hits = results.filter { $0.title.caseInsensitiveCompare(query) == .orderedSame }
        guard hits.count == 1, let hit = hits.first else { return }
        prefs.rememberSearch(query)
        app.push(.item(hit.Id))
    }
    #endif

    #if os(macOS)
    /// Films, then shows, then episodes, each under its own heading, so a
    /// search reads the way the TV app's does rather than as one grid of
    /// everything the term touched. Paging carries on off the end of the last
    /// group.
    @ViewBuilder
    private var groupedResults: some View {
        let groups: [(String, [BaseItem])] = [
            ("Films", results.filter { $0.kind == "Movie" }),
            ("Shows", results.filter { $0.kind == "Series" }),
            ("Episodes", results.filter { $0.isEpisode }),
        ].filter { !$0.1.isEmpty }
        ForEach(Array(groups.enumerated()), id: \.element.0) { index, group in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.0)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(group.1.count)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    if group.1.count > 6, let scope = Scope.allCases.first(where: { $0.title == group.0 }) {
                        Button("Show Only \(group.0)") { self.scope = scope }
                            .buttonStyle(.link)
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                resultGrid(group.1, pages: index == groups.count - 1)
            }
        }
    }

    private func resultGrid(_ items: [BaseItem], pages: Bool) -> some View {
        MediaGrid(items: items) { item in
            prefs.rememberSearch(term)
            app.push(.item(item.Id))
        } onReachEnd: {
            if pages { Task { await loadMore() } }
        }
        .padding(.bottom, 24)
    }
    #endif

    @ViewBuilder
    private var recents: some View {
        #if os(macOS)
        // The recent terms drop down from the sidebar's field (see
        // `RootView`); the page under an empty field just says what it is for.
        EmptyState(
            symbol: "magnifyingglass",
            title: "Search Your Libraries",
            message: "Type a film, show or episode name in the sidebar's search field and press Return."
        )
        #else
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
        #endif
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
            // Music is asked for only where there is somewhere to show it —
            // the phone's Music tab. Asked for elsewhere it came back and was
            // counted as a match, and a term that matched nothing but an
            // album drew a page with nothing on it.
            #if os(iOS)
            async let musicTask: JellyfinClient.MusicSearchResults? = app.hasAudio ? client.searchMusic(query, limit: 12) : nil
            #endif
            let response = try await client.search(query, types: scope.types)
            #if os(iOS)
            let found = (try? await musicTask) ?? nil
            #else
            let found: JellyfinClient.MusicSearchResults? = nil
            #endif
            guard !Task.isCancelled else { return }
            results = Self.ranked(response.items, for: query)
            total = response.total
            music = found ?? .init()
            searchedTerm = query
            #if os(macOS)
            if openExactMatchWhenReady {
                openExactMatchWhenReady = false
                openExactMatch(for: query)
            }
            #endif
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
        guard let response = try? await client.search(query, startIndex: results.count, types: scope.types) else { return }
        // The term may have changed while this page was on its way, and these
        // would be the old term's results.
        guard term.trimmingCharacters(in: .whitespaces) == query, searchedTerm == query else { return }
        let known = Set(results.map(\.Id))
        // Ranked within the page only: re-sorting everything would move the
        // cards already on screen out from under the pointer.
        results += Self.ranked(response.items.filter { !known.contains($0.Id) }, for: query)
    }

    /// The server's order, made to read like a search. Jellyfin answers
    /// `searchTerm` in no order worth keeping — "star" put South Park's
    /// "Starvin' Marvin" ahead of Star Wars — so: the title itself, then titles
    /// that start with the term as a word, then a word inside the title, then
    /// the term inside a word, then anything the server matched some other way
    /// (a show's name on one of its episodes). Films and shows go ahead of
    /// episodes within each tier, and the server's order breaks the ties.
    static func ranked(_ items: [BaseItem], for query: String) -> [BaseItem] {
        let term = query.lowercased()
        func isWordStart(_ name: String, at range: Range<String.Index>) -> Bool {
            range.lowerBound == name.startIndex
                || !name[name.index(before: range.lowerBound)].isLetter
        }
        func isWordEnd(_ name: String, at range: Range<String.Index>) -> Bool {
            range.upperBound == name.endIndex || !name[range.upperBound].isLetter
        }
        func tier(_ item: BaseItem) -> Int {
            let name = item.title.lowercased()
            if name == term { return 0 }
            var best = 5
            var from = name.startIndex
            while let r = name.range(of: term, range: from..<name.endIndex) {
                let start = isWordStart(name, at: r), end = isWordEnd(name, at: r)
                let rank = switch (r.lowerBound == name.startIndex, start && end, start) {
                case (true, true, _): 1
                case (_, true, _): 2
                case (_, _, true): 3
                default: 4
                }
                best = min(best, rank)
                from = name.index(after: r.lowerBound)
            }
            return best
        }
        return items.enumerated()
            .map { (offset: $0.offset, item: $0.element, key: (tier($0.element), $0.element.isEpisode ? 1 : 0)) }
            .sorted { a, b in
                if a.key.0 != b.key.0 { return a.key.0 < b.key.0 }
                if a.key.1 != b.key.1 { return a.key.1 < b.key.1 }
                return a.offset < b.offset
            }
            .map(\.item)
    }
}
