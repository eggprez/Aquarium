//  What Siri can ask of the watch: resume the book, play a book, play an
//  album or a playlist, shuffle the music. Each opens the app and starts
//  playing. Declared as App Shortcuts, so they work by voice the moment the
//  app is on the watch.

import AppIntents
import Foundation

struct WatchBookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audiobook")
    static let defaultQuery = WatchBookQuery()

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

struct WatchBookQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [WatchBookEntity] {
        var out: [WatchBookEntity] = []
        var missing: [String] = []
        for id in identifiers {
            if let record = WatchDownloads.shared.record(for: id) { out.append(WatchBookEntity(record.asItem)) } else { missing.append(id) }
        }
        if !missing.isEmpty, let fetched = try? await JellyfinClient.shared.items(ids: missing) {
            out += fetched.filter(\.isAudiobook).map(WatchBookEntity.init)
        }
        return out
    }

    @MainActor
    func entities(matching string: String) async throws -> [WatchBookEntity] {
        let term = string.trimmingCharacters(in: .whitespaces).lowercased()
        let local = WatchDownloads.shared.books.map(\.asItem).filter {
            $0.title.lowercased().contains(term) || $0.artistLine.lowercased().contains(term)
        }
        var seen = Set(local.map(\.Id))
        var out = local.map(WatchBookEntity.init)
        if JellyfinClient.shared.isSignedIn, !JellyfinClient.shared.isOffline,
           let found = try? await JellyfinClient.shared.audiobooks(limit: 10, searchTerm: string).items {
            for book in found where seen.insert(book.Id).inserted { out.append(WatchBookEntity(book)) }
        }
        return out
    }

    @MainActor
    func suggestedEntities() async throws -> [WatchBookEntity] {
        WatchDownloads.shared.booksInProgress.prefix(5).map { WatchBookEntity($0.asItem) }
    }
}

struct WatchCollectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album or Playlist")
    static let defaultQuery = WatchCollectionQuery()

    var id: String
    var title: String
    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    init(_ item: BaseItem) {
        id = item.Id
        title = item.title
        detail = item.isPlaylist ? "Playlist" : (item.artistLine.isEmpty ? "Album" : item.artistLine)
    }
}

struct WatchCollectionQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [WatchCollectionEntity] {
        var out: [WatchCollectionEntity] = []
        var missing: [String] = []
        let downloads = WatchDownloads.shared
        for id in identifiers {
            if let list = downloads.playlists.first(where: { $0.id == id }) {
                var item = BaseItem(); item.Id = id; item.Name = list.name; item.type = "Playlist"
                out.append(WatchCollectionEntity(item))
            } else if let album = downloads.albums.first(where: { $0.Id == id }) {
                out.append(WatchCollectionEntity(album))
            } else {
                missing.append(id)
            }
        }
        if !missing.isEmpty, let fetched = try? await JellyfinClient.shared.items(ids: missing) {
            out += fetched.filter { $0.isAlbum || $0.isPlaylist }.map(WatchCollectionEntity.init)
        }
        return out
    }

    @MainActor
    func entities(matching string: String) async throws -> [WatchCollectionEntity] {
        let term = string.trimmingCharacters(in: .whitespaces).lowercased()
        let downloads = WatchDownloads.shared
        var out: [WatchCollectionEntity] = []
        var seen = Set<String>()
        for list in downloads.playlists where list.name.lowercased().contains(term) {
            var item = BaseItem(); item.Id = list.id; item.Name = list.name; item.type = "Playlist"
            if seen.insert(list.id).inserted { out.append(WatchCollectionEntity(item)) }
        }
        for album in downloads.albums where album.title.lowercased().contains(term) || album.artistLine.lowercased().contains(term) {
            if seen.insert(album.Id).inserted { out.append(WatchCollectionEntity(album)) }
        }
        if JellyfinClient.shared.isSignedIn, !JellyfinClient.shared.isOffline,
           let found = try? await JellyfinClient.shared.search(string, limit: 8) {
            for item in found.albums + found.playlists where seen.insert(item.Id).inserted {
                out.append(WatchCollectionEntity(item))
            }
        }
        return out
    }

    @MainActor
    func suggestedEntities() async throws -> [WatchCollectionEntity] {
        let downloads = WatchDownloads.shared
        var out: [WatchCollectionEntity] = downloads.playlists.prefix(4).map { list in
            var item = BaseItem(); item.Id = list.id; item.Name = list.name; item.type = "Playlist"
            return WatchCollectionEntity(item)
        }
        out += downloads.albums.prefix(4).map(WatchCollectionEntity.init)
        return out
    }
}

struct ResumeAudiobookIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Audiobook"
    static let description = IntentDescription("Picks up the audiobook you were listening to, from where you left it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await WatchActions.resumeBook()
        return .result(dialog: ok ? "Resuming." : "There's no audiobook to resume.")
    }
}

struct PlayAudiobookIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Audiobook"
    static let description = IntentDescription("Starts an audiobook from where you left it.")
    static let openAppWhenRun = true

    @Parameter(title: "Audiobook")
    var book: WatchBookEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$book)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WatchActions.play(itemId: book.id)
        return .result()
    }
}

struct PlayMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays an album or a playlist.")
    static let openAppWhenRun = true

    @Parameter(title: "Album or playlist")
    var collection: WatchCollectionEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$collection)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WatchActions.play(itemId: collection.id)
        return .result()
    }
}

struct ShuffleMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Music"
    static let description = IntentDescription("Shuffles your music — everything on the server when it can be reached, everything on the watch otherwise.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = JellyfinClient.shared
        var songs: [BaseItem] = []
        if client.isSignedIn, !client.isOffline { songs = (try? await client.randomSongs(limit: 200)) ?? [] }
        if songs.isEmpty { songs = WatchDownloads.shared.songs.map(\.asItem) }
        guard !songs.isEmpty else { return .result(dialog: "There's no music to shuffle.") }
        WatchPlayer.shared.play(songs, shuffle: true, title: "Shuffle")
        return .result(dialog: "Shuffling.")
    }
}

struct AquariumWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeAudiobookIntent(),
            phrases: [
                "Resume my audiobook in \(.applicationName)",
                "Continue my book in \(.applicationName)",
                "Resume my book on \(.applicationName)",
            ],
            shortTitle: "Resume Audiobook",
            systemImageName: "book.circle"
        )
        AppShortcut(
            intent: PlayAudiobookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Listen to \(\.$book) in \(.applicationName)",
            ],
            shortTitle: "Play an Audiobook",
            systemImageName: "book"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play \(\.$collection) in \(.applicationName)",
                "Play the album \(\.$collection) in \(.applicationName)",
                "Play the playlist \(\.$collection) in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play"
        )
        AppShortcut(
            intent: ShuffleMusicIntent(),
            phrases: [
                "Shuffle my music in \(.applicationName)",
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Shuffle Music",
            systemImageName: "shuffle"
        )
    }
}
