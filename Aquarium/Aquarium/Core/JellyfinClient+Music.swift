//  The music half of the API: artists, albums, songs, genres, playlists,
//  audiobooks, and the mixes the server can build from any of them.
//
//  Kept apart from the video endpoints because the shape of the questions is
//  different — a film library is browsed by title, a music library by the
//  people who made it — and because these routes are the ones Jellyfin has
//  been moving: `/Items?userId=` rather than `/Users/{id}/Items`, which the
//  server still answers today and has said it will stop answering. New code
//  takes the new spelling.

import Foundation

/// How a list of music is ordered. The raw value is what the server is sent.
enum MusicSort: String, CaseIterable, Sendable, Identifiable, Codable {
    case name = "SortName"
    case artist = "AlbumArtist,SortName"
    case recentlyAdded = "DateCreated,SortName"
    case year = "ProductionYear,SortName"
    case recentlyPlayed = "DatePlayed,SortName"
    case mostPlayed = "PlayCount,SortName"
    case random = "Random"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Title"
        case .artist: "Artist"
        case .recentlyAdded: "Recently added"
        case .year: "Year"
        case .recentlyPlayed: "Recently played"
        case .mostPlayed: "Most played"
        case .random: "Random"
        }
    }

    /// Whether newest-first is the sensible reading of this key.
    var descending: Bool {
        switch self {
        case .recentlyAdded, .recentlyPlayed, .mostPlayed, .year: true
        default: false
        }
    }
}

/// Synced or plain lyrics for one song, as `/Audio/{id}/Lyrics` returns them.
struct LyricsResponse: Codable, Sendable {
    struct Line: Codable, Sendable, Identifiable {
        var Text: String?
        /// Ticks from the start of the track; absent on plain lyrics.
        var Start: Int64?
        /// Where the line sits in the song. Plain lyrics have no `Start` and
        /// two lines can share one, so the place is the identity.
        var index = 0
        var id: Int64 { Int64(index) }
        var startSeconds: Double? { Start.map { Double($0) / 10_000_000 } }
        private enum CodingKeys: String, CodingKey { case Text, Start }
    }
    var Lyrics: [Line]?
    var lines: [Line] {
        (Lyrics ?? []).enumerated().map { i, line in
            var line = line
            line.index = i
            return line
        }
    }
    var isSynced: Bool { lines.contains { $0.Start != nil } }
}

extension JellyfinClient {
    // MARK: - Fields

    /// What a list of songs, albums or artists needs. `MediaSources` is left
    /// out on purpose: a song's carries every stream in the file, and a page
    /// of three thousand songs was several megabytes of codec facts nobody
    /// reads until one of them is played — at which point PlaybackInfo says
    /// it all again anyway.
    nonisolated static let musicFields =
        "PrimaryImageAspectRatio,Genres,UserData,ChildCount,ProductionYear,RunTimeTicks,DateCreated,ParentId,SortName,AlbumArtists,ArtistItems,MediaType"

    /// The above plus what a single page draws: the biography, the file, and
    /// for an audiobook its chapters.
    nonisolated static let musicDetailFields = musicFields + ",Overview,MediaSources,Chapters,GenreItems,Studios"

    private static let musicImages = "&EnableImageTypes=Primary,Backdrop,Logo&ImageTypeLimit=1"

    // MARK: - Libraries

    /// The music and audiobook libraries the account can see. Jellyfin files
    /// audiobooks under the `books` library type — the same one ebooks use —
    /// so both spellings are taken.
    func musicViews() async throws -> (music: [BaseItem], books: [BaseItem]) {
        let all = try await views()
        return (
            music: all.filter { $0.CollectionType == "music" },
            books: all.filter { $0.CollectionType == "books" || $0.CollectionType == "audiobooks" }
        )
    }

    // MARK: - One query for most of it

