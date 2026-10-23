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

    /// Whether `LayoutOverride` counts on a device with no hinge: only in a
    /// debug build, for holding a pose on a plain simulator.
    static var overrideWithoutHinge: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

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
        creaseIsVertical: Bool = false,
        override: LayoutOverride,
        isPhoneIdiom: Bool
    ) -> DevicePose {
        // An override is for a foldable: a plain phone asking for the inside
        // would get nowhere useful, and the picker is not shown there anyway.
        // A debug build honours it without a hinge, so the tent and the
        // half-folded layouts can be held on a plain simulator that can be
        // turned sideways — the foldable's cannot be, headless.
        if override != .automatic, hinge != nil || Self.overrideWithoutHinge { return override.pose }
        let innerSignature = isPhoneIdiom && horizontal == .regular && vertical == .regular
        switch hinge {
        case .fullyOpen:
            return .inside
        case .partiallyOpen:
            // Part-open with the inside screen on is a laptop when the crease
            // runs across the screen and a book when it runs down it. The
            // book gets the open-flat layout: a picture-above-controls split
            // has no top half to give it, and two pages side by side is a
            // layout this app does not have yet.
            if horizontal == .regular { return creaseIsVertical ? .inside : .halfFolded }
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

    /// Which way the crease runs across the screen that is on, when the
    /// system reports one: down it (a book) or across it (a laptop). Read at
    /// the root by the pose provider; false where no crease is reported.
    private(set) var creaseIsVertical = false

    /// How far a page's own top bar may rise into the status strip — zero
    /// everywhere but the inside screen held upright.
    ///
    /// Held sideways the inside screen keeps its clock and battery in a pill
    /// down the trailing edge, an 84-point column. Turned upright that column
    /// becomes an 84-point strip across the top, empty but for the pill in
    /// its trailing corner, and a bar fitted under it stood a good 20 points
    /// taller than the same bar on any other iPhone. So the bars that draw
    /// themselves (`AppTopBar`, the player's title row) rise until their
    /// content sits where a phone's would, keeping clear of the trailing
    /// corner as the player already did (`PlayerTransport.foldableCornerClearance`).
    private(set) var topReclaim: CGFloat = 0

    /// Where a phone's top bar content starts: below a Dynamic Island.
    private static let phoneStatusHeight: CGFloat = 59

    private init() {}

    func safeAreaResolved(top: CGFloat, size: CGSize) {
        let upright = size.height > size.width
        let reclaim = usesInnerDisplay && upright && top > Self.phoneStatusHeight + 10
            ? top - Self.phoneStatusHeight : 0
        guard reclaim != topReclaim else { return }
        Self.log.debug("top strip \(top, format: .fixed(precision: 0)) in \(size.width, format: .fixed(precision: 0))×\(size.height, format: .fixed(precision: 0)): bars rise \(reclaim, format: .fixed(precision: 0))")
        topReclaim = reclaim
    }

    /// A hinge has been seen, or the developer is pretending one has.
    var isFoldable: Bool {
        hinge != nil || Preferences.shared.layoutOverride != .automatic
    }

    /// The hinge as far as the rest of the app is concerned: the override's
    /// idea of it when one is set, else the real one.
    var effectiveHinge: HingeStatus? {
        let override = Preferences.shared.layoutOverride
        if override != .automatic, hinge != nil || DevicePose.overrideWithoutHinge { return override.hinge }
        return hinge
    }

    func creaseResolved(vertical: Bool) {
        guard vertical != creaseIsVertical else { return }
        Self.log.debug("crease \(vertical ? "vertical" : "horizontal")")
        creaseIsVertical = vertical
    }

    func update(hinge new: HingeStatus?, angle: Double) {
        self.angle = angle
        guard new != hinge else { return }
        Self.log.debug("hinge \(String(describing: new)) at \(angle, format: .fixed(precision: 0))°")
        hinge = new
        #if os(iOS)
        FoldKeyboardGuard.shared.screenChanging()
        OrientationLock.shared.hingeChanged()
        #endif
    }

    #if os(iOS)
    /// Called by the provider once the pose has been resolved, outside any
    /// layout pass, with the display that is on.
    func poseResolved(_ pose: DevicePose) {
        let inner = pose.usesInnerDisplay
        if inner != usesInnerDisplay {
            usesInnerDisplay = inner
            FoldKeyboardGuard.shared.screenChanging()
        }
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

#if os(iOS)
/// Keeps the keyboard down across a fold.
///
/// Opening or closing the phone moves the window to the other screen, and
/// UIKit hands first responder back to whichever text field last had it —
/// a search field several pages back, say — so the keyboard rose over a
/// title page nobody was typing on. A keyboard that was down before the
/// fold and rises within a moment of it was not asked for, and is put away.
@MainActor
final class FoldKeyboardGuard {
    static let shared = FoldKeyboardGuard()

    private var keyboardUp = false
    /// Whether the keyboard was up when the screen last started to change,
    /// and when that was.
    private var fold: (keyboardWasUp: Bool, at: Date)?
    private static let window: TimeInterval = 1.5

    private init() {
        let centre = NotificationCenter.default
        centre.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FoldKeyboardGuard.shared.keyboardWillShow() }
        }
        centre.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FoldKeyboardGuard.shared.keyboardUp = false }
        }
    }

    /// Started at launch, so the keyboard's state is known before the
    /// first fold.
    func start() {}

    func screenChanging() {
        // A second report of the same fold (the hinge, then the pose)
        // keeps the first one's reading.
        if let fold, Date().timeIntervalSince(fold.at) < Self.window { return }
        fold = (keyboardUp, Date())
    }

    private func keyboardWillShow() {
        defer { keyboardUp = true }
        guard let fold, !fold.keyboardWasUp, Date().timeIntervalSince(fold.at) < Self.window else { return }
        FoldState.log.debug("keyboard rose with the fold; putting it away")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif

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
            creaseIsVertical: FoldState.shared.creaseIsVertical,
            override: Preferences.shared.layoutOverride,
            isPhoneIdiom: UIDevice.current.userInterfaceIdiom == .phone
        )
    }

    func body(content: Content) -> some View {
        let pose = resolved
        let _ = FoldKeyboardGuard.shared.start()
        content
            .environment(\.devicePose, pose)
            .modifier(HingeObserver())
            .background { CreaseObserver() }
            .background { SafeAreaObserver() }
            .onChange(of: pose, initial: true) { _, now in
                FoldState.shared.poseResolved(now)
            }
    }
}

