//  Delete from Server on an iPad against a real Seerr, Radarr and Sonarr
//  (`ArrQA`): the title page's disc row and a card's press-and-hold menu both
//  offer it, the question has Jellyfin, Seerr and Both, and Both takes a film
//  off Radarr and out of Jellyfin. Skips when the stack is down.

#if os(iOS)
import XCTest

final class PadServerDeleteLiveTests: PadUITestCase {
    private var admin: JellyfinAPI!
    private var account: QA.Account!

    override func setUpWithError() throws {
        try super.setUpWithError()
        (account, admin) = try ArrQA.start()
    }

    private func titlePage(_ id: String) {
        launch(account: account, environment: ArrQA.environment(opening: id))
        app.element(TestID.Detail.page(id)).waitToExist(90)
        app.element(TestID.Detail.actions).waitToExist(40)
    }

    private func assertAllThree(_ context: String) {
        XCTAssertTrue(ArrQA.button(app, TestID.Shell.serverDeleteBoth, "Delete from Both").waitForExistence(timeout: 20), "Both, \(context)")
        XCTAssertTrue(ArrQA.button(app, TestID.Shell.serverDeleteSeerr, "Delete from Seerr").exists, "Seerr, \(context)")
        XCTAssertTrue(ArrQA.button(app, TestID.Shell.serverDeleteJellyfin, "Delete from Jellyfin").exists, "Jellyfin, \(context)")
    }

    func testTheTitlePageOffersJellyfinSeerrAndBoth() throws {
        let id = try ArrQA.itemId("Nosferatu", "Movie", admin)
        titlePage(id)
        let delete = app.button(TestID.Detail.deleteFromServer)
        XCTAssertTrue(reveal(delete), "no Delete from Server on the title page")
        delete.padTap()
        assertAllThree("from the title page")
        attachScreenshot("iPad delete dialog")
        // On an iPad the question is a popover, which has no Cancel: a tap
        // outside it is the way out.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        XCTAssertEqual(ArrQA.radarrHas(tmdb: 653), true, "leaving the question deleted nothing")
    }

    func testTheCardMenuOffersIt() throws {
        let id = try ArrQA.itemId("Nosferatu", "Movie", admin)
        try ArrQA.putFirstOnContinueWatching(id, admin)
        launch(account: account, environment: ArrQA.environment)
        app.element(TestID.Home.root).waitToExist(90)
        let card = cardButton(id)
        XCTAssertTrue(reveal(card))
        contextMenu(on: card, waitingFor: TestID.Item.menuDeleteFromServer)
        app.button(TestID.Item.menuDeleteFromServer).padTap()
        assertAllThree("from the card menu")
    }

    func testBothTakesAFilmOffRadarrAndOutOfJellyfin() throws {
        let id = try ArrQA.itemId("The General", "Movie", admin)
        titlePage(id)
        let delete = app.button(TestID.Detail.deleteFromServer)
        XCTAssertTrue(reveal(delete))
        delete.padTap()
        ArrQA.button(app, TestID.Shell.serverDeleteBoth, "Delete from Both").padTap()
        XCTAssertTrue(ArrQA.eventually { ArrQA.radarrHas(tmdb: 961) == false }, "Radarr still has the film")
        XCTAssertTrue(ArrQA.eventually { ArrQA.gone(id, self.admin) }, "Jellyfin still lists the film")
    }
}
#endif
