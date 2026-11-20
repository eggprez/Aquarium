//  Jellyfin SyncPlay, as it comes down the wire: what the server's web socket
//  says, read into values, and the arithmetic that turns the server's clock
//  into this device's. Nothing here touches the network or the player — see
//  `SyncPlayCoordinator` for that — so all of it can be tested with strings.
//
//  A socket message is `{"MessageType": …, "Data": …}`. Two types matter:
//  `SyncPlayGroupUpdate` (joined, left, somebody else came or went, the
//  queue changed) and `SyncPlayCommand` (unpause, pause, seek, stop — each
//  with the position it applies to and the server time to do it at).
//  `ForceKeepAlive` says how often the server wants to hear from the socket.

import Foundation

/// A group on the server, as `/SyncPlay/List` and the joined update give it.
struct SyncPlayGroup: Codable, Identifiable, Equatable, Sendable {
    var GroupId: String
    var GroupName: String
    var State: String?
    var Participants: [String]?

    var id: String { GroupId }
    var people: [String] { Participants ?? [] }

    /// "Movie night · 3 watching", "Movie night · just Alex".
    var summary: String {
        switch people.count {
        case 0: GroupName
        case 1: "\(GroupName) · just \(people[0])"
        default: "\(GroupName) · \(people.count) watching"
        }
    }
}

/// What the group is watching.
struct SyncPlayQueue: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var itemId: String
        var playlistItemId: String
    }

    var reason: String
    var lastUpdate: Date
    var entries: [Entry]
    var playingIndex: Int
    var startPositionTicks: Int64
    var isPlaying: Bool

    var current: Entry? { entries.indices.contains(playingIndex) ? entries[playingIndex] : nil }

    /// Where the group's playhead is at `serverNow`: where the update put
    /// it, plus however long it has been playing since.
    func position(serverNow: Date) -> Double {
        let start = Double(startPositionTicks) / 10_000_000
        return isPlaying ? start + max(0, serverNow.timeIntervalSince(lastUpdate)) : start
    }
}

/// One order to every device in the group.
struct SyncPlayCommand: Equatable, Sendable {
    enum Kind: String, Sendable { case unpause = "Unpause", pause = "Pause", seek = "Seek", stop = "Stop" }

    var kind: Kind
    var groupId: String
    var playlistItemId: String
    /// Server time to carry it out at.
    var when: Date
    var positionTicks: Int64?
    var emittedAt: Date

    var seconds: Double? { positionTicks.map { Double($0) / 10_000_000 } }
}

enum SyncPlayEvent: Equatable, Sendable {
    /// The server wants a `KeepAlive` at least this often, in seconds.
    case keepAlive(Double)
    case joined(SyncPlayGroup)
    case left
    case userJoined(String)
    case userLeft(String)
    case state(String)
    case queue(SyncPlayQueue)
    case command(SyncPlayCommand)
    /// The server turned something down: `NotInGroup`, `GroupDoesNotExist`,
    /// `LibraryAccessDenied`.
    case refused(String)
}

