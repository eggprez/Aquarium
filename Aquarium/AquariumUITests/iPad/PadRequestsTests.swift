//  Requests on an iPad: the sidebar's Requests row and its page, Seerr's
//  titles under a search, a request made from a title's page, and what a
//  person's page gains. Against the stand-in Seerr server (see `SeerrQA`).

#if os(iOS)
import XCTest

final class PadRequestsTests: PadUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SeerrQA.require()
    }

    private func launchConnected() {
        launch(environment: SeerrQA.environment)
        app.element(TestID.Home.root).waitToExist(60)
    }

    private func search(_ term: String) {
        app.button(TestID.Sidebar.searchRow).padTap()
        app.element(TestID.Search.root).waitToExist(20)
        let field = app.textFields[TestID.Search.field].exists
            ? app.textFields[TestID.Search.field] : app.searchFields[TestID.Search.field]
        field.padTap()
        field.typeText(term + "\n")
    }

    func testTheSidebarGainsRequestsOnlyWhenConnected() throws {
        launchHome()
        XCTAssertFalse(sidebarRowIds().contains("requests"), "no Seerr, no row")
        app.terminate()

        launchConnected()
        XCTAssertTrue(eventually(30) { self.sidebarRowIds().contains("requests") }, "the row arrives with the connection")
        showSection("requests")
        app.element(TestID.Requests.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Requests.mineEmpty).waitForExistence(timeout: 20), "nothing asked for yet")
        let trending = app.element(TestID.Requests.shelf("trending"))
        XCTAssertTrue(trending.waitForExistence(timeout: 30))
        XCTAssertGreaterThan(trending.frame.minX, sidebar.frame.maxX - 1, "the page is beside the sidebar, not under it")
        attachScreenshot("requests")
    }

    /// Seerr's rows answer after the requests: until each lands it stands as
    /// a placeholder, so the page says more is coming. The page is called
    /// Seerr, and its foot credits Seerr and TMDB.
    func testRowsShowTheyAreLoadingAndThePageCreditsSeerrAndTMDB() throws {
        SeerrQA.slowRows(8)
        defer { SeerrQA.slowRows(0) }
        launchConnected()
        showSection("requests")
        app.element(TestID.Requests.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Requests.shelfLoading("trending")).waitForExistence(timeout: 6),
                      "Trending stands as a placeholder while it loads")
        XCTAssertFalse(app.element(TestID.Requests.shelf("trending")).exists)
        XCTAssertTrue(app.navigationBars["Seerr"].exists || app.staticTexts["Seerr"].exists, "the page is called Seerr")
        attachScreenshot("seerr rows loading")

        app.element(TestID.Requests.shelf("trending")).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Requests.shelfLoading("trending")).exists)
        let credit = app.staticTexts[TestID.Requests.credit].firstMatch
        _ = reveal(credit)
        XCTAssertTrue(credit.label.contains("Seerr") && credit.label.contains("TMDB"), credit.label)
        XCTAssertTrue(credit.label.contains("isn't made, endorsed or certified"))
        attachScreenshot("seerr credit")
    }

    func testSearchOffersARequestAndThePageMakesIt() throws {
        launchConnected()
        search("Inception")
        app.element(TestID.Search.empty).waitToExist(30)
        let card = app.button(TestID.Requests.card("movie-27205"))
        card.waitToExist(30)
        attachScreenshot("search offers a request")
        card.padTap()

        app.element(TestID.Requests.titlePage("movie-27205")).waitToExist(30)
        let standing = app.staticTexts[TestID.Requests.titleStanding].firstMatch
        standing.waitToExist(20)
        XCTAssertEqual(standing.label, "Not in your library")
        attachScreenshot("request page")
        app.button(TestID.Requests.titleRequest).padTap()
        XCTAssertTrue(eventually(20) { standing.label == "Waiting for approval" })
        XCTAssertEqual(SeerrQA.requests().first?["tmdbId"] as? Int, 27205)

        // And it is in Requests, named.
        showSection("requests")
        let id = try XCTUnwrap(SeerrQA.requests().first?["id"] as? Int)
        XCTAssertTrue(app.button(TestID.Requests.row(id)).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Inception"].firstMatch.waitForExistence(timeout: 20))
    }

    func testLibraryResultsStillLeadAndSeerrFollows() throws {
        launchConnected()
        // "The" matches library titles and titles Seerr knows.
        search("The Expanse")
        app.element(TestID.Search.results).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Requests.card("tv-63639")).exists,
                       "a show that is partly here is offered from its own page, not as a stranger")
    }

    func testAPersonsPageShowsTheRestOfTheirWork() throws {
        let sherlock = try XCTUnwrap(SeerrQA.libraryId("tv", tmdbId: 19885), "Sherlock isn't in the QA library")
        launchConnected()
        search("Sherlock")
        cardButton(sherlock).padTap(30)
        app.element(TestID.Detail.page(sherlock)).waitToExist(30)
        // The show's own page says seasons are missing.
        XCTAssertTrue(eventually(30) { self.app.element(TestID.Requests.detailSeasons).exists })
        _ = reveal(app.element(TestID.Requests.detailSeasons))
        attachScreenshot("missing seasons")

        let cumberbatch = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Benedict Cumberbatch")).firstMatch
        XCTAssertTrue(cumberbatch.waitForExistence(timeout: 20), "the cast lists him")
        _ = reveal(cumberbatch)
        cumberbatch.padTap()
        app.element(TestID.Person.root).waitToExist(30)
        let shelf = app.element(TestID.Requests.shelf("person"))
        XCTAssertTrue(eventually(30) { shelf.exists }, "what of his isn't here")
        XCTAssertTrue(app.button(TestID.Requests.card("movie-284052")).exists, "Doctor Strange can be asked for")
        XCTAssertFalse(app.button(TestID.Requests.card("tv-19885")).exists, "Sherlock is not offered: part of it is here")
        attachScreenshot("person")
    }
}
#endif
