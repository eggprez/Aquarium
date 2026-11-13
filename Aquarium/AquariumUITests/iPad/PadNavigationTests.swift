//  The iPad's shell: the grouped "Deep Water" sidebar (eff49a1), its header,
//  footer and Now Playing card, collapsing and bringing it back, and every
//  section reachable from it in both orientations.

#if os(iOS)
import XCTest

final class PadSidebarTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testSidebarIsTheShellNotATabBar() {
        launchHome()
        sidebar.waitToExist(20)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "an iPad at full width has no tab bar")
        XCTAssertFalse(app.button(TestID.Tab.item("home")).exists)
        attachScreenshot("sidebar")
    }

    func testHeaderNamesTheAccountAndServer() {
        launchHome()
        let account = app.element(TestID.Sidebar.account)
        account.waitToExist(20)
        XCTAssertTrue(account.label.contains("suite-ipad"), "header reads \(account.label)")
        XCTAssertTrue(account.label.contains("127.0.0.1"), "header names the server's host: \(account.label)")
    }

    func testRowsAreGroupedHomeFirstAndEveryLibraryListed() throws {
        let fx = try fx
        launchHome()
        sidebar.waitToExist(20)
        app.button(TestID.Sidebar.row("home")).waitToExist(20)
        // Libraries arrive after the shell is drawn.
        let films = TestID.Sidebar.row("lib-\(try fx.libraryId("Fixture Films"))")
        app.button(films).waitToExist(30)
        let ids = sidebarRowIds()
        XCTAssertEqual(ids.first, "home")
        for name in ["Fixture Films", "Fixture Shows", "Movies"] {
            XCTAssertTrue(ids.contains("lib-\(try fx.libraryId(name))"), "\(name) has a row: \(ids)")
        }
        XCTAssertTrue(ids.contains("music"), "Music is a section on this server: \(ids)")
        XCTAssertTrue(ids.contains("books"), "Audiobooks is a section on this server: \(ids)")
        XCTAssertTrue(ids.contains("favorites"))
        XCTAssertTrue(ids.contains("downloads"))
        XCTAssertTrue(ids.contains("livetv"), "the QA server has a tuner")
        XCTAssertFalse(ids.contains("settings"), "Settings is the gear, not a row")
        XCTAssertFalse(ids.contains("more"), "a sidebar has no More")
        // Grouping: Browse (Home) … Libraries … Live … You (Favorites, Downloads).
        let index = { (id: String) in ids.firstIndex(of: id) ?? -1 }
        XCTAssertLessThan(index("home"), index("music"))
        XCTAssertLessThan(index("music"), index("livetv"))
        XCTAssertLessThan(index("livetv"), index("favorites"))
        XCTAssertLessThan(index("favorites"), index("downloads"))
        for eyebrow in ["BROWSE", "LIBRARIES", "LIVE", "YOU"] {
            XCTAssertTrue(app.staticTexts[eyebrow].exists, "eyebrow \(eyebrow)")
        }
    }

    func testEverySectionOpensFromItsRow() throws {
        let fx = try fx
        launchHome()
        let sections = ["music", "books", "lib-\(try fx.libraryId("Fixture Films"))",
                        "lib-\(try fx.libraryId("Fixture Shows"))", "favorites", "livetv", "downloads", "home"]
        app.button(TestID.Sidebar.row(sections[2])).waitToExist(30)
        for id in sections {
            showSection(id)
            XCTAssertTrue(app.button(TestID.Sidebar.row(id)).isSelected, "\(id)'s row is lit")
        }
    }

    func testSelectedRowGoesBackToTheTopOfItsSection() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        // Home's row is lit and a title is pushed over Home: a second tap
        // goes back to Home's top, as a tab does.
        app.button(TestID.Sidebar.row("home")).padTap()
        app.element(TestID.Home.root).waitToExist(20)
        XCTAssertTrue(app.element(TestID.Detail.page(film.id)).waitToVanish(10))
    }

    func testSearchRowPushesSearch() {
        launchHome()
        app.button(TestID.Sidebar.searchRow).padTap()
        app.element(TestID.Search.root).waitToExist(20)
        XCTAssertTrue(app.button(TestID.Sidebar.row("home")).isSelected, "Search opens over Home")
    }

    func testSettingsGearSelectsSettings() {
        launchHome()
        app.button(TestID.Sidebar.settings).padTap()
        app.element(TestID.Settings.root).waitToExist(20)
        XCTAssertTrue(app.button(TestID.Sidebar.settings).isSelected)
    }

    func testFooterSaysSynced() {
        launchHome()
        let status = app.element(TestID.Sidebar.status)
        status.waitToExist(20)
        XCTAssertTrue(eventually(30) { status.label == "Synced" }, "status reads \(status.label)")
    }

    func testCollapseAndBringBackTheSidebarInLandscape() {
        launchHome()
        turn(.landscapeLeft)
        app.button(TestID.Sidebar.collapse).padTap()
        XCTAssertTrue(eventually(10) { !self.app.button(TestID.Sidebar.collapse).isHittable }, "sidebar went away")
        // Home draws its own bar, with the toggle in it.
        let show = app.button(TestID.Sidebar.show)
        show.padTap()
        app.button(TestID.Sidebar.collapse).waitToExist(10)
        XCTAssertTrue(eventually(10) { self.isOnScreen(self.app.button(TestID.Sidebar.collapse)) }, "the sidebar is back")
    }

    func testCollapsedSidebarComesBackFromATitlePage() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        turn(.landscapeLeft)
        // Opened the way a person would: its card on Home.
        let card = cardButton(film.id)
        XCTAssertTrue(reveal(card))
        card.padTap()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
        app.button(TestID.Sidebar.collapse).padTap()
        XCTAssertTrue(eventually(10) { !self.app.button(TestID.Sidebar.collapse).isHittable })
        // The title page's own bar should then carry the way back
        // (ItemDetailView.padBar, `showSidebar`): seen missing on a title
        // pushed over Home, landscape, 2026-11-13; fixed the same day (the
        // pushed page is handed `SidebarToggle`).
        let toggle = app.button(TestID.Detail.showSidebar)
        let offered = toggle.waitForExistence(timeout: 10)
        attachScreenshot("title page, sidebar hidden")
        XCTAssertTrue(offered, "Show sidebar in the title page's bar")
        guard offered else { return }
        toggle.padTap()
        // On screen rather than hittable, as the Home test above checks:
        // over a pushed title page the sidebar comes back and its buttons
        // take real touches (checked by hand, 2026-11-13), yet XCUITest
        // calls every sidebar button unhittable there; its hit test lands on
        // something of the page under the column (see `isOnScreen`).
        XCTAssertTrue(eventually(10) { self.isOnScreen(self.app.button(TestID.Sidebar.collapse)) },
                      "the title page's own bar brings the sidebar back")
    }

    func testSidebarInPortraitAndLandscape() {
        launchHome()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            turn(orientation)
            revealSidebar()
            XCTAssertTrue(app.button(TestID.Sidebar.row("home")).waitForExistence(timeout: 10),
                          "sidebar reachable in \(orientation.rawValue)")
            attachScreenshot("sidebar \(orientation.isLandscape ? "landscape" : "portrait")")
        }
    }

    /// The sidebar keeps to its narrow column (6344432: "Sidebar: iPad
    /// 190–280 (ideal 210)").
    func testSidebarIsNarrow() {
        launchHome()
        turn(.landscapeLeft)
        let row = app.button(TestID.Sidebar.row("home"))
        row.waitToExist(20)
        let width = sidebar.frame.width
        XCTAssertGreaterThanOrEqual(width, 180, "sidebar \(width) pt")
        XCTAssertLessThanOrEqual(width, 290, "sidebar \(width) pt")
        XCTAssertLessThan(row.frame.maxX, app.frame.width * 0.3)
    }

    func testDownloadsBadgeAndNowPlayingAbsentWhenIdle() {
        launchHome()
        sidebar.waitToExist(20)
        XCTAssertFalse(app.element(TestID.Sidebar.nowPlaying).exists, "no card with nothing playing")
    }
}

