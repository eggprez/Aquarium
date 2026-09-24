//  Holding the picture back, for a stream whose sound cannot be moved.
//
//  The audio offset in `PlayerModel` is made by rebuilding the item as a
//  composition with the audio track inserted at a different time — and a
//  composition needs asset tracks, which an HLS stream has none of. Every
//  transcode, every remux of an MKV, every live channel is HLS, so on an Apple
//  TV — where the offset is nearly always the room's soundbar, and nearly
//  everything played is a remux — the control that mattered most applied to
//  the streams that mattered least.
//
//  This is the other way round the problem. The sound is left exactly where
//  AVPlayer puts it; it is the *picture* that is moved, later, by the amount
//  the sound is wanted earlier. AVPlayer hands over each decoded frame through
//  an `AVPlayerItemVideoOutput` and is told not to draw it itself; the frames
//  are held in a short queue, and each is shown — through an
//  `AVSampleBufferDisplayLayer` sitting between the video and AVKit's controls
//  — once the hold has run. The rest of the player is untouched: seeks,
//  pauses and stalls all arrive at the picture the same fixed interval after
//  they arrive at the sound, which is what a delay line is.
//
//  What this can and cannot do follows from that. It can only make the sound
//  *earlier* — the picture can be held, not brought forward — so an HLS stream
//  gets the negative half of the range and nothing else. It costs memory: each
//  held frame is a decoded picture, and at 4K that is some twenty-five
//  megabytes apiece, so `maxQueuedBytes` caps what is held and a hold that
//  would need more than that is quietly shortened rather than allowed to
//  crash the app. And it is the tvOS build only: it is the one device here
//  that plays through a soundbar, and the one where Picture in Picture — which
//  draws from the player's own layer and would go black under this — does not
//  exist.

#if os(tvOS)
import AVFoundation
import UIKit

@MainActor
final class DelayedVideoRenderer: NSObject, AVPlayerItemOutputPullDelegate {
    /// How long each frame is held before it is shown, in seconds. Positive:
    /// this is the size of the hold, not the signed offset it implements.
    let hold: Double

    /// The surface the delayed picture is drawn on. Sized by whoever puts it
    /// in a view hierarchy — see `PlayerScreen`'s coordinator.
    let view = DelayedVideoView()

    /// The most memory the queue may hold. Four hundred megabytes is sixteen
    /// frames of 4K 10-bit video, which is two-thirds of a second at 24 fps
    /// and a quarter of one at 60 — more than the range offers at film rates,
    /// a shortened hold at 4K60 rather than a jetsam.
    static let maxQueuedBytes = 400 << 20

    private let output: AVPlayerItemVideoOutput
    private weak var item: AVPlayerItem?
    private var link: CADisplayLink?

    private struct Frame {
        let hostTime: CFTimeInterval
        let buffer: CVPixelBuffer
        let bytes: Int
    }
    private var queue: [Frame] = []
    private var queuedBytes = 0
    /// Reused across frames of the same size and format; a format description
    /// is not free to build and the picture doesn't change shape mid-stream.
    private var format: CMVideoFormatDescription?
    /// Display-link ticks since anything last arrived or left. The link is
    /// parked when the player has gone quiet — paused, stalled, ended — and
    /// the output wakes it when frames are on their way again.
    private var idleTicks = 0

    /// Whether this renderer is the one keeping the screensaver off.
    /// `suppressesPlayerRendering` makes AVPlayer think it is playing audio
    /// only, so it no longer holds the idle timer off itself, and the Apple
    /// TV screensaver came on in the middle of a film as soon as an audio
    /// offset was set. Held while frames are moving, and given back when the
    /// link parks (paused, stalled, ended) or the renderer is detached, so a
    /// paused film still gets its screensaver.
    private var holdsIdleTimer = false {
        didSet {
            guard holdsIdleTimer != oldValue else { return }
            UIApplication.shared.isIdleTimerDisabled = holdsIdleTimer
        }
    }

    init(item: AVPlayerItem, hold: Double) {
        self.hold = max(0, hold)
        self.item = item
        // No pixel buffer attributes: whatever format the decoder produces is
        // the format taken. Asking for another means a conversion of every
        // frame, and the display layer draws the native one directly.
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        // The whole point. With this set the player's own layer stays black
        // and the only picture on screen is the one drawn here, on time.
        output.suppressesPlayerRendering = true
        super.init()
        output.setDelegate(self, queue: .main)
        item.add(output)
        startLink()
    }

    /// Stop drawing and give the item its rendering back. Called before the
    /// item is replaced or the player closed; a renderer left attached to an
    /// item that has gone would keep a display link and a queue of frames
    /// alive for nothing.
    func detach() {
        link?.invalidate()
        link = nil
        holdsIdleTimer = false
        item?.remove(output)
        item = nil
        queue.removeAll()
        queuedBytes = 0
        view.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        view.removeFromSuperview()
    }

    // MARK: - The delay line

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        idleTicks = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let pulled = pull(at: now)
        let shown = present(at: now)
        guard !pulled, !shown, queue.isEmpty else {
            idleTicks = 0
            if shown { holdsIdleTimer = true }
            return
        }
        // Nothing arriving and nothing waiting. A paused film would otherwise
        // keep a 60 Hz timer running for the length of the pause; park it and
        // let the output say when there is something to draw again.
        idleTicks += 1
        if idleTicks > 120 {
            link.invalidate()
            self.link = nil
            holdsIdleTimer = false
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
        }
    }

    /// Take the frame the player would be showing right now, if there is a
    /// new one, and put it at the back of the queue stamped with when it
    /// was taken.
    private func pull(at now: CFTimeInterval) -> Bool {
        let itemTime = output.itemTime(forHostTime: now)
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return false }
        let bytes = CVPixelBufferGetDataSize(buffer)
        queue.append(Frame(hostTime: now, buffer: buffer, bytes: bytes))
        queuedBytes += bytes
        return true
    }

    /// Show whatever has finished its hold. When more than one frame has —
    /// after a hiccup in the link — only the newest is drawn; the others are
    /// late and drawing them would only make the newest later.
    private func present(at now: CFTimeInterval) -> Bool {
        let due = now - hold
        var latest: Frame?
        while let first = queue.first, first.hostTime <= due || queuedBytes > Self.maxQueuedBytes {
            queue.removeFirst()
            queuedBytes -= first.bytes
            latest = first
        }
        guard let latest else { return false }
        enqueue(latest.buffer)
        return true
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        if let format, !CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: pixelBuffer) {
            self.format = nil
        }
        if format == nil {
            var fresh: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fresh)
            format = fresh
        }
        guard let format else { return }

        // No timestamps: the frame is marked to be displayed the moment it is
        // enqueued, and *when* it is enqueued is the timing. The layer's own
        // timebase would be a second clock to keep in step with the player's,
        // and the queue above already is the clock.
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = view.displayLayer.sampleBufferRenderer
        // A renderer that has failed — the route changed under it, a frame it
        // could not take — refuses everything after until it is flushed. Flush
        // and carry on rather than go black for the rest of the film.
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    // MARK: - AVPlayerItemOutputPullDelegate

    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        Task { @MainActor in self.startLink() }
    }
}

/// A view whose layer is the display layer, so it takes its size from the
/// view hierarchy like anything else and needs no frame bookkeeping of its
/// own.
final class DelayedVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // The cast cannot fail: `layerClass` above is what made the layer.
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }
}
#endif
