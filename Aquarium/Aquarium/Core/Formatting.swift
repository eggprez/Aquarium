//  The formatting helpers from api.ts, unchanged in behaviour so the two
//  clients describe the same file the same way.

import Foundation

enum Format {
    /// "2h 14m" / "48m" from Jellyfin ticks.
    static func ticks(_ ticks: Int64?) -> String {
        guard let ticks, ticks > 0 else { return "" }
        let totalMin = Int((Double(ticks) / 600_000_000).rounded())
        let h = totalMin / 60
        let m = totalMin % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// "1:04:12" / "4:12".
    static func clock(_ seconds: Double) -> String {
        var sec = seconds
        if !sec.isFinite || sec < 0 { sec = 0 }
        let s = Int(sec.truncatingRemainder(dividingBy: 60))
        let m = Int((sec / 60).truncatingRemainder(dividingBy: 60))
        let h = Int(sec / 3600)
        let mm = String(format: "%02d", m)
        let ss = String(format: "%02d", s)
        return h > 0 ? "\(h):\(mm):\(ss)" : "\(m):\(ss)"
    }

    static func bytes(_ n: Int64) -> String {
        let gib: Int64 = 1 << 30, mib: Int64 = 1 << 20, kib: Int64 = 1 << 10
        if n >= gib { return String(format: "%.2f GiB", Double(n) / Double(gib)) }
        if n >= mib { return String(format: "%.1f MiB", Double(n) / Double(mib)) }
        if n >= kib { return String(format: "%.0f KiB", Double(n) / Double(kib)) }
        return "\(n) B"
    }

    /// Height → the name people actually use for it. Width counts too: a
    /// widescreen film is cropped top and bottom, so a 1080p encode of one is
    /// 1920×800 and by height alone would read as 720p.
    static func resolutionLabel(_ stream: MediaStream?) -> String? {
        guard let h = stream?.Height else { return nil }
        let w = stream?.Width ?? 0
        if h >= 2000 || w >= 3800 { return "4K" }
        if h >= 1000 || w >= 1800 { return "1080p" }
        if h >= 700 || w >= 1200 { return "720p" }
        if h >= 550 { return "576p" }
        if h >= 400 { return "480p" }
        return "\(h)p"
    }

    static func channelLabel(_ stream: MediaStream?) -> String? {
        if let layout = stream?.ChannelLayout, !layout.isEmpty {
            return layout == "mono" ? "Mono" : layout
        }
        switch stream?.Channels {
        case 8: return "7.1"
        case 6: return "5.1"
        case 2: return "Stereo"
        case 1: return "Mono"
        default: return nil
        }
    }

    /// What the file on the server actually is: "1080p · HEVC · EAC3 · 5.1 · 8.4 GiB".
    static func mediaSummary(_ item: BaseItem) -> [String] {
        guard let ms = item.MediaSources?.first else { return [] }
        let streams = ms.streams
        let video = streams.first { $0.type == "Video" }
        let audio = streams.first { $0.type == "Audio" }
        let subs = streams.filter { $0.type == "Subtitle" }.count

        func upper(_ v: String?) -> String? {
            guard let v, !v.isEmpty else { return nil }
            return v.uppercased()
        }

        return [
            resolutionLabel(video),
            upper(video?.Codec),
            upper(audio?.Codec),
            channelLabel(audio),
            subs > 0 ? "\(subs) subtitle track\(subs == 1 ? "" : "s")" : nil,
            (ms.Size ?? 0) > 0 ? bytes(ms.Size!) : nil,
        ].compactMap { $0 }
    }

    /// The line under a card: year · runtime · rating, whichever exist.
    ///
    /// Not which episode this is: that is `episodeLabel`, spelled out, and it
    /// gets a line to itself wherever it is shown rather than a clause in this
    /// one.
    static func itemSubtitle(_ item: BaseItem) -> String {
        var parts: [String] = []
        if let year = item.ProductionYear {
            parts.append(String(year))
        }
        let runtime = ticks(item.RunTimeTicks)
        if !runtime.isEmpty { parts.append(runtime) }
        if let rating = item.OfficialRating, !rating.isEmpty { parts.append(rating) }
        return parts.joined(separator: " · ")
    }

    /// A display name for a track, preferring what the server already composed.
    static func trackLabel(_ stream: MediaStream) -> String {
        if let t = stream.DisplayTitle, !t.isEmpty { return t }
        var parts: [String] = []
        if let l = stream.Language, !l.isEmpty { parts.append(l.uppercased()) }
        if let c = stream.Codec, !c.isEmpty { parts.append(c.uppercased()) }
        if let ch = channelLabel(stream) { parts.append(ch) }
        if stream.IsForced == true { parts.append("Forced") }
        return parts.isEmpty ? "Track \(stream.Index ?? 0)" : parts.joined(separator: " · ")
    }

    /// Jellyfin's programme dates, which arrive as .NET's own flavour of
    /// ISO 8601 — fractional seconds `ISO8601DateFormatter` doesn't always
    /// parse — with a plain, fraction-less reading as the fallback.
    ///
    /// Both readings come from formatters made once and kept, and the answers
    /// are remembered. That is not premature: this is the hottest function in
    /// the app. `BaseItem.programStart` and `programEnd` are computed
    /// properties over it, and the Live TV guide reads them for every
    /// programme it groups, sorts, filters and draws — a guide of 2,250
    /// programmes asks this question thousands of times for one screen, and
    /// again on every layout pass while you scroll it. Built fresh each call
    /// (an `ISO8601DateFormatter` is an ICU formatter behind a Foundation
    /// wrapper, and costs accordingly) that was around 150 microseconds a
    /// time: measured on a desktop, one pass over a real guide spent 692 ms
    /// doing nothing but making formatters, on the main thread, which is the
    /// second the whole app stopped for when Live TV opened.
    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return ISODates.shared.date(for: s)
    }

