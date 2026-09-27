//  What is kept on the watch, and how it gets there.
//
//  Every download is one AAC file at 128 kbps in its own folder, beside a
//  meta.json that is the record of it and an art.jpg for its cover. The
//  record is the only source of truth — the folder is what is read at launch
//  — which is what lets a transfer be picked up after the app was put away.
//
//  Transfers run on a background URLSession so a book keeps arriving with the
//  wrist down. The system wakes the app for the session's events through
//  `WatchDelegate`, and one transfer runs at a time: a watch's radio and a
//  server's encoder are both better at one thing than six.
//
//  A transcode has no length the server can promise, and a stream that ends
//  early looks exactly like one that finished. So every file that lands is
//  opened and its length compared with the item's: short by more than a few
//  percent and it is thrown away and asked for again, up to three times.
//
//  Nothing here is deleted without being asked. The phone can ask, through
//  `WatchLink`, and so can the person; nothing else can.

import AVFoundation
import Foundation
import Network
import Observation
import WatchKit
import os

// MARK: - The record

struct WatchRecord: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case queued, downloading, complete, error }

    var itemId: String
    var name: String
    /// "Audio" or "AudioBook".
    var type: String
    var album: String?
    var albumId: String?
    var artist: String?
    var track: Int?
    var disc: Int?
    var year: Int?
    var runTimeTicks: Int64 = 0
    var imageTag: String?
    var albumImageTag: String?
    var fileName = "audio.m4a"
    var bytes: Int64 = 0
    var estimatedBytes: Int64 = 0
    var status: Status = .queued
    var errorMessage: String?
    var attempts = 0
    /// Why this is here: "book", "song", "album:<id>", "playlist:<id>". A
    /// group deleted takes its reason away; a record with none left goes.
    var reasons: Set<String> = []
    /// Put here by the mirror plan rather than a tap. Waits for Wi-Fi.
    var automatic = false
    /// Being fetched by the phone and handed over as a file, rather than
    /// by this watch's own radio. Set when the phone was asked, and moved
    /// on each time the phone shows it is still at it — progress, a piece
    /// arriving — so patience runs from the phone's last word, not the ask.
    var relayAskedAt: Date?
    var createdAt = Date()
    /// Listening, kept here so a book opens where it was left with no server.
    var positionTicks: Int64 = 0
    var played = false
    var lastPlayedAt: Date?
    /// Whether the server has heard everything noted here. Cleared by each
    /// note, set once the server has taken an event at least as new as it.
    var progressSynced = true
    /// When the listening here last moved, for weighing it against the
    /// server's last play.
    var localChangedAt: Date?
    var chapters: [ChapterInfo]?
    var overview: String?

    var id: String { itemId }
    var isAudiobook: Bool { type == "AudioBook" }

    init(item: BaseItem, reasons: Set<String>, automatic: Bool) {
        itemId = item.Id
        name = item.title
        type = item.kind == "AudioBook" ? "AudioBook" : "Audio"
        album = item.Album
        albumId = item.AlbumId
        artist = item.artistLine.isEmpty ? nil : item.artistLine
        track = item.IndexNumber
        disc = item.ParentIndexNumber
        year = item.ProductionYear
        runTimeTicks = item.RunTimeTicks ?? 0
        imageTag = item.ImageTags?["Primary"] ?? item.PrimaryImageTag
        albumImageTag = item.AlbumPrimaryImageTag
        estimatedBytes = JellyfinClient.estimatedBytes(for: item)
        self.reasons = reasons
        self.automatic = automatic
        positionTicks = item.userData.positionTicks
        played = item.userData.played
        chapters = item.Chapters
        overview = item.Overview
    }

    /// Key by key, so a field added later never empties the folder written
    /// by the build before.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decode(String.self, forKey: .itemId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Audio"
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        disc = try c.decodeIfPresent(Int.self, forKey: .disc)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: .runTimeTicks) ?? 0
        imageTag = try c.decodeIfPresent(String.self, forKey: .imageTag)
        albumImageTag = try c.decodeIfPresent(String.self, forKey: .albumImageTag)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "audio.m4a"
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        estimatedBytes = try c.decodeIfPresent(Int64.self, forKey: .estimatedBytes) ?? 0
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        reasons = try c.decodeIfPresent(Set<String>.self, forKey: .reasons) ?? ["song"]
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        relayAskedAt = try c.decodeIfPresent(Date.self, forKey: .relayAskedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        positionTicks = try c.decodeIfPresent(Int64.self, forKey: .positionTicks) ?? 0
        played = try c.decodeIfPresent(Bool.self, forKey: .played) ?? false
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        progressSynced = try c.decodeIfPresent(Bool.self, forKey: .progressSynced) ?? true
        localChangedAt = try c.decodeIfPresent(Date.self, forKey: .localChangedAt)
        chapters = try c.decodeIfPresent([ChapterInfo].self, forKey: .chapters)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
    }

    /// The record as an item, for the player and the rows: enough to play
    /// it, name it and find its cover, with no server behind any of it.
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
        item.Chapters = chapters
        item.Overview = overview
        if let imageTag { item.ImageTags = ["Primary": imageTag] }
        item.AlbumPrimaryImageTag = albumImageTag
        item.UserData = UserData(PlaybackPositionTicks: positionTicks, Played: played)
        let art = WatchDownloads.artFile(itemId)
        if FileManager.default.fileExists(atPath: art.path) { item.ExternalLogoURL = art.absoluteString }
        return item
    }

    /// Where a book opens: where it was left, or the top once it is done.
    var resumeSeconds: Double {
        if played { return 0 }
        if isAudiobook {
            if BookProgress.isFinished(positionTicks: positionTicks, runTimeTicks: runTimeTicks) { return 0 }
        } else if runTimeTicks > 0, Double(positionTicks) / Double(runTimeTicks) > 0.98 {
            return 0
        }
        return Double(positionTicks) / 10_000_000
    }

    var progressFraction: Double? {
        guard !played, runTimeTicks > 0, positionTicks > 0 else { return nil }
        return min(1, Double(positionTicks) / Double(runTimeTicks))
    }
}

/// A playlist as the watch keeps it: its name and its songs, in order.
struct WatchPlaylist: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var itemIds: [String]
    var automatic = false
    var imageTag: String?
}

// MARK: - The store

@MainActor
@Observable
final class WatchDownloads: NSObject {
    static let shared = WatchDownloads()

