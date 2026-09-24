//  Finding a Jellyfin server on the local network.
//
//  Jellyfin listens on UDP 7359 and answers "who is JellyfinServer?" with a
//  line of JSON naming itself and the address it would like to be reached at.
//  That is the whole protocol — no mDNS, no SSDP — so this is one datagram out
//  and a short wait for whatever comes back, on a plain BSD socket because
//  Network.framework has no broadcast.
//
//  The question goes to 255.255.255.255 and, separately, to every interface's
//  own broadcast address: the limited broadcast leaves by the default route
//  only, which on a Mac with two networks up, or a phone on Wi-Fi with a VPN,
//  is not necessarily the one the server is on.
//
//  Two things about the platform. iOS 14 and later ask the user before an app
//  may talk to the local network at all (`NSLocalNetworkUsageDescription`
//  covers this), and Apple gates IP broadcast on iPhone and Apple TV behind
//  the `com.apple.developer.networking.multicast` entitlement, which is
//  granted on request. Without it the send fails or the reply never comes,
//  which here means the list under the address field stays empty — the typed
//  address always works, and nothing waits on this.

import Foundation

/// One server that answered.
struct DiscoveredServer: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// As the server gave it, scheme and port included.
    var address: String
}

enum ServerDiscovery {
    private static let question = Array("who is JellyfinServer?".utf8)
    private static let port: UInt16 = 7359

    private struct Reply: Decodable {
        var Address: String?
        var Id: String?
        var Name: String?
    }

    /// Ask, and gather answers for about `timeout` seconds.
    static func find(timeout: TimeInterval = 1.6) async -> [DiscoveredServer] {
        await Task.detached(priority: .userInitiated) { blockingFind(timeout: timeout) }.value
    }

    private static func blockingFind(timeout: TimeInterval) -> [DiscoveredServer] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        // recv wakes up every 250 ms so the deadline is honoured even when the
        // network is silent.
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let targets = broadcastTargets()
        guard !targets.isEmpty else { return [] }
        var sentAny = false
        for target in targets where send(to: target, on: fd) { sentAny = true }
        guard sentAny else { return [] }

        var found: [String: DiscoveredServer] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        var resent = false
        while Date() < deadline {
            // A second copy half-way through, in case the first datagram was
            // dropped — UDP promises nothing, and Wi-Fi drops broadcasts
            // more readily than anything else.
            if !resent, Date().addingTimeInterval(timeout / 2) > deadline {
                resent = true
                for target in targets { _ = send(to: target, on: fd) }
            }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(buffer[0..<n])),
                  let address = reply.Address?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !address.isEmpty,
                  // Anything on the network can answer. What it says has to be
                  // a web address, and there is a limit to how many answers a
                  // home network plausibly has — the list is drawn, and a
                  // flood of replies would otherwise be too.
                  let url = URL(string: address), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host?.isEmpty == false
            else { continue }
            let id = reply.Id ?? address
            guard found[id] != nil || found.count < 16 else { continue }
            let name = String((reply.Name ?? address).prefix(80))
            found[id] = DiscoveredServer(id: id, name: name, address: address)
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func send(to target: in_addr_t, on fd: Int32) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = target
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                question.withUnsafeBytes { buf in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == question.count
    }

    /// 255.255.255.255 plus the broadcast address of every IPv4 interface
    /// that is up and has one.
    private static func broadcastTargets() -> [in_addr_t] {
        var targets: [in_addr_t] = [in_addr_t(0xffff_ffff)]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return targets }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let broadcast = ifa.pointee.ifa_dstaddr, broadcast.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let target = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if target != 0, !targets.contains(target) { targets.append(target) }
        }
        return targets
    }
}
