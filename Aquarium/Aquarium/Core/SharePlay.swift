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
//  iPhone, iPad and Mac. Not Apple TV, whose player is mpv and has no
//  coordinator to join; the activity would arrive there with nothing to
//  hand it to.

#if !os(tvOS)

import AVFoundation
import Combine
import Foundation
import GroupActivities
import Observation
import os

struct WatchTogetherActivity: GroupActivity, Codable, Sendable {
    static let activityIdentifier = "scottai.FellyJin.watch-together"

    var itemId: String
    var title: String
    var subtitle: String?

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = title
        meta.subtitle = subtitle
        meta.type = .watchTogether
        meta.fallbackURL = URL(string: "aquarium://item/\(JellyfinClient.pathId(itemId))")
        return meta
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
    var participantCount: Int { session?.activeParticipants.count ?? 0 }

    @ObservationIgnored private var sessionsTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    /// The item this device last opened on the session's behalf, so an
    /// activity change this device caused isn't acted on twice.
    @ObservationIgnored private var openedItemId: String?

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
        let activity = WatchTogetherActivity(
            itemId: item.Id,
            title: PlayerModel.displayTitle(item),
            subtitle: item.isEpisode ? item.SeriesName : nil
        )
        if let session {
            openedItemId = item.Id
            session.activity = activity
            return
        }
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            openedItemId = item.Id
            do {
                _ = try await activity.activate()
            } catch {
                Self.log.error("activate failed: \(error.localizedDescription, privacy: .public)")
                AppModel.shared.toast("Couldn't start SharePlay: \(error.localizedDescription)", tone: .error)
            }
        case .activationDisabled:
            AppModel.shared.toast("Start a FaceTime call first, then choose Watch Together", tone: .error)
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

    /// Something started playing here. On a session, it becomes what the
    /// session is watching — unless it is the very thing the session just
    /// asked this device to open.
    func playerStarted(_ item: BaseItem) {
        guard let session else { return }
        if openedItemId == item.Id { return }
        openedItemId = item.Id
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
        let player = PlayerModel.shared
        player.player.playbackCoordinator.delegate = self
        player.player.playbackCoordinator.coordinateWithSession(session)

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
            }
        })
        session.join()
    }

    /// Open what the session is watching, unless this device already is.
    private func follow(_ activity: WatchTogetherActivity) async {
        guard openedItemId != activity.itemId else { return }
        openedItemId = activity.itemId
        let player = PlayerModel.shared
        if player.isActive, player.item?.Id == activity.itemId { return }
        await AppModel.shared.play(itemId: activity.itemId)
    }

    private func clearSession() {
        for task in sessionTasks { task.cancel() }
        sessionTasks = []
        session = nil
        openedItemId = nil
    }
}

extension SharePlayCoordinator: AVPlayerPlaybackCoordinatorDelegate {
    /// Each device streams its own copy, by its own URL — a transcode's URL
    /// carries that device's session — so the coordinator has to be told
    /// that two different URLs are the same film. Jellyfin's id is that.
    nonisolated func playbackCoordinator(
        _ coordinator: AVPlayerPlaybackCoordinator, identifierFor playerItem: AVPlayerItem
    ) -> String {
        MainActor.assumeIsolated {
            let player = PlayerModel.shared
            if let id = player.item?.Id, player.player.currentItem === playerItem { return id }
            return (playerItem.asset as? AVURLAsset)?.url.absoluteString ?? UUID().uuidString
        }
    }
}

#endif
