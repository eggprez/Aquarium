//  What the app and its widgets agree on — the Now Playing card and the
//  Control Centre buttons.
//
//  A widget is drawn by another process and can see none of the players,
//  so the app writes this small value into the app group whenever what is
//  playing changes, with the artwork beside it, and asks the widget to
//  redraw. The widget never talks to the server.
//
//  The controls are App Intents. The system runs an intent's `perform` in
//  the app's process — one that opens the app, or one that starts audio —
//  but the extension still has to compile them, and cannot see the players,
//  so `perform` goes through a closure the app installs at launch, the way
//  the Live Activity buttons do (LiveActivityTypes.swift).
//
//  Compiled into both the app and the LiveActivities extension. iPhone and
//  iPad only.

#if os(iOS)

import AppIntents
import Foundation

// MARK: - Now Playing

struct NowPlayingSnapshot: Codable, Hashable, Sendable {
    var itemId: String
    var title: String
    var subtitle: String
    /// A film or an episode rather than something in the music player. A
    /// tap on the card opens the title's page; music opens Now Playing.
    var isVideo: Bool
    var isPlaying: Bool
    /// Where the playhead was when this was written, in seconds. A card
    /// drawn later runs it forward from `updatedAt` while `isPlaying`.
    var position: Double
    var duration: Double
    var rate: Double = 1
    var updatedAt = Date()
    var hasArtwork: Bool

    /// The group both bundles are in. Set on both targets' entitlements.
    static let appGroup = "group.scottai.FellyJin"
    static let widgetKind = "scottai.FellyJin.nowplaying"

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static var file: URL? { folder?.appendingPathComponent("nowplaying.json") }
    static var artworkFile: URL? { folder?.appendingPathComponent("nowplaying-art.jpg") }

    /// The playhead as of `date`.
    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        let elapsed = max(0, date.timeIntervalSince(updatedAt)) * rate
        return duration > 0 ? min(duration, position + elapsed) : position + elapsed
    }

    func fraction(at date: Date) -> Double? {
        guard duration > 0 else { return nil }
        return min(1, max(0, position(at: date) / duration))
    }

    /// Where a tap on the card lands.
    var link: URL? {
        guard isVideo else { return URL(string: "aquarium://nowplaying") }
        // A download playing with no server item has no page to open.
        return itemId.isEmpty ? nil : URL(string: "aquarium://item/\(itemId)")
    }

    static func read() -> NowPlayingSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    static func write(_ snapshot: NowPlayingSnapshot?) {
        guard let file else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
            if let artworkFile { try? FileManager.default.removeItem(at: artworkFile) }
        }
    }

    static func writeArtwork(_ jpeg: Data?) {
        guard let artworkFile else { return }
        if let jpeg {
            try? jpeg.write(to: artworkFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: artworkFile)
        }
    }
}

// MARK: - Controls

/// What a Control Centre button asks of the app.
enum ControlAction: Sendable {
    case resumeWatching
    case shuffleMusic
    case resumeAudiobook
}

enum ControlActions {
    /// Installed by the app at launch. Nil in the extension, where the
    /// intents below are only ever drawn, never performed.
    @MainActor static var handler: (@Sendable (ControlAction) async -> Void)?

    static func send(_ action: ControlAction) async {
        guard let handler = await MainActor.run(body: { handler }) else { return }
        await handler(action)
        // A moment more before the intent is reported done: an audio intent
        // that returns at once can see the app suspended with the stream
        // still opening.
        try? await Task.sleep(for: .seconds(1))
    }
}

@available(iOS 18.0, *)
struct ResumeWatchingControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Picks up the film or episode you were in the middle of.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await ControlActions.send(.resumeWatching)
        return .result()
    }
}

@available(iOS 18.0, *)
struct ShuffleMusicControlIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Music"
    static let description = IntentDescription("Shuffles your whole music library.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await ControlActions.send(.shuffleMusic)
        return .result()
    }
}

@available(iOS 18.0, *)
struct ResumeAudiobookControlIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Audiobook"
    static let description = IntentDescription("Picks up the audiobook you were listening to.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await ControlActions.send(.resumeAudiobook)
        return .result()
    }
}

#endif
