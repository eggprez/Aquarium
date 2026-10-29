//  Which engine plays a stream, and whether the server is asked for the file
//  or for a transcode of it. Pure functions with unit tests; nothing here
//  touches the player or the network.
//
//  The policy is written down in PLAYER-OVERHAUL-PLAN.md under "Choosing the
//  engine" and the reasoning under "Where the battery actually goes". In one
//  line: AVPlayer by default on anything with a battery, mpv when the file or
//  the viewer asks for something AVPlayer cannot give, mpv always on Apple TV.

import Foundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

enum EnginePolicy {
    enum Platform: Sendable, Hashable {
        case appleTV, iPhone, iPad, mac

        /// The one this build is running on.
        @MainActor
        static var current: Platform {
            #if os(tvOS)
            return .appleTV
            #elseif os(macOS)
            return .mac
            #else
            return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
            #endif
        }
    }

    /// Settings → Video → Playback engine. Automatic is the default.
    enum Preference: String, Sendable, Hashable, CaseIterable {
        case automatic, apple, mpv

        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .apple: "Apple"
            case .mpv: "mpv"
            }
        }
    }

    /// Settings → Video → Battery saver: whether the mpv engine draws
    /// cheaply. Automatic reads the device.
    enum BatterySaver: String, Sendable, Hashable, CaseIterable {
        case automatic, always, never

        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    /// Everything the choice is made from. Built by the model from the item,
    /// the options and the preferences; the function itself reads nothing
    /// else, which is what makes it testable.
    struct Request: Sendable {
        var platform: Platform
        var preference: Preference = .automatic
        /// Whether libmpv is compiled into this build at all; no rule below
        /// can be honoured without it.
        var mpvAvailable: Bool
        /// Picture in Picture, AirPlay or SharePlay is wanted on this stream,
        /// and only AVPlayer has them: the hand-over case.
        var requiresApple = false
        /// The server's description of the file, when there is one.
        var source: MediaSource?
        /// The tracks the stream is being asked for, in the server's
        /// numbering. Nil leaves the choice to the server's defaults; `-1`
        /// for the subtitle is none.
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var isLive = false
        /// The stream will reach the engine as HLS — a transcode, a channel
        /// — rather than as the file itself.
        var isHLS = false
        /// A download played from disk, or an address with no Jellyfin
        /// server behind it (a playlist channel, a debug URL): nothing to
        /// remux the file, so its container decides.
        var isDownload = false
        var isExternalFile = false
        /// The container of such a file, as its extension or as it was saved.
        var fileContainer: String?
        var picture: PictureAdjustment = .neutral
        var framing: Framing = .fit
        var audioDelay: Double = 0
        /// Whether this device decodes AV1 in hardware (A17 Pro, M3 and
        /// later).
        var decodesAV1 = false
    }

    /// Codecs VideoToolbox decodes on every device this build runs on.
    static let hardwareVideoCodecs: Set<String> = ["h264", "avc1", "hevc", "hvc1", "dvhe", "dvh1", "prores"]

    /// Subtitle codecs AVFoundation cannot draw: the server would burn them
    /// into the picture, a full re-encode, where mpv renders them itself.
    static let subtitlesNeedingMPV: Set<String> = [
        "pgssub", "pgs", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub", "xsub", "ass", "ssa",
    ]

    /// Audio codecs AVFoundation has no decoder for: the server re-encodes
    /// the track, where mpv decodes it to PCM.
    static let audioNeedingMPV: Set<String> = ["dts", "dca", "truehd", "mlp"]

    /// Containers AVFoundation opens from disk. A download in anything else
    /// has no server to remux it, so it is mpv's or it doesn't play.
    static let fileContainersAVFoundationOpens: Set<String> = ["mp4", "m4v", "mov"]

    /// Whether this device decodes AV1 in hardware. Read once; a fact about
    /// the chip.
    static let decodesAV1InHardware: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    static func choose(_ request: Request) -> PlaybackEngineKind {
        // Nothing below can be honoured without the engine.
        guard request.mpvAvailable else { return .apple }

        // 1. Apple TV: mpv. On mains, with a GPU to spare and a soundbar to
        //    keep in step, every argument for AVPlayer is the battery's.
        if request.platform == .appleTV { return .mpv }

        // 4, taken first: Picture in Picture, AirPlay and SharePlay are
        //    AVPlayer's alone, so asking for one is asking for the engine,
        //    whatever the setting says.
        if request.requiresApple { return .apple }

        // 2. A preference is a decision already made.
        switch request.preference {
        case .apple: return .apple
        case .mpv: return .mpv
        case .automatic: break
        }

        // 3. Automatic.
        if let source = request.source {
            // A subtitle AVFoundation can't draw, or an audio track it can't
            // decode, sends the server a re-encode; mpv takes both from the
            // original. Only worth it when the video is decoded in hardware
            // either way — otherwise the server transcodes the picture
            // regardless and AVPlayer should take what it makes.
            let video = source.streams.first { $0.type == "Video" }
            if videoDecodesInHardware(video, decodesAV1: request.decodesAV1) {
                if let index = request.subtitleStreamIndex, index >= 0,
                   let subtitle = source.subtitleStreams.first(where: { $0.Index == index }),
                   subtitlesNeedingMPV.contains(subtitle.Codec?.lowercased() ?? "") {
                    return .mpv
                }
                let audioIndex = request.audioStreamIndex ?? source.DefaultAudioStreamIndex
                let audio = source.audioStreams.first { $0.Index == audioIndex } ?? source.audioStreams.first
                if let codec = audio?.Codec?.lowercased(), audioNeedingMPV.contains(codec) {
                    return .mpv
                }
            }
        }

        // Anything AVPlayer has no control for.
        if !request.picture.isNeutral { return .mpv }
        switch request.framing {
        case .zoom, .aspect: return .mpv
        case .fit, .fill: break
        }
        if request.isHLS, abs(request.audioDelay) > 0.0005 { return .mpv }

        // A download, or an address with no server behind it, in a container
        // AVFoundation won't open: the one case with nothing to remux it. A
        // playlist is a stream, not a file, and AVPlayer's; a bare MPEG-TS
        // address, which AVFoundation never opens on its own, is mpv's.
        if request.isDownload || request.isExternalFile, !request.isHLS,
           let container = request.fileContainer?.lowercased(),
           !container.isEmpty, !fileContainersAVFoundationOpens.contains(container) {
            return .mpv
        }

        // AVPlayer otherwise — every Live TV and IPTV channel included, where
        // the system pipeline's idle power over a long session is the whole
        // story.
        return .apple
    }

    /// How much of mpv's rendering budget to spend, from the setting and the
    /// device's state. Thermal pressure wins over everything: a phone at its
    /// limit is throttling its clocks whatever the viewer asked for.
    static func powerProfile(
        platform: Platform, saver: BatterySaver, onBattery: Bool, lowPower: Bool,
        thermal: ProcessInfo.ThermalState
    ) -> PowerProfile {
        if thermal == .serious || thermal == .critical { return .battery }
        switch saver {
        case .always: return .battery
        case .never: return .quality
        case .automatic: break
        }
        switch platform {
        case .iPhone, .iPad: return .battery
        case .mac: return onBattery || lowPower ? .battery : .quality
        case .appleTV: return .quality
        }
    }

    /// Whether the file at `url`, played with nothing to remux it, is one
    /// AVFoundation opens; the policy's `fileContainer` for it.
    static func fileContainer(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// Whether VideoToolbox would decode this picture on this device. An
    /// undescribed stream is given the benefit of the doubt, as
    /// `DeviceProfile.canDirectPlay` gives it.
    static func videoDecodesInHardware(_ video: MediaStream?, decodesAV1: Bool) -> Bool {
        guard let codec = video?.Codec?.lowercased(), !codec.isEmpty else { return true }
        if hardwareVideoCodecs.contains(codec) { return true }
        if codec == "av1", decodesAV1 { return true }
        return false
    }
}

extension PlaybackEngineKind {
    /// The engine a platform plays through when nothing has been decided:
    /// mpv on the Apple TV, AVPlayer elsewhere.
    static var platformDefault: PlaybackEngineKind {
        #if os(tvOS)
        .mpv
        #else
        .apple
        #endif
    }

    var title: String {
        switch self {
        case .apple: "AVFoundation"
        case .mpv: "mpv"
        }
    }
}

/// How the server is asked for a stream: the rule `JellyfinClient.resolvePlayback`
/// applies, written down once so it can be tested.
///
/// Whether a transcode is a remux (the same bitstream rewrapped as HLS) or a
/// re-encode is the server's call from the device profile; from here the two
/// look the same.
enum StreamPlan: Equatable, Sendable {
    /// The file as it sits on the server's disk.
    case direct
    /// The HLS stream the server offered.
    case transcode
    /// The server offered the file but this engine can't open it: ask again
    /// with direct play and direct stream switched off, which leaves the
    /// server nothing to answer with but a transcode.
    case escalate

    static func decide(
        source: MediaSource, forceTranscode: Bool, live: Bool, engineCanOpen: Bool
    ) -> StreamPlan {
        if source.TranscodingUrl != nil,
           forceTranscode || (source.SupportsDirectPlay != true && source.SupportsDirectStream != true) {
            return .transcode
        }
        // A tuner that won't say what it is sending is very often MPEG-TS,
        // which AVFoundation reads inside an HLS playlist and never on its own.
        if !forceTranscode, !engineCanOpen || (live && (source.Container ?? "").isEmpty) {
            return .escalate
        }
        return .direct
    }
}
