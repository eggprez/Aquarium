//  What Siri and Shortcuts can ask of the music player: resume the book,
//  play a book by name, play an album, an artist, a playlist or a song,
//  shuffle everything, play a genre. The video ones are in AppIntents.swift;
//  these join them in `AquariumShortcuts`.
//
//  Each resolves against the server when it can be reached and against the
//  downloads when it can't, the way the music pages do.

import AppIntents
import Foundation

// MARK: - Entities

/// An audiobook as Siri sees it.
struct AudiobookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audiobook")
    static let defaultQuery = AudiobookQuery()

    var id: String
    var title: String
    var author: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(author)")
    }

    init(_ item: BaseItem) {
        id = item.Id
        title = item.title
        author = item.artistLine
    }
}

struct AudiobookQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AudiobookEntity] {
        var out: [AudiobookEntity] = []
        var missing: [String] = []
        for id in identifiers {
            #if !os(tvOS)
            if let book = OfflineMusic.book(id) { out.append(AudiobookEntity(book)); continue }
            #endif
            missing.append(id)
        }
        if !missing.isEmpty, let fetched = try? await JellyfinClient.shared.itemsByIds(missing) {
            out += fetched.filter(\.isAudiobook).map(AudiobookEntity.init)
        }
        return out
    }

    @MainActor
    func entities(matching string: String) async throws -> [AudiobookEntity] {
        let client = JellyfinClient.shared
        var out: [AudiobookEntity] = []
        var seen = Set<String>()
        #if !os(tvOS)
        for book in OfflineMusic.searchBooks(string) where seen.insert(book.Id).inserted { out.append(AudiobookEntity(book)) }
        #endif
        if client.isSignedIn, !client.showsOffline {
            let found = (try? await client.music(JellyfinClient.MusicQuery(types: "AudioBook", sort: .name, limit: 10, searchTerm: string)))?.items ?? []
            for book in found where seen.insert(book.Id).inserted { out.append(AudiobookEntity(book)) }
        }
        return out
    }

    @MainActor
    func suggestedEntities() async throws -> [AudiobookEntity] {
        let client = JellyfinClient.shared
        if client.isSignedIn, !client.showsOffline, let books = try? await client.resumeAudio(limit: 8) {
            return books.filter(\.isAudiobook).map(AudiobookEntity.init)
        }
        #if !os(tvOS)
        return OfflineMusic.booksInProgress.prefix(8).map(AudiobookEntity.init)
        #else
        return []
        #endif
    }
}

/// An album, an artist, a playlist or a song — anything "play X" can mean
/// in the music library.
struct MusicEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Music")
    static let defaultQuery = MusicQuery()

    var id: String
    var title: String
    var detail: String
    var kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    init(_ item: BaseItem) {
        id = item.Id
        title = item.isArtist ? MusicNames.artistName(item.title, sortName: item.SortName) : item.title
        kind = item.kind
        var facts: [String] = []
        switch item.kind {
        case "MusicAlbum":
            facts.append("Album")
            if !item.artistLine.isEmpty { facts.append(item.artistLine) }
        case "MusicArtist": facts.append("Artist")
        case "Playlist": facts.append("Playlist")
        default:
            facts.append("Song")
            if !item.artistLine.isEmpty { facts.append(item.artistLine) }
        }
        detail = facts.joined(separator: " · ")
    }
}

