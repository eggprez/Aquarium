//  What the Mac's View menu adjusts: how big the thumbnails are. One value for
//  the whole app rather than a slider per page — Bigger and Smaller in the
//  menu bar, on ⌘+ and ⌘−, are where Finder, Photos and the TV app keep it,
//  and a size chosen once should hold from one grid to the next.
//
//  Not gated to macOS: a grid reads it inside its own `#if os(macOS)`, and a
//  type that exists everywhere can't be referenced from the wrong side of one
//  by mistake. On the other platforms it just stays at 1.

import Foundation
import Observation

@MainActor @Observable
final class MacViewOptions {
    static let shared = MacViewOptions()

    /// The smallest and largest a grid is worth drawing at: 0.6 is Finder's
    /// smallest icon view before the titles stop fitting, 1.6 is two posters
    /// across a laptop window.
    static let range: ClosedRange<Double> = 0.6...1.6
    /// One menu press. Seven steps from smallest to largest, the middle of
    /// them being the size the app was designed at.
    static let step = 0.15

    /// What a grid multiplies its minimum column width by. Persisted so a
    /// size picked once is the size the app opens at.
    var thumbnailSize: Double {
        didSet {
            let clamped = min(max(thumbnailSize, Self.range.lowerBound), Self.range.upperBound)
            if clamped != thumbnailSize {
                thumbnailSize = clamped
                return
            }
            UserDefaults.standard.set(thumbnailSize, forKey: Self.key)
        }
    }

    private static let key = "mac_thumbnail_size"

    private init() {
        let saved = UserDefaults.standard.object(forKey: Self.key) as? Double
        thumbnailSize = saved.map { min(max($0, Self.range.lowerBound), Self.range.upperBound) } ?? 1
    }

    var canGrow: Bool { thumbnailSize < Self.range.upperBound - 0.001 }
    var canShrink: Bool { thumbnailSize > Self.range.lowerBound + 0.001 }
    var isActualSize: Bool { abs(thumbnailSize - 1) < 0.001 }

    /// View ▸ Bigger (⌘+).
    func bigger() {
        thumbnailSize = (thumbnailSize + Self.step).rounded(toStep: Self.step)
    }

    /// View ▸ Smaller (⌘−).
    func smaller() {
        thumbnailSize = (thumbnailSize - Self.step).rounded(toStep: Self.step)
    }

    /// View ▸ Actual Size (⌘0).
    func actualSize() {
        thumbnailSize = 1
    }
}

private extension Double {
    /// Snapped to the nearest multiple of `step` above 1 — so seven presses
    /// of Smaller and seven of Bigger land back on exactly 1 rather than on
    /// 0.9999999.
    func rounded(toStep step: Double) -> Double {
        let steps = ((self - 1) / step).rounded()
        return ((1 + steps * step) * 100).rounded() / 100
    }
}
