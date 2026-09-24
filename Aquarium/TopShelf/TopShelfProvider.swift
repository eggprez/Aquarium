//  The Apple TV home screen's shelf: Next Up, as posters.
//
//  Runs as its own process, started by the system whenever it wants the shelf
//  redrawn — which can be long before the app has ever been opened this boot,
//  and with no network worth waiting on. So this reads the manifest the app left
//  in the shared group container and returns; there is no request to make and
//  nothing to sign in to. `TopShelfSnapshot` explains the arrangement.

import Foundation
import TVServices

final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = Self.snapshot(), !snapshot.entries.isEmpty,
              let imagesDir = TopShelfPaths.images
        else {
            // Nothing published — no session yet, or a fresh install. Handing
            // back nil leaves the static Top Shelf Image in place, which is the
            // right thing to show rather than an empty row with a heading.
            completionHandler(nil)
            return
        }

        let items: [TVTopShelfSectionedItem] = snapshot.entries.map { entry in
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.title
            item.imageShape = .poster
            item.playbackProgress = entry.progress
            // A file URL inside the group container, which is the only local
            // artwork the home screen will load — it reads the file itself,
            // out of this process.
            let image = imagesDir.appendingPathComponent(entry.image)
            item.setImageURL(image, for: .screenScale1x)
            item.setImageURL(image, for: .screenScale2x)
            if let display = TopShelfPaths.link("item", entry.id) {
                item.displayAction = TVTopShelfAction(url: display)
            }
            if let play = TopShelfPaths.link("play", entry.id) {
                item.playAction = TVTopShelfAction(url: play)
            }
            return item
        }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "Next Up"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }

    private static func snapshot() -> TopShelfSnapshot? {
        guard let url = TopShelfPaths.manifest,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }
}
