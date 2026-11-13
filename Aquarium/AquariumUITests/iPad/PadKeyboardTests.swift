//  A hardware keyboard on an iPad, as far as XCUITest can press its keys
//  (`typeKey`, which the simulator delivers as a hardware key press).
//
//  The app defines no keyboard shortcuts of its own on iOS: its
//  `keyboardShortcut`s and key handlers are macOS-only (PlayerWindow,
//  MacCommands, ItemContextMenu.macShortcut, the guide and grid key presses).
//  What an iPad keyboard does is what the system gives: Return submits a
//  field (`onSubmit` in LoginView, SearchView), Tab moves between fields,
//  Escape dismisses what the system presents. Those are tested here; the
//  shortcut list (holding ⌘) is in MANUAL.md.

#if os(iOS)
import XCTest

final class PadKeyboardTests: PadUITestCase {
    private func press(_ key: XCUIKeyboardKey, on element: XCUIElement, modifiers: XCUIElement.KeyModifierFlags = []) {
        element.typeKey(key.rawValue, modifierFlags: modifiers)
    }

    func testReturnKeySubmitsSearch() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        app.button(TestID.Sidebar.searchRow).padTap()
        let field = app.textFields[TestID.Search.field]
        field.padTap()
        field.typeText("FX Long Direct")
        press(.return, on: field)
        XCTAssertTrue(cardButton(film.id).waitForExistence(timeout: 30))
        // A submitted term is remembered.
        app.button(TestID.Search.clear).padTap()
        XCTAssertTrue(app.element(TestID.Search.recent("FX Long Direct")).waitForExistence(timeout: 10))
    }

    func testReturnKeyConnectsAndTabMovesToThePassword() throws {
        guard let account = QA.account() else { throw XCTSkip("no account") }
        launch(signIn: false)
        let server = app.textFields[TestID.Login.serverField]
        server.padTap(30)
        server.typeText(QA.server)
        press(.return, on: server)
        app.element(TestID.Login.serverBanner).waitToExist(30)
        let user = app.textFields[TestID.Login.username]
        user.padTap()
        user.typeText(account.name)
        press(.tab, on: user)
        let password = app.secureTextFields[TestID.Login.password]
        XCTAssertTrue(waitUntil(5, "Tab to move to the password") { password.hasFocus })
        password.typeText(account.password)
        press(.return, on: password)
        app.element(TestID.Home.root).waitToExist(60)
    }

    func testEscapeDismissesTheInfoPopover() throws {
        let film = try fx.item("film.hevc_mp4")
        launchHome()
        play(film.id)
        waitForPlaying()
        tapControl(TestID.Player.pillInfo)
        let panel = app.element(TestID.Player.panel)
        panel.waitToExist(15)
        press(.escape, on: app)
        XCTAssertTrue(panel.waitToVanish(10), "Escape closes the popover")
        XCTAssertTrue(player.exists, "and only the popover: the player stays")
    }

    func testEscapeDismissesAContextMenu() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let card = cardButton(film.id)
        XCTAssertTrue(reveal(card))
        contextMenu(on: card, waitingFor: TestID.Item.menuPlay)
        press(.escape, on: app)
        XCTAssertTrue(app.button(TestID.Item.menuPlay).waitToVanish(10))
    }
}
#endif
