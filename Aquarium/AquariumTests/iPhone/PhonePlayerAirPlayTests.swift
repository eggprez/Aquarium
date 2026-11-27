//  AirPlay from the video player sends the picture, not the sound alone.
//  Two things left it with sound only: a saved audio offset, which AVPlayer
//  plays as a composition that cannot go to a television
//  (`PlayerModel.airPlayHoldsDelay`), and the long-form audio session the
//  music player leaves behind (`PlayerModel.sessionNeedsVideoCategory`).
//  The route itself needs a television: see MANUAL.md.

#if os(iOS)
import AVFoundation
import XCTest
@testable import Aquarium

@MainActor
final class PhonePlayerAirPlayTests: PhoneUnitTestCase {
    // MARK: The offset steps aside

    func testTheOffsetIsHeldWhileThePickerIsOpenOrTheRouteIsAirPlay() {
        XCTAssertTrue(PlayerModel.airPlayHoldsDelay(pickerOpen: true, routeIsAirPlay: false))
        XCTAssertTrue(PlayerModel.airPlayHoldsDelay(pickerOpen: false, routeIsAirPlay: true))
        XCTAssertTrue(PlayerModel.airPlayHoldsDelay(pickerOpen: true, routeIsAirPlay: true))
        XCTAssertFalse(PlayerModel.airPlayHoldsDelay(pickerOpen: false, routeIsAirPlay: false))
    }

    /// The picker opens on a composition: it has to be opened again plain.
    func testHoldingReopensAComposition() {
        XCTAssertTrue(PlayerModel.airPlayHoldRebuilds(
            holds: true, isActive: true, onApple: true, delay: 0.15, composed: true, carriesDelay: true))
    }

    /// A stream that never carried the offset (HLS) is left alone.
    func testHoldingLeavesAPlainStreamAlone() {
        XCTAssertFalse(PlayerModel.airPlayHoldRebuilds(
            holds: true, isActive: true, onApple: true, delay: 0.15, composed: false, carriesDelay: false))
    }

    /// AirPlay over: a file takes its offset back; a transcode cannot.
    func testReleasingGivesAFileItsOffsetBack() {
        XCTAssertTrue(PlayerModel.airPlayHoldRebuilds(
            holds: false, isActive: true, onApple: true, delay: -0.1, composed: false, carriesDelay: true))
        XCTAssertFalse(PlayerModel.airPlayHoldRebuilds(
            holds: false, isActive: true, onApple: true, delay: -0.1, composed: false, carriesDelay: false))
    }

    /// No offset saved, nothing playing, or mpv (which shifts the sound
    /// without a composition and is handed to AVPlayer for AirPlay anyway):
    /// nothing is reopened.
    func testNothingReopensWithoutAnOffsetAStreamOrAVPlayer() {
        XCTAssertFalse(PlayerModel.airPlayHoldRebuilds(
            holds: true, isActive: true, onApple: true, delay: 0, composed: false, carriesDelay: true))
        XCTAssertFalse(PlayerModel.airPlayHoldRebuilds(
            holds: true, isActive: false, onApple: true, delay: 0.15, composed: true, carriesDelay: true))
        XCTAssertFalse(PlayerModel.airPlayHoldRebuilds(
            holds: true, isActive: true, onApple: false, delay: 0.15, composed: true, carriesDelay: true))
    }

    /// The model's applied offset is zero while held and the saved one after.
    func testAppliedOffsetIsZeroWhileHeld() {
        let player = PlayerModel.shared
        let was = player.airPlayHoldsDelay
        defer { player.airPlayHoldsDelay = was }
        player.airPlayHoldsDelay = true
        XCTAssertEqual(player.appliedAudioDelay, 0)
        player.airPlayHoldsDelay = false
        XCTAssertEqual(player.appliedAudioDelay, player.audioDelay)
    }

    // MARK: The session

    /// The video player's own session is left as it is.
    func testTheVideoSessionIsKept() {
        XCTAssertFalse(PlayerModel.sessionNeedsVideoCategory(category: .playback, mode: .moviePlayback, policy: .default))
    }

    /// What music leaves behind — long-form audio, which AirPlays sound
    /// only — is replaced before a video plays.
    func testTheMusicSessionIsReplaced() {
        XCTAssertTrue(PlayerModel.sessionNeedsVideoCategory(category: .playback, mode: .default, policy: .longFormAudio))
        XCTAssertTrue(PlayerModel.sessionNeedsVideoCategory(category: .playback, mode: .moviePlayback, policy: .longFormAudio))
        XCTAssertTrue(PlayerModel.sessionNeedsVideoCategory(category: .playback, mode: .default, policy: .default))
        XCTAssertTrue(PlayerModel.sessionNeedsVideoCategory(category: .ambient, mode: .moviePlayback, policy: .default))
    }
}
#endif
