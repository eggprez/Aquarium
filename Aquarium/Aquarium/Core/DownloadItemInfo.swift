//  What a downloaded film or episode is, kept beside it: the overview, the
//  rating, the genres, the file the server holds. The record knows a
//  download's name and its place in its show and little else, which left
//  the player's Info page all but empty for one. Written when the download
//  finishes and again each time it is played with a server in reach.

#if !os(tvOS)
import Foundation

enum DownloadItemInfo {
    static let fileName = "item.json"

    static func local(in folder: URL) -> BaseItem? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(BaseItem.self, from: data)
    }

    /// Ask the server and keep its answer. Nil when it can't be asked or the
    /// download has gone; what is on disk stays as it was.
    @MainActor
    @discardableResult
    static func fetch(itemId: String, into folder: URL) async -> BaseItem? {
        guard DownloadManager.shared.record(for: itemId)?.isAudio == false,
              !JellyfinClient.shared.isOffline,
              var item = try? await JellyfinClient.shared.item(itemId) else { return nil }
        // Nothing the Info page draws, and the bulk of the answer.
        item.People = nil
        item.Chapters = nil
        item.Trickplay = nil
        item.ImageBlurHashes = nil
        guard FileManager.default.fileExists(atPath: folder.path),
              let data = try? JSONEncoder().encode(item) else { return item }
        var url = folder.appendingPathComponent(fileName)
        try? data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return item
    }
}
#endif