    /// The knobs every music list shares. Everything is optional; what is left
    /// nil is left out of the request rather than sent as a default.
    struct MusicQuery: Sendable {
        var types: String
        var parentId: String?
        var sort: MusicSort = .name
        var descending: Bool? = nil
        var startIndex = 0
        var limit = 100
        var albumArtistIds: [String] = []
        var artistIds: [String] = []
        var contributingArtistIds: [String] = []
        var genreIds: [String] = []
        /// Genres by name, for rules written before an id was known.
        var genres: [String] = []
        var favorites = false
        var played: Bool? = nil
        var searchTerm: String? = nil
        var years: [Int] = []
        var fields: String = JellyfinClient.musicFields
        var recursive = true
        /// Songs only: a single letter to start at, for the A–Z index.
        var nameStartsWith: String? = nil
        var excludeItemIds: [String] = []
    }

    func music(_ q: MusicQuery) async throws -> ItemsResponse {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var items: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "IncludeItemTypes", value: q.types),
            .init(name: "Recursive", value: q.recursive ? "true" : "false"),
            .init(name: "SortBy", value: q.sort.rawValue),
            .init(name: "SortOrder", value: (q.descending ?? q.sort.descending) ? "Descending" : "Ascending"),
            .init(name: "Fields", value: q.fields),
            .init(name: "StartIndex", value: String(q.startIndex)),
            .init(name: "Limit", value: String(q.limit)),
            .init(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        if let parent = q.parentId { items.append(.init(name: "ParentId", value: parent)) }
        if !q.albumArtistIds.isEmpty { items.append(.init(name: "AlbumArtistIds", value: q.albumArtistIds.joined(separator: ","))) }
        if !q.artistIds.isEmpty { items.append(.init(name: "ArtistIds", value: q.artistIds.joined(separator: ","))) }
        if !q.contributingArtistIds.isEmpty { items.append(.init(name: "ContributingArtistIds", value: q.contributingArtistIds.joined(separator: ","))) }
        if !q.genreIds.isEmpty { items.append(.init(name: "GenreIds", value: q.genreIds.joined(separator: ","))) }
        if !q.genres.isEmpty { items.append(.init(name: "Genres", value: q.genres.joined(separator: "|"))) }
        if !q.years.isEmpty { items.append(.init(name: "Years", value: q.years.map(String.init).joined(separator: ","))) }
        if !q.excludeItemIds.isEmpty { items.append(.init(name: "ExcludeItemIds", value: q.excludeItemIds.joined(separator: ","))) }
        var filters: [String] = []
        if q.favorites { filters.append("IsFavorite") }
        if let played = q.played { filters.append(played ? "IsPlayed" : "IsUnplayed") }
        if !filters.isEmpty { items.append(.init(name: "Filters", value: filters.joined(separator: ","))) }
        if let term = q.searchTerm, !term.isEmpty { items.append(.init(name: "SearchTerm", value: term)) }
        if let letter = q.nameStartsWith { items.append(.init(name: "NameStartsWith", value: letter)) }
        return try await get(ItemsResponse.self, "/Items?\(Self.encode(items))")
    }

    // MARK: - Artists

    /// Artists with an album to their name, which is the list a music library
    /// means by "Artists" — the other list, everyone who has ever been credited
    /// on a track, is twice as long and mostly guest features.
    func albumArtists(
        parentId: String? = nil, startIndex: Int = 0, limit: Int = 200,
        favorites: Bool = false, searchTerm: String? = nil, sort: MusicSort = .name
    ) async throws -> ItemsResponse {
        try await artists(
            path: "/Artists/AlbumArtists", parentId: parentId, startIndex: startIndex,
            limit: limit, favorites: favorites, searchTerm: searchTerm, sort: sort
        )
    }

    /// Everyone credited anywhere, for search.
    func allArtists(
        parentId: String? = nil, startIndex: Int = 0, limit: Int = 200,
        favorites: Bool = false, searchTerm: String? = nil, sort: MusicSort = .name
    ) async throws -> ItemsResponse {
        try await artists(
            path: "/Artists", parentId: parentId, startIndex: startIndex,
            limit: limit, favorites: favorites, searchTerm: searchTerm, sort: sort
        )
    }

