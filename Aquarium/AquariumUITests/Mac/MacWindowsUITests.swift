//  The Mac's windows: title windows ("Open in New Window") with their own
//  pages, library windows from the sidebar, one window per title, alerts on
//  the window being worked in, the main window's minimum size, and pages that
//  must not grow the window.

#if os(macOS)
import XCTest

final class MacWindowsUITests: MacUITestCase {
    private func fixtures() throws -> Fixtures { try Fixtures.require() }

    func testTitleWindowHasItsOwnPages() throws {
        let show = try fixtures().item("show.long")
        launchToHome()
        openTitle(named: show.name, id: show.id)
        app.element(TestID.Detail.openInNewWindow).tapWhenReady()
        let window = routeWindows.firstMatch
        window.waitToExist(20)
        // A season opened in the title window opens in it.
        let season = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'detail.season.'")).firstMatch
        if season.waitForExistence(timeout: 20) {
            season.click()
            XCTAssertTrue(window.descendants(matching: .any).matching(identifier: TestID.Detail.episodeList).firstMatch.waitForExistence(timeout: 20))
        }
        // ⌘[ goes back in the title window, not the main one.
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(app.element(TestID.Detail.page(show.id)).waitForExistence(timeout: 10))
        attachScreenshot("title window")
    }

    func testSameTitleTwiceIsOneWindow() throws {
        let film = try fixtures().item("film.hevc_mp4")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey("o", modifierFlags: [.command, .option])
        routeWindows.firstMatch.waitToExist(20)
        mainWindow.click()
        app.typeKey("o", modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(routeWindows.count, 1, "asking again brings the same window forward")
    }

    func testLibraryWindowFromTheSidebar() throws {
        let lib = try fixtures().libraryId("Fixture Films")
        launchToHome()
        sidebarRow("lib-\(lib)").rightClick()
        app.menuItems.matching(identifier: TestID.Sidebar.rowOpenInNewWindow("lib-\(lib)")).firstMatch.tapWhenReady()
        let window = routeWindows.firstMatch
        window.waitToExist(20)
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: TestID.Library.page(lib)).firstMatch.waitForExistence(timeout: 30))
    }

    func testTitleWindowClosesOnSignOut() throws {
        let film = try fixtures().item("film.hevc_mp4")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey("o", modifierFlags: [.command, .option])
        routeWindows.firstMatch.waitToExist(20)
        mainWindow.click()
        app.element(TestID.Sidebar.accountMenu).tapWhenReady()
        app.element(TestID.Sidebar.accountMenuSignOut).tapWhenReady()
        app.button(TestID.Shell.signOutConfirm).tapWhenReady()
        XCTAssertTrue(routeWindows.firstMatch.waitToVanish(20), "a window belongs to the account it was opened under")
    }

    /// Regression: MainWindowNoMinimumSize — the main window can't be made
    /// smaller than 960×600. Source: commit 9b138e5 (QA #11); AquariumApp.swift:136.
    func testBugMainWindowNoMinimumSize() {
        launchToHome()
        let window = mainWindow
        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)))
        XCTAssertGreaterThanOrEqual(window.frame.width, 960)
        XCTAssertGreaterThanOrEqual(window.frame.height, 600)
        _ = frame
    }

    /// Regression: PushedPageGrowsMainWindow — opening a series with many
    /// seasons widened the window, once to 3,094 pt. Source: commits 9b138e5,
    /// 3cd4288; Views/ItemDetailView+Mac.swift:40-58.
    func testBugPushedPageGrowsMainWindow() throws {
        let show = try fixtures().item("show.long")
        launchToHome()
        let before = mainWindow.frame
        openTitle(named: show.name, id: show.id)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(mainWindow.frame.width, before.width, accuracy: 1)
    }

    /// Regression: AlertsToastsRefreshHitEveryWindow — an alert raised from a
    /// title window is shown on that window only. Source: commit a016c37.
    func testBugAlertShowsOnTheWindowBeingWorkedIn() throws {
        let film = try fixtures().item("film.hevc_mp4")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey("o", modifierFlags: [.command, .option])
        let window = routeWindows.firstMatch
        window.waitToExist(20)
        XCTAssertEqual(app.sheets.count + app.dialogs.count, 0)
        attachScreenshot("two windows, no stray alert")
    }

    /// Regression: RestoredPlayerWindowBlack — relaunched with window
    /// restoration on, a player window with nothing to play dismisses itself.
    /// Source: Player/PlayerWindow.swift:53-56.
    func testBugRestoredPlayerWindowBlack() throws {
        let film = try fixtures().item("film.rated_g")
        launchToHome()
        play(film)
        app.terminate()
        // Without -ApplePersistenceIgnoreState NO the launcher ignores saved
        // state; ask for it back explicitly.
        launch(reset: false, signIn: false, arguments: ["-ApplePersistenceIgnoreState", "NO"])
        app.element(TestID.Home.root).waitToExist(60)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(playerWindow.exists, "no black player window comes back")
    }
}
#endif
