//  What Siri and the Shortcuts app can ask of this app, for video.
//
//  "Continue watching" is whatever Home's Continue Watching row would have
//  put first; "Play <title>" looks the title up in the library copy when
//  there is one, in the downloads when the server can't be reached, and asks
//  the server otherwise; "Show <title>" opens the title's page without
//  starting it. The player's own controls — sleep timer, speed, skipping,
//  the queue, languages — are in PlayerIntents.swift; the library ones —
//  what's new, watched, favourites, collections, a random pick, downloads —
//  in LibraryIntents.swift; music and audiobooks in MusicIntents.swift.
//
//  The ten App Shortcuts at the bottom (the system allows no more) work by
//  voice the moment the app is installed and never need setting up in
//  Shortcuts first. Every other intent is there for the Shortcuts app, where
//  the ones that return a value can be chained: "What's new" into "Download",
//  "Up next" into a list, "Surprise me" into a notification.
//
//  Compiled into the iPhone, iPad, Apple TV and Mac apps alike; the watch
//  has its own (Watch/WatchIntents.swift).

import AppIntents
import Foundation
#if os(iOS) || os(macOS)
import CoreSpotlight
#endif

/// A film, show or episode as Siri sees it: an id, a title, and one line to
/// tell two titles apart. The properties are `@Property` so the system's
/// search can index them — see `SpotlightIndexer`.
struct MediaItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Title")
    static let defaultQuery = MediaItemQuery()

    var id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Details")
    var detail: String

    /// "Movie", "Series" or "Episode".
    @Property(title: "Kind")
    var kind: String

    @Property(title: "Year")
    var year: Int?

    @Property(title: "Series")
    var seriesName: String?

    @Property(title: "Season")
    var season: Int?

    @Property(title: "Episode")
    var episode: Int?

    @Property(title: "Minutes")
    var minutes: Int?

    @Property(title: "Watched")
    var watched: Bool

    @Property(title: "Favorite")
    var favorite: Bool

    @Property(title: "Genres")
    var genres: [String]

    /// The poster, for Siri's card. The server's image routes take no token,
    /// so the system can fetch it without us.
    var artwork: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(detail)",
            image: artwork.map { .init(url: $0) }
        )
    }

    init(_ item: BaseItem) {
        id = item.Id
        title = item.Name ?? "Untitled"
        kind = item.kind
        year = item.ProductionYear
        seriesName = item.SeriesName
        season = item.isEpisode ? item.ParentIndexNumber : nil
        episode = item.isEpisode ? item.IndexNumber : nil
        minutes = item.kind == "Series" || item.runtimeSeconds <= 0 ? nil : Int((item.runtimeSeconds / 60).rounded())
        watched = item.userData.played
        favorite = item.userData.isFavorite
        genres = item.Genres ?? []
        artwork = Artwork.url(item, width: 300)
        var facts: [String] = []
        switch item.kind {
        case "Episode":
            if let series = item.SeriesName { facts.append(series) }
            if let label = item.episodeLabel { facts.append(label) }
        case "Series":
            facts.append("TV show")
            if let year = item.ProductionYear { facts.append(String(year)) }
        default:
            facts.append("Film")
            if let year = item.ProductionYear { facts.append(String(year)) }
        }
        detail = facts.joined(separator: " · ")
    }

    #if !os(tvOS)
    /// A downloaded film or episode, for when the server can't be asked.
    init(record: DownloadRecord) {
        id = record.itemId
        title = record.name
        kind = record.type ?? (record.isEpisode ? "Episode" : "Movie")
        year = record.year
        seriesName = record.series
        season = record.season
        episode = record.episode
        minutes = record.runTimeTicks > 0 ? Int((Double(record.runTimeTicks) / 600_000_000).rounded()) : nil
        watched = record.played
        favorite = false
        genres = []
        artwork = nil
        var facts: [String] = []
        if record.isEpisode {
            if let series = record.series { facts.append(series) }
            if let s = record.season, let e = record.episode { facts.append(String(format: "S%02dE%02d", s, e)) }
        } else {
            facts.append("Film")
            if let year = record.year { facts.append(String(year)) }
        }
        facts.append("Downloaded")
        detail = facts.joined(separator: " · ")
    }

    /// A downloaded show, standing for its episodes on this device.
    init(seriesId: String, name: String, episodes: Int) {
        id = seriesId
        title = name
        kind = "Series"
        year = nil
        seriesName = nil
        season = nil
        episode = nil
        minutes = nil
        watched = false
        favorite = false
        genres = []
        artwork = nil
        detail = "TV show · \(episodes) downloaded"
    }
    #endif
}