    private func artists(
        path: String, parentId: String?, startIndex: Int, limit: Int,
        favorites: Bool, searchTerm: String?, sort: MusicSort
    ) async throws -> ItemsResponse {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var q: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "SortBy", value: sort.rawValue),
            .init(name: "SortOrder", value: sort.descending ? "Descending" : "Ascending"),
            .init(name: "Fields", value: Self.musicFields),
            .init(name: "StartIndex", value: String(startIndex)),
            .init(name: "Limit", value: String(limit)),
            .init(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        if let parentId { q.append(.init(name: "ParentId", value: parentId)) }
        if favorites { q.append(.init(name: "IsFavorite", value: "true")) }
        if let searchTerm, !searchTerm.isEmpty { q.append(.init(name: "SearchTerm", value: searchTerm)) }
        return try await get(ItemsResponse.self, "\(path)?\(Self.encode(q))")
    }

    /// One item with everything a page needs — an artist's biography, an
    /// album's file facts, an audiobook's chapters.
    func musicItem(_ id: String) async throws -> BaseItem {
        guard let s = prefs.session else { throw APIError.notConfigured }
        return try await get(
            BaseItem.self,
            "/Items/\(Self.pathId(id))?userId=\(s.userId)&Fields=\(Self.musicDetailFields)"
        )
    }

    // MARK: - Albums and songs

    /// An album's tracks in disc-and-track order.
    func albumTracks(albumId: String) async throws -> [BaseItem] {
        try await music(MusicQuery(
            types: "Audio", parentId: albumId, sort: .name, limit: 500, recursive: true
        )).items.sortedByTrack()
    }

    /// The tracks of one artist, most played first, for the top of their page.
    func topSongs(artistId: String, limit: Int = 8) async throws -> [BaseItem] {
        var q = MusicQuery(types: "Audio", sort: .mostPlayed, limit: limit)
        q.artistIds = [artistId]
        return try await music(q).items
    }

    /// Every song an artist is credited on, in album order, for "Play" and
    /// "Shuffle" on their page.
    func allSongs(artistId: String) async throws -> [BaseItem] {
        var q = MusicQuery(types: "Audio", sort: .artist, limit: 2000)
        q.artistIds = [artistId]
        return try await music(q).items
    }

    /// The songs of a genre, for its Play and Shuffle.
    func songs(genreId: String, limit: Int = 500) async throws -> [BaseItem] {
        var q = MusicQuery(types: "Audio", sort: .random, limit: limit)
        q.genreIds = [genreId]
        return try await music(q).items
    }

