//  SyncPlay: the same film on everyone's screen at once, through the Jellyfin
//  server. SharePlay's other half — no FaceTime call, no Apple account, and
//  it works with the people watching in a browser or on another client — for
//  everyone signed in to the *same* server.
//
//  How it goes. The server keeps groups; a device creates one or joins one
//  (`/SyncPlay/New`, `/SyncPlay/Join`) and from then on listens on the
//  server's web socket. What the group watches is a queue on the server:
//  putting a title on is `/SyncPlay/SetNewQueue`, and every device hears the
//  queue change and opens the title for itself, paused. Each says when it is
//  ready (`/SyncPlay/Ready`); once all are, the server sends everyone the same
//  order — unpause, from this position, at this moment by my clock. A pause, a
//  play or a jump on any device is a request to the server, which answers
//  everyone the same way. A device that runs dry says so (`/SyncPlay/Buffering`)
//  and the rest wait for it.
//
//  The server's clock is not this device's, so it is measured (`SyncPlayClock`,
//  a few round trips to `/GetUtcTime`) and every "at this moment" is turned
//  into local time before it is acted on.
//
//  The player's side is `GroupTransport` / `PlayerModel.follow` — see
//  Player/PlayerModel+Group.swift. Wire formats and the clock arithmetic are
//  in SyncPlayWire.swift.
//
//  Leaving: "Leave SyncPlay", closing the player, or the socket staying down.
//  A group with nobody in it is removed by the server.

import Foundation
import Observation
import os

