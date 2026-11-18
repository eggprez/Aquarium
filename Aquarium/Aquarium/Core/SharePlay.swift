//  SharePlay: the same film, on everyone's screen at once, over FaceTime.
//
//  A `GroupActivity` names the title; `AVPlayerPlaybackCoordinator` does the
//  rest. Once the player's coordinator is joined to the session, a pause on
//  one device is a pause on all of them, a seek is a seek everywhere, and a
//  phone whose stream falls behind holds the others until it has caught up.
//  Each device opens its own stream of its own server — nothing is sent over
//  the call but the item's id and the transport — so everyone on the call
//  needs an account that can see the title.
//
//  Starting one: "Watch Together" in the player's menu, which offers the
//  title to the FaceTime call in progress. Joining: the system hands the
//  activity to every participant's app through `sessions()`, and the app
//  opens the title and joins the coordination. While a session is on, the
//  next thing anyone plays becomes the session's activity, so a series
//  carries on together — see `playerStarted`.
//
//  Whose progress: each device tells the others its account's saved spot in
//  the title (`SharedProgress`, over the session's messenger). The person who
//  put the title on is asked once which spot to start from — theirs, a
//  friend's, or the beginning — and the seek that answer makes is a seek
//  everywhere. A device that joins opens the title at the start and lets the
//  coordinator place it, rather than seeking to its own account's spot, which
//  the coordinator would have sent to everyone.
//
//  iPhone, iPad and Mac. Not Apple TV, whose player is mpv and has no
//  coordinator to join; the activity would arrive there with nothing to
//  hand it to.

#if !os(tvOS)

import AVFoundation
import Combine
import Foundation
import GroupActivities
import ImageIO
import Observation
import os
#if os(iOS)
import UIKit
#endif

struct WatchTogetherActivity: GroupActivity, Codable, Sendable {
    static let activityIdentifier = "scottai.FellyJin.watch-together"

    var itemId: String
    var title: String
    var subtitle: String?
    /// The poster FaceTime shows on the invitation. Only the device that
    /// offers the title has it: it isn't sent (see `CodingKeys`), since the
    /// system reads the metadata where the activity is offered.
    var poster: Data?

    private enum CodingKeys: String, CodingKey { case itemId, title, subtitle }

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = title
        meta.subtitle = subtitle
        meta.type = .watchTogether
        // No `fallbackURL`: it is opened in Safari for someone without the
        // app, and an `aquarium://` address does nothing there. Without one,
        // the system offers the app from the App Store instead.
        if let poster, let source = CGImageSourceCreateWithData(poster as CFData, nil) {
            meta.previewImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return meta
    }

    /// The Jellyfin item id in a stream address: `/Videos/<id>/stream.mp4`,
    /// `/videos/<id>/master.m3u8`, under any base path. What the playback
    /// coordinator matches streams by, read from the address alone so it
    /// can be answered on any thread.
    static func itemId(in url: URL?) -> String? {
        guard let parts = url?.pathComponents else { return nil }
        for (index, part) in parts.enumerated()
        where part.caseInsensitiveCompare("Videos") == .orderedSame && index + 1 < parts.count {
            return parts[index + 1].lowercased().replacingOccurrences(of: "-", with: "")
        }
        return nil
    }
}

/// One person's saved spot in a title, sent to everyone else on the call.
/// Each device reads its own account's spot from its own server, so two
/// accounts on one server, or two servers, each say their own.
struct SharedProgress: Codable, Sendable, Equatable {
    var itemId: String
    /// The Jellyfin user name, which is what the question shows.
    var name: String
    /// Seconds in. 0 for not started, and for finished (watching again
    /// starts at the beginning, as everywhere else in the app).
    var seconds: Double

    /// This account's spot from what the server says of the title.
    static func saved(itemId: String, name: String, positionTicks: Int64, runTimeTicks: Int64?) -> SharedProgress {
        let total = runTimeTicks ?? 0
        let finished = VideoProgress.isFinished(positionTicks: positionTicks, runTimeTicks: total)
        let seconds = finished || positionTicks <= 0 ? 0 : Double(positionTicks) / 10_000_000
        return SharedProgress(itemId: itemId, name: name, seconds: seconds)
    }
}

/// One answer to "start from whose progress?".
struct ProgressChoice: Identifiable, Equatable, Sendable {
    /// Stable for tests: "beginning", or the person's name lowercased.
    var id: String
    var title: String
    var seconds: Double

