//  The watch's side of the conversation with the phone, and the queue of
//  listening waiting to be told to somebody.
//
//  The phone hands over the sign-in and the mirror plan as the application
//  context; the watch hands back what it has on it the same way. Listening —
//  where a book was left, a song heard to its end — is queued here and sent
//  the way the phone's own offline sync works: to the phone first when it is
//  in reach, which forwards it to the server; straight to the server when the
//  phone is away and the watch has a network of its own; and kept until one
//  of those works.

import Foundation
import Observation
import WatchConnectivity
import os

// MARK: - The queue

@MainActor
@Observable
final class WatchSyncQueue {
    static let shared = WatchSyncQueue()

    private(set) var pending: [WatchProgressEvent] = []
    private(set) var lastFlushedAt: Date?
    private(set) var lastRoute: String?
    private var isFlushing = false
    /// Something was queued while a flush was under way: go round again.
    private var flushAgain = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: "watch_pending_events"),
           let saved = try? JSONDecoder().decode([WatchProgressEvent].self, from: data) {
            pending = saved
        }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: "watch_pending_events")
    }

    /// Queue one event. A position for an item replaces the position waiting
    /// for it — a book paused ten times is one resume point, not ten.
    func add(_ event: WatchProgressEvent) {
        if !event.played {
            pending.removeAll { $0.itemId == event.itemId && !$0.played }
        }
        pending.append(event)
        persist()
        Task { await flush() }
    }

    func hasPending(for itemId: String) -> Bool { pending.contains { $0.itemId == itemId } }

    /// Try to send everything waiting. Phone first, server second.
    func flush() async {
        guard !isFlushing else {
            flushAgain = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushAgain = false
            // A book noted and never queued — the app put away between the
            // two — goes too, from its record.
            let unsent = WatchDownloads.shared.unsentBookEvents(except: Set(pending.map(\.itemId)))
            if !unsent.isEmpty {
                pending += unsent
                persist()
            }
            guard !pending.isEmpty else { return }
            await flushOnce()
        } while flushAgain
    }

    private func flushOnce() async {
        let batch = pending
        if WatchLink.shared.isPhoneReachable, let reply = await WatchLink.shared.send(events: batch), reply.ok {
            // A phone that names what reached the server keeps the rest and
            // sends it when it can; they stay here too, so the watch's place
            // in a book isn't overwritten by the server's older one, and are
            // asked about again next time. An older phone took the lot.
            let delivered = reply.delivered.map(Set.init) ?? Set(batch.map(\.id))
            let settled = batch.filter { delivered.contains($0.id) }
            settle(settled)
            if !settled.isEmpty {
                lastRoute = "iPhone"
                lastFlushedAt = Date()
            }
            return
        }
        let client = JellyfinClient.shared
        guard client.isSignedIn, WatchDownloads.shared.hasNetwork, await client.checkOnline() else { return }
        for event in batch {
            do {
                try await client.send(event)
                settle([event])
            } catch is CancellationError {
                return
            } catch APIError.server(let status, _) where (400..<500).contains(status) && ![401, 403, 408, 429].contains(status) {
                // The server won't ever take this one — the item is gone —
                // and keeping it would hold up everything behind it.
                WatchLog.error("link", "server refused an event for \(event.itemId) with \(status); dropping it")
                settle([event])
            } catch {
                // Whatever stopped this one stops the rest for now.
                WatchLink.log.error("direct sync failed: \(error.localizedDescription)")
                return
            }
        }
        lastRoute = "server"
        lastFlushedAt = Date()
    }

    /// These have reached the server, or been found older than what it has.
    private func settle(_ done: [WatchProgressEvent]) {
        guard !done.isEmpty else { return }
        let ids = Set(done.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        persist()
        for event in done where event.isAudiobook {
            WatchDownloads.shared.markSynced(itemId: event.itemId, through: event.at)
        }
    }
}

// MARK: - The link