    nonisolated static let log = Logger(subsystem: "scottai.FellyJin.watchkitapp", category: "downloads")
    nonisolated static let sessionIdentifier = "scottai.FellyJin.watchkitapp.downloads"

    private(set) var records: [WatchRecord] = []
    private(set) var playlists: [WatchPlaylist] = []
    /// Bytes so far for the transfer running, by item.
    private(set) var liveBytes: [String: (received: Int64, expected: Int64)] = [:]
    private(set) var revision = 0
    /// The last mirror plan the phone sent.
    private(set) var plan = WatchMirrorPlan()
    private(set) var isOnWiFi = true
    private(set) var hasNetwork = true
    /// Whether the path monitor has spoken yet. Until it has, `isOnWiFi`
    /// is a guess, and a pump on the guess cancelled the phone's fetch at
    /// launch and started the watch's own over Bluetooth.
    private var pathKnown = false
    private(set) var mirrorNote: String?

    var onChange: (() -> Void)?

    private var byId: [String: Int] = [:]
    /// Task identifiers → item, kept across launches so a relaunch can tell
    /// which transfer the session's events are about. Behind a lock: the
    /// session's delegate asks from its own queue.
    @ObservationIgnored nonisolated private let taskMap = OSAllocatedUnfairLock(initialState: [Int: String]())
    /// Bytes last passed on for each transfer, so the session's stream of
    /// reports is thinned before it reaches the main thread.
    @ObservationIgnored nonisolated private let lastReported = OSAllocatedUnfairLock(initialState: [String: Int64]())
    private var tasks: [Int: String] {
        get { taskMap.withLock { $0 } }
        set { taskMap.withLock { $0 = newValue } }
    }
    private var active: String?
    private var mirrorTask: Task<Void, Never>?
    /// Items this watch failed to fetch for itself: asked of the phone next,
    /// even on Wi‑Fi. A watch on a network that can't reach the server
    /// (a TLS failure, a timeout) otherwise retries the same dead route.
    private var viaPhone: Set<String> = []
    /// Items the phone has shown progress on since launch: asked for and
    /// under way, not merely asked for.
    private var phoneWorking: Set<String> = []
    /// Bumped when the plan changes, so a mirror pass still working from the
    /// old plan stops queueing, and its end doesn't clear the new one's task.
    private var mirrorGeneration = 0
    /// When each playlist was last matched to the server's, so a wrist
    /// raised every minute doesn't fetch every list every time.
    private var playlistSyncedAt: [String: Date] = [:]
    private static let playlistSyncInterval: TimeInterval = 10 * 60
    /// Playlists taken off here, and when. A plan the phone built before it
    /// heard still names them, and would put them straight back; the phone
    /// is given a while to catch up before its word counts again.
    private var droppedPlaylists: [String: Date] = [:]
    private static let dropGrace: TimeInterval = 10 * 60
    /// Things a background wake is still doing — a file being measured, the
    /// next transfer being started — before the app may be put back to sleep.
    private var settling = 0
    private var pendingItems: [String: BaseItem] = [:]
    private let pathMonitor = NWPathMonitor()
    private var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        records = Self.loadRecords()
        reindex()
        playlists = Self.loadPlaylists()
        if let data = UserDefaults.standard.data(forKey: "watch_tasks"),
           let saved = try? JSONDecoder().decode([Int: String].self, from: data) {
            tasks = saved
        }
        if let data = UserDefaults.standard.data(forKey: "watch_plan"),
           let saved = try? JSONDecoder().decode(WatchMirrorPlan.self, from: data) {
            plan = saved
        }
        if let data = UserDefaults.standard.data(forKey: "watch_dropped_playlists"),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            droppedPlaylists = saved
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Wi‑Fi of the watch's own. Through the phone the path is
            // neither Wi‑Fi nor cellular, and the phone is the better carrier.
            // Wired is the Simulator's word for the Mac's connection; a watch
            // has no such thing, so it costs nothing to count it.
            let wifi = (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive
            let up = path.status == .satisfied
            WatchLog.note("downloads", "network: \(up ? "up" : "down") via \(path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")) expensive=\(path.isExpensive)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let gained = up && !self.hasNetwork
                let first = !self.pathKnown
                self.pathKnown = true
                self.isOnWiFi = wifi
                self.hasNetwork = up
                if gained || first { self.pump() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "aquarium.watch.path"))
        // Anything the session still has running is picked up; anything the
        // records say was running and the session has forgotten goes back
        // in the queue.
        rejoin()
    }

    // MARK: - Storage layout

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aquarium/Watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static func folder(_ itemId: String) -> URL {
        root.appendingPathComponent(JellyfinClient.pathId(itemId), isDirectory: true)
    }

    nonisolated static func artFile(_ itemId: String) -> URL { folder(itemId).appendingPathComponent("art.jpg") }

    private nonisolated static var playlistsFile: URL { root.appendingPathComponent("playlists.json") }

    private nonisolated static func loadRecords() -> [WatchRecord] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [WatchRecord] = []
        for dir in dirs {
            let meta = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  var record = try? JSONDecoder().decode(WatchRecord.self, from: data) else { continue }
            if record.status == .complete {
                let file = dir.appendingPathComponent(record.fileName)
                if !fm.fileExists(atPath: file.path) {
                    record.status = .error
                    record.errorMessage = "The file is no longer on the watch"
                    record.bytes = 0
                }
            }
            out.append(record)
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    private nonisolated static func loadPlaylists() -> [WatchPlaylist] {
        guard let data = try? Data(contentsOf: playlistsFile) else { return [] }
        return (try? JSONDecoder().decode([WatchPlaylist].self, from: data)) ?? []
    }

    private func reindex() {
        byId = [:]
        for (i, r) in records.enumerated() { byId[r.itemId] = i }
    }

    private func save(_ record: WatchRecord) {
        if let i = byId[record.itemId] {
            records[i] = record
        } else {
            records.insert(record, at: 0)
            reindex()
        }
        let folder = Self.folder(record.itemId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        }
        changed()
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: Self.playlistsFile, options: .atomic) }
        changed()
    }

    private func persistTasks() {
        UserDefaults.standard.set(try? JSONEncoder().encode(tasks), forKey: "watch_tasks")
    }

    private func changed() {
        revision &+= 1
        onChange?()
    }

    // MARK: - Reading

    func record(for itemId: String) -> WatchRecord? {
        byId[itemId].map { records[$0] }
    }

    func isComplete(_ itemId: String) -> Bool { record(for: itemId)?.status == .complete }

    /// The watch's own transfer is being set up for this item.
    func isStarting(_ itemId: String) -> Bool { active == itemId && liveBytes[itemId] == nil }

    func isQueuedOrRunning(_ itemId: String) -> Bool {
        guard let r = record(for: itemId) else { return false }
        return r.status == .queued || r.status == .downloading
    }

    func mediaURL(for record: WatchRecord) -> URL? {
        guard record.status == .complete else { return nil }
        let url = Self.folder(record.itemId).appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// How far a running transfer has got, 0...1, against the estimate.
    func fraction(_ itemId: String) -> Double? {
        guard let live = liveBytes[itemId] else { return nil }
        let expected = live.expected > 0 ? live.expected : (record(for: itemId)?.estimatedBytes ?? 0)
        guard expected > 0 else { return nil }
        return min(0.99, Double(live.received) / Double(expected))
    }

    var complete: [WatchRecord] { records.filter { $0.status == .complete } }
    var inFlight: [WatchRecord] { records.filter { $0.status == .queued || $0.status == .downloading } }

    /// What the phone was asked for and hasn't delivered: all it should be
    /// fetching for this watch.
    var awaitingPhone: [String] { records.filter { $0.status == .downloading && $0.relayAskedAt != nil }.map(\.itemId) }
    var failed: [WatchRecord] { records.filter { $0.status == .error } }
    var books: [WatchRecord] { complete.filter(\.isAudiobook).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var songs: [WatchRecord] { complete.filter { !$0.isAudiobook } }
    var totalBytes: Int64 { complete.reduce(0) { $0 + $1.bytes } }

    /// Books started and not finished, most recently heard first.
    var booksInProgress: [WatchRecord] {
        books.filter { $0.progressFraction != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    /// The albums the downloaded songs belong to, one entry each.
    var albums: [BaseItem] { songs.map(\.asItem).albumsInOrder().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }

    func albumTracks(albumId: String) -> [BaseItem] {
        songs.filter { $0.albumId == albumId }.map(\.asItem).sortedByTrack()
    }

    func playlistSongs(_ list: WatchPlaylist) -> [BaseItem] {
        list.itemIds.compactMap { record(for: $0) }.filter { $0.status == .complete }.map(\.asItem)
    }

    nonisolated static func freeBytes() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: - Queueing

    /// Keep these. `reason` says what they were asked for as, and decides
    /// what a later delete of that thing takes with it.
    @discardableResult
    func enqueue(_ items: [BaseItem], reason: String, automatic: Bool = false) -> Int {
        // One pass, one index rebuild, one note to the phone, and the
        // records' files written off the main thread: a playlist of
        // fifteen hundred songs queued one save at a time held the main
        // thread long enough for the watch to kill the app part-way.
        var queued = 0
        var fresh: [WatchRecord] = []
        var touched: [WatchRecord] = []
        var seen = Set<String>()
        for item in items where item.isAudio && seen.insert(item.Id).inserted {
            if var existing = record(for: item.Id) {
                var changed = false
                if !existing.reasons.contains(reason) { existing.reasons.insert(reason); changed = true }
                if existing.automatic, !automatic { existing.automatic = false; changed = true }
                if existing.status == .error { existing.status = .queued; existing.errorMessage = nil; existing.attempts = 0; changed = true; queued += 1 }
                if existing.chapters == nil, let chapters = item.Chapters { existing.chapters = chapters; changed = true }
                if changed { records[byId[item.Id]!] = existing; touched.append(existing) }
                continue
            }
            let record = WatchRecord(item: item, reasons: [reason], automatic: automatic)
            pendingItems[item.Id] = item
            fresh.append(record)
            queued += 1
        }
        if !fresh.isEmpty {
            records.insert(contentsOf: fresh, at: 0)
            reindex()
        }
        if !fresh.isEmpty || !touched.isEmpty {
            Self.writeMeta(fresh + touched)
            changed()
        }
        WatchLog.note("downloads", "queued \(queued) of \(items.count) as \(reason)\(automatic ? " (automatic)" : ""), \(records.count) records, \(WatchLog.memory)")
        pump()
        return queued
    }

    /// Each record to its folder, in the background: the caller has already
    /// put them in `records`, which is what the app reads.
    private nonisolated static func writeMeta(_ list: [WatchRecord]) {
        let encoded: [(String, Data)] = list.compactMap { r in (try? JSONEncoder().encode(r)).map { (r.itemId, $0) } }
        Task.detached(priority: .utility) {
            for (itemId, data) in encoded {
                let folder = folder(itemId)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
            }
        }
    }

    func retry(_ itemId: String) {
        guard var r = record(for: itemId), r.status == .error else { return }
        r.status = .queued
        r.errorMessage = nil
        r.attempts = 0
        r.relayAskedAt = nil
        save(r)
        pump()
    }

    func retryAllFailed() {
        for r in failed { retry(r.itemId) }
    }

    /// Cancel and forget a download that hasn't finished.
    func cancel(_ itemId: String) {
        WatchLog.note("downloads", "cancel \(itemId)")
        if active == itemId { cancelActiveTask() }
        if record(for: itemId)?.relayAskedAt != nil { WatchLink.shared.send(.cancelFetch(itemId: itemId)) }
        removeFolder(itemId)
    }

    // MARK: - Deleting

    func delete(_ itemId: String) {
        if active == itemId { cancelActiveTask() }
        if record(for: itemId)?.relayAskedAt != nil { WatchLink.shared.send(.cancelFetch(itemId: itemId)) }
        removeFolder(itemId)
        for i in playlists.indices { playlists[i].itemIds.removeAll { $0 == itemId } }
        savePlaylists()
    }

    /// Take away one reason for these records to be here; whatever has none
    /// left is deleted. What a group's delete does.
    private func withdraw(reason: String, from itemIds: [String]) {
        for id in itemIds {
            guard var r = record(for: id) else { continue }
            r.reasons.remove(reason)
            if r.reasons.isEmpty {
                if active == id { cancelActiveTask() }
                if r.relayAskedAt != nil, r.status != .complete { WatchLink.shared.send(.cancelFetch(itemId: id)) }
                removeFolder(id)
            } else {
                save(r)
            }
        }
    }

    func deleteBook(_ itemId: String) { delete(itemId) }

    func deleteAlbum(_ albumId: String) {
        let ids = records.filter { $0.albumId == albumId && !$0.isAudiobook }.map(\.itemId)
        // Songs kept for an album, or on their own, go with the album; songs
        // that are also in a kept playlist stay for it.
        for id in ids {
            guard var r = record(for: id) else { continue }
            r.reasons.remove("album:\(albumId)")
            r.reasons.remove("song")
            if r.reasons.isEmpty {
                if active == id { cancelActiveTask() }
                removeFolder(id)
            } else {
                save(r)
            }
        }
        pump()
    }

    func deletePlaylist(_ playlistId: String) {
        guard let list = playlists.first(where: { $0.id == playlistId }) else { return }
        withdraw(reason: "playlist:\(playlistId)", from: list.itemIds)
        playlists.removeAll { $0.id == playlistId }
        playlistSyncedAt[playlistId] = nil
        savePlaylists()
        dropped([playlistId])
        pump()
    }

    /// Playlists taken off the watch here: the phone is told, so its
    /// "Kept on the watch" switch goes off and its plan stops naming them,
    /// and until it has caught up its plan's word on them is set aside.
    private func dropped(_ playlistIds: [String]) {
        guard !playlistIds.isEmpty else { return }
        let now = Date()
        for id in playlistIds {
            droppedPlaylists[id] = now
            WatchLink.shared.send(.playlistRemoved(id: id))
        }
        persistDropped()
    }

    private func persistDropped() {
        droppedPlaylists = droppedPlaylists.filter { Date().timeIntervalSince($0.value) < Self.dropGrace }
        UserDefaults.standard.set(try? JSONEncoder().encode(droppedPlaylists), forKey: "watch_dropped_playlists")
    }

    /// The plan's playlists, less those just taken off here.
    var plannedPlaylistIds: [String] {
        plan.playlistIds.filter { id in droppedPlaylists[id].map { Date().timeIntervalSince($0) >= Self.dropGrace } ?? true }
    }

    /// Loose songs: those here for no album, playlist or book.
    func deleteLooseSongs() {
        let loose = songs.filter { $0.reasons == ["song"] }.map(\.itemId)
        for id in loose { removeFolder(id) }
    }

    func deleteEverything() {
        cancelActiveTask()
        for r in records { removeFolder(r.itemId, quiet: true) }
        records = []
        reindex()
        dropped(Array(Set(playlists.map(\.id) + plan.playlistIds)))
        playlists = []
        playlistSyncedAt = [:]
        tasks = [:]
        persistTasks()
        try? FileManager.default.removeItem(at: Self.root)
        savePlaylists()
    }

    private func removeFolder(_ itemId: String, quiet: Bool = false) {
        try? FileManager.default.removeItem(at: Self.folder(itemId))
        pendingItems[itemId] = nil
        liveBytes[itemId] = nil
        lastReported.withLock { $0[itemId] = nil }
        WatchImages.forget(itemId)
        guard !quiet else { return }
        if let i = byId[itemId] {
            records.remove(at: i)
            reindex()
        }
        changed()
    }

    // MARK: - Listening

    /// Where a file was left, and whether it is finished. Written locally;
    /// the server hears through `WatchSyncQueue`.
    func noteProgress(itemId: String, positionSeconds: Double, played: Bool? = nil) {
        guard var r = record(for: itemId) else { return }
        r.positionTicks = Int64(max(0, positionSeconds) * 10_000_000)
        let finished = r.isAudiobook
            ? BookProgress.isFinished(positionTicks: r.positionTicks, runTimeTicks: r.runTimeTicks)
            : r.runTimeTicks > 0 && Double(r.positionTicks) / Double(r.runTimeTicks) > 0.98
        if let played {
            r.played = played
        } else if r.played, r.isAudiobook, positionSeconds > 30, !finished {
            // Started again after finishing.
            r.played = false
        }
        if finished { r.played = true }
        let now = Date()
        r.lastPlayedAt = now
        r.localChangedAt = now
        r.progressSynced = false
        save(r)
    }

    /// The server has taken an event heard at `at`. The record is in step
    /// unless it has moved on since.
    func markSynced(itemId: String, through at: Date) {
        guard var r = record(for: itemId), !r.progressSynced else { return }
        if let changed = r.localChangedAt, changed.timeIntervalSince(at) > 1 { return }
        r.progressSynced = true
        save(r)
    }

    /// Books whose listening the server hasn't had and nothing queued will
    /// tell it: the app put away between the last note and the next event.
    /// One event each, from the record, dated when it was heard.
    func unsentBookEvents(except pending: Set<String>) -> [WatchProgressEvent] {
        let playing = WatchPlayer.shared.isActive ? WatchPlayer.shared.current?.Id : nil
        return records.filter { $0.isAudiobook && !$0.progressSynced && !pending.contains($0.itemId) && $0.itemId != playing }
            .map { r in
                WatchProgressEvent(
                    itemId: r.itemId, positionTicks: r.played ? r.runTimeTicks : r.positionTicks,
                    played: r.played, isAudiobook: true, at: r.localChangedAt ?? Date()
                )
            }
    }

    /// The server's word on a book — a chapter listened to on the phone last
    /// night — taken unless the watch has something newer to say: listening
    /// still queued, or noted since the server last heard and later than the
    /// book was last started anywhere else.
    func applyServerState(itemId: String, positionTicks: Int64, played: Bool, lastPlayed: Date?) {
        guard var r = record(for: itemId) else { return }
        guard !WatchSyncQueue.shared.hasPending(for: itemId) else { return }
        guard BookProgress.takesServer(synced: r.progressSynced, localChangedAt: r.localChangedAt, serverLastPlayed: lastPlayed) else {
            WatchLog.note("downloads", "keeping the watch's place in \(itemId): newer than the server's")
            return
        }
        guard r.positionTicks != positionTicks || r.played != played || !r.progressSynced else { return }
        r.positionTicks = positionTicks
        r.played = played
        r.progressSynced = true
        save(r)
    }

    // MARK: - The pump

    /// How long a phone is given, from its last word, before the watch
    /// tries by itself.
    private static let relayPatience: TimeInterval = 20 * 60
    /// A phone heard from this recently is well into an item: the watch
    /// finding Wi‑Fi of its own doesn't take that one back.
    private static let phoneBusyWindow: TimeInterval = 10 * 60

    /// Start the next transfer, if there is one and something can carry it.
    ///
    /// On Wi‑Fi of its own the watch fetches for itself. Through the
    /// phone's Bluetooth link a background download session is throttled to
    /// a crawl, so there the item is asked of the phone, which fetches it on
    /// its own connection and hands the file across — a transfer that runs
    /// in the background on both ends, in reach or not. Cellular carries
    /// what was asked for by hand, never the mirror's things; and the phone
    /// gets a long while before the watch takes an item back.
    func pump() {
        guard JellyfinClient.shared.isSignedIn, pathKnown else { return }
        let link = WatchLink.shared
        let phone = link.hasCompanion && !isOnWiFi
        // Anything the phone was asked for is taken back only when this
        // watch will fetch it itself: on Wi‑Fi of its own, or with no phone
        // app to ask. Taken back anywhere else, it went straight back to the
        // phone, which started the whole book again. On Wi‑Fi, an item the
        // phone is well into stays the phone's unless it has gone quiet.
        if hasNetwork {
            for var r in records where r.status == .downloading && r.relayAskedAt != nil && active != r.itemId {
                let quiet = Date().timeIntervalSince(r.relayAskedAt!)
                let overdue = quiet > Self.relayPatience && !link.isPhoneReachable
                let busy = phoneWorking.contains(r.itemId) && quiet < Self.phoneBusyWindow
                let fetchesItself = isOnWiFi || (!link.hasCompanion && !r.automatic)
                if fetchesItself, (!viaPhone.contains(r.itemId) && !busy) || overdue {
                    link.send(.cancelFetch(itemId: r.itemId))
                    r.status = .queued
                    r.relayAskedAt = nil
                    save(r)
                }
            }
        }
        // Asked-for things first; the mirror's things only when a phone
        // will carry them or the watch is on Wi‑Fi.
        let candidates = makeRoom(for: records.filter { $0.status == .queued }
            .sorted { a, b in
                if a.automatic != b.automatic { return !a.automatic }
                return a.createdAt < b.createdAt
            })
        let forPhone = phone ? candidates : link.hasCompanion ? candidates.filter { viaPhone.contains($0.itemId) } : []
        if !forPhone.isEmpty {
            // Every queued item goes to the phone at once: its queue is the
            // reliable one, and it downloads a few at a time on its own. One
            // message carries them all, a few hundred at a time.
            var asked: [WatchRecord] = []
            for var r in forPhone where r.relayAskedAt == nil {
                r.status = .downloading
                r.relayAskedAt = Date()
                records[byId[r.itemId]!] = r
                asked.append(r)
            }
            if !asked.isEmpty {
                Self.writeMeta(asked)
                changed()
                let ids = asked.map(\.itemId)
                if ids.count == 1 {
                    link.send(.fetch(itemId: ids[0]))
                } else {
                    for start in stride(from: 0, to: ids.count, by: 200) {
                        link.send(.fetchMany(itemIds: Array(ids[start..<min(start + 200, ids.count)])))
                    }
                }
                WatchLog.note("downloads", "asked the phone for \(ids.count) items")
            }
            if phone { return }
        }
        guard active == nil, hasNetwork else { return }
        guard let next = candidates.first(where: { (!$0.automatic || isOnWiFi) && !viaPhone.contains($0.itemId) }) else { return }
        settling += 1
        Task {
            await start(next)
            settling -= 1
        }
    }

    /// The app is being put away. The watch's own session fetches one item
    /// at a time and needs the app woken between them, which watchOS allows
    /// only now and then; the phone's downloads and file transfers carry on
    /// in the background by themselves. So with the phone in reach, what is
    /// still waiting goes to it, and stays its for as long as the app runs.
    func handOffToPhone() {
        let link = WatchLink.shared
        guard link.hasCompanion, link.isPhoneReachable else { return }
        let waiting = records.filter { $0.status == .queued && $0.itemId != active }.map(\.itemId)
        guard !waiting.isEmpty else { return }
        viaPhone.formUnion(waiting)
        WatchLog.note("downloads", "put away: handing \(waiting.count) waiting items to the phone")
        pump()
    }

    /// Space kept free for watchOS and everything else on the watch.
    private static let spareBytes: Int64 = 500 * 1024 * 1024

    /// The queued items that fit, in order; what doesn't fit is failed now
    /// with the sizes, rather than downloaded for an hour and refused at
    /// the end. What is already on its way has its room taken first.
    private func makeRoom(for candidates: [WatchRecord]) -> [WatchRecord] {
        guard let free = Self.freeBytes() else { return candidates }
        let coming = records.filter { $0.status == .downloading }
            .reduce(Int64(0)) { sum, r in sum + max(0, r.estimatedBytes - (liveBytes[r.itemId]?.received ?? 0)) }
        var room = free - Self.spareBytes - coming
        var fitting: [WatchRecord] = []
        for var r in candidates {
            if r.estimatedBytes <= room {
                room -= max(0, r.estimatedBytes)
                fitting.append(r)
                continue
            }
            let size = ByteCountFormatter.string(fromByteCount: r.estimatedBytes, countStyle: .file)
            let left = ByteCountFormatter.string(fromByteCount: max(0, free - Self.spareBytes), countStyle: .file)
            WatchLog.error("downloads", "no room for \(r.itemId): needs \(size), \(left) usable")
            r.status = .error
            r.errorMessage = "Not enough space: needs \(size), \(left) free"
            save(r)
        }
        return fitting
    }

    /// How far the phone has got with an item it is fetching.
    func notePhoneProgress(itemId: String, fraction: Double) {
        guard let r = record(for: itemId), r.status == .downloading, r.relayAskedAt != nil else { return }
        let expected = r.estimatedBytes > 0 ? r.estimatedBytes : 1
        liveBytes[itemId] = (Int64(Double(expected) * max(0, min(1, fraction))), expected)
        phoneStillAtIt(itemId)
    }

    /// The phone is still fetching or sending an item: its patience starts
    /// again. Written down at most once a minute.
    func phoneStillAtIt(_ itemId: String) {
        phoneWorking.insert(itemId)
        guard var r = record(for: itemId), r.status == .downloading, let asked = r.relayAskedAt,
              Date().timeIntervalSince(asked) > 60 else { return }
        r.relayAskedAt = Date()
        save(r)
    }

    /// The phone gave up on an item. The watch tries itself when it can,
    /// and otherwise says why.
    func phoneFailed(itemId: String, reason: String) {
        WatchLog.error("downloads", "phone gave up on \(itemId): \(reason)")
        guard var r = record(for: itemId), r.relayAskedAt != nil else { return }
        r.relayAskedAt = nil
        liveBytes[itemId] = nil
        lastReported.withLock { $0[itemId] = nil }
        if hasNetwork, isOnWiFi || !r.automatic {
            r.status = .queued
            save(r)
            pump()
        } else {
            r.status = .error
            r.errorMessage = reason
            save(r)
        }
    }

    /// A file the phone handed over, already moved into place by the link.
    func receivedFromPhone(itemId: String, at url: URL, bytes: Int64) async {
        guard let r = record(for: itemId) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if r.status == .complete {
            // Arrived twice — a phone that resent, or a watch that fetched
            // for itself in the meantime.
            if url.lastPathComponent != r.fileName { try? FileManager.default.removeItem(at: url) }
            return
        }
        await landed(itemId: itemId, at: url, bytes: bytes)
    }

    private func start(_ record: WatchRecord) async {
        guard active == nil else { return }
        active = record.itemId
        var item = pendingItems[record.itemId]
        // The download address wants the media source; a record restored
        // from disk has to ask the server again.
        if item?.MediaSources?.isEmpty != false {
            item = try? await JellyfinClient.shared.item(record.itemId)
        }
        guard active == record.itemId else { return }
        var rec = self.record(for: record.itemId) ?? record
        if let item {
            if rec.chapters == nil { rec.chapters = item.Chapters }
            if rec.runTimeTicks == 0 { rec.runTimeTicks = item.RunTimeTicks ?? 0 }
            if rec.estimatedBytes == 0 { rec.estimatedBytes = JellyfinClient.estimatedBytes(for: item) }
        }
        guard let (request, fileExtension) = JellyfinClient.shared.downloadRequest(for: item ?? rec.asItem) else {
            rec.status = .error
            rec.errorMessage = "Not signed in"
            save(rec)
            active = nil
            return
        }
        rec.status = .downloading
        rec.relayAskedAt = nil
        rec.errorMessage = nil
        save(rec)
        let task = session.downloadTask(with: request)
        // Kept on the task, so it survives a relaunch with it.
        task.taskDescription = fileExtension
        tasks[task.taskIdentifier] = rec.itemId
        persistTasks()
        liveBytes[rec.itemId] = (0, rec.estimatedBytes)
        task.resume()
        WatchLog.note("downloads", "downloading \(rec.itemId) attempt \(rec.attempts) as .\(fileExtension)\(fileExtension == "m4a" ? "" : " (the server's file)")")
    }

    private func cancelActiveTask() {
        guard let id = active else { return }
        session.getAllTasks { tasks in
            for task in tasks where self.taskItem(task) == id { task.cancel() }
        }
        active = nil
        liveBytes[id] = nil
    }

    private nonisolated func taskItem(_ task: URLSessionTask) -> String? {
        taskMap.withLock { $0[task.taskIdentifier] }
    }

    /// At launch: the session's live tasks stand; records marked downloading
    /// with no task behind them are queued again.
    private func rejoin() {
        session.getAllTasks { live in
            Task { @MainActor in
                let running = Set(live.compactMap { self.tasks[$0.taskIdentifier] })
                for var r in self.records where r.status == .downloading {
                    if running.contains(r.itemId) {
                        self.active = r.itemId
                    } else if r.relayAskedAt == nil {
                        r.status = .queued
                        self.save(r)
                    }
                    // Asked of the phone: still the phone's, until it is
                    // delivered or the pump loses patience.
                }
                self.tasks = self.tasks.filter { running.contains($0.value) }
                self.persistTasks()
                self.pump()
            }
        }
    }

    /// The system woke the app for the background session. Held until the
    /// session says its events are delivered, and then until what they set
    /// going is done: let go as soon as the events were in, the app slept
    /// with the file still being measured and the next transfer not yet
    /// started, and the queue sat until somebody opened the app.
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session
    }

    private func releaseBackgroundWake() {
        guard let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        Task {
            // A moment first: the landing the last event set off may not
            // have started yet. Then up to twenty seconds for it to settle.
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<80 where settling > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            if settling > 0 { WatchLog.note("downloads", "background wake let go with \(settling) things unfinished") }
            WatchDelegate.scheduleRefresh()
            completion()
        }
    }

    // MARK: - Landing

    /// A file has arrived. Opened and measured before it is believed.
    private func landed(itemId: String, at url: URL, bytes: Int64) async {
        settling += 1
        defer { settling -= 1 }
        guard var rec = record(for: itemId) else {
            try? FileManager.default.removeItem(at: url)
            finishActive(itemId)
            return
        }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let expected = Double(rec.runTimeTicks) / 10_000_000
        let whole = seconds.isFinite && seconds > 0 && (expected <= 0 || seconds >= expected * 0.97)
        if !whole {
            try? FileManager.default.removeItem(at: url)
            WatchLog.error("downloads", "\(itemId) arrived short: \(seconds)s of \(expected)s")
            rec.relayAskedAt = nil
            rec.attempts += 1
            if rec.attempts < 3 {
                rec.status = .queued
                rec.errorMessage = nil
            } else {
                rec.status = .error
                rec.errorMessage = "The file arrived incomplete"
            }
            save(rec)
            finishActive(itemId)
            return
        }
        WatchLog.note("downloads", "\(itemId) landed: \(Int(seconds))s, \(bytes / 1024)KB")
        viaPhone.remove(itemId)
        rec.fileName = url.lastPathComponent
        rec.status = .complete
        rec.bytes = bytes
        rec.relayAskedAt = nil
        rec.errorMessage = nil
        if rec.runTimeTicks == 0, seconds.isFinite { rec.runTimeTicks = Int64(seconds * 10_000_000) }
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        save(rec)
        pendingItems[itemId] = nil
        finishActive(itemId)
        await cacheArt(for: rec)
    }

    private func failed(itemId: String, message: String) {
        guard var rec = record(for: itemId) else { finishActive(itemId); return }
        WatchLog.error("downloads", "\(itemId) failed (attempt \(rec.attempts + 1)): \(message)")
        rec.attempts += 1
        if WatchLink.shared.hasCompanion, !viaPhone.contains(itemId) {
            // This watch couldn't fetch it; the phone gets the next try.
            viaPhone.insert(itemId)
            WatchLog.note("downloads", "\(itemId): asking the phone next")
        }
        if rec.attempts < 3, hasNetwork {
            rec.status = .queued
        } else {
            rec.status = .error
            rec.errorMessage = message
        }
        save(rec)
        finishActive(itemId)
    }

    private func finishActive(_ itemId: String) {
        if active == itemId { active = nil }
        liveBytes[itemId] = nil
        lastReported.withLock { $0[itemId] = nil }
        tasks = tasks.filter { $0.value != itemId }
        persistTasks()
        pump()
    }

    /// The cover, kept beside the file so the row draws with no server.
    private func cacheArt(for record: WatchRecord) async {
        let file = Self.artFile(record.itemId)
        guard !FileManager.default.fileExists(atPath: file.path),
              let url = JellyfinClient.shared.imageURL(for: record.asItem, width: 200) else { return }
        var req = URLRequest(url: url)
        for (k, v) in JellyfinClient.shared.authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              !data.isEmpty else { return }
        try? data.write(to: file, options: .atomic)
        WatchImages.forget(record.itemId)
        changed()
    }

    // MARK: - The mirror

    /// Keep the phone's plan and act on it when there is a network.
    func apply(plan: WatchMirrorPlan) {
        if plan != self.plan {
            self.plan = plan
            UserDefaults.standard.set(try? JSONEncoder().encode(plan), forKey: "watch_plan")
            mirrorTask?.cancel()
            mirrorTask = nil
            mirrorGeneration += 1
        }
        // A plan that no longer names a playlist taken off here: the phone
        // has caught up, and its word counts again.
        let caughtUp = droppedPlaylists.keys.filter { !plan.playlistIds.contains($0) }
        if !caughtUp.isEmpty {
            for id in caughtUp { droppedPlaylists[id] = nil }
            persistDropped()
        }
        // What the phone asked for by itself and no longer does is dropped
        // from the queue; what already arrived stays until removed by hand.
        let planned = Set(plannedPlaylistIds)
        let wanted = Set(plan.bookIds + playlists.filter { planned.contains($0.id) || !$0.automatic }.flatMap(\.itemIds))
        for r in inFlight where r.automatic && !wanted.contains(r.itemId) && r.reasons.allSatisfy({ $0 == "book" || $0.hasPrefix("playlist:") }) {
            cancel(r.itemId)
        }
        mirror()
    }

    /// Fetch what the plan names and queue whatever is missing, and match
    /// every playlist on the watch to the server's — the plan's and those
    /// downloaded by hand alike. Books come with their chapters.
    ///
    /// `force` (Sync Now) matches every playlist whenever it was last
    /// looked at, and queues again any of its songs not on the watch.
    func mirror(force: Bool = false) {
        guard mirrorTask == nil, hasNetwork, JellyfinClient.shared.isSignedIn else { return }
        let plan = plan
        let planned = plannedPlaylistIds
        let lists = planned + playlists.map(\.id).filter { !planned.contains($0) }
        guard !plan.bookIds.isEmpty || !lists.isEmpty else { return }
        let generation = mirrorGeneration
        mirrorTask = Task {
            defer { if mirrorGeneration == generation { mirrorTask = nil } }
            let client = JellyfinClient.shared
            var queued = 0
            let missingBooks = plan.bookIds.filter { record(for: $0) == nil }
            if !missingBooks.isEmpty {
                for id in missingBooks {
                    guard let book = try? await client.item(id), book.isAudiobook else { continue }
                    guard !Task.isCancelled else { return }
                    queued += enqueue([book], reason: "book", automatic: true)
                }
            }
            for id in lists {
                let known = playlists.contains { $0.id == id }
                if !force, known, let at = playlistSyncedAt[id], Date().timeIntervalSince(at) < Self.playlistSyncInterval { continue }
                guard let added = await syncPlaylist(id, planned: planned.contains(id), force: force) else { continue }
                guard !Task.isCancelled else { return }
                queued += added
            }
            mirrorNote = queued > 0 ? "Queued \(queued) for the watch" : nil
            pump()
        }
    }

    /// One playlist made to match the server's: songs added there are
    /// queued, and songs taken out there leave the watch — unless an album,
    /// another playlist or a tap of their own still keeps them. A song that
    /// was already in the list and isn't on the watch (cancelled, or taken
    /// off by hand) is left off, except by `force`. Nil when the server
    /// couldn't be asked, or the list went while it was being asked.
    private func syncPlaylist(_ id: String, planned: Bool, force: Bool) async -> Int? {
        let client = JellyfinClient.shared
        guard let songs = try? await client.playlistItems(playlistId: id) else { return nil }
        let named = try? await client.item(id)
        guard !Task.isCancelled else { return nil }
        // Looked at again after the waits: taken off meanwhile, it stays off.
        let existing = playlists.first { $0.id == id }
        guard existing != nil || (planned && plannedPlaylistIds.contains(id)) else { return nil }
        var list = existing ?? WatchPlaylist(id: id, name: "Playlist", itemIds: [], automatic: true)
        if let named {
            list.name = named.title
            list.imageTag = named.ImageTags?["Primary"]
        }
        let audio = songs.filter(\.isAudio)
        let before = Set(existing?.itemIds ?? [])
        let now = audio.map(\.Id)
        let gone = before.subtracting(now)
        list.itemIds = now
        if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i] = list } else { playlists.append(list) }
        playlistSyncedAt[id] = Date()
        savePlaylists()
        if !gone.isEmpty {
            WatchLog.note("downloads", "playlist \(id): \(gone.count) songs gone from the server's list")
            withdraw(reason: "playlist:\(id)", from: Array(gone))
        }
        let wanted = force ? audio : audio.filter { !before.contains($0.Id) || record(for: $0.Id) != nil }
        let added = enqueue(wanted, reason: "playlist:\(id)", automatic: list.automatic)
        if existing != nil, added > 0 || !gone.isEmpty {
            WatchLog.note("downloads", "playlist \(id) matched to the server: \(added) queued, \(gone.count) gone")
        }
        return added
    }

    /// Keep a whole playlist by hand: saved, and every song queued.
    func keep(playlist: BaseItem, songs: [BaseItem]) {
        var list = playlists.first { $0.id == playlist.Id }
            ?? WatchPlaylist(id: playlist.Id, name: playlist.title, itemIds: [], automatic: false)
        list.name = playlist.title
        list.itemIds = songs.map(\.Id)
        list.automatic = false
        list.imageTag = playlist.ImageTags?["Primary"]
        if let i = playlists.firstIndex(where: { $0.id == playlist.Id }) { playlists[i] = list } else { playlists.append(list) }
        playlistSyncedAt[playlist.Id] = Date()
        if droppedPlaylists.removeValue(forKey: playlist.Id) != nil { persistDropped() }
        savePlaylists()
        enqueue(songs, reason: "playlist:\(playlist.Id)")
    }

    // MARK: - What the phone is told

    /// The watch's storage as the phone lists it: a group per book, per
    /// playlist and per album, each byte counted once — a song in a kept
    /// playlist is the playlist's, not its album's.
    func inventory() -> WatchInventory {
        var groups: [WatchStorageGroup] = []
        for book in records where book.isAudiobook {
            groups.append(WatchStorageGroup(
                id: book.itemId, kind: .book, title: book.name, subtitle: book.artist,
                count: 1, bytes: book.bytes, complete: book.status == .complete ? 1 : 0
            ))
        }
        var claimed = Set<String>()
        for list in playlists {
            let members = list.itemIds.compactMap { record(for: $0) }
            claimed.formUnion(members.map(\.itemId))
            groups.append(WatchStorageGroup(
                id: list.id, kind: .playlist, title: list.name, subtitle: "\(list.itemIds.count) songs",
                count: list.itemIds.count, bytes: members.reduce(0) { $0 + $1.bytes },
                complete: members.filter { $0.status == .complete }.count
            ))
        }
        var byAlbum: [String: [WatchRecord]] = [:]
        var loose: [WatchRecord] = []
        for song in records where !song.isAudiobook && !claimed.contains(song.itemId) {
            if let albumId = song.albumId, !albumId.isEmpty { byAlbum[albumId, default: []].append(song) } else { loose.append(song) }
        }
        for (albumId, songs) in byAlbum {
            groups.append(WatchStorageGroup(
                id: albumId, kind: .album, title: songs[0].album ?? "Album", subtitle: songs[0].artist,
                count: songs.count, bytes: songs.reduce(0) { $0 + $1.bytes },
                complete: songs.filter { $0.status == .complete }.count
            ))
        }
        if !loose.isEmpty {
            groups.append(WatchStorageGroup(
                id: "songs", kind: .songs, title: "Songs", subtitle: nil,
                count: loose.count, bytes: loose.reduce(0) { $0 + $1.bytes },
                complete: loose.filter { $0.status == .complete }.count
            ))
        }
        groups.sort { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        var inventory = WatchInventory(
            groups: groups, itemCount: complete.count, totalBytes: totalBytes,
            freeBytes: Self.freeBytes(), inFlight: inFlight.count
        )
        // Kept under the size a message may be.
        while let data = try? JSONEncoder().encode(inventory), data.count > 50_000, !inventory.groups.isEmpty {
            inventory.groups.removeLast()
            inventory.truncated = true
        }
        return inventory
    }

    /// A delete asked for from the phone.
    func delete(group kind: WatchStorageGroup.Kind, id: String) {
        switch kind {
        case .book: deleteBook(id)
        case .album: deleteAlbum(id)
        case .playlist: deletePlaylist(id)
        case .songs: deleteLooseSongs()
        }
    }

    /// A download asked for from the phone: fetch what it names and queue it.
    func download(_ request: WatchDownloadRequest) async {
        let client = JellyfinClient.shared
        switch request.kind {
        case .song, .book:
            if let item = try? await client.item(request.id) {
                enqueue([item], reason: request.kind == .book ? "book" : "song")
            }
        case .album:
            if let songs = try? await client.albumTracks(albumId: request.id) {
                enqueue(songs, reason: "album:\(request.id)")
            }
        case .playlist:
            if let songs = try? await client.playlistItems(playlistId: request.id) {
                var list = BaseItem()
                list.Id = request.id
                list.Name = request.title
                list.type = "Playlist"
                keep(playlist: list, songs: songs)
            }
        case .artist:
            if let songs = try? await client.songs(artistId: request.id) {
                for (albumId, group) in Dictionary(grouping: songs, by: { $0.AlbumId ?? "" }) {
                    enqueue(group, reason: albumId.isEmpty ? "song" : "album:\(albumId)")
                }
            }
        case .genre:
            if let songs = try? await client.songs(genreId: request.id) {
                enqueue(songs, reason: "song")
            }
        }
    }
}

// MARK: - URLSession delegate

extension WatchDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let itemId = taskItem(downloadTask) else { return }
        // The session reports every chunk; the rings and bars need a step
        // of half a percent or so, and every report redraws the pages.
        let step = max(Int64(65_536), totalBytesExpectedToWrite / 200)
        let due = lastReported.withLock { last -> Bool in
            let previous = last[itemId] ?? 0
            let finished = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
            guard finished || totalBytesWritten - previous >= step else { return false }
            last[itemId] = totalBytesWritten
            return true
        }
        guard due else { return }
        // A line every tenth of the way, with the memory left: the number
        // a download that died part-way is judged by.
        let tenth = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite / 10 : Int64(8 * 1024 * 1024)
        if tenth > 0, (totalBytesWritten - bytesWritten) / tenth != totalBytesWritten / tenth {
            WatchLog.note("downloads", "\(itemId) at \(totalBytesWritten / 1024)KB of \(totalBytesExpectedToWrite / 1024)KB, \(WatchLog.memory)")
        }
        Task { @MainActor in
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (self.liveBytes[itemId]?.expected ?? 0)
            self.liveBytes[itemId] = (totalBytesWritten, expected)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let itemId = taskItem(downloadTask) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        // Moved here and now: the system deletes the temporary file when this
        // returns.
        let folder = Self.folder(itemId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("audio.\(downloadTask.taskDescription ?? "m4a")")
        try? FileManager.default.removeItem(at: destination)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        var moved = false
        if (200..<300).contains(status) {
            moved = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        WatchLog.note("downloads", "\(itemId) finished: HTTP \(status), \(bytes / 1024)KB, moved=\(moved), \(WatchLog.memory)")
        Task { @MainActor in
            if moved {
                await self.landed(itemId: itemId, at: destination, bytes: bytes)
            } else {
                self.failed(itemId: itemId, message: status == 401 ? "The watch's sign-in was refused" : "Server error \(status)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard let itemId = taskItem(task) else { return }
        let code = (error as? URLError)?.code
        WatchLog.error("downloads", "\(itemId) task ended: \(error.localizedDescription) (\(code.map { String($0.rawValue) } ?? "?"))")
        Task { @MainActor in
            if code == .cancelled { self.finishActive(itemId); return }
            self.failed(itemId: itemId, message: error.localizedDescription)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.releaseBackgroundWake() }
    }
}
