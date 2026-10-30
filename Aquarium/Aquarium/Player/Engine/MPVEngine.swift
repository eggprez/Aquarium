//  libmpv, behind `PlaybackEngine`.
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
//  is `PlayerModel`'s business.
//
//  mpv's API is thread-safe. Its events are drained on a private serial queue,
//  turned into `EngineEvent` values there, and handed to the model through
//  `events`; commands and property writes are made from the main thread
//  directly. The handle is only destroyed once the queue has been told to stop
//  reading it — see `shutdown`.
//
//  The picture is drawn by mpv itself (`vo=gpu-next`, Vulkan through MoltenVK)
//  into `layer`, a CAMetalLayer, the way MPVKit's own tvOS demo does it.
//  Decoding is VideoToolbox where the hardware takes the codec and software
//  where it doesn't.
//
//  On an iPhone or iPad mpv draws instead, by default, into an
//  `AVSampleBufferDisplayLayer` (`vo=avfoundation`, a patch of our own in
//  `Vendor/MPVKit`). Picture in Picture takes only that layer or an
//  `AVPlayerLayer`, never a Metal one, so this is what lets mpv's picture
//  float without the stream being reopened on AVPlayer. The frames go
//  straight from VideoToolbox to the layer, so gpu-next's shaders don't run:
//  a picture adjustment, a zoom or an aspect override, and Dolby Vision
//  profile 5 — whose colours only libplacebo puts right — draw through
//  gpu-next instead. The two are swapped on the running stream (`setOutput`).
//
//  Compiled wherever MPVKit is linked: iPhone, iPad, Mac and Apple TV since
//  phase 4 of the overhaul opened the package's platform filter. The two view
//  classes at the top are the only parts tied to a platform rather than to the
//  library; the engine itself only ever sees a `CAMetalLayer`.
//
//  On a battery the engine is told to draw cheaply (`powerProfile`): the
//  `[aquarium-battery]` profile below is the Linux app's, applied with
//  `apply-profile` and taken off again with `profile-restore=copy`, so mpv
//  itself puts every option back as it was. The handle is made for a stream
//  and destroyed when the player comes down, so nothing of mpv runs while
//  the app browses.

#if canImport(Libmpv)

import Foundation
import Libmpv
import OSLog
import QuartzCore
#if os(iOS)
import AVFoundation
import CoreMedia
#endif

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The surface mpv draws into.
///
/// MoltenVK forces a presentation to finish by setting the drawable to 1×1,
/// which flickers and can leave the drawable stuck at that size; refusing any
/// drawable that small is the workaround mpv itself uses.
/// https://github.com/mpv-player/mpv/pull/13651
///
/// Two drawables rather than the default three: mpv presents one frame at a
/// time and a third buffer is memory held for nothing. Presentation is not
/// tied to a Core Animation transaction, which would make every frame wait
/// on the main thread's layout.
final class MPVMetalLayer: CAMetalLayer {
    override init() {
        super.init()
        configure()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        framebufferOnly = true
        maximumDrawableCount = 2
        presentsWithTransaction = false
        backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Called by the view hosting the layer when the drawable has been
    /// given a new size — a rotation, a window resize, the first layout —
    /// so the engine can have mpv's output configured for it; see
    /// `MPVEngine.surfaceResized`.
    var onResize: (() -> Void)?

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

#if canImport(UIKit)
/// A view whose layer is the one mpv draws into, so it is sized by the view
/// hierarchy like anything else. The Apple TV's player holds one for the life
/// of the app; on an iPhone or iPad the layer is hosted by `VideoSurface`
/// instead, and this view goes unused.
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
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.windowScene?.screen {
            metalLayer.contentsScale = screen.nativeScale
        }
    }
}
#endif

#if os(iOS)
/// Which layer mpv draws into on an iPhone or iPad.
enum MPVOutput: Sendable {
    /// gpu-next into `MPVMetalLayer`: every shader, no Picture in Picture.
    case metal
    /// `vo=avfoundation` into `MPVSampleBufferLayer`: what Picture in
    /// Picture can lift out.
    case sampleBuffer
}

/// The layer mpv's `avfoundation` output enqueues frames on. Each frame is
/// stamped with the layer's clock as it is drawn, so it shows at once; the
/// clock is kept at the playhead and stopped while paused only so that
/// Picture in Picture has a time to show and a rate to read.
final class MPVSampleBufferLayer: AVSampleBufferDisplayLayer, @unchecked Sendable {
    let clock: CMTimebase

