//  Keeping the Apple TV home screen's shelf in step with Next Up.
//
//  tvOS only: nothing else has a top shelf. See `TopShelfSnapshot` for why the
//  extension is handed files rather than a server address and a token.

#if os(tvOS)

import Foundation
import TVServices

enum TopShelf {
    /// How many posters to publish. The shelf scrolls, but nobody scrolls it
    /// far, and every entry is a JPEG the app has to fetch and keep.
    private static let limit = 10

    /// Replace the shelf with these items, newest state wins.
    ///
    /// Called from Home each time Next Up comes back. Cheap on the common path:
    /// a poster already on disk is not fetched again, and the system is only
    /// told the shelf changed once everything is written.
    static func publish(_ items: [BaseItem]) async {
        let items = Array(items.prefix(limit))
        // The session lives on the main actor, and Home calls this from a
        // detached task: the addresses are worked out there, and the writer is
        // handed them rather than reading the preferences from its own actor.
        let sources = await MainActor.run { () -> [URL?]? in
            guard let server = Preferences.shared.session?.server else { return nil }
            return items.map { Writer.posterURL(for: $0, server: server) }
        }
        // Signed out between Home asking and now: nothing to show.
        guard let sources else { return }
        await Writer.shared.publish(Array(zip(items, sources)))
    }

    /// Signing out takes the shelf with it — the posters are the user's library,
    /// and a signed-out television should not still be showing it.
    static func clear() {
        Task { await Writer.shared.clear() }
    }
}

// MARK: -

private actor Writer {
    static let shared = Writer()

    private let fm = FileManager.default

    /// Bumped by `clear()`. A publish waits on poster downloads, and a
    /// sign-out that clears the shelf in one of those waits must not have the
    /// old account's shelf written back over it when the publish resumes.
    private var generation = 0

    func publish(_ items: [(BaseItem, URL?)]) async {
        let started = generation
        guard let dir = TopShelfPaths.directory,
              let imagesDir = TopShelfPaths.images,
              let manifest = TopShelfPaths.manifest
        else { return }

        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        var entries: [TopShelfSnapshot.Entry] = []
        for (item, source) in items {
            guard let source else { continue }
            let name = Self.fileName(for: item, url: source)
            let file = imagesDir.appendingPathComponent(name)
            // The name carries the image tag, so a file that is already here is
            // already the right picture — a changed poster arrives under a
            // different name and the old one is swept up below.
            if !fm.fileExists(atPath: file.path) {
                guard let data = await Self.fetch(source) else { continue }
                guard generation == started else { return }
                guard (try? data.write(to: file, options: .atomic)) != nil else { continue }
            }
            entries.append(.init(
                id: item.Id,
                title: item.SeriesName ?? item.title,
                image: name,
                progress: item.progressFraction ?? 0
            ))
        }

        guard generation == started else { return }
        let snapshot = TopShelfSnapshot(entries: entries, generated: Date())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: manifest, options: .atomic)

        prune(keeping: Set(entries.map(\.image)), in: imagesDir)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    func clear() {
        generation += 1
        guard let dir = TopShelfPaths.directory else { return }
        try? fm.removeItem(at: dir)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Posters the shelf no longer names. Left alone, a season of nightly
    /// viewing turns the group container into a folder of dead artwork.
    private func prune(keeping wanted: Set<String>, in dir: URL) {
        let found = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in found where !wanted.contains(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Artwork

    /// The picture for a 2:3 cell.
    ///
    /// Deliberately not `Artwork.url`, which resolves Primary to the episode's
    /// own image and only falls back to the series when the episode has none.
    /// That is right everywhere the app draws a Next Up card — a still from the
    /// episode is more use than the show's poster — and wrong here, because the
    /// episode still is 16:9 and the cell is a poster. So the series is asked
    /// for first, and the episode is what's left if a show somehow has no
    /// poster of its own.
    ///
    /// Called on the main actor — see `TopShelf.publish` — since both this and
    /// `Artwork.url` read the session.
    static func posterURL(for item: BaseItem, server: String) -> URL? {
        let width = posterWidth
        if let seriesId = item.SeriesId, let tag = item.SeriesPrimaryImageTag {
            let q = [
                URLQueryItem(name: "maxWidth", value: String(width)),
                URLQueryItem(name: "tag", value: tag),
                URLQueryItem(name: "quality", value: "90"),
            ]
            return URL(string: "\(server)/Items/\(JellyfinClient.pathId(seriesId))/Images/Primary?\(JellyfinClient.encode(q))")
        }
        return Artwork.url(item, type: "Primary", width: width)
    }

    /// What the shelf actually draws a poster at, doubled for a 2x screen. Asked
    /// of TVServices rather than written down, because a cell that is 404 points
    /// wide today has not always been.
    private static var posterWidth: Int {
        let size = TVTopShelfSectionedContent.imageSize(for: .poster)
        return max(400, Int(size.width * 2))
    }

    /// `<item>-<tag>.jpg`, so the file name changes when the artwork does.
    private static func fileName(for item: BaseItem, url: URL) -> String {
        let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "tag" }?.value
        let id = item.SeriesId ?? item.Id
        // Both come from the server, and both end up in a path: escaped, so
        // that neither can carry a "/" or a ".." out of the images directory.
        return "\(JellyfinClient.pathId(id))-\(JellyfinClient.pathId(tag ?? "notag")).jpg"
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty
        else { return nil }
        return data
    }
}

#endif
