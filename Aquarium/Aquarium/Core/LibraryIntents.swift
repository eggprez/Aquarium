//  What Siri and Shortcuts can ask of the library: what's new, mark a title
//  watched or a favourite, list the favourites, play a collection, pick
//  something at random, and the downloads — start one, list them, delete
//  one.
//
//  The ones that return titles return `MediaItemEntity` values, so a
//  Shortcut can carry them on: "What's new" into a notification each
//  morning, "Surprise me" into "Download" before a flight, "Downloads" into
//  a size check. The library copy answers first wherever it can, which is
//  also what lets a random pick be instant and work with no server.

import AppIntents
import Foundation

// MARK: - Shared lookups

@MainActor
enum LibraryActions {
    private static var client: JellyfinClient { .shared }

    /// The video libraries — films and shows — from what the app has loaded,
    /// else from the server, else from the copy.
    static func videoLibraries() async -> [BaseItem] {
        var views = AppModel.shared.libraries
        if views.isEmpty { views = (try? await client.views()) ?? LibraryIndex.shared.savedViews ?? [] }
        return views.filter { ["movies", "tvshows", "mixed"].contains($0.CollectionType ?? "mixed") }
    }

    /// The item behind an entity: the copy's, else the server's.
    static func item(_ entity: MediaItemEntity) async throws -> BaseItem {
        if let kept = LibraryIndex.shared.item(entity.id) { return kept }
        return try await client.item(entity.id)
    }

    /// What playing an entity means in files: a film or an episode is
    /// itself; a show is its unwatched episodes, in order, or all of them
    /// when every one has been seen.
    static func playable(_ entity: MediaItemEntity) async throws -> [BaseItem] {
        let item = try await self.item(entity)
        guard item.isSeries else { return item.isFolderLike ? [] : [item] }
        var episodes = LibraryIndex.shared.episodes(seriesId: item.Id, seasonId: nil) ?? []
        if episodes.isEmpty { episodes = (try? await client.episodes(seriesId: item.Id, seasonId: nil)) ?? [] }
        let unwatched = episodes.filter { !$0.userData.played }
        return unwatched.isEmpty ? episodes : unwatched
    }

    static func spokenList(_ entities: [MediaItemEntity], limit: Int = 3) -> String {
        let names = entities.prefix(limit).map(\.title).joined(separator: ", ")
        let more = entities.count > limit ? " and \(entities.count - limit) more" : ""
        return names + more
    }
}

extension JellyfinClient {
    /// Box sets and video playlists whose names match, for the collection
    /// entity. An empty term lists the most recent.
    func collections(matching term: String, limit: Int = 12) async throws -> [BaseItem] {
        guard let s = Preferences.shared.session else { throw APIError.notConfigured }
        var q = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "BoxSet,Playlist"),
            URLQueryItem(name: "Fields", value: "ChildCount,MediaType,ProductionYear"),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]
        if term.isEmpty {
            q.append(.init(name: "SortBy", value: "DateCreated"))
            q.append(.init(name: "SortOrder", value: "Descending"))
        } else {
            q.append(.init(name: "searchTerm", value: term))
        }
        let items = try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))").items
        return items.filter { $0.kind == "BoxSet" || ($0.MediaType ?? "Video") != "Audio" }
    }

    /// A box set's titles, in its order.
    func boxSetItems(_ boxSetId: String) async throws -> [BaseItem] {
        guard let s = Preferences.shared.session else { throw APIError.notConfigured }
        let q = [
            URLQueryItem(name: "ParentId", value: boxSetId),
            URLQueryItem(name: "Fields", value: "ProductionYear,UserData,RunTimeTicks,Genres"),
        ]
        return try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))").items
    }
}

// MARK: - What's new

struct WhatsNewIntent: AppIntent {
    static let title: LocalizedStringResource = "What's New"
    static let description = IntentDescription("The latest films and shows added to your server, newest first.")

    @Parameter(title: "How many", default: 10, inclusiveRange: (1, 50))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get the \(\.$count) newest titles")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else {
            return .result(value: [], dialog: "The server can't be reached.")
        }
        let libraries = await LibraryActions.videoLibraries()
        var latest: [BaseItem] = []
        await withTaskGroup(of: [BaseItem].self) { group in
            for library in libraries {
                group.addTask { (try? await client.latest(parentId: library.Id, limit: count)) ?? [] }
            }
            for await items in group { latest += items }
        }
        var seen = Set<String>()
        let newest = latest
            .filter { seen.insert($0.Id).inserted }
            .sorted { (Format.parseDate($0.DateCreated) ?? .distantPast) > (Format.parseDate($1.DateCreated) ?? .distantPast) }
            .prefix(count)
            .map(MediaItemEntity.init)
        guard !newest.isEmpty else { return .result(value: [], dialog: "Nothing new has been added.") }
        return .result(value: Array(newest), dialog: "New: \(LibraryActions.spokenList(Array(newest))).")
    }
}

