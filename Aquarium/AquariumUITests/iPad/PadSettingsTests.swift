//  Settings on an iPad: the gear at the foot of the sidebar; two columns
//  (list and page) with 720 points beside the sidebar, the phone's list
//  narrower (6344432); "Sidebar" rather than "Tab Bar"; and pages a page
//  opens belonging to Settings (346bc31).

#if os(iOS)
import XCTest

final class PadSettingsTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    private func openSettings() {
        launchHome()
        app.button(TestID.Sidebar.settings).padTap()
        app.element(TestID.Settings.root).waitToExist(20)
    }

    private var splitList: XCUIElement { app.element(TestID.Settings.splitList) }

    /// Landscape on an 11-inch iPad leaves 970 points beside the sidebar:
    /// two columns.
    func testTwoColumnsInLandscape() {
        launchHome()
        turn(.landscapeLeft)
        app.button(TestID.Sidebar.settings).padTap()
        app.element(TestID.Settings.root).waitToExist(20)
        XCTAssertTrue(splitList.waitForExistence(timeout: 10), "the list column")
        let title = app.element(TestID.Settings.splitPageTitle)
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the page beside it")
        XCTAssertEqual(title.label, "Video", "the split opens on Video")
        XCTAssertGreaterThan(title.frame.minX, splitList.frame.maxX - 1)
        attachScreenshot("settings split")
    }

    /// Portrait leaves 610 points: under 720, the phone's list, each row
    /// opening its page full width.
    func testOneColumnInPortrait() {
        openSettings()
        XCTAssertFalse(splitList.exists, "no split at 610 points")
        app.button(TestID.Settings.pageLink("video")).padTap()
        app.element(TestID.Settings.pageRoot("video")).waitToExist(10)
        attachScreenshot("settings portrait page")
    }

    func testEveryPageOpensFromTheSplitList() {
        launchHome()
        turn(.landscapeLeft)
        app.button(TestID.Sidebar.settings).padTap()
        splitList.waitToExist(20)
        let title = app.element(TestID.Settings.splitPageTitle)
        let pages: [(String, String)] = [("account", "Account"), ("appearance", "Appearance"), ("video", "Video"),
                                         ("audio", "Audio"), ("subtitles", "Subtitles"), ("music", "Music"),
                                         ("liveTV", "Live TV"), ("downloads", "Downloads"),
                                         ("libraryCopy", "Library copy"), ("about", "About")]
        for (key, name) in pages {
            let link = app.element(TestID.Settings.pageLink(key))
            // A list builds only the rows near the screen: scroll for it.
            _ = link.waitForExistence(timeout: 3)
            for _ in 0..<4 where !isOnScreen(link) { splitList.swipeUp() }
            for _ in 0..<6 where !isOnScreen(link) { splitList.swipeDown() }
            guard link.exists else { XCTFail("no \(key) row"); continue }
            link.padTap()
            XCTAssertTrue(waitUntil(10, "\(name)'s page") { title.label == name }, "\(key): title reads \(title.label)")
            XCTAssertTrue(app.element(TestID.Settings.pageRoot(key)).waitForExistence(timeout: 10), "\(key)'s page")
        }
    }

    func testRotatingSwitchesBetweenSplitAndList() {
        launchHome()
        turn(.landscapeLeft)
        app.button(TestID.Sidebar.settings).padTap()
        XCTAssertTrue(splitList.waitForExistence(timeout: 10))
        turn(.portrait)
        XCTAssertTrue(splitList.waitToVanish(10), "the list alone upright")
        turn(.landscapeLeft)
        XCTAssertTrue(splitList.waitForExistence(timeout: 10), "two columns again")
    }

    /// Landscape: the Appearance page beside the list, its Sidebar row
    /// pushing the order page onto Settings' stack.
    func testAppearanceNamesTheSidebarNotTheTabBar() {
        launchHome()
        turn(.landscapeLeft)
        app.button(TestID.Sidebar.settings).padTap()
        splitList.waitToExist(20)
        app.element(TestID.Settings.pageLink("appearance")).padTap()
        let row = app.button(TestID.Settings.tabBar)
        row.waitToExist(10)
        XCTAssertTrue(row.label.contains("Sidebar"), "row reads \(row.label)")
        row.padTap()
        app.element(TestID.TabBarSettings.root).waitToExist(10)
        XCTAssertTrue(app.element(TestID.TabBarSettings.home).exists, "Home leads, fixed")
        XCTAssertTrue(app.element(TestID.TabBarSettings.row("favorites")).exists)
    }

    /// Upright (one column), the first-level pages are pushed by
    /// view-destination links (SettingsView.swift:1053, `NavigationLink {
    /// SettingsPageView … }`), while the pages they open are value links
    /// onto the path (`Route.settings`, since 346bc31: App Icon, Sidebar,
    /// Measure sync, Station mix, Custom playlist). A value pushed over a
    /// page the path does not hold goes nowhere: the row lit and nothing
    /// opened. Found 2026-11-13; fixed the same day by making the first-level
    /// rows value links too (`SettingsRoute.page`).
    func testSubPagesOpenInTheOneColumnLayout() {
        openSettings()
        XCTAssertFalse(splitList.exists, "upright: one column")
        app.button(TestID.Settings.pageLink("appearance")).padTap()
        app.element(TestID.Settings.pageRoot("appearance")).waitToExist(10)
        app.button(TestID.Settings.tabBar).padTap()
        let opened = app.element(TestID.TabBarSettings.root).waitForExistence(timeout: 10)
        attachScreenshot("appearance, Sidebar tapped")
        XCTAssertTrue(opened, "the Sidebar order page opens")
    }

    func testThemeChoice() {
        openSettings()
        app.button(TestID.Settings.pageLink("appearance")).padTap()
        let theme = app.element(TestID.Settings.theme)
        theme.padTap()
        let dark = app.element(TestID.Settings.option(TestID.Settings.theme, "dark"))
        if dark.waitForExistence(timeout: 5) {
            dark.padTap()
            attachScreenshot("dark theme")
        } else {
            app.buttons["Dark"].padTap()
        }
    }

    /// Regression, 346bc31 ("iPad: leaving Settings from a sub-page goes
    /// where the sidebar says"): App Icon stayed on screen with Home's row lit.
    func testLeavingASettingsSubPageByTheSidebarLeavesIt() throws {
        launchHome()
        turn(.landscapeLeft)
        app.button(TestID.Sidebar.settings).padTap()
        splitList.waitToExist(20)
        app.element(TestID.Settings.pageLink("appearance")).padTap()
        let appIcon = app.button(TestID.Settings.appIcon)
        try XCTSkipUnless(appIcon.waitForExistence(timeout: 10), "no alternate icons on this simulator")
        appIcon.padTap()
        app.element(TestID.AppIconSettings.root).waitToExist(10)
        app.button(TestID.Sidebar.row("home")).padTap()
        app.element(TestID.Home.root).waitToExist(20)
        XCTAssertTrue(app.element(TestID.AppIconSettings.root).waitToVanish(10), "App Icon left with Settings")
        app.button(TestID.Sidebar.settings).padTap()
        XCTAssertTrue(app.element(TestID.AppIconSettings.root).waitForExistence(timeout: 10),
                      "and is still Settings' own page when Settings comes back")
    }

    func testAccountPageAndQuickConnectApproval() {
        openSettings()
        app.button(TestID.Settings.pageLink("account")).padTap()
        app.element(TestID.Settings.pageRoot("account")).waitToExist(10)
        XCTAssertTrue(app.element(TestID.Settings.accountSignedInAs).waitForExistence(timeout: 10))
        XCTAssertTrue(text(app.element(TestID.Settings.accountSignedInAs)).contains("suite-ipad"))
        let code = app.textFields[TestID.QuickConnect.codeField]
        XCTAssertTrue(reveal(code), "the Quick Connect approval field")
    }

    func testAboutNamesTheVersionAndEngine() {
        openSettings()
        app.button(TestID.Settings.pageLink("about")).padTap()
        let version = app.element(TestID.Settings.aboutVersion)
        XCTAssertTrue(reveal(version))
        XCTAssertFalse(text(version).isEmpty)
    }

    /// The iPad has no engine choice (pinned to the Apple engine).
    func testVideoPageHasNoEngineChoiceOnIPad() {
        openSettings()
        app.button(TestID.Settings.pageLink("video")).padTap()
        app.element(TestID.Settings.pageRoot("video")).waitToExist(10)
        XCTAssertFalse(app.element(TestID.Settings.videoEngine).exists)
        XCTAssertTrue(reveal(app.element(TestID.Settings.videoQuality)), "default quality row")
    }

    func testSignOutGoesToTheSignInScreen() {
        openSettings()
        app.button(TestID.Settings.pageLink("account")).padTap()
        let signOut = app.button(TestID.Settings.signOut)
        XCTAssertTrue(reveal(signOut))
        signOut.padTap()
        app.button(TestID.Settings.signOutConfirm).padTap()
        XCTAssertTrue(app.element(TestID.Shell.signedOut).waitForExistence(timeout: 30)
                      || app.element(TestID.Login.accounts).waitForExistence(timeout: 5))
    }
}
#endif
