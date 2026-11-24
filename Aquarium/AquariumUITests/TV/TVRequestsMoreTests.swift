//  Requests on the Apple TV beyond `TVRequestsTests`: where each request
//  stands on its row, taking one back with the remote (and its "Cancel this
//  request?" dialog), a show's missing seasons offered on its own page and
//  asked for, and "Like This, Not in Your Library" under a film. Against the
//  stand-in Seerr server (`SeerrQA`); Sherlock (TMDB 19885) is in the QA
//  library with two of its four seasons, and TMDB 10378 is a film that is.

#if os(tvOS)
import XCTest

final class TVRequestsMoreTests: TVTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SeerrQA.require()
    }

    private func launchConnected(opening link: String? = nil) {
        markSessionsStale()
        var environment = SeerrQA.environment
        if let link { environment[TestLaunch.linkEnv] = link }
        launch(environment: environment)
        if link == nil { app.element(TestID.Home.root).waitToExist(60) }
    }

    /// A row's status, read from its own element or, where the card hands
    /// its children's words up to itself, from the row's label.
    private func status(of id: Int) -> String {
        let own = app.descendants(matching: .any).matching(identifier: TestID.Requests.rowStatus(id)).firstMatch
        if own.exists, !own.label.isEmpty { return own.label }
        return app.element(TestID.Requests.row(id)).label
    }

    func testEachRequestsRowSaysWhereItStands() throws {
        let me = try XCTUnwrap(QA.account()).name
        let pending = try XCTUnwrap(SeerrQA.request(as: me, type: "movie", tmdbId: 603))
        let approved = try XCTUnwrap(SeerrQA.request(as: me, type: "tv", tmdbId: 1396, seasons: [1, 2]))
        SeerrQA.approve(approved)
        launchConnected()
        openTab("requests", title: "Seerr", anchor: TestID.Requests.root)
        XCTAssertTrue(app.element(TestID.Requests.row(pending)).waitForExistence(timeout: 30))
        XCTAssertTrue(app.element(TestID.Requests.row(approved)).waitForExistence(timeout: 30))
        waitUntil("the pending row to say so", timeout: 15) { [weak self] in
            self?.status(of: pending).contains("Waiting for approval") ?? false
        }
        waitUntil("the approved row to say so", timeout: 15) { [weak self] in
            self?.status(of: approved).contains("On its way") ?? false
        }
        attachScreenshot("request statuses")
    }

    func testARequestIsTakenBackWithTheRemote() throws {
        let me = try XCTUnwrap(QA.account()).name
        let made = try XCTUnwrap(SeerrQA.request(as: me, type: "movie", tmdbId: 27205))
        launchConnected()
        openTab("requests", title: "Seerr", anchor: TestID.Requests.root)
        let row = app.element(TestID.Requests.row(made))
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        Remote.press(.down)
        XCTAssertTrue(Remote.focus(on: row, in: app), "the request's row can't be reached")
        Remote.select()
        app.element(TestID.Requests.titlePage("movie-27205")).waitToExist(30)
        let cancel = app.button(TestID.Requests.titleCancel)
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), "its own pending request has no Cancel Request")
        XCTAssertTrue(Remote.focus(on: cancel, in: app), "Cancel Request can't be reached (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        let confirm = app.element(TestID.Requests.titleCancelConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Cancel Request didn't ask first")
        attachScreenshot("cancel this request?")
        XCTAssertTrue(focusDialogButton("Cancel Request"), "can't reach the dialog's Cancel Request (on \(focusedLabel))")
        Remote.select()
        waitUntil("the request to be gone from Seerr", timeout: 20) { SeerrQA.requests().isEmpty }
        let standing = app.staticTexts[TestID.Requests.titleStanding].firstMatch
        waitUntil("the page to say it isn't here", timeout: 20) { standing.label == "Not in your library" }
        XCTAssertTrue(app.button(TestID.Requests.titleRequest).waitForExistence(timeout: 10), "nothing to ask for again")
        assertFocusPresent("the title page after cancelling")
    }

    func testAShowsMissingSeasonsAreOfferedOnItsPageAndAskedFor() throws {
        let sherlock = try XCTUnwrap(SeerrQA.libraryId("tv", tmdbId: 19885), "Sherlock isn't in the QA library")
        launchConnected(opening: "aquarium://item/\(sherlock)")
        app.element(TestID.Detail.page(sherlock)).waitToExist(60)
        assertFocusPresent("Sherlock's page")
        let banner = app.element(TestID.Requests.detailSeasons)
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "the page doesn't say more seasons exist")
        let more = app.button(TestID.Requests.detailSeasonsButton)
        // The button sits at the banner's far right, below the seasons row:
        // the remote reaches it with Down, not by heading right along the row.
        XCTAssertTrue(press(.down, until: { isFocused(on: more) }, max: 8) || Remote.focus(on: more, in: app, maxPresses: 30),
                      "Request… can't be reached (on \(focused?.summary ?? "nothing"))")
        attachScreenshot("missing seasons")
        Remote.select()
        app.element(TestID.Requests.titlePage("tv-19885")).waitToExist(30)
        assertFocusPresent("Sherlock's request page")
        let one = app.button(TestID.Requests.titleSeason(1))
        let three = app.button(TestID.Requests.titleSeason(3))
        let four = app.button(TestID.Requests.titleSeason(4))
        XCTAssertTrue(three.waitForExistence(timeout: 20), "no season 3 to tick")
        XCTAssertFalse(one.isEnabled, "a season already here can be ticked")
        XCTAssertEqual(three.value as? String, "selected")
        XCTAssertEqual(four.value as? String, "selected")
        let request = app.button(TestID.Requests.titleRequest)
        XCTAssertTrue(Remote.focus(on: request, in: app, maxPresses: 60), "Request can't be reached (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        waitUntil("the request for seasons 3 and 4", timeout: 20) {
            (SeerrQA.requests().first?["seasons"] as? [Int])?.sorted() == [3, 4]
        }
        assertFocusPresent("after asking for the seasons")
    }

    func testAFilmsPageOffersLikeThisFromSeerr() throws {
        let film = try XCTUnwrap(SeerrQA.libraryId("movie", tmdbId: 10378), "no TMDB film in the QA library")
        launchConnected(opening: "aquarium://item/\(film)")
        app.element(TestID.Detail.page(film)).waitToExist(60)
        let shelf = app.element(TestID.Requests.shelf("likeThis"))
        XCTAssertTrue(shelf.waitForExistence(timeout: 40), "no Like This, Not in Your Library under the film")
        let title = app.descendants(matching: .any).matching(identifier: TestID.Common.shelfTitle("requests-likeThis")).firstMatch
        if title.exists { XCTAssertEqual(title.label, "Like This, Not in Your Library") }
        let cards = app.elements(prefix: "requests.card.").allElementsBoundByIndex.filter { shelf.frame.intersects($0.frame) }
        XCTAssertFalse(cards.isEmpty, "the shelf has nothing to open")
        guard let card = cards.first else { return }
        XCTAssertTrue(Remote.focus(on: card, in: app, maxPresses: 80), "the shelf can't be reached (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        app.element(TestID.Requests.titleRoot).waitToExist(30)
        assertFocusPresent("a request page from Like This")
    }
}
#endif
