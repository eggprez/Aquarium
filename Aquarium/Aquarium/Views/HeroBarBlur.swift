//  HeroBarBlur.swift
//  Aquarium
//
//  The blur behind a bar that floats over artwork: the phone's own bars
//  (`PhoneHeroBar`, `AppTopBar`, through `BarBlur`), the iPad's
//  (`padBarSurface`) and the Mac's window toolbar over Home's hero
//  (`HeroHeader`).
//
//  It has no tint of its own, so it takes the colours of whatever is under
//  it instead of laying a grey or white band across the picture. What tint
//  there is on iOS is the system's: a sheet of its glass lies over the blur
//  (`BarGlass`), so the bar follows the person's Liquid Glass setting the
//  way the tab bar does. At the
//  very top of the page it covers only the strip the clock (or the window's
//  title) sits in, so the top of a poster is left alone; as soon as the page
//  moves off its top it reaches down past the bar's row, so a title never
//  sits on a line of text.
//
//  It is one blur that grows as the page leaves its top (`BarScroll`), not
//  two that crossfade: a system blur that is partly transparent stops
//  blurring, which is what made the old crossfade stutter. It follows the
//  finger on a slow drag and takes its time on a flick.
//
//  Built on the backdrop's variable-blur filter — the one the system draws
//  under its own bars — which neither UIKit nor AppKit publishes, so it is
//  looked up by name. Should the name ever stop answering, the view keeps
//  the ordinary blur and fades it out with a gradient mask instead, which is
//  paler but still keeps the bar readable.

import SwiftUI
import QuartzCore

#if os(iOS)
import UIKit

/// The blur under an iPad's floating bar: at the top of the page only the
/// top `strip`; once the page has moved, down past the bar's row. Drawn
/// from the top of the screen, so a bar below the status bar hands its
/// `topInset` in to reach up through it.
struct HeroBarBlur: View {
    let scroll: BarScroll
    let topInset: CGFloat
    /// How much of the top stays blurred at the top of the page.
    let strip: CGFloat
    var bar: CGFloat = Metrics.topBar

