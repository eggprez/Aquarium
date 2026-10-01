//  Offline downloads — the port of downloads.rs plus the batch queue that lived
//  in playback.ts.
//
//  Transfers run on a background URLSession, so a season keeps downloading with
//  the app suspended and survives being swapped out. Each download owns a folder
//  under Application Support holding the media file and a meta.json describing
//  it; that file is the only source of truth, which is what lets an interrupted
//  transfer be replayed after a relaunch.
//
//  Not built for tvOS: it has no storage a large file can be kept in — the
//  system evicts app data whenever it wants to — so the whole feature is
//  compiled out there rather than offered and then quietly broken.

import AVFoundation
import Foundation
import Network
import Observation
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if !os(tvOS)

struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, downloading, complete, error, canceled
    }

    var itemId: String
    /// "The Bear S01E03 · System" — what the row shows.
    var title: String
    var name: String
    var type: String?
    var series: String?
    var seriesId: String?
    var season: Int?
    var seasonId: String?
    var episode: Int?
    var year: Int?
    var runTimeTicks: Int64 = 0
    var quality: String = ""
    var fileName: String = ""
    /// How this was fetched. Old records predate the choice and were all
    /// progressive single-file transfers.
    var transport: JellyfinClient.DownloadTransport = .file
    /// Where an HLS download landed, relative to the app's home directory.
    /// AVFoundation picks the location for a downloaded stream and it must be
    /// addressed relatively — the absolute path changes between launches.
    var hlsPath: String?
    /// How far an HLS download has got, as a share of its duration. Segments
    /// arrive as time rather than as a share of a size nobody knows.
    var loadedFraction: Double?
    /// Kept so a failed transfer can be replayed without the item it came from.
    var sourceURL: String = ""
    var estimatedBytes: Int64?
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var status: Status = .queued
    var errorMessage: String?
    /// Watch state recorded locally while offline, pushed back when a server is
    /// reachable again.
    var positionTicks: Int64 = 0
    var played: Bool = false
    /// True once the local state has been written back to Jellyfin.
    var progressSynced: Bool = true
    /// Watched was taken off here and the server hasn't been told. A resume
    /// point alone can't say it — the server keeps its tick through a stopped
    /// report — so the sync un-marks it explicitly.
    var unplayedPending: Bool = false
    /// Bumped on every local change to the watch state, so a sync can tell
    /// whether what it sent is still what the record says.
    var progressRevision: Int = 0
    /// How many times this has arrived as a file that wouldn't open. See
    /// `verifyAndComplete` — one such arrival is worth another try, two is a
    /// fault worth reporting.
    var verifyFailures: Int = 0
    /// How many times in a row this has been put back in the queue by the app
    /// itself rather than by a tap — after a dropped connection, a stall, a
    /// server that went away mid-transfer. Reset whenever an attempt actually
    /// moves the transfer forward, so a download on a bad link gets as many
    /// goes as it needs, and one that fails the same way every time stops
    /// after a few. See `scheduleAutomaticRetry`.
    var autoRetries: Int = 0
    /// This item's own artwork: an episode's still, a film's poster. Never
    /// borrowed from a parent — the two below are what a parent's artwork is
    /// for, and a row that quietly substituted one for the other is why every
    /// episode of a show used to look identical in the downloads list.
    var imageURL: String?
    /// The poster of the season an episode belongs to, where it has one.
    var seasonImageURL: String?
    var seriesImageURL: String?
    var createdAt: Date = .init()

    // A song or an audiobook — the album it came from, who made it, and its
    // place on the sleeve. Optional so records written before music existed
    // still decode.
    var album: String?
    var albumId: String?
    var artist: String?
    var track: Int?
    var disc: Int?

    /// Whether this is something the music player opens.
    var isAudio: Bool { type == "Audio" || type == "AudioBook" }

    /// The record as an item, for the music player and the rows that draw
    /// one: enough of the song to play it, name it and find its cover on
    /// disk, with no server behind any of it.
    var asItem: BaseItem {
        var item = BaseItem()
        item.Id = itemId
        item.Name = name
        item.type = type
        item.MediaType = "Audio"
        item.Album = album
        item.AlbumId = albumId
        item.AlbumArtist = artist
        if let artist, !artist.isEmpty { item.Artists = [artist] }
        item.IndexNumber = track
        item.ParentIndexNumber = disc
        item.RunTimeTicks = runTimeTicks
        item.ProductionYear = year
        item.UserData = UserData(PlaybackPositionTicks: positionTicks, Played: played)
        // The cover, on disk where it has been kept. Read back through the
        // image tags so `MusicArt` needs no special case: a `file:` URL in the
        // tag slot is decoded by the same loader as a server one.
        if let art = artURL { item.ExternalLogoURL = art }
        return item
    }

    var id: String { itemId }

    var isEpisode: Bool { type == "Episode" || (series != nil && type != "Movie") }

    /// Decoded key by key, every one of them optional.
    ///
    /// Swift's own `init(from:)` would be shorter and is a trap here: it does
    /// *not* fall back to a property's default value when a key is missing, it
    /// throws. `meta.json` is the only record that a download exists — nothing
    /// else knows about it — and `loadRecords` drops a folder whose meta.json
    /// won't decode. So one field added to this struct in a later version is
    /// enough to make every download written by the previous one disappear
    /// without trace, which is exactly what it looks like from the outside: a
    /// transfer that was 86% done, an app relaunch, and an empty list.
    ///
    /// Only `itemId` is genuinely required, because a record that doesn't know
    /// what it is is not a record.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decode(String.self, forKey: .itemId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? itemId
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? title
        type = try c.decodeIfPresent(String.self, forKey: .type)
        series = try c.decodeIfPresent(String.self, forKey: .series)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        season = try c.decodeIfPresent(Int.self, forKey: .season)
        seasonId = try c.decodeIfPresent(String.self, forKey: .seasonId)
        episode = try c.decodeIfPresent(Int.self, forKey: .episode)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: .runTimeTicks) ?? 0
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        transport = try c.decodeIfPresent(JellyfinClient.DownloadTransport.self, forKey: .transport) ?? .file
        hlsPath = try c.decodeIfPresent(String.self, forKey: .hlsPath)
        loadedFraction = try c.decodeIfPresent(Double.self, forKey: .loadedFraction)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        estimatedBytes = try c.decodeIfPresent(Int64.self, forKey: .estimatedBytes)
        receivedBytes = try c.decodeIfPresent(Int64.self, forKey: .receivedBytes) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        positionTicks = try c.decodeIfPresent(Int64.self, forKey: .positionTicks) ?? 0
        played = try c.decodeIfPresent(Bool.self, forKey: .played) ?? false
        progressSynced = try c.decodeIfPresent(Bool.self, forKey: .progressSynced) ?? true
        unplayedPending = try c.decodeIfPresent(Bool.self, forKey: .unplayedPending) ?? false
        progressRevision = try c.decodeIfPresent(Int.self, forKey: .progressRevision) ?? 0
        verifyFailures = try c.decodeIfPresent(Int.self, forKey: .verifyFailures) ?? 0
        autoRetries = try c.decodeIfPresent(Int.self, forKey: .autoRetries) ?? 0
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        seasonImageURL = try c.decodeIfPresent(String.self, forKey: .seasonImageURL)
        seriesImageURL = try c.decodeIfPresent(String.self, forKey: .seriesImageURL)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .init()
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        disc = try c.decodeIfPresent(Int.self, forKey: .disc)
    }

    /// The memberwise initialiser, which writing one of our own above takes
    /// away.
    init(
        itemId: String,
        title: String,
        name: String,
        type: String? = nil,
        series: String? = nil,
        seriesId: String? = nil,
        season: Int? = nil,
        seasonId: String? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        runTimeTicks: Int64 = 0,
        quality: String = "",
        fileName: String = "",
        transport: JellyfinClient.DownloadTransport = .file,
        sourceURL: String = "",
        estimatedBytes: Int64? = nil,
        positionTicks: Int64 = 0,
        played: Bool = false,
        imageURL: String? = nil,
        seasonImageURL: String? = nil,
        seriesImageURL: String? = nil,
        album: String? = nil,
        albumId: String? = nil,
        artist: String? = nil,
        track: Int? = nil,
        disc: Int? = nil
    ) {
        self.itemId = itemId
        self.title = title
        self.name = name
        self.type = type
        self.series = series
        self.seriesId = seriesId
        self.season = season
        self.seasonId = seasonId
        self.episode = episode
        self.year = year
        self.runTimeTicks = runTimeTicks
        self.quality = quality
        self.fileName = fileName
        self.transport = transport
        self.sourceURL = sourceURL
        self.estimatedBytes = estimatedBytes
        self.positionTicks = positionTicks
        self.played = played
        self.imageURL = imageURL
        self.seasonImageURL = seasonImageURL
        self.seriesImageURL = seriesImageURL
        self.album = album
        self.albumId = albumId
        self.artist = artist
        self.track = track
        self.disc = disc
    }

    /// How far along, against the best figure available: the length the server
    /// gave where there is one, and this app's estimate otherwise.
    ///
    /// A transcode has no length — the server cannot know how big the file is
    /// until it has finished encoding it — so for most downloads the
    /// denominator is `estimatedBytes`, which is a projection from the bitrate
    /// the encode was asked for (see `JellyfinClient.estimateDownloadSize`). It
    /// is close, not exact, and a transfer that runs past it holds at the full
    /// bar while the byte count carries on: an encode is variable bitrate and
    /// the last word on its size is the file itself.
    ///
    /// Nil only when there is nothing at all to measure against — no length and
    /// nothing to estimate from — which is the one case the bar can't show a
    /// share of.
    var fraction: Double? {
        // An HLS download knows exactly where it is: the share of the running
        // time it has segments for. No estimate involved.
        if let loadedFraction { return min(1, max(0, loadedFraction)) }
        let total = totalBytes > 0 ? totalBytes : (estimatedBytes ?? 0)
        guard total > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(total))
    }

    /// The denominator `fraction` used, and whether it was a real length or an
    /// estimate — what the row writes next to the bar.
    ///
    /// For a stream the two halves of the row used to disagree with each
    /// other: the percentage came from time (segments loaded over running
    /// time) while the total beside it was the bitrate projection made before
    /// the transfer started, so "40% · 300 MiB / ~1.2 GiB" was an ordinary
    /// thing to see, with the bytes saying 25% and the bar saying 40. Once
    /// enough has arrived to project from, the total is instead what the bytes
    /// so far imply at this fraction — which by construction makes the
    /// percentage, the bar and the bytes one figure, and converges on the real
    /// size as the encode goes on. The bitrate estimate only covers the first
    /// moments, before there is anything to project from.
    var progressTotal: (bytes: Int64, estimated: Bool)? {
        if totalBytes > 0 { return (totalBytes, false) }
        if let loadedFraction, loadedFraction >= Self.projectableFraction, receivedBytes > 0 {
            let projected = Int64((Double(receivedBytes) / loadedFraction).rounded())
            return (max(projected, receivedBytes), true)
        }
        if let estimate = estimatedBytes, estimate > 0 { return (estimate, true) }
        return nil
    }

    /// How much of a stream has to have arrived before its size is projected
    /// from what came rather than from the bitrate it was asked for. One
    /// segment out of six hundred is not a sample; a few percent is.
    static let projectableFraction = 0.03

    /// How far through this you are, for the bar across the bottom of a tile.
    /// Nothing to draw for something untouched or already finished.
    var watchedFraction: Double? {
        guard !played, runTimeTicks > 0, positionTicks > 0 else { return nil }
        return min(1, Double(positionTicks) / Double(runTimeTicks))
    }

    var resumeSeconds: Double {
        // A file watched all the way through would otherwise "resume" in its
        // closing seconds; start it from the top instead. A book is done by
        // the server's rule, the watch's too: the last 90% of a twenty-hour
        // book is two hours, not its closing seconds.
        if played { return 0 }
        if type == "AudioBook" {
            if BookProgress.isFinished(positionTicks: positionTicks, runTimeTicks: runTimeTicks) { return 0 }
        } else if runTimeTicks > 0, Double(positionTicks) / Double(runTimeTicks) > 0.9 {
            return 0
        }
        return Double(positionTicks) / 10_000_000
    }
}

/// A download waiting its turn, held only in memory but persisted alongside the
/// records so closing the app mid-season doesn't silently drop what hadn't
/// started yet.
struct QueuedDownload: Codable, Hashable, Sendable, Identifiable {
    var itemId: String
    var title: String
    var series: String?
    var season: Int?
    var episode: Int?
    var quality: String
    /// A replay of something that already failed, rather than a first attempt.
    var isRetry: Bool = false
    /// Not before this. Set on a retry the app scheduled for itself, so a
    /// transfer that just lost its connection waits a little before asking
    /// again rather than hammering a link that is still down. Nil means now.
    var retryAt: Date?
    /// Why the app put this back in the queue, in the words the row shows.
    var reason: String?
    /// The item's type — "Audio", "AudioBook", "Episode" — so the Music and
    /// Audiobooks tabs can say how much of the queue is theirs without
    /// looking every entry up. Nil on entries queued before this was kept.
    var type: String?
    var id: String { itemId }

