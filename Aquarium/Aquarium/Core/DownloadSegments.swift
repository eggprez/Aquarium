//  Intro and credits markers for a download, kept beside it.
//
//  The skip buttons come from the server's media segments, which a streamed
//  item fetches as it opens. A download has no server to ask on a plane, so
//  its segments are fetched when the transfer finishes and kept as a small
//  file in its folder; playing it online asks again, in case a plugin has
//  analysed the episode since. A file download and an HLS one both start at
//  zero, so the server's times fit either as they are.

#if !os(tvOS)
import Foundation

enum DownloadSegments {
    static let fileName = "segments.json"

    /// The segments kept beside a download; empty when it has none.
    static func local(in folder: URL) -> [MediaSegment] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([MediaSegment].self, from: data)) ?? []
    }

    /// Ask the server and keep what it says. The client reads a failure as
    /// an empty list, so an empty answer never replaces segments already
    /// kept. Nothing is written once the folder has gone — the download
    /// deleted mid-fetch.
    @MainActor @discardableResult
    static func fetch(itemId: String, into folder: URL) async -> [MediaSegment] {
        let fetched = (try? await JellyfinClient.shared.mediaSegments(itemId: itemId)) ?? []
        guard !fetched.isEmpty else { return local(in: folder) }
        guard FileManager.default.fileExists(atPath: folder.path),
              let data = try? JSONEncoder().encode(fetched) else { return fetched }
        var url = folder.appendingPathComponent(fileName)
        try? data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return fetched
    }
}
#endif
