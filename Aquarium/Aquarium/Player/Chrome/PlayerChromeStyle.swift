//  The look the shared chrome is drawn in, and the numbers that change by
//  platform.
//
//  Material: Liquid Glass where the system has it (iOS 26, macOS 26), the thin
//  material with a hairline of `Theme.border` under it everywhere older. Reduce
//  Transparency gets a solid `Theme.raised` at 85 %. The player is dark
//  whatever the app's theme, so every piece of chrome is drawn in the dark
//  scheme — see `playerChromeScheme`.

import SwiftUI

// MARK: - Material

private struct PlayerMaterial<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Theme.raised.opacity(0.85), in: shape)
        } else {
            glass(content)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        #if os(iOS) || os(macOS)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            classic(content)
        }
        #else
        classic(content)
        #endif
    }

    /// Before Liquid Glass: the thin material, and a hairline so the shape
    /// has an edge over a bright picture.
    private func classic(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

extension View {
    /// What a pill, a button or a card of the chrome sits on.
    func playerMaterial<S: InsettableShape>(_ shape: S) -> some View {
        modifier(PlayerMaterial(shape: shape))
    }

    /// The chrome is dark over the picture whatever the app's theme.
    func playerChromeScheme() -> some View {
        environment(\.colorScheme, .dark)
    }
}

// MARK: - Metrics

/// The sizes that differ by platform and by the room there is. `compact` is a
/// phone (compact width) or a Mac window narrower than `narrowWindow`;
/// everything else is an iPad, a Mac window with room, or a television. A
/// Mac's glyphs are a step smaller than an iPad's at either size: a pointer
/// needs no finger-sized target, and the window can be 480×270.
enum PlayerMetrics {
    /// A Mac window narrower than this takes the compact metrics.
    static let narrowWindow: CGFloat = 640

    /// The chrome's inset from the picture's edges.
    static func edge(compact: Bool) -> CGFloat {
        #if os(tvOS)
        90
        #elseif os(macOS)
        compact ? 14 : 22
        #else
        compact ? 16 : 28
        #endif
    }

    /// The play/pause glyph in the centre cluster.
    static func centreGlyph(compact: Bool) -> CGFloat {
        #if os(tvOS)
        72
        #elseif os(macOS)
        compact ? 34 : 46
        #else
        compact ? 40 : 52
        #endif
    }

    /// The skip glyphs either side of it.
    static func skipGlyph(compact: Bool) -> CGFloat {
        #if os(tvOS)
        48
        #elseif os(macOS)
        compact ? 24 : 32
        #else
        compact ? 30 : 38
        #endif
    }

    static func clusterSpacing(compact: Bool) -> CGFloat {
        #if os(tvOS)
        90
        #elseif os(macOS)
        compact ? 40 : 64
        #else
        compact ? 52 : 76
        #endif
    }

    /// The trickplay thumbnail that rides above the scrubber.
    static func previewWidth(compact: Bool) -> CGFloat {
        #if os(tvOS)
        400
        #elseif os(macOS)
        compact ? 150 : 220
        #else
        compact ? 160 : 220
        #endif
    }

    /// How far the title row starts in from the leading edge on a Mac, so
    /// it clears the window's close, minimise and zoom buttons; nothing in
    /// full screen, where they are gone, and nothing anywhere else.
    static func titleLeadingInset(fullScreen: Bool) -> CGFloat {
        #if os(macOS)
        fullScreen ? 0 : 58
        #else
        0
        #endif
    }

    /// Whether the player window is full screen; always false off a Mac.
    @MainActor static var isFullScreen: Bool {
        #if os(macOS)
        PlayerMacState.shared.isFullScreen
        #else
        false
        #endif
    }

    /// The timeline's bar, at rest and while scrubbing.
    static let barHeight: CGFloat = 4
    static let barHeightScrubbing: CGFloat = 8
    static let thumbSize: CGFloat = 14
    static let thumbSizeScrubbing: CGFloat = 20

    /// The bottom scrim's stops: the television bar's, reused.
    static let scrimStops: [Gradient.Stop] = [
        .init(color: .black.opacity(0), location: 0),
        .init(color: .black.opacity(0.55), location: 0.45),
        .init(color: .black.opacity(0.85), location: 1),
    ]
}

// MARK: - Buttons

/// A round glyph button of the chrome: the dismiss chevron, AirPlay, Picture
/// in Picture, the centre cluster.
struct PlayerGlyphButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 20
    var weight: Font.Weight = .semibold
    var padding: CGFloat = 10
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(isOn ? Theme.link : .white)
                .frame(width: size + padding * 2, height: size + padding * 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A pill under the timeline: a glyph and a word on the material. `isOn`
/// paints the word in the accent, for Fill.
struct PlayerPill<Label: View>: View {
    var isOn = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(spacing: 6) { label() }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isOn ? Theme.link : .white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .playerMaterial(Capsule())
            .contentShape(Capsule())
    }
}

/// The press of a pill: a little smaller under the finger, nothing else.
struct PlayerPillStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
