//  What the app and the Live Activities extension agree on.
//
//  A Live Activity is drawn by a separate process from a small Codable value
//  the app hands the system; the extension never sees the players, only what
//  is written here. One activity: a sleep timer's countdown over whatever is
//  playing.
//
//  It is not told the time. Nothing can push to a Jellyfin client — there is
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
        /// "Skip intro" or "Skip credits" while the playhead is in one the
        /// server has marked; nil when there is nothing to skip.
        var skipLabel: String?
    }

}

extension ListeningActivityAttributes.ContentState {
    private enum CodingKeys: String, CodingKey { case title, subtitle, isPlaying, sleepDeadline, isVideo, skipLabel }

    /// Key by key: an activity already running when the app updates can have
    /// the system hand its extension a state encoded by the build before
    /// `isVideo` existed, and a synthesized decoder would drop the whole
    /// update over that one missing key.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        sleepDeadline = try c.decode(Date.self, forKey: .sleepDeadline)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        skipLabel = try c.decodeIfPresent(String.self, forKey: .skipLabel)
    }
}

// MARK: - Buttons

/// What a button on an activity asks of the app.
enum LiveActivityAction: Sendable {
    case extendSleepTimer(minutes: Int)
    case cancelSleepTimer
    case togglePlayPause
    case skipSegment
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

struct TogglePlayPauseActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.send(.togglePlayPause)
        return .result()
    }
}

struct SkipSegmentActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Intro or Credits"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.send(.skipSegment)
        return .result()
    }
}

#endif
