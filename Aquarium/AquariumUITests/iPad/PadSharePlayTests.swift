//  SharePlay's "start from whose progress?" on an iPad. A simulator has no
//  FaceTime, so the app is launched with made-up friends on the call
//  (`AQUARIUM_TEST_SHAREPLAY_PROGRESS`) and asks as it would of the person
//  who put the title on. The session itself is a hardware check (MANUAL.md).

#if os(iOS)
import XCTest

final class PadSharePlayTests: PadUITestCase {
    /// Alex is 11:40 in, Sam hasn't started, this account is 5:00 in: the
    /// question offers you, Alex and the beginning, and picking Alex moves
    /// the player there.
    func testWhoseProgressIsAskedAndThePickIsWherePlayGoes() throws {
        let film = try fx.item("film.long_direct")
        try api().setResume(film.id, seconds: 300)
        let me = try XCTUnwrap(QA.account()).name
        launch(environment: [TestLaunch.sharePlayProgressEnv: "Alex:700,Sam:0"])
        app.element(TestID.Home.root).waitToExist(60)
        play(film.id)

        // Alert buttons can be listed twice (a button inside a button): firstMatch.
        let alex = app.buttons[TestID.Player.sharePlayProgressChoice("alex")].firstMatch
        XCTAssertTrue(alex.waitForExistence(timeout: 60), "the question never came")
        XCTAssertTrue(app.staticTexts["Start from whose progress?"].firstMatch.exists)
        XCTAssertEqual(alex.label, "Alex · 11:40")
        let mine = app.buttons[TestID.Player.sharePlayProgressChoice(me.lowercased())].firstMatch
        XCTAssertTrue(mine.exists, "this account's own spot is offered")
        XCTAssertTrue(mine.label.hasPrefix("\(me) (you) · "), mine.label)
        XCTAssertTrue(app.buttons[TestID.Player.sharePlayProgressChoice("beginning")].firstMatch.exists)
        XCTAssertFalse(app.buttons[TestID.Player.sharePlayProgressChoice("sam")].firstMatch.exists, "no spot, no row")
        XCTAssertTrue(app.buttons[TestID.Player.sharePlayProgressKeep].firstMatch.exists)
        attachScreenshot("whose progress")

        alex.tap()
        XCTAssertTrue(alex.waitToVanish(10), "the question goes once answered")
        XCTAssertTrue(eventually(30) { (self.elapsedSeconds() ?? 0) >= 695 },
                      "didn't move to Alex's spot (read \(elapsedSeconds() ?? -1))")
        closePlayer()
    }

    /// "Keep Watching Here" leaves the player where it was.
    func testKeepWatchingHereStaysPut() throws {
        let film = try fx.item("film.long_direct")
        try api().setResume(film.id, seconds: 300)
        launch(environment: [TestLaunch.sharePlayProgressEnv: "Alex:700"])
        app.element(TestID.Home.root).waitToExist(60)
        play(film.id)

        let keep = app.buttons[TestID.Player.sharePlayProgressKeep].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 60), "the question never came")
        keep.tap()
        XCTAssertTrue(keep.waitToVanish(10))
        // Give a wrong seek time to land, then read the clock.
        Thread.sleep(forTimeInterval: 5)
        var at: Double = -1
        XCTAssertTrue(eventually(20) { at = self.elapsedSeconds() ?? -1; return at >= 295 },
                      "still at this account's 5:00 (read \(at))")
        XCTAssertLessThan(at, 600, "didn't jump to Alex's spot (read \(at))")
        closePlayer()
    }
}
#endif
