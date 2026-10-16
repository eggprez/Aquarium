//  AVPlayer, behind `PlaybackEngine`.
//
//  What AVFoundation gives back for free is everything mpv never could on a
//  phone: Picture in Picture, AirPlay, SharePlay, the sound carrying on in the
//  background, and hardware decode straight into the system compositor with
//  no shader pass. What it cannot do is open Matroska, decode DTS or TrueHD,
//  draw a picture subtitle, or move the sound against the picture on anything
//  but a file it was handed whole — and `capabilities` says so.
//
//  This file is the AVPlayer-shaped two thirds of what used to be
//  `PlayerModel`: installing an item and its observers, holding playback back
//  until a start position has been reached, the hand-over that puts a new
//  transcode on screen without the old one going black, the composition that
//  shifts the audio of a file, media selection, and the classification of
//  AVFoundation's failures into "ask for the stream again" and "this won't
//  play". Everything it decides is reported through `events`; everything it
//  is told is a command on the protocol. What any of it means for Jellyfin
//  stays in the model.

import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class AVEngine: PlaybackEngine {
    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "avengine")

    let kind: PlaybackEngineKind = .apple

    let capabilities: EngineCapabilities = [
        .pictureInPicture, .airPlay, .sharePlay, .backgroundAudio, .handOver, .liveEdge,
    ]

    /// The ISO base-media family and QuickTime, over HTTP.
    let directContainers: Set<String> = ["mp4", "m4v", "mov", "3gp", "3g2"]

    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    /// The player itself, for the AVKit surfaces that draw it and for the
    /// SharePlay coordinator. Nothing else outside this file should touch it.
    let player = AVPlayer()
    private var playerItem: AVPlayerItem?
    /// The asset the current stream came from, before any composition was
    /// built on top of it. The track lists and the chapters are read from
    /// this: a composition carries no media selection groups of its own.
    private var sourceAsset: AVAsset?
    private var currentURL: URL?
    private var loadedLive = false
    private var hints: [EngineTrackHint] = []
    /// The tracks the composition in the player was built around, by engine
    /// id; nil when the item is not a composition.
    private var composed: (audio: Int?, subtitle: Int?)?

    /// Where the current stream has to be taken to once its asset is ready to
    /// be seeked; nil once that's done, or when it started from the top.
    ///
    /// While this is set the rate is deliberately zero and nothing reads that
    /// as a pause: it covers the whole window from `install` until the seek
    /// lands, because the seek itself is the slow part — a transcode has to
    /// be encoding at the offset before it can answer.
    private var pendingSeek: Double?
    private var holding: Bool { pendingSeek != nil }
    /// Whether playback should run once the hold releases: the model's own
    /// intent, as distinct from the player's state.
    private var wantsPlay = true
    private var wantedRate: Double = 1
    private var hadFirstFrame = false
    /// Gives up on a seek that is never going to be answered and plays anyway.
    private var seekWatchdog: Task<Void, Never>?
    /// See `watchForPicture`.
    private var pictureWatchdog: Task<Void, Never>?

    private var timeObserver: Any?
    private var statusObservers: Set<AnyCancellable> = []
    /// Lives as long as the engine does, unlike `statusObservers`, which is
    /// torn down and rebuilt around every item.
    private var speedObserver: Set<AnyCancellable> = []
    private var endObserver: NSObjectProtocol?
    private var failedEndObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var accessLogObserver: NSObjectProtocol?
    /// The variant bitrate last seen on this item, and when variant changes
    /// start to count: every stream feels its way up in its first seconds, and
    /// that is the stream opening, not the connection changing.
    private var lastVariantBitrate: Double?
    private var variantChangesCountFrom = Date.distantFuture
    private var lastReportedDuration: Double?
    private var lastReportedPaused: Bool?
    private var reportedBuffering = false
    private var droppedFramesSampledAt = Date.distantPast

    /// Bumped by every load, stop and quiesce, so work that resumes after an
    /// await — a composition being built, a hand-over waiting on a playlist
    /// — never lands on the stream that replaced the one it was started for.
    private var loadGeneration = 0

    private(set) var tracks: [EngineTrack] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        player.allowsExternalPlayback = true
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        player.defaultRate = Float(wantedRate)
        // Speed is chosen in AVKit's own control, which reports the choice
        // by way of `defaultRate`. Reported up so the model stays the one
        // place that knows the speed.
        player.publisher(for: \.defaultRate)
            .map(Double.init)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                MainActor.assumeIsolated {
                    guard let self, rate > 0, abs(rate - self.wantedRate) > 0.001 else { return }
                    self.wantedRate = rate
                    self.deliver(.rate(rate))
                }
            }
            .store(in: &speedObserver)
    }

    func shutdown() {
        stop()
        speedObserver.removeAll()
        continuation.finish()
    }

    // MARK: - Streams

    func load(_ request: EngineLoadRequest) {
        loadGeneration &+= 1
        let mine = loadGeneration
        currentURL = request.url
        loadedLive = request.live
        hints = request.hints
        hadFirstFrame = false
        // A stored offset is built into the stream as it opens rather than
        // applied to it a moment later, so nothing is ever handed to the
        // player at the wrong offset first.
        let delay = audioDelay
        guard delay != 0 else {
            attachPlainly(request)
            return
        }
        Task {
            let built = await Self.makeDelayedItem(
                url: request.url, headers: request.headers, delay: delay,
                audioIndex: request.audioTrack, subtitleIndex: request.subtitleTrack
            )
            guard loadGeneration == mine else { return }
            guard let built else {
                // This file won't compose — an audio track AVFoundation won't
                // hand over, a duration it can't read. It plays in step
                // rather than not at all, and the model is told so.
                attachPlainly(request, refusedDelay: true)
                return
            }
            sourceAsset = built.source
            composed = (built.audio, built.subtitle)
            install(built.item, startAt: request.startAt, paused: request.paused)
            deliver(.audioDelayApplied(delay, refused: false))
        }
    }

    private func attachPlainly(_ request: EngineLoadRequest, refusedDelay: Bool = false) {
        // An asset `prepare` already has reading its playlist is used as it
        // is; anything else is built here.
        let asset: AVURLAsset
        if let prepared = request.prepared as? AVPreparedStream, prepared.url == request.url {
            asset = prepared.asset
        } else {
            asset = AVURLAsset(url: request.url, options: Self.assetOptions(request.headers))
        }
        sourceAsset = asset
        composed = nil
        install(AVPlayerItem(asset: asset), startAt: request.startAt, paused: request.paused)
        deliver(.audioDelayApplied(0, refused: refusedDelay))
    }

    private static func assetOptions(_ headers: [String: String]) -> [String: Any] {
        headers.isEmpty
            ? [:]
            // Jellyfin's own transcode URLs carry their key, but a direct-play
            // URL is built by the model and deliberately doesn't — the token
            // rides the request instead, so it stays out of the server's
            // access log.
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    }

    /// Put a prepared item into the player.
    private func install(_ newItem: AVPlayerItem, startAt: Double, paused: Bool) {
        teardownObservers()
        seekWatchdog?.cancel()
        seekWatchdog = nil
        // The sound carries on when the screen locks or the app goes behind
        // another — the thing the `audio` background mode is declared for.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Zero is not "don't buffer" — it is AVFoundation deciding for itself,
        // and it reads a long way further ahead than a ceiling would allow.
        // A deep buffer is what rides out both a bad minute of Wi-Fi and an
        // encoder that falls momentarily behind real time. Live gets the
        // same: how far behind the broadcast you are is decided by where you
        // join the playlist, not by how much is downloaded ahead.
        newItem.preferredForwardBufferDuration = 0
        // Left alone, AVPlayer joins a live stream at the edge and then,
        // after every rebuffer, resumes from where it stopped — so each stall
        // pushes the playhead further behind until it is behind the oldest
        // segment the server holds, which 404s. Preserving the offset makes
        // the player treat it as a target and quietly reclaim it after a
        // stall rather than banking the loss.
        if loadedLive {
            newItem.automaticallyPreservesTimeOffsetFromLive = true
            newItem.configuredTimeOffsetFromLive =
                CMTime(seconds: Self.liveOffsetFromLive, preferredTimescale: 1)
        }
        applySubtitleStyling(to: newItem)
        playerItem = newItem
        player.replaceCurrentItem(with: newItem)
        player.volume = Float(volume)
        player.isMuted = isMuted
        tracks = []
        lastReportedDuration = nil
        lastReportedPaused = nil
        reportedBuffering = false
        droppedFramesSampledAt = .distantPast

        // The seek can't be made yet. An HLS asset has no seekable range until
        // its playlist has been fetched, and a seek issued before then is
        // dropped without a word — the stream just plays from its first
        // segment. It's held here and made in `applyPendingSeek` once the
        // item is ready, with playback held back until then so the opening
        // seconds never flash up before the jump.
        pendingSeek = startAt > 1 ? startAt : nil
        wantsPlay = !paused
        installObservers(on: newItem)
        if pendingSeek == nil {
            if wantsPlay { startPlaying() } else { player.rate = 0 }
        } else {
            // Explicitly, rather than by leaving the rate alone: the rate the
            // last stream was playing at carries over to the new item, and
            // the opening seconds would play under the hold.
            player.rate = 0
        }
    }

    /// How far behind the live edge a channel is asked to sit, in seconds:
    /// enough to absorb a segment that arrives late without being long
    /// enough for anyone to notice they are behind.
    private static let liveOffsetFromLive: Double = 20

    func stop() {
        loadGeneration &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        // And let go of the item and its asset, rather than holding them
        // until the next stream overwrites them: the socket closing is the
        // only signal a stream server gets that this client has gone.
        sourceAsset?.cancelLoading()
        sourceAsset = nil
        playerItem?.cancelPendingSeeks()
        playerItem = nil
        currentURL = nil
        composed = nil
        teardownObservers()
        pendingSeek = nil
        seekWatchdog?.cancel()
        seekWatchdog = nil
        tracks = []
    }

    /// Silence the item while its replacement is being asked for: paused, and
    /// with its observers gone, so it neither reports progress, nor ends, nor
    /// fails on behalf of whatever is opening. The item itself stays: its
    /// last frame is what is on screen under the loading card.
    func quiesce() {
        loadGeneration &+= 1
        teardownObservers()
        player.pause()
        pendingSeek = nil
        seekWatchdog?.cancel()
        seekWatchdog = nil
    }

    func prepare(url: URL, headers: [String: String]) -> (any PreparedStream)? {
        let asset = AVURLAsset(url: url, options: Self.assetOptions(headers))
        return AVPreparedStream(asset: asset)
    }

    // MARK: - Changing stream without losing the picture

    /// How long the whole hand-over may take before it is given up on.
    private static let handoverLimit: TimeInterval = 30

    /// Put a new stream on screen without taking the old one off it first.
    ///
    /// A quality change is not a seek. It is the same picture at a different
    /// bitrate, and the ideal is that nothing visible happens at all. What
    /// stops that being free is the server: Jellyfin starts a fresh ffmpeg at
    /// the offset and has to write enough segments to hand over, which takes
    /// seconds and often tens of them. So the replacement is prepared inside
    /// a player of its own that nothing is looking at, and swapped in when
    /// the old stream's own clock reaches the point the new one begins at.
    ///
    /// Returns whether the swap was made. `false` leaves everything exactly
    /// as it was — the old item is still installed and still playing.
    func handOver(to request: EngineLoadRequest, at target: Double) async -> Bool {
        let mine = loadGeneration
        let asset = AVURLAsset(url: request.url, options: Self.assetOptions(request.headers))
        let candidate = AVPlayerItem(asset: asset)
        candidate.preferredForwardBufferDuration = 0
        applySubtitleStyling(to: candidate)

        // Silent, and nothing is drawing it: this player exists only to make
        // AVFoundation fetch the playlist and fill a buffer, which an
        // `AVPlayerItem` will not do on its own.
        let preroll = AVPlayer()
        preroll.isMuted = true
        preroll.replaceCurrentItem(with: candidate)

        let deadline = Date().addingTimeInterval(Self.handoverLimit)
        var ok = true

        // Woken by the candidate itself — its status and its buffer — rather
        // than by asking it every 150 ms for up to half a minute. The slow
        // tick is the backstop for what no notification announces: the
        // deadline, and this hand-over being overtaken by another load.
        let (wakes, wakeUp) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let statusWatch = candidate.observe(\.status) { _, _ in wakeUp.yield() }
        let bufferWatch = candidate.observe(\.isPlaybackLikelyToKeepUp) { _, _ in wakeUp.yield() }
        let backstop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                wakeUp.yield()
            }
        }
        defer {
            statusWatch.invalidate()
            bufferWatch.invalidate()
            backstop.cancel()
            wakeUp.finish()
        }
        var wake = wakes.makeAsyncIterator()

        // 1. The playlist has to be readable before anything can be asked of it.
        while candidate.status == .unknown, Date() < deadline, ok {
            _ = await wake.next()
            ok = loadGeneration == mine
        }
        // 2. Move it to the point the swap will happen at and let it fill.
        if ok, candidate.status == .readyToPlay {
            let landed = await preroll.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
            ok = landed && loadGeneration == mine
            while ok, !candidate.isPlaybackLikelyToKeepUp, candidate.status == .readyToPlay,
                  Date() < deadline {
                _ = await wake.next()
                ok = loadGeneration == mine
            }
            ok = ok && candidate.isPlaybackLikelyToKeepUp
        } else {
            ok = false
        }
        // 3. Wait for the picture to reach where the new stream starts. Paused,
        //    it never will, and the swap is worth making immediately instead.
        while ok, transport != .paused, (clock ?? 0) < target - 0.2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            ok = loadGeneration == mine
        }

        preroll.replaceCurrentItem(with: nil)
        guard ok, loadGeneration == mine else { return false }

        // 4. The swap. Landing where the picture actually is rather than where
        //    it was expected to be: if step three ran out of time, the playhead
        //    is past the point this stream was opened at, and the seek below is
        //    still inside what has been fetched. Short of the target — paused,
        //    sought back, or out of time — it lands where the picture is, not
        //    ahead of it.
        let position = clock ?? 0
        let landing = position >= target - 0.2 ? max(target, position) : position
        let wasPaused = transport == .paused
        loadGeneration &+= 1
        currentURL = request.url
        loadedLive = request.live
        hints = request.hints
        hadFirstFrame = false
        sourceAsset = asset
        composed = nil

        // A *new* item off the same asset, rather than the one that was
        // prerolled. "An AVPlayerItem cannot be associated with more than one
        // instance of AVPlayer" is an `NSInvalidArgumentException` thrown
        // straight through Swift, and `replaceCurrentItem(with: nil)` on the
        // preroll takes effect asynchronously, so the prerolled item is still
        // its when the next line would claim it. Building a second item costs
        // the swap a second of buffering and keeps everything the wait was
        // for: by now the server is ready, the playlist is fetched, and the
        // asset it is fetched into is this same one.
        let live = AVPlayerItem(asset: asset)
        live.preferredForwardBufferDuration = 0
        install(live, startAt: landing, paused: wasPaused)
        deliver(.audioDelayApplied(0, refused: false))
        return true
    }

    // MARK: - A manual audio offset
    //
    // There is no audio-delay control on AVPlayer, so the shift is made by
    // rebuilding the item as an `AVMutableComposition` with the audio track
    // inserted at a different time from the video. A composition is built
    // out of `AVAssetTrack`s, and an HLS asset has none — so the offset
    // reaches a direct play and a download, and cannot reach a transcode or
    // a live channel. `capabilities` says as much by leaving
    // `.audioDelayOnAnyStream` out.

    /// Seconds; positive plays the sound later than the picture. Read by the
    /// next `load`, which builds it in where it can.
    var audioDelay: Double = 0

    /// The item that carries the offset, or nil if this asset can't produce one.
    ///
    /// At composition time `c` the picture is the source's picture at `c`,
    /// and the sound is wanted from source time `c - delay`. Asking for the
    /// sound *later* therefore means starting the audio track further into
    /// the timeline and leaving the opening silent; asking for it *earlier*
    /// means throwing away the front of the audio and starting what is left
    /// at the top.
    private static func makeDelayedItem(
        url: URL, headers: [String: String], delay: Double,
        audioIndex: Int?, subtitleIndex: Int?
    ) async -> (item: AVPlayerItem, source: AVAsset, audio: Int?, subtitle: Int?)? {
        let asset = AVURLAsset(url: url, options: assetOptions(headers))
        guard let duration = try? await asset.load(.duration), duration > .zero,
              let video = (try? await asset.loadTracks(withMediaType: .video))?.first
        else { return nil }

        let audios = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        // The track lists the menus show are built from the audible *selection
        // group*, and the group's options come back in the same order as the
        // file's audio tracks — so the engine id indexes this too. Out of
        // range falls back to the first rather than failing.
        let audio = audioIndex.flatMap { audios.indices.contains($0) ? audios[$0] : nil } ?? audios.first
        guard let audio else { return nil }
        let usedAudio = audios.firstIndex(of: audio)

        let shift = CMTime(seconds: abs(delay), preferredTimescale: 600)
        guard duration > shift else { return nil }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        let whole = CMTimeRange(start: .zero, duration: duration)
        do {
            try videoTrack.insertTimeRange(whole, of: video, at: .zero)
            if delay >= 0 {
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration - shift), of: audio, at: shift)
            } else {
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: shift, duration: duration - shift), of: audio, at: .zero)
            }
        } catch {
            return nil
        }

        // Subtitles ride with the picture rather than the sound. Only the
        // chosen one is carried: every track in a composition is enabled, so
        // inserting them all would draw them all at once.
        let legible = ((try? await asset.loadTracks(withMediaType: .subtitle)) ?? [])
            + ((try? await asset.loadTracks(withMediaType: .text)) ?? [])
        var usedSubtitle: Int?
        if let subtitleIndex, legible.indices.contains(subtitleIndex) {
            let source = legible[subtitleIndex]
            if let track = composition.addMutableTrack(
                withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? track.insertTimeRange(whole, of: source, at: .zero)
                usedSubtitle = subtitleIndex
            }
        }

        // Carried across by hand. A composition track starts out square and
        // upright whatever the source was, and a film shot in portrait plays
        // sideways without this.
        if let transform = try? await video.load(.preferredTransform) {
            videoTrack.preferredTransform = transform
        }

        let immutable = composition.copy() as? AVComposition ?? composition
        return (AVPlayerItem(asset: immutable), asset, usedAudio, usedSubtitle)
    }

    // MARK: - Transport

    func play() {
        wantsPlay = true
        guard !holding else { return }
        startPlaying()
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    /// Start the picture moving.
    ///
    /// `play()` rather than a rate written straight into the player.
    /// `automaticallyWaitsToMinimizeStalling` is the heuristic that holds a
    /// stream back until it has buffered enough to run without stopping, and
    /// it is built around `play()`; setting `rate` is a demand to start
    /// *now*, which on a live channel means starting on an all-but-empty
    /// buffer and stalling a second later. Only a speed that isn't 1× still
    /// needs the rate, and live never offers one.
    private func startPlaying() {
        if abs(wantedRate - 1) < 0.001 {
            player.play()
        } else {
            player.rate = Float(wantedRate)
        }
    }

    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard playerItem != nil else { return false }
        var target = max(0, seconds)
        // Before the item is ready the seek can't be made at all — an HLS
        // asset drops one issued before its playlist is in — so it becomes
        // the position the hold is waiting to jump to instead.
        if holding {
            pendingSeek = target
            return true
        }
        // A live playlist's seekable window slides forward as segments age
        // out of it; a target behind it is a segment the server no longer
        // holds.
        if loadedLive, let item = playerItem,
           let range = item.seekableTimeRanges.last?.timeRangeValue, range.duration > .zero {
            let clamped = CMTimeMinimum(
                CMTimeMaximum(CMTime(seconds: target, preferredTimescale: 600), range.start), range.end)
            target = clamped.seconds
        }
        hadFirstFrame = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, finished else { return }
            Task { @MainActor in
                self.hadFirstFrame = true
                self.deliver(.firstFrame)
            }
        }
        return true
    }

    @discardableResult
    func seek(by seconds: Double) -> Bool {
        guard let now = clock else { return false }
        return seek(to: now + seconds)
    }

    var rate: Double {
        get { wantedRate }
        set {
            wantedRate = newValue
            // The player's `defaultRate` is the documented two-way channel
            // between this and AVKit's own speed control: setting it moves
            // the tick in that menu, and the menu moving sets it back.
            if abs(Double(player.defaultRate) - newValue) > 0.001 {
                player.defaultRate = Float(newValue)
            }
            if wantsPlay, !holding, player.timeControlStatus != .paused {
                startPlaying()
            }
        }
    }

    var volume: Double = 1 {
        didSet { player.volume = Float(volume) }
    }

    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    var transport: EngineTransport {
        if holding { return .waiting }
        switch player.timeControlStatus {
        case .paused: return .paused
        case .waitingToPlayAtSpecifiedRate: return .waiting
        case .playing: return .playing
        @unknown default: return .waiting
        }
    }

    var clock: Double? {
        if let pendingSeek { return pendingSeek }
        guard playerItem != nil else { return nil }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    /// When the playhead was last thrown forward to the live edge: often
    /// enough to rescue the occasional stall, rarely enough that a channel
    /// which is genuinely dead gets reopened on the next tick instead of
    /// skipping forward for ever inside a window that isn't moving.
    private var jumpedToEdgeAt = Date.distantPast
    private static let liveEdgeJumpInterval: TimeInterval = 30

    func jumpToLiveEdge(margin: Double) -> Bool {
        guard let avItem = playerItem,
              Date().timeIntervalSince(jumpedToEdgeAt) > Self.liveEdgeJumpInterval,
              let range = avItem.seekableTimeRanges.last?.timeRangeValue,
              range.duration > .zero
        else { return false }
        // Not the very end: the last segment in a playlist is frequently still
        // being written, and landing on it is landing on the same stall again.
        let edge = CMTimeSubtract(range.end, CMTime(seconds: margin, preferredTimescale: 1))
        let target = CMTimeMaximum(edge, range.start)
        guard CMTimeCompare(target, player.currentTime()) > 0 else { return false }
        jumpedToEdgeAt = Date()
        player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wantsPlay else { return }
                self.startPlaying()
            }
        }
        return true
    }

    /// Re-select whichever audible option the item is already playing, which
    /// is the documented way to ask for a fresh audio mix without touching
    /// the stream. An `AVPlayer` that was decoding through an audio session
    /// that went away keeps a dead audio tap, and simply owning a live
    /// session again doesn't rebuild it; re-selecting the track makes
    /// AVFoundation tear the mix down and construct a new one against the
    /// route that now exists, and setting the rate afresh restarts the clock
    /// they share. Both are no-ops when the sound never went away.
    ///
    /// Does nothing to a composition, which has no audible selection group
    /// to re-select in; the model reloads one of those instead.
    func rebuildAudio() async {
        guard let avItem = playerItem else { return }
        if composed == nil,
           let group = try? await avItem.asset.loadMediaSelectionGroup(for: .audible),
           let current = avItem.currentMediaSelection.selectedMediaOption(in: group) {
            avItem.select(nil, in: group)
            avItem.select(current, in: group)
        }
        guard playerItem === avItem else { return }
        if wantsPlay, !holding {
            player.rate = Float(wantedRate)
        }
    }

    // MARK: - Tracks

    func selectAudio(trackID: Int?) {
        guard let avItem = playerItem, composed == nil, let trackID else { return }
        Task {
            guard let group = try? await avItem.asset.loadMediaSelectionGroup(for: .audible),
                  group.options.indices.contains(trackID), playerItem === avItem else { return }
            avItem.select(group.options[trackID], in: group)
            await readTracks(on: avItem)
        }
    }

    func selectSubtitle(trackID: Int?) {
        guard let avItem = playerItem, composed == nil else { return }
        Task {
            guard let group = try? await avItem.asset.loadMediaSelectionGroup(for: .legible),
                  playerItem === avItem else { return }
            if let trackID, group.options.indices.contains(trackID) {
                avItem.select(group.options[trackID], in: group)
            } else {
                avItem.select(nil, in: group)
            }
            await readTracks(on: avItem)
        }
    }

    /// AVFoundation adds no subtitle to a stream after the fact; the server
    /// has to put it in the manifest.
    func addExternalSubtitle(url: URL, language: String?, title: String?) {}

    private func readTracks(on avItem: AVPlayerItem) async {
        // The original rather than the item's own asset: with an audio offset
        // in force the item is a composition, and a composition lists no
        // selectable tracks at all.
        let asset = sourceAsset ?? avItem.asset
        var list: [EngineTrack] = []

        // Every await below is a moment the item can be replaced in — a
        // quality change, the next episode — and what was read about this one
        // must not land on that.
        let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard playerItem === avItem else { return }

        if let group = audibleGroup {
            let selected = composed == nil
                ? avItem.currentMediaSelection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }
                : composed?.audio
            for (i, option) in group.options.enumerated() {
                list.append(EngineTrack(
                    id: i, kind: .audio, title: option.displayName,
                    language: option.extendedLanguageTag ?? option.locale?.identifier,
                    isSelected: i == selected
                ))
            }
        }
        if let group = legibleGroup {
            let selected = composed == nil
                ? avItem.currentMediaSelection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }
                : composed?.subtitle
            for (i, option) in group.options.enumerated() {
                list.append(EngineTrack(
                    id: i, kind: .subtitle, title: option.displayName,
                    language: option.extendedLanguageTag ?? option.locale?.identifier,
                    isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                        || option.displayName.localizedCaseInsensitiveContains("forced"),
                    isSelected: i == selected
                ))
            }
        }
        tracks = Self.numbered(list, by: hints)
        deliver(.tracks(tracks))
    }

    /// Line the engine's tracks up with the server's numbering.
    ///
    /// Three ways, in the order they are trustworthy. The name is the
    /// strongest: Jellyfin writes each track's `DisplayTitle` into the HLS
    /// manifest as the rendition name, so on a transcode the two lists are
    /// describing themselves with the same string. Failing that, two lists of
    /// the same length are the same list — the direct-play case, where what
    /// AVFoundation can see *is* the file. Only then the language, which is
    /// the loosest: it cannot tell two English tracks apart, and picking the
    /// first is a better answer than reopening the stream to fetch a track
    /// already in it.
    static func numbered(_ tracks: [EngineTrack], by hints: [EngineTrackHint]) -> [EngineTrack] {
        var out = tracks
        for kind in [EngineTrack.Kind.audio, .subtitle] {
            let kindHints = hints.filter { $0.kind == kind }
            let indexes = out.indices.filter { out[$0].kind == kind }
            var taken = Set<Int>()
            for (position, hint) in kindHints.enumerated() {
                // A picture-based subtitle is never in a selection group: the
                // server paints it into the video or it isn't shown at all.
                if hint.isImage { continue }
                let match: Int? = {
                    if let title = hint.title, !title.isEmpty,
                       let found = indexes.first(where: {
                           out[$0].title?.caseInsensitiveCompare(title) == .orderedSame && !taken.contains($0)
                       }) {
                        return found
                    }
                    // An external track is a separate file on the server and
                    // is in no container this app was handed, so a
                    // same-length coincidence must not be read as a line-up.
                    if indexes.count == kindHints.count, !hint.isExternal, position < indexes.count,
                       !taken.contains(indexes[position]) {
                        return indexes[position]
                    }
                    guard let language = hint.language, !language.isEmpty else { return nil }
                    return indexes.first {
                        !taken.contains($0)
                            && Languages.matches(preference: language, tag: out[$0].language)
                            && out[$0].isForced == hint.isForced
                    }
                }()
                if let match {
                    out[match].fileIndex = hint.fileIndex
                    taken.insert(match)
                }
            }
        }
        return out
    }

    private func loadChapters(from asset: AVAsset) async -> [EngineChapter] {
        guard let locales = try? await asset.load(.availableChapterLocales), let locale = locales.first,
              let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale)
        else { return [] }
        var out: [EngineChapter] = []
        for (i, group) in groups.enumerated() {
            let start = group.timeRange.start.seconds
            let title = (try? await group.items
                .first(where: { $0.commonKey == .commonKeyTitle })?
                .load(.stringValue)) ?? nil
            out.append(EngineChapter(id: i, start: start, title: title ?? "Chapter \(i + 1)"))
        }
        return out
    }

    // MARK: - The picture and the sound

    /// AVPlayer honours `AVTextStyleRule` on WebVTT tracks, which is what every
    /// HLS stream from Jellyfin carries.
    var subtitleStyle = SubtitleStyle() {
        didSet {
            if let playerItem { applySubtitleStyling(to: playerItem) }
        }
    }

    private func applySubtitleStyling(to avItem: AVPlayerItem) {
        let scale = max(0.5, min(2.0, subtitleStyle.size / 100))
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: scale * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0, 1.0, 1.0, 1.0],
        ]
        switch subtitleStyle.background {
        case .outline:
            attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [0.0, 0.0, 0.0, 0.0]
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_Uniform as String
        case .shadow:
            attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [0.0, 0.0, 0.0, 0.0]
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_DropShadow as String
        case .box:
            attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [0.75, 0.0, 0.0, 0.0]
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_None as String
        }
        if let rule = AVTextStyleRule(textMarkupAttributes: attributes) {
            avItem.textStyleRules = [rule]
        }
    }

    /// The surface that draws the player applies this as its video gravity;
    /// zoom and aspect override are not things an `AVPlayerLayer` does.
    var framing: Framing = .fit
    var picture = PictureAdjustment.neutral
    var nightMode = false
    var powerProfile: PowerProfile = .quality
    /// `continuesIfPossible` already drops the picture and keeps the sound
    /// when the app goes behind another; there is nothing to switch here.
    var pictureDecode = true

    func setDisplayRefreshRate(_ hertz: Double?) {}

    var streamFacts: EngineStreamFacts {
        var facts = EngineStreamFacts()
        guard let avItem = playerItem else { return facts }
        let size = avItem.presentationSize
        if size.width > 0, size.height > 0 {
            facts.width = Int(size.width)
            facts.height = Int(size.height)
        }
        if let event = avItem.accessLog()?.events.last {
            if event.indicatedBitrate > 0 { facts.indicatedBitrate = event.indicatedBitrate }
            if event.observedBitrate > 0 { facts.observedBitrate = event.observedBitrate }
            if event.numberOfStalls >= 0 { facts.stalls = event.numberOfStalls }
            if event.numberOfDroppedVideoFrames >= 0 {
                facts.droppedFrames = event.numberOfDroppedVideoFrames
            }
        }
        return facts
    }

    // MARK: - Observers

    private func installObservers(on avItem: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: avItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliver(.ended(.finished)) }
        }

        // Where a mid-playback HLS failure actually shows up. An item whose
        // playlist or segments go bad twenty minutes in does not move to
        // `.failed` — it has been playing, so its status stays `readyToPlay`
        // — it posts this instead, with the CoreMedia code in the user info.
        failedEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: avItem, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                self?.fail(error, duringPlayback: true)
            }
        }

        lastVariantBitrate = nil
        variantChangesCountFrom = Date().addingTimeInterval(10)
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: avItem, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.noteVariantChange(note.object as? AVPlayerItem)
            }
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: avItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A stream still being held open at its start position is not
                // a stream that can't keep up: the rate is deliberately 0 and
                // the buffer is empty because it hasn't been let play yet.
                guard let self, !self.holding else { return }
                self.reportBuffering(true)
            }
        }

        // Duration and track lists only become known once enough of the asset
        // has loaded, so they're read when the status flips rather than now.
        avItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self, self.playerItem === avItem else { return }
                    if status == .readyToPlay {
                        self.deliver(.fileLoaded)
                        self.applyPendingSeek()
                        self.watchForPicture(on: avItem)
                        Task {
                            await self.readTracks(on: avItem)
                            let chapters = await self.loadChapters(from: self.sourceAsset ?? avItem.asset)
                            guard self.playerItem === avItem else { return }
                            self.deliver(.chapters(chapters))
                        }
                    } else if status == .failed {
                        self.fail(avItem.error, duringPlayback: false)
                    }
                }
            }
            .store(in: &statusObservers)

        // Whether this stream has a picture, asked of the thing that would be
        // drawing it. `loadTracks` answers for a file and says nothing at all
        // about an HLS stream; `presentationSize` is the size of the picture
        // actually being presented, so a non-zero one settles the question.
        avItem.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                MainActor.assumeIsolated {
                    guard let self, self.playerItem === avItem, size != .zero else { return }
                    self.pictureWatchdog?.cancel()
                    self.pictureWatchdog = nil
                    self.deliver(.videoSize(size))
                }
            }
            .store(in: &statusObservers)

        avItem.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keepUp in
                MainActor.assumeIsolated {
                    guard let self, self.playerItem === avItem, keepUp else { return }
                    self.reportBuffering(false)
                }
            }
            .store(in: &statusObservers)

        avItem.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] empty in
                MainActor.assumeIsolated {
                    guard let self, self.playerItem === avItem, empty, self.wantsPlay, !self.holding else { return }
                    self.reportBuffering(true)
                }
            }
            .store(in: &statusObservers)
    }

    private func teardownObservers() {
        pictureWatchdog?.cancel()
        pictureWatchdog = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failedEndObserver { NotificationCenter.default.removeObserver(failedEndObserver) }
        failedEndObserver = nil
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = nil
        if let accessLogObserver { NotificationCenter.default.removeObserver(accessLogObserver) }
        accessLogObserver = nil
        statusObservers.removeAll()
    }

    private func reportBuffering(_ buffering: Bool) {
        guard buffering != reportedBuffering else { return }
        reportedBuffering = buffering
        deliver(.buffering(buffering))
    }

    private func tick(_ time: CMTime) {
        guard let avItem = playerItem else { return }
        // A stream still opening at a position sits at the position it was
        // asked to start from, whatever the player's clock currently says.
        // Reading that clock would show 0:00 on the scrubber and report 0:00
        // to the server as this item's resume point.
        if !holding {
            deliver(.position(time.seconds.isFinite ? time.seconds : 0))
        }
        let d = avItem.duration.seconds
        // A live HLS stream has no meaningful duration; the seekable range
        // is what the scrubber can honestly offer.
        var duration: Double?
        if d.isFinite, d > 0 {
            duration = d
        } else if let range = avItem.seekableTimeRanges.last?.timeRangeValue {
            duration = loadedLive ? 0 : (range.start.seconds + range.duration.seconds)
        }
        if let duration, duration != lastReportedDuration {
            lastReportedDuration = duration
            deliver(.duration(duration))
        }
        if let loaded = avItem.loadedTimeRanges.last?.timeRangeValue {
            deliver(.cachedUntil(loaded.start.seconds + loaded.duration.seconds))
        }
        if !holding {
            let paused = player.timeControlStatus == .paused
            if paused != lastReportedPaused {
                lastReportedPaused = paused
                deliver(.paused(paused))
            }
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                reportBuffering(true)
            }
        }
        // Frames given up on, as a running total. `accessLog()` hands back a
        // fresh copy of every event since the stream opened — a copy that
        // grows for the length of a film — so it is read every ten seconds
        // rather than twice a second.
        let now = Date()
        if now.timeIntervalSince(droppedFramesSampledAt) >= 10, !holding {
            droppedFramesSampledAt = now
            if let event = avItem.accessLog()?.events.last, event.numberOfDroppedVideoFrames >= 0 {
                deliver(.droppedFrames(event.numberOfDroppedVideoFrames))
            }
        }
    }

    /// Jump to the position this stream was started at, now that its asset can
    /// answer a seek.
    private func applyPendingSeek() {
        guard let target = pendingSeek else {
            hadFirstFrame = true
            deliver(.firstFrame)
            return
        }
        // Both answers below belong to the item this seek was made on, and
        // must not release the hold of whatever has replaced it since.
        let seekItem = playerItem.map { ObjectIdentifier($0) }
        // A transcode that has to be encoding at the offset before it can
        // serve it can take tens of seconds to answer, and a server that has
        // given up never answers at all. Either way the hold has to end.
        seekWatchdog?.cancel()
        seekWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.holding,
                  self.playerItem.map({ ObjectIdentifier($0) }) == seekItem else { return }
            self.releaseHold(at: nil)
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self else { return }
            Task { @MainActor in
                // The target is re-read: a seek made by the viewer during the
                // hold replaces it, and lands as this one's completion.
                guard finished, self.playerItem.map({ ObjectIdentifier($0) }) == seekItem,
                      let landed = self.pendingSeek else { return }
                if abs(landed - target) > 0.5 {
                    // Moved during the hold: make the new seek instead.
                    self.pendingSeek = nil
                    self.pendingSeek = landed
                    self.applyPendingSeek()
                    return
                }
                self.releaseHold(at: landed)
            }
        }
    }

    /// Start playing the stream that was held open at a position.
    private func releaseHold(at target: Double?) {
        seekWatchdog?.cancel()
        seekWatchdog = nil
        guard holding else { return }
        pendingSeek = nil
        if let target { deliver(.position(target)) }
        hadFirstFrame = true
        deliver(.firstFrame)
        if wantsPlay { startPlaying() }
    }

    /// Give the stream a few seconds to produce a frame, then take silence for
    /// an answer. A backstop, not the main test: an HLS master playlist that
    /// advertises `RESOLUTION=1920x1080` gives the item that size whether or
    /// not a frame ever decodes, so the model's reading of the stream — see
    /// `StreamDiagnosis` — outranks anything measured here.
    private func watchForPicture(on avItem: AVPlayerItem) {
        pictureWatchdog?.cancel()
        guard avItem.presentationSize == .zero else { return }
        pictureWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.playerItem === avItem else { return }
            self.pictureWatchdog = nil
            guard avItem.presentationSize == .zero else { return }
            self.deliver(.noPicture)
        }
    }

    /// AVPlayer moving to another variant of the playlist it is reading.
    /// Most Jellyfin transcodes offer one variant and never get here; live
    /// TV, IPTV and a direct-streamed HLS source can offer several, and
    /// AVPlayer moves between them as the connection changes without asking
    /// anyone. Small wobbles are ignored — a step has to be at least 15%
    /// either way to be one somebody could see.
    private func noteVariantChange(_ avItem: AVPlayerItem?) {
        guard let rate = avItem?.accessLog()?.events.last?.indicatedBitrate, rate > 0 else { return }
        defer { lastVariantBitrate = rate }
        guard let previous = lastVariantBitrate, Date() >= variantChangesCountFrom else { return }
        let ratio = rate / previous
        guard ratio >= 1.15 || ratio <= 1 / 1.15 else { return }
        deliver(.variantChanged(bitsPerSecond: rate))
    }

    // MARK: - Failures

    private func fail(_ error: (any Error)?, duringPlayback: Bool) {
        Self.log.error(
            "stream failure live=\(self.loadedLive) duringPlayback=\(duringPlayback): \(error?.localizedDescription ?? "no error", privacy: .public)")
        pendingSeek = nil
        seekWatchdog?.cancel()
        seekWatchdog = nil
        deliver(.failed(EngineFailure(
            message: error?.localizedDescription,
            duringPlayback: duringPlayback,
            isSessionLoss: Self.isRecoverableStreamFailure(error)
        )))
    }

    /// CoreMedia codes that mean the session went bad rather than the media
    /// being unplayable.
    ///
    /// -12889 is the player asking for a segment the playlist no longer
    /// lists. -12888 is its sibling, a playlist that stopped being updated.
    /// -12660 is a 403 on a segment, which on Jellyfin is a transcode whose
    /// session the server has already closed. -1102 is its 401. -12927 is the
    /// read itself failing part-way through — the connection went away
    /// between two reads of the same file. Deliberately a short list:
    /// anything not on it is treated as real, and a file that genuinely will
    /// not decode must reach the error card on its first try rather than
    /// after two silent retries.
    private static let recoverableMediaCodes: Set<Int> = [-12889, -12888, -12927, -12660, -1102]

    /// The URL-loading failures worth one more go: the connection dropped, the
    /// request timed out, the host went away for a moment.
    private static let recoverableURLCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorResourceUnavailable,
    ]

    /// The code is looked for on the error *and* on whatever it is wrapping.
    /// AVFoundation reports these as an `AVFoundationErrorDomain` failure with
    /// the CoreMedia one underneath, and the outer code says nothing useful.
    static func isRecoverableStreamFailure(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        var pending: [NSError] = [error as NSError]
        var seen = 0
        while seen < pending.count, seen < 4 {
            let next = pending[seen]
            seen += 1
            if next.domain == "CoreMediaErrorDomain", recoverableMediaCodes.contains(next.code) {
                return true
            }
            if next.domain == NSURLErrorDomain, recoverableURLCodes.contains(next.code) {
                return true
            }
            if let under = next.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(under) }
        }
        return false
    }

    private func deliver(_ event: EngineEvent) {
        continuation.yield(event)
    }
}

/// An asset already reading its playlist — see `AVEngine.prepare`. Reading
/// the playlist is what gets the server encoding, and what leaves the first
/// frame nothing to wait on.
final class AVPreparedStream: PreparedStream {
    let asset: AVURLAsset
    var url: URL { asset.url }

    init(asset: AVURLAsset) {
        self.asset = asset
        Task { _ = try? await asset.load(.isPlayable) }
    }

    func cancel() {
        asset.cancelLoading()
    }
}
