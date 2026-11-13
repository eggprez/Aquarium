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
        // Keys go to the frontmost app: make sure that is this one.
        app.activate()
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
        let byTitle = top.menuItems[title].firstMatch
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
        field.typeKey("a", modifierFlags: .command)
        field.typeText(term)
        // A typed "\r" fills the field but doesn't submit `.searchable`; the
        // Return key does.
        field.typeKey(.return, modifierFlags: [])
        app.element(TestID.Search.root).waitToExist(20)
    }

    // MARK: Titles and playback

    /// An item's card, not the scroll view SwiftUI may hand the same
    /// identifier to, scrolled into view.
    func card(_ itemId: String, timeout: TimeInterval = 30) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(identifier: TestID.Item.card(itemId))
        query.firstMatch.waitToExist(timeout)
        // SwiftUI hands the identifier to the shelf's scroll view as well as
        // the card: take the first match that isn't one.
        let card = query.allElementsBoundByIndex.first { $0.elementType != .scrollView } ?? query.firstMatch
        scrollIntoView(card)
        return card
    }

    /// An element by identifier that isn't a scroll view SwiftUI handed the
    /// same identifier to (episode rows, cast tiles, cards).
    func solid(_ id: String, timeout: TimeInterval = 30) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(identifier: id)
        query.firstMatch.waitToExist(timeout)
        let element = query.allElementsBoundByIndex.first { $0.elementType != .scrollView } ?? query.firstMatch
        scrollIntoView(element)
        return element
    }

    /// Click the middle of an element whether or not XCUITest calls it
    /// hittable (the title page's disc actions report "not hittable" while
    /// being on screen and clickable).
    func clickCentre(_ element: XCUIElement) {
        element.waitToExist(20)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Scroll the window under the element until it can be clicked.
    func scrollIntoView(_ element: XCUIElement, window: XCUIElement? = nil, maxScrolls: Int = 15) {
        let window = window ?? mainWindow
        var n = 0
        while element.exists, !element.isHittable, n < maxScrolls {
            let up = element.frame.minY < window.frame.minY
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).scroll(byDeltaX: 0, deltaY: up ? 300 : -300)
            n += 1
        }
    }

    /// An item in an open menu whose title starts with `prefix` ("Sign Out"
    /// for "Sign Out…").
    func menuChoice(startingWith prefix: String, timeout: TimeInterval = 5) -> XCUIElement {
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        _ = item.waitForExistence(timeout: timeout)
        return item
    }

    /// An item in an open menu (context menu, pop-up, menu button). SwiftUI
    /// does not hand these their identifiers on a Mac (checked 2026-11-13:
    /// the menu bar's items are all `menuAction:`), so the title is the
    /// fallback.
    func menuChoice(_ id: String, title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let byId = app.menuItems.matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 1) { return byId }
        let byTitle = app.menuItems[title].firstMatch
        _ = byTitle.waitForExistence(timeout: timeout)
        return byTitle
    }

    /// Settings ▸ Account ▸ Sign Out, then the confirmation's `button`.
    func signOutThroughSettings(confirm: Bool) {
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["Account"].tapWhenReady()
        app.element(TestID.Settings.signOut).tapWhenReady()
        app.button(confirm ? TestID.Settings.signOutConfirm : TestID.Settings.signOutCancel).tapWhenReady()
    }

    /// Open the sidebar's account menu.
    func openAccountMenu() {
        // The label is several parts, each a menu button with the identifier;
        // the chevron is the one that reliably opens it.
        let parts = app.menuButtons.matching(identifier: TestID.Sidebar.accountMenu)
        parts.firstMatch.waitToExist(20)
        let chevron = parts.matching(NSPredicate(format: "title CONTAINS[c] 'Chevron'")).firstMatch
        // A plain-styled Menu opens on mouse-down; a quick click can close it
        // again before XCUITest looks.
        (chevron.exists ? chevron : parts.firstMatch).press(forDuration: 0.4)
    }

    /// A title's page, opened from its library's grid (Fixture Films, else
    /// Fixture Shows). Not through Search: under XCUITest, Return in the
    /// sidebar's search field doesn't show Search (see the report), and every
    /// test that only needs a title page shouldn't depend on that.
    func openTitle(named name: String, id: String) {
        let fx = Fixtures.shared
        for library in ["Fixture Films", "Fixture Shows"] {
            guard let lib = fx?.libraries[library] else { continue }
            openSection("lib-\(lib)")
            let match = app.descendants(matching: .any).matching(identifier: TestID.Item.card(id)).firstMatch
            if match.waitForExistence(timeout: 10) { break }
        }
        let card = self.card(id)
        card.doubleClick()
        if !app.element(TestID.Detail.page(id)).waitForExistence(timeout: 5) {
            card.click()
            app.typeKey(.return, modifierFlags: [])
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

#if os(macOS)
/// `JellyfinAPI.sessions()` asks `/Sessions?ControllableByUserId=…`, which
/// Jellyfin 12.2 answers with nothing for a non-admin suite account (checked
/// 2026-11-13: 0 sessions there, 258 from plain `/Sessions`), so every
/// "what the server heard" check came back empty. These ask `/Sessions` and
/// keep this account's, the test's own device left out. Kept in the Mac
/// folder; the shared helper is the other agents' too (see the report).
extension JellyfinAPI {
    /// Newest activity first, so a session a previous test left behind
    /// (still "playing" until the server times it out) comes after this one's.
    func macSessions(activeWithinSeconds: Int = 120) throws -> [Session] {
        let list = (try json("/Sessions?ActiveWithinSeconds=\(activeWithinSeconds)") as? [[String: Any]] ?? [])
            .sorted { ($0["LastActivityDate"] as? String ?? "") > ($1["LastActivityDate"] as? String ?? "") }
        return list.compactMap { s in
            guard (s["UserId"] as? String) == userId, (s["DeviceId"] as? String) != Self.deviceId else { return nil }
            let playing = s["NowPlayingItem"] as? [String: Any]
            let state = s["PlayState"] as? [String: Any]
            let ticks = (state?["PositionTicks"] as? Int64) ?? (state?["PositionTicks"] as? Int).map(Int64.init)
            return Session(
                id: s["Id"] as? String ?? "", client: s["Client"] as? String ?? "",
                deviceName: s["DeviceName"] as? String ?? "", deviceId: s["DeviceId"] as? String ?? "",
                userName: s["UserName"] as? String ?? "", nowPlayingId: playing?["Id"] as? String,
                positionSeconds: ticks.map { Double($0) / 10_000_000 }, isPaused: state?["IsPaused"] as? Bool, raw: s)
        }
    }

    func macWaitForPlayback(of itemId: String? = nil, timeout: TimeInterval = 30) throws -> Session? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let s = try macSessions().first(where: { $0.nowPlayingId != nil && (itemId == nil || $0.nowPlayingId == itemId) }) {
                return s
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }
}
#endif
