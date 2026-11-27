//  Delete from Server against the real thing: the QA Jellyfin, and a real
//  Seerr, Radarr and Sonarr beside it (`AquariumQA/arr`, see its README).
//  Every test skips when that stack isn't running. The deleting tests each
//  use up a title; `arr/setup.py` puts them back.

#if os(iOS)
import XCTest

final class PhoneServerDeleteLiveTests: PhoneUITestCase {
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private var admin: JellyfinAPI!
    private var account: QA.Account!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try standardOnly()
        (account, admin) = try ArrQA.start()
    }

    private func itemId(_ name: String, _ kind: String) throws -> String { try ArrQA.itemId(name, kind, admin) }
    private func gone(_ id: String) -> Bool { ArrQA.gone(id, admin) }

    /// The film's own page, signed in as the admin and connected to the real
    /// Seerr, with Delete from Server… chosen from its More menu.
    private func askToDelete(_ id: String, named name: String) throws {
        launch(account: account, environment: ArrQA.environment)
        app.element(TestID.Home.root).waitToExist(90)
        openTitle(id, searching: name)
        app.button(TestID.Detail.more).tapNow(20)
        any(TestID.Detail.deleteFromServer).tapNow(15)
    }

    private func dialogButton(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    func testAFilmOnRadarrOffersJellyfinSeerrAndBoth() throws {
        try askToDelete(itemId("Nosferatu", "Movie"), named: "Nosferatu")
        XCTAssertTrue(dialogButton("Delete from Jellyfin").waitForExistence(timeout: 20), "Jellyfin's way is not offered")
        attachScreenshot("delete dialog, real Seerr")
        XCTAssertTrue(dialogButton("Delete from Seerr").exists, "Seerr's way is not offered")
        XCTAssertTrue(dialogButton("Delete from Both").exists, "Both is not offered")
    }

    /// The press-and-hold menu on a Home card has the entry, and it asks the
    /// same three-way question.
    func testTheCardMenuOffersItToo() throws {
        let id = try itemId("Nosferatu", "Movie")
        try ArrQA.putFirstOnContinueWatching(id, admin)
        launch(account: account, environment: ArrQA.environment)
        app.element(TestID.Home.root).waitToExist(90)
        let card = app.buttons.matching(identifier: TestID.Item.card(id)).firstMatch
        app.reveal(card)
        card.waitToExist(30)
        let window = app.windows.firstMatch
        for _ in 0..<3 {
            let mid = card.frame.midY
            guard mid < window.frame.minY + 140 || mid > window.frame.maxY - 140 else { break }
            let middle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: mid < window.frame.midY ? 160 : -160)))
        }
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        any(TestID.Item.menuDeleteFromServer).tapNow(15)
        XCTAssertTrue(dialogButton("Delete from Both").waitForExistence(timeout: 20), "Both is not offered from the card menu")
        XCTAssertTrue(dialogButton("Delete from Seerr").exists)
        XCTAssertTrue(dialogButton("Delete from Jellyfin").exists)
        attachScreenshot("delete dialog from the card menu")
        // The question has no Cancel on a phone: a tap above it is the way out.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertEqual(ArrQA.radarrHas(tmdb: 653), true, "leaving the question deleted nothing")
    }

    func testSeerrAloneTakesTheFilmOffRadarr() throws {
        let id = try itemId("Metropolis", "Movie")
        try askToDelete(id, named: "Metropolis")
        dialogButton("Delete from Seerr").tapNow(20)
        XCTAssertTrue(eventually(timeout: 30) { ArrQA.radarrHas(tmdb: 19) == false }, "Radarr still has the film")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ArrQA.folder.appendingPathComponent("media/movies/Metropolis (1927)/Metropolis (1927).mkv").path))
    }

    func testBothTakesTheFilmOffRadarrAndOutOfJellyfin() throws {
        let id = try itemId("Safety Last", "Movie")
        try askToDelete(id, named: "Safety Last")
        dialogButton("Delete from Both").tapNow(20)
        XCTAssertTrue(eventually(timeout: 30) { ArrQA.radarrHas(tmdb: 22596) == false }, "Radarr still has the film")
        XCTAssertTrue(eventually(timeout: 30) { self.gone(id) }, "Jellyfin still lists the film")
    }

    func testBothTakesAShowOffSonarrAndOutOfJellyfin() throws {
        let id = try itemId("Spaced", "Series")
        try askToDelete(id, named: "Spaced")
        dialogButton("Delete from Both").tapNow(20)
        XCTAssertTrue(eventually(timeout: 30) { ArrQA.sonarrHas(tvdb: 72658) == false }, "Sonarr still has the show")
        XCTAssertTrue(eventually(timeout: 30) { self.gone(id) }, "Jellyfin still lists the show")
    }
}

#endif
