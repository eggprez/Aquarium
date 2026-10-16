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
        if activate { try? session.setActive(true) }
        #endif
    }

    func reactivateAudioSession() {
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// Put the session back and give the engine a reason to rebuild its audio.
    func recoverAudio(rebuildingComposition: Bool = false) {
        #if os(iOS) || os(tvOS)
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        #if !os(tvOS)
        audioWasInterrupted = false
        // A composition has no audible selection group to re-select in, so
        // the only way to repair a dead audio tap on one is to build the
        // stream again — which is what reopening at the current position does.
        if rebuildingComposition, audioDelayIsApplied {
            rebuildForAudioDelay()
            return
        }
        #endif
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
                    #if !os(tvOS)
                    self.audioWasInterrupted = true
                    #endif
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

    #if os(tvOS)
    /// Going to the background takes the drawable away from mpv; the video
    /// track is let go of on the way out and picked up on the way back, which
    /// keeps the picture from coming back black.
    func observeLifecycle() {
        let centre = NotificationCenter.default
        routeObservers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.pause()
                self.engine?.pictureDecode = false
            }
        })
        routeObservers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.engine?.pictureDecode = true
                self.recoverAudio()
                self.checkSleepDeadline()
                self.holdScreenAwake(reassert: true)
            }
        })
    }

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
    #else
    /// No screensaver to hold off where AVPlayer owns the picture.
    func holdScreenAwake(reassert: Bool = false) {}
    #endif

    #if !os(tvOS)
    /// The device's thermal state and Low Power Mode. Both arrive off the
    /// main thread.
    func observePower() {
        let names = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        for name in names {
            routeObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.powerStateChanged() }
            })
        }
    }

    func powerStateChanged() {
        guard prefs.adaptiveQuality, prefs.powerAwareQuality, isActive, !isLocal, !isExternal else { return }
        let info = ProcessInfo.processInfo
        if adaptive.notePower(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled, currentBitrate: currentBitrate) {
            maybeAdapt()
        }
    }

    /// The rung a stream may open at right now, given the device's state.
    var powerCapBitrate: Int? {
        guard prefs.adaptiveQuality, prefs.powerAwareQuality else { return nil }
        let info = ProcessInfo.processInfo
        return AdaptiveQuality.powerRung(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled)
    }
    #endif
}