// MARK: - Watched and favourites

struct MarkWatchedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark as Watched"
    static let description = IntentDescription("Marks a title watched — or unwatched — on the server, and in the downloads.")

    @Parameter(title: "Title")
    var item: MediaItemEntity

    @Parameter(title: "Watched", default: true)
    var watched: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$watched, .equalTo, true) {
            Summary("Mark \(\.$item) as watched")
        } otherwise: {
            Summary("Mark \(\.$item) as unwatched")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MediaItemEntity> & ProvidesDialog {
        let client = JellyfinClient.shared
        let updated = item
        updated.watched = watched
        #if !os(tvOS)
        if let record = DownloadManager.shared.record(for: item.id) {
            DownloadManager.shared.setPlayed(record.itemId, played: watched)
        }
        #endif
        if client.isSignedIn, !client.showsOffline {
            try await client.markPlayed(item.id, played: watched)
            LibraryIndex.shared.patchUserData(item.id) {
                $0.Played = watched
                if watched { $0.PlaybackPositionTicks = 0 }
            }
            ItemMutations.shared.changed()
        }
        return .result(value: updated, dialog: watched ? "Marked \(item.title) as watched." : "Marked \(item.title) as unwatched.")
    }
}

struct SetFavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Favorites"
    static let description = IntentDescription("Stars a title on the server, or takes the star away.")

    @Parameter(title: "Title")
    var item: MediaItemEntity

    @Parameter(title: "Favorite", default: true)
    var favorite: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$favorite, .equalTo, true) {
            Summary("Add \(\.$item) to favorites")
        } otherwise: {
            Summary("Remove \(\.$item) from favorites")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MediaItemEntity> & ProvidesDialog {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else {
            return .result(value: item, dialog: "The server can't be reached.")
        }
        try await client.setFavorite(item.id, favorite: favorite)
        LibraryIndex.shared.patchUserData(item.id) { $0.IsFavorite = favorite }
        ItemMutations.shared.changed()
        let updated = item
        updated.favorite = favorite
        return .result(value: updated, dialog: favorite ? "Added \(item.title) to your favorites." : "Removed \(item.title) from your favorites.")
    }
}

enum TitleKind: String, AppEnum {
    case anything, movies, shows

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Kind")
    static let caseDisplayRepresentations: [TitleKind: DisplayRepresentation] = [
        .anything: "Films and shows", .movies: "Films", .shows: "Shows",
    ]

    var includeTypes: String {
        switch self {
        case .anything: "Movie,Series"
        case .movies: "Movie"
        case .shows: "Series"
        }
    }
}

struct GetFavoritesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Favorites"
    static let description = IntentDescription("The titles you've starred, in name order.")

    @Parameter(title: "Kind", default: .anything)
    var kind: TitleKind

    @Parameter(title: "How many", default: 20, inclusiveRange: (1, 200))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$count) favorite \(\.$kind)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        let response = try await JellyfinClient.shared.favorites(limit: count, includeTypes: kind.includeTypes)
        let entities = response.items.map(MediaItemEntity.init)
        guard !entities.isEmpty else { return .result(value: [], dialog: "You haven't starred anything yet.") }
        return .result(value: entities, dialog: "Favorites: \(LibraryActions.spokenList(entities)).")
    }
}

// MARK: - Collections

/// A box set or a video playlist as Siri sees it.
struct CollectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Collection")
    static let defaultQuery = CollectionQuery()

    var id: String
    var title: String
    var detail: String
    var isPlaylist: Bool
    var artwork: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)", image: artwork.map { .init(url: $0) })
    }

    init(_ item: BaseItem) {
        id = item.Id
        title = item.title
        isPlaylist = item.isPlaylist
        var facts = [item.isPlaylist ? "Playlist" : "Collection"]
        if let n = item.ChildCount, n > 0 { facts.append("\(n) titles") }
        detail = facts.joined(separator: " · ")
        artwork = Artwork.url(item, width: 300)
    }
}