    /// Less than this in is the beginning, near enough: not worth a row.
    static let minimumSpot: Double = 30

    /// The rows for `itemId`: this device's person first, then everyone
    /// else by name, each once, each with a spot worth starting from; then
    /// the beginning. Empty when nobody has a spot — there is nothing to ask.
    static func options(_ reports: [SharedProgress], itemId: String, me: String?) -> [ProgressChoice] {
        var seen = Set<String>()
        let mine = me?.lowercased()
        let people = reports
            .filter { $0.itemId == itemId && $0.seconds >= minimumSpot }
            .sorted { a, b in
                let am = a.name.lowercased() == mine, bm = b.name.lowercased() == mine
                if am != bm { return am }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            .filter { seen.insert($0.name.lowercased()).inserted }
        guard !people.isEmpty else { return [] }
        let rows = people.map { report in
            let who = report.name.lowercased() == mine ? "\(report.name) (you)" : report.name
            return ProgressChoice(id: report.name.lowercased(), title: "\(who) · \(Format.clock(report.seconds))", seconds: report.seconds)
        }
        return rows + [ProgressChoice(id: "beginning", title: "From the Beginning", seconds: 0)]
    }
}

@MainActor
@Observable
final class SharePlayCoordinator: NSObject {
    static let shared = SharePlayCoordinator()

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "shareplay")

    /// The session this device is part of, while it is.
    private(set) var session: GroupSession<WatchTogetherActivity>?
    /// Whether the person is on a FaceTime call this could join. Read from
    /// the activity's `prepareForActivation` rather than guessed.
    private(set) var isEligible = false

    var isActive: Bool { session != nil }

    @ObservationIgnored private var sessionsTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    /// The item this device last opened on the session's behalf, so an
    /// activity change this device caused isn't acted on twice.
    @ObservationIgnored private var openedItemId: String?

    /// Everyone's saved spot in what the session is watching, this device's
    /// included, by participant.
    private(set) var reports: [UUID: SharedProgress] = [:]
    /// "Start from whose progress?", while it is asked.
    var progressQuestion: [ProgressChoice]?
    /// Whether this device put the current title on: the one asked.
    @ObservationIgnored private var putItOn = false
    /// The title the question has been asked about, so it is asked once.
    @ObservationIgnored private var askedItemId: String?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var messenger: GroupSessionMessenger?
    /// This account's spot, read once per title per session: once the
    /// title plays here, the server's spot follows the group's.
    @ObservationIgnored private var myReport: SharedProgress?

    /// The rows the question would offer now, for the "…" menu's way back to it.
    var progressChoices: [ProgressChoice] {
        guard let itemId = session?.activity.itemId else { return [] }
        return ProgressChoice.options(Array(reports.values), itemId: itemId, me: Self.myName)
    }

    private static var myName: String? { Preferences.shared.session?.userName }

