//  The palette, carried over from styles.css so the two clients look like the
//  same application. The tokens keep their CSS names.

import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum Theme {
    // Dark is the app's native mode; light is the same palette inverted, as on
    // Linux. tvOS is always dark — a television is a dark room by definition,
    // and Apple's own focus engine assumes it.
    //
    // The Mac is different again: it is not painted from this palette at all.
    // Every token below becomes the system's semantic colour on macOS — the
    // window background, the label colours, the separator, and the accent the
    // user picked in System Settings ▸ Appearance — so the app is drawn from
    // the same box of colours as every other window on the desk, and so the
    // brand purple (the asset catalog's `AccentColor`) yields to a user who
    // has chosen graphite or blue. The names stay: the code that reads
    // `Theme.textDim` doesn't need to know which platform is answering.
    #if os(macOS)
    static let accent = Color.accentColor
    static let accentStrong = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.16)
    static let danger = Color.red
    static let ok = Color.green
    static let warn = Color.orange

    static let background = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    /// The fill a system list draws under the pointer: the label colour at a
    /// few percent, which is right on both appearances without a hex for each.
    static let hover = Color.primary.opacity(0.07)
    static let border = Color(nsColor: .separatorColor)
    static let text = Color(nsColor: .labelColor)
    static let textBody = Color(nsColor: .secondaryLabelColor)
    /// Secondary rather than tertiary. The tertiary label colour is the label
    /// at a quarter strength, which under a poster at subheadline size — where
    /// most of this app's `textDim` is — is a smudge rather than a line of
    /// text; the system's own media apps set their subtitles in secondary.
    static let textDim = Color(nsColor: .secondaryLabelColor)
    #else
    static let accent = Color(hex: 0x8B5CF6)
    static let accentStrong = Color(hex: 0x7C3AED)
    static let accentSoft = Color(hex: 0x8B5CF6, alpha: 0.16)
    static let danger = Color(hex: 0xEF4444)
    static let ok = Color(hex: 0x34D399)
    static let warn = Color(hex: 0xFBBF24)

    static let background = adaptive(dark: 0x0E0E14, light: 0xF7F7FB)
    static let raised = adaptive(dark: 0x16161F, light: 0xFFFFFF)
    static let hover = adaptive(dark: 0x1E1E2A, light: 0xECECF3)
    static let border = adaptive(dark: 0x262635, light: 0xDCDCE8)
    static let text = adaptive(dark: 0xECECF4, light: 0x16161F)
    static let textBody = adaptive(dark: 0xC9C9DA, light: 0x3D3D4E)
    static let textDim = adaptive(dark: 0x9A9AB0, light: 0x63637A)
    #endif

    /// A word that goes somewhere. `accent` itself is a fill colour — mid
    /// purple, which is fine under white type and thin against a near-white
    /// page at caption size — so text that leads elsewhere gets its own step:
    /// lighter than the accent in the dark theme, darker in the light one. On
    /// the Mac a link is the accent colour, as it is in every other window.
    #if os(macOS)
    static let link = Color.accentColor
    #else
    static let link = adaptive(dark: 0xA78BFA, light: 0x6D28D9)
    #endif

    /// What a card shows before its artwork arrives and where the server has
    /// none at all.
    ///
    /// Adaptive like every other surface: hard-coded to the dark ramp this was a
    /// near-black slab on the light theme's near-white page, which is what every
    /// skeleton tile and every artwork-less poster showed.
    ///
    /// On the Mac it is the quaternary label colour — the fill `.redacted` and
    /// the system's own loading placeholders use — so an empty tile is the same
    /// grey as an empty tile anywhere else, in both appearances and under any
    /// wallpaper the window's vibrancy lets through.
    static let placeholderFill = LinearGradient(
        colors: [placeholderTop, placeholderBottom],
        startPoint: .top, endPoint: .bottom
    )

    /// The bars a skeleton draws where text is going to be. `raised` is white in
    /// light mode, which on the page colour is invisible.
    #if os(macOS)
    static let skeletonBar = Color(nsColor: .quaternaryLabelColor)
    private static let placeholderTop = Color(nsColor: .quaternaryLabelColor)
    private static let placeholderBottom = Color(nsColor: .quaternaryLabelColor).opacity(0.7)
    #else
    static let skeletonBar = adaptive(dark: 0x22222E, light: 0xE0E0EA)
    private static let placeholderTop = adaptive(dark: 0x1C1C28, light: 0xE7E7F0)
    private static let placeholderBottom = adaptive(dark: 0x14141D, light: 0xDCDCE8)
    #endif

    /// The hero keeps the dark ramp in both themes, unlike every other
    /// placeholder. It is a three-hundred-point band with white text and white
    /// controls laid over it — that text is white because it normally sits on a
    /// backdrop, and a light slab behind it would leave the title of anything
    /// the server has no artwork for invisible.
    static let heroPlaceholderFill = LinearGradient(
        colors: [Color(hex: 0x1C1C28), Color(hex: 0x14141D)],
        startPoint: .top, endPoint: .bottom
    )

    /// Twelve points is an iOS card. The Mac's own media apps round their
    /// artwork at six to eight, and anything rounder reads as a widget.
    #if os(macOS)
    static let cornerRadius: CGFloat = 8
    #else
    static let cornerRadius: CGFloat = 12
    #endif

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        #if os(tvOS)
        return Color(hex: dark)
        #elseif canImport(UIKit)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark_ = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: dark_ ? dark : light))
        })
        #endif
    }
}

