//  The app's side of its two Live Activities — see Shared/LiveActivityTypes
//  for what they are and why their state is made of dates.
//
//  Nothing in the players or the download manager knows this file exists. It
//  watches them through Observation, works out what each activity should say,
//  and tells the system only when that has actually changed. The watching is
//  cheap enough to do on every playback tick; the telling is not, and an
//  activity that is updated too eagerly is one the system starts ignoring.
//
//  Two rules of ActivityKit shape what follows. An activity can only be
//  *started* while the app is in front — so a sleep timer set from the player
//  always gets one, and one set from CarPlay gets one the next time the app
//  is opened. And an activity outlives the process: a download
//  batch whose app was swapped out is picked back up here on the next launch,
//  with the counts it began from kept in defaults.

#if os(iOS)

import ActivityKit
import Foundation
import Observation
import UIKit
import os

@MainActor
final class LiveActivityCenter {
    static let shared = LiveActivityCenter()

    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "liveactivity")

    private typealias Listening = ListeningActivityAttributes
    private typealias Downloads = DownloadsActivityAttributes

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
        LiveActivityActions.handler = { [weak self] in self?.perform($0) }

        listening = Activity<Listening>.activities.first { Self.isLive($0) }
        downloading = Activity<Downloads>.activities.first { Self.isLive($0) }
        // Left over from a run that ended without saying so.
        for extra in Activity<Listening>.activities where extra.id != listening?.id { end(extra) }
        for extra in Activity<Downloads>.activities where extra.id != downloading?.id { end(extra) }
        if let listening { watchForEnd(of: listening) }
        if let downloading { watchForEnd(of: downloading) }

        watchListening()
        watchDownloads()

        // A start refused because the app was behind is asked for again here.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dropEndedActivities()
                self?.renewOldListening()
                self?.refreshListening()
                self?.refreshDownloads()
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
        case .setDownloadsPaused(let paused):
            DownloadManager.shared.setPaused(paused)
        }
        // Said now rather than when Observation gets round to it: the system
        // redraws the activity as the intent returns.
        refreshListening(immediately: true)
        refreshDownloads()
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
                sleepDeadline: deadline, isVideo: true
            )
        }
        return nil
    }

    // MARK: - Downloads

    private var downloading: Activity<Downloads>?
    private var downloadsSent: Downloads.ContentState?
    private var downloadsSentAt = Date.distantPast
    private var downloadsTrailing: Task<Void, Never>?
    private var downloadsSettling: Task<Void, Never>?
    /// Swiped away; not put back until the next batch.
    private var downloadsDismissed = false

    /// What had already finished, and already failed, when the batch began.
    /// The batch's own counts are what has been added since — two numbers,
    /// kept in defaults, rather than a set of a music library's item ids.
    private var baseline: (complete: Int, failed: Int)? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: Self.baselineCompleteKey) != nil else { return nil }
            return (d.integer(forKey: Self.baselineCompleteKey), d.integer(forKey: Self.baselineFailedKey))
        }
        set {
            let d = UserDefaults.standard
            if let newValue {
                d.set(newValue.complete, forKey: Self.baselineCompleteKey)
                d.set(newValue.failed, forKey: Self.baselineFailedKey)
            } else {
                d.removeObject(forKey: Self.baselineCompleteKey)
                d.removeObject(forKey: Self.baselineFailedKey)
            }
        }
    }

    private static let baselineCompleteKey = "liveActivity.downloads.baselineComplete"
    private static let baselineFailedKey = "liveActivity.downloads.baselineFailed"

    /// No more than one update a second, and no more than one every few for
    /// a bar that has only crept: a library of songs lands one a second for
    /// twenty minutes, and a film reports its bytes twice a second for an hour.
    private static let downloadsMinInterval: TimeInterval = 1
    private static let downloadsCreepInterval: TimeInterval = 4
    /// How long nothing may be in flight before the batch is called finished.
    /// An item between the queue and its retry is briefly in neither.
    private static let downloadsSettleTime: TimeInterval = 2
    /// A running batch that has said nothing for this long has an app that is
    /// suspended behind it; the activity stops quoting a percentage then.
    private static let downloadsStaleAfter: TimeInterval = 5 * 60
    /// How long "Downloaded 40 items" stays on the Lock Screen.
    private static let downloadsLinger: TimeInterval = 10 * 60

    private func watchDownloads() {
        withObservationTracking {
            refreshDownloads()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchDownloads() }
        }
    }

    private func refreshDownloads() {
        let manager = DownloadManager.shared
        let inFlight = manager.inFlightCount
        // Read whether or not they are used, so the tracking above hears of
        // a transfer's progress and of a pause.
        let paused = manager.isPaused
        let live = manager.liveProgress

        guard inFlight > 0 else {
            if downloading != nil || baseline != nil { settleDownloads() }
            return
        }
        downloadsSettling?.cancel()
        downloadsSettling = nil

        let tally = manager.tally
        if baseline == nil {
            // One song is there before an activity could say so. Anything
            // else — a film, a book, two of anything — is worth the space.
            let single = manager.queue.first?.type ?? tally.running.first?.type
            guard inFlight > 1 || single != "Audio" else { return }
            baseline = (tally.completeCount, tally.failed.count)
        }
        let counts = batchCounts(tally)
        let total = counts.done + counts.failed + inFlight

        var arriving = 0.0
        for record in tally.running {
            arriving += Self.itemFraction(record, live[record.itemId]) ?? 0
        }
        let current = paused ? nil : tally.running.first
        let currentFraction = current.flatMap { Self.itemFraction($0, live[$0.itemId]) }
        let span = current.flatMap { itemSpan(itemId: $0.itemId, title: $0.title, fraction: currentFraction) }
        if current == nil { paceSamples = [] }
        let now = Date()
        let next = manager.queue.first { $0.isDue(at: now) } ?? manager.queue.first
        let state = Downloads.ContentState(
            phase: paused ? .paused : .running,
            done: counts.done, failed: counts.failed, total: total,
            currentTitle: current?.title,
            fraction: min((Double(counts.done + counts.failed) + arriving) / Double(max(total, 1)), 1),
            currentFraction: currentFraction,
            currentStart: span?.start,
            currentEnd: span?.end,
            nextTitle: next?.title
        )
        push(state)
    }

    /// How far one transfer has got, 0...1, or nil when that can't be told.
    /// A transcode has no length until it is over; its fraction is the share
    /// of the programme's running time fetched, and failing that the bytes
    /// against the size estimated when it was queued.
    private static func itemFraction(_ record: DownloadRecord, _ progress: DownloadManager.LiveProgress?) -> Double? {
        if let fraction = progress?.fraction ?? record.loadedFraction {
            return min(max(fraction, 0), 1)
        }
        if let progress, progress.total > 0 {
            return min(Double(progress.received) / Double(progress.total), 1)
        }
        let received = progress?.received ?? record.receivedBytes
        if let estimate = record.estimatedBytes, estimate > 0, received > 0 {
            return min(Double(received) / Double(estimate), 0.99)
        }
        return nil
    }

    /// Recent (time, fraction) readings of the arriving item, for its pace.
    /// A window rather than a start point, so a transfer that sped up or
    /// slowed down is judged on how it is going now.
    private var paceSamples: [(itemId: String, at: Date, fraction: Double)] = []
    private static let paceWindow: TimeInterval = 90

    /// The arriving item's progress as a span of time — see
    /// `ContentState.currentStart`. Kept as it was last sent while the new
    /// estimate agrees with it, so the bar isn't re-anchored (and the activity
    /// updated) on every reading.
    private func itemSpan(itemId: String, title: String, fraction: Double?) -> (start: Date, end: Date)? {
        guard let fraction, fraction < 1 else { return nil }
        let now = Date()
        paceSamples.removeAll { $0.itemId != itemId || $0.fraction > fraction || now.timeIntervalSince($0.at) > Self.paceWindow }
        if paceSamples.last.map({ now.timeIntervalSince($0.at) >= 2 }) ?? true {
            paceSamples.append((itemId, now, fraction))
        }
        guard let oldest = paceSamples.first else { return nil }
        let elapsed = now.timeIntervalSince(oldest.at)
        let gained = fraction - oldest.fraction
        guard elapsed >= 6, gained > 0.002 else { return nil }
        let whole = elapsed / gained
        let left = (1 - fraction) * whole
        guard left.isFinite, whole.isFinite, left < 12 * 3600 else { return nil }
        let end = now.addingTimeInterval(left)
        if let sent = downloadsSent, sent.currentTitle == title,
           let s = sent.currentStart, let e = sent.currentEnd,
           abs(e.timeIntervalSince(end)) < max(5, left * 0.1) {
            return (s, e)
        }
        return (now.addingTimeInterval(-fraction * whole), end)
    }

    private func batchCounts(_ tally: DownloadManager.Tally) -> (done: Int, failed: Int) {
        guard let baseline else { return (0, 0) }
        return (max(0, tally.completeCount - baseline.complete), max(0, tally.failed.count - baseline.failed))
    }

    private func push(_ state: Downloads.ContentState) {
        guard let sent = downloadsSent, downloading != nil else {
            let content = ActivityContent(state: state, staleDate: staleDate(for: state))
            if let activity = downloading {
                // Adopted from an earlier run; bring it up to date.
                enqueue { await activity.update(content) }
            } else {
                guard !downloadsDismissed,
                      let activity = request(Downloads(), content: content) else { return }
                downloading = activity
                watchForEnd(of: activity)
            }
            downloadsSent = state
            downloadsSentAt = Date()
            return
        }
        guard state != sent else { return }

        // The span moves only when the estimate drifts (see `itemSpan`), so
        // it is not part of what counts as creeping.
        var sameButFraction = state
        sameButFraction.fraction = sent.fraction
        sameButFraction.currentFraction = sent.currentFraction
        let onlyCrept = sameButFraction == sent
        if onlyCrept, abs(state.fraction - sent.fraction) < 0.01,
           abs((state.currentFraction ?? 0) - (sent.currentFraction ?? 0)) < 0.02 { return }

        let wait = (onlyCrept ? Self.downloadsCreepInterval : Self.downloadsMinInterval)
            - Date().timeIntervalSince(downloadsSentAt)
        // A pause is the answer to a button; it doesn't wait its turn.
        guard wait <= 0 || state.phase != sent.phase else {
            guard downloadsTrailing == nil else { return }
            downloadsTrailing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.downloadsTrailing = nil
                self.refreshDownloads()
            }
            return
        }
        guard let activity = downloading else { return }
        downloadsSent = state
        downloadsSentAt = Date()
        let content = ActivityContent(state: state, staleDate: staleDate(for: state))
        enqueue { await activity.update(content) }
    }

    /// A running batch goes stale after a stretch of silence — or a minute
    /// after the arriving item should have landed, since a bar sitting full
    /// with nothing after it is a claim nobody is standing behind.
    private func staleDate(for state: Downloads.ContentState) -> Date? {
        guard state.phase == .running else { return nil }
        let silence = Date().addingTimeInterval(Self.downloadsStaleAfter)
        guard let end = state.currentEnd else { return silence }
        return min(silence, max(end.addingTimeInterval(60), Date().addingTimeInterval(30)))
    }

    /// Nothing is in flight. If that is still so in a moment, the batch is
    /// over: say what it came to and let the activity go.
    private func settleDownloads() {
        guard downloadsSettling == nil else { return }
        downloadsSettling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.downloadsSettleTime))
            guard let self, !Task.isCancelled else { return }
            self.downloadsSettling = nil
            guard DownloadManager.shared.inFlightCount == 0 else { return }
            self.finishDownloads()
        }
    }

    private func finishDownloads() {
        downloadsTrailing?.cancel()
        downloadsTrailing = nil
        let counts = batchCounts(DownloadManager.shared.tally)
        baseline = nil
        downloadsSent = nil
        downloadsDismissed = false
        guard let activity = downloading else { return }
        downloading = nil

        let total = counts.done + counts.failed
        guard total > 0 else {
            // Everything was cancelled; there is nothing to report.
            end(activity)
            return
        }
        let state = Downloads.ContentState(
            phase: .finished, done: counts.done, failed: counts.failed, total: total,
            currentTitle: nil, fraction: 1
        )
        // A failure stays until it has been seen; a clean finish is only
        // worth a few minutes of Lock Screen.
        let policy: ActivityUIDismissalPolicy =
            counts.failed > 0 ? .default : .after(Date().addingTimeInterval(Self.downloadsLinger))
        Self.log.notice("download batch finished: \(counts.done) done, \(counts.failed) failed")
        enqueue { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
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
        if let downloading, !Self.isLive(downloading) {
            activityEnded(downloading.id, dismissed: downloading.activityState == .dismissed)
        }
    }

    private func activityEnded(_ id: String, dismissed: Bool) {
        if listening?.id == id {
            Self.log.notice("listening activity \(dismissed ? "dismissed" : "ended by the system", privacy: .public)")
            if dismissed { listeningDismissedTitle = listeningSent?.title }
            listening = nil
            listeningSent = nil
        }
        if downloading?.id == id {
            Self.log.notice("downloads activity \(dismissed ? "dismissed" : "ended by the system", privacy: .public)")
            if dismissed { downloadsDismissed = true }
            downloading = nil
            downloadsSent = nil
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