    @ObservationIgnored private var transportObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
    }

    /// Once, at launch. The system delivers an activity accepted from a
    /// FaceTime call here, whether the app was running or not.
    func start() {
        guard !started else { return }
        started = true
        sessionsTask = Task { [weak self] in
            for await session in WatchTogetherActivity.sessions() {
                self?.adopt(session)
            }
        }
        observeEligibility()
    }

    /// Whether "Watch Together" is worth offering: a call is on and the
    /// system would take an activity.
    private func observeEligibility() {
        Task { [weak self] in
            for await state in GroupStateObserver().$isEligibleForGroupSession.values {
                self?.isEligible = state
            }
        }
    }

    // MARK: - Starting one

    /// Offer the title to the call in progress. With a session already on,
    /// the title becomes its activity instead, and everyone follows.
    func share(_ item: BaseItem) async {
        var activity = WatchTogetherActivity(
            itemId: item.Id,
            title: PlayerModel.displayTitle(item),
            subtitle: item.isEpisode ? item.SeriesName : nil
        )
        if let session {
            openedItemId = item.Id
            putItOn = true
            session.activity = activity
            return
        }
        activity.poster = await Self.poster(for: item)
        // No call on: nothing to activate into. On iPhone and iPad the
        // system's sheet can start one with the title already offered.
        guard isEligible else {
            #if os(iOS)
            openedItemId = item.Id
            putItOn = true
            await invite(activity)
            #else
            AppModel.shared.toast("Start a FaceTime call first, then choose Watch Together", tone: .error)
            #endif
            return
        }
        let outcome = await activity.prepareForActivation()
        Self.log.info("Watch Together asked; the system answered \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .activationPreferred:
            openedItemId = item.Id
            putItOn = true
            do {
                _ = try await activity.activate()
            } catch {
                Self.log.error("activate failed: \(error.localizedDescription, privacy: .public)")
                AppModel.shared.toast("Couldn't start SharePlay: \(error.localizedDescription)", tone: .error)
            }
        case .activationDisabled:
            // On a call, this is "Start Only for Me" (or SharePlay turned off
            // for the app in Settings): the title carries on here alone.
            Self.log.info("Watch Together declined on the call: playing here only")
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    /// This device leaves; everyone else carries on.
    func leave() {
        session?.leave()
        clearSession()
    }

    /// Everyone's SharePlay ends, not just this device's.
    func endForEveryone() {
        session?.end()
        clearSession()
    }

    /// The player was closed. Closing it is leaving: otherwise the next
    /// thing played, any time until the call ends, would become everyone's.
    func playerClosed() {
        guard session != nil else { return }
        Self.log.info("player closed: leaving SharePlay")
        leave()
    }

    #if os(iOS)
    /// No call on: Apple's SharePlay sheet, which picks people and starts the
    /// FaceTime call with the title already offered. The session then
    /// arrives like any other, through `sessions()`. Closed without that (a
    /// person who changed their mind, or a device with no FaceTime, such as
    /// a simulator, where it closes at once), it is said rather than left to
    /// look like nothing happened.
    private func invite(_ activity: WatchTogetherActivity) async {
        guard let controller = try? GroupActivitySharingController(activity),
              let top = Self.frontmostController()
        else {
            AppModel.shared.toast(Self.notStarted, tone: .error)
            return
        }
        top.present(controller, animated: true)
        let result = await controller.result
        Self.log.info("SharePlay sheet closed: \(String(describing: result), privacy: .public)")
        if result != .success {
            AppModel.shared.toast(Self.notStarted, tone: .error)
        }
    }

    private static func frontmostController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif

    /// Watch Together that didn't get as far as a session.
    nonisolated static let notStarted = "SharePlay didn\u{2019}t start. Pick someone in the SharePlay sheet, or start a FaceTime call first."

    /// The poster for the invitation, small and quickly or not at all.
    private static func poster(for item: BaseItem) async -> Data? {
        guard let url = Artwork.url(item, type: "Primary", width: 300) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Ask again from the "…" menu: someone joined late, or the first answer
    /// was "keep watching here".
    func askAgain() {
        let rows = progressChoices
        guard !rows.isEmpty else { return }
        progressQuestion = rows
    }

    /// Start everyone from that spot. On a coordinated player a seek is a
    /// seek on every device.
    func choose(_ choice: ProgressChoice) {
        progressQuestion = nil
        Self.log.info("starting from \(choice.id, privacy: .public) at \(choice.seconds, privacy: .public)s")
        PlayerModel.shared.seek(to: choice.seconds)
    }

    /// Something started playing here. On a session, it becomes what the
    /// session is watching — unless it is the very thing the session just
    /// asked this device to open.
    func playerStarted(_ item: BaseItem) {
        #if DEBUG
        if session == nil, TestRuntime.isUITest, let fake = TestLaunch.env(TestLaunch.sharePlayProgressEnv) {
            askForTests(item, fake)
            return
        }
        #endif
        guard let session else { return }
        if openedItemId == item.Id { return }
        openedItemId = item.Id
        putItOn = true
        session.activity = WatchTogetherActivity(
            itemId: item.Id,
            title: PlayerModel.displayTitle(item),
            subtitle: item.isEpisode ? item.SeriesName : nil
        )
    }

    // MARK: - Being in one

    private func adopt(_ session: GroupSession<WatchTogetherActivity>) {
        if let old = self.session, old.id != session.id {
            old.leave()
        }
        clearSession()
        self.session = session
        Self.log.notice("joining session for \(session.activity.itemId, privacy: .public)")

        // The player's transport follows the group from here on.
        // The coordinator lives on AVPlayer, which is the Apple engine's; a
        // Watch Together session forces that engine for its length (see the
        // plan's "SharePlay stays an AVPlayer-only feature"), so a stream on
        // mpv is handed over first.
        let player = PlayerModel.shared
        // Only when what is on mpv is the session's title: anything else is
        // about to be replaced by `follow`, and reopening it first would
        // race that.
        if player.isActive, player.engine?.kind == .mpv, player.item?.Id == session.activity.itemId {
            Task {
                await player.prepareForSharePlay()
                guard self.session?.id == session.id else { return }
                let avPlayer = player.appleEngine.player
                avPlayer.playbackCoordinator.delegate = self
                avPlayer.playbackCoordinator.coordinateWithSession(session)
            }
        } else {
            let avPlayer = player.appleEngine.player
            avPlayer.playbackCoordinator.delegate = self
            avPlayer.playbackCoordinator.coordinateWithSession(session)
        }

        sessionTasks.append(Task { [weak self] in
            for await state in session.$state.values {
                if case .invalidated = state {
                    self?.clearSession()
                    break
                }
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await activity in session.$activity.values {
                await self?.follow(activity)
                await self?.sendMyProgress(for: activity.itemId)
            }
        })

        observeTransport(of: player.appleEngine.player)

        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger
        sessionTasks.append(Task { [weak self] in
            for await (report, context) in messenger.messages(of: SharedProgress.self) {
                self?.heard(report, from: context.source.id)
            }
        })
        // Someone new on the call hasn't heard anyone's spot: say it again.
        sessionTasks.append(Task { [weak self] in
            var known = Set<UUID>()
            for await participants in session.$activeParticipants.values {
                let ids = Set(participants.map(\.id))
                defer { known = ids }
                guard !ids.subtracting(known).isEmpty, let itemId = self?.session?.activity.itemId else { continue }
                await self?.sendMyProgress(for: itemId)
            }
        })
        session.join()
    }

    /// Open what the session is watching, unless this device already is.
    private func follow(_ activity: WatchTogetherActivity) async {
        guard openedItemId != activity.itemId else { return }
        openedItemId = activity.itemId
        // Someone else put this on: they are the one asked.
        putItOn = false
        let player = PlayerModel.shared
        if player.isActive, player.item?.Id == activity.itemId { return }
        // Each device opens the title from its own server with its own
        // account: one that can't find it would sit in the session showing
        // nothing. Say so, and leave.
        guard (try? await JellyfinClient.shared.item(activity.itemId)) != nil else {
            Self.log.notice("session's title \(activity.itemId, privacy: .public) isn't reachable here: leaving")
            AppModel.shared.toast(Self.unavailable(activity.title), tone: .error)
            leave()
            return
        }
        // At the start, not at this account's own spot: the coordinator
        // moves this player to where the group is, and a seek of its own
        // here would have moved the whole group instead. Where to start is
        // the question the one who put it on is asked.
        await AppModel.shared.play(itemId: activity.itemId, resume: false)
    }

    /// What a joiner is told when their server or account can't open the
    /// title everyone else is watching.
    nonisolated static func unavailable(_ title: String) -> String {
        "Couldn\u{2019}t open \u{201C}\(title)\u{201D} for SharePlay. It isn\u{2019}t on your server, or your account can\u{2019}t see it. You\u{2019}ve left the session."
    }

    // MARK: - Who did that

    /// Someone else paused, played or jumped: say who, since every device
    /// does it at once and the player's own controls don't.
    private func observeTransport(of avPlayer: AVPlayer) {
        let center = NotificationCenter.default
        transportObservers.append(center.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: avPlayer, queue: .main
        ) { [weak self] note in
            guard let who = note.userInfo?[AVPlayer.rateDidChangeOriginatingParticipantKey] as? AVCoordinatedPlaybackParticipant else { return }
            let rate = avPlayer.rate
            let id = who.identifier
            MainActor.assumeIsolated { self?.announce(Self.notice(name: self?.name(of: id), paused: rate == 0)) }
        })
        transportObservers.append(center.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem, item === avPlayer.currentItem,
                  let who = note.userInfo?[AVPlayerItem.timeJumpedOriginatingParticipantKey] as? AVCoordinatedPlaybackParticipant
            else { return }
            let seconds = item.currentTime().seconds
            let id = who.identifier
            MainActor.assumeIsolated { self?.announce(Self.notice(name: self?.name(of: id), jumpedTo: seconds)) }
        })
    }

    private func name(of participant: UUID) -> String? { reports[participant]?.name }

    @ObservationIgnored private var lastNotice: (text: String, at: Date)?

    /// One toast per thing done: a pause can be reported more than once.
    private func announce(_ text: String) {
        if let last = lastNotice, last.text == text, Date().timeIntervalSince(last.at) < 2 { return }
        lastNotice = (text, Date())
        AppModel.shared.toast(text)
    }

    /// "Alex paused", "Someone played", "Alex jumped to 23:10".
    nonisolated static func notice(name: String?, paused: Bool) -> String {
        "\(name ?? "Someone") \(paused ? "paused" : "played")"
    }

    nonisolated static func notice(name: String?, jumpedTo seconds: Double) -> String {
        "\(name ?? "Someone") jumped to \(Format.clock(seconds))"
    }

    // MARK: - Whose progress

    /// Tell everyone this account's spot in the title.
    private func sendMyProgress(for itemId: String) async {
        guard let session, let messenger else { return }
        if myReport?.itemId != itemId {
            guard let name = Self.myName,
                  let item = try? await JellyfinClient.shared.item(itemId)
            else { return }
            myReport = .saved(itemId: itemId, name: name,
                              positionTicks: item.userData.positionTicks, runTimeTicks: item.RunTimeTicks)
        }
        guard let report = myReport, self.session?.id == session.id else { return }
        heard(report, from: session.localParticipant.id)
        do {
            try await messenger.send(report)
        } catch {
            Self.log.error("couldn't send progress: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func heard(_ report: SharedProgress, from participant: UUID) {
        reports[participant] = report
        guard putItOn, let session, report.itemId == session.activity.itemId,
              participant != session.localParticipant.id,
              askedItemId != report.itemId
        else { return }
        // The first friend's spot is in; the rest are a moment behind.
        askedItemId = report.itemId
        askTask?.cancel()
        askTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.session?.activity.itemId == report.itemId else { return }
            let rows = self.progressChoices
            if !rows.isEmpty { self.progressQuestion = rows }
        }
    }

    #if DEBUG
    /// UI tests only: no FaceTime in a simulator, so the question is asked
    /// with made-up friends (`AQUARIUM_TEST_SHAREPLAY_PROGRESS`, "Name:seconds,…")
    /// beside this account's own spot.
    private func askForTests(_ item: BaseItem, _ fake: String) {
        guard askedItemId != item.Id else { return }
        askedItemId = item.Id
        var all = fake.split(separator: ",").compactMap { pair -> SharedProgress? in
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let seconds = Double(parts[1]) else { return nil }
            return SharedProgress(itemId: item.Id, name: String(parts[0]), seconds: seconds)
        }
        if let name = Self.myName {
            all.append(.saved(itemId: item.Id, name: name, positionTicks: item.userData.positionTicks, runTimeTicks: item.RunTimeTicks))
        }
        let rows = ProgressChoice.options(all, itemId: item.Id, me: Self.myName)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !rows.isEmpty { self?.progressQuestion = rows }
        }
    }
    #endif

    private func clearSession() {
        for task in sessionTasks { task.cancel() }
        sessionTasks = []
        session = nil
        openedItemId = nil
        messenger = nil
        reports = [:]
        progressQuestion = nil
        putItOn = false
        askedItemId = nil
        askTask?.cancel()
        askTask = nil
        myReport = nil
        for observer in transportObservers { NotificationCenter.default.removeObserver(observer) }
        transportObservers = []
        lastNotice = nil
    }
}

extension SharePlayCoordinator: AVPlayerPlaybackCoordinatorDelegate {
    /// Each device streams its own copy, by its own URL — a transcode's URL
    /// carries that device's session — so the coordinator has to be told
    /// that two different URLs are the same film. Jellyfin's id is that.
    nonisolated func playbackCoordinator(
        _ coordinator: AVPlayerPlaybackCoordinator, identifierFor playerItem: AVPlayerItem
    ) -> String {
        // From the stream's address alone. This may be called on any thread,
        // and while the player is between items, so nothing on the main
        // actor is read: it once was, through `assumeIsolated`, which traps
        // off the main thread and answered with a per-device URL mid-swap.
        let url = (playerItem.asset as? AVURLAsset)?.url
        return WatchTogetherActivity.itemId(in: url) ?? url?.absoluteString ?? "unknown"
    }
}

#endif