    /// These songs, by id, with what a list of them needs. Asked fifty at a
    /// time: the ids travel in the address, and a few thousand of them is
    /// longer than a server will read.
    /// `detail` asks for what a download needs — the media sources and the
    /// artwork tags — rather than the slim list shape.
    func songs(ids: [String], detail: Bool = false) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var out: [BaseItem] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let q: [URLQueryItem] = [
                .init(name: "userId", value: s.userId),
                .init(name: "Ids", value: ids[start..<min(start + 50, ids.count)].joined(separator: ",")),
                .init(name: "Fields", value: detail ? Self.musicDetailFields : Self.musicFields),
                .init(name: "EnableImages", value: detail ? "true" : "false"),
            ]
            out += try await get(ItemsResponse.self, "/Items?\(Self.encode(q))", countsForOffline: false).items
        }
        return out
    }

    // MARK: - Genres

    func musicGenres(parentId: String? = nil, startIndex: Int = 0, limit: Int = 300) async throws -> ItemsResponse {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var q: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "SortOrder", value: "Ascending"),
            .init(name: "StartIndex", value: String(startIndex)),
            .init(name: "Limit", value: String(limit)),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        if let parentId { q.append(.init(name: "ParentId", value: parentId)) }
        return try await get(ItemsResponse.self, "/MusicGenres?\(Self.encode(q))")
    }

    // MARK: - Playlists

    /// The account's playlists, audio ones only.
    func audioPlaylists() async throws -> [BaseItem] {
        try await music(MusicQuery(types: "Playlist", sort: .name, limit: 500))
            .items.filter { ($0.MediaType ?? "Audio") == "Audio" }
    }

    /// A playlist's songs, in the playlist's own order.
    ///
    /// Asked two ways. `/Playlists/{id}/Items` is the route made for it, and
    /// it is also the strict one: it answers 403 unless the account owns the
    /// playlist, is on its share list, or the playlist is public — so one made
    /// by another account, or by an importer, lists with a song count and then
    /// opens with nothing. `/Items?ParentId=` is what Jellyfin's web client
    /// opens a playlist with, has no such check, and keeps the order. It is
    /// tried whenever the first route fails or comes back empty; an empty
    /// playlist costs one extra request.
    func playlistItems(playlistId: String) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let q: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "Fields", value: Self.musicFields),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        var failure: Error?
        do {
            let items = try await get(ItemsResponse.self, "/Playlists/\(Self.pathId(playlistId))/Items?\(Self.encode(q))").items
            if !items.isEmpty { return items }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError {
            // Offline is offline on either route.
            if case .offline = error { throw error }
            failure = error
        }
        let byParent = q + [.init(name: "ParentId", value: playlistId)]
        do {
            return try await get(ItemsResponse.self, "/Items?\(Self.encode(byParent))").items
        } catch {
            throw failure ?? error
        }
    }

    // MARK: - Editing playlists

    /// A new playlist, with these songs in it. Returns its id.
    @discardableResult
    func createPlaylist(name: String, itemIds: [String]) async throws -> String {
        guard let s = prefs.session else { throw APIError.notConfigured }
        struct Body: Encodable { let Name: String; let Ids: [String]; let UserId: String; let MediaType: String }
        struct Reply: Decodable { let Id: String? }
        let data = try await request(
            "/Playlists", method: "POST",
            body: Body(Name: name, Ids: itemIds, UserId: s.userId, MediaType: "Audio")
        )
        guard let id = try? JSONDecoder().decode(Reply.self, from: data).Id, !id.isEmpty else {
            throw APIError.message("The server made the playlist but didn't say which one it is")
        }
        return id
    }

    func renamePlaylist(_ playlistId: String, to name: String) async throws {
        struct Body: Encodable { let Name: String }
        try await request("/Playlists/\(Self.pathId(playlistId))", method: "POST", body: Body(Name: name))
    }

    func deletePlaylist(_ playlistId: String) async throws {
        try await request("/Items/\(Self.pathId(playlistId))", method: "DELETE")
    }

    func addToPlaylist(_ playlistId: String, itemIds: [String]) async throws {
        guard let s = prefs.session, !itemIds.isEmpty else { return }
        let q = [
            URLQueryItem(name: "ids", value: itemIds.joined(separator: ",")),
            URLQueryItem(name: "userId", value: s.userId),
        ]
        try await request("/Playlists/\(Self.pathId(playlistId))/Items?\(Self.encode(q))", method: "POST")
    }

    /// Remove by entry, not by song — see `BaseItem.PlaylistItemId`.
    func removeFromPlaylist(_ playlistId: String, entryIds: [String]) async throws {
        guard !entryIds.isEmpty else { return }
        let q = [URLQueryItem(name: "entryIds", value: entryIds.joined(separator: ","))]
        try await request("/Playlists/\(Self.pathId(playlistId))/Items?\(Self.encode(q))", method: "DELETE")
    }

    func movePlaylistEntry(_ playlistId: String, entryId: String, to index: Int) async throws {
        try await request(
            "/Playlists/\(Self.pathId(playlistId))/Items/\(Self.pathId(entryId))/Move/\(max(0, index))",
            method: "POST"
        )
    }

    // MARK: - Mixes and recommendations

    /// A station built by the server from one thing — a song, an album, an
    /// artist, a genre. Jellyfin's own name for it.
    func instantMix(from itemId: String, limit: Int = 100) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let q: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: Self.musicFields),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        return try await get(ItemsResponse.self, "/Items/\(Self.pathId(itemId))/InstantMix?\(Self.encode(q))").items
    }

    /// Artists the server thinks are like this one.
    func similarArtists(to artistId: String, limit: Int = 12) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        return try await get(
            ItemsResponse.self,
            "/Items/\(Self.pathId(artistId))/Similar?userId=\(s.userId)&limit=\(limit)&Fields=\(Self.musicFields)"
        ).items
    }

    /// What was listened to last, newest first: the row Discover leads with.
    func recentlyPlayedSongs(limit: Int = 40) async throws -> [BaseItem] {
        var q = MusicQuery(types: "Audio", sort: .recentlyPlayed, limit: limit)
        q.played = true
        return try await music(q).items
    }

    func mostPlayedSongs(limit: Int = 40) async throws -> [BaseItem] {
        var q = MusicQuery(types: "Audio", sort: .mostPlayed, limit: limit)
        q.played = true
        return try await music(q).items
    }

    /// Songs and audiobooks stopped partway through. Audiobooks are what this
    /// is really for: a song is rarely resumed, a twelve-hour book always is.
    func resumeAudio(limit: Int = 12) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let q: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "MediaTypes", value: "Audio"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: Self.musicFields),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        return try await get(ItemsResponse.self, "/UserItems/Resume?\(Self.encode(q))").items
    }

    // MARK: - Lyrics

    /// The words, timed where the server has an LRC file or an embedded sync.
    func lyrics(itemId: String) async throws -> LyricsResponse? {
        do {
            return try await get(LyricsResponse.self, "/Audio/\(Self.pathId(itemId))/Lyrics", countsForOffline: false)
        } catch APIError.server(let status, _) where status == 404 {
            return nil
        }
    }

    // MARK: - Search

    /// Everything in the music libraries matching a term, in one round trip
    /// per kind. Artists come from their own route because `/Items` only
    /// searches the artist entries a library has a folder for.
    struct MusicSearchResults: Sendable {
        var artists: [BaseItem] = []
        var albums: [BaseItem] = []
        var songs: [BaseItem] = []
        var audiobooks: [BaseItem] = []
        var playlists: [BaseItem] = []
        var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty && audiobooks.isEmpty && playlists.isEmpty }
    }

    func searchMusic(_ term: String, limit: Int = 24) async throws -> MusicSearchResults {
        async let artists = allArtists(limit: limit, searchTerm: term)
        async let albums = music(MusicQuery(types: "MusicAlbum", sort: .name, limit: limit, searchTerm: term))
        async let songs = music(MusicQuery(types: "Audio", sort: .name, limit: limit, searchTerm: term))
        async let books = music(MusicQuery(types: "AudioBook", sort: .name, limit: limit, searchTerm: term))
        async let lists = music(MusicQuery(types: "Playlist", sort: .name, limit: limit, searchTerm: term))
        var out = MusicSearchResults()
        out.artists = (try? await artists.items) ?? []
        out.albums = try await albums.items
        out.songs = try await songs.items
        out.audiobooks = (try? await books.items) ?? []
        out.playlists = ((try? await lists.items) ?? []).filter { ($0.MediaType ?? "Audio") == "Audio" }
        return out
    }
}