    override init() {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        // Cannot fail with the host clock.
        clock = timebase!
        super.init()
        CMTimebaseSetTime(clock, time: .zero)
        CMTimebaseSetRate(clock, rate: 0)
        controlTimebase = clock
        videoGravity = .resizeAspect
        backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Core Animation's copies for presentation share the original's clock.
    override init(layer: Any) {
        // Cannot fail: Core Animation copies a layer as its own class.
        clock = (layer as! MPVSampleBufferLayer).clock
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    /// Keep the clock at the playhead. Moved only when it has drifted, since
    /// setting it back would hold the frame just enqueued until the clock
    /// caught up with its stamp. Any thread: a timebase is thread-safe.
    func follow(position: Double, running: Bool) {
        let rate = running ? 1.0 : 0.0
        if CMTimebaseGetRate(clock) != rate { CMTimebaseSetRate(clock, rate: rate) }
        let now = CMTimebaseGetTime(clock).seconds
        if !now.isFinite || abs(now - position) > 0.5 {
            CMTimebaseSetTime(clock, time: CMTime(seconds: position, preferredTimescale: 90_000))
        }
    }
}
#endif

#if canImport(AppKit) && !canImport(UIKit)
/// The AppKit twin: a layer-backed view whose backing layer is the Metal
/// layer mpv draws into, given the window's backing scale so it draws at
/// Retina size. Takes no clicks of its own; the chrome above it does.
final class MPVVideoView: NSView {
    let metalLayer = MPVMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}
#endif

final class MPVEngine: @unchecked Sendable {
    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "mpv")

    let kind: PlaybackEngineKind = .mpv

    let capabilities: EngineCapabilities = [
        .audioDelayOnAnyStream, .pictureAdjust, .zoom, .externalSubtitles, .nightMode,
        .playsOnWhileReloading, .restartsAudioOutput, .displaySync,
    ]

    let directContainers: Set<String> = [
        "mkv", "matroska", "webm", "mp4", "m4v", "mov", "avi", "ts", "mpegts", "m2ts", "flv",
        "ogm", "ogv", "wmv", "asf", "3gp",
    ]

    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "aquarium.mpv.events", qos: .userInitiated)
    /// Read and written only on `queue`. Set before the handle is destroyed so
    /// a wakeup already in flight doesn't read a dead handle.
    private var closed = false
    /// The last position delivered, and when — see `deliverPosition`.
    private var lastPosition: (value: Double, at: CFTimeInterval) = (-1, 0)
    /// The last track list read, for `tracks`.
    private var lastTracks: [EngineTrack] = []
    /// Whether the file now loaded is open, and whether it is a live stream
    /// — read on `queue` when a file ends, written from the main thread.
    private var fileIsOpen = false
    private var sawFirstFrame = false
    private var loadedLive = false
    /// The layer mpv draws into, kept so a load can wait for it to have a
    /// size — see `load`.
    private let layer: MPVMetalLayer
    #if os(iOS)
    /// The other surface, and which of the two mpv is drawing into.
    private let sampleLayer: MPVSampleBufferLayer?
    private(set) var output: MPVOutput = .metal
    /// Something about the stream itself needs gpu-next — Dolby Vision
    /// profile 5 — whatever the viewer has set. `onRequirementsChanged`
    /// is called on the main thread when it changes.
    private(set) var requiresMetal = false
    var onRequirementsChanged: (() -> Void)?
    /// Whether mpv is paused or waiting on the cache, on `queue`: the
    /// sample layer's clock runs only while neither.
    private var clockHeld = (paused: false, buffering: false)
    #endif
    /// A `loadfile` held back until the layer has a size, and the resize
    /// nudge waiting to run; both on the main thread.
    private var pendingLoad: [String]?
    private var resizeNudge: DispatchWorkItem?
    /// The profile applied last, so the next can restore it first.
    private var appliedProfile: PowerProfile?

    /// What differs between a phone and a box on mains: how much of a stream
    /// is read ahead. Bigger, less frequent reads let a phone's radio sleep
    /// between bursts; the ceiling is the phone's memory.
    struct Tuning: Sendable, Hashable {
        var demuxerMaxBytes: String
        var readaheadSeconds: Int

        /// iPhone and iPad.
        static let handheld = Tuning(demuxerMaxBytes: "64MiB", readaheadSeconds: 60)
        /// Mac and Apple TV.
        static let plugged = Tuning(demuxerMaxBytes: "150MiB", readaheadSeconds: 20)
    }

    /// Create the handle and point it at `layer`. Returns nil if libmpv
    /// couldn't be started at all. `sampleLayer`, an `MPVSampleBufferLayer`
    /// on an iPhone or iPad (typed loosely so the signature is the same on
    /// every platform), is the layer `setOutput` can move the picture to.
    init?(layer: MPVMetalLayer, sampleLayer: Any? = nil, tuning: Tuning = .plugged) {
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        guard let h = mpv_create() else { return nil }
        handle = h
        self.layer = layer
        #if os(iOS)
        self.sampleLayer = sampleLayer as? MPVSampleBufferLayer
        #endif

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)
        layer.onResize = { [weak self] in self?.surfaceResized() }

