//  Where a downloaded stream's sound stops lining up with itself.
//
//  A transcoded download is an HLS stream the server encodes as it is
//  fetched, and the encode does not always run in one go: a download that is
//  resumed, retried, or left unpinged long enough for Jellyfin to reap it is
//  carried on by a *new* ffmpeg, started at the first segment still missing.
//  The new encoder's audio does not begin where the old one's ended. It
//  begins a little before the segment boundary — its AAC priming, on its own
//  frame grid — so the two segments either side of the restart overlap by
//  50–90 ms of sound.
//
//  AVPlayer does not trim that overlap. It plays the audio of one segment
//  straight after the last, so from the restart onwards every sound comes
//  out late by the length of the overlap, and each further restart adds its
//  own. Measured with a click track encoded with a restart every three
//  seconds: 70 ms later at each one, 1.3 s late after a minute, and exact
//  again the moment the player is asked to seek — which reads the
//  timestamps afresh. MPEG-TS segments behave the same, so there is no
//  server setting that avoids it, and an HLS item has no audio offset to
//  correct it with (see `AVEngine.audioDelay`).
//
//  A restart can also leave the opposite. A download waiting on the segment
//  being written when the encode is killed is handed that segment as far as
//  it had got — four frames of a three-second segment, in one measured case
//  — and the copy on this device then has a hole: picture and sound both
//  missing up to the next segment. AVPlayer closes the hole in the sound the
//  same way it ignores an overlap, so everything after is heard *early* by
//  the length of the hole, seconds rather than milliseconds, until a seek.
//  Killing the encode once every few seconds through the server's own API
//  left a download with as many holes as overlaps. The usual cause in the
//  field is a download carrying on in the background, where nothing pings
//  the server and it reaps the encode a minute later.
//
//  So the seams are found here, from the timestamps in the package itself,
//  and `AVEngine` re-anchors as playback crosses them. Reading the package
//  rather than remembering the restarts as they happen is what reaches a
//  download made before this existed, and a restart the server made on its
//  own that the app never saw.

import Foundation
import os

/// One place where a segment's audio does not start where the previous
/// one's ended.
struct StreamSeam: Codable, Equatable, Sendable {
    /// Where the earlier segment's audio ends, in the stream's own time.
    var time: Double
    /// How much sound is there twice, in seconds: how much later everything
    /// after this point is heard once playback has run across it. Negative
    /// for a hole — sound that is missing — after which it is heard early.
    var overlap: Double

    /// Where the later segment's audio starts.
    var resume: Double { time - overlap }
    /// The later of the two edges: past this, playback is inside the later
    /// segment whichever kind of seam it is.
    var farEdge: Double { max(time, resume) }
    /// A hole long enough to step over rather than play across.
    var isGap: Bool { overlap <= -SeamSlip.gap }
}

enum StreamSeams {
    private static let log = Logger(subsystem: "scottai.FellyJin", category: "player")

    /// Smaller than this is rounding between two timescales, not a restart.
    static let smallestSeam = 0.005
    /// An overlap is an encoder's priming and can only be so long. The one
    /// thing seen past this is the stream's last sliver of a segment, which
    /// a restarted encode writes seconds out of place, at the very end.
    static let largestOverlap = 0.5
    /// A hole is at most the segment that was cut short. Longer than any
    /// segment the server writes, and it is a segment missing from the
    /// package altogether, which is not this problem.
    static let largestHole = 10.0
    /// Bumped when what `scan` finds changes, so a list kept by an older
    /// build is read again: the first one knew nothing of holes.
    static let version = 2

    /// The seams in a downloaded `.movpkg`, in order. Empty for anything
    /// else, and for a package that can't be read.
    ///
    /// Slow the first time — every segment is opened — and kept afterwards
    /// in Caches, against the number of segments it was read from.
    static func seams(inPackage package: URL) async -> [StreamSeam] {
        guard package.isFileURL, package.pathExtension.lowercased() == "movpkg" else { return [] }
        return await Task.detached(priority: .utility) { () -> [StreamSeam] in
            let fragments = fragmentFiles(in: package)
            guard fragments.count > 1 else { return [] }
            let cache = cacheFile(for: package)
            if let data = try? Data(contentsOf: cache),
               let kept = try? JSONDecoder().decode(Kept.self, from: data), kept.fragments == fragments.count,
               kept.version == version {
                return kept.seams
            }
            let started = Date()
            guard let found = scan(fragments) else { return [] }
            log.notice("seams: \(found.count, privacy: .public) (\(found.filter { $0.overlap < 0 }.count, privacy: .public) holes) in \(fragments.count, privacy: .public) segments, read in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s")
            if let data = try? JSONEncoder().encode(Kept(version: version, fragments: fragments.count, seams: found)) {
                try? FileManager.default.createDirectory(
                    at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            }
            return found
        }.value
    }

    private struct Kept: Codable {
        var version: Int?
        var fragments: Int
        var seams: [StreamSeam]
    }

    private static func cacheFile(for package: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("StreamSeams", isDirectory: true)
            .appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".json")
    }

