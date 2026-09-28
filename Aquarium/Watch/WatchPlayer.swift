//  The watch's player: a queue of songs or one book, and the thing that
//  plays them.
//
//  A cut-down cousin of the phone's `MusicPlayer`. One `AVPlayer`, advanced
//  by hand at the end of each item — a watch does not need gapless joins as
//  much as it needs to be simple — with the lock-screen card and the crown's
//  transport wired to the same controls the screen has. A downloaded item
//  plays from its file; anything else is streamed.
//
//  Listening is written two ways. The record on the watch is told where a
//  book was left, so it opens there with no network. And `WatchSyncQueue` is
//  given an event for the server — a position for a book, a play for a song
//  heard to its end — which goes by way of the phone when it is in reach.

import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Observation
import WidgetKit
import os

@MainActor
@Observable
final class WatchPlayer: NSObject {
    static let shared = WatchPlayer()

    nonisolated static let log = Logger(subsystem: "scottai.FellyJin.watchkitapp", category: "player")

    struct Entry: Identifiable, Hashable, Sendable {
        let id: UUID
        var item: BaseItem
        init(_ item: BaseItem) { id = UUID(); self.item = item }
        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: State

    private(set) var queue: [Entry] = []
    private(set) var currentIndex: Int?
    private(set) var isActive = false
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    private(set) var isLocal = false
    private(set) var isTranscoding = false
    private(set) var queueTitle: String?
    private(set) var chapters: [ChapterInfo] = []
    private(set) var isShuffled = false
    /// Bumped by every `play`, so the shell can bring the player page up.
    private(set) var playRequests = 0

    /// Playback rate. Kept at 1 for music and remembered for books.
    var speed: Double = 1 {
        didSet {
            guard speed != oldValue else { return }
            if isPlaying { player.rate = Float(speed) }
            if current?.isAudiobook == true { UserDefaults.standard.set(speed, forKey: "watch_book_speed") }
            updateNowPlaying()
        }
    }
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var current: BaseItem? { currentEntry?.item }
    var currentEntry: Entry? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }
    var hasNext: Bool { (currentIndex ?? 0) + 1 < queue.count }
    var hasPrevious: Bool { (currentIndex ?? 0) > 0 || position > 3 }
    var upNextCount: Int { max(0, queue.count - ((currentIndex ?? -1) + 1)) }

    var currentChapter: ChapterInfo? {
        chapters.last { $0.startSeconds <= position + 0.5 }
    }

    // MARK: Internals

    let player = AVPlayer()
    private var stream: WatchStream?
    private var generation = 0
    private var timeObserver: Any?
    private var observers: Set<AnyCancellable> = []
    private var endObserver: NSObjectProtocol?
    private var lastReportAt = Date.distantPast
    private var lastLocalNoteAt = Date.distantPast
    private var lastEventAt = Date.distantPast
    private var artworkTask: Task<Void, Never>?
    private var artworkFor: URL?
    private var snapshotTask: Task<Void, Never>?
    private var userPaused = false
    private var startedReport = false
    /// Whether `position` is where the item really is: false from opening
    /// until the seek to the resume point has landed. Until then nothing is
    /// written down — a pause while the route picker is up would otherwise
    /// save a book's place as 0:00.
    private var positionKnown = false

    private var client: JellyfinClient { .shared }
    private var downloads: WatchDownloads { .shared }

