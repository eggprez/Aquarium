//  Putting back what a downloaded stream is missing.
//
//  A transcoded download can come out with holes in it — see `StreamSeams`
//  for how: the server's encode is stopped while the download is waiting on
//  the segment being written, and the server hands that segment over as far
//  as it had got. The download carries on from the next segment and finishes
//  as if nothing had happened, a second or three short at that spot.
//  `AVAssetDownloadTask` gives no say in any of it; the segments are fetched
//  by the system, out of this process, and it takes whatever it is served.
//
//  What it leaves behind can be mended, though. A package keeps an index of
//  its segments (`StreamInfoBoot.xml`): for each, the file it was saved as,
//  how long that file is, and the address it came from. A segment asked for
//  again, on its own, comes back whole — the server starts an encode at it
//  and nothing stops that one half-way — and put in place of the short one,
//  with its length corrected in the index, the package plays straight
//  through. Tried by hand first on a download with a 2.9 s hole: the three
//  seconds came back, on time, and it played to its end.
//
//  The mended spot still has a seam either side — the new segment is from a
//  different encode than its neighbours — but those are overlaps of a few
//  hundredths of a second, which the player already puts right as it passes.
//
//  Run when a stream download finishes, and once for each download made
//  before this existed, the next time its server is in reach.

import Foundation
import os

// MARK: - The package's index

/// The part of a package's index that names its segments.
enum PackageIndex {
    static let fileName = "StreamInfoBoot.xml"

    struct Entry: Equatable {
        /// Where the segment was fetched from.
        var url: URL
        /// The length the index believes the file to be.
        var length: Int
    }

    /// The index's entry for the segment saved as `name`.
    static func entry(for name: String, in index: String) -> Entry? {
        guard let tag = tag(for: name, in: index),
              let address = attribute("URL", in: index[tag]), let url = URL(string: unescaped(address)),
              let length = attribute("Len", in: index[tag]).flatMap({ Int($0) })
        else { return nil }
        return Entry(url: url, length: length)
    }

    /// The index with the segment saved as `name` given a new length; nil if
    /// it has no such segment.
    static func index(_ index: String, settingLengthOf name: String, to length: Int) -> String? {
        guard let tag = tag(for: name, in: index),
              let old = index[tag].range(of: #"Len="[0-9]+""#, options: .regularExpression)
        else { return nil }
        var changed = index
        changed.replaceSubrange(old, with: "Len=\"\(length)\"")
        return changed
    }

    /// The `<SEG … >` element whose `PATH` is `name`.
    private static func tag(for name: String, in index: String) -> Range<String.Index>? {
        guard let path = index.range(of: "PATH=\"\(name)\""),
              let open = index.range(of: "<SEG ", options: .backwards, range: index.startIndex..<path.lowerBound),
              let close = index.range(of: ">", range: path.upperBound..<index.endIndex),
              // Nothing closes between the two: the PATH is this element's own.
              index.range(of: ">", range: open.upperBound..<path.lowerBound) == nil
        else { return nil }
        return open.lowerBound..<close.upperBound
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let start = tag.range(of: " \(name)=\""),
              let end = tag.range(of: "\"", range: start.upperBound..<tag.endIndex)
        else { return nil }
        return String(tag[start.upperBound..<end.lowerBound])
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Finding and mending

extension StreamSeams {
    /// A segment that stops short of the one after it.
    struct CutShort: Equatable {
        var file: URL
        /// Where its audio runs to now, and from.
        var start: Double
        var end: Double
        /// How much is missing after it, in seconds.
        var missing: Double
    }

    /// Less than this is a frame or two at an encoder's edge, which a fresh
    /// copy of the segment would not bring back.
    static let smallestRepair = 0.1

    /// The segments of a package that were handed over unfinished.
    static func cutShort(in package: URL) -> [CutShort] {
        guard let spans = audioSpans(fragmentFiles(in: package)) else { return [] }
        return cutShort(spans)
    }

    static func cutShort(_ spans: [(file: URL, span: (start: Double, end: Double)?)]) -> [CutShort] {
        var found: [CutShort] = []
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            guard let a = earlier.span, let b = later.span else { continue }
            let missing = b.start - a.end
            if (smallestRepair...largestHole).contains(missing) {
                found.append(CutShort(file: earlier.file, start: a.start, end: a.end, missing: missing))
            }
        }
        return found
    }

    /// Put a freshly fetched copy of a segment in place of the short one,
    /// and its length in the package's index. False, and nothing changed, if
    /// the copy is no better than what is there.
    static func replace(_ short: CutShort, with data: Data) -> Bool {
        let folder = short.file.deletingLastPathComponent()
        let indexFile = folder.appendingPathComponent(PackageIndex.fileName)
        let name = short.file.lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              let initSegment = files.first(where: { $0.pathExtension == "initfrag" }),
              let initData = try? Data(contentsOf: initSegment),
              let track = audioTrack(inInitSegment: initData),
              let index = try? String(contentsOf: indexFile, encoding: .utf8),
              let changed = PackageIndex.index(index, settingLengthOf: name, to: data.count)
        else { return false }

        // Read as a segment before it is trusted as one: it has to start
        // where the short one did and run on past where that one stopped.
        let fresh = folder.appendingPathComponent(".mending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fresh) }
        guard (try? data.write(to: fresh)) != nil,
              let span = audioSpan(ofSegment: fresh, track: track),
              abs(span.start - short.start) < 0.5,
              span.end >= short.end + short.missing / 2
        else { return false }

        // The file, then the index. Between the two the index gives the old,
        // shorter length for a longer file, which reads as the short segment
        // did; the other order would promise bytes that are not there.
        guard (try? FileManager.default.replaceItemAt(short.file, withItemAt: fresh)) != nil else { return false }
        try? changed.write(to: indexFile, atomically: true, encoding: .utf8)
        return true
    }
}

// MARK: - Doing it for a download

#if !os(tvOS)
@MainActor
enum DownloadRepair {
    private static let log = Logger(subsystem: "scottai.FellyJin", category: "downloads")

    /// What was found in a download and done about it, kept beside it so it
    /// is looked over once.
    struct Note: Codable {
        var version: Int
        var mended: Int
        /// Still short: the server could not be asked, or did no better.
        var left: Int
    }

    static let fileName = "repair.json"
    static let version = 1

    static func note(in folder: URL) -> Note? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(Note.self, from: data)
    }

    private static var busy = false

    /// Look over every finished stream download not yet looked over, one at
    /// a time. Cheap to call often: it does nothing while it is already
    /// running, while offline, or while something is playing.
    static func sweep() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            let manager = DownloadManager.shared
            for record in manager.records where record.status == .complete && record.hlsPath != nil {
                let folder = DownloadManager.folder(for: record.itemId)
                // One left unfinished is tried again; one looked over is not.
                if let note = note(in: folder), note.version == version, note.left == 0 { continue }
                guard await mend(record.itemId) != nil else { return }
            }
        }
    }

