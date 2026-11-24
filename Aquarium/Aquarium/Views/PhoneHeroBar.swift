//  PhoneHeroBar.swift
//  Aquarium
//
//  The phone's bar on the two pages that open on artwork: Home and a title
//  page. The artwork runs up to the top of the screen and the bar floats on
//  it — the logo, the wordmark and Search / Refresh on Home, the way back on
//  a title.
//
//  Since 2026-11-22 (the user's pick of five ideas, after a bar
//  with nothing behind it at all proved unreadable over the page): at the
//  very top of the page the bar is bare — white glyphs with a soft shadow,
//  no blur, no band. As the page moves off its top (`BarScroll`) the
//  wordmark fades away and each button takes a disc of the system's glass,
//  the tab bar's own material, so nothing bare ever sits on a row of text.
//  A title's name no longer comes into the bar: there is nothing for it to
//  stand on.
//
//  A foldable floats it too, in the frame `AppTopBar` takes
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
    /// How far the page has moved off its top, which is what the wordmark's
    /// fade and the buttons' discs follow.
    let scroll: BarScroll

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

    /// How far off its top the page is when the buttons take their discs.
    static let liftAt: CGFloat = 0.25

    private var bar: CGFloat { Metrics.topBar }
    /// Bare glyphs are white with a shadow; a disc brings its own colour.
    private var ink: Color { .white }
    private var shadow: Color { .black.opacity(0.45) }
    /// Whether the page has left its top, which is when the buttons take
    /// their glass discs.
    private var lifted: Bool { Self.lifted(progress: scroll.progress) }
    static func lifted(progress: CGFloat) -> Bool { progress > liftAt }
    /// The wordmark is whole at the top of the page and gone by the time
    /// the page has moved `BarScroll.distance`.
    static func brandOpacity(progress: CGFloat) -> CGFloat { max(0, min(1, 1 - progress)) }

    var body: some View {
        content
            // The glyphs' hit areas are 44 points tall and fill the bar.
            .modifier(TopBarFrame(height: bar, row: 44, bottom: 0))
            .animation(.easeInOut(duration: 0.25), value: lifted)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home(let search, let refresh, let isRefreshing):
            HStack(spacing: 6) {
                brand
                    .opacity(Self.brandOpacity(progress: scroll.progress))
                Spacer(minLength: 12)
                glyphButton("magnifyingglass", label: "Search", action: search)
                    .accessibilityIdentifier(TestID.Home.search)
                refreshButton(isRefreshing: isRefreshing, action: refresh)
                    .accessibilityIdentifier(TestID.Home.refresh)
            }
        case .detail:
            HStack(spacing: 4) {
                glyphButton("chevron.backward", label: "Back") {
                    if let popPage { popPage() } else { dismiss() }
                }
                .accessibilityIdentifier(TestID.Detail.back)
                Spacer(minLength: 0)
            }
        }
    }

    /// A button's glyph: bare and white at the top of the page, on a disc
    /// of glass (`barButtonDisc`) once the page has moved. Both are drawn
    /// and one shows, so the change is a fade and the 44-point hit area
    /// never moves.
    private func glyph(_ symbol: String) -> some View {
        ZStack {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink)
                .shadow(color: shadow, radius: 4)
                .opacity(lifted ? 0 : 1)
            if lifted {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .barButtonDisc(size: 36)
                    .transition(.opacity)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
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
        Button(action: action) { glyph(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func refreshButton(isRefreshing: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isRefreshing {
                ProgressView().tint(lifted ? Theme.text : ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } else {
                glyph("arrow.clockwise")
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .accessibilityLabel("Refresh")
    }
}

#endif
