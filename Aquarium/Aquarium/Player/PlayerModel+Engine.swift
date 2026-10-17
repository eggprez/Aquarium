//  Which engine plays a stream, and handing a stream from one engine to the
//  other. The choice itself is `EnginePolicy.choose`, a pure function with
//  tests; this file builds its request from the item, the options and the
//  preferences, and acts on the answer. Consulted when a stream is asked for
//  and again when the viewer changes something only the other engine can do:
//  the Picture tab on AVPlayer, an audio delay on an HLS stream, Picture in
//  Picture, AirPlay or Watch Together on mpv.
//
//  A hand-over is a reopen at the same position through the model's own
//  `play` path, with `engineOverride` carrying the viewer's wish through the
//  reopens of the title and dropped when the title changes.

import Foundation
import OSLog

#if canImport(UIKit)
import UIKit
#endif

extension PlayerModel {
    /// Whether libmpv is in this build at all.
    static var mpvAvailable: Bool {
        #if canImport(Libmpv)
        true
        #else
        false
        #endif
    }

    var platform: EnginePolicy.Platform { .current }

    #if canImport(Libmpv)
    /// How much mpv reads ahead on this device.
    var mpvTuning: MPVEngine.Tuning {
        switch platform {
        case .iPhone, .iPad: .handheld
        case .mac, .appleTV: .plugged
        }
    }
    #endif

    // MARK: - Choosing

    /// The parts of the request that come from the preferences and the
    /// player's state rather than from the stream.
    private func baseRequest() -> EnginePolicy.Request {
        var request = EnginePolicy.Request(platform: platform, mpvAvailable: Self.mpvAvailable)
        request.preference = prefs.playbackEngine
        request.picture = prefs.picture
        request.framing = preferredFraming
        request.audioDelay = audioDelay
        request.decodesAV1 = EnginePolicy.decodesAV1InHardware
        #if !os(tvOS)
        // A Watch Together session is AVPlayer's for its length.
        if SharePlayCoordinator.shared.isActive { request.requiresApple = true }
        #endif
        switch engineOverride {
        case .apple: request.requiresApple = true
        case .mpv: request.preference = .mpv
        case nil: break
        }
        return request
    }

    /// The engine for a Jellyfin item, asked for with `options`.
    func chooseEngine(for item: BaseItem, options: StreamOptions) -> PlaybackEngineKind {
        var request = baseRequest()
        request.source = item.MediaSources?.first
        request.audioStreamIndex = options.audioStreamIndex
        request.subtitleStreamIndex = options.subtitleStreamIndex
        request.isLive = options.live
        request.isHLS = options.live || options.forceTranscode || options.forceFullEncode || options.maxBitrate != nil
        return EnginePolicy.choose(request)
    }

    /// The engine for an address with no Jellyfin server behind it: a
    /// playlist channel, or the debug URL.
    func chooseEngine(forExternal url: URL) -> PlaybackEngineKind {
        var request = baseRequest()
        request.isExternalFile = true
        request.fileContainer = EnginePolicy.fileContainer(of: url)
        request.isLive = true
        request.isHLS = request.fileContainer == "m3u8" || request.fileContainer == "m3u"
        return EnginePolicy.choose(request)
    }

    #if !os(tvOS)
    /// The engine for a download played from disk.
    func chooseEngine(forLocal record: DownloadRecord) -> PlaybackEngineKind {
        var request = baseRequest()
        request.isDownload = true
        if record.hlsPath != nil {
            request.isHLS = true
        } else {
            request.fileContainer = EnginePolicy.fileContainer(of: URL(fileURLWithPath: record.fileName))
        }
        return EnginePolicy.choose(request)
    }
    #endif

    /// Which engine is playing, for the About row and the Info tab.
    var engineKind: PlaybackEngineKind? { isActive ? engine?.kind : nil }

