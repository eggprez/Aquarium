//  The screen held on while something is worth watching: the Downloads page
//  through a long batch. One place for the system's idle timer so that two
//  reasons to hold it don't let go of each other: the flag is set while any
//  reason holds, and cleared when the last lets go. (The video player's own
//  picture keeps the screen on by itself on iPhone and iPad, so it doesn't
//  come through here.)

#if os(iOS)
import UIKit

@MainActor
enum ScreenAwake {
    private static var reasons: Set<String> = []

    /// Hold the screen awake for `reason`, or let it go. Safe to call with
    /// the same value again.
    static func hold(_ reason: String, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        let wanted = !reasons.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != wanted {
            UIApplication.shared.isIdleTimerDisabled = wanted
        }
    }
}
#endif