    /// Whether the pump may start this yet.
    func isDue(at now: Date) -> Bool {
        guard let retryAt else { return true }
        return retryAt <= now
    }
}

/// A transfer, as the session it runs in and its number there. The file
/// session and the two stream sessions each number their own tasks from one,
/// so the number alone can name three different downloads at once.
struct DownloadTaskKey: Hashable, Sendable {
    var session: String
    var id: Int

    init(_ session: URLSession, _ task: URLSessionTask) {
        self.session = session.configuration.identifier ?? ""
        self.id = task.taskIdentifier
    }
}

@MainActor
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    /// What a transfer did when it failed, in full, for Console. The row on
    /// screen gets the short version.
    /// The bundle identifier, which every persistent identifier below hangs
    /// off so a change to it is made in one place (the target's build
    /// settings) and nowhere else.
    nonisolated static let bundleID = Bundle.main.bundleIdentifier ?? "Aquarium"

    nonisolated static let log = Logger(subsystem: bundleID, category: "downloads")

    private(set) var records: [DownloadRecord] = []
    private(set) var queue: [QueuedDownload] = [] {
        didSet { queuedIds = nil }
    }
    /// The ids in `queue`, worked out when first asked after a change.
    @ObservationIgnored private var queuedIds: Set<String>?
    /// Bumped whenever `records` changes, for things that build something
    /// from the list and want to know when to build it again — see
    /// `OfflineMusic.songs`. Not observed itself: readers observe `records`.
    @ObservationIgnored private(set) var recordsRevision = 0
    /// The same, for records that aren't songs or audiobooks. The Downloads
    /// page groups films and episodes into shelves, and was regrouping them —
    /// a pass over every record — each time a song finished.
    @ObservationIgnored private(set) var videoRevision = 0
    /// Where each record is in `records`, by item id — counted from the *end*
    /// of the list. New records go in at the front, and counted from the front
    /// that moved every other record's place: the whole index was rebuilt for
    /// each song of a library being queued. `record(for:)` is asked
    /// from inside view bodies — once per song row, per render — and from
    /// loops over whole seasons, and it was a scan of every download each time.
    @ObservationIgnored private var recordIndex: [String: Int] = [:]

    /// What a running transfer has fetched so far, twice a second.
    ///
    /// Kept apart from `records` because Observation tracks by property: every
    /// screen that reads `records` — the downloads list, the sidebar footer,
    /// every song row, a detail page's download button — used to redraw twice
    /// a second per transfer, to show a number only the transfer's own row
    /// draws. `records` now changes when a download's state does, and when its
    /// byte count is written to disk every ten seconds; the row reads this
    /// through `live(_:)`.
    private(set) var liveProgress: [String: LiveProgress] = [:]

    struct LiveProgress: Equatable {
        var received: Int64
        var total: Int64
        var fraction: Double?
    }

    /// A record with its transfer's latest counts laid over it.
    func live(_ record: DownloadRecord) -> DownloadRecord {
        guard let progress = liveProgress[record.itemId] else { return record }
        var out = record
        out.receivedBytes = progress.received
        out.totalBytes = progress.total
        out.loadedFraction = progress.fraction
        return out
    }

    private var tasks: [DownloadTaskKey: String] = [:]  // session + task id → item id
    /// Tasks cancelled on purpose whose callbacks have yet to arrive. They
    /// answer to no item: the one they ran for may have been deleted, or be
    /// running again under a new task whose slot and status a late
    /// "cancelled" would otherwise take.
    @ObservationIgnored
    private var retiredTasks: Set<DownloadTaskKey> = []
    private var active: Set<String> = []
    private var pendingItems: [String: BaseItem] = [:]  // queued item id → the item
    /// A cancel that arrived while `resolveThenStart` was still asking the
    /// server for the item: there is no task and no record yet for `cancel`
    /// to act on, so without this, the fetch completing would start the
    /// transfer the person had just called off.
    private var cancelledResolves: Set<String> = []

    /// How often a running transfer is allowed to redraw and, separately, how
    /// often it writes its byte count to disk.
    nonisolated private static let progressPublishInterval: TimeInterval = 0.5

    /// When each task's progress last crossed to the main actor. Progress
    /// arrives once per chunk written — thousands of callbacks for one film —
    /// and the throttle used to be applied after the hop, so every one of
    /// them was still a task and a main-actor enqueue. Checked here, in the
    /// delegate, under a lock, only the ones worth drawing make the trip.
    nonisolated private static let progressHops = OSAllocatedUnfairLock(initialState: [DownloadTaskKey: Date]())

    nonisolated private static func progressHopDue(_ task: DownloadTaskKey) -> Bool {
        let now = Date()
        return progressHops.withLock { hops in
            if let last = hops[task], now.timeIntervalSince(last) < progressPublishInterval { return false }
            hops[task] = now
            return true
        }
    }
    private static let progressPersistInterval: TimeInterval = 10

    @ObservationIgnored
    private var lastPersistAt: [String: Date] = [:]

    /// Bytes a stream download had already fetched before the task now
    /// running it was started. An `AVAssetDownloadTask` resumed from its
    /// package counts from zero; the record counts from the beginning.
    @ObservationIgnored
    private var streamByteBase: [String: Int64] = [:]

    /// When each running transfer last produced anything at all — written on
    /// every callback that reaches the main actor, which is at most twice a
    /// second (see `progressHopDue`). What it answers is whether the transfer
    /// is moving at all. See `sweepStalledTransfers`.
    @ObservationIgnored
    private var activityAt: [String: Date] = [:]

    /// The byte count each running task reported at the last sweep, so a
    /// transfer whose callbacks this process never saw can still be told from
    /// one that has genuinely stopped.
    @ObservationIgnored
    private var lastSeenBytes: [String: Int64] = [:]

    /// How long a transfer may go without a byte before it is called stalled,
    /// and how often that is checked.
    ///
    /// This is the fault behind a download that sits at 86% and will not go on:
    /// nothing was watching for it, so the slot stayed claimed, the queue
    /// behind it stayed stopped, and the only way out was to force-quit the
    /// app — which is not a way out, because the record was mid-transfer and
    /// there was nothing on screen offering to pick it back up.
    private static let stallLimit: TimeInterval = 180
    private static let stallSweepInterval: TimeInterval = 60

    /// How many times the app will put a transfer back in the queue on its own
    /// before it stops and asks, and how long it waits before each go. The
    /// waits climb because the second failure in a row is evidence the first
    /// one wasn't a blip; the count resets whenever an attempt gets somewhere,
    /// so a long download over a link that keeps dropping is not bounded by
    /// this — only one that fails the same way from the same place is.
    private static let maxAutomaticRetries = 5
    private static let retryDelays: [TimeInterval] = [5, 15, 45, 120, 300]
    /// How much an attempt has to have fetched before it counts as having
    /// got somewhere. A task's byte count starts from zero on each attempt, so
    /// this is per attempt: a resume that pulls one more segment and dies is
    /// not progress, a resume that pulls a few megabytes is.
    private static let progressWorthResetting: Int64 = 4 << 20
    /// How long a transfer waiting for the network to come back is left
    /// before it is tried anyway, in case the path monitor never says so.
    private static let networkWaitFallback: TimeInterval = 90

    /// Whether the device currently has a route to anything at all. Not the
    /// same as `JellyfinClient.isOffline`, which is about the server answering;
    /// this is the radio. The stall sweep stops counting while it is down —
    /// three minutes without a byte on a phone that has walked out of Wi-Fi
    /// range is not a stalled transfer, it is a phone out of range — and the
    /// queue holds its retries until it is back.
    @ObservationIgnored
    private var pathIsSatisfied = true

    @ObservationIgnored
    private let pathMonitor = NWPathMonitor()

    /// Wakes the pump when the earliest scheduled retry falls due.
    @ObservationIgnored
    private var retryWake: Task<Void, Never>?

    /// Transfers the stall sweep has cancelled on purpose so they can be put
    /// back in the queue, keyed by the reason. The cancellation arrives at
    /// `didCompleteWithError` like any other failure, and this is what tells it
    /// apart from one the user asked for.
    @ObservationIgnored
    private var retryingAfterCancel: [String: String] = [:]

    private let prefs = Preferences.shared

    /// Never fill the volume to the last byte: a download that lands on a disk
    /// with nothing left takes the rest of the system down with it.
    static let spaceHeadroom: Int64 = 1 << 30

    @ObservationIgnored
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "\(Self.bundleID).downloads")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        // Left open here and decided per transfer instead: a session's
        // configuration is fixed at the moment it is built, and this one is
        // built once for the lifetime of the process, so reading the preference
        // here meant turning Wi-Fi-only on or off did nothing until the next
        // launch. See `start`.
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// The session that fetches HLS downloads.
    ///
    /// Separate from the one above because it has to be: AVFoundation owns the
    /// whole transfer for a stream — it reads the manifest, fetches every
    /// segment, and stores the result where it chooses. What that buys is the
    /// thing the progressive endpoint could never give: a download that either
    /// arrives whole or fails. There is no silent short answer, because the
    /// manifest says how many segments there are.
    ///
    /// Two of them, because whether a transfer may use cellular data is fixed
    /// on the session's configuration and cannot be set per task the way it
    /// can on a plain download request. Before this, "Wi-Fi only" applied to
    /// file downloads and quietly not to streams — which are most downloads —
    /// so a phone that stepped out of Wi-Fi range carried on over cellular.
    /// The cellular one keeps the identifier the single session had, so the
    /// system hands back any transfer that was running under it.
    @ObservationIgnored
    private lazy var assetSession: AVAssetDownloadURLSession = makeAssetSession(
        identifier: "\(Self.bundleID).streamdownloads", allowsCellular: true
    )

    @ObservationIgnored
    private lazy var wifiAssetSession: AVAssetDownloadURLSession = makeAssetSession(
        identifier: "\(Self.bundleID).streamdownloads.wifi", allowsCellular: false
    )

    private var assetSessions: [AVAssetDownloadURLSession] { [assetSession, wifiAssetSession] }

    private func makeAssetSession(identifier: String, allowsCellular: Bool) -> AVAssetDownloadURLSession {
        let cfg = URLSessionConfiguration.background(withIdentifier: identifier)
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = allowsCellular
        // One connection, so segments are asked for in order.
        //
        // Left to itself AVFoundation opens several at once and pulls segments
        // out of order — 2, 3, 1, 4 — which is harmless against a static host
        // and ruinous against this one: Jellyfin encodes a segment on demand,
        // and a request for one outside the range the running encode covers
        // kills that encode and starts another at the new offset. Parallel
        // fetching of an on-demand transcode is a queue of jobs killing each
        // other. In order, it is one encode read straight through.
        cfg.httpMaximumConnectionsPerHost = 1
        // A segment of a transcode is not sent until the server has encoded
        // it, and when the client has caught up with the encoder each request
        // sits open waiting for the next one to be written. On a server that
        // encodes slowly that wait can outlast the default minute, and a
        // timeout there fails a transfer that was doing exactly what it
        // should. Three minutes matches the stall limit: past that the sweep
        // has an opinion anyway.
        cfg.timeoutIntervalForRequest = Self.stallLimit
        return AVAssetDownloadURLSession(
            configuration: cfg,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
    }

    /// Every task the three sessions are carrying, each with the session it
    /// runs in — see `DownloadTaskKey`.
    private func everyTask() async -> [(session: URLSession, task: URLSessionTask)] {
        var out: [(session: URLSession, task: URLSessionTask)] = []
        for s in [session] + assetSessions.map({ $0 as URLSession }) {
            for task in await s.allTasks { out.append((s, task)) }
        }
        return out
    }

    /// The completion handlers the system hands over when it relaunches the
    /// app to deliver a session's background events, one per session: all
    /// three can be woken at once, and a single slot lost all but the last.
    @ObservationIgnored
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        backgroundCompletionHandlers[identifier] = handler
    }

    private override init() {
        super.init()
        records = Self.loadRecords()
        rebuildRecordIndex()
        queue = Self.loadQueue()
        pendingItems = Self.loadPendingItems()
        // Anything the last run left mid-transfer is picked back up; the
        // background session may already be doing it, in which case adopting it
        // here is what advances the queue when it lands.
        Task { await self.reconcile() }
        Task { await self.watchForStalls() }
        watchConcurrency()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.pathChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "aquarium.downloads.path"))
        // What `persistQueue` held back goes to disk before the app can be
        // suspended and reclaimed.
        #if canImport(UIKit)
        let backgrounded = UIApplication.didEnterBackgroundNotification
        #else
        let backgrounded = NSApplication.willTerminateNotification
        #endif
        NotificationCenter.default.addObserver(forName: backgrounded, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DownloadManager.shared.flushPersisted() }
        }
        // Everything downloaded before artwork was kept locally, filled in the
        // next time there is a network to fill it from. One pass, cheapest
        // priority, and each picture is skipped the moment it is found on disk.
        let existing = records
        Task.detached(priority: .background) {
            for record in existing { await DownloadArtwork.cache(record) }
        }
    }

    // MARK: - Storage layout

    static var root: URL {
        _ = rootPrepared
        let base = rootPath
        if !FileManager.default.fileExists(atPath: base.path) { prepareRoot() }
        return base
    }

    /// Once a launch, whether or not the directory was already there: the
    /// exclusion used to be set only by whoever created it, and `freeSpace`
    /// got there first on a fresh install and created it without.
    private nonisolated static let rootPrepared: Void = prepareRoot()

    private nonisolated static func prepareRoot() {
        let base = rootPath
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Nothing under here belongs in a backup: the media is excluded
        // file by file when it lands, but the metadata, partial files and
        // resume data beside it used to ride along with the container.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = base
        try? url.setResourceValues(values)
    }

    /// Where the downloads live, as an address and nothing more.
    ///
    /// `root` and `folder(for:)` make the directory as a side effect of being
    /// asked where it is, which is right when something is about to be written
    /// there and wrong for the artwork lookups in `DownloadArtwork`: those are
    /// read from inside view bodies, several times per row, and a path helper
    /// that touches the disk on every draw is not one.
    nonisolated static var rootPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // "FellyJin" is the pre-Aquarium name, kept so existing downloads are found
            .appendingPathComponent("FellyJin/Downloads", isDirectory: true)
    }

    /// The folder name for an item. A Jellyfin id is 32 hex characters and is
    /// used as is; an id from anywhere less trustworthy is escaped so it can
    /// only ever name one folder directly under the root.
    nonisolated static func folderName(for itemId: String) -> String {
        let name = JellyfinClient.pathId(itemId)
        return name.isEmpty ? "item" : name
    }

    nonisolated static func folderPath(for itemId: String) -> URL {
        rootPath.appendingPathComponent(folderName(for: itemId), isDirectory: true)
    }

    static func folder(for itemId: String) -> URL {
        let url = root.appendingPathComponent(folderName(for: itemId), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What a sign-out owes the downloads: every task the sessions are still
    /// running carries the old token in its request, and the resume data of a
    /// stopped file download has the same request archived inside it. Both
    /// are stopped and dropped; finished downloads stay, since they are the
    /// user's files and carry no credentials.
    func endSession() {
        for itemId in Set(tasks.values) {
            cancelTasks(for: itemId, keepingProgress: false)
            forgetProgressThrottle(itemId)
        }
        active.removeAll()
        retryingAfterCancel.removeAll()
        isPaused = false
        // The queue was built against the old server, and a retry replays the
        // URL it was first started with — under the next account's token.
        queue.removeAll()
        pendingItems.removeAll()
        persistQueue()
        persistPendingItems()
        retryWake?.cancel()
        retryWake = nil
        // Settled here rather than by the cancels coming back, which are
        // ignored (see `retiredTasks`); left as running, the stall sweep would
        // put them straight back in the queue.
        for rec in records where rec.status == .downloading || rec.status == .queued {
            var stopped = rec
            stopped.status = .canceled
            stopped.errorMessage = nil
            save(stopped)
        }
        let fm = FileManager.default
        if let folders = try? fm.contentsOfDirectory(at: Self.rootPath, includingPropertiesForKeys: nil) {
            for folder in folders {
                try? fm.removeItem(at: folder.appendingPathComponent("resume.data"))
            }
        }
    }

    func mediaURL(for record: DownloadRecord) -> URL? {
        guard record.status == .complete else { return nil }
        if let path = record.hlsPath {
            let url = Self.hlsURL(forRelativePath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard !record.fileName.isEmpty else { return nil }
        let url = Self.folder(for: record.itemId).appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A downloaded stream lives where AVFoundation put it, and only the path
    /// relative to the app's home directory survives a relaunch — the container
    /// itself is moved by the system between launches.
    nonisolated static func hlsURL(forRelativePath path: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }

    /// Every record on disk, read as the manager is first touched — which is
    /// during the first frame, so it stays synchronous: a list that briefly
    /// read as empty would be believed by the offline screen and by the
    /// background session's own events, which can arrive at launch.
    ///
    /// Made cheap instead. The meta files are read and decoded side by side
    /// rather than one after another, and checking a finished file no longer
    /// creates its folder on the way (see `folderPath(for:)`).
    private static func loadRecords() -> [DownloadRecord] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: rootPath, includingPropertiesForKeys: nil),
              !dirs.isEmpty
        else { return [] }
        var found = [DownloadRecord?](repeating: nil, count: dirs.count)
        found.withUnsafeMutableBufferPointer { slots in
            // Each iteration writes only its own slot.
            nonisolated(unsafe) let slots = slots
            DispatchQueue.concurrentPerform(iterations: dirs.count) { index in
                let meta = dirs[index].appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: meta),
                      let record = try? JSONDecoder().decode(DownloadRecord.self, from: data)
                else { return }
                slots[index] = verified(record)
            }
        }
        return found.compactMap { $0 }.sorted { $0.createdAt > $1.createdAt }
    }

    /// A record claiming to be finished, checked against the disk it claims to
    /// be on. One whose file has gone is a failure with a Retry on it, not a
    /// tile that looks downloaded and does nothing at all when tapped — which
    /// is what a missing file used to be, because the only thing that noticed
    /// was the player, and the player never opened to say so.
    private nonisolated static func verified(_ record: DownloadRecord) -> DownloadRecord {
        guard record.status == .complete else { return record }
        let present: Bool
        if let path = record.hlsPath {
            present = FileManager.default.fileExists(atPath: hlsURL(forRelativePath: path).path)
        } else {
            present = !record.fileName.isEmpty && FileManager.default.fileExists(
                atPath: folderPath(for: record.itemId).appendingPathComponent(record.fileName).path
            )
        }
        guard !present else { return record }
        var broken = record
        broken.status = .error
        broken.errorMessage = "The file is no longer on this device"
        broken.receivedBytes = 0
        return broken
    }

    /// The same finding, from the one other place it surfaces: something tapped
    /// a download whose file has since gone.
    func markMissing(_ itemId: String) {
        guard var rec = record(for: itemId), rec.status == .complete else { return }
        rec.status = .error
        rec.errorMessage = "The file is no longer on this device"
        rec.receivedBytes = 0
        save(rec)
    }

    /// `toDisk: false` updates what the screens show without re-encoding
    /// meta.json — for the byte counts of a running transfer, which change
    /// constantly and mean nothing after a relaunch.
    private func save(_ record: DownloadRecord, toDisk: Bool = true) {
        if toDisk {
            // Encoded here, written elsewhere: the write is a file created,
            // filled and renamed, and a draining music library asks for three
            // of them per song. In order, on one queue, so the last state
            // saved is the one left on disk.
            let meta = Self.folder(for: record.itemId).appendingPathComponent("meta.json")
            if let data = try? JSONEncoder().encode(record) {
                Self.metaWriter.async { try? data.write(to: meta, options: .atomic) }
            }
        }
        recordsRevision &+= 1
        if !record.isAudio { videoRevision &+= 1 }
        if let i = index(of: record.itemId) {
            records[i] = record
        } else {
            records.insert(record, at: 0)
            // Counted from the end, so that this — the common change — moves
            // nobody else's place. See `recordIndex`.
            recordIndex[record.itemId] = records.count - 1
        }
        // A transfer that has stopped — finished, failed, cancelled back to
        // the queue — is described by its record again.
        if record.status != .downloading { liveProgress[record.itemId] = nil }
    }

    /// Where meta.json files are written. Drained before the app is put away
    /// — see `flushPersisted`.
    private nonisolated static let metaWriter = DispatchQueue(label: "Aquarium.downloads.meta", qos: .utility)

    private func index(of itemId: String) -> Int? {
        guard let fromEnd = recordIndex[itemId] else {
            return records.firstIndex { $0.itemId == itemId }
        }
        let i = records.count - 1 - fromEnd
        guard i >= 0, i < records.count, records[i].itemId == itemId else {
            return records.firstIndex { $0.itemId == itemId }
        }
        return i
    }

    private func rebuildRecordIndex() {
        let last = records.count - 1
        recordIndex = Dictionary(
            records.enumerated().map { ($0.element.itemId, last - $0.offset) }, uniquingKeysWith: { first, _ in first }
        )
    }

    private nonisolated static let queueKey = "download_queue"

    private static func loadQueue() -> [QueuedDownload] {
        guard let data = UserDefaults.standard.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([QueuedDownload].self, from: data)) ?? []
    }

    /// Held up while a batch is being added: a season is a hundred calls to
    /// `enqueue`, and writing the whole queue and every item it carries once per
    /// episode is a hundred rewrites of a file that only the last one matters.
    @ObservationIgnored
    private var isBatching = false

    /// Marks the queue for writing. Written a second later, once, however
    /// many changes land in between — see `flushPersisted`.
    private func persistQueue() {
        guard !isBatching else { return }
        queueNeedsWrite = true
        schedulePersist()
    }

    // Everything waiting on a download is written a second after the last
    // change rather than on every one. As a queued season drains, each start
    // used to re-encode and rewrite the queue and every item still waiting:
    // a hundred writes of a file that only the last one mattered for. The
    // write can't be lost to the app being put away — going to the background
    // writes it at once — only to a crash inside that second, which the
    // relaunch's reconcile already copes with.

    @ObservationIgnored private var queueNeedsWrite = false
    @ObservationIgnored private var pendingItemsNeedWrite = false
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    private func schedulePersist() {
        guard persistTask == nil else { return }
        // A long queue is a big file, and a second apart is a lot of big
        // files; a whole music library draining gets five.
        let wait: Duration = queue.count > 200 ? .seconds(5) : .seconds(1)
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flushPersisted(inline: false)
        }
    }

    /// The write before this one, so that two of them can't land out of order.
    @ObservationIgnored private var persistWrite: Task<Void, Never>?

    /// Writes whatever is marked.
    ///
    /// `inline` is for the app being put away, where the write has to have
    /// happened by the time this returns. Otherwise the encoding is done off
    /// the main actor: with a music library queued this is thousands of items,
    /// media sources and all, and it was a hitch in every scroll and every
    /// tap, once a second, for as long as the queue took to drain.
    func flushPersisted(inline: Bool = true) {
        if inline { Self.metaWriter.sync {} }
        persistTask?.cancel()
        persistTask = nil
        let queue = queueNeedsWrite ? self.queue : nil
        let items = pendingItemsNeedWrite ? pendingItems : nil
        queueNeedsWrite = false
        pendingItemsNeedWrite = false
        guard queue != nil || items != nil else { return }
        if inline {
            // Whatever is still being written is older than this, and must
            // not land after it.
            persistWrite?.cancel()
            persistWrite = nil
            Self.write(queue: queue, items: items)
            return
        }
        let earlier = persistWrite
        persistWrite = Task.detached(priority: .utility) {
            await earlier?.value
            guard !Task.isCancelled else { return }
            Self.write(queue: queue, items: items)
        }
    }

    private nonisolated static func write(queue: [QueuedDownload]?, items: [String: BaseItem]?) {
        if let queue, let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: queueKey)
        }
        if let items {
            if let data = try? JSONEncoder().encode(items) {
                try? data.write(to: pendingItemsFile, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: pendingItemsFile)
            }
        }
    }

    // The queue is only half of what a waiting download needs: the URL it will
    // be fetched from is built out of the item itself, and until now that item
    // was held in memory only. A relaunch — after a crash, or after the system
    // reclaimed a suspended app — brought the queue back with nothing to build
    // URLs from, and every entry was discarded on sight. It goes to disk with
    // the queue now, trimmed of the fields only a detail page reads.

    /// By `rootPath`: the directory exists by the time anything is queued,
    /// and this is read off the main actor.
    private nonisolated static var pendingItemsFile: URL {
        rootPath.appendingPathComponent("queued-items.json")
    }

    private static func loadPendingItems() -> [String: BaseItem] {
        guard let data = try? Data(contentsOf: pendingItemsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: BaseItem].self, from: data)) ?? [:]
    }

    private func persistPendingItems() {
        guard !isBatching else { return }
        pendingItemsNeedWrite = true
        schedulePersist()
    }

    /// Everything a download URL and a record are built from, and nothing a
    /// hundred queued episodes should be carrying to disk.
    private static func trimmed(_ item: BaseItem) -> BaseItem {
        var out = item
        out.Overview = nil
        out.Taglines = nil
        out.Genres = nil
        out.People = nil
        out.Studios = nil
        out.BackdropImageTags = nil
        return out
    }

    // MARK: - Free space

    /// Free bytes on the volume downloads live on, or nil when it can't be told.
    /// Nonisolated, so a screen can ask off the main thread.
    nonisolated static func freeSpace() -> Int64? {
        _ = rootPrepared
        let base = rootPath
        let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        let legacy = try? FileManager.default.attributesOfFileSystem(forPath: base.path)
        return (legacy?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Total estimated size of a set of items at one quality, or nil when none
    /// of them can be estimated.
    static func estimateTotal(_ items: [BaseItem], quality: DownloadQuality) -> Int64? {
        var sum: Int64 = 0
        var known = false
        for item in items {
            guard let e = JellyfinClient.estimateDownloadSize(item: item, quality: quality) else { continue }
            known = true
            // Saturating: the sizes are the server's word, and a total past
            // what an Int64 holds is "too big", not a reason to trap. Held
            // under half the range so the headroom added to it fits too.
            sum = min(Int64.max / 2, sum + min(max(0, e), Int64.max / 4))
        }
        return known ? sum : nil
    }

    /// What a batch would need against what there is. Nil when either side is
    /// unknowable, which queues as before — this exists to catch the obvious
    /// failure, not to become a new way to fail.
    struct SpaceVerdict: Sendable {
        var needed: Int64
        var free: Int64
        var fits: Bool
        /// Rungs below the chosen one that would fit, cheapest fit first.
        var alternatives: [DownloadQuality]
    }

    static func checkSpace(for items: [BaseItem], quality: DownloadQuality) -> SpaceVerdict? {
        guard let need = estimateTotal(items, quality: quality), let free = freeSpace() else { return nil }
        if need + spaceHeadroom <= free {
            return SpaceVerdict(needed: need, free: free, fits: true, alternatives: [])
        }
        let alternatives = DownloadQualities.all.filter { alt in
            guard alt.label != quality.label, let n = estimateTotal(items, quality: alt) else { return false }
            return n + spaceHeadroom <= free
        }
        return SpaceVerdict(needed: need, free: free, fits: false, alternatives: alternatives)
    }

    // MARK: - Queueing

    func record(for itemId: String) -> DownloadRecord? {
        index(of: itemId).map { records[$0] }
    }

    func isQueuedOrRunning(_ itemId: String) -> Bool {
        if active.contains(itemId) { return true }
        if let queuedIds { return queuedIds.contains(itemId) }
        let ids = Set(queue.map(\.itemId))
        queuedIds = ids
        return ids.contains(itemId)
    }

    /// Where an item that isn't here yet has got to.
    enum TransferState: Sendable { case queued, downloading }

    /// For a row to draw: waiting, arriving, or neither. Reads `queue` so that
    /// a row asking is told when the queue changes — `isQueuedOrRunning`
    /// answers from its cached set and tells nobody.
    func transferState(of itemId: String) -> TransferState? {
        if active.contains(itemId) { return .downloading }
        guard !queue.isEmpty else { return nil }
        return isQueuedOrRunning(itemId) ? .queued : nil
    }

    /// Everything waiting or arriving, counted without looking at a record —
    /// an item the pump has taken off the queue is in `active` before it has
    /// a record to its name, and must not read as "nothing left" in between.
    var inFlightCount: Int { queue.count + active.count }

    /// How many songs — or audiobooks — are waiting or arriving.
    func audioBacklog(books: Bool) -> Int {
        let wanted = books ? "AudioBook" : "Audio"
        var n = 0
        for entry in queue where entry.type == wanted { n += 1 }
        for id in active where record(for: id)?.type == wanted { n += 1 }
        return n
    }

    /// Queue one item. The disk-space check is the caller's — the views run it
    /// so they can offer the smaller rungs in a dialog.
    func enqueue(item: BaseItem, quality: DownloadQuality) {
        guard record(for: item.Id)?.status != .complete, !isQueuedOrRunning(item.Id) else { return }
        append(item, quality: quality)
    }

    /// The queueing itself, for a caller that has already checked the item
    /// isn't downloaded or waiting.
    private func append(_ item: BaseItem, quality: DownloadQuality) {
        pendingItems[item.Id] = Self.trimmed(item)
        persistPendingItems()
        queue.append(QueuedDownload(
            itemId: item.Id,
            title: Self.displayTitle(item),
            series: item.SeriesName,
            season: item.ParentIndexNumber,
            episode: item.IndexNumber,
            quality: quality.label,
            type: item.type
        ))
        persistQueue()
        pump()
    }

    /// Queue a batch, skipping anything already downloaded or already waiting.
    /// Returns how many were newly queued and how many were skipped.
    @discardableResult
    func enqueue(items: [BaseItem], quality: DownloadQuality) -> (queued: Int, skipped: Int) {
        var queued = 0, skipped = 0
        isBatching = true
        // What is already waiting, worked out once. `isQueuedOrRunning`
        // rebuilds its set after every change to the queue, which for a batch
        // that changes it every time round — a whole music library — was the
        // queue read through once per song.
        var waiting = Set(queue.map(\.itemId)).union(active)
        for item in items {
            if record(for: item.Id)?.status == .complete || !waiting.insert(item.Id).inserted {
                skipped += 1
            } else {
                append(item, quality: quality)
                queued += 1
            }
        }
        isBatching = false
        persistQueue()
        persistPendingItems()
        pump()
        return (queued, skipped)
    }

    /// Replay a download that stopped with an error. Retries go to the *front*
    /// of the queue — it is something the user already asked for and watched
    /// fail — but they still wait their turn, because firing a dozen stalled
    /// transfers at once is generally what stalled them.
    func retry(_ itemId: String) {
        guard var rec = record(for: itemId), !isQueuedOrRunning(itemId) else { return }
        rec.status = .queued
        rec.errorMessage = nil
        // A tap is a fresh start for the counter: the person has looked at
        // the failure and asked again, and gets the full run of automatic
        // goes behind that.
        rec.autoRetries = 0
        save(rec)
        queue.insert(QueuedDownload(
            itemId: itemId, title: rec.title, series: rec.series,
            season: rec.season, episode: rec.episode,
            quality: rec.quality, isRetry: true, type: rec.type
        ), at: 0)
        persistQueue()
        pump()
    }

    /// Put a transfer that stopped through no fault of its own back in the
    /// queue, after a wait — the app's own retry, as against the one behind
    /// the button.
    ///
    /// This is what "resiliency" comes down to. A download over a connection
    /// that comes and goes used to end in one of two places: a row in the
    /// failed list with a Retry on it, or a bar that had stopped moving and
    /// nobody to say so. Now a dropped link, a request that timed out, a
    /// server that went away and came back, a transfer the stall sweep gave up
    /// on — each puts the download back at the front of the queue and, when
    /// it starts again, picks up from what had already arrived (see `start`).
    /// Nothing is asked of the person holding the phone unless the same thing
    /// keeps happening from the same place.
    ///
    /// `countsAsAttempt` is false when the failure was plainly the network's —
    /// the device has no route at all — because a phone with no signal is not
    /// evidence that the download is broken, and counting it would exhaust
    /// the retries on a long train journey. Those wait for the path to come
    /// back rather than for a timer.
    private func scheduleAutomaticRetry(_ itemId: String, reason: String, countsAsAttempt: Bool) {
        guard var rec = record(for: itemId), !isQueuedOrRunning(itemId) else { return }
        forgetProgressThrottle(itemId)
        lastSeenBytes[itemId] = nil

        let waitingForNetwork = !pathIsSatisfied
        if countsAsAttempt && !waitingForNetwork { rec.autoRetries += 1 }
        guard rec.autoRetries <= Self.maxAutomaticRetries else {
            rec.status = .error
            rec.errorMessage = "\(reason) — stopped after \(Self.maxAutomaticRetries) attempts"
            save(rec)
            pump()
            return
        }

        let delay: TimeInterval
        let words: String
        if waitingForNetwork {
            delay = Self.networkWaitFallback
            words = "\(reason) — waiting for a connection"
        } else {
            let attempt = max(0, min(rec.autoRetries - 1, Self.retryDelays.count - 1))
            delay = countsAsAttempt ? Self.retryDelays[attempt] : 2
            words = countsAsAttempt ? "\(reason) — trying again in \(Self.describe(delay))" : reason
        }

        rec.status = .queued
        rec.errorMessage = words
        save(rec)
        queue.insert(QueuedDownload(
            itemId: itemId, title: rec.title, series: rec.series,
            season: rec.season, episode: rec.episode,
            quality: rec.quality, isRetry: true,
            retryAt: Date().addingTimeInterval(delay), reason: words, type: rec.type
        ), at: 0)
        persistQueue()
        Self.log.notice("Requeued \(itemId, privacy: .public): \(words, privacy: .public)")
        pump()
    }

    private static func describe(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }

    /// The radio came or went.
    private func pathChanged(satisfied: Bool) {
        let was = pathIsSatisfied
        pathIsSatisfied = satisfied
        guard satisfied, !was else { return }
        // Back. Anything that was holding for this goes now, and the running
        // transfers get their stall clock put back to zero: whatever they
        // failed to receive while the path was down was not their fault.
        let now = Date()
        for id in active { activityAt[id] = now }
        for i in queue.indices where queue[i].retryAt != nil { queue[i].retryAt = nil }
        persistQueue()
        pump()
    }

    /// Sleep until the earliest scheduled retry falls due, then pump. Replaced
    /// whenever the queue changes, so it always tracks the nearest one.
    private func armRetryWake() {
        retryWake?.cancel()
        retryWake = nil
        let now = Date()
        guard let soonest = queue.compactMap(\.retryAt).filter({ $0 > now }).min() else { return }
        let wait = soonest.timeIntervalSince(now)
        retryWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.pump()
        }
    }

    @discardableResult
    func retryAllFailed() -> Int {
        let failed = records.filter { $0.status == .error }
        for rec in failed { retry(rec.itemId) }
        return failed.count
    }

    func cancelQueued(_ itemId: String) {
        queue.removeAll { $0.itemId == itemId }
        pendingItems[itemId] = nil
        persistQueue()
        persistPendingItems()
    }

    // MARK: - Pausing

    /// Held by the person rather than by the network. Kept across launches:
    /// a queue paused from the Lock Screen that started itself again the next
    /// time the app was woken would not have been paused at all.
    private(set) var isPaused = UserDefaults.standard.bool(forKey: DownloadManager.pausedKey) {
        didSet { UserDefaults.standard.set(isPaused, forKey: Self.pausedKey) }
    }

    private static let pausedKey = "downloads.paused"
    /// What a transfer stopped by a pause says in its row, and how its
    /// cancellation is told from a stall's when it comes back round.
    private static let pausedReason = "Paused"
    /// What a transfer set aside by lowering Parallel downloads says, and why
    /// its cancellation isn't counted against it either.
    private static let yieldedReason = "Waiting for a free slot"

    /// Stop the queue where it is, or let it go again.
    ///
    /// Pausing takes the running transfers down the way the stall sweep does —
    /// cancelled so as to be carried on with, not written off — so each goes
    /// back to the front of the queue with what it had fetched, and nothing
    /// new starts until the pause is lifted. It is asked for from the
    /// Downloads page and from the download Live Activity.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        Self.log.notice("Downloads \(paused ? "paused" : "resumed", privacy: .public)")
        if paused {
            for itemId in active where tasks.values.contains(itemId) && retryingAfterCancel[itemId] == nil {
                retryingAfterCancel[itemId] = Self.pausedReason
                cancelTasks(for: itemId, keepingProgress: true)
            }
        } else {
            for i in queue.indices where queue[i].reason?.hasPrefix(Self.pausedReason) == true {
                queue[i].retryAt = nil
                queue[i].reason = nil
            }
            persistQueue()
            pump()
        }
    }

    // MARK: - Parallel downloads

    /// Follows the Parallel downloads setting, from the Downloads page or
    /// from Settings, and the switch that holds transcodes to one.
    private func watchConcurrency() {
        withObservationTracking {
            _ = prefs.downloadConcurrency
            _ = prefs.transcodesOneAtATime
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyConcurrencyLimit()
                self.pump()
                self.watchConcurrency()
            }
        }
    }

    /// Brings the running transfers down to the limit when it's lowered.
    ///
    /// The limit used to be read only when deciding whether to start the
    /// next one, so going from 4 to 1 left all four running. The extras are
    /// set aside the way a pause sets them aside — kept, to carry on from
    /// where they got to — and go back to the front of the queue. The ones
    /// furthest along keep going.
    ///
    /// Turning on one transcode at a time does the same to every running
    /// transcode but the one furthest along.
    private func applyConcurrencyLimit() {
        func done(_ itemId: String) -> Double {
            guard let rec = record(for: itemId) else { return 0 }
            guard let total = rec.estimatedBytes, total > 0 else { return Double(rec.receivedBytes) }
            return Double(rec.receivedBytes) / Double(total)
        }
        func setAside(_ itemId: String, because why: String) {
            Self.log.notice("Setting \(itemId, privacy: .public) aside: \(why, privacy: .public)")
            retryingAfterCancel[itemId] = Self.yieldedReason
            cancelTasks(for: itemId, keepingProgress: true)
        }
        var running = active.filter { tasks.values.contains($0) && retryingAfterCancel[$0] == nil }
        if prefs.transcodesOneAtATime {
            let transcodes = running.intersection(startedAsTranscode)
            for itemId in transcodes.sorted(by: { done($0) < done($1) }).dropLast() {
                setAside(itemId, because: "one transcode at a time")
                running.remove(itemId)
            }
        }
        let excess = running.count - max(1, prefs.downloadConcurrency)
        guard excess > 0 else { return }
        for itemId in running.sorted(by: { done($0) < done($1) }).prefix(excess) {
            setAside(itemId, because: "Parallel downloads lowered")
        }
    }

    /// Whether the server encodes this download as it sends it: a video at
    /// one of the transcoded rungs. Original quality is the file, or at most
    /// the same streams in a new wrapper, and songs ignore the rungs.
    private static func isTranscode(quality: String, type: String?) -> Bool {
        type != "Audio" && type != "AudioBook" && !DownloadQualities.named(quality).original
    }

    /// The items that went in as transcodes when they were started. Read only
    /// against `active`, so an entry outliving its transfer means nothing.
    private var startedAsTranscode: Set<String> = []

    /// Whether `entry` must wait for the running transcode to finish.
    private func waitsForTranscode(_ entry: QueuedDownload) -> Bool {
        prefs.transcodesOneAtATime
            && Self.isTranscode(quality: entry.quality, type: entry.type)
            && !active.isDisjoint(with: startedAsTranscode)
    }

    @discardableResult
    func clearQueue() -> Int {
        let n = queue.count
        queue.removeAll()
        pendingItems.removeAll()
        // Nothing left to hold back; what is queued next starts as usual.
        isPaused = false
        persistQueue()
        persistPendingItems()
        return n
    }

    func cancel(_ itemId: String) {
        cancelQueued(itemId)
        cancelTasks(for: itemId, keepingProgress: false)
        cancelledResolves.insert(itemId)
        active.remove(itemId)
        forgetProgressThrottle(itemId)
        retryingAfterCancel[itemId] = nil
        if var rec = record(for: itemId), rec.status == .downloading || rec.status == .queued {
            rec.status = .canceled
            save(rec)
        }
        pump()
    }

    /// Stop whatever the sessions are doing for one item.
    ///
    /// `keepingProgress` is the difference between a cancel someone asked for
    /// and one the app is doing so it can try again: the second kind asks the
    /// file session for resume data, and keeps the map entry so the completion
    /// that follows can still be matched to its item.
    private func cancelTasks(for itemId: String, keepingProgress: Bool) {
        let keys = Set(tasks.filter { $0.value == itemId }.keys)
        guard !keys.isEmpty else { return }
        if !keepingProgress {
            for key in keys { tasks[key] = nil }
            retiredTasks.formUnion(keys)
        }
        Task {
            // Matched on session and number together — see `DownloadTaskKey`.
            // A stream download keeps its package on cancel regardless; the
            // next attempt resumes from it.
            for (session, task) in await everyTask() where keys.contains(DownloadTaskKey(session, task)) {
                if keepingProgress, let download = task as? URLSessionDownloadTask {
                    if let data = await download.cancelByProducingResumeData() {
                        Self.keepResumeData(data, for: itemId)
                    }
                } else {
                    task.cancel()
                }
            }
        }
    }

    func delete(_ itemId: String) {
        // Read before cancelling: cancelling rewrites the record, and the path
        // of a downloaded stream is the only way back to bytes that live
        // outside this item's own folder.
        let streamPath = record(for: itemId)?.hlsPath
        cancel(itemId)
        if let streamPath {
            try? FileManager.default.removeItem(at: Self.hlsURL(forRelativePath: streamPath))
        }
        try? FileManager.default.removeItem(at: Self.folder(for: itemId))
        DownloadArtwork.forget(itemId: itemId)
        records.removeAll { $0.itemId == itemId }
        recordsRevision &+= 1
        videoRevision &+= 1
        rebuildRecordIndex()
        liveProgress[itemId] = nil
    }

    /// Delete a set of downloads — a season, a series, everything. Returns how
    /// many were actually there to delete, which is what the confirmation says.
    @discardableResult
    func delete(_ itemIds: [String]) -> Int {
        var deleted = 0
        for id in itemIds where record(for: id) != nil {
            delete(id)
            deleted += 1
        }
        return deleted
    }

    /// Everything: the files, the failures, and anything still waiting its turn.
    @discardableResult
    func deleteEverything() -> Int {
        clearQueue()
        return delete(records.map(\.itemId))
    }

    /// Every download of one series, for the Downloads view's grouping and for
    /// shuffle.
    func episodes(ofSeries seriesId: String?, seriesName: String?) -> [DownloadRecord] {
        records.filter { rec in
            guard rec.status == .complete, rec.isEpisode else { return false }
            if let seriesId, let recId = rec.seriesId { return recId == seriesId }
            return rec.series != nil && rec.series == seriesName
        }.sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
    }

    // MARK: - The pump

    private func pump() {
        defer { armRetryWake() }
        // Download URLs are built against the live session; offline they would
        // all error out one after another and drain the queue.
        guard !JellyfinClient.shared.isOffline, JellyfinClient.shared.isSignedIn, !isPaused else { return }
        let now = Date()
        // The first entry that is *due*, not the first entry: a retry waiting
        // out its delay at the front of the queue must not hold up everything
        // behind it, and must not be started early either.
        // A transcode held back by the one-at-a-time switch is passed over in
        // the same way, so a song or an original behind it still starts.
        while active.count < max(1, prefs.downloadConcurrency),
              let i = queue.firstIndex(where: { $0.isDue(at: now) && !waitsForTranscode($0) }) {
            let next = queue.remove(at: i)
            persistQueue()
            start(next)
        }
    }

    private func start(_ entry: QueuedDownload) {
        active.insert(entry.itemId)
        if Self.isTranscode(quality: entry.quality, type: entry.type) {
            startedAsTranscode.insert(entry.itemId)
        } else {
            startedAsTranscode.remove(entry.itemId)
        }
        forgetProgressThrottle(entry.itemId)
        // The clock the stall sweep measures against starts here, so a transfer
        // that never produces a single byte is caught too.
        activityAt[entry.itemId] = Date()

        let quality = DownloadQualities.named(entry.quality)

        var record: DownloadRecord
        var url: URL

        if entry.isRetry, let existing = self.record(for: entry.itemId), let u = URL(string: existing.sourceURL),
           JellyfinClient.shared.isSessionOrigin(u) {
            // A replay rebuilds nothing: the stored request is the only thing
            // that still knows the original URL and quality.
            //
            // Only against the server it was made for. A failed or cancelled
            // record outlives a sign-out, and replayed after signing in
            // somewhere else its URL would take the new server's token back to
            // the old one. Such a record falls through instead, and is rebuilt
            // from the item as this server knows it — or fails, if it doesn't.
            record = existing
            url = u
        } else if let item = pendingItems[entry.itemId],
                  let built = JellyfinClient.shared.downloadURL(item: item, quality: quality) {
            // A fresh start over an old failure: whatever the old one had
            // fetched into a package is not being resumed, so it goes now
            // rather than sitting on disk with nothing pointing at it.
            if let stale = self.record(for: entry.itemId), stale.status != .complete {
                discardPartialPackage(stale.itemId)
                _ = Self.takeResumeData(for: stale.itemId)
            }
            // What the download will actually be, which is the original file
            // whenever the encode that was asked for would have come out larger
            // (see `JellyfinClient.effectiveQuality`). Resolved again here, not
            // just inside the URL builder, because the label goes on the record
            // and from there onto the screen: a row reading "1080p · 9 Mbps"
            // over a file that is the untouched original is a lie the retry
            // path would then replay.
            let quality = JellyfinClient.effectiveQuality(item: item, quality: quality)
            url = built.url
            record = DownloadRecord(
                itemId: item.Id,
                title: Self.displayTitle(item),
                name: item.title,
                type: item.kind,
                series: item.SeriesName,
                seriesId: item.SeriesId,
                season: item.ParentIndexNumber,
                seasonId: item.SeasonId,
                episode: item.IndexNumber,
                year: item.ProductionYear,
                runTimeTicks: item.RunTimeTicks ?? 0,
                quality: quality.label,
                fileName: built.fileName,
                transport: built.transport,
                sourceURL: built.url.absoluteString,
                estimatedBytes: JellyfinClient.estimateDownloadSize(item: item, quality: quality),
                // Seed watch state from the server so an already-watched episode
                // shows its tick and resume point immediately.
                positionTicks: item.userData.positionTicks,
                played: item.userData.played,
                // Three levels, stored separately, because the downloads
                // screens draw all three: the episode's own thumbnail on its
                // row, the season's poster on its heading, the show's on its
                // tile. Which one a view falls back to when the server has none
                // is the view's decision, not this one's.
                imageURL: (item.isAudio
                    ? MusicArt.url(item, width: 600)
                    : item.isEpisode
                        ? Artwork.ownPrimary(item, width: 500)
                        : Artwork.url(item, type: "Primary", width: 500))?.absoluteString,
                seasonImageURL: item.isEpisode ? Artwork.seasonPoster(item, width: 500)?.absoluteString : nil,
                seriesImageURL: item.isEpisode ? Artwork.seriesPoster(item, width: 500)?.absoluteString : nil,
                album: item.Album,
                albumId: item.AlbumId,
                artist: item.isAudio ? (item.AlbumArtist ?? item.artistLine) : nil,
                track: item.isAudio ? item.IndexNumber : nil,
                disc: item.isAudio ? item.ParentIndexNumber : nil
            )
        } else {
            // Nothing to build a URL from. The slot stays claimed while the
            // item is fetched back, because releasing it here sends the pump
            // straight round the loop to discard the next entry, and the next,
            // until the queue is empty — which is what a relaunch used to do to
            // a season that was still waiting.
            Task { await self.resolveThenStart(entry) }
            return
        }

        record.status = .downloading
        record.errorMessage = nil
        save(record)
        // Keep a copy of the artwork while there is still a server to ask. See
        // `DownloadArtwork`.
        let artworkRecord = record
        Task.detached(priority: .utility) { await DownloadArtwork.cache(artworkRecord) }
        pendingItems[entry.itemId] = nil
        persistPendingItems()

        if record.transport == .hls {
            startStream(record, url: url, resuming: entry.isRetry)
            return
        }

        // A replay picks up from where the last attempt stopped, if it left
        // anything behind to pick up from: the resume data URLSession hands
        // over when a transfer fails or is cancelled for it. Without this a
        // dropped connection at 90% meant fetching the 90% again.
        let task: URLSessionDownloadTask
        if entry.isRetry, let resumeData = Self.takeResumeData(for: entry.itemId) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            for (k, v) in JellyfinClient.shared.authHeaders(for: url) { request.setValue(v, forHTTPHeaderField: k) }
            request.allowsCellularAccess = !prefs.downloadsWiFiOnly
            task = session.downloadTask(with: request)
        }
        // On the task as well as in the map. The map is memory, and memory does
        // not survive the app being terminated while the system carries on with
        // the transfer — which is the ordinary way a large download finishes.
        // What the task carries comes back with it.
        task.taskDescription = entry.itemId
        tasks[DownloadTaskKey(session, task)] = entry.itemId
        task.resume()
    }

    /// Hand a stream download to AVFoundation.
    ///
    /// The token goes on the URL as `api_key`, because it is the only
    /// credential AVFoundation carries onto the segment requests; it is added
    /// here and never written to meta.json.
    ///
    /// A replay is handed the partly downloaded package rather than the URL.
    /// AVFoundation keeps what it has fetched of a stream in that package, and
    /// an asset made from the package's own location resumes the transfer:
    /// only the segments still missing are asked for, in order, and the
    /// server — which encodes on demand — picks the encode up at the first of
    /// them. Before this a retry started over from the first segment, and the
    /// package the failed attempt had filled was left on disk with nothing
    /// pointing at it.
    private func startStream(_ record: DownloadRecord, url: URL, resuming: Bool) {
        let asset: AVURLAsset
        if resuming, let partial = Self.partialPackage(of: record) {
            asset = AVURLAsset(url: partial)
            // The task about to start counts only what *it* pulls, from zero,
            // while the fraction it reports covers the whole package — so a
            // resume that picked up at 60% used to show the bar there and the
            // bytes starting again from nothing. What the earlier attempts
            // fetched is carried forward under the new count. See
            // `noteStreamProgress`.
            streamByteBase[record.itemId] = record.receivedBytes
            Self.log.notice("Resuming stream \(record.itemId, privacy: .public) from its package")
        } else {
            streamByteBase[record.itemId] = nil
            // Records saved before downloads carried a session of their own
            // get one here; see `JellyfinClient.withPlaySession`.
            asset = AVURLAsset(url: JellyfinClient.shared.authorized(JellyfinClient.withPlaySession(url)))
        }
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: record.title)
        let session = prefs.downloadsWiFiOnly ? wifiAssetSession : assetSession
        let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = record.itemId
        tasks[DownloadTaskKey(session, task)] = record.itemId
        task.resume()
    }

    /// Where a stream download's package is, if there is one on disk to
    /// resume from.
    private static func partialPackage(of record: DownloadRecord) -> URL? {
        guard let path = record.hlsPath else { return nil }
        let url = hlsURL(forRelativePath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Throw away what a stream download had fetched so far, so the next
    /// attempt starts clean. For a package the server will no longer honour —
    /// a token that has changed, a transcode it has forgotten — resuming would
    /// fail the same way every time.
    private func discardPartialPackage(_ itemId: String) {
        guard var rec = record(for: itemId), let path = rec.hlsPath else { return }
        try? FileManager.default.removeItem(at: Self.hlsURL(forRelativePath: path))
        rec.hlsPath = nil
        rec.loadedFraction = nil
        rec.receivedBytes = 0
        save(rec)
    }

    // The resume data of a file download that stopped, kept beside the
    // download's metadata until a replay picks it up.

    nonisolated private static func resumeDataFile(for itemId: String) -> URL {
        folderPath(for: itemId).appendingPathComponent("resume.data")
    }

    /// Resume data has the original request archived inside it, Authorization
    /// header and all, so it is the one file here holding a credential: kept
    /// out of backups, and unreadable until the device has been unlocked once
    /// (not stricter — a transfer fails and is retried with the screen locked).
    nonisolated private static func keepResumeData(_ data: Data, for itemId: String) {
        var file = resumeDataFile(for: itemId)
        #if os(macOS)
        let options: Data.WritingOptions = .atomic
        #else
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #endif
        guard (try? data.write(to: file, options: options)) != nil else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
    }

    private static func takeResumeData(for itemId: String) -> Data? {
        let file = resumeDataFile(for: itemId)
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }

    /// A stream download that AVFoundation says is finished. Its bytes are a
    /// bundle of segments rather than one file, so what goes on the record is
    /// where it landed and how much room it takes.
    private func finishStream(_ itemId: String) async {
        guard var rec = record(for: itemId) else { return }
        guard let path = rec.hlsPath else {
            rec.status = .error
            rec.errorMessage = "The download finished with nowhere to put it"
            save(rec)
            return
        }
        let url = Self.hlsURL(forRelativePath: path)
        guard await Self.isPlayable(url, strict: false) else {
            try? FileManager.default.removeItem(at: url)
            guard var broken = record(for: itemId) else { return }
            broken.hlsPath = nil
            broken.loadedFraction = nil
            broken.receivedBytes = 0
            broken.verifyFailures += 1
            broken.status = .error
            save(broken)
            Self.log.error("\(itemId, privacy: .public) finished as a package that won't open (\(broken.verifyFailures))")
            // Once is worth a clean start, the way a file that won't open
            // gets one in `verifyAndComplete`. A package is most often left
            // like this by a transfer that was interrupted and carried on —
            // its segments from an encode the server stopped, and the rest
            // from the one it started in its place — and a copy made in one
            // go doesn't have that seam.
            if broken.verifyFailures <= 1 {
                retry(itemId)
                if var queued = record(for: itemId) {
                    queued.errorMessage = "The first copy wouldn't open"
                    save(queued)
                }
            } else {
                broken.errorMessage = "The download finished but wouldn't open, twice"
                save(broken)
            }
            return
        }
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        // A feature-length stream is thousands of segment files, each asked
        // for its size: seconds of work, and it used to be the main thread's,
        // at exactly the moment the row flips to finished.
        let size = await Task.detached(priority: .utility) { Self.sizeOnDisk(of: url) }.value
        // Read again: the checks above suspended, and the record may have been
        // deleted or changed in the meantime.
        guard let current = record(for: itemId), current.hlsPath == path else { return }
        rec = current
        rec.receivedBytes = size
        rec.totalBytes = size
        rec.loadedFraction = 1
        rec.status = .complete
        rec.errorMessage = nil
        rec.verifyFailures = 0
        save(rec)
    }

    /// What a downloaded stream actually occupies — it is a directory of
    /// segments, so the answer has to be walked for.
    private nonisolated static func sizeOnDisk(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Ask the server to describe an item we no longer hold, then start it. A
    /// download that can't be described is left as a failure with a Retry on it
    /// rather than vanishing.
    private func resolveThenStart(_ entry: QueuedDownload) async {
        let item = try? await JellyfinClient.shared.item(entry.itemId)
        guard cancelledResolves.remove(entry.itemId) == nil else {
            // Called off while its metadata was in flight — see
            // `cancelledResolves`. Neither started nor written off as failed.
            active.remove(entry.itemId)
            return
        }
        if let item {
            pendingItems[entry.itemId] = Self.trimmed(item)
            persistPendingItems()
            active.remove(entry.itemId)
            start(entry)
            return
        }
        active.remove(entry.itemId)
        var rec = record(for: entry.itemId) ?? DownloadRecord(
            itemId: entry.itemId,
            title: entry.title,
            name: entry.title,
            series: entry.series,
            season: entry.season,
            episode: entry.episode,
            quality: entry.quality
        )
        rec.status = .error
        rec.errorMessage = "Couldn't ask the server about this item"
        save(rec)
        pump()
    }

    /// Which download a delegate callback belongs to.
    ///
    /// The in-memory map is only good for the run of the app that started the
    /// transfer. A background download that finished while the app was
    /// terminated — the normal end of any download big enough to be worth
    /// making — arrives at a delegate that has never seen the task, and
    /// answering "no idea" there is what threw the finished file away and left
    /// the record to be swept up as a failure a moment later. Neither of the
    /// other two answers depends on this process having been alive: the item id
    /// is written onto the task, and the URL it was started with is on the
    /// record.
    private func itemId(forTask key: DownloadTaskKey, description: String?, url: String?) -> String? {
        if let known = tasks[key] { return known }
        if retiredTasks.contains(key) { return nil }
        if let description, record(for: description) != nil {
            tasks[key] = description
            return description
        }
        if let url, let rec = records.first(where: { $0.sourceURL == url }) {
            tasks[key] = rec.itemId
            return rec.itemId
        }
        return nil
    }

    /// How long the sweep below waits for the system to deliver the events it
    /// was holding while the app wasn't running.
    private static let reconcileGrace: TimeInterval = 8

    /// After a relaunch: adopt whatever the background session is still doing,
    /// and mark as failed anything that claimed to be running but isn't.
    private func reconcile() async {
        // Creating the session is what makes the system start replaying the
        // callbacks it held while the app was away, so this is also the moment
        // the backlog begins to arrive.
        let running = await everyTask()
        var live = Set<String>()
        for (session, task) in running {
            guard let itemId = itemId(
                forTask: DownloadTaskKey(session, task),
                description: task.taskDescription,
                // See `didCompleteWithError` — this property throws on a
                // stream download rather than answering.
                url: task is AVAssetDownloadTask ? nil : task.originalRequest?.url?.absoluteString
            ) else { continue }
            live.insert(itemId)
            active.insert(itemId)
        }
        pump()

        // Anything still claiming to be running is either a transfer the last
        // run genuinely lost, or one that finished without the app there to be
        // told. Those two look identical right now and different a second from
        // now, so the sweep waits: marking the second kind failed moments before
        // its file lands is how a download that had actually completed ended up
        // in the failed list.
        try? await Task.sleep(for: .seconds(Self.reconcileGrace))
        // Picked back up rather than written off. What was fetched before the
        // interruption is still on disk — the stream's package, the file's
        // resume data — and `start` resumes from it; the only thing a relaunch
        // used to add was a Retry button between the person and their
        // download. Not counted as an attempt: the app going away is not the
        // transfer's doing.
        for rec in records
        where rec.status == .downloading && !live.contains(rec.itemId) && !active.contains(rec.itemId) {
            scheduleAutomaticRetry(rec.itemId, reason: "Interrupted — picking it back up", countsAsAttempt: false)
        }
        // And a retry that was waiting out its delay when the process ended:
        // its queue entry is back, but with a time in the past on it, which
        // the pump treats as now.
        pump()
    }

    /// A transfer said how far along it is.
    ///
    /// This arrives once per block written — tens of thousands of times for a
    /// film, and more again for a transcode, which the server sends in small
    /// chunks as it encodes. Acting on every one of them meant re-encoding
    /// meta.json and republishing the record to every screen observing it,
    /// thousands of times a second.
    ///
    /// That is survivable while the app is in front of you. It is not survivable
    /// when it isn't: the system holds a background session's callbacks while an
    /// app is suspended and delivers the backlog in one burst on the way back to
    /// the foreground, so a download left running with the screen off would come
    /// back to a main thread with an hour of accumulated writes queued on it —
    /// long enough for the watchdog to kill the app before it drew a frame.
    ///
    /// So: redraw twice a second, touch the disk every ten. Neither number
    /// changes what the transfer does, only how often it is talked about.
    private func noteTransfer(itemId: String, received: Int64, expected: Int64) {
        let now = Date()
        // What the stall sweep reads: the transfer is alive. Callbacks now
        // arrive here at most twice a second (see `progressHopDue`), which is
        // far inside the three minutes the sweep allows.
        activityAt[itemId] = now
        guard var rec = record(for: itemId), rec.status != .complete else { return }
        rec.receivedBytes = received
        if expected > 0 { rec.totalBytes = expected }
        publish(&rec, received: received, at: now)
    }

    /// The counts go to `liveProgress` every time; the record changes only
    /// when its state does, or when the counts are due on disk.
    private func publish(_ rec: inout DownloadRecord, received: Int64, at now: Date) {
        liveProgress[rec.itemId] = LiveProgress(
            received: rec.receivedBytes, total: rec.totalBytes, fraction: rec.loadedFraction
        )
        var stateChanged = false
        if rec.status != .downloading {
            rec.status = .downloading
            stateChanged = true
        }
        // Moving again, so the run of failures it may have had is over.
        if rec.autoRetries > 0, received > Self.progressWorthResetting {
            rec.autoRetries = 0
            stateChanged = true
        }
        let persist = lastPersistAt[rec.itemId].map { now.timeIntervalSince($0) >= Self.progressPersistInterval } ?? true
        if persist { lastPersistAt[rec.itemId] = now }
        guard persist || stateChanged else { return }
        save(rec, toDisk: persist)
    }

    /// A finished transfer, checked before it is called finished.
    ///
    /// A transcode is sent as it is being encoded, and the server cannot say how
    /// big it will be because it does not yet know. With no length to measure
    /// the transfer against, one that ends early ends *successfully* as far as
    /// URLSession is concerned: 200, connection closed, file handed over. What
    /// lands is an MP4 whose index was never written — the part ffmpeg writes
    /// last — and that is the file that sits in the list looking downloaded and
    /// then fails the moment the player opens it.
    ///
    /// Asking AVFoundation whether it can open the file is the only check worth
    /// anything here, and on a local file it costs a fraction of a second: it
    /// reads the header and the index, not the picture.
    ///
    /// A file that fails is fetched once more rather than reported. This is not
    /// optimism — it is what already worked by hand: deleting the download and
    /// asking again produced a file that played, and produced it much faster,
    /// because by then the server had finished the encode it was streaming the
    /// first time. The second attempt gets the finished one.
    private func verifyAndComplete(_ itemId: String, at url: URL) async {
        let isAudio = record(for: itemId)?.isAudio ?? false
        let playable = await Self.isPlayable(url, audio: isAudio)
        guard var rec = record(for: itemId) else { return }

        if playable {
            rec.status = .complete
            rec.errorMessage = nil
            rec.verifyFailures = 0
            save(rec)
            return
        }

        try? FileManager.default.removeItem(at: url)
        rec.receivedBytes = 0
        rec.totalBytes = 0
        rec.verifyFailures += 1
        rec.status = .error
        save(rec)

        if rec.verifyFailures <= 1 {
            // `retry` clears the message, which is right for a retry someone
            // pressed and wrong for one nobody asked for: this is the only
            // explanation there will be for the same episode downloading a
            // second time, and it has to survive into the row that shows it.
            retry(itemId)
            if var queued = record(for: itemId) {
                queued.errorMessage = "The first copy arrived incomplete"
                save(queued)
            }
        } else {
            rec.errorMessage = "The file arrived incomplete twice and wouldn't open"
            save(rec)
            pump()
        }
    }

    /// Whether AVFoundation can actually open what landed on disk.
    ///
    /// `strict` is for a single file arriving over one connection, where nothing
    /// but the bytes themselves says whether the whole thing came: there,
    /// `isPlayable` is not enough — a truncated MP4 can answer yes and have
    /// nothing in it — so a video track and a real duration are demanded too.
    ///
    /// A downloaded stream is not asked those questions. Its completeness was
    /// settled by the manifest before AVFoundation reported success, and a
    /// `.movpkg` is a package of segments rather than a movie: it does not
    /// answer `loadTracks` or `duration` the way a file does, and treating a
    /// blank answer as a fault threw away downloads that were perfectly good.
    ///
    /// `audio` is a song or an audiobook: the same test, asking for a sound
    /// track rather than a picture — a FLAC has no video track and never will.
    ///
    /// `@concurrent`: opening the asset is not main-actor work, and with a
    /// music library draining it is asked every second or so.
    @concurrent
    private nonisolated static func isPlayable(_ url: URL, strict: Bool = true, audio: Bool = false) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { return false }
            guard strict else { return true }
            guard try await !asset.loadTracks(withMediaType: audio ? .audio : .video).isEmpty else { return false }
            let duration = try await asset.load(.duration)
            return duration.isNumeric && duration.seconds > 0
        } catch {
            return false
        }
    }

    /// Same throttle as `noteTransfer`, and for the same reason: this arrives
    /// once per segment, and a season's worth of them delivered in one burst on
    /// the way back to the foreground is what the watchdog kills an app for.
    private func noteStreamProgress(itemId: String, fraction: Double, received: Int64) {
        let now = Date()
        activityAt[itemId] = now
        guard var rec = record(for: itemId), rec.status != .complete else { return }
        rec.loadedFraction = fraction
        // Fraction and bytes are written together, from the same callback, so
        // the two never describe different moments of the transfer.
        if received > 0 { rec.receivedBytes = (streamByteBase[itemId] ?? 0) + received }
        publish(&rec, received: received, at: now)
    }

    private func forgetProgressThrottle(_ itemId: String) {
        liveProgress[itemId] = nil
        lastPersistAt[itemId] = nil
        activityAt[itemId] = nil
        streamByteBase[itemId] = nil
    }

    /// Watch for transfers that have stopped moving.
    private func watchForStalls() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.stallSweepInterval))
            guard !Task.isCancelled else { return }
            await sweepStalledTransfers()
        }
    }

    /// A transfer that has produced nothing for three minutes is finished with,
    /// whatever the session still thinks. Its task is cancelled, its slot is
    /// given back so the queue moves on, and the record is left as a failure
    /// with a Retry on it — which is a download you can see and act on, rather
    /// than a bar that never moves again.
    private func sweepStalledTransfers() async {
        // No route, no verdict. The transfers are not stalled, the phone is
        // somewhere without signal, and the clock is put back when it returns
        // — see `pathChanged`.
        guard pathIsSatisfied else { return }
        let now = Date()
        var stalled = records.filter { rec in
            guard rec.status == .downloading else { return false }
            let last = activityAt[rec.itemId] ?? rec.createdAt
            return now.timeIntervalSince(last) >= Self.stallLimit
        }
        guard !stalled.isEmpty else { return }

        // Ask the session before writing anything off. The clock above stops
        // while the app is suspended and the callbacks that would have advanced
        // it are held by the system until it comes back — so on the way to the
        // foreground every background transfer looks three minutes idle, and a
        // sweep that trusted the clock alone would cancel the very downloads
        // that had been running happily all along. The byte count on the task
        // itself is kept up to date whether this process was listening or not.
        var live: [String: Int64] = [:]
        for (session, task) in await everyTask() {
            guard let itemId = itemId(
                forTask: DownloadTaskKey(session, task),
                description: task.taskDescription,
                // See `didCompleteWithError`: this property raises rather than
                // answering on a stream download.
                url: task is AVAssetDownloadTask ? nil : task.originalRequest?.url?.absoluteString
            ) else { continue }
            live[itemId] = task.countOfBytesReceived
        }
        stalled.removeAll { rec in
            guard let bytes = live[rec.itemId] else { return false }
            guard bytes != lastSeenBytes[rec.itemId] else { return false }
            // It moved. Put the clock back where the transfer actually is.
            lastSeenBytes[rec.itemId] = bytes
            activityAt[rec.itemId] = Date()
            return true
        }
        guard !stalled.isEmpty else { return }

        // Cancelled so as to be tried again, not written off. The task's
        // completion arrives at `didCompleteWithError` with the resume data
        // (for a file) or after the package has been noted (for a stream), and
        // that is where the transfer is put back in the queue — after the
        // cancel has landed, so a resume has something to resume from. A
        // transfer with no task to cancel is requeued straight away.
        let reason = "Stalled"
        for rec in stalled {
            // `stalled` was read before `await everyTask()` above; the item
            // may have finished, failed or been removed in that gap. Acting
            // on the stale copy regardless is how a download that had just
            // completed got put back in the queue as `.queued`.
            guard record(for: rec.itemId)?.status == .downloading else { continue }
            // A cancel the previous sweep sent that never came back — the map
            // held a task the session no longer had — is not sent again; the
            // transfer is requeued directly instead.
            let hasTask = tasks.values.contains(rec.itemId) && retryingAfterCancel[rec.itemId] == nil
            if hasTask {
                retryingAfterCancel[rec.itemId] = reason
                cancelTasks(for: rec.itemId, keepingProgress: true)
            } else {
                retryingAfterCancel[rec.itemId] = nil
                for id in tasks.filter({ $0.value == rec.itemId }).keys { tasks[id] = nil }
                active.remove(rec.itemId)
                scheduleAutomaticRetry(rec.itemId, reason: reason, countsAsAttempt: true)
            }
        }
        pump()
    }

    /// The queue restored from a previous run waits here until a server is back.
    func connectivityChanged(online: Bool) {
        guard online else { return }
        // The server answered, which settles anything that was waiting on the
        // network more surely than the path monitor can.
        for i in queue.indices where queue[i].retryAt != nil { queue[i].retryAt = nil }
        persistQueue()
        pump()
    }

    static func displayTitle(_ item: BaseItem) -> String {
        if item.isEpisode, let series = item.SeriesName {
            let label = item.episodeLabel.map { " · \($0)" } ?? ""
            return "\(series)\(label) · \(item.title)"
        }
        return item.title
    }

    // MARK: - Local watch state

    /// Record where a downloaded file was left. Written locally and flagged for
    /// sync; OfflineProgress pushes it back when the server is reachable.
    func noteProgress(itemId: String, positionSeconds: Double, played: Bool? = nil) {
        guard var rec = record(for: itemId) else { return }
        rec.positionTicks = Int64(max(0, positionSeconds) * 10_000_000)
        let fraction = rec.runTimeTicks > 0 ? Double(rec.positionTicks) / Double(rec.runTimeTicks) : 0
        let finished = rec.type == "AudioBook"
            ? BookProgress.isFinished(positionTicks: rec.positionTicks, runTimeTicks: rec.runTimeTicks)
            : rec.runTimeTicks > 0 && fraction > 0.92
        if let played {
            if rec.played && !played { rec.unplayedPending = true }
            rec.played = played
        } else if rec.played, rec.isAudio, positionSeconds > 30, rec.runTimeTicks > 0, !finished {
            // A book finished once and started again: `resumeSeconds` ignores
            // the position of anything marked played, so without this it
            // would open at 0:00 every time from here on.
            rec.played = false
            rec.unplayedPending = true
        }
        if finished {
            rec.played = true
        }
        if rec.played { rec.unplayedPending = false }
        rec.progressSynced = false
        rec.progressRevision += 1
        save(rec)
    }

    /// `revision` is the one the sync read before it went to the server. If
    /// the record has moved on since — playback carried on during the await —
    /// it stays unsynced so the newer state goes next time.
    func markSynced(_ itemId: String, revision: Int? = nil) {
        guard var rec = record(for: itemId) else { return }
        if let revision, rec.progressRevision != revision { return }
        rec.progressSynced = true
        rec.unplayedPending = false
        save(rec)
    }

    var pendingSyncCount: Int { tally.unsynced }

    var unsyncedRecords: [DownloadRecord] {
        records.filter { !$0.progressSynced }
    }

    /// Overwrite local watch state with the server's, without marking it dirty —
    /// this is the server telling us, not us telling the server. Records with
    /// unsynced local changes are left alone: those are newer.
    func applyServerState(itemId: String, positionTicks: Int64, played: Bool) {
        guard var rec = record(for: itemId), rec.progressSynced else { return }
        guard rec.positionTicks != positionTicks || rec.played != played else { return }
        rec.positionTicks = positionTicks
        rec.played = played
        save(rec)
    }

    func setPlayed(_ itemId: String, played: Bool) {
        guard var rec = record(for: itemId) else { return }
        // Un-watching is something the server has to be told in so many
        // words; see `OfflineProgress.sync`.
        rec.unplayedPending = !played
        rec.played = played
        if played { rec.positionTicks = 0 }
        rec.progressSynced = false
        rec.progressRevision += 1
        save(rec)
    }

    var totalBytesOnDisk: Int64 { tally.completeBytes }

    /// What the Downloads page counts, counted once per change to the records
    /// rather than once per mention per redraw: with a music library on the
    /// device every one of these was a pass over thousands of records, and the
    /// page asked for a dozen of them each time a song finished.
    struct Tally {
        var running: [DownloadRecord] = []
        var failed: [DownloadRecord] = []
        var completeCount = 0
        var completeBytes: Int64 = 0
        /// Finished films and episodes that have been watched. Not songs or
        /// books: one that has been played is not one that is finished with.
        var watched: [DownloadRecord] = []
        var unsynced = 0
        /// Finished songs and audiobooks. The Downloads page has a door for
        /// each rather than a tile per record, and needs to know whether
        /// there is anything behind it.
        var songs = 0
        var books = 0
    }

    var tally: Tally {
        // Read first, so whoever asks is told when the records change.
        let records = records
        if let kept = keptTally, kept.revision == recordsRevision { return kept.tally }
        var t = Tally()
        for record in records {
            if !record.progressSynced { t.unsynced += 1 }
            switch record.status {
            case .downloading: t.running.append(record)
            case .error: t.failed.append(record)
            case .complete:
                t.completeCount += 1
                t.completeBytes += max(record.receivedBytes, record.totalBytes)
                if record.played, !record.isAudio { t.watched.append(record) }
                if record.type == "Audio" { t.songs += 1 }
                if record.type == "AudioBook" { t.books += 1 }
            default: break
            }
        }
        keptTally = (recordsRevision, t)
        return t
    }

    @ObservationIgnored private var keptTally: (revision: Int, tally: Tally)?
}

