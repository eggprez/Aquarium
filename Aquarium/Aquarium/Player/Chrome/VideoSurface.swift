//  Where the picture is drawn on an iPhone, iPad or Mac: a plain view hosting
//  a `CALayer` the engine renders into. For AVPlayer that is an
//  `AVPlayerLayer`; the mpv engine's `CAMetalLayer` (phase 4) goes in the same
//  slot. The view takes no touches or clicks of its own — the gesture layer
//  above it does — and the layer takes the view's bounds on every layout.
//
//  This replaces `AVPlayerViewController` on iOS and `AVPlayerView` on the
//  Mac, which drew the picture and a transport this app could not change.
//  Background audio needs nothing here: `AVEngine` sets
//  `audiovisualBackgroundPlaybackPolicy` to `continuesIfPossible`, so a player
//  attached to a layer carries on as sound when the app goes behind another —
//  which is what the controller did.

#if os(iOS) || os(macOS)

import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func host(_ layer: CALayer) {
        guard layer !== videoLayer else { return }
        videoLayer?.removeFromSuperlayer()
        videoLayer = layer
        layer.frame = bounds
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitVideoLayer()
    }

    private func fitVideoLayer() {
        guard let videoLayer, videoLayer.frame != bounds else { return }
        // No implicit animation: a rotation would otherwise show the picture
        // sliding to its new frame after the view had already turned.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
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
    }

    private func fitVideoLayer() {
        guard let videoLayer, videoLayer.frame != bounds else { return }
        // No implicit animation: a live resize would otherwise show the
        // picture lagging a frame behind the window's edge.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
#endif

/// The engine's layer in the host view, made for AVPlayer if the view has
/// none or the engine has changed under it, and kept at Fit or Fill.
@MainActor
private enum VideoSurfaceWiring {
    static func attach(_ player: PlayerModel, to view: VideoLayerHostView, pictureInPicture: PictureInPicture?) {
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

#if os(iOS)
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

#endif
