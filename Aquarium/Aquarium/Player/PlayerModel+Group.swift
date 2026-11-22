//  Watching together, from the player's side.
//
//  Two things can put several screens on one clock: a SharePlay session whose
//  player is mpv (the Apple TV — `SharePlayCoordinator`, through an
//  `AVDelegatingPlaybackCoordinator`), and a Jellyfin SyncPlay group
//  (`SyncPlayCoordinator`, through the server). Both work the same way from
//  here: while one is on, a pause, a play or a jump made on this device is
//  *asked of the group* instead of done, and what the group decides comes
//  back as a `GroupOrder` — pause there, play from there at that moment —
//  which is carried out on whichever engine is playing.
//
//  SharePlay on an iPhone, an iPad or a Mac is not one of these: its
//  `AVPlayerPlaybackCoordinator` sits inside AVPlayer and intercepts the
//  transport itself, so the model never knows.
//
//  The seam is `GroupTransport` (what the model tells the group) and
//  `follow(_:)` (what the group tells the model). Nothing here knows which
//  kind of group it is.

import Foundation
import os

/// Whoever owns the transport while people are watching together.
@MainActor
protocol GroupTransport: AnyObject {
    /// A title opened while the group is on opens paused and waits to be
    /// told when to play, so nobody is ahead of anybody.
    var holdsNewStreams: Bool { get }
    /// The viewer pressed pause, play, or jumped. The group answers with an
    /// order; nothing has been done to the stream yet.
    func viewerPaused()
    func viewerResumed()
    func viewerSeeked(to seconds: Double)
    /// The stream has a frame up: opened, or landed after a jump.
    func streamSettled()
    /// The stream ran dry mid-play, or has data again.
    func streamStalled(_ stalled: Bool)
}

/// What the group wants of the transport.
struct GroupOrder: Equatable, Sendable {
    /// Where the playhead belongs, in seconds; nil leaves it where it is.
    var position: Double?
    var playing: Bool
    /// The moment `position` is (or was, or will be) where the playhead
    /// belongs, by this device's clock. Nil is now.
    var at: Date?

    /// Nearer than this to where a paused playhead belongs is near enough:
    /// a seek costs more than it mends.
    static let pausedTolerance = 0.35
    /// The same for one that is playing, where a seek also costs a rebuffer.
    static let playingTolerance = 0.75

    enum Step: Equatable {
        case pause(seekTo: Double?)
        case playNow(seekTo: Double?)
        /// Line up at `seekTo`, then play after `after` seconds.
        case playLater(seekTo: Double?, after: TimeInterval)
    }

    /// Where the playhead belongs at `now`, for an order that is playing.
    func expectedPosition(now: Date, rate: Double) -> Double? {
        guard let position else { return nil }
        guard playing, let at else { return position }
        return position + max(0, now.timeIntervalSince(at)) * rate
    }

    /// What to do about it, given where the engine's clock is.
    func step(now: Date, clock: Double?, rate: Double) -> Step {
        func far(_ target: Double?, _ tolerance: Double) -> Double? {
            guard let target else { return nil }
            guard let clock else { return target }
            return abs(clock - target) > tolerance ? target : nil
        }
        guard playing else { return .pause(seekTo: far(position, Self.pausedTolerance)) }
        if let at, at > now {
            return .playLater(seekTo: far(position, Self.pausedTolerance), after: at.timeIntervalSince(now))
        }
        return .playNow(seekTo: far(expectedPosition(now: now, rate: rate), Self.playingTolerance))
    }
}

extension PlayerModel {
    /// Whether a group has the transport.
    var isInGroup: Bool { group != nil }

    /// Whether the stream has a frame up and nothing the group ordered is
    /// still on its way to one: the moment to tell a group "ready".
    var isSettledForGroup: Bool {
        isActive && !isOpening && !awaitingLoad && !groupOrderAwaitsFrame && !groupSeekLanding
    }

