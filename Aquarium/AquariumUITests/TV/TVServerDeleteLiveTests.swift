//  Delete from Server on an Apple TV against a real Seerr, Radarr and Sonarr
//  (`ArrQA`): the title page's row and a card's press-and-hold menu both
//  offer it, the question has Jellyfin, Seerr and Both, and Both takes a film
//  off Radarr and out of Jellyfin. Skips when the stack is down.

#if os(tvOS)
import XCTest

final class TVServerDeleteLiveTests: TVPlayerTestCase {
    private var admin: JellyfinAPI!
    private var account: QA.Account!

    override func setUpWithError() throws {
        try super.setUpWithError()
        (account, admin) = try ArrQA.start()
    }

    private func titlePage(_ id: String) {
        markSessionsStale()
        launch(account: account, environment: ArrQA.environment(opening: id))
        app.element(TestID.Detail.page(id)).waitToExist(90)
        assertFocusPresent("the title page")
    }

    private func askFromTitlePage() {
        let delete = app.element(TestID.Detail.deleteFromServer)
        XCTAssertTrue(delete.waitForExistence(timeout: 30), "no Delete from Server on the title page")
        XCTAssertTrue(Remote.focus(on: delete, in: app), "can't reach Delete from Server (on \(focused?.summary ?? "nothing"))")
        Remote.select()
    }

    private func assertAllThree(_ context: String) {
        XCTAssertTrue(ArrQA.button(app, TestID.Shell.serverDeleteBoth, "Delete from Both").waitForExistence(timeout: 20), "Both, \(context)")
        XCTAssertTrue(ArrQA.button(app, TestID.Shell.serverDeleteSeerr, "Delete from Seerr").exists, "Seerr, \(context)")
        XCTAssertTrue(ArrQA.button(app, TestID.Shell.serverDeleteJellyfin, "Delete from Jellyfin").exists, "Jellyfin, \(context)")
    }

    func testTheTitlePageOffersJellyfinSeerrAndBoth() throws {
        let id = try ArrQA.itemId("Nosferatu", "Movie", admin)
        titlePage(id)
        askFromTitlePage()
        assertAllThree("from the title page")
        attachScreenshot("Apple TV delete dialog")
        Remote.menu()
        XCTAssertEqual(ArrQA.radarrHas(tmdb: 653), true, "leaving the dialog deleted nothing")
    }

    func testTheCardMenuOffersIt() throws {
        let id = try ArrQA.itemId("Nosferatu", "Movie", admin)
        try ArrQA.putFirstOnContinueWatching(id, admin)
        markSessionsStale()
        launch(account: account, environment: ArrQA.environment)
        app.element(TestID.Home.root).waitToExist(90)
        let card = try XCTUnwrap(homeCard(id, onRow: TestID.Home.rowResume), "Nosferatu not on Continue Watching")
        guard openCardMenu(card, showing: TestID.Item.menuDeleteFromServer) else { return }
        chooseMenuEntry(TestID.Item.menuDeleteFromServer)
        assertAllThree("from the card menu")
        Remote.menu()
    }

    func testBothTakesAFilmOffRadarrAndOutOfJellyfin() throws {
        let id = try ArrQA.itemId("Safety Last", "Movie", admin)
        titlePage(id)
        askFromTitlePage()
        XCTAssertTrue(focusDialogButton("Both"), "can't reach Delete from Both (on \(focusedLabel))")
        Remote.select()
        XCTAssertTrue(ArrQA.eventually { ArrQA.radarrHas(tmdb: 22596) == false }, "Radarr still has the film")
        XCTAssertTrue(ArrQA.eventually { ArrQA.gone(id, self.admin) }, "Jellyfin still lists the film")
    }
}
#endif