// MARK: - URLSession delegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let id = DownloadTaskKey(session, downloadTask)
        guard Self.progressHopDue(id) else { return }
        let described = downloadTask.taskDescription
        let source = downloadTask.originalRequest?.url?.absoluteString
        Task { @MainActor in
            guard let itemId = self.itemId(forTask: id, description: described, url: source) else { return }
            // Adopting a transfer this run of the app didn't start also means
            // claiming its slot, so the pump doesn't run a second one alongside
            // it and blow past the concurrency the user asked for.
            self.active.insert(itemId)
            self.noteTransfer(
                itemId: itemId,
                received: totalBytesWritten,
                expected: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let id = DownloadTaskKey(session, downloadTask)
        let described = downloadTask.taskDescription
        let source = downloadTask.originalRequest?.url?.absoluteString
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // The temporary file is gone as soon as this returns, so it has to be
        // moved here rather than after a hop onto the main actor.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staged)

        Task { @MainActor in
            guard let itemId = self.itemId(forTask: id, description: described, url: source),
                  var rec = self.record(for: itemId)
            else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            self.tasks[id] = nil
            self.active.remove(itemId)
            self.forgetProgressThrottle(itemId)
            defer { self.pump() }

            guard (200..<300).contains(status) else {
                try? FileManager.default.removeItem(at: staged)
                // A server that is up but not well — a gateway timing out, a
                // reverse proxy between restarts — is worth asking again. One
                // that says no is not.
                if status >= 500 {
                    self.scheduleAutomaticRetry(itemId, reason: "Server answered \(status)", countsAsAttempt: true)
                    return
                }
                // Not found, timed out, too many at once: on a first go these
                // are as often the server catching up as a real refusal, and
                // the retry by hand that fixed them costs nothing to make here.
                if [404, 408, 429].contains(status), rec.autoRetries == 0 {
                    self.scheduleAutomaticRetry(itemId, reason: "Server answered \(status)", countsAsAttempt: true)
                    return
                }
                rec.status = .error
                rec.errorMessage = "Server answered \(status)"
                self.save(rec)
                return
            }

            // A record restored from a run that never got as far as naming the
            // file still has somewhere to put it.
            if rec.fileName.isEmpty {
                rec.fileName = JellyfinClient.safeFileName(rec.name.isEmpty ? itemId : rec.name) + ".mp4"
            }
            let destination = Self.folder(for: itemId).appendingPathComponent(rec.fileName)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: staged, to: destination)
                var noBackup = URLResourceValues()
                // Media is re-downloadable; backing it up would blow out iCloud.
                noBackup.isExcludedFromBackup = true
                var mutable = destination
                try? mutable.setResourceValues(noBackup)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
                rec.receivedBytes = size ?? rec.receivedBytes
                rec.totalBytes = size ?? rec.totalBytes
                rec.errorMessage = nil
                // Deliberately not `.complete` yet — see `verifyAndComplete`.
                self.save(rec)
                Task { await self.verifyAndComplete(itemId, at: destination) }
                return
            } catch {
                rec.status = .error
                rec.errorMessage = error.localizedDescription
            }
            self.save(rec)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // The task is over; its entry in the progress throttle goes with it.
        let finished = DownloadTaskKey(session, task)
        Self.progressHops.withLock { $0[finished] = nil }
        // A stream download reports its success here and nowhere else — there is
        // no "finished downloading to" for the whole asset, only for the bundle
        // it was written into. A file download reports success elsewhere and
        // only reaches this with something to say.
        let isStream = task is AVAssetDownloadTask
        guard error != nil || isStream else { return }
        let id = DownloadTaskKey(session, task)
        let described = task.taskDescription
        // Never ask a stream download what it was asked for: reading
        // `originalRequest` on an AVAssetDownloadTask raises an Objective-C
        // exception rather than returning nil, and an exception through a
        // delegate callback takes the app with it. Those tasks carry the item
        // id on `taskDescription` anyway, which is what this is a fallback for.
        let source = isStream ? nil : task.originalRequest?.url?.absoluteString
        let failure = error.map(Self.classify)
        let received = task.countOfBytesReceived
        // A file download that stopped hands over the means to carry on from
        // where it was, and it hands it over here and nowhere else.
        let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let itemId = self.itemId(forTask: id, description: described, url: source) else {
                // The last word from a task cancelled on purpose; nothing
                // more will come from it.
                self.retiredTasks.remove(id)
                return
            }
            if let resumeData { Self.keepResumeData(resumeData, for: itemId) }
            self.tasks[id] = nil
            self.active.remove(itemId)
            self.forgetProgressThrottle(itemId)
            defer { self.pump() }

            guard let failure else {
                await self.finishStream(itemId)
                return
            }
            guard let rec = self.record(for: itemId), rec.status != .complete else { return }
            Self.log.error(
                "\(itemId, privacy: .public) stopped after \(received) bytes: \(failure.detail, privacy: .private)"
            )

            // The stall sweep's own cancel, coming back round — or a pause's,
            // which is nobody's failure and is not counted as one.
            if let reason = self.retryingAfterCancel.removeValue(forKey: itemId) {
                self.scheduleAutomaticRetry(itemId, reason: reason, countsAsAttempt: reason != Self.pausedReason && reason != Self.yieldedReason)
                return
            }

            switch failure.kind {
            case .cancelled:
                var stopped = rec
                stopped.status = .canceled
                stopped.errorMessage = nil
                self.save(stopped)
                // The system's stop button means stop: left alone, the pump
                // would start the next in the queue and put the activity
                // straight back. Paused rather than cleared, so what was
                // waiting is still there to resume from the Downloads page.
                if failure.fromSystemControls { self.setPaused(true) }
            case .permanent:
                // Jellyfin starts encoding when the first request comes in,
                // and can answer it with a 404 before there's anything to
                // send — which AVFoundation reports as "not found on this
                // server". A retry by hand always worked, so one goes by
                // itself; a second "not found" is believed.
                if isStream, received == 0, failure.notFound, rec.autoRetries == 0 {
                    self.scheduleAutomaticRetry(itemId, reason: "The server wasn't ready", countsAsAttempt: true)
                    return
                }
                var broken = rec
                broken.status = .error
                broken.errorMessage = failure.summary
                self.save(broken)
            case .transient:
                // A resumed stream that fetched nothing at all before it
                // failed, on a network that is up, is a package the server
                // won't honour any more; the next go starts clean.
                if isStream, received == 0, rec.hlsPath != nil, self.pathIsSatisfied, !failure.isConnectivity {
                    self.discardPartialPackage(itemId)
                }
                self.scheduleAutomaticRetry(
                    itemId, reason: failure.summary,
                    countsAsAttempt: !failure.isConnectivity || self.pathIsSatisfied
                )
            }
        }
    }

    /// What a failed transfer's error amounts to.
    struct Failure: Sendable {
        enum Kind: Sendable { case cancelled, transient, permanent }
        var kind: Kind
        /// The network itself went away, as against the server or the file.
        var isConnectivity: Bool
        /// For the row.
        var summary: String
        /// For the log: every layer of the error, with its codes.
        var detail: String
        /// The server said there was nothing at the address. Permanent in
        /// the end, but on a stream's first request it is usually a transcode
        /// that hasn't written its first segment yet.
        var notFound: Bool = false
        /// Stopped from the system's Live Activity rather than from the app.
        var fromSystemControls: Bool = false
    }

    /// Sort an error into "someone stopped it", "worth another go" and
    /// "no point". The chain of underlying errors is walked because the one
    /// AVFoundation hands over for a stream says nothing — "The operation
    /// could not be completed" — and the URL error underneath it says
    /// everything. Anything not recognised is treated as worth another go: a
    /// retry is cheap, a download stopped on a hunch is not, and the attempt
    /// limit stops it from going on forever.
    nonisolated static func classify(_ error: any Error) -> Failure {
        var layers: [NSError] = []
        var current: NSError? = error as NSError
        while let e = current, layers.count < 6 {
            layers.append(e)
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let detail = layers.map { "\($0.domain) \($0.code): \($0.localizedDescription)" }.joined(separator: " ← ")
        let urlErrors = layers.filter { $0.domain == NSURLErrorDomain }.map { URLError.Code(rawValue: $0.code) }

        // The system's own Live Activity for stream downloads has a cancel
        // button, and what it hands back is Cocoa's user-cancelled rather
        // than URLError's: without this it read as a hiccup and every
        // download the person had just cancelled was started again.
        let systemCancel = layers.contains { $0.domain == NSCocoaErrorDomain && $0.code == NSUserCancelledError }
        if urlErrors.contains(.cancelled) || systemCancel {
            return Failure(
                kind: .cancelled, isConnectivity: false, summary: "Cancelled", detail: detail,
                fromSystemControls: systemCancel
            )
        }
        let connectivity: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
            .callIsActive, .backgroundSessionWasDisconnected, .secureConnectionFailed,
        ]
        if let hit = urlErrors.first(where: connectivity.contains) {
            let words: String = switch hit {
            case .timedOut: "The server stopped answering"
            case .dataNotAllowed, .internationalRoamingOff: "Cellular data isn't allowed"
            default: "The connection was lost"
            }
            return Failure(kind: .transient, isConnectivity: true, summary: words, detail: detail)
        }
        let permanent: Set<URLError.Code> = [
            .userAuthenticationRequired, .badURL, .unsupportedURL, .fileDoesNotExist,
            .cannotCreateFile, .cannotWriteToFile, .noPermissionsToReadFile, .cannotOpenFile,
        ]
        if urlErrors.contains(where: permanent.contains) {
            return Failure(
                kind: .permanent, isConnectivity: false, summary: error.localizedDescription, detail: detail,
                notFound: urlErrors.contains(.fileDoesNotExist)
            )
        }
        if layers.contains(where: { $0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError }) {
            return Failure(kind: .permanent, isConnectivity: false, summary: "This device is out of space", detail: detail)
        }
        // Everything else — AVFoundation's own codes included, which do not
        // say whether the server refused or the link dropped — gets its goes
        // and then stops.
        let innermost = layers.last?.localizedDescription ?? error.localizedDescription
        return Failure(kind: .transient, isConnectivity: false, summary: innermost, detail: detail)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        Task { @MainActor in
            self.backgroundCompletionHandlers.removeValue(forKey: identifier)?()
        }
    }
}