    // MARK: - The package

    /// A stream's segments and the init segment that describes them.
    struct Fragments {
        var initSegment: URL
        /// In playing order.
        var segments: [URL]
        var count: Int { segments.count }
    }

    /// The muxed stream's files. AVFoundation keeps each stream of a package
    /// in a folder of its own: `(start)_(n)_(duration).frag` for a segment
    /// and one `.initfrag`. The folder with the most segments is the one
    /// that plays; a download here has only the one.
    static func fragmentFiles(in package: URL) -> Fragments {
        let fm = FileManager.default
        var best = Fragments(initSegment: package, segments: [])
        for folder in (try? fm.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)) ?? [] {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                  let initSegment = files.first(where: { $0.pathExtension == "initfrag" })
            else { continue }
            let timed: [(Double, URL)] = files.compactMap { file in
                guard file.pathExtension == "frag", let start = startTime(ofFragmentNamed: file.lastPathComponent)
                else { return nil }
                return (start, file)
            }
            if timed.count > best.count {
                best = Fragments(initSegment: initSegment, segments: timed.sorted { $0.0 < $1.0 }.map(\.1))
            }
        }
        return best
    }

    /// `(126.793)_(0)_(7.92501).frag` → 126.793.
    static func startTime(ofFragmentNamed name: String) -> Double? {
        guard name.hasPrefix("("), let close = name.firstIndex(of: ")") else { return nil }
        return Double(name[name.index(after: name.startIndex)..<close])
    }

    // MARK: - Reading the timestamps

    /// The seams between consecutive segments, or nil if the stream isn't
    /// fragmented MP4 with an audio track this can read.
    static func scan(_ fragments: Fragments) -> [StreamSeam]? {
        audioSpans(fragments).map { seams(between: $0.map(\.span)) }
    }

    /// Where each segment's audio starts and ends, in playing order; nil for
    /// a segment that is unreadable or has no sound in it.
    static func audioSpans(_ fragments: Fragments) -> [(file: URL, span: (start: Double, end: Double)?)]? {
        guard let initData = try? Data(contentsOf: fragments.initSegment),
              let audio = audioTrack(inInitSegment: initData)
        else { return nil }
        return fragments.segments.map { ($0, audioSpan(ofSegment: $0, track: audio)) }
    }

    static func seams(between spans: [(start: Double, end: Double)?]) -> [StreamSeam] {
        var seams: [StreamSeam] = []
        var previousEnd: Double?
        for span in spans {
            guard let span else {
                // Whatever comes next is not measured against what came before.
                previousEnd = nil
                continue
            }
            if let previousEnd {
                let overlap = previousEnd - span.start
                if (smallestSeam...largestOverlap).contains(overlap)
                    || (smallestSeam...largestHole).contains(-overlap) {
                    seams.append(StreamSeam(time: previousEnd, overlap: overlap))
                }
            }
            previousEnd = span.end
        }
        return seams
    }

    /// Forget what was read from a package: its segments have changed.
    static func forget(package: URL) {
        try? FileManager.default.removeItem(at: cacheFile(for: package))
    }

    struct AudioTrack: Equatable {
        var id: UInt32
        var timescale: Double
        /// `trex`'s sample duration, for a fragment that states none.
        var defaultDuration: UInt32
    }

    /// The first sound track an init segment declares.
    static func audioTrack(inInitSegment data: Data) -> AudioTrack? {
        let bytes = [UInt8](data)
        guard let moov = boxes(in: bytes, 0..<bytes.count).first(where: { $0.type == "moov" }) else { return nil }
        let inMoov = boxes(in: bytes, moov.body)
        var defaults: [UInt32: UInt32] = [:]
        if let mvex = inMoov.first(where: { $0.type == "mvex" }) {
            for trex in boxes(in: bytes, mvex.body) where trex.type == "trex" && trex.body.count >= 16 {
                // version/flags, track id, description index, sample duration.
                defaults[u32(bytes, trex.body.lowerBound + 4)] = u32(bytes, trex.body.lowerBound + 12)
            }
        }
        for trak in inMoov where trak.type == "trak" {
            let inTrak = boxes(in: bytes, trak.body)
            guard let tkhd = inTrak.first(where: { $0.type == "tkhd" }),
                  let mdia = inTrak.first(where: { $0.type == "mdia" })
            else { continue }
            let inMdia = boxes(in: bytes, mdia.body)
            guard let hdlr = inMdia.first(where: { $0.type == "hdlr" }), hdlr.body.count >= 12,
                  fourCC(bytes, hdlr.body.lowerBound + 8) == "soun",
                  let mdhd = inMdia.first(where: { $0.type == "mdhd" }), !tkhd.body.isEmpty, !mdhd.body.isEmpty
            else { continue }
            // Version 1 of either box carries 64-bit dates ahead of the field.
            let idAt = tkhd.body.lowerBound + (bytes[tkhd.body.lowerBound] == 1 ? 20 : 12)
            let scaleAt = mdhd.body.lowerBound + (bytes[mdhd.body.lowerBound] == 1 ? 20 : 12)
            guard idAt + 4 <= tkhd.body.upperBound, scaleAt + 4 <= mdhd.body.upperBound else { continue }
            let id = u32(bytes, idAt)
            let timescale = u32(bytes, scaleAt)
            guard timescale > 0 else { continue }
            return AudioTrack(id: id, timescale: Double(timescale), defaultDuration: defaults[id] ?? 0)
        }
        return nil
    }

    /// Where a segment's audio starts and ends, in seconds.
    ///
    /// Only the `moof` boxes are read: the file is walked header by header
    /// and the media itself is skipped over, so a segment costs a few small
    /// reads however large it is.
    static func audioSpan(ofSegment file: URL, track: AudioTrack) -> (start: Double, end: Double)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        var start: Int64?
        var end = Int64.min
        while offset + 8 <= size {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8
            else { break }
            let head = [UInt8](header)
            var length = UInt64(u32(head, 0))
            var headerLength: UInt64 = 8
            if length == 1, head.count >= 16 {
                length = u64(head, 8)
                headerLength = 16
            } else if length == 0 {
                length = size - offset
            }
            guard length >= headerLength, offset + length <= size else { break }
            if fourCC(head, 4) == "moof", length <= 8 << 20,
               (try? handle.seek(toOffset: offset + headerLength)) != nil,
               let body = try? handle.read(upToCount: Int(length - headerLength)) {
                let bytes = [UInt8](body)
                for traf in boxes(in: bytes, 0..<bytes.count) where traf.type == "traf" {
                    guard let run = audioRun(in: bytes, traf: traf.body, track: track) else { continue }
                    if start == nil { start = run.start }
                    end = max(end, run.start &+ run.duration)
                }
            }
            offset += length
        }
        guard let start else { return nil }
        return (Double(start) / track.timescale, Double(end) / track.timescale)
    }

    /// One track fragment's decode time and length, in the track's timescale,
    /// if it belongs to `track`.
    private static func audioRun(in bytes: [UInt8], traf: Range<Int>, track: AudioTrack)
        -> (start: Int64, duration: Int64)?
    {
        let inTraf = boxes(in: bytes, traf)
        guard let tfhd = inTraf.first(where: { $0.type == "tfhd" }), tfhd.body.count >= 8,
              u32(bytes, tfhd.body.lowerBound + 4) == track.id,
              let tfdt = inTraf.first(where: { $0.type == "tfdt" }), tfdt.body.count >= 8
        else { return nil }

        // The optional fields of `tfhd` come in flag order; the sample
        // duration is the third of them.
        let flags = u32(bytes, tfhd.body.lowerBound) & 0xFF_FFFF
        var at = tfhd.body.lowerBound + 8
        if flags & 0x1 != 0 { at += 8 }
        if flags & 0x2 != 0 { at += 4 }
        var perSample = track.defaultDuration
        if flags & 0x8 != 0, at + 4 <= tfhd.body.upperBound { perSample = u32(bytes, at) }

        // Read as signed: with `-copyts` the server's first segment starts
        // its audio a priming's length *before* zero, which ffmpeg writes as
        // the 64-bit value it is.
        let start: Int64
        if bytes[tfdt.body.lowerBound] == 1 {
            guard tfdt.body.count >= 12 else { return nil }
            start = Int64(bitPattern: u64(bytes, tfdt.body.lowerBound + 4))
        } else {
            start = Int64(u32(bytes, tfdt.body.lowerBound + 4))
        }

        var duration: Int64 = 0
        for trun in inTraf where trun.type == "trun" && trun.body.count >= 8 {
            let runFlags = u32(bytes, trun.body.lowerBound) & 0xFF_FFFF
            let count = Int(u32(bytes, trun.body.lowerBound + 4))
            guard runFlags & 0x100 != 0 else {
                duration &+= Int64(count) &* Int64(perSample)
                continue
            }
            // Each sample is a row of whichever of duration, size, flags and
            // composition offset the run carries, duration first.
            var field = trun.body.lowerBound + 8
            if runFlags & 0x1 != 0 { field += 4 }
            if runFlags & 0x4 != 0 { field += 4 }
            let row = 4 + (runFlags & 0x200 != 0 ? 4 : 0) + (runFlags & 0x400 != 0 ? 4 : 0)
                + (runFlags & 0x800 != 0 ? 4 : 0)
            guard count >= 0, field + count * row <= trun.body.upperBound else { return nil }
            for i in 0..<count { duration &+= Int64(u32(bytes, field + i * row)) }
        }
        return (start, duration)
    }

    // MARK: - Boxes

    private struct Box {
        var type: String
        var body: Range<Int>
    }

    /// The boxes laid end to end in `range`. Stops at the first that doesn't
    /// fit rather than guessing.
    private static func boxes(in bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var found: [Box] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            var length = Int(u32(bytes, at))
            var header = 8
            if length == 1 {
                guard at + 16 <= range.upperBound else { break }
                length = Int(clamping: u64(bytes, at + 8))
                header = 16
            } else if length == 0 {
                length = range.upperBound - at
            }
            guard length >= header, at + length <= range.upperBound else { break }
            found.append(Box(type: fourCC(bytes, at + 4), body: (at + header)..<(at + length)))
            at += length
        }
        return found
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= b.count else { return 0 }
        return UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    private static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        UInt64(u32(b, at)) << 32 | UInt64(u32(b, at + 4))
    }

    private static func fourCC(_ b: [UInt8], _ at: Int) -> String {
        guard at >= 0, at + 4 <= b.count else { return "" }
        return String(decoding: b[at..<(at + 4)], as: UTF8.self)
    }
}

