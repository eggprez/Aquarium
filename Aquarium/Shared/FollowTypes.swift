//  What the app and the Follow widget agree on.
//
//  The widget is the Home Screen tile for one thing the user is in the
//  middle of: a film part-watched, a show with an episode up next, a
//  favourite. It is configurable — press and hold, Edit Widget, pick the
//  title — and the picking is done by an App Intent whose choices have to
//  come from somewhere the widget's process can read. It can't reach the
//  server, so the app writes the candidates here, into the app group, each
//  time Home loads its rows: what is part-watched, what is up next, and a
//  few favourites, with a poster for each beside the file. The widget then
//  draws whichever one was picked, or the first when none was.
//
//  Compiled into both the app and the LiveActivities extension. iPhone and
//  iPad only.

#if os(iOS)

import AppIntents
import Foundation

struct FollowSnapshot: Codable, Sendable {
    struct Entry: Codable, Hashable, Sendable, Identifiable {
        /// The show's id for an episode, so a tile set to a show keeps
        /// following it as the episodes go by; a film's own id otherwise.
        var id: String
        var title: String
        /// "S02E03 · The Bear" or "42 minutes left" or "Favorite".
        var subtitle: String
        /// How far through, 0...1, when there is a playhead to show.
        var fraction: Double?
        /// What a tap opens: the episode or the film.
        var linkId: String
        var isSeries: Bool
        var hasArtwork: Bool
    }

    var entries: [Entry]
    var updatedAt = Date()

    static let widgetKind = "scottai.FellyJin.follow"

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NowPlayingSnapshot.appGroup)
    }

    private static var file: URL? { folder?.appendingPathComponent("follow.json") }

    static func artworkFile(for id: String) -> URL? {
        // The id is the server's, hex and dashes, so it is safe in a name.
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return folder?.appendingPathComponent("follow-\(safe).jpg")
    }

    static func read() -> FollowSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(FollowSnapshot.self, from: data)
    }

    static func write(_ snapshot: FollowSnapshot?) {
        guard let file else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Drop the posters of entries no longer in the snapshot.
    static func pruneArtwork(keeping ids: Set<String>) {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let keep = Set(ids.compactMap { artworkFile(for: $0)?.lastPathComponent })
        for name in names where name.hasPrefix("follow-") && name.hasSuffix(".jpg") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

// MARK: - The widget's configuration

/// A title the widget can be set to follow, from the snapshot above.
struct FollowableEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Title")
    static let defaultQuery = FollowableQuery()

    var id: String
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ entry: FollowSnapshot.Entry) {
        id = entry.id
        title = entry.title
        subtitle = entry.subtitle
    }
}

struct FollowableQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FollowableEntity] {
        let entries = FollowSnapshot.read()?.entries ?? []
        return identifiers.compactMap { id in entries.first { $0.id == id }.map(FollowableEntity.init) }
    }

    func suggestedEntities() async throws -> [FollowableEntity] {
        (FollowSnapshot.read()?.entries ?? []).map(FollowableEntity.init)
    }

    func defaultResult() async -> FollowableEntity? {
        nil
    }
}

struct FollowTitleIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Follow a Title"
    static let description = IntentDescription("Which film or show the tile follows. Leave it empty for whatever is next.")

    @Parameter(title: "Title")
    var title: FollowableEntity?

    init() {}
    init(title: FollowableEntity?) { self.title = title }
}

#endif