// MARK: - Shared modifiers

/// The card treatment used by every poster and row tile.
///
/// On the Mac the hairline goes: a stroke around every poster is what made a
/// grid of them read as a page of web cards. The one exception is dark mode,
/// where artwork with a black edge sinks into a near-black window and a
/// one-pixel separator is what keeps the tiles' shapes.
struct CardChrome: ViewModifier {
    var radius: CGFloat = Theme.cornerRadius
    #if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(strokeStyle, lineWidth: lineWidth)
            )
    }

    private var strokeStyle: AnyShapeStyle {
        #if os(macOS)
        colorScheme == .dark ? AnyShapeStyle(.separator) : AnyShapeStyle(.clear)
        #else
        AnyShapeStyle(Theme.border.opacity(0.6))
        #endif
    }

    private var lineWidth: CGFloat {
        #if os(macOS)
        colorScheme == .dark ? 1 : 0
        #else
        0.5
        #endif
    }
}

extension View {
    func cardChrome(radius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(CardChrome(radius: radius))
    }

    /// Paints the navigation bar in the app's own background colour rather than
    /// the system's grey.
    ///
    /// Everything on a page is drawn from the palette in `Theme`; the bar above
    /// it was the one surface still coming from UIKit's defaults, which in dark
    /// mode is a different, greyer black than the page it sits on. Screens whose
    /// artwork runs under the bar — Home, and a detail page's hero — don't want
    /// this: they want no bar background at all.
    @ViewBuilder
    func paletteBar() -> some View {
        #if os(iOS)
        toolbarBackground(Theme.background, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Applies the user's theme choice. `auto` leaves it to the system.
    @ViewBuilder
    func themed(_ pref: ThemePref) -> some View {
        switch pref {
        case .auto: self
        case .light: self.preferredColorScheme(.light)
        case .dark: self.preferredColorScheme(.dark)
        }
    }
}

/// A small pill of status text — the HTTPS/HTTP marker, sync state, quality.
///
/// On the Mac a pill is a web idiom. The same fact is a coloured dot and a
/// word, the way the Network pane in System Settings says "Connected": the
/// colour carries the state and the text stays text.
struct StatusPill: View {
    enum Tone { case neutral, ok, warn, bad }
    var text: String
    var tone: Tone = .neutral

    var body: some View {
        #if os(macOS)
        HStack(spacing: 5) {
            Circle()
                .fill(colour)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        #else
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(colour.opacity(0.16), in: Capsule())
            .foregroundStyle(colour)
        #endif
    }

    private var colour: Color {
        switch tone {
        case .neutral: Theme.textDim
        case .ok: Theme.ok
        case .warn: Theme.warn
        case .bad: Theme.danger
        }
    }
}
