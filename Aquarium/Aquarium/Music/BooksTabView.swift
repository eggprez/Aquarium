//  Audiobooks: their own tab, kept apart from music on purpose.
//
//  A book is listened to once, over weeks, from where it was left — none of
//  which is true of a record — so the page leads with what is in progress,
//  then what is new, then everything, by title or by author. The player
//  underneath is the music player, which already knows a book from a song:
//  chapters, a resume point, a speed, and fifteen-and-thirty-second skips in
//  place of previous and next.

import SwiftUI

#if os(iOS)

struct BooksTabView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var inProgress: [BaseItem] = []
    @State private var recent: [BaseItem] = []
    @State private var authors: [BaseItem] = []
    @State private var paged: PagedItems?
    @State private var isLoading = true
    @State private var error: String?
    @State private var term = ""
    @State private var isSearchPresented = false
    @State private var sort: MusicSort = .name

    private var isSearching: Bool { isSearchPresented || !term.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if client.showsOffline {
                OfflineBooksView(term: term)
            } else if isSearching {
                BookSearchView(term: term)
            } else {
                front
            }
        }
        .background(Theme.background)
        .navigationTitle("Audiobooks")
        .paletteBar()
        .toolbar {
            if !isSearching, !client.showsOffline {
                SortMenu(sort: $sort, choices: [.name, .artist, .recentlyAdded, .recentlyPlayed, .year])
            }
        }
        .searchable(
            text: $term, isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Titles and authors"
        )
        .task(id: client.showsOffline) { await OfflineMusicIndex.shared.refresh() }
    }

    private var front: some View {
        ScrollView {
            if isLoading, paged == nil {
                VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    SkeletonShelf()
                    AlbumGrid(items: [], pendingCount: 6) { _ in }
                }
                .padding(.top, 12)
            } else if let error, inProgress.isEmpty, recent.isEmpty, (paged?.items.isEmpty ?? true) {
                ErrorState(error: error) { Task { await load() } }
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    // In the page rather than pinned over it: an inset at the
                    // top of this tab costs it its large title.
                    DownloadQueueBanner(books: true)
                    AlbumShelf(title: "Continue Listening", items: inProgress, subtitleFor: { Self.progressLine($0) }) {
                        open($0)
                    }
                    AlbumShelf(title: "Recently Added", items: recent, subtitleFor: { $0.AlbumArtist ?? $0.artistLine }) {
                        open($0)
                    }
                    // Names, not pictures. An author is an artist entry on the
                    // server and the artwork it picks up comes from music
                    // metadata providers, which match a novelist's name to
                    // whichever band shares it.
                    if !authors.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "Authors")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(authors) { author in
                                        Button {
                                            app.push(.music(.author(id: author.Id, name: author.title)))
                                        } label: {
                                            Text(author.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(Theme.text)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(Theme.raised, in: Capsule())
                                                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, Metrics.gutter)
                            }
                        }
                    }
                    if let paged {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "All Books", subtitle: "\(paged.total) title\(paged.total == 1 ? "" : "s")")
                            if paged.items.isEmpty, !paged.isLoading {
                                EmptyState(symbol: "book", title: "No audiobooks", message: "Nothing has been scanned into this library yet.")
                            } else {
                                AlbumGrid(items: paged.items, pendingCount: paged.isLoading ? 2 : 0, subtitleFor: { $0.AlbumArtist ?? $0.artistLine }) {
                                    open($0)
                                } onReachEnd: {
                                    Task { await paged.loadMore() }
                                }
                            }
                        }
                    }
                    if DownloadManager.shared.records.contains(where: { $0.type == "AudioBook" && $0.status == .complete }) {
                        Button {
                            app.push(.music(.downloadedBooks))
                        } label: {
                            Label("Downloaded audiobooks", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .appButtonStyle()
                        .padding(.horizontal, Metrics.gutter)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .refreshable { await load() }
        .task(id: sort.rawValue) { await load() }
        .reloadWhenItemsChange { await load() }
    }

    private func open(_ book: BaseItem) {
        app.push(.music(.audiobook(book.Id)))
    }

    /// "42% · 5h 12m left", for a book that has been started.
    static func progressLine(_ book: BaseItem) -> String? {
        guard let fraction = book.progressFraction, let total = book.RunTimeTicks else { return book.AlbumArtist }
        let left = Format.ticks(Int64(Double(total) * (1 - fraction)))
        return "\(Int(fraction * 100))% · \(left) left"
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let libraries = app.audiobookLibraries.map(\.Id)
        // One library is the common case and gets the exact parent; several
        // are searched across the whole account, where only the type filter
        // separates them from music.
        let parent = libraries.count == 1 ? libraries.first : nil
        async let resumeTask = client.resumeAudio(limit: 20)
        async let recentTask = client.music({ var q = JellyfinClient.MusicQuery(types: "AudioBook", sort: .recentlyAdded, limit: 16); q.parentId = parent; return q }())
        async let authorsTask = client.albumArtists(parentId: parent, limit: 30)
        let sort = sort
        let p = PagedItems(pageSize: 60) { start, limit in
            var q = JellyfinClient.MusicQuery(types: "AudioBook", sort: sort, startIndex: start, limit: limit)
            q.parentId = parent
            return try await client.music(q)
        }
        paged = p
        async let pageTask: Void = p.reload()
        var failure: (any Error)?
        do { inProgress = try await resumeTask.filter(\.isAudiobook) } catch { failure = error }
        do { recent = try await recentTask.items } catch { failure = failure ?? error }
        authors = (try? await authorsTask.items) ?? []
        await pageTask
        if let failure { error = failure.localizedDescription }
    }
}

/// Books by title or author, as typed.
struct BookSearchView: View {
    let term: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var books: [BaseItem] = []
    @State private var isSearching = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            let query = term.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "Search your audiobooks", message: "By title or by author.")
            } else if isSearching, books.isEmpty {
                AlbumGrid(items: [], pendingCount: 4) { _ in }.padding(.top, 12)
            } else if books.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "No audiobook matches “\(query)”.")
            } else {
                AlbumGrid(items: books, subtitleFor: { $0.AlbumArtist ?? $0.artistLine }) {
                    app.push(.music(.audiobook($0.Id)))
                }
                .padding(.vertical, 12)
            }
        }
        .onChange(of: term, initial: true) { _, new in schedule(new.trimmingCharacters(in: .whitespaces)) }
    }

    private func schedule(_ query: String) {
        task?.cancel()
        guard !query.isEmpty else {
            books = []
            return
        }
        task = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            let found = (try? await client.music(.init(types: "AudioBook", sort: .name, limit: 60, searchTerm: query)).items) ?? []
            guard !Task.isCancelled else { return }
            books = found
        }
    }
}