        // The two profiles, from a file of this app's own, so they can be put
        // on and taken off with `apply-profile` exactly as the Linux app does.
        if let profiles = Self.profilesFile() {
            let status = mpv_set_option_string(h, "include", profiles.path)
            if status < 0 {
                Self.log.error("mpv profiles could not be read: \(String(cString: mpv_error_string(status)), privacy: .public)")
            }
        }

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
            ("demuxer-max-bytes", tuning.demuxerMaxBytes),
            ("demuxer-max-back-bytes", "50MiB"),
            ("demuxer-readahead-secs", String(tuning.readaheadSeconds)),
            // As many channels as the route takes. mpv decodes Dolby and DTS
            // itself and sends PCM, so a soundbar gets 5.1 or 7.1 PCM rather
            // than a bitstream to decode on its own time.
            ("audio-channels", "auto"),
            // A new audio output for every file. mpv's default keeps the one
            // it has when the next file's format matches — which, for a
            // library of 5.1 at 48 kHz, is every file for the life of the
            // app — and that output has lived through the television
            // switching 24 Hz → 60 → 24 around each title. It came out of
            // each switch a little later than it thought it was, so the
            // offset a film needed grew with every film opened. One opened
            // after the switch knows where it is.
            ("gapless-audio", "no"),
            // Subtitles in the file are chosen by the player from the
            // viewer's preferences, not by mpv from the file's flags.
            ("sid", "no"),
            ("sub-auto", "no"),
            ("audio-file-auto", "no"),
            ("network-timeout", "30"),
        ]
        #if os(iOS) || os(tvOS)
        // mpv's AudioUnit output sets the audio session's category itself,
        // every time it opens — which, with `gapless-audio=no`, is every
        // file — and without this it asks for `mixWithOthers`. A session that
        // mixes is not the device's media player: other apps' sound plays on
        // under the film, nothing is ducked, and the lock screen and Control
        // Centre show no card. Exclusive here means only "don't mix"; on a
        // Mac the same option would hog the output device, so it stays off
        // there.
        mpv_set_option_string(h, "audio-exclusive", "yes")
        #endif
        #if os(iOS)
        // Subtitles drawn into each frame rather than on a layer of their
        // own above it: Picture in Picture shows the frames and nothing else.
        if self.sampleLayer != nil {
            mpv_set_option_string(h, "avfoundation-composite-osd", "yes")
        }
        #endif
        for (name, value) in options {
            let status = mpv_set_option_string(h, name, value)
            if status < 0 {
                Self.log.error("mpv option \(name, privacy: .public)=\(value, privacy: .public): \(String(cString: mpv_error_string(status)), privacy: .public)")
            }
        }
        #if DEBUG
        // `-AquariumMPVLog v` (or `debug`, `trace`) for mpv's own account of a
        // stream, in the app's log under the mpv category.
        mpv_request_log_messages(h, UserDefaults.standard.string(forKey: "AquariumMPVLog") ?? "warn")
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
        pendingLoad = nil
        resizeNudge?.cancel()
        layer.onResize = nil
        #if os(iOS)
        pacing?.invalidate()
        pacing = nil
        #endif
        mpv_set_wakeup_callback(h, nil, nil)
        queue.sync { closed = true }
        handle = nil
        mpv_terminate_destroy(h)
        continuation.finish()
    }

    // MARK: - The profiles

    /// What `[aquarium-battery]` turns off, and what it is set to: the cheapest
    /// draw that still looks right, from the Linux app's measured profile
    /// (`Linux/src-tauri/mpv-config/mpv.conf`), plus no interpolation and
    /// frames timed to the audio clock rather than resampled to the display.
    static let batteryProfile: [(String, String)] = [
        ("scale", "bilinear"),
        ("cscale", "bilinear"),
        ("dscale", "bilinear"),
        ("dither", "no"),
        ("deband", "no"),
        ("correct-downscaling", "no"),
        ("linear-downscaling", "no"),
        ("sigmoid-upscaling", "no"),
        ("hdr-compute-peak", "no"),
        ("fbo-format", "rgba8"),
        ("interpolation", "no"),
        ("video-sync", "audio"),
    ]

    /// `[aquarium-quality]`: mpv's own defaults, with frames resampled to the
    /// display's refresh — a Mac on mains and the Apple TV, where the display
    /// has already been matched to the film.
    static let qualityProfile: [(String, String)] = [
        ("video-sync", "display-resample"),
    ]

    /// The two profiles as an mpv config file, written once per launch into
    /// the caches and handed to the handle with `include`. `profile-restore=copy`
    /// is what makes `apply-profile <name> restore` put the options back.
    nonisolated static func profilesFile() -> URL? {
        let text = """
        # Written by Aquarium at launch; not read by anything else.
        [aquarium-battery]
        profile-restore=copy
        \(batteryProfile.map { "\($0.0)=\($0.1)" }.joined(separator: "\n"))

        [aquarium-quality]
        profile-restore=copy
        \(qualityProfile.map { "\($0.0)=\($0.1)" }.joined(separator: "\n"))

        """
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("mpv", isDirectory: true)
        let file = folder.appendingPathComponent("aquarium-profiles.conf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != text {
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            return file
        } catch {
            log.error("mpv profiles file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Streams

    func load(_ request: EngineLoadRequest) {
        guard handle != nil else { return }
        command(["change-list", "http-header-fields", "clr", ""])
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            // `append` takes the whole string as one element, where setting the
            // option would split it on the commas inside Jellyfin's
            // Authorization header.
            command(["change-list", "http-header-fields", "append", "\(name): \(value)"])
        }
        // A property rather than a per-file option, because it is simplest to
        // set it every time: `none` for the top.
        setString("start", request.startAt > 0.5 ? String(format: "%.3f", request.startAt) : "none")
        // `pause` outlives the file: a stream opened over a paused one would
        // start paused, and the model — which begins every stream playing —
        // would never hear otherwise, since the property didn't change.
        setFlag("pause", request.paused)
        queue.sync {
            fileIsOpen = false
            sawFirstFrame = false
            loadedLive = request.live
        }
        // Per-file options go after the index (-1: not placed in a playlist)
        // and lapse with the file.
        var args = ["loadfile", request.url.absoluteString, "replace", "-1"]
        var perFile: [String] = []
        if request.loop { perFile.append("loop-file=inf") }
        if let audio = request.audioTrack { perFile.append("aid=\(audio)") }
        if let subtitle = request.subtitleTrack { perFile.append("sid=\(subtitle)") }
        if !perFile.isEmpty { args.append(perFile.joined(separator: ",")) }
        // mpv's MoltenVK context reads the layer's drawable size as the
        // output is configured and again only at a reconfigure. A file
        // opened before the layer has been laid out — the debug URL at
        // launch, a download — met a 1×1 drawable and drew into it, black,
        // for as long as it played. So the open waits, briefly, for the
        // layer to be hosted and sized; the resize nudge below is the
        // second line.
        pendingLoad = nil
        if layerIsSized {
            command(args)
        } else {
            pendingLoad = args
            loadWhenSized(deadline: .now + .milliseconds(1500))
        }
    }

    private var layerIsSized: Bool {
        let surface = drawingLayer
        return surface.superlayer != nil && surface.bounds.width >= 2 && surface.bounds.height >= 2
    }

    /// The layer mpv is drawing into now.
    var drawingLayer: CALayer {
        #if os(iOS)
        if output == .sampleBuffer, let sampleLayer { return sampleLayer }
        #endif
        return layer
    }

    private func loadWhenSized(deadline: ContinuousClock.Instant) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            guard let self, let args = self.pendingLoad else { return }
            if self.layerIsSized || ContinuousClock.now >= deadline {
                if !self.layerIsSized { Self.log.notice("opening with the layer still unsized") }
                self.pendingLoad = nil
                self.command(args)
            } else {
                self.loadWhenSized(deadline: deadline)
            }
        }
    }

    /// The layer's drawable was given a new size. mpv's MoltenVK context
    /// only learns the size when the output is configured, so the picture
    /// would otherwise stay drawn for the old one — stretched across the
    /// new frame after a rotation, or 1×1 and black after an open that beat
    /// the layout. A reconfigure is had by changing the decoded picture's
    /// parameters: a crop two rows short, then none, each of which the
    /// output is configured for as the next frame goes through — and while
    /// paused no frame would, so a seek to where it is pushes one. Settled
    /// a moment, since a live resize lays out every frame.
    func surfaceResized() {
        resizeNudge?.cancel()
        let nudge = DispatchWorkItem { [weak self] in self?.reconfigureOutput() }
        resizeNudge = nudge
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: nudge)
    }

    private func reconfigureOutput() {
        #if os(iOS)
        // The sample layer scales what it is given to its bounds itself.
        if output == .sampleBuffer { return }
        #endif
        guard handle != nil, queue.sync(execute: { fileIsOpen }),
              let w = getInt("width"), let h = getInt("height"), w > 2, h > 2 else { return }
        Self.log.info("surface resized to \(Int(self.layer.bounds.width), privacy: .public)×\(Int(self.layer.bounds.height), privacy: .public); reconfiguring the output")
        let paused = getFlag("pause")
        setString("video-crop", "\(w)x\(h - 2)+0+0")
        if paused { command(["seek", "0", "relative+exact"]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self, self.handle != nil, self.queue.sync(execute: { self.fileIsOpen }) else { return }
            self.setString("video-crop", "")
            if self.getFlag("pause") { self.command(["seek", "0", "relative+exact"]) }
        }
    }

    func stop() {
        pendingLoad = nil
        command(["stop"])
    }

    /// Nothing: a `loadfile … replace` cuts straight from the old file to the
    /// new, so the old one is left playing — see `.playsOnWhileReloading`.
    /// The model drops what it reports meanwhile.
    func quiesce() {}

    func handOver(to request: EngineLoadRequest, at target: Double) async -> Bool { false }

    func prepare(url: URL, headers: [String: String]) -> (any PreparedStream)? { nil }

    // MARK: - Transport

    func play() { setFlag("pause", false) }
    func pause() { setFlag("pause", true) }

    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard queue.sync(execute: { fileIsOpen }) else { return false }
        command(["seek", String(format: "%.3f", max(0, seconds)), "absolute"])
        return true
    }

    @discardableResult
    func seek(by seconds: Double) -> Bool {
        guard queue.sync(execute: { fileIsOpen }) else { return false }
        command(["seek", String(format: "%.3f", seconds), "relative"])
        return true
    }

    var rate: Double {
        get { getDouble("speed") }
        set { setDouble("speed", newValue) }
    }

    /// 0…1 here; mpv's own scale is 0…100.
    var volume: Double {
        get { getDouble("volume") / 100 }
        set { setDouble("volume", min(max(newValue, 0), 1) * 100) }
    }

    var isMuted: Bool {
        get { getFlag("mute") }
        set { setFlag("mute", newValue) }
    }

    var transport: EngineTransport {
        if getFlag("pause") { return .paused }
        if getFlag("paused-for-cache") || !queue.sync(execute: { sawFirstFrame }) { return .waiting }
        return .playing
    }

    var clock: Double? {
        guard queue.sync(execute: { fileIsOpen }) else { return nil }
        let value = getDouble("time-pos")
        return value.isFinite ? value : nil
    }

    func jumpToLiveEdge(margin: Double) -> Bool { false }

    /// Open the audio output afresh against the route that exists now.
    func rebuildAudio() async {
        command(["ao-reload"])
    }

    // MARK: - Tracks

    var tracks: [EngineTrack] { queue.sync { lastTracks } }

    /// The audio track, by mpv id; nil for none.
    func selectAudio(trackID: Int?) { setString("aid", trackID.map(String.init) ?? "no") }
    /// The subtitle track, by mpv id; nil for none.
    func selectSubtitle(trackID: Int?) { setString("sid", trackID.map(String.init) ?? "no") }

    /// Add a subtitle file by URL and make it the one shown.
    func addExternalSubtitle(url: URL, language: String?, title: String?) {
        var args = ["sub-add", url.absoluteString, "select"]
        if title != nil || language != nil { args.append(title ?? "") }
        if let language { args.append(language) }
        command(args)
    }

    // MARK: - The picture and the sound

    /// Seconds; positive plays the sound later than the picture. Applied to
    /// whatever is playing, at once.
    var audioDelay: Double {
        get { getDouble("audio-delay") }
        set { setDouble("audio-delay", newValue) }
    }

    var subtitleStyle = SubtitleStyle() {
        didSet { applySubtitleStyle() }
    }

    /// Size and background from Settings, as mpv's subtitle options; the
    /// position lifts the words clear of a bar while one is up.
    private func applySubtitleStyle() {
        let scale = max(0.5, min(2.0, subtitleStyle.size / 100))
        setString("sub-scale", String(format: "%.2f", scale))
        setString("sub-font", "Helvetica Neue")
        setString("sub-color", "#FFFFFFFF")
        switch subtitleStyle.background {
        case .outline:
            setString("sub-border-style", "outline-and-shadow")
            setString("sub-outline-size", "2.5")
            setString("sub-outline-color", "#FF000000")
            setString("sub-shadow-offset", "0")
        case .shadow:
            setString("sub-border-style", "outline-and-shadow")
            setString("sub-outline-size", "0")
            setString("sub-shadow-offset", "2")
            setString("sub-shadow-color", "#C0000000")
        case .box:
            setString("sub-border-style", "background-box")
            setString("sub-back-color", "#BF000000")
            setString("sub-outline-size", "0")
            setString("sub-shadow-offset", "0")
        }
        // Where the bottom of a subtitle sits, as a percentage of the
        // picture's height: 100 is mpv's own place at the foot of it.
        setDouble("sub-pos", subtitleStyle.raised ? 70 : 100)
    }

    /// `panscan` at 1 grows a picture whose shape isn't the screen's until it
    /// covers it, cropping what spills over, and at 0 shows the whole frame.
    /// A property of the player rather than of a file, so it holds for
    /// everything opened after.
    var framing: Framing = .fit {
        didSet {
            #if os(iOS)
            // Fit and Fill on the sample layer are its gravity; a zoom or an
            // aspect override sends the picture through gpu-next instead.
            let gravity: AVLayerVideoGravity = framing == .fill ? .resizeAspectFill : .resizeAspect
            if let sampleLayer, sampleLayer.videoGravity != gravity { sampleLayer.videoGravity = gravity }
            #endif
            switch framing {
            case .fit:
                setDouble("panscan", 0)
                setDouble("video-zoom", 0)
                setString("video-aspect-override", "-1")
            case .fill:
                setDouble("panscan", 1)
                setDouble("video-zoom", 0)
                setString("video-aspect-override", "-1")
            case .zoom(let factor):
                setDouble("panscan", 0)
                setDouble("video-zoom", log2(max(factor, 0.01)))
                setString("video-aspect-override", "-1")
            case .aspect(let ratio):
                setDouble("panscan", 0)
                setDouble("video-zoom", 0)
                setString("video-aspect-override", String(format: "%.6f", ratio))
            }
        }
    }

    var picture = PictureAdjustment.neutral {
        didSet {
            setDouble("brightness", picture.brightness)
            setDouble("contrast", picture.contrast)
            setDouble("saturation", picture.saturation)
            setDouble("gamma", picture.gamma)
        }
    }

    /// Dynamic range compression on the sound: quiet dialogue up, explosions
    /// down, for a room where the volume has to stay low. FFmpeg's
    /// `dynaudnorm`, through mpv's `lavfi` filter — which the FFmpeg inside
    /// MPVKit's LGPL build does not carry (its audio filters are `aformat`,
    /// `aresample`, `atempo`, `volume` and the equalizers), so on that build
    /// the filter is refused as it is set and the chain is cleared again,
    /// with `nightModeUnavailableReason` saying so. Never left half-set: a
    /// filter chain that fails to build silences the sound.
    var nightMode = false {
        didSet { applyNightMode() }
    }

    /// Set against a running audio chain, where a filter the build lacks
    /// is refused on the spot and cleared again. Before a file is open the
    /// option would be taken without a word and fail as the chain is built,
    /// which can leave the sound off — so with no file open the wish waits
    /// for `MPV_EVENT_FILE_LOADED`, which applies it then.
    private func applyNightMode() {
        guard queue.sync(execute: { fileIsOpen }) else { return }
        if nightMode {
            if command(["af", "set", Self.nightModeFilter]) < 0 {
                command(["af", "clr", ""])
                if nightModeUnavailableReason == nil {
                    Self.log.notice("night mode refused: this build's FFmpeg has no audio compressor")
                }
                nightModeUnavailableReason = Self.noCompressorReason
            }
        } else {
            command(["af", "clr", ""])
        }
    }

    private static let nightModeFilter = "lavfi=[dynaudnorm=f=150:g=15:p=0.9]"
    private static let noCompressorReason = "This build of the mpv engine has no audio compressor (FFmpeg's dynaudnorm is not in MPVKit's LGPL build), so night mode cannot be applied."

    /// Why night mode cannot be applied, once a try has shown it can't.
    private(set) var nightModeUnavailableReason: String?

    /// Which profile is on. Applied on every set, not only on a change: a
    /// fresh handle has neither on, and the model's first set is what puts
    /// one there. The profile on is restored before the other goes on, so
    /// every option ends up as mpv's own default plus the one profile.
    var powerProfile: PowerProfile = .quality {
        didSet { applyPowerProfile() }
    }

    private func applyPowerProfile() {
        guard appliedProfile != powerProfile else { return }
        if let appliedProfile {
            command(["apply-profile", Self.profileName(appliedProfile), "restore"])
        }
        command(["apply-profile", Self.profileName(powerProfile)])
        appliedProfile = powerProfile
        Self.log.info("profile \(Self.profileName(self.powerProfile), privacy: .public) applied")
    }

    private static func profileName(_ profile: PowerProfile) -> String {
        switch profile {
        case .battery: "aquarium-battery"
        case .quality: "aquarium-quality"
        }
    }

    /// Off, the video track is let go of: decode and draw stop, the sound
    /// carries on. What keeps the picture from coming back black after the
    /// background is picking the track up again on the way in.
    var pictureDecode = true {
        didSet {
            #if os(iOS)
            // A sample layer that was handed frames as the app went behind
            // another is left failed, and shows nothing more until flushed.
            if pictureDecode, let sampleLayer, sampleLayer.status == .failed || sampleLayer.requiresFlushToResumeDecoding {
                sampleLayer.flush()
            }
            #endif
            setString("vid", pictureDecode ? "auto" : "no")
        }
    }

    #if os(iOS)
    /// Draw into the other layer, on the running stream. mpv remakes its
    /// output when `vo` or `wid` changes, so the video track is let go of
    /// first — with it gone there is no output to remake against the wrong
    /// layer — and picked up again once both are set, which seeks to where
    /// it was. The sound plays on throughout. Main thread.
    func setOutput(_ wanted: MPVOutput) {
        guard wanted != output, let sampleLayer, let handle else { return }
        let track = getString("vid") ?? "auto"
        let restore = queue.sync(execute: { fileIsOpen }) && pictureDecode && track != "no"
        if restore { setString("vid", "no") }
        let driver = wanted == .sampleBuffer ? "avfoundation" : "gpu-next"
        let status = mpv_set_property_string(handle, "vo", driver)
        if status < 0 {
            // A libmpv without the patch: stay on gpu-next for good.
            Self.log.error("mpv vo=\(driver, privacy: .public): \(String(cString: mpv_error_string(status)), privacy: .public)")
            if restore { setString("vid", track) }
            return
        }
        let surface: AnyObject = wanted == .sampleBuffer ? sampleLayer : layer
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(surface).toOpaque()))
        mpv_set_property(handle, "wid", MPV_FORMAT_INT64, &wid)
        output = wanted
        if wanted == .sampleBuffer { sampleLayer.flush() }
        if restore { setString("vid", track) }
        Self.log.info("drawing into the \(wanted == .sampleBuffer ? "sample-buffer" : "Metal", privacy: .public) layer")
    }

    /// The selected video track's Dolby Vision profile, read on `queue` as
    /// the track list changes. Profile 5 has no HDR10 base: its colours are
    /// right only after libplacebo's reshaping, which only gpu-next does.
    private func checkDolbyVision() {
        let count = getInt("track-list/count") ?? 0
        var profile: Int?
        for i in 0..<count where getString("track-list/\(i)/type") == "video" && getFlag("track-list/\(i)/selected") {
            profile = getInt("track-list/\(i)/dolby-vision-profile")
        }
        let needs = profile == 5
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requiresMetal != needs else { return }
            self.requiresMetal = needs
            if needs { Self.log.info("Dolby Vision profile 5: drawing through gpu-next") }
            self.onRequirementsChanged?()
        }
    }

    /// The sample layer's clock follows the playhead; see `MPVSampleBufferLayer`.
    private func moveClock(position: Double? = nil) {
        guard let sampleLayer else { return }
        let at = position ?? lastPosition.value
        guard at >= 0 else { return }
        sampleLayer.follow(position: at, running: !clockHeld.paused && !clockHeld.buffering)
    }
    #endif

    /// How frames are timed. Given the rate the display is known to be
    /// running at, `display-resample` times them to its refreshes and nudges
    /// the audio to keep up — no frame held for an extra refresh or dropped
    /// to catch the sound up. Without one, whatever the profile on says:
    /// `display-resample` against the display mpv detects under
    /// `[aquarium-quality]`, the audio clock under `[aquarium-battery]`.
    func setDisplayRefreshRate(_ hertz: Double?) {
        if let hertz {
            setString("display-fps-override", String(format: "%.6f", hertz))
            setString("video-sync", "display-resample")
        } else {
            setString("display-fps-override", "0")
            setString("video-sync", powerProfile == .battery ? "audio" : "display-resample")
        }
    }

    #if os(iOS)
    /// A display link that draws nothing, kept only for its frame-rate
    /// preference: on a ProMotion panel it is how an app says what refresh
    /// it would like, and a 24 fps film has no use for 120 Hz.
    private var pacing: CADisplayLink?

    /// Ask the display to run at the content's frame rate while this handle
    /// draws; nil lets it go. Does nothing on a panel that is fixed at 60.
    @MainActor
    func hintContentFrameRate(_ fps: Double?) {
        pacing?.invalidate()
        pacing = nil
        guard let fps, fps > 0, UIScreen.main.maximumFramesPerSecond > 60 else { return }
        let wanted = Float(min(max(fps.rounded(), 10), Double(UIScreen.main.maximumFramesPerSecond)))
        let link = CADisplayLink(target: self, selector: #selector(pacingTick))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: wanted, maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: wanted)
        link.add(to: .main, forMode: .common)
        pacing = link
    }

    @objc private func pacingTick() {}
    #endif

    var streamFacts: EngineStreamFacts {
        var facts = EngineStreamFacts()
        if let w = getInt("dwidth"), let h = getInt("dheight"), w > 0, h > 0 {
            facts.width = w
            facts.height = h
        }
        if let bitrate = getInt("video-bitrate"), bitrate > 0 { facts.indicatedBitrate = Double(bitrate) }
        // Bytes a second the cache is reading in. Zero once it is full,
        // which says nothing about the link, so only a reading counts.
        if let speed = getInt("cache-speed"), speed > 0 { facts.observedBitrate = Double(speed) * 8 }
        facts.droppedFrames = getInt("frame-drop-count")
        facts.decoder = getString("hwdec-current")
        return facts
    }

    /// Anything else, by name — for the debug hook.
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
                fileIsOpen = true
                if nightMode { DispatchQueue.main.async { [weak self] in self?.applyNightMode() } }
                deliver(.fileLoaded)
                deliver(.chapters(readChapters()))
            case MPV_EVENT_PLAYBACK_RESTART:
                sawFirstFrame = true
                deliver(.firstFrame)
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
            #if os(iOS)
            clockHeld.paused = flag(p)
            moveClock()
            #endif
            deliver(.paused(flag(p)))
        case ("paused-for-cache", MPV_FORMAT_FLAG):
            #if os(iOS)
            clockHeld.buffering = flag(p)
            moveClock()
            #endif
            deliver(.buffering(flag(p)))
        case ("seeking", MPV_FORMAT_FLAG):
            deliver(.seeking(flag(p)))
        case ("demuxer-cache-time", MPV_FORMAT_DOUBLE):
            deliver(.cachedUntil(double(p)))
        case ("track-list", _):
            let list = readTracks()
            lastTracks = list
            #if os(iOS)
            if sampleLayer != nil { checkDolbyVision() }
            #endif
            deliver(.tracks(list))
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
        #if os(iOS)
        moveClock(position: value)
        #endif
        let now = CACurrentMediaTime()
        let jumped = abs(value - lastPosition.value) > 1
        guard jumped || now - lastPosition.at >= 0.2 else { return }
        lastPosition = (value, now)
        deliver(.position(value))
    }

    private func endFile(_ end: mpv_event_end_file) {
        let error = end.error < 0 ? String(cString: mpv_error_string(end.error)) : nil
        lastPosition = (-1, 0)
        let wasOpen = fileIsOpen
        let hadFrame = sawFirstFrame
        fileIsOpen = false
        sawFirstFrame = false
        switch end.reason {
        case MPV_END_FILE_REASON_EOF:
            deliver(.ended(.finished))
        case MPV_END_FILE_REASON_ERROR:
            // A channel that fails to open is reopened as it always was on
            // the Apple TV, where there is no reading of the stream to
            // explain it; everything else says whether it had been playing.
            deliver(.failed(EngineFailure(
                message: error, duringPlayback: loadedLive || (wasOpen && hadFrame), isSessionLoss: false
            )))
        default:
            // A `loadfile … replace` ends the file before it; that is not the
            // stream ending.
            deliver(.ended(.stopped))
        }
    }

    private func double(_ p: mpv_event_property) -> Double {
        guard let data = p.data else { return 0 }
        return data.assumingMemoryBound(to: Double.self).pointee
    }

    private func flag(_ p: mpv_event_property) -> Bool {
        guard let data = p.data else { return false }
        return data.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    private func readTracks() -> [EngineTrack] {
        let count = getInt("track-list/count") ?? 0
        return (0..<count).compactMap { i in
            let base = "track-list/\(i)/"
            guard let id = getInt(base + "id"), let type = getString(base + "type") else { return nil }
            let kind: EngineTrack.Kind
            switch type {
            case "audio": kind = .audio
            case "video": kind = .video
            case "sub": kind = .subtitle
            default: return nil
            }
            return EngineTrack(
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
                // The stream's index inside the file — what ffprobe, and so
                // Jellyfin, numbers it by. Nil for an external track.
                fileIndex: getInt(base + "ff-index"),
                externalURL: getString(base + "external-filename")
            )
        }
    }

    private func readChapters() -> [EngineChapter] {
        let count = getInt("chapter-list/count") ?? 0
        return (0..<count).map { i in
            let base = "chapter-list/\(i)/"
            let title = getString(base + "title").flatMap { $0.isEmpty ? nil : $0 }
            return EngineChapter(id: i, start: getDouble(base + "time"), title: title ?? "Chapter \(i + 1)")
        }
    }

    private func deliver(_ event: EngineEvent) {
        continuation.yield(event)
    }
}

extension MPVEngine: PlaybackEngine {}

#endif