    /// What Settings → About says the engine is: the one playing while
    /// something plays, the setting otherwise.
    var engineDescription: String {
        if let engineKind { return "\(engineKind.title), playing now" }
        #if os(tvOS)
        return "mpv"
        #else
        switch prefs.playbackEngine {
        case .automatic: return "Automatic: AVFoundation, mpv when a title needs it"
        case .apple: return "AVFoundation"
        case .mpv: return Self.mpvAvailable ? "mpv" : "AVFoundation (mpv is not in this build)"
        }
        #endif
    }

    // MARK: - Switching

    /// Whether the stream playing can be reopened on `kind`.
    func canSwitchEngine(to kind: PlaybackEngineKind) -> Bool {
        engineSwitchUnavailableReason(to: kind) == nil
    }

    /// Why it cannot, or nil when it can.
    func engineSwitchUnavailableReason(to kind: PlaybackEngineKind) -> String? {
        #if os(tvOS)
        return "The Apple TV plays through mpv alone."
        #else
        guard isActive else { return "Nothing is playing." }
        if errorMessage != nil { return "Once the stream is playing again." }
        if engine?.kind == kind { return nil }
        switch kind {
        case .mpv:
            if !Self.mpvAvailable { return "The mpv engine is not in this build." }
            if SharePlayCoordinator.shared.isActive { return "Watch Together plays through Apple's engine for the length of the session." }
            if prefs.playbackEngine == .apple { return "Settings → Video → Playback engine is set to Apple." }
        case .apple:
            if prefs.playbackEngine == .mpv, engineOverride != .apple {
                return "Settings → Video → Playback engine is set to mpv."
            }
        }
        return nil
        #endif
    }