struct MusicQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MusicEntity] {
        var out: [MusicEntity] = []
        var missing: [String] = []
        #if !os(tvOS)
        let local = OfflineMusic.songs
        for id in identifiers {
            if let song = local.first(where: { $0.Id == id }) { out.append(MusicEntity(song)) }
            else if let album = local.albumsInOrder().first(where: { $0.Id == id }) { out.append(MusicEntity(album)) }
            else { missing.append(id) }
        }
        #else
        missing = identifiers
        #endif
        if !missing.isEmpty, let fetched = try? await JellyfinClient.shared.itemsByIds(missing, fields: JellyfinClient.musicFields) {
            out += fetched.map(MusicEntity.init)
        }
        return out
    }

    @MainActor
    func entities(matching string: String) async throws -> [MusicEntity] {
        let client = JellyfinClient.shared
        var out: [MusicEntity] = []
        var seen = Set<String>()
        func add(_ items: [BaseItem]) {
            for item in items where seen.insert(item.Id).inserted { out.append(MusicEntity(item)) }
        }
        if client.isSignedIn, !client.showsOffline, let found = try? await client.searchMusic(string, limit: 6) {
            add(found.albums); add(found.playlists); add(found.artists); add(found.songs)
        }
        #if !os(tvOS)
        let local = OfflineMusic.search(string, limit: 6)
        add(local.albums); add(local.playlists); add(local.artists); add(local.songs)
        #endif
        return out
    }

    @MainActor
    func suggestedEntities() async throws -> [MusicEntity] {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else {
            #if !os(tvOS)
            return OfflineMusic.recentlyPlayed(limit: 20).albumsInOrder().prefix(8).map(MusicEntity.init)
            #else
            return []
            #endif
        }
        async let recent = (try? client.recentlyPlayedSongs(limit: 20)) ?? []
        async let lists = (try? client.audioPlaylists()) ?? []
        var out: [MusicEntity] = []
        var seen = Set<String>()
        for item in await recent.albumsInOrder().prefix(5) + lists.prefix(4) where seen.insert(item.Id).inserted {
            out.append(MusicEntity(item))
        }
        return out
    }
}

struct MusicGenreEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Genre")
    static let defaultQuery = MusicGenreQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ item: BaseItem) {
        id = item.Id
        name = item.title
    }
}

struct MusicGenreQuery: EntityStringQuery {
    @MainActor
    private func all() async -> [BaseItem] {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else {
            #if !os(tvOS)
            var seen = Set<String>()
            return OfflineMusic.songs.flatMap { $0.Genres ?? [] }.filter { seen.insert($0.lowercased()).inserted }.map { name in
                var item = BaseItem()
                item.Id = "genre:\(name)"
                item.Name = name
                item.type = "MusicGenre"
                return item
            }
            #else
            return []
            #endif
        }
        return (try? await client.musicGenres())?.items ?? []
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MusicGenreEntity] {
        let wanted = Set(identifiers)
        return await all().filter { wanted.contains($0.Id) }.map(MusicGenreEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MusicGenreEntity] {
        let term = string.lowercased()
        return await all().filter { $0.title.lowercased().contains(term) }.prefix(10).map(MusicGenreEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MusicGenreEntity] {
        await all().prefix(10).map(MusicGenreEntity.init)
    }
}

// MARK: - Intents

struct ResumeAudiobookIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Audiobook"
    static let description = IntentDescription("Picks up the audiobook you were listening to, from where you left it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await MusicActions.resumeBook()
        return .result(dialog: ok ? "Resuming." : "There's no audiobook to resume.")
    }
}

struct PlayAudiobookIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Audiobook"
    static let description = IntentDescription("Starts an audiobook from where you left it.")
    static let openAppWhenRun = true

    @Parameter(title: "Audiobook")
    var book: AudiobookEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$book)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        await MusicActions.play(itemId: book.id, shuffle: false)
        return .result()
    }
}

struct PlayMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays an album, an artist, a playlist or a song. Artists and playlists are shuffled.")
    static let openAppWhenRun = true

    @Parameter(title: "Music")
    var music: MusicEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$music)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        await MusicActions.play(itemId: music.id, shuffle: music.kind == "MusicArtist" || music.kind == "Playlist")
        return .result()
    }
}

struct ShuffleMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Music"
    static let description = IntentDescription("Shuffles your whole music library — the downloads, when the server can't be reached.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await MusicActions.shuffleAll()
        return .result(dialog: ok ? "Shuffling your music." : "There's no music to shuffle.")
    }
}

