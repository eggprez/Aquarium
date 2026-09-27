//  The iPhone's side of the Apple Watch app.
//
//  Three jobs. It hands the watch the sign-in and the mirror plan — the
//  audiobooks in progress and the playlists picked for the watch — as the
//  application context, so the watch has them whenever it next wakes. It
//  takes the watch's listening and tells the server, exactly the way the
//  phone's own offline sync does, and keeps what it couldn't send until the
//  server is back. And it keeps the watch's storage list, so Settings can
//  show what is on the watch and take things off it from here.
//
//  See Shared/WatchSyncTypes.swift for the vocabulary. iPhone only: an iPad
//  and a Mac have no watch.

#if os(iOS)

import AVFoundation
import Foundation
import Observation
import WatchConnectivity
import os
import OSLog
import UIKit

@MainActor
@Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "watch")

    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var isActivated = false
    /// What the watch last said it holds.
    private(set) var inventory: WatchInventory?
    /// The playlists the watch keeps, however they were asked for — on the
    /// watch, from here, or by the plan. Kept across launches.
    private(set) var watchPlaylistIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "watch_kept_playlists") ?? [])
    private(set) var inventoryAt: Date?
    private(set) var watchSignedIn = false
    private(set) var lastContextSentAt: Date?
    /// Listening the watch handed over that the server hasn't taken yet.
    private(set) var pendingEvents: [WatchProgressEvent] = []
    private(set) var lastForwardedAt: Date?
    /// The last few hundred events settled — sent, or found older than what
    /// the server had — so one the watch sends again, having not heard, is
    /// answered as done rather than sent twice.
    private var settledIds: [UUID] = UserDefaults.standard.array(forKey: "watch_forward_settled")?
        .compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) } ?? []
    /// When the newest position sent for each book was heard: an older one
    /// arriving late isn't sent over it.
    private var lastSentAt: [String: Date] = (UserDefaults.standard.dictionary(forKey: "watch_forward_last_sent") as? [String: Date]) ?? [:]
    private var forwardRetry: Task<Void, Never>?

    /// Items the watch has asked for, in the order asked, waiting their
    /// turn. Kept across launches.
    private(set) var fetchQueue: [String] = []
    /// The fetches running now, oldest first: up to `fetchWindow` of them,
    /// and at most one long item — a book — among them.
    private(set) var fetching: [String] = []
    /// Files fetched and handed to WatchConnectivity, still on their way.
    private(set) var transferring: [String] = []
    /// Everything the watch asked the phone for, as Settings shows it: the
    /// download from the server, then the send to the watch. Kept across
    /// launches; finished rows go after a day.
    private(set) var relayItems: [RelayItem] = []

    private var started = false
    /// Kept across launches, so the watch's log reads in the order sent.
    private var revision = UserDefaults.standard.integer(forKey: "watch_context_revision")
    private var contextTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    @ObservationIgnored nonisolated private let taskMap = OSAllocatedUnfairLock(initialState: [Int: String]())
    @ObservationIgnored private var fetchSession: URLSession!
    private var fetchCompletion: (() -> Void)?
    /// When each item's progress last went to the watch.
    private var lastProgressSentAt: [String: Date] = [:]
    /// Which start of `fetching` is current: a cancel, or a second ask for
    /// the same item, leaves an earlier start's lookup nothing to do.
    private var fetchTokens: [String: UUID] = [:]
    /// The items the running and deferred fetches are for, as the server
    /// described them: a book put back to wait for another is known to be
    /// one without asking again.
    private var fetchItems: [String: BaseItem] = [:]
    /// The long item being fetched, if one is.
    private var longFetch: String?
    /// Landings being measured and fetches being started: a background wake
    /// is held until they are done, or the app is put back to sleep with the
    /// next download never started.
    private var settling = 0
    /// Expected bytes by item, for a transcode that comes with no length.
    private var fetchEstimates: [String: Int64] = [:]
    /// The send in pieces running for each item, so a piece of an earlier
    /// one, cancelled or overtaken, can't finish or fail the current one.
    private var currentSend: [String: String] = [:]
    /// Reports how far the files handed to WatchConnectivity have got.
    private var transferProgressTask: Task<Void, Never>?
    /// Watches the running fetch for a download that has stopped moving.
    private var stallTask: Task<Void, Never>?
    /// The running fetch's byte count when it last moved.
    private var lastMovement: [String: (bytes: Int64, at: Date)] = [:]
    /// The last tenth of a download written to the log, by item.
    private var loggedTenth: [String: Int] = [:]
    /// Restarts after a stall, by item; the third stall fails it.
    private var stallRestarts: [String: Int] = [:]
    /// Pick-ups after an interruption, by item: a dropped connection, the
    /// app closed from the switcher. Each carries on from where the last
    /// stopped when the server allows it; the sixth fails the item.
    private var resumes: [String: Int] = [:]
    private static let resumeLimit = 5
    /// When the stall watch last looked. A gap means the app was asleep and
    /// nothing was watching: the bytes' clock starts again rather than
    /// reading the sleep as a stall.
    private var stallCheckedAt: Date?
    /// A download with no new bytes for this long is started again.
    private static let stallLimit: TimeInterval = 3 * 60
    /// How many fetches run at once. All of them are the background
    /// session's, so they carry on with the app asleep; one at a time, the
    /// app had to be woken between each, and iOS wakes an app for its
    /// downloads less and less often the more it asks — the queue stalled
    /// whenever the app wasn't open.
    private static let fetchWindow = 6
    /// An item this long is a book, or like one: the server encodes it for
    /// minutes, and only one goes at a time.
    private static let longSeconds: Double = 20 * 60

    private static func isLong(_ item: BaseItem) -> Bool { item.runtimeSeconds >= longSeconds }

    /// The watch sees one bar for an item it asked the phone for: the
    /// server's download fills the first half, the send to the watch the rest.
    private static let fetchShare = 0.5

    nonisolated static let fetchSessionIdentifier = "scottai.FellyJin.watchrelay"

    var isAvailable: Bool { WCSession.isSupported() && isPaired && isWatchAppInstalled }

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "watch_forward_pending"),
           let saved = try? JSONDecoder().decode([WatchProgressEvent].self, from: data) {
            pendingEvents = saved
        }
        fetchQueue = UserDefaults.standard.stringArray(forKey: "watch_fetch_queue") ?? []
        if let data = UserDefaults.standard.data(forKey: "watch_relay_items"),
           let saved = try? JSONDecoder().decode([RelayItem].self, from: data) {
            relayItems = saved.filter { $0.stage != .delivered && (!$0.stage.isFinished || Date().timeIntervalSince($0.updatedAt) < 24 * 60 * 60) }
        }
        if let data = UserDefaults.standard.data(forKey: "watch_fetch_tasks"),
           let saved = try? JSONDecoder().decode([Int: String].self, from: data) {
            taskMap.withLock { $0 = saved }
        }
        // A background session: a ten-hour book is minutes of transcode,
        // and the phone is in a pocket for most of them.
        let config = URLSessionConfiguration.background(withIdentifier: Self.fetchSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.httpMaximumConnectionsPerHost = Self.fetchWindow
        fetchSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Called once at launch.
    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        rejoinFetches()
    }

    /// The system woke the app for the relay session's events.
    func handleFetchEvents(completion: @escaping () -> Void) {
        fetchCompletion = completion
        _ = fetchSession
    }

    /// The session's events are in. The system is told only once what they
    /// set going has settled — the files measured and handed to the watch,
    /// the next fetches started — so the queue keeps moving while the app
    /// is asleep.
    private func releaseFetchWake() {
        guard let completion = fetchCompletion else { return }
        fetchCompletion = nil
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<80 where settling > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            if settling > 0 { Self.log.notice("relay wake let go with \(self.settling) things unsettled") }
            completion()
        }
    }

    /// Coming forward: anything waiting starts now, while tasks started are
    /// the app's own and not the system's to put off.
    func resumeFetches() {
        pumpFetches()
    }

    // MARK: - Phone → watch

    /// Send the sign-in and the plan. Debounced: a sign-in writes the
    /// session and the accounts list in one breath.
    func sendContext(now: Bool = false) {
        contextTask?.cancel()
        contextTask = Task {
            if !now { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            await pushContext()
        }
    }

    private func pushContext() async {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let context = await buildContext()
        do {
            try WCSession.default.updateApplicationContext(WatchSync.pack(context))
            lastContextSentAt = Date()
        } catch {
            Self.log.error("context not sent: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The sign-in and the plan as they stand.
    private func buildContext() async -> PhoneContext {
        let client = JellyfinClient.shared
        var credentials: WatchCredentials?
        if let s = client.session, let token = Keychain.token(server: s.server, userId: s.userId) {
            credentials = WatchCredentials(server: s.server, userId: s.userId, userName: s.userName, serverId: s.serverId, token: token)
        }
        var plan = WatchMirrorPlan()
        plan.playlistIds = Preferences.shared.watchPlaylistIds
        if !Preferences.shared.watchKeepsBooks {
            plan.bookIds = []
        } else if credentials != nil, !client.isOffline {
            do {
                let books = try await client.resumeAudio(limit: 12)
                plan.bookIds = books.filter(\.isAudiobook).map(\.Id)
            } catch {
                // A failed ask is not an empty shelf: the watch cancels
                // whatever the plan stops naming.
                Self.log.error("books in progress unavailable, keeping the last plan: \(error.localizedDescription, privacy: .public)")
                plan.bookIds = lastPlan?.bookIds ?? []
            }
        } else if let last = lastPlan {
            plan.bookIds = last.bookIds
        }
        lastPlan = plan
        revision += 1
        UserDefaults.standard.set(revision, forKey: "watch_context_revision")
        return PhoneContext(revision: revision, credentials: credentials, mirror: plan)
    }

    private var lastPlan: WatchMirrorPlan? {
        get {
            UserDefaults.standard.data(forKey: "watch_last_plan").flatMap { try? JSONDecoder().decode(WatchMirrorPlan.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "watch_last_plan")
        }
    }

    /// A message for the watch: delivered now when it is in reach, queued
    /// for its next wake otherwise.
    func send(_ message: WatchMessage) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload = WatchSync.pack(message)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(payload)
            }
        } else {
            WCSession.default.transferUserInfo(payload)
        }
    }

    func deleteFromWatch(_ group: WatchStorageGroup) {
        if group.kind == .playlist {
            setKeepsOnWatch(group.id, false)
            return
        }
        send(.deleteGroup(kind: group.kind, id: group.id))
        // Shown gone at once; the watch's next inventory confirms it.
        inventory?.groups.removeAll { $0.id == group.id && $0.kind == group.kind }
    }

    func deleteEverythingOnWatch() {
        send(.deleteAll)
        inventory?.groups = []
        inventory?.itemCount = 0
        inventory?.totalBytes = 0
        // Playlists kept there go from the plan too, or they'd come back.
        watchPlaylistIds = []
        UserDefaults.standard.set([String](), forKey: "watch_kept_playlists")
        if !Preferences.shared.watchPlaylistIds.isEmpty {
            Preferences.shared.watchPlaylistIds = []
            sendContext()
        }
    }

    /// Ask the watch to keep this: an album, a playlist, a book, a song, an
    /// artist's songs, a genre.
    func download(_ item: BaseItem) {
        let kind: WatchDownloadRequest.Kind
        if item.isAudiobook { kind = .book }
        else if item.isAlbum { kind = .album }
        else if item.isPlaylist { kind = .playlist }
        else if item.isArtist { kind = .artist }
        else if item.isMusicGenre { kind = .genre }
        else { kind = .song }
        send(.download(WatchDownloadRequest(kind: kind, id: item.Id, title: item.title)))
    }

    func requestInventory() { send(.requestInventory) }

    // MARK: - Logs from the watch

    /// Logs the watch has sent, newest first. Kept in Documents/WatchLogs;
    /// the share sheet is how they leave.
    private(set) var watchLogs: [URL] = []
    private(set) var logsRequestedAt: Date?

    nonisolated static var logsFolder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func requestWatchLogs() {
        logsRequestedAt = Date()
        send(.requestLogs)
    }

    func reloadWatchLogs() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.logsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        watchLogs = files
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    func deleteWatchLog(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reloadWatchLogs()
    }

    /// This phone's own side of the story — what it logged about the watch
    /// since launch — as a file beside the watch's, so both halves of a
    /// transfer can be read together.
    func exportPhoneLog() async -> URL? {
        let subsystem = Bundle.main.bundleIdentifier ?? "Aquarium"
        let lines: [String] = await Task.detached(priority: .utility) {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
                  let entries = try? store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0)) else { return [] }
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var out: [String] = []
            for case let entry as OSLogEntryLog in entries {
                let ours = entry.subsystem == subsystem
                guard ours || entry.level.rawValue >= OSLogEntryLog.Level.error.rawValue else { continue }
                let level = entry.level == .fault ? "F" : (entry.level == .error ? "E" : "N")
                out.append("\(stamp.string(from: entry.date)) \(level) [\(entry.subsystem):\(entry.category)] \(entry.composedMessage)")
            }
            return out
        }.value
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = Self.logsFolder.appendingPathComponent("AquariumPhone-\(f.string(from: Date())).log")
        let head = "Aquarium iPhone log (this launch), exported \(Date().ISO8601Format())\n\n"
        guard (try? (head + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        reloadWatchLogs()
        return url
    }

    // MARK: - Watch → phone

    private func apply(_ dictionary: [String: Any]) {
        guard let context = WatchSync.unpack(WatchContext.self, from: dictionary) else { return }
        inventory = context.inventory
        inventoryAt = context.sentAt
        watchSignedIn = context.signedIn
        let lists = context.playlistIds.map(Set.init)
            ?? Set(context.inventory.groups.filter { $0.kind == .playlist }.map(\.id))
        if lists != watchPlaylistIds {
            watchPlaylistIds = lists
            UserDefaults.standard.set(Array(lists), forKey: "watch_kept_playlists")
        }
        if let awaiting = context.awaitingPhone { keepOnly(Set(awaiting), saidAt: context.sentAt) }
    }

    /// Whether a playlist is kept on the watch, as Settings' switch shows
    /// it: picked here, or on the watch however it got there.
    func keepsOnWatch(_ playlistId: String) -> Bool {
        Preferences.shared.watchPlaylistIds.contains(playlistId) || watchPlaylistIds.contains(playlistId)
    }

    /// Settings' switch. On, the plan names it and the watch fetches it;
    /// off, the plan stops naming it and the watch lets it go — the switch
    /// is what is on the watch, so off can't leave it there.
    func setKeepsOnWatch(_ playlistId: String, _ on: Bool) {
        var ids = Preferences.shared.watchPlaylistIds
        if on {
            if !ids.contains(playlistId) { ids.append(playlistId) }
        } else {
            ids.removeAll { $0 == playlistId }
            send(.deleteGroup(kind: .playlist, id: playlistId))
            watchPlaylistIds.remove(playlistId)
            UserDefaults.standard.set(Array(watchPlaylistIds), forKey: "watch_kept_playlists")
            inventory?.groups.removeAll { $0.kind == .playlist && $0.id == playlistId }
        }
        Preferences.shared.watchPlaylistIds = ids
        sendContext()
    }

    /// Taken off on the watch: the plan stops naming it, or the watch would
    /// fetch it all again.
    private func playlistRemovedOnWatch(_ playlistId: String) {
        watchPlaylistIds.remove(playlistId)
        UserDefaults.standard.set(Array(watchPlaylistIds), forKey: "watch_kept_playlists")
        var ids = Preferences.shared.watchPlaylistIds
        guard ids.contains(playlistId) else { return }
        ids.removeAll { $0 == playlistId }
        Preferences.shared.watchPlaylistIds = ids
        Self.log.notice("playlist \(playlistId, privacy: .public) taken off on the watch; no longer kept there")
        sendContext()
    }

    /// The watch says what it is still waiting on; everything else queued
    /// for it goes. Only what was asked before the watch said so: an ask
    /// that crossed with this report stands.
    private func keepOnly(_ awaiting: Set<String>, saidAt: Date) {
        var held = Set(fetchQueue)
        held.formUnion(fetching)
        held.formUnion(transferring)
        held.formUnion(relayItems.filter { !$0.stage.isFinished }.map(\.id))
        for id in held where !awaiting.contains(id) {
            let askedAt = relayItems.first { $0.id == id }?.askedAt ?? .distantPast
            guard askedAt < saidAt else { continue }
            Self.log.notice("the watch isn't waiting on \(id, privacy: .public); dropping it")
            cancelFetch(id)
        }
    }

    /// Listening from the watch: queued, then told to the server in order.
    private func handle(_ message: WatchMessage) {
        Self.log.notice("from the watch: \(String(describing: message).prefix(80), privacy: .public)")
        switch message {
        case .progress(let events): take(events)
        case .fetch(let itemId): enqueueFetch(itemId)
        case .fetchMany(let itemIds): for id in itemIds { enqueueFetch(id, pumping: false) }; persistFetches(); pumpFetches()
        case .cancelFetch(let itemId): cancelFetch(itemId)
        case .playlistRemoved(let id): playlistRemovedOnWatch(id)
        case .logs(let chunk): take(chunk)
        default: break
        }
    }

    /// Pieces of a log on their way, by export id.
    private var logPieces: [String: [Int: Data]] = [:]

    private func take(_ chunk: WatchLogChunk) {
        var pieces = logPieces[chunk.id] ?? [:]
        pieces[chunk.index] = chunk.data
        guard pieces.count == chunk.count else { logPieces[chunk.id] = pieces; return }
        logPieces[chunk.id] = nil
        var packed = Data()
        for i in 0..<chunk.count { packed.append(pieces[i] ?? Data()) }
        guard let raw = try? (packed as NSData).decompressed(using: .lzfse) as Data else {
            Self.log.error("the watch's log would not unpack")
            return
        }
        let safeName = chunk.name.components(separatedBy: "/").last ?? "AquariumWatch.log"
        let destination = Self.logsFolder.appendingPathComponent(safeName)
        do {
            try raw.write(to: destination, options: .atomic)
            Self.log.notice("the watch's log arrived in \(chunk.count) pieces: \(safeName, privacy: .public)")
        } catch {
            Self.log.error("couldn't keep the watch's log: \(error.localizedDescription, privacy: .public)")
        }
        reloadWatchLogs()
    }

    // MARK: - Fetching for the watch

    /// Where a fetched file waits for its transfer. Under tmp: nothing
    /// here is the phone's to keep.
    nonisolated private static var relayFolder: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WatchRelay", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static func relayFile(_ itemId: String, ext: String) -> URL {
        relayFolder.appendingPathComponent("\(JellyfinClient.pathId(itemId)).\(ext)")
    }

    /// Where an interrupted fetch's resume data waits: apart from the relay
    /// files, which are found by their name alone.
    nonisolated private static func resumeFile(_ itemId: String) -> URL {
        let folder = relayFolder.appendingPathComponent("Resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(JellyfinClient.pathId(itemId))
    }

    nonisolated private static func saveResumeData(_ data: Data, for itemId: String) {
        try? data.write(to: resumeFile(itemId), options: .atomic)
    }

    /// The resume data kept for an item, used up by taking it.
    nonisolated private static func takeResumeData(_ itemId: String) -> Data? {
        let file = resumeFile(itemId)
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }

    /// A task's description: the file's extension, then the item it is
    /// for, so a task the map has lost can still be placed.
    nonisolated private static func taskInfo(_ task: URLSessionTask) -> (ext: String, itemId: String?) {
        let parts = (task.taskDescription ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "m4a", parts.count > 1 ? parts[1] : nil)
    }

    /// A file already fetched for this item, whatever its type.
    nonisolated private static func existingRelayFile(_ itemId: String) -> URL? {
        let stem = JellyfinClient.pathId(itemId)
        return ((try? FileManager.default.contentsOfDirectory(at: relayFolder, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.deletingPathExtension().lastPathComponent == stem }
    }

    private func persistFetches() {
        UserDefaults.standard.set(fetchQueue, forKey: "watch_fetch_queue")
        UserDefaults.standard.set(try? JSONEncoder().encode(taskMap.withLock { $0 }), forKey: "watch_fetch_tasks")
    }

    private func enqueueFetch(_ itemId: String, pumping: Bool = true) {
        guard !fetchQueue.contains(itemId), !fetching.contains(itemId), !transferring.contains(itemId) else {
            let stage = transferring.contains(itemId) ? "sending" : fetching.contains(itemId) ? "downloading" : "waiting"
            Self.log.notice("fetch of \(itemId, privacy: .public) already under way: \(stage, privacy: .public)")
            // Asked again: a download that has stopped moving starts over
            // now rather than at the next stall check.
            // Only on what the stall watch saw for itself: a phone app just
            // woken hasn't been looking, and its clock says nothing yet.
            if fetching.contains(itemId), let last = lastMovement[itemId], Date().timeIntervalSince(last.at) > 60,
               let checked = stallCheckedAt, Date().timeIntervalSince(checked) < 60 {
                restartFetch(itemId, reason: "asked again with nothing new for \(Int(Date().timeIntervalSince(last.at)))s")
            }
            return
        }
        updateRelay(itemId) { r in
            r.stage = .waiting
            r.failure = nil
            r.downloadFraction = nil
            r.transferFraction = nil
            r.askedAt = Date()
        }
        nameRelayItem(itemId)
        // Already fetched and waiting: hand it over again.
        if let file = Self.existingRelayFile(itemId) {
            updateRelay(itemId) { $0.downloadFraction = 1 }
            handOver(itemId: itemId, file: file)
            return
        }
        fetchQueue.append(itemId)
        if pumping {
            persistFetches()
            pumpFetches()
        }
    }

    private func cancelFetch(_ itemId: String) {
        fetchQueue.removeAll { $0 == itemId }
        fetchEstimates[itemId] = nil
        stallRestarts[itemId] = nil
        fetchItems[itemId] = nil
        lastProgressSentAt[itemId] = nil
        relayItems.removeAll { $0.id == itemId }
        persistRelay()
        if fetching.contains(itemId) { stopFetching(itemId) }
        for transfer in WCSession.default.outstandingFileTransfers
        where transfer.file.metadata?[WatchFileTransfer.itemKey] as? String == itemId {
            transfer.cancel()
        }
        transferring.removeAll { $0 == itemId }
        currentSend[itemId] = nil
        resumes[itemId] = nil
        Self.removePieces(itemId)
        _ = Self.takeResumeData(itemId)
        if let file = Self.existingRelayFile(itemId) { try? FileManager.default.removeItem(at: file) }
        persistFetches()
        pumpFetches()
    }

    /// Drop the running fetch at once. Cleared here, not when the task
    /// reports back: a cancel can land while the item is still being looked
    /// up, before there is a task to cancel, and the lookup must then find
    /// it gone.
    ///
    /// Keeping resume data, the download is cancelled so that it can carry
    /// on where it stopped, and `then` runs once that data is written.
    private func stopFetching(_ itemId: String, keepingResumeData: Bool = false, then: (@MainActor () -> Void)? = nil) {
        fetching.removeAll { $0 == itemId }
        if longFetch == itemId { longFetch = nil }
        fetchTokens[itemId] = nil
        lastMovement[itemId] = nil
        let taskIds = taskMap.withLock { map in
            let ids = Set(map.filter { $0.value == itemId }.keys)
            map = map.filter { $0.value != itemId }
            return ids
        }
        fetchSession.getAllTasks { tasks in
            let mine = tasks.filter { taskIds.contains($0.taskIdentifier) }
            guard keepingResumeData, let task = mine.first as? URLSessionDownloadTask else {
                for task in mine { task.cancel() }
                if let then { Task { @MainActor in then() } }
                return
            }
            for other in mine where other !== task { other.cancel() }
            task.cancel { data in
                if let data { Self.saveResumeData(data, for: itemId) }
                if let then { Task { @MainActor in then() } }
            }
        }
    }

    /// A download that stopped moving goes back to the head of the queue
    /// and starts over; the third time, the watch is told it failed.
    private func restartFetch(_ itemId: String, reason: String) {
        let restarts = (stallRestarts[itemId] ?? 0) + 1
        stallRestarts[itemId] = restarts
        guard restarts < 3 else {
            Self.log.error("fetch of \(itemId, privacy: .public) stalled again (\(reason, privacy: .public)); giving up")
            stopFetching(itemId)
            stallRestarts[itemId] = nil
            fetchFailed(itemId, reason: "The server stopped sending it")
            return
        }
        Self.log.error("fetch of \(itemId, privacy: .public) stalled (\(reason, privacy: .public)); starting it again from where it stopped, try \(restarts + 1)")
        stopFetching(itemId, keepingResumeData: true) {
            // Queued only now, with the resume data written: queued at once,
            // another pump could start it from nothing first.
            if !self.fetching.contains(itemId), !self.fetchQueue.contains(itemId) { self.fetchQueue.insert(itemId, at: 0) }
            self.persistFetches()
            self.pumpFetches()
        }
    }

    /// While a fetch runs, look at its task every half minute: bytes that
    /// stop coming for `stallLimit` restart it. A background download can
    /// otherwise sit for hours with nothing arriving and nothing reported,
    /// and the one-at-a-time queue waits behind it.
    private func watchForStall() {
        guard stallTask == nil else { return }
        stallTask = Task {
            defer { stallTask = nil }
            while !fetching.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                let tasks = await fetchSession.allTasks
                let now = Date()
                let asleep = stallCheckedAt.map { now.timeIntervalSince($0) > 90 } ?? true
                stallCheckedAt = now
                for itemId in fetching {
                    let task = tasks.first { taskItem($0) == itemId }
                    let bytes = task?.countOfBytesReceived ?? 0
                    guard !asleep, let last = lastMovement[itemId] else {
                        lastMovement[itemId] = (bytes, Date())
                        continue
                    }
                    if bytes > last.bytes {
                        lastMovement[itemId] = (bytes, Date())
                    } else if Date().timeIntervalSince(last.at) > Self.stallLimit {
                        let idle = Int(Date().timeIntervalSince(last.at))
                        let state = task.map { Self.describe($0.state) } ?? "no task"
                        restartFetch(itemId, reason: "\(state), \(max(bytes, last.bytes) / 1024)KB, nothing new for \(idle)s")
                    }
                }
            }
        }
    }

    nonisolated private static func describe(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running: "running"
        case .suspended: "suspended"
        case .canceling: "canceling"
        case .completed: "completed"
        @unknown default: "state \(state.rawValue)"
        }
    }

    /// At launch: a fetch the session is still running stands; a queue
    /// head with no task behind it is started again.
    private func rejoinFetches() {
        fetchSession.getAllTasks { live in
            // A task the session still lists can be finished: a completed
            // download whose events never reached the app. Taken for running,
            // it held the queue for hours with nothing arriving.
            let dead = live.filter { $0.state == .completed || $0.state == .canceling }
            for task in dead { task.cancel() }
            let alive = live.filter { $0.state == .running || $0.state == .suspended }
            let found = alive.compactMap { task in
                self.taskItem(task).map { ($0, Self.describe(task.state), task.countOfBytesReceived) }
            }
            let deadItems = dead.compactMap { task in self.taskItem(task).map { ($0, task.countOfBytesReceived) } }
            let deadIds = Set(dead.map(\.taskIdentifier))
            self.taskMap.withLock { map in map = map.filter { !deadIds.contains($0.key) } }
            let strays = alive.count - found.count
            Task { @MainActor in
                for (id, bytes) in deadItems {
                    Self.log.notice("dropping a finished task for \(id, privacy: .public) (\(bytes / 1024)KB): it goes back in the queue")
                    if !self.fetchQueue.contains(id) { self.fetchQueue.insert(id, at: 0) }
                }
                for (id, state, bytes) in found {
                    Self.log.notice("rejoining fetch of \(id, privacy: .public): \(state, privacy: .public), \(bytes / 1024)KB so far")
                }
                if strays > 0 { Self.log.notice("\(strays) relay task(s) with no item; left to finish") }
                for (id, _, _) in found where !self.fetching.contains(id) {
                    self.fetching.append(id)
                    self.fetchQueue.removeAll { $0 == id }
                    self.updateRelay(id) { $0.stage = .downloading }
                    self.nameRelayItem(id)
                    self.lookUpEstimate(id)
                }
                if found.isEmpty {
                    self.taskMap.withLock { $0 = [:] }
                } else {
                    self.watchForStall()
                }
                // A fetch running when the app was killed, with no task left
                // and none on its way back: it goes at the head of the queue.
                for r in self.relayItems where r.stage == .downloading && !self.fetching.contains(r.id)
                    && !self.fetchQueue.contains(r.id) && !self.transferring.contains(r.id) {
                    Self.log.notice("fetch of \(r.id, privacy: .public) was cut off with the app; picking it up again")
                    self.fetchQueue.insert(r.id, at: 0)
                }
                Self.log.notice("relay at launch: \(self.fetchQueue.count) waiting")
                self.persistFetches()
                self.pumpFetches()
            }
        }
    }

    /// After a relaunch the estimate is gone; ask for the item again.
    private func lookUpEstimate(_ itemId: String) {
        guard fetchEstimates[itemId] == nil else { return }
        Task {
            guard let item = try? await JellyfinClient.shared.musicItem(itemId) else { return }
            fetchEstimates[itemId] = Self.estimatedBytes(for: item)
            fetchItems[itemId] = item
            if Self.isLong(item), fetching.contains(itemId), longFetch == nil { longFetch = itemId }
        }
    }

    // MARK: - What Settings shows

    private func updateRelay(_ itemId: String, _ change: (inout RelayItem) -> Void) {
        let index = relayItems.firstIndex { $0.id == itemId }
        var item = index.map { relayItems[$0] } ?? RelayItem(id: itemId)
        let stage = item.stage
        change(&item)
        item.updatedAt = Date()
        if let index { relayItems[index] = item } else { relayItems.append(item) }
        // Progress alone isn't written down: it comes many times a second.
        if index == nil || item.stage != stage { persistRelay() }
    }

    private func persistRelay() {
        UserDefaults.standard.set(try? JSONEncoder().encode(relayItems), forKey: "watch_relay_items")
    }

    /// A row with only an id gets the item's name from the server.
    private func nameRelayItem(_ itemId: String) {
        guard relayItems.first(where: { $0.id == itemId })?.title == nil else { return }
        Task {
            guard let item = try? await JellyfinClient.shared.musicItem(itemId) else { return }
            updateRelay(itemId) { $0.title = item.title }
            persistRelay()
        }
    }

    /// Settings' "Clear": the failed rows go. Delivered ones go by
    /// themselves, the moment the watch has the file.
    func clearFinishedRelayItems() {
        relayItems.removeAll { $0.stage.isFinished }
        persistRelay()
    }

    /// A few at a time, all handed to the background session, which runs
    /// them with the app asleep. A long item goes with no other long one:
    /// a book waiting behind another holds its place at the head of the
    /// queue, and what is behind it waits too.
    private func pumpFetches() {
        let client = JellyfinClient.shared
        guard client.isSignedIn else {
            if !fetchQueue.isEmpty { Self.log.notice("fetch waits: not signed in") }
            return
        }
        while fetching.count < Self.fetchWindow, let next = fetchQueue.first {
            if longFetch != nil, let known = fetchItems[next], Self.isLong(known) { break }
            fetchQueue.removeFirst()
            startFetch(next)
        }
        persistFetches()
    }

    private func startFetch(_ next: String) {
        let client = JellyfinClient.shared
        fetching.append(next)
        let token = UUID()
        fetchTokens[next] = token
        // Woken in the background, the app has seconds; the lookup and the
        // task's start are held awake until they are done.
        let hold = UIApplication.shared.beginBackgroundTask(withName: "WatchRelayStart")
        settling += 1
        Task {
            defer {
                settling -= 1
                if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) }
            }
            var item = fetchItems[next]
            if item == nil, !client.isOffline { item = try? await client.musicItem(next) }
            guard fetching.contains(next), fetchTokens[next] == token else { return }
            guard let item, let (request, ext) = Self.fetchRequest(for: item, client: client) else {
                fetchFailed(next, reason: client.isOffline ? "The phone can't reach the server" : "The server doesn't have this item")
                return
            }
            fetchItems[next] = item
            if Self.isLong(item) {
                if let other = longFetch, other != next {
                    // Another book is on its way: this one waits its turn at
                    // the head of the queue.
                    fetching.removeAll { $0 == next }
                    fetchTokens[next] = nil
                    if !fetchQueue.contains(next) { fetchQueue.insert(next, at: 0) }
                    persistFetches()
                    return
                }
                longFetch = next
            }
            fetchEstimates[next] = ext == "m4a" ? Self.estimatedBytes(for: item) : (item.MediaSources?.first?.Size ?? Self.estimatedBytes(for: item))
            updateRelay(next) { r in
                r.title = item.title
                r.stage = .downloading
                r.downloadFraction = 0
            }
            let resumeData = Self.takeResumeData(next)
            let task = resumeData.map { fetchSession.downloadTask(withResumeData: $0) } ?? fetchSession.downloadTask(with: request)
            if resumeData != nil { Self.log.notice("picking up \(next, privacy: .public) where it stopped") }
            // Kept on the task, so it survives a relaunch with it.
            task.taskDescription = "\(ext) \(next)"
            taskMap.withLock { $0[task.taskIdentifier] = next }
            persistFetches()
            task.resume()
            lastMovement[next] = (0, Date())
            watchForStall()
            Self.log.notice("fetching \(next, privacy: .public) for the watch (\(self.fetching.count) running): \(item.title, privacy: .public), \(ext == "m4a" && WatchDownloadSource.originalExtension(for: item, encodedBytes: Self.estimatedBytes(for: item)) == nil ? "encoded, about \(Self.estimatedBytes(for: item) / (1024 * 1024))MB" : "the server's .\(ext), \((item.MediaSources?.first?.Size ?? 0) / (1024 * 1024))MB", privacy: .public)")
        }
    }

    /// The same choice the watch makes for itself: the server's own file
    /// when the watch can play it, otherwise AAC at 128 kbps in an MP4
    /// wrapper, one file. The token goes in a header.
    private static func fetchRequest(for item: BaseItem, client: JellyfinClient) -> (URLRequest, String)? {
        guard let s = client.session else { return nil }
        if let ext = WatchDownloadSource.originalExtension(for: item, encodedBytes: estimatedBytes(for: item)) {
            let q = WatchDownloadSource.originalQuery(for: item, deviceId: s.deviceId)
            guard let url = URL(string: "\(s.server)/Audio/\(JellyfinClient.pathId(item.Id))/stream.\(ext)?\(JellyfinClient.encode(q))") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            for (k, v) in client.authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
            return (req, ext)
        }
        var q = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "deviceId", value: s.deviceId),
            URLQueryItem(name: "Context", value: "Static"),
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "audioBitRate", value: "128000"),
            URLQueryItem(name: "maxAudioChannels", value: "2"),
        ]
        if let id = item.MediaSources?.first?.Id { q.append(URLQueryItem(name: "mediaSourceId", value: id)) }
        guard let url = URL(string: "\(s.server)/Audio/\(JellyfinClient.pathId(item.Id))/stream.m4a?\(JellyfinClient.encode(q))") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        for (k, v) in client.authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        return (req, "m4a")
    }

    /// What the AAC transcode should come to: the runtime at 128 kbps,
    /// plus the container's few percent.
    private static func estimatedBytes(for item: BaseItem) -> Int64 {
        let seconds = item.runtimeSeconds
        guard seconds > 0 else { return 0 }
        return Int64(seconds * 128_000 / 8 * 1.03)
    }

    /// How far along an item the watch asked for is, sent while it is in reach.
    private func reportProgress(_ itemId: String, _ fraction: Double) {
        guard WCSession.default.isReachable, Date().timeIntervalSince(lastProgressSentAt[itemId] ?? .distantPast) > 2 else { return }
        lastProgressSentAt[itemId] = Date()
        WCSession.default.sendMessage(WatchSync.pack(WatchMessage.fetchProgress(itemId: itemId, fraction: min(0.99, fraction))), replyHandler: nil, errorHandler: nil)
    }

    /// While files are on their way over, their progress goes to the watch:
    /// a book is hundreds of megabytes over Bluetooth, and minutes of it.
    private func watchTransfers() {
        guard transferProgressTask == nil else { return }
        transferProgressTask = Task {
            defer { transferProgressTask = nil }
            while !transferring.isEmpty, !Task.isCancelled {
                for (itemId, sent) in Self.sentFractions(WCSession.default.outstandingFileTransfers) {
                    updateRelay(itemId) { $0.transferFraction = sent }
                    reportProgress(itemId, Self.fetchShare + (1 - Self.fetchShare) * sent)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    nonisolated private func taskItem(_ task: URLSessionTask) -> String? {
        taskMap.withLock { $0[task.taskIdentifier] }
    }

    private func fetchFailed(_ itemId: String, reason: String) {
        Self.log.error("fetch for the watch failed: \(itemId, privacy: .public) \(reason, privacy: .public)")
        updateRelay(itemId) { r in
            r.stage = .failed
            r.failure = reason
        }
        forget(itemId)
        fetchEstimates[itemId] = nil
        resumes[itemId] = nil
        _ = Self.takeResumeData(itemId)
        taskMap.withLock { map in map = map.filter { $0.value != itemId } }
        persistFetches()
        send(.fetchFailed(itemId: itemId, reason: reason))
        pumpFetches()
    }

    /// A file has landed. Measured before it goes to the watch: the server
    /// cannot promise a transcode's length, and a short file sent across
    /// would only be measured and thrown away there.
    private func fetched(itemId: String, at url: URL, expectedSeconds: Double?) async {
        let hold = UIApplication.shared.beginBackgroundTask(withName: "WatchRelayLanded")
        settling += 1
        defer {
            settling -= 1
            if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) }
        }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let whole = seconds.isFinite && seconds > 0 && (expectedSeconds.map { seconds >= $0 * 0.97 } ?? true)
        guard whole else {
            try? FileManager.default.removeItem(at: url)
            fetchFailed(itemId, reason: "The file arrived incomplete")
            return
        }
        Self.log.notice("fetched \(itemId, privacy: .public): \(Int(seconds))s of audio")
        forget(itemId)
        stallRestarts[itemId] = nil
        resumes[itemId] = nil
        loggedTenth[itemId] = nil
        updateRelay(itemId) { $0.downloadFraction = 1 }
        fetchEstimates[itemId] = nil
        taskMap.withLock { map in map = map.filter { $0.value != itemId } }
        persistFetches()
        handOver(itemId: itemId, file: url, seconds: seconds)
        pumpFetches()
    }

    /// A fetch that has finished, one way or the other, is no longer running.
    private func forget(_ itemId: String) {
        fetching.removeAll { $0 == itemId }
        if longFetch == itemId { longFetch = nil }
        fetchTokens[itemId] = nil
        fetchItems[itemId] = nil
        lastMovement[itemId] = nil
    }

    private func handOver(itemId: String, file: URL, seconds: Double? = nil) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        var metadata: [String: Any] = [
            WatchFileTransfer.itemKey: itemId,
            WatchFileTransfer.bytesKey: bytes,
            WatchFileTransfer.extensionKey: file.pathExtension,
        ]
        if let seconds { metadata[WatchFileTransfer.secondsKey] = seconds }
        updateRelay(itemId) { r in
            r.stage = .sending
            r.transferFraction = 0
        }
        if !transferring.contains(itemId) { transferring.append(itemId) }
        guard bytes > WatchFileTransfer.pieceBytes else {
            currentSend[itemId] = nil
            WCSession.default.transferFile(file, metadata: metadata)
            watchTransfers()
            Self.log.notice("handing \(itemId, privacy: .public) to the watch, \(bytes) bytes")
            return
        }
        // Too big for one transfer: cut into pieces off the main thread,
        // then queued all at once, so the send carries on with the phone
        // app put away.
        let send = UUID().uuidString
        currentSend[itemId] = send
        metadata[WatchFileTransfer.sendKey] = send
        metadata[WatchFileTransfer.pieceBytesKey] = WatchFileTransfer.pieceBytes
        Task {
            let pieces = await Task.detached(priority: .utility) {
                Self.cut(file, into: Self.piecesFolder(itemId, send: send))
            }.value
            // Cancelled, or asked again, while it was being cut.
            guard currentSend[itemId] == send, transferring.contains(itemId),
                  Self.existingRelayFile(itemId)?.lastPathComponent == file.lastPathComponent else {
                try? FileManager.default.removeItem(at: Self.piecesFolder(itemId, send: send))
                return
            }
            guard let pieces else {
                sendFailed(itemId, reason: "The file couldn't be cut into pieces for the watch")
                return
            }
            for (index, piece) in pieces.enumerated() {
                var m = metadata
                m[WatchFileTransfer.pieceKey] = index
                m[WatchFileTransfer.piecesKey] = pieces.count
                WCSession.default.transferFile(piece, metadata: m)
            }
            watchTransfers()
            Self.log.notice("handing \(itemId, privacy: .public) to the watch, \(bytes) bytes in \(pieces.count) pieces")
        }
    }

    /// Where a send's pieces wait for their transfers.
    nonisolated private static func piecesFolder(_ itemId: String, send: String) -> URL {
        relayFolder.appendingPathComponent("Pieces", isDirectory: true)
            .appendingPathComponent(JellyfinClient.pathId(itemId), isDirectory: true)
            .appendingPathComponent(send, isDirectory: true)
    }

    nonisolated private static func removePieces(_ itemId: String) {
        let folder = relayFolder.appendingPathComponent("Pieces", isDirectory: true)
            .appendingPathComponent(JellyfinClient.pathId(itemId), isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The file, as pieces of `WatchFileTransfer.pieceBytes` in order; nil
    /// if any of it couldn't be written.
    nonisolated private static func cut(_ file: URL, into folder: URL) -> [URL]? {
        try? FileManager.default.removeItem(at: folder)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let input = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? input.close() }
        var pieces: [URL] = []
        let block = 1024 * 1024
        while true {
            let piece = folder.appendingPathComponent("\(pieces.count).part")
            guard FileManager.default.createFile(atPath: piece.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: piece) else { return nil }
            var written: Int64 = 0
            var ended = false
            while written < WatchFileTransfer.pieceBytes {
                let want = Int(min(Int64(block), WatchFileTransfer.pieceBytes - written))
                guard let data = try? input.read(upToCount: want), !data.isEmpty else { ended = true; break }
                guard (try? output.write(contentsOf: data)) != nil else { try? output.close(); return nil }
                written += Int64(data.count)
            }
            try? output.close()
            if written == 0 {
                try? FileManager.default.removeItem(at: piece)
                break
            }
            pieces.append(piece)
            if ended { break }
        }
        return pieces.isEmpty ? nil : pieces
    }

    /// How far each item's send has got, from what WatchConnectivity still
    /// holds: pieces no longer held have arrived, and count whole.
    private static func sentFractions(_ transfers: [WCSessionFileTransfer]) -> [String: Double] {
        var sends: [String: (count: Int, held: Int, sent: Double)] = [:]
        var result: [String: Double] = [:]
        for transfer in transfers {
            let m = transfer.file.metadata
            guard let itemId = m?[WatchFileTransfer.itemKey] as? String else { continue }
            guard let count = m?[WatchFileTransfer.piecesKey] as? Int, count > 0 else {
                result[itemId] = transfer.progress.fractionCompleted
                continue
            }
            var s = sends[itemId] ?? (count, 0, 0)
            s.held += 1
            s.sent += transfer.progress.fractionCompleted
            sends[itemId] = s
        }
        for (itemId, s) in sends {
            result[itemId] = min(1, max(0, (Double(s.count - s.held) + s.sent) / Double(s.count)))
        }
        return result
    }

    /// The send to the watch has failed: what is left of it goes, and the
    /// watch is told, which asks again or fetches for itself.
    private func sendFailed(_ itemId: String, reason: String) {
        guard transferring.contains(itemId) else { return }
        Self.log.error("transfer to the watch failed: \(itemId, privacy: .public) \(reason, privacy: .public)")
        transferring.removeAll { $0 == itemId }
        currentSend[itemId] = nil
        for transfer in WCSession.default.outstandingFileTransfers
        where transfer.file.metadata?[WatchFileTransfer.itemKey] as? String == itemId {
            transfer.cancel()
        }
        Self.removePieces(itemId)
        if let file = Self.existingRelayFile(itemId) { try? FileManager.default.removeItem(at: file) }
        updateRelay(itemId) { r in
            r.stage = .failed
            r.failure = reason
        }
        send(.fetchFailed(itemId: itemId, reason: "The transfer to the watch failed"))
    }

    private func take(_ events: [WatchProgressEvent]) {
        let known = Set(pendingEvents.map(\.id)).union(settledIds)
        for event in events where !known.contains(event.id) {
            // A book's newer position makes an older one still waiting moot.
            if !event.played {
                for older in pendingEvents where older.itemId == event.itemId && !older.played && older.at <= event.at {
                    settle(older)
                }
                if pendingEvents.contains(where: { $0.itemId == event.itemId && !$0.played && $0.at > event.at }) {
                    settle(event)
                    continue
                }
            }
            pendingEvents.append(event)
        }
        persistPending()
        forward()
    }

    /// Take the watch's events and answer once the server has them, or
    /// after `limit`: the watch keeps whatever isn't named, so its place in
    /// a book isn't overwritten by the server's older one meanwhile.
    private func takeAndAnswer(_ events: [WatchProgressEvent], within limit: Duration) async -> [UUID] {
        take(events)
        let ids = Set(events.map(\.id))
        let deadline = ContinuousClock.now + limit
        while forwardTask != nil, pendingEvents.contains(where: { ids.contains($0.id) }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        let settled = Set(settledIds)
        return events.map(\.id).filter { settled.contains($0) }
    }

    private func persistPending() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pendingEvents), forKey: "watch_forward_pending")
    }

    private func settle(_ event: WatchProgressEvent) {
        pendingEvents.removeAll { $0.id == event.id }
        persistPending()
        settledIds.append(event.id)
        if settledIds.count > 400 { settledIds.removeFirst(settledIds.count - 400) }
        UserDefaults.standard.set(settledIds.map(\.uuidString), forKey: "watch_forward_settled")
    }

    /// Send what the watch handed over, oldest first, including what
    /// arrives on the way. Each event lands or stays; a server blip keeps
    /// the rest, and they are tried again in a minute while the app is up,
    /// when the server comes back, and when the app comes forward.
    func forward() {
        guard forwardTask == nil, !pendingEvents.isEmpty else { return }
        forwardRetry?.cancel()
        forwardRetry = nil
        forwardTask = Task {
            // Woken by the watch in the background, the app has seconds;
            // this asks for enough to finish what it started.
            let hold = UIApplication.shared.beginBackgroundTask(withName: "WatchForward")
            defer {
                forwardTask = nil
                if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) }
            }
            let client = JellyfinClient.shared
            guard client.isSignedIn, !client.isOffline else { return }
            while let event = pendingEvents.first {
                do {
                    if try await deliver(event, with: client) { lastForwardedAt = Date() }
                    settle(event)
                } catch is CancellationError {
                    return
                } catch APIError.server(let status, _) where (400..<500).contains(status) && ![401, 403, 408, 429].contains(status) {
                    // Never going to land — the item is gone — and it would
                    // hold up everything behind it.
                    Self.log.error("server refused a watch event for \(event.itemId, privacy: .public) with \(status); dropping it")
                    settle(event)
                } catch {
                    Self.log.error("forward failed: \(error.localizedDescription, privacy: .public)")
                    retryForward()
                    return
                }
            }
        }
    }

    private func retryForward() {
        guard forwardRetry == nil else { return }
        forwardRetry = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            forwardRetry = nil
            forward()
        }
    }

    /// The same two routes the phone's own offline sync uses. A play that
    /// the watch streamed was counted by the server when the stream began,
    /// so it is told as a stopped report at the end; a play from the
    /// watch's own copy is counted here with the played-items route.
    ///
    /// A book's event is weighed first. One heard before the book was last
    /// started anywhere else — here, on the web — or older than a position
    /// already sent, is dropped: the newer listening wins. A position for a
    /// book the server has as finished is someone starting it again, and
    /// says so first, since a stopped report leaves the tick where it is.
    /// False when dropped.
    private func deliver(_ event: WatchProgressEvent, with client: JellyfinClient) async throws -> Bool {
        var server: UserData?
        var runTimeTicks: Int64 = 0
        if event.isAudiobook {
            if !event.played, let sent = lastSentAt[event.itemId], sent.timeIntervalSince(event.at) > 0 {
                Self.log.notice("watch position for \(event.itemId, privacy: .public) is older than one already sent; dropping it")
                return false
            }
            let item = try await client.itemsByIds([event.itemId]).first
            server = item?.UserData
            runTimeTicks = item?.RunTimeTicks ?? 0
            if BookProgress.isStale(eventAt: event.at, serverLastPlayed: BookProgress.date(fromServer: server?.LastPlayedDate)) {
                Self.log.notice("watch position for \(event.itemId, privacy: .public) predates the book's last play; dropping it")
                return false
            }
        }
        if event.played, !event.streamed {
            try await client.markPlayed(event.itemId, played: true, at: event.at)
        } else {
            if event.isAudiobook, !event.played, server?.Played == true,
               !BookProgress.isFinished(positionTicks: event.positionTicks, runTimeTicks: runTimeTicks) {
                try await client.markPlayed(event.itemId, played: false)
            }
            try await client.reportPlaybackStoppedOrThrow(PlaybackReport(
                itemId: event.itemId, mediaSourceId: nil, playSessionId: nil,
                positionSeconds: Double(max(0, event.positionTicks)) / 10_000_000,
                isPaused: true, isTranscode: false
            ))
        }
        if event.isAudiobook {
            lastSentAt[event.itemId] = max(lastSentAt[event.itemId] ?? .distantPast, event.at)
            UserDefaults.standard.set(lastSentAt, forKey: "watch_forward_last_sent")
        }
        // The phone's own copy of the book, if it has one, moves too — as the
        // server's word, since the server has just been told.
        DownloadManager.shared.applyServerState(
            itemId: event.itemId,
            positionTicks: event.played ? 0 : event.positionTicks,
            played: event.played
        )
        LibraryIndex.shared.patchUserData(event.itemId) {
            if event.played { $0.Played = true; $0.PlaybackPositionTicks = 0 } else { $0.PlaybackPositionTicks = event.positionTicks }
        }
        ItemMutations.shared.changed()
        return true
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        let context = session.receivedApplicationContext
        // Only an activated session knows its outstanding transfers; read
        // before this, the list is empty and a send in flight is forgotten.
        let transfers = session.outstandingFileTransfers
        Task { @MainActor in
            for (id, sent) in Self.sentFractions(transfers) {
                Self.log.notice("send of \(id, privacy: .public) to the watch still under way, \(Int(sent * 100))%")
                if !transferring.contains(id) { transferring.append(id) }
                updateRelay(id) { $0.stage = .sending; $0.transferFraction = sent }
            }
            if !transferring.isEmpty { watchTransfers() }
            isActivated = activationState == .activated
            isPaired = paired
            isWatchAppInstalled = installed
            isReachable = reachable
            if !context.isEmpty { apply(context) }
            if installed { sendContext(now: true) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A new watch: the session is re-activated for it.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            isPaired = paired
            isWatchAppInstalled = installed
            if installed { sendContext(now: true) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in isReachable = reachable }
    }

    /// A file from the watch: its log. Moved at once — the system deletes
    /// it when this returns — into Documents/WatchLogs under its own name.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?[WatchFileTransfer.kindKey] as? String == WatchFileTransfer.logsKind else {
            Self.log.error("a file of no known kind arrived from the watch: \(String(describing: file.metadata), privacy: .public)")
            return
        }
        let destination = Self.logsFolder.appendingPathComponent(file.fileURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
            Self.log.notice("the watch's log arrived: \(destination.lastPathComponent, privacy: .public)")
        } catch {
            Self.log.error("couldn't keep the watch's log: \(error.localizedDescription, privacy: .public)")
        }
        Task { @MainActor in reloadWatchLogs() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: message) else {
            replyHandler(WatchSync.pack(WatchReply(ok: false, note: "unreadable")))
            return
        }
        Task { @MainActor in
            if case .requestContext = decoded {
                let context = await buildContext()
                lastContextSentAt = Date()
                replyHandler(WatchSync.pack(WatchReply(ok: true, context: context)))
                return
            }
            // Listening is answered once it has reached the server, well
            // inside the watch's fifteen-second patience.
            if case .progress(let events) = decoded {
                Self.log.notice("from the watch: \(events.count) listening event\(events.count == 1 ? "" : "s")")
                let settled = await takeAndAnswer(events, within: .seconds(9))
                replyHandler(WatchSync.pack(WatchReply(ok: true, delivered: settled)))
                return
            }
            handle(decoded)
            replyHandler(WatchSync.pack(WatchReply(ok: true)))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: message) else { return }
        Task { @MainActor in handle(decoded) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: userInfo) else {
            Self.log.error("unreadable transfer from the watch: \(userInfo.keys.joined(separator: ","), privacy: .public)")
            return
        }
        Task { @MainActor in handle(decoded) }
    }

    /// A file handed to the watch has arrived there, or not. Either way the
    /// phone's copy goes; a failure is told to the watch, which asks again
    /// or fetches for itself.
    ///
    /// A piece is one of many: the send is delivered when WatchConnectivity
    /// holds no other piece of it, and the whole file goes then.
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let metadata = fileTransfer.file.metadata
        let itemId = metadata?[WatchFileTransfer.itemKey] as? String
        let file = fileTransfer.file.fileURL
        let sendId = metadata?[WatchFileTransfer.sendKey] as? String
        let piece = metadata?[WatchFileTransfer.pieceKey] as? Int
        let count = metadata?[WatchFileTransfer.piecesKey] as? Int
        let othersHeld = sendId.map { id in
            session.outstandingFileTransfers.contains { $0 !== fileTransfer && $0.file.metadata?[WatchFileTransfer.sendKey] as? String == id }
        } ?? false
        Task { @MainActor in
            try? FileManager.default.removeItem(at: file)
            guard let itemId else { return }
            // After a relaunch nothing is known of the send: whatever
            // WatchConnectivity still holds is the current one.
            if let sendId, let current = currentSend[itemId], current != sendId { return }
            if let error {
                sendFailed(itemId, reason: "The send to the watch failed: \(error.localizedDescription)")
                return
            }
            if let piece, let count, othersHeld {
                if piece == 0 || piece == count - 1 { Self.log.notice("piece \(piece + 1) of \(count) of \(itemId, privacy: .public) delivered") }
                return
            }
            transferring.removeAll { $0 == itemId }
            currentSend[itemId] = nil
            if sendId != nil {
                Self.removePieces(itemId)
                if let whole = Self.existingRelayFile(itemId) { try? FileManager.default.removeItem(at: whole) }
            }
            Self.log.notice("\(itemId, privacy: .public) delivered to the watch")
            // Done with: the row goes by itself.
            relayItems.removeAll { $0.id == itemId }
            lastProgressSentAt[itemId] = nil
            persistRelay()
        }
    }
}

