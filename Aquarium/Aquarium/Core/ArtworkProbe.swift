//  Why a channel's logo isn't showing, answered rather than guessed at.
//
//  A blank tile has half a dozen possible causes and they are indistinguishable
//  by looking: the playlist may name no logo at all, or name one this device
//  can't reach, or one the host refuses, or one it serves happily in a format
//  no Apple decoder reads. Only the machine running the app can tell them
//  apart, so it does — see Settings.

import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ArtworkProbe {
    struct Result: Identifiable, Sendable {
        var id: String { channel }
        var channel: String
        var address: String?
        var outcome: String
        var ok: Bool
    }

    /// Fetches a sample of channel logos and says what happened to each.
    ///
    /// A sample rather than the lot: with a few hundred channels the answer is
    /// the same for all of them, and the point is a report short enough to read.
    static func run(channels: [BaseItem], sample: Int = 8) async -> [Result] {
        let picked = Array(channels.prefix(sample))
        // All at once, and reordered afterwards. One of the answers this is
        // meant to produce is "that host never replies", and asked one after
        // another a single unreachable address holds up every channel behind
        // it for the whole timeout — the report would arrive long after anyone
        // stopped waiting for it.
        return await withTaskGroup(of: (Int, Result).self) { group in
            for (index, channel) in picked.enumerated() {
                group.addTask { (index, await probe(channel)) }
            }
            var collected: [(Int, Result)] = []
            for await pair in group { collected.append(pair) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Short, and deliberately shorter than the loader's own: this is a report
    /// on whether an address answers, and "not within a few seconds" is the
    /// answer it is looking for.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    private static func probe(_ channel: BaseItem) async -> Result {
        let name = channel.title
        guard let raw = channel.ExternalLogoURL, !raw.isEmpty else {
            return Result(
                channel: name,
                address: nil,
                outcome: "no logo — the playlist has no tvg-logo for this channel and the guide no <icon>",
                ok: false
            )
        }
        guard let url = URL.lenient(raw) else {
            return Result(channel: name, address: raw, outcome: "not a usable address", ok: false)
        }

        do {
            let (data, response) = try await session.data(for: ImageLoader.imageRequest(url))
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let type = http?.value(forHTTPHeaderField: "Content-Type")?
                .components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces) ?? "unknown type"
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)

            guard (200..<300).contains(status) else {
                return Result(
                    channel: name,
                    address: url.absoluteString,
                    outcome: "HTTP \(status) — the host refused or doesn't have it",
                    ok: false
                )
            }
            guard PlatformImage(data: data) != nil else {
                let note = type.contains("svg")
                    ? "SVG, which no Apple image decoder reads"
                    : "\(type), which this device couldn't decode"
                return Result(
                    channel: name,
                    address: url.absoluteString,
                    outcome: "HTTP 200, \(size), but it is \(note)",
                    ok: false
                )
            }
            return Result(
                channel: name,
                address: url.absoluteString,
                outcome: "HTTP 200, \(type), \(size) — decoded fine",
                ok: true
            )
        } catch {
            return Result(
                channel: name,
                address: url.absoluteString,
                outcome: "couldn't be reached from this device: \(error.localizedDescription)",
                ok: false
            )
        }
    }
}
