//  How the picture is touched. The only file of the chrome that is about
//  fingers:
//
//  - a tap toggles the controls;
//  - a double-tap on the left or right skips, with a ripple and a running
//    total (the Apple TV's `skipTotal`, now shared);
//  - a pinch out fills the screen and a pinch in fits it;
//  - a long press holds 2× and lets go to the speed before it;
//  - with the Settings toggle on, a vertical drag on the left edge sets the
//    brightness and on the right edge the volume.
//
//  The drag along the timeline is the timeline's own — see `PlayerTimeline`.
//  Everything here is a SwiftUI gesture, so the same layer serves a pointer
//  on a Mac; only the brightness and volume setters are UIKit's.

#if !os(tvOS)

import SwiftUI
#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit
#endif

struct PlayerGestureLayer: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    let chrome: PlayerChromeState
    let compact: Bool
    let onTap: () -> Void
    /// A double-tap: forward on the right half, back on the left.
    let onSkip: (_ forward: Bool) -> Void

    /// Which edge a drag began on, decided from its first moves; `.none` is
    /// a drag that began somewhere else and is being ignored.
    @State private var edge: EdgeDrag?
    @State private var edgeStart: Double = 0

    private enum EdgeDrag { case none, brightness, volume }

    /// How far in from the edge a drag may begin.
    private static let edgeWidth: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                // The double-tap first: declared before the single, SwiftUI
                // holds the single back until a second tap has had its chance.
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    guard !player.isLive else { return }
                    onSkip(location.x > geo.size.width / 2)
                }
                .onTapGesture { onTap() }
                .simultaneousGesture(hold, including: holdAllowed ? .all : .subviews)
                .simultaneousGesture(pinch)
                .simultaneousGesture(edgeDrag(in: geo.size), including: prefs.edgeGestures ? .all : .subviews)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: Hold for 2×

    private var holdAllowed: Bool { prefs.holdForDoubleSpeed && !player.isLive && player.isActive }

    /// The press, then a drag of no distance that lasts until the finger
    /// lifts: the lift is the end of the sequence.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 24)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                if case .second(true, _) = value, !chrome.holdingDoubleSpeed {
                    chrome.speedBeforeHold = player.speed
                    chrome.holdingDoubleSpeed = true
                    player.speed = 2
                    if player.isPaused { player.resume() }
                }
            }
            .onEnded { _ in endHold() }
    }

    private func endHold() {
        guard chrome.holdingDoubleSpeed else { return }
        chrome.holdingDoubleSpeed = false
        player.speed = chrome.speedBeforeHold
    }

    // MARK: Pinch

    private var pinch: some Gesture {
        MagnifyGesture().onEnded { value in
            let fill: Bool
            if value.magnification > 1.15 { fill = true } else if value.magnification < 0.87 { fill = false } else { return }
            guard fill != prefs.fillScreen else { return }
            prefs.fillScreen = fill
            player.applyFraming()
        }
    }

    // MARK: Edge drags

    private func edgeDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                if edge == nil {
                    let vertical = abs(value.translation.height) > abs(value.translation.width) * 1.5
                    let x = value.startLocation.x
                    if !vertical {
                        edge = EdgeDrag.none
                    } else if x < Self.edgeWidth {
                        edge = .brightness
                        edgeStart = ScreenLevels.brightness
                    } else if x > size.width - Self.edgeWidth {
                        edge = .volume
                        edgeStart = ScreenLevels.volume
                    } else {
                        edge = EdgeDrag.none
                    }
                }
                guard let edge, edge != EdgeDrag.none else { return }
                // The height of the picture less a margin is the whole range.
                let delta = -Double(value.translation.height) / Double(max(200, size.height * 0.6))
                let level = min(max(edgeStart + delta, 0), 1)
                switch edge {
                case .brightness:
                    ScreenLevels.setBrightness(level)
                    chrome.showEdgeLevel(.init(kind: .brightness, level: level))
                case .volume:
                    ScreenLevels.setVolume(level)
                    chrome.showEdgeLevel(.init(kind: .volume, level: level))
                case .none:
                    break
                }
            }
            .onEnded { _ in
                edge = nil
                chrome.fadeEdgeLevel()
            }
    }
}

// MARK: - Brightness and volume

/// The two system levels an edge drag sets. UIKit's on an iPhone; a Mac has
/// keys for both and gets no-ops.
enum ScreenLevels {
    @MainActor static var brightness: Double {
        #if os(iOS)
        Double(screen?.brightness ?? 0.5)
        #else
        0.5
        #endif
    }

    @MainActor static func setBrightness(_ level: Double) {
        #if os(iOS)
        screen?.brightness = CGFloat(level)
        #endif
    }

    @MainActor static var volume: Double {
        #if os(iOS)
        Double(AVAudioSession.sharedInstance().outputVolume)
        #else
        PlayerModel.shared.volume
        #endif
    }

    /// The system volume, through the slider `MPVolumeView` carries: the one
    /// sanctioned way to set it.
    @MainActor static func setVolume(_ level: Double) {
        #if os(iOS)
        let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        slider?.value = Float(level)
        #else
        PlayerModel.shared.volume = level
        #endif
    }

    #if os(iOS)
    @MainActor private static let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.01
        return view
    }()

    @MainActor private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
    }
    #endif
}

#endif