struct CollectionQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CollectionEntity] {
        let found = (try? await JellyfinClient.shared.itemsByIds(identifiers, fields: "ChildCount,MediaType")) ?? []
        return found.map(CollectionEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [CollectionEntity] {
        try await JellyfinClient.shared.collections(matching: string).map(CollectionEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [CollectionEntity] {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else { return [] }
        return ((try? await client.collections(matching: "", limit: 10)) ?? []).map(CollectionEntity.init)
    }
}

struct PlayCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Collection"
    static let description = IntentDescription("Plays a box set or a video playlist from the start, in its order or shuffled, and queues the rest.")
    static let openAppWhenRun = true

    @Parameter(title: "Collection")
    var collection: CollectionEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$shuffle, .equalTo, true) {
            Summary("Shuffle \(\.$collection)")
        } otherwise: {
            Summary("Play \(\.$collection)")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else {
            return .result(value: [], dialog: "The server can't be reached.")
        }
        await AppModel.shared.refreshConnectivity()
        var items = collection.isPlaylist
            ? try await client.playlistItems(playlistId: collection.id)
            : try await client.boxSetItems(collection.id)
        // A show in a box set stands for its next unwatched episode; a
        // folder of anything else is skipped.
        var expanded: [BaseItem] = []
        for item in items {
            if item.isSeries {
                let episodes = (try? await client.episodes(seriesId: item.Id, seasonId: nil)) ?? []
                if let next = episodes.first(where: { !$0.userData.played }) ?? episodes.first { expanded.append(next) }
            } else if !item.isFolderLike, !item.isAudio {
                expanded.append(item)
            }
        }
        items = shuffle ? expanded.shuffled() : expanded
        guard let first = items.first else { return .result(value: [], dialog: "\(collection.title) is empty.") }
        let player = PlayerModel.shared
        await player.play(item: first)
        #if !os(tvOS)
        player.queueLater(Array(items.dropFirst()))
        #endif
        return .result(value: items.map(MediaItemEntity.init), dialog: "Playing \(collection.title).")
    }
}

// MARK: - A random pick

struct SurpriseMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Surprise Me"
    static let description = IntentDescription("Plays something you haven't seen, chosen at random — by kind, genre or length if you like. Instant from the library copy, and works offline from it.")
    static let openAppWhenRun = true

    @Parameter(title: "Kind", default: .anything)
    var kind: TitleKind

    @Parameter(title: "Genre")
    var genre: String?

    @Parameter(title: "No longer than (minutes)")
    var maxMinutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Play a random unwatched \(\.$kind)") {
            \.$genre
            \.$maxMinutes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MediaItemEntity> & ProvidesDialog {
        let client = JellyfinClient.shared
        guard client.isSignedIn else { throw PlaybackError.nothingPlaying }
        await AppModel.shared.refreshConnectivity()
        let libraries = await LibraryActions.videoLibraries()
        let genreName = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = JellyfinClient.LibraryQuery(limit: 40, includeTypes: kind.includeTypes, sortBy: "Random", unwatched: true)
        if let genreName, !genreName.isEmpty { query.genre = genreName }
        var candidates: [BaseItem] = []
        for library in libraries {
            candidates += (try? await client.libraryItems(parentId: library.Id, query: query))?.items ?? []
        }
        if let maxMinutes, maxMinutes > 0 {
            // A show is as long as one episode; the limit is about tonight.
            candidates = candidates.filter { $0.runtimeSeconds <= 0 || $0.runtimeSeconds <= Double(maxMinutes) * 60 }
        }
        guard let pick = candidates.randomElement() else { throw PlaybackError.nothingFits }
        await AppModel.shared.play(itemId: pick.Id)
        return .result(value: MediaItemEntity(pick), dialog: "How about \(pick.title)?")
    }
}

// MARK: - Downloads

#if !os(tvOS)
enum DownloadQualityChoice: String, AppEnum {
    case settings, original, uhd, qhd, fhd, hd, sd

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quality")
    static let caseDisplayRepresentations: [DownloadQualityChoice: DisplayRepresentation] = [
        .settings: "As in Settings", .original: "Original quality", .uhd: "4K", .qhd: "1440p",
        .fhd: "1080p", .hd: "720p", .sd: "480p",
    ]

    var quality: DownloadQuality {
        let all = DownloadQualities.all
        switch self {
        case .settings: return DownloadQualities.named(Preferences.shared.downloadQuality)
        case .original: return all[0]
        case .uhd: return all[1]
        case .qhd: return all[2]
        case .fhd: return all[3]
        case .hd: return all[4]
        case .sd: return all[5]
        }
    }
}