    /// Watching together is done on the server's stream. A download that is
    /// playing is left for it, at the same moment; false when the server
    /// can't be reached, which is said.
    func streamForGroup() async -> Bool {
        #if os(tvOS)
        return true
        #else
        guard isLocal, let id = localRecordId else { return true }
        let resume = position
        guard let streamed = try? await JellyfinClient.shared.item(id) else {
            AppModel.shared.toast("Watching together needs the server, and it can\u{2019}t be reached. The download plays on.", tone: .error)
            return false
        }
        guard isLocal, localRecordId == id else { return true }
        var opts = StreamOptions()
        opts.startSeconds = resume
        await play(item: streamed, options: opts, meta: StartMeta(leavingDownloadForTrack: true))
        return !isLocal
        #endif
    }

    /// A group takes the transport. Speed is the group's, and the group's
    /// is normal: SyncPlay has no rate, and one device on 1.5× would drift.
    func joinGroup(_ transport: any GroupTransport) {
        if let old = group, old !== transport { leaveGroup(old) }
        group = transport
        if abs(speed - 1) > 0.001 { speed = 1 }
        Self.log.notice("group has the transport")
    }

    /// The group lets go. The stream carries on as it was.
    func leaveGroup(_ transport: any GroupTransport) {
        guard group === transport else { return }
        group = nil
        groupOrder = nil
        groupOrderAwaitsFrame = false
        groupSeekLanding = false
        groupPlayTask?.cancel(); groupPlayTask = nil
        groupDriftTask?.cancel(); groupDriftTask = nil
        Self.log.notice("group let go of the transport")
    }

    /// Carry out what the group decided. While a stream is still opening the
    /// order is kept and carried out at its first frame.
    func follow(_ order: GroupOrder) {
        guard group != nil else { return }
        groupOrder = order
        guard isActive, !isOpening else { return }
        enact(order)
    }

    /// The first frame after a load or a jump: the order waiting on it, then
    /// the group is told this device is there.
    func groupStreamSettled() {
        guard let group else { return }
        groupSeekLanding = false
        if groupOrderAwaitsFrame {
            groupOrderAwaitsFrame = false
            if let order = groupOrder { enact(order) }
        }
        group.streamSettled()
    }

    private func enact(_ order: GroupOrder) {
        groupPlayTask?.cancel(); groupPlayTask = nil
        groupDriftTask?.cancel(); groupDriftTask = nil
        let step = order.step(now: Date(), clock: engine?.clock ?? position, rate: speed)
        Self.log.info("group order: \(String(describing: step), privacy: .public)")
        switch step {
        case .pause(let target):
            pauseNow()
            if let target { groupSeek(to: target) }
        case .playNow(let target):
            if let target { groupSeek(to: target) }
            resumeNow()
            watchGroupDrift(order)
        case .playLater(let target, let delay):
            // Held where the group will start from, and started on the dot.
            if !isPaused { pauseNow() }
            if let target { groupSeek(to: target) }
            let mine = generation
            groupPlayTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.generation == mine, self.groupOrder == order else { return }
                self.resumeNow()
                self.watchGroupDrift(order)
            }
        }
    }

    /// A jump the group ordered: made on the engine, never asked of the
    /// group again.
    private func groupSeek(to seconds: Double) {
        let target = duration > 0 ? min(max(0, seconds), duration - 0.5) : max(0, seconds)
        adaptive.noteSeek()
        position = target
        if engine?.seek(to: target) == true {
            groupSeekLanding = true
        } else {
            // Not open yet: the order is carried out again at the first frame.
            groupOrderAwaitsFrame = true
        }
        refreshCues()
    }

    /// A few seconds into playing, look once at where the playhead is against
    /// where the group has it, and close a gap worth closing. A start that
    /// had to seek first lands late by however long the seek took; this is
    /// what brings it back. Twice at most per order: a stream too slow to
    /// keep up would otherwise be thrown about for ever.
    private func watchGroupDrift(_ order: GroupOrder) {
        guard order.playing, order.position != nil else { return }
        let mine = generation
        groupDriftTask = Task { [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.generation == mine, self.groupOrder == order,
                      !self.isPaused, !self.isBuffering, !self.isOpening,
                      let clock = self.engine?.clock,
                      let expected = order.expectedPosition(now: Date(), rate: self.speed)
                else { return }
                let gap = expected - clock
                guard abs(gap) > 1 else { return }
                Self.log.notice("group drift \(gap, format: .fixed(precision: 2))s: catching up")
                // A little past where the group is now, for the time the
                // seek itself takes.
                self.groupSeek(to: expected + 0.4)
            }
        }
    }
}
