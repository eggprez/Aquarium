//  Delete from Server on the Mac against a real Seerr, Radarr and Sonarr
//  (`ArrQA`): the title page's button and a card's context menu both offer
//  it, the question has Jellyfin, Seerr and Both, and Both takes a show off
//  Sonarr and out of Jellyfin. Skips when the stack is down.

#if os(macOS)
import XCTest

final class MacServerDeleteLiveTests: MacUITestCase {
    private var admin: JellyfinAPI!
    private var account: QA.Account!

    override func setUpWithError() throws {
        try super.setUpWithError()
        (account, admin) = try ArrQA.start()
    }

    private func titlePage(_ id: String) {
        launch(account: account, environment: ArrQA.environment(opening: id))
        app.element(TestID.Detail.page(id)).waitToExist(90)
    }

    /// A button of the question in the window (the Touch Bar carries copies).
    private func dialogButton(_ id: String, _ label: String) -> XCUIElement {
        let inWindow = app.windows.descendants(matching: .button)
        let byId = inWindow.matching(identifier: id).firstMatch
        return byId.exists ? byId : inWindow.matching(NSPredicate(format: "label == %@ OR title == %@", label, label)).firstMatch
    }

    private func assertAllThree(_ context: String) {
        XCTAssertTrue(dialogButton(TestID.Shell.serverDeleteBoth, "Delete from Both").waitForExistence(timeout: 20), "Both, \(context)")
        XCTAssertTrue(dialogButton(TestID.Shell.serverDeleteSeerr, "Delete from Seerr").exists, "Seerr, \(context)")
        XCTAssertTrue(dialogButton(TestID.Shell.serverDeleteJellyfin, "Delete from Jellyfin").exists, "Jellyfin, \(context)")
    }

    func testTheTitlePageOffersJellyfinSeerrAndBoth() throws {
        let id = try ArrQA.itemId("Nosferatu", "Movie", admin)
        titlePage(id)
        app.button(TestID.Detail.deleteFromServer).tapWhenReady(30)
        assertAllThree("from the title page")
        attachScreenshot("Mac delete dialog")
        dialogButton(TestID.Shell.serverDeleteCancel, "Cancel").click()
        XCTAssertEqual(ArrQA.radarrHas(tmdb: 653), true, "Cancel deleted nothing")
    }

    func testTheCardMenuOffersIt() throws {
        let id = try ArrQA.itemId("Nosferatu", "Movie", admin)
        let views = try admin.json("/UserViews?userId=\(admin.userId)") as? [String: Any]
        let library = try XCTUnwrap((views?["Items"] as? [[String: Any]])?.first { $0["Name"] as? String == "Arr Movies" }?["Id"] as? String,
                                    "no Arr Movies library (run arr/up.sh)")
        launch(account: account, environment: ArrQA.environment)
        app.element(TestID.Home.root).waitToExist(90)
        openSection("lib-\(library)")
        card(id).rightClick()
        menuChoice(TestID.Item.menuDeleteFromServer, title: "Delete from Server…").click()
        assertAllThree("from the context menu")
    }

    func testBothTakesAShowOffSonarrAndOutOfJellyfin() throws {
        let id = try ArrQA.itemId("Fawlty Towers", "Series", admin)
        titlePage(id)
        app.button(TestID.Detail.deleteFromServer).tapWhenReady(30)
        dialogButton(TestID.Shell.serverDeleteBoth, "Delete from Both").tapWhenReady(20)
        XCTAssertTrue(ArrQA.eventually { ArrQA.sonarrHas(tvdb: 75932) == false }, "Sonarr still has the show")
        XCTAssertTrue(ArrQA.eventually { ArrQA.gone(id, self.admin) }, "Jellyfin still lists the show")
    }
}
#endif
