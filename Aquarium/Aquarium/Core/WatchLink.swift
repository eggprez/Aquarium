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
    private(set) var inventoryAt: Date?
    private(set) var watchSignedIn = false
    private(set) var lastContextSentAt: Date?
    /// Listening the watch handed over that the server hasn't taken yet.
    private(set) var pendingEvents: [WatchProgressEvent] = []
    private(set) var lastForwardedAt: Date?

    /// Items the watch has asked for, in the order asked; the first is the
    /// one being fetched. Kept across launches.
    private(set) var fetchQueue: [String] = []
    private(set) var fetching: String?
    private(set) var fetchFraction: Double?
    /// Files fetched and handed to WatchConnectivity, still on their way.
    private(set) var transferring: [String] = []

    private var started = false
    private var revision = 0
    private var contextTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    @ObservationIgnored nonisolated private let taskMap = OSAllocatedUnfairLock(initialState: [Int: String]())
    @ObservationIgnored private var fetchSession: URLSession!
    private var fetchCompletion: (() -> Void)?
    private var lastProgressSentAt = Date.distantPast

    nonisolated static let fetchSessionIdentifier = "scottai.FellyJin.watchrelay"

    var isAvailable: Bool { WCSession.isSupported() && isPaired && isWatchAppInstalled }

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "watch_forward_pending"),
           let saved = try? JSONDecoder().decode([WatchProgressEvent].self, from: data) {
            pendingEvents = saved
        }
        fetchQueue = UserDefaults.standard.stringArray(forKey: "watch_fetch_queue") ?? []
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
        fetchSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Called once at launch.
    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        transferring = session.outstandingFileTransfers.compactMap { $0.file.metadata?[WatchFileTransfer.itemKey] as? String }
        rejoinFetches()
    }

    /// The system woke the app for the relay session's events.
    func handleFetchEvents(completion: @escaping () -> Void) {
        fetchCompletion = completion
        _ = fetchSession
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
            let books = (try? await client.resumeAudio(limit: 12)) ?? []
            plan.bookIds = books.filter(\.isAudiobook).map(\.Id)
        } else if let last = lastPlan {
            plan.bookIds = last.bookIds
        }
        lastPlan = plan
        revision += 1
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
        send(.deleteGroup(kind: group.kind, id: group.id))
        // Shown gone at once; the watch's next inventory confirms it.
        inventory?.groups.removeAll { $0.id == group.id && $0.kind == group.kind }
    }

    func deleteEverythingOnWatch() {
        send(.deleteAll)
        inventory?.groups = []
        inventory?.itemCount = 0
        inventory?.totalBytes = 0
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
    }

    /// Listening from the watch: queued, then told to the server in order.
    private func handle(_ message: WatchMessage) {
        Self.log.notice("from the watch: \(String(describing: message).prefix(80), privacy: .public)")
        switch message {
        case .progress(let events): take(events)
        case .fetch(let itemId): enqueueFetch(itemId)
        case .fetchMany(let itemIds): for id in itemIds { enqueueFetch(id, pumping: false) }; persistFetches(); pumpFetches()
        case .cancelFetch(let itemId): cancelFetch(itemId)
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

    nonisolated private static func relayFile(_ itemId: String) -> URL {
        relayFolder.appendingPathComponent("\(JellyfinClient.pathId(itemId)).m4a")
    }

    private func persistFetches() {
        UserDefaults.standard.set(fetchQueue, forKey: "watch_fetch_queue")
        UserDefaults.standard.set(try? JSONEncoder().encode(taskMap.withLock { $0 }), forKey: "watch_fetch_tasks")
    }

    private func enqueueFetch(_ itemId: String, pumping: Bool = true) {
        guard !fetchQueue.contains(itemId), fetching != itemId, !transferring.contains(itemId) else {
            Self.log.notice("fetch of \(itemId, privacy: .public) already under way")
            return
        }
        // Already fetched and waiting: hand it over again.
        let file = Self.relayFile(itemId)
        if FileManager.default.fileExists(atPath: file.path) {
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
        if fetching == itemId {
            fetchSession.getAllTasks { tasks in
                for task in tasks where self.taskItem(task) == itemId { task.cancel() }
            }
        }
        for transfer in WCSession.default.outstandingFileTransfers
        where transfer.file.metadata?[WatchFileTransfer.itemKey] as? String == itemId {
            transfer.cancel()
        }
        transferring.removeAll { $0 == itemId }
        try? FileManager.default.removeItem(at: Self.relayFile(itemId))
        persistFetches()
    }

    /// At launch: a fetch the session is still running stands; a queue
    /// head with no task behind it is started again.
    private func rejoinFetches() {
        fetchSession.getAllTasks { live in
            let running = live.compactMap { self.taskItem($0) }
            Task { @MainActor in
                if let first = running.first {
                    self.fetching = first
                    self.fetchQueue.removeAll { $0 == first }
                } else {
                    self.taskMap.withLock { $0 = [:] }
                }
                self.persistFetches()
                self.pumpFetches()
            }
        }
    }

    /// One at a time: the server encodes one, the phone sends one.
    private func pumpFetches() {
        guard fetching == nil, let next = fetchQueue.first else { return }
        let client = JellyfinClient.shared
        guard client.isSignedIn else { Self.log.notice("fetch waits: not signed in"); return }
        fetchQueue.removeFirst()
        fetching = next
        fetchFraction = nil
        persistFetches()
        Task {
            var item: BaseItem?
            if !client.isOffline { item = try? await client.musicItem(next) }
            guard fetching == next else { return }
            guard let item, let request = Self.fetchRequest(for: item, client: client) else {
                fetchFailed(next, reason: client.isOffline ? "The phone can't reach the server" : "The server doesn't have this item")
                return
            }
            let task = fetchSession.downloadTask(with: request)
            taskMap.withLock { $0[task.taskIdentifier] = next }
            persistFetches()
            task.resume()
            Self.log.notice("fetching \(next, privacy: .public) for the watch")
        }
    }

    /// The same address the watch would use itself: AAC at 128 kbps in an
    /// MP4 wrapper, one file. The token goes in a header.
    private static func fetchRequest(for item: BaseItem, client: JellyfinClient) -> URLRequest? {
        guard let s = client.session else { return nil }
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
        return req
    }

    nonisolated private func taskItem(_ task: URLSessionTask) -> String? {
        taskMap.withLock { $0[task.taskIdentifier] }
    }

    private func fetchFailed(_ itemId: String, reason: String) {
        Self.log.error("fetch for the watch failed: \(itemId, privacy: .public) \(reason, privacy: .public)")
        if fetching == itemId { fetching = nil }
        fetchFraction = nil
        taskMap.withLock { map in map = map.filter { $0.value != itemId } }
        persistFetches()
        send(.fetchFailed(itemId: itemId, reason: reason))
        pumpFetches()
    }

    /// A file has landed. Measured before it goes to the watch: the server
    /// cannot promise a transcode's length, and a short file sent across
    /// would only be measured and thrown away there.
    private func fetched(itemId: String, at url: URL, expectedSeconds: Double?) async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let whole = seconds.isFinite && seconds > 0 && (expectedSeconds.map { seconds >= $0 * 0.97 } ?? true)
        guard whole else {
            try? FileManager.default.removeItem(at: url)
            fetchFailed(itemId, reason: "The file arrived incomplete")
            return
        }
        if fetching == itemId { fetching = nil }
        fetchFraction = nil
        taskMap.withLock { map in map = map.filter { $0.value != itemId } }
        persistFetches()
        handOver(itemId: itemId, file: url, seconds: seconds)
        pumpFetches()
    }

    private func handOver(itemId: String, file: URL, seconds: Double? = nil) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        var metadata: [String: Any] = [WatchFileTransfer.itemKey: itemId, WatchFileTransfer.bytesKey: bytes]
        if let seconds { metadata[WatchFileTransfer.secondsKey] = seconds }
        WCSession.default.transferFile(file, metadata: metadata)
        if !transferring.contains(itemId) { transferring.append(itemId) }
        Self.log.notice("handing \(itemId, privacy: .public) to the watch, \(bytes) bytes")
    }

    private func take(_ events: [WatchProgressEvent]) {
        let known = Set(pendingEvents.map(\.id))
        pendingEvents += events.filter { !known.contains($0.id) }
        persistPending()
        forward()
    }

    private func persistPending() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pendingEvents), forKey: "watch_forward_pending")
    }

    /// Send what the watch handed over. Each event lands or stays; a server
    /// blip mid-list keeps the rest for next time.
    func forward() {
        guard forwardTask == nil, !pendingEvents.isEmpty else { return }
        forwardTask = Task {
            defer { forwardTask = nil }
            let client = JellyfinClient.shared
            guard client.isSignedIn, !client.isOffline else { return }
            for event in pendingEvents {
                do {
                    try await deliver(event, with: client)
                    pendingEvents.removeAll { $0.id == event.id }
                    persistPending()
                    lastForwardedAt = Date()
                } catch is CancellationError {
                    return
                } catch {
                    Self.log.error("forward failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }
    }

    /// The same two routes the phone's own offline sync uses. A play that
    /// the watch streamed was counted by the server when the stream began,
    /// so it is told as a stopped report at the end; a play from the
    /// watch's own copy is counted here with the played-items route.
    private func deliver(_ event: WatchProgressEvent, with client: JellyfinClient) async throws {
        if event.played, !event.streamed {
            try await client.markPlayed(event.itemId, played: true, at: event.at)
        } else if event.positionTicks > 0 {
            try await client.reportPlaybackStoppedOrThrow(PlaybackReport(
                itemId: event.itemId, mediaSourceId: nil, playSessionId: nil,
                positionSeconds: Double(event.positionTicks) / 10_000_000,
                isPaused: true, isTranscode: false
            ))
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
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        let context = session.receivedApplicationContext
        Task { @MainActor in
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
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let itemId = fileTransfer.file.metadata?[WatchFileTransfer.itemKey] as? String
        let file = fileTransfer.file.fileURL
        Task { @MainActor in
            try? FileManager.default.removeItem(at: file)
            guard let itemId else { return }
            transferring.removeAll { $0 == itemId }
            if let error {
                Self.log.error("transfer to the watch failed: \(error.localizedDescription, privacy: .public)")
                send(.fetchFailed(itemId: itemId, reason: "The transfer to the watch failed"))
            }
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
            // The server sends a transcode with no length; the estimate is
            // the item's runtime at the bitrate, which the watch keeps.
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            fetchFraction = fraction
            if WCSession.default.isReachable, Date().timeIntervalSince(lastProgressSentAt) > 2 {
                lastProgressSentAt = Date()
                WCSession.default.sendMessage(WatchSync.pack(WatchMessage.fetchProgress(itemId: itemId, fraction: fraction)), replyHandler: nil, errorHandler: nil)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let itemId = taskItem(downloadTask) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        let destination = Self.relayFile(itemId)
        try? FileManager.default.removeItem(at: destination)
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

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let itemId = taskItem(task) else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor in
            if cancelled {
                if fetching == itemId { fetching = nil }
                taskMap.withLock { map in map = map.filter { $0.value != itemId } }
                persistFetches()
                pumpFetches()
            } else {
                fetchFailed(itemId, reason: error.localizedDescription)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            fetchCompletion?()
            fetchCompletion = nil
        }
    }
}

#endif