// MARK: - Artwork kept beside the media

/// The pictures a downloaded item is drawn with, saved next to it.
///
/// Every artwork address on a `DownloadRecord` is one of the server's, which is
/// fine while there is a server and exactly wrong the moment there isn't.
/// Left as they were, opening Downloads away from home put every tile through
/// `RemoteImage`'s retry passes against a host that cannot answer — three
/// attempts each, and on a network that is up but has no route out each attempt
/// waits the whole request timeout before failing. A screen of episodes took
/// the better part of a minute to draw pictures whose video was already on the
/// device.
enum DownloadArtwork {
    /// The three levels a downloads screen draws: the episode's own still, its
    /// season's poster, its series'. Named on disk rather than numbered so a
    /// folder can be read by a human.
    enum Kind: String {
        case primary, season, series
        var fileName: String { "art-\(rawValue)" }
    }

    static func file(itemId: String, kind: Kind) -> URL {
        DownloadManager.folderPath(for: itemId).appendingPathComponent(kind.fileName)
    }

    /// What to actually ask for: the copy on this device where there is one,
    /// the server's address where there isn't. A record written before this
    /// existed, or one whose picture the server never had, still points at the
    /// network — and still works, whenever the network is there.
    ///
    /// Read from inside view bodies, several times per row and again on every
    /// redraw, so whether the file is there is asked of the disk once per
    /// picture and remembered; `cache` and `forget` keep the answer true.
    static func resolve(itemId: String, kind: Kind, remote: String?) -> String? {
        let local = file(itemId: itemId, kind: kind)
        let key = "\(itemId)/\(kind.rawValue)"
        let present: Bool
        if let known = presence.withLock({ $0[key] }) {
            present = known
        } else {
            present = FileManager.default.fileExists(atPath: local.path)
            presence.withLock { $0[key] = present }
        }
        return present ? local.absoluteString : remote
    }