@MainActor
@Observable
final class SyncPlayCoordinator: GroupTransport {
    static let shared = SyncPlayCoordinator()

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "syncplay")

    /// The group this device is in, while it is.
    private(set) var group: SyncPlayGroup?
    /// "Which group?", while it is asked: the server's groups, which may be none.
    var picker: [SyncPlayGroup]?
    /// A request is on its way: the rows say so rather than take a second tap.
    private(set) var isBusy = false

    var isActive: Bool { group != nil }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var socketTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var clock = SyncPlayClock()
    @ObservationIgnored private var queue: SyncPlayQueue?
    /// Server time this device joined at: orders from before it are not for it.
    @ObservationIgnored private var joinedAt: Date?
    @ObservationIgnored private var lastCommand: SyncPlayCommand?
    /// The title this device last opened for the group, or put on for it, so
    /// neither is done twice.
    @ObservationIgnored private var openedItemId: String?
    /// The group is owed a "ready" once the stream has a frame up.
    @ObservationIgnored private var owesReady = false
    @ObservationIgnored private var readyTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var reportedStall = false
    @ObservationIgnored private var offerTask: Task<Void, Never>?
    @ObservationIgnored private var reconnects = 0
    /// The server has said something on the socket: it is connected.
    @ObservationIgnored private var socketIsUp = false

    private var client: JellyfinClient { .shared }
    private var player: PlayerModel { .shared }

    private init() {}

    // MARK: - Groups

    /// "Watch Together with SyncPlay": ask the server what groups there are,
    /// and ask the viewer which, or a new one.
    func choose() async {
        guard !isBusy else { return }
        guard !SharePlayCoordinator.shared.isActive else {
            AppModel.shared.toast("Leave SharePlay first: one or the other keeps everyone together.", tone: .error)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            picker = try await client.syncPlayGroups()
        } catch {
            Self.log.error("couldn't list groups: \(error.localizedDescription, privacy: .public)")
            AppModel.shared.toast(Self.refusal(error), tone: .error)
        }
    }

    /// A new group, named for whoever made it, with whatever is playing put on.
    func create() async {
        let name = Self.groupName(for: client.session?.userName)
        await enter(putOnWhatIsPlaying: true) {
            try await self.client.syncPlayCreate(name: name) ?? SyncPlayGroup(GroupId: "", GroupName: name)
        }
    }

    /// Join a group. What it is watching opens here; if it is watching
    /// nothing, what is playing here is put on.
    func join(_ group: SyncPlayGroup) async {
        await enter(putOnWhatIsPlaying: false) {
            try await self.client.syncPlayJoin(groupId: group.GroupId)
            return group
        }
    }

    private func enter(putOnWhatIsPlaying: Bool, _ request: @escaping () async throws -> SyncPlayGroup) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if isActive { await leave() }
        guard await player.streamForGroup() else { return }
        do {
            try await connect()
            // Orders older than this are some other sitting's.
            joinedAt = clock.server(Date()).addingTimeInterval(-1)
            let entered = try await request()
            adopt(entered)
            Self.log.notice("in group \(entered.GroupName, privacy: .public)")
            AppModel.shared.toast("You\u{2019}re in \u{201C}\(entered.GroupName)\u{201D}")
            offerWhatIsPlaying(after: putOnWhatIsPlaying ? 0 : 1.5)
        } catch {
            Self.log.error("couldn't enter a group: \(error.localizedDescription, privacy: .public)")
            tearDown()
            AppModel.shared.toast(Self.refusal(error), tone: .error)
        }
    }

    private func adopt(_ entered: SyncPlayGroup) {
        // The joined update can beat the request's own answer, and carries
        // the id a created group's answer may not.
        if let group, !group.GroupId.isEmpty, entered.GroupId.isEmpty { return }
        group = entered
        player.joinGroup(self)
    }

    /// What is playing here becomes what the group watches — at once for a
    /// group just made, and for one joined only if a moment later it turns
    /// out to be watching nothing.
    private func offerWhatIsPlaying(after delay: Double) {
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled, self.isActive, self.queue?.current == nil,
                  self.player.isActive, !self.player.isLive, !self.player.isExternal, !self.player.isLocal,
                  let item = self.player.item
            else { return }
            await self.putOn(item, at: self.player.position)
        }
    }

    /// This device leaves; everyone else carries on.
    func leave() async {
        guard isActive else { return }
        Self.log.notice("leaving the group")
        tearDown()
        try? await client.syncPlayPost("/SyncPlay/Leave")
    }

    /// The player was closed by hand. Closing it is leaving: a device in the
    /// group with nothing open would be waited on by everyone else.
    func playerClosed() {
        guard isActive else { return }
        Task { await leave() }
    }

    private func tearDown() {
        for task in socketTasks { task.cancel() }
        socketTasks = []
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        readyTask?.cancel(); readyTask = nil
        stallTask?.cancel(); stallTask = nil
        offerTask?.cancel(); offerTask = nil
        group = nil
        queue = nil
        joinedAt = nil
        lastCommand = nil
        openedItemId = nil
        owesReady = false
        reportedStall = false
        reconnects = 0
        player.leaveGroup(self)
    }

    // MARK: - What the group watches

    /// Something started playing here. In a group, it becomes what the group
    /// watches — unless it is what the group just asked this device to open,
    /// or already has on.
    func playerStarted(_ item: BaseItem, at seconds: Double) {
        guard isActive, !item.isAudio, item.kind != "TvChannel", item.kind != "Program" else { return }
        if SyncPlayWire.sameId(openedItemId, item.Id) { return }
        if SyncPlayWire.sameId(queue?.current?.itemId, item.Id) {
            openedItemId = item.Id
            return
        }
        Task { await putOn(item, at: seconds) }
    }

    private func putOn(_ item: BaseItem, at seconds: Double) async {
        openedItemId = item.Id
        // Nothing the last title was told holds for this one.
        player.groupOrder = GroupOrder(position: seconds, playing: false)
        Self.log.notice("putting \(item.Id, privacy: .public) on for the group at \(seconds, format: .fixed(precision: 1))")
        do {
            try await client.syncPlayPost("/SyncPlay/SetNewQueue", body: SyncPlayBody.Queue(
                PlayingQueue: [item.Id], PlayingItemPosition: 0, StartPositionTicks: SyncPlayWire.ticks(seconds)))
        } catch {
            Self.log.error("couldn't put it on: \(error.localizedDescription, privacy: .public)")
            AppModel.shared.toast("Couldn\u{2019}t put this on for the SyncPlay group.", tone: .error)
        }
    }

    private func heard(_ update: SyncPlayQueue) {
        if let queue, update.lastUpdate < queue.lastUpdate { return }
        let wasOn = queue?.current
        queue = update
        guard let current = update.current else { return }
        let start = update.position(serverNow: clock.server(Date()))
        if player.isActive, SyncPlayWire.sameId(player.item?.Id, current.itemId) {
            openedItemId = current.itemId
            // The queue changed around the entry that is on — something
            // added after it, the repeat mode — and the entry didn't.
            if wasOn == current, Self.leavesTheEntryAlone.contains(update.reason) { return }
            // Already on here: hold where the group starts from, and say so.
            player.follow(GroupOrder(position: start, playing: false))
            sayReadyOnceSettled()
            return
        }
        open(current, at: start)
    }

    /// Open what the group is watching: from this account, on this device,
    /// paused at the group's spot until the server says play.
    private func open(_ entry: SyncPlayQueue.Entry, at start: Double) {
        openedItemId = entry.itemId
        player.groupOrder = GroupOrder(position: start, playing: false)
        Self.log.notice("opening the group's title \(entry.itemId, privacy: .public) at \(start, format: .fixed(precision: 1))")
        Task {
            guard (try? await client.item(entry.itemId)) != nil else {
                Self.log.notice("the group's title isn't reachable here: leaving")
                AppModel.shared.toast(
                    "Couldn\u{2019}t open what the SyncPlay group is watching: your account can\u{2019}t see it. You\u{2019}ve left the group.",
                    tone: .error)
                await leave()
                return
            }
            guard isActive, queue?.current == entry else { return }
            sayReadyOnceSettled()
            await AppModel.shared.play(itemId: entry.itemId, at: start, resume: false)
        }
    }

    // MARK: - Orders

    private func heard(_ command: SyncPlayCommand) {
        guard isActive else { return }
        if let joinedAt, command.emittedAt < joinedAt { return }
        if command == lastCommand { return }
        // An order is for the entry it names. A group with nothing on sends a
        // Stop for no entry at all as it is joined; that one closes nothing.
        guard let current = queue?.current, SyncPlayWire.sameId(command.playlistItemId, current.playlistItemId) else {
            Self.log.info("order \(command.kind.rawValue, privacy: .public) for another entry: ignored")
            return
        }
        lastCommand = command
        Self.log.info("order \(command.kind.rawValue, privacy: .public) at \(command.seconds ?? -1, format: .fixed(precision: 2))")
        switch command.kind {
        case .unpause:
            owesReady = false
            readyTask?.cancel()
            player.follow(GroupOrder(position: command.seconds, playing: true, at: clock.local(command.when)))
        case .pause:
            player.follow(GroupOrder(position: command.seconds, playing: false))
        case .seek:
            // Everyone jumps, holds, and says when they have landed.
            player.follow(GroupOrder(position: command.seconds, playing: false))
            sayReadyOnceSettled()
        case .stop:
            // The title is over for the group. The group itself carries on,
            // so this is not the viewer closing the player.
            guard player.isActive else { return }
            Task { await player.finish(userRequested: false, reason: "SyncPlay stop") }
        }
    }

    // MARK: - GroupTransport

    var holdsNewStreams: Bool { isActive }

    func viewerPaused() {
        // At once here, and for everyone as soon as the server says so.
        player.pauseNow()
        send("/SyncPlay/Pause") { }
    }

    func viewerResumed() {
        send("/SyncPlay/Unpause") { [player] in player.resumeNow() }
    }

    func viewerSeeked(to seconds: Double) {
        send("/SyncPlay/Seek", body: SyncPlayBody.Seek(PositionTicks: SyncPlayWire.ticks(seconds))) { [weak self] in
            guard let self else { return }
            self.player.follow(GroupOrder(position: seconds, playing: !self.player.isPaused))
        }
    }

    /// Ask the server. If it can't be asked, the viewer still gets what they
    /// pressed, on this device at least.
    private func send(_ path: String, body: (any Encodable & Sendable)? = nil, otherwise: @escaping @MainActor () -> Void) {
        Task {
            do {
                try await client.syncPlayPost(path, body: body)
            } catch {
                Self.log.error("\(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                otherwise()
            }
        }
    }

    func streamSettled() {
        if owesReady { sayReady() }
    }

    func streamStalled(_ stalled: Bool) {
        guard isActive else { return }
        stallTask?.cancel(); stallTask = nil
        if !stalled {
            if reportedStall { sayReady() }
            return
        }
        // Not while paused, held or landing a jump: none of those is running dry.
        guard !player.isPaused, !owesReady else { return }
        stallTask = Task { [weak self] in
            // A blip isn't worth stopping everyone for.
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, self.isActive, self.player.isBuffering, !self.player.isPaused else { return }
            self.reportedStall = true
            Self.log.notice("ran dry: asking the group to wait")
            try? await self.client.syncPlayPost("/SyncPlay/Buffering", body: self.status(playing: false))
            // The server pauses everyone, this device included, and a paused
            // engine may never say it has data again: say ready anyway.
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self.reportedStall else { return }
            self.sayReady()
        }
    }

    // MARK: - Ready

    /// Say "ready" when the right title has a frame up and no jump is still
    /// landing — at the first frame if that comes (`streamSettled`), and by
    /// looking, for the case where there was nothing to wait for.
    private func sayReadyOnceSettled() {
        owesReady = true
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.owesReady else { return }
                if self.isSettled { break }
            }
            guard let self, !Task.isCancelled, self.owesReady else { return }
            self.sayReady()
        }
    }

    private var isSettled: Bool {
        guard let current = queue?.current else { return false }
        return player.isSettledForGroup && SyncPlayWire.sameId(player.item?.Id, current.itemId)
    }

    private func sayReady() {
        guard isActive, queue?.current != nil else { return }
        owesReady = false
        reportedStall = false
        readyTask?.cancel(); readyTask = nil
        let body = status(playing: !player.isPaused)
        Self.log.info("ready at \(Double(body.PositionTicks) / 10_000_000, format: .fixed(precision: 2))")
        Task { try? await client.syncPlayPost("/SyncPlay/Ready", body: body) }
    }

    private func status(playing: Bool) -> SyncPlayBody.Status {
        SyncPlayBody.Status(
            When: SyncPlayWire.string(clock.server(Date())),
            PositionTicks: SyncPlayWire.ticks(player.engine?.clock ?? player.position),
            IsPlaying: playing,
            PlaylistItemId: queue?.current?.playlistItemId ?? "")
    }

    // MARK: - The socket

    private func connect() async throws {
        guard socket == nil else { return }
        guard let session = client.session,
              let url = SyncPlayWire.socketURL(server: session.server, deviceId: session.deviceId)
        else { throw APIError.notConfigured }
        var request = URLRequest(url: url)
        for (name, value) in client.authHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        socket = task
        socketIsUp = false
        socketTasks.append(Task { [weak self] in await self?.listen(to: task) })
        // The server speaks first (its keep-alive) once it has the socket,
        // and an update sent before that would go nowhere: wait for it, but
        // not for ever — a server that says nothing may still be listening.
        for _ in 0..<50 where !socketIsUp {
            try await Task.sleep(for: .milliseconds(100))
            guard socket === task else { throw APIError.message("SyncPlay\u{2019}s connection closed") }
        }
        if !socketIsUp { Self.log.notice("the socket said nothing in 5 s; going on") }
        await measureClock()
        socketTasks.append(Task { [weak self] in
            // Twice more close together, for a better least-delay sample,
            // then now and again for as long as the group lasts.
            for wait in [0.5, 0.5] + Array(repeating: 60.0, count: 100_000) {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                await self.measureClock()
            }
        })
    }

    private func listen(to task: URLSessionWebSocketTask) async {
        var keepAlive: Task<Void, Never>?
        defer { keepAlive?.cancel() }
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard !Task.isCancelled, socket === task else { return }
                Self.log.error("socket closed: \(error.localizedDescription, privacy: .public)")
                // Before a group, `connect` is still waiting and says so itself.
                guard isActive else { socket = nil; return }
                await socketLost()
                return
            }
            socketIsUp = true
            guard case .string(let text) = message, let event = SyncPlayWire.event(from: text) else { continue }
            reconnects = 0
            switch event {
            case .keepAlive(let seconds):
                keepAlive?.cancel()
                keepAlive = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(max(5, seconds / 2)))
                        guard !Task.isCancelled else { return }
                        try? await task.send(.string(#"{"MessageType":"KeepAlive"}"#))
                    }
                }
            case .joined(let entered):
                group = entered
                player.joinGroup(self)
            case .left:
                guard isActive else { break }
                tearDown()
                AppModel.shared.toast("You\u{2019}ve left the SyncPlay group")
                return
            case .refused(let why):
                Self.log.notice("the server said \(why, privacy: .public)")
                guard isActive else { break }
                tearDown()
                AppModel.shared.toast(Self.refusal(why), tone: .error)
                return
            case .userJoined(let name):
                // Read first, then written: both at once on one observed
                // property is an exclusivity trap.
                let people = (group?.people ?? []).filter { $0 != name } + [name]
                group?.Participants = people
                if name != client.session?.userName { AppModel.shared.toast("\(name) joined SyncPlay") }
            case .userLeft(let name):
                let people = (group?.people ?? []).filter { $0 != name }
                group?.Participants = people
                AppModel.shared.toast("\(name) left SyncPlay")
            case .state(let state):
                group?.State = state
                // The server is waiting to hear from everyone — after an
                // unpause, a jump, somebody joining. Say so, unless this is
                // the device it is waiting on.
                if state == "Waiting", !reportedStall, queue?.current != nil { sayReadyOnceSettled() }
            case .queue(let update):
                heard(update)
            case .command(let command):
                heard(command)
            }
        }
    }

    /// The socket went: the app was in the background, the network changed.
    /// The server still has this device in the group, so a new socket and a
    /// join of the same group picks it up where it was. Three goes.
    private func socketLost() async {
        guard let group, reconnects < 3 else {
            if isActive {
                tearDown()
                AppModel.shared.toast("Lost the connection to SyncPlay. You\u{2019}ve left the group.", tone: .error)
            }
            return
        }
        reconnects += 1
        let attempt = reconnects
        for task in socketTasks { task.cancel() }
        socketTasks = []
        socket = nil
        try? await Task.sleep(for: .seconds(Double(attempt)))
        guard isActive else { return }
        do {
            try await connect()
            try await client.syncPlayJoin(groupId: group.GroupId)
            Self.log.notice("socket back after \(attempt) tries")
        } catch {
            await socketLost()
        }
    }

    private func measureClock() async {
        let sent = Date()
        guard let times = try? await client.syncPlayServerTime() else { return }
        let received = Date()
        guard let arrived = SyncPlayWire.date(times.RequestReceptionTime),
              let left = SyncPlayWire.date(times.ResponseTransmissionTime) else { return }
        clock.add(SyncPlayClock.sample(sent: sent, serverReceived: arrived, serverSent: left, received: received))
        Self.log.info("server clock \(self.clock.offset * 1000, format: .fixed(precision: 0)) ms from ours, \(self.clock.ping * 1000, format: .fixed(precision: 0)) ms away")
        if isActive {
            try? await client.syncPlayPost("/SyncPlay/Ping", body: SyncPlayBody.Ping(Ping: Int64(clock.ping * 1000)))
        }
    }

    /// Queue updates that are about the list, not about what is on.
    nonisolated static let leavesTheEntryAlone: Set<String> = [
        "RemoveItems", "MoveItem", "Queue", "QueueNext", "RepeatMode", "ShuffleMode",
    ]

    // MARK: - Words

    /// "Alex’s group", or "Watch Together" for nobody in particular.
    nonisolated static func groupName(for user: String?) -> String {
        guard let user, !user.isEmpty else { return "Watch Together" }
        return "\(user)\u{2019}s group"
    }

    /// Why the server said no, in words.
    nonisolated static func refusal(_ error: any Error) -> String {
        if case APIError.server(let status, _) = error, status == 403 {
            return "Your account isn\u{2019}t allowed to use SyncPlay on this server. Whoever runs it can turn that on."
        }
        return "Couldn\u{2019}t reach SyncPlay on your server."
    }

    nonisolated static func refusal(_ kind: String) -> String {
        switch kind {
        case "LibraryAccessDenied":
            "Your account can\u{2019}t see what that SyncPlay group is watching."
        case "GroupDoesNotExist":
            "That SyncPlay group has ended."
        default:
            "You\u{2019}re no longer in the SyncPlay group."
        }
    }
}

