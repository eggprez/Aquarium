//  The seam between the player and whatever decodes the picture.
//
//  `PlayerModel` is the Jellyfin half of the player: which stream to ask for,
//  what to report, which tracks the viewer wants, what comes next. Below it sit
//  the engines — AVPlayer in `AVEngine`, libmpv in `MPVEngine` — and this file
//  is the whole of what the model is allowed to know about either: the
//  commands it may give, the events it will hear back, and `EngineCapabilities`,
//  which says honestly what a given engine can do so the chrome never draws a
//  button that does nothing.
//
//  Nothing here is shaped like AVFoundation or like mpv. Positions are seconds,
//  tracks are numbered by the engine and, where the engine can read it, by the
//  file (`EngineTrack.fileIndex`, which is how Jellyfin numbers them too), and
//  everything an engine reports arrives on one `AsyncStream<EngineEvent>` that
//  the model drains on the main actor.

import CoreGraphics
import Foundation

/// Which engine plays a stream. Chosen per stream by `EnginePolicy`.
enum PlaybackEngineKind: String, Sendable, Hashable {
    /// AVPlayer: hardware decode, the system compositor, Picture in Picture,
    /// AirPlay and SharePlay for free; a narrow set of containers.
    case apple
    /// libmpv: the original file whatever it is, every picture control, an
    /// audio delay on any stream; a shader pass per frame.
    case mpv
}

/// What an engine can do. Read by the chrome before it draws a control and by
/// the model before it asks for something the engine would silently ignore.
struct EngineCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: UInt32

    static let pictureInPicture = EngineCapabilities(rawValue: 1 << 0)
    static let airPlay = EngineCapabilities(rawValue: 1 << 1)
    static let sharePlay = EngineCapabilities(rawValue: 1 << 2)
    /// `audioDelay` moves the sound on everything, HLS and live included,
    /// without reopening the stream. Without it the delay reaches only a
    /// file the engine was handed whole, and setting it reopens the stream.
    static let audioDelayOnAnyStream = EngineCapabilities(rawValue: 1 << 3)
    static let pictureAdjust = EngineCapabilities(rawValue: 1 << 4)
    static let zoom = EngineCapabilities(rawValue: 1 << 5)
    static let externalSubtitles = EngineCapabilities(rawValue: 1 << 6)
    static let nightMode = EngineCapabilities(rawValue: 1 << 7)
    /// The sound carries on when the app leaves the foreground.
    static let backgroundAudio = EngineCapabilities(rawValue: 1 << 8)
    /// `handOver(to:at:)` can swap a stream for its replacement without the
    /// picture going black in between.
    static let handOver = EngineCapabilities(rawValue: 1 << 9)
    /// A `load` over a stream that is playing cuts straight from the old one
    /// to the new: the old picture can be left running while the server is
    /// asked for its replacement.
    static let playsOnWhileReloading = EngineCapabilities(rawValue: 1 << 10)
    /// The engine's audio output can stall after the route is renegotiated
    /// — an HDMI frame-rate switch — and `rebuildAudio` reopens it. The model
    /// watches an opening or a seek that shows no frame with data in hand
    /// and kicks the output once.
    static let restartsAudioOutput = EngineCapabilities(rawValue: 1 << 11)
    /// `jumpToLiveEdge` can move a live stream's playhead to where the server
    /// still has segments.
    static let liveEdge = EngineCapabilities(rawValue: 1 << 12)
    /// Frame timing can be matched to the display's refresh rate
    /// (`setDisplayRefreshRate`).
    static let displaySync = EngineCapabilities(rawValue: 1 << 13)
}

/// How a picture is framed on the surface.
enum Framing: Sendable, Hashable {
    /// The whole picture, bars where its shape isn't the screen's.
    case fit
    /// The picture grown until it covers the screen, cropping what spills.
    case fill
    /// Zoomed in by a factor, 1 being `fit`.
    case zoom(Double)
    /// The picture stretched or cropped to a given aspect ratio.
    case aspect(Double)
}

/// Brightness, contrast, saturation and gamma, each -100…100 with 0 as the
/// file's own. Only an engine with `.pictureAdjust` reads them.
struct PictureAdjustment: Sendable, Hashable {
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var gamma: Double = 0

    static let neutral = PictureAdjustment()
    var isNeutral: Bool { self == .neutral }
}

/// How much of the engine's rendering budget to spend.
enum PowerProfile: Sendable, Hashable {
    /// The engine's own defaults: the best picture it can draw.
    case quality
    /// The cheapest draw that still looks right: bilinear scaling, no
    /// dithering or debanding, 8-bit intermediates.
    case battery
}

/// Subtitle appearance, from the one pair of preferences that exist.
struct SubtitleStyle: Sendable, Hashable {
    /// Relative to the engine's default size, as a percentage.
    var size: Double = 100
    var background: SubtitleBackground = .outline
    /// Lifted clear of a transport bar while one is up.
    var raised = false
}