    private override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in self?.timeControlChanged(status) }
            }
            .store(in: &observers)
        wireRemoteCommands()
        observeInterruptions()
    }

    // MARK: - Starting

    /// Play these, from `index`, replacing the queue. `position` opens the
    /// first at a point — a chapter — instead of where it was left.
    func play(_ items: [BaseItem], startingAt index: Int = 0, shuffle: Bool = false, title: String? = nil, at position: Double? = nil) {
        let playable = items.filter(\.isAudio)
        guard !playable.isEmpty else { return }
        var entries = playable.map(Entry.init)
        var start = min(max(0, index), entries.count - 1)
        isShuffled = false
        if shuffle {
            let chosen = entries.remove(at: start)
            entries.shuffle()
            entries.insert(chosen, at: 0)
            start = 0
            isShuffled = true
        }
        closeCurrent(finished: false)
        queue = entries
        currentIndex = start
        queueTitle = title
        playRequests &+= 1
        startCurrent(startAt: position)
    }

    func playLater(_ items: [BaseItem]) {
        let entries = items.filter(\.isAudio).map(Entry.init)
        guard !entries.isEmpty else { return }
        if !isActive { return play(items) }
        queue.append(contentsOf: entries)
    }

    func skip(to entry: Entry) {
        guard let i = queue.firstIndex(of: entry) else { return }
        closeCurrent(finished: false)
        currentIndex = i
        startCurrent()
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        userPaused = true
        player.pause()
        isPlaying = false
        note(finished: false)
        updateNowPlaying()
        Task { await reportLive(started: false) }
    }

    func resume() {
        guard isActive else { return }
        userPaused = false
        Task {
            guard await activateSession() else { return }
            player.playImmediately(atRate: Float(speed))
            isPlaying = true
            updateNowPlaying()
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func skipNext() {
        guard let i = currentIndex else { return }
        guard i + 1 < queue.count else {
            // The end of the queue: stop where we are.
            stop()
            return
        }
        closeCurrent(finished: false)
        currentIndex = i + 1
        startCurrent()
    }

    func skipPrevious() {
        guard let i = currentIndex else { return }
        if position > 3 || i == 0 {
            seek(to: 0)
            return
        }
        closeCurrent(finished: false)
        currentIndex = i - 1
        startCurrent()
    }

    func skipChapter(_ direction: Int) {
        guard !chapters.isEmpty else { return seek(by: direction > 0 ? 30 : -15) }
        if direction > 0 {
            if let next = chapters.first(where: { $0.startSeconds > position + 1 }) { seek(to: next.startSeconds) } else { skipNext() }
        } else {
            let current = currentChapter
            if let current, position - current.startSeconds > 3 {
                seek(to: current.startSeconds)
            } else if let current, let i = chapters.firstIndex(of: current), i > 0 {
                seek(to: chapters[i - 1].startSeconds)
            } else {
                seek(to: 0)
            }
        }
    }

    func stepSpeed(_ direction: Int) {
        let i = Self.speeds.firstIndex(of: speed) ?? 1
        let next = min(max(0, i + direction), Self.speeds.count - 1)
        speed = Self.speeds[next]
    }

    func stop() {
        closeCurrent(finished: false)
        generation &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        teardownItemObservers()
        queue = []
        currentIndex = nil
        isActive = false
        isPlaying = false
        isBuffering = false
        position = 0
        duration = 0
        chapters = []
        stream = nil
        clearNowPlaying()
        writeSnapshot()
    }

    // MARK: - Opening

    private func startCurrent(startAt: Double? = nil) {
        guard let entry = currentEntry else { return stop() }
        generation &+= 1
        let mine = generation
        player.pause()
        player.replaceCurrentItem(with: nil)
        teardownItemObservers()
        let old = stream
        stream = nil
        startedReport = false
        positionKnown = false

        WatchLog.note("player", "opening \(entry.item.Id) \"\(entry.item.title)\" \(entry.item.isAudiobook ? "book" : "song") at \(Int(startAt ?? 0))s, queue \(queue.count), \(WatchLog.memory)")
        isActive = true
        isBuffering = true
        isPlaying = false
        errorMessage = nil
        position = startAt ?? 0
        duration = entry.item.runtimeSeconds
        chapters = entry.item.Chapters ?? downloads.record(for: entry.item.Id)?.chapters ?? []
        speed = entry.item.isAudiobook ? (UserDefaults.standard.object(forKey: "watch_book_speed") as? Double ?? 1) : 1
        updateNowPlaying()
        writeSnapshot()

        if let old, old.isTranscode { Task { await client.stopTranscode(playSessionId: old.playSessionId) } }

        Task {
            guard await activateSession() else {
                guard generation == mine else { return }
                errorMessage = "Choose where to play, then try again"
                isBuffering = false
                return
            }
            let avItem: AVPlayerItem
            if let record = downloads.record(for: entry.item.Id), let url = downloads.mediaURL(for: record) {
                avItem = AVPlayerItem(url: url)
                isLocal = true
                isTranscoding = false
            } else {
                do {
                    let src = try await client.stream(for: entry.item)
                    guard generation == mine else {
                        if src.isTranscode { await client.stopTranscode(playSessionId: src.playSessionId) }
                        return
                    }
                    let asset = AVURLAsset(url: src.url, options: src.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": src.headers])
                    avItem = AVPlayerItem(asset: asset)
                    avItem.preferredForwardBufferDuration = 20
                    stream = src
                    isLocal = false
                    isTranscoding = src.isTranscode
                } catch {
                    guard generation == mine else { return }
                    failedToOpen(error)
                    return
                }
            }
            guard generation == mine else { return }
            // A book opens where it was last left anywhere: the server is
            // asked first, briefly, and the record takes its word unless
            // the watch has newer listening of its own.
            var opening = entry.item
            if startAt == nil, opening.isAudiobook,
               let fresh = await WatchActions.refreshBookPositions(ids: [opening.Id], timeout: .seconds(2.5)).first {
                guard generation == mine else { return }
                opening.UserData = fresh.UserData
            }
            let resumeAt = resumePoint(for: opening, explicit: startAt)
            install(avItem, startAt: resumeAt)
            // A book's chapters come with the full item; a list row hasn't got them.
            if entry.item.isAudiobook, chapters.isEmpty, !client.isOffline, let full = try? await client.item(entry.item.Id) {
                guard generation == mine else { return }
                chapters = full.Chapters ?? []
                if let i = currentIndex, queue.indices.contains(i) { queue[i].item = full }
            }
        }
    }

    /// A book with a record opens from the record: it has the watch's own
    /// listening, and the server's whenever that is newer, brought in just
    /// before. The item handed in may be a list row loaded an hour ago.
    private func resumePoint(for item: BaseItem, explicit: Double?) -> Double {
        if let explicit { return max(0, explicit) }
        guard item.isAudiobook else { return 0 }
        if let record = downloads.record(for: item.Id) { return record.resumeSeconds }
        let ticks = item.userData.positionTicks
        guard ticks > 0, !item.userData.played, let total = item.RunTimeTicks, total > 0 else { return 0 }
        return BookProgress.isFinished(positionTicks: ticks, runTimeTicks: total) ? 0 : Double(ticks) / 10_000_000
    }

    /// Put the item in and start it once it is at `startAt`. Playing before
    /// the seek lands plays a moment of the top, and reports it as where
    /// the book is.
    private func install(_ avItem: AVPlayerItem, startAt: Double) {
        player.replaceCurrentItem(with: avItem)
        installItemObservers(on: avItem)
        position = max(0, startAt)
        isPlaying = true
        userPaused = false
        updateNowPlaying()
        let mine = generation
        guard startAt > 0.5 else { return begin(mine) }
        // A seek that says when it's done throws if the item isn't ready.
        Task {
            while avItem.status == .unknown {
                guard generation == mine else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard generation == mine, avItem.status == .readyToPlay else { return }
            _ = await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            begin(mine)
        }
    }

    private func begin(_ mine: Int) {
        guard generation == mine else { return }
        positionKnown = true
        guard !userPaused else { return }
        player.playImmediately(atRate: Float(speed))
        Task { await reportLive(started: true) }
    }

    private func failedToOpen(_ error: Error) {
        isBuffering = false
        isPlaying = false
        errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        WatchLog.error("player", "open failed: \(self.errorMessage ?? "")")
        updateNowPlaying()
    }

    // MARK: - Following the player

    private func installItemObservers(on avItem: AVPlayerItem) {
        avItem.publisher(for: \.status)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.player.currentItem === avItem else { return }
                    if status == .failed {
                        self.failedToOpen(avItem.error ?? APIError.message("This couldn't be played"))
                    } else if status == .readyToPlay {
                        let d = avItem.duration.seconds
                        if d.isFinite, d > 0 { self.duration = d }
                    }
                }
            }
            .store(in: &observers)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.itemEnded() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }
    }

    private func teardownItemObservers() {
        observers.removeAll()
        // The player's own status stream stays.
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in self?.timeControlChanged(status) }
            }
            .store(in: &observers)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard isActive else { return }
        switch status {
        case .playing:
            isBuffering = false
            isPlaying = true
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
        case .paused:
            isBuffering = false
            if !userPaused, player.currentItem != nil, player.currentItem?.status == .readyToPlay {
                // Paused by the system — headphones off, a route gone.
                isPlaying = false
            }
        @unknown default:
            break
        }
        updateNowPlayingRate()
    }

    private func tick(_ seconds: Double) {
        guard isActive, positionKnown, seconds.isFinite else { return }
        position = seconds
        let now = Date()
        if isPlaying, now.timeIntervalSince(lastReportAt) >= 10 {
            lastReportAt = now
            Task { await reportLive(started: false) }
        }
        if let item = current, item.isAudiobook, isPlaying {
            if now.timeIntervalSince(lastLocalNoteAt) >= 5 {
                lastLocalNoteAt = now
                downloads.noteProgress(itemId: item.Id, positionSeconds: seconds)
                writeSnapshot()
            }
            if now.timeIntervalSince(lastEventAt) >= 60 {
                lastEventAt = now
                note(finished: false, periodic: true)
            }
        }
    }

    private func itemEnded() {
        guard isActive else { return }
        closeCurrent(finished: true)
        if let i = currentIndex, i + 1 < queue.count {
            currentIndex = i + 1
            startCurrent()
        } else {
            stop()
        }
    }

    // MARK: - Telling

    /// The item on its way out: the record and the queue are told how far it
    /// got, and whether it counts as heard.
    private func closeCurrent(finished: Bool) {
        guard isActive, current != nil, positionKnown || finished else { return }
        note(finished: finished)
        if stream != nil {
            let s = stream
            let report = (current?.Id ?? "", Int64(position * 10_000_000))
            Task { [client] in
                _ = try? await client.reportStopped(itemId: report.0, positionTicks: report.1, mediaSourceId: s?.mediaSourceId, playSessionId: s?.playSessionId)
            }
        }
    }

    /// Where a book is now, for the server, while it plays on: the app
    /// going to the background may be the last chance.
    func checkpoint() {
        guard isActive, isPlaying, current?.isAudiobook == true else { return }
        note(finished: false, periodic: true)
    }

    /// One event for the server, and the local note. A song counts as heard
    /// when it played to its end or nearly. A book is a position until it is
    /// done by the server's own rule — under five minutes left — and the
    /// once-a-minute note is only ever a position: the server makes a
    /// position that close to the end "played" by itself.
    private func note(finished: Bool, periodic: Bool = false) {
        guard let item = current, positionKnown || finished else { return }
        let total = duration > 0 ? duration : item.runtimeSeconds
        let at = finished ? total : position
        let ticks = Int64(max(0, at) * 10_000_000)
        if item.isAudiobook {
            let heard = finished || (!periodic && BookProgress.isFinished(position: at, duration: total))
            downloads.noteProgress(itemId: item.Id, positionSeconds: at, played: heard ? true : nil)
            WatchSyncQueue.shared.add(WatchProgressEvent(
                itemId: item.Id, positionTicks: heard ? Int64(total * 10_000_000) : ticks,
                played: heard, isAudiobook: true, streamed: stream != nil
            ))
        } else if finished || (total > 0 && at / total > 0.9) {
            downloads.noteProgress(itemId: item.Id, positionSeconds: 0, played: true)
            WatchSyncQueue.shared.add(WatchProgressEvent(
                itemId: item.Id, positionTicks: Int64(total * 10_000_000),
                played: true, isAudiobook: false, streamed: stream != nil
            ))
        }
        lastEventAt = Date()
        writeSnapshot()
    }

    /// The live session, for a stream: the server's dashboard, and the
    /// transcode kept alive.
    private func reportLive(started: Bool) async {
        guard let item = current, let stream else { return }
        if started { startedReport = true } else if !startedReport { return }
        await client.reportPlaying(
            started: started, itemId: item.Id, positionTicks: Int64(position * 10_000_000),
            paused: !isPlaying, stream: stream, rate: speed
        )
    }

    // MARK: - Audio session

    /// watchOS wants long-form audio activated with a route to play to, and
    /// asks the person to pick one when there isn't.
    private func activateSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            return try await session.activate(options: [])
        } catch {
            WatchLog.error("player", "audio session: \(error.localizedDescription)")
            return false
        }
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                switch type {
                case .began:
                    self.isPlaying = false
                    self.updateNowPlaying()
                case .ended:
                    if options.contains(.shouldResume), !self.userPaused { self.resume() }
                @unknown default: break
                }
            }
        }
    }

    // MARK: - The lock screen and the crown

    private func wireRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        centre.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        centre.nextTrackCommand.addTarget { [weak self] _ in self?.skipNext(); return .success }
        centre.previousTrackCommand.addTarget { [weak self] _ in self?.skipPrevious(); return .success }
        centre.skipForwardCommand.preferredIntervals = [30]
        centre.skipBackwardCommand.preferredIntervals = [15]
        centre.skipForwardCommand.addTarget { [weak self] event in
            self?.seek(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? 30); return .success
        }
        centre.skipBackwardCommand.addTarget { [weak self] event in
            self?.seek(by: -((event as? MPSkipIntervalCommandEvent)?.interval ?? 15)); return .success
        }
        centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
        centre.changePlaybackRateCommand.supportedPlaybackRates = Self.speeds.map { NSNumber(value: $0) }
        centre.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.speed = Double(e.playbackRate); return .success
        }
        refreshCommands()
    }

    private func refreshCommands() {
        let centre = MPRemoteCommandCenter.shared()
        let book = current?.isAudiobook == true
        centre.nextTrackCommand.isEnabled = !book && hasNext
        centre.previousTrackCommand.isEnabled = !book
        centre.skipForwardCommand.isEnabled = book
        centre.skipBackwardCommand.isEnabled = book
        centre.changePlaybackRateCommand.isEnabled = book
    }

    private func updateNowPlaying() {
        guard isActive, let item = current else { return }
        refreshCommands()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        let artist = item.artistLine
        if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.Album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if let chapter = currentChapter?.Name, !chapter.isEmpty { info[MPMediaItemPropertyAlbumTitle] = chapter }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let i = currentIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = i
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        let art = artworkURL
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork], artworkFor == art {
            info[MPMediaItemPropertyArtwork] = existing
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        if artworkFor != art {
            artworkFor = art
            loadArtwork(art)
        }
    }

    private func updateNowPlayingRate() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return updateNowPlaying() }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        writeSnapshot()
    }

    var artworkURL: URL? { current.flatMap { WatchImages.url(for: $0, width: 320) } }

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task {
            guard let image = await WatchImages.shared.load(url), !Task.isCancelled, artworkFor == url else { return }
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

    // MARK: - The Smart Stack

    /// What the widget shows: this, while something is up; the book most
    /// recently left otherwise. Written a moment after the last change.
    func writeSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            let snapshot: ListeningSnapshot?
            if isActive, let item = current {
                snapshot = ListeningSnapshot(
                    itemId: item.Id, title: item.title,
                    subtitle: item.isAudiobook ? (currentChapter?.Name ?? item.artistLine) : item.artistLine,
                    isAudiobook: item.isAudiobook, isPlaying: isPlaying,
                    position: position, duration: duration > 0 ? duration : item.runtimeSeconds
                )
            } else if let book = downloads.booksInProgress.first {
                snapshot = ListeningSnapshot(
                    itemId: book.itemId, title: book.name, subtitle: book.artist ?? "",
                    isAudiobook: true, isPlaying: false,
                    position: Double(book.positionTicks) / 10_000_000, duration: Double(book.runTimeTicks) / 10_000_000
                )
            } else {
                snapshot = nil
            }
            ListeningSnapshot.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