extension Array where Element == BaseItem {
    /// Disc, then track, then name — the order a sleeve lists them in. The
    /// server's `SortBy=ParentIndexNumber,IndexNumber` does the same thing,
    /// but not every route takes it, and a playlist's own order must be left
    /// alone, so it is done here and only where asked for.
    func sortedByTrack() -> [BaseItem] {
        sorted {
            let a = ($0.ParentIndexNumber ?? 1, $0.IndexNumber ?? Int.max)
            let b = ($1.ParentIndexNumber ?? 1, $1.IndexNumber ?? Int.max)
            if a != b { return a < b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// The albums these songs belong to, one entry each, in the order the
    /// songs were given. What turns "recently played songs" into a shelf of
    /// covers.
    func albumsInOrder() -> [BaseItem] {
        var seen = Set<String>()
        var out: [BaseItem] = []
        for song in self {
            guard let albumId = song.AlbumId, !albumId.isEmpty, !seen.contains(albumId) else { continue }
            seen.insert(albumId)
            var album = BaseItem()
            album.Id = albumId
            album.Name = song.Album
            album.type = "MusicAlbum"
            album.AlbumArtist = song.AlbumArtist
            album.AlbumArtists = song.AlbumArtists
            album.Artists = song.AlbumArtists?.compactMap(\.Name)
            album.ProductionYear = song.ProductionYear
            if let tag = song.AlbumPrimaryImageTag { album.ImageTags = ["Primary": tag] }
            album.ImageBlurHashes = song.ImageBlurHashes
            out.append(album)
        }
        return out
    }
}