/// Which way the system's crease runs, read from the root's geometry and
/// handed to `FoldState` outside the layout pass. The one place the
/// reserved-region API is asked about direction; `FoldSplit` asks it where
/// the crease is.
private struct CreaseObserver: View {
    var body: some View {
        GeometryReader { geo in
            let vertical = Self.creaseIsVertical(in: geo)
            Color.clear
                .onChange(of: vertical, initial: true) { _, now in
                    FoldState.shared.creaseResolved(vertical: now)
                }
        }
        .ignoresSafeArea()
    }

    private static func creaseIsVertical(in geo: GeometryProxy) -> Bool {
        if #available(iOS 27.1, *) {
            if let region = geo.reservedRegions(kind: .division).first(where: \.isActive) {
                return region.frame.height > region.frame.width
            }
        }
        return false
    }
}

/// The window's top inset and shape, for `FoldState.topReclaim`. Read where
/// the safe area is respected, which is the only place it is reported.
private struct SafeAreaObserver: View {
    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            let size = CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                              height: geo.size.height + top + geo.safeAreaInsets.bottom)
            // Read again when the display changes, too: the inset alone can
            // stay the same across a fold while what it means does not.
            let inner = FoldState.shared.usesInnerDisplay
            Color.clear
                .onChange(of: [top, size.width, size.height, inner ? 1 : 0], initial: true) { _, _ in
                    FoldState.shared.safeAreaResolved(top: top, size: size)
                }
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