    /// Whether each picture is on disk, by "itemId/kind", as far as it has
    /// been asked.
    private static let presence = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// The item's folder is gone.
    static func forget(itemId: String) {
        presence.withLock { known in
            for kind in [Kind.primary, .season, .series] { known["\(itemId)/\(kind.rawValue)"] = nil }
        }
    }

    /// How long a picture the server said it didn't have is left alone before
    /// it is asked for again.
    private static let absentFor: TimeInterval = 7 * 24 * 3600

    private static func absentMarker(itemId: String, kind: Kind) -> URL {
        DownloadManager.folderPath(for: itemId).appendingPathComponent(kind.fileName + ".missing")
    }

    /// Recently told there is no such picture.
    private static func knownAbsent(itemId: String, kind: Kind) -> Bool {
        let marker = absentMarker(itemId: itemId, kind: kind)
        guard let written = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(written) < absentFor
    }

    private static func markAbsent(itemId: String, kind: Kind) {
        try? Data().write(to: absentMarker(itemId: itemId, kind: kind), options: .atomic)
    }

    /// Fetch and keep whichever of the three this record names. Idempotent:
    /// anything already on disk is left alone, so this can be called on every
    /// launch and on every download without re-fetching a thing.
    static func cache(_ record: DownloadRecord) async {
        let wanted: [(Kind, String?)] = [
            (.primary, record.imageURL),
            (.season, record.seasonImageURL),
            (.series, record.seriesImageURL),
        ]
        for (kind, remote) in wanted {
            guard let remote, let url = URL(string: remote), !url.isFileURL else { continue }
            let destination = file(itemId: record.itemId, kind: kind)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            // A picture the server answered "no" for — a show with no season
            // posters is the usual one — was asked for again on every launch,
            // for every such download, for good. It is left alone for a week
            // now. Only an answer counts: a request that got none is no
            // evidence and is tried again next time, as before.
            guard !knownAbsent(itemId: record.itemId, kind: kind) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(
                for: ImageLoader.imageRequest(url)
            ) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // A server that is struggling is not a server without the
                // picture.
                if http.statusCode < 500, http.statusCode != 429 { markAbsent(itemId: record.itemId, kind: kind) }
                continue
            }
            // Decoded before it is kept: a 200 carrying an error page is a file
            // that would sit on disk for good, standing in front of the address
            // that would have worked.
            guard !data.isEmpty, PlatformImage(data: data) != nil else {
                markAbsent(itemId: record.itemId, kind: kind)
                continue
            }
            try? FileManager.default.createDirectory(
                at: DownloadManager.folderPath(for: record.itemId),
                withIntermediateDirectories: true
            )
            try? data.write(to: destination, options: .atomic)
            presence.withLock { $0["\(record.itemId)/\(kind.rawValue)"] = nil }
            var excluded = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
        }
    }
}

