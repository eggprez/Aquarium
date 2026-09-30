//  The Apple TV's player: Jellyfin on one side, mpv on the other.
//
//  The iPhone, iPad and Mac keep the AVPlayer model in `PlayerModel.swift`;
//  this is the same class name for the tvOS build, so everything outside the
//  player — the library, the guide, Settings, the Now Playing card — goes on
//  calling `PlayerModel.shared.play(item:)` and never learns which engine is
//  underneath. What it offers is the handful of things they call, plus what
//  the tvOS player screen reads.
//
//  A good deal of the old model does not come across, because the reasons for
//  it have gone. mpv reads the original file, so there is no composition to
//  build for an audio offset, no held picture, no hand-over between HLS
//  variants, no resync of an audio mix that AVFoundation lost track of, and no
//  escalation to a transcode because AVFoundation couldn't open the container.
//  The sound is moved against the picture by one property, both ways, on
//  everything — `setAudioDelay`.
//
//  What does come across is the Jellyfin side, mostly unchanged: the stream
//  request, the track preferences (per series, then Settings), progress
//  reporting, intro and credits skipping, Up Next and autoplay, the sleep
//  timer, and releasing the server's encode and tuner when a stream closes.

#if os(tvOS)

import AVFoundation
import AVKit
import Foundation
import MediaPlayer
import Observation
import OSLog
import UIKit

