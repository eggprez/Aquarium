//  What the Mac UI tests share beyond `MacUITestCase`: the menu bar, keyboard
//  shortcuts, the windows, and getting to a title and playing it.
//
//  Menu items: `MacCommands` and `PlaybackCommands` give every item an
//  identifier from `TestID.MacMenu` / `TestID.Player.menu…`, but whether
//  SwiftUI hands a `Commands` button's identifier to the AppKit menu item is
//  not confirmed (see TESTING.md, "Known gaps"). `menuItem` looks for the
//  identifier first and falls back to the visible title, and records which it
//  used, so the first run that gets this far answers the question.

#if os(macOS)
import XCTest

extension MacUITestCase {
    // MARK: Windows

    /// The main window (SwiftUI names it "main-AppWindow-1").
    var mainWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-'")).firstMatch
    }

    /// The player window, found by its anchor.
    var playerWindow: XCUIElement {
        app.windows.containing(.any, identifier: TestID.Player.window).firstMatch
    }

    /// Windows opened from "Open in New Window" (title and library windows).
    var routeWindows: XCUIElementQuery {
        app.windows.containing(.any, identifier: TestID.Detail.window)
    }

    var settingsWindow: XCUIElement {
        app.windows.containing(.any, identifier: TestID.Settings.window).firstMatch
    }

    // MARK: Launching

    /// Launch signed in as this suite's account and wait for Home.
    @discardableResult
    func launchToHome(engine: String? = nil, arguments: [String] = []) -> XCUIApplication {
        launch(engine: engine, arguments: arguments)
        app.element(TestID.Home.root).waitToExist(60)
        return app
    }

    // MARK: The menu bar

    /// A menu-bar item by catalogue identifier, else by its title in the named
    /// top-level menu. Opens that menu first.
    @discardableResult
    func menuItem(_ menu: String, id: String, title: String? = nil,
                  file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let bar = app.menuBars.firstMatch
        let top = bar.menuBarItems[menu]
        XCTAssertTrue(top.waitForExistence(timeout: 10), "no \(menu) menu", file: file, line: line)
        top.click()
        let byId = top.menuItems.matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 2) {
            noteMenuIdentifiers(found: true)
            return byId
        }
        noteMenuIdentifiers(found: false)
        guard let title else {
            XCTFail("menu item \(id) has no identifier in the menu bar and no title was given", file: file, line: line)
            return byId
        }
        let byTitle = top.menuItems[title]
        XCTAssertTrue(byTitle.waitForExistence(timeout: 5), "\(menu) ▸ \(title) not found", file: file, line: line)
        return byTitle
    }

    /// Choose a menu-bar item.
    func chooseMenu(_ menu: String, id: String, title: String? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
        let item = menuItem(menu, id: id, title: title, file: file, line: line)
        XCTAssertTrue(item.isEnabled, "\(menu) ▸ \(title ?? id) is disabled", file: file, line: line)
        item.click()
    }

    /// Close any open menu.
    func dismissMenus() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Records, once per run, whether menu-bar identifiers reached AppKit —
    /// the open question in TESTING.md.
    private func noteMenuIdentifiers(found: Bool) {
        let note = XCTAttachment(string: found
            ? "menu-bar items carry their TestID identifiers"
            : "menu-bar items do NOT carry their TestID identifiers; matched by title")
        note.name = "menu identifier probe"
        note.lifetime = .keepAlways
        add(note)
    }

    // MARK: Sidebar

    func sidebarRow(_ sectionId: String) -> XCUIElement {
        app.element(TestID.Sidebar.row(sectionId))
    }

    /// Click a sidebar row and wait for its page.
    func openSection(_ sectionId: String, file: StaticString = #filePath, line: UInt = #line) {
        sidebarRow(sectionId).tapWhenReady(20, file: file, line: line)
        app.element(TestID.Shell.section(sectionId)).waitToExist(20, file: file, line: line)
    }

    /// Type into the sidebar's search field and press Return.
    func searchFromSidebar(_ term: String) {
        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        field.waitToExist(10)
        field.click()
        field.typeText(term + "\r")
        app.element(TestID.Search.root).waitToExist(20)
    }

    // MARK: Titles and playback

    /// A title's page, opened through Search (the one route to any item).
    func openTitle(named name: String, id: String) {
        searchFromSidebar(name)
        let card = app.elements(prefix: TestID.Item.card(id)).firstMatch
        card.waitToExist(30)
        card.doubleClick()
        if !app.element(TestID.Detail.page(id)).waitForExistence(timeout: 5) {
            card.click()
        }
        app.element(TestID.Detail.page(id)).waitToExist(30)
    }

    /// Press Play on the title page in front and wait for the player window.
    func playFromTitlePage() {
        app.button(TestID.Detail.play).tapWhenReady(20)
        playerWindow.waitToExist(45)
    }

    /// Open a fixture and play it.
    func play(_ item: Fixtures.Item) {
        openTitle(named: item.name, id: item.id)
        playFromTitlePage()
    }

    /// Wake the player's controls (they follow the pointer on a Mac).
    func wakePlayerControls() {
        let window = playerWindow
        window.hover()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).hover()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.5)).hover()
    }

    /// Bring the player window to the front (its keys only work there).
    func focusPlayerWindow() {
        playerWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
    }

    /// Poll a condition for up to `timeout` seconds.
    @discardableResult
    func eventually(_ timeout: TimeInterval = 20, poll: TimeInterval = 0.5, _ condition: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: poll)
        }
        return try condition()
    }
}
#endif
