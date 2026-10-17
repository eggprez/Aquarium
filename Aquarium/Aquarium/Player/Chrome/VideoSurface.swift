//  Where the picture is drawn on an iPhone or iPad: a plain view hosting a
//  `CALayer` the engine renders into. For AVPlayer that is an `AVPlayerLayer`;
//  the mpv engine's `CAMetalLayer` (phase 4) goes in the same slot. The view
//  takes no touches of its own — the gesture layer above it does — and the
//  layer takes the view's bounds on every layout.
//
//  This replaces `AVPlayerViewController`, which drew the picture and a
//  transport this app could not change. Background audio needs nothing here:
//  `AVEngine` sets `audiovisualBackgroundPlaybackPolicy` to
//  `continuesIfPossible`, so a player attached to a layer carries on as sound
//  when the app goes behind another — which is what the controller did.

#if os(iOS)

import AVFoundation
import SwiftUI
import UIKit

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
        guard let videoLayer, videoLayer.frame != bounds else { return }
        // No implicit animation: a rotation would otherwise show the picture
        // sliding to its new frame after the view had already turned.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoSurface: UIViewRepresentable {
    @Environment(PlayerModel.self) private var player
    let pictureInPicture: PictureInPicture

    func makeUIView(context: Context) -> VideoLayerHostView {
        let view = VideoLayerHostView(frame: .zero)
        attach(to: view)
        return view
    }

    func updateUIView(_ view: VideoLayerHostView, context: Context) {
        attach(to: view)
        if let layer = view.videoLayer as? AVPlayerLayer {
            let gravity: AVLayerVideoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
            if layer.videoGravity != gravity { layer.videoGravity = gravity }
        }
    }

    static func dismantleUIView(_ view: VideoLayerHostView, coordinator: ()) {
        // Nothing: the player layer belongs to the view and goes with it. The
        // Picture in Picture controller keeps the window alive if it has one.
    }

    /// Give the view the engine's layer, making one for AVPlayer if the view
    /// has none or the engine has changed under it.
    private func attach(to view: VideoLayerHostView) {
        guard let engine = player.engine as? AVEngine else { return }
        if let existing = view.videoLayer as? AVPlayerLayer, existing.player === engine.player { return }
        let layer = AVPlayerLayer(player: engine.player)
        layer.videoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        view.host(layer)
        pictureInPicture.attach(to: layer)
    }
}

#endif