#if os(iOS) || os(macOS)
/// Indexed through App Intents as well as Core Spotlight, so Siri's
/// semantic search and the system's suggestions see the same titles the
/// search field does. See `SpotlightIndexer`, which associates each
/// searchable item with its entity.
@available(iOS 18.0, macOS 15.0, *)
extension MediaItemEntity: IndexedEntity {}
#endif

struct MediaItemQuery: EntityStringQuery {
    private static let kinds: Set<String> = ["Movie", "Series", "Episode"]

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MediaItemEntity] {
        // The copy first; what it doesn't hold is asked for in one request
        // rather than one per title — each of those was the whole detail
        // payload, cast and all, for a name and a year.
        var found: [String: MediaItemEntity] = [:]
        for id in identifiers {
            if let kept = LibraryIndex.shared.item(id) { found[id] = MediaItemEntity(kept) }
        }
        #if !os(tvOS)
        // Then the downloads, which answer with no server at all.
        for id in identifiers where found[id] == nil {
            if let entity = Self.downloaded(id) { found[id] = entity }
        }
        #endif
        let missing = identifiers.filter { found[$0] == nil }
        if !missing.isEmpty, JellyfinClient.shared.isSignedIn, !JellyfinClient.shared.showsOffline,
           let fetched = try? await JellyfinClient.shared.itemsByIds(missing, fields: "ProductionYear,Genres,UserData") {
            for item in fetched { found[item.Id] = MediaItemEntity(item) }
        }
        return identifiers.compactMap { found[$0] }
    }

    /// What "Play Heat" resolves against. The copy answers instantly and
    /// offline; the downloads answer when there is no copy and no server;
    /// the server's search is the fallback, and also the only answer when
    /// the copy is off.
    @MainActor
    func entities(matching string: String) async throws -> [MediaItemEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        if let local = LibraryIndex.shared.search(term, limit: 12), !local.isEmpty {
            return local.map(MediaItemEntity.init)
        }
        let client = JellyfinClient.shared
        #if !os(tvOS)
        if !client.isSignedIn || client.showsOffline {
            return Self.searchDownloads(term)
        }
        #endif
        let response = try await client.search(term, limit: 12)
        return (response.Items ?? []).filter { Self.kinds.contains($0.kind) }.map(MediaItemEntity.init)
    }

    /// What Siri offers before anything is typed: the titles part-watched and
    /// the episodes up next — the same rows Home leads with — and, with the
    /// server out of reach, the downloads.
    @MainActor
    func suggestedEntities() async throws -> [MediaItemEntity] {
        let client = JellyfinClient.shared
        guard client.isSignedIn else { return [] }
        #if !os(tvOS)
        if client.showsOffline { return Self.searchDownloads("") }
        #endif
        async let resume = (try? client.resume()) ?? []
        async let nextUp = (try? client.nextUp()) ?? []
        var seen = Set<String>()
        return (await resume + nextUp).filter { seen.insert($0.Id).inserted }.prefix(10).map(MediaItemEntity.init)
    }

    #if !os(tvOS)
    /// A downloaded film or episode by id, or a show by the id its episodes
    /// share.
    @MainActor
    static func downloaded(_ id: String) -> MediaItemEntity? {
        let manager = DownloadManager.shared
        if let record = manager.record(for: id), !record.isAudio, record.status == .complete {
            return MediaItemEntity(record: record)
        }
        let episodes = manager.records.filter { $0.seriesId == id && !$0.isAudio && $0.status == .complete }
        guard let first = episodes.first, let name = first.series else { return nil }
        return MediaItemEntity(seriesId: id, name: name, episodes: episodes.count)
    }

    /// The downloads matching a few typed words: shows first, then films and
    /// episodes. An empty term lists them all.
    @MainActor
    static func searchDownloads(_ term: String) -> [MediaItemEntity] {
        let needle = term.lowercased()
        let records = DownloadManager.shared.records.filter { !$0.isAudio && $0.status == .complete }
        func matches(_ text: String?) -> Bool { needle.isEmpty || (text?.lowercased().contains(needle) ?? false) }
        var out: [MediaItemEntity] = []
        var series: [String: (name: String, count: Int)] = [:]
        for record in records {
            if let seriesId = record.seriesId, let name = record.series, matches(name) {
                series[seriesId, default: (name, 0)].count += 1
            }
        }
        for (id, entry) in series.sorted(by: { $0.value.name < $1.value.name }) {
            out.append(MediaItemEntity(seriesId: id, name: entry.name, episodes: entry.count))
        }
        for record in records where matches(record.name) || (record.isEpisode && matches(record.series)) {
            out.append(MediaItemEntity(record: record))
        }
        return Array(out.prefix(20))
    }
    #endif
}