@MainActor
@Observable
final class PlayerModel {
    static let shared = PlayerModel()

    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "player")

    // MARK: - Published state

    private(set) var isActive = false
    private(set) var isPaused = false
    /// Waiting on the network, or opening: the spinner.
    private(set) var isBuffering = false
    /// Between asking for a stream and its first frame.
    private(set) var isOpening = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// How far ahead the cache reaches, in stream seconds.
    private(set) var buffered: Double = 0
    private(set) var title = ""
    private(set) var subtitle = ""
    private(set) var isLive = false
    /// A channel from an M3U playlist rather than Jellyfin: no session on the
    /// other end, so nothing is reported for it.
    private(set) var isExternal = false
    private(set) var errorMessage: String?

    private(set) var item: BaseItem?
    private(set) var artworkURL: URL?
    /// The whole item, fetched while the stream opens, for the Info tab.
    private(set) var fullItem: BaseItem?
    private(set) var trickplay: TrickplayInfo?
    private(set) var segments: [MediaSegment] = [] {
        didSet { refreshCues() }
    }
    private(set) var chapters: [Chapter] = []

    /// What mpv found in the stream.
    private(set) var tracks: [MPVEngine.Track] = []

    private(set) var upNext: BaseItem? {
        didSet { refreshCues() }
    }
    private(set) var isStartingNext = false
    private(set) var autoplayCancelled = false {
        didSet { refreshCues() }
    }
    /// The intro or credits sequence the playhead is in, if any.
    private(set) var activeSegment: MediaSegment?
    /// Whether the Up Next card should be on screen.
    private(set) var shouldShowUpNext = false

    private(set) var sleepDeadline: Date?
    /// The quality rung the stream was asked for; nil for the original file.
    private(set) var currentBitrate: Int?
    private(set) var isTranscoding = false

    /// What the picture is, once mpv has decoded some of it.
    private(set) var videoSize: CGSize = .zero
    private(set) var frameRate: Double?
    /// `videotoolbox`, or `no` when mpv is decoding in software.
    private(set) var decoder: String?
    private(set) var droppedFrames = 0

    var speed: Double = 1 {
        didSet { engine?.speed = speed }
    }
    var volume: Double = 1 {
        didSet {
            engine?.volume = volume * 100
            Preferences.shared.volume = volume
        }
    }

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func speedName(_ rate: Double) -> String {
        rate == 1 ? "Normal" : "\(rate.formatted())×"
    }

    // The Now Playing card asks these of every player; neither exists on a
    // television, which has no downloads to shuffle.
    var isShuffling: Bool { false }
    var upNextLocalId: String? { nil }

    // MARK: - Internals

    /// The surface the picture is drawn on. One for the life of the app, like
    /// the engine drawing into it; the player screen puts it on screen.
    let videoView = MPVVideoView(frame: .zero)
    private var engine: MPVEngine?

    private var source: PlaybackSource?
    private var options = StreamOptions()
    /// The M3U channel being played, for reopening it.
    private var externalStream: (url: URL, channel: BaseItem?)?
    /// The server's numbers for the tracks wanted on the stream now opening,
    /// applied once mpv has listed what is in it. `-1` for the subtitle is off.
    private var wantedTracks: (audio: Int?, subtitle: Int?)
    private var tracksApplied = false
    private var upNextSettled = false
    private var autoplayInFlight = false
    private var sleepTask: Task<Void, Never>?
    private var lastReportAt = Date.distantPast
    /// Reopens of a live channel that ended or failed, and when the count
    /// started. A dead channel is given up on rather than reopened for ever.
    private var liveReopens = 0
    private var liveReopensSince = Date.distantPast
    /// Whether this stream has already been retried as a transcode after the
    /// original failed to open.
    private var escalated = false

    /// Bumped by everything that starts or ends a stream, so work begun for one
    /// stream never lands on the next. Read before an await, compared after.
    private var generation = 0

    private var client: JellyfinClient { .shared }
    private var prefs: Preferences { .shared }

    private init() {
        volume = prefs.volume
        configureAudioSession(activate: false)
        observeAudioRoute()
        observeLifecycle()
    }

    private func makeEngine() -> MPVEngine? {
        if let engine { return engine }
        guard let made = MPVEngine(layer: videoView.metalLayer) else {
            Self.log.error("mpv could not be created")
            return nil
        }
        made.onEvent = { [weak self] event in self?.handle(event) }
        made.volume = volume * 100
        engine = made
        refreshSubtitleStyling()
        NowPlaying.shared.attach(to: self)
        return made
    }

    // MARK: - Starting playback

    /// Play a server item.
    func play(item: BaseItem, options: StreamOptions = .init(), meta: StartMeta = .init()) async {
        MusicPlayer.shared.yield()
        guard let engine = makeEngine() else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }
        let sameItem = self.item?.Id == item.Id

        var opts = options
        if opts.maxBitrate == nil, !opts.bitrateIsChosen, !opts.live, prefs.defaultBitrate != nil,
           !meta.inherited {
            opts.maxBitrate = prefs.defaultBitrate
        }
        // Tracks are settled here from the file's own list, for a different
        // file always, for the same one only when nothing was chosen.
        if !opts.live, let source = item.MediaSources?.first, !source.streams.isEmpty,
           !sameItem || (opts.audioStreamIndex == nil && opts.subtitleStreamIndex == nil) {
            let wanted = preferredStreams(in: source, seriesId: item.SeriesId)
            opts.audioStreamIndex = wanted.audio
            opts.subtitleStreamIndex = wanted.subtitle
        }

        let startSeconds: Double = {
            if let explicit = opts.startSeconds { return explicit.isFinite ? min(max(0, explicit), 30 * 86_400) : 0 }
            guard opts.resume, prefs.resumePlayback else { return 0 }
            let ticks = item.userData.positionTicks
            guard ticks > 0, let total = item.RunTimeTicks, total > 0 else { return 0 }
            // Something watched to the end resumes from the top.
            let f = Double(ticks) / Double(total)
            return f > 0.92 ? 0 : Double(ticks) / 10_000_000
        }()

        let previous = source
        resetStreamState()
        if !sameItem { fullItem = nil }
        if !meta.reopening { liveReopens = 0 }
        if !meta.recovering { escalated = false }
        self.item = item
        self.options = opts
        self.externalStream = nil
        self.isExternal = false
        self.isLive = opts.live
        self.autoplayCancelled = false
        self.title = Self.displayTitle(item)
        self.subtitle = item.isEpisode ? (item.SeriesName ?? "") : Format.itemSubtitle(item)
        self.artworkURL = Artwork.url(item, type: "Primary", width: 600)
        self.currentBitrate = opts.maxBitrate
        self.wantedTracks = (opts.audioStreamIndex, opts.subtitleStreamIndex)
        self.isActive = true
        self.isOpening = true
        self.isBuffering = true
        generation &+= 1
        let mine = generation

        do {
            let src = try await client.resolvePlayback(
                itemId: item.Id,
                maxBitrate: opts.maxBitrate,
                forceTranscode: opts.forceTranscode || opts.maxBitrate != nil,
                live: opts.live,
                startTicks: Int64(startSeconds * 10_000_000),
                audioStreamIndex: opts.audioStreamIndex,
                subtitleStreamIndex: opts.subtitleStreamIndex
            )
            guard generation == mine else {
                await release(src)
                return
            }
            source = src
            isTranscoding = src.isTranscode
            engine.audioDelay = prefs.audioDelay
            engine.speed = speed
            // A Jellyfin HLS playlist covers the whole item from zero whatever
            // start the server was given, so a transcode is seeked the same
            // way as a file.
            engine.load(src.url, start: opts.live ? 0 : startSeconds, headers: client.authHeaders(for: src.url))
            // The encode and the tuner the last stream held.
            if let previous {
                if previous.isTranscode, previous.playSessionId != src.playSessionId {
                    await client.stopTranscode(playSessionId: previous.playSessionId)
                }
                if let stale = previous.mediaSource.LiveStreamId, !stale.isEmpty,
                   stale != src.mediaSource.LiveStreamId {
                    await client.closeLiveStream(id: stale)
                }
            }
            await loadExtras(for: item)
            guard generation == mine else { return }
            await client.reportPlaybackStart(report(paused: false))
        } catch {
            guard generation == mine else { return }
            Self.log.error("start failed \(item.Id, privacy: .public): \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            isBuffering = false
            isOpening = false
        }
    }

    /// Play a channel from a custom M3U playlist. mpv follows the redirects
    /// and reads a bare transport stream itself, so the URL goes in as given.
    func playExternal(
        title: String,
        subtitle: String,
        artworkURL: URL?,
        streamURL: URL,
        channel: BaseItem? = nil,
        reopening: Bool = false
    ) {
        MusicPlayer.shared.yield()
        guard let engine = makeEngine() else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }
        let previous = source
        resetStreamState()
        if !reopening { liveReopens = 0 }
        item = channel
        fullItem = nil
        source = nil
        options = StreamOptions(live: true)
        externalStream = (streamURL, channel)
        isExternal = true
        isLive = true
        autoplayCancelled = true
        upNextSettled = true
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        currentBitrate = nil
        wantedTracks = (nil, nil)
        isActive = true
        isOpening = true
        isBuffering = true
        generation &+= 1
        engine.audioDelay = prefs.audioDelay
        engine.speed = 1
        engine.load(streamURL, start: 0, headers: ["User-Agent": prefs.iptvUserAgentHeader])
        if let previous { Task { await release(previous) } }
    }

    /// Everything that belongs to one stream, cleared before the next opens.
    private func resetStreamState() {
        errorMessage = nil
        position = 0
        duration = 0
        buffered = 0
        isPaused = false
        tracks = []
        chapters = []
        segments = []
        trickplay = nil
        upNext = nil
        upNextSettled = false
        tracksApplied = false
        activeSegment = nil
        shouldShowUpNext = false
        videoSize = .zero
        frameRate = nil
        decoder = nil
        droppedFrames = 0
    }

    /// Give back what a source holds on the server: its encode, and the tuner
    /// behind a live channel.
    private func release(_ src: PlaybackSource) async {
        if src.isTranscode { await client.stopTranscode(playSessionId: src.playSessionId) }
        if let id = src.mediaSource.LiveStreamId, !id.isEmpty {
            await client.closeLiveStream(id: id)
        }
    }

    // MARK: - Engine events

    private func handle(_ event: MPVEngine.Event) {
        guard isActive else { return }
        switch event {
        case .position(let seconds):
            position = seconds
            refreshCues()
            maybeReport()
            checkSleepDeadline()
            NowPlaying.shared.updateElapsed(seconds, rate: isPaused ? 0 : speed)
            if !upNextSettled, upNext == nil, duration > 0, duration - seconds < 90 {
                upNextSettled = true
                Task { await refreshUpNext() }
            }
        case .duration(let seconds):
            duration = seconds.isFinite ? max(0, seconds) : 0
            refreshCues()
        case .paused(let paused):
            guard paused != isPaused else { return }
            isPaused = paused
            NowPlaying.shared.update(from: self)
            Task { await reportNow() }
        case .buffering(let waiting):
            isBuffering = waiting || isOpening
        case .seeking:
            break
        case .cachedUntil(let seconds):
            buffered = seconds
        case .tracks(let list):
            tracks = list
            if !tracksApplied, list.contains(where: { $0.kind == .audio || $0.kind == .video }) {
                tracksApplied = true
                applyWantedTracks()
            }
        case .chapters(let list):
            chapters = list.enumerated().map { i, chapter in
                Chapter(id: i, start: chapter.time, title: chapter.title ?? "Chapter \(i + 1)")
            }
        case .videoSize(let size):
            videoSize = size
        case .frameRate(let rate):
            frameRate = rate > 0 ? rate : nil
        case .decoder(let name):
            decoder = name
        case .droppedFrames(let count):
            droppedFrames = count
        case .fileLoaded:
            break
        case .playbackRestart:
            if isOpening {
                isOpening = false
                Self.log.info("first frame: \(self.title, privacy: .public)")
                NowPlaying.shared.update(from: self)
            }
            isBuffering = false
        case .endFile(let reason, let error):
            endFile(reason, error: error)
        }
    }

    private func endFile(_ reason: MPVEngine.EndReason, error: String?) {
        switch reason {
        case .eof:
            handleReachedEnd()
        case .error:
            Self.log.error("stream ended in error: \(error ?? "unknown", privacy: .public)")
            if isLive {
                reopenLive()
                return
            }
            // The original wouldn't open or play: once, ask the server for a
            // transcode of it instead.
            if !escalated, let item, !isTranscoding {
                escalated = true
                var opts = options
                opts.forceTranscode = true
                opts.startSeconds = position > 1 ? position : nil
                Task { await play(item: item, options: opts, meta: StartMeta(inherited: true, recovering: true)) }
                return
            }
            errorMessage = "This stream couldn't be played (\(error ?? "unknown error"))."
            isBuffering = false
            isOpening = false
        case .stop, .quit, .redirect, .unknown:
            // A `loadfile … replace` ends the file before it; that is not the
            // stream ending.
            break
        }
    }

    // MARK: - Live

    /// A live stream that ended or failed is opened again — the playlist
    /// stopped, a tuner dropped — up to three times a minute.
    private func reopenLive() {
        if Date().timeIntervalSince(liveReopensSince) > 60 {
            liveReopens = 0
            liveReopensSince = Date()
        }
        liveReopens += 1
        guard liveReopens <= 3 else {
            errorMessage = "The channel stopped and didn't come back."
            isBuffering = false
            return
        }
        Self.log.notice("reopening live stream (\(self.liveReopens))")
        if let external = externalStream {
            playExternal(title: title, subtitle: subtitle, artworkURL: artworkURL,
                         streamURL: external.url, channel: external.channel, reopening: true)
        } else if let item {
            Task { await play(item: item, options: options, meta: StartMeta(reopening: true)) }
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPaused ? resume() : pause()
    }

    func pause() {
        engine?.isPaused = true
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        engine?.isPaused = false
    }

    func seek(to seconds: Double) {
        guard isActive, !isOpening else { return }
        let target = duration > 0 ? min(max(0, seconds), duration - 0.5) : max(0, seconds)
        position = target
        engine?.seek(to: target)
        refreshCues()
    }

    func seek(by delta: Double) {
        seek(to: position + delta)
    }

    func stepSpeed(_ direction: Int) {
        let current = Self.speeds.firstIndex { abs($0 - speed) < 0.001 } ?? Self.speeds.firstIndex(of: 1)!
        let next = min(max(current + direction, 0), Self.speeds.count - 1)
        speed = Self.speeds[next]
    }

    func stop(reason: String = "stop") {
        Task { await finish(userRequested: true, reason: reason) }
    }

    func retry() async {
        errorMessage = nil
        if let external = externalStream {
            playExternal(title: title, subtitle: subtitle, artworkURL: artworkURL,
                         streamURL: external.url, channel: external.channel)
        } else if let item {
            var opts = options
            opts.startSeconds = position > 1 ? position : nil
            await play(item: item, options: opts, meta: StartMeta(inherited: true))
        }
    }

    /// Whether Try again has anything to try.
    var canRetry: Bool { item != nil || externalStream != nil }

    /// Take the player down, then settle with the server. The player comes
    /// down before anything is awaited, so a stream started while the server
    /// is being told about this one starts on a clean board.
    func finish(userRequested: Bool, reason: String = "ended") async {
        guard isActive else { return }
        Self.log.info("finish: \(reason, privacy: .public) position=\(self.position, format: .fixed(precision: 1))")
        generation &+= 1
        let closingReport = isExternal ? nil : report(paused: true, position: position)
        let closingSource = source

        engine?.stop()
        cancelSleepTimer()
        NowPlaying.shared.clear()
        resetStreamState()
        isActive = false
        isBuffering = false
        isOpening = false
        item = nil
        fullItem = nil
        source = nil
        externalStream = nil
        isExternal = false
        isLive = false

        async let reported: Void = {
            guard let closingReport else { return }
            await client.reportPlaybackStopped(closingReport)
        }()
        async let released: Void = {
            guard let closingSource else { return }
            await release(closingSource)
        }()
        _ = await (reported, released)
        if closingReport != nil {
            Task { await LibraryIndex.shared.sync(minimumGap: 5) }
        }
    }

    // MARK: - Audio delay
    //
    // One offset, kept in Preferences because what it corrects is the room —
    // the television and whatever the sound goes through — and the room is the
    // same for the next film. mpv applies it to whatever is playing, in either
    // direction, at once: no reopen, no rounding to screen refreshes.

    /// The offsets Settings offers, in milliseconds. Positive plays the sound
    /// later than the picture.
    static let audioDelays: [Int] = Array(stride(from: -500, through: 500, by: 50))

    static func audioDelayName(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "In step" }
        return milliseconds < 0
            ? "Sound \(-milliseconds) ms earlier"
            : "Sound \(milliseconds) ms later"
    }

    static func audioDelayShortName(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "in step" }
        return milliseconds < 0 ? "\(-milliseconds) ms earlier" : "\(milliseconds) ms later"
    }

    /// The furthest the offset goes either way, in milliseconds.
    static let audioDelayReach = 1000

    var audioDelayMilliseconds: Int { Int((prefs.audioDelay * 1000).rounded()) }

    func setAudioDelay(milliseconds: Int) {
        let clamped = min(max(milliseconds, -Self.audioDelayReach), Self.audioDelayReach)
        prefs.audioDelay = Double(clamped) / 1000
        engine?.audioDelay = prefs.audioDelay
    }

    // MARK: - Tracks

    /// Every audio track the file has, as a menu lists them.
    ///
    /// From the server's list where there is one — a transcode carries a
    /// single audio track, and the others are a reopen away — and from mpv's
    /// otherwise. `avIndex` here is mpv's track id: set when the track is in
    /// the stream that is playing and choosing it costs nothing.
    var audioOptions: [TrackOption] {
        let playing = tracks.filter { $0.kind == .audio }
        guard let streams = serverStreams?.audioStreams, !streams.isEmpty else {
            return playing.map {
                TrackOption(serverIndex: nil, avIndex: $0.id, label: Self.label($0),
                            language: $0.language, isForced: false)
            }
        }
        return streams.map { stream in
            TrackOption(
                serverIndex: stream.Index,
                avIndex: isTranscoding ? nil : playing.first { $0.fileIndex == stream.Index }?.id,
                label: stream.menuLabel, language: stream.Language, isForced: false
            )
        }
    }

    /// Every subtitle track the file has. Off is not in here; `nil` stands for
    /// it.
    var subtitleOptions: [TrackOption] {
        let playing = tracks.filter { $0.kind == .sub }
        guard let streams = serverStreams?.subtitleStreams, !streams.isEmpty else {
            return playing.map {
                TrackOption(serverIndex: nil, avIndex: $0.id, label: Self.label($0),
                            language: $0.language, isForced: $0.isForced)
            }
        }
        return streams.map { stream in
            TrackOption(
                serverIndex: stream.Index,
                avIndex: mpvTrack(forSubtitle: stream)?.id,
                label: stream.menuLabel, language: stream.Language, isForced: stream.isForced
            )
        }
    }

    /// The audio entry to tick.
    var selectedAudioOption: TrackOption.ID? {
        let choices = audioOptions
        if let playing = tracks.first(where: { $0.kind == .audio && $0.isSelected }),
           let match = choices.first(where: { $0.avIndex == playing.id }) {
            return match.id
        }
        let asked = options.audioStreamIndex ?? serverStreams?.DefaultAudioStreamIndex
        if let asked, let match = choices.first(where: { $0.serverIndex == asked }) { return match.id }
        return choices.first?.id
    }

    /// The subtitle entry to tick, or nil for off.
    var selectedSubtitleOption: TrackOption.ID? {
        let choices = subtitleOptions
        if let playing = tracks.first(where: { $0.kind == .sub && $0.isSelected }),
           let match = choices.first(where: { $0.avIndex == playing.id }) {
            return match.id
        }
        // Burnt into a transcode: no track to see, but it was asked for.
        if isTranscoding, let asked = options.subtitleStreamIndex, asked >= 0,
           let match = choices.first(where: { $0.serverIndex == asked }) {
            return match.id
        }
        return nil
    }

    func selectAudio(_ option: TrackOption) {
        guard option.id != selectedAudioOption else { return }
        if let id = option.avIndex {
            engine?.selectAudio(id)
            options.audioStreamIndex = option.serverIndex
            rememberTrackChoice(audioLanguage: option.language)
            return
        }
        guard let index = option.serverIndex else { return }
        rememberTrackChoice(audioLanguage: option.language)
        Task { await reopen(audio: index, subtitle: options.subtitleStreamIndex) }
    }

    func selectSubtitles(_ option: TrackOption?) {
        guard let option else {
            engine?.selectSubtitle(nil)
            let wasBurnedIn = isTranscoding && (options.subtitleStreamIndex ?? -1) >= 0
                && subtitleOptions.first(where: { $0.serverIndex == options.subtitleStreamIndex })?.avIndex == nil
            options.subtitleStreamIndex = -1
            rememberTrackChoice(subtitleOff: true)
            if wasBurnedIn { Task { await reopen(audio: options.audioStreamIndex, subtitle: -1) } }
            return
        }
        rememberTrackChoice(subtitleLanguage: option.language ?? "und")
        if let id = option.avIndex {
            engine?.selectSubtitle(id)
            options.subtitleStreamIndex = option.serverIndex
            return
        }
        // A sidecar file the server can hand over by URL: added, no reopen.
        if let index = option.serverIndex,
           let stream = serverStreams?.subtitleStreams.first(where: { $0.Index == index }),
           addExternalSubtitle(stream) {
            options.subtitleStreamIndex = index
            return
        }
        guard let index = option.serverIndex else { return }
        Task { await reopen(audio: options.audioStreamIndex, subtitle: index) }
    }

    /// Open the stream again for tracks it doesn't carry, where it is.
    private func reopen(audio: Int?, subtitle: Int?) async {
        guard let item else { return }
        var opts = options
        opts.audioStreamIndex = audio
        opts.subtitleStreamIndex = subtitle
        opts.startSeconds = position
        await play(item: item, options: opts, meta: StartMeta(inherited: true))
    }

    private var serverStreams: MediaSource? {
        isExternal ? nil : source?.mediaSource
    }

    /// The track mpv has for one of the server's subtitle streams: embedded
    /// ones by their index in the file, sidecars by the URL they were added
    /// from.
    private func mpvTrack(forSubtitle stream: MediaStream) -> MPVEngine.Track? {
        let playing = tracks.filter { $0.kind == .sub }
        if stream.IsExternal == true || stream.DeliveryMethod == "External" {
            guard let url = externalURL(for: stream)?.absoluteString else { return nil }
            return playing.first { $0.isExternal && $0.externalURL == url }
        }
        guard !isTranscoding else { return nil }
        return playing.first { !$0.isExternal && $0.fileIndex == stream.Index }
    }

    private func externalURL(for stream: MediaStream) -> URL? {
        guard let path = stream.DeliveryUrl, !path.isEmpty,
              let server = prefs.session?.server else { return nil }
        if path.hasPrefix("http"), let url = URL(string: path), client.isSessionOrigin(url) { return url }
        guard path.hasPrefix("/"), let url = URL(string: server + path), client.isSessionOrigin(url) else { return nil }
        return url
    }

    /// Add a sidecar subtitle by its URL, or select it if it was added
    /// already. False if the stream has no URL to add it from.
    @discardableResult
    private func addExternalSubtitle(_ stream: MediaStream) -> Bool {
        if let existing = mpvTrack(forSubtitle: stream) {
            engine?.selectSubtitle(existing.id)
            return true
        }
        guard let url = externalURL(for: stream) else { return false }
        engine?.addSubtitle(url, title: stream.menuLabel, language: stream.Language)
        return true
    }

    /// Put on the tracks this stream was opened for, once mpv has listed them.
    private func applyWantedTracks() {
        guard let engine else { return }
        let streams = serverStreams
        // Audio: by index in the file on a direct play; a transcode carries
        // only the one it was asked for.
        if !isTranscoding, let index = wantedTracks.audio,
           let track = tracks.first(where: { $0.kind == .audio && $0.fileIndex == index }) {
            engine.selectAudio(track.id)
        }
        // Subtitles: mpv was started with none, and this decides.
        let subtitleIndex = wantedTracks.subtitle
            ?? streams?.DefaultSubtitleStreamIndex.flatMap { $0 >= 0 ? $0 : nil }
        guard let subtitleIndex, subtitleIndex >= 0 else { return }
        if let stream = streams?.subtitleStreams.first(where: { $0.Index == subtitleIndex }) {
            if let track = mpvTrack(forSubtitle: stream) {
                engine.selectSubtitle(track.id)
            } else if stream.IsExternal == true || stream.DeliveryMethod == "External" {
                addExternalSubtitle(stream)
            }
        } else if streams == nil,
                  let track = tracks.first(where: { $0.kind == .sub && $0.isDefault }) {
            engine.selectSubtitle(track.id)
        }
    }

    /// Which tracks to ask for, from the file's own list: what was chosen for
    /// this series last time, then the languages in Settings. `nil` leaves a
    /// choice to the server; `-1` for the subtitle is none.
    private func preferredStreams(in source: MediaSource, seriesId: String?) -> (audio: Int?, subtitle: Int?) {
        let audioStreams = source.audioStreams
        let subtitleStreams = source.subtitleStreams
        let saved = seriesId.flatMap { prefs.trackChoice(seriesId: $0) }

        let defaultAudio = audioStreams.first { $0.Index == source.DefaultAudioStreamIndex }
            ?? audioStreams.first { $0.IsDefault ?? false }
            ?? audioStreams.first

        var audio: MediaStream?
        for want in [saved?.audio, prefs.audioLanguage] {
            guard let want, !want.isEmpty else { continue }
            if let match = audioStreams.first(where: { Languages.matches(preference: want, tag: $0.Language) }) {
                audio = match
                break
            }
        }
        let audioIndex = audio?.Index == defaultAudio?.Index ? nil : audio?.Index

        // With the sound already in the preferred language, "forced only"
        // means the track that translates signs and the odd foreign line.
        let audioMatches = Languages.matches(
            preference: prefs.audioLanguage, tag: (audio ?? defaultAudio)?.Language
        )
        var subtitle: Int?
        for (want, fromSettings) in [(saved?.sub, false), (prefs.subtitleLanguage, true)] {
            guard let want, !want.isEmpty else { continue }
            if want == "off" {
                subtitle = subtitleStreams.isEmpty ? nil : -1
                break
            }
            let candidates = subtitleStreams.filter { Languages.matches(preference: want, tag: $0.Language) }
            if fromSettings, prefs.forcedSubtitlesOnly, audioMatches {
                subtitle = candidates.first(where: \.isForced)?.Index ?? (subtitleStreams.isEmpty ? nil : -1)
                break
            }
            if let pick = candidates.first(where: { !$0.isForced }) ?? candidates.first {
                subtitle = pick.Index
                break
            }
        }
        return (audioIndex, subtitle)
    }

    /// Record a track choice against the series, so its next episode opens
    /// with the same one.
    private func rememberTrackChoice(
        audioLanguage: String? = nil, subtitleLanguage: String? = nil, subtitleOff: Bool = false
    ) {
        guard let seriesId = item?.SeriesId else { return }
        var choice = prefs.trackChoice(seriesId: seriesId) ?? .init(audio: nil, sub: nil)
        if let audioLanguage { choice.audio = audioLanguage }
        if let subtitleLanguage { choice.sub = subtitleLanguage }
        if subtitleOff { choice.sub = "off" }
        prefs.setTrackChoice(choice, seriesId: seriesId)
    }

    private static func label(_ track: MPVEngine.Track) -> String {
        let parts = [track.title, track.language.map { Languages.name(for: $0) }, track.codec?.uppercased()]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Track \(track.id)" : parts.joined(separator: " · ")
    }

    // MARK: - Subtitle appearance

    /// Size and background from Settings, as mpv's subtitle options. Applied
    /// live, so a change in Settings can be judged against the picture.
    func refreshSubtitleStyling() {
        guard let engine else { return }
        let scale = max(0.5, min(2.0, prefs.subtitleSize / 100))
        engine.set("sub-scale", String(format: "%.2f", scale))
        engine.set("sub-font", "Helvetica Neue")
        engine.set("sub-color", "#FFFFFFFF")
        switch prefs.subtitleBackground {
        case .outline:
            engine.set("sub-border-style", "outline-and-shadow")
            engine.set("sub-outline-size", "2.5")
            engine.set("sub-outline-color", "#FF000000")
            engine.set("sub-shadow-offset", "0")
        case .shadow:
            engine.set("sub-border-style", "outline-and-shadow")
            engine.set("sub-outline-size", "0")
            engine.set("sub-shadow-offset", "2")
            engine.set("sub-shadow-color", "#C0000000")
        case .box:
            engine.set("sub-border-style", "background-box")
            engine.set("sub-back-color", "#BF000000")
            engine.set("sub-outline-size", "0")
            engine.set("sub-shadow-offset", "0")
        }
    }

    // MARK: - Quality

    /// Open the stream again at another quality, where it is. nil asks for the
    /// original file.
    func switchQuality(to bitrate: Int?) async {
        guard let item, !isExternal, !isLive || bitrate != currentBitrate else { return }
        var opts = options
        opts.maxBitrate = bitrate
        opts.bitrateIsChosen = true
        opts.forceTranscode = false
        opts.startSeconds = isLive ? nil : position
        await play(item: item, options: opts, meta: StartMeta(inherited: true))
    }

    // MARK: - Progress reporting

    private static let reportInterval: TimeInterval = 10

    private func maybeReport() {
        guard isActive, !isExternal, !isOpening,
              Date().timeIntervalSince(lastReportAt) >= Self.reportInterval else { return }
        lastReportAt = Date()
        Task { await client.reportPlaybackProgress(report(paused: isPaused)) }
    }

    private func reportNow() async {
        guard isActive, !isExternal else { return }
        lastReportAt = Date()
        await client.reportPlaybackProgress(report(paused: isPaused))
    }

    private func report(paused: Bool, position override: Double? = nil) -> PlaybackReport {
        var report = PlaybackReport(
            itemId: item?.Id ?? "",
            mediaSourceId: source?.mediaSourceId,
            playSessionId: source?.playSessionId,
            positionSeconds: override ?? position,
            isPaused: paused,
            isTranscode: isTranscoding,
            rate: speed,
            volume: volume
        )
        if !isTranscoding { report.PlayMethod = "DirectPlay" }
        report.AudioStreamIndex = options.audioStreamIndex
        report.SubtitleStreamIndex = options.subtitleStreamIndex
        return report
    }

    // MARK: - Per-item extras

    private func loadExtras(for item: BaseItem) async {
        let itemId = item.Id
        let needsDetail = item.Overview?.isEmpty != false
            || item.People?.isEmpty != false
            || item.MediaSources?.isEmpty != false
        async let segmentsTask = client.mediaSegments(itemId: itemId)
        async let detailTask = needsDetail ? try? client.item(itemId) : nil
        let loadedSegments = (try? await segmentsTask) ?? []
        let loadedDetail = await detailTask ?? nil
        guard self.item?.Id == itemId else { return }
        segments = loadedSegments
        trickplay = JellyfinClient.trickplayInfo(for: loadedDetail ?? item)
        fullItem = loadedDetail ?? item
        await refreshUpNext()
    }

    private func refreshCues() {
        let segment = currentSegment()
        if segment != activeSegment { activeSegment = segment }
        let due = upNextIsDue()
        if due != shouldShowUpNext { shouldShowUpNext = due }
    }

    /// How close to the end of a file counts as at the end.
    private static let segmentTailSlack: Double = 1.5

    private func currentSegment() -> MediaSegment? {
        guard duration > 0 else { return nil }
        return segments.first {
            guard position >= $0.start, position < $0.end - 1 else { return false }
            return $0.isOutro || $0.end < duration - Self.segmentTailSlack
        }
    }

    func skipSegment() {
        guard let segment = activeSegment else { return }
        guard segment.end < duration - Self.segmentTailSlack else {
            // Credits that run to the end: skipping them is reaching it.
            handleReachedEnd()
            return
        }
        seek(to: segment.end)
    }

    // MARK: - Up Next and autoplay

    func cancelAutoplay() { autoplayCancelled = true }
    func resumeAutoplay() { autoplayCancelled = false }

    /// Seconds left, for the Up Next countdown.
    var secondsRemaining: Double {
        duration > 0 ? max(0, duration - position) : .infinity
    }

    var upNextTitle: String? { upNext.map(Self.displayTitle) }

    private func upNextIsDue() -> Bool {
        guard !autoplayCancelled, prefs.autoplayNext, duration > 0, upNext != nil else { return false }
        return secondsRemaining <= 25 && secondsRemaining > 0
    }

    private func refreshUpNext() async {
        guard let item, item.isEpisode, let seriesId = item.SeriesId else { return }
        let found = await lookUpNextEpisode(after: item, seriesId: seriesId)
        guard self.item?.Id == item.Id else { return }
        if found.settled { upNextSettled = true }
        if let next = found.next { upNext = next }
    }

    /// Next in the season, else the first of the next season. `settled` says
    /// every request needed was answered — nil with it is a series that ended.
    private func lookUpNextEpisode(after item: BaseItem, seriesId: String) async -> (next: BaseItem?, settled: Bool) {
        guard let episodes = try? await client.episodes(seriesId: seriesId, seasonId: item.SeasonId) else {
            return (nil, false)
        }
        if let i = episodes.firstIndex(where: { $0.Id == item.Id }), i + 1 < episodes.count {
            return (episodes[i + 1], true)
        }
        guard let seasons = try? await client.seasons(seriesId: seriesId) else { return (nil, false) }
        guard let si = seasons.firstIndex(where: { $0.Id == item.SeasonId }), si + 1 < seasons.count else {
            return (nil, true)
        }
        guard let nextEpisodes = try? await client.episodes(seriesId: seriesId, seasonId: seasons[si + 1].Id) else {
            return (nil, false)
        }
        return (nextEpisodes.first, true)
    }

    /// Start the next episode now rather than waiting for this one to end.
    func playNextNow() async {
        guard !isStartingNext else { return }
        isStartingNext = true
        defer { isStartingNext = false }
        _ = await advanceToNext()
    }

    private func handleReachedEnd() {
        if isLive, isActive {
            Self.log.notice("live stream reported its end; reopening")
            reopenLive()
            return
        }
        position = duration
        Task {
            guard !autoplayCancelled, prefs.autoplayNext else {
                await finish(userRequested: false)
                return
            }
            guard !autoplayInFlight else { return }
            autoplayInFlight = true
            let started = await advanceToNext()
            autoplayInFlight = false
            if !started { await finish(userRequested: false) }
        }
    }

    private func advanceToNext() async -> Bool {
        var candidate = upNext
        if candidate == nil, !upNextSettled, let item, item.isEpisode, let seriesId = item.SeriesId {
            candidate = await lookUpNextEpisode(after: item, seriesId: seriesId).next
        }
        guard let next = candidate else { return false }
        // The episode that ended is reported finished before the next starts.
        if let item, !isExternal {
            await client.reportPlaybackStopped(report(paused: true, position: duration))
            _ = item
        }
        var opts = options
        opts.startSeconds = nil
        opts.resume = true
        opts.audioStreamIndex = nil
        opts.subtitleStreamIndex = nil
        await play(item: next, options: opts, meta: StartMeta(inherited: true, quiet: true))
        return true
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let seconds = Double(max(1, minutes)) * 60
        let deadline = Date().addingTimeInterval(seconds)
        sleepDeadline = deadline
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.sleepTimerElapsed(deadline)
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
    }

    var sleepMinutesRemaining: Int? {
        guard let sleepDeadline else { return nil }
        return max(1, Int((sleepDeadline.timeIntervalSinceNow / 60).rounded(.up)))
    }

    private func checkSleepDeadline() {
        guard let sleepDeadline, Date() >= sleepDeadline else { return }
        Task { await sleepTimerElapsed(sleepDeadline) }
    }

    private func sleepTimerElapsed(_ deadline: Date) async {
        guard sleepDeadline == deadline else { return }
        sleepDeadline = nil
        sleepTask = nil
        cancelAutoplay()
        await finish(userRequested: true, reason: "sleep timer")
    }

    // MARK: - Audio session

    private var observers: [NSObjectProtocol] = []

    private func configureAudioSession(activate: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        if activate { try? session.setActive(true) }
    }

    /// The television going to sleep takes the HDMI route, and with it the
    /// session. When it comes back, the session is made active again and mpv
    /// is told to open its audio output afresh against the route that exists
    /// now.
    private func observeAudioRoute() {
        let centre = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            MainActor.assumeIsolated { self?.recoverAudio() }
        })
        observers.append(centre.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
            case .newDeviceAvailable, .routeConfigurationChange, .override:
                MainActor.assumeIsolated { self?.recoverAudio() }
            default:
                break
            }
        })
        observers.append(centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureAudioSession(activate: false)
                self?.recoverAudio()
            }
        })
    }

    private func recoverAudio() {
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        engine?.command(["ao-reload"])
    }

    /// Going to the background takes the drawable away from mpv; the video
    /// track is let go of on the way out and picked up on the way back, which
    /// is what keeps the picture from coming back black.
    private func observeLifecycle() {
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.pause()
                self.engine?.set("vid", "no")
            }
        })
        observers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.engine?.set("vid", "auto")
                self.recoverAudio()
                self.checkSleepDeadline()
            }
        })
    }

    #if DEBUG
    /// Launched with `-AquariumPlayURL <url>`, play that URL straight away:
    /// for trying the player in the simulator without a server to sign in to.
    func playDebugStreamIfAsked() {
        guard let string = UserDefaults.standard.string(forKey: "AquariumPlayURL"),
              let url = URL(string: string) else { return }
        playExternal(title: url.lastPathComponent, subtitle: url.host ?? "", artworkURL: nil, streamURL: url)
        // A file, not a channel: seekable, and it ends.
        isLive = false
    }
    #endif

    // MARK: - Helpers

    static func displayTitle(_ item: BaseItem) -> String {
        if item.isEpisode, let series = item.SeriesName {
            let label = item.episodeLabel.map { " · \($0)" } ?? ""
            return "\(series)\(label) · \(item.title)"
        }
        return item.title
    }

    /// The chapter containing `seconds`.
    func chapter(at seconds: Double) -> Chapter? {
        chapters.last { $0.start <= seconds }
    }
}

#endif
