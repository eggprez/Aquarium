//  What soundtracks a downloaded title has on the server, kept as a small
//  list beside the download.
//
//  A download saved as a stream carries one soundtrack, and offline nothing
//  says there were ever others. This is that list — names and languages
//  only, no sound — so the player's Audio menu can still show them and say
//  what choosing one takes: leaving the download for a stream from the
//  server. A download that is the file itself has every track in it, and
//  its list says so by being empty.

#if !os(tvOS)
import Foundation

enum DownloadAudioList {
    static let indexName = "audio-tracks.json"

    struct Track: Codable, Hashable, Sendable {
        /// The track's index as the server numbers it.
        var index: Int
        var language: String?
        /// What a menu calls it: the server's `DisplayTitle` where it has one.
        var title: String
    }

    struct Index: Codable, Sendable {
        var mediaSourceId: String?
        /// The track inside the download, which a stream's package can't name.
        var main: Track?
        /// The ones left on the server.
        var others: [Track]
    }

    static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(indexName).path)
    }

    static func index(in folder: URL) -> Index? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(indexName)) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    /// Write the list for a download of `source`. `sourceURL` is the address
    /// the download was fetched from, which names the track it carries;
    /// `isStream` is whether it was saved as a stream at all.
    static func save(source: MediaSource, sourceURL: String, isStream: Bool, into folder: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        var saved = Index(mediaSourceId: source.Id, main: nil, others: [])
        if isStream {
            let tracks = source.audioStreams.compactMap { stream in
                stream.Index.map { Track(index: $0, language: stream.Language, title: stream.menuLabel) }
            }
            let asked = URLComponents(string: sourceURL)?.queryItems?
                .first { $0.name.caseInsensitiveCompare("AudioStreamIndex") == .orderedSame }?.value.flatMap(Int.init)
            let mainIndex = asked ?? source.DefaultAudioStreamIndex ?? tracks.first?.index
            saved.main = tracks.first { $0.index == mainIndex }
            saved.others = tracks.filter { $0.index != mainIndex }
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        var url = folder.appendingPathComponent(indexName)
        try? data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
#endif
