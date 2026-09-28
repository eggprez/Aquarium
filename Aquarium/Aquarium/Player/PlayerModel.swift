//  The player.
//
//  On Linux this was an mpv process driven over a JSON IPC socket, with the
//  video embedded as an X11 child window. Here it is AVPlayer, which changes
//  the mechanics completely but not the behaviour: the same resume points, the
//  same quality rungs and the same automatic fallback between them, the same
//  per-series memory of which audio and subtitle track you chose, the same skip
//  buttons, sleep timer, Up Next card and shuffle.
//
//  What AVFoundation gives back for free is everything mpv never could on a
//  phone: Picture in Picture, AirPlay, the lock screen and Control Centre
//  transport, and hardware decode without a setting to get wrong.

import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Observation
import OSLog

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if os(tvOS)
import AVKit
#endif

/// How a stream came to be started, for the things that care about the
/// difference. Kept apart from the options because it describes the *call*, not
/// the stream — it must not survive into the next one.
struct StartMeta: Sendable {
    /// The bitrate wasn't a fresh choice by the user, it carried over from the
    /// last stream (an automatic quality change, the next episode, an episode
    /// picked from the in-player queue). Adaptive quality keeps its ceiling
    /// across these, so one bad stretch of network doesn't pin a whole binge to
    /// 1.5 Mbps.
    var inherited: Bool = false
    var quiet: Bool = false
    /// This start is the stall watchdog opening a live stream again rather
    /// than anyone choosing to play something — see `reopenStalledLive`. It
    /// must not be counted as a fresh start, or the budget of attempts resets
    /// on every attempt and a dead channel is reopened for ever.
    var reopening: Bool = false
    /// The same, for a stream the player is quietly reopening after the
    /// session behind it went bad — see `recoverFromStreamFailure`. Same
    /// reason: it must not hand back the budget of attempts it is spending.
    var recovering: Bool = false
    /// Autoplay is carrying a transcode forced for a subtitle into the next
    /// episode, and with it the way back to direct play once that subtitle is
    /// turned off. See `transcodingForSubtitle`.
    var carriesSubtitleTranscode: Bool = false
}

struct StreamOptions: Sendable {
    /// nil = direct play; a number forces a transcode at that bitrate.
    var maxBitrate: Int?
    /// Whether `maxBitrate` is an answer or an absence. Without this the two
    /// are the same value: "direct play" and "nobody said" are both nil, so the
    /// default-quality preference used to be substituted into a stream the user
    /// had just deliberately set to direct play — every rung in the quality menu
    /// worked except the top one, which silently came back as whatever Settings
    /// said. A caller that has a quality in mind sets this, and Settings then
    /// keeps out of it.
    var bitrateIsChosen: Bool = false
    /// Ask the server to transcode whatever it would otherwise have sent
    /// untouched, without naming a bitrate.
    ///
    /// Those two used to be the same switch — `forceTranscode` was derived from
    /// `maxBitrate != nil` — so the only way to make the server re-encode
    /// something was to also cap it at one of the rungs in the quality menu.
    /// That is exactly backwards for the case this exists for: a file this
    /// device cannot decode should come back *at the best quality the server
    /// can manage*, not ground down to 4 Mbps because 4 Mbps happened to be the
    /// only phrasing available. Left nil, `DeviceProfile.build` gives the
    /// transcode the full 200 Mbps ceiling.
    var forceTranscode: Bool = false
    /// Make the server encode the picture and the sound together rather than
    /// copying either bitstream through untouched.
    ///
    /// Set only by `reencodeForSync`, and only for a stream that arrived out of
    /// step: it is the one lever this client has that reaches the *cause* of a
    /// transcode desync, and it costs the server a full re-encode of something
    /// it could otherwise have remuxed for nothing. Implies `forceTranscode` —
    /// there is nothing here for it to change about a direct play.
    var forceFullEncode: Bool = false
    var resume: Bool = true
    var live: Bool = false
    /// Explicit start position, overriding resume.
    var startSeconds: Double?
    /// The tracks this stream was asked for, in the server's own numbering.
    ///
    /// Only set when the viewer has picked one. A track that is already in the
    /// stream is switched to inside `AVPlayerItem` and never reaches here; these
    /// are for the ones that are not — another audio track on a transcode, which
    /// carries exactly one, or a subtitle the server has to convert or burn in.
    /// Choosing either means asking for the stream again, which is why they live
    /// with the bitrate rather than beside the selected-track state: everything
    /// that reopens a stream carries the whole of `StreamOptions` across.
    ///
    /// `nil` leaves it to the server. `-1` for the subtitle means none — see
    /// `JellyfinClient.resolvePlayback`.
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
}

/// One selectable track, flattened out of an `AVMediaSelectionGroup`.
///
/// This is what *arrived* — which on a transcode is a good deal less than what
/// the file has. See `TrackOption` for the list a menu is built from.
struct PlayerTrack: Identifiable, Hashable, Sendable {
    var id: Int
    var label: String
    var language: String?
    var isForced: Bool
}

/// One entry in the player's own audio or subtitle menu.
///
/// The two halves are the point. `avIndex` says the track is in the stream that
/// is playing, and choosing it costs a frame; `serverIndex` says the server has
/// it and this one does not, and choosing it costs a new stream. A transcode
/// carries a single audio track and only the subtitles that were asked for, so
/// for most of a Jellyfin library the second is the ordinary case — a menu built
/// from the stream alone offers one audio track for a film that has four, and
/// no subtitles at all for one with six.
struct TrackOption: Identifiable, Hashable, Sendable {
    /// The file's own track number, as the server numbers it. `nil` for a
    /// downloaded file or an IPTV channel, where there is no server to ask.
    var serverIndex: Int?
    /// Where this track sits in `AVMediaSelectionGroup`, when it is in the
    /// stream at all.
    var avIndex: Int?
    var label: String
    var language: String?
    var isForced: Bool

    /// Whether choosing this means opening the stream again.
    var needsNewStream: Bool { avIndex == nil }

    /// Unique within one menu, which is either all server tracks or all stream
    /// tracks and never a mix of the two.
    var id: Int { serverIndex ?? -(( avIndex ?? 0) + 1) }
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