// MARK: - Requests

enum SyncPlayBody {
    struct NewGroup: Encodable, Sendable { var GroupName: String }
    struct Join: Encodable, Sendable { var GroupId: String }
    struct Queue: Encodable, Sendable {
        var PlayingQueue: [String]
        var PlayingItemPosition: Int
        var StartPositionTicks: Int64
    }
    struct Seek: Encodable, Sendable { var PositionTicks: Int64 }
    struct Ping: Encodable, Sendable { var Ping: Int64 }
    /// `/SyncPlay/Ready` and `/SyncPlay/Buffering`: where this device is.
    struct Status: Encodable, Sendable {
        var When: String
        var PositionTicks: Int64
        var IsPlaying: Bool
        var PlaylistItemId: String
    }
    struct ServerTime: Decodable, Sendable {
        var RequestReceptionTime: String
        var ResponseTransmissionTime: String
    }
}

extension JellyfinClient {
    func syncPlayGroups() async throws -> [SyncPlayGroup] {
        try await get([SyncPlayGroup].self, "/SyncPlay/List", countsForOffline: false)
    }

    /// The new group, where the server says what it made (older ones answer
    /// with nothing and say it over the socket instead).
    func syncPlayCreate(name: String) async throws -> SyncPlayGroup? {
        let data = try await request(
            "/SyncPlay/New", method: "POST", body: SyncPlayBody.NewGroup(GroupName: name), countsForOffline: false)
        return try? JSONDecoder().decode(SyncPlayGroup.self, from: data)
    }

    func syncPlayJoin(groupId: String) async throws {
        try await syncPlayPost("/SyncPlay/Join", body: SyncPlayBody.Join(GroupId: groupId))
    }

    func syncPlayPost(_ path: String, body: (any Encodable & Sendable)? = nil) async throws {
        try await request(path, method: "POST", body: body, countsForOffline: false)
    }

    func syncPlayServerTime() async throws -> SyncPlayBody.ServerTime {
        try await get(SyncPlayBody.ServerTime.self, "/GetUtcTime", countsForOffline: false)
    }
}