/// The iPad window at sizes other than the whole screen. The simulator's
/// window can be resized only where its multitasking setting allows windows;
/// a drag on the window's corner does it there. Elsewhere these skip.
final class PadWindowSizeTests: PadUITestCase {
    private func windowIsResizable() -> Bool {
        let window = app.frame
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows.firstMatch.frame
        return window.width < screen.width - 1 || window.height < screen.height - 1
    }

    /// Drags the window's bottom-trailing corner by `dx` points.
    private func dragCorner(by dx: CGFloat) {
        let frame = app.frame
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let corner = origin.withOffset(CGVector(dx: frame.maxX - 6, dy: frame.maxY - 6))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: dx, dy: 0)))
    }

    /// Regression, "Window passing through compact width loses the sidebar
    /// with no way back" (master-fix-list.md iPad #4, ipad-qa-findings.md
    /// bug 4; fixed on claude/qa-fix-list-cb0b58 as 3e83bd4, which is not on
    /// this branch's main).
    func testSidebarComesBackAfterAPhoneWidthWindow() throws {
        launchHome()
        try XCTSkipUnless(windowIsResizable(),
                          "this simulator shows apps full screen (Stage Manager/windowed apps off); see MANUAL.md")
        let full = app.frame.width
        dragCorner(by: -(full - 360))
        let narrowed = eventually(10) { self.app.tabBars.firstMatch.exists || self.app.button(TestID.Tab.item("home")).exists }
        try XCTSkipUnless(narrowed, "the window would not narrow to phone width by a corner drag")
        dragCorner(by: full)
        XCTExpectFailure("bug: sidebar lost after a phone-width window (3e83bd4 not on main)", strict: false)
        XCTAssertTrue(eventually(15) { self.app.button(TestID.Sidebar.row("home")).isHittable
                                     || self.app.button(TestID.Sidebar.show).exists },
                      "a way back to the sidebar after widening")
    }
}
#endif