// MARK: - Intents

struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Picks up the film or episode you were in the middle of, or the next episode of what you were watching.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.shared.continueWatching()
        return .result()
    }
}

struct PlayMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Plays a film, a show's next episode, or an episode from your Jellyfin server — or from your downloads when the server can't be reached.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var item: MediaItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$item)")
    }

    init() {}
    init(item: MediaItemEntity) { self.item = item }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MediaItemEntity> & ProvidesDialog {
        let app = AppModel.shared
        let client = JellyfinClient.shared
        guard client.isSignedIn else {
            return .result(value: item, dialog: "Sign in to a Jellyfin server first.")
        }
        await app.refreshConnectivity()

        #if !os(tvOS)
        // No server: the downloads, said so, rather than a page that waits
        // for a server to fill it in.
        if client.showsOffline {
            return .result(value: item, dialog: try await playDownloaded())
        }
        #endif

        // A show by name is two different requests — carry on, or start
        // over — and when they differ, Siri asks which.
        if item.kind == "Series", let chosen = try await chooseEpisode() {
            await PlayerModel.shared.play(item: chosen)
            return .result(value: MediaItemEntity(chosen), dialog: "Playing \(Self.spoken(chosen)).")
        }
        await app.play(itemId: item.id)
        return .result(value: item, dialog: "Playing \(item.title).")
    }

    /// The episode to start a show from. Nil means `AppModel.play` should
    /// decide (the first unwatched), which is also the only answer when
    /// there is nothing to choose between.
    @MainActor
    private func chooseEpisode() async throws -> BaseItem? {
        let client = JellyfinClient.shared
        let episodes = (try? await client.episodes(seriesId: item.id, seasonId: nil)) ?? []
        guard let first = episodes.first else { return nil }
        let partWatched = (try? await client.resume())?.first { $0.SeriesId == item.id }
        let nextUp = try? await client.seriesNextUp(seriesId: item.id)
        guard let next = partWatched ?? nextUp, next.Id != first.Id else { return nil }
        let choices = [next, first].map(MediaItemEntity.init)
        let picked = try await $item.requestDisambiguation(
            among: choices,
            dialog: "Carry on with \(Self.spoken(next)), or start \(item.title) from the beginning?"
        )
        return picked.id == first.Id ? first : next
    }

    private static func spoken(_ episode: BaseItem) -> String {
        if let label = episode.episodeLabel, let series = episode.SeriesName { return "\(series), \(label)" }
        return episode.title
    }

    #if !os(tvOS)
    @MainActor
    private func playDownloaded() async throws -> IntentDialog {
        let manager = DownloadManager.shared
        let records = manager.records.filter { !$0.isAudio && $0.status == .complete }
        let record: DownloadRecord?
        if let own = records.first(where: { $0.itemId == item.id }) {
            record = own
        } else {
            // A show: the first downloaded episode not yet watched, in order.
            record = records
                .filter { $0.seriesId == item.id }
                .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
                .first { !$0.played } ?? records.first { $0.seriesId == item.id }
        }
        guard let record, manager.mediaURL(for: record) != nil else {
            throw PlaybackError.notDownloaded(item.title)
        }
        PlayerModel.shared.playLocal(record)
        return "Playing \(record.name) from your downloads."
    }
    #endif
}

