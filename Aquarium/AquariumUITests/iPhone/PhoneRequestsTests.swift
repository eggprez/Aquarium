//  Requests on the iPhone: Seerr in Search, a title's request page, the
//  Requests section, a show's missing seasons, and connecting in Settings.
//  Against the stand-in Seerr server (see `SeerrQA`).

#if os(iOS)
import XCTest

final class PhoneRequestsTests: PhoneUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SeerrQA.require()
    }

    private func launchConnected() {
        launch(environment: SeerrQA.environment)
        app.element(TestID.Home.root).waitToExist(90)
    }

    private func standing() -> String { app.staticTexts[TestID.Requests.titleStanding].firstMatch.label }

    func testASearchWithNoMatchesEndsInARequest() throws {
        launchConnected()
        let settingsReads = SeerrQA.callCount("/settings/public")
        search("Matrix")
        // Not in the library, and said so; with it, what can be asked for.
        app.element(TestID.Search.empty).waitToExist(30)
        let card = app.button(TestID.Requests.card("movie-603"))
        card.waitToExist(30)
        // Each search reads Cache Images again, so posters refused before it
        // was turned on are asked for again.
        XCTAssertGreaterThan(SeerrQA.callCount("/settings/public"), settingsReads, "the search read Seerr's settings again")
        assertOnScreen(card, "The Matrix's card")
        assertAboveKeyboard(card, "The Matrix's card")
        attachScreenshot("search offers a request (\(device.rawValue))")

        card.tapNow(20)
        app.element(TestID.Requests.titleRoot).waitToExist(30)
        let name = app.staticTexts[TestID.Requests.titleName].firstMatch
        name.waitToExist(30)
        XCTAssertEqual(name.label, "The Matrix")
        XCTAssertEqual(standing(), "Not in your library")
        let request = app.button(TestID.Requests.titleRequest)
        assertOnScreen(request, "Request")
        attachScreenshot("request page (\(device.rawValue))")

        request.tapNow(20)
        XCTAssertTrue(eventually(timeout: 20) { self.standing() == "Waiting for approval" }, "the page says where the request stands")
        XCTAssertEqual(SeerrQA.requests().count, 1)
        XCTAssertEqual(SeerrQA.requests().first?["tmdbId"] as? Int, 603)
        XCTAssertTrue(app.button(TestID.Requests.titleCancel).waitForExistence(timeout: 10), "its own request can be taken back")
        XCTAssertFalse(app.button(TestID.Requests.titleRequest).exists, "nothing left to ask for")
    }

    func testARequestCanBeCancelled() throws {
        try standardOnly()
        launchConnected()
        let me = try XCTUnwrap(QA.account()).name
        XCTAssertNotNil(SeerrQA.request(as: me, type: "movie", tmdbId: 27205))
        search("Inception")
        app.button(TestID.Requests.card("movie-27205")).tapNow(30)
        app.button(TestID.Requests.titleCancel).tapNow(30)
        app.button(TestID.Requests.titleCancelConfirm).tapNow(10)
        XCTAssertTrue(eventually(timeout: 20) { SeerrQA.requests().isEmpty }, "the request is gone from the server")
        XCTAssertTrue(eventually(timeout: 20) { self.standing() == "Not in your library" })
    }

    func testRequestsSectionShowsWhatWasAskedAndThingsToAskFor() throws {
        launchConnected()
        let me = try XCTUnwrap(QA.account()).name
        let pending = try XCTUnwrap(SeerrQA.request(as: me, type: "movie", tmdbId: 603))
        let approved = try XCTUnwrap(SeerrQA.request(as: me, type: "tv", tmdbId: 1396, seasons: [1, 2]))
        SeerrQA.approve(approved)

        moreSection("requests")
        app.element(TestID.Requests.root).waitToExist(30)
        app.button(TestID.Requests.row(pending)).waitToExist(30)
        XCTAssertEqual(app.staticTexts[TestID.Requests.rowStatus(pending)].firstMatch.label, "Waiting for approval")
        XCTAssertEqual(app.staticTexts[TestID.Requests.rowStatus(approved)].firstMatch.label, "On its way")
        XCTAssertTrue(app.staticTexts["The Matrix"].firstMatch.waitForExistence(timeout: 20), "cards are named, not numbered")
        XCTAssertFalse(app.element(TestID.Requests.postersOff).exists, "Cache Images is on: no warning")
        // One carousel: the requests sit side by side, not stacked.
        let first = app.button(TestID.Requests.row(pending)).frame
        let second = app.button(TestID.Requests.row(approved)).frame
        XCTAssertEqual(first.midY, second.midY, accuracy: 2, "requests share one row")
        XCTAssertNotEqual(first.minX, second.minX, "requests sit side by side")
        attachScreenshot("requests (\(device.rawValue))")

        // Trending straight under it, then the other rows.
        let trending = app.element(TestID.Requests.shelf("trending"))
        app.reveal(trending)
        XCTAssertTrue(trending.exists, "rows of things to ask for")
        XCTAssertGreaterThan(trending.frame.minY, app.element(TestID.Requests.mine).frame.minY, "Trending is under Your Requests")
        let popular = app.element(TestID.Requests.shelf("popularMovies"))
        app.reveal(popular)
        XCTAssertGreaterThan(popular.frame.minY, trending.frame.minY, "the other rows follow Trending")

        // A row opens the title's request page.
        app.reveal(app.button(TestID.Requests.row(pending)))
        app.button(TestID.Requests.row(pending)).tapNow(20)
        app.element(TestID.Requests.titlePage("movie-603")).waitToExist(30)
    }

    /// Seerr's rows answer after the requests: until each lands it stands as
    /// a placeholder, so the page says more is coming (it used to show the
    /// requests alone, the rows appearing later unannounced). The page is
    /// called Seerr, and its foot credits Seerr and TMDB.
    func testRowsShowTheyAreLoadingAndThePageCreditsSeerrAndTMDB() throws {
        try standardOnly()
        SeerrQA.slowRows(8)
        defer { SeerrQA.slowRows(0) }
        launchConnected()
        let me = try XCTUnwrap(QA.account()).name
        let made = try XCTUnwrap(SeerrQA.request(as: me, type: "movie", tmdbId: 603))

        moreSection("requests")
        app.element(TestID.Requests.root).waitToExist(30)
        app.button(TestID.Requests.row(made)).waitToExist(6)
        XCTAssertTrue(app.element(TestID.Requests.shelfLoading("trending")).exists, "Trending stands as a placeholder while it loads")
        XCTAssertFalse(app.element(TestID.Requests.shelf("trending")).exists)
        XCTAssertTrue(app.navigationBars["Seerr"].exists, "the page is called Seerr")
        attachScreenshot("seerr rows loading (\(device.rawValue))")

        // Landed: the placeholder gives way to the row.
        app.element(TestID.Requests.shelf("trending")).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Requests.shelfLoading("trending")).exists)
        let credit = app.staticTexts[TestID.Requests.credit].firstMatch
        app.reveal(credit)
        XCTAssertTrue(credit.label.contains("Seerr") && credit.label.contains("TMDB"), credit.label)
        XCTAssertTrue(credit.label.contains("isn't made, endorsed or certified"))
        attachScreenshot("seerr credit (\(device.rawValue))")
    }

    /// Seerr hands out no posters while its Cache Images is off; the page and
    /// Settings say why instead of showing blank cards with no explanation.
    func testPostersOffIsExplained() throws {
        try standardOnly()
        SeerrQA.cacheImages(false)
        defer { SeerrQA.cacheImages(true) }
        launchConnected()
        moreSection("requests")
        let notice = app.element(TestID.Requests.postersOff)
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the page says why there are no posters")
        assertOnScreen(notice, "the posters-off notice")
        attachScreenshot("posters off (\(device.rawValue))")

        openSettings()
        app.button(TestID.Settings.pageLink("account")).tapNow(20)
        let posters = app.element(TestID.Requests.settingsPosters)
        app.reveal(posters)
        XCTAssertTrue(posters.label.hasSuffix("Off"), posters.label)
    }

    func testAShowsMissingSeasonsCanBeAskedFor() throws {
        try standardOnly()
        let sherlock = try XCTUnwrap(SeerrQA.libraryId("tv", tmdbId: 19885), "Sherlock isn't in the QA library")
        launchConnected()
        openTitle(sherlock, searching: "Sherlock")
        let banner = app.element(TestID.Requests.detailSeasons)
        XCTAssertTrue(eventually(timeout: 30) { banner.exists }, "the page says more seasons exist")
        app.reveal(app.button(TestID.Requests.detailSeasonsButton))
        attachScreenshot("missing seasons")
        app.button(TestID.Requests.detailSeasonsButton).tapNow(20)

        app.element(TestID.Requests.titlePage("tv-19885")).waitToExist(30)
        let three = app.button(TestID.Requests.titleSeason(3))
        let four = app.button(TestID.Requests.titleSeason(4))
        app.reveal(four)
        XCTAssertEqual(three.value as? String, "selected")
        XCTAssertFalse(app.button(TestID.Requests.titleSeason(1)).isEnabled, "a season already here can't be ticked")
        four.tapNow(10)
        XCTAssertEqual(four.value as? String, "not selected")
        attachScreenshot("season ticks")

        let request = app.button(TestID.Requests.titleRequest)
        app.reveal(request, up: false)
        XCTAssertEqual(request.label, "Request 1 Season")
        request.tapNow(20)
        XCTAssertTrue(eventually(timeout: 20) { (SeerrQA.requests().first?["seasons"] as? [Int]) == [3] })
    }

    /// A film's, a show's and an episode's page each end in what Seerr would
    /// suggest beside them that isn't here; an episode's are its show's.
    func testTitlePagesOfferLikeThisFromSeerr() throws {
        try standardOnly()
        let api = try self.api
        let filmId = try XCTUnwrap(SeerrQA.libraryId("movie", tmdbId: 10378), "no TMDB film in the QA library")
        let showId = try XCTUnwrap(SeerrQA.libraryId("tv", tmdbId: 19885), "Sherlock isn't in the QA library")
        let film = try XCTUnwrap(api.json("/Items/\(filmId)?userId=\(api.userId)") as? [String: Any])
        let episodes = try XCTUnwrap(api.json("/Shows/\(showId)/Episodes?userId=\(api.userId)&Limit=1") as? [String: Any])
        let episode = try XCTUnwrap((episodes["Items"] as? [[String: Any]])?.first, "Sherlock has no episodes")
        launchConnected()

        func expectShelf(_ what: String) {
            let shelf = app.element(TestID.Requests.shelf("likeThis"))
            XCTAssertTrue(eventually(timeout: 30) {
                if !shelf.exists { self.app.swipeUp() }
                return shelf.exists
            }, "\(what)'s page offers titles like it from Seerr")
            app.reveal(shelf)
            XCTAssertEqual(app.staticTexts[TestID.Common.shelfTitle("requests-likeThis")].firstMatch.label, "Like This, Not in Your Library")
            XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "with something to open")
        }
        // The shelf's anchor doesn't hand its cards down; they are found by id.
        var cards: XCUIElementQuery {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "requests.card."))
        }

        openTitle(filmId, searching: try XCTUnwrap(film["Name"] as? String))
        expectShelf("a film")
        attachScreenshot("film like this")
        // A card opens the title's request page.
        let card = cards.firstMatch
        app.reveal(card)
        card.tapNow(20)
        app.element(TestID.Requests.titleRoot).waitToExist(30)

        openTitle(showId, searching: "Sherlock")
        expectShelf("a show")
        attachScreenshot("show like this")

        openTitle(try XCTUnwrap(episode["Id"] as? String), searching: try XCTUnwrap(episode["Name"] as? String))
        expectShelf("an episode")
        attachScreenshot("episode like this")
        XCTAssertGreaterThan(SeerrQA.callCount("/tv/19885/recommendations"), 0, "the episode asked about its show")
    }

    func testAnExpiredSessionRenewsItselfQuietly() throws {
        try standardOnly()
        launchConnected()
        SeerrQA.expireSessions()
        XCTAssertEqual(SeerrQA.sessionCount, 0)
        // (Every session, other tests' too: suites run one at a time.)
        moreSection("requests")
        app.element(TestID.Requests.mine).waitToExist(30)
        XCTAssertTrue(eventually(timeout: 20) { SeerrQA.sessionCount == 1 }, "the app signed in again by itself")
        XCTAssertTrue(app.element(TestID.Requests.shelf("trending")).waitForExistence(timeout: 30))
        XCTAssertFalse(app.element(TestID.Requests.notConnected).exists)
    }

    func testConnectingAndDisconnectingInSettings() throws {
        try standardOnly()
        launchHome()
        // No Seerr, no Requests.
        tab("More")
        app.element(TestID.Shell.more).waitToExist(20)
        XCTAssertFalse(app.element(TestID.Shell.moreRow("requests")).exists)

        let sessionsBefore = SeerrQA.sessionCount
        openSettings()
        app.button(TestID.Settings.pageLink("account")).tapNow(20)
        let connect = app.button(TestID.Requests.settingsConnect)
        app.reveal(connect)
        connect.tapNow(20)
        app.element(TestID.Requests.connectRoot).waitToExist(20)
        let address = app.textFields[TestID.Requests.connectAddress].firstMatch
        address.tapNow(20)
        address.typeText(SeerrQA.server)
        app.button(TestID.Requests.connectContinue).tapNow(20)
        // Plain http: said before anything is sent.
        app.element(TestID.Requests.connectInsecure).waitToExist(30)
        attachScreenshot("unencrypted warning")
        app.button(TestID.Requests.connectAnyway).tapNow(20)

        let server = app.staticTexts[TestID.Requests.settingsServer].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 40), "connected without a password being typed")
        XCTAssertTrue(server.label.hasSuffix(SeerrQA.server.replacingOccurrences(of: "http://", with: "")), server.label)
        XCTAssertEqual(SeerrQA.sessionCount, sessionsBefore + 1)
        attachScreenshot("connected")

        let disconnect = app.button(TestID.Requests.settingsDisconnect)
        app.reveal(disconnect)
        disconnect.tapNow(20)
        app.buttons["Disconnect"].firstMatch.tapNow(10)
        XCTAssertTrue(app.button(TestID.Requests.settingsConnect).waitForExistence(timeout: 30))
        XCTAssertTrue(eventually(timeout: 20) { SeerrQA.sessionCount == sessionsBefore }, "Seerr was told the session is over")
    }
}
#endif
