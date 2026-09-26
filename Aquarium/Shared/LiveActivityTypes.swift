//  What the app and the Live Activities extension agree on.
//
//  A Live Activity is drawn by a separate process from a small Codable value
//  the app hands the system; the extension never sees the player or the
//  download manager, only what is written here. Two activities: a sleep
//  timer's countdown over whatever is playing, and what is being downloaded.
//
//  Neither is told the time. Nothing can push to a Jellyfin client — there is
//  no server of ours for a push to come from — so an activity is only ever
//  updated while the app is running, and anything that moves between updates
//  has to move by itself. That is why the state below carries *dates*: the
//  system draws a countdown to a deadline with no further word from the app.
//
//  The buttons are App Intents, and the system runs an intent's `perform` in
//  the app's process, not the extension's. The extension still has to compile
//  them, and cannot see the players, so `perform` goes through a closure the
//  app installs at launch — see `LiveActivityCenter.start`.
//
//  Compiled into both the app and the LiveActivities extension. iPhone and
//  iPad only: there is no ActivityKit on tvOS or the Mac.

#if os(iOS)

import ActivityKit
import AppIntents
import Foundation

// MARK: - Listening

struct ListeningActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// The book, the song, the film.
        var title: String
        /// The author or artist, when there is one.
        var subtitle: String?
        var isPlaying: Bool
        /// When the sleep timer stops playback.
        var sleepDeadline: Date
        /// A film rather than something in the music player. Tapping the
        /// activity opens Now Playing, which a film doesn't have.
        var isVideo = false
    }

}

// MARK: - Downloads

struct DownloadsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Sendable { case running, paused, finished }

        var phase: Phase
        /// Counted in items, not bytes. The app hears nothing of a transfer's
        /// bytes while it is suspended, but it is woken as each item lands, so
        /// the count is the number that stays true with the phone locked.
        var done: Int
        var failed: Int
        var total: Int
        /// What is arriving now; nil between items and once finished.
        var currentTitle: String?
        /// 0...1 across the whole batch, the running item's share included.
        var fraction: Double
        /// The arriving item's own progress, 0...1, as of this update. Nil when
        /// nothing is arriving or its size can't be told.
        var currentFraction: Double?
        /// The arriving item's progress as a span of time, at the pace it has
        /// kept so far: the bar is full at `currentEnd` and reads
        /// `currentFraction` now. A span rather than a number because the app
        /// is mostly asleep while the phone is locked, and a span fills itself
        /// in between updates. Nil until there is a pace to go on.
        var currentStart: Date?
        var currentEnd: Date?
        /// What the queue will start after the arriving one.
        var nextTitle: String?

        /// Not landed yet, the arriving one included.
        var remaining: Int { max(0, total - done - failed) }
    }
}

// MARK: - Buttons

/// What a button on an activity asks of the app.
enum LiveActivityAction: Sendable {
    case extendSleepTimer(minutes: Int)
    case cancelSleepTimer
    case setDownloadsPaused(Bool)
}

enum LiveActivityActions {
    /// Installed by the app at launch. Nil in the extension, where the intents
    /// below are only ever drawn, never performed.
    @MainActor static var handler: ((LiveActivityAction) -> Void)?

    static func send(_ action: LiveActivityAction) async {
        await MainActor.run { handler?(action) }
    }
}

struct ExtendSleepTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add Time to Sleep Timer"
    static let isDiscoverable = false

    @Parameter(title: "Minutes") var minutes: Int

    init() { minutes = 15 }
    init(minutes: Int) { self.minutes = minutes }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.send(.extendSleepTimer(minutes: minutes))
        return .result()
    }
}

struct CancelSleepTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Off Sleep Timer"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.send(.cancelSleepTimer)
        return .result()
    }
}

struct SetDownloadsPausedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Downloads"
    static let isDiscoverable = false

    @Parameter(title: "Paused") var paused: Bool

    init() { paused = true }
    init(paused: Bool) { self.paused = paused }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.send(.setDownloadsPaused(paused))
        return .result()
    }
}

#endif
