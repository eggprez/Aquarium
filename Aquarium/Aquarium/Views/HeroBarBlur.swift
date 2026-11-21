//  HeroBarBlur.swift
//  Aquarium
//
//  The blur behind a bar that floats over artwork: the phone's and the
//  iPad's own bars (`PhoneHeroBar`, `padBarSurface`) and the Mac's window
//  toolbar over Home's hero (`HeroHeader`).
//
//  It has no tint of its own, so it takes the colours of whatever is under
//  it instead of laying a grey or white band across the picture. Over the
//  artwork it covers only the strip the clock (or the window's title) sits
//  in; once the artwork has scrolled away and page text is under the bar
//  instead, it reaches down past the bar's row so a title never sits on a
//  line of text.
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

/// Two blurs, crossfaded: over the artwork only the top `strip`; over the
/// page, down past the bar's row. Drawn from the top of the screen, so a bar
/// below the status bar hands its `topInset` in to reach up through it.
struct HeroBarBlur: View {
    let overPage: Bool
    let topInset: CGFloat
    /// How much of the top stays blurred over artwork.
    let strip: CGFloat
    var bar: CGFloat = Metrics.topBar

    var body: some View {
        ZStack(alignment: .top) {
            VariableBlur(radius: 5, fullUntil: 0.35)
                .frame(height: strip)
                .opacity(overPage ? 0 : 1)
            VariableBlur(radius: 18, fullUntil: 0.75)
                .frame(height: topInset + bar + 22)
                .opacity(overPage ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .offset(y: -topInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A blur that is strongest at the top and gone by the bottom, with no tint
/// of its own: what shows through is the page's own colours, smeared.
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
        if let filter = VariableBlurFilter.make(radius: radius, height: bounds.height, fullUntil: fullUntil),
           let backdrop = subviews.first {
            backdrop.layer.filters = [filter]
            for sub in subviews.dropFirst() { sub.alpha = 0 }
            usesFilter = true
            layer.mask = nil
        } else {
            usesFilter = false
            layer.mask = VariableBlurFilter.fallbackMask(bounds: bounds, fullUntil: fullUntil)
        }
    }
}
#endif

#if os(macOS)
import AppKit

/// The Mac's two blurs, crossfaded, pinned under the window's toolbar: over
/// the artwork only the toolbar's strip, with a little shade so the window's
/// title reads on a bright poster; over the page, down past the toolbar.
struct HeroBarBlur: View {
    let overPage: Bool
    /// The toolbar's height.
    let topInset: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            VariableBlur(radius: 6, fullUntil: 0.4)
                .frame(height: topInset)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                }
                .opacity(overPage ? 0 : 1)
            VariableBlur(radius: 18, fullUntil: 0.7)
                .frame(height: topInset + 22)
                .opacity(overPage ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: overPage)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Whether Home has scrolled its hero out from under the toolbar, for the
/// Mac's `HeroBarBlur`. A Bool, so the page redraws twice per pass rather
/// than every frame; the threshold follows the window's width, which is what
/// the hero's height does. macOS 15's scroll geometry; before it the answer
/// stays "no" and the blur stays the thin one.
struct MacHeroScrollWatcher: ViewModifier {
    @Binding var isPast: Bool
    let threshold: (CGFloat) -> CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > threshold(g.containerSize.width)
            } action: { _, past in
                isPast = past
            }
        } else {
            content
        }
    }
}

/// A blur that is strongest at the top and gone by the bottom, with no tint
/// of its own — the Mac's counterpart of the iOS one, for the hero under a
/// window toolbar that has no surface of its own.
struct VariableBlur: NSViewRepresentable {
    var radius: CGFloat
    var fullUntil: CGFloat = 0.45

    func makeNSView(context: Context) -> VariableBlurView {
        VariableBlurView(radius: radius, fullUntil: fullUntil)
    }

    func updateNSView(_ view: VariableBlurView, context: Context) {}
}

/// The system's within-window blur with its backdrop's filter swapped for
/// the variable one, and its tint layers emptied — the same surgery the iOS
/// view does. Falls back to that blur with a gradient mask.
final class VariableBlurView: NSVisualEffectView {
    private let radius: CGFloat
    private let fullUntil: CGFloat
    private var lastHeight: CGFloat = -1
    /// Whether the backdrop layer and its filter were both found.
    private(set) var usesFilter = false

    init(radius: CGFloat, fullUntil: CGFloat) {
        self.radius = radius
        self.fullUntil = fullUntil
        super.init(frame: .zero)
        blendingMode = .withinWindow
        material = .headerView
        state = .active
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Passes made before AppKit had built the effect's layers: it builds
    /// them after the first layout, so the first few find nothing.
    private var attempts = 0

    override func layout() {
        super.layout()
        layer?.mask?.frame = bounds
        apply()
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
                layer?.mask = VariableBlurFilter.fallbackMask(bounds: bounds, fullUntil: fullUntil)
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
        if let filter = VariableBlurFilter.make(radius: radius, height: bounds.height, fullUntil: fullUntil) {
            backdrop.filters = [filter]
            usesFilter = true
            layer?.mask = nil
        } else {
            usesFilter = false
            layer?.mask = VariableBlurFilter.fallbackMask(bounds: bounds, fullUntil: fullUntil)
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
/// The private filter, and the mask both versions fall back to.
enum VariableBlurFilter {
    /// The backdrop's variable blur, masked to be full strength down to
    /// `fullUntil` of the height and gone at the bottom. Nil if the class
    /// or the filter type is no longer there.
    static func make(radius: CGFloat, height: CGFloat, fullUntil: CGFloat) -> NSObject? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = type.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                  .takeUnretainedValue() as? NSObject,
              let mask = mask(height: height, fullUntil: fullUntil) else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }

    /// Opaque where the blur is at full strength, then easing to nothing. A
    /// column one pixel wide: the filter stretches it across. Top-down on
    /// both platforms — the filter reads the image in its own rows, not the
    /// view's coordinates.
    static func mask(height: CGFloat, fullUntil: CGFloat) -> CGImage? {
        let rows = max(1, Int(height.rounded(.up)))
        guard let context = CGContext(data: nil, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [black, black, clear] as CFArray,
                                        locations: [0, fullUntil, 1]) else { return nil }
        // A bitmap context's origin is the bottom row; the image's first
        // row is the top, so the opaque end is drawn at the far end here.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(rows)), end: .zero, options: [])
        return context.makeImage()
    }

    static func fallbackMask(bounds: CGRect, fullUntil: CGFloat) -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        gradient.locations = [0, NSNumber(value: Double(fullUntil)), 1]
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
