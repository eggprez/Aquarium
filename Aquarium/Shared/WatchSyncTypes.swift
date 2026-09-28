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

extension PhoneContext {
    private enum CodingKeys: String, CodingKey { case revision, credentials, mirror, sentAt }

    /// Key by key, so a side of the link one field behind — a phone that
    /// hasn't sent `mirror` or `sentAt` yet — doesn't fail the whole context
    /// over it. A synthesized `init(from:)` would: a default value in Swift
    /// isn't a default on the wire, only `Optional` gets that for free.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int.self, forKey: .revision)
        credentials = try c.decodeIfPresent(WatchCredentials.self, forKey: .credentials)
        mirror = try c.decodeIfPresent(WatchMirrorPlan.self, forKey: .mirror) ?? WatchMirrorPlan()
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
    }
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

extension WatchInventory {
    private enum CodingKeys: String, CodingKey { case groups, itemCount, totalBytes, freeBytes, inFlight, truncated }

    /// Key by key, for the same reason as `PhoneContext`: a default value in
    /// Swift isn't a default on the wire for the synthesized decoder.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([WatchStorageGroup].self, forKey: .groups) ?? []
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        freeBytes = try c.decodeIfPresent(Int64.self, forKey: .freeBytes)
        inFlight = try c.decodeIfPresent(Int.self, forKey: .inFlight) ?? 0
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

struct WatchContext: Codable, Sendable {
    var revision: Int
    var inventory: WatchInventory
    /// The items the watch has asked the phone for and is still waiting on.
    /// Whatever else the phone has queued for the watch, it drops: an ask
    /// the watch has since cancelled, or one left over from an old plan.
    /// Nil from a watch too old to say.
    var awaitingPhone: [String]?
    /// Every playlist the watch keeps, however it was asked for: what the
    /// phone's "Kept on the watch" switches show. Apart from the inventory,
    /// which is cut to fit a message. Nil from a watch too old to say.
    var playlistIds: [String]?
    /// Whether the watch is signed in to the same account the phone last sent.
    var signedIn: Bool
    var sentAt = Date()
}

extension WatchContext {
    private enum CodingKeys: String, CodingKey { case revision, inventory, awaitingPhone, playlistIds, signedIn, sentAt }

    /// Key by key, for the same reason as `PhoneContext`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int.self, forKey: .revision)
        inventory = try c.decode(WatchInventory.self, forKey: .inventory)
        awaitingPhone = try c.decodeIfPresent([String].self, forKey: .awaitingPhone)
        playlistIds = try c.decodeIfPresent([String].self, forKey: .playlistIds)
        signedIn = try c.decode(Bool.self, forKey: .signedIn)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
    }
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
/// pause, track change or finish, and one a minute while a book plays;
/// `played` is the one that counts as a play. `at` is when it was heard: a
/// book's position is dropped, not sent, if the book has been played
/// anywhere since — see `BookProgress.isStale`.
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
    /// Send the watch's log over as a file — see `WatchFileTransfer.logsKind`.
    case requestLogs
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
    /// The same for a whole list at once: a playlist's worth of songs asked
    /// for one message at a time swamps the link.
    case fetchMany(itemIds: [String])
    case cancelFetch(itemId: String)
    /// A playlist was taken off the watch there: the phone stops keeping it
    /// there too, or the next plan would put it straight back.
    case playlistRemoved(id: String)
    /// Send me the sign-in and the plan now, in the reply. The application
    /// context is the usual way; this is for a watch that missed it.
    case requestContext
    /// A slice of the watch's log, sent while the phone is in reach: the
    /// whole file, LZFSE-compressed, cut into pieces small enough for a
    /// message. A file transfer carries it when the phone is away.
    case logs(WatchLogChunk)
}

struct WatchLogChunk: Codable, Sendable {
    /// One export; every chunk of it carries the same id.
    var id: String
    var name: String
    var index: Int
    var count: Int
    var data: Data
}

/// What a watch download is fetched as. The server's own file when the watch
/// can play it and it isn't much bigger than the encode would be: an .m4b
/// audiobook sent as it sits on disk arrives at once, with a length, and
/// can't be cut short. An encode comes from the progressive stream, which
/// sends while ffmpeg is still writing, with no length — a long book there
/// can sit at nothing for as long as the server takes, or end early.
enum WatchDownloadSource {
    static let playableContainers: Set<String> = ["m4a", "m4b", "mp4", "mp3", "aac"]
    static let playableCodecs: Set<String> = ["aac", "mp3", "alac"]

