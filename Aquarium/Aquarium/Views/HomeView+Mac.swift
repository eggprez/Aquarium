//  Home on a Mac: the media bar as a carousel a pointer and a keyboard can
//  drive, and the button style its Play wears.
//
//  The phone pages with a swipe and the television crossfades on a timer; a
//  Mac has both a pointer and arrow keys and no swipe at all, so this one is
//  driven the way the TV app's is — chevrons at the edges under the pointer,
//  ←/→ when the bar has the keyboard, dots you can click — and the timer stops
//  while the pointer is over it, since a bar that changes title under the
//  pointer would open something other than what was pointed at.

#if os(macOS)
import AppKit
import Combine
import SwiftUI

struct HeroCarousel: View {
    let items: [BaseItem]
    /// The title on screen, kept current for whoever else wants to start it —
    /// the toolbar's Play Featured, in `HomeView`.
    @Binding var featured: BaseItem?

    @State private var index = 0
    @State private var isHovering = false
    /// The bar's own width, from which its height and everything inside it
    /// are sized. Zero until the first layout pass, when the platform's fixed
    /// height stands in.
    @State private var width: CGFloat = 0
    @FocusState private var isFocused: Bool
    /// Held in state so it belongs to the view's lifetime rather than being a
    /// fresh countdown on every redraw.
    @State private var ticker = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    /// Something that moves on its own is exactly what this setting is for.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: BaseItem? {
        items.indices.contains(index) ? items[index] : items.first
    }

    /// Tall in proportion to the window rather than a fixed strip: a 2.4:1
    /// band, which takes the top and bottom off a 16:9 backdrop rather than
    /// the middle out of it, held between a height that still fits a title
    /// and two buttons and one that doesn't push the first shelf off a
    /// laptop's screen.
    private var height: CGFloat {
        guard width > 0 else { return HeroHeader.height }
        return min(520, max(280, (width / 2.4).rounded()))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let current {
                HeroHeader(item: current, heroHeight: height, availableWidth: width)
                    .id(current.Id)
                    .transition(.opacity)
            }
            if items.count > 1 { pageDots }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(WidthReader(width: $width))
        .overlay(alignment: .leading) {
            if items.count > 1 {
                ShelfPagingButton(direction: .back) { turn(by: -1) }
                    .padding(.leading, 10)
                    .opacity(showsChevrons ? 1 : 0)
            }
        }
        .overlay(alignment: .trailing) {
            if items.count > 1 {
                ShelfPagingButton(direction: .forward) { turn(by: 1) }
                    .padding(.trailing, 10)
                    .opacity(showsChevrons ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsChevrons)
        .onHover { isHovering = $0 }
        // The bar as one stop on the Tab key, with the arrows turning it —
        // and no ring drawn round a picture the width of the window; the
        // chevrons appearing is what says it has the keyboard.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { turn(by: -1); return .handled }
        .onKeyPress(.rightArrow) { turn(by: 1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured")
        .onReceive(ticker) { _ in
            guard !reduceMotion, !isHovering, !isFocused, items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                index = (index + 1) % items.count
            }
        }
        // A fresh draw is a fresh bar: it starts at the first of the new set
        // rather than at wherever the old one had got to — which would also be
        // out of range whenever the new draw is the shorter of the two.
        .onChange(of: items.map(\.Id)) { _, _ in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { index = 0 }
        }
        .onAppear { featured = current }
        .onChange(of: current?.Id) { _, _ in featured = current }
        .task(id: items.map(\.Id)) { await prefetch() }
    }

    private var showsChevrons: Bool { isHovering || isFocused }

    /// One title along, wrapping at either end, which is what the arrows and
    /// the chevrons both do. Restarts the timer's count implicitly: the tick
    /// after a manual turn moves on from the title you chose, not the one
    /// you left.
    private func turn(by offset: Int) {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            index = (index + offset + items.count) % items.count
        }
    }

    /// Everything but the page on screen, pulled into the image cache, at the
    /// size the page on screen asked for. Without it the first turn of the
    /// bar shows a blur resolving, because `RemoteImage` only skips its
    /// placeholder when the artwork is already cached.
    private func prefetch() async {
        guard width > 0 else { return }
        let pixels = min(3840, ImageLoader.requestWidth(points: width, displayScale: NSScreen.main?.backingScaleFactor ?? 2))
        for item in items.dropFirst() {
            guard let url = Artwork.url(item, type: "Backdrop", width: pixels) else { continue }
            _ = await ImageLoader.shared.load(url)
            if Task.isCancelled { return }
        }
    }

    /// Where you are in the set, and a way to go straight there. Drawn from
    /// the accent and the secondary label so they read on either appearance,
    /// over the part of the hero that has already become the window.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { position in
                Button {
                    withAnimation(.easeInOut(duration: 0.35)) { index = position }
                } label: {
                    Capsule()
                        .fill(position == index ? Color.accentColor : Color.secondary.opacity(0.6))
                        .frame(width: position == index ? 18 : 6, height: 6)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help(HeroHeader.displayTitle(of: items[position]))
                .accessibilityLabel("Show \(HeroHeader.displayTitle(of: items[position]))")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.background.opacity(0.55), in: Capsule())
        .padding(.trailing, Metrics.gutter)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.25), value: index)
    }
}

/// The hero's Play button: a rounded rectangle in the accent colour with white
/// on it, the size of a large system button, lighter under the pointer and
/// darker while pressed. Drawn here rather than borrowed from
/// `.borderedProminent`, which loses its fill whenever the window isn't the
/// key one and left the hero with no Play button at all — see
/// `HeroHeader.actions`.
struct MacHeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Bezel(configuration: configuration)
    }

    /// A view of its own, because a style is not one: the hover has to be
    /// state, and state lives in a view.
    private struct Bezel: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .brightness(configuration.isPressed ? -0.12 : (isHovering ? 0.08 : 0))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
        }
    }
}
#endif
