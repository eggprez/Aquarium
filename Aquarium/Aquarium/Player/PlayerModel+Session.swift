//  The audio session, the route coming and going, and the app's lifecycle —
//  the parts of the model that are about the device rather than about
//  Jellyfin. Split out of `PlayerModel` so its one AVFoundation import is for
//  `AVAudioSession` only, which is one of the uses allowed outside `Engine/`.
//
//  Turning a television off while something is playing takes the audio route
//  with it: HDMI is the only output an Apple TV has, and when the set sleeps
//  the route disappears and the session is deactivated out from under us.
//  Waking the set brings the picture straight back; the sound does not,
//  because an interrupted session stays inactive until somebody activates it
//  again. These notifications are the ways the route can be lost, and each is
//  answered by putting the session back and asking the engine to rebuild its
//  audio against the route that now exists.

import Foundation
import OSLog
import QuartzCore

#if os(iOS) || os(tvOS)
import AVFoundation
#endif
#if os(tvOS)
import AVKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension PlayerModel {
    func configureAudioSession(activate: Bool = true) {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        // .moviePlayback keeps dialogue intelligible on a phone speaker and is
        // what lets AirPlay and the lock-screen transport work at all.
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        audioSessionConfigured = true
        if activate { try? session.setActive(true) }
        #endif
    }

    /// Every start of playback comes through here, so a title started before
    /// the first frame's deferred setup has run — from Siri, say — still
    /// gets the category before the session goes active.
    func reactivateAudioSession() {
        #if os(iOS) || os(tvOS)
        guard audioSessionConfigured else {
            configureAudioSession(activate: true)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// Put the session back and give the engine a reason to rebuild its audio.
    func recoverAudio(rebuildingComposition: Bool = false) {
        #if os(iOS) || os(tvOS)
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        audioWasInterrupted = false
        // A composition has no audible selection group to re-select in, so
        // the only way to repair a dead audio tap on one is to build the
        // stream again — which is what reopening at the current position does.
        if rebuildingComposition, audioDelayIsApplied {
            rebuildForAudioDelay()
            return
        }
        Task { await engine?.rebuildAudio() }
        #endif
    }

    func observeAudioRoute() {
        #if os(iOS) || os(tvOS)
        let centre = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        routeObservers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.audioWasInterrupted = true
                case .ended:
                    self.recoverAudio(rebuildingComposition: true)
                @unknown default:
                    self.recoverAudio(rebuildingComposition: true)
                }
            }
        })

        routeObservers.append(centre.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
                case .newDeviceAvailable, .routeConfigurationChange, .override, .categoryChange:
                    // `oldDeviceUnavailable` is deliberately not here: it fires
                    // as the route is going away, and reactivating against a
                    // route that no longer exists is how you get a session that
                    // thinks it is live and isn't.
                    self.recoverAudio(rebuildingComposition: true)
                default:
                    break
                }
            }
        })

        routeObservers.append(centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.configureAudioSession(activate: false)
                self.recoverAudio(rebuildingComposition: true)
            }
        })
        #endif

        #if os(tvOS)
        // The television renegotiating HDMI for a frame-rate switch can leave
        // the audio output stalled, or holding the last mode's latency.
        routeObservers.append(NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchEnd, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.info("display mode switch ended; restarting audio output")
                self?.recoverAudio()
                self?.holdScreenAwake(reassert: true)
            }
        })
        #endif
    }

    /// The sleep timer's deadline, checked on every return to the foreground:
    /// the timer's own task cannot wake while the process is suspended.
    func observeForeground() {
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

    /// Going to the background takes the drawable away from mpv; the video
    /// track is let go of on the way out and picked up on the way back, which
    /// keeps the picture from coming back black. On an iPhone or iPad the
    /// sound carries on meanwhile through the audio session — what
    /// AVPlayer's `continuesIfPossible` policy does for free — and only the
    /// Apple TV, which has no background audio to speak of, pauses.
    func observeLifecycle() {
        #if canImport(UIKit)
        let centre = NotificationCenter.default
        routeObservers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                #if os(tvOS)
                self.pause()
                #endif
                #if os(iOS)
                // The floating window is showing the frames: keep drawing.
                if self.pictureInPictureHoldsPicture { return }
                #endif
                if self.engine?.kind == .mpv {
                    Self.log.info("background: mpv picture decode off")
                    self.engine?.pictureDecode = false
                }
            }
        })
        routeObservers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                if self.engine?.kind == .mpv {
                    self.engine?.pictureDecode = true
                    #if os(tvOS)
                    self.recoverAudio()
                    #endif
                }
                self.checkSleepDeadline()
                self.holdScreenAwake(reassert: true)
            }
        })
        #endif
    }

    #if os(tvOS)
    /// Keeps the screensaver off while something is playing. AVPlayer did this
    /// itself; mpv draws into a layer tvOS knows nothing about, so the idle
    /// timer ran on through a film.
    func holdScreenAwake(reassert: Bool = false) {
        let playing = isActive && !isPaused
        let application = UIApplication.shared
        if application.isIdleTimerDisabled != playing || (reassert && playing) {
            application.isIdleTimerDisabled = playing
        }
    }

    /// On every position tick: writes the flag again every ten seconds.
    func keepScreenAwake() {
        let now = CACurrentMediaTime()
        guard now - lastAwakeAssert >= 10 else { return }
        lastAwakeAssert = now
        holdScreenAwake(reassert: true)
    }
    #elseif os(iOS)
    /// Keeps the screen from locking while mpv plays. AVPlayer holds it on
    /// by itself (`preventsDisplaySleepDuringVideoPlayback`); mpv's Metal
    /// layer is nothing the system counts as video, so the phone dimmed and
    /// locked through a film. Through `ScreenAwake` so the Downloads page's
    /// own hold and this one don't let go of each other.
    func holdScreenAwake(reassert: Bool = false) {
        ScreenAwake.hold("player", isActive && !isPaused && engine?.kind == .mpv)
    }

    /// On every position tick, so a switch of engine mid-stream is caught.
    func keepScreenAwake() { holdScreenAwake() }
    #elseif os(macOS)
    /// The Mac twin: an activity that keeps the display awake while mpv
    /// plays, for the same reason as on the phone.
    func holdScreenAwake(reassert: Bool = false) {
        let wanted = isActive && !isPaused && engine?.kind == .mpv
        if wanted, displayAwake == nil {
            displayAwake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if !wanted, let activity = displayAwake {
            ProcessInfo.processInfo.endActivity(activity)
            displayAwake = nil
        }
    }

    func keepScreenAwake() { holdScreenAwake() }
    #else
    func holdScreenAwake(reassert: Bool = false) {}
    #endif

    /// The device's thermal state and Low Power Mode, and on a Mac whether
    /// it is on its battery. All arrive off the main thread. The Apple TV is
    /// on mains and never throttles a stream for power, but the thermal state
    /// still picks mpv's render profile.
    func observePower() {
        var names = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        #if os(macOS)
        PowerSource.startObserving()
        names.append(PowerSource.changed)
        #endif
        for name in names {
            routeObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.powerStateChanged() }
            })
        }
        #if DEBUG
        PowerDebugHook.start()
        #endif
    }

    func powerStateChanged() {
        refreshPowerProfile()
        guard adaptsQuality, prefs.powerAwareQuality, isActive, !isLocal, !isExternal else { return }
        let power = devicePower
        if adaptive.notePower(thermal: power.thermal, lowPower: power.lowPower, currentBitrate: currentBitrate) {
            maybeAdapt()
        }
    }

    /// Whether Auto steers this player's quality. Never on an Apple TV: its
    /// Settings hold one quality rather than offering Auto, and nothing there
    /// turns the synced switch off — so the iPhone's Auto was quietly
    /// stepping down the TV's streams, overruling the rung picked on it.
    var adaptsQuality: Bool {
        #if os(tvOS)
        false
        #else
        prefs.adaptiveQuality
        #endif
    }

    /// What the speed check opens a fresh stream at: nil to leave the opening
    /// as it was, or the rung (nil inside, the original) that fits. Only for a
    /// title nobody chose a quality for, under Auto, with the setting on.
    /// Autoplay's next episode inherits the rung the last one ended on and
    /// carries its memory forward; the next episode started by hand reuses
    /// that memory; a server on the home network is opened as it always was.
    /// Everything else is timed, with the quality pill turning meanwhile.
    func speedCheckedOpening(for item: BaseItem, options opts: StreamOptions, meta: StartMeta) async -> Int?? {
        guard adaptsQuality, prefs.speedCheck, !opts.live else { return nil }
        let interface = client.lastInterface
        if meta.inherited {
            if let memory = speedMemory, memory.itemId != item.Id, memory.isFollowed(by: item, interface: interface) {
                speedMemory = memory.carried(to: item)
            }
            return nil
        }
        guard opts.maxBitrate == nil, !opts.bitrateIsChosen else { return nil }
        let source = item.MediaSources?.first
        if let memory = speedMemory, memory.isFollowed(by: item, interface: interface) {
            speedMemory = memory.carried(to: item)
            Self.log.info("speed check: next episode, reusing \(Int(memory.bitsPerSecond / 1000)) kbps")
            return .some(Quality.fitting(memory.bitsPerSecond, source: source))
        }
        guard await !SpeedCheck.serverIsHome(prefs.session?.server, interface: interface) else {
            Self.log.info("speed check: server is on the home network, skipped")
            return nil
        }
        isCheckingSpeed = true
        defer { isCheckingSpeed = false }
        guard let measured = await client.measureThroughput() else {
            Self.log.info("speed check: no answer, opening as usual")
            return nil
        }
        speedMemory = SpeedMemory(item: item, bitsPerSecond: measured, interface: interface)
        let fit = Quality.fitting(measured, source: source)
        Self.log.info("speed check: \(Int(measured / 1000)) kbps, opening at \(Quality.label(for: fit), privacy: .public)")
        return .some(fit)
    }

    /// The connection's speed as far as anyone knows it now: the check's,
    /// and what the engine is actually seeing arrive, whichever is lower.
    /// Only with the speed check on — its step-downs jump to what fits.
    var knownThroughput: Double? {
        guard prefs.speedCheck, let item else { return nil }
        let remembered = speedMemory?.itemId == item.Id ? speedMemory?.bitsPerSecond : nil
        let observed = engine?.streamFacts.observedBitrate
        return [remembered, observed].compactMap { $0 }.filter { $0 > 0 }.min()
    }

    /// The rung a stream may open at right now, given the device's state.
    var powerCapBitrate: Int? {
        guard adaptsQuality, prefs.powerAwareQuality else { return nil }
        let power = devicePower
        return AdaptiveQuality.powerRung(thermal: power.thermal, lowPower: power.lowPower)
    }

    /// What the device says about its power right now: the thermal state,
    /// Low Power Mode, and on a Mac whether it is on its battery. Read in one
    /// place so a debug build can stand in for a device that is hot or
    /// unplugged — see `PowerDebugHook`.
    var devicePower: (thermal: ProcessInfo.ThermalState, lowPower: Bool, onBattery: Bool) {
        let info = ProcessInfo.processInfo
        var power = (thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled, onBattery: PowerSource.onBattery)
        #if DEBUG
        if let thermal = PowerDebugHook.thermal { power.thermal = thermal }
        if let lowPower = PowerDebugHook.lowPower { power.lowPower = lowPower }
        if let onBattery = PowerDebugHook.onBattery { power.onBattery = onBattery }
        #endif
        return power
    }
}