struct DownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Download"
    static let description = IntentDescription("Downloads a film or an episode, or the next unwatched episodes of a show, to watch without the server.")

    @Parameter(title: "Title")
    var item: MediaItemEntity

    @Parameter(title: "Episodes", default: 1, inclusiveRange: (1, 50))
    var count: Int

    @Parameter(title: "Quality", default: .settings)
    var quality: DownloadQualityChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$item)") {
            \.$count
            \.$quality
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else {
            return .result(value: [], dialog: "The server can't be reached.")
        }
        let manager = DownloadManager.shared
        // Asked for whole: a download needs the media sources, which the
        // lists leave out — see `ItemContextMenu.queueDownload`.
        var wanted: [BaseItem] = []
        if item.kind == "Series" {
            let episodes = (try? await client.episodes(seriesId: item.id, seasonId: nil)) ?? []
            // The next episodes are the story's: season by season, episode by
            // episode. The server lists specials (season 0) first, and "the
            // next three" should never be three specials — they only count
            // when the series has nothing else left to fetch.
            // Matched by what an episode is as well as by id, as `enqueue`
            // does, so one already here under an old id isn't picked and then
            // skipped, leaving "the next three" one short. An episode with no
            // season number is not a special.
            let unfetched = episodes.filter {
                !$0.userData.played && manager.completeRecord(matching: $0) == nil && !manager.isQueuedOrRunning($0.Id)
            }
            let regular = unfetched.filter { $0.ParentIndexNumber != 0 }
            let next = (regular.isEmpty ? unfetched : regular).sorted {
                (DownloadGroups.seasonSortKey($0.ParentIndexNumber), $0.IndexNumber ?? 0)
                    < (DownloadGroups.seasonSortKey($1.ParentIndexNumber), $1.IndexNumber ?? 0)
            }
            let ids = next.prefix(count).map(\.Id)
            let fetched = ids.isEmpty ? [] : try await client.itemsByIds(ids, fields: "MediaSources")
            // Queued in the order chosen, whatever order the server sends them.
            wanted = fetched.sorted { (ids.firstIndex(of: $0.Id) ?? .max) < (ids.firstIndex(of: $1.Id) ?? .max) }
        } else {
            guard !isDownloaded(item.id) else {
                return .result(value: [item], dialog: "\(item.title) is already downloaded.")
            }
            wanted = [try await client.item(item.id)]
        }
        guard !wanted.isEmpty else { return .result(value: [], dialog: "There's nothing left to download for \(item.title).") }
        let rung = quality.quality
        if let verdict = DownloadManager.checkSpace(for: wanted, quality: rung), !verdict.fits {
            return .result(value: [], dialog: "Not enough space: that needs about \(Format.bytes(verdict.needed)) and there is \(Format.bytes(verdict.free)) free.")
        }
        let outcome = manager.enqueue(items: wanted, quality: rung)
        let what = wanted.count == 1 ? wanted[0].title : "\(outcome.queued) episodes of \(item.title)"
        guard outcome.queued > 0 else { return .result(value: [], dialog: "\(item.title) is already downloaded.") }
        return .result(value: wanted.map(MediaItemEntity.init), dialog: "Queued \(what).")
    }

    /// On the device or on its way there. A record alone isn't that: a
    /// cancelled or failed one is still listed, and is worth asking for again.
    @MainActor
    private func isDownloaded(_ itemId: String) -> Bool {
        let manager = DownloadManager.shared
        return manager.record(for: itemId)?.status == .complete || manager.isQueuedOrRunning(itemId)
    }
}

struct DownloadsStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Downloads"
    static let description = IntentDescription("What's downloaded on this device and how much space it takes. Returns the films and episodes.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        let manager = DownloadManager.shared
        let complete = manager.records.filter { $0.status == .complete }
        let videos = complete.filter { !$0.isAudio }
        let audio = complete.count - videos.count
        guard !complete.isEmpty else { return .result(value: [], dialog: "Nothing is downloaded.") }
        var parts: [String] = []
        if !videos.isEmpty { parts.append("\(videos.count) \(videos.count == 1 ? "video" : "videos")") }
        if audio > 0 { parts.append("\(audio) audio") }
        let size = Format.bytes(manager.totalBytesOnDisk)
        let queued = manager.queue.count
        var dialog = "\(parts.joined(separator: " and ")) downloaded, using \(size)."
        if queued > 0 { dialog += " \(queued) more queued." }
        return .result(value: videos.map(MediaItemEntity.init(record:)), dialog: "\(dialog)")
    }
}

struct DeleteDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Download"
    static let description = IntentDescription("Removes a downloaded film or episode — or every downloaded episode of a show — from this device.")

    @Parameter(title: "Title")
    var item: MediaItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Delete the download of \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = DownloadManager.shared
        if manager.record(for: item.id) != nil {
            manager.delete(item.id)
            return .result(dialog: "Deleted \(item.title).")
        }
        let episodes = manager.records.filter { $0.seriesId == item.id }.map(\.itemId)
        guard !episodes.isEmpty else { return .result(dialog: "\(item.title) isn't downloaded.") }
        let removed = manager.delete(episodes)
        return .result(dialog: "Deleted \(removed) episodes of \(item.title).")
    }
}
#endif
