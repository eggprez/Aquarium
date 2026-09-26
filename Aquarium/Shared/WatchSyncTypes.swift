//  What the iPhone app and the Apple Watch app say to each other.
//
//  WatchConnectivity carries property lists, so everything here is one
//  Codable value encoded as JSON and put under a single key — see
//  `WatchSync.pack` — which keeps the two sides free to add a field without
//  the other side choking on it. Every field is optional on the wire for the
//  same reason `BaseItem`'s are.
//
//  Three kinds of traffic:
//
//  - The **phone's context**: who is signed in and what the watch should keep
//    mirrored. Sent as the application context, so only the latest matters
//    and it is waiting for the watch whenever it next wakes.
//  - The **watch's context**: what is on the watch, in groups a person would
//    delete by — an album, a playlist, a book. Also the application context,
//    the other way.
//  - **Messages**: a delete or a download asked for from the phone, and the
//    listening the watch has done, sent as a queued transfer when the phone
//    is away and as a live message when it is in reach.
//
//  Compiled into the iOS app and the watch app. Nothing in here imports
//  WatchConnectivity: it is the vocabulary, not the transport.

import Foundation

enum WatchSync {
    /// The one key under which a payload travels.
    static let key = "aquarium"

    static func pack<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return [key: data]
    }

    static func unpack<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) -> T? {
        guard let data = dictionary[key] as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Phone → watch

/// The sign-in, handed over so nothing is typed on a wrist.
struct WatchCredentials: Codable, Hashable, Sendable {
    var server: String
    var userId: String
    var userName: String
    var serverId: String?
    var token: String
}

/// What the phone wants kept on the watch without anyone asking each time:
/// the audiobooks that are part-way through, and the playlists picked for it.
/// Ids only — the watch asks the server for the rest when it has a network,
/// which is the only time it could download anything anyway.
struct WatchMirrorPlan: Codable, Hashable, Sendable {
    var bookIds: [String] = []
    var playlistIds: [String] = []
}

struct PhoneContext: Codable, Sendable {
    var revision: Int
    /// Nil means signed out: the watch forgets its token and shows sign-in.
    var credentials: WatchCredentials?
    var mirror = WatchMirrorPlan()
    var sentAt = Date()
}

// MARK: - Watch → phone

/// One row of the watch's storage as the phone lists it. A song sits under
/// its album; a book and a playlist stand on their own. The phone deletes by
/// group, and the watch resolves the group to files.
struct WatchStorageGroup: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case album, playlist, book, songs
        var label: String {
            switch self {
            case .album: "Album"
            case .playlist: "Playlist"
            case .book: "Audiobook"
            case .songs: "Songs"
            }
        }
        var symbol: String {
            switch self {
            case .album: "square.stack"
            case .playlist: "music.note.list"
            case .book: "book"
            case .songs: "music.note"
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var count: Int
    var bytes: Int64
    /// How many of the group's items have landed, against `count`: an album
    /// still arriving reads "4 of 12".
    var complete: Int
}

struct WatchInventory: Codable, Hashable, Sendable {
    var groups: [WatchStorageGroup] = []
    var itemCount = 0
    var totalBytes: Int64 = 0
    var freeBytes: Int64?
    /// Downloads queued or running.
    var inFlight = 0
    /// The list was cut to fit the message; the totals are still whole.
    var truncated = false
}

struct WatchContext: Codable, Sendable {
    var revision: Int
    var inventory: WatchInventory
    /// Whether the watch is signed in to the same account the phone last sent.
    var signedIn: Bool
    var sentAt = Date()
}

// MARK: - Messages, either way

/// Something asked for from the phone.
struct WatchDownloadRequest: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case album, playlist, book, song, artist, genre }
    var kind: Kind
    var id: String
    var title: String
}

/// Listening done on the watch, to be told to the server. One per stop,
/// pause, track change or finish; `played` is the one that counts as a play.
struct WatchProgressEvent: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var itemId: String
    var positionTicks: Int64
    /// Finished. For a book, done; for a song, heard to the end.
    var played: Bool
    var isAudiobook: Bool
    /// Streamed from the server rather than played from the watch's copy. The
    /// server counted the play itself when the stream started, so a finished
    /// stream is told as a stopped report at its end rather than as another
    /// play — see `WatchProgressEvent.deliver`.
    var streamed = false
    var at = Date()
}

enum WatchMessage: Codable, Sendable {
    // Phone → watch
    case deleteGroup(kind: WatchStorageGroup.Kind, id: String)
    case deleteAll
    case download(WatchDownloadRequest)
    case requestInventory
    /// How far the phone has got fetching an item for the watch, 0...1.
    case fetchProgress(itemId: String, fraction: Double)
    /// The phone could not fetch this; the watch may try itself.
    case fetchFailed(itemId: String, reason: String)
    // Watch → phone
    case progress([WatchProgressEvent])
    /// Fetch this item and hand it over as a file. The watch's own radio
    /// only reaches the server over Wi‑Fi; through the phone it goes as a
    /// file transfer, which runs in the background on both ends.
    case fetch(itemId: String)
    case cancelFetch(itemId: String)
    /// Send me the sign-in and the plan now, in the reply. The application
    /// context is the usual way; this is for a watch that missed it.
    case requestContext
}

/// The metadata on a file the phone hands the watch.
enum WatchFileTransfer {
    static let itemKey = "item"
    static let bytesKey = "bytes"
    static let secondsKey = "seconds"
}

/// The reply a live message gets. A queued transfer gets none.
struct WatchReply: Codable, Sendable {
    var ok: Bool
    var note: String?
    /// The answer to `requestContext`.
    var context: PhoneContext?
}
