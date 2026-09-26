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

import Foundation
import Observation
import WatchConnectivity
import os

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

    private var started = false
    private var revision = 0
    private var contextTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?

    var isAvailable: Bool { WCSession.isSupported() && isPaired && isWatchAppInstalled }

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "watch_forward_pending"),
           let saved = try? JSONDecoder().decode([WatchProgressEvent].self, from: data) {
            pendingEvents = saved
        }
    }

    /// Called once at launch.
    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
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
        let client = JellyfinClient.shared
        var credentials: WatchCredentials?
        if let s = client.session, let token = Keychain.token(server: s.server, userId: s.userId) {
            credentials = WatchCredentials(server: s.server, userId: s.userId, userName: s.userName, serverId: s.serverId, token: token)
        }
        var plan = WatchMirrorPlan()
        plan.playlistIds = Preferences.shared.watchPlaylistIds
        if credentials != nil, !client.isOffline {
            let books = (try? await client.resumeAudio(limit: 12)) ?? []
            plan.bookIds = books.filter(\.isAudiobook).map(\.Id)
        } else if let last = lastPlan {
            plan.bookIds = last.bookIds
        }
        lastPlan = plan
        revision += 1
        let context = PhoneContext(revision: revision, credentials: credentials, mirror: plan)
        do {
            try WCSession.default.updateApplicationContext(WatchSync.pack(context))
            lastContextSentAt = Date()
        } catch {
            Self.log.error("context not sent: \(error.localizedDescription, privacy: .public)")
        }
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

    // MARK: - Watch → phone

    private func apply(_ dictionary: [String: Any]) {
        guard let context = WatchSync.unpack(WatchContext.self, from: dictionary) else { return }
        inventory = context.inventory
        inventoryAt = context.sentAt
        watchSignedIn = context.signedIn
    }

    /// Listening from the watch: queued, then told to the server in order.
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

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: message) else {
            replyHandler(WatchSync.pack(WatchReply(ok: false, note: "unreadable")))
            return
        }
        Task { @MainActor in
            if case .progress(let events) = decoded { take(events) }
            replyHandler(WatchSync.pack(WatchReply(ok: true)))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: message) else { return }
        Task { @MainActor in
            if case .progress(let events) = decoded { take(events) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let decoded = WatchSync.unpack(WatchMessage.self, from: userInfo) else { return }
        Task { @MainActor in
            if case .progress(let events) = decoded { take(events) }
        }
    }
}

#endif