    /// "20:00 – 20:45" for a live programme.
    static func programWindow(_ p: CurrentProgram) -> String? {
        programWindow(start: parseDate(p.StartDate), end: parseDate(p.EndDate))
    }

    /// Same, from already-parsed dates — what the guide's own programme cells
    /// use, since they read `BaseItem.programStart`/`programEnd` rather than
    /// a `CurrentProgram`.
    static func programWindow(start: Date?, end: Date?) -> String? {
        guard let start else { return nil }
        let df = shortTime
        guard let end else { return df.string(from: start) }
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }

    /// One formatter for every programme label. It was built per call, and the
    /// guide calls this once per programme cell on every redraw — a few
    /// hundred ICU formatters for one pass over the grid. Formatting from one
    /// shared instance is thread-safe.
    private static let shortTime: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    /// How far through the current programme we are, for the channel row's bar.
    static func programProgress(_ p: CurrentProgram) -> Double? {
        guard let start = parseDate(p.StartDate), let end = parseDate(p.EndDate) else { return nil }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return nil }
        let done = Date().timeIntervalSince(start) / total
        return min(max(done, 0), 1)
    }
}


/// The formatters behind `Format.parseDate`, and what they have already been
/// asked.
///
/// `@unchecked Sendable` because the safety is the lock's rather than the
/// compiler's: the two formatters and the dictionary are only ever touched
/// with it held. Callers come from both the main actor (a guide row laying
/// itself out) and background tasks (the grouping pass), so this cannot be
/// isolated to either.
private final class ISODates: @unchecked Sendable {
    static let shared = ISODates()

    private let lock = NSLock()
    private var known: [String: Date] = [:]

    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()

    /// A guide window is a few thousand distinct timestamps; this is room for
    /// several of them, emptied rather than aged because the cost of being
    /// wrong is one re-parse.
    private static let limit = 20_000

    func date(for string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = known[string] { return hit }
        guard let parsed = fractional.date(from: string) ?? plain.date(from: string) else {
            return nil
        }
        if known.count >= Self.limit { known.removeAll(keepingCapacity: true) }
        known[string] = parsed
        return parsed
    }
}
