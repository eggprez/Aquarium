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
        guard !pending.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let batch = pending
        if WatchLink.shared.isPhoneReachable {
            if await WatchLink.shared.send(events: batch) {
                remove(batch)
                lastRoute = "iPhone"
                lastFlushedAt = Date()
                return
            }
        }
        let client = JellyfinClient.shared
        guard client.isSignedIn, WatchDownloads.shared.hasNetwork, await client.checkOnline() else { return }
        for event in batch {
            do {
                try await client.send(event)
                remove([event])
            } catch is CancellationError {
                return
            } catch {
                // Whatever stopped this one stops the rest for now.
                WatchLink.log.error("direct sync failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        lastRoute = "server"
        lastFlushedAt = Date()
    }

    private func remove(_ sent: [WatchProgressEvent]) {
        let ids = Set(sent.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        persist()
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
    private(set) var lastPhoneContextAt: Date?
    private(set) var lastInventorySentAt: Date?

    private var inventoryTask: Task<Void, Never>?
    private var revision = 0

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
        lastPhoneContextAt = Date()
        let client = JellyfinClient.shared
        if let credentials = context.credentials {
            client.install(credentials)
        } else if client.isSignedIn {
            client.signOut()
        }
        WatchDownloads.shared.apply(plan: context.mirror)
        Task { await WatchSyncQueue.shared.flush() }
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
        case .progress:
            break
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
                signedIn: JellyfinClient.shared.isSignedIn
            )
            do {
                try WCSession.default.updateApplicationContext(WatchSync.pack(context))
                lastInventorySentAt = Date()
            } catch {
                Self.log.error("inventory not sent: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Hand the phone these events and wait for it to say it took them.
    func send(events: [WatchProgressEvent]) async -> Bool {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return false }
        let payload = WatchSync.pack(WatchMessage.progress(events))
        return await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            func finish(_ ok: Bool) {
                let first = done.withLock { was in
                    if was { return false }
                    was = true
                    return true
                }
                if first { continuation.resume(returning: ok) }
            }
            WCSession.default.sendMessage(payload, replyHandler: { reply in
                finish(WatchSync.unpack(WatchReply.self, from: reply)?.ok ?? false)
            }, errorHandler: { error in
                Self.log.error("phone did not take events: \(error.localizedDescription, privacy: .public)")
                finish(false)
            })
            // WatchConnectivity times a reply out on its own, but not quickly.
            Task {
                try? await Task.sleep(for: .seconds(15))
                finish(false)
            }
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            isActivated = activationState == .activated
            isPhoneReachable = reachable
            if !context.isEmpty { apply(context) }
            publishInventory(now: true)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            isPhoneReachable = reachable
            if reachable { await WatchSyncQueue.shared.flush() }
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