@MainActor
@Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    nonisolated static let log = Logger(subsystem: "scottai.FellyJin.watchkitapp", category: "link")

    private(set) var isActivated = false
    private(set) var isPhoneReachable = false
    /// A phone with Aquarium on it is paired: it can fetch for the watch,
    /// in reach or not — a queued transfer waits for it.
    private(set) var hasCompanion = false
    private(set) var lastPhoneContextAt: Date?
    private(set) var lastInventorySentAt: Date?

    private var inventoryTask: Task<Void, Never>?
    private var revision = 0
    /// When the newest context applied was built. The phone's revision
    /// restarts with each launch, so its clock is what orders them: the
    /// context the system kept from last time can land after a fresh one.
    private var lastContextSentAt = UserDefaults.standard.object(forKey: "phone_context_sent_at") as? Date

    private override init() {
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        WatchDownloads.shared.onChange = { [weak self] in self?.publishInventory() }
    }

    // MARK: Phone → watch

    private func apply(_ dictionary: [String: Any]) {
        guard let context = WatchSync.unpack(PhoneContext.self, from: dictionary) else { return }
        apply(context)
    }

    /// Ask the phone for the sign-in and the plan now. The application
    /// context is what normally carries them; this covers a watch that
    /// missed it, and a phone that couldn't send it.
    func requestContext() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(WatchSync.pack(WatchMessage.requestContext), replyHandler: { reply in
            guard let answer = WatchSync.unpack(WatchReply.self, from: reply), let context = answer.context else { return }
            Task { @MainActor in self.apply(context) }
        }, errorHandler: { error in
            WatchLog.error("link", "context request failed: \(error.localizedDescription)")
        })
    }

    private func apply(_ context: PhoneContext) {
        if let last = lastContextSentAt, context.sentAt < last {
            WatchLog.note("link", "ignoring an older context from the phone: revision \(context.revision), built \(context.sentAt.formatted(.iso8601))")
            return
        }
        lastContextSentAt = context.sentAt
        UserDefaults.standard.set(context.sentAt, forKey: "phone_context_sent_at")
        lastPhoneContextAt = Date()
        WatchLog.note("link", "context from the phone: revision \(context.revision), \(context.credentials == nil ? "signed out" : "signed in"), \(context.mirror.bookIds.count) books, \(context.mirror.playlistIds.count) playlists")
        let client = JellyfinClient.shared
        if let credentials = context.credentials {
            client.install(credentials)
        } else if client.isSignedIn {
            client.signOut()
        }
        WatchDownloads.shared.apply(plan: context.mirror)
        Task {
            await WatchSyncQueue.shared.flush()
            await WatchActions.refreshBookPositions()
        }
        publishInventory()
    }

    private func handle(_ message: WatchMessage) {
        let downloads = WatchDownloads.shared
        switch message {
        case .deleteGroup(let kind, let id):
            downloads.delete(group: kind, id: id)
        case .deleteAll:
            downloads.deleteEverything()
        case .download(let request):
            Task { await downloads.download(request) }
        case .requestInventory:
            publishInventory(now: true)
        case .requestLogs:
            Task { await sendLogs() }
        case .fetchProgress(let itemId, let fraction):
            downloads.notePhoneProgress(itemId: itemId, fraction: fraction)
        case .fetchFailed(let itemId, let reason):
            downloads.phoneFailed(itemId: itemId, reason: reason)
        case .progress, .fetch, .fetchMany, .cancelFetch, .playlistRemoved, .requestContext, .logs:
            break
        }
    }

    /// The watch's log, as a file transfer: it goes in the background, in
    /// reach or not, and the phone keeps it under Settings → Apple Watch.
    private(set) var logsSentAt: Date?
    private(set) var logsSending = false

    func sendLogs() async {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, !logsSending else { return }
        logsSending = true
        defer { logsSending = false }
        WatchLog.note("link", "sending the log to the phone")
        guard let file = await WatchLog.export() else { return }
        // In reach, the log goes now, in pieces, and the phone answers each
        // one; away, or if a piece is refused, it goes as a file transfer,
        // which waits for the phone.
        if WCSession.default.isReachable, await sendLogsInline(file) {
            logsSentAt = Date()
            return
        }
        WCSession.default.transferFile(file, metadata: [WatchFileTransfer.kindKey: WatchFileTransfer.logsKind])
        logsSentAt = Date()
    }

    private func sendLogsInline(_ file: URL) async -> Bool {
        guard let raw = try? Data(contentsOf: file),
              let packed = try? (raw as NSData).compressed(using: .lzfse) as Data else { return false }
        let piece = 40 * 1024
        let count = max(1, (packed.count + piece - 1) / piece)
        let id = UUID().uuidString
        for index in 0..<count {
            let slice = packed.subdata(in: index * piece ..< min((index + 1) * piece, packed.count))
            let chunk = WatchLogChunk(id: id, name: file.lastPathComponent, index: index, count: count, data: slice)
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let done = OSAllocatedUnfairLock(initialState: false)
                func finish(_ ok: Bool) {
                    if done.withLock({ was in if was { return false }; was = true; return true }) { continuation.resume(returning: ok) }
                }
                WCSession.default.sendMessage(WatchSync.pack(WatchMessage.logs(chunk)), replyHandler: { reply in
                    finish(WatchSync.unpack(WatchReply.self, from: reply)?.ok ?? false)
                }, errorHandler: { error in
                    WatchLog.error("link", "log piece \(index + 1) of \(count) refused: \(error.localizedDescription)")
                    finish(false)
                })
                Task {
                    try? await Task.sleep(for: .seconds(20))
                    finish(false)
                }
            }
            guard ok else { return false }
        }
        WatchLog.note("link", "log sent in \(count) piece\(count == 1 ? "" : "s"), \(packed.count / 1024)KB packed from \(raw.count / 1024)KB")
        return true
    }

    /// A message for the phone: now when it is in reach, queued for its
    /// next wake otherwise. A fetch is always queued, so it survives both
    /// apps being put away.
    func send(_ message: WatchMessage) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload = WatchSync.pack(message)
        // In reach, a message lands at once; away, a queued transfer waits
        // for the phone — and a message that fails on the way becomes one.
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in WCSession.default.transferUserInfo(payload) }
        } else {
            WCSession.default.transferUserInfo(payload)
        }
    }

    // MARK: Watch → phone

    /// What is on the watch, as the application context: the latest is the
    /// only one that matters. Debounced, since a download landing writes
    /// the record twice and the cover once.
    func publishInventory(now: Bool = false) {
        inventoryTask?.cancel()
        inventoryTask = Task {
            if !now { try? await Task.sleep(for: .seconds(1.5)) }
            guard !Task.isCancelled else { return }
            guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
            revision += 1
            let context = WatchContext(
                revision: revision,
                inventory: WatchDownloads.shared.inventory(),
                awaitingPhone: WatchDownloads.shared.awaitingPhone,
                playlistIds: WatchDownloads.shared.playlists.map(\.id),
                signedIn: JellyfinClient.shared.isSignedIn
            )
            do {
                try WCSession.default.updateApplicationContext(WatchSync.pack(context))
                lastInventorySentAt = Date()
            } catch {
                WatchLog.error("link", "inventory not sent: \(error.localizedDescription)")
            }
        }
    }

    /// Hand the phone these events and wait for its answer: which of them
    /// reached the server. Nil when it didn't answer.
    func send(events: [WatchProgressEvent]) async -> WatchReply? {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return nil }
        let payload = WatchSync.pack(WatchMessage.progress(events))
        return await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            func finish(_ reply: WatchReply?) {
                let first = done.withLock { was in
                    if was { return false }
                    was = true
                    return true
                }
                if first { continuation.resume(returning: reply) }
            }
            WCSession.default.sendMessage(payload, replyHandler: { reply in
                finish(WatchSync.unpack(WatchReply.self, from: reply))
            }, errorHandler: { error in
                WatchLog.error("link", "phone did not take events: \(error.localizedDescription)")
                finish(nil)
            })
            // WatchConnectivity times a reply out on its own, but not quickly.
            // The phone answers once the server has the events, or after
            // about ten seconds of trying.
            Task {
                try? await Task.sleep(for: .seconds(15))
                finish(nil)
            }
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        let companion = session.isCompanionAppInstalled
        WatchLog.note("link", "session \(activationState == .activated ? "activated" : "not activated (\(activationState.rawValue))")\(error.map { ": \($0.localizedDescription)" } ?? ""), phone \(reachable ? "in reach" : "away"), companion \(companion ? "installed" : "missing")")
        Task { @MainActor in
            isActivated = activationState == .activated
            isPhoneReachable = reachable
            hasCompanion = companion
            if !context.isEmpty { apply(context) }
            if reachable { requestContext() }
            publishInventory(now: true)
            WatchDownloads.shared.pump()
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        let companion = session.isCompanionAppInstalled
        Task { @MainActor in
            hasCompanion = companion
            WatchDownloads.shared.pump()
        }
    }

    /// A file from the phone: an item it fetched for the watch. Moved into
    /// the item's folder here and now — the system deletes it when this
    /// returns — and then measured before it is believed.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let itemId = file.metadata?[WatchFileTransfer.itemKey] as? String else {
            WatchLog.error("link", "a file with no item id arrived from the phone: \(String(describing: file.metadata))")
            return
        }
        let folder = WatchDownloads.folder(itemId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The server's own file keeps its type: an .mp3 named .m4a won't open.
        let ext = (file.metadata?[WatchFileTransfer.extensionKey] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "m4a"
        let destination = folder.appendingPathComponent("audio.\(ext)")
        let source: URL
        if let send = file.metadata?[WatchFileTransfer.sendKey] as? String {
            guard let whole = Self.takePiece(file.fileURL, metadata: file.metadata, send: send, itemId: itemId, folder: folder) else {
                Task { @MainActor in WatchDownloads.shared.phoneStillAtIt(itemId) }
                return
            }
            source = whole
        } else {
            WatchLog.note("link", "file for \(itemId) arrived from the phone")
            source = file.fileURL
        }
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("audio.") {
            try? FileManager.default.removeItem(at: old)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            WatchLog.error("link", "couldn't keep the phone's file: \(error.localizedDescription)")
            return
        }
        Self.removeIncoming(in: folder)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        Task { @MainActor in
            await WatchDownloads.shared.receivedFromPhone(itemId: itemId, at: destination, bytes: bytes)
        }
    }

    /// One piece of a file the phone sent in pieces. It joins the send's
    /// partial file when its turn comes — pieces mostly arrive in order,
    /// and one that doesn't waits beside it — so nothing is copied whole at
    /// the end. The finished file, once the last piece is in.
    nonisolated private static func takePiece(_ file: URL, metadata m: [String: Any]?, send: String, itemId: String, folder: URL) -> URL? {
        guard let index = m?[WatchFileTransfer.pieceKey] as? Int,
              let count = m?[WatchFileTransfer.piecesKey] as? Int, count > 0,
              let pieceBytes = (m?[WatchFileTransfer.pieceBytesKey] as? NSNumber)?.int64Value, pieceBytes > 0 else {
            WatchLog.error("link", "a piece for \(itemId) arrived without its place: \(String(describing: m))")
            return nil
        }
        let total = (m?[WatchFileTransfer.bytesKey] as? NSNumber)?.int64Value ?? 0
        let fm = FileManager.default
        let incoming = folder.appendingPathComponent("incoming-\(send)", isDirectory: true)
        // A send left behind — cancelled, or overtaken by another — goes
        // once it has sat for an hour.
        for other in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where other.lastPathComponent.hasPrefix("incoming-") && other.lastPathComponent != incoming.lastPathComponent {
            let at = (try? other.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(at) > 60 * 60 { try? fm.removeItem(at: other) }
        }
        try? fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        let piece = incoming.appendingPathComponent("\(index).part")
        try? fm.removeItem(at: piece)
        do {
            try fm.moveItem(at: file, to: piece)
        } catch {
            WatchLog.error("link", "couldn't keep piece \(index + 1) of \(count) for \(itemId): \(error.localizedDescription)")
            return nil
        }
        let partial = incoming.appendingPathComponent("partial")
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        guard let out = try? FileHandle(forWritingTo: partial) else { return nil }
        defer { try? out.close() }
        // What is in already: whole pieces only. A write cut short by a
        // kill is trimmed back and done again from its piece, which is
        // removed only once it is in.
        var size = Int64((try? out.seekToEnd()) ?? 0)
        var next: Int
        if total > 0, size == total {
            next = count
        } else {
            if size % pieceBytes != 0 {
                size -= size % pieceBytes
                try? out.truncate(atOffset: UInt64(size))
            }
            next = Int(size / pieceBytes)
        }
        while next < count {
            let waiting = incoming.appendingPathComponent("\(next).part")
            guard fm.fileExists(atPath: waiting.path), let input = try? FileHandle(forReadingFrom: waiting) else { break }
            var ok = true
            while let data = try? input.read(upToCount: 1024 * 1024), !data.isEmpty {
                guard (try? out.write(contentsOf: data)) != nil else { ok = false; break }
            }
            try? input.close()
            guard ok else {
                try? out.truncate(atOffset: UInt64(Int64(next) * pieceBytes))
                WatchLog.error("link", "couldn't add piece \(next + 1) of \(count) for \(itemId), \(WatchLog.disk)")
                return nil
            }
            try? fm.removeItem(at: waiting)
            next += 1
        }
        WatchLog.note("link", "piece \(index + 1) of \(count) for \(itemId) arrived, \(next) in place, \(WatchLog.memory)")
        return next == count ? partial : nil
    }

    /// Whatever sends in pieces an item still has on the go.
    nonisolated private static func removeIncoming(in folder: URL) {
        for other in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where other.lastPathComponent.hasPrefix("incoming-") {
            try? FileManager.default.removeItem(at: other)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            isPhoneReachable = reachable
            if reachable {
                requestContext()
                WatchDownloads.shared.pump()
                await WatchSyncQueue.shared.flush()
                await WatchActions.refreshBookPositions()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let message = WatchSync.unpack(WatchMessage.self, from: userInfo) else { return }
        Task { @MainActor in handle(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: message) else { return }
        Task { @MainActor in handle(decoded) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: message) else {
            replyHandler(WatchSync.pack(WatchReply(ok: false, note: "unreadable")))
            return
        }
        Task { @MainActor in
            handle(decoded)
            replyHandler(WatchSync.pack(WatchReply(ok: true)))
        }
    }
}
