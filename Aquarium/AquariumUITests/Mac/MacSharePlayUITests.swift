//  SharePlay's "start from whose progress?" on the Mac. No FaceTime call in a
//  test, so the app is launched with made-up friends on the call
//  (`AQUARIUM_TEST_SHAREPLAY_PROGRESS`) and asks as it would of the person
//  who put the title on. The session itself is a hardware check (MANUAL.md).

#if os(macOS)
import XCTest

final class MacSharePlayUITests: MacUITestCase {
    /// A Mac's text carries its words as its value; a Label, as its label.
    private func words(_ element: XCUIElement) -> String {
        element.label.isEmpty ? (element.value as? String ?? element.title) : element.label
    }

    /// Alex is 11:40 in, Sam hasn't started, this account is 5:00 in: the
    /// question offers you, Alex and the beginning, and picking Alex moves
    /// the player there.
    func testWhoseProgressIsAskedAndThePickIsWherePlayGoes() throws {
        let film = try Fixtures.require().item("film.long_direct")
        let api = try JellyfinAPI.signIn()
        try api.setResume(film.id, seconds: 300)
        let me = try XCTUnwrap(QA.account()).name
        launch(environment: [TestLaunch.sharePlayProgressEnv: "Alex:700,Sam:0"])
        app.element(TestID.Home.root).waitToExist(60)
        app.activate()
        play(film)

        let alex = app.buttons[TestID.Player.sharePlayProgressChoice("alex")].firstMatch
        XCTAssertTrue(alex.waitForExistence(timeout: 60), "the question never came")
        XCTAssertEqual(words(alex), "Alex · 11:40")
        let mine = app.buttons[TestID.Player.sharePlayProgressChoice(me.lowercased())].firstMatch
        XCTAssertTrue(mine.exists, "this account's own spot is offered")
        XCTAssertTrue(words(mine).hasPrefix("\(me) (you) · "), words(mine))
        XCTAssertTrue(app.buttons[TestID.Player.sharePlayProgressChoice("beginning")].firstMatch.exists)
        XCTAssertFalse(app.buttons[TestID.Player.sharePlayProgressChoice("sam")].firstMatch.exists, "no spot, no row")
        // Regression (2026-11-19): a Mac alert hid the cancel-role button,
        // leaving no visible way to decline.
        XCTAssertTrue(app.buttons[TestID.Player.sharePlayProgressKeep].firstMatch.exists, "Keep Watching Here is shown")
        attachScreenshot("whose progress")

        alex.click()
        XCTAssertTrue(alex.waitToVanish(10), "the question goes once answered")
        XCTAssertTrue(eventually(60) {
            (try? api.macSessions().first { $0.nowPlayingId == film.id }?.positionSeconds ?? 0) ?? 0 >= 700
        }, "didn't move to Alex's spot")
    }
}
#endif