struct PlayGenreIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Genre"
    static let description = IntentDescription("Shuffles the songs of a genre.")
    static let openAppWhenRun = true

    @Parameter(title: "Genre")
    var genre: MusicGenreEntity

    static var parameterSummary: some ParameterSummary { Summary("Play some \(\.$genre)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await MusicActions.playGenre(id: genre.id, name: genre.name)
        return .result(dialog: ok ? "Playing \(genre.name)." : "Nothing found in \(genre.name).")
    }
}

// MARK: - What they do

@MainActor
enum MusicActions {
    private static var client: JellyfinClient { .shared }
    private static var music: MusicPlayer { .shared }

    /// The book most recently left, from where it was left.
    @discardableResult
    static func resumeBook() async -> Bool {
        if let current = music.current, current.isAudiobook, !music.isPlaying {
            music.resume()
            return true
        }
        await AppModel.shared.refreshConnectivity()
        if client.isSignedIn, !client.showsOffline,
           let book = (try? await client.resumeAudio(limit: 10))?.first(where: \.isAudiobook) {
            music.play([book], title: book.title)
            return true
        }
        #if !os(tvOS)
        let books = OfflineMusic.booksInProgress
        let byRecency = books.sorted {
            (OfflineMusicIndex.shared.facts[$0.Id]?.lastPlayed ?? .distantPast) > (OfflineMusicIndex.shared.facts[$1.Id]?.lastPlayed ?? .distantPast)
        }
        if let book = byRecency.first ?? OfflineMusic.books.first {
            music.play([book], title: book.title)
            return true
        }
        #endif
        return false
    }

    /// Play something by id: a song or a book as itself, a collection as
    /// its songs.
    static func play(itemId: String, shuffle: Bool) async {
        await AppModel.shared.refreshConnectivity()
        var item: BaseItem?
        #if !os(tvOS)
        if client.showsOffline || !client.isSignedIn {
            item = OfflineMusic.book(itemId)
                ?? OfflineMusic.songs.first { $0.Id == itemId }
                ?? OfflineMusic.songs.albumsInOrder().first { $0.Id == itemId }
        }
        #endif
        if item == nil, client.isSignedIn, !client.showsOffline { item = try? await client.musicItem(itemId) }
        guard let item else { return }
        let songs = await songs(of: item)
        guard !songs.isEmpty else { return }
        music.play(songs, shuffle: shuffle && !item.isSong && !item.isAudiobook, title: item.isSong ? item.Album : item.title)
    }

    static func shuffleAll() async -> Bool {
        await AppModel.shared.refreshConnectivity()
        var songs: [BaseItem] = []
        if client.isSignedIn, !client.showsOffline {
            songs = (try? await client.music(JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 300)))?.items ?? []
        }
        #if !os(tvOS)
        if songs.isEmpty { songs = OfflineMusic.songs }
        #endif
        guard !songs.isEmpty else { return false }
        music.play(songs, shuffle: true, title: "Shuffle")
        return true
    }

    static func playGenre(id: String, name: String) async -> Bool {
        await AppModel.shared.refreshConnectivity()
        var songs: [BaseItem] = []
        if client.isSignedIn, !client.showsOffline, !id.hasPrefix("genre:") {
            songs = (try? await client.songs(genreId: id)) ?? []
        }
        #if !os(tvOS)
        if songs.isEmpty { songs = OfflineMusic.songs(inGenre: name) }
        #endif
        guard !songs.isEmpty else { return false }
        music.play(songs, shuffle: true, title: name)
        return true
    }

    private static func songs(of item: BaseItem) async -> [BaseItem] {
        if item.isSong || item.isAudiobook { return [item] }
        #if !os(tvOS)
        if client.showsOffline || !client.isSignedIn { return OfflineMusic.songs(for: item) }
        #endif
        if item.isAlbum { return (try? await client.albumTracks(albumId: item.Id)) ?? [] }
        if item.isArtist { return (try? await client.allSongs(artistId: item.Id)) ?? [] }
        if item.isPlaylist { return (try? await client.playlistItems(playlistId: item.Id)) ?? [] }
        if item.isMusicGenre { return (try? await client.songs(genreId: item.Id)) ?? [] }
        return []
    }
}