enum SyncPlayWire {
    /// One socket message, or nil for one that isn't SyncPlay's.
    static func event(from text: String) -> SyncPlayEvent? {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["MessageType"] as? String
        else { return nil }
        switch type {
        case "ForceKeepAlive":
            return (message["Data"] as? NSNumber).map { .keepAlive($0.doubleValue) }
        case "SyncPlayCommand":
            guard let body = message["Data"] as? [String: Any],
                  let kind = (body["Command"] as? String).flatMap(SyncPlayCommand.Kind.init(rawValue:)),
                  let when = date(body["When"] as? String)
            else { return nil }
            return .command(SyncPlayCommand(
                kind: kind,
                groupId: body["GroupId"] as? String ?? "",
                playlistItemId: body["PlaylistItemId"] as? String ?? "",
                when: when,
                positionTicks: (body["PositionTicks"] as? NSNumber)?.int64Value,
                emittedAt: date(body["EmittedAt"] as? String) ?? when))
        case "SyncPlayGroupUpdate":
            guard let update = message["Data"] as? [String: Any], let kind = update["Type"] as? String else { return nil }
            let body = update["Data"]
            switch kind {
            case "GroupJoined":
                guard let info = body as? [String: Any], let id = info["GroupId"] as? String else { return nil }
                return .joined(SyncPlayGroup(
                    GroupId: id, GroupName: info["GroupName"] as? String ?? "SyncPlay",
                    State: info["State"] as? String, Participants: info["Participants"] as? [String]))
            case "GroupLeft": return .left
            case "UserJoined": return .userJoined(body as? String ?? "")
            case "UserLeft": return .userLeft(body as? String ?? "")
            case "StateUpdate":
                return ((body as? [String: Any])?["State"] as? String).map { .state($0) }
            case "PlayQueue":
                guard let info = body as? [String: Any] else { return nil }
                let entries = (info["Playlist"] as? [[String: Any]] ?? []).compactMap { row -> SyncPlayQueue.Entry? in
                    guard let item = row["ItemId"] as? String, let entry = row["PlaylistItemId"] as? String else { return nil }
                    return .init(itemId: item, playlistItemId: entry)
                }
                return .queue(SyncPlayQueue(
                    reason: info["Reason"] as? String ?? "",
                    lastUpdate: date(info["LastUpdate"] as? String) ?? .distantPast,
                    entries: entries,
                    playingIndex: (info["PlayingItemIndex"] as? NSNumber)?.intValue ?? 0,
                    startPositionTicks: (info["StartPositionTicks"] as? NSNumber)?.int64Value ?? 0,
                    isPlaying: info["IsPlaying"] as? Bool ?? false))
            case "NotInGroup", "GroupDoesNotExist", "LibraryAccessDenied":
                return .refused(kind)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// A Jellyfin timestamp: ISO 8601 with up to seven decimal places
    /// (`2026-11-18T20:22:33.1234567Z`), which is more than
    /// `ISO8601DateFormatter` is documented to take. The whole seconds go
    /// through the formatter and the fraction is added by hand, so the
    /// sub-millisecond part — which is the point of a sync clock — is kept.
    static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            text.removeSubrange(dot..<text.index(dot, offsetBy: digits.count + 1))
        }
        // No zone is UTC: the server's clock is, and says so only sometimes.
        if !text.hasSuffix("Z"), text.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil {
            text += "Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map { $0.addingTimeInterval(fraction) }
    }

    /// The same shape back, to the millisecond.
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Jellyfin writes an id with or without dashes, in either case,
    /// depending on who is asking. The same id either way.
    static func sameId(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return normal(a) == normal(b)
    }

    static func normal(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func ticks(_ seconds: Double) -> Int64 { Int64((max(0, seconds) * 10_000_000).rounded()) }

    /// The socket's address for a server's: `http` becomes `ws`, `https`
    /// `wss`, and `/socket` goes on the end of whatever base path it has.
    static func socketURL(server: String, deviceId: String) -> URL? {
        guard var parts = URLComponents(string: server) else { return nil }
        switch parts.scheme?.lowercased() {
        case "https": parts.scheme = "wss"
        case "http": parts.scheme = "ws"
        default: return nil
        }
        parts.path = (parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path) + "/socket"
        parts.queryItems = [URLQueryItem(name: "deviceId", value: deviceId)]
        return parts.url
    }
}

/// The server's clock, as seen from here. Each sample is one round trip to
/// `/GetUtcTime`; the one with the shortest trip is the one believed, since
/// its two legs can differ least.
struct SyncPlayClock: Sendable {
    struct Sample: Equatable, Sendable {
        /// Server time minus this device's.
        var offset: TimeInterval
        /// One way, in seconds.
        var ping: TimeInterval
    }

    private(set) var samples: [Sample] = []

    /// NTP's sums: `sent` and `received` by this device's clock, the two in
    /// the middle by the server's.
    static func sample(sent: Date, serverReceived: Date, serverSent: Date, received: Date) -> Sample {
        let offset = (serverReceived.timeIntervalSince(sent) + serverSent.timeIntervalSince(received)) / 2
        let ping = (received.timeIntervalSince(sent) - serverSent.timeIntervalSince(serverReceived)) / 2
        return Sample(offset: offset, ping: max(0, ping))
    }

    mutating func add(_ sample: Sample) {
        samples.append(sample)
        if samples.count > 8 { samples.removeFirst() }
    }

    private var best: Sample? { samples.min { $0.ping < $1.ping } }

    var offset: TimeInterval { best?.offset ?? 0 }
    var ping: TimeInterval { best?.ping ?? 0 }
    var isSet: Bool { !samples.isEmpty }

    func local(_ server: Date) -> Date { server.addingTimeInterval(-offset) }
    func server(_ local: Date) -> Date { local.addingTimeInterval(offset) }
}
