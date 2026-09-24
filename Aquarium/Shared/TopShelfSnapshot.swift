//  What the app leaves behind for the Apple TV home screen to read.
//
//  The top shelf is drawn by a separate process that the system starts on its
//  own schedule — often when the app has not run for days, and never with the
//  app's keychain in reach. So the extension is given no credentials and asks
//  the server nothing: the app writes a small manifest and the poster JPEGs
//  next to it into the shared group container each time Home refreshes, and the
//  extension only reads what is already on disk. That also keeps the access
//  token where `Keychain` promises it stays, and means a shelf full of posters
//  costs the extension no network at all.
//
//  Compiled into both the app and the TopShelf extension — the one file both
//  sides agree on.

import Foundation

/// The Next Up list, flattened to what a top shelf cell can draw.
struct TopShelfSnapshot: Codable, Sendable {
    struct Entry: Codable, Sendable {
        /// The Jellyfin item id, which is also what the deep link carries back.
        var id: String
        /// Drawn under the poster. The series name, since the poster is the
        /// series' — Next Up returns at most one episode per show, so there is
        /// nothing for an episode number to disambiguate.
        var title: String
        /// File name inside `TopShelfPaths.images`, not a path: the container's
        /// address is not the same in both processes on every OS version, so
        /// each side resolves it for itself.
        var image: String
        /// 0...1, for the bar across the bottom of the cell. Zero for an
        /// episode not yet started, which is most of them.
        var progress: Double
    }

    var entries: [Entry]
    /// When the app last wrote this. Only ever used to say how stale the shelf
    /// is in a log line; the extension draws whatever it finds.
    var generated: Date
}

/// Where the two processes meet.
enum TopShelfPaths {
    /// Must match the `com.apple.security.application-groups` entitlement on
    /// both targets.
    /// Registered under the pre-Aquarium name; it moves only with the bundle id.
    static let appGroup = "group.scottai.FellyJin"

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("TopShelf", isDirectory: true)
    }

    static var manifest: URL? { directory?.appendingPathComponent("nextup.json") }

    static var images: URL? { directory?.appendingPathComponent("images", isDirectory: true) }

    /// The deep link a cell opens. `aquarium://item/<id>` shows the title page;
    /// `aquarium://play/<id>` starts it, and is what the Play button on the
    /// remote does while a cell is focused.
    static func link(_ action: String, _ id: String) -> URL? {
        URL(string: "aquarium://\(action)/\(id)")
    }
}
