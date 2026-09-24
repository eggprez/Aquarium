//  The library, in the system's search.
//
//  Every film, show and episode the app has seen goes into Core Spotlight
//  under this app's name, so a title typed into the iPhone's search field or
//  the Mac's Spotlight opens its page here — the same page the top shelf's
//  `aquarium://item` link lands on. The library copy is the main source, and
//  keeps the index in step with what changed on each sync; without the copy,
//  Home's own rows are indexed as they load, which is less than everything
//  but is at least what the user has most recently been looking at.
//
//  Not on tvOS, which has no Core Spotlight.

#if os(iOS) || os(macOS)
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    /// One domain for the lot, so signing out can drop it in one call.
    nonisolated private static let domain = "media"
    private static let kinds: Set<String> = ["Movie", "Series", "Episode"]
    private static let batch = 400

    private var pending: Task<Void, Never>?

    /// Put these in the index (replacing what was there under the same ids)
    /// and take those out. Anything that isn't a film, show or episode is
    /// ignored, so callers can hand over a row as it is.
    func update(changed: [BaseItem], removed: [String] = []) {
        let items = changed.filter { Self.kinds.contains($0.kind) && !$0.Id.isEmpty }
        guard !items.isEmpty || !removed.isEmpty else { return }
        let previous = pending
        pending = Task { [previous] in
            await previous?.value
            // Which of them have a picture saved on disk, read once for the
            // batch rather than once per item.
            let thumbnails = await ImageLoader.shared.savedArtworkFiles(for: items.map(\.Id))
            let built = await Task.detached(priority: .utility) {
                items.map { Self.searchableItem($0, thumbnail: thumbnails[$0.Id]) }
            }.value
            let index = CSSearchableIndex.default()
            if !removed.isEmpty {
                try? await index.deleteSearchableItems(withIdentifiers: removed)
            }
            var start = 0
            while start < built.count {
                let slice = Array(built[start..<min(start + Self.batch, built.count)])
                try? await index.indexSearchableItems(slice)
                start += Self.batch
            }
        }
    }

    /// Everything out, on sign-out.
    func wipe() {
        let previous = pending
        pending = Task { [previous] in
            await previous?.value
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        }
    }

    nonisolated private static func searchableItem(_ item: BaseItem, thumbnail: URL?) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .movie)
        attributes.title = item.Name ?? "Untitled"
        attributes.thumbnailURL = thumbnail
        attributes.keywords = item.Genres
        // A show's run time is one episode's, which is not what a duration
        // under the title would read as.
        if item.kind != "Series", let seconds = item.RunTimeTicks.map({ Double($0) / 10_000_000 }), seconds > 0 {
            attributes.duration = NSNumber(value: seconds)
        }
        var lines: [String] = []
        switch item.kind {
        case "Episode":
            var facts: [String] = []
            if let series = item.SeriesName { facts.append(series) }
            if let label = item.episodeLabel { facts.append(label) }
            if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
            // A search for the show's name should find its episodes too.
            if let series = item.SeriesName { attributes.alternateNames = [series] }
        default:
            var facts: [String] = [item.kind == "Series" ? "TV show" : "Film"]
            if let year = item.ProductionYear { facts.append(String(year)) }
            lines.append(facts.joined(separator: " · "))
        }
        if let overview = item.Overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
            lines.append(overview)
        }
        // One line: the system's search collapses a newline to a space anyway.
        attributes.contentDescription = lines.joined(separator: " · ")
        let searchable = CSSearchableItem(uniqueIdentifier: item.Id, domainIdentifier: domain, attributeSet: attributes)
        searchable.expirationDate = .distantFuture
        return searchable
    }
}
#endif
