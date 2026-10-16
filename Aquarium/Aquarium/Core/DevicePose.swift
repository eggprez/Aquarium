//  Which way a foldable phone is being held, and what the app makes of it.
//
//  iPhone Duo has two screens and a hinge, and the same app has four shapes on
//  it: the front screen closed is an ordinary phone; opened flat the inside is
//  an iPad; stood up part-open on its edges, like a tent, the front screen is a
//  television; and part-open flat on a table, like a laptop, the inside is two
//  screens, a picture above the fold and controls below it.
//
//  The system says little of this directly. It reports the hinge — closed,
//  part-open, fully open — and the size classes of whichever display is on.
//  Everything else is worked out here, once, and handed down the tree as
//  `devicePose`, so that no view has to reason about hinges. A device without a
//  hinge is `.standard` from the first frame to the last, and every reader of
//  the pose treats `.standard` as "do what you always did".
//
//  The pieces: `FoldState` holds what the hinge last said (an app-wide fact
//  that non-view code — the orientation lock, the layout metrics — needs
//  synchronously); `DevicePose.resolve` merges it with the size classes; and
//  `DevicePoseProvider`, applied once at the root, is where the merge happens.

import SwiftUI
import os

#if os(iOS)
import UIKit
#endif

/// What the hinge reports, in this app's own words. The system's type is
/// iOS 27.1 and up; this one is spoken everywhere.
enum HingeStatus: Equatable, Sendable {
    case closed
    case partiallyOpen
    case fullyOpen
}

/// The shape the app takes.
enum DevicePose: String, Equatable, Sendable {
    /// Not a foldable, or nothing is known yet: today's layout on every device.
    case standard
    /// The front screen, closed: a phone.
    case front
    /// The inside screen, flat: an iPad.
    case inside
    /// The front screen, part-open and stood up in landscape: a television.
    case tent
    /// The inside screen, part-open flat on a table: picture above the fold,
    /// controls below it.
    case halfFolded

    /// The big screen is the one on, so the layout is the iPad's.
    var usesInnerDisplay: Bool { self == .inside || self == .halfFolded }

    /// Which pose the size classes alone describe, with no hinge at all, and
    /// which they describe with one.
    ///
    /// On the phone idiom, regular width *and* regular height is a shape only
    /// the inside screen has: a Plus or Pro Max phone on its side is regular
    /// width and compact height. So the inside can be told without the hinge
    /// having spoken, which it may not have by the first layout. The tent is
    /// the one pose that genuinely needs the hinge — compact both ways is also
    /// just any phone on its side in the player.
    static func resolve(
        hinge: HingeStatus?,
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?,
        override: LayoutOverride,
        isPhoneIdiom: Bool
    ) -> DevicePose {
        // An override is for a foldable: a plain phone asking for the inside
        // would get nowhere useful, and the picker is not shown there anyway.
        if override != .automatic, hinge != nil { return override.pose }
        let innerSignature = isPhoneIdiom && horizontal == .regular && vertical == .regular
        switch hinge {
        case .fullyOpen:
            return .inside
        case .partiallyOpen:
            if horizontal == .regular { return .halfFolded }
            return vertical == .compact ? .tent : .front
        case .closed:
            return .front
        case nil:
            return innerSignature ? .inside : .standard
        }
    }
}

/// The Settings › Appearance › Layout picker. Device-only; see
/// `Preferences.layoutOverride`.
enum LayoutOverride: String, CaseIterable, Sendable {
    case automatic
    case front
    case inside
    case tent
    case halfFolded

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .front: "Front"
        case .inside: "Inside"
        case .tent: "Tent"
        case .halfFolded: "Half-folded"
        }
    }

    var pose: DevicePose {
        switch self {
        case .automatic: .standard
        case .front: .front
        case .inside: .inside
        case .tent: .tent
        case .halfFolded: .halfFolded
        }
    }

    /// What the hinge would be saying for this pose, for code that keys on
    /// the hinge rather than the pose — see `OrientationLock.mask`.
    var hinge: HingeStatus? {
        switch self {
        case .automatic: nil
        case .front: .closed
        case .inside: .fullyOpen
        case .tent, .halfFolded: .partiallyOpen
        }
    }
}