    var body: some View {
        let height = topInset + bar + BarBlur.overhang + BarBlur.margin
        VariableBlur(radius: 5, fullUntil: 0.35, clearBottom: height - strip,
                     scrolled: BarBlur.scrolled, progress: scroll.progress)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .top)
            .offset(y: -topInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The surface under a bar that is fitted below the status bar and whose
/// fill reaches up through it — `AppTopBar` and `PhoneHeroBar`. Drawn as
/// the bar's background with the safe area ignored, so it is as tall as the
/// status bar and the bar together without either being measured (the
/// measuring is what `AppTopBar` documents as unreliable). At the top of a
/// page that opens on artwork (`progress` 0) only the status bar's strip is
/// blurred: the bar's own row, `barHeight` from the bottom, stays clear but
/// for 12 points of easing, and what sits in it is white with a shadow. Once
/// the page has moved (`progress` 1) the whole of it is, reaching `overhang`
/// past the bar so a title never sits on a line of text. In between it is
/// the same blur part-way there.
///
/// Where the status bar takes little or no room above the bar — a
/// foldable's front screen and its inside screen held sideways, where the
/// safe area's top is zero, and a phone with a 20-point status bar — that
/// strip would be a sliver or nothing, and the bar had no blur at all until
/// the page scrolled. So the blur is never shorter than `least`: there it
/// starts at the top of the screen all the same and eases out behind the
/// bar's row.
struct BarBlur: View {
    /// How far the page has moved off its top, 0 to 1 — `BarScroll`. A bar
    /// with no artwork under it is at 1 from the start.
    let progress: CGFloat
    /// The bar's own row — how much of the bottom stays clear over artwork.
    let barHeight: CGFloat

    /// The shortest the blur over artwork gets: what an iPhone 17 has under
    /// its clock (59 points of status bar, less the 12 of easing), so that
    /// phone and the taller ones are as they were.
    static let least: CGFloat = 47
    /// How far past the bar's foot the blur reaches once the page has moved.
    static let overhang: CGFloat = 22
    /// Room kept under the blur, inside its view, for the view to fade out
    /// in — see `VariableBlurView.fadeLength`.
    static let margin: CGFloat = VariableBlurView.fadeLength
    /// The blur once the page has moved: down to `overhang` past the bar,
    /// and stronger.
    static let scrolled = BlurShape(radius: 18, fullUntil: 0.75, clearBottom: margin)

    var body: some View {
        VariableBlur(radius: 5, fullUntil: 0.35, clearBottom: barHeight + 12 + Self.overhang + Self.margin,
                     least: Self.least, scrolled: Self.scrolled, progress: progress)
            .padding(.bottom, -(Self.overhang + Self.margin))
            .ignoresSafeArea(edges: [.top, .horizontal])
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `BarBlur` for a bar over a page that scrolls. Its own view so that the
/// first points of a scroll redraw this and not the page around it.
struct ScrollingBarBlur: View {
    let scroll: BarScroll
    let barHeight: CGFloat

    var body: some View {
        BarBlur(progress: scroll.progress, barHeight: barHeight)
    }
}

/// A blur that is strongest at the top and gone by the bottom, with no tint
/// of its own: what shows through is the page's own colours, smeared.
struct VariableBlur: UIViewRepresentable {
    var radius: CGFloat
    /// How far down, as a fraction of the blurred height, the blur stays at
    /// full strength before easing out.
    var fullUntil: CGFloat = 0.45
    /// Points at the bottom of the view left unblurred: the blur eases out
    /// above them. Zero blurs to the bottom edge. For a view that is handed
    /// its height by the layout and only knows how much of it to leave
    /// clear — see `BarBlur`.
    var clearBottom: CGFloat = 0
    /// The fewest points blurred from the top, whatever `clearBottom` asks
    /// for (or the whole view, if it is shorter than this) — see `BarBlur`.
    var least: CGFloat = 0
    /// What the blur becomes as `progress` goes from 0 to 1, if it changes
    /// at all — see `BlurShape.blend`.
    var scrolled: BlurShape? = nil
    var progress: CGFloat = 0

    func makeUIView(context: Context) -> BarBlurSurface {
        let view = BarBlurSurface(blur: VariableBlurView(radius: radius, fullUntil: fullUntil,
                                                         clearBottom: clearBottom, least: least))
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: BarBlurSurface, context: Context) {
        view.blur.set(radius: radius, fullUntil: fullUntil, clearBottom: clearBottom, least: least,
                      scrolled: scrolled, progress: progress)
        view.setNeedsLayout()
    }
}

/// The blur and, over it, a sheet of the system's glass cut to the same
/// shape.
///
/// The glass is what makes the bar answer to Settings › Appearance › Liquid
/// Glass (clear at one end, tinted at the other, and Reduce Transparency and
/// Increase Contrast with it): the tab bar at the foot of the screen is that
/// material, and a bar that stayed a bare blur was clear above a tab bar the
/// person had asked to be nearly solid. There is no published way to read
/// that setting, so the bar does not try to: the system's own material is
/// laid in and does the following itself, live.
///
/// A sibling of the blur, not a child: a visual-effect view refuses
/// subviews of its own.
final class BarBlurSurface: UIView {
    let blur: VariableBlurView
    /// Nil before iOS 26, which has no glass (and no setting for it).
    private(set) var glass: UIVisualEffectView?
    private let glassFade = FadeMask()
    /// Where the glass starts to fade and where it is gone, as fractions of
    /// its own height — for the tests.
    var glassStops: (from: CGFloat, to: CGFloat) { glassFade.stops }

    init(blur: VariableBlurView) {
        self.blur = blur
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // The glass is wider and taller than the bar (`BarGlass.outset`).
        clipsToBounds = true
        addSubview(blur)
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.isUserInteractionEnabled = false
            glass.mask = glassFade
            addSubview(glass)
            self.glass = glass
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        blur.layoutIfNeeded()
        guard let glass else { return }
        let drawn = blur.drawn
        glass.isHidden = bounds.height <= 0 || drawn.reach <= 0
        guard !glass.isHidden else { return }
        glass.frame = BarGlass.frame(in: bounds)
        glassFade.frame = glass.bounds
        let stops = BarGlass.stops(drawn, height: bounds.height)
        glassFade.set(from: stops.from, to: stops.to)
    }
}

/// Where the glass over a bar's blur lies and how it fades.
enum BarGlass {
    /// How far the glass runs past the bar at the top and the sides, so the
    /// bright rim the system draws round a piece of glass is off the screen
    /// and what shows is a plain sheet.
    static let outset: CGFloat = 24
    /// How far past the blur's reach the glass is gone. Shorter than the
    /// blur's own fade (`VariableBlurView.fadeLength`): tinted glass is
    /// nearly solid, and a solid edge drawn out past the blur would sit on
    /// sharp artwork.
    static let tail: CGFloat = 12

    static func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: -outset, y: -outset, width: bounds.width + outset * 2, height: bounds.height + outset)
    }

    /// The glass is whole where the blur is at full strength and fades with
    /// it — fractions of the glass's own height, which is `outset` taller
    /// than the bar's.
    static func stops(_ drawn: BlurShape.Drawn, height: CGFloat) -> (from: CGFloat, to: CGFloat) {
        let whole = height + outset
        guard whole > 0 else { return (1, 1) }
        let from = outset + drawn.reach * drawn.fullUntil
        let to = min(outset + drawn.reach + tail, whole)
        return (min(from, to) / whole, to / whole)
    }
}

final class VariableBlurView: UIVisualEffectView {
    private var rest: BlurShape
    private var scrolled: BlurShape?
    private var progress: CGFloat = 0
    private var lastHeight: CGFloat = -1
    private(set) var usesFilter = false

    init(radius: CGFloat, fullUntil: CGFloat, clearBottom: CGFloat = 0, least: CGFloat = 0) {
        rest = BlurShape(radius: radius, fullUntil: fullUntil, clearBottom: clearBottom, least: least)
        super.init(effect: UIBlurEffect(style: .regular))
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// New numbers from the view that owns this one: a bar's row changes
    /// height when a foldable changes pose, and the blur above it follows;
    /// `progress` changes with every point of the first few a page scrolls.
    func set(radius: CGFloat, fullUntil: CGFloat, clearBottom: CGFloat, least: CGFloat = 0,
             scrolled: BlurShape? = nil, progress: CGFloat = 0) {
        let rest = BlurShape(radius: radius, fullUntil: fullUntil, clearBottom: clearBottom, least: least)
        guard rest != self.rest || scrolled != self.scrolled || progress != self.progress else { return }
        self.rest = rest
        self.scrolled = scrolled
        self.progress = progress
        lastHeight = -1
        setNeedsLayout()
    }

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

    /// How many points from the top are blurred: what is left above the
    /// clear part, and never fewer than `least` (or the whole view, if it
    /// is shorter than that).
    static func reach(height: CGFloat, clearBottom: CGFloat, least: CGFloat) -> CGFloat {
        BlurShape(radius: 0, fullUntil: 0, clearBottom: clearBottom, least: least).reach(height: height)
    }

    /// The blur this view draws as it is laid out and as far as the page
    /// has scrolled.
    var drawn: BlurShape.Drawn {
        BlurShape.blend(rest, scrolled, progress: progress, height: bounds.height)
    }

    /// How many points from the top it blurs.
    var reach: CGFloat { drawn.reach }

    /// The view itself fades out below the blur. The filter leaves what it
    /// does not blur a little soft (it works on a smaller copy of what is
    /// behind it, more so the stronger the blur), so where the view stopped
    /// there was a line across the artwork: soft above, sharp below. It
    /// never showed while the strong blur only came in over a plain page.
    /// Faded over `fadeLength` points, the soft part gives way to the
    /// picture with no line.
    static let fadeLength: CGFloat = 24
    private let fade = FadeMask()
    /// Where the view starts to fade and where it is gone, as fractions of
    /// its height — for the tests.
    var fadeStops: (from: CGFloat, to: CGFloat) { fade.stops }

    private func apply() {
        // Nothing above the clear part and no least: nothing to blur.
        let drawn = self.drawn
        isHidden = drawn.reach <= 0
        guard drawn.reach > 0 else { return }
        let endAt = min(drawn.reach / bounds.height, 1)
        if let backdrop = subviews.first,
           VariableBlurFilter.apply(to: backdrop.layer, radius: drawn.radius, height: bounds.height,
                                    fullUntil: drawn.fullUntil * endAt, endAt: endAt) {
            for sub in subviews.dropFirst() { sub.alpha = 0 }
            usesFilter = true
            fade.frame = bounds
            fade.set(from: drawn.reach / bounds.height,
                     to: min(drawn.reach + Self.fadeLength, bounds.height) / bounds.height)
            if mask !== fade { mask = fade }
        } else {
            usesFilter = false
            mask = nil
            layer.mask = VariableBlurFilter.fallbackMask(bounds: bounds, fullUntil: drawn.fullUntil * endAt, endAt: endAt)
        }
    }
}

/// A mask that is opaque down to one point and clear from another — see
/// `VariableBlurView.fadeLength`.
final class FadeMask: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private(set) var stops: (from: CGFloat, to: CGFloat) = (1, 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as? CAGradientLayer
        gradient?.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
        set(from: 1, to: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(from: CGFloat, to: CGFloat) {
        let start = min(max(from, 0), 1), end = min(max(to, start), 1)
        stops = (start, end)
        // At once: the layer's own half-second ease would trail the finger.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (layer as? CAGradientLayer)?.locations = [0, start, end, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
    }
}
#endif

#if os(macOS)
import AppKit

/// The Mac's blur, pinned under the window's toolbar: at the top of the
/// page only the toolbar's strip, with a little shade so the window's title
/// reads on a bright poster; once the page has moved, down past the toolbar.
struct HeroBarBlur: View {
    let scroll: BarScroll
    /// No artwork under the toolbar at all, so the whole blur from the start.
    var whole = false
    /// The toolbar's height.
    let topInset: CGFloat

    /// How far past the toolbar's foot the blur reaches once the page has moved.
    static let overhang: CGFloat = 22
    /// Room kept under the blur, inside its view, for the view to fade out
    /// in — see `VariableBlurView.fadeFoot`.
    static let margin: CGFloat = 24
    static let scrolled = BlurShape(radius: 18, fullUntil: 0.7, clearBottom: margin)

    var body: some View {
        let progress = whole ? 1 : scroll.progress
        VariableBlur(radius: 6, fullUntil: 0.4, clearBottom: Self.overhang + Self.margin,
                     scrolled: Self.scrolled, progress: progress, fadeLength: Self.margin)
            .frame(height: topInset + Self.overhang + Self.margin)
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset)
                    .opacity(1 - progress)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A blur that is strongest at the top and gone by the bottom, with no tint
/// of its own — the Mac's counterpart of the iOS one, for the hero under a
/// window toolbar that has no surface of its own.
struct VariableBlur: NSViewRepresentable {
    var radius: CGFloat
    var fullUntil: CGFloat = 0.45
    /// Points at the bottom of the view left unblurred.
    var clearBottom: CGFloat = 0
    /// What the blur becomes as `progress` goes from 0 to 1 — see
    /// `BlurShape.blend`.
    var scrolled: BlurShape? = nil
    var progress: CGFloat = 0

    /// How much of the view's foot fades out — `VariableBlurView.fadeFoot`.
    var fadeLength: CGFloat = 0

    func makeNSView(context: Context) -> VariableBlurView {
        let view = VariableBlurView(radius: radius, fullUntil: fullUntil)
        view.fadeLength = fadeLength
        view.set(clearBottom: clearBottom, scrolled: scrolled, progress: progress)
        return view
    }

    func updateNSView(_ view: VariableBlurView, context: Context) {
        view.fadeLength = fadeLength
        view.set(clearBottom: clearBottom, scrolled: scrolled, progress: progress)
    }
}

/// The system's within-window blur with its backdrop's filter swapped for
/// the variable one, and its tint layers emptied — the same surgery the iOS
/// view does. Falls back to that blur with a gradient mask.
final class VariableBlurView: NSVisualEffectView {
    private var rest: BlurShape
    private var scrolled: BlurShape?
    private var progress: CGFloat = 0
    private var lastHeight: CGFloat = -1
    /// Whether the backdrop layer and its filter were both found.
    private(set) var usesFilter = false

    init(radius: CGFloat, fullUntil: CGFloat) {
        rest = BlurShape(radius: radius, fullUntil: fullUntil)
        super.init(frame: .zero)
        blendingMode = .withinWindow
        material = .headerView
        state = .active
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// How much of the bottom to leave clear, and how far the page has
    /// scrolled toward the `scrolled` blur — `progress` changes with every
    /// point of the first few a page scrolls.
    func set(clearBottom: CGFloat, scrolled: BlurShape?, progress: CGFloat) {
        guard clearBottom != rest.clearBottom || scrolled != self.scrolled || progress != self.progress else { return }
        rest.clearBottom = clearBottom
        self.scrolled = scrolled
        self.progress = progress
        lastHeight = -1
        apply()
    }

    /// The blur this view draws as it is laid out and as far as the page
    /// has scrolled.
    var drawn: BlurShape.Drawn {
        BlurShape.blend(rest, scrolled, progress: progress, height: bounds.height)
    }

    /// Passes made before AppKit had built the effect's layers: it builds
    /// them after the first layout, so the first few find nothing.
    private var attempts = 0

    override func layout() {
        super.layout()
        layer?.mask?.frame = bounds
        fadeFoot()
        apply()
    }

    /// How much of the view's foot fades out, if any — see `fadeFoot`.
    var fadeLength: CGFloat = 0 {
        didSet { if fadeLength != oldValue { fadedSize = .zero; needsLayout = true } }
    }
    private var fadedSize: CGSize = .zero

    /// The view fades out over its last `fadeLength` points. The filter
    /// leaves what it does not blur a little soft, more so the stronger the
    /// blur, so where the view stopped there was a line across the artwork
    /// (soft above, sharp below) — the iOS view's `FadeMask`, done here
    /// with the effect view's own mask image, once per size.
    private func fadeFoot() {
        guard fadeLength > 0, bounds.height > fadeLength, bounds.width > 0 else {
            if maskImage != nil { maskImage = nil; fadedSize = .zero }
            return
        }
        guard bounds.size != fadedSize else { return }
        fadedSize = bounds.size
        let start = fadeLength / bounds.height
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            // Clear at the foot (the image's origin), opaque from `start` up.
            NSGradient(colorsAndLocations: (NSColor.clear, 0), (NSColor.black, start), (NSColor.black, 1))?
                .draw(in: rect, angle: 90)
            return true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard bounds.height > 0, let root = layer else { return }
        guard let backdrop = Self.backdrop(in: root) else {
            // Not built yet: look again on the next turn of the run loop,
            // and settle for the masked blur only after a few tries.
            attempts += 1
            if attempts < 6 {
                DispatchQueue.main.async { [weak self] in self?.apply() }
            } else if layer?.mask == nil {
                usesFilter = false
                let drawn = self.drawn
                let endAt = min(max(drawn.reach, 1) / bounds.height, 1)
                layer?.mask = VariableBlurFilter.fallbackMask(bounds: bounds, fullUntil: drawn.fullUntil * endAt, endAt: endAt)
            }
            return
        }
        // The tint comes back whenever AppKit rebuilds the layers (a change of
        // appearance or of key window), and so may the system's own filter,
        // so both are checked on every pass.
        Self.clearTint(in: root, keeping: backdrop)
        let current = (backdrop.filters?.first as? NSObject)?.value(forKey: "type") as? String
        guard bounds.height != lastHeight || current != "variableBlur" else { return }
        lastHeight = bounds.height
        // Never nothing: a toolbar not yet measured would leave no strip,
        // and a hidden effect view does not build the layers this needs.
        let drawn = self.drawn
        let endAt = min(max(drawn.reach, 1) / bounds.height, 1)
        if VariableBlurFilter.apply(to: backdrop, radius: drawn.radius, height: bounds.height,
                                    fullUntil: drawn.fullUntil * endAt, endAt: endAt) {
            usesFilter = true
            layer?.mask = nil
        } else {
            usesFilter = false
            layer?.mask = VariableBlurFilter.fallbackMask(bounds: bounds, fullUntil: drawn.fullUntil * endAt, endAt: endAt)
        }
    }

    private static func backdrop(in layer: CALayer) -> CALayer? {
        if NSStringFromClass(type(of: layer)).contains("Backdrop") { return layer }
        for sub in layer.sublayers ?? [] { if let found = backdrop(in: sub) { return found } }
        return nil
    }

    /// Everything the effect view draws over its backdrop: the material's
    /// colour and the grain.
    private static func clearTint(in layer: CALayer, keeping backdrop: CALayer) {
        for sub in layer.sublayers ?? [] where sub !== backdrop {
            if backdrop.isDescendant(of: sub) {
                clearTint(in: sub, keeping: backdrop)
            } else {
                sub.opacity = 0
            }
        }
        if layer !== backdrop { layer.backgroundColor = nil }
    }
}

private extension CALayer {
    func isDescendant(of ancestor: CALayer) -> Bool {
        var current = superlayer
        while let layer = current {
            if layer === ancestor { return true }
            current = layer.superlayer
        }
        return false
    }
}
#endif

#if os(iOS) || os(macOS)
/// How far a page has moved off its top, for the blur under its bar: 0 at
/// the top, 1 once it has scrolled `distance` points, and every step
/// between while it is on the way, so the blur grows rather than switches.
///
/// It is paced as well as placed. On a slow drag the blur keeps to the
/// finger; a flick covers `distance` in a frame or two, and a blur that kept
/// to that snapped from one to the other, so `progress` never moves faster
/// than the whole way in `swing` seconds and catches the page up after.
///
/// An object the page owns and only the blur reads, so those first points
/// of scrolling redraw the blur and not the page.
@Observable
final class BarScroll {
    /// Points of scrolling over which the blur goes from the strip under
    /// the clock to the whole bar. Long enough to be seen growing; short
    /// enough that it is whole well before anything on the page (a hero's
    /// title is the nearest thing, over two hundred points down) can reach
    /// the bar.
    static let distance: CGFloat = 96
    /// The least time the blur takes to go the whole way, however fast the
    /// page moved.
    static let swing: TimeInterval = 0.5

    /// What the blur draws.
    private(set) var progress: CGFloat = 0
    /// Where the page says it should be; `progress` is on its way there.
    @ObservationIgnored private(set) var target: CGFloat = 0
    @ObservationIgnored private var ticker: BarScrollTicker?

    deinit { ticker?.stop() }

    /// `offset` is how far the page has scrolled, in points.
    func set(offset: CGFloat) {
        target = Self.progress(offset: offset)
        guard target != progress else { return }
        if ticker == nil {
            ticker = BarScrollTicker { [weak self] elapsed in self?.advance(by: elapsed) }
        }
    }

    /// Moves `progress` toward where the page is by as much as `seconds`
    /// allows. The ticker calls this once a frame until it has arrived.
    func advance(by seconds: TimeInterval) {
        let next = Self.step(from: progress, toward: target, seconds: seconds)
        if next != progress { progress = next }
        if progress == target {
            ticker?.stop()
            ticker = nil
        }
    }

    /// 0 at the top of the page and 1 at `distance`, eased at both ends so
    /// the blur neither starts nor stops with a jolt.
    static func progress(offset: CGFloat) -> CGFloat {
        let t = min(max(offset / distance, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// `current` moved toward `target`, no further than `seconds` out of
    /// `swing` of the whole way.
    static func step(from current: CGFloat, toward target: CGFloat, seconds: TimeInterval) -> CGFloat {
        let most = CGFloat(max(seconds, 0) / swing)
        let gap = target - current
        return abs(gap) <= most ? target : current + (gap < 0 ? -most : most)
    }
}

/// Calls back once a frame with the seconds since the last one, until
/// stopped: the screen's own refresh on iOS, a timer on the Mac. In the
/// run loop's common modes, so it keeps going while a finger is scrolling.
private final class BarScrollTicker: NSObject {
    private let tick: (TimeInterval) -> Void
    private var last = CACurrentMediaTime()
    #if os(iOS)
    private var link: CADisplayLink?
    #else
    private var timer: Timer?
    #endif

    init(tick: @escaping (TimeInterval) -> Void) {
        self.tick = tick
        super.init()
        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
        #else
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(fire), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        #endif
    }

    func stop() {
        #if os(iOS)
        link?.invalidate()
        link = nil
        #else
        timer?.invalidate()
        timer = nil
        #endif
    }

    @objc private func fire() {
        let now = CACurrentMediaTime()
        // A frame's worth at most: a stall should not be made up in one go.
        let elapsed = min(now - last, 1.0 / 20)
        last = now
        tick(elapsed)
    }
}

/// Keeps a `BarScroll` up to date with a scroll view. iOS 18's and macOS
/// 15's scroll geometry; before them it stays at the top of the page and
/// the blur stays the thin one.
struct BarScrollWatcher: ViewModifier {
    let scroll: BarScroll

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scroll.set(offset: offset)
            }
        } else {
            content
        }
    }
}

/// One blur: how strong, how far down it stays at full strength (a fraction
/// of what it covers), and how much it covers — everything above
/// `clearBottom`, and never fewer than `least` points.
struct BlurShape: Equatable {
    var radius: CGFloat
    var fullUntil: CGFloat
    var clearBottom: CGFloat = 0
    var least: CGFloat = 0

    /// How many points from the top of a view this tall are blurred.
    func reach(height: CGFloat) -> CGFloat {
        max(height - clearBottom, min(least, height))
    }

    /// A blur as it is drawn in a view of a known height.
    struct Drawn: Equatable {
        var radius: CGFloat
        var fullUntil: CGFloat
        var reach: CGFloat
    }

    /// `rest` at `progress` 0, `scrolled` at 1, and evenly between: the
    /// radius, the reach and the full-strength part all move together, so
    /// the blur grows rather than one giving way to another.
    static func blend(_ rest: BlurShape, _ scrolled: BlurShape?, progress: CGFloat, height: CGFloat) -> Drawn {
        let from = Drawn(radius: rest.radius, fullUntil: rest.fullUntil, reach: rest.reach(height: height))
        guard let scrolled else { return from }
        let t = min(max(progress, 0), 1)
        let to = Drawn(radius: scrolled.radius, fullUntil: scrolled.fullUntil, reach: scrolled.reach(height: height))
        return Drawn(radius: from.radius + (to.radius - from.radius) * t,
                     fullUntil: from.fullUntil + (to.fullUntil - from.fullUntil) * t,
                     reach: from.reach + (to.reach - from.reach) * t)
    }
}

/// The private filter, and the mask both versions fall back to.
enum VariableBlurFilter {
    /// The backdrop's variable blur, masked to be full strength down to
    /// `fullUntil` of the height and gone at `endAt` of it (the bottom, by
    /// default; anything below `endAt` is left as it is). Nil if the class
    /// or the filter type is no longer there.
    static func make(radius: CGFloat, height: CGFloat, fullUntil: CGFloat, endAt: CGFloat = 1) -> NSObject? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = type.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                  .takeUnretainedValue() as? NSObject,
              let mask = mask(height: height, fullUntil: fullUntil, endAt: endAt) else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(name, forKey: "name")
        return filter
    }

    /// The name the filter goes by on its layer, for changing it in place.
    static let name = "variableBlur"

    /// Puts the blur on a backdrop layer, or changes the one already there.
    /// A layer that has the filter is changed through its key path rather
    /// than handed a new one, since this runs on every point of the first
    /// few a page scrolls. False if the filter is no longer there to be had.
    static func apply(to layer: CALayer, radius: CGFloat, height: CGFloat, fullUntil: CGFloat, endAt: CGFloat = 1) -> Bool {
        let has = (layer.filters ?? []).contains { ($0 as? NSObject)?.value(forKey: "name") as? String == name }
        if has, let mask = mask(height: height, fullUntil: fullUntil, endAt: endAt) {
            layer.setValue(radius, forKeyPath: "filters.\(name).inputRadius")
            layer.setValue(mask, forKeyPath: "filters.\(name).inputMaskImage")
            return true
        }
        guard let filter = make(radius: radius, height: height, fullUntil: fullUntil, endAt: endAt) else { return false }
        layer.filters = [filter]
        return true
    }

    /// Opaque where the blur is at full strength, then easing to nothing. A
    /// column one pixel wide: the filter stretches it across. Top-down on
    /// both platforms — the filter reads the image in its own rows, not the
    /// view's coordinates.
    static func mask(height: CGFloat, fullUntil: CGFloat, endAt: CGFloat = 1) -> CGImage? {
        let rows = max(1, Int(height.rounded(.up)))
        guard let context = CGContext(data: nil, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        let (colors, locations) = stops(fullUntil: fullUntil, endAt: endAt, opaque: black, clear: clear)
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray, locations: locations) else { return nil }
        // A bitmap context's origin is the bottom row; the image's first
        // row is the top, so the opaque end is drawn at the far end here.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(rows)), end: .zero, options: [])
        return context.makeImage()
    }

    /// Opaque to `fullUntil`, clear from `endAt`; one stop each when the
    /// blur runs to the bottom, a fourth clear stop at the bottom when not.
    static func stops(fullUntil: CGFloat, endAt: CGFloat, opaque: CGColor, clear: CGColor) -> ([CGColor], [CGFloat]) {
        let full = min(max(fullUntil, 0), 1)
        let end = min(max(endAt, full), 1)
        if end >= 1 { return ([opaque, opaque, clear], [0, full, 1]) }
        return ([opaque, opaque, clear, clear], [0, full, end, 1])
    }

    static func fallbackMask(bounds: CGRect, fullUntil: CGFloat, endAt: CGFloat = 1) -> CAGradientLayer {
        let gradient = CAGradientLayer()
        let (colors, locations) = stops(fullUntil: fullUntil, endAt: endAt,
                                        opaque: CGColor(gray: 0, alpha: 1), clear: CGColor(gray: 0, alpha: 0))
        gradient.colors = colors
        gradient.locations = locations.map { NSNumber(value: Double($0)) }
        #if os(macOS)
        // An AppKit layer's y runs upward unless the view is flipped.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        #endif
        gradient.frame = bounds
        return gradient
    }
}
#endif
