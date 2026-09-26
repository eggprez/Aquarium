//  What the watch app tells its Smart Stack widget.
//
//  A widget is drawn by another process and can see none of the player, so
//  the app writes this small value into the app group whenever what is
//  playing changes, and asks the widget to redraw. Compiled into the watch
//  app and its widget extension.

import Foundation

struct ListeningSnapshot: Codable, Hashable, Sendable {
    var itemId: String
    var title: String
    var subtitle: String
    var isAudiobook: Bool
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var updatedAt = Date()

    var fraction: Double? {
        guard duration > 0, position > 0 else { return nil }
        return min(1, position / duration)
    }

    /// The group both bundles are in. Set on both targets' entitlements.
    static let appGroup = "group.scottai.FellyJin"

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("listening.json")
    }

    static func read() -> ListeningSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ListeningSnapshot.self, from: data)
    }

    static func write(_ snapshot: ListeningSnapshot?) {
        guard let file else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