    /// Reopen whatever is playing on `kind` at the same position, and keep
    /// to `kind` for this title. The reopen is the model's own `play` path —
    /// the stream is asked for again with the other engine's profile, so a
    /// Matroska that was being remuxed for AVPlayer reaches mpv as the file.
    func switchEngine(to kind: PlaybackEngineKind, reason: String) async {
        guard isActive, engine?.kind != kind else { return }
        if let why = engineSwitchUnavailableReason(to: kind) {
            Self.log.notice("engine switch to \(kind.title, privacy: .public) for \(reason, privacy: .public) refused: \(why, privacy: .public)")
            return
        }
        Self.log.notice("switching to \(kind.title, privacy: .public) for \(reason, privacy: .public) at \(self.position, format: .fixed(precision: 1))")
        engineOverride = kind
        let resume = isLive ? 0 : position
        let wasPaused = isPaused
        #if !os(tvOS)
        if isLocal, let id = localRecordId, let record = DownloadManager.shared.record(for: id) {
            playLocal(record, keepShuffle: true, startAt: resume, paused: wasPaused)
            return
        }
        #endif
        if let channel = externalChannel {
            let wasLive = isLive
            playExternal(
                title: channel.title, subtitle: channel.subtitle, artworkURL: channel.artworkURL,
                streamURL: channel.streamURL, channel: channel.item, reopening: true,
                startAt: resume, paused: wasPaused)
            if !wasLive { isLive = false; options.live = false }
            return
        }
        guard let item else { return }
        var opts = options
        opts.startSeconds = isLive ? nil : resume
        let mine = generation &+ 1
        await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true))
        // A paused title stays paused on the other engine.
        if wasPaused, generation == mine, isActive, errorMessage == nil { pause() }
    }

    // MARK: - Hand-over for Picture in Picture, AirPlay and Watch Together
    //
    // Never on the Apple TV, where `canSwitchEngine(to: .apple)` is false and
    // each of these is a no-op.

    /// Whether the Picture in Picture button has anything to do on mpv:
    /// hand the stream to AVPlayer, whose layer the system can lift out.
    var canHandOverForPictureInPicture: Bool {
        engine?.kind == .mpv && canSwitchEngine(to: .apple)
    }

    /// Reopen on AVPlayer and start Picture in Picture as soon as its layer
    /// is playing. When the picture comes back the stream returns to mpv.
    func handOverForPictureInPicture(_ pictureInPicture: PictureInPicture) {
        guard canHandOverForPictureInPicture else { return }
        returnsToMPV = true
        pictureInPicture.startWhenPossible()
        Task { await switchEngine(to: .apple, reason: "Picture in Picture") }
    }

    /// The AirPlay picker is opening: AirPlay video is AVPlayer's, so the
    /// stream is handed to it before a television can be chosen.
    func handOverForAirPlay() {
        guard engine?.kind == .mpv, canSwitchEngine(to: .apple) else { return }
        Task { await switchEngine(to: .apple, reason: "AirPlay") }
    }

    /// Watch Together is AVPlayer's; the stream goes there first.
    func prepareForSharePlay() async {
        guard engine?.kind == .mpv else { return }
        await switchEngine(to: .apple, reason: "Watch Together")
    }

    /// Picture in Picture ended on a stream that was handed over for it: back
    /// to mpv, which is what the title was on.
    func pictureInPictureEnded() {
        guard returnsToMPV else { return }
        returnsToMPV = false
        guard isActive, engine?.kind == .apple else { return }
        engineOverride = nil
        Task { await switchEngine(to: .mpv, reason: "Picture in Picture ended") }
    }

    // MARK: - The picture

    /// Fit, Fill, a zoom or an aspect override, from Settings.
    var preferredFraming: Framing {
        if prefs.aspectOverride > 0 { return .aspect(prefs.aspectOverride) }
        if abs(prefs.pictureZoom - 1) > 0.001 { return .zoom(prefs.pictureZoom) }
        return prefs.fillScreen ? .fill : .fit
    }

    /// Brightness, contrast, saturation and gamma, from Settings, applied
    /// live. On an engine without them, `switchingIfNeeded` reopens on mpv
    /// when any is off neutral.
    func applyPicture(switchingIfNeeded: Bool = false) {
        engine?.picture = prefs.picture
        guard switchingIfNeeded, isActive, engine?.capabilities.contains(.pictureAdjust) == false,
              prefs.pictureIsAdjusted, canSwitchEngine(to: .mpv) else { return }
        Task { await switchEngine(to: .mpv, reason: "picture adjusted") }
    }

    // MARK: - Power

    /// How much of mpv's rendering budget to spend, from Settings and the
    /// device's state: on a battery, in Low Power Mode, or running hot.
    func refreshPowerProfile() {
        guard let engine else { return }
        let info = ProcessInfo.processInfo
        let profile = EnginePolicy.powerProfile(
            platform: platform, saver: prefs.batterySaver, onBattery: PowerSource.onBattery,
            lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
        if engine.powerProfile != profile {
            Self.log.info("render profile: \(profile == .battery ? "battery" : "quality", privacy: .public)")
        }
        engine.powerProfile = profile
    }

    // MARK: - The decoder

    /// mpv said which decoder it is using. Software decode on a phone is a
    /// hand-warmer, and the server can send something the hardware takes: the
    /// stream is reopened on AVPlayer with the server transcoding.
    func onDecoder(_ name: String) {
        guard engine?.kind == .mpv, name == "no", !softwareDecodeHandled else { return }
        softwareDecodeHandled = true
        #if os(iOS)
        guard let item, !isExternal, !isLocal else {
            Self.log.notice("mpv is decoding in software and there is no server to ask for a transcode")
            return
        }
        guard canSwitchEngine(to: .apple) else { return }
        Self.log.notice("mpv is decoding \(self.title, privacy: .public) in software on this device; reopening on AVPlayer with the server transcoding")
        engineOverride = .apple
        var opts = options
        opts.forceTranscode = true
        opts.startSeconds = isLive ? nil : position
        Task { await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true, recovering: true)) }
        #else
        Self.log.notice("mpv is decoding in software")
        #endif
    }
}