/// One track as the engine lists it.
struct EngineTrack: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case audio, video, subtitle }

    /// The engine's own id for the track, unique within a kind: what
    /// `selectAudio(trackID:)` and `selectSubtitle(trackID:)` take.
    var id: Int
    var kind: Kind
    var title: String?
    var language: String?
    var codec: String?
    var isDefault = false
    var isForced = false
    var isExternal = false
    var isSelected = false
    var channels: Int?
    /// The stream's index inside the file — what ffprobe, and so Jellyfin,
    /// numbers it by. How a Jellyfin stream index is found among an engine's
    /// tracks. Nil for an external track, and for an engine that cannot read
    /// the file's own numbering and was given no hint for this track.
    var fileIndex: Int?
    /// For an external subtitle, the URL it was added from.
    var externalURL: String?

    /// What a menu calls it when the server has nothing better.
    var label: String {
        let parts = [title, language.map { Languages.name(for: $0) }, codec?.uppercased()]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
    }
}

/// The server's description of one of the file's tracks, for an engine that
/// cannot read the file's own numbering (AVFoundation reads an HLS rendition
/// and not the container) and has to line its tracks up with the server's by
/// name, position and language instead.
struct EngineTrackHint: Hashable, Sendable {
    var fileIndex: Int
    var kind: EngineTrack.Kind
    /// The server's `DisplayTitle`, which Jellyfin also writes into the HLS
    /// manifest as the rendition's name.
    var title: String?
    var language: String?
    var isForced = false
    var isExternal = false
    /// A picture-based subtitle (PGS, VOBSUB). Never a selectable track in
    /// an engine that cannot draw one; the server burns it in or it isn't
    /// shown.
    var isImage = false
}

/// A chapter, as the file lists them.
struct EngineChapter: Hashable, Sendable, Identifiable {
    var id: Int
    var start: Double
    var title: String
}

/// A stream prepared ahead of its load — its playlist already read, so the
/// first frame has nothing to wait on. See `PlaybackEngine.prepare`.
protocol PreparedStream: AnyObject {
    var url: URL { get }
    func cancel()
}

/// Everything a `load` needs.
struct EngineLoadRequest {
    var url: URL
    var headers: [String: String] = [:]
    /// Where in the stream to begin, in seconds. The engine holds playback
    /// back until it is there, so the opening seconds never flash up first.
    var startAt: Double = 0
    var paused = false
    var live = false
    /// Play it round for ever — the sync test clip.
    var loop = false
    /// The server's track list, for an engine that needs the hints.
    var hints: [EngineTrackHint] = []
    /// The tracks to open on, by engine track id, where they are already
    /// known: a stream reopened for an audio delay keeps the ones it had.
    var audioTrack: Int?
    var subtitleTrack: Int?
    /// A stream `prepare` already has reading its playlist, used in place of
    /// a fresh one when it is for this URL.
    var prepared: (any PreparedStream)?
}

/// Why a stream stopped.
enum EngineEndReason: Sendable {
    /// Played to the end.
    case finished
    /// Stopped or replaced by a command; not news.
    case stopped
}

/// A stream failed, before it opened or in the middle.
struct EngineFailure: Sendable {
    var message: String?
    /// It had been playing. A live stream that dies mid-play is the stall
    /// watchdog's to reopen rather than the error card's.
    var duringPlayback: Bool
    /// The session behind the stream went away rather than the media being
    /// unplayable — a transcode the server reaped, a segment that aged out of
    /// a live playlist, a connection dropped between two reads. Asking for
    /// the same stream again is the fix.
    var isSessionLoss: Bool
}

/// What the stream turned out to be, as the engine measures it.
struct EngineStreamFacts: Sendable {
    var width: Int?
    var height: Int?
    /// Bits per second the variant being played declares.
    var indicatedBitrate: Double?
    /// Bits per second actually arriving.
    var observedBitrate: Double?
    var stalls: Int?
    var droppedFrames: Int?
    /// `videotoolbox`, or `no` for software. Only an engine that decodes for
    /// itself knows.
    var decoder: String?

    var resolution: String? {
        guard let width, let height else { return nil }
        return "\(width)×\(height)"
    }
}

/// The engine's own transport state, as distinct from what the model has
/// asked for: a stall and a pause both stop the clock, and only this tells
/// them apart.
enum EngineTransport: Sendable {
    case playing
    case paused
    /// Wants to play and can't yet: buffering, or held at an opening position.
    case waiting
}

/// What an engine reports, in order, on one stream.
enum EngineEvent: Sendable {
    case position(Double)
    case duration(Double)
    /// The engine's transport flipped between playing and paused.
    case paused(Bool)
    /// Waiting on the network with the playhead stopped.
    case buffering(Bool)
    case seeking(Bool)
    /// How far the cache reaches, in stream seconds.
    case cachedUntil(Double)
    case tracks([EngineTrack])
    case chapters([EngineChapter])
    /// The picture's display size, once there is one.
    case videoSize(CGSize)
    /// The stream's own frame rate, as the container declares it.
    case frameRate(Double)
    /// Which hardware decoder is in use: `videotoolbox`, or `no`.
    case decoder(String)
    case droppedFrames(Int)
    /// The engine moved between variants of the playlist it is reading, to
    /// one declaring this many bits per second.
    case variantChanged(bitsPerSecond: Double)
    /// The engine's rate was changed from outside the model — the system's
    /// own speed control.
    case rate(Double)
    /// What offset the stream now carries, after a load. Zero when the engine
    /// could not build one in; `refused` says one was wanted and could not be
    /// made, so the viewer can be told.
    case audioDelayApplied(Double, refused: Bool)
    /// The file has been opened and its tracks are known.
    case fileLoaded
    /// Playback (re)started after a load or a seek: the first frame after it
    /// is on screen.
    case firstFrame
    /// Seconds have passed with the stream playing and no picture in it.
    case noPicture
    case ended(EngineEndReason)
    case failed(EngineFailure)
}

