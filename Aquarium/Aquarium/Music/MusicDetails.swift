//  The pages one thing opens into: an album and its tracks, an artist and
//  their records, a genre, a playlist, an audiobook.

import SwiftUI

#if os(iOS)

// MARK: - Album

struct AlbumDetailView: View {
    let albumId: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var album: BaseItem?
    @State private var tracks: [BaseItem] = []
    @State private var moreByArtist: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?

    /// Track numbers restart on each disc; a two-disc album is two lists
    /// with a heading between them.
    private var discs: [(number: Int?, tracks: [BaseItem])] {
        let grouped = Dictionary(grouping: tracks) { $0.ParentIndexNumber }
        let keys = grouped.keys.sorted { ($0 ?? 1) < ($1 ?? 1) }
        return keys.map { (number: $0, tracks: (grouped[$0] ?? []).sortedByTrack()) }
    }

    var body: some View {
        ScrollView {
            if isLoading, album == nil {
                VStack(alignment: .leading, spacing: 16) {
                    CollectionHeaderSkeleton()
                    SkeletonList(count: 8)
                }
            } else if let error, album == nil {
                ErrorState(error: error) { Task { await load() } }
            } else if let album {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(album)
                    PlayShuffleBar {
                        music.play(tracks, title: album.title)
                    } onShuffle: {
                        music.play(tracks, shuffle: true, title: album.title)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    ForEach(Array(discs.enumerated()), id: \.offset) { _, disc in
                        if discs.count > 1 {
                            Text("Disc \(disc.number ?? 1)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textDim)
                                .padding(.horizontal, Metrics.gutter)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        ForEach(disc.tracks) { track in
                            SongRow(
                                song: track, style: .album, number: track.IndexNumber,
                                isCurrent: music.current?.Id == track.Id, isPlaying: music.isPlaying
                            ) {
                                music.play(tracks, startingAt: tracks.position(of: track) ?? 0, title: album.title)
                            }
                        }
                    }

                    footer(album)

                    if !moreByArtist.isEmpty {
                        AlbumShelf(title: "More by \(album.AlbumArtist ?? album.artistLine)", items: moreByArtist) {
                            app.push(.music(.album($0.Id)))
                        }
                        .padding(.top, 24)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(album?.title ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .paletteBar()
        .toolbar {
            if let album {
                Menu {
                    MusicItemMenu(item: album)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: albumId) { await load() }
        .reloadWhenItemsChange { await load() }
    }

    private func header(_ album: BaseItem) -> some View {
        CollectionHeader(kicker: "Album", title: album.title, wash: album) {
            MusicArtwork(item: album, width: 800)
        } detail: {
            if let artist = album.AlbumArtists?.first ?? album.ArtistItems?.first, let id = artist.Id {
                Button { app.push(.music(.artist(id))) } label: {
                    Text(artist.Name ?? album.artistLine)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Theme.link)
                }
                .buttonStyle(.plain)
            } else if !album.artistLine.isEmpty {
                Text(album.artistLine).font(.subheadline).lineLimit(2).foregroundStyle(Theme.textDim)
            }
            HeaderFacts(parts: Self.facts(album))
        }
    }

    private func footer(_ album: BaseItem) -> some View {
        let total = tracks.reduce(0.0) { $0 + $1.runtimeSeconds }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(Self.minutes(total))")
        }
        .font(.caption)
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 14)
    }

    static func facts(_ album: BaseItem) -> [String] {
        var parts: [String] = []
        if let genre = album.Genres?.first { parts.append(genre) }
        if let year = album.ProductionYear { parts.append(String(year)) }
        return parts
    }

    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m >= 60 { return "\(m / 60) hr \(m % 60) min" }
        return "\(m) min"
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let a = client.musicItem(albumId)
            async let t = client.albumTracks(albumId: albumId)
            let fetched = try await a
            album = fetched
            tracks = try await t
            if let artistId = (fetched.AlbumArtists?.first ?? fetched.ArtistItems?.first)?.Id {
                var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: .year, limit: 20)
                q.albumArtistIds = [artistId]
                q.excludeItemIds = [albumId]
                moreByArtist = (try? await client.music(q).items) ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Artist

struct ArtistDetailView: View {
    let artistId: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var artist: BaseItem?
    @State private var albums: [BaseItem] = []
    @State private var appearsOn: [BaseItem] = []
    @State private var topSongs: [BaseItem] = []
    @State private var similar: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var bioExpanded = false

    var body: some View {
        ScrollView {
            if isLoading, artist == nil {
                VStack(spacing: 16) {
                    SkeletonHero()
                    SkeletonShelf()
                }
            } else if let error, artist == nil {
                ErrorState(error: error) { Task { await load() } }
            } else if let artist {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    hero(artist)
                    PlayShuffleBar {
                        Task { await playAll(shuffle: false) }
                    } onShuffle: {
                        Task { await playAll(shuffle: true) }
                    }
                    if !topSongs.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "Top Songs")
                            ForEach(topSongs) { song in
                                SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                                    music.play(topSongs, startingAt: topSongs.position(of: song) ?? 0, title: artist.title)
                                }
                            }
                        }
                    }
                    AlbumShelf(title: "Albums", items: albums, subtitleFor: { $0.ProductionYear.map(String.init) ?? "" }) {
                        app.push(.music(.album($0.Id)))
                    }
                    AlbumShelf(title: "Appears On", items: appearsOn) { app.push(.music(.album($0.Id))) }
                    if let overview = artist.Overview, !overview.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ShelfHeading(title: "About")
                            Text(overview)
                                .font(.body)
                                .foregroundStyle(Theme.textBody)
                                .lineLimit(bioExpanded ? nil : 4)
                                .padding(.horizontal, Metrics.gutter)
                            Button(bioExpanded ? "Less" : "More") { withAnimation { bioExpanded.toggle() } }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.link)
                                .buttonStyle(.plain)
                                .padding(.horizontal, Metrics.gutter)
                        }
                    }
                    ArtistShelf(title: "Similar Artists", items: similar) { app.push(.music(.artist($0.Id))) }
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(artist?.title ?? "Artist")
        .navigationBarTitleDisplayMode(.inline)
        .paletteBar()
        .toolbar {
            if let artist {
                Menu {
                    MusicItemMenu(item: artist)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: artistId) { await load() }
        .reloadWhenItemsChange { await load() }
    }

    private func hero(_ artist: BaseItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let backdrop = MusicArt.backdrop(artist) {
                    RemoteImage(url: backdrop, blurHash: Artwork.hash(artist, type: "Backdrop"), placeholderFill: Theme.heroPlaceholderFill)
                } else {
                    // White type sits on this: dark in both themes when there
                    // is no picture. See `Theme.heroPlaceholderFill`.
                    RemoteImage(
                        url: MusicArt.url(artist, width: 1000), blurHash: MusicArt.hash(artist),
                        placeholderFill: Theme.heroPlaceholderFill
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                if let genres = artist.Genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(Metrics.gutter)
        }
        .frame(height: 260)
    }

    private func playAll(shuffle: Bool) async {
        let songs = (try? await client.allSongs(artistId: artistId)) ?? topSongs
        guard !songs.isEmpty else { return app.toast("Nothing to play", tone: .error) }
        music.play(songs, shuffle: shuffle, title: artist?.title)
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let own: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: .year, limit: 100)
                q.albumArtistIds = [artistId]
                return q
            }()
            let featured: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: .year, limit: 60)
                q.contributingArtistIds = [artistId]
                return q
            }()
            async let a = client.musicItem(artistId)
            async let al = client.music(own)
            async let ap = client.music(featured)
            async let top = client.topSongs(artistId: artistId, limit: 8)
            async let sim = client.similarArtists(to: artistId, limit: 12)
            artist = try await a
            albums = try await al.items
            let ownIds = Set(albums.map(\.Id))
            appearsOn = ((try? await ap.items) ?? []).filter { !ownIds.contains($0.Id) }
            topSongs = (try? await top) ?? []
            similar = (try? await sim) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Genre

struct GenreDetailView: View {
    let genreId: String
    let name: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var paged: PagedItems?
    @State private var artists: [BaseItem] = []

    var body: some View {
        ScrollView {
            if let paged {
                LazyVStack(alignment: .leading, spacing: 16) {
                    PlayShuffleBar {
                        Task { await play(shuffle: false) }
                    } onShuffle: {
                        Task { await play(shuffle: true) }
                    }
                    .padding(.top, 8)
                    ArtistShelf(title: "Artists", items: artists) { app.push(.music(.artist($0.Id))) }
                    if paged.isLoading, paged.items.isEmpty {
                        AlbumGrid(items: [], pendingCount: 6) { _ in }
                    } else if let error = paged.error, paged.items.isEmpty {
                        ErrorState(error: error) { Task { await paged.reload() } }
                    } else if paged.items.isEmpty {
                        EmptyState(symbol: "guitars", title: "No albums", message: "Nothing in this genre.")
                    } else {
                        ShelfHeading(title: "Albums")
                        AlbumGrid(items: paged.items, pendingCount: paged.isLoading ? 2 : 0) {
                            app.push(.music(.album($0.Id)))
                        } onReachEnd: {
                            Task { await paged.loadMore() }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(name)
        .paletteBar()
        .task(id: genreId) {
            let p = PagedItems(pageSize: 60) { start, limit in
                var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: .name, startIndex: start, limit: limit)
                q.genreIds = [genreId]
                return try await client.music(q)
            }
            paged = p
            async let a = p.reload()
            var artistQuery = JellyfinClient.MusicQuery(types: "MusicArtist", sort: .name, limit: 30)
            artistQuery.genreIds = [genreId]
            artists = (try? await client.music(artistQuery).items) ?? []
            await a
        }
    }

    private func play(shuffle: Bool) async {
        let songs = (try? await client.songs(genreId: genreId)) ?? []
        guard !songs.isEmpty else { return app.toast("Nothing to play in this genre", tone: .error) }
        music.play(songs, shuffle: shuffle, title: name)
    }
}

// MARK: - Playlist

/// One line of a playlist, keyed by its entry rather than its song: the same
/// song can be in a playlist twice.
private struct PlaylistRow: Identifiable {
    let offset: Int
    let song: BaseItem
    var id: String { song.PlaylistItemId ?? "#\(offset)" }
}

struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var playlist: BaseItem?
    @State private var songs: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var songsError: String?
    @State private var isEditing = false
    @State private var isSaving = false

    private var rows: [PlaylistRow] {
        songs.enumerated().map { PlaylistRow(offset: $0.offset, song: $0.element) }
    }

    var body: some View {
        Group {
            if isLoading, playlist == nil {
                ScrollView { SkeletonList(count: 10) }
            } else if let error, playlist == nil {
                ScrollView { ErrorState(error: error) { Task { await load() } } }
            } else if let playlist {
                if isEditing {
                    editor(playlist)
                } else {
                    page(playlist)
                }
            }
        }
        .navigationTitle(playlist?.title ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .paletteBar()
        .toolbar {
            if let playlist {
                if isEditing {
                    Button("Done") { withAnimation { isEditing = false } }
                        .disabled(isSaving)
                } else {
                    Menu {
                        MusicItemMenu(item: playlist)
                        Divider()
                        Button { withAnimation { isEditing = true } } label: {
                            Label("Edit Songs", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task(id: playlistId) { await load() }
        .reloadWhenItemsChange { if !isEditing { await load() } }
    }

    private func page(_ playlist: BaseItem) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(playlist)
                PlayShuffleBar(onPlay: {
                    music.play(songs, title: playlist.title)
                }, onShuffle: {
                    music.play(songs, shuffle: true, title: playlist.title)
                }, isEnabled: !songs.isEmpty)
                .padding(.vertical, 16)
                if songs.isEmpty, let songsError {
                    // The playlist loaded and its songs did not. Said as
                    // that, rather than as a playlist with nothing in it.
                    ErrorState(error: songsError) { Task { await load() } }
                } else if songs.isEmpty, !isLoading {
                    EmptyState(
                        symbol: "music.note.list",
                        title: "Empty playlist",
                        message: "Press and hold any song, album or artist and choose Add to Playlist."
                    )
                }
                ForEach(rows) { row in
                    let song = row.song
                    SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                        music.play(songs, startingAt: row.offset, title: playlist.title)
                    }
                    .contextMenu {
                        MusicItemMenu(item: song)
                        Divider()
                        Button(role: .destructive) {
                            Task { await remove([song]) }
                        } label: {
                            Label("Remove from Playlist", systemImage: "minus.circle")
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
    }

    /// The list with its handles out: drag to reorder, swipe to remove.
    /// Every change goes to the server as it is made.
    private func editor(_ playlist: BaseItem) -> some View {
        List {
            Section {
                ForEach(rows) { row in
                    let song = row.song
                    HStack(spacing: 12) {
                        MusicArtwork(item: song, width: 160, radius: 5)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.body).lineLimit(1).foregroundStyle(Theme.text)
                            Text(song.artistLine).font(.caption).lineLimit(1).foregroundStyle(Theme.textDim)
                        }
                    }
                    .listRowBackground(Theme.background)
                }
                .onDelete { offsets in
                    let gone = offsets.map { songs[$0] }
                    Task { await remove(gone) }
                }
                .onMove { from, to in
                    Task { await move(from: from, to: to) }
                }
            } header: {
                Text(isSaving ? "Saving…" : "Drag to reorder, swipe to remove")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .environment(\.editMode, .constant(.active))
    }

    private func header(_ playlist: BaseItem) -> some View {
        CollectionHeader(kicker: "Playlist", title: playlist.title, wash: playlist) {
            MusicArtwork(item: playlist, width: 800, placeholderSymbol: "music.note.list")
        } detail: {
            HeaderFacts(parts: [
                "\(songs.count) song\(songs.count == 1 ? "" : "s")",
                AlbumDetailView.minutes(songs.reduce(0) { $0 + $1.runtimeSeconds }),
            ])
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        songsError = nil
        async let p = client.musicItem(playlistId)
        async let s = client.playlistItems(playlistId: playlistId)
        do {
            playlist = try await p
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        do {
            songs = try await s
        } catch is CancellationError {
        } catch {
            songsError = error.localizedDescription
        }
    }

    private func remove(_ gone: [BaseItem]) async {
        let entries = gone.map { $0.PlaylistItemId ?? $0.Id }
        let before = songs
        songs.removeAll { song in gone.contains { $0.PlaylistItemId ?? $0.Id == song.PlaylistItemId ?? song.Id } }
        isSaving = true
        defer { isSaving = false }
        do {
            try await PlaylistStore.shared.remove(entryIds: entries, from: playlistId)
        } catch {
            songs = before
            app.toast("Couldn't remove that: \(error.localizedDescription)", tone: .error)
        }
    }

    private func move(from: IndexSet, to: Int) async {
        guard let source = from.first else { return }
        let before = songs
        songs.move(fromOffsets: from, toOffset: to)
        let moved = before[source]
        // `onMove`'s destination counts the row's own old slot; the server
        // wants the index it should land at in the list without it.
        let target = to > source ? to - 1 : to
        isSaving = true
        defer { isSaving = false }
        do {
            try await PlaylistStore.shared.move(entryId: moved.PlaylistItemId ?? moved.Id, in: playlistId, to: target)
        } catch {
            songs = before
            app.toast("Couldn't reorder: \(error.localizedDescription)", tone: .error)
        }
    }
}

// MARK: - Audiobook

struct AudiobookDetailView: View {
    let bookId: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var book: BaseItem?
    @State private var isLoading = true
    @State private var error: String?
    @State private var overviewExpanded = false

    private var isCurrent: Bool { music.current?.Id == bookId }

    var body: some View {
        ScrollView {
            if isLoading, book == nil {
                CollectionHeaderSkeleton()
            } else if let error, book == nil {
                ErrorState(error: error) { Task { await load() } }
            } else if let book {
                LazyVStack(alignment: .leading, spacing: 18) {
                    CollectionHeader(kicker: "Audiobook", title: book.title, wash: book) {
                        MusicArtwork(item: book, width: 800, placeholderSymbol: "book")
                    } detail: {
                        if let author = book.AlbumArtist ?? book.Artists?.first {
                            Text(author).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(Theme.textBody)
                        }
                        HeaderFacts(parts: facts(book))
                    }

                    if let progress = book.progressFraction {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress).tint(Theme.accent)
                            Text("\(Int(progress * 100))% · \(Format.ticks(Int64(Double(book.RunTimeTicks ?? 0) * (1 - progress)))) left")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }

                    // The play bar's shapes: one wide button in the accent,
                    // and the lesser action as the round one beside it.
                    HStack(spacing: 10) {
                        Button {
                            if isCurrent { music.togglePlayPause() } else { music.play([book], title: book.title) }
                        } label: {
                            Label(playLabel(book), systemImage: isCurrent && music.isPlaying ? "pause.fill" : "play.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: 340)
                                .frame(height: 48)
                                .background(Theme.accentStrong, in: Capsule())
                                .contentShape(Capsule())
                        }
                        if book.progressFraction != nil {
                            Button {
                                if isCurrent { music.seek(to: 0) } else { music.play([book], title: book.title, at: 0) }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.headline)
                                    .foregroundStyle(Theme.text)
                                    .frame(width: 48, height: 48)
                                    .background(Theme.raised, in: Circle())
                                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                                    .contentShape(Circle())
                            }
                            .accessibilityLabel("Start Over")
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .padding(.horizontal, Metrics.gutter)

                    DownloadStateLine(itemId: book.Id)
                        .padding(.horizontal, Metrics.gutter)

                    if let overview = book.Overview, !overview.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(overview)
                                .font(.body)
                                .foregroundStyle(Theme.textBody)
                                .lineLimit(overviewExpanded ? nil : 5)
                            Button(overviewExpanded ? "Less" : "More") { withAnimation { overviewExpanded.toggle() } }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.link)
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }

                    if let chapters = book.Chapters, !chapters.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ShelfHeading(title: "Chapters").padding(.bottom, 6)
                            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                                let isHere = isCurrent && music.currentChapter == chapter
                                Button {
                                    if isCurrent {
                                        music.seek(to: chapter.startSeconds)
                                        if !music.isPlaying { music.resume() }
                                    } else {
                                        music.play([book], title: book.title, at: chapter.startSeconds)
                                    }
                                } label: {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.subheadline).monospacedDigit()
                                            .foregroundStyle(Theme.textDim)
                                            .frame(width: 28, alignment: .leading)
                                        Text(chapter.Name ?? "Chapter \(index + 1)")
                                            .foregroundStyle(isHere ? Theme.accent : Theme.text)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(Format.clock(chapter.startSeconds))
                                            .font(.caption).monospacedDigit()
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, Metrics.gutter)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RowPressStyle())
                            }
                        }
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(book?.title ?? "Audiobook")
        .navigationBarTitleDisplayMode(.inline)
        .paletteBar()
        .toolbar {
            if let book {
                Menu { MusicItemMenu(item: book) } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: bookId) { await load() }
        .reloadWhenItemsChange { await load() }
    }

    private func playLabel(_ book: BaseItem) -> String {
        if isCurrent { return music.isPlaying ? "Pause" : "Resume" }
        return book.progressFraction != nil ? "Resume" : "Play"
    }

    private func facts(_ book: BaseItem) -> [String] {
        var parts: [String] = []
        let length = Format.ticks(book.RunTimeTicks)
        if !length.isEmpty { parts.append(length) }
        if let n = book.Chapters?.count, n > 0 { parts.append("\(n) chapters") }
        if let year = book.ProductionYear { parts.append(String(year)) }
        return parts
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        // A downloaded book is its own page offline: the saved item has the
        // chapters and the blurb, the record has the listener's place.
        if client.showsOffline, let local = OfflineMusic.book(bookId) {
            book = local
            return
        }
        do { book = try await client.musicItem(bookId) } catch {
            if let local = OfflineMusic.book(bookId) { book = local } else { self.error = error.localizedDescription }
        }
    }
}

#endif
