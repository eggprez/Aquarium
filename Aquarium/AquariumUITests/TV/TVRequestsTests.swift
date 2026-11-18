//  Requests on the Apple TV: a tab of its own while Seerr is connected, a
//  title asked for with the remote, and Seerr's titles under a search.
//  Against the stand-in Seerr server (see `SeerrQA`).

#if os(tvOS)
import XCTest

final class TVRequestsTests: TVTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SeerrQA.require()
    }

    private func launchConnected() {
        markSessionsStale()
        launch(environment: SeerrQA.environment)
        app.element(TestID.Home.root).waitToExist(60)
        assertFocusPresent("Home after launch")
    }

    func testNoRequestsTabWithoutSeerr() {
        launchHome()
        XCTAssertTrue(focusTabStrip())
        XCTAssertFalse(tab("requests", title: "Seerr").exists)
    }

    func testTheRequestsTabListsRequestsAndThingsToAskFor() throws {
        launchConnected()
        let me = try XCTUnwrap(QA.account()).name
        let made = try XCTUnwrap(SeerrQA.request(as: me, type: "movie", tmdbId: 603))
        openTab("requests", title: "Seerr", anchor: TestID.Requests.root)
        let row = app.element(TestID.Requests.row(made))
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(app.element(TestID.Requests.shelf("trending")).waitForExistence(timeout: 30))
        Remote.press(.down)
        XCTAssertTrue(Remote.focus(on: row, in: app), "the request's row can be reached with the remote")
        attachScreenshot("requests")
        Remote.select()
        app.element(TestID.Requests.titlePage("movie-603")).waitToExist(30)
        assertFocusPresent("the request page")
        attachScreenshot("request page")
    }

    func testAFilmIsAskedForWithTheRemote() throws {
        launchConnected()
        openTab("requests", title: "Seerr", anchor: TestID.Requests.root)
        let card = app.element(TestID.Requests.card("movie-27205"))
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Inception is on a row")
        Remote.press(.down)
        XCTAssertTrue(Remote.focus(on: card, in: app, maxPresses: 60), "its card can be reached")
        Remote.select()
        app.element(TestID.Requests.titlePage("movie-27205")).waitToExist(30)
        let request = app.element(TestID.Requests.titleRequest)
        XCTAssertTrue(request.waitForExistence(timeout: 20))
        XCTAssertTrue(Remote.focus(on: request, in: app), "Request can be reached")
        Remote.select()
        waitUntil("the request on the server", timeout: 20) { SeerrQA.requests().first?["tmdbId"] as? Int == 27205 }
        waitUntil("the page saying so", timeout: 20) { [weak self] in
            self?.app.staticTexts[TestID.Requests.titleStanding].firstMatch.label == "Waiting for approval"
        }
        assertFocusPresent("after requesting")
        attachScreenshot("requested")
    }

    func testSearchOffersWhatTheLibraryLacks() throws {
        launchConnected()
        openTab("search", title: "Search", anchor: TestID.Search.root)
        Remote.press(.down)
        let field = app.element(TestID.Search.field)
        XCTAssertTrue(Remote.focus(on: field, in: app))
        Remote.select()
        waitUntil("the keyboard", timeout: 10) { [weak self] in
            (self?.app.keyboards.count ?? 0) > 0 || (self?.focused?.elementType == .key)
        }
        app.typeText("Matrix")
        Remote.menu()
        let card = app.element(TestID.Requests.card("movie-603"))
        XCTAssertTrue(card.waitForExistence(timeout: 30), "The Matrix is offered")
        XCTAssertTrue(Remote.focus(on: card, in: app), "and can be reached")
        attachScreenshot("search offers a request")
    }
}
#endif
