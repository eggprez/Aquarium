//  The player: Jellyfin on one side, an engine on the other.
//
//  One class for iPhone, iPad, Mac and Apple TV. It owns the Jellyfin half of
//  playing something — which stream to ask for, where it resumes, what to
//  report, which track the viewer wants, what comes next, the queue, the sleep
//  timer, Now Playing, Live TV recovery — and drives a `PlaybackEngine` for the
//  decoding. The engine is AVPlayer (`AVEngine`) or libmpv (`MPVEngine`),
//  chosen per stream by `EnginePolicy` (`PlayerModel+Engine`): AVPlayer by
//  default on anything with a battery, mpv when the file or the viewer asks
//  for something AVPlayer cannot give, mpv always on the Apple TV. The
//  AVPlayer engine lives for the life of the app, since SharePlay and the
//  AirPlay picker want its player before anything plays; the mpv handle is
//  made when a stream needs it and destroyed when the player comes down.
//
//  Everything outside the player — the library, the guide, Settings, the Now
//  Playing card — calls `PlayerModel.shared.play(item:)` and never learns which
//  engine is underneath. Each engine reports through one `AsyncStream` of
//  `EngineEvent`s, drained in `handle` below; the Jellyfin orchestration hangs
//  off that one stream rather than off either engine's own observers.
//
//  The file is split: this one holds the state, the engine wiring, the event
//  handling and the transport; `PlayerModel+Playback` starts and recovers
//  streams on every platform; `PlayerModel+Engine` chooses the engine and
//  hands a stream from one to the other; `PlayerModel+Tracks` the track menus,
//  subtitles and the audio offset; `PlayerModel+Extras` the queue, Up Next,
//  reporting and the read-outs; `PlayerModel+Chrome` what the shared chrome
//  asks. One shape on every platform: the Apple TV has a queue like the rest,
//  no downloads (so `isLocal` is simply false there), and the few things that
//  are its alone — the display's frame rate, the screensaver, the sync clips'
//  code — sit behind the one `#if os(tvOS)` each needs.

import Foundation
import OSLog

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Call-shaped values

/// How a stream came to be started, for the things that care about the
/// difference. Kept apart from the options because it describes the *call*, not
/// the stream — it must not survive into the next one.
struct StartMeta: Sendable {
    /// The bitrate wasn't a fresh choice by the user, it carried over from the
    /// last stream. Adaptive quality keeps its ceiling across these, so one bad
    /// stretch of network doesn't pin a whole binge to 1.5 Mbps.
    var inherited: Bool = false
    var quiet: Bool = false
    /// The stall watchdog opening a live stream again rather than anyone
    /// choosing to play something. Must not be counted as a fresh start, or
    /// the budget of attempts resets on every attempt.
    var reopening: Bool = false
    /// The player quietly reopening after the session behind it went bad.
    var recovering: Bool = false
    /// Autoplay carrying a subtitle-forced transcode into the next episode,
    /// and with it the way back to direct play once that subtitle is off.
    var carriesSubtitleTranscode: Bool = false
    /// The same title reopened for a different audio or subtitle track. Loaded
    /// straight away rather than handed over: a hand-over opens the new
    /// stream twelve seconds ahead and swaps when the playhead gets there,
    /// which for a quality change is seamless and for a subtitle is twelve
    /// seconds of the old stream with none, under a menu saying it is on.
    var forTracks: Bool = false
}

struct StreamOptions: Sendable {
    /// nil = direct play; a number forces a transcode at that bitrate.
    var maxBitrate: Int?
    /// Whether `maxBitrate` is an answer or an absence, so "direct play" and
    /// "nobody said" aren't confused — see the long note this replaces.
    var bitrateIsChosen: Bool = false
    var forceTranscode: Bool = false
    /// Make the server encode picture and sound together rather than copying
    /// either bitstream through — the one lever that reaches a transcode
    /// desync at its cause. Implies `forceTranscode`.
    var forceFullEncode: Bool = false
    var resume: Bool = true
    var live: Bool = false
    /// Explicit start position, overriding resume.
    var startSeconds: Double?
    /// The tracks this stream was asked for, in the server's own numbering.
    /// `nil` leaves it to the server; `-1` for the subtitle means none.
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
}

