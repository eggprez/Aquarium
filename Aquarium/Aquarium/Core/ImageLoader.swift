//  Artwork loading, cached, with a BlurHash under it.
//
//  SwiftUI's own AsyncImage re-fetches every time a cell is recycled, which on
//  a library grid means the same poster is downloaded a dozen times as you
//  scroll. This keeps decoded images in an NSCache and coalesces concurrent
//  requests for the same URL, so a poster that appears in three rows is fetched
//  once.

import Foundation
import ImageIO
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

actor ImageLoader {
    static let shared = ImageLoader()

    private let cache: NSCache<NSURL, PlatformImage> = {
        let c = NSCache<NSURL, PlatformImage>()
        c.countLimit = 400
        // Decoded artwork, and the budget has to be measured against the one
        // screen that actually strains it. A television asks for 480-point-wide
        // posters, which decode to about 1.4 MB each: at 80 MB the cache held
        // fifty-eight of them, and a library page is sixty. So scrolling a
        // library evicted the row you had just left, every time, and every tile
        // was fetched again on the way back — which is what turned an
        // occasional failed request into posters that were "randomly" missing.
        // 192 MB holds three screenfuls, and `purge()` still gives the lot back
        // the moment the system asks.
        c.totalCostLimit = 192 * 1024 * 1024
        return c
    }()

    /// A fetch in progress, and how many callers are still waiting on it.
    ///
    /// Counted so that a fetch nobody wants any more can be called off. A
    /// library flicked through quickly mounts and unmounts dozens of tiles, and
    /// with six connections to the host, requests for posters already scrolled
    /// past used to sit in the queue ahead of the ones now on screen.
    private struct Flight {
        let task: Task<Fetched, Never>
        var waiters: Int
    }

    /// An `Outcome`, plus the bytes to save when the picture came off the
    /// network and is worth keeping for the library copy.
    private enum Fetched: Sendable {
        case image(PlatformImage, keep: Data?)
        case absent
        case failed

        var outcome: Outcome {
            switch self {
            case .image(let image, _): .image(image)
            case .absent: .absent
            case .failed: .failed
            }
        }
    }

    private var inFlight: [URL: Flight] = [:]

    /// The widest copy of each server picture held in `cache`, by the same
    /// item-and-type slot the disk copy is filed under. The same poster is asked
    /// for at a different width by every card size that shows it; a narrower
    /// request is answered from the wider copy already in memory rather than
    /// fetched and decoded a second time.
    private var widestInMemory: [String: (tag: String, width: Int, url: URL)] = [:]

    #if os(macOS)
    /// The Mac's word that memory is short. Kept, because a dispatch source
    /// nobody holds is cancelled.
    private let memoryPressure: DispatchSourceMemoryPressure
    #endif

    private init() {
        #if canImport(UIKit)
        // `purge()` used to be defined and never called, so the cache relied on
        // NSCache trimming itself — which it does late, and a jetsam comes first
        // on a television or an older phone.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { _ in
            Task { await ImageLoader.shared.purge() }
        }
        #else
        // A Mac has no memory warning notification; the kernel's pressure
        // level is the same signal. Warning as well as critical, since by
        // critical the app is already being swapped.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            Task { await ImageLoader.shared.purge() }
        }
        source.resume()
        memoryPressure = source
        #endif
    }

    /// How many pixels to ask the server for, for a picture drawn `points`
    /// wide on a screen of `displayScale` — the value of
    /// `@Environment(\.displayScale)` where the picture is drawn.
    ///
    /// Rounded up to a step of eighty, and not because the arithmetic needs
    /// it: a Mac shelf sizes its cards from the window, so every resize would
    /// otherwise be a new width, a new URL, a new resize on the server and a
    /// new download. Eighty pixels of step is at most a few percent of blur on
    /// the widest card and a cache that survives dragging a window edge.
    nonisolated static func requestWidth(points: CGFloat, displayScale: CGFloat) -> Int {
        let pixels = points * max(1, displayScale)
        let step: CGFloat = 80
        return Int((pixels / step).rounded(.up) * step)
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // `.returnCacheDataElseLoad` was wrong for anything that can fail.
        // It hands back whatever is in the cache without asking the server,
        // and a 403 or a 404 is a cacheable response like any other — so a
        // logo that failed once (a host that was briefly down, an address the
        // app used to build wrongly) stayed failed for as long as the entry
        // lived, no matter what was fixed in between. The protocol's own rules
        // still serve everything from disk that the server said could be.
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        cfg.timeoutIntervalForRequest = 20
        // A library page appears and asks for sixty posters in one breath. Over
        // HTTP/2 URLSession will happily put all sixty on one connection at
        // once, and a Jellyfin that is also serving a transcode answers some of
        // them with a 500 or a 503. Six at a time is what every browser does
        // and it costs nothing visible — the grid fills a row at a time instead
        // of all at once.
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    /// What image hosts are asked with.
    ///
    /// A plain `URLSession` request carries no `Accept` and a User-Agent that
    /// names this app, and a surprising number of the hosts an IPTV playlist
    /// points at — Wikimedia among them — answer 403 to anything that doesn't
    /// look like a browser. Every other client on the platform sends something
    /// like this, which is why their tiles fill in.
    static func imageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    /// How a fetch ended, which is two different things that used to be one.
    ///
    /// `nil` meant both "the server answered and there is no picture there" and
    /// "nothing came back at all", and the caller had to treat them the same:
    /// as a settled answer. So a poster whose request lost the network — the
    /// first card of a shelf built the instant the page loaded, while several
    /// other requests were in flight, is the one this kept happening to — was
    /// recorded as having no artwork and never asked for again, and sat blank
    /// until the page was left and come back to. Told apart, one of them is
    /// worth another go and the other is not. See `RemoteImage.refresh`.
    enum Outcome: Sendable {
        case image(PlatformImage)
        /// The host answered, and what it answered with was not a picture: a
        /// 404, a 403, a body that doesn't decode. Asking again gets the same
        /// answer.
        case absent
        /// Nothing was answered — a timeout, a dropped connection, a refused
        /// socket. Says nothing about whether the picture exists.
        case failed
    }

    func cached(_ url: URL) -> PlatformImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        return widerCopy(of: url)
    }

    /// The same picture already in memory at this width or wider.
    private func widerCopy(of url: URL) -> PlatformImage? {
        guard let key = Self.diskKey(url), key.width > 0,
              let held = widestInMemory[key.slot], held.tag == key.tag, held.width >= key.width
        else { return nil }
        guard let image = cache.object(forKey: held.url as NSURL) else {
            widestInMemory[key.slot] = nil
            return nil
        }
        return image
    }

    private func remember(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: estimatedCost(image))
        guard let key = Self.diskKey(url), key.width > 0 else { return }
        if let held = widestInMemory[key.slot], held.tag == key.tag, held.width >= key.width { return }
        widestInMemory[key.slot] = (key.tag, key.width, url)
    }

    /// The old shape, for the callers that only ever wanted the picture.
    func load(_ url: URL) async -> PlatformImage? {
        if case .image(let image) = await fetch(url) { return image }
        return nil
    }

    func fetch(_ url: URL) async -> Outcome {
        if let hit = cached(url) { return .image(hit) }

        let flight: Task<Fetched, Never>
        if let running = inFlight[url] {
            flight = running.task
            inFlight[url]?.waiters += 1
        } else {
            // Where a saved copy is, worked out here because the index lives on
            // this actor; reading and decoding it happens in the task, off it.
            let saved = await diskFile(for: url)
            // The index read can suspend, and another caller may have started
            // the same fetch meanwhile.
            if let running = inFlight[url] {
                flight = running.task
                inFlight[url]?.waiters += 1
            } else {
                flight = Task<Fetched, Never> { [session] in
                    await Self.run(url, saved: saved, session: session)
                }
                inFlight[url] = Flight(task: flight, waiters: 1)
            }
        }

        let fetched = await withTaskCancellationHandler {
            await flight.value
        } onCancel: {
            Task { await self.abandon(url, flight) }
        }
        // The first waiter back files the result; the rest find it filed.
        guard inFlight[url]?.task == flight else { return fetched.outcome }
        inFlight[url] = nil
        if case .image(let image, let keep) = fetched {
            remember(image, for: url)
            if let keep { await keepOnDisk(keep, for: url) }
        }
        return fetched.outcome
    }

    /// One caller stopped waiting. The last one to leave calls the fetch off.
    private func abandon(_ url: URL, _ flight: Task<Fetched, Never>) {
        guard var entry = inFlight[url], entry.task == flight else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            inFlight[url] = nil
            flight.cancel()
        } else {
            inFlight[url] = entry
        }
    }

    /// The fetch itself, with nothing of the actor's in it, so that sixty
    /// tiles' worth of disk reads and decodes run side by side instead of
    /// queueing behind one another on the actor.
    @concurrent
    private static func run(_ url: URL, saved: (file: URL, isLargeEnough: Bool)?, session: URLSession) async -> Fetched {
        // A saved copy that is big enough is the answer; one that is too small
        // is kept back in case the server can't be reached for a better one.
        var fallback: PlatformImage?
        if let saved, let data = try? Data(contentsOf: saved.file),
           let image = decode(data, for: url) {
            if saved.isLargeEnough { return .image(image, keep: nil) }
            fallback = image
        }
        let outcome: Fetched
        do {
            let (data, response) = try await session.data(for: imageRequest(url))
            // A `file:` URL answers with no status line at all, so the bytes
            // are the whole answer. Calling that a failure would put it in
            // the retry loop below, three times over, for a picture that is
            // either on disk or isn't.
            if let http = response as? HTTPURLResponse {
                // "Not now" is not "not here". A 5xx or a 429 is the host
                // under load — which is exactly what sixty simultaneous poster
                // requests produce — and writing those off as artwork that
                // doesn't exist is what left tiles blank for as long as the
                // page stayed open, since a settled answer is never asked
                // again. Told apart, they go back through the retry passes.
                if http.statusCode >= 500 || http.statusCode == 429 {
                    outcome = .failed
                } else if !(200..<300).contains(http.statusCode) {
                    outcome = .absent
                } else if Task.isCancelled {
                    outcome = .failed
                } else if let image = decode(data, for: url) {
                    outcome = .image(image, keep: data)
                } else {
                    // A 200 whose body won't decode is a response that was cut
                    // short far more often than it is a broken file on the
                    // server, so it is worth the same second look.
                    outcome = .failed
                }
            } else {
                outcome = decode(data, for: url).map { .image($0, keep: nil) } ?? .absent
            }
        } catch {
            outcome = .failed
        }
        if case .failed = outcome, let fallback { return .image(fallback, keep: nil) }
        return outcome
    }

    /// A picture decoded now, off the main thread, rather than lazily by the
    /// first frame that draws it.
    ///
    /// `UIImage(data:)` doesn't decode anything: it keeps the compressed bytes
    /// and the JPEG is unpacked on the main thread the first time SwiftUI
    /// renders it — one tile at a time as a grid scrolls, which is where the
    /// hitches were. And a playlist's channel logo is whatever file the host
    /// had: a 2000-pixel PNG unpacks to 16 MB for a 160-point tile, so a web
    /// picture with no width asked of the server is scaled down as it is read.
    private static func decode(_ data: Data, for url: URL) -> PlatformImage? {
        // A URL that asks for a width is taken to have been given one — but
        // only up to a point. "maxwidth=" in a query is something any host can
        // write, and a logo address carrying it used to skip the scaling
        // altogether: a 30,000-pixel PNG then unpacks to gigabytes.
        let ceiling = Self.asksServerForWidth(url) ? Self.sizedMaxPixel : Self.unsizedMaxPixel
        if url.scheme?.hasPrefix("http") == true, let small = downsample(data, maxPixel: ceiling) {
            return small
        }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
        #else
        // `NSImage(data:)` is as lazy as `UIImage(data:)`: the JPEG is
        // unpacked by the first draw, on the main thread, one tile at a time
        // as the grid scrolls. Decoding through the image source here, with
        // caching on, hands the view a bitmap that is already pixels.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return NSImage(data: data) }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// The longest side a picture from a host that can't be asked for a size
    /// is kept at. Twice the widest tile that draws one.
    private static let unsizedMaxPixel = 1024

    /// And one that said it would size the picture itself. Well past the
    /// widest thing the app asks for, so a server that did as asked never
    /// meets it.
    private static let sizedMaxPixel = 4096

    private static func asksServerForWidth(_ url: URL) -> Bool {
        guard let query = url.query?.lowercased() else { return false }
        return query.contains("maxwidth=") || query.contains("fillwidth=")
    }

    /// Nil when the picture is already small enough, and the ordinary decode
    /// will do.
    private static func downsample(_ data: Data, maxPixel: Int) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixel
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: thumbnail)
        #else
        // Sized in pixels, so a point is a pixel and the view scales it to the
        // frame it is given, the same as the UIKit path.
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        #endif
    }

    // MARK: - Artwork kept on disk

    /// Server artwork saved for the library copy — see `LibraryIndex`.
    ///
    /// Filed by item, image type and tag, and not by URL, because the same
    /// poster is asked for at a different width by every card size that shows
    /// it; the width is recorded so a saved picture is only used where it is
    /// big enough not to look soft. A new tag is a new picture, and replaces
    /// the old file.
    private struct DiskEntry {
        var tag: String
        var width: Int
        var file: String
        var bytes: Int64
    }

    /// Whether pictures fetched are saved. Reading what was saved doesn't
    /// depend on it: turning the setting off deletes the lot.
    private var diskEnabled = false
    /// By "id_type". Read from the directory on first use.
    private var diskEntries: [String: DiskEntry]?

    private static var artworkDirectory: URL {
        LibraryIndex.directory.appending(path: "Artwork", directoryHint: .isDirectory)
    }

    func setDiskEnabled(_ enabled: Bool) {
        diskEnabled = enabled
    }

    /// The copy was deleted.
    func forgetDisk() {
        diskEntries = [:]
    }

    /// Which item, image type and tag a server artwork URL is for, and how
    /// wide it was asked for. Nil for anything else — a playlist's logo, a
    /// season poster asked for without a tag, which has nothing to say when it
    /// has changed.
    private static func diskKey(_ url: URL) -> (slot: String, tag: String, width: Int)? {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[parts.count - 4] == "Items", parts[parts.count - 2] == "Images",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let tag = items.first(where: { $0.name == "tag" })?.value, !tag.isEmpty
        else { return nil }
        let width = items.first { $0.name == "maxWidth" }?.value.flatMap(Int.init) ?? 0
        let safe = { (s: Substring) in String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" }) }
        return ("\(safe(parts[parts.count - 3]))_\(safe(parts[parts.count - 1]))",
                String(tag.filter { $0.isLetter || $0.isNumber }), width)
    }

    /// Where the saved copies of these items' pictures are, for anything that
    /// wants a file rather than an image — Spotlight's thumbnails. Only ids
    /// with a picture on disk are in the answer.
    func savedArtworkFiles(for ids: [String], type: String = "Primary") async -> [String: URL] {
        let all = await entries()
        var out: [String: URL] = [:]
        for id in ids {
            if let entry = all["\(id)_\(type)"] {
                out[id] = Self.artworkDirectory.appending(path: entry.file)
            }
        }
        return out
    }

    /// The scan of the artwork folder, once, shared by everyone who asks
    /// before it has finished.
    private var scanning: Task<[String: DiskEntry], Never>?

    private func entries() async -> [String: DiskEntry] {
        if let diskEntries { return diskEntries }
        let scan = scanning ?? Task.detached(priority: .utility) { Self.scanArtwork() }
        scanning = scan
        let found = await scan.value
        scanning = nil
        // A picture saved, or the copy deleted, while the scan ran is already
        // in `diskEntries` and is the newer answer.
        if let diskEntries { return diskEntries }
        diskEntries = found
        return found
    }

    /// Every saved picture, with its size, from one listing of the folder —
    /// not a listing and then a `stat` per file, which with a library copy is
    /// thousands of calls that the first tile on screen used to wait behind.
    private static func scanArtwork() -> [String: DiskEntry] {
        var found: [String: DiskEntry] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: artworkDirectory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        for file in files {
            // id_type_tag_width
            let name = file.lastPathComponent
            let fields = name.split(separator: "_")
            guard fields.count == 4, let width = Int(fields[3]) else { continue }
            let slot = "\(fields[0])_\(fields[1])"
            if let existing = found[slot], existing.width >= width { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            found[slot] = DiskEntry(tag: String(fields[2]), width: width, file: name, bytes: Int64(size))
        }
        return found
    }

    /// The saved copy of this picture, if there is one with the right tag, and
    /// whether it is wide enough to use as it is.
    private func diskFile(for url: URL) async -> (file: URL, isLargeEnough: Bool)? {
        guard let key = Self.diskKey(url), let entry = await entries()[key.slot], entry.tag == key.tag
        else { return nil }
        // Three quarters of the asked-for width is indistinguishable on a card;
        // less is visibly soft and worth fetching again when the server is there.
        return (Self.artworkDirectory.appending(path: entry.file), entry.width * 4 >= key.width * 3)
    }

    private func hasOnDisk(_ url: URL) async -> Bool {
        guard let key = Self.diskKey(url), let entry = await entries()[key.slot] else { return false }
        return entry.tag == key.tag && entry.width * 4 >= key.width * 3
    }

    private func keepOnDisk(_ data: Data, for url: URL) async {
        guard diskEnabled, let key = Self.diskKey(url) else { return }
        if let existing = await entries()[key.slot], existing.tag == key.tag, existing.width >= key.width { return }
        let name = "\(key.slot)_\(key.tag)_\(key.width)"
        guard await Self.write(data, named: name) else { return }
        // Read again: the write let other saves run, and one of them may have
        // filed this slot already — at a greater width, even.
        var all = diskEntries ?? [:]
        let dir = Self.artworkDirectory
        if let current = all[key.slot], current.file != name {
            if current.tag == key.tag, current.width >= key.width {
                try? FileManager.default.removeItem(at: dir.appending(path: name))
                return
            }
            try? FileManager.default.removeItem(at: dir.appending(path: current.file))
        }
        all[key.slot] = DiskEntry(tag: key.tag, width: key.width, file: name, bytes: Int64(data.count))
        diskEntries = all
    }

    @concurrent
    private static func write(_ data: Data, named name: String) async -> Bool {
        let dir = artworkDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appending(path: name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Of these, the ones with nothing good enough on disk.
    func missingOnDisk(_ urls: [URL]) async -> [URL] {
        var seen = Set<String>()
        var missing: [URL] = []
        for url in urls {
            guard let key = Self.diskKey(url), seen.insert(key.slot).inserted else { continue }
            if !(await hasOnDisk(url)) { missing.append(url) }
        }
        return missing
    }

    /// Fetch a picture straight to disk without decoding it for display. For
    /// the library copy, which saves thousands of pictures nobody is looking
    /// at yet. True when it is there afterwards.
    func saveToDisk(_ url: URL) async -> Bool {
        guard diskEnabled else { return false }
        if await hasOnDisk(url) { return true }
        guard let (data, response) = try? await session.data(for: Self.imageRequest(url)),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              Self.looksLikeImage(data)
        else { return false }
        await keepOnDisk(data, for: url)
        return await hasOnDisk(url)
    }

    /// JPEG, PNG, WebP or GIF by their first bytes — enough to keep an HTML
    /// error page from being filed as a poster, without decoding every one.
    private static func looksLikeImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 4 else { return false }
        if head[0] == 0xFF, head[1] == 0xD8 { return true }
        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return true }
        if head[0] == 0x47, head[1] == 0x49, head[2] == 0x46 { return true }
        if head.count >= 12, head[0] == 0x52, head[1] == 0x49, head[8] == 0x57, head[9] == 0x45 { return true }
        return false
    }

    func diskUsage() async -> Int64 {
        await entries().values.reduce(0) { $0 + $1.bytes }
    }

    private func estimatedCost(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        let scale = image.scale
        return Int(image.size.width * scale * image.size.height * scale * 4)
        #else
        return Int(image.size.width * image.size.height * 4)
        #endif
    }

    /// Dropped when the app is put under memory pressure.
    func purge() {
        cache.removeAllObjects()
        widestInMemory = [:]
    }
}

/// Cached remote artwork with a BlurHash placeholder beneath it.
///
/// The hash is decoded synchronously on first appearance — it is a 32×32 image
/// built from twenty-odd characters, which is cheap enough to do inline and
/// avoids a frame of empty grey before the placeholder itself appears.
///
/// The placeholder stays *underneath* the artwork rather than being swapped out
/// for it. Swapping is what made loading look wrong while scrolling: the blur
/// was replaced in a single frame by a picture whose own fade-in started from
/// nothing, so a grid filling in read as a series of flashes. Layered, the
/// artwork simply resolves out of the blur, which is what every first-party
/// grid does.
struct RemoteImage: View {
    let url: URL?
    /// Tried when `url` has no image behind it — a season poster falling back
    /// to its show's, an episode with no still of its own.
    var fallbackURL: URL?
    var blurHash: String?
    var contentMode: ContentMode = .fill
    /// What to paint under artwork that hasn't arrived, for the callers whose
    /// slot isn't a card — the hero, which stays dark in both themes.
    var placeholderFill: LinearGradient = Theme.placeholderFill
    /// Told whether there turned out to be a picture behind the URL, once the
    /// fetch has settled. For the callers that have something else to draw when
    /// there isn't — a hero whose title art is missing still has to say what the
    /// title is — rather than leaving a hole where the artwork would have been.
    var onResolved: ((Bool) -> Void)?
    /// A last say over a picture that did arrive, by its size. An image this
    /// turns down is treated as one the server doesn't have: nothing is drawn
    /// and `onResolved` hears `false`, so the caller's fallback takes over.
    var accepts: ((CGSize) -> Bool)?

    @State private var image: PlatformImage?
    @State private var placeholder: CGImage?
    @State private var loadedURL: URL?
    @State private var isFetching = false

    private var candidates: [URL] { [url, fallbackURL].compactMap { $0 } }

    var body: some View {
        sized
            .task(id: candidates) { await refresh() }
            .onAppear {
                if placeholder == nil, let blurHash {
                    placeholder = BlurHash.image(from: blurHash)
                }
            }
    }

    /// Filling artwork is drawn into a frame that has already been decided,
    /// rather than deciding one.
    ///
    /// A `.fill` image reports a size *larger* than the one it was proposed —
    /// that is what filling means — and a stack takes the size of its largest
    /// child. Left as this view's own size that overspill escapes upward: the
    /// frame around a card centres a picture wider than the slot, the card's
    /// rounded clip is cut at the picture's size rather than the slot's, and the
    /// tile lands over its neighbours with a band of blur showing beside it.
    /// `.clipped()` here can't help — by then the bounds it clips to are the
    /// oversized ones.
    ///
    /// `Color.clear` accepts exactly what it is proposed and reports nothing
    /// else, so the size the parent sees is the size it asked for. The artwork
    /// goes on as an overlay, which is sized by those bounds and cropped to
    /// them.
    ///
    /// A `.fit` image never exceeds its proposal, and its own size is what
    /// callers want — a logo laid over a backdrop is sized and aligned by the
    /// picture, not by the box around it — so it is left to size itself, and
    /// gets no placeholder: it is drawn inside its frame, so whatever is painted
    /// behind it would stay visible for good.
    ///
    /// It does get a zero-sized clear layer, though, and that is not decoration:
    /// a view that renders *nothing at all* is never mounted, and a `.task`
    /// attached to one never runs. Left as a bare empty artwork layer, a `.fit`
    /// image waited for itself — the loader that sets `image` hung off a view
    /// that only exists once `image` is set — so every logo in the app was a
    /// blank space, and a hero whose title art was its title showed no title.
    /// A zero-sized layer takes no part in the layout and gives the loader
    /// something to be attached to.
    ///
    /// The blur and the artwork go on as two overlays rather than as one stack.
    /// A stack has to take a size that holds both, and the blur is square while
    /// the artwork is whatever shape the server had: the stack ends up a
    /// different shape from either, and centring two pictures inside *that*
    /// leaves them offset from one another — the blur showing down one side of
    /// its own artwork. As separate overlays each is cropped to the same bounds
    /// and they land exactly on top of each other.
    @ViewBuilder
    private var sized: some View {
        if contentMode == .fill {
            Color.clear
                .overlay { placeholderLayer }
                .overlay { artworkLayer }
                .clipped()
        } else {
            ZStack {
                Color.clear.frame(width: 0, height: 0)
                artworkLayer
            }
        }
    }

    @ViewBuilder
    private var placeholderLayer: some View {
        if let placeholder {
            Image(decorative: placeholder, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholderFill
                .overlay { if isFetching { ShimmerOverlay() } }
        }
    }

    @ViewBuilder
    private var artworkLayer: some View {
        if let image {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .transition(.opacity)
        }
    }

    private func refresh() async {
        let urls = candidates
        guard let primary = urls.first else {
            image = nil
            isFetching = false
            onResolved?(false)
            return
        }
        // A cell recycled onto the same URL keeps what it already drew.
        if loadedURL == primary, image != nil { return }
        if placeholder == nil, let blurHash {
            placeholder = BlurHash.image(from: blurHash)
        }
        for candidate in urls {
            if let hit = await ImageLoader.shared.cached(candidate) {
                guard isAcceptable(hit) else { return reject() }
                image = hit
                loadedURL = primary
                isFetching = false
                onResolved?(true)
                return
            }
        }
        image = nil
        isFetching = true
        defer { isFetching = false }

        // Each pass tries every candidate; a pass that ends with nothing but
        // *failures* is worth repeating, one that ends with a settled "there
        // isn't one" is not. See `ImageLoader.Outcome` for what this is fixing:
        // a poster whose request lost the network was written off as artwork
        // the server doesn't have, and a card only asks once.
        //
        // Three passes, backing off, which is over in four seconds — quick
        // enough that a card fills in while you are still looking at the shelf,
        // and few enough that a genuinely unreachable host isn't hammered.
        // With no route to the server there is nothing a second pass can find
        // that the first didn't, and each pass pays for it: a network that is
        // up but cannot reach the host doesn't refuse the connection, it waits
        // out the request timeout. Three of those per tile is what made a
        // downloads screen take the better part of a minute to draw offline.
        // A `file:` candidate is unaffected either way — it answers at once.
        let passes = JellyfinClient.shared.isOffline ? 1 : Self.attempts
        for attempt in 0..<passes {
            if attempt > 0 {
                try? await Task.sleep(for: Self.backoff[attempt - 1])
                guard !Task.isCancelled else { return }
            }
            var anyFailed = false
            for candidate in urls {
                switch await ImageLoader.shared.fetch(candidate) {
                case .image(let loaded):
                    guard !Task.isCancelled else { return }
                    guard isAcceptable(loaded) else { return reject() }
                    withAnimation(.easeOut(duration: Self.fadeIn)) {
                        image = loaded
                    }
                    loadedURL = primary
                    onResolved?(true)
                    return
                case .failed:
                    anyFailed = true
                case .absent:
                    break
                }
                guard !Task.isCancelled else { return }
            }
            // Every candidate answered, and none of them had a picture: a tag
            // the scan left behind, a logo the server can't produce. Nothing to
            // come back for.
            guard anyFailed else { break }
        }
        onResolved?(false)
    }

    private func isAcceptable(_ picture: PlatformImage) -> Bool {
        accepts?(picture.size) ?? true
    }

    private func reject() {
        image = nil
        isFetching = false
        onResolved?(false)
    }

    /// How long a picture that came off the network takes to resolve out of
    /// its placeholder. One that was already in memory doesn't fade at all —
    /// see the cached branch of `refresh`. A quarter of a second reads as a
    /// flicker on a Mac grid scrolled with a wheel, where a row of tiles
    /// arrives at once; a tenth is the artwork settling.
    private static var fadeIn: Double {
        #if os(macOS)
        0.12
        #else
        0.25
        #endif
    }

    /// How many times a pass that only ever *failed* is repeated, and how long
    /// is left between them.
    private static let attempts = 3
    private static let backoff: [Duration] = [.milliseconds(400), .milliseconds(1200)]
}

/// What a tile shows while it is waiting on a picture it has no blur for: one
/// soft highlight travelling across the placeholder.
///
/// A spinner per cell is the wrong shape for a grid — a dozen of them spinning
/// out of step is more distracting than the empty tiles were — and Apple's own
/// grids use a moving sheen over the eventual shape instead. It respects Reduce
/// Motion, where the placeholder simply stays still.
///
/// Nothing on the Mac, where a sheen sweeping across a page of tiles is a
/// web loading idiom: the placeholder stays a still quaternary fill, and the
/// screens put a small `ProgressView` in the toolbar for "still loading".
struct ShimmerOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var sweeping = false

    /// A white band at 8% is a sheen on a near-black tile and nothing at all on
    /// a light grey one, so the sweep is pitched against whichever it is
    /// crossing.
    private var sheen: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .white.opacity(0.65)
    }

    var body: some View {
        #if os(macOS)
        Color.clear.allowsHitTesting(false)
        #else
        sweep
        #endif
    }

    private var sweep: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let band = max(width * 0.55, 48)
            LinearGradient(
                colors: [.clear, sheen, .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: band)
            .offset(x: sweeping ? width : -band)
            .animation(
                reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false),
                value: sweeping
            )
            .onAppear { sweeping = true }
        }
        .allowsHitTesting(false)
        .opacity(reduceMotion ? 0 : 1)
    }
}
