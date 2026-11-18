//  SharePlay's "start from whose progress?" on the iPhone. A simulator has no
//  FaceTime, so the app is launched with made-up friends on the call
//  (`AQUARIUM_TEST_SHAREPLAY_PROGRESS`) and asks as it would of the person
//  who put the title on. The session itself is a hardware check (MANUAL.md).

#if os(iOS)
import XCTest

final class PhoneSharePlayTests: PhoneUITestCase {
    /// Alex is 11:40 in, Sam hasn't started, this account is 5:00 in: the
    /// question offers you, Alex and the beginning, and picking Alex moves
    /// the player there.
    func testWhoseProgressIsAskedAndThePickIsWherePlayGoes() throws {
        try standardOnly()
        let api = try self.api
        let film = try Fixtures.require().item("film.long_direct")
        try api.setResume(film.id, seconds: 300)
        let me = try XCTUnwrap(QA.account()).name
        launch(environment: [TestLaunch.sharePlayProgressEnv: "Alex:700,Sam:0"])
        app.element(TestID.Home.root).waitToExist(90)
        openTitle(film.id, searching: film.name)
        playFromDetail()

        // iOS lists each alert button twice (a button inside a button): firstMatch.
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
        attachScreenshot("whose progress (\(device.rawValue))")

        alex.tap()
        XCTAssertNotNil(waitForServerPosition(api, itemId: film.id, atLeast: 700, timeout: 60), "didn't move to Alex's spot")
    }
}
#endif