/// One entry in a track menu. `avIndex` (here, the engine's track id) says the
/// track is in the stream that is playing and choosing it costs a frame;
/// `serverIndex` says the server has it and this stream does not, and choosing
/// it costs a new stream.
struct TrackOption: Identifiable, Hashable, Sendable {
    var serverIndex: Int?
    var avIndex: Int?
    var label: String
    var language: String?
    var isForced: Bool

    var needsNewStream: Bool { avIndex == nil }
    var id: Int { serverIndex ?? -(( avIndex ?? 0) + 1) }
}

/// One selectable track as the engine lists it, the shape the menus are
/// built on, made from `EngineTrack` on every engine.
struct PlayerTrack: Identifiable, Hashable, Sendable {
    var id: Int
    var label: String
    var language: String?
    var isForced: Bool
}

struct Chapter: Identifiable, Hashable, Sendable {
    var id: Int
    var start: Double
    var title: String
}

@MainActor
@Observable
final class PlayerModel {
    static let shared = PlayerModel()

    /// Every way the player comes down is written here with why.
    /// `log show --predicate 'subsystem == "<bundle id>"'`.
    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "player")

    // MARK: - Published state

    var isActive = false { didSet { holdScreenAwake() } }
    var isPaused = false { didSet { holdScreenAwake() } }
    /// Waiting on the network, or opening: the spinner.
    var isBuffering = false
    /// Between asking for a stream and its first frame.
    var isOpening = false
    var position: Double = 0
    var duration: Double = 0
    /// How far ahead the cache reaches, in stream seconds.
    var buffered: Double = 0
    var title = ""
    var subtitle = ""
    var isLive = false
    /// A channel from an M3U playlist rather than Jellyfin: no session on the
    /// other end, so nothing is reported for it.
    var isExternal = false
    var errorMessage: String?

    var item: BaseItem?
    var artworkURL: URL?
    /// The whole item, fetched while the stream opens, for the Info panel.
    var fullItem: BaseItem?
    var trickplay: TrickplayInfo?
    var segments: [MediaSegment] = [] { didSet { refreshCues() } }

    /// The episodes the series has left after this one, in order, across
    /// seasons — as many as the Up Next list shows (`PlayerModel.upNextLimit`).
    /// Empty until `refreshUpNext` has looked, and for anything but an episode.
    var upcoming: [BaseItem] = [] { didSet { refreshCues() } }
    /// The one that plays next by itself.
    var upNext: BaseItem? { upcoming.first }
    /// How many titles the Up Next list shows at most.
    static let upNextLimit = 5
    var isStartingNext = false
    var autoplayCancelled = false { didSet { refreshCues() } }
    /// The intro or credits sequence the playhead is in, if any.
    var activeSegment: MediaSegment?
    /// Whether the Up Next card should be on screen.
    var shouldShowUpNext = false

    var sleepDeadline: Date?
    /// The quality rung the stream was asked for; nil for the original file.
    var currentBitrate: Int?
    var isTranscoding = false

    /// The picture's display size, once there is one.
    var videoSize: CGSize = .zero
    var frameRate: Double?
    /// `videotoolbox`, or `no` when the engine is decoding in software.
    var decoder: String?
    var droppedFrames = 0

    /// What the engine found in the stream, as last reported.
    var tracks: [EngineTrack] = []

    var speed: Double = 1 { didSet { engine?.rate = speed } }
    var volume: Double = 1 {
        didSet {
            engine?.volume = volume
            Preferences.shared.volume = volume
        }
    }

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func speedName(_ rate: Double) -> String {
        rate == 1 ? "Normal" : "\(rate.formatted())×"
    }

    /// Whether what the surface shows belongs to something else. An engine
    /// leaves its last frame on the layer when a file stops, so a new title
    /// would open over the last one's final frame without this. Cleared by
    /// the new title's first frame; the screen covers the picture while it
    /// is set.
    var pictureIsStale = true

    /// A download playing from this device. Never on the Apple TV, which has
    /// no downloads; the chrome reads it all the same.
    var isLocal = false
    /// The asset turned out to have no video track once it was ready — an
    /// IPTV channel carrying a codec no Apple platform decodes.
    var noVideoTrack = false
    /// What the stream turned out to contain, once it has been looked at — see
    /// `StreamDiagnosis`.
    var noVideoDetail: String?
    /// The size of the picture being shown; the Mac's player window takes its
    /// shape from it.
    var pictureSize: CGSize = .zero
    var isMuted = false { didSet { engine?.isMuted = isMuted } }

    /// The AVPlayer engine, which exists from init so its `player` is there
    /// for the AirPlay picker and the SharePlay coordinator before anything
    /// plays. Reached as `(engine as? AVEngine)?.player` while it is the one
    /// playing, and as `appleEngine.player` by the AirPlay picker, which
    /// needs an `AVPlayer` whichever engine is on. On the Apple TV it is
    /// never the one playing.
    let appleEngine = AVEngine()

    #if canImport(Libmpv)
    /// The surface mpv draws into, hosted by `VideoSurface` while the mpv
    /// engine is the one playing. One for the life of the app; the handle
    /// drawing into it is made per stream.
    let mpvLayer = MPVMetalLayer()
    #endif

    // MARK: - Internals

    var engine: (any PlaybackEngine)?
    #if canImport(Libmpv)
    /// The mpv handle, while a stream is on it. Made by `makeEngine(.mpv)`,
    /// destroyed by `finish` so nothing of mpv runs while the app browses.
    var mpvEngine: MPVEngine?
    #endif
    /// One task per engine, for the engine's life: an `AsyncStream` ends when
    /// the task reading it is cancelled, so the AVPlayer engine's — which
    /// lives for the app — is never cancelled, and the mpv engine's ends when
    /// its handle is destroyed.
    private var engineEventsTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// An engine the viewer asked for on this title — the Picture tab's
    /// "switch for this title", Picture in Picture's hand-over — carried
    /// through its reopens and dropped when the title changes.
    var engineOverride: PlaybackEngineKind?
    /// The stream was on mpv until Picture in Picture or AirPlay asked for
    /// AVPlayer; when that ends it goes back.
    var returnsToMPV = false
    /// Software decode was already answered on this stream.
    var softwareDecodeHandled = false

    var source: PlaybackSource?
    var options = StreamOptions()
    /// Whichever tracks the stream opening was asked for, applied once the
    /// engine lists what is in it.
    var wantedTracks: (audio: Int?, subtitle: Int?) = (nil, nil)
    var tracksApplied = false
    var upNextSettled = false
    var upNextChecked = false
    var autoplayInFlight = false
    var sleepTask: Task<Void, Never>?
    var lastReportAt = Date.distantPast
    /// Bumped by everything that starts or ends a stream, so work begun for one
    /// stream never lands on the next. Read before an await, compared after.
    var generation = 0
    /// Between a stream being asked for and its going to the engine: whatever
    /// the engine says then is about the file before, and would be taken for
    /// the new one's first frame, tracks and position.
    var awaitingLoad = false
    /// The just-chosen tracks, waiting for the stream opened for them.
    var pendingTrackChoice: (audio: Int?, subtitle: Int?)?
    /// Set when a subtitle forced this stream to be one the server builds, so
    /// turning it off can hand the direct play back.
    var transcodingForSubtitle = false

    /// Registered for the life of the player, unlike the per-stream work.
    var routeObservers: [NSObjectProtocol] = []
    /// The address the current stream is really being read from — what a
    /// reopen for an audio offset and `StreamDiagnosis` are pointed at.
    var currentStreamURL: URL?
    /// The start still waiting on the server for its stream, so a reopen
    /// for an audio offset doesn't put the old stream back under a new title.
    var resolvingGeneration: Int?
    /// Whether subtitles are lifted clear of a transport bar.
    var subtitlesRaised = false

    var client: JellyfinClient { .shared }
    var prefs: Preferences { .shared }

    let adaptive = AdaptiveQuality()
    /// What Now Playing was last told, so its clock is only re-anchored when
    /// it would otherwise be wrong.
    var nowPlayingAnchor: (position: Double, rate: Double, at: Date, duration: Double)?
    /// A change of bitrate the connection caused: on screen a few seconds,
    /// then gone.
    struct BitrateNotice: Equatable, Identifiable, Sendable {
        let id = UUID()
        var isUp: Bool
        var headline: String
        var detail: String
    }
    var bitrateNotice: BitrateNotice?
    @ObservationIgnored var bitrateNoticeDismissal: Task<Void, Never>?

    #if !os(tvOS)
    /// The download playing now, as the server hears about it.
    @ObservationIgnored var localSession: OfflineProgress.Session?
    #endif
    var localRecordId: String?
    var episodeQueue: [BaseItem]?
    /// Titles queued by hand, played ahead of what the series would offer.
    var queue: [BaseItem] = [] {
        didSet {
            refreshCues()
            NowPlaying.shared.refreshCommandAvailability()
        }
    }
    func setQueue(_ q: [BaseItem]) { queue = q }
    var upNextLocalId: String? { didSet { refreshCues() } }
    func setUpNextLocalId(_ id: String?) { upNextLocalId = id }

    /// The next title's stream, asked for before this one ends.
    var prefetched: PrefetchedNext?
    var prefetchAttempted = false
    var preparedStream: (any PreparedStream)?
    struct PrefetchedNext {
        var itemId: String
        var source: PlaybackSource
        var prepared: (any PreparedStream)?
        var maxBitrate: Int?
        var forceTranscode: Bool
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var startTicks: Int64
        /// The engine the stream was asked for with.
        var engine: PlaybackEngineKind
    }
    /// The series being shuffled over downloaded episodes.
    var shuffleSeries: DownloadShuffleState?
    struct DownloadShuffleState {
        var seriesId: String?
        var seriesName: String?
        var seen: Set<String>
        /// The downloads this shuffle draws from: a season's, when it was
        /// started from a season. Nil is every download of the series.
        var pool: Set<String>? = nil
    }

    /// Set while an interruption is in force, so a route change in the same
    /// breath doesn't recover twice.
    var audioWasInterrupted = false
    /// Whether the item now in the player is a composition carrying an offset.
    var audioDelayIsApplied = false
    func setAudioDelayApplied(_ applied: Bool) { audioDelayIsApplied = applied }

    /// A channel that came from a custom M3U playlist rather than Jellyfin.
    struct ExternalChannel {
        var title: String
        var subtitle: String
        var artworkURL: URL?
        var streamURL: URL
        var item: BaseItem?
        /// Where the resolver last found this channel's stream, so a reopen
        /// doesn't walk the redirect chain again.
        var resolvedURL: URL?
    }
    var externalChannel: ExternalChannel?
    var externalResolve: Task<Void, Never>?

    // Live stall recovery.
    var liveWatchdog: Task<Void, Never>?
    var lastAdvance: (at: Date, position: Double)?
    var liveReconnects = 0
    var lastReopenAt = Date.distantPast
    var isReopeningLive = false
    var jumpedToEdgeAt = Date.distantPast
    var jumpedForThisStall = false

    // Quiet reopen after the session behind a stream failed.
    var streamRecoveries = 0
    var lastRecoveryAt: Date?

    /// Reading what a channel with no picture actually contains.
    var diagnosis: Task<Void, Never>?

    /// The variant bitrate last seen, for the notice when it steps.
    var lastVariantBitrate: Double?
    var isResyncing = false
    func setBitrateNotice(_ notice: BitrateNotice?) { bitrateNotice = notice }

    // Non-tvOS track menus are built on these.
    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    var selectedAudioTrack: Int?
    var selectedSubtitleTrack: Int?
    var chapters: [Chapter] = []
    func setAudioTracks(_ a: [PlayerTrack]) { audioTracks = a }
    func setSubtitleTracks(_ s: [PlayerTrack]) { subtitleTracks = s }
    func setSelectedAudioTrack(_ i: Int?) { selectedAudioTrack = i }
    func setSelectedSubtitleTrack(_ i: Int?) { selectedSubtitleTrack = i }
    func setChapters(_ c: [Chapter]) { chapters = c }

    /// Which of the sync clips is playing, by the rate it sets the delay for.
    var syncTest: DelayRate?
    var isSyncTest: Bool { syncTest != nil }
    /// The opening or the seek being watched for a stalled audio output —
    /// see `watchOpening` and `watchSeek`.
    var seekWatch: Task<Void, Never>?
    #if os(tvOS)
    /// Whether the display has been asked to match this stream's frame rate.
    var displayRequested = false
    var lastAwakeAssert: CFTimeInterval = 0
    #endif

    /// Whether the audio session has been given this app's category. Set
    /// after the first frame, or by the first playback — see
    /// `reactivateAudioSession`. Setting it is a round trip to the audio
    /// server, and it used to happen in this init, inside the app's own.
    @ObservationIgnored var audioSessionConfigured = false

    private init() {
        Launch.mark("player init")
        volume = prefs.volume
        #if !os(tvOS)
        // The Apple TV's engine is made per stream; the others have AVPlayer
        // standing by for the AirPlay picker and SharePlay.
        engine = appleEngine
        wireEngineEvents(for: appleEngine)
        configure(appleEngine)
        #endif
        observeForeground()
        observePower()
        NowPlaying.shared.attach(to: self)
        Launch.afterFirstFrame { [self] in
            if !audioSessionConfigured { configureAudioSession(activate: false) }
        }
        observeAudioRoute()
        observeLifecycle()
        Launch.mark("player init done")
    }

    /// The engine of `kind`, made if it isn't there, with the event stream
    /// pointed at `handle`. The AVPlayer engine exists from init; the mpv
    /// handle is made here and kept for the session, so a title reopened for
    /// a track or a quality plays on until the new file is in. Asking for the
    /// other kind shuts the mpv handle down. Nil when the kind cannot be made
    /// on this build.
    @discardableResult
    func makeEngine(_ kind: PlaybackEngineKind) -> (any PlaybackEngine)? {
        switch kind {
        case .apple:
            #if os(tvOS)
            Self.log.error("AVPlayer is not an engine on the Apple TV")
            return nil
            #else
            tearDownMPV()
            if engine !== appleEngine {
                engine = appleEngine
                configure(appleEngine)
            }
            return appleEngine
            #endif
        case .mpv:
            #if canImport(Libmpv)
            if let mpvEngine { return mpvEngine }
            guard let made = MPVEngine(layer: mpvLayer, tuning: mpvTuning) else {
                Self.log.error("mpv could not be created")
                return nil
            }
            appleEngine.stop()
            mpvEngine = made
            engine = made
            wireEngineEvents(for: made)
            configure(made)
            Self.log.info("mpv engine made (\(self.mpvTuning.demuxerMaxBytes, privacy: .public) cache)")
            return made
            #else
            Self.log.error("mpv is not in this build")
            return nil
            #endif
        }
    }

    /// What every engine is told as it becomes the one playing.
    private func configure(_ engine: any PlaybackEngine) {
        engine.volume = volume
        engine.isMuted = isMuted
        engine.rate = speed
        refreshSubtitleStyling()
        applyFraming()
        applyPicture()
        applyNightMode()
        refreshPowerProfile()
        NowPlaying.shared.attach(to: self)
    }

    /// Destroy the mpv handle, if there is one. On an iPhone, iPad or Mac the
    /// AVPlayer engine is the one left in `engine`, so the AirPlay picker and
    /// SharePlay have their player; on the Apple TV nothing is.
    func tearDownMPV() {
        #if canImport(Libmpv)
        guard let mpvEngine else { return }
        #if os(iOS)
        mpvEngine.hintContentFrameRate(nil)
        #endif
        mpvEngine.shutdown()
        engineEventsTasks[ObjectIdentifier(mpvEngine)] = nil
        self.mpvEngine = nil
        Self.log.info("mpv engine destroyed")
        #if os(tvOS)
        engine = nil
        #else
        engine = appleEngine
        #endif
        #endif
    }

    private func wireEngineEvents(for engine: any PlaybackEngine) {
        let id = ObjectIdentifier(engine)
        engineEventsTasks[id]?.cancel()
        let events = engine.events
        engineEventsTasks[id] = Task { [weak self, weak engine] in
            for await event in events {
                guard let self, let engine else { return }
                self.handle(event, from: engine)
            }
        }
    }

    // MARK: - Engine events

    private func handle(_ event: EngineEvent, from source: any PlaybackEngine) {
        // Only the engine playing is listened to: the AVPlayer engine is
        // still wired while mpv has the stream, and says nothing of interest.
        guard source === engine, isActive, !awaitingLoad else { return }
        switch event {
        case .position(let seconds):
            #if os(tvOS)
            keepScreenAwake()
            #endif
            position = seconds
            // The first frame is the usual way the cover comes off; a stream
            // whose engine says nothing of one comes out from under it on
            // its first tick of playing.
            if pictureIsStale, !isOpening, !isBuffering, seconds > 0 {
                Self.log.info("cover off on the first tick of playing")
                pictureIsStale = false
            }
            refreshCues()
            maybeReport()
            checkSleepDeadline()
            NowPlaying.shared.updateElapsed(seconds, rate: isPaused ? 0 : speed)
            onPositionTick(seconds)

        case .duration(let seconds):
            let d = seconds.isFinite ? max(0, seconds) : 0
            if d != duration { duration = d }
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
            if seconds.isFinite { buffered = seconds }

        case .tracks(let list):
            tracks = list
            onTracks(list)

        case .chapters(let list):
            onChapters(list)

        case .videoSize(let size):
            videoSize = size
            if pictureSize != size { pictureSize = size }
            noVideoTrack = false

        case .frameRate(let rate):
            frameRate = rate > 0 ? rate : nil
            onFrameRate(rate)

        case .decoder(let name):
            if name != decoder {
                Self.log.info("decoder: \(name, privacy: .public) (\(self.engine?.kind.title ?? "no engine", privacy: .public))")
            }
            decoder = name
            onDecoder(name)

        case .droppedFrames(let count):
            droppedFrames = count

        case .variantChanged(let bitsPerSecond):
            onVariantChanged(bitsPerSecond)

        case .rate(let rate):
            if abs(rate - speed) > 0.001 { speed = rate }

        case .audioDelayApplied(let delay, let refused):
            onAudioDelayApplied(delay, refused: refused)

        case .fileLoaded:
            break

        case .firstFrame:
            onFirstFrame()

        case .noPicture:
            onNoPicture()

        case .ended(let reason):
            if case .finished = reason { handleReachedEnd() }

        case .failed(let failure):
            handleStreamFailure(failure)
        }
    }

    private func onFirstFrame() {
        Self.log.info("first frame on \(self.engine?.kind.title ?? "-", privacy: .public) (was opening: \(self.isOpening, privacy: .public), cover: \(self.pictureIsStale, privacy: .public))")
        if isOpening {
            isOpening = false
            adaptive.noteOpened()
            NowPlaying.shared.update(from: self)
        }
        isBuffering = false
        pictureIsStale = false
        seekWatch?.cancel(); seekWatch = nil
        holdScreenAwake(reassert: true)
    }

    // MARK: - Starting and stopping state

    /// Everything that belongs to one stream, cleared before the next opens.
    func resetStreamState() {
        errorMessage = nil
        position = 0
        duration = 0
        buffered = 0
        isPaused = false
        tracks = []
        segments = []
        trickplay = nil
        upcoming = []
        upNextSettled = false
        upNextChecked = false
        tracksApplied = false
        activeSegment = nil
        shouldShowUpNext = false
        videoSize = .zero
        frameRate = nil
        decoder = nil
        droppedFrames = 0
        softwareDecodeHandled = false
        syncTest = nil
        seekWatch?.cancel(); seekWatch = nil
        #if os(tvOS)
        displayRequested = false
        #endif
        noVideoTrack = false
        noVideoDetail = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        chapters = []
        bitrateNoticeDismissal?.cancel()
        bitrateNotice = nil
    }

    /// Give back what a source holds on the server: its encode, and the tuner
    /// behind a live channel.
    func release(_ src: PlaybackSource) async {
        if src.isTranscode { await client.stopTranscode(playSessionId: src.playSessionId) }
        if let id = src.mediaSource.LiveStreamId, !id.isEmpty {
            await client.closeLiveStream(id: id)
        }
    }

    // MARK: - Transport

    func togglePlayPause() { isPaused ? resume() : pause() }

    func pause() {
        engine?.pause()
        isPaused = true
        postNowPlayingRate()
        Task { await reportNow() }
    }

    func resume() {
        reactivateAudioSession()
        engine?.play()
        isPaused = false
        postNowPlayingRate()
        Task { await reportNow() }
    }

    func seek(to seconds: Double) {
        guard isActive else { return }
        let target = duration > 0 ? min(max(0, seconds), duration - 0.5) : max(0, seconds)
        adaptive.noteSeek()
        position = target
        engine?.seek(to: target)
        refreshCues()
        watchSeek(to: target)
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func stepSpeed(_ direction: Int) {
        let current = Self.speeds.firstIndex { abs($0 - speed) < 0.001 } ?? Self.speeds.firstIndex(of: 1)!
        let next = min(max(current + direction, 0), Self.speeds.count - 1)
        speed = Self.speeds[next]
    }

    func stop(reason: String = "stop") {
        Task { await finish(userRequested: true, reason: reason) }
    }

    /// `generation`, for a caller outside that has to act on the stream it saw
    /// and not on whatever has replaced it since.
    var streamGeneration: Int { generation }

    func stop(reason: String, ifStill generation: Int) {
        guard self.generation == generation else { return }
        stop(reason: reason)
    }

    /// Take the player down, then settle with the server. The player comes
    /// down first, synchronously, before anything is awaited, so a start
    /// racing it has a clean board.
    func finish(userRequested: Bool, reason: String = "ended") async {
        guard isActive else { return }
        Self.log.info(
            "finish: \(reason, privacy: .public) live=\(self.isLive) external=\(self.isExternal) position=\(self.position, format: .fixed(precision: 1)) error=\(self.errorMessage ?? "none", privacy: .public)")
        generation &+= 1

        let finalPosition = position
        let closingReport = isExternal || isLocal ? nil : report(paused: true, position: finalPosition)
        let closingLocalId = localRecordId
        #if !os(tvOS)
        let closingLocalSession = localSession
        localSession = nil
        #endif
        dropPrefetched()
        let closingSource = source

        engine?.stop()
        pictureIsStale = true
        #if os(tvOS)
        engine?.setDisplayRefreshRate(nil)
        DisplayMatch.reset()
        #endif
        // Nothing of mpv runs while the app browses.
        tearDownMPV()
        engineOverride = nil
        returnsToMPV = false
        cancelSleepTimer()
        resetLiveRecovery()
        NowPlaying.shared.clear()
        resetStreamState()
        adaptive.reset()
        #if !os(tvOS)
        PlaybackHandoff.shared.end()
        #endif
        episodeQueue = nil
        localRecordId = nil
        externalChannel = nil
        externalResolve?.cancel(); externalResolve = nil
        if userRequested { shuffleSeries = nil }
        isActive = false
        isBuffering = false
        isOpening = false
        item = nil
        fullItem = nil
        source = nil
        isExternal = false
        isLive = false
        isTranscoding = false
        pendingTrackChoice = nil
        transcodingForSubtitle = false
        position = 0
        duration = 0

        #if !os(tvOS)
        if let closingLocalId {
            DownloadManager.shared.noteProgress(itemId: closingLocalId, positionSeconds: finalPosition)
            if let closingLocalSession {
                Task { await OfflineProgress.end(closingLocalSession) }
            } else {
                Task { await OfflineProgress.sync() }
            }
        }
        #else
        _ = closingLocalId
        #endif

        let liveStreamId = closingSource?.mediaSource.LiveStreamId
        async let reported: Void = {
            guard let closingReport else { return }
            await client.reportPlaybackStopped(closingReport)
        }()
        async let encodeStopped: Void = {
            guard let closingSource, closingSource.isTranscode else { return }
            await client.stopTranscode(playSessionId: closingSource.playSessionId)
        }()
        async let liveClosed: Void = {
            guard let liveStreamId, !liveStreamId.isEmpty else { return }
            await client.closeLiveStream(id: liveStreamId)
        }()
        _ = await (reported, encodeStopped, liveClosed)
        if closingReport != nil {
            Task { await LibraryIndex.shared.sync(minimumGap: 5) }
            #if os(tvOS)
            Task { await TopShelf.refresh() }
            #endif
        }
    }

    func retry() async {
        resetLiveRecovery()
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        if let channel = externalChannel {
            playExternal(title: channel.title, subtitle: channel.subtitle,
                         artworkURL: channel.artworkURL, streamURL: channel.streamURL, channel: channel.item)
            return
        }
        if let item {
            var opts = options
            opts.startSeconds = position > 1 ? position : nil
            await play(item: item, options: opts, meta: StartMeta(inherited: true))
        }
    }

    var canRetry: Bool { externalChannel != nil || item != nil }

    // MARK: - Helpers

    static func displayTitle(_ item: BaseItem) -> String {
        if item.isEpisode, let series = item.SeriesName {
            let label = item.episodeLabel.map { " · \($0)" } ?? ""
            return "\(series)\(label) · \(item.title)"
        }
        return item.title
    }

    /// `23.976 fps`, `25 fps`, `59.94 fps`.
    static func frameRateName(_ rate: Double, unit: String = "fps") -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...3)))) \(unit)"
    }

    var secondsRemaining: Double {
        duration > 0 ? max(0, duration - position) : .infinity
    }

    func refreshCues() {
        let segment = currentSegment()
        if segment != activeSegment { activeSegment = segment }
        let due = upNextIsDue()
        if due != shouldShowUpNext { shouldShowUpNext = due }
    }

    /// How close to the end of a file counts as *at* the end.
    static let segmentTailSlack: Double = 1.5

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
            handleReachedEnd()
            return
        }
        seek(to: segment.end)
    }

    /// The item behind what is on screen, wherever it came from.
    var infoItem: BaseItem? { fullItem ?? item ?? externalChannel?.item }
}