    /// The extension the server's own file keeps, or nil to have it encoded.
    static func originalExtension(for item: BaseItem, encodedBytes: Int64) -> String? {
        guard let source = item.MediaSources?.first else { return nil }
        let names = (source.Container ?? "").lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard let container = names.first(where: { playableContainers.contains($0) }) else { return nil }
        if let codec = source.audioStreams.first?.Codec?.lowercased(), !codec.isEmpty, !playableCodecs.contains(codec) { return nil }
        if let size = source.Size, encodedBytes > 0, size > encodedBytes * 3 / 2 { return nil }
        return container == "mp4" ? "m4a" : container
    }

    /// The query for the server's own file, sent untouched with its length.
    static func originalQuery(for item: BaseItem, deviceId: String) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "deviceId", value: deviceId)]
        if let source = item.MediaSources?.first {
            if let id = source.Id { q.append(URLQueryItem(name: "mediaSourceId", value: id)) }
            if let tag = source.ETag { q.append(URLQueryItem(name: "Tag", value: tag)) }
        }
        return q
    }
}

/// The metadata on a file the phone hands the watch.
enum WatchFileTransfer {
    /// What a file is: absent for an audio item, `logsKind` for a log.
    static let kindKey = "kind"
    static let logsKind = "logs"
    static let itemKey = "item"
    static let bytesKey = "bytes"
    static let secondsKey = "seconds"
    /// The file's extension: the server's own file when the watch can play
    /// it (an .m4b, an .mp3), an .m4a when the phone had it encoded.
    static let extensionKey = "ext"
    /// A file past `pieceBytes` goes over in pieces of that size, each its
    /// own transfer: a book is hundreds of megabytes, and one transfer that
    /// large has taken the watch down with it (a Neural Engine timeout
    /// panic on watchOS 27.0, three times in a row, as each one started).
    /// A piece carries the send it belongs to, its place, and the count.
    static let sendKey = "send"
    static let pieceKey = "piece"
    static let piecesKey = "pieces"
    static let pieceBytesKey = "pieceBytes"
    static let pieceBytes: Int64 = 16 * 1024 * 1024
}

/// The reply a live message gets. A queued transfer gets none.
struct WatchReply: Codable, Sendable {
    var ok: Bool
    var note: String?
    /// The answer to `requestContext`.
    var context: PhoneContext?
    /// For `progress`: the events the server has had, or that it had
    /// something newer than. The rest the phone keeps and sends when it can;
    /// the watch keeps them too until a later reply names them. Nil from a
    /// phone too old to say, whose `ok` meant it had taken the lot.
    var delivered: [UUID]?
}

// MARK: - Listening rules, both ends

/// When a book counts as finished, and which of two accounts of it is the
/// newer. The watch and the phone decide with the same rules, and the rules
/// are the server's, so all three agree.
enum BookProgress {
    /// Jellyfin calls a book finished with less than this left: its
    /// MaxAudiobookResume, five minutes unless changed.
    static let finishWindow: TimeInterval = 5 * 60
    /// A watch, a phone and a server keep nearly the same time, not exactly.
    static let clockSlack: TimeInterval = 5

    static func isFinished(position: Double, duration: Double) -> Bool {
        duration > 0 && position > 0 && duration - position < finishWindow
    }

    static func isFinished(positionTicks: Int64, runTimeTicks: Int64) -> Bool {
        isFinished(position: Double(positionTicks) / 10_000_000, duration: Double(runTimeTicks) / 10_000_000)
    }

    /// A position heard at `eventAt` is old news when the book was started
    /// somewhere else after it: sent now, it would take someone back.
    static func isStale(eventAt: Date, serverLastPlayed: Date?) -> Bool {
        guard let serverLastPlayed else { return false }
        return serverLastPlayed.timeIntervalSince(eventAt) > clockSlack
    }

    /// Whether a record takes the server's word. Yes when everything heard
    /// locally has reached the server, or when the server's last play is
    /// later than the last local change.
    static func takesServer(synced: Bool, localChangedAt: Date?, serverLastPlayed: Date?) -> Bool {
        if synced { return true }
        guard let serverLastPlayed else { return false }
        guard let localChangedAt else { return true }
        return serverLastPlayed.timeIntervalSince(localChangedAt) > clockSlack
    }

    /// The server's `LastPlayedDate`. It writes seven places of fractional
    /// seconds, which `ISO8601DateFormatter` won't read, and some servers
    /// leave off the zone, which is UTC.
    static func date(fromServer text: String?) -> Date? {
        guard var s = text?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            let rest = s[s.index(after: dot)...]
            let digits = rest.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            s = String(s[..<dot]) + String(rest.dropFirst(digits.count))
        }
        if !s.hasSuffix("Z"), s.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil { s += "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map { $0.addingTimeInterval(fraction) }
    }
}