#if DEBUG
/// Debug builds only: a device that is hot, in Low Power Mode or on its
/// battery, faked from the Mac, since a simulator is never any of them and
/// the Mac's own state can't be changed from a script without a password.
///
///     xcrun simctl spawn booted notifyutil -p aquarium.debug.thermal.serious
///     notifyutil -p aquarium.debug.battery.on          # the Mac app
///
/// Names: `thermal.<nominal|fair|serious|critical|real>`, `lowpower.<on|off|real>`,
/// `battery.<on|off|real>`; `real` hands the reading back to the device. Each
/// runs the same `powerStateChanged` a real change would, so the render
/// profile and the quality cap follow.
@MainActor
enum PowerDebugHook {
    static var thermal: ProcessInfo.ThermalState?
    static var lowPower: Bool?
    static var onBattery: Bool?
    private static var registered = false

    private static let names = [
        "thermal.nominal", "thermal.fair", "thermal.serious", "thermal.critical", "thermal.real",
        "lowpower.on", "lowpower.off", "lowpower.real",
        "battery.on", "battery.off", "battery.real",
    ]

    static func start() {
        guard !registered else { return }
        registered = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in names {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    guard let raw = name?.rawValue as String? else { return }
                    Task { @MainActor in PowerDebugHook.received(raw) }
                },
                "aquarium.debug.\(name)" as CFString,
                nil, .deliverImmediately
            )
        }
    }

    private static func received(_ full: String) {
        let parts = full.split(separator: ".")
        guard parts.count == 4 else { return }
        let value = String(parts[3])
        switch parts[2] {
        case "thermal":
            thermal = switch value {
            case "nominal": .nominal
            case "fair": .fair
            case "serious": .serious
            case "critical": .critical
            default: nil
            }
        case "lowpower": lowPower = value == "real" ? nil : value == "on"
        case "battery": onBattery = value == "real" ? nil : value == "on"
        default: return
        }
        PlayerModel.log.notice("power hook: \(full, privacy: .public)")
        PlayerModel.shared.powerStateChanged()
    }
}
#endif
