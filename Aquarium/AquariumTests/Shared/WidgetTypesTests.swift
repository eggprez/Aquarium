//  What the app and its widget extension agree on (Shared/WidgetTypes.swift
//  and Shared/LiveActivityTypes.swift): the Now Playing card's snapshot as it
//  is written to and read from the app group, and the buttons — each an App
//  Intent whose `perform` hands one action to whatever the app installed.
//
//  iPhone and iPad only. The widget's own drawing (LiveActivities/) is a
//  separate target and is checked by hand. PhoneWidgetTests covers the
//  snapshot's clock and the listening state's decoding.

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class NowPlayingSnapshotTests: XCTestCase {
    private var saved: NowPlayingSnapshot?
    private var savedArtwork: Data?

    override func setUp() async throws {
        try XCTSkipIf(NowPlayingSnapshot.artworkFile == nil, "this build has no app group container")
        saved = NowPlayingSnapshot.read()
        savedArtwork = NowPlayingSnapshot.artworkFile.flatMap { try? Data(contentsOf: $0) }
        NowPlayingSnapshot.write(nil)
    }

    override func tearDown() async throws {
        NowPlayingSnapshot.write(saved)
        if saved != nil { NowPlayingSnapshot.writeArtwork(savedArtwork) }
    }

    private func snapshot(itemId: String = "item", isVideo: Bool = true, isPlaying: Bool = true, position: Double = 10,
                          duration: Double = 100, rate: Double = 1, updatedAt: Date = Date()) -> NowPlayingSnapshot {
        NowPlayingSnapshot(itemId: itemId, title: "Title", subtitle: "Subtitle", isVideo: isVideo, isPlaying: isPlaying,
                           position: position, duration: duration, rate: rate, updatedAt: updatedAt, hasArtwork: false)
    }

    func testTheCardIsReadBackAsWrittenAndClearingItTakesTheArtworkToo() throws {
        XCTAssertNil(NowPlayingSnapshot.read())
        let card = snapshot(updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        NowPlayingSnapshot.write(card)
        XCTAssertEqual(NowPlayingSnapshot.read(), card)

        let artwork = try XCTUnwrap(NowPlayingSnapshot.artworkFile)
        NowPlayingSnapshot.writeArtwork(Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(try Data(contentsOf: artwork), Data([0xFF, 0xD8, 0xFF]))
        NowPlayingSnapshot.writeArtwork(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artwork.path))

        NowPlayingSnapshot.writeArtwork(Data([1]))
        NowPlayingSnapshot.write(nil)
        XCTAssertNil(NowPlayingSnapshot.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: artwork.path), "nothing playing: no card and no picture")
    }

    func testWhereATapOnTheCardLands() {
        XCTAssertEqual(snapshot(itemId: "abc", isVideo: true).link?.absoluteString, "aquarium://item/abc")
        XCTAssertEqual(snapshot(itemId: "", isVideo: true).link?.absoluteString, "aquarium://downloads",
                       "a download with no server item has no page; Downloads is where it lives")
        XCTAssertEqual(snapshot(itemId: "abc", isVideo: false).link?.absoluteString, "aquarium://nowplaying")
    }

    func testThePlayheadRunsAtTheSpeedItIsPlayingAt() {
        let then = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let fast = snapshot(position: 10, duration: 100, rate: 2, updatedAt: then)
        XCTAssertEqual(fast.position(at: then.addingTimeInterval(20)), 50)
        XCTAssertEqual(fast.position(at: then.addingTimeInterval(-20)), 10, "a clock that reads earlier never runs it backwards")
        XCTAssertEqual(fast.fraction(at: then.addingTimeInterval(20)), 0.5)
        XCTAssertEqual(fast.fraction(at: then.addingTimeInterval(500)), 1)

        let live = snapshot(position: 10, duration: 0, updatedAt: then)
        XCTAssertEqual(live.position(at: then.addingTimeInterval(3600)), 3610, "with no length there is no end to stop at")
        XCTAssertNil(live.fraction(at: then), "and no bar to draw")
    }
}

/// The buttons on the Now Playing card, in Control Centre and on the Live
/// Activity. Each `perform` should reach the app's handler with its action.
@MainActor
final class WidgetButtonTests: XCTestCase {
    private var savedControl: (@Sendable (ControlAction) async -> Void)?
    private var savedActivity: ((LiveActivityAction) -> Void)?

    override func setUp() async throws {
        savedControl = ControlActions.handler
        savedActivity = LiveActivityActions.handler
    }

    override func tearDown() async throws {
        ControlActions.handler = savedControl
        LiveActivityActions.handler = savedActivity
    }

    private final class Log<Action>: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Action] = []
        func add(_ action: Action) { lock.withLock { seen.append(action) } }
        var all: [Action] { lock.withLock { seen } }
    }

    private func name(_ action: ControlAction) -> String {
        switch action {
        case .resumeWatching: "resumeWatching"
        case .shuffleMusic: "shuffleMusic"
        case .resumeAudiobook: "resumeAudiobook"
        case .togglePlayPause: "togglePlayPause"
        case .skipSegment: "skipSegment"
        case .nextEpisode: "nextEpisode"
        }
    }

    private func name(_ action: LiveActivityAction) -> String {
        switch action {
        case .extendSleepTimer(let minutes): "extend \(minutes)"
        case .cancelSleepTimer: "cancel"
        case .togglePlayPause: "togglePlayPause"
        case .skipSegment: "skipSegment"
        }
    }

    func testEachControlButtonSendsItsOwnAction() async throws {
        let log = Log<ControlAction>()
        ControlActions.handler = { log.add($0) }
        // Side by side: each waits a second after the handler, for the audio
        // to start before the system suspends the app.
        var expected = ["skipSegment", "togglePlayPause"]
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await PlayPauseWidgetIntent().perform() }
            group.addTask { _ = try await SkipSegmentWidgetIntent().perform() }
            if #available(iOS 18.0, *) {
                // The Control Centre buttons.
                group.addTask { _ = try await ResumeWatchingControlIntent().perform() }
                group.addTask { _ = try await ShuffleMusicControlIntent().perform() }
                group.addTask { _ = try await ResumeAudiobookControlIntent().perform() }
                group.addTask { _ = try await NextEpisodeControlIntent().perform() }
                expected += ["nextEpisode", "resumeAudiobook", "resumeWatching", "shuffleMusic"]
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(log.all.map { self.name($0) }.sorted(), expected.sorted())
    }

    func testAControlButtonWithNoAppBehindItDoesNothing() async throws {
        // In the extension nothing is installed: the intents are only drawn.
        ControlActions.handler = nil
        let started = Date()
        _ = try await PlayPauseWidgetIntent().perform()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "and nothing to wait for")
    }

    func testEachLiveActivityButtonSendsItsOwnAction() async throws {
        let log = Log<LiveActivityAction>()
        LiveActivityActions.handler = { log.add($0) }
        _ = try await ExtendSleepTimerIntent().perform()
        _ = try await ExtendSleepTimerIntent(minutes: 30).perform()
        _ = try await CancelSleepTimerIntent().perform()
        _ = try await TogglePlayPauseActivityIntent().perform()
        _ = try await SkipSegmentActivityIntent().perform()
        XCTAssertEqual(log.all.map { self.name($0) }, ["extend 15", "extend 30", "cancel", "togglePlayPause", "skipSegment"],
                       "the + button adds a quarter of an hour unless told otherwise")

        LiveActivityActions.handler = nil
        _ = try await CancelSleepTimerIntent().perform()
        XCTAssertEqual(log.all.count, 5)
    }
}
#endif
