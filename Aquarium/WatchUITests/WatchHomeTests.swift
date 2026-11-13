//  The top of the watch app: its states (signed in, signed out), every way
//  in, the Watch / iPhone switch, the book in progress, and Settings.

import XCTest

final class WatchHomeTests: WatchUITestCase {
    func testSignedInHomeHasEveryWayIn() {
        launchHome()
        app.element(TestID.Watch.rootMode("watch")).waitToExist()
        for door in ["books", "music", "playlists", "onWatch", "search", "settings"] {
            let row = app.element(TestID.Watch.rootDoor(door))
            XCTAssertTrue(reach(row), "no \(door) row")
        }
        XCTAssertFalse(app.element(TestID.Watch.rootSignedOut).exists)
        XCTAssertFalse(app.element(TestID.Watch.rootOffline).exists)
        attachScreenshot("home signed in")
    }

    /// The book in progress after suite-reset (FX Chaptered Audiobook at
    /// 6:40) is offered under Continue.
    func testTheBookInProgressIsOfferedToContinue() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        let row = app.element(TestID.Watch.rootContinue(book.id))
        row.waitToExist(30)
        XCTAssertTrue(reach(row))
        attachScreenshot("continue")
    }

    func testSignedOutTheWatchSaysToOpenThePhone() {
        launch(signIn: false)
        app.element(TestID.Watch.rootState("signedOut")).waitToExist(30)
        app.element(TestID.Watch.rootSignedOut).waitToExist()
        XCTAssertFalse(app.element(TestID.Watch.rootDoor("search")).exists, "no search without a server")
        XCTAssertTrue(reach(app.element(TestID.Watch.rootDoor("onWatch"))), "what is on the watch is still there")
        attachScreenshot("signed out")
    }

    func testTheSwitchShowsThePhonesSideAndBack() {
        launchHome()
        app.button(TestID.Watch.rootSource("phone")).tapWhenReady()
        app.element(TestID.Watch.rootMode("phone")).waitToExist()
        app.element(TestID.Watch.rootPhoneIdle).waitToExist()
        // The test phone has no Aquarium: nothing playing there, or away.
        let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                          "Nothing playing on iPhone", "iPhone out of reach")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the idle row says why there is nothing")
        app.element(TestID.Watch.phoneIdleCheckAgain).waitToExist()
        XCTAssertFalse(app.element(TestID.Watch.rootDoor("books")).exists, "the library is the watch side's")
        attachScreenshot("iphone side")
        app.button(TestID.Watch.rootSource("watch")).tapWhenReady()
        app.element(TestID.Watch.rootMode("watch")).waitToExist()
        app.element(TestID.Watch.rootDoor("books")).waitToExist()
    }

    func testTheChoiceOfSideIsRemembered() {
        launchHome()
        app.button(TestID.Watch.rootSource("phone")).tapWhenReady()
        app.element(TestID.Watch.rootMode("phone")).waitToExist()
        app.terminate()
        launch(reset: false)
        app.element(TestID.Watch.rootMode("phone")).waitToExist(60)
    }

    func testSettingsShowsTheAccountTheServerAndThePhone() {
        launchHome()
        open(TestID.Watch.rootDoor("settings"))
        app.element(TestID.Watch.settingsRoot).waitToExist()
        let user = waitForText(TestID.Watch.settingsUserName) { $0.contains("suite-watch") }
        XCTAssertTrue(user.contains("suite-watch"), user)
        let server = waitForText(TestID.Watch.settingsServerStatus) { $0.contains("Connected") }
        XCTAssertTrue(server.contains("Connected"), server)
        XCTAssertTrue(text(TestID.Watch.settingsServer).contains("127.0.0.1"))
        // In the page's order: what is above is gone from the tree once
        // scrolled past.
        for id in [TestID.Watch.settingsPhoneReach, TestID.Watch.storageUsed, TestID.Watch.settingsFromPhone,
                   TestID.Watch.settingsWaitingToSend, TestID.Watch.settingsSyncNow, TestID.Watch.settingsSendLog] {
            XCTAssertTrue(reach(app.element(id)), "no \(id)")
        }
        attachScreenshot("settings")
    }

    func testSettingsSignedOut() {
        launch(signIn: false)
        app.element(TestID.Watch.root).waitToExist(30)
        open(TestID.Watch.rootDoor("settings"))
        app.element(TestID.Watch.settingsSignedOut).waitToExist()
    }

    func testSyncNowRunsWithNothingToSync() {
        launchHome()
        open(TestID.Watch.rootDoor("settings"))
        open(TestID.Watch.settingsSyncNow)
        app.element(TestID.Watch.settingsRoot).waitToExist()
        XCTAssertTrue(text(TestID.Watch.settingsWaitingToSend).contains("0"))
    }
}
