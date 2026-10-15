//  What the Follow widget can be set to follow.
//
//  The widget's configuration menu is drawn by another process with no way
//  to the server, so its choices are written here, into the app group,
//  each time Home loads its rows: what is part-watched, what is up next,
//  and a few favourites — with a poster for each, saved small beside the
//  snapshot. See Shared/FollowTypes.swift for what is written and
//  LiveActivities/FollowWidget.swift for how it is drawn.
//
//  iPhone and iPad only, where the widget is.

#if os(iOS)

import Foundation
import UIKit
import WidgetKit

@MainActor
final class FollowFeed {
    static let shared = FollowFeed()

    private var task: Task<Void, Never>?
    /// The favourites are a request of their own, so they are asked for
    /// now and then rather than with every Home load.
    private var favorites: [BaseItem] = []
    private var favoritesAt: Date?
    private static let favoritesEvery: TimeInterval = 30 * 60
    private static let maxEntries = 24
    nonisolated private static let posterSide: CGFloat = 300

    private init() {}

    func update(resume: [BaseItem], nextUp: [BaseItem]) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.refreshFavorites()
            guard !Task.isCancelled else { return }
            var entries: [FollowSnapshot.Entry] = []
            var posters: [String: URL] = [:]
            var seen = Set<String>()

            func add(_ item: BaseItem, subtitle: String, fraction: Double?) {
                // A show is followed as a show, whichever episode is next.
                let id = item.isEpisode ? (item.SeriesId ?? item.Id) : item.Id
                guard seen.insert(id).inserted else { return }
                let title = item.isEpisode ? (item.SeriesName ?? item.title) : item.title
                entries.append(FollowSnapshot.Entry(
                    id: id, title: title, subtitle: subtitle, fraction: fraction,
                    linkId: item.Id, isSeries: item.isEpisode || item.isSeries, hasArtwork: false
                ))
                let poster = item.isEpisode ? Artwork.seriesPoster(item, width: Int(Self.posterSide)) : Artwork.url(item, width: Int(Self.posterSide))
                if let poster { posters[id] = poster }
            }

            for item in resume { add(item, subtitle: Self.resumeLine(item), fraction: Self.fraction(item)) }
            for item in nextUp { add(item, subtitle: Self.nextLine(item), fraction: nil) }
            for item in self.favorites { add(item, subtitle: "Favorite", fraction: nil) }
            entries = Array(entries.prefix(Self.maxEntries))

            for i in entries.indices {
                guard !Task.isCancelled else { return }
                if let url = posters[entries[i].id], await Self.savePoster(url, for: entries[i].id) {
                    entries[i].hasArtwork = true
                }
            }
            guard !Task.isCancelled else { return }
            FollowSnapshot.pruneArtwork(keeping: Set(entries.map(\.id)))
            FollowSnapshot.write(FollowSnapshot(entries: entries))
            WidgetCenter.shared.reloadTimelines(ofKind: FollowSnapshot.widgetKind)
        }
    }

    /// Everything out, on sign-out.
    func wipe() {
        task?.cancel()
        favorites = []
        favoritesAt = nil
        FollowSnapshot.pruneArtwork(keeping: [])
        FollowSnapshot.write(nil)
        WidgetCenter.shared.reloadTimelines(ofKind: FollowSnapshot.widgetKind)
    }

    private func refreshFavorites() async {
        if let at = favoritesAt, Date().timeIntervalSince(at) < Self.favoritesEvery { return }
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.showsOffline else { return }
        guard let response = try? await client.favorites(limit: 8, includeTypes: "Movie,Series") else { return }
        favorites = response.items
        favoritesAt = Date()
    }

    private static func fraction(_ item: BaseItem) -> Double? {
        if let percent = item.userData.PlayedPercentage, percent > 0 { return min(1, percent / 100) }
        guard item.runtimeSeconds > 0 else { return nil }
        let position = Double(item.userData.positionTicks) / 10_000_000
        return position > 0 ? min(1, position / item.runtimeSeconds) : nil
    }

    private static func resumeLine(_ item: BaseItem) -> String {
        var facts: [String] = []
        if item.isEpisode, let label = item.episodeLabel { facts.append(label) }
        let left = item.runtimeSeconds - Double(item.userData.positionTicks) / 10_000_000
        if item.runtimeSeconds > 0, left > 0 {
            facts.append("\(max(1, Int((left / 60).rounded()))) min left")
        }
        return facts.isEmpty ? "Continue watching" : facts.joined(separator: " · ")
    }

    private static func nextLine(_ item: BaseItem) -> String {
        var facts: [String] = []
        if let label = item.episodeLabel { facts.append(label) }
        if item.isEpisode, let name = item.Name { facts.append(name) }
        return facts.isEmpty ? "Up next" : facts.joined(separator: " · ")
    }

    /// The poster, saved small. One already on disk is kept: a poster
    /// changes about never, and Home loads often.
    private static func savePoster(_ url: URL, for id: String) async -> Bool {
        guard let file = FollowSnapshot.artworkFile(for: id) else { return false }
        if FileManager.default.fileExists(atPath: file.path) { return true }
        guard let image = await ImageLoader.shared.load(url) else { return false }
        let jpeg = await Task.detached(priority: .utility) { thumbnail(image, side: posterSide) }.value
        guard let jpeg else { return false }
        return (try? jpeg.write(to: file, options: .atomic)) != nil
    }

    nonisolated private static func thumbnail(_ image: UIImage, side: CGFloat) -> Data? {
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.jpegData(compressionQuality: 0.82)
    }
}

#endif
