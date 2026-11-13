//  The Mac's menu bar and its keyboard shortcuts (`MacCommands`): the app
//  menu's About, the View menu (Bigger / Smaller / Actual Size, ⌘1…⌘9,
//  Refresh), the Go menu, the Item menu, and Window ▸ Aquarium.

#if os(macOS)
import XCTest

final class MacMenuCommandUITests: MacUITestCase {
    private func fixtures() throws -> Fixtures { try Fixtures.require() }

    // MARK: The app menu

    func testAboutPanelShowsVersionAndEngine() {
        launchToHome()
        chooseMenu("Aquarium", id: TestID.MacMenu.about, title: "About Aquarium")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Playback engine' OR label CONTAINS 'Playback engine'")).firstMatch.waitForExistence(timeout: 10),
                      "the About panel names the playback engine")
        attachScreenshot("about")
        app.typeKey("w", modifierFlags: .command)
    }

    func testNoNewWindowCommand() {
        launchToHome()
        let file = app.menuBars.firstMatch.menuBarItems["File"]
        if file.exists {
            file.click()
            XCTAssertFalse(file.menuItems["New Window"].exists, "one main window")
            dismissMenus()
        }
    }

    // MARK: View

    /// Regression: CommandEqualsZoomedNothing. Bigger was bound to "+", which
    /// needs Shift, so ⌘= did nothing. Source: commit 9c6fb8c;
    /// Views/MacCommands.swift:96-102.
    func testBugCommandEqualsZoomedNothing() throws {
        let lib = try fixtures().libraryId("Fixture Films")
        launchToHome()
        openSection("lib-\(lib)")
        let card = app.elements(prefix: "item.card.").firstMatch
        card.waitToExist(30)
        let before = card.frame.width
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(eventually(10) { card.frame.width > before + 1 }, "⌘= makes the thumbnails bigger")
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(eventually(10) { abs(card.frame.width - before) < 1 }, "⌘0 is actual size again")
        app.typeKey("-", modifierFlags: .command)
        XCTAssertTrue(eventually(10) { card.frame.width < before - 1 }, "⌘- makes them smaller")
        app.typeKey("0", modifierFlags: .command)
    }

    func testActualSizeIsDisabledAtActualSize() {
        launchToHome()
        let item = menuItem("View", id: TestID.MacMenu.actualSize, title: "Actual Size")
        XCTAssertFalse(item.isEnabled)
        dismissMenus()
    }

    /// ⌘1…⌘9 follow the sidebar's rows as drawn.
    func testCommandNumbersFollowTheSidebar() {
        launchToHome()
        app.typeKey("2", modifierFlags: .command)
        // Row 2 is the first library under the Libraries heading.
        let firstLibraryShown = app.elements(prefix: "shell.section.root.lib-").firstMatch
        XCTAssertTrue(firstLibraryShown.waitForExistence(timeout: 20))
        app.typeKey("1", modifierFlags: .command)
        app.element(TestID.Home.root).waitToExist(20)
    }

    func testViewMenuListsTheSections() {
        launchToHome()
        XCTAssertTrue(menuItem("View", id: TestID.MacMenu.section("home"), title: "Home").exists)
        dismissMenus()
        XCTAssertTrue(menuItem("View", id: TestID.MacMenu.refresh, title: "Refresh").isEnabled)
        dismissMenus()
    }

    func testRefreshKeepsThePage() {
        launchToHome()
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.element(TestID.Home.root).waitForExistence(timeout: 20))
    }

    // MARK: Go

    func testGoBackAndHome() throws {
        let film = try fixtures().item("film.long_direct")
        launchToHome()
        let card = app.elements(prefix: TestID.Item.card(film.id)).firstMatch
        card.waitToExist(30)
        card.doubleClick()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(app.element(TestID.Detail.page(film.id)).waitToVanish(10), "⌘[ goes back")
        card.doubleClick()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
        // Regression: GoHomeDoesNothingFromPushedPage (commit 9c6fb8c).
        app.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.element(TestID.Detail.page(film.id)).waitToVanish(10), "⇧⌘H goes to the top of Home")
    }

    func testBackIsDisabledAtTheTop() {
        launchToHome()
        XCTAssertFalse(menuItem("Go", id: TestID.MacMenu.goBack, title: "Back").isEnabled)
        dismissMenus()
    }

    func testCommandFPutsTheCursorInSearch() {
        launchToHome()
        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        field.waitToExist(10)
        app.typeText("FX")
        XCTAssertEqual(field.value as? String, "FX")
    }

    func testGoDownloadsAndLiveTV() {
        launchToHome()
        app.typeKey("j", modifierFlags: [.command, .option])
        app.element(TestID.Shell.section("downloads")).waitToExist(20)
        app.typeKey("l", modifierFlags: [.command, .shift])
        app.element(TestID.Shell.section("livetv")).waitToExist(20)
    }

    func testShowDownloadsInFinderIsThere() {
        // Not chosen: it opens Finder, which is outside the app under test.
        launchToHome()
        XCTAssertTrue(menuItem("Go", id: TestID.MacMenu.goShowDownloadsInFinder, title: "Show Downloads in Finder").isEnabled)
        dismissMenus()
    }

    func testGuideCommandsOnlyLiveOnTheGuide() {
        launchToHome()
        XCTAssertFalse(menuItem("Go", id: TestID.MacMenu.goEarlier, title: "Earlier").isEnabled)
        dismissMenus()
        app.typeKey("l", modifierFlags: [.command, .shift])
        app.element(TestID.Guide.root).waitToExist(30)
        XCTAssertTrue(menuItem("Go", id: TestID.MacMenu.goLater, title: "Later").isEnabled)
        dismissMenus()
    }

    // MARK: Item

    func testItemMenuOnATitlePage() throws {
        let film = try fixtures().item("film.rated_nc17")
        let api = try JellyfinAPI.signIn()
        try api.resetItem(film.id)
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(try eventually(20) { try api.userData(film.id).favorite }, "⌘D adds to Favorites")
        app.typeKey("u", modifierFlags: [.command, .shift])
        XCTAssertTrue(try eventually(20) { try api.userData(film.id).played }, "⇧⌘U marks watched")
        let favorite = menuItem("Item", id: TestID.MacMenu.itemFavorite, title: "Remove from Favorites")
        XCTAssertEqual(favorite.title, "Remove from Favorites")
        dismissMenus()
        try api.resetItem(film.id)
    }

    func testItemMenuDisabledWithNoTitleInFront() {
        launchToHome()
        XCTAssertFalse(menuItem("Item", id: TestID.MacMenu.itemFavorite, title: "Add to Favorites").isEnabled)
        dismissMenus()
    }

    func testCommandReturnPlays() throws {
        let film = try fixtures().item("film.rated_g")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey(.return, modifierFlags: .command)
        playerWindow.waitToExist(45)
    }

    func testOptionCommandOOpensTheTitleInANewWindow() throws {
        let film = try fixtures().item("film.hevc_mp4")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey("o", modifierFlags: [.command, .option])
        XCTAssertTrue(routeWindows.firstMatch.waitForExistence(timeout: 20))
    }

    /// Regression: ItemMenuGreyedForGridSelection — one title selected in a
    /// library grid drives the Item menu. Source: commit 9c6fb8c;
    /// Views/LibraryView.swift:65, :278.
    func testBugItemMenuGreyedForGridSelection() throws {
        let fx = try fixtures()
        let lib = try fx.libraryId("Fixture Films")
        let film = try fx.item("film.hevc_mp4")
        launchToHome()
        openSection("lib-\(lib)")
        let card = app.elements(prefix: TestID.Item.card(film.id)).firstMatch
        card.waitToExist(30)
        card.click()
        XCTAssertTrue(menuItem("Item", id: TestID.MacMenu.itemPlay, title: "Play").isEnabled)
        dismissMenus()
    }

    /// Regression: ItemMenuActsOnCoveredLibrarySelection — with a title
    /// pushed over a library, the Item menu is the title's, not the hidden
    /// grid selection's. Source: commit a016c37; Views/LibraryView.swift:278.
    func testBugItemMenuActsOnCoveredLibrarySelection() throws {
        let fx = try fixtures()
        let lib = try fx.libraryId("Fixture Films")
        let selected = try fx.item("film.hevc_mp4")
        let opened = try fx.item("film.rated_r")
        let api = try JellyfinAPI.signIn()
        try api.resetItem(opened.id)
        let selectedWasFavorite = try api.userData(selected.id).favorite
        launchToHome()
        openSection("lib-\(lib)")
        app.elements(prefix: TestID.Item.card(selected.id)).firstMatch.tapWhenReady(30)
        let other = app.elements(prefix: TestID.Item.card(opened.id)).firstMatch
        other.waitToExist(30)
        other.doubleClick()
        app.element(TestID.Detail.page(opened.id)).waitToExist(30)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(try eventually(20) { try api.userData(opened.id).favorite })
        XCTAssertEqual(try api.userData(selected.id).favorite, selectedWasFavorite, "the covered selection is untouched")
        try api.resetItem(opened.id)
    }

    // MARK: Window

    /// Regression: MainWindowUnreachableOnceClosed. With the main window
    /// closed and a title window open, Window ▸ Aquarium (⌥⌘1) brings it back.
    /// Source: commit 9c6fb8c; Views/MacCommands.swift:68-78.
    func testBugMainWindowUnreachableOnceClosed() throws {
        let film = try fixtures().item("film.hevc_mp4")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey("o", modifierFlags: [.command, .option])
        routeWindows.firstMatch.waitToExist(20)
        mainWindow.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(mainWindow.waitToVanish(10))
        app.typeKey("1", modifierFlags: [.command, .option])
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
    }

    /// Regression: GoCommandsChangeHiddenMainWindow. ⌘2 with a title window
    /// in front brings the main window forward with the section.
    /// Source: commit a016c37.
    func testBugGoCommandsChangeHiddenMainWindow() throws {
        let film = try fixtures().item("film.hevc_mp4")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.typeKey("o", modifierFlags: [.command, .option])
        let titleWindow = routeWindows.firstMatch
        titleWindow.waitToExist(20)
        titleWindow.click()
        app.typeKey("j", modifierFlags: [.command, .option])
        app.element(TestID.Shell.section("downloads")).waitToExist(20)
        XCTAssertTrue(mainWindow.isHittable, "the main window came forward")
    }
}
#endif