    /// Mend one download. Nil when it could not be looked at now — offline,
    /// another account's, something playing — and is worth another try.
    @discardableResult
    static func mend(_ itemId: String) async -> Note? {
        let manager = DownloadManager.shared
        let client = JellyfinClient.shared
        guard let record = manager.record(for: itemId), record.status == .complete,
              let path = record.hlsPath, manager.belongsToCurrentAccount(record),
              !client.isOffline, PlayerActions.active == nil
        else { return nil }
        let package = DownloadManager.hlsURL(forRelativePath: path)
        let folder = DownloadManager.folder(for: itemId)

        let short = await Task.detached(priority: .utility) { StreamSeams.cutShort(in: package) }.value
        guard !short.isEmpty else {
            keep(Note(version: version, mended: 0, left: 0), in: folder)
            return Note(version: version, mended: 0, left: 0)
        }
        log.notice("\(itemId, privacy: .public): \(short.count, privacy: .public) segments cut short, \(short.reduce(0) { $0 + $1.missing }, format: .fixed(precision: 1), privacy: .public) s missing; fetching them again")

        // An encode of its own, so stopping it afterwards stops nothing else.
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var mended = 0
        for segment in short {
            // Not under a player: it has the old file open and its length in mind.
            guard !client.isOffline, PlayerActions.active == nil,
                  manager.record(for: itemId)?.hlsPath == path
            else { break }
            guard let data = await fetch(segment, session: session) else { continue }
            if await Task.detached(priority: .utility, operation: { StreamSeams.replace(segment, with: data) }).value {
                mended += 1
            }
        }
        await client.stopTranscode(playSessionId: session)
        if mended > 0 { StreamSeams.forget(package: package) }

        let note = Note(version: version, mended: mended, left: short.count - mended)
        log.notice("\(itemId, privacy: .public): mended \(mended, privacy: .public) of \(short.count, privacy: .public)")
        keep(note, in: folder)
        return note
    }

    /// The segment again, from where the package says it came from — as this
    /// session, not with the token it was first fetched with, which the
    /// package wrote down and may have outlived.
    private static func fetch(_ segment: StreamSeams.CutShort, session: String) async -> Data? {
        let client = JellyfinClient.shared
        let indexFile = segment.file.deletingLastPathComponent().appendingPathComponent(PackageIndex.fileName)
        guard let index = try? String(contentsOf: indexFile, encoding: .utf8),
              let entry = PackageIndex.entry(for: segment.file.lastPathComponent, in: index),
              client.isSessionOrigin(entry.url),
              var parts = URLComponents(url: entry.url, resolvingAgainstBaseURL: false)
        else { return nil }
        let kept = (parts.percentEncodedQuery ?? "").split(separator: "&").filter {
            let name = $0.lowercased()
            return !name.hasPrefix("apikey=") && !name.hasPrefix("api_key=") && !name.hasPrefix("playsessionid=")
        }
        parts.percentEncodedQuery = (kept + ["PlaySessionId=\(session)"]).joined(separator: "&")
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: client.authorized(url))
        // The server has to start an encode and write a segment and the one
        // after before it answers.
        request.timeoutInterval = 90
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
        else { return nil }
        return data
    }

    private static func keep(_ note: Note, in folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path),
              let data = try? JSONEncoder().encode(note) else { return }
        var url = folder.appendingPathComponent(fileName)
        try? data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
#endif
