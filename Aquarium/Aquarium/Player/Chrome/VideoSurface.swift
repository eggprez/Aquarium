//  Where the picture is drawn, on every platform: a plain view hosting
//  a `CALayer` the engine renders into. For AVPlayer that is an
//  `AVPlayerLayer`; for mpv the model's `MPVMetalLayer`, which goes in the
//  same slot and is given the screen's scale so it draws at Retina size. The
//  view takes no touches or clicks of its own — the gesture layer above it
//  does — and the layer takes the view's bounds on every layout.
//
//  This replaces `AVPlayerViewController` on iOS and `AVPlayerView` on the
//  Mac, which drew the picture and a transport this app could not change.
//  Background audio needs nothing here: `AVEngine` sets
//  `audiovisualBackgroundPlaybackPolicy` to `continuesIfPossible`, so a player
//  attached to a layer carries on as sound when the app goes behind another —
//  which is what the controller did.

import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)
/// A view that gives its bounds to one video layer.
final class VideoLayerHostView: UIView {
    private(set) var videoLayer: CALayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Video"
        accessibilityTraits = .image
        // The display scale changes when the view moves between screens
        // (AirPlay mirroring, an external display): the layer is told so it
        // keeps drawing at the new screen's pixel size.
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _: UITraitCollection) in
            view.videoLayer?.contentsScale = view.traitCollection.displayScale
            view.videoLayer.map(sizeDrawable)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func host(_ layer: CALayer) {
        guard layer !== videoLayer else { return }
        videoLayer?.removeFromSuperlayer()
        videoLayer = layer
        layer.frame = bounds
        layer.contentsScale = traitCollection.displayScale
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitVideoLayer()
    }

    private func fitVideoLayer() {
        guard let videoLayer else { return }
        if videoLayer.frame != bounds {
            // No implicit animation: a rotation would otherwise show the
            // picture sliding to its new frame after the view had already
            // turned.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
        sizeDrawable(videoLayer)
    }
}
#else
/// The AppKit twin: layer-backed, so the video layer is a sublayer of the
/// view's own, and sized on every `layout` as a window is resized or taken
/// full screen. The layer is given the window's scale so a Metal layer
/// (phase 4) draws at Retina size.
final class VideoLayerHostView: NSView {
    private(set) var videoLayer: CALayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityLabel("Video")
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Clicks, scrolls and hovers belong to the SwiftUI layers above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func host(_ layer: CALayer) {
        guard layer !== videoLayer else { return }
        videoLayer?.removeFromSuperlayer()
        videoLayer = layer
        layer.frame = bounds
        layer.contentsScale = window?.backingScaleFactor ?? 2
        self.layer?.addSublayer(layer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fitVideoLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer?.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.map(sizeDrawable)
    }

    private func fitVideoLayer() {
        guard let videoLayer else { return }
        if videoLayer.frame != bounds {
            // No implicit animation: a live resize would otherwise show the
            // picture lagging a frame behind the window's edge.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
        sizeDrawable(videoLayer)
    }
}
#endif

/// A Metal layer's drawable, kept at the layer's size in pixels. Left to
/// itself a `CAMetalLayer` sizes its drawable from its bounds — until
/// something sets `drawableSize` by hand, after which it stays put. MoltenVK
/// does exactly that as it builds mpv's swapchain, so from then on a rotation
/// or a window resize changed the frame and not the drawable: the picture
/// was stretched to the new frame (a film turned sideways drawn as a band
/// across the middle), and a stream opened before the view had its bounds
/// drew into a drawable of nothing and stayed black. Set on every layout,
/// the swapchain sees the new extent and is rebuilt for it.
@MainActor
private func sizeDrawable(_ layer: CALayer) {
    guard let metal = layer as? CAMetalLayer else { return }
    let scale = metal.contentsScale
    let size = CGSize(width: (metal.bounds.width * scale).rounded(), height: (metal.bounds.height * scale).rounded())
    guard size.width > 1, size.height > 1, metal.drawableSize != size else { return }
    metal.drawableSize = size
    #if canImport(Libmpv)
    (metal as? MPVMetalLayer)?.onResize?()
    #endif
}

/// The engine's layer in the host view: the model's Metal layer while mpv is
/// playing, else an `AVPlayerLayer` made for AVPlayer if the view has none
/// or the engine has changed under it, and kept at Fit or Fill.
@MainActor
private enum VideoSurfaceWiring {
    static func attach(_ player: PlayerModel, to view: VideoLayerHostView, pictureInPicture: PictureInPicture?) {
        #if canImport(Libmpv)
        if player.engine?.kind == .mpv {
            let layer = player.mpvLayer
            guard view.videoLayer !== layer else { return }
            // Picture in Picture is AVPlayer's; the button on mpv hands the
            // stream over rather than lifting this layer out.
            pictureInPicture?.detach()
            view.host(layer)
            return
        }
        #endif
        guard let engine = player.engine as? AVEngine else { return }
        if let existing = view.videoLayer as? AVPlayerLayer, existing.player === engine.player {
            applyGravity(to: existing)
            return
        }
        let layer = AVPlayerLayer(player: engine.player)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        applyGravity(to: layer)
        view.host(layer)
        pictureInPicture?.attach(to: layer)
    }

    static func applyGravity(to layer: AVPlayerLayer) {
        let gravity: AVLayerVideoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
        if layer.videoGravity != gravity { layer.videoGravity = gravity }
    }
}

#if canImport(UIKit)
struct VideoSurface: UIViewRepresentable {
    @Environment(PlayerModel.self) private var player
    let pictureInPicture: PictureInPicture

    func makeUIView(context: Context) -> VideoLayerHostView {
        let view = VideoLayerHostView(frame: .zero)
        VideoSurfaceWiring.attach(player, to: view, pictureInPicture: pictureInPicture)
        return view
    }

    func updateUIView(_ view: VideoLayerHostView, context: Context) {
        VideoSurfaceWiring.attach(player, to: view, pictureInPicture: pictureInPicture)
    }

    static func dismantleUIView(_ view: VideoLayerHostView, coordinator: ()) {
        // Nothing: the player layer belongs to the view and goes with it. The
        // Picture in Picture controller keeps the window alive if it has one.
    }
}
#else
struct VideoSurface: NSViewRepresentable {
    @Environment(PlayerModel.self) private var player
    let pictureInPicture: PictureInPicture

    func makeNSView(context: Context) -> VideoLayerHostView {
        let view = VideoLayerHostView(frame: .zero)
        VideoSurfaceWiring.attach(player, to: view, pictureInPicture: pictureInPicture)
        return view
    }

    func updateNSView(_ view: VideoLayerHostView, context: Context) {
        VideoSurfaceWiring.attach(player, to: view, pictureInPicture: pictureInPicture)
    }
}
#endif