    /// Every way the player comes down is written here with why, so "it went
    /// back to the guide by itself" can be read off the console rather than
    /// reasoned about. `log show --predicate 'subsystem == "<bundle id>"'`.
    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "player")

    // MARK: - Published state

    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    private(set) var title = ""
    private(set) var subtitle = ""
    private(set) var isLive = false
    private(set) var isLocal = false
    /// Playing a stream that didn't come from Jellyfin — a channel resolved
    /// from an M3U playlist rather than the server's own Live TV. There is no
    /// session on the other end of one of these, so progress is never
    /// reported for it; see `playExternal`.
    private(set) var isExternal = false
    private(set) var errorMessage: String?
    /// The asset turned out to have no video track once it was ready.
    ///
    /// An IPTV channel carrying video no Apple platform will decode, which in
    /// practice means one of two things: MPEG-2 broadcast video, or — much the
    /// more common one now that re-streamers transcode for themselves — H.265
    /// inside MPEG-TS. AVFoundation plays HEVC over HLS only from fMP4
    /// segments; in a transport stream it demuxes the container happily, finds
    /// the audio, and has no video track to hand a picture from. The audio
    /// plays regardless; this is what tells the screen to explain the black
    /// picture rather than leave it looking like a hang.
    private(set) var noVideoTrack = false
    /// The size of the picture being shown, once there is one. The Mac's
    /// player window takes its shape from it; zero until the first frame.
    private(set) var pictureSize: CGSize = .zero
    /// What the stream turned out to contain, once it has been looked at — see
    /// `StreamDiagnosis`. Replaces the general explanation on the banner with
    /// the actual codec whenever it can be read.
    private(set) var noVideoDetail: String?

    /// The item on screen, when it came from the server.
    private(set) var item: BaseItem?
    /// Artwork for the transport controls and the loading screen.
    private(set) var artworkURL: URL?

    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var selectedAudioTrack: Int?
    /// nil means subtitles are off.
    private(set) var selectedSubtitleTrack: Int?

    private(set) var chapters: [Chapter] = []
    private(set) var segments: [MediaSegment] = [] {
        didSet { refreshCues() }
    }
    /// The whole item behind what is playing, fetched while the stream opens.
    ///
    /// The info ribbon used to ask for this itself, the first time it was
    /// pulled down — so the overview, the cast and the genres arrived a moment
    /// *after* the band had slid into place and made it grow while it was
    /// still moving. Fetched here, it has been there for minutes by the time
    /// anyone swipes. See `infoItem`.
    private(set) var fullItem: BaseItem?
    private(set) var trickplay: TrickplayInfo?

    /// What's coming after this, when it's an episode with a successor.
    private(set) var upNext: BaseItem? {
        didSet { refreshCues() }
    }
    private(set) var upNextLocalId: String? {
        didSet { refreshCues() }
    }
    private(set) var isStartingNext = false

    /// Set when the user dismisses the Up Next card: this episode ends and
    /// stops there. Cleared whenever something new starts playing.
    private(set) var autoplayCancelled = false {
        didSet { refreshCues() }
    }

    private(set) var sleepDeadline: Date?
    private(set) var currentBitrate: Int?

    /// A change of bitrate the connection caused, rather than the person
    /// watching: on screen for a few seconds, then gone. See `BitrateBadge`.
    struct BitrateNotice: Equatable, Identifiable, Sendable {
        let id = UUID()
        var isUp: Bool
        /// What it is now — "5 Mbps · 720p", or "3.2 Mbps" for a step inside
        /// the stream.
        var headline: String
        /// Why, in two or three words.
        var detail: String
    }
    private(set) var bitrateNotice: BitrateNotice?
    @ObservationIgnored private var bitrateNoticeDismissal: Task<Void, Never>?
    private(set) var isTranscoding = false

    var speed: Double = 1 {
        didSet {
            if !isPaused { startPlaying() }
            // The player's `defaultRate` is the documented two-way channel
            // between this and AVKit's own speed control: setting it moves the
            // tick in that menu, and the menu moving sets it back. Kept in step
            // here so the speed shown by the system's control is this one, from
            // whichever side it was chosen.
            if abs(Double(player.defaultRate) - speed) > 0.001 {
                player.defaultRate = Float(speed)
            }
        }
    }
    var volume: Double = 1 {
        didSet {
            player.volume = Float(volume)
            Preferences.shared.volume = volume
        }
    }
    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func speedName(_ rate: Double) -> String {
        rate == 1 ? "Normal" : "\(rate.formatted())×"
    }

    // MARK: - Internals

    let player = AVPlayer()
    private var playerItem: AVPlayerItem?
    private var source: PlaybackSource?
    private var options = StreamOptions()
    private var localRecordId: String?
    /// Where the current stream has to be taken to once its asset is ready to
    /// be seeked; nil once that's done, or when it started from the top.
    private var pendingSeek: Double?
    /// The stream is being opened at a position: the rate is deliberately zero
    /// from `attach` until the seek lands, and nothing may read that as the user
    /// having paused. It covers the whole window rather than just the wait for
    /// `readyToPlay`, because the seek itself is the slow part — a transcode has
    /// to be encoding at the offset before it can answer — and a tick landing
    /// mid-seek used to record the hold as a pause, which then stopped the seek's
    /// own completion from ever starting playback again. That is what left the
    /// player sitting dead on the first frame after a quality change.
    private(set) var isOpening = false
    /// Gives up on a seek that is never going to be answered and plays anyway.
    private var seekWatchdog: Task<Void, Never>?
    /// See `watchForPicture`.
    private var pictureWatchdog: Task<Void, Never>?
    /// The address of an IPTV channel being resolved — see `playExternal`.
    private var externalResolve: Task<Void, Never>?
    /// The channel `playExternal` was last given, kept because reopening one
    /// means asking for it from the top: the address in `currentStreamURL` is
    /// where the last session was resolved to, and a session that has died is
    /// exactly what must not be asked for again.
    private var externalChannel: ExternalChannel?
    private struct ExternalChannel {
        var title: String
        var subtitle: String
        var artworkURL: URL?
        var streamURL: URL
        /// The playlist channel this stream came from, when the caller had it.
        /// Nothing about playback needs it — the URL is the whole of that — but
        /// the info panel does: reduced to a title and an address, a channel has
        /// no id to look its programme up by. See `infoItem`.
        var item: BaseItem?
        /// Where the resolver last found this channel's stream.
        ///
        /// Kept so a reopen doesn't walk the redirect chain a second time. That
        /// walk is up to five HEAD requests with a four-second timeout each —
        /// twenty seconds of black screen in the worst case — and, which
        /// matters more on a source that limits concurrent connections, it is
        /// another request to the far end at the exact moment the player is
        /// trying to make one of its own. The address is only re-resolved by `retry()`,
        /// where the address itself is what's in doubt.
        var resolvedURL: URL?
    }
    /// Watches a live stream for having quietly stopped — see
    /// `armLiveWatchdog`.
    private var liveWatchdog: Task<Void, Never>?
    /// When the player's clock was last seen to have moved, and where it was.
    private var lastAdvance: (at: Date, position: Double)?
    /// How many times the current live stream has been reopened after dying,
    /// and when the last of those was.
    private var liveReconnects = 0
    private var lastReopenAt = Date.distantPast
    /// A reopen is in flight. The dead item stays in the player while its
    /// replacement is being resolved, and it keeps its observers until then —
    /// a dead live playlist that posts `didPlayToEndTime` during that window
    /// would otherwise start a second reopen and spend two of the three
    /// attempts on one stall.
    private var isReopeningLive = false
    /// Reading what a channel with no picture actually contains.
    private var diagnosis: Task<Void, Never>?
    /// The address the current stream is really being read from, after any
    /// redirects — what `StreamDiagnosis` has to be pointed at.
    private var currentStreamURL: URL?
    private var timeObserver: Any?
    private var statusObservers: Set<AnyCancellable> = []
    /// Lives as long as the player does, unlike `statusObservers`, which is torn
    /// down and rebuilt around every item.
    private var speedObserver: Set<AnyCancellable> = []
    private var endObserver: NSObjectProtocol?
    /// See the note where this is installed.
    private var failedEndObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    /// Where AVPlayer moving between an HLS master playlist's variants shows
    /// up — the one bitrate change nothing in this app decides. See
    /// `noteVariantChange`.
    private var accessLogObserver: NSObjectProtocol?
    /// The variant bitrate last seen on this item, and when variant changes
    /// start to count: every stream feels its way up in its first seconds, and
    /// that is the stream opening, not the connection changing.
    private var lastVariantBitrate: Double?
    private var variantChangesCountFrom = Date.distantFuture

    /// Which stream the player is on, counted rather than named.
    ///
    /// Starting and stopping both take a turn off the main actor — a start
    /// waits on PlaybackInfo, a stop reports where it got to — and for that
    /// stretch the model is describing a stream that is on its way in or on its
    /// way out while somebody may already have asked for the next one. Closing
    /// a channel and immediately opening another is exactly that pair, and it
    /// is what "the channel drops straight back to the guide" was: the *first*
    /// channel's teardown finishing after the second one's start had set
    /// `isActive`, and clearing it again. The second stream went on playing —
    /// audio over the guide — with nothing on screen to stop it, and the next
    /// channel opened on top of a player that still had an orphan running
    /// underneath.
    ///
    /// So each start takes a number, and any work that resumes after an await
    /// checks its number is still the current one before touching shared state.
    /// A stale one releases what it opened and says nothing.
    private var generation = 0

    /// The start still waiting on the server for its stream, if there is one.
    /// Compared against `generation`, so a start that was overtaken leaves
    /// nothing behind. See `rebuildForAudioDelay`.
    private var resolvingGeneration: Int?

    /// `generation`, for a caller outside that has to act on the stream it saw
    /// and not on whatever has replaced it since — see `PlayerScreen`'s
    /// `onDisappear`, which stops the player a moment after the screen goes
    /// and must not stop the channel picked in that moment.
    var streamGeneration: Int { generation }

    /// `stop`, unless the stream has changed since `generation` was read.
    func stop(reason: String, ifStill generation: Int) {
        guard self.generation == generation else { return }
        stop(reason: reason)
    }

    /// How many times the current item has been quietly reopened after the
    /// stream underneath it failed — see `recoverFromStreamFailure`.
    private var streamRecoveries = 0
    /// The ceiling on that. Two is enough for the fault it exists for (a
    /// transcode session the server has reaped, a segment that aged out of the
    /// playlist) and few enough that a genuinely broken file still reaches the
    /// error card rather than looping.
    private static let streamRecoveryLimit = 2
    /// When the last quiet reopen happened, and how long the stream has to run
    /// cleanly before the budget above is handed back.
    ///
    /// Without this the two attempts are two for the whole film. A network that
    /// drops a connection twice in two hours is not a broken file, and the
    /// third drop put an error card over a title that had been playing happily
    /// for forty minutes — the same shape the live watchdog already handles
    /// with `liveSettledAfter`.
    private var lastRecoveryAt: Date?
    private static let streamRecoverySettled: TimeInterval = 90

    private var lastReportAt = Date.distantPast
    /// What Now Playing was last told: where playback was, at what rate, and
    /// when. The system runs the clock forward from that by itself.
    private var nowPlayingAnchor: (position: Double, rate: Double, at: Date, duration: Double)?
    private var sleepTask: Task<Void, Never>?
    private var autoplayInFlight = false
    private var episodeQueue: [BaseItem]?
    private var tracksApplied = false
    /// The server has already been asked what comes next; a "nothing" answer
    /// must not be re-asked twice a second for the rest of the episode.
    private var upNextChecked = false
    /// The server *answered* what comes next — including "nothing, this is
    /// the last one". Unlike `upNextChecked`, which is set before a lookup
    /// runs so that one is not started twice a second, this is only set by a
    /// lookup that succeeded, so a failed one still gets its retry at the end.
    private var upNextSettled = false

    /// The series being shuffled over downloaded episodes, and what has already
    /// been drawn in this pass.
    private var shuffleSeries: DownloadShuffleState?

    private struct DownloadShuffleState {
        var seriesId: String?
        var seriesName: String?
        var seen: Set<String>
    }

    let adaptive = AdaptiveQuality()

    private var client: JellyfinClient { .shared }
    private var prefs: Preferences { .shared }

    private init() {
        volume = prefs.volume
        player.volume = Float(prefs.volume)
        player.allowsExternalPlayback = true
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        player.defaultRate = Float(speed)
        // Speed is chosen in AVKit's own control now, which reports the choice
        // by way of `defaultRate`. Adopting it here keeps this the one place
        // that knows the speed, so the resumes and quality changes that set the
        // rate from `speed` don't quietly undo what the user just picked.
        player.publisher(for: \.defaultRate)
            .map(Double.init)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                MainActor.assumeIsolated {
                    guard let self, rate > 0, abs(rate - self.speed) > 0.001 else { return }
                    self.speed = rate
                }
            }
            .store(in: &speedObserver)
        // The category only. Activating a non-mixing playback session is what
        // stops whatever else is playing, and doing it here did that the
        // moment the app opened — a podcast cut off by launching the app to
        // browse — and then held the audio hardware for as long as the app
        // lived. `installItem` activates it for each stream, which is when it
        // is wanted.
        configureAudioSession(activate: false)
        observeAudioRoute()
        observeForeground()
        NowPlaying.shared.attach(to: self)
    }

    /// The sleep timer's deadline, checked on every return to the foreground.
    /// The timer's own task cannot wake while the process is suspended; this
    /// is what ends playback on the way back in when it should already have.
    private func observeForeground() {
        #if canImport(UIKit)
        let name = UIApplication.didBecomeActiveNotification
        #else
        let name = NSApplication.didBecomeActiveNotification
        #endif
        routeObservers.append(NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSleepDeadline() }
        })
    }

    private func configureAudioSession(activate: Bool = true) {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        // .moviePlayback keeps dialogue intelligible on a phone speaker and is
        // what lets AirPlay and the lock-screen transport work at all.
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        if activate { try? session.setActive(true) }
        #endif
    }

    // MARK: - Losing and regaining the audio route
    //
    // Turning the television off while something is playing takes the audio
    // route away with it: HDMI is the only output an Apple TV has, and when the
    // set goes to sleep the route disappears, the session is deactivated out
    // from under us, and — if the box itself sleeps too — playback is
    // interrupted. Waking the set brings the picture straight back, because
    // AVPlayer keeps decoding video against a session it no longer owns. The
    // sound does not: an interrupted session stays inactive until somebody
    // activates it again, and nobody was.
    //
    // That is the whole of "the sound never comes back". These three
    // notifications are the three ways the route can be lost — an interruption,
    // the device going away and coming back, and the media daemon being
    // restarted — and each of them is answered by putting the session back the
    // way `configureAudioSession` had it and then giving the player the nudge
    // described on `recoverAudio`.

    /// Registered for the life of the player, unlike the per-item observers.
    private var routeObservers: [NSObjectProtocol] = []

    private func observeAudioRoute() {
        #if os(iOS) || os(tvOS)
        let centre = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        routeObservers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    // Nothing to do but remember that the sound went away for a
                    // reason: the player is left exactly as it is, so that
                    // whatever was playing is still playing when it comes back.
                    self.audioWasInterrupted = true
                case .ended:
                    self.recoverAudio(rebuildingComposition: true)
                @unknown default:
                    self.recoverAudio(rebuildingComposition: true)
                }
            }
        })

        routeObservers.append(centre.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                switch reason {
                case .newDeviceAvailable, .routeConfigurationChange, .override, .categoryChange:
                    // The set is back. `oldDeviceUnavailable` is deliberately
                    // not here: that one fires as the route is going away, and
                    // reactivating against a route that no longer exists is how
                    // you get a session that thinks it is live and isn't.
                    self.recoverAudio(rebuildingComposition: true)
                default:
                    break
                }
            }
        })

        // The media daemon restarting invalidates the session's configuration
        // wholesale — category, mode and all — so this one starts from scratch
        // rather than merely reactivating.
        routeObservers.append(centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The category now; `recoverAudio` activates the session, and
                // only when something is playing to need it.
                self.configureAudioSession(activate: false)
                self.recoverAudio(rebuildingComposition: true)
            }
        })
        #endif

        #if os(tvOS)
        // The belt to the three braces above. A set switched off long enough
        // for the box to sleep as well comes back through the foreground
        // transition, and whether that also produces an interruption-ended
        // notification depends on how far down it went — deep enough and the
        // session was torn down rather than interrupted, and there is no
        // "ended" for something that never said it had begun.
        routeObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wasBackgrounded = true }
        })
        routeObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // The composition is rebuilt here only if something actually said
            // the sound had gone. This fires on every return to the
            // foreground — dismissing a system dialog included — and rebuilding
            // a stream costs a visible second or two.
            //
            // And nothing is done at all for a return that wasn't from the
            // background: a dialog, the Control Center, a notification banner
            // only make the app inactive for a moment, and never take the
            // audio session with them. Each of those used to reselect the
            // audio track and rebuild the mix. A box that slept — the case
            // this is here for — goes through the background on the way.
            MainActor.assumeIsolated {
                guard let self else { return }
                let slept = self.wasBackgrounded
                self.wasBackgrounded = false
                guard slept || self.audioWasInterrupted else { return }
                self.recoverAudio(rebuildingComposition: self.audioWasInterrupted)
            }
        })
        #endif
    }

    /// Set while an interruption is in force, so a route change arriving in the
    /// same breath doesn't try to recover twice.
    private var audioWasInterrupted = false

    /// The app went to the background since it was last active — what tells a
    /// television waking up from a dialog closing. See `observeAudioRoute`.
    private var wasBackgrounded = false

    /// Put the session back and give the player a reason to rebuild its audio.
    ///
    /// Reactivating the session is necessary and, on its own, not sufficient:
    /// an `AVPlayer` that was decoding through a session that went away keeps a
    /// dead audio tap, and simply owning a live session again doesn't rebuild
    /// it. Re-selecting the audio track the item is already on is what does —
    /// it makes AVFoundation tear the audio mix down and construct a new one
    /// against the route that now exists — and setting the rate afresh restarts
    /// the clock they share. Both are no-ops when the sound never went away,
    /// which is why this is safe to call on any of the three notifications.
    private func recoverAudio(rebuildingComposition: Bool = false) {
        #if os(iOS) || os(tvOS)
        audioWasInterrupted = false
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        // An item built as a composition has no audible selection group, so
        // `rebuildAudioMix` cannot do anything with one — it looks for the
        // group, finds none, and returns. Which meant the one repair for a dead
        // audio tap was unavailable on exactly the files that get composed: a
        // download played with an audio offset. The sound stopped at an
        // interruption and did not come back, and closing the player and
        // reopening the episode was the only thing that worked — because that
        // rebuilt the item, which is what this now does directly, keeping the
        // position and whether it was paused.
        if rebuildingComposition, audioDelayIsApplied {
            rebuildForAudioDelay()
            return
        }
        Task { await rebuildAudioMix() }
        // Not during the opening hold, whose rate is zero on purpose until the
        // seek lands — see `isOpening`.
        if !isPaused, !isOpening {
            player.rate = Float(speed)
        }
        #endif
    }

    /// Re-select whichever audible option the item is already playing, which is
    /// the documented way to ask for a fresh audio mix without touching the
    /// stream.
    ///
    /// Async rather than fire-and-forget, because `resyncAudio` has to know when
    /// it has finished: the seek it makes afterwards is worth something only if
    /// it primes the mix this builds, rather than the one being torn down under
    /// it. `recoverAudio` above doesn't care, and starts it in a task of its own.
    ///
    /// Does nothing while an audio offset is in force: a composition has no
    /// audible selection group to re-select in. The seek in `resyncAudio` is
    /// still worth making, and is what that case falls back to.
    private func rebuildAudioMix() async {
        guard let avItem = playerItem else { return }
        guard let group = try? await avItem.asset.loadMediaSelectionGroup(for: .audible) else { return }
        let current = avItem.currentMediaSelection.selectedMediaOption(in: group)
        guard let current else { return }
        avItem.select(nil, in: group)
        avItem.select(current, in: group)
    }

    // MARK: - Putting the sound back on the picture's clock
    //
    // AVPlayer renders audio and video against one master clock, so a stream
    // that started in step does not wander out of it on its own. What it does
    // do is come back wrong after that clock has been disturbed underneath it:
    // an interruption, an HDMI route that went away with the television, a live
    // playlist reopened mid-stall, one transcode session replaced by another.
    // `recoverAudio` above answers the cases a notification announces. This is
    // the same repair, offered by hand, for the ones nothing announces.
    //
    // What it cannot do is fix an offset that was there from the first frame —
    // a file muxed out of sync, or a transcode ffmpeg built that way. Nothing
    // on this device can. There is no audio-delay control on AVPlayer, and the
    // one native way to shift a track, an `AVMutableComposition`, needs asset
    // tracks to shift: an HLS asset has none, and every transcode this client
    // asks for is HLS. So a constant offset on a transcode is answered by
    // `reencodeForSync` instead, which fixes the cause on the server rather
    // than the symptom here.

    /// How far behind the playhead a resync seeks to.
    ///
    /// Deliberately not zero. A seek to the position the player is already at
    /// is one AVFoundation is entitled to satisfy by doing nothing at all, and
    /// doing nothing is the single outcome this must not have — the whole point
    /// is to flush both renderers and prime them again together. Half a second
    /// back is unambiguously a seek, and short enough to read as a hiccup
    /// rather than as a jump.
    private static let resyncNudge: Double = 0.5

    private var isResyncing = false

    /// Whether there is anything for a resync to act on. Downloads and IPTV
    /// channels included: the clock can be disturbed under any of them.
    var canResync: Bool { isActive && !isOpening && playerItem != nil }

    /// Flush the picture and the sound and start them again together.
    ///
    /// Two halves, in this order and no other. The audio mix is torn down and
    /// rebuilt first, which is what makes AVFoundation construct a fresh one
    /// against the route that exists now; the exact seek then primes both
    /// renderers from a single keyframe, so whatever relationship they had
    /// drifted into is discarded rather than carried across. Rebuilding after
    /// the seek would leave the new mix primed by nothing.
    func resyncAudio() {
        guard canResync, !isResyncing, let avItem = playerItem else { return }
        isResyncing = true
        #if !os(tvOS)
        // Not on a television — see `maybeAdapt` for why. There is nothing to
        // say there that the sound coming back into step doesn't say better.
        AppModel.shared.toast("Resyncing the audio…")
        #endif
        Task {
            defer { isResyncing = false }
            await rebuildAudioMix()
            // The item can be replaced while the mix is being rebuilt — a
            // quality change, an episode ending, a live stream reopening — and
            // seeking the player then would move whatever took its place.
            guard isActive, playerItem === avItem else { return }
            let wasPlaying = !isPaused
            _ = await player.seek(
                to: resyncTarget(for: avItem),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            guard isActive, playerItem === avItem else { return }
            // Set back rather than assumed to have survived: a seek does not
            // always return the rate it found, which is the same reason
            // `recoverAudio` ends this way.
            if wasPlaying { player.rate = Float(speed) }
        }
    }

    private func resyncTarget(for avItem: AVPlayerItem) -> CMTime {
        let nudge = CMTime(seconds: Self.resyncNudge, preferredTimescale: 600)
        var target = player.currentTime() - nudge
        // A live playlist's seekable window slides forward as segments age out
        // of it, and half a second back can be half a second the server no
        // longer holds. Consulted rather than assumed: an ordinary file has one
        // range covering the whole item, and clamping to it changes nothing.
        if let range = avItem.seekableTimeRanges.last?.timeRangeValue, range.duration > .zero {
            target = CMTimeMinimum(CMTimeMaximum(target, range.start), range.end)
        }
        return CMTimeMaximum(target, .zero)
    }

    // MARK: - A manual audio offset
    //
    // The repair for the case `resyncAudio` cannot touch: a stream whose sound
    // was never in step with its picture to begin with, and which no amount of
    // re-priming will move. There is no audio-delay control on AVPlayer, so the
    // shift is made by rebuilding the item as an `AVMutableComposition` with
    // the audio track inserted at a different time from the video.
    //
    // That mechanism decides where this can be offered, and it is narrower than
    // anyone wants: a composition is built out of `AVAssetTrack`s, and an HLS
    // asset has none. So the offset reaches a direct play and a download, and
    // cannot reach a transcode, a Jellyfin live channel or an IPTV stream — all
    // of which are HLS. `canDelayAudio` is that fact, and the menu says so
    // rather than hiding the control and looking broken. A transcode that is
    // out of step has `reencodeForSync`, which fixes the cause instead.
    //
    // On tvOS there is a second mechanism for exactly the streams the first
    // one can't touch: the picture is held back instead of the sound being
    // moved, frame by frame, through `DelayedVideoRenderer`. It covers every
    // HLS stream and only the negative half of the range — a soundbar's lag
    // is the whole reason the setting exists on a television, and that is the
    // half a soundbar needs. `heldPicture` is that renderer while it is in
    // force; `canDelayAudioLater` is which half of the range this stream can
    // take.
    //
    // Two things follow from building a composition, and both are handled
    // below. It has no media selection groups, so the track lists are read from
    // `sourceAsset` — the untouched original — and choosing a different track
    // rebuilds the composition rather than selecting within the item. And the
    // offset outlives the stream: it lives in `Preferences.audioDelay`, because
    // what it corrects is almost always the room — a soundbar's lag — and the
    // room is the same for the next film. On tvOS it is set from inside the
    // player, over the picture — see `AudioDelayOverlay`.

    /// The offsets the menu offers, in milliseconds: fifty at a time either
    /// side of zero. Positive means the sound plays later than the picture.
    static let audioDelays: [Int] = Array(stride(from: -500, through: 500, by: 50))

    static func audioDelayName(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "In step" }
        return milliseconds < 0
            ? "Sound \(-milliseconds) ms earlier"
            : "Sound \(milliseconds) ms later"
    }

    /// The same in the few words a line already saying something else has room
    /// for — "set to 200 ms later", rather than a sentence inside a sentence.
    static func audioDelayShortName(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "in step" }
        return milliseconds < 0 ? "\(-milliseconds) ms earlier" : "\(milliseconds) ms later"
    }

    /// The offset that is *set*, in seconds. Positive means the sound plays
    /// later. Lives in Preferences and outlives the stream — see there.
    var audioDelay: Double { prefs.audioDelay }

    /// The same, as the menu spells it.
    var audioDelayMilliseconds: Int { Int((audioDelay * 1000).rounded()) }

    /// What is actually built into the stream: the offset that is set, plus
    /// the frame-rate one while the television has been switched for this
    /// video. The menus move `audioDelay`; everything that makes the offset
    /// reads this.
    var appliedAudioDelay: Double { audioDelay + frameRateMatchDelay }

    var appliedAudioDelayMilliseconds: Int { Int((appliedAudioDelay * 1000).rounded()) }

    /// The share of `appliedAudioDelay` that is there for Match Frame Rate —
    /// zero unless it is set, matching is on, and this video is one the
    /// display switches for.
    var frameRateMatchDelay: Double {
        #if os(tvOS)
        guard prefs.frameRateMatchDelay != 0, Self.displayMatchesFrameRate,
              let rate = contentFrameRate else { return 0 }
        // The home screen runs at 60 Hz, and Match Frame Rate leaves 59.94
        // and 60 where they are. Anything else — 23.976, 24, 25, 29.97, 50 —
        // is a switch, and a switch is what costs the television time.
        return abs(rate - 60) > 1 ? prefs.frameRateMatchDelay : 0
        #else
        return 0
        #endif
    }

    var frameRateMatchMilliseconds: Int { Int((frameRateMatchDelay * 1000).rounded()) }

    #if os(tvOS)
    /// Whether Settings → Video and Audio → Match Content is on. tvOS reports
    /// one answer for Match Frame Rate and Match Dynamic Range together, and
    /// nothing at all about how long the television takes once it switches —
    /// which is why the amount is a setting rather than a reading.
    static var displayMatchesFrameRate: Bool {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        return window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false
    }

    /// The video's frame rate as the server read it. Nil for a channel from an
    /// M3U playlist and anything else the server hasn't probed; with no rate
    /// there is no telling whether the display will switch, so no frame-rate
    /// offset is added.
    private var contentFrameRate: Double? {
        guard let video = source?.mediaSource.streams.first(where: { $0.type == "Video" })
        else { return nil }
        return (video.RealFrameRate ?? video.AverageFrameRate).flatMap { $0 > 0 ? $0 : nil }
    }
    #endif

    /// Whether the item now in the player actually carries the offset.
    ///
    /// A different question from whether one is set, and the two come apart
    /// constantly now that the offset is a standing preference: a transcode
    /// carries none of it, and neither does a file that refused to compose.
    /// Everything that has to know "is this item a composition" asks this, not
    /// `audioDelay` — a composition is where the media selection groups go
    /// missing, and the mistake to avoid is treating a plain transcode as one.
    private(set) var audioDelayIsApplied = false

    /// The tracks the composition in the player was built around. Choosing the
    /// same ones again is not a reason to build it a second time, and without
    /// this every stream with a language preference composed twice: once on
    /// opening, and again the moment `applyPreferredTracks` made its choice.
    private var composedTracks: (audio: Int?, subtitle: Int?) = (nil, nil)

    /// The asset the current stream came from, before any composition was built
    /// on top of it. The track lists and the chapters are read from this: a
    /// composition carries no media selection groups of its own, so with a
    /// delay in force the item cannot answer what tracks the file holds.
    private var sourceAsset: AVAsset?

    /// Whether the stream being set up is one an offset can be built into.
    ///
    /// A file, in other words — one AVFoundation will hand over asset tracks
    /// for. Everything HLS is refused, and that is the whole of the rule.
    ///
    /// Deliberately says nothing about `isOpening`: `attach` asks this while
    /// the stream is opening, which is the one moment `canDelayAudio` below is
    /// bound to answer no.
    private var streamCarriesDelay: Bool {
        guard !isExternal, !isLive else { return false }
        if isLocal { return true }
        guard let source else { return false }
        return !source.isTranscode
    }

    /// The same question asked from the menu, where a stream still opening has
    /// nothing to offer yet. On tvOS every open stream can take an offset —
    /// one way or the other, see `heldPicture` — so there the answer is only
    /// about whether the stream has opened.
    var canDelayAudio: Bool {
        guard isActive, !isOpening else { return false }
        #if os(tvOS)
        return true
        #else
        return streamCarriesDelay
        #endif
    }

    /// Whether the sound can be made *later* on this stream, as well as
    /// earlier. Only a composition can do that, so this is the file question
    /// again; a stream that is having its picture held instead offers the
    /// negative half of the range and says why the other half is missing.
    /// Answered from the moment the stream is asked for, not once it has
    /// opened: the controls that ask need to know which half of the range to
    /// draw before there is anything to draw it over.
    var canDelayAudioLater: Bool { isActive && streamCarriesDelay }

    /// Set the offset, and put it on the stream if there is one to put it on.
    ///
    /// Not gated on the stream having opened. A stream still opening picks
    /// the preference up as it installs — `attach` builds the composition
    /// from it and `installItem` hands it to the held picture — so a value
    /// set during that moment is not lost, it is simply applied a moment
    /// later. Gating it here was what made a second nudge from the overlay
    /// vanish while the first was still being built.
    func setAudioDelay(milliseconds: Int) {
        guard isActive else { return }
        let seconds = Double(milliseconds) / 1000
        guard abs(seconds - prefs.audioDelay) > 0.0005 else { return }
        if streamCarriesDelay {
            prefs.audioDelay = seconds
            rebuildForAudioDelay()
            return
        }
        #if os(tvOS)
        // The picture can be held, not brought forward: a positive offset on
        // an HLS stream is not something this can do, and the menu doesn't
        // offer one. Refused here as well so the preference never records a
        // value the screen isn't showing.
        guard seconds <= 0 else { return }
        prefs.audioDelay = seconds
        // No reopen. The renderer is swapped under the running item; the
        // sound doesn't so much as hiccup.
        if let avItem = playerItem { refreshHeldPicture(for: avItem) }
        #endif
    }

    #if os(tvOS)
    /// The renderer holding the picture back, while the offset is being made
    /// that way rather than by a composition. Nil on a stream that is
    /// composed, one with no offset, or one with an offset the picture can't
    /// make (a positive one).
    private(set) var heldPicture: DelayedVideoRenderer?

    /// Where the held picture is drawn: AVKit's content overlay, between the
    /// (now blank) video layer and its controls. Handed over by the player
    /// screen's coordinator, which is the only thing that has the controller.
    @ObservationIgnored var heldPictureHost: (() -> UIView?)?

    /// Put the right renderer under the item — or none. Called whenever an
    /// item goes into the player and whenever the offset changes on one that
    /// is already there.
    private func refreshHeldPicture(for avItem: AVPlayerItem) {
        heldPicture?.detach()
        heldPicture = nil
        let delay = appliedAudioDelay
        // Only the streams the composition couldn't take, and only the
        // direction the picture can go. `audioDelayIsApplied` rather than
        // `streamCarriesDelay`: a file that refused to compose gets this as
        // its fallback too.
        guard delay < 0, !audioDelayIsApplied, playerItem === avItem else { return }
        let renderer = DelayedVideoRenderer(item: avItem, hold: -delay)
        renderer.view.displayLayer.videoGravity = prefs.fillScreen ? .resizeAspectFill : .resizeAspect
        if let host = heldPictureHost?() {
            renderer.view.frame = host.bounds
            host.addSubview(renderer.view)
        }
        heldPicture = renderer
    }
    #endif

    /// Open the current stream again, at whatever offset now applies, holding
    /// the position and whether it was paused.
    ///
    /// All of the work is `attach`, which decides for itself whether this
    /// stream can carry an offset and builds the composition if it can. This
    /// only has to take a fresh number first, so that anything still in flight
    /// for the item being replaced loses. See `generation`.
    private func rebuildForAudioDelay() {
        // Not while `play` is waiting on the server: `currentStreamURL` is
        // still the old stream's, and taking a number here would put it back
        // under the new title. The new stream picks the offset up as it opens.
        guard resolvingGeneration != generation else { return }
        guard let url = currentStreamURL else { return }
        isBuffering = true
        generation &+= 1
        attach(
            url: url, startAt: position,
            headers: isLocal ? [:] : client.authHeaders(for: url),
            startPaused: isPaused
        )
    }

    /// The item that carries the offset, or nil if this asset can't produce one.
    ///
    /// The arithmetic is the whole of it. At composition time `c` the picture
    /// is the source's picture at `c`, and the sound is wanted from source time
    /// `c - delay`. Asking for the sound *later* therefore means starting the
    /// audio track further into the timeline and leaving the opening silent;
    /// asking for it *earlier* means throwing away the front of the audio and
    /// starting what is left at the top.
    ///
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
        // file's audio tracks — so the index the user picked indexes this too.
        // Out of range falls back to the first rather than failing: a stream
        // with one track and a stale choice should still play.
        let audio = audioIndex.flatMap { audios.indices.contains($0) ? audios[$0] : nil } ?? audios.first
        guard let audio else { return nil }
        // What was *used*, which is not always what was asked for. Recorded so
        // a later choice of the same track doesn't compose the whole thing again.
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

        // Subtitles ride with the picture rather than the sound — they are
        // timed against what is on screen. Only the chosen one is carried:
        // every track in a composition is enabled, so inserting them all would
        // draw them all at once.
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

    /// Whether the server could be asked to build this stream differently.
    ///
    /// A transcode only. A direct play is the file exactly as it sits on the
    /// server's disk, so an offset in one is an offset in the library — asking
    /// ffmpeg to re-encode it would reproduce the fault faithfully.
    var canReencodeForSync: Bool {
        isActive && isTranscoding && !isLocal && !isExternal && item != nil
    }

    /// Ask the server to encode the picture and the sound together, for a
    /// transcode that arrived out of step and stayed that way.
    ///
    /// The fault this answers is the ordinary way a Jellyfin transcode ends up
    /// out of sync, and it is not repairable from this end. When ffmpeg copies
    /// the video bitstream through untouched and re-encodes only the audio —
    /// which is exactly what this client asks for most of the time, an HEVC
    /// picture carried across while a DTS or TrueHD track is turned into AC-3 —
    /// the two are timed against different things, and a start offset lands on
    /// a keyframe the audio was never cut at. Encoding both together puts them
    /// on one timebase. It costs the server real work, which is why it is asked
    /// for rather than assumed.
    func reencodeForSync() async {
        guard canReencodeForSync, let item else { return }
        var opts = options
        opts.forceTranscode = true
        opts.forceFullEncode = true
        opts.startSeconds = isLive ? nil : position
        #if !os(tvOS)
        AppModel.shared.toast("Asking the server to re-encode this stream…")
        #endif
        // `inherited`, so the rung this stream is already on is kept rather
        // than read back out of Settings, and `quiet`, because the stream
        // changing underneath is not news — it is what was just asked for.
        await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true))
    }

    // MARK: - Starting playback

    /// Play a server item. `meta.inherited` marks a start that carried its
    /// bitrate over rather than the user choosing one.
    func play(item: BaseItem, options: StreamOptions = .init(), meta: StartMeta = .init()) async {
        // Read before anything below is touched: whether there is a picture on
        // screen right now, of this very title, that is worth leaving there
        // while its replacement is built. See `handOver`.
        //
        // `timeControlStatus == .playing` is the whole test and is deliberately
        // stricter than "there is an item and it says it is ready". A stream
        // that died in the middle keeps a `readyToPlay` item and leaves its
        // last decoded frame on screen for ever — there is nothing to hand over
        // *from* there, and pressing Try again on it must go straight to the
        // plain replacement rather than spend half a minute preparing one
        // behind a picture that is already dead.
        let streamIsPlaying = isActive && !isOpening && !isBuffering
            && errorMessage == nil
            && !isLocal && !isExternal && !isLive
            && player.timeControlStatus == .playing
            && playerItem?.status == .readyToPlay
            && self.item?.Id == item.Id
            && !options.live

        // A song playing under a film is never what anyone meant.
        MusicPlayer.shared.yield()
        shuffleSeries = nil
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel()
        bitrateNotice = nil

        var opts = options
        if opts.maxBitrate == nil, !opts.bitrateIsChosen, !opts.live, prefs.defaultBitrate != nil,
           !meta.inherited {
            opts.maxBitrate = prefs.defaultBitrate
        }

        // Which of the file's tracks to ask for, settled here from the file's
        // own list rather than left to the server's defaults — see
        // `preferredStreams`. For a different file than the last one, always:
        // indexes carried over from the previous episode number *its* tracks.
        // For the same file, only when nothing has been chosen for it; a
        // reopen that names a track is that choice, and keeps it.
        if !opts.live, let source = item.MediaSources?.first, !source.streams.isEmpty,
           self.item?.Id != item.Id || (opts.audioStreamIndex == nil && opts.subtitleStreamIndex == nil) {
            let wanted = preferredStreams(in: source, seriesId: item.SeriesId)
            opts.audioStreamIndex = wanted.audio
            opts.subtitleStreamIndex = wanted.subtitle
        }

        let startSeconds: Double = {
            if let explicit = opts.startSeconds { return explicit.isFinite ? min(max(0, explicit), 30 * 86_400) : 0 }
            guard opts.resume, prefs.resumePlayback else { return 0 }
            let ticks = item.userData.positionTicks
            guard ticks > 0, let total = item.RunTimeTicks, total > 0 else { return 0 }
            // Something watched to the end resumes from the top, not from its
            // closing seconds.
            let f = Double(ticks) / Double(total)
            return f > 0.92 ? 0 : Double(ticks) / 10_000_000
        }()

        // A hand-over only makes sense somewhere into a stream: at the top of a
        // file there is nothing on screen worth preserving, and near the end
        // there is nowhere ahead of the playhead left to open the replacement
        // at. `duration` is the item that is playing now, which — this being a
        // hand-over — is the same item.
        let canHandOver = streamIsPlaying
            && startSeconds > 1
            && duration > 0
            && startSeconds + Self.handoverLead < duration - 30

        // Unless it is being handed over from, the stream on screen goes quiet
        // now rather than when its replacement arrives: until then its ticks
        // would report its own position under the new item's id, and its end
        // would advance past an episode that never opened.
        if !canHandOver { quiesceOutgoingStream() }

        // Keep the episode queue across a quality switch or a hop within the
        // same series.
        if self.item?.SeriesId != item.SeriesId { episodeQueue = nil }

        // Track state belongs to a file. A different item starts without the
        // last one's choices — they index someone else's track list, and the
        // composition in `attach` would be built around them.
        if self.item?.Id != item.Id {
            selectedAudioTrack = nil
            selectedSubtitleTrack = nil
            pendingTrackChoice = nil
            transcodingForSubtitle = meta.carriesSubtitleTranscode && opts.forceTranscode
        }

        self.item = item
        self.options = opts
        self.isLocal = false
        self.isExternal = false
        self.externalChannel = nil
        if !meta.reopening { resetLiveRecovery() }
        self.localRecordId = nil
        self.isLive = opts.live
        self.autoplayCancelled = false
        self.tracksApplied = false
        self.upNext = nil
        self.upNextChecked = false
        self.upNextSettled = false
        self.title = Self.displayTitle(item)
        self.subtitle = item.isEpisode ? (item.SeriesName ?? "") : Format.itemSubtitle(item)
        self.artworkURL = Artwork.url(item, type: "Primary", width: 600)
        self.currentBitrate = opts.maxBitrate
        self.isActive = true
        #if !os(tvOS)
        // Another device on the same iCloud account can pick this up — see
        // PlaybackHandoff. A channel has no position worth handing over.
        if opts.live {
            PlaybackHandoff.shared.end()
        } else {
            PlaybackHandoff.shared.begin(item: item, position: startSeconds)
        }
        #endif
        // Not while the old stream is still playing: `isBuffering` is what
        // draws the "opening…" card, and there is nothing to wait for on
        // screen — the picture carries on until the moment of the swap.
        self.isBuffering = !canHandOver
        if !meta.recovering && !meta.reopening {
            streamRecoveries = 0
            lastRecoveryAt = nil
        }
        generation &+= 1
        let mine = generation
        resolvingGeneration = mine

        // The replacement is asked for a little *ahead* of the playhead when the
        // old stream is going to go on playing while it is prepared, so that
        // the point it starts at is a point the picture has not reached yet.
        // See `handOver`.
        let handoverTarget = startSeconds + Self.handoverLead
        let requestedStart = canHandOver ? handoverTarget : startSeconds

        do {
            let src = try await client.resolvePlayback(
                itemId: item.Id,
                maxBitrate: opts.maxBitrate,
                forceTranscode: opts.forceTranscode || opts.forceFullEncode || opts.maxBitrate != nil,
                live: opts.live,
                startTicks: Int64(requestedStart * 10_000_000),
                fullEncode: opts.forceFullEncode,
                audioStreamIndex: opts.audioStreamIndex,
                subtitleStreamIndex: opts.subtitleStreamIndex
            )
            // Overtaken while the server was being asked: something else was
            // started, or this was closed. The session that has just been
            // opened is still ours to release — nobody else knows about it —
            // and nothing else here may be touched.
            guard generation == mine else {
                await release(src)
                return
            }
            let previous = self.source

            // A transcode replacing a stream that is still playing is handed
            // over rather than cut to. Only a transcode: everything else either
            // opens in a moment (a direct file) or carries an audio offset that
            // has to be composed, and a composition is not something to build
            // twice over. If the hand-over can't be made — the server never
            // gets far enough, the item won't open — it says so and the
            // ordinary path below runs, exactly as before.
            if canHandOver, src.isTranscode,
               await handOver(
                   to: src, at: handoverTarget, replacing: previous, generation: mine
               ) {
                resolvingGeneration = nil
                await loadExtras(for: item)
                guard generation == mine else { return }
                await client.reportPlaybackStart(report(paused: false))
                adaptive.begin(inherited: meta.inherited, ceiling: opts.maxBitrate)
                return
            }
            guard generation == mine else {
                await release(src)
                return
            }
            resolvingGeneration = nil
            self.isBuffering = true

            self.source = src
            self.isTranscoding = src.isTranscode
            // Every transcode this client asks for is HLS, and a Jellyfin HLS
            // playlist always covers the whole item from zero however many
            // StartTimeTicks the server was handed — that value only decides
            // which segment ffmpeg encodes first. So the offset has to be
            // seeked to here, exactly as the Linux build does with mpv's
            // --start. Trusting the server to have skipped ahead is what put
            // every quality change back at the top of the episode.
            // Where a hand-over that didn't come off resumes from. It may have
            // spent half a minute trying, during which the old stream went on
            // playing, and `startSeconds` is where the playhead was when this
            // began — going back to it would rewind the film by exactly as long
            // as the failed attempt took.
            let resumeAt = canHandOver ? max(startSeconds, position) : startSeconds
            attach(url: src.url, startAt: opts.live ? 0 : resumeAt, headers: client.authHeaders(for: src.url))
            // Release the transcode this one replaced: the ffmpeg process
            // behind it keeps running otherwise, and a few quality changes into
            // an episode the server is encoding it three times over.
            if let previous, previous.isTranscode, previous.playSessionId != src.playSessionId {
                await client.stopTranscode(playSessionId: previous.playSessionId)
            }
            // And the tuner behind it. `finish` closes the live stream when a
            // channel is *closed*; nothing did when one was *replaced* — a
            // reopen after a stall, Try again, a quality change — so the
            // server was asked to open the channel a second time while this
            // client still held the first. On anything with a limit (one
            // tuner, an M3U source that allows one connection) that second
            // open waits on the first, and the reopen that was meant to
            // rescue the channel is what finished it off.
            if let stale = previous?.mediaSource.LiveStreamId, !stale.isEmpty,
               stale != src.mediaSource.LiveStreamId {
                await client.closeLiveStream(id: stale)
            }
            await loadExtras(for: item)
            guard generation == mine else { return }
            await client.reportPlaybackStart(report(paused: false))
            adaptive.begin(inherited: meta.inherited, ceiling: opts.maxBitrate)
        } catch {
            guard generation == mine else { return }
            resolvingGeneration = nil
            // A hand-over's old stream was left playing while this was asked
            // for. It is not what the card is about, and must not go on
            // reporting as it.
            if canHandOver { quiesceOutgoingStream() }
            pendingTrackChoice = nil
            // The player stays up, with the card saying what went wrong.
            //
            // It used to clear `isActive` here, and that dismissed the cover:
            // a PlaybackInfo that failed or timed out — which for a live
            // channel is ordinary, since `AutoOpenLiveStream` has the server
            // open a tuner and probe the stream before it answers — looked
            // like a channel that loaded and then quietly went back to the
            // guide, with the message written and nothing left on screen to
            // show it. The card's Try again works from here: `item` is set,
            // so `canRetry` is true.
            Self.log.error(
                "start failed \(item.Id, privacy: .public) live=\(opts.live) reopening=\(meta.reopening): \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            isBuffering = false
            isOpening = false
            pendingSeek = nil
            isReopeningLive = false
        }
    }

    /// Give back everything a source holds on the server: its encode, and the
    /// tuner or connection behind a live channel. For a source that was opened
    /// and then never played — the start was overtaken while the server was
    /// still answering — and nobody else knows it exists.
    private func release(_ src: PlaybackSource) async {
        if src.isTranscode { await client.stopTranscode(playSessionId: src.playSessionId) }
        if let id = src.mediaSource.LiveStreamId, !id.isEmpty {
            await client.closeLiveStream(id: id)
        }
    }

    /// Silence the item in the player while its replacement is being asked
    /// for: paused, and with its observers gone, so it neither reports
    /// progress, nor ends, nor fails on behalf of whatever is opening. The item
    /// itself stays — on tvOS an empty player is one AVKit closes itself over.
    private func quiesceOutgoingStream() {
        teardownObservers()
        player.pause()
        // Said as well as done, so nothing that resumes "unless paused" — a
        // speed change, `recoverAudio` — starts it again. `installItem` sets
        // it afresh for the stream that replaces this one.
        isPaused = true
        pendingSeek = nil
        isOpening = false
        seekWatchdog?.cancel()
        seekWatchdog = nil
    }

    #if !os(tvOS)
    /// Play a downloaded file. Everything about it comes from the record on
    /// disk, so this works with no server at all.
    func playLocal(_ record: DownloadRecord, keepShuffle: Bool = false) {
        guard let url = DownloadManager.shared.mediaURL(for: record) else {
            // `errorMessage` is drawn by the player, and the player is exactly
            // what isn't opening — setting it here made a tap on the tile do
            // nothing at all, with nowhere for the reason to appear. Say it
            // where the tap happened, and put the record where a Retry can
            // reach it.
            DownloadManager.shared.markMissing(record.itemId)
            AppModel.shared.toast(
                "That download isn't on this device any more — it's in Downloads under Failed, with a Retry on it",
                tone: .error
            )
            return
        }
        MusicPlayer.shared.yield()
        if !keepShuffle { shuffleSeries = nil }
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel()
        bitrateNotice = nil
        item = nil
        source = nil
        options = .init()
        isLocal = true
        isExternal = false
        isLive = false
        isTranscoding = false
        localRecordId = record.itemId
        autoplayCancelled = false
        tracksApplied = false
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        pendingTrackChoice = nil
        transcodingForSubtitle = false
        upNext = nil
        upNextLocalId = nil
        upNextChecked = false
        upNextSettled = false
        title = record.title
        subtitle = record.series ?? ""
        artworkURL = (record.seriesArtURL ?? record.artURL).flatMap(URL.init(string:))
        currentBitrate = nil
        chapters = []
        segments = []
        trickplay = nil
        fullItem = nil
        isActive = true
        isBuffering = true
        attach(url: url, startAt: record.resumeSeconds, headers: [:])
        Task { await refreshLocalUpNext(after: record) }
    }
    #endif

    /// Play a channel that came from a custom M3U playlist instead of
    /// Jellyfin — see `IPTVSource`. No `resolvePlayback`, no PlaybackInfo, no
    /// progress reporting: the URL plays as given, straight into AVPlayer,
    /// exactly as a browser would open it.
    func playExternal(
        title: String,
        subtitle: String,
        artworkURL: URL?,
        streamURL: URL,
        channel: BaseItem? = nil,
        reopening: Bool = false
    ) {
        MusicPlayer.shared.yield()
        // As in `play`: the address may take a while to resolve, and the old
        // item's end or failure must not fire on this channel's behalf.
        quiesceOutgoingStream()
        shuffleSeries = nil
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel()
        bitrateNotice = nil
        item = nil
        source = nil
        options = StreamOptions(live: true)
        // The address the resolver already found for this very channel, carried
        // across the record being rebuilt below. Only for a reopen, and only
        // when it is the same channel: `retry()` deliberately comes through
        // here without it, because there the address is what's in doubt.
        let carriedResolution = reopening && externalChannel?.streamURL == streamURL
            ? externalChannel?.resolvedURL
            : nil
        externalChannel = ExternalChannel(
            title: title, subtitle: subtitle, artworkURL: artworkURL, streamURL: streamURL,
            item: channel, resolvedURL: carriedResolution
        )
        if !reopening { resetLiveRecovery() }
        isLocal = false
        localRecordId = nil
        isLive = true
        isExternal = true
        autoplayCancelled = true
        tracksApplied = false
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        pendingTrackChoice = nil
        transcodingForSubtitle = false
        upNext = nil
        upNextLocalId = nil
        upNextChecked = true
        upNextSettled = true
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        currentBitrate = nil
        chapters = []
        segments = []
        trickplay = nil
        fullItem = nil
        isActive = true
        isBuffering = true
        generation &+= 1
        let mine = generation
        externalResolve?.cancel()
        externalResolve = nil
        // A reopen already knows where this channel lives — see
        // `ExternalChannel.resolvedURL`. Walking the redirects again would cost
        // the reconnection up to twenty seconds of black screen and would put a
        // second request on a far end that has just dropped us.
        if let known = carriedResolution {
            attach(url: known, startAt: 0, headers: Self.externalHeaders())
            return
        }
        // Resolved before it is handed over rather than after it has failed —
        // see `StreamResolver`. A channel's address is very often a redirect to
        // the real one, and AVFoundation reads the address it is given rather
        // than the one it ends up at.
        externalResolve = Task { [weak self] in
            let resolved = await StreamResolver.resolve(streamURL)
            // `generation` rather than `isActive && isExternal`, which those two
            // cannot tell apart: closing this channel and opening another one is
            // a state that looks identical from here, and the walk that finished
            // late would attach the channel you just left over the one you asked
            // for. See `generation`.
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.externalResolve = nil
            guard !resolved.isBareTransportStream else {
                self.isBuffering = false
                self.errorMessage = "This channel is being sent as a raw MPEG-TS stream, which Apple's player can't open \u{2014} it reads transport-stream segments inside an HLS playlist, but never a transport stream on its own. Set this channel's stream mode to HLS on the server sending it."
                return
            }
            self.externalChannel?.resolvedURL = resolved.url
            self.attach(url: resolved.url, startAt: 0, headers: Self.externalHeaders())
        }
    }

    /// What a custom-playlist channel is fetched with.
    ///
    /// The User-Agent is the whole of it. Some stream servers vary what they
    /// serve by the client string, and AVFoundation's own `AppleCoreMedia/1.0.0…`
    /// is not always one they have a rule for. A channel that plays in one
    /// player and stutters in another, byte-identical either way, is usually
    /// this and nothing else — see `Preferences.iptvUserAgent`.
    private static func externalHeaders() -> [String: String] {
        ["User-Agent": Preferences.shared.iptvUserAgentHeader]
    }

    // MARK: - Changing stream without losing the picture

    /// How far ahead of the playhead a replacement stream is opened, and how
    /// long the whole hand-over may take before it is given up on.
    ///
    /// Twelve seconds is a guess at how long a Jellyfin server takes to start
    /// an encode and write a playable window of it, and it does not have to be
    /// right: reaching the point early only means waiting at step three, and
    /// reaching it late means the swap is made a little after it, which is the
    /// old behaviour and no worse.
    private static let handoverLead: Double = 12
    private static let handoverLimit: TimeInterval = 30

    /// Put a new transcode on screen without taking the old one off it first.
    ///
    /// A quality change is not a seek. It is the same picture at a different
    /// bitrate, and the ideal is that nothing visible happens at all. What
    /// stopped that being free is the server: Jellyfin starts a fresh ffmpeg at
    /// the offset and has to write enough segments to hand over, which takes
    /// seconds and often tens of them — and the player was given the new item
    /// straight away and sat on a black screen for every one of them. That is
    /// the whole of "it takes a while when it switches".
    ///
    /// So the replacement is asked for a little *ahead* of the playhead (see
    /// `handoverLead`), prepared inside a player of its own that nothing is
    /// looking at, and swapped in when the old stream's own clock reaches the
    /// point the new one begins at. Prepared in time, the change costs a frame.
    ///
    /// Returns whether the swap was made. `false` leaves everything exactly as
    /// it was — the old item is still installed and still playing — for the
    /// caller to fall back to the plain replacement.
    private func handOver(
        to src: PlaybackSource,
        at target: Double,
        replacing previous: PlaybackSource?,
        generation mine: Int
    ) async -> Bool {
        let asset = AVURLAsset(url: src.url, options: Self.assetOptions(client.authHeaders(for: src.url)))
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
        // deadline, and this hand-over being overtaken by another.
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
            ok = generation == mine && isActive
        }
        // 2. Move it to the point the swap will happen at and let it fill.
        if ok, candidate.status == .readyToPlay {
            let landed = await preroll.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
            ok = landed && generation == mine && isActive
            while ok, !candidate.isPlaybackLikelyToKeepUp, candidate.status == .readyToPlay,
                  Date() < deadline {
                _ = await wake.next()
                ok = generation == mine && isActive
            }
            ok = ok && candidate.isPlaybackLikelyToKeepUp
        } else {
            ok = false
        }
        // 3. Wait for the picture to reach where the new stream starts. Paused,
        //    it never will, and the swap is worth making immediately instead.
        //    `position` moves only on the player's half-second tick, so it is
        //    looked at four times a second rather than ten.
        while ok, !isPaused, position < target - 0.2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            ok = generation == mine && isActive
        }

        preroll.replaceCurrentItem(with: nil)
        guard ok, generation == mine, isActive else { return false }

        // 4. The swap. Landing where the picture actually is rather than where
        //    it was expected to be: if step three ran out of time, the playhead
        //    is past the point this stream was opened at, and the seek below is
        //    still inside what has been fetched. Short of the target — paused,
        //    sought back, or out of time — it lands where the picture is, not
        //    ahead of it: the playlist covers the whole item, and jumping to
        //    the target would skip what hasn't been watched or undo a seek.
        let landing = position >= target - 0.2 ? max(target, position) : position
        currentStreamURL = src.url
        sourceAsset = asset
        audioDelayIsApplied = false
        composedTracks = (nil, nil)
        source = src
        isTranscoding = src.isTranscode

        // A *new* item off the same asset, rather than the one that was
        // prerolled — and this is the whole of why the app used to die on a
        // quality change.
        //
        // "An AVPlayerItem cannot be associated with more than one instance of
        // AVPlayer" is not a warning, it is an `NSInvalidArgumentException`
        // thrown straight through Swift, and no `do`/`catch` in this file can
        // hold it. The line above used to be `preroll.replaceCurrentItem(with:
        // nil)` followed immediately by handing that same item to the real
        // player, on the theory that detaching it first made it free. It does
        // not: `replaceCurrentItem` is documented to take effect
        // *asynchronously*, so the item is still the preroll player's when the
        // next line claims it, and the app is gone.
        //
        // Building a second item costs the swap its seamlessness — the new one
        // has to fetch and fill where the prerolled one was already full — and
        // keeps everything the wait was actually for. What made a quality
        // change take tens of seconds was never the client's buffer; it was
        // Jellyfin starting an encoder from nothing and writing enough segments
        // to be playable. Steps one to three above are what wait for that, and
        // by the time this line runs the server is ready, the playlist is
        // fetched, and the asset it is fetched into is this same one. What is
        // left is a second of buffering rather than a frame — which is the
        // price of a swap that cannot throw.
        let live = AVPlayerItem(asset: asset)
        live.preferredForwardBufferDuration = 0
        installItem(live, startAt: landing, startPaused: isPaused)

        // Only now: the old encode was feeding the picture until a moment ago.
        if let previous, previous.isTranscode, previous.playSessionId != src.playSessionId {
            await client.stopTranscode(playSessionId: previous.playSessionId)
        }
        return true
    }

    private func attach(
        url: URL, startAt: Double, headers: [String: String], startPaused: Bool = false
    ) {
        currentStreamURL = url
        // A stored offset is built into the stream as it opens rather than
        // applied to it a moment later, so nothing is ever handed to the player
        // at the wrong offset first. See the audio-offset section.
        let delay = streamCarriesDelay ? appliedAudioDelay : 0
        guard delay != 0 else {
            attachPlainly(url: url, startAt: startAt, headers: headers, startPaused: startPaused)
            return
        }
        isBuffering = true
        // Not bumped, only read: whoever called this has already taken their
        // number, and a stream started or closed while the composition is being
        // built wins over it. See `generation`.
        let mine = generation
        let audioChoice = selectedAudioTrack
        let subtitleChoice = selectedSubtitleTrack
        Task {
            let built = await Self.makeDelayedItem(
                url: url, headers: headers, delay: delay,
                audioIndex: audioChoice, subtitleIndex: subtitleChoice
            )
            guard generation == mine else { return }
            guard let built else {
                // This file won't compose — an audio track AVFoundation won't
                // hand over, a duration it can't read. The offset itself is
                // left alone: it is a standing preference and the next file
                // will want it. This one plays in step rather than not at all.
                attachPlainly(url: url, startAt: startAt, headers: headers, startPaused: startPaused)
                #if !os(tvOS)
                AppModel.shared.toast(
                    "This file's sound can't be shifted — playing it in step", tone: .error)
                #endif
                return
            }
            sourceAsset = built.source
            audioDelayIsApplied = true
            composedTracks = (built.audio, built.subtitle)
            installItem(built.item, startAt: startAt, startPaused: startPaused)
        }
    }

    private func attachPlainly(
        url: URL, startAt: Double, headers: [String: String], startPaused: Bool
    ) {
        let asset = AVURLAsset(url: url, options: Self.assetOptions(headers))
        sourceAsset = asset
        audioDelayIsApplied = false
        composedTracks = (nil, nil)
        installItem(AVPlayerItem(asset: asset), startAt: startAt, startPaused: startPaused)
    }

    private static func assetOptions(_ headers: [String: String]) -> [String: Any] {
        headers.isEmpty
            ? [:]
            // Jellyfin's own transcode URLs carry their key, but a direct-play
            // URL is built here and deliberately doesn't — the token rides the
            // request instead, so it stays out of the server's access log.
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    }

    /// Put a prepared item into the player.
    ///
    /// Split out of `attach` because an audio delay produces its item a
    /// different way — out of a composition rather than straight from a URL —
    /// and everything from here down is the same either way. See
    /// `makeDelayedItem`.
    private func installItem(_ newItem: AVPlayerItem, startAt: Double, startPaused: Bool = false) {
        teardownObservers()
        // The last item's opening watchdog is not this one's.
        seekWatchdog?.cancel()
        seekWatchdog = nil
        // The sound carries on when the screen locks or the app goes behind
        // another — the thing the `audio` background mode is declared for.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Asked for again on every stream rather than once at launch. The
        // session is shared with every other app on the device, and something
        // else taking it — a call, a podcast, Siri — leaves this one inactive
        // until it is claimed back. It is a no-op when it is already ours.
        configureAudioSession()
        // Zero is not "don't buffer" — it is AVFoundation deciding for itself,
        // and it reads a long way further ahead than this used to allow. The
        // explicit ten seconds was a *ceiling*: it told the player to stop
        // filling at ten seconds, which is exactly the wrong instruction for a
        // transcode being produced live at the other end. A deep buffer is what
        // rides out both a bad minute of Wi-Fi and an encoder that falls
        // momentarily behind real time.
        //
        // Live used to be the exception, capped at twelve seconds on the
        // argument that read-ahead *is* delay. For HLS that argument is simply
        // wrong, and it cost this player most of its resilience for nothing.
        // How far behind the broadcast you are is decided by where you join the
        // playlist — the live edge, three target durations back — and it is
        // fixed from that moment. Downloading further ahead does not push the
        // playhead later; it only means more of what is coming is already here.
        // So the cap bought no latency at all and threw away the entire buffer:
        // with six- or ten-second segments, twelve seconds is barely one
        // segment of headroom, and every wobble in the network became a stall.
        // Live now gets what everything else gets, which is AVFoundation's own
        // judgement.
        newItem.preferredForwardBufferDuration = 0
        // What actually controls the latency, and what actually keeps a live
        // stream alive over a bad hour.
        //
        // Left alone, AVPlayer joins at the edge and then, after every rebuffer,
        // resumes from where it stopped — so each stall pushes the playhead a
        // few seconds further behind, permanently, and the drift only
        // accumulates. Eventually it is behind the oldest segment the server
        // still holds, that segment 404s, and what arrives is
        // `CoreMediaErrorDomain -12889` and a stream that has to be reopened
        // from scratch. That is the "freezes, then has to be restarted" this
        // whole section exists for, and it was never a bandwidth problem.
        //
        // `automaticallyPreservesTimeOffsetFromLive` is the part that fixes it:
        // the player treats the offset as a target and quietly reclaims it
        // after a stall rather than banking the loss. The configured twenty
        // seconds is the margin it defends.
        if isLive {
            newItem.automaticallyPreservesTimeOffsetFromLive = true
            newItem.configuredTimeOffsetFromLive =
                CMTime(seconds: Self.liveOffsetFromLive, preferredTimescale: 1)
        }
        applySubtitleStyling(to: newItem)
        playerItem = newItem
        player.replaceCurrentItem(with: newItem)
        player.volume = Float(volume)
        player.isMuted = isMuted

        // The seek can't be made yet. An HLS asset has no seekable range until
        // its playlist has been fetched, and a seek issued before then is
        // dropped without a word — the stream just plays from its first
        // segment. It's held here and made in `applyPendingSeek` once the item
        // is ready, with playback held back until then so the opening seconds
        // never flash up before the jump.
        pendingSeek = startAt > 1 ? startAt : nil
        position = pendingSeek ?? 0
        isOpening = pendingSeek != nil

        installObservers(on: newItem)
        #if os(tvOS)
        refreshHeldPicture(for: newItem)
        #endif
        if pendingSeek == nil {
            startPlaying()
        } else {
            // Explicitly, rather than by leaving the rate alone: the rate the
            // last stream was playing at carries over to the new item, and the
            // opening seconds would play under the hold.
            player.rate = 0
        }
        isPaused = startPaused
        if startPaused { player.rate = 0 }
        NowPlaying.shared.update(from: self)
        // A new card: the next tick sets the clock against it.
        nowPlayingAnchor = nil
        armLiveWatchdog()
    }

    /// How far behind the live edge a channel is asked to sit, in seconds.
    ///
    /// Twenty is enough to absorb a segment that arrives late without being
    /// long enough for anyone to notice they are behind — and, because
    /// `automaticallyPreservesTimeOffsetFromLive` is set alongside it, it is a
    /// margin the player spends and then earns back rather than one it loses
    /// once and keeps losing. See `installItem`.
    private static let liveOffsetFromLive: Double = 20

    /// Jump to the position this stream was started at, now that its asset can
    /// answer a seek.
    private func applyPendingSeek() {
        guard let target = pendingSeek else {
            isBuffering = false
            return
        }
        pendingSeek = nil
        // Both answers below belong to the item this seek was made on, and
        // must not release the hold of whatever has replaced it since.
        let seekItem = playerItem.map({ ObjectIdentifier($0) })
        // A transcode that has to be encoding at the offset before it can serve
        // it can take tens of seconds to answer, and a server that has given up
        // never answers at all. Either way the hold has to end.
        seekWatchdog?.cancel()
        seekWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.isActive, self.isOpening,
                  self.playerItem.map({ ObjectIdentifier($0) }) == seekItem else { return }
            self.releaseOpeningHold(at: nil)
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            // Unwrapped out here rather than inside the task: a weak capture is
            // a mutable binding, and reading it from the concurrent job is what
            // Swift 6 refuses. What the task captures is the plain reference.
            guard let self else { return }
            Task { @MainActor in
                // An interrupted seek was overtaken by another — the user's,
                // which releases the hold itself — or by the item going; the
                // watchdog covers anything else.
                guard finished, self.isActive,
                      self.playerItem.map({ ObjectIdentifier($0) }) == seekItem else { return }
                self.releaseOpeningHold(at: target)
            }
        }
    }

    /// Start playing the stream that was held open at a position.
    private func releaseOpeningHold(at target: Double?) {
        seekWatchdog?.cancel()
        seekWatchdog = nil
        guard isOpening else { return }
        isOpening = false
        // The startup grace is meant to cover the seconds a stream spends
        // finding its feet. Those seconds start here, not when the stream was
        // asked for: opening a transcode at an offset can take half a minute,
        // and the grace had long since run out by the time a frame appeared.
        adaptive.noteOpened()
        if let target { position = target }
        isBuffering = false
        if !isPaused { startPlaying() }
    }

    /// Start the picture moving.
    ///
    /// `play()` rather than a rate written straight into the player, and the
    /// difference is not cosmetic. `automaticallyWaitsToMinimizeStalling` is on
    /// by default and is never turned off here: it is the heuristic that holds
    /// a stream back until it has buffered enough to run without stopping, and
    /// it is built around `play()`. Setting `rate` is a demand to start *now*,
    /// which on a live channel means starting on an all-but-empty buffer and
    /// stalling a second later — the stall then being read as a bad connection
    /// rather than as an instruction this player gave itself.
    ///
    /// Only a speed that isn't 1× still needs the rate, and live never offers
    /// one.
    private func startPlaying() {
        if abs(speed - 1) < 0.001 {
            player.play()
        } else {
            player.rate = Float(speed)
        }
    }

    // MARK: - Live stall recovery

    /// How long a live stream may sit with its clock stopped before the cheap
    /// recovery is tried on it.
    ///
    /// Twenty-eight seconds, not twelve. Twelve was set against a
    /// twelve-second read-ahead cap, where a stopped clock really did mean the
    /// feed had gone; with a proper buffer underneath it, twelve seconds is one
    /// slow segment, and answering that with a full teardown turns a hiccup
    /// nobody would have noticed into fifteen seconds of black screen. The
    /// cheap recovery below runs long before this does.
    private static let liveStallLimit: TimeInterval = 28
    /// The same, for a stream that has not produced a frame yet. Much longer,
    /// because starting a channel is the slow part: a re-streamer has to launch
    /// ffmpeg and write enough segments to fill a playlist before anything can
    /// be handed over, and fifteen seconds of that is ordinary. Reopening it
    /// during that wait would restart the very thing being waited for.
    ///
    /// Sixty rather than forty: a Jellyfin channel starts its clock only once
    /// PlaybackInfo has answered, and what follows is ffmpeg starting from
    /// nothing and writing enough of a playlist for AVFoundation to join — on
    /// a busy server, or one encoding in software, that alone can run past
    /// forty. A reopen at that point restarts the very encode being waited
    /// for, and three of them in a row spend the whole budget on a channel
    /// that would have played on its own a moment later.
    private static let liveOpenLimit: TimeInterval = 60
    private static let liveReopenLimit = 3
    /// How long a reopened stream has to play for before its stall is treated
    /// as a one-off and the budget of attempts is handed back.
    private static let liveRecoveryWindow: TimeInterval = 60

    /// Watch a live stream for having quietly stopped.
    ///
    /// A live stream that the far end stops feeding does not fail. The item
    /// stays `readyToPlay`, no error is posted, `AVPlayerItem.status` never
    /// moves, and AVFoundation goes on waiting for a segment that is not
    /// coming. What is left on the screen is the last frame that decoded — for
    /// ever, with no message and nothing to press. That is the freeze this
    /// exists to end.
    ///
    /// Nothing else in the player covers it. `seekWatchdog` only ever arms for
    /// a stream opening at a position, which a live one never is, and adaptive
    /// quality — which does now reach a Jellyfin live channel — answers a
    /// different question: it moves a stream that is struggling, not one that
    /// has stopped arriving altogether.
    ///
    /// Two recoveries hang off this, in order of what they cost. `jumpToLiveEdge`
    /// moves the playhead to where the server still has segments, which is what
    /// most stalls actually are and costs a seek. Failing that,
    /// `reopenStalledLive` opens the channel again — which for an IPTV channel
    /// is also the only way to get a *new* session out of the server sending
    /// it, rather than rejoining the one that just died.
    private func armLiveWatchdog() {
        liveWatchdog?.cancel()
        isReopeningLive = false
        guard isLive, isActive else { liveWatchdog = nil; return }
        lastAdvance = (Date(), -1)
        jumpedForThisStall = false
        liveWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.checkLiveProgress() else { return }
            }
        }
    }

    /// One tick of the watchdog. Returns false when there is nothing left to
    /// watch — the stream ended, or it is being reopened and will arm a new one.
    private func checkLiveProgress() -> Bool {
        guard isActive, isLive, errorMessage == nil else { return false }
        // Standing still on purpose: paused by the user, or held at an opening
        // position. `player.timeControlStatus` rather than `isPaused` — the
        // latter is maintained from the periodic time observer, which is one of
        // the things that stops firing when a stream dies.
        guard player.timeControlStatus != .paused, !isOpening else {
            lastAdvance = (Date(), lastAdvance?.position ?? -1)
            return true
        }

        let clock = player.currentTime().seconds
        let now = clock.isFinite ? clock : -1
        guard let last = lastAdvance else {
            lastAdvance = (Date(), now)
            return true
        }
        if now > last.position + 0.25 {
            lastAdvance = (Date(), now)
            jumpedForThisStall = false
            // Playing steadily since the last reopen means that stall was a
            // one-off; a channel that hiccups once an hour should keep being
            // recovered rather than run out of attempts over a whole evening.
            if liveReconnects > 0,
               Date().timeIntervalSince(lastReopenAt) > Self.liveRecoveryWindow {
                liveReconnects = 0
            }
            return true
        }
        // Before the first frame this is a channel still starting up, not one
        // that has died, and it is given far longer.
        let limit: TimeInterval
        if jumpedForThisStall {
            // A jump has already been made and the clock still hasn't moved.
            // The seek either landed in a segment the server actually has or it
            // didn't, and that is answered in a few seconds — so this is the
            // short wait before giving up on the cheap repair, not another full
            // stall limit on top of the one already served.
            limit = Self.liveEdgeGrace
        } else {
            limit = last.position <= 0 ? Self.liveOpenLimit : Self.liveStallLimit
        }
        guard Date().timeIntervalSince(last.at) >= limit else { return true }
        isBuffering = true
        // The cheap repair first. A live stream that has stopped moving is much
        // more often a playhead sitting behind where the server still has
        // segments than it is a feed that has died, and that costs a seek to
        // fix — no new session, no resolver walk, no refill from nothing.
        if !jumpedForThisStall, jumpToLiveEdge() {
            jumpedForThisStall = true
            // The timestamp restarts; the position deliberately does not. A
            // sentinel here would push the next check into `liveOpenLimit`,
            // which is the branch for a channel that has never produced a
            // frame — the opposite of what this is.
            lastAdvance = (Date(), last.position)
            return true
        }
        Task { await self.reopenStalledLive() }
        return false
    }

    /// When the playhead was last thrown forward to the live edge, and whether
    /// that has already been tried for the stall now in progress. Cleared the
    /// moment the clock moves again.
    private var jumpedToEdgeAt = Date.distantPast
    private var jumpedForThisStall = false
    /// How long a live-edge jump is given to take effect before the stream is
    /// reopened instead.
    private static let liveEdgeGrace: TimeInterval = 10
    /// How often that may be done. Often enough to rescue the occasional
    /// stall; rarely enough that a channel which is genuinely dead reaches
    /// `reopenStalledLive` on the next tick instead of skipping forward for
    /// ever inside a window that isn't moving.
    private static let liveEdgeJumpInterval: TimeInterval = 30

    /// Throw the playhead forward to the end of what the server still holds,
    /// without taking the stream down.
    ///
    /// Returns whether there was anywhere to jump to. False means the seekable
    /// window isn't ahead of us — which is the real "this feed has stopped",
    /// and the case a reopen is for.
    private func jumpToLiveEdge() -> Bool {
        guard let avItem = playerItem,
              Date().timeIntervalSince(jumpedToEdgeAt) > Self.liveEdgeJumpInterval,
              let range = avItem.seekableTimeRanges.last?.timeRangeValue,
              range.duration > .zero
        else { return false }
        // Not the very end: the last segment in a playlist is frequently still
        // being written, and landing on it is landing on the same stall again.
        let edge = CMTimeSubtract(range.end, CMTime(seconds: 4, preferredTimescale: 1))
        let target = CMTimeMaximum(edge, range.start)
        guard CMTimeCompare(target, player.currentTime()) > 0 else { return false }
        jumpedToEdgeAt = Date()
        player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.isLive, !self.isPaused else { return }
                self.startPlaying()
            }
        }
        return true
    }

    /// Open the live stream again after it stopped feeding, and say so once
    /// reopening it has stopped helping.
    private func reopenStalledLive() async {
        guard isActive, isLive, errorMessage == nil, !isReopeningLive else { return }
        isReopeningLive = true
        liveWatchdog?.cancel()
        liveWatchdog = nil
        liveReconnects += 1
        lastReopenAt = Date()
        Self.log.notice("reopening live stream, attempt \(self.liveReconnects) of \(Self.liveReopenLimit)")
        guard liveReconnects <= Self.liveReopenLimit else {
            isReopeningLive = false
            isBuffering = false
            errorMessage = "This channel stopped sending data. Reopening it "
                + "\(Self.liveReopenLimit) times didn't bring it back — the server "
                + "sending the channel is the thing that has stopped."
            return
        }
        isBuffering = true
        // The dead item goes before its replacement is asked for, not after it
        // arrives. It was still holding a socket open on the far end for the
        // whole of the resolve-and-attach, and on a source that allows one
        // connection at a time — a single tuner, a one-client stream server —
        // that is the reopen being refused by a connection this app is itself
        // still holding. The observers come down with it so the corpse can't post a
        // `didPlayToEndTime` into the middle of its own recovery.
        teardownObservers()
        player.replaceCurrentItem(with: nil)
        playerItem = nil
        // For a Jellyfin channel the socket is only half of it: the server is
        // holding the tuner open on this client's behalf, and until it is
        // told otherwise the PlaybackInfo below asks for a second one. Closed
        // here, before the pause, so the far end has that pause to free it.
        // `play` would close it too, but only after the new stream had been
        // opened — which on a single tuner is after it had waited for this.
        // The encode goes with it, for the same reason and so `play` doesn't
        // find a source it has already been asked to stop.
        //
        // Let go of before the await rather than after it: a start made while
        // the release is in flight owns `source` by the time it returns, and
        // clearing it then would leak that start's encode and tuner.
        let mine = generation
        if let held = source {
            source = nil
            await release(held)
        }
        // And a moment for the far end to notice. A server that has just
        // dropped a connection generally needs a beat before it will hand out
        // another, and three reopens fired back to back inside a second is how
        // a recoverable stall spends the whole budget without ever giving the
        // channel a chance to answer. Lengthens with each attempt.
        try? await Task.sleep(for: .seconds(0.6 * Double(liveReconnects)))
        guard generation == mine else { return }
        guard isActive, isLive, isReopeningLive else {
            isReopeningLive = false
            return
        }
        if let channel = externalChannel {
            playExternal(
                title: channel.title,
                subtitle: channel.subtitle,
                artworkURL: channel.artworkURL,
                streamURL: channel.streamURL,
                channel: channel.item,
                reopening: true
            )
        } else if let item {
            await play(item: item, options: options, meta: StartMeta(reopening: true))
        }
    }

    private func resetLiveRecovery() {
        liveWatchdog?.cancel()
        liveWatchdog = nil
        isReopeningLive = false
        lastAdvance = nil
        liveReconnects = 0
        lastReopenAt = .distantPast
        jumpedForThisStall = false
        jumpedToEdgeAt = .distantPast
    }

    /// Start whatever is on screen over again — what the error card offers when
    /// a stream failed outright. A channel is re-resolved from the address the
    /// playlist gave rather than from wherever the dead session resolved to.
    func retry() async {
        resetLiveRecovery()
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        if let channel = externalChannel {
            playExternal(
                title: channel.title,
                subtitle: channel.subtitle,
                artworkURL: channel.artworkURL,
                streamURL: channel.streamURL,
                channel: channel.item
            )
        } else if let item {
            await play(item: item, options: options)
        }
    }

    /// Whether there is something for "Try again" to reopen.
    var canRetry: Bool { externalChannel != nil || item != nil }

    // MARK: - What is playing, for the info panel

    /// The item behind what is on screen, wherever it came from: the server's
    /// own item, or the playlist channel an external stream was tuned from.
    ///
    /// `playExternal` reduces a channel to a title and an address, which is all
    /// playback needs; the info panel needs the channel itself, to find its
    /// number, its logo and the programme it is showing in the guide.
    var infoItem: BaseItem? { fullItem ?? item ?? externalChannel?.item }

    /// What the stream turned out to be, as opposed to what was asked for.
    ///
    /// Read out of the player item each time rather than kept: none of it is a
    /// property anything writes, so there is nothing here for observation to
    /// notice. The panel that shows it redraws on the clock — see
    /// `PlayerStreamPanel`.
    struct StreamFacts: Sendable {
        var width: Int?
        var height: Int?
        /// Bits per second the variant being played declares.
        var indicatedBitrate: Double?
        /// Bits per second actually arriving.
        var observedBitrate: Double?
        var stalls: Int?
        var droppedFrames: Int?
        /// Where the bytes are coming from, the host and nothing else: the
        /// address itself carries this session's access token, and a television
        /// is the last screen to put one on.
        var host: String?

        var resolution: String? {
            guard let width, let height else { return nil }
            return "\(width)×\(height)"
        }
    }

    var streamFacts: StreamFacts {
        var facts = StreamFacts(host: currentStreamURL?.host)
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
            MainActor.assumeIsolated { self?.handleReachedEnd() }
        }

        // Where a mid-playback HLS failure actually shows up. An item whose
        // playlist or segments go bad twenty minutes in does not move to
        // `.failed` — it has been playing, so its status stays `readyToPlay`
        // — it posts this instead, with the CoreMedia code in the user info.
        // Watched only from here, so a stream that dies in the middle takes the
        // same road as one that never opened. See `handleStreamFailure`.
        failedEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: avItem, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                self?.handleStreamFailure(error, duringPlayback: true)
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
                guard let self else { return }
                self.isBuffering = true
                // A stream still being held open at its start position is not a
                // stream that can't keep up: the rate is deliberately 0 and the
                // buffer is empty because we haven't let it play yet. Counting
                // that as stalling is what walked a freshly chosen quality back
                // down the ladder the moment it finally opened.
                if !self.isOpening { self.noteStall() }
            }
        }

        // Duration and track lists only become known once enough of the asset
        // has loaded, so they're read when the status flips rather than now.
        avItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if status == .readyToPlay {
                        self.applyPendingSeek()
                        self.watchForPicture(on: avItem)
                        Task { await self.readTracks() }
                    } else if status == .failed {
                        self.handleStreamFailure(avItem.error)
                    }
                }
            }
            .store(in: &statusObservers)

        // Whether this stream has a picture, asked of the thing that would be
        // drawing it.
        //
        // The track lists are no use for the case that matters. `loadTracks`
        // on an AVURLAsset answers for a file; for an HLS stream it returns
        // nothing at all, whether the stream has video or not — so a channel
        // with an undecodable picture and a channel that was fine looked
        // identical, and the explanation this app had written for exactly that
        // situation never appeared. What was left on screen was AVKit's
        // audio-only placeholder and no reason for it.
        //
        // `presentationSize` is the size of the picture actually being
        // presented, so a non-zero one settles the question outright.
        avItem.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                MainActor.assumeIsolated {
                    guard let self, self.playerItem === avItem else { return }
                    if size != .zero {
                        if self.pictureSize != size { self.pictureSize = size }
                        self.pictureWatchdog?.cancel()
                        self.pictureWatchdog = nil
                        self.noVideoTrack = false
                    }
                }
            }
            .store(in: &statusObservers)

        avItem.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keepUp in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if keepUp { self.endStall() }
                    if keepUp, !self.isOpening { self.isBuffering = false }
                }
            }
            .store(in: &statusObservers)

        avItem.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] empty in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if empty, !self.isPaused {
                        self.isBuffering = true
                        if !self.isOpening { self.noteStall() }
                    }
                }
            }
            .store(in: &statusObservers)
    }

    // MARK: - Stream failures

    /// A stream stopped, either before it ever opened or in the middle.
    ///
    /// Most of what arrives here is fatal and belongs on the error card. A
    /// particular family of it is not, and this is what that family looks like
    /// from the app: `CoreMediaErrorDomain -12889` and its neighbours, which do
    /// not mean "this file cannot be played" — they mean the HLS session behind
    /// it went out from under the player. A transcode the server reaped for
    /// idling, a segment that aged out of a live playlist's sliding window, a
    /// connection that dropped between two segments: in every one of those the
    /// item is still perfectly playable and the fix is to ask for it again.
    /// Which is precisely what a person does when the card appears, so the
    /// player does it for them, at the position they were at, twice, before
    /// giving up and saying so.
    private func handleStreamFailure(_ error: (any Error)?, duringPlayback: Bool = false) {
        // A live stream that dies *while playing* is the stall watchdog's, not
        // this function's: it has its own budget of reopens, its own idea of how
        // long a channel may sit still, and it re-resolves the address from the
        // playlist rather than from wherever the dead session ended up. Sending
        // one here instead would put an error card over a channel that a single
        // reopen fixes — see `reopenStalledLive`, and `handleReachedEnd`, which
        // hands over the same way for the same reason.
        //
        // A live stream that fails on the way *up* still lands below, because
        // that is where `StreamDiagnosis` is: a channel whose codec this device
        // can't decode should be told so on the first attempt, not after three
        // silent reopens of a stream that was never going to play.
        if duringPlayback, isLive, isActive, errorMessage == nil, !isReopeningLive {
            Self.log.notice(
                "live stream failed mid-play: \(error?.localizedDescription ?? "no error", privacy: .public); reopening")
            isBuffering = true
            Task { await self.reopenStalledLive() }
            return
        }
        Self.log.error(
            "stream failure live=\(self.isLive) external=\(self.isExternal) duringPlayback=\(duringPlayback): \(error?.localizedDescription ?? "no error", privacy: .public)")
        if recoverFromStreamFailure(error) { return }
        // Not a session that went bad, then — the stream itself is the problem.
        // If the server sent the original file, it has another way to send it.
        if escalateToTranscode() { return }
        errorMessage = error?.localizedDescription ?? "This stream couldn't be played"
        // An IPTV channel that fails outright gets looked into for the same
        // reason one that plays without a picture does: AVFoundation's own
        // message names no cause, and the cause is written in the stream. Which
        // of the two happens for an undecodable codec is not even stable — it
        // differs between devices — so both roads have to lead to the same
        // explanation.
        diagnoseExternalStream()
        isBuffering = false
        isOpening = false
        pendingSeek = nil
        seekWatchdog?.cancel()
        seekWatchdog = nil
    }

    /// Quietly reopen the current item where it left off, when the failure was
    /// one a fresh session fixes. Returns whether it took the job on.
    private func recoverFromStreamFailure(_ error: (any Error)?) -> Bool {
        // A live stream has its own recovery, with its own budget and its own
        // idea of what a stall is — see `armLiveWatchdog`. Two of them fighting
        // over one channel is how attempts get spent twice as fast.
        guard let item, isActive, !isLive, !isLocal else { return false }
        guard Self.isRecoverableStreamFailure(error) else { return false }
        guard streamRecoveries < Self.streamRecoveryLimit else { return false }
        streamRecoveries += 1
        lastRecoveryAt = Date()

        // Where to come back to. `position` is the truth unless the stream was
        // still being held open at an offset it never reached, in which case
        // the offset is.
        let resume = isOpening ? (pendingSeek ?? position) : position
        pendingSeek = nil
        isOpening = false
        seekWatchdog?.cancel()
        seekWatchdog = nil
        isBuffering = true

        var opts = options
        opts.startSeconds = max(0, resume)
        // Inherited, so the quality policy treats this as the same stream
        // carrying on rather than a rung somebody just chose.
        Task { await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true, recovering: true)) }
        return true
    }

    /// Ask the server to transcode the thing that just refused to play.
    ///
    /// The backstop to `DeviceProfile.canDirectPlay`, and between them they are
    /// what "transcode it automatically when the video won't play" actually
    /// means here. That check runs before a stream is opened and catches what
    /// can be read off the server's own description of the file; this one runs
    /// after it has been opened and catches everything that description didn't
    /// say — an ffprobe that reported no bit depth, an HEVC variant that is on
    /// paper Main 10 and in practice undecodable, a container whose contents
    /// aren't what its extension claims.
    ///
    /// Both failures look like this from here: a direct play that either failed
    /// outright or is playing sound with no picture. In both cases the file is
    /// fine and the server can send a version of it that works, so it is asked
    /// for one — at the position the viewer had reached, with no rung named, so
    /// the transcode comes back at the best quality the server can manage. No
    /// error card, no prompt; the picture simply arrives a few seconds later.
    ///
    /// Returns whether it took the job on. Once per stream: `forceTranscode` is
    /// already set on the second pass, so a transcode that also fails falls
    /// through to the error card rather than being asked for again.
    @discardableResult
    private func escalateToTranscode() -> Bool {
        guard let item, isActive, !isLocal, !isExternal, !isLive else { return false }
        guard let source, !source.isTranscode else { return false }
        guard !options.forceTranscode else { return false }
        // Something with no video track at all is not a codec this device is
        // failing to decode — it is an audio file, and re-encoding it will not
        // produce a picture. Only a source the server positively described as
        // having no video is refused; one it described not at all is tried.
        let streams = source.mediaSource.streams
        if !streams.isEmpty, !streams.contains(where: { $0.type == "Video" }) { return false }

        let resume = isOpening ? (pendingSeek ?? position) : position
        pendingSeek = nil
        isOpening = false
        seekWatchdog?.cancel()
        seekWatchdog = nil
        pictureWatchdog?.cancel()
        pictureWatchdog = nil
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        isBuffering = true

        var opts = options
        opts.forceTranscode = true
        opts.startSeconds = max(0, resume)
        Task {
            await play(
                item: item,
                options: opts,
                meta: StartMeta(inherited: true, quiet: true, recovering: true)
            )
        }
        return true
    }

    /// CoreMedia codes that mean the session went bad rather than the media
    /// being unplayable.
    ///
    /// -12889 is the one that started this: the player asked for a segment the
    /// playlist no longer lists. -12888 is its sibling, a playlist that stopped
    /// being updated. -12660 is a 403 on a segment, which on Jellyfin is a
    /// transcode whose session the server has already closed. -1102 is its 401.
    /// -12927 is the read itself failing part-way through — the connection went
    /// away between two reads of the same file — which is what a direct play
    /// over a Wi-Fi that hiccuped reports, and it says nothing whatever about
    /// whether the file can be decoded. It was reaching the error card, where
    /// the only thing that worked was closing the player and opening the same
    /// title again: which is exactly what this does, without the trip.
    /// Deliberately a short list: anything not on it is treated as real, and a
    /// file that genuinely will not decode must reach the error card on its
    /// first try rather than after two silent retries.
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
    private static func isRecoverableStreamFailure(_ error: (any Error)?) -> Bool {
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

    /// Give the stream a few seconds to produce a frame, then take silence for
    /// an answer.
    ///
    /// A backstop, not the main test. `presentationSize` catches a stream that
    /// reports nothing at all, but it cannot be trusted the other way round: an
    /// HLS master playlist that advertises `RESOLUTION=1920x1080` gives the
    /// item that size whether or not a frame ever decodes, so a channel whose
    /// video this device can't read looks, from here, exactly like one that is
    /// playing. `StreamDiagnosis` is what actually settles it, by reading the
    /// stream — which is why a finding from there outranks anything measured
    /// here and is never cleared by it.
    private func watchForPicture(on avItem: AVPlayerItem) {
        pictureWatchdog?.cancel()
        guard avItem.presentationSize == .zero else {
            if noVideoDetail == nil { noVideoTrack = false }
            return
        }
        pictureWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.playerItem === avItem else { return }
            self.pictureWatchdog = nil
            let missing = avItem.presentationSize == .zero
            self.noVideoTrack = missing
            guard missing else { return }
            self.noVideoTrack = true
            // A *server* item playing sound with no picture is a video codec
            // this device can't decode, and unlike an IPTV channel there is
            // something to be done about it: the server has the file and can
            // send a version that plays. Asked for silently, in place of the
            // banner explaining why there's nothing to look at.
            if self.escalateToTranscode() { return }
            // Only an external channel gets looked into: a Jellyfin stream was
            // negotiated through PlaybackInfo and the server already knows what
            // it sent, whereas an IPTV address is opaque until something reads
            // it.
            self.diagnoseExternalStream()
        }
    }

    /// Read what the channel actually contains and say so, on whichever of the
    /// two failures happened. Only for external channels: a Jellyfin stream was
    /// negotiated through PlaybackInfo and the server already knows what it
    /// sent, whereas an IPTV address is opaque until something reads it.
    ///
    /// Deliberately *not* run speculatively as every channel opens, which is
    /// what it used to do. Reading a stream means fetching the master playlist,
    /// the media playlist and a range of the first segment — three requests to
    /// the source, concurrent with the one AVPlayer is making. On a source
    /// that allows a single connection at a time, that is the app killing its
    /// own stream: the server drops a connection, the picture freezes, the
    /// watchdog reopens, and the reopen probes again.
    /// The explanation is worth having; it is not worth having at the price of
    /// causing the fault it explains. So it waits until there is something to
    /// explain.
    private func diagnoseExternalStream() {
        guard isExternal, noVideoDetail == nil,
              noVideoTrack || errorMessage != nil,
              let url = currentStreamURL
        else { return }
        diagnosis?.cancel()
        diagnosis = Task { [weak self] in
            let finding = await StreamDiagnosis.inspect(hlsURL: url)
            // Not cancelled by a channel change to another external stream —
            // only `diagnoseExternalStream` and `finish()` cancel this task —
            // so without checking the URL is still current, a slow diagnosis
            // of the channel just left behind lands on whatever is playing now.
            guard !Task.isCancelled, let self, let finding, self.isExternal, self.currentStreamURL == url else { return }
            self.noVideoDetail = finding.message
            // The stream has been read and it is not going to produce a
            // picture. Said outright rather than waiting for AVFoundation to
            // admit it, which in this case it never does: it reports the
            // resolution the playlist advertises and goes on playing the audio.
            if finding.videoWillNotPlay { self.noVideoTrack = true }
        }
    }

    // MARK: - Stalls, for adaptive quality

    /// A stall has been counted and the buffer hasn't recovered from it yet.
    /// One stall announces itself twice — `playbackStalled` and the buffer
    /// going empty — and counted twice it was a quality drop on its own.
    private var stallInProgress = false
    /// Times a stall that doesn't end. The periodic observer `sample` hangs
    /// off stops with the clock, so a stall that goes on is otherwise never
    /// looked at again.
    private var longStallCheck: Task<Void, Never>?

    /// Only ever reached from the observers on the installed item, which come
    /// down with it — so the item in the player is the one that stalled.
    private func noteStall() {
        guard !stallInProgress, let avItem = playerItem else { return }
        stallInProgress = true
        adaptive.noteStall()
        longStallCheck?.cancel()
        longStallCheck = Task { [weak self] in
            var stalledFor: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isActive, self.stallInProgress,
                      self.playerItem === avItem else { return }
                // The player's own intent, not the timebase, whose rate is zero
                // for a stall and a pause alike. Paused by the user, the wait
                // isn't the network's.
                switch self.player.timeControlStatus {
                case .playing:
                    // Moving again without the buffer saying so first.
                    self.endStall()
                    return
                case .paused:
                    continue
                default:
                    break
                }
                guard !self.isOpening else { continue }
                stalledFor += 1
                if self.adaptive.noteStillStalled(for: stalledFor) {
                    self.maybeAdapt()
                    return
                }
            }
        }
    }

    private func endStall() {
        stallInProgress = false
        longStallCheck?.cancel()
        longStallCheck = nil
    }

    private func teardownObservers() {
        endStall()
        pictureWatchdog?.cancel()
        pictureWatchdog = nil
        #if os(tvOS)
        heldPicture?.detach()
        heldPicture = nil
        #endif
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

    private func tick(_ time: CMTime) {
        guard isActive else { return }
        checkSleepDeadline()
        // A stream still opening at a position sits at the position it was
        // asked to start from, whatever the player's clock currently says.
        // Reading that clock here would show 0:00 on the scrubber and, worse,
        // report 0:00 to the server as this episode's resume point — and would
        // record the deliberate hold on the rate as the user having paused.
        guard !isOpening else { return }
        position = time.seconds.isFinite ? time.seconds : 0
        // A stream that has been playing for a minute and a half since it was
        // last reopened is a stream that is working, and whatever went wrong
        // before it should not be counted against whatever goes wrong next.
        if let at = lastRecoveryAt, !isBuffering,
           Date().timeIntervalSince(at) >= Self.streamRecoverySettled {
            streamRecoveries = 0
            lastRecoveryAt = nil
        }
        if let avItem = playerItem {
            let d = avItem.duration.seconds
            // A live HLS stream has no meaningful duration; the seekable range
            // is what the scrubber can honestly offer.
            // Assigned only when it changes, here and for `isPaused` below:
            // Observation tells every reader on every write, equal or not, and
            // these were written twice a second for the length of a film.
            var newDuration = duration
            if d.isFinite, d > 0 {
                newDuration = d
            } else if let range = avItem.seekableTimeRanges.last?.timeRangeValue {
                newDuration = isLive ? 0 : (range.start.seconds + range.duration.seconds)
            }
            if newDuration != duration { duration = newDuration }
            if let loaded = avItem.loadedTimeRanges.last?.timeRangeValue {
                buffered = loaded.start.seconds + loaded.duration.seconds
            }
            adaptive.sample(
                item: avItem, position: position, buffered: buffered,
                paused: player.timeControlStatus == .paused
            )
        }
        let nowPaused = player.timeControlStatus == .paused
        if nowPaused != isPaused { isPaused = nowPaused }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate, !isBuffering {
            isBuffering = true
        }
        refreshCues()
        // Only when the lock screen would otherwise be wrong. Now Playing is
        // given a position and a rate and runs the clock forward itself, so
        // re-posting the whole dictionary — a cross-process write, from the
        // main actor — once a second during steady playback told it nothing
        // it didn't know. What it can't know: a pause or a change of speed, a
        // seek or a stall that puts the picture somewhere other than where its
        // clock says, and a duration that moves, as a live window's does.
        let rate = isPaused ? 0 : speed
        let now = Date()
        let isStale: Bool = {
            guard let anchor = nowPlayingAnchor else { return true }
            if anchor.rate != rate { return true }
            let expected = anchor.position + anchor.rate * now.timeIntervalSince(anchor.at)
            if abs(expected - position) > 1.5 { return true }
            return abs(anchor.duration - duration) > 5
        }()
        if isStale {
            nowPlayingAnchor = (position, rate, now, duration)
            NowPlaying.shared.updateElapsed(position, rate: rate)
        }
        maybeReport()
        maybeAdapt()
        // The Up Next card appears over the closing stretch rather than at the
        // very end — by the time the file runs out the decision has already been
        // made for you.
        if upNext == nil, upNextLocalId == nil, !upNextChecked, duration > 0, duration - position < 90 {
            upNextChecked = true
            Task { await self.refreshUpNext() }
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            startPlaying()
            isPaused = false
        } else {
            player.pause()
            isPaused = true
        }
        postNowPlayingRate()
        Task { await reportNow() }
    }

    func pause() {
        player.pause()
        isPaused = true
        postNowPlayingRate()
        Task { await reportNow() }
    }

    func resume() {
        startPlaying()
        isPaused = false
        postNowPlayingRate()
        Task { await reportNow() }
    }

    /// Tell Now Playing about a pause or a resume straight away, rather than
    /// whenever the next tick happens to notice.
    private func postNowPlayingRate() {
        guard isActive else { return }
        let rate = isPaused ? 0 : speed
        nowPlayingAnchor = (position, rate, Date(), duration)
        NowPlaying.shared.updateElapsed(position, rate: rate)
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        adaptive.noteSeek()
        // Somewhere of the user's own choosing replaces the position the stream
        // was opening at, and ends the hold that was waiting on it.
        pendingSeek = nil
        releaseOpeningHold(at: nil)
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) {
        seek(to: position + delta)
    }

    func stop(reason: String = "stop") {
        Task { await finish(userRequested: true, reason: reason) }
    }

    // MARK: - The Menu button, and AVKit closing the player (tvOS)

    /// When a Menu press was last acted on, whichever door it came in by.
    @ObservationIgnored private var lastExitAt = Date.distantPast

    /// One Menu press.
    ///
    /// On tvOS the press has three ways in — SwiftUI's `onExitCommand`, the
    /// recogniser the player screen puts on AVKit's view, and AVKit itself
    /// asking to dismiss — and one press can arrive by more than one of them.
    /// Handled twice, a press meant to put the ribbon away would put it away
    /// and then close the player. So a press is acted on once and its echoes
    /// inside the next moment are dropped. `hideRibbon` says whether there was
    /// a ribbon to put away; if not, the player closes.
    func handleExit(hidingRibbon hideRibbon: () -> Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastExitAt) > 0.5 else { return }
        lastExitAt = now
        if hideRibbon() { return }
        #if os(tvOS)
        // With the transport bar up, the press is AVKit's: it puts the bar
        // away, and closing the player on what was meant as the first of two
        // presses is what SwiftUI's exit command used to do here (seen in the
        // log, not reasoned — see `PlayerScreen`). The doors that still lead
        // here stand down while the bar is up; this is the belt to those
        // braces. Not over the error card, where there is nothing behind the
        // bar worth keeping.
        if transportBarVisible, errorMessage == nil {
            Self.log.notice("Menu press left to AVKit: the transport bar is up")
            return
        }
        #endif
        stop(reason: "Menu")
    }

    #if os(tvOS)
    /// Whether AVKit's transport bar is on screen, as its delegate reports it
    /// to the player screen's coordinator. Read by `handleExit`.
    @ObservationIgnored var transportBarVisible = false
    #endif

    #if os(tvOS)
    /// Whether a dismissal AVKit is asking for should go ahead.
    ///
    /// On tvOS `AVPlayerViewController` closes itself: when its item plays to
    /// the end, when it is left with no item, when the item fails. Presented as
    /// a child inside the player cover, "closes itself" means the cover — UIKit
    /// forwards a dismissal up to the nearest ancestor that was presented — and
    /// the cover's binding then calls `stop`. Every one of those moments is one
    /// this model is already handling for a live channel: `handleReachedEnd`
    /// reopens a playlist that ended, `reopenStalledLive` pulls the dead item
    /// out before asking for its replacement, and a failure goes on the error
    /// card. AVKit acting on the same moment took the player down under all
    /// three, which from the sofa was a channel that loaded and then went back
    /// to the guide by itself. Consulted from `playerViewControllerShouldDismiss`.
    ///
    /// What is allowed is a dismissal in a steady state, which is the user
    /// pressing Menu — including while a stream is still being asked for, when
    /// nothing has been installed yet and there is nothing to protect.
    var systemMayDismiss: Bool {
        guard isActive else { return true }
        if errorMessage != nil || isReopeningLive { return false }
        guard let avItem = player.currentItem else {
            // Nothing installed yet is a stream on its way in; nothing
            // installed *any more* is a reopen in progress.
            return playerItem == nil
        }
        if avItem.status == .failed { return false }
        // Played to the end. A live playlist that gains an end marker acquires
        // a finite duration at the same moment, so one test covers both.
        let d = avItem.duration.seconds
        if d.isFinite, d > 0, avItem.currentTime().seconds >= d - 0.5 { return false }
        return true
    }
    #endif

    /// Tear the player down, reporting where it got to and releasing the
    /// server's transcode job.
    ///
    /// Order matters here, and it used to be the wrong way round. The two
    /// things this owes the server — where the stream got to, and the transcode
    /// job behind it — are network calls, and they were made *first*, with the
    /// player left running and `isActive` left true across both. Anything
    /// started during that window — closing a channel and picking another one
    /// out of the guide is a second and a half, and these calls can take longer
    /// than that on a busy server — was then torn down by a teardown that
    /// belonged to the stream before it: `isActive` cleared under a player that
    /// had just been told to start, the cover dismissed back to the guide, and
    /// the new stream left playing with nothing on screen.
    ///
    /// So the player comes down first, synchronously, before anything is
    /// awaited: by the time this function yields, `isActive` is already false
    /// and a start racing it has a clean board to set up on. What the server is
    /// owed is snapshotted beforehand and settled afterwards, out of everyone
    /// else's way.
    func finish(userRequested: Bool, reason: String = "ended") async {
        guard isActive else { return }
        Self.log.info(
            "finish: \(reason, privacy: .public) live=\(self.isLive) external=\(self.isExternal) position=\(self.position, format: .fixed(precision: 1)) error=\(self.errorMessage ?? "none", privacy: .public)")
        generation &+= 1

        // Everything the two closing calls need, read while it is still true.
        let finalPosition = position
        let closingReport = isExternal ? nil : report(paused: true, position: finalPosition)
        let closingSource = source
        #if !os(tvOS)
        let closingLocalId = localRecordId
        #endif

        player.pause()
        player.replaceCurrentItem(with: nil)
        // And let go of the item and its asset, rather than holding them
        // until the next stream overwrites them. A channel from a playlist
        // has no session to close on the far end — there is no "stop" an
        // HTTP stream can be sent — so the socket closing is the only signal
        // the provider gets that this client has gone, and the socket closes
        // when nothing here holds the item any more. A provider that counts
        // connections was seeing the last channel still counted until the
        // next one opened.
        sourceAsset?.cancelLoading()
        sourceAsset = nil
        playerItem?.cancelPendingSeeks()
        playerItem = nil
        externalResolve?.cancel()
        externalResolve = nil
        externalChannel = nil
        resetLiveRecovery()
        diagnosis?.cancel()
        diagnosis = nil
        currentStreamURL = nil
        teardownObservers()
        pendingSeek = nil
        isOpening = false
        seekWatchdog?.cancel()
        seekWatchdog = nil
        cancelSleepTimer()
        adaptive.reset()
        NowPlaying.shared.clear()
        #if !os(tvOS)
        PlaybackHandoff.shared.end()
        #endif

        isActive = false
        isBuffering = false
        item = nil
        source = nil
        localRecordId = nil
        upNext = nil
        upNextLocalId = nil
        upNextChecked = false
        upNextSettled = false
        chapters = []
        segments = []
        trickplay = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        pendingTrackChoice = nil
        transcodingForSubtitle = false
        episodeQueue = nil
        streamRecoveries = 0
        lastRecoveryAt = nil
        if userRequested { shuffleSeries = nil }
        position = 0
        duration = 0

        // The player is down and out of the way; what is left is owed to the
        // server and touches nothing here.
        #if !os(tvOS)
        if let closingLocalId {
            DownloadManager.shared.noteProgress(itemId: closingLocalId, positionSeconds: finalPosition)
            Task { await OfflineProgress.sync() }
        }
        #endif
        //
        // Three calls, made together rather than one after another. Each is
        // a request that can take a busy server its full twenty seconds, and
        // in a row the tuner was the last thing released — after the stopped
        // report and after the encode — which on a single-tuner setup is the
        // next channel waiting on this one for as long as the other two took.
        // The stopped report is what ends the session on the server's side
        // and marks where the stream got to; the encode is the ffmpeg job
        // behind a transcode; the live stream is the tuner, or whatever
        // connection sits behind a channel, and it is separate from the
        // encode and was the thing being leaked. See
        // `JellyfinClient.closeLiveStream`.
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
            // What was just watched is now further along, or finished — the
            // library copy hears it from the server rather than guessing.
            Task { await LibraryIndex.shared.sync(minimumGap: 5) }
        }
    }

    func stepSpeed(_ direction: Int) {
        let current = Self.speeds.firstIndex { abs($0 - speed) < 0.001 } ?? Self.speeds.firstIndex(of: 1)!
        let next = min(max(current + direction, 0), Self.speeds.count - 1)
        speed = Self.speeds[next]
    }

    // MARK: - Progress reporting

    /// Ten seconds, the same cadence every first-class Jellyfin client uses.
    private static let reportInterval: TimeInterval = 10

    private func maybeReport() {
        #if !os(tvOS)
        if isActive { PlaybackHandoff.shared.update(position: position) }
        #endif
        guard isActive, !isLocal, !isExternal,
              Date().timeIntervalSince(lastReportAt) >= Self.reportInterval else { return }
        lastReportAt = Date()
        Task { await client.reportPlaybackProgress(report(paused: isPaused)) }
    }

    private func reportNow() async {
        guard isActive, !isExternal else { return }
        #if !os(tvOS)
        if let localRecordId {
            DownloadManager.shared.noteProgress(itemId: localRecordId, positionSeconds: position)
            return
        }
        #endif
        lastReportAt = Date()
        await client.reportPlaybackProgress(report(paused: isPaused))
    }

    private func report(paused: Bool, position override: Double? = nil) -> PlaybackReport {
        PlaybackReport(
            itemId: item?.Id ?? localRecordId ?? "",
            mediaSourceId: source?.mediaSourceId,
            playSessionId: source?.playSessionId,
            positionSeconds: override ?? position,
            isPaused: paused,
            isTranscode: isTranscoding,
            rate: speed,
            volume: isMuted ? 0 : volume
        )
    }

    // MARK: - Per-item extras

    private func loadExtras(for item: BaseItem) async {
        chapters = []
        segments = []
        trickplay = nil
        fullItem = nil
        // All four are per-file and are thrown away when the item changes, so
        // a slow one arriving late must not land on the next episode.
        let itemId = item.Id
        // Something started from its own page already came through the detail
        // endpoint and needs nothing; something started from a shelf on Home
        // arrives with a name, an id and little else.
        let needsDetail = item.Overview?.isEmpty != false
            || item.People?.isEmpty != false
            || item.MediaSources?.isEmpty != false
        async let segmentsTask = client.mediaSegments(itemId: itemId)
        async let detailTask = needsDetail ? try? client.item(itemId) : nil
        let loadedSegments = (try? await segmentsTask) ?? []
        let loadedDetail = await detailTask ?? nil
        guard self.item?.Id == itemId else { return }
        segments = loadedSegments
        // The detail endpoint asks for trickplay, so whichever copy came
        // through it — the one handed in, or the one just fetched — already
        // says whether there are thumbnails. It used to be a third request for
        // the whole item again, with `Fields=Trickplay`.
        trickplay = JellyfinClient.trickplayInfo(for: loadedDetail ?? item)
        fullItem = loadedDetail
        await refreshUpNext()
    }

    /// The intro or credits sequence `position` is inside, if any.
    ///
    /// Stored, and set only when it changes. As a computed property it was
    /// worked out from `position`, so everything that read it — the player's
    /// overlay, the tvOS contextual actions — was redrawn twice a second for
    /// the whole film to find out that nothing had started or ended.
    private(set) var activeSegment: MediaSegment?

    /// Whether the Up Next card should be on screen. Stored for the same
    /// reason as `activeSegment`.
    private(set) var shouldShowUpNext = false

    /// Brings the two cues up to date: from `tick`, and whenever something
    /// they are worked out from changes.
    private func refreshCues() {
        let segment = currentSegment()
        if segment != activeSegment { activeSegment = segment }
        let upNextDue = upNextIsDue()
        if upNextDue != shouldShowUpNext { shouldShowUpNext = upNextDue }
    }

    private func currentSegment() -> MediaSegment? {
        guard duration > 0 else { return nil }
        return segments.first {
            guard position >= $0.start, position < $0.end - 1 else { return false }
            // An intro is only skippable if there is something after it to skip
            // *to*. Closing credits are the opposite case and used to be caught
            // by the same rule: an outro almost always runs to the last frame
            // of the file, so `end < duration - 1` was false for every one of
            // them and "Skip credits" never appeared, however well the server
            // had analysed the episode. Skipping an outro that ends where the
            // file does means finishing it — see `skipSegment`.
            return $0.isOutro || $0.end < duration - Self.segmentTailSlack
        }
    }

    /// How close to the end of a file counts as *at* the end. A segment
    /// analyser rarely puts the last credit frame on the exact final sample,
    /// and a "skip" that lands a second and a half from the end is a skip that
    /// looks like it did nothing.
    private static let segmentTailSlack: Double = 1.5

    func skipSegment() {
        guard let segment = activeSegment else { return }
        guard segment.end < duration - Self.segmentTailSlack else {
            // Nothing after the credits to seek to, so skipping them means what
            // reaching the end means: the next episode where there is one, the
            // end of the player where there isn't.
            handleReachedEnd()
            return
        }
        seek(to: segment.end)
    }

    // MARK: - Tracks

    private func readTracks() async {
        guard let avItem = playerItem else { return }
        // The original rather than the item's own asset: with an audio offset in
        // force the item is a composition, and a composition lists no
        // selectable tracks at all.
        let asset = sourceAsset ?? avItem.asset

        var audio: [PlayerTrack] = []
        var subs: [PlayerTrack] = []

        // Every await below is a moment the item can be replaced in — a
        // quality change, the next episode — and what was read about this one
        // must not land on that.
        let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard playerItem === avItem else { return }
        if let group = audibleGroup {
            for (i, option) in group.options.enumerated() {
                audio.append(PlayerTrack(
                    id: i,
                    label: option.displayName,
                    language: option.extendedLanguageTag ?? option.locale?.identifier,
                    isForced: false
                ))
            }
            // Only while the item and the group come from the same asset. With
            // an offset in force they do not — the item answers nil for every
            // option — and reading that back would discard the very choice the
            // composition was built around.
            if !audioDelayIsApplied,
               let selected = avItem.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                selectedAudioTrack = index
            }
        }

        if let group = legibleGroup {
            for (i, option) in group.options.enumerated() {
                subs.append(PlayerTrack(
                    id: i,
                    label: option.displayName,
                    language: option.extendedLanguageTag ?? option.locale?.identifier,
                    isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                        || option.displayName.localizedCaseInsensitiveContains("forced")
                ))
            }
            if !audioDelayIsApplied {
                if let selected = avItem.currentMediaSelection.selectedMediaOption(in: group),
                   let index = group.options.firstIndex(of: selected) {
                    selectedSubtitleTrack = index
                } else {
                    selectedSubtitleTrack = nil
                }
            }
        }

        audioTracks = audio
        subtitleTracks = subs

        // Whether there is a picture is settled by `watchForPicture`, not
        // here: `loadTracks` answers for a file and says nothing at all about
        // an HLS stream, which is the one shape this question actually gets
        // asked about — see there.

        let loadedChapters = await loadChapters(from: asset)
        guard playerItem === avItem else { return }
        chapters = loadedChapters

        if !tracksApplied {
            tracksApplied = true
            applyPreferredTracks()
        }
    }

    private func loadChapters(from asset: AVAsset) async -> [Chapter] {
        guard let locales = try? await asset.load(.availableChapterLocales), let locale = locales.first,
              let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale)
        else { return [] }
        var out: [Chapter] = []
        for (i, group) in groups.enumerated() {
            let start = group.timeRange.start.seconds
            let title = (try? await group.items
                .first(where: { $0.commonKey == .commonKeyTitle })?
                .load(.stringValue)) ?? nil
            out.append(Chapter(id: i, start: start, title: title ?? "Chapter \(i + 1)"))
        }
        return out
    }

    /// The chapter containing `seconds`, for the scrubber's readout.
    func chapterName(at seconds: Double) -> String? {
        var found: String?
        for c in chapters {
            if c.start > seconds { break }
            found = c.title
        }
        return found
    }

    func selectAudioTrack(_ index: Int) {
        guard let avItem = playerItem else { return }
        guard !audioDelayIsApplied else {
            // Nothing to select *within*: the composition carries one audio
            // track and choosing another means building it again around that one.
            guard audioTracks.indices.contains(index) else { return }
            selectedAudioTrack = index
            rememberTrackChoice()
            guard composedTracks.audio != index else { return }
            rebuildForAudioDelay()
            return
        }
        Task {
            guard let group = try? await avItem.asset.loadMediaSelectionGroup(for: .audible),
                  group.options.indices.contains(index) else { return }
            avItem.select(group.options[index], in: group)
            selectedAudioTrack = index
            rememberTrackChoice()
        }
    }

    /// `nil` turns subtitles off.
    func selectSubtitleTrack(_ index: Int?) {
        guard let avItem = playerItem else { return }
        guard !audioDelayIsApplied else {
            // The same, for the one legible track the composition carries.
            if let index, !subtitleTracks.indices.contains(index) { return }
            selectedSubtitleTrack = index
            rememberTrackChoice()
            guard composedTracks.subtitle != index else { return }
            rebuildForAudioDelay()
            return
        }
        Task {
            guard let group = try? await avItem.asset.loadMediaSelectionGroup(for: .legible) else { return }
            if let index, group.options.indices.contains(index) {
                avItem.select(group.options[index], in: group)
            } else {
                avItem.select(nil, in: group)
            }
            selectedSubtitleTrack = index
            rememberTrackChoice()
        }
    }

    /// The tracks Settings would pick from the file's own list, as the server
    /// numbers them — what to ask for, so the stream arrives carrying them.
    ///
    /// `applyPreferredTracks` makes the same choice once the stream is open,
    /// from what AVFoundation can see; and on a transcode that is one audio
    /// track and no subtitles, whichever the file has, so a preference applied
    /// only there was never applied to a transcode at all — the film opened in
    /// whatever language the file leads with, every time. Asked for up front,
    /// the track is in the stream when it opens.
    ///
    /// Only where it would make a difference. A track that is the file's own
    /// default is left unnamed: the server sends it anyway, the stream is the
    /// one it would have been, and a direct play stays a direct play. Naming
    /// a subtitle is what turns a direct play into a stream the server builds
    /// (see `DeviceProfile.requestedSubtitleProfiles`), which is the price of
    /// the words being there when the picture is — the same price choosing
    /// the track from the menu pays.
    ///
    /// What was chosen for this series last time wins over Settings, as it
    /// does below. `nil` leaves a choice to the server; `-1` for the subtitle
    /// is Jellyfin's spelling of none.
    private func preferredStreams(in source: MediaSource, seriesId: String?) -> (audio: Int?, subtitle: Int?) {
        let audioStreams = source.audioStreams
        let subtitleStreams = source.subtitleStreams
        let saved = seriesId.flatMap { prefs.trackChoice(seriesId: $0) }

        // The track the server sends when nothing is asked for.
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

        // The same rule as `applyPreferredTracks`: with the sound already in
        // the preferred language, "forced only" means the track that
        // translates signs and the odd foreign line, or nothing.
        let audioMatches = Languages.matches(
            preference: prefs.audioLanguage, tag: (audio ?? defaultAudio)?.Language
        )
        var subtitle: Int?
        for (want, fromSettings) in [(saved?.sub, false), (prefs.subtitleLanguage, true)] {
            guard let want, !want.isEmpty else { continue }
            if want == "off" {
                // Only worth saying when the file has something to turn on.
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
            // A saved language the file doesn't have falls through to
            // Settings, as it does once the stream is open.
        }
        if let subtitle, subtitle >= 0, subtitle == source.DefaultSubtitleStreamIndex {
            // Already what the server would send.
            return (audioIndex, nil)
        }
        return (audioIndex, subtitle)
    }

    /// The first track list of a file is AVFoundation's own choice, and it is
    /// the only one worth overriding rather than recording. What was chosen for
    /// this series last time wins; failing that, the language defaults do.
    private func applyPreferredTracks() {
        // A choice made a moment ago, for this very stream, outranks every
        // default below it. See `pendingTrackChoice`.
        if applyChosenTracks() { return }

        if let seriesId = item?.SeriesId, let saved = prefs.trackChoice(seriesId: seriesId) {
            if let wantAudio = saved.audio,
               let match = audioTracks.firstIndex(where: { Languages.matches(preference: wantAudio, tag: $0.language) }) {
                selectAudioTrack(match)
            }
            if saved.sub == "off" {
                selectSubtitleTrack(nil)
                return
            } else if let wantSub = saved.sub,
                      let match = subtitleTracks.firstIndex(where: { Languages.matches(preference: wantSub, tag: $0.language) }) {
                selectSubtitleTrack(match)
                return
            }
        }

        if !prefs.audioLanguage.isEmpty,
           let match = audioTracks.firstIndex(where: { Languages.matches(preference: prefs.audioLanguage, tag: $0.language) }) {
            selectAudioTrack(match)
        }

        switch prefs.subtitleLanguage {
        case "":
            // Only when the file turns them on — leave AVFoundation's pick.
            break
        case "off":
            selectSubtitleTrack(nil)
        case let wanted:
            // When the audio is already in the preferred language, "forced only"
            // means show just the track that translates signs and the odd line
            // of foreign dialogue rather than subtitling the whole thing.
            let audioMatches = selectedAudioTrack
                .flatMap { audioTracks.indices.contains($0) ? audioTracks[$0] : nil }
                .map { Languages.matches(preference: prefs.audioLanguage, tag: $0.language) } ?? false
            let candidates = subtitleTracks.enumerated().filter {
                Languages.matches(preference: wanted, tag: $0.element.language)
            }
            if prefs.forcedSubtitlesOnly, audioMatches {
                if let forced = candidates.first(where: { $0.element.isForced }) {
                    selectSubtitleTrack(forced.offset)
                } else {
                    selectSubtitleTrack(nil)
                }
            } else if let first = candidates.first(where: { !$0.element.isForced }) ?? candidates.first {
                selectSubtitleTrack(first.offset)
            }
        }
    }

    /// Record what is selected now, which is how a change made from AVPlayer's
    /// own track menu is captured — those never come through this class.
    private func rememberTrackChoice() {
        guard let seriesId = item?.SeriesId else { return }
        let audio = selectedAudioTrack.flatMap { audioTracks.indices.contains($0) ? audioTracks[$0].language : nil }
        let sub: String? = {
            guard let index = selectedSubtitleTrack, subtitleTracks.indices.contains(index) else { return "off" }
            return subtitleTracks[index].language ?? "und"
        }()
        prefs.setTrackChoice(.init(audio: audio, sub: sub), seriesId: seriesId)
    }

    // MARK: - The track menus

    /// What the server said this file contains, when there is a server and the
    /// file is its. A download plays from disk and an IPTV channel is nobody's
    /// library, so both fall back to the stream's own list.
    private var serverStreams: MediaSource? {
        guard !isLocal, !isExternal else { return nil }
        return source?.mediaSource
    }

    /// Every audio track the file has, not merely the one that arrived.
    var audioOptions: [TrackOption] {
        guard let streams = serverStreams?.audioStreams, !streams.isEmpty else {
            return audioTracks.map {
                TrackOption(
                    serverIndex: nil, avIndex: $0.id, label: $0.label,
                    language: $0.language, isForced: false
                )
            }
        }
        return streams.enumerated().map { position, stream in
            TrackOption(
                serverIndex: stream.Index,
                avIndex: Self.streamIndex(
                    matching: stream, at: position, among: audioTracks, of: streams.count
                ),
                label: stream.menuLabel,
                language: stream.Language,
                isForced: false
            )
        }
    }

    /// Every subtitle track the file has. Off is not in here — a menu offers it
    /// as an entry of its own, and `nil` is what stands for it in this class.
    var subtitleOptions: [TrackOption] {
        guard let streams = serverStreams?.subtitleStreams, !streams.isEmpty else {
            return subtitleTracks.map {
                TrackOption(
                    serverIndex: nil, avIndex: $0.id, label: $0.label,
                    language: $0.language, isForced: $0.isForced
                )
            }
        }
        return streams.enumerated().map { position, stream in
            // A picture-based subtitle is never in an `AVMediaSelectionGroup`,
            // whatever the lists look like: there is no text in it to select.
            // The server paints it into the video or it isn't shown at all.
            let av = stream.isImageSubtitle ? nil : Self.streamIndex(
                matching: stream, at: position, among: subtitleTracks, of: streams.count
            )
            return TrackOption(
                serverIndex: stream.Index, avIndex: av, label: stream.menuLabel,
                language: stream.Language, isForced: stream.isForced
            )
        }
    }

    /// Find the server's track in the stream's own list, so the menu knows
    /// whether choosing it is free.
    ///
    /// Three ways, in the order they are trustworthy. The name is the strongest:
    /// Jellyfin writes each track's `DisplayTitle` into the HLS manifest as the
    /// rendition name, so on a transcode the two lists are describing themselves
    /// with the same string. Failing that, two lists of the same length are the
    /// same list — which is the direct-play case, where what AVFoundation can
    /// see *is* the file. Only then the language, which is the loosest: it
    /// cannot tell two English tracks apart, and picking the first is a better
    /// answer than reopening the stream to fetch a track already in it.
    private static func streamIndex(
        matching stream: MediaStream, at position: Int, among tracks: [PlayerTrack], of total: Int
    ) -> Int? {
        if let title = stream.DisplayTitle, !title.isEmpty,
           let match = tracks.firstIndex(where: { $0.label.caseInsensitiveCompare(title) == .orderedSame }) {
            return match
        }
        // An external track is a separate file on the server and is in no
        // container this app was handed, so a same-length coincidence must not
        // be read as a line-up.
        if tracks.count == total, !(stream.IsExternal ?? false) { return position }
        guard let language = stream.Language, !language.isEmpty else { return nil }
        return tracks.firstIndex {
            Languages.matches(preference: language, tag: $0.language)
                && $0.isForced == stream.isForced
        }
    }

    /// The audio entry to tick.
    var selectedAudioOption: TrackOption.ID? {
        let choices = audioOptions
        if let av = selectedAudioTrack, let match = choices.first(where: { $0.avIndex == av }) {
            return match.id
        }
        // Nothing matched in the stream, which on a transcode is the ordinary
        // case — one track arrived and it answers to no name the server used.
        // What was asked for, or failing that what the server sends when
        // nothing is asked for, is then the only thing that knows.
        let asked = options.audioStreamIndex ?? serverStreams?.DefaultAudioStreamIndex
        if let asked, let match = choices.first(where: { $0.serverIndex == asked }) { return match.id }
        return choices.first?.id
    }

    /// The subtitle entry to tick, or `nil` for off.
    var selectedSubtitleOption: TrackOption.ID? {
        let choices = subtitleOptions
        if let av = selectedSubtitleTrack, let match = choices.first(where: { $0.avIndex == av }) {
            return match.id
        }
        if let burned = burnedInSubtitle,
           let match = choices.first(where: { $0.serverIndex == burned }) {
            return match.id
        }
        return nil
    }

    /// The subtitle the server painted into the picture, if it did.
    ///
    /// Nothing in the stream says so — a burnt-in subtitle is video. What says
    /// so is that one was asked for and no selectable track came back for it.
    private var burnedInSubtitle: Int? {
        guard let asked = options.subtitleStreamIndex, asked >= 0 else { return nil }
        guard !subtitleOptions.contains(where: { $0.serverIndex == asked && $0.avIndex != nil })
        else { return nil }
        return asked
    }

    func selectAudio(_ option: TrackOption) {
        // Already playing. Worth saying before anything else: a track this app
        // cannot find in the stream is not necessarily one that isn't in it —
        // a file whose tracks carry no language tag matches nothing — and
        // reopening a stream to fetch the track it is already playing is a
        // gap in the picture in exchange for nothing at all.
        guard option.id != selectedAudioOption else { return }
        if let av = option.avIndex {
            selectAudioTrack(av)
            return
        }
        guard let index = option.serverIndex else { return }
        Task { await reopen(audio: index, subtitle: subtitleRequest) }
    }

    /// `nil` turns subtitles off.
    func selectSubtitles(_ option: TrackOption?) {
        guard option?.id != selectedSubtitleOption else { return }
        guard let option else {
            // Off is free unless the sound and the words are the same pixels,
            // in which case the only way to take them off the picture is to ask
            // the server for a picture without them.
            if burnedInSubtitle != nil {
                Task { await reopen(audio: audioRequest, subtitle: -1) }
            } else {
                selectSubtitleTrack(nil)
            }
            return
        }
        if let av = option.avIndex {
            selectSubtitleTrack(av)
            return
        }
        guard let index = option.serverIndex else { return }
        Task { await reopen(audio: audioRequest, subtitle: index, forSubtitleTheServerMustRender: true) }
    }

    /// What the server would have to be told to keep the audio where it is.
    private var audioRequest: Int? {
        if let av = selectedAudioTrack, let match = audioOptions.first(where: { $0.avIndex == av }) {
            return match.serverIndex
        }
        return options.audioStreamIndex
    }

    /// The same for the subtitles, including `-1` for off — which has to be
    /// said out loud rather than left blank once anything has been chosen, or
    /// the server puts the file's default back on the next stream.
    private var subtitleRequest: Int? {
        if let av = selectedSubtitleTrack,
           let match = subtitleOptions.first(where: { $0.avIndex == av }) {
            return match.serverIndex
        }
        if let burned = burnedInSubtitle { return burned }
        return options.subtitleStreamIndex == nil ? nil : -1
    }

    /// Set when a subtitle forced this stream to be one the server builds, so
    /// turning that subtitle off can hand the direct play back.
    private var transcodingForSubtitle = false

    /// Ask for this stream again, carrying different tracks.
    ///
    /// The position is kept and the rest of `StreamOptions` with it, so the
    /// rung, the re-encode and everything else about the stream survive a track
    /// change. Quiet and inherited: the stream changing underneath is not news,
    /// it is what was just asked for.
    private func reopen(
        audio: Int?, subtitle: Int?, forSubtitleTheServerMustRender: Bool = false
    ) async {
        guard let item, isActive, !isLocal, !isExternal else { return }
        var opts = options
        opts.audioStreamIndex = audio
        opts.subtitleStreamIndex = subtitle

        // A subtitle that isn't in the stream is one the server has to convert
        // or paint on, and neither happens to a file it hands over untouched.
        // Emptying the direct-play profiles is what makes sure the answer comes
        // back as HLS — the bitstreams are still copied where they can be, so
        // this is the container being rewritten rather than the film re-encoded.
        if forSubtitleTheServerMustRender, !opts.forceTranscode {
            opts.forceTranscode = true
            transcodingForSubtitle = true
        } else if transcodingForSubtitle, let subtitle, subtitle < 0 {
            // And the way back: the subtitle that needed it has been turned off.
            opts.forceTranscode = false
            transcodingForSubtitle = false
        }

        opts.startSeconds = isLive ? nil : position
        pendingTrackChoice = (audio: audio, subtitle: subtitle)
        await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true))
    }

    /// What was chosen, waiting for the stream it was chosen for to open.
    ///
    /// Without this the choice is made twice and lost: `applyPreferredTracks`
    /// runs on every new stream and picks by saved language and settings, so a
    /// viewer who turned on the Dutch subtitles of an English film would watch
    /// the new stream arrive with them and then turn itself off again, because
    /// Settings says subtitles are off. An explicit choice outranks a default.
    private var pendingTrackChoice: (audio: Int?, subtitle: Int?)?

    /// Put the just-chosen tracks back on the stream that was opened for them.
    /// Returns whether it had anything to say.
    private func applyChosenTracks() -> Bool {
        guard let wanted = pendingTrackChoice else { return false }
        pendingTrackChoice = nil
        guard wanted.audio != nil || wanted.subtitle != nil else { return false }
        if let audio = wanted.audio,
           let match = audioOptions.first(where: { $0.serverIndex == audio }),
           let av = match.avIndex {
            selectAudioTrack(av)
        }
        guard let subtitle = wanted.subtitle else { return true }
        if subtitle < 0 {
            selectSubtitleTrack(nil)
        } else if let match = subtitleOptions.first(where: { $0.serverIndex == subtitle }),
                  let av = match.avIndex {
            selectSubtitleTrack(av)
        }
        // Anything else is a subtitle that came back burnt into the picture,
        // which is on screen already and is not a track to select.
        return true
    }

    // MARK: - Subtitle appearance

    /// AVPlayer honours `AVTextStyleRule` on WebVTT tracks, which is what every
    /// HLS stream from Jellyfin carries — so size and background survive the
    /// port even though nothing like mpv's subtitle renderer exists here.
    private func applySubtitleStyling(to avItem: AVPlayerItem) {
        let scale = max(0.5, min(2.0, prefs.subtitleSize / 100))
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: scale * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0, 1.0, 1.0, 1.0],
        ]
        switch prefs.subtitleBackground {
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

    /// Re-apply styling to what's playing now, so a slider dragged in Settings
    /// can be judged against the picture in front of you.
    func refreshSubtitleStyling() {
        guard let playerItem else { return }
        applySubtitleStyling(to: playerItem)
    }

    // MARK: - Quality

    /// Restart the current stream at a new bitrate, keeping the position.
    func switchQuality(to bitrate: Int?, meta: StartMeta = .init()) async {
        guard let item, !isLocal else { return }
        var opts = options
        opts.maxBitrate = bitrate
        // Every switch names a rung, direct play included — nothing here is a
        // stream with no opinion about its quality.
        opts.bitrateIsChosen = true
        // Cleared rather than carried: choosing "Direct Play (original)" has to
        // mean it. If the file genuinely can't be direct-played, the escalation
        // in `resolvePlayback` will say so again on this very call — so the
        // right answer is still reached, without this pinning a transcode on
        // for the rest of the session because one was needed earlier.
        opts.forceTranscode = false
        // And the same for a re-encode that was forced to fix sync. Picking a
        // rung is a fresh decision about this stream rather than a modifier on
        // the last one, and a full encode that quietly survived it would leave
        // "Direct Play (original)" transcoding with nothing on screen saying
        // why. It is one menu entry to ask for again if the new stream needs it.
        opts.forceFullEncode = false
        opts.startSeconds = isLive ? nil : position
        await play(item: item, options: opts, meta: meta)
    }

    private func maybeAdapt() {
        // `!isExternal` rather than `!isLive`. An IPTV channel has one stream
        // and no rung to move to, so the policy has nothing to offer it. A
        // Jellyfin live channel is not in that position at all — the server
        // will happily encode it smaller — and excluding it meant a struggling
        // connection had exactly one outcome available to it: stall, stall
        // again, and get torn down by the watchdog. A quality drop is the relief
        // valve that was missing.
        guard prefs.adaptiveQuality, !isLocal, !isExternal, isActive else { return }
        guard let decision = adaptive.decide(currentBitrate: currentBitrate) else { return }
        guard decision.bitrate != currentBitrate else {
            // Nothing is moving — the floor has been reached and this is the
            // explanation. Said on a phone or a Mac, where a toast is a line at
            // the bottom of a window you are holding; not across a film on a
            // television.
            #if !os(tvOS)
            AppModel.shared.toast(decision.message, tone: .error)
            #endif
            return
        }
        // A move, which is announced everywhere, tvOS included: a corner badge
        // that goes by itself, rather than the toast, which on a television is a
        // banner across the picture.
        showBitrateNotice(BitrateNotice(
            isUp: !decision.isDrop,
            headline: decision.bitrate == nil ? "Original quality" : Quality.label(for: decision.bitrate),
            detail: decision.reason
        ))
        Task {
            await switchQuality(to: decision.bitrate, meta: StartMeta(inherited: true, quiet: true))
        }
    }

    /// AVPlayer moving to another variant of the playlist it is reading. Most
    /// Jellyfin transcodes offer one variant and never get here; live TV,
    /// IPTV and a direct-streamed HLS source can offer several, and AVPlayer
    /// moves between them as the connection changes without asking anyone.
    /// Small wobbles are ignored — a step has to be at least 15% either way
    /// to be one somebody could see.
    private func noteVariantChange(_ avItem: AVPlayerItem?) {
        guard let rate = avItem?.accessLog()?.events.last?.indicatedBitrate, rate > 0 else { return }
        defer { lastVariantBitrate = rate }
        guard !isLocal, let previous = lastVariantBitrate, Date() >= variantChangesCountFrom else { return }
        let ratio = rate / previous
        guard ratio >= 1.15 || ratio <= 1 / 1.15 else { return }
        let up = rate > previous
        showBitrateNotice(BitrateNotice(
            isUp: up,
            headline: String(format: "%.1f Mbps", rate / 1_000_000),
            detail: up ? "Network improved" : "Network slowed"
        ))
    }

    private func showBitrateNotice(_ notice: BitrateNotice) {
        Self.log.notice("bitrate \(notice.isUp ? "up" : "down", privacy: .public): \(notice.headline, privacy: .public) (\(notice.detail, privacy: .public))")
        bitrateNotice = notice
        bitrateNoticeDismissal?.cancel()
        bitrateNoticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.bitrateNotice?.id == notice.id else { return }
            self?.bitrateNotice = nil
        }
    }

    // MARK: - Sleep timer
    //
    // A deadline, not only a countdown. The task below is the ordinary way the
    // timer goes off, but the deadline is also checked from every playback
    // tick and whenever the app comes back to the foreground, so a wake-up
    // that arrives late — the process suspended with the phone, and the timer
    // with it — still ends playback the moment it can rather than never.
    // Going off means leaving the player: `finish` takes the cover down
    // everywhere, the same as pressing Close. Autoplay is cancelled first,
    // because a plain stop ends the file, and a natural end is exactly what
    // starts the next episode. Everything it does is in the `player` log.

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let seconds = Double(max(1, minutes)) * 60
        let deadline = Date().addingTimeInterval(seconds)
        sleepDeadline = deadline
        Self.log.notice("sleep timer set: \(minutes) min")
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.sleepTimerElapsed(deadline)
        }
    }

    func cancelSleepTimer() {
        if sleepDeadline != nil { Self.log.notice("sleep timer cancelled") }
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
    }

    /// Whole minutes left on the timer, for the menus that show it.
    var sleepMinutesRemaining: Int? {
        guard let sleepDeadline else { return nil }
        return max(1, Int((sleepDeadline.timeIntervalSinceNow / 60).rounded(.up)))
    }

    /// The deadline, if it has passed. Called from `tick` and from the
    /// foreground transition; a no-op while the timer is still running.
    private func checkSleepDeadline() {
        guard let sleepDeadline, Date() >= sleepDeadline else { return }
        Task { await sleepTimerElapsed(sleepDeadline) }
    }

    /// Acted on once, and only for the timer that was set: a task waking late
    /// for a timer that has since been cancelled or replaced does nothing.
    private func sleepTimerElapsed(_ deadline: Date) async {
        guard sleepDeadline == deadline else { return }
        sleepDeadline = nil
        // Dropped rather than cancelled. `finish` calls `cancelSleepTimer`,
        // and when this runs inside the timer's own task, cancelling that task
        // would cancel the requests `finish` then awaits — the position report
        // and the transcode's close — so the server was never told the stream
        // had stopped.
        sleepTask = nil
        cancelAutoplay()
        Self.log.notice("sleep timer elapsed; closing the player")
        await finish(userRequested: true, reason: "sleep timer")
    }

    // MARK: - Up Next, autoplay and shuffle

    func cancelAutoplay() {
        autoplayCancelled = true
    }

    func resumeAutoplay() {
        autoplayCancelled = false
    }

    private func refreshUpNext() async {
        guard let item, item.isEpisode, let seriesId = item.SeriesId else { return }
        let found = await lookUpNextEpisode(after: item, seriesId: seriesId)
        guard self.item?.Id == item.Id else { return }
        // A lookup that got its answers is settled either way. "There is no
        // next episode" used to be indistinguishable from "the request
        // failed", so the last episode of a series was asked about three
        // times: at the start, ninety seconds from the end, and at the end —
        // up to three requests each. A failure still leaves the later checks
        // to try again.
        if found.settled {
            upNextChecked = true
            upNextSettled = true
        }
        if let next = found.next { upNext = next }
    }

    /// Next in season, else the first of the next season.
    private func findNextEpisode(after item: BaseItem, seriesId: String) async -> BaseItem? {
        await lookUpNextEpisode(after: item, seriesId: seriesId).next
    }

    /// The next episode, and whether every request needed to decide it was
    /// answered — nil with `settled` is a series that has ended.
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

    #if !os(tvOS)
    private func refreshLocalUpNext(after record: DownloadRecord) async {
        guard record.isEpisode else { return }
        let siblings = DownloadManager.shared.episodes(ofSeries: record.seriesId, seriesName: record.series)
        guard let i = siblings.firstIndex(where: { $0.itemId == record.itemId }), i + 1 < siblings.count else {
            upNextLocalId = nil
            return
        }
        upNextLocalId = siblings[i + 1].itemId
    }

    /// Shuffle whatever of a series is downloaded. Works on however much of the
    /// show is there — there is no completeness requirement.
    func startShuffle(_ records: [DownloadRecord]) {
        let pool = records.filter { $0.status == .complete }
        guard let first = pool.randomElement() else {
            // Same reason as `playLocal`: nothing opens, so nothing would show
            // a player error.
            AppModel.shared.toast("Nothing to shuffle — no playable downloads", tone: .error)
            return
        }
        shuffleSeries = DownloadShuffleState(
            seriesId: first.seriesId, seriesName: first.series, seen: [first.itemId]
        )
        playLocal(first, keepShuffle: true)
    }

    var isShuffling: Bool { shuffleSeries != nil }

    /// Draw the next episode of the shuffled series, or nil when it's spent.
    private func nextShuffled(after current: String) -> DownloadRecord? {
        guard var state = shuffleSeries else { return nil }
        // Re-read every time so episodes downloaded (or deleted) mid-binge join
        // or leave the shuffle.
        let pool = DownloadManager.shared.episodes(ofSeries: state.seriesId, seriesName: state.seriesName)
        guard !pool.isEmpty else { return nil }
        var choices = pool.filter { !state.seen.contains($0.itemId) }
        if choices.isEmpty {
            // Whole series has played — reshuffle, just never straight back into
            // the episode that only just ended.
            state.seen.removeAll()
            choices = pool.filter { $0.itemId != current }
            if choices.isEmpty { return nil }
        }
        guard let next = choices.randomElement() else { return nil }
        state.seen.insert(next.itemId)
        shuffleSeries = state
        return next
    }
    #endif

    /// Start the next episode now rather than waiting for this one to run out.
    func playNextNow() async {
        guard !isStartingNext else { return }
        isStartingNext = true
        defer { isStartingNext = false }
        _ = await advanceToNext()
    }

    private func handleReachedEnd() {
        // A live stream has no end to reach. Getting this notification for one
        // means the playlist stopped — the session behind it was closed, or the
        // server wrote an end marker and walked away — which is the same fault
        // the stall watchdog handles and wants the same answer: open it again.
        // Left to fall through, it closes the player and drops you back in the
        // guide as though the channel had finished.
        if isLive, isActive {
            Self.log.notice("live stream reported its end; reopening")
            Task { await self.reopenStalledLive() }
            return
        }
        position = duration
        Task {
            // Only a natural end counts, and only for an episode.
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

    /// Returns true when something next was found and started.
    private func advanceToNext() async -> Bool {
        #if !os(tvOS)
        if isLocal, let current = localRecordId {
            if isShuffling, let next = nextShuffled(after: current) {
                await reportLocalFinished(current)
                playLocal(next, keepShuffle: true)
                return true
            }
            if let nextId = upNextLocalId, let record = DownloadManager.shared.record(for: nextId) {
                await reportLocalFinished(current)
                playLocal(record, keepShuffle: true)
                return true
            }
            return false
        }
        #endif
        var candidate = upNext
        // Not asked again when an earlier lookup already settled that this is
        // the last one.
        if candidate == nil, !upNextSettled, let item, item.isEpisode, let seriesId = item.SeriesId {
            // Reaching the end before the lookahead ran — ask now rather than
            // stopping on an episode that does have a successor.
            candidate = await findNextEpisode(after: item, seriesId: seriesId)
        }
        guard let next = candidate else { return false }
        var opts = options
        opts.startSeconds = nil
        opts.resume = true
        await play(
            item: next, options: opts,
            meta: StartMeta(
                inherited: true, quiet: true,
                carriesSubtitleTranscode: transcodingForSubtitle && opts.forceTranscode
            )
        )
        return true
    }

    #if !os(tvOS)
    private func reportLocalFinished(_ itemId: String) async {
        DownloadManager.shared.noteProgress(itemId: itemId, positionSeconds: duration, played: true)
        Task { await OfflineProgress.sync() }
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

    /// Seconds left, for the Up Next countdown.
    var secondsRemaining: Double {
        duration > 0 ? max(0, duration - position) : .infinity
    }

    private func upNextIsDue() -> Bool {
        guard !autoplayCancelled, prefs.autoplayNext, duration > 0 else { return false }
        let hasNext = upNext != nil || upNextLocalId != nil
        return hasNext && secondsRemaining <= 25 && secondsRemaining > 0
    }

    var upNextTitle: String? {
        if let upNext { return Self.displayTitle(upNext) }
        #if !os(tvOS)
        if let upNextLocalId, let record = DownloadManager.shared.record(for: upNextLocalId) {
            return record.title
        }
        #endif
        return nil
    }
}
