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
//  A foldable floats it too, in the frame `AppTopBar` would have taken
//  (`TopBarFrame`): clear of the front screen's dead touch strip, on the
//  inside screen's status strip when that screen is held upright.

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

    @Environment(\.popPage) private var popPage
    @Environment(\.dismiss) private var dismiss

    /// Whether these pages float this bar: every phone, a foldable on
    /// either of its screens included. An iPad floats its own
    /// (`padBarSurface`); a Mac has the window's toolbar.
    static var applies: Bool { Metrics.phoneLayout }

    /// How far the artwork reaches up to run under the bar: through the
    /// status bar (`topInset`, measured outside the scroll view that ignores
    /// it) and the bar's own row — see `TopBarFrame.layoutHeight`.
    @MainActor
    static func bleed(topInset: CGFloat) -> CGFloat { topInset + TopBarFrame.layoutHeight() }

    /// How far a page scrolls before the artwork has left the bar: most of
    /// Home's hero, most of a title's. Measured in points scrolled.
    static func threshold(home: Bool) -> CGFloat { home ? 420 : 330 }

    private var bar: CGFloat { Metrics.topBar }
    /// White on the artwork, the page's own colour on the page.
    private var ink: Color { overPage ? Theme.text : .white }
    private var shadow: Color { .black.opacity(overPage ? 0 : 0.45) }

    var body: some View {
        content
            // The glyphs' hit areas are 44 points tall and fill the bar.
            .modifier(TopBarFrame(height: bar, row: 44, bottom: 0))
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

    /// Over the artwork only the status bar's strip; over the page, down
    /// past the bar's row — see `BarBlur`.
    private var blur: some View {
        BarBlur(overPage: overPage, barHeight: TopBarFrame.layoutHeight(height: bar))
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

#endif
