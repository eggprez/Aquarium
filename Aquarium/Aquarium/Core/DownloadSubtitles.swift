//  Subtitles for a download, kept as files beside it.
//
//  An HLS download carries no subtitles at all — the server remuxes or
//  encodes one picture and one sound track — and a file download carries only
//  what is inside the file, never the `.srt` the server keeps next to it. So
//  every text subtitle the server knows of is fetched separately, as a file
//  converted by the server, and listed in a small index the player reads
//  offline. Picture subtitles (PGS, VobSub, DVB) have no text to fetch and
//  are left out; see `JellyfinClient.downloadTracks` for the one that can be
//  burned in instead.

#if !os(tvOS)
import Foundation
import OSLog

enum DownloadSubtitles {
    private static let log = Logger(subsystem: DownloadManager.bundleID, category: "downloads")

    /// The index beside the media.
    static let indexName = "subtitles.json"

    /// One subtitle file and what the server said about the stream it came from.
    struct Entry: Codable, Hashable, Sendable {
        /// The stream's index as the server numbers it — the file's own
        /// numbering for an embedded track.
        var index: Int
        var fileName: String
        var codec: String?
        var language: String?
        /// What a menu calls it: the server's `DisplayTitle` where it has one.
        var title: String
        var isDefault: Bool
        var isForced: Bool
        /// A file beside the video on the server, rather than a track inside
        /// it. An embedded one may also be in a file download's own tracks.
        var isExternal: Bool
    }

    struct Index: Codable, Sendable {
        var mediaSourceId: String?
        /// The subtitle the server would have sent with nothing asked for —
        /// what "only when the file turns them on" means offline.
        var defaultIndex: Int?
        var entries: [Entry]
        /// Every text stream the source listed was fetched. False leaves the
        /// next call to try the ones that failed.
        var complete: Bool
        /// Goes it has taken. A stream the server always refuses — closed
        /// captions, a codec it can't convert — left the index incomplete
        /// for good, and every play asked for the item and that stream again.
        var attempts: Int?
    }

    /// Goes before an incomplete index is left as it is.
    private static let maxAttempts = 3

    // MARK: Reading

    /// The index beside a download, or nil when it has none.
    static func index(in folder: URL) -> Index? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(indexName)) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    /// The subtitle files beside a download that are actually there.
    static func local(in folder: URL) -> [Entry] {
        let fm = FileManager.default
        return (index(in: folder)?.entries ?? []).filter {
            fm.fileExists(atPath: folder.appendingPathComponent($0.fileName).path)
        }
    }

    // MARK: Fetching

    /// Fetch every text subtitle of `item` into `folder`, the download's own.
    ///
    /// Safe to call again, and cheap once done: a file already there is not
    /// fetched twice, and a complete index ends it before the network. Never
    /// throws — a download without subtitles is still a download. Nothing is
    /// written once the folder has gone, which is what deleting the download
    /// mid-fetch does.
    @MainActor
    static func fetch(for item: BaseItem, source: MediaSource?, into folder: URL) async {
        guard !item.isAudio else { return }
        let earlier = index(in: folder)
        if let existing = earlier, existing.complete,
           existing.entries.count == local(in: folder).count { return }

        // A list item can arrive without its streams; the full item has them.
        var source = source ?? item.MediaSources?.first
        if source?.MediaStreams == nil {
            let sourceId = source?.Id
            let full = try? await JellyfinClient.shared.item(item.Id)
            source = full?.MediaSources?.first(where: { $0.Id == sourceId }) ?? full?.MediaSources?.first
        }
        guard let source else { return }
        let mediaSourceId = source.Id ?? item.Id
        let wanted = source.subtitleStreams.filter { !$0.isImageSubtitle && $0.Index != nil }

        let fm = FileManager.default
        var entries: [Entry] = []
        var complete = true
        for stream in wanted {
            guard let index = stream.Index else { continue }
            let format = Self.format(for: stream.Codec)
            let entry = Entry(
                index: index, fileName: Self.fileName(for: stream, index: index, format: format),
                codec: stream.Codec, language: stream.Language, title: stream.menuLabel,
                isDefault: stream.IsDefault ?? false, isForced: stream.isForced,
                isExternal: stream.IsExternal ?? false)
            let url = folder.appendingPathComponent(entry.fileName)
            if fm.fileExists(atPath: url.path) {
                entries.append(entry)
                continue
            }
            do {
                let path = JellyfinClient.subtitlePath(
                    itemId: item.Id, mediaSourceId: mediaSourceId, index: index, format: format)
                let data = try await JellyfinClient.shared.request(path, countsForOffline: false)
                guard !data.isEmpty, fm.fileExists(atPath: folder.path) else {
                    complete = false
                    continue
                }
                try data.write(to: url, options: .atomic)
                excludeFromBackup(url)
                entries.append(entry)
            } catch {
                // Closed captions read out of the video stream, and a server
                // that can't convert a codec, answer with an error; the rest
                // are still worth having.
                complete = false
                log.notice("subtitle \(index) of \(item.Id, privacy: .public) not fetched: \(String(describing: error), privacy: .public)")
            }
        }

        guard fm.fileExists(atPath: folder.path) else { return }
        let attempts = (earlier?.attempts ?? 0) + 1
        let saved = Index(
            mediaSourceId: source.Id, defaultIndex: source.DefaultSubtitleStreamIndex,
            entries: entries, complete: complete || attempts >= maxAttempts, attempts: attempts)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let url = folder.appendingPathComponent(indexName)
        try? data.write(to: url, options: .atomic)
        excludeFromBackup(url)
    }

    /// The same, for a download known only by its id — a retry, or one that
    /// finished without the item to hand.
    @MainActor
    static func fetch(itemId: String, into folder: URL) async {
        if let existing = index(in: folder), existing.complete,
           existing.entries.count == local(in: folder).count { return }
        guard let item = try? await JellyfinClient.shared.item(itemId) else { return }
        // The version that was downloaded, which its address names; the
        // first of several versions has its own, differently numbered,
        // subtitle streams.
        let downloaded = DownloadManager.shared.record(for: itemId)
            .flatMap { URLComponents(string: $0.sourceURL)?.queryItems }?
            .first { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }?.value
        let source = item.MediaSources?.first { $0.Id == downloaded } ?? item.MediaSources?.first
        await fetch(for: item, source: source, into: folder)
    }

    // MARK: Naming

    /// What to ask the server to convert to. ASS and SSA keep their styling
    /// as ASS, which mpv draws as written; everything else is plain SRT.
    private static func format(for codec: String?) -> String {
        switch codec?.lowercased() {
        case "ass", "ssa": "ass"
        default: "srt"
        }
    }

    /// Plain ASCII, so the name reads back the same out of an engine's track
    /// list as it went in: mpv reports the URL it was given, percent-escaped.
    private static func fileName(for stream: MediaStream, index: Int, format: String) -> String {
        let language = (stream.Language ?? "und").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        var name = "subtitle-\(index).\(language.isEmpty ? "und" : language)"
        if stream.isForced { name += ".forced" }
        return name + "." + format
    }

    /// Like the media: fetched again from the server whenever it is needed,
    /// so no place in a backup.
    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
    }
}
#endif
