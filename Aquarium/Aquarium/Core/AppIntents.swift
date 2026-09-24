//  What Siri and the Shortcuts app can ask of this app.
//
//  Two things, both of which open the app and play: "Continue watching",
//  which is whatever Home's Continue Watching row would have put first, and
//  "Play <title>", which looks the title up in the library copy when there is
//  one and asks the server otherwise. A third, "Show <title>", opens the
//  title's page without starting it. They are declared as App Shortcuts, so
//  they work by voice the moment the app is installed and never need setting
//  up in Shortcuts first.

import AppIntents
import Foundation

/// A film, show or episode as Siri sees it: an id, a title, and one line to
/// tell two titles apart.
struct MediaItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Title")
    static let defaultQuery = MediaItemQuery()

    var id: String
    var title: String
    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    init(_ item: BaseItem) {
        id = item.Id
        title = item.Name ?? "Untitled"
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
}

struct MediaItemQuery: EntityStringQuery {
    private static let kinds: Set<String> = ["Movie", "Series", "Episode"]

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MediaItemEntity] {
        // The copy first; what it doesn't hold is asked for in one request
        // rather than one per title — each of those was the whole detail
        // payload, cast and all, for a name and a year.
        var found: [String: BaseItem] = [:]
        for id in identifiers {
            if let kept = LibraryIndex.shared.item(id) { found[id] = kept }
        }
        let missing = identifiers.filter { found[$0] == nil }
        if !missing.isEmpty,
           let fetched = try? await JellyfinClient.shared.itemsByIds(missing, fields: "ProductionYear") {
            for item in fetched { found[item.Id] = item }
        }
        return identifiers.compactMap { found[$0].map(MediaItemEntity.init) }
    }

    /// What "Play Heat" resolves against. The copy answers instantly and
    /// offline; the server's search is the fallback, and also the only answer
    /// when the copy is off.
    @MainActor
    func entities(matching string: String) async throws -> [MediaItemEntity] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        if let local = LibraryIndex.shared.search(term, limit: 12), !local.isEmpty {
            return local.map(MediaItemEntity.init)
        }
        let response = try await JellyfinClient.shared.search(term, limit: 12)
        return (response.Items ?? []).filter { Self.kinds.contains($0.kind) }.map(MediaItemEntity.init)
    }

    /// What Siri offers before anything is typed: the titles part-watched and
    /// the episodes up next — the same rows Home leads with.
    @MainActor
    func suggestedEntities() async throws -> [MediaItemEntity] {
        let client = JellyfinClient.shared
        guard client.isSignedIn else { return [] }
        async let resume = (try? client.resume()) ?? []
        async let nextUp = (try? client.nextUp()) ?? []
        var seen = Set<String>()
        return (await resume + nextUp).filter { seen.insert($0.Id).inserted }.prefix(10).map(MediaItemEntity.init)
    }
}

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
    static let description = IntentDescription("Plays a film, a show's next episode, or an episode from your Jellyfin server.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var item: MediaItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.shared.play(itemId: item.id)
        return .result()
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
    func perform() async throws -> some IntentResult {
        AppModel.shared.open(itemId: item.id)
        return .result()
    }
}

struct AquariumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueWatchingIntent(),
            phrases: [
                "Continue watching in \(.applicationName)",
                "Continue watching on \(.applicationName)",
                "Resume what I was watching in \(.applicationName)",
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayMediaIntent(),
            phrases: [
                "Play \(\.$item) in \(.applicationName)",
                "Play \(\.$item) on \(.applicationName)",
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
            ],
            shortTitle: "Show a Title",
            systemImageName: "info.circle"
        )
    }
}
