//  What a download will weigh, for the menus that offer one.
//
//  The estimate itself is `JellyfinClient.estimateDownloadSize`: the server's
//  file size for an original, bitrate × runtime for an encode. What it needs
//  is the item's media sources, and most lists leave those out to stay light.
//  So the pages that offer a download hand over what they have — a title
//  page's own item, a season's episodes, an album's tracks fetched with their
//  files — and the menus read from here. Where nothing has been handed over,
//  the library copy is asked, then the item as it is; a menu with no figure
//  to give simply gives none.

#if !os(tvOS)
import Foundation
import Observation

@MainActor
@Observable
final class DownloadSizes {
    static let shared = DownloadSizes()

    /// Items with their media sources, by id.
    @ObservationIgnored private var sized: [String: BaseItem] = [:]
    /// What a season, series, album or playlist is made of, by its id. The
    /// one thing here a menu waits on, so the one thing observed.
    private var members: [String: [String]] = [:]
    @ObservationIgnored private var warming: Set<String> = []

    private init() {}

    // MARK: Handing over

    /// Keep these, where they carry what an estimate needs.
    func note(_ items: [BaseItem]) {
        for item in items where item.MediaSources?.isEmpty == false {
            sized[item.Id] = item
        }
    }

    /// Keep what `id` is made of.
    func note(_ items: [BaseItem], as id: String) {
        note(items)
        members[id] = items.map(\.Id)
    }

    /// Fetch what `id` is made of, once, for a menu that will want it.
    func warm(_ id: String, load: () async -> [BaseItem]) async {
        guard members[id] == nil, !warming.contains(id) else { return }
        warming.insert(id)
        defer { warming.remove(id) }
        let items = await load()
        guard !items.isEmpty else { return }
        note(items, as: id)
    }

    // MARK: Reading

    /// The best copy of `item` there is for an estimate.
    func best(_ item: BaseItem) -> BaseItem {
        if item.MediaSources?.isEmpty == false { return item }
        if let kept = sized[item.Id] { return kept }
        if let copy = LibraryIndex.shared.item(item.Id), copy.MediaSources?.isEmpty == false { return copy }
        return item
    }

    /// What `id` is made of, as far as it has been handed over.
    func items(of id: String) -> [BaseItem]? {
        guard let ids = members[id] else { return nil }
        return ids.compactMap { sized[$0] }
    }

    /// About what downloading these at `quality` would add to the device:
    /// what is already on it, or on its way, is left out. Nil when nothing
    /// can be said.
    func bytes(_ items: [BaseItem], quality: DownloadQuality) -> Int64? {
        let manager = DownloadManager.shared
        let fresh = items.filter {
            manager.record(for: $0.Id)?.status != .complete && !manager.isQueuedOrRunning($0.Id)
        }
        guard !fresh.isEmpty else { return nil }
        return DownloadManager.estimateTotal(fresh.map(best), quality: quality)
    }

    /// The words a menu puts under a choice.
    static func text(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return "About \(Format.bytes(bytes))"
    }
}
#endif

import SwiftUI

/// One download choice in a menu: what it is, and under it what it weighs.
/// On a Mac, whose menus draw one line a row, the two share it.
/// A menu takes its row's title and subtitle from the button's label as it
/// stands, so the size sits beside the title rather than inside a `Label`'s
/// title, where it would be run into one line.
struct DownloadChoiceLabel: View {
    let title: String
    let size: String?
    let systemImage: String?

    init(_ title: String, size: String?, systemImage: String? = nil) {
        self.title = title
        self.size = size
        self.systemImage = systemImage
    }

    var body: some View {
        #if os(macOS)
        let line = size.map { "\(title) — \($0)" } ?? title
        if let systemImage { Label(line, systemImage: systemImage) } else { Text(line) }
        #else
        if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        if let size { Text(size) }
        #endif
    }
}