/// How far the sound has moved off the picture since playback last started
/// reading from a timestamp, and when that is enough to do something about.
///
/// Fed the playhead as it moves. A step forward of about a tick is playback
/// running on, and takes on every seam it passed; anything else — backwards,
/// or a jump — is a seek, after which the player is exact again whatever it
/// had run across before.
struct SeamSlip {
    var seams: [StreamSeam] = []
    /// Seconds the sound is behind the picture; negative when it is ahead.
    private(set) var slip = 0.0
    private var last: Double?

    /// Sound this late is past what reads as in sync; one overlap is not.
    static let tolerableLate = 0.1
    /// Sound ahead of the picture is noticed sooner than sound behind it.
    static let tolerableEarly = 0.06
    /// A hole this long is stepped over as playback reaches it, rather than
    /// played across with the sound that far ahead and put right afterwards.
    static let gap = 0.5
    /// Further than this between two looks at the playhead is not playing.
    static let longestStep = 1.5
    /// How far past a seam the playhead has to be before the seam counts.
    /// The re-anchoring seek goes to wherever the playhead is, and one made
    /// the instant a seam is passed lands a few milliseconds short of the
    /// segment boundary — the audio's edge and the picture's are not the
    /// same instant — so the player crosses the seam a second time and is
    /// off again by exactly as much. Measured: re-anchored on the seam, the
    /// slip was back within a second; a quarter of a second in, it stays gone.
    static let settle = 0.25

    /// The player was asked to seek, or has just been re-anchored.
    mutating func reset() {
        slip = 0
        last = nil
    }

    /// Note where the playhead is. True when the sound is far enough off
    /// that the player should be re-anchored — after which, call `reset`.
    mutating func advance(to time: Double) -> Bool {
        defer { last = time }
        guard let last, time >= last, time - last <= Self.longestStep else {
            slip = 0
            return false
        }
        for seam in seams where seam.farEdge + Self.settle > last && seam.farEdge + Self.settle <= time {
            slip += seam.overlap
        }
        return slip >= Self.tolerableLate || slip <= -Self.tolerableEarly
    }

    /// Where the holes worth stepping over begin.
    var gapStarts: [Double] { seams.filter(\.isGap).map(\.time) }

    /// Where to land to step over the hole the playhead has just reached, if
    /// it has reached one: far enough into the segment after it that the
    /// hole is not counted against the landing as well.
    func landing(past time: Double) -> Double? {
        seams.first { $0.isGap && time >= $0.time - 0.05 && time < $0.resume }
            .map { $0.resume + Self.settle + 0.02 }
    }
}