/// Why a play request could not be honoured, in Siri's words.
enum PlaybackError: Error, CustomLocalizedStringResourceConvertible {
    case notDownloaded(String)
    case nothingPlaying
    case nothingFits

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notDownloaded(let title): "\(title) isn't downloaded, and the server can't be reached."
        case .nothingPlaying: "Nothing is playing."
        case .nothingFits: "Nothing unwatched fits that."
        }
    }
}

struct OpenMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Show"
    static let description = IntentDescription("Opens a title's page without starting it.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var item: MediaItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MediaItemEntity> {
        AppModel.shared.open(itemId: item.id)
        return .result(value: item)
    }
}

// MARK: - App Shortcuts

/// The ten that work by voice with no setting up. Siri needs the app's name
/// in each phrase; the ones with an entity in them are matched against the
/// titles `suggestedEntities` offers and whatever the user says.
struct AquariumShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueWatchingIntent(),
            phrases: [
                "Continue watching in \(.applicationName)",
                "Continue watching on \(.applicationName)",
                "Resume what I was watching in \(.applicationName)",
                "What's next on \(.applicationName)",
                "Pick up where I left off in \(.applicationName)",
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayMediaIntent(),
            phrases: [
                "Play \(\.$item) in \(.applicationName)",
                "Play \(\.$item) on \(.applicationName)",
                "Watch \(\.$item) in \(.applicationName)",
                "Put on \(\.$item) in \(.applicationName)",
                "Play something in \(.applicationName)",
            ],
            shortTitle: "Play a Title",
            systemImageName: "play"
        )
        AppShortcut(
            intent: OpenMediaIntent(),
            phrases: [
                "Show \(\.$item) in \(.applicationName)",
                "Open \(\.$item) in \(.applicationName)",
                "Find \(\.$item) in \(.applicationName)",
            ],
            shortTitle: "Show a Title",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: SurpriseMeIntent(),
            phrases: [
                "Surprise me in \(.applicationName)",
                "Play something I haven't seen in \(.applicationName)",
                "Pick a film for me in \(.applicationName)",
                "Pick a movie for me in \(.applicationName)",
                "Pick something to watch in \(.applicationName)",
            ],
            shortTitle: "Surprise Me",
            systemImageName: "dice"
        )
        AppShortcut(
            intent: WhatsNewIntent(),
            phrases: [
                "What's new in \(.applicationName)",
                "What's new on \(.applicationName)",
                "What was added to \(.applicationName)",
                "Show me new titles in \(.applicationName)",
            ],
            shortTitle: "What's New",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            // Siri can fill an entity or an enum from a phrase, not a
            // number; the minutes are asked for after.
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Start a sleep timer in \(.applicationName)",
                "Stop \(.applicationName) in a while",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: NextEpisodeIntent(),
            phrases: [
                "Next episode in \(.applicationName)",
                "Play the next episode in \(.applicationName)",
                "Skip to the next episode in \(.applicationName)",
            ],
            shortTitle: "Next Episode",
            systemImageName: "forward.end"
        )
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
            intent: PlayMusicIntent(),
            phrases: [
                "Play \(\.$music) in \(.applicationName)",
                "Play the album \(\.$music) in \(.applicationName)",
                "Play the playlist \(\.$music) in \(.applicationName)",
                "Play some \(\.$music) in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: ShuffleMusicIntent(),
            phrases: [
                "Shuffle my music in \(.applicationName)",
                "Shuffle \(.applicationName)",
                "Play my music in \(.applicationName)",
            ],
            shortTitle: "Shuffle Music",
            systemImageName: "shuffle"
        )
    }
}
