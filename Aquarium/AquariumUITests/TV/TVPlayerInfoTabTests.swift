//  What the Apple TV player's Info tab can change (Player/Chrome/PlayerPanel
//  `InfoTab.actions`): on an episode with one after it, the Autoplay switch,
//  which stops the next one starting by itself. No sleep timer. `TVPlayerTests` covers what the tab says.

#if os(tvOS)
import XCTest

final class TVPlayerInfoTabTests: TVPlayerTestCase {
    func testInfoHasNoSleepTimer() throws {
        // The sleep timer was taken off the Apple TV: the television has its
        // own.
        let film = try Fixtures.require().item("film.long_direct").id
        try play(film, from: 300)
        defer {
            closePlayer()
            try? api().setResume(film, seconds: 300)
        }
        openPanel("info")
        app.element(TestID.Player.infoTitle).waitToExist(10)
        for minutes in [15, 30, 60, 90] {
            XCTAssertFalse(app.element(TestID.Player.sleepOption(minutes)).exists, "a \(minutes)-minute sleep choice on the TV")
        }
        XCTAssertFalse(app.element(TestID.Player.sleepCancel).exists)
    }

    func testAFilmHasNoAutoplaySwitch() throws {
        // Only an episode with something after it has a next one to start.
        let film = try Fixtures.require().item("film.long_direct").id
        try play(film, from: 300)
        defer {
            closePlayer()
            try? api().setResume(film, seconds: 300)
        }
        openPanel("info")
        app.element(TestID.Player.infoTitle).waitToExist(10)
        XCTAssertFalse(app.element(TestID.Player.stopAfterThis).exists, "a film offers Autoplay")
    }

    func testAutoplayOffInInfoStopsTheNextEpisodeStarting() throws {
        let fx = try Fixtures.require()
        let e3 = try fx.episode("show.short", season: 1, episode: 3)
        let e4 = try fx.episode("show.short", season: 1, episode: 4)
        try play(e3, from: 0)
        openPanel("info")
        let toggle = app.element(TestID.Player.stopAfterThis)
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "no Autoplay switch on an episode with a next one")
        XCTAssertTrue(toggle.label.contains("Autoplay: On"), toggle.label)
        pick(TestID.Player.stopAfterThis)
        waitUntil("the switch to read Off", timeout: 10) { toggle.label.contains("Autoplay: Off") }
        attachScreenshot("autoplay off")
        TVHook.debug("tab.none")
        XCTAssertTrue(app.element(TestID.Player.panel).waitToVanish(10), "the panel stayed open")
        TVHook.debug("nearEnd")
        // With autoplay off there is no countdown card, and nothing follows.
        XCTAssertFalse(app.element(TestID.Player.upNextCard).waitForExistence(timeout: 20), "the Up Next card counted down anyway")
        XCTAssertNil(try api().tvWaitForPlayback(of: e4, timeout: 30), "S01E04 started with autoplay off")
    }
}
#endif
