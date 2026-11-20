//  PhoneHeroBar.swift
//  Aquarium
//
//  The phone's bar on the two pages that open on artwork: Home and a title
//  page. The artwork runs up to the top of the screen and the bar floats on
//  it — the wordmark and Search / Refresh on Home, the way back on a title —
//  with nothing behind it but a blur under the clock.
//
//  The blur has no tint of its own, so it takes the colours of whatever is
//  under it instead of laying a grey or white band across the picture, and
//  over the artwork it stops at the bottom of the status bar: enough to keep
//  the clock readable on a bright poster, and nothing over a face below it.
//  Once the artwork has scrolled out from under the bar and there is page
//  text there instead, the blur reaches down past the bar's row and the
//  glyphs turn from white to the page's colour, so the wordmark and the
//  title never sit on top of a line of text.
//
//  A foldable keeps `AppTopBar`: its status strips and the front screen's
//  dead touch strip are what that bar is built around.

#if os(iOS)
import SwiftUI

struct PhoneHeroBar: View {
    enum Page {
        case home(search: () -> Void, refresh: () -> Void, isRefreshing: Bool)
        case detail(title: String)
    }

    let page: Page
    /// Whether the artwork has gone from under the bar — see `isPast`.
    let overPage: Bool
    /// The status bar's height, which the blur reaches up through.
    let topInset: CGFloat

    @Environment(\.popPage) private var popPage
    @Environment(\.dismiss) private var dismiss

    /// Whether these pages float this bar rather than drawing `AppTopBar`.
    static var applies: Bool { Metrics.phoneLayout && !FoldState.shared.isFoldable }

    /// How far a page scrolls before the artwork has left the bar: most of
    /// Home's hero, most of a title's. Measured in points scrolled.
    static func threshold(home: Bool) -> CGFloat { home ? 420 : 330 }

    private var bar: CGFloat { Metrics.topBar }
    /// White on the artwork, the page's own colour on the page.
    private var ink: Color { overPage ? Theme.text : .white }
    private var shadow: Color { .black.opacity(overPage ? 0 : 0.45) }

    var body: some View {
        content
            .padding(.horizontal, Metrics.gutter)
            .frame(height: bar)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) { blur }
            .animation(.easeInOut(duration: 0.25), value: overPage)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home(let search, let refresh, let isRefreshing):
            HStack(spacing: 6) {
                brand
                Spacer(minLength: 12)
                glyphButton("magnifyingglass", label: "Search", action: search)
                    .accessibilityIdentifier(TestID.Home.search)
                refreshButton(isRefreshing: isRefreshing, action: refresh)
                    .accessibilityIdentifier(TestID.Home.refresh)
            }
        case .detail(let title):
            HStack(spacing: 4) {
                glyphButton("chevron.backward", label: "Back") {
                    if let popPage { popPage() } else { dismiss() }
                }
                .accessibilityIdentifier(TestID.Detail.back)
                if overPage {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .transition(.opacity)
                        .accessibilityIdentifier(TestID.Detail.barTitle)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Two blurs, crossfaded: over the artwork only the status bar's strip;
    /// over the page, down past the bar's row.
    private var blur: some View {
        ZStack(alignment: .top) {
            VariableBlur(radius: 5, fullUntil: 0.35)
                .frame(height: max(0, topInset - 12))
                .opacity(overPage ? 0 : 1)
            VariableBlur(radius: 18, fullUntil: 0.75)
                .frame(height: topInset + bar + 22)
                .opacity(overPage ? 1 : 0)
        }
        .offset(y: -topInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var brand: some View {
        HStack(spacing: 7) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .shadow(color: shadow.opacity(0.6), radius: 4)
            Wordmark(font: .title3, color: ink)
                .shadow(color: shadow.opacity(0.8), radius: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aquarium")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(TestID.Common.brand)
    }

    private func glyphButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink)
                .shadow(color: shadow, radius: 4)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func refreshButton(isRefreshing: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isRefreshing {
                    ProgressView().tint(ink)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ink)
                        .shadow(color: shadow, radius: 4)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .accessibilityLabel("Refresh")
    }
}

/// Whether a scroll view has scrolled past a point, for `PhoneHeroBar`. A
/// Bool rather than the offset, so the page redraws twice per pass under
/// the bar rather than on every frame of a scroll. iOS 18's scroll
/// geometry; before it the answer stays "no" and the bar stays white.
struct PhoneHeroScrollWatcher: ViewModifier {
    let threshold: CGFloat
    @Binding var isPast: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > threshold
            } action: { _, past in
                isPast = past
            }
        } else {
            content
        }
    }
}

/// A blur that is strongest at the top and gone by the bottom,
/// with no tint of its own: what shows through is the page's own colours,
/// smeared.
///
/// Built on the backdrop layer's variable-blur filter — the one the system
/// draws under its own bars — which UIKit does not publish, so it is looked
/// up by name. Should that name ever stop answering, the view keeps the
/// ordinary tinted blur and fades it out with a gradient mask instead, which
/// is paler but still keeps the clock and the bar readable.
struct VariableBlur: UIViewRepresentable {
    var radius: CGFloat
    /// How far down, as a fraction of the height, the blur stays at full
    /// strength before easing out.
    var fullUntil: CGFloat = 0.45

    func makeUIView(context: Context) -> VariableBlurView {
        VariableBlurView(radius: radius, fullUntil: fullUntil)
    }

    func updateUIView(_ view: VariableBlurView, context: Context) {}
}

final class VariableBlurView: UIVisualEffectView {
    private let radius: CGFloat
    private let fullUntil: CGFloat
    private var lastHeight: CGFloat = -1
    private var usesFilter = false

    init(radius: CGFloat, fullUntil: CGFloat) {
        self.radius = radius
        self.fullUntil = fullUntil
        super.init(effect: UIBlurEffect(style: .regular))
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The tint and the grain come back on a trait change; keep them out.
        if usesFilter { for sub in subviews.dropFirst() { sub.alpha = 0 } }
        guard bounds.height > 0, bounds.height != lastHeight else {
            (layer.mask as? CAGradientLayer)?.frame = bounds
            return
        }
        lastHeight = bounds.height
        apply()
    }

    private func apply() {
        if let type = NSClassFromString("CAFilter") as? NSObject.Type,
           let filter = type.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
               .takeUnretainedValue() as? NSObject,
           let backdrop = subviews.first,
           let mask = Self.mask(height: bounds.height, fullUntil: fullUntil) {
            filter.setValue(radius, forKey: "inputRadius")
            filter.setValue(mask, forKey: "inputMaskImage")
            filter.setValue(true, forKey: "inputNormalizeEdges")
            backdrop.layer.filters = [filter]
            for sub in subviews.dropFirst() { sub.alpha = 0 }
            usesFilter = true
            layer.mask = nil
        } else {
            usesFilter = false
            let gradient = CAGradientLayer()
            gradient.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            gradient.locations = [0, NSNumber(value: Double(fullUntil)), 1]
            gradient.frame = bounds
            layer.mask = gradient
        }
    }

    /// Opaque where the blur is at full strength, then easing to nothing.
    private static func mask(height: CGFloat, fullUntil: CGFloat) -> CGImage? {
        let size = CGSize(width: 1, height: max(1, height))
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colours = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                                            locations: [0, fullUntil, 1]) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        return image.cgImage
    }
}
#endif