/// What the model needs from an engine, and nothing AVFoundation- or
/// mpv-shaped. Every engine is driven from the main actor.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var capabilities: EngineCapabilities { get }
    /// Containers the engine opens itself, so a stream in one needs no
    /// remux from the server.
    var directContainers: Set<String> { get }
    /// Everything the engine reports, for the life of the engine.
    var events: AsyncStream<EngineEvent> { get }

    // Streams

    /// Open a stream, replacing whatever is playing.
    func load(_ request: EngineLoadRequest)
    /// Stop and let go of the stream.
    func stop()
    /// Silence the stream while its replacement is asked for: nothing more
    /// is reported about it, so it neither ends nor fails on behalf of the
    /// stream that is opening. An engine with `.playsOnWhileReloading` may
    /// keep drawing it.
    func quiesce()
    /// Put `request` on screen in place of the stream playing, at `target`
    /// seconds, without the picture going black between the two. Returns
    /// whether the swap was made; false leaves everything as it was.
    func handOver(to request: EngineLoadRequest, at target: Double) async -> Bool
    /// Start reading a stream's playlist ahead of its load. Nil from an
    /// engine that has nothing to gain by it.
    func prepare(url: URL, headers: [String: String]) -> (any PreparedStream)?

    // Transport

    func play()
    func pause()
    /// Returns whether the seek was taken; a stream not yet open can't be.
    @discardableResult func seek(to seconds: Double) -> Bool
    @discardableResult func seek(by seconds: Double) -> Bool
    var rate: Double { get set }
    /// 0…1.
    var volume: Double { get set }
    var isMuted: Bool { get set }
    var transport: EngineTransport { get }
    /// The engine's own clock, in seconds; nil when there is nothing playing.
    var clock: Double? { get }
    /// Throw a live stream's playhead forward to `margin` seconds short of
    /// the end of what the server still holds. False when there is nowhere
    /// to jump to.
    func jumpToLiveEdge(margin: Double) -> Bool
    /// Tear the audio output down and build it again against the route that
    /// exists now, keeping the picture where it is.
    func rebuildAudio() async

    // Tracks

    /// What the engine found in the stream, as last reported.
    var tracks: [EngineTrack] { get }
    /// By engine track id; nil for none.
    func selectAudio(trackID: Int?)
    func selectSubtitle(trackID: Int?)
    /// Add a subtitle file by URL and show it.
    func addExternalSubtitle(url: URL, language: String?, title: String?)

    // The picture and the sound

    /// Seconds; positive plays the sound later than the picture. Live on an
    /// engine with `.audioDelayOnAnyStream`; otherwise read by the next
    /// `load`, which builds it into the stream where it can.
    var audioDelay: Double { get set }
    var subtitleStyle: SubtitleStyle { get set }
    var framing: Framing { get set }
    var picture: PictureAdjustment { get set }
    /// Dynamic range compression on the sound, on an engine with `.nightMode`.
    /// `nightModeUnavailableReason` says why it is not in force: the engine
    /// has no such filter, or the build of it turned out not to.
    var nightMode: Bool { get set }
    var nightModeUnavailableReason: String? { get }
    var powerProfile: PowerProfile { get set }
    /// Off, the picture is neither decoded nor drawn and the sound carries
    /// on — the background-audio case.
    var pictureDecode: Bool { get set }
    /// Time frames to a display known to be refreshing at `hertz`; nil
    /// returns to the engine's default clock.
    func setDisplayRefreshRate(_ hertz: Double?)

    var streamFacts: EngineStreamFacts { get }

    /// Let go of everything. Safe to call twice.
    func shutdown()
}

extension PlaybackEngine {
    /// Select the audio track the file numbers `streamIndex`, as Jellyfin
    /// does. False when the engine has no such track.
    @discardableResult
    func selectAudio(streamIndex: Int) -> Bool {
        guard let track = tracks.first(where: { $0.kind == .audio && $0.fileIndex == streamIndex }) else {
            return false
        }
        selectAudio(trackID: track.id)
        return true
    }

    /// The same for a subtitle; nil turns them off.
    @discardableResult
    func selectSubtitle(streamIndex: Int?) -> Bool {
        guard let streamIndex else {
            selectSubtitle(trackID: nil)
            return true
        }
        guard let track = tracks.first(where: { $0.kind == .subtitle && $0.fileIndex == streamIndex }) else {
            return false
        }
        selectSubtitle(trackID: track.id)
        return true
    }
}
