//  The speed check: before a stream opens away from home, time a short
//  download from the server and open at the quality that fits, rather than
//  at the original and stalling down to it one rung at a time.
//
//  Off unless turned on in Settings, and only while the player's Quality is
//  Auto. A server reached on the home network is never checked — the link is
//  almost never the limit there — and the next episode reuses what the one
//  before it learnt rather than checking again. See `PlayerModel.speedCheckedOpening`.

import Foundation
import Network

enum SpeedCheck {
    /// The share of a measured speed a stream is allowed: a connection that
    /// tests at 10 Mbps dips under that, and the audio rides on top.
    static let headroom = 0.7

    /// How long a measured speed is believed for the next episode.
    static let memoryLifetime: TimeInterval = 4 * 3600

    /// Whether a server at `host` is on the home network: a private,
    /// loopback or link-local address, or a `.local` name. The carrier-grade
    /// range (100.64/10) is left out on purpose — it is where Tailscale puts
    /// a server that is far from home.
    static func isHomeAddress(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if let v6 = IPv6Address(host) {
            let b = [UInt8](v6.rawValue)
            if v6 == .loopback { return true }
            if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return true }     // fe80::/10
            if b[0] & 0xFE == 0xFC { return true }                    // fc00::/7
        }
        return false
    }

    /// Whether the signed-in server is reached on the home network right now.
    /// Never on cellular. A name is looked up, and counts as home only when
    /// every address it gives is one.
    static func serverIsHome(_ server: String?, interface: NWInterface.InterfaceType?) async -> Bool {
        #if DEBUG
        // The QA servers are all on this Mac; this stands them somewhere else.
        if UserDefaults.standard.bool(forKey: "AquariumSpeedCheckAway") { return false }
        #endif
        if interface == .cellular { return false }
        guard let server, let host = URL(string: server)?.host, !host.isEmpty else { return false }
        if isHomeAddress(host) { return true }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return false }
        let addresses = await Task.detached { resolve(host) }.value
        return !addresses.isEmpty && addresses.allSatisfy(isHomeAddress)
    }

    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var found: [String] = []
        for node in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                found.append(String(cString: buffer))
            }
        }
        return found
    }
}

/// What a stream learnt about the connection, kept for the episode after it.
struct SpeedMemory: Sendable {
    var itemId: String
    var seriesId: String?
    var season: Int?
    var episode: Int?
    var bitsPerSecond: Double
    var interface: NWInterface.InterfaceType?
    var at: Date

    init(item: BaseItem, bitsPerSecond: Double, interface: NWInterface.InterfaceType?, at: Date = Date()) {
        itemId = item.Id
        seriesId = item.SeriesId
        season = item.ParentIndexNumber
        episode = item.IndexNumber
        self.bitsPerSecond = bitsPerSecond
        self.interface = interface
        self.at = at
    }

    /// The same memory, now about `item` — autoplay carrying it forward.
    func carried(to item: BaseItem) -> SpeedMemory {
        var next = SpeedMemory(item: item, bitsPerSecond: bitsPerSecond, interface: interface, at: at)
        next.at = at
        return next
    }

    /// Whether `item` is the episode straight after this one: the next in
    /// the season, or the first of the next season. On the same kind of
    /// connection, and not so long ago that the network may have moved on.
    func isFollowed(by item: BaseItem, interface now: NWInterface.InterfaceType?, at date: Date = Date()) -> Bool {
        guard date.timeIntervalSince(at) < SpeedCheck.memoryLifetime, interface == now,
              let seriesId, item.SeriesId == seriesId,
              let season, let episode, let nextSeason = item.ParentIndexNumber, let nextEpisode = item.IndexNumber
        else { return false }
        return (nextSeason == season && nextEpisode == episode + 1)
            || (nextSeason == season + 1 && nextEpisode == 1)
    }
}

extension Quality {
    /// The best stream a connection of `bitsPerSecond` carries with room to
    /// spare: the original when the file itself fits, else the highest rung
    /// that does, else the smallest there is. Nil is the original.
    static func fitting(_ bitsPerSecond: Double, source: MediaSource?) -> Int? {
        let budget = bitsPerSecond * SpeedCheck.headroom
        let rungs = choices.compactMap(\.maxBitrate)
        if let bitrate = source?.Bitrate, bitrate > 0 {
            if Double(bitrate) <= budget { return nil }
        } else if let top = rungs.first, Double(top) <= budget {
            // Nothing says how big the file is, and the connection would
            // carry the biggest stream anyway: leave it untouched.
            return nil
        }
        return rungs.first { Double($0) <= budget } ?? rungs.last
    }
}
