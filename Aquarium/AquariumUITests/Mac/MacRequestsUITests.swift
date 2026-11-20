//  Requests on the Mac: the sidebar's row and its page, Seerr's titles under
//  a search, and a request made from a title's page. Against the stand-in
//  Seerr server (see `SeerrQA`).

#if os(macOS)
import XCTest

final class MacRequestsUITests: MacUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SeerrQA.require()
    }

    /// A Mac's text carries its words as its value; a Label, as its label.
    private func text(_ element: XCUIElement) -> String {
        element.label.isEmpty ? (element.value as? String ?? "") : element.label
    }

    private func launchConnected() {
        launch(environment: SeerrQA.environment)
        app.element(TestID.Home.root).waitToExist(60)
        app.activate()
    }

    func testTheSidebarGainsRequests() throws {
        launchConnected()
        XCTAssertTrue(sidebarRow("requests").waitForExistence(timeout: 30), "the row arrives with the connection")
        openSection("requests")
        app.element(TestID.Requests.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Requests.shelf("trending")).waitForExistence(timeout: 30))
        attachScreenshot("requests")
    }

    /// Seerr's rows answer after the requests: until each lands it stands as
    /// a placeholder, so the page says more is coming. The page is called
    /// Seerr, and its foot credits Seerr and TMDB.
    func testRowsShowTheyAreLoadingAndThePageCreditsSeerrAndTMDB() throws {
        SeerrQA.slowRows(8)
        defer { SeerrQA.slowRows(0) }
        launchConnected()
        XCTAssertTrue(sidebarRow("requests").waitForExistence(timeout: 30))
        XCTAssertTrue(text(sidebarRow("requests")).contains("Seerr") || app.staticTexts["Seerr"].exists,
                      "the row is called Seerr")
        openSection("requests")
        app.element(TestID.Requests.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Requests.shelfLoading("trending")).waitForExistence(timeout: 6),
                      "Trending stands as a placeholder while it loads")
        XCTAssertFalse(app.element(TestID.Requests.shelf("trending")).exists)
        attachScreenshot("seerr rows loading")

        app.element(TestID.Requests.shelf("trending")).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Requests.shelfLoading("trending")).exists)
        let credit = app.staticTexts[TestID.Requests.credit].firstMatch
        credit.waitToExist(10)
        scrollIntoView(credit)
        let words = text(credit)
        XCTAssertTrue(words.contains("Seerr") && words.contains("TMDB"), words)
        attachScreenshot("seerr credit")
    }

    func testSearchOffersARequestAndThePageMakesIt() throws {
        launchConnected()
        searchFromSidebar("Inception")
        let card = solid(TestID.Requests.card("movie-27205"))
        attachScreenshot("search offers a request")
        clickCentre(card)
        app.element(TestID.Requests.titlePage("movie-27205")).waitToExist(30)
        let standing = app.staticTexts[TestID.Requests.titleStanding].firstMatch
        standing.waitToExist(20)
        XCTAssertEqual(text(standing), "Not in your library")
        app.button(TestID.Requests.titleRequest).tapWhenReady(20)
        XCTAssertTrue(eventually(20) { SeerrQA.requests().first?["tmdbId"] as? Int == 27205 })
        XCTAssertTrue(eventually(20) { self.text(standing) == "Waiting for approval" })
        attachScreenshot("requested")
    }

    func testConnectingInSettings() throws {
        launchToHome()
        XCTAssertFalse(sidebarRow("requests").exists, "no Seerr, no row")
        let sessionsBefore = SeerrQA.sessionCount
        app.typeKey(",", modifierFlags: .command)
        app.element(TestID.Settings.window).waitToExist(20)
        let account = app.descendants(matching: .any).matching(identifier: TestID.Settings.pageLink("account")).firstMatch
        if account.waitForExistence(timeout: 5) { account.click() } else { app.toolbars.buttons["Account"].firstMatch.click() }
        let connect = app.button(TestID.Requests.settingsConnect)
        connect.waitToExist(20)
        scrollIntoView(connect)
        connect.click()
        let address = app.textFields[TestID.Requests.connectAddress].firstMatch
        address.waitToExist(20)
        address.click()
        address.typeText(SeerrQA.server)
        app.button(TestID.Requests.connectContinue).tapWhenReady(10)
        app.element(TestID.Requests.connectInsecure).waitToExist(30)
        app.button(TestID.Requests.connectAnyway).tapWhenReady(10)
        XCTAssertTrue(app.staticTexts[TestID.Requests.settingsServer].firstMatch.waitForExistence(timeout: 40))
        XCTAssertEqual(SeerrQA.sessionCount, sessionsBefore + 1)
        attachScreenshot("connected")
    }
}
#endif