/// One author's books.
struct AuthorView: View {
    let authorId: String
    let name: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var books: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            if isLoading, books.isEmpty {
                AlbumGrid(items: [], pendingCount: 4) { _ in }.padding(.top, 12)
            } else if let error, books.isEmpty {
                ErrorState(error: error) { Task { await load() } }
            } else if books.isEmpty {
                EmptyState(
                    symbol: "book", title: "No audiobooks",
                    message: client.showsOffline ? "Nothing by \(name) is on this device." : "Nothing by \(name) has been scanned in."
                )
            } else {
                AlbumGrid(items: books, subtitleFor: { BooksTabView.progressLine($0) ?? $0.ProductionYear.map(String.init) }) {
                    app.push(.music(.audiobook($0.Id)))
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(name)
        .paletteBar()
        .task(id: authorId) { await load() }
        .reloadWhenItemsChange { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        if client.showsOffline {
            books = OfflineMusic.books(byAuthor: name)
            return
        }
        do {
            // Credited either way: as the album artist (the usual) or on the
            // track itself (a narrator-tagged file).
            let byAlbum: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "AudioBook", sort: .year, limit: 200)
                q.albumArtistIds = [authorId]
                return q
            }()
            let byTrack: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "AudioBook", sort: .year, limit: 200)
                q.artistIds = [authorId]
                return q
            }()
            async let a = client.music(byAlbum)
            async let t = client.music(byTrack)
            var seen = Set<String>()
            var out: [BaseItem] = []
            for book in (try await a.items) + ((try? await t.items) ?? []) where !seen.contains(book.Id) {
                seen.insert(book.Id)
                out.append(book)
            }
            books = out
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#endif