extension DownloadRecord {
    /// The three addresses again, each resolved against this device first.
    /// Everything that draws a download reads these rather than the stored
    /// fields — see `DownloadArtwork`.
    var artURL: String? { DownloadArtwork.resolve(itemId: itemId, kind: .primary, remote: imageURL) }
    var seasonArtURL: String? {
        DownloadArtwork.resolve(itemId: itemId, kind: .season, remote: seasonImageURL)
    }
    var seriesArtURL: String? {
        DownloadArtwork.resolve(itemId: itemId, kind: .series, remote: seriesImageURL)
    }
}

// MARK: - Stream downloads

extension DownloadManager: AVAssetDownloadDelegate {
    /// Where the finished stream was put. AVFoundation chooses the location and
    /// this is the only time it says so, so it goes on the record here — as a
    /// path relative to the app's home directory, because the absolute one is
    /// not the same after the next launch.
    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let id = DownloadTaskKey(session, assetDownloadTask)
        let described = assetDownloadTask.taskDescription
        let path = location.relativePath
        // Written on the spot rather than from a task hopped onto the main
        // actor. This session delivers on the main queue, so the hop is
        // needless — and it was harmful: the completion callback that follows
        // this one hops the same way, and if its hop landed first the finish
        // found no path on the record and reported the download as having
        // "nowhere to put it", with the whole package sitting on disk.
        MainActor.assumeIsolated {
            // A download cancelled on purpose still owns its package while
            // nothing else has started under its item — that is what a
            // Retry resumes from.
            var retiredOwner: String?
            if self.retiredTasks.contains(id), let described, !self.tasks.values.contains(described) {
                retiredOwner = described
            }
            guard let itemId = self.itemId(forTask: id, description: described, url: nil) ?? retiredOwner,
                  var rec = self.record(for: itemId)
            else {
                // Nothing will ever point at this package: its download was
                // deleted, or replaced by a new transfer, while AVFoundation
                // was still writing it — mid-transfer the record had no path
                // to it for `delete` to remove. It goes now rather than
                // sitting on disk for good, unless the record names it (a
                // resume of this same package).
                if let described, self.record(for: described)?.hlsPath == path { return }
                try? FileManager.default.removeItem(at: location)
                return
            }
            if let old = rec.hlsPath, old != path {
                try? FileManager.default.removeItem(at: Self.hlsURL(forRelativePath: old))
            }
            rec.hlsPath = path
            self.save(rec)
        }
    }

    /// Progress for a stream is time, not bytes: how much of the running time
    /// there are segments for. It is exact — no estimate, and nothing to
    /// overshoot.
    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let id = DownloadTaskKey(session, assetDownloadTask)
        guard Self.progressHopDue(id) else { return }
        let described = assetDownloadTask.taskDescription
        // Real bytes, not a projection — the task counts what it has pulled.
        let received = assetDownloadTask.countOfBytesReceived
        Task { @MainActor in
            guard let itemId = self.itemId(forTask: id, description: described, url: nil) else { return }
            self.active.insert(itemId)
            self.noteStreamProgress(itemId: itemId, fraction: loaded / expected, received: received)
        }
    }
}

#endif

#if os(macOS)
import AppKit

extension DownloadManager {
    /// Opens the downloads folder in Finder, making it first if nothing has
    /// been downloaded yet — Finder can't show a folder that isn't there.
    @MainActor
    static func revealInFinder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}
#endif
