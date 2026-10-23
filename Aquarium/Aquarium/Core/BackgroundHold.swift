#if canImport(UIKit)
import UIKit

/// A stretch of background time that gives itself back when the system asks
/// for it. Begun without an expiration handler, a hold that outlasted the time
/// granted — a long book being cut for the watch, a stream's segments being
/// walked after the app was woken for a download — was never ended, and the
/// system kills an app for that.
@MainActor
final class BackgroundHold {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Called on the main thread.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    /// Safe to call more than once; only the first does anything.
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