// MARK: - The relay session

extension WatchLink: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let itemId = taskItem(downloadTask) else { return }
        Task { @MainActor in
            if fetching.contains(itemId), totalBytesWritten > (lastMovement[itemId]?.bytes ?? -1) {
                lastMovement[itemId] = (totalBytesWritten, Date())
            }
            // The server sends a transcode with no length; then the estimate
            // is the item's runtime at the bitrate.
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (fetchEstimates[itemId] ?? 0)
            guard expected > 0 else { return }
            let fraction = min(0.99, Double(totalBytesWritten) / Double(expected))
            updateRelay(itemId) { $0.downloadFraction = fraction }
            let tenth = Int(fraction * 10)
            if tenth > (loggedTenth[itemId] ?? 0) {
                loggedTenth[itemId] = tenth
                Self.log.notice("fetching \(itemId, privacy: .public): \(tenth * 10)%, \(totalBytesWritten / (1024 * 1024))MB")
            }
            reportProgress(itemId, fraction * Self.fetchShare)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let itemId = taskItem(downloadTask) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        if let old = Self.existingRelayFile(itemId) { try? FileManager.default.removeItem(at: old) }
        let destination = Self.relayFile(itemId, ext: Self.taskInfo(downloadTask).ext)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        var moved = false
        if (200..<300).contains(status) {
            moved = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        }
        Task { @MainActor in
            if moved {
                await fetched(itemId: itemId, at: destination, expectedSeconds: nil)
            } else {
                fetchFailed(itemId, reason: status == 401 ? "The server refused the sign-in" : "Server error \(status)")
            }
        }
    }

    /// A download that ended short. Cut off — the connection dropped, the
    /// app was closed from the switcher, the phone slept through it — it is
    /// picked up again here, from where it stopped when the server allows
    /// it. Told to the watch as a failure, it was asked for again and
    /// started over from nothing: an hour of a long book, lost each time.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let info = (error as NSError).userInfo
        let code = (error as? URLError)?.code
        // Cancelled by the system rather than by this app: this app's own
        // cancels take the task out of the map first. The map may be gone
        // by the time a closed app hears of it, so the task says whose.
        let bySystem = code == .cancelled && info[NSURLErrorBackgroundTaskCancelledReasonKey] != nil
        let mapped = taskItem(task)
        guard let itemId = mapped ?? (bySystem ? Self.taskInfo(task).itemId : nil) else { return }
        let taskId = task.taskIdentifier
        let resumeData = info[NSURLSessionDownloadTaskResumeData] as? Data
        let transient: Set<URLError.Code> = [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .backgroundSessionWasDisconnected]
        let cutOff = bySystem || resumeData != nil || code.map(transient.contains) == true
        Task { @MainActor in
            // Placed by its description, not the map: a task from before a
            // kill, whose item launch may already have started again.
            if mapped == nil, fetching.contains(itemId) || fetchQueue.contains(itemId) { return }
            if cutOff, let resumeData { Self.saveResumeData(resumeData, for: itemId) }
            taskMap.withLock { map in map[taskId] = nil }
            if fetching.contains(itemId) {
                // Cut off, it goes back to the head of the queue with what
                // was learned of it; failed or cancelled, all of it goes.
                let item = fetchItems[itemId]
                forget(itemId)
                if cutOff { fetchItems[itemId] = item }
            }
            if code == .cancelled, !bySystem {
                persistFetches()
                pumpFetches()
                return
            }
            guard cutOff else {
                fetchFailed(itemId, reason: error.localizedDescription)
                return
            }
            let tries = (resumes[itemId] ?? 0) + 1
            resumes[itemId] = tries
            guard tries <= Self.resumeLimit else {
                Self.log.error("fetch of \(itemId, privacy: .public) cut off \(tries) times; giving up")
                fetchFailed(itemId, reason: error.localizedDescription)
                return
            }
            Self.log.error("fetch of \(itemId, privacy: .public) cut off (\(error.localizedDescription, privacy: .public)); picking it up again \(resumeData == nil ? "from the start" : "from where it stopped", privacy: .public), try \(tries + 1)")
            if !fetchQueue.contains(itemId) { fetchQueue.insert(itemId, at: 0) }
            persistFetches()
            pumpFetches()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in releaseFetchWake() }
    }
}

/// One item fetched for the watch, for Settings.
struct RelayItem: Codable, Hashable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case waiting, downloading, sending, delivered, failed
        var isFinished: Bool { self == .delivered || self == .failed }
    }

    var id: String
    var title: String?
    var stage: Stage = .waiting
    /// From the server to the phone; nil before it starts.
    var downloadFraction: Double?
    /// From the phone to the watch; nil before it starts.
    var transferFraction: Double?
    var failure: String?
    var updatedAt = Date()
    /// When the watch asked; nil for a row older than the field.
    var askedAt: Date?
}

#endif
