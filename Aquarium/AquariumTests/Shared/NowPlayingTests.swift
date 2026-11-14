//  `NowPlaying`: the card the lock screen, Control Centre and the media keys
//  read, and which remote commands are offered.
//
//  The video player is never started here: the tests set the plain facts the
//  card is built from (title, position, length, paused) on the idle
//  `PlayerModel` and put them back. What a press of each remote command then
//  does needs a playing stream and the system's command centre, and is
//  checked by hand.

import MediaPlayer
import XCTest
@testable import Aquarium

@MainActor
final class NowPlayingTests: XCTestCase {
    private var model: PlayerModel { .shared }
    private var card: [String: Any]? { MPNowPlayingInfoCenter.default().nowPlayingInfo }
    private var saved: (title: String, subtitle: String, position: Double, duration: Double, paused: Bool, speed: Double,
                        live: Bool, artwork: URL?, queue: [BaseItem])!

    override func setUp() async throws {
        try XCTSkipIf(model.isActive || MusicPlayer.shared.isActive, "something is playing in the host app")
        saved = (model.title, model.subtitle, model.position, model.duration, model.isPaused, model.speed,
                 model.isLive, model.artworkURL, model.queue)
        NowPlaying.shared.attach(to: model)
        NowPlaying.shared.clear()
    }

    override func tearDown() async throws {
        guard let saved else { return }
        model.title = saved.title
        model.subtitle = saved.subtitle
        model.position = saved.position
        model.duration = saved.duration
        model.isPaused = saved.paused
        model.speed = saved.speed
        model.isLive = saved.live
        model.artworkURL = saved.artwork
        model.setQueue(saved.queue)
        NowPlaying.shared.clear()
    }

    private func set(title: String = "Heat", subtitle: String = "1995", position: Double = 12, duration: Double = 100,
                     paused: Bool = false, speed: Double = 1) {
        model.title = title
        model.subtitle = subtitle
        model.position = position
        model.duration = duration
        model.isPaused = paused
        model.speed = speed
    }

    // MARK: The card

    func testTheCardCarriesWhatIsPlaying() {
        set(speed: 1.5)
        NowPlaying.shared.update(from: model)
        XCTAssertEqual(card?[MPMediaItemPropertyTitle] as? String, "Heat")
        XCTAssertEqual(card?[MPMediaItemPropertyArtist] as? String, "1995")
        XCTAssertEqual(card?[MPMediaItemPropertyAlbumTitle] as? String, "1995")
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(card?[MPMediaItemPropertyPlaybackDuration] as? Double, 100)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.video.rawValue)
        #if os(macOS)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)
        #endif
    }

    func testAPausedCardStandsStillButRemembersItsSpeed() {
        set(paused: true, speed: 1.25)
        NowPlaying.shared.update(from: model)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.25)
        #if os(macOS)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)
        #endif
    }

    func testWhatIsNotKnownIsLeftOffTheCard() {
        set(subtitle: "", duration: 0)
        model.isLive = true
        NowPlaying.shared.update(from: model)
        XCTAssertNil(card?[MPMediaItemPropertyArtist])
        XCTAssertNil(card?[MPMediaItemPropertyAlbumTitle])
        XCTAssertNil(card?[MPMediaItemPropertyPlaybackDuration], "a live channel has no length")
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
    }

    func testATickMovesOnlyThePlayhead() {
        set()
        NowPlaying.shared.update(from: model)
        // The length arrives after the first card, as it does when a stream opens.
        model.duration = 240
        model.title = "Heat (Director's Cut)"
        NowPlaying.shared.updateElapsed(50, rate: 2)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 50)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 2)
        XCTAssertEqual(card?[MPMediaItemPropertyPlaybackDuration] as? Double, 240)
        XCTAssertEqual(card?[MPMediaItemPropertyTitle] as? String, "Heat (Director's Cut)")
        XCTAssertEqual(card?[MPMediaItemPropertyArtist] as? String, "1995", "the rest of the card is as it was")

        NowPlaying.shared.updateElapsed(51, rate: 0)
        XCTAssertEqual(card?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        #if os(macOS)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused, "the Mac reads the state, not the rate")
        #endif
    }

    func testATickWithNoCardYetPutsTheWholeCardUp() {
        set(title: "Alien", subtitle: "")
        XCTAssertNil(card)
        NowPlaying.shared.updateElapsed(5, rate: 1)
        XCTAssertEqual(card?[MPMediaItemPropertyTitle] as? String, "Alien")
    }

    func testClearingTakesTheCardDown() {
        set()
        NowPlaying.shared.update(from: model)
        XCTAssertNotNil(card)
        NowPlaying.shared.clear()
        XCTAssertNil(card)
    }

    func testArtworkArrivesIsKeptForTheSameItemAndDroppedForTheNext() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nowplaying-\(UUID().uuidString).png")
        try CorePicture.png(width: 40, height: 60).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        set()
        model.artworkURL = file
        NowPlaying.shared.update(from: model)
        let arrived = await CoreWait.until { self.card?[MPMediaItemPropertyArtwork] != nil }
        XCTAssertTrue(arrived, "the picture never reached the card")

        model.position = 30
        NowPlaying.shared.update(from: model)
        XCTAssertNotNil(card?[MPMediaItemPropertyArtwork], "the same item keeps the picture it has")

        model.title = "Next Film"
        model.artworkURL = nil
        NowPlaying.shared.update(from: model)
        XCTAssertNil(card?[MPMediaItemPropertyArtwork], "a new item with no artwork must not go on showing the last one's")
    }

    // MARK: Which buttons are offered

    func testAFilmOffersSkippingButNoPreviousAndNoShuffle() {
        model.setQueue([])
        NowPlaying.shared.refreshCommandAvailability()
        let centre = MPRemoteCommandCenter.shared()
        XCTAssertFalse(centre.previousTrackCommand.isEnabled, "a film has no \"previous\"")
        XCTAssertTrue(centre.skipForwardCommand.isEnabled)
        XCTAssertTrue(centre.skipBackwardCommand.isEnabled)
        XCTAssertFalse(centre.changeShuffleModeCommand.isEnabled)
        XCTAssertFalse(centre.changeRepeatModeCommand.isEnabled)
        XCTAssertFalse(centre.likeCommand.isEnabled)
        XCTAssertFalse(centre.dislikeCommand.isEnabled)
        XCTAssertEqual(centre.changePlaybackRateCommand.supportedPlaybackRates.map(\.doubleValue), PlayerModel.speeds,
                       "the rates the system's menu offers are the video player's")
    }

    func testNextIsOfferedOnlyWhenSomethingFollows() throws {
        try XCTSkipIf(model.upNext != nil || model.upNextLocalId != nil || model.isShuffling, "the host app has something queued")
        let centre = MPRemoteCommandCenter.shared()
        model.setQueue([])
        XCTAssertFalse(centre.nextTrackCommand.isEnabled)
        // Queueing by hand refreshes the buttons itself.
        model.setQueue([CoreItem.movie("queued")])
        XCTAssertTrue(centre.nextTrackCommand.isEnabled)
        model.setQueue([])
        XCTAssertFalse(centre.nextTrackCommand.isEnabled)
    }
}
