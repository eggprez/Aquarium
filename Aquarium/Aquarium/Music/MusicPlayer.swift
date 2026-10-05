//  The music player: a queue of songs and the thing that plays them.
//
//  Separate from `PlayerModel` on purpose. That one is a video player with a
//  decade of television and phone behaviour in it — hand-overs between
//  qualities, live-stream watchdogs, subtitle styling, an Up Next card — and
//  none of it is what a song needs. A song needs a queue, gapless joins
//  between tracks, shuffle and repeat, and a lock screen that shows the album
//  cover. The two share the server, the downloads, and the audio session, and
//  they take turns: starting one stops the other, so there is never a film
//  playing under a song.
//
//  Gapless playback is `AVQueuePlayer`'s to give and it only gives it when the
//  next item is already in the player, buffered, before the current one ends.
//  So the queue here is two deep on the player's side — the track playing and
//  the one after it — and as deep as the user likes on this side. Every
//  change to the queue below re-derives what the second slot should hold.

import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Network
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class MusicPlayer {
    static let shared = MusicPlayer()

    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "music")

    /// One place in the queue. A song can be queued twice, so the identity is
    /// the slot rather than the song.
    struct Entry: Identifiable, Hashable, Sendable {
        let id: UUID
        var item: BaseItem
        /// Dealt by the station playing, and so the station's to re-deal.
        /// Anything queued by hand, or moved by hand, is not.
        var fromStation = false
        init(_ item: BaseItem, fromStation: Bool = false) {
            id = UUID()
            self.item = item
            self.fromStation = fromStation
        }
        // The slot is the identity: a starred or chapter-filled copy of the
        // song is still the same place in the queue.
        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one
        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    // MARK: - Published state

    private(set) var queue: [Entry] = []
    private(set) var currentIndex: Int?
    /// Something is loaded: the mini player shows, the lock screen has a card.
    private(set) var isActive = false
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    private(set) var isTranscoding = false
    private(set) var isLocal = false
    /// Where the queue came from — an album's name, "Rock Mix", a playlist —
    /// for the top of the Now Playing screen.
    private(set) var queueTitle: String?
    private(set) var isShuffled = false
    private(set) var sleepDeadline: Date?
    /// The audiobook's chapters, when the current item has them.
    private(set) var chapters: [ChapterInfo] = []
    /// The track reached the end of the queue and stopped; Play starts it over.
    private(set) var reachedEndOfQueue = false
    /// The station the queue is being dealt from, when it is one. It re-deals
    /// Up Next after every song finished or skipped and every thumb. Nil for
    /// an album, a playlist or anything else picked by hand — and then there
    /// is nothing for a thumb to steer.
    private(set) var station: LiveStation? {
        didSet {
            // The lock screen's thumbs come and go with the station.
            if station !== oldValue { NowPlaying.shared.refreshCommandAvailability() }
        }
    }

    /// How many songs a station keeps queued ahead.
    static let stationDepth = 25

    var repeatMode: RepeatMode {
        didSet {
            Preferences.shared.musicRepeat = repeatMode.rawValue
            prepareNext()
        }
    }

    /// Playback rate. Kept at 1 for music and remembered for audiobooks, where
    /// 1.25× is the speed most people actually listen at.
    var speed: Double = 1 {
        didSet {
            player.defaultRate = Float(speed)
            if isPlaying { player.rate = Float(speed) }
            // Every chapter and every file of a book sets the speed again as
            // it starts, almost always to what it already was. That used to
            // be a defaults write, an iCloud write and a Now Playing post each
            // time — and the caller posts Now Playing itself straight after.
            guard speed != oldValue else { return }
            if current?.isAudiobook == true { Preferences.shared.audiobookSpeed = speed }
            updateNowPlaying()
        }
    }

    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var current: BaseItem? { currentEntry?.item }
    var currentEntry: Entry? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }
    /// What comes after this, in order.
    var upNext: [Entry] {
        guard let i = currentIndex, i + 1 <= queue.count else { return [] }
        return Array(queue[(i + 1)...])
    }

    /// Whether anything is queued after this, without copying the rest of
    /// the queue out to find out — which is what `upNext.isEmpty` does.
    var hasUpNext: Bool {
        guard let i = currentIndex else { return false }
        return i + 1 < queue.count
    }
    var artworkURL: URL? { current.flatMap { MusicArt.url($0, width: 600) } }

    var hasNext: Bool {
        guard let i = currentIndex else { return false }
        return repeatMode == .all || i + 1 < queue.count
    }
    var hasPrevious: Bool { (currentIndex ?? 0) > 0 || position > 3 }

    // MARK: - Internals

    let player = AVQueuePlayer()

    /// A queue entry turned into something the player can hold.
    private struct Prepared {
        let entryId: UUID
        /// What it is, kept here rather than looked up: by the time a track
        /// is closed, `currentIndex` may already point at the next one.
        let item: BaseItem
        let avItem: AVPlayerItem
        let source: PlaybackSource?
        let isLocal: Bool
        var isTranscode: Bool { source?.isTranscode ?? false }
    }

    private var currentPrepared: Prepared?
    private var nextPrepared: Prepared?
    private var nextTask: Task<Void, Never>?
    /// The order before shuffle was turned on, so turning it off restores it.
    private var unshuffled: [Entry]?
    /// Counted like `PlayerModel.generation`: work that resumes after an await
    /// checks it is still describing the stream that was asked for.
    private var generation = 0
    private var isSwitching = false
    /// Set by `skipNext` before it hands the player its prepared slot, so the
    /// advance that follows knows the outgoing track was cut short rather than
    /// finished — and reports where it actually got to instead of its end.
    private var skippedByUser = false
    /// Seconds of the current track actually played — seeks not counted —
    /// which is what a skip or a finish is judged on.
    private var heardSeconds = 0.0
    private var lastTickPosition: Double?
    /// The track whose leaving has been learned from, so two ways out of one
    /// track don't count twice.
    private var learnedFrom: ObjectIdentifier?
    /// How the next `startCurrent` leaves the track playing.
    private var leaveAs: Leaving = .other
    private var restationPending = false
    private var timeObserver: Any?
    private var itemObservers: Set<AnyCancellable> = []
    private var playerObservers: Set<AnyCancellable> = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastReportAt = Date.distantPast
    private var lastNowPlayingRate: Double = -1
    /// Where Now Playing was last told playback was, and when; the system runs
    /// its clock forward from there. See `tick`.
    private var nowPlayingAnchor: (position: Double, at: Date, duration: Double)?
    private var consecutiveFailures = 0
    private var sleepTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkFor: URL?
    /// Autoplay past the end of the queue has been asked for once already
    /// for this queue; a mix that came back empty is not asked for again.
    private var autoplayTried = false
    /// The current entry played to its end and nothing followed. Anything
    /// queued since is what Play opens — see `resume`.
    private var currentRanOut = false
    /// Paused by someone rather than by the system, so an interruption that
    /// ends doesn't start what they stopped.
    private var userPaused = false
    private var interruptedWhilePlaying = false

    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Whether the current network is one to be careful on — cellular, a
    /// personal hotspot. Read when a stream is opened, so the choice between
    /// lossless and AAC follows the network the song actually goes over.
    @ObservationIgnored private var isExpensivePath = false

    private var client: JellyfinClient { .shared }
    private var prefs: Preferences { .shared }

    private static let reportInterval: TimeInterval = 10

    private init() {
        repeatMode = RepeatMode(rawValue: Preferences.shared.musicRepeat) ?? .off
        player.actionAtItemEnd = .advance
        player.allowsExternalPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.publisher(for: \.currentItem)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncWithPlayer() }
            }
            .store(in: &playerObservers)
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in self?.timeControlChanged(status) }
            }
            .store(in: &playerObservers)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in self?.isExpensivePath = expensive }
        }
        pathMonitor.start(queue: DispatchQueue(label: "aquarium.music.path"))
        observeAudioSession()
        Task.detached(priority: .utility) { StationSession.forgetOldTaste() }
    }

    // MARK: - Starting a queue

    /// Play these, from `index`, replacing whatever was queued. `position`
    /// opens the first of them at a point in seconds — a chapter, or zero for
    /// "start over" — rather than where it was left; a `seek` sent after this
    /// returns is lost, because the item is not in the player yet.
    func play(
        _ items: [BaseItem], startingAt index: Int = 0, shuffle: Bool = false, title: String? = nil,
        at position: Double? = nil
    ) {
        let playable = items.filter { $0.isAudio || $0.isSong || $0.isAudiobook }
        guard !playable.isEmpty else {
            AppModel.shared.toast("Nothing here to play", tone: .error)
            return
        }
        var entries = playable.map { Entry($0) }
        var start = min(max(0, index), entries.count - 1)
        unshuffled = nil
        isShuffled = false
        if shuffle {
            let chosen = entries.remove(at: start)
            unshuffled = [chosen] + entries
            entries.shuffle()
            entries.insert(chosen, at: 0)
            start = 0
            isShuffled = true
        }
        queue = entries
        currentIndex = start
        queueTitle = title
        station = nil
        autoplayTried = false
        reachedEndOfQueue = false
        startCurrent(startAt: position)
    }

    /// Play a station's first songs and keep dealing from it.
    func playStation(_ station: LiveStation, songs: [BaseItem]) {
        play(songs, title: station.title)
        guard !queue.isEmpty else { return }
        for i in queue.indices { queue[i].fromStation = true }
        self.station = station
    }

    /// Everything after the current track, in order, then these.
    func playLater(_ items: [BaseItem]) {
        let entries = items.filter(\.isAudio).map { Entry($0) }
        guard !entries.isEmpty else { return }
        if !isActive || currentIndex == nil {
            play(items)
            return
        }
        queue.append(contentsOf: entries)
        unshuffled?.append(contentsOf: entries)
        reachedEndOfQueue = false
        prepareNext()
    }

    /// These, and then everything that was already coming.
    func playNext(_ items: [BaseItem]) {
        let entries = items.filter(\.isAudio).map { Entry($0) }
        guard !entries.isEmpty else { return }
        guard isActive, let i = currentIndex else {
            play(items)
            return
        }
        queue.insert(contentsOf: entries, at: i + 1)
        if unshuffled != nil, let cur = currentEntry, let j = unshuffled?.firstIndex(of: cur) {
            unshuffled?.insert(contentsOf: entries, at: j + 1)
        }
        reachedEndOfQueue = false
        prepareNext()
    }

    /// The whole queue from one of its own entries.
    func skip(to entry: Entry) {
        guard let i = queue.firstIndex(of: entry) else { return }
        // Jumping ahead past what is playing is passing on it.
        if let c = currentIndex, i > c { leaveAs = .skipped }
        currentIndex = i
        reachedEndOfQueue = false
        startCurrent()
    }

    func remove(_ entry: Entry) {
        guard let i = queue.firstIndex(of: entry) else { return }
        unshuffled?.removeAll { $0 == entry }
        if let station, entry.item.isSong {
            station.session.note(entry.item, .removed)
            scheduleRestation()
        }
        if i == currentIndex {
            queue.remove(at: i)
            if queue.isEmpty {
                stop()
            } else {
                currentIndex = min(i, queue.count - 1)
                startCurrent()
            }
            return
        }
        queue.remove(at: i)
        if let c = currentIndex, i < c { currentIndex = c - 1 }
        prepareNext()
    }

    /// Reorder within Up Next. Offsets are into `upNext`, not the whole queue.
    func moveUpNext(fromOffsets: IndexSet, toOffset: Int) {
        guard let c = currentIndex else { return }
        var rest = upNext
        // Put somewhere by hand, so it stays there.
        for i in fromOffsets where rest.indices.contains(i) { rest[i].fromStation = false }
        rest.move(fromOffsets: fromOffsets, toOffset: toOffset)
        queue = Array(queue[...c]) + rest
        prepareNext()
    }

    func clearUpNext() {
        guard let c = currentIndex else { return }
        queue = Array(queue[...c])
        unshuffled = nil
        station = nil
        prepareNext()
    }

    func toggleShuffle() {
        guard let c = currentIndex else { return }
        if isShuffled {
            // Back to the order things were in, with the playhead still on
            // the same song.
            if let original = unshuffled, let cur = currentEntry {
                let known = Set(queue.map(\.id))
                // A set each way: `original.contains` per entry was a scan of
                // the whole original queue for every song in this one.
                let wasThere = Set(original.map(\.id))
                let restored = original.filter { known.contains($0.id) }
                    + queue.filter { !wasThere.contains($0.id) }
                queue = restored
                currentIndex = restored.firstIndex(of: cur) ?? 0
            }
            unshuffled = nil
            isShuffled = false
        } else {
            unshuffled = queue
            let before = Array(queue[..<c])
            let cur = queue[c]
            var after = Array(queue[(c + 1)...])
            after.shuffle()
            queue = before + [cur] + after
            isShuffled = true
        }
        prepareNext()
    }

    // MARK: - Transport

    func togglePlayPause() {
        if reachedEndOfQueue {
            restartFromTop()
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        userPaused = true
        player.pause()
        isPlaying = false
        updateNowPlaying()
        Task { await reportNow() }
    }

    func resume() {
        guard isActive else { return }
        if reachedEndOfQueue {
            restartFromTop()
            return
        }
        userPaused = false
        // Nothing in the player — the queue ran out, or gave up on a track,
        // and something has been queued since. Open it rather than spin.
        if !isBuffering, currentPrepared == nil || player.currentItem == nil
            || player.currentItem?.status == .failed, let i = currentIndex {
            // Past the one that ended, or the one it gave up on; a give-up
            // with nothing after it tries that track again.
            let target: Int? = currentRanOut ? nextIndex(after: i)
                : errorMessage != nil ? (nextIndex(after: i) ?? i) : i
            guard let target, queue.indices.contains(target) else { return }
            currentIndex = target
            startCurrent()
            return
        }
        activateSession()
        player.playImmediately(atRate: Float(speed))
        isPlaying = true
        updateNowPlaying()
        Task { await reportNow() }
    }

    private func restartFromTop() {
        guard !queue.isEmpty else { return }
        currentIndex = 0
        reachedEndOfQueue = false
        startCurrent()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.25) : seconds)
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func skipNext() {
        guard let i = currentIndex else { return }
        // A book moves by chapter: a stray double-tap on the AirPods must not
        // end it, or send its resume point back to the start.
        if current?.isAudiobook == true {
            skipChapter(1)
            return
        }
        // Asked for, so repeat-one steps aside.
        let target = nextIndex(after: i, byUser: true)
        // The prepared item is already buffered: hand the player its own
        // next slot and let the bookkeeping follow, as it does at a track's
        // natural end.
        if let next = nextPrepared, let target, queue[target].id == next.entryId,
           player.items().contains(where: { $0 === next.avItem }) {
            skippedByUser = true
            player.advanceToNextItem()
            player.playImmediately(atRate: Float(speed))
            return
        }
        guard let target else {
            learn(.skipped)
            reachedEnd()
            return
        }
        leaveAs = .skipped
        currentIndex = target
        startCurrent()
    }

    func skipPrevious() {
        guard let i = currentIndex else { return }
        if current?.isAudiobook == true {
            skipChapter(-1)
            return
        }
        if position > 3 || i == 0 {
            seek(to: 0)
            if !isPlaying { resume() }
            return
        }
        currentIndex = i - 1
        startCurrent()
    }

    /// The audiobook's chapter that `position` is inside.
    var currentChapter: ChapterInfo? {
        chapters.last { $0.startSeconds <= position + 0.5 }
    }

    func skipChapter(_ direction: Int) {
        guard !chapters.isEmpty else {
            seek(by: direction > 0 ? 30 : -15)
            return
        }
        if direction > 0, let next = chapters.first(where: { $0.startSeconds > position + 1 }) {
            seek(to: next.startSeconds)
        } else if direction < 0 {
            // Back to the top of this chapter, or the one before it when
            // this one has only just started — the way a track skip works.
            let past = chapters.filter { $0.startSeconds < position - 3 }
            seek(to: past.last?.startSeconds ?? 0)
        }
    }

    func stepSpeed(_ direction: Int) {
        let i = Self.speeds.firstIndex { abs($0 - speed) < 0.001 } ?? Self.speeds.firstIndex(of: 1)!
        speed = Self.speeds[min(max(i + direction, 0), Self.speeds.count - 1)]
    }

    /// Take everything down. What is owed to the server is paid on the way.
    func stop() {
        guard isActive || !queue.isEmpty else { return }
        Self.log.info("stop at \(self.position, format: .fixed(precision: 1))")
        generation &+= 1
        learn(.other)
        let closing = closingReport()
        let closingSource = currentPrepared?.source
        let nextSource = nextPrepared?.source
        nextTask?.cancel()
        nextTask = nil
        isSwitching = true
        player.pause()
        player.removeAllItems()
        isSwitching = false
        teardownItemObservers()
        currentPrepared = nil
        nextPrepared = nil
        cancelSleepTimer()
        queue = []
        currentIndex = nil
        unshuffled = nil
        isShuffled = false
        isActive = false
        isPlaying = false
        isBuffering = false
        position = 0
        duration = 0
        chapters = []
        queueTitle = nil
        station = nil
        errorMessage = nil
        reachedEndOfQueue = false
        clearNowPlaying()
        Task {
            if let closing { await client.reportPlaybackStopped(closing) }
            if let closingSource, closingSource.isTranscode {
                await client.stopTranscode(playSessionId: closingSource.playSessionId)
            }
            if let nextSource, nextSource.isTranscode {
                await client.stopTranscode(playSessionId: nextSource.playSessionId)
            }
        }
    }

    /// The video player is about to start: get out of its way.
    func yield() {
        guard isActive else { return }
        stop()
    }

    /// A star set from the Now Playing screen, reflected in the queue's own
    /// copy of the song so the button doesn't snap back.
    func markFavorite(_ itemId: String, _ favorite: Bool) {
        for i in queue.indices where queue[i].item.Id == itemId {
            var data = queue[i].item.UserData ?? UserData()
            data.IsFavorite = favorite
            queue[i].item.UserData = data
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepDeadline = deadline
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard let self, !Task.isCancelled else { return }
            self.pause()
            self.sleepDeadline = nil
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
    }

    // MARK: - Opening the current entry

    /// Open whatever `currentIndex` points at, from the top or from its
    /// resume point, replacing what the player holds.
    private func startCurrent(startAt: Double? = nil) {
        guard let entry = currentEntry else {
            stop()
            return
        }
        // The other player, if it is up, comes down first: two things making
        // sound at once is never what anyone meant.
        if PlayerModel.shared.isActive { PlayerModel.shared.stop(reason: "music started") }

        generation &+= 1
        let mine = generation
        learn(leaveAs)
        leaveAs = .other
        let closing = closingReport()
        let previousSource = currentPrepared?.source
        nextTask?.cancel()
        nextTask = nil
        let stale = nextPrepared
        nextPrepared = nil
        // The old track and its prepared next come out now, not when the new
        // one resolves: until then nothing plays, and `tick` — which only
        // follows `currentPrepared` — writes nobody's position.
        isSwitching = true
        player.pause()
        player.removeAllItems()
        isSwitching = false
        teardownItemObservers()
        currentPrepared = nil
        currentRanOut = false
        userPaused = false

        isActive = true
        isBuffering = true
        isPlaying = false
        errorMessage = nil
        reachedEndOfQueue = false
        position = startAt ?? 0
        duration = entry.item.runtimeSeconds
        chapters = entry.item.Chapters ?? []
        speed = entry.item.isAudiobook ? prefs.audiobookSpeed : 1
        activateSession()
        updateNowPlaying()

        Task {
            if let closing { await client.reportPlaybackStopped(closing) }
            if let previousSource, previousSource.isTranscode {
                await client.stopTranscode(playSessionId: previousSource.playSessionId)
            }
            if let stale, stale.entryId != entry.id, let src = stale.source, src.isTranscode {
                await client.stopTranscode(playSessionId: src.playSessionId)
            }
        }

        Task {
            // A prepared next slot that happens to be this very entry — the
            // user pressed Next while it was still resolving, or repeat-one
            // wrapped — is reused rather than resolved twice.
            let prepared: Prepared
            if let stale, stale.entryId == entry.id, stale.avItem.status != .failed {
                prepared = stale
            } else {
                do {
                    prepared = try await prepare(entry)
                } catch {
                    guard generation == mine else { return }
                    failedToOpen(entry, error: error)
                    return
                }
            }
            guard generation == mine else {
                if let src = prepared.source { await release(src) }
                return
            }
            install(prepared, startAt: resumePoint(for: entry.item, explicit: startAt))
            await client.reportPlaybackStart(report(paused: false))
            // The full item, for an audiobook's chapters, which the list
            // query doesn't carry.
            if entry.item.isAudiobook, entry.item.Chapters == nil {
                var full = client.isOffline ? nil : try? await client.musicItem(entry.item.Id)
                #if !os(tvOS)
                // A downloaded book keeps its chapters beside it, for when
                // there is nobody to ask.
                if full == nil { full = OfflineMusic.book(entry.item.Id) }
                #endif
                guard generation == mine, let full else { return }
                chapters = full.Chapters ?? []
                if let i = currentIndex, queue.indices.contains(i) { queue[i].item = full }
            }
        }
    }

    /// Where to open an item: an audiobook where it was left, a song at the
    /// top, anything at the point explicitly asked for.
    private func resumePoint(for item: BaseItem, explicit: Double?) -> Double {
        if let explicit { return max(0, explicit) }
        #if !os(tvOS)
        if let record = DownloadManager.shared.record(for: item.Id), record.status == .complete,
           item.isAudiobook {
            return record.resumeSeconds
        }
        #endif
        guard item.isAudiobook else { return 0 }
        let ticks = item.userData.positionTicks
        guard ticks > 0, let total = item.RunTimeTicks, total > 0 else { return 0 }
        let f = Double(ticks) / Double(total)
        return f > 0.98 ? 0 : Double(ticks) / 10_000_000
    }

    private func install(_ prepared: Prepared, startAt: Double) {
        isSwitching = true
        player.pause()
        player.removeAllItems()
        currentPrepared = prepared
        player.insert(prepared.avItem, after: nil)
        isSwitching = false
        isLocal = prepared.isLocal
        isTranscoding = prepared.isTranscode
        applyGain(for: currentEntry?.item)
        installItemObservers(on: prepared.avItem)
        consecutiveFailures = 0
        if startAt > 0.5 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.playImmediately(atRate: Float(speed))
        isPlaying = true
        Self.log.info(
            "playing \(prepared.entryId, privacy: .public) local=\(prepared.isLocal) transcode=\(prepared.isTranscode) at=\(startAt, format: .fixed(precision: 1))")
        prepareNext()
    }

    /// Turn an entry into a player item: the file on this device when it is
    /// downloaded, else whatever the server says to stream.
    private func prepare(_ entry: Entry) async throws -> Prepared {
        let item = entry.item
        #if !os(tvOS)
        if let record = DownloadManager.shared.record(for: item.Id), record.status == .complete,
           let url = DownloadManager.shared.mediaURL(for: record) {
            let avItem = AVPlayerItem(url: url)
            return Prepared(entryId: entry.id, item: item, avItem: avItem, source: nil, isLocal: true)
        }
        #endif
        // On a cellular link, unless told otherwise, a lossless file is asked
        // for as AAC: a FLAC album is a gigabyte and a phone plan is not.
        let cap: Int? = (isExpensivePath && !prefs.losslessOnCellular) ? 384_000 : nil
        let src = try await client.resolvePlayback(itemId: item.Id, maxBitrate: cap, audio: true)
        let asset = AVURLAsset(url: src.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": client.authHeaders(for: src.url),
        ])
        let avItem = AVPlayerItem(asset: asset)
        avItem.preferredForwardBufferDuration = 15
        return Prepared(entryId: entry.id, item: item, avItem: avItem, source: src, isLocal: false)
    }

    private func release(_ src: PlaybackSource) async {
        if src.isTranscode { await client.stopTranscode(playSessionId: src.playSessionId) }
    }

    /// Which entry follows `i`, given the repeat mode. Nil at the end.
    /// `byUser` is a Next pressed: repeat-one only repeats a track that ends.
    private func nextIndex(after i: Int, byUser: Bool = false) -> Int? {
        switch repeatMode {
        case .one where !byUser: return i
        case .all: return queue.isEmpty ? nil : (i + 1) % queue.count
        case .off, .one: return i + 1 < queue.count ? i + 1 : nil
        }
    }

    /// Make the player's second slot hold what the queue says comes next.
    private func prepareNext() {
        guard let i = currentIndex, let cur = currentPrepared else { return }
        let target = nextIndex(after: i).map { queue[$0] }
        // Already right.
        if let target, let next = nextPrepared, next.entryId == target.id,
           repeatMode != .one || next.avItem !== cur.avItem {
            return
        }
        nextTask?.cancel()
        // Whatever was in the slot is not what comes next any more.
        if let old = nextPrepared {
            if player.items().contains(where: { $0 === old.avItem }) { player.remove(old.avItem) }
            nextPrepared = nil
            if let src = old.source { Task { await release(src) } }
        }
        guard let target else { return }
        let mine = generation
        nextTask = Task {
            guard let prepared = try? await prepare(target) else { return }
            guard !Task.isCancelled, generation == mine, currentPrepared?.avItem === cur.avItem else {
                if let src = prepared.source { await release(src) }
                return
            }
            // Two slots and no more: anything else the player has picked up
            // (it shouldn't) is cleared before the new second slot goes in.
            for extra in player.items() where extra !== cur.avItem { player.remove(extra) }
            if player.canInsert(prepared.avItem, after: cur.avItem) {
                player.insert(prepared.avItem, after: cur.avItem)
                nextPrepared = prepared
            } else if let src = prepared.source {
                await release(src)
            }
        }
    }

    // MARK: - Stations, and what steers them

    private enum Leaving { case finished, skipped, other }

    /// The track playing is on its way out: tell the station, if one is
    /// playing, how much of it was heard and how it ended. Called at every
    /// way out, before the report. Outside a station nothing is learned.
    private func learn(_ how: Leaving) {
        guard let prepared = currentPrepared else { return }
        let key = ObjectIdentifier(prepared.avItem)
        guard learnedFrom != key else { return }
        learnedFrom = key
        let heard = heardSeconds
        heardSeconds = 0
        lastTickPosition = nil
        guard let station, prepared.item.isSong,
              let reaction = ListenReaction(
                  heard: heard, duration: duration,
                  finished: how == .finished, skipped: how == .skipped
              )
        else { return }
        station.session.note(prepared.item, reaction)
        scheduleRestation()
    }

    /// Whether thumbs mean anything now: a station is dealing the queue and
    /// a song is playing. A thumb is advice to that station and nothing
    /// else, so an album or a playlist picked by hand offers none.
    var canThumb: Bool { station != nil && current?.isSong == true }

    /// The thumb on the song playing, in this station: 1 up, -1 down, nil
    /// neither — and nil whenever `canThumb` is false.
    var thumb: Int? {
        guard let station, let song = current, song.isSong else { return nil }
        return station.session.thumbs[song.Id]
    }

    /// Thumbs up (1), down (-1) or neither (nil) for the song playing, told
    /// to the station playing it and forgotten when it ends. Down also skips
    /// the song, and this station never deals it again; up pulls in more
    /// like it. Does nothing when `canThumb` is false.
    func setThumb(_ value: Int?) {
        guard canThumb, let station, let song = current else { return }
        guard station.session.thumbs[song.Id] != value else { return }
        station.session.setThumb(song, value)
        // The lock screen shows the thumb too, and after a skip, the next
        // song's lack of one.
        defer { NowPlaying.shared.refreshCommandAvailability() }
        if value == -1 {
            if let c = currentIndex {
                let later = queue.indices.filter { $0 > c && queue[$0].item.Id == song.Id }
                for i in later.reversed() { queue.remove(at: i) }
            }
            // The thumb has said all there is to say about it: the skip that
            // follows isn't counted again as a skip.
            if let prepared = currentPrepared {
                learnedFrom = ObjectIdentifier(prepared.avItem)
                heardSeconds = 0
                lastTickPosition = nil
            }
            // `learn` won't ask for the re-deal, having been told the song is
            // already accounted for.
            if hasNext { skipNext() }
            scheduleRestation()
        } else if value == 1 {
            // More like this, as well as more of this.
            Task {
                await StationBuilder.widen(station, from: song)
                scheduleRestation()
            }
        } else {
            scheduleRestation()
        }
    }

    /// Re-deal once whatever is under way has settled — `currentIndex` has
    /// usually still to move when a track's leaving is learned.
    private func scheduleRestation() {
        guard station != nil, !restationPending else { return }
        restationPending = true
        Task {
            restationPending = false
            restation()
        }
    }

    /// Deal Up Next again from the station's pool, with everything it now
    /// knows. Songs queued or moved by hand keep their places; the station's
    /// own slots around them are refilled, and topped up to `stationDepth`.
    /// The next song is left alone when it is already buffered and still
    /// wanted, so the join into it stays gapless.
    private func restation() {
        guard let station, !isShuffled, let c = currentIndex, queue.indices.contains(c) else { return }
        let head = Array(queue[...c])
        let tail = Array(queue[(c + 1)...])

        var keep: Entry?
        if let first = tail.first, first.fromStation, nextPrepared?.entryId == first.id,
           !station.session.passed.contains(first.item.Id) {
            keep = first
        }
        let pinned = tail.filter { !$0.fromStation }
        let history = head.map(\.item) + (keep.map { [$0.item] } ?? [])
        let exclude = Set(history.map(\.Id)).union(pinned.map(\.item.Id))
        let slots = tail.filter(\.fromStation).count
        let want = max(Self.stationDepth, slots) - (keep == nil ? 0 : 1)
        let fresh = station.upcoming(count: want, after: history, exclude: exclude)

        // The same song keeps its queue entry, so the list doesn't redraw
        // every row for a song that only moved.
        var existing: [String: Entry] = [:]
        for e in tail where e.fromStation && e.id != keep?.id { existing[e.item.Id] = existing[e.item.Id] ?? e }
        var dealt = fresh.map { existing.removeValue(forKey: $0.Id) ?? Entry($0, fromStation: true) }
        if let keep { dealt.insert(keep, at: 0) }

        var next = dealt.makeIterator()
        var newTail: [Entry] = []
        for e in tail {
            if !e.fromStation {
                newTail.append(e)
            } else if let n = next.next() {
                newTail.append(n)
            }
        }
        while let n = next.next() { newTail.append(n) }
        queue = head + newTail
        prepareNext()

        // Running low: reach for more like what is playing now.
        if let playing = current, station.remaining(excluding: Set(queue.map(\.item.Id))) < 15 {
            Task {
                // Only when it found something: a pool that can't grow would
                // otherwise ask again after every deal, for ever.
                let grew = await StationBuilder.widen(station, from: playing)
                if grew, self.station === station { scheduleRestation() }
            }
        }
    }

    // MARK: - Following the player

    /// The player's current item changed. Either it advanced into the slot we
    /// prepared, or it ran out.
    private func syncWithPlayer() {
        guard !isSwitching else { return }
        let live = player.currentItem
        if let cur = currentPrepared, live === cur.avItem { return }
        if let next = nextPrepared, live === next.avItem {
            advanced(into: next)
            return
        }
        if live == nil, currentPrepared != nil {
            // The next track wasn't in the player in time — its prepare failed
            // or was still running. The queue isn't over: open it the long way.
            if let i = currentIndex, let target = nextIndex(after: i) {
                learn(skippedByUser ? .skipped : .finished)
                if skippedByUser {
                    skippedByUser = false
                } else {
                    // Ran out rather than cut short: reported at its end.
                    position = duration
                    #if !os(tvOS)
                    if let heard = current, heard.isSong { OfflineMusicIndex.shared.notePlayed(heard.Id) }
                    #endif
                }
                currentIndex = target
                startCurrent(startAt: 0)
                return
            }
            reachedEnd()
        }
    }

    private func advanced(into next: Prepared) {
        guard let i = currentIndex else { return }
        learn(skippedByUser ? .skipped : .finished)
        // A track that ran out is reported at its end, which is what makes the
        // server count it as played; one that was skipped is reported where
        // it was left, so a song heard for ten seconds is not "played".
        let finished = closingReport(position: skippedByUser ? position : duration)
        let heardToTheEnd = !skippedByUser
        skippedByUser = false
        let finishedSource = currentPrepared?.source
        // A book part skipped keeps the place `closingReport` just saved.
        let finishedLocalId = isLocal && (heardToTheEnd || currentEntry?.item.isAudiobook != true)
            ? currentEntry?.item.Id : nil
        #if !os(tvOS)
        // Heard to the end: counted here as well as on the server, so Top
        // Songs and the stations built from it keep up with no server.
        if heardToTheEnd, let heard = currentEntry?.item, heard.isSong {
            OfflineMusicIndex.shared.notePlayed(heard.Id)
        }
        #endif
        teardownItemObservers()
        currentPrepared = next
        nextPrepared = nil
        let target = queue.firstIndex { $0.id == next.entryId } ?? nextIndex(after: i) ?? i
        currentIndex = target
        isLocal = next.isLocal
        isTranscoding = next.isTranscode
        position = 0
        duration = currentEntry?.item.runtimeSeconds ?? 0
        chapters = currentEntry?.item.Chapters ?? []
        if let item = currentEntry?.item, item.isAudiobook { speed = prefs.audiobookSpeed } else if speed != 1 { speed = 1 }
        applyGain(for: currentEntry?.item)
        installItemObservers(on: next.avItem)
        isPlaying = player.timeControlStatus != .paused
        updateNowPlaying()
        Self.log.info("advanced to \(next.entryId, privacy: .public)")
        Task {
            if let finished { await client.reportPlaybackStopped(finished) }
            if let finishedSource, finishedSource.isTranscode {
                await client.stopTranscode(playSessionId: finishedSource.playSessionId)
            }
            #if !os(tvOS)
            if let finishedLocalId {
                DownloadManager.shared.noteProgress(itemId: finishedLocalId, positionSeconds: 0, played: heardToTheEnd ? true : nil)
            }
            #endif
            await client.reportPlaybackStart(report(paused: false))
        }
        prepareNext()
    }

    /// The last track ended and nothing was queued after it.
    private func reachedEnd() {
        learn(.finished)
        let finished = closingReport(position: duration)
        let finishedSource = currentPrepared?.source
        #if !os(tvOS)
        if let heard = current, heard.isSong { OfflineMusicIndex.shared.notePlayed(heard.Id) }
        #endif
        teardownItemObservers()
        currentPrepared = nil
        nextPrepared = nil
        currentRanOut = true
        isPlaying = false
        isBuffering = false
        Task {
            if let finished { await client.reportPlaybackStopped(finished) }
            if let finishedSource, finishedSource.isTranscode {
                await client.stopTranscode(playSessionId: finishedSource.playSessionId)
            }
        }
        // Keep going with something like it, once, when asked to.
        if prefs.musicAutoplay, !autoplayTried, let last = current, last.isSong {
            autoplayTried = true
            Task { await autoplayMore(after: last) }
            return
        }
        position = 0
        reachedEndOfQueue = true
        updateNowPlaying()
    }

    /// Carry on past the end with a station grown from the last song, so
    /// what autoplay brings learns from skips like any other station.
    private func autoplayMore(after last: BaseItem) async {
        let mine = generation
        let built = await StationBuilder.build(from: last, title: "Autoplay")
        guard generation == mine, currentPrepared == nil else { return }
        let history = queue.map(\.item)
        let more = built?.upcoming(count: Self.stationDepth, after: history) ?? []
        guard let built, !more.isEmpty, let i = currentIndex else {
            position = 0
            reachedEndOfQueue = true
            updateNowPlaying()
            return
        }
        queue.append(contentsOf: more.map { Entry($0, fromStation: true) })
        station = built
        if queueTitle != nil { queueTitle = "Autoplay" }
        currentIndex = i + 1
        startCurrent()
    }

    private func failedToOpen(_ entry: Entry, error: any Error) {
        Self.log.error("failed to open \(entry.item.Id, privacy: .public): \(error.localizedDescription, privacy: .private)")
        consecutiveFailures += 1
        isBuffering = false
        isPlaying = false
        if consecutiveFailures >= 3 {
            errorMessage = error.localizedDescription
            AppModel.shared.toast("Couldn't play \(entry.item.title): \(error.localizedDescription)", tone: .error)
            return
        }
        AppModel.shared.toast("Skipped \(entry.item.title) — it couldn't be opened", tone: .error)
        guard let i = currentIndex, let next = nextIndex(after: i), next != i else {
            errorMessage = error.localizedDescription
            return
        }
        currentIndex = next
        startCurrent()
    }

    // MARK: - Observers

    private func installItemObservers(on avItem: AVPlayerItem) {
        teardownItemObservers()
        avItem.publisher(for: \.status)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in self?.itemStatusChanged(status, of: avItem) }
            }
            .store(in: &itemObservers)
        let failed = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: avItem, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor [weak self] in
                guard let self, self.currentPrepared?.avItem === avItem else { return }
                self.streamFailed(error)
            }
        }
        notificationObservers.append(failed)
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                Task { @MainActor [weak self] in self?.tick(time) }
            }
        }
    }

    private func teardownItemObservers() {
        itemObservers.removeAll()
        for o in notificationObservers { NotificationCenter.default.removeObserver(o) }
        notificationObservers.removeAll()
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, of avItem: AVPlayerItem) {
        guard currentPrepared?.avItem === avItem else { return }
        switch status {
        case .readyToPlay:
            isBuffering = false
            let d = avItem.duration.seconds
            if d.isFinite, d > 0 { duration = d }
            updateNowPlaying()
        case .failed:
            streamFailed(avItem.error as NSError?)
        default:
            break
        }
    }

    private func streamFailed(_ error: NSError?) {
        guard let entry = currentEntry else { return }
        let described = error?.localizedDescription ?? "The stream stopped"
        Self.log.error("stream failed \(entry.item.Id, privacy: .public): \(described, privacy: .private)")
        failedToOpen(entry, error: APIError.message(described))
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard isActive else { return }
        switch status {
        case .playing:
            isPlaying = true
            isBuffering = false
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
        case .paused:
            isPlaying = false
        @unknown default:
            break
        }
        updateNowPlayingRateIfChanged()
    }

    private func tick(_ time: CMTime) {
        guard isActive, let avItem = currentPrepared?.avItem, player.currentItem === avItem else { return }
        position = time.seconds.isFinite ? max(0, time.seconds) : 0
        // Played, not jumped to: a seek moves the clock further than one tick.
        if let last = lastTickPosition, isPlaying {
            let step = position - last
            if step > 0, step < 2 { heardSeconds += step }
        }
        lastTickPosition = position
        let d = avItem.duration.seconds
        if d.isFinite, d > 0 { duration = d }
        let now = Date()
        // Only when the lock screen's own clock has gone wrong — a seek, a
        // stall, a duration that settled late. It used to be re-posted once a
        // second, a cross-process write from the main actor, to say what the
        // system had already worked out. Pauses, speed and track changes post
        // the whole card themselves (see `updateNowPlaying`).
        let rate = isPlaying ? speed : 0
        let isStale: Bool = {
            guard let anchor = nowPlayingAnchor else { return true }
            let expected = anchor.position + rate * now.timeIntervalSince(anchor.at)
            return abs(expected - position) > 1.5 || abs(anchor.duration - duration) > 1
        }()
        if isStale {
            nowPlayingAnchor = (position, now, duration)
            updateNowPlayingElapsed()
        }
        if now.timeIntervalSince(lastReportAt) >= Self.reportInterval {
            lastReportAt = now
            Task { await reportNow() }
        }
    }

    // MARK: - Reporting

    private func report(paused: Bool, position override: Double? = nil) -> PlaybackReport {
        PlaybackReport(
            itemId: currentPrepared?.item.Id ?? current?.Id ?? "",
            mediaSourceId: currentPrepared?.source?.mediaSourceId,
            playSessionId: currentPrepared?.source?.playSessionId,
            positionSeconds: override ?? position,
            isPaused: paused,
            isTranscode: isTranscoding,
            rate: speed,
            volume: 1
        )
    }

    /// The stopped report for what is playing now, or nil when nothing is
    /// owed — a local file, or nothing at all.
    ///
    /// A downloaded file is reported too, the same as a streamed one: the
    /// server is what keeps play counts and "recently played", and a song
    /// heard from the device's own copy was still heard. The record on disk
    /// is told as well, which is what carries an audiobook's position across
    /// a stretch with no server — see `OfflineProgress`.
    private func closingReport(position override: Double? = nil) -> PlaybackReport? {
        // The track being closed, not whatever `currentIndex` was moved to
        // before this was called: a jump in the queue used to report the
        // song jumped *to* as stopped at the old one's position.
        guard let item = currentPrepared?.item else { return nil }
        if isLocal {
            #if !os(tvOS)
            // Position matters for a book; a song counts as played only once
            // it got most of the way — the same 92% the record itself uses.
            let at = override ?? position
            let heard = duration > 0 && at / duration > 0.92
            DownloadManager.shared.noteProgress(
                itemId: item.Id, positionSeconds: item.isAudiobook ? at : 0,
                played: item.isAudiobook || !heard ? nil : true
            )
            #endif
        }
        return report(paused: true, position: override)
    }

    private func reportNow() async {
        guard isActive, current != nil else { return }
        if isLocal {
            #if !os(tvOS)
            if let item = current, item.isAudiobook {
                DownloadManager.shared.noteProgress(itemId: item.Id, positionSeconds: position)
            }
            #endif
            // With no server in reach the report simply fails; the record
            // above is what survives that.
            guard !client.isOffline else { return }
        }
        lastReportAt = Date()
        await client.reportPlaybackProgress(report(paused: !isPlaying))
    }

    // MARK: - Audio session

    private func activateSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        try? session.setActive(true)
        #endif
    }

    private func observeAudioSession() {
        #if os(iOS) || os(tvOS)
        let centre = NotificationCenter.default
        centre.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                switch type {
                case .began:
                    // Judged by intent, not `isPlaying`, which the player's
                    // own pause may already have cleared.
                    self.interruptedWhilePlaying = !self.userPaused && !self.reachedEndOfQueue
                        && self.currentPrepared != nil
                    self.isPlaying = false
                    self.updateNowPlaying()
                case .ended:
                    let wasPlaying = self.interruptedWhilePlaying
                    self.interruptedWhilePlaying = false
                    if options.contains(.shouldResume), wasPlaying, !self.userPaused { self.resume() }
                @unknown default:
                    break
                }
            }
        }
        centre.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable else { return }
            // Headphones pulled out: the speaker must not take over mid-song.
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif
    }

    /// ReplayGain, as the server measured it, applied as a plain level. Only
    /// ever turns a track *down*: a positive gain would need headroom this
    /// player doesn't have.
    private func applyGain(for item: BaseItem?) {
        guard prefs.normalizeVolume, let gain = item?.NormalizationGain, gain < 0 else {
            player.volume = 1
            return
        }
        player.volume = Float(max(0.2, pow(10, gain / 20)))
    }

    // MARK: - The lock screen

    private func updateNowPlaying() {
        guard isActive, let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        let artist = item.artistLine
        if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.Album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let i = currentIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = i
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        if let chapter = currentChapter?.Name, !chapter.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = chapter
        }
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           artworkFor == artworkURL {
            info[MPMediaItemPropertyArtwork] = existing
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        lastNowPlayingRate = isPlaying ? speed : 0
        nowPlayingAnchor = (position, Date(), duration)
        if artworkFor != artworkURL {
            artworkFor = artworkURL
            loadArtwork(artworkURL)
        }
        NowPlaying.shared.refreshCommandAvailability()
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            updateNowPlaying()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingRateIfChanged() {
        let rate = isPlaying ? speed : 0
        guard rate != lastNowPlayingRate else { return }
        updateNowPlaying()
    }

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task {
            guard let image = await ImageLoader.shared.load(url), !Task.isCancelled, artworkFor == url else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func clearNowPlaying() {
        artworkTask?.cancel()
        artworkFor = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

// MARK: - Artwork

/// Where a song's, an album's or an artist's picture comes from.
///
/// A song usually has no picture of its own: its cover is the album's, and
/// the server says so by putting the album's tag on the song rather than by
/// giving the song a tag. `Artwork.url` would ask for the song's own image and
/// get a 404.
enum MusicArt {
    static func url(_ item: BaseItem, width: Int = 400) -> URL? {
        // A downloaded song carries its cover as a file on this device — see
        // `DownloadRecord.asItem` — and that wins over anything the server
        // could be asked for, which offline is nothing.
        if let raw = item.ExternalLogoURL, let local = URL(string: raw) { return local }
        if let own = item.ImageTags?["Primary"], !own.isEmpty {
            return Artwork.url(item, type: "Primary", width: width)
        }
        // A song's cover is its album's; so is a station seed's that was
        // built from a song — see `ListenNowView.stations`.
        if let albumId = item.AlbumId, let tag = item.AlbumPrimaryImageTag, !tag.isEmpty,
           let server = Preferences.shared.session?.server {
            let q = [
                URLQueryItem(name: "maxWidth", value: String(width)),
                URLQueryItem(name: "tag", value: tag),
                URLQueryItem(name: "quality", value: "90"),
            ]
            return URL(string: "\(server)/Items/\(JellyfinClient.pathId(albumId))/Images/Primary?\(JellyfinClient.encode(q))")
        }
        if item.isSong || item.isAudiobook { return nil }
        return Artwork.url(item, type: "Primary", width: width)
    }

    static func hash(_ item: BaseItem) -> String? {
        if let tag = item.ImageTags?["Primary"] ?? item.AlbumPrimaryImageTag,
           let hash = item.ImageBlurHashes?["Primary"]?[tag], hash.count > 5 {
            return hash
        }
        return nil
    }

    /// An artist's wide picture, for the top of their page.
    static func backdrop(_ item: BaseItem, width: Int = 1200) -> URL? {
        Artwork.url(item, type: "Backdrop", width: width)
    }
}
