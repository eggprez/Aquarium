//  When the app started, what it has got to since, and what can wait.
//
//  A launch is the one moment the whole app does its setup at once, and most
//  of it was done before the first frame: every singleton's init ran inside
//  the app's own `init`, and several of them talk to other processes — the
//  background download daemon, the Live Activity server, iCloud's key-value
//  store — which on a phone is tens to hundreds of milliseconds each, all on
//  the main thread, all before anything was on screen. On the simulator the
//  same calls return at once, which is why it never showed there.
//
//  `afterFirstFrame` is for that work: it runs once the root view has
//  appeared, or after a short fallback for a launch with no window at all (a
//  Live Activity button, a background download finishing). `mark` writes a
//  timeline to the `launch` log category, in milliseconds since the kernel
//  started the process, so a slow launch on a device can be read back:
//
//      log show --predicate 'subsystem == "scottai.FellyJin" AND category == "launch"'

import Foundation
import os

enum Launch {
    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "launch")

    /// When the kernel started this process — before `main`, before dyld —
    /// so the timeline includes the load the app can't see.
    nonisolated static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()

    /// A line on the timeline.
    nonisolated static func mark(_ phase: String) {
        let ms = Int(Date().timeIntervalSince(processStart) * 1000)
        log.notice("\(ms, privacy: .public) ms  \(phase, privacy: .public)")
        #if DEBUG
        print("launch \(ms) ms  \(phase)")
        #endif
    }

    /// Run this once the first frame is up — or, with no window to draw one,
    /// soon anyway. Work queued after the frame runs at once. Callable from
    /// anywhere: some of the inits that queue work here aren't on the main
    /// actor themselves.
    nonisolated static func afterFirstFrame(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in queue(work) }
    }

    @MainActor
    private static func queue(_ work: @escaping @MainActor () -> Void) {
        if drawn {
            work()
            return
        }
        pending.append(work)
        guard fallback == nil else { return }
        fallback = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            firstFrameDrawn()
        }
    }

    /// The root view has appeared. Called from `RootView`; harmless again.
    @MainActor
    static func firstFrameDrawn() {
        guard !drawn else { return }
        drawn = true
        fallback?.cancel()
        fallback = nil
        mark("first frame")
        let work = pending
        pending = []
        // Not on the spot: `onAppear` runs before the frame it announces is
        // committed, and this is exactly the work that must not delay it.
        // One task each, so touches and the next frame get in between.
        for item in work {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                item()
            }
        }
    }

    @MainActor private static var drawn = false
    @MainActor private static var pending: [@MainActor () -> Void] = []
    @MainActor private static var fallback: Task<Void, Never>?
}
