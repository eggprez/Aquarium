//  Play at a Set Quality holds its rung for the sitting (found by the iPad
//  suite, 2026-11-13). Plain `XCTestCase`, not `PadUnitTestCase`: the model is
//  the same on an iPhone, so these run on either.

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class PadQualityPinTests: XCTestCase {
    private var player: PlayerModel { PlayerModel.shared }
    private var prefs: Preferences { Preferences.shared }
    private var saved: (adaptive: Bool, bitrate: Int?)!

    override func setUp() async throws {
        saved = (prefs.adaptiveQuality, prefs.defaultBitrate)
        player.qualityPinned = false
    }

    override func tearDown() async throws {
        player.qualityPinned = false
        prefs.adaptiveQuality = saved.adaptive
        prefs.defaultBitrate = saved.bitrate
    }

    // MARK: Play at a set quality

    /// PadDetailTests.testQualityMenuPlaysAtTheRungChosen: a rung chosen on
    /// the title page played, and the player still said Auto (and Auto was
    /// free to climb away from it).
    func testAPinnedRungIsNotAutoAndLeavesThePreferenceAlone() {
        prefs.adaptiveQuality = true
        player.qualityPinned = true
        XCTAssertNotEqual(player.qualitySelection, .auto)
        XCTAssertFalse(player.adaptsQuality, "Auto doesn't steer a pinned rung")
        XCTAssertTrue(prefs.adaptiveQuality, "the saved preference is untouched")
        player.qualityPinned = false
        XCTAssertEqual(player.qualitySelection, .auto)
    }

    func testChoosingAutoInThePlayerDropsThePin() async {
        prefs.adaptiveQuality = true
        player.qualityPinned = true
        await player.chooseQuality(.auto)
        XCTAssertFalse(player.qualityPinned)
        XCTAssertEqual(player.qualitySelection, .auto)
    }

    func testAChosenBitrateOnAFreshStartPinsAndAPlainStartDoesNot() async {
        ClientStub.install()
        defer { ClientStub.remove() }
        var item = BaseItem()
        item.Id = "pinned-film"
        item.type = "Movie"
        // Nothing is stubbed: PlaybackInfo answers 404 and the start fails,
        // after the pin has been decided.
        await player.play(item: item, options: StreamOptions(maxBitrate: 2_500_000, bitrateIsChosen: true))
        XCTAssertTrue(player.qualityPinned, "Play at a Set Quality pins the rung")
        _ = player.stop(reason: "test")
        item.Id = "plain-film"
        await player.play(item: item)
        XCTAssertFalse(player.qualityPinned, "a plain Play starts on the preference")
        _ = player.stop(reason: "test")
    }
}
#endif
