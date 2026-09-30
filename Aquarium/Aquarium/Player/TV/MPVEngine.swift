//  libmpv, wrapped for the Apple TV player.
//
//  The Apple TV plays video through mpv rather than AVPlayer. AVPlayer could
//  not open Matroska, DTS or TrueHD, so most of a library reached it as a
//  server transcode — and a transcode is where the sound drifted from the
//  picture. It could only move the sound against the picture on a file it had
//  been handed whole, which every stream the server built was not. mpv reads
//  the original file, whatever it is, and `audio-delay` moves the sound either
//  way to the millisecond on everything.
//
//  This file is only the engine: a handle, the options it is created with,
//  the properties it reports and the commands it takes. What any of it means
//  for Jellyfin — which stream to ask for, what to report, what comes next —
//  is `PlayerModel`'s business (the tvOS one, in `TVPlayerModel.swift`).
//
//  mpv's API is thread-safe. Its events are drained on a private serial queue,
//  turned into `MPVEngine.Event` values there, and handed to the main thread
//  through `onEvent`; commands and property writes are made from the main
//  thread directly. The handle is only destroyed once the queue has been told
//  to stop reading it — see `shutdown`.
//
//  The picture is drawn by mpv itself (`vo=gpu-next`, Vulkan through MoltenVK)
//  into `layer`, a CAMetalLayer, the way MPVKit's own tvOS demo does it.
//  Decoding is VideoToolbox where the hardware takes the codec and software
//  where it doesn't.

#if os(tvOS)

import Foundation
import Libmpv
import OSLog
import QuartzCore
import UIKit

/// The surface mpv draws into.
///
/// MoltenVK forces a presentation to finish by setting the drawable to 1×1,
/// which flickers and can leave the drawable stuck at that size; refusing any
/// drawable that small is the workaround mpv itself uses.
/// https://github.com/mpv-player/mpv/pull/13651
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// A view whose layer is the one mpv draws into, so it is sized by the view
/// hierarchy like anything else.
final class MPVVideoView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: MPVMetalLayer {
        // Cannot fail: `layerClass` above is what made the layer.
        layer as! MPVMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.windowScene?.screen {
            metalLayer.contentsScale = screen.nativeScale
        }
    }
}