/// What the hinge last said, and the two numbers the layout metrics need from
/// the display that is on.
///
/// `angle` is deliberately not observed: a part-open hinge reports every
/// degree, and publishing it would redraw the whole tree per degree. Only a
/// change of status is published.
@MainActor
@Observable
final class FoldState {
    static let shared = FoldState()

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "fold")

    /// Nil until a hinge has reported, which on a device without one is
    /// forever: nil means "not a foldable".
    private(set) var hinge: HingeStatus?

    @ObservationIgnored private(set) var angle: Double = 0

    /// Whether the display that is on is the big one. Written by the pose
    /// provider after layout, read by `Metrics` during it.
    private(set) var usesInnerDisplay = false

    /// The on display's width held upright — the smaller of its two sides.
    /// The number the phone's TV guide is laid out against; see `Metrics`.
    private(set) var portraitWidth: CGFloat = 375

    private init() {}

    /// A hinge has been seen, or the developer is pretending one has.
    var isFoldable: Bool {
        hinge != nil || Preferences.shared.layoutOverride != .automatic
    }

    /// The hinge as far as the rest of the app is concerned: the override's
    /// idea of it when one is set, else the real one.
    var effectiveHinge: HingeStatus? {
        let override = Preferences.shared.layoutOverride
        if override != .automatic, hinge != nil { return override.hinge }
        return hinge
    }

    func update(hinge new: HingeStatus?, angle: Double) {
        self.angle = angle
        guard new != hinge else { return }
        Self.log.debug("hinge \(String(describing: new)) at \(angle, format: .fixed(precision: 0))°")
        hinge = new
        #if os(iOS)
        OrientationLock.shared.hingeChanged()
        #endif
    }

    #if os(iOS)
    /// Called by the provider once the pose has been resolved, outside any
    /// layout pass, with the display that is on.
    func poseResolved(_ pose: DevicePose) {
        let inner = pose.usesInnerDisplay
        if inner != usesInnerDisplay { usesInnerDisplay = inner }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let size = scene?.screen.bounds.size {
            let width = min(size.width, size.height)
            if width != portraitWidth { portraitWidth = width }
        }
        Self.log.debug("pose \(pose.rawValue) inner=\(inner) portraitWidth=\(self.portraitWidth, format: .fixed(precision: 0))")
    }
    #endif
}

// MARK: - Environment

private struct DevicePoseKey: EnvironmentKey {
    static let defaultValue: DevicePose = .standard
}

extension EnvironmentValues {
    /// The shape the app is in — see `DevicePose`. `.standard` everywhere the
    /// provider has not been applied, which is every platform but iOS.
    var devicePose: DevicePose {
        get { self[DevicePoseKey.self] }
        set { self[DevicePoseKey.self] = newValue }
    }
}

#if os(iOS)
/// Resolves the pose from the hinge and the window's size classes and hands it
/// down. Applied once, to the root view.
private struct DevicePoseProvider: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    /// The singleton by name rather than from the environment: this sits
    /// outside the `.environment(prefs)` that the rest of the tree is inside
    /// of. Same object, and `@Observable` tracks the read either way.
    private var resolved: DevicePose {
        DevicePose.resolve(
            hinge: FoldState.shared.hinge,
            horizontal: horizontal,
            vertical: vertical,
            override: Preferences.shared.layoutOverride,
            isPhoneIdiom: UIDevice.current.userInterfaceIdiom == .phone
        )
    }

    func body(content: Content) -> some View {
        let pose = resolved
        content
            .environment(\.devicePose, pose)
            .modifier(HingeObserver())
            .onChange(of: pose, initial: true) { _, now in
                FoldState.shared.poseResolved(now)
            }
    }
}

/// The one place the system's hinge API is named.
private struct HingeObserver: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                let status: HingeStatus? = context.hinge.map { hinge in
                    switch hinge.status {
                    case .closed: .closed
                    case .partiallyOpen: .partiallyOpen
                    case .fullyOpen: .fullyOpen
                    default: .closed
                    }
                }
                FoldState.shared.update(hinge: status, angle: context.hinge?.angle.degrees ?? 0)
            }
        } else {
            content
        }
    }
}
#endif

extension View {
    /// Works out the device's pose and hands it down as `devicePose`. Once,
    /// at the root. Nothing on other platforms.
    @ViewBuilder
    func providesDevicePose() -> some View {
        #if os(iOS)
        modifier(DevicePoseProvider())
        #else
        self
        #endif
    }
}
