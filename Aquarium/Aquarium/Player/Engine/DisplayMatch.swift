//  Match Frame Rate, for a player that isn't AVPlayer.
//
//  AVPlayerViewController asks the Apple TV to change its display mode for
//  whatever it plays; mpv draws into a Metal layer and nobody asks. With the
//  display left at the menu's 60 Hz, a 23.976 fps film is shown by holding
//  frames for two refreshes and three in turn, and every pan judders. So the
//  player asks itself: the rate the file declares, through the window's
//  `AVDisplayManager`, before the file opens — a switch blanks the television
//  for a second or two, and that is better spent before the first frame than
//  over it.
//
//  Only the rate. Every stream is described as SDR, because that is what mpv
//  sends: it draws into an ordinary Metal layer and tone-maps HDR down. Asking
//  for HDR as well would put the television in HDR mode under an SDR picture,
//  which looks washed out.
//
//  AVKit, which puts `avDisplayManager` on the window, is linked for tvOS in
//  the target's build settings: this player uses nothing else of it, and an
//  Objective-C category alone doesn't make the linker keep a framework — without
//  the flag the property isn't there at run time and the call crashes.
//
//  Nothing happens when Match Content → Match Frame Rate is off in Settings;
//  tvOS ignores the request then, and the player doesn't wait on a switch that
//  will never come.

#if os(tvOS)

import AVFoundation
import AVKit
import OSLog
import UIKit

@MainActor
enum DisplayMatch {
    private static var manager: AVDisplayManager? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        return window?.avDisplayManager
    }

    /// Whether Settings → Video and Audio → Match Content → Match Frame Rate
    /// is on.
    static var isEnabled: Bool { manager?.isDisplayCriteriaMatchingEnabled ?? false }

    /// The rate last asked for; nil once handed back.
    private(set) static var requested: Double?

    /// Ask for a display running at `rate`, and wait for the television to
    /// get there if it has to switch. Returns once the display is ready for
    /// the first frame, or after `patience`, whichever is first. True if a
    /// new rate was asked for — the television may have renegotiated HDMI.
    @discardableResult
    static func request(rate: Double?, codec: String?, size: CGSize, patience: Duration = .seconds(6)) async -> Bool {
        guard let manager, manager.isDisplayCriteriaMatchingEnabled,
              let rate = rate.map(normalized), rate > 0,
              let description = formatDescription(codec: codec, size: size)
        else { return false }
        guard requested != rate else { return false }
        requested = rate
        PlayerModel.log.info("display: asking for \(rate, format: .fixed(precision: 3)) Hz")
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(rate), formatDescription: description)

        // The switch, if there is one, begins a moment after the request.
        // Wait for it to begin, then for it to end.
        let deadline = ContinuousClock.now + patience
        let beginBy = ContinuousClock.now + .milliseconds(600)
        while !manager.isDisplayModeSwitchInProgress, ContinuousClock.now < beginBy {
            try? await Task.sleep(for: .milliseconds(50))
        }
        while manager.isDisplayModeSwitchInProgress, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Give the display back to the Home screen's mode.
    static func reset() {
        guard requested != nil else { return }
        requested = nil
        manager?.preferredDisplayCriteria = nil
    }

    /// The refresh rate the screen is running at now, if it is the one asked
    /// for — the only case where mpv can time frames to the display. tvOS
    /// reports whole numbers (24 for 23.976), so it is compared to the rate
    /// rounded.
    static var matchedRate: Double? {
        guard let requested, !(manager?.isDisplayModeSwitchInProgress ?? true) else { return nil }
        let screenRate = Double(UIScreen.main.maximumFramesPerSecond)
        return abs(screenRate - requested.rounded()) <= 1 ? requested : nil
    }

    /// The exact NTSC rates, from the approximations files carry:
    /// 23.976023… as 24000/1001.
    private static func normalized(_ rate: Double) -> Double {
        for exact in [24000.0 / 1001, 30000.0 / 1001, 60000.0 / 1001] where abs(rate - exact) < 0.01 {
            return exact
        }
        return (rate * 1000).rounded() / 1000
    }

    private static func formatDescription(codec: String?, size: CGSize) -> CMFormatDescription? {
        let type: CMVideoCodecType
        switch codec?.lowercased() {
        case "hevc", "h265": type = kCMVideoCodecType_HEVC
        case "av1": type = kCMVideoCodecType_AV1
        case "vp9": type = kCMVideoCodecType_VP9
        default: type = kCMVideoCodecType_H264
        }
        let width = Int32(size.width > 0 ? size.width : 1920)
        let height = Int32(size.height > 0 ? size.height : 1080)
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: type, width: width, height: height,
            extensions: nil, formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }
}

#endif
