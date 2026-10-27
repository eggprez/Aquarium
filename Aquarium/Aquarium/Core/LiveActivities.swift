//  The app's side of its Live Activity — see Shared/LiveActivityTypes for
//  what it is and why its state is made of dates.
//
//  Nothing in the players knows this file exists. It watches them through
//  Observation, works out what the activity should say, and tells the system
//  only when that has actually changed. The watching is cheap enough to do
//  on every playback tick; the telling is not, and an activity that is
//  updated too eagerly is one the system starts ignoring.
//
//  Two rules of ActivityKit shape what follows. An activity can only be
//  *started* while the app is in front — so a sleep timer set from the player
//  always gets one, and one set from CarPlay gets one the next time the app
//  is opened. And an activity outlives the process: one left running by an
//  app that was swapped out is picked back up here on the next launch.

#if os(iOS)

import ActivityKit
import Foundation
import Observation
import UIKit
import WidgetKit
import os

@MainActor
final class LiveActivityCenter {
    static let shared = LiveActivityCenter()

    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "liveactivity")

    private typealias Listening = ListeningActivityAttributes

    private var started = false
    /// Calls into ActivityKit, one after another. An update and the end that
    /// follows it are separate awaits, and must arrive in the order asked.
    private var tail: Task<Void, Never>?

    private init() {}

    /// Called once, from the app's `init` — early enough that a button pressed
    /// on an activity while the app wasn't running finds its handler in place.
    func start() {
        guard !started else { return }
        started = true
        Launch.mark("live activities handler")
        LiveActivityActions.handler = { [weak self] in self?.perform($0) }

        // The rest waits for the first frame. The handler above is all a
        // Live Activity button needs, and it is in place now; what follows
        // asks the activity server what is live and reloads the widgets —
        // round trips to other processes, from inside the app's `init`,
        // before anything was on screen.
        Launch.afterFirstFrame { [self] in
            Launch.mark("live activities")

            listening = Activity<Listening>.activities.first { Self.isLive($0) }
            // Left over from a run that ended without saying so.
            for extra in Activity<Listening>.activities where extra.id != listening?.id { end(extra) }
            if let listening { watchForEnd(of: listening) }

            watchListening()
            settleStaleNowPlaying()
            watchNowPlaying()

            // A start refused because the app was behind is asked for again here.
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dropEndedActivities()
                    self?.renewOldListening()
                    self?.refreshListening()
                }
            }
        }
    }

    // MARK: - Buttons

    private func perform(_ action: LiveActivityAction) {
        switch action {
        case .extendSleepTimer(let minutes):
            let music = MusicPlayer.shared
            let player = PlayerModel.shared
            if let deadline = music.sleepDeadline {
                music.setSleepTimer(minutes: Self.minutesLeft(until: deadline) + minutes)
            } else if let deadline = player.sleepDeadline {
                player.setSleepTimer(minutes: Self.minutesLeft(until: deadline) + minutes)
            }
        case .cancelSleepTimer:
            MusicPlayer.shared.cancelSleepTimer()
            PlayerModel.shared.cancelSleepTimer()
        case .togglePlayPause:
            _ = PlayerActions.togglePlayPause()
        case .skipSegment:
            _ = PlayerActions.skipSegment()
        }
        // Said now rather than when Observation gets round to it: the system
        // redraws the activity as the intent returns.
        refreshListening(immediately: true)
    }

    private static func minutesLeft(until deadline: Date) -> Int {
        max(0, Int((deadline.timeIntervalSinceNow / 60).rounded()))
    }

    // MARK: - Listening

    private var listening: Activity<Listening>?
    private var listeningSent: Listening.ContentState?

    /// A paused player is not a live anything. The activity can't be taken down
    /// later — the app is suspended soon after a pause — so it is marked to go
    /// stale instead, and draws itself small once it has.
    private static let pausedStaleAfter: TimeInterval = 15 * 60

    /// A playing activity is marked to go stale this long after the moment
    /// it expects to hear from the app again — the sleep deadline. If
    /// nothing has come by then the app has died or been
    /// stopped behind the activity's back, and a countdown sitting at 0:00
    /// is worse than none; stale, the activity stops drawing its clocks.
    private static let playingStaleGrace: TimeInterval = 30

    /// How long an activity with nothing to say is kept before it is ended.
    /// Moving between the files of a book or the songs of a queue passes
    /// through a moment with no player active — and an activity ended then,
    /// with the app behind, could not be started again until the app came
    /// forward.
    private static let listeningEndGrace: TimeInterval = 3

    /// The system ends any activity at eight hours, and leaves it on the Lock
    /// Screen with its last dates running out. One this old is swapped for a
    /// fresh one whenever the app comes forward.
    private static let listeningRenewAfter: TimeInterval = 7 * 60 * 60

    private var listeningSince = Date()
    private var listeningEnding: Task<Void, Never>?
    /// Swiped away. Not put back for the same thing until it stops.
    private var listeningDismissedTitle: String?

    private func watchListening() {
        withObservationTracking {
            refreshListening()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchListening() }
        }
    }

    /// `immediately` is for a button's answer, which the system redraws the
    /// activity for as the intent returns.
    private func refreshListening(immediately: Bool = false) {
        guard let state = listeningState() else {
            endListeningSoon()
            return
        }
        listeningEnding?.cancel()
        listeningEnding = nil
        if let sent = listeningSent, listening != nil, sent == state {
            // Back to what is already drawn — a stall too short to matter.
            listeningSettling?.cancel()
            listeningSettling = nil
            listeningSettlingSince = nil
            return
        }
        if listening == nil, listeningDismissedTitle == state.title { return }
        // A new activity can only be had while the app is in front; that is
        // not a moment to wait out.
        if listening == nil || immediately {
            sendListening(state)
        } else {
            settleListening()
        }
    }

    /// Play is three changes in half a second — playing, waiting for the
    /// stream, playing — and each used to be an update. The system answers a
    /// burst like that by holding updates back, and the one it held was the
    /// last: the activity said paused with the music playing, or the other
    /// way round. Now a change is sent once things have been
    /// still for a moment, and never later than `listeningSettleMax` after
    /// it began.
    private static let listeningSettle: TimeInterval = 0.4
    private static let listeningSettleMax: TimeInterval = 1.5
    private var listeningSettling: Task<Void, Never>?
    private var listeningSettlingSince: Date?

    private func settleListening() {
        let since = listeningSettlingSince ?? Date()
        listeningSettlingSince = since
        listeningSettling?.cancel()
        let wait = max(0, min(Self.listeningSettle, Self.listeningSettleMax - Date().timeIntervalSince(since)))
        // A pause is the last thing the app does before it is suspended; the
        // wait must not be the reason the update never goes.
        let hold = UIApplication.shared.beginBackgroundTask(withName: "LiveActivitySettle")
        listeningSettling = Task { [weak self] in
            defer { if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) } }
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.listeningSettling = nil
            self.listeningSettlingSince = nil
            // Nothing to say is `refreshListening`'s business — it ends it.
            guard let state = self.listeningState() else { return }
            self.sendListening(state)
        }
    }

    private func sendListening(_ state: Listening.ContentState) {
        listeningSettling?.cancel()
        listeningSettling = nil
        listeningSettlingSince = nil
        if let sent = listeningSent, listening != nil, sent == state { return }
        listeningDismissedTitle = nil

        let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state))
        if let activity = listening {
            listeningSent = state
            enqueue { await activity.update(content) }
        } else if let activity = request(Listening(), content: content) {
            listening = activity
            listeningSent = state
            listeningSince = Date()
            watchForEnd(of: activity)
        }
    }

    private static func staleDate(for state: Listening.ContentState) -> Date? {
        guard state.isPlaying else { return Date().addingTimeInterval(pausedStaleAfter) }
        return state.sleepDeadline.addingTimeInterval(playingStaleGrace)
    }

    private func endListeningSoon() {
        guard listeningEnding == nil else { return }
        guard listening != nil else {
            listeningDismissedTitle = nil
            return
        }
        listeningEnding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.listeningEndGrace))
            guard let self, !Task.isCancelled else { return }
            self.listeningEnding = nil
            guard self.listeningState() == nil, let activity = self.listening else { return }
            self.listening = nil
            self.listeningSent = nil
            self.listeningDismissedTitle = nil
            self.end(activity)
        }
    }

    /// Called as the app comes forward, the only time a new one can be had.
    private func renewOldListening() {
        guard let activity = listening,
              Date().timeIntervalSince(listeningSince) > Self.listeningRenewAfter else { return }
        Self.log.notice("renewing a listening activity near the system's limit")
        listening = nil
        listeningSent = nil
        end(activity)
    }

    /// Only a sleep timer earns an activity. An audiobook's place in its
    /// chapter used to be drawn here too, and was taken out: a countdown the
    /// app has to keep re-anchoring after every stall, seek and pause never
    /// stayed honest for long.
    private func listeningState() -> Listening.ContentState? {
        let music = MusicPlayer.shared
        if music.isActive, let item = music.current {
            guard let deadline = music.sleepDeadline else { return nil }
            let byline = item.artistLine
            return .init(
                title: (item.isAudiobook ? item.Album : nil) ?? item.Name ?? "",
                subtitle: byline.isEmpty ? nil : byline,
                isPlaying: music.isPlaying,
                sleepDeadline: deadline
            )
        }
        let player = PlayerModel.shared
        if player.isActive, let deadline = player.sleepDeadline {
            return .init(
                title: player.title, subtitle: nil, isPlaying: !player.isPaused,
                sleepDeadline: deadline, isVideo: true,
                skipLabel: PlayerActions.skipLabel
            )
        }
        return nil
    }

    // MARK: - The Now Playing widget

    private var nowPlayingSent: NowPlayingSnapshot?
    /// The artwork written beside the snapshot, by the URL it came from.
    private var nowPlayingArtworkFor: URL?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    /// While something plays, a look a minute at where the playhead really
    /// is, so a seek the card didn't hear about is caught.
    private var nowPlayingTicker: Task<Void, Never>?
    private static let nowPlayingDrift: Double = 3

    /// A card left saying "playing" by a run that ended without saying so — a
    /// force-quit, a crash — put right at launch. Nothing else would:
    /// `publishNowPlaying` only ever pauses a snapshot this run sent itself,
    /// so the card stayed on "Now Playing" with its bar running until
    /// something else was played. It keeps the position it last knew, which
    /// is the last one anybody saw rather than one run on to the end.
    private func settleStaleNowPlaying() {
        guard nowPlayingSnapshot() == nil, var stale = NowPlayingSnapshot.read(), stale.isPlaying else { return }
        stale.isPlaying = false
        stale.updatedAt = Date()
        nowPlayingSent = stale
        NowPlayingSnapshot.write(stale)
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingSnapshot.widgetKind)
    }

    /// What the Home Screen card shows — see Shared/WidgetTypes.swift. Only
    /// the things that name a change are read under observation; the
    /// playhead is read in a turn of its own, so a tick isn't a redraw.
    private func watchNowPlaying() {
        withObservationTracking {
            let music = MusicPlayer.shared
            let player = PlayerModel.shared
            _ = music.isActive
            _ = music.current?.Id
            _ = music.isPlaying
            _ = music.duration
            _ = player.isActive
            _ = player.item?.Id
            _ = player.title
            _ = player.isPaused
            _ = player.duration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishNowPlaying()
                self?.watchNowPlaying()
            }
        }
    }

    private func nowPlayingSnapshot() -> (snapshot: NowPlayingSnapshot, artwork: URL?)? {
        let music = MusicPlayer.shared
        if music.isActive, let item = music.current {
            let snapshot = NowPlayingSnapshot(
                itemId: item.Id,
                title: (item.isAudiobook ? item.Album : nil) ?? item.title,
                subtitle: item.artistLine,
                isVideo: false, isPlaying: music.isPlaying,
                position: music.position, duration: music.duration, rate: music.speed,
                hasArtwork: false
            )
            return (snapshot, music.artworkURL)
        }
        let player = PlayerModel.shared
        if player.isActive, !player.isLive, !player.isExternal {
            let snapshot = NowPlayingSnapshot(
                itemId: player.item?.Id ?? "",
                title: player.title, subtitle: player.subtitle,
                isVideo: true, isPlaying: !player.isPaused,
                position: player.position, duration: player.duration, rate: player.speed,
                hasArtwork: false
            )
            return (snapshot, player.artworkURL)
        }
        return nil
    }

    private func publishNowPlaying() {
        guard let current = nowPlayingSnapshot() else {
            nowPlayingTicker?.cancel()
            nowPlayingTicker = nil
            // Playback stopped. The card keeps what was last playing, paused,
            // so a glance at StandBy still says where you were.
            guard var last = nowPlayingSent, last.isPlaying else { return }
            last.position = last.position(at: Date())
            last.isPlaying = false
            last.updatedAt = Date()
            nowPlayingSent = last
            NowPlayingSnapshot.write(last)
            WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingSnapshot.widgetKind)
            return
        }
        var snapshot = current.snapshot
        loadNowPlayingArtwork(current.artwork)
        snapshot.hasArtwork = current.artwork != nil && nowPlayingArtworkFor == current.artwork

        if let sent = nowPlayingSent,
           sent.itemId == snapshot.itemId, sent.title == snapshot.title, sent.isPlaying == snapshot.isPlaying,
           sent.hasArtwork == snapshot.hasArtwork, abs(sent.duration - snapshot.duration) < 1,
           abs(sent.position(at: snapshot.updatedAt) - snapshot.position) < Self.nowPlayingDrift {
            return
        }
        nowPlayingSent = snapshot
        NowPlayingSnapshot.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingSnapshot.widgetKind)

        if snapshot.isPlaying, nowPlayingTicker == nil {
            nowPlayingTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self, !Task.isCancelled else { return }
                    self.publishNowPlaying()
                }
            }
        } else if !snapshot.isPlaying {
            nowPlayingTicker?.cancel()
            nowPlayingTicker = nil
        }
    }

    /// The cover, saved small beside the snapshot. The card is drawn by
    /// another process with no way to the server, so the picture has to be
    /// on disk before the card can show it; once it is, the card is
    /// redrawn with it.
    private func loadNowPlayingArtwork(_ url: URL?) {
        guard url != nowPlayingArtworkFor else { return }
        nowPlayingArtworkTask?.cancel()
        guard let url else {
            nowPlayingArtworkFor = nil
            NowPlayingSnapshot.writeArtwork(nil)
            return
        }
        nowPlayingArtworkTask = Task { [weak self] in
            guard let image = await ImageLoader.shared.load(url), !Task.isCancelled else { return }
            let jpeg = await Task.detached(priority: .utility) { Self.thumbnail(image, side: 400) }.value
            guard let self, !Task.isCancelled else { return }
            NowPlayingSnapshot.writeArtwork(jpeg)
            self.nowPlayingArtworkFor = jpeg == nil ? nil : url
            self.publishNowPlaying()
        }
    }

    nonisolated private static func thumbnail(_ image: UIImage, side: CGFloat) -> Data? {
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.jpegData(compressionQuality: 0.8)
    }

    // MARK: - ActivityKit

    private func request<A: ActivityAttributes>(_ attributes: A, content: ActivityContent<A.ContentState>) -> Activity<A>? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        // Asked only from the front. Behind, the answer is always no, and
        // this is reached on every playback tick until the app comes forward.
        guard UIApplication.shared.applicationState == .active else { return nil }
        do {
            return try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            Self.log.error("couldn't start \(String(describing: A.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func isLive<A: ActivityAttributes>(_ activity: Activity<A>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    /// An activity can end without the app ending it: swiped away, or at the
    /// system's eight-hour limit. Updates sent to it after that go nowhere, and
    /// a new one is never asked for while the old one is still held here.
    private func watchForEnd<A: ActivityAttributes & Sendable>(of activity: Activity<A>) {
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                self?.activityEnded(activity.id, dismissed: state == .dismissed)
                return
            }
        }
    }

    /// The same, asked directly as the app comes forward — the updates above
    /// are not delivered to a suspended app.
    private func dropEndedActivities() {
        if let listening, !Self.isLive(listening) {
            activityEnded(listening.id, dismissed: listening.activityState == .dismissed)
        }
    }

    private func activityEnded(_ id: String, dismissed: Bool) {
        if listening?.id == id {
            Self.log.notice("listening activity \(dismissed ? "dismissed" : "ended by the system", privacy: .public)")
            if dismissed { listeningDismissedTitle = listeningSent?.title }
            listening = nil
            listeningSent = nil
        }
    }

    private func end<A: ActivityAttributes & Sendable>(_ activity: Activity<A>) {
        enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Each call is held open against suspension. A pause from the Lock
    /// Screen or the headphones is the last thing the app does before iOS
    /// suspends it — audio has stopped — and an update still awaiting then
    /// was only delivered when the app next woke: at the following Play, so
    /// the activity kept counting through the whole pause.
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        let hold = UIApplication.shared.beginBackgroundTask(withName: "LiveActivityUpdate")
        tail = Task {
            await previous?.value
            await operation()
            if hold != .invalid { UIApplication.shared.endBackgroundTask(hold) }
        }
    }
}

#endif