final class MPVEngine: @unchecked Sendable {
    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "mpv")

    /// A track as mpv lists it.
    struct Track: Hashable, Sendable {
        enum Kind: String, Sendable { case audio, video, sub }
        /// mpv's own id for the track: what `aid`, `sid` and `vid` take.
        var id: Int
        var kind: Kind
        var title: String?
        var language: String?
        var codec: String?
        var isDefault: Bool
        var isForced: Bool
        var isExternal: Bool
        var isSelected: Bool
        var channels: Int?
        /// The stream's index inside the file — what ffprobe, and so Jellyfin,
        /// numbers it by. How a Jellyfin stream index is found among mpv's
        /// tracks. Nil for an external track.
        var fileIndex: Int?
        /// For an external subtitle, the URL it was added from.
        var externalURL: String?
    }

    struct Chapter: Hashable, Sendable {
        var title: String?
        var time: Double
    }

    enum EndReason: Sendable { case eof, stop, quit, error, redirect, unknown }

    enum Event: Sendable {
        case position(Double)
        case duration(Double)
        case paused(Bool)
        /// Waiting on the network with the playhead stopped.
        case buffering(Bool)
        case seeking(Bool)
        /// How far the cache reaches, in stream seconds.
        case cachedUntil(Double)
        case tracks([Track])
        case chapters([Chapter])
        /// The picture's display size, once there is one.
        case videoSize(CGSize)
        /// The stream's own frame rate, as the container declares it.
        case frameRate(Double)
        /// Which hardware decoder is in use: `videotoolbox`, or `no` for
        /// software.
        case decoder(String)
        case droppedFrames(Int)
        /// The file has been opened and its tracks are known.
        case fileLoaded
        /// Playback (re)started after a load or a seek: the first frame after
        /// it is on screen.
        case playbackRestart
        case endFile(EndReason, error: String?)
    }

    /// Where events go, on the main thread.
    var onEvent: (@MainActor (Event) -> Void)?

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "aquarium.mpv.events", qos: .userInitiated)
    /// Read and written only on `queue`. Set before the handle is destroyed so
    /// a wakeup already in flight doesn't read a dead handle.
    private var closed = false
    /// The last position delivered, and when — see `deliverPosition`.
    private var lastPosition: (value: Double, at: CFTimeInterval) = (-1, 0)

    /// Create the handle and point it at `layer`. Returns nil if libmpv
    /// couldn't be started at all.
    init?(layer: MPVMetalLayer) {
        guard let h = mpv_create() else { return nil }
        handle = h

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)

        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("video-rotate", "no"),
            // Nothing of mpv's own on screen: the player draws its own
            // controls and mpv's would sit on top of them.
            ("osc", "no"),
            ("osd-level", "0"),
            ("osd-bar", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("config", "no"),
            ("ytdl", "no"),
            ("load-scripts", "no"),
            // The player decides what happens at the end — up next, back to
            // the library — so mpv just says the file ended.
            ("keep-open", "no"),
            ("idle", "yes"),
            // Every seek lands where it was asked to, not on the keyframe
            // before: a ten-second skip that goes back four is not a skip.
            ("hr-seek", "yes"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("demuxer-readahead-secs", "20"),
            // As many channels as the route takes. mpv decodes Dolby and DTS
            // itself and sends PCM, so a soundbar gets 5.1 or 7.1 PCM rather
            // than a bitstream to decode on its own time.
            ("audio-channels", "auto"),
            // Subtitles in the file are chosen by the player from the
            // viewer's preferences, not by mpv from the file's flags.
            ("sid", "no"),
            ("sub-auto", "no"),
            ("audio-file-auto", "no"),
            ("network-timeout", "30"),
        ]
        for (name, value) in options {
            let status = mpv_set_option_string(h, name, value)
            if status < 0 {
                Self.log.error("mpv option \(name, privacy: .public)=\(value, privacy: .public): \(String(cString: mpv_error_string(status)), privacy: .public)")
            }
        }
        #if DEBUG
        mpv_request_log_messages(h, "warn")
        #else
        mpv_request_log_messages(h, "error")
        #endif

        guard mpv_initialize(h) >= 0 else {
            mpv_terminate_destroy(h)
            handle = nil
            return nil
        }

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("seeking", MPV_FORMAT_FLAG)
        observe("demuxer-cache-time", MPV_FORMAT_DOUBLE)
        observe("track-list", MPV_FORMAT_NONE)
        observe("chapter-list", MPV_FORMAT_NONE)
        observe("dwidth", MPV_FORMAT_INT64)
        observe("dheight", MPV_FORMAT_INT64)
        observe("container-fps", MPV_FORMAT_DOUBLE)
        observe("hwdec-current", MPV_FORMAT_STRING)
        observe("frame-drop-count", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(h, { context in
            guard let context else { return }
            let engine = Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue()
            engine.queue.async { engine.drain() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        shutdown()
    }

    /// Stop reading events and destroy the handle. Safe to call twice.
    func shutdown() {
        guard let h = handle else { return }
        mpv_set_wakeup_callback(h, nil, nil)
        queue.sync { closed = true }
        handle = nil
        mpv_terminate_destroy(h)
    }

    // MARK: - Commands

    /// Open a URL, replacing whatever is playing. `start` is where in the
    /// stream to begin; `headers` go on every request mpv makes for it.
    func load(_ url: URL, start: Double, headers: [String: String]) {
        guard handle != nil else { return }
        command(["change-list", "http-header-fields", "clr", ""])
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            // `append` takes the whole string as one element, where setting the
            // option would split it on the commas inside Jellyfin's
            // Authorization header.
            command(["change-list", "http-header-fields", "append", "\(name): \(value)"])
        }
        // A property rather than a per-file option, because it is simplest to
        // set it every time: `none` for the top.
        setString("start", start > 0.5 ? String(format: "%.3f", start) : "none")
        command(["loadfile", url.absoluteString, "replace"])
    }

    func stop() {
        command(["stop"])
    }

    func seek(to seconds: Double) {
        command(["seek", String(format: "%.3f", max(0, seconds)), "absolute"])
    }

    func seek(by seconds: Double) {
        command(["seek", String(format: "%.3f", seconds), "relative"])
    }

    /// Add a subtitle file by URL and make it the one shown.
    func addSubtitle(_ url: URL, title: String?, language: String?) {
        var args = ["sub-add", url.absoluteString, "select"]
        if title != nil || language != nil { args.append(title ?? "") }
        if let language { args.append(language) }
        command(args)
    }

    var isPaused: Bool {
        get { getFlag("pause") }
        set { setFlag("pause", newValue) }
    }

    /// Seconds; positive plays the sound later than the picture.
    var audioDelay: Double {
        get { getDouble("audio-delay") }
        set { setDouble("audio-delay", newValue) }
    }

    var speed: Double {
        get { getDouble("speed") }
        set { setDouble("speed", newValue) }
    }

    /// 0…100.
    var volume: Double {
        get { getDouble("volume") }
        set { setDouble("volume", newValue) }
    }

    /// The audio track, by mpv id; nil for none.
    func selectAudio(_ id: Int?) { setString("aid", id.map(String.init) ?? "no") }
    /// The subtitle track, by mpv id; nil for none.
    func selectSubtitle(_ id: Int?) { setString("sid", id.map(String.init) ?? "no") }

    /// Anything else, by name — subtitle styling and the like.
    func set(_ name: String, _ value: String) { setString(name, value) }
    func get(_ name: String) -> String? { getString(name) }

    // MARK: - Low-level access

    private func observe(_ name: String, _ format: mpv_format) {
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for pointer in cargs where pointer != nil { free(UnsafeMutablePointer(mutating: pointer)) } }
        let status = mpv_command(handle, &cargs)
        if status < 0 {
            Self.log.error("mpv \(args.first ?? "", privacy: .public) failed: \(String(cString: mpv_error_string(status)), privacy: .public)")
        }
        return status
    }

    private func getDouble(_ name: String) -> Double {
        guard let handle else { return 0 }
        var value = 0.0
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        var value = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func getFlag(_ name: String) -> Bool {
        guard let handle else { return false }
        var value: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
        return value != 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard let handle else { return }
        var value: Int32 = flag ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &value)
    }

    private func getInt(_ name: String) -> Int? {
        guard let handle else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return Int(value)
    }

    private func getString(_ name: String) -> String? {
        guard let handle, let cstring = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstring) }
        return String(cString: cstring)
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        let status = mpv_set_property_string(handle, name, value)
        if status < 0 {
            Self.log.error("mpv set \(name, privacy: .public)=\(value, privacy: .public): \(String(cString: mpv_error_string(status)), privacy: .public)")
        }
    }

    // MARK: - Events

    /// Read every event waiting. On `queue` only.
    private func drain() {
        while !closed, let handle {
            guard let event = mpv_wait_event(handle, 0)?.pointee else { return }
            switch event.event_id {
            case MPV_EVENT_NONE:
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.data {
                    property(data.assumingMemoryBound(to: mpv_event_property.self).pointee)
                }
            case MPV_EVENT_FILE_LOADED:
                deliver(.fileLoaded)
            case MPV_EVENT_PLAYBACK_RESTART:
                deliver(.playbackRestart)
            case MPV_EVENT_END_FILE:
                if let data = event.data {
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    endFile(end)
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.data {
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let prefix = message.prefix.map { String(cString: $0) } ?? ""
                    let text = message.text.map { String(cString: $0) } ?? ""
                    Self.log.notice("[\(prefix, privacy: .public)] \(text.trimmingCharacters(in: .newlines), privacy: .public)")
                }
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
    }

    private func property(_ p: mpv_event_property) {
        let name = String(cString: p.name)
        switch (name, p.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE):
            deliverPosition(double(p))
        case ("duration", MPV_FORMAT_DOUBLE):
            deliver(.duration(double(p)))
        case ("pause", MPV_FORMAT_FLAG):
            deliver(.paused(flag(p)))
        case ("paused-for-cache", MPV_FORMAT_FLAG):
            deliver(.buffering(flag(p)))
        case ("seeking", MPV_FORMAT_FLAG):
            deliver(.seeking(flag(p)))
        case ("demuxer-cache-time", MPV_FORMAT_DOUBLE):
            deliver(.cachedUntil(double(p)))
        case ("track-list", _):
            deliver(.tracks(readTracks()))
        case ("chapter-list", _):
            deliver(.chapters(readChapters()))
        case ("dwidth", MPV_FORMAT_INT64), ("dheight", MPV_FORMAT_INT64):
            if let w = getInt("dwidth"), let h = getInt("dheight"), w > 0, h > 0 {
                deliver(.videoSize(CGSize(width: w, height: h)))
            }
        case ("container-fps", MPV_FORMAT_DOUBLE):
            deliver(.frameRate(double(p)))
        case ("hwdec-current", MPV_FORMAT_STRING):
            if let data = p.data, let cstring = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                deliver(.decoder(String(cString: cstring)))
            }
        case ("frame-drop-count", MPV_FORMAT_INT64):
            if let data = p.data {
                deliver(.droppedFrames(Int(data.assumingMemoryBound(to: Int64.self).pointee)))
            }
        default:
            break
        }
    }

    /// The playhead moves every frame, and the screen needs it four or five
    /// times a second. A jump — a seek landing — goes through at once.
    private func deliverPosition(_ value: Double) {
        let now = CACurrentMediaTime()
        let jumped = abs(value - lastPosition.value) > 1
        guard jumped || now - lastPosition.at >= 0.2 else { return }
        lastPosition = (value, now)
        deliver(.position(value))
    }

    private func endFile(_ end: mpv_event_end_file) {
        let reason: EndReason
        switch end.reason {
        case MPV_END_FILE_REASON_EOF: reason = .eof
        case MPV_END_FILE_REASON_STOP: reason = .stop
        case MPV_END_FILE_REASON_QUIT: reason = .quit
        case MPV_END_FILE_REASON_ERROR: reason = .error
        case MPV_END_FILE_REASON_REDIRECT: reason = .redirect
        default: reason = .unknown
        }
        let error = end.error < 0 ? String(cString: mpv_error_string(end.error)) : nil
        lastPosition = (-1, 0)
        deliver(.endFile(reason, error: error))
    }

    private func double(_ p: mpv_event_property) -> Double {
        guard let data = p.data else { return 0 }
        return data.assumingMemoryBound(to: Double.self).pointee
    }

    private func flag(_ p: mpv_event_property) -> Bool {
        guard let data = p.data else { return false }
        return data.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    private func readTracks() -> [Track] {
        let count = getInt("track-list/count") ?? 0
        return (0..<count).compactMap { i in
            let base = "track-list/\(i)/"
            guard let id = getInt(base + "id"),
                  let kind = getString(base + "type").flatMap(Track.Kind.init(rawValue:))
            else { return nil }
            return Track(
                id: id,
                kind: kind,
                title: getString(base + "title"),
                language: getString(base + "lang"),
                codec: getString(base + "codec"),
                isDefault: getFlag(base + "default"),
                isForced: getFlag(base + "forced"),
                isExternal: getFlag(base + "external"),
                isSelected: getFlag(base + "selected"),
                channels: getInt(base + "demux-channel-count"),
                fileIndex: getInt(base + "ff-index"),
                externalURL: getString(base + "external-filename")
            )
        }
    }

    private func readChapters() -> [Chapter] {
        let count = getInt("chapter-list/count") ?? 0
        return (0..<count).map { i in
            Chapter(
                title: getString("chapter-list/\(i)/title"),
                time: getDouble("chapter-list/\(i)/time")
            )
        }
    }

    private func deliver(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }
}

#endif
