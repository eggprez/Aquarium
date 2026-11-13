//  Signing in on an iPad: the card on the wide screen, the server banner,
//  the public users, a password sign-in landing on the sidebar shell, a
//  wrong password, Quick Connect's code, and the hardware keyboard's Return
//  moving through the form (`onSubmit` in LoginView).

#if os(iOS)
import XCTest

final class PadSignInTests: PadUITestCase {
    private func field(_ id: String) -> XCUIElement {
        let text = app.textFields[id]
        return text.exists ? text : app.secureTextFields[id]
    }

    private func connectToQAServer(byReturn: Bool = false) {
        launch(signIn: false)
        app.element(TestID.Shell.signedOut).waitToExist(30)
        let server = app.textFields[TestID.Login.serverField]
        server.padTap()
        server.typeText(QA.server)
        if byReturn {
            // A hardware keyboard's Return submits the field.
            server.typeText("\n")
        } else {
            app.button(TestID.Login.connect).padTap()
        }
        app.element(TestID.Login.serverBanner).waitToExist(30)
    }

    func testSignInCardIsCentredOnTheWideScreen() {
        launch(signIn: false)
        let form = app.element(TestID.Login.form)
        XCTAssertTrue(form.waitForExistence(timeout: 30))
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(form.frame.width, window.width * 0.9, "a card, not edge to edge: \(form.frame)")
        XCTAssertEqual(form.frame.midX, window.midX, accuracy: 30)
        attachScreenshot("sign-in")
    }

    func testReturnInTheServerFieldConnects() {
        connectToQAServer(byReturn: true)
        XCTAssertTrue(app.element(TestID.Login.serverName).exists)
        XCTAssertTrue(text(app.element(TestID.Login.serverDetail)).contains("127.0.0.1"))
    }

    func testPublicUsersAreListed() throws {
        connectToQAServer()
        let names = try fx.raw["publicUsers"] as? [String] ?? []
        let users = try fx.raw["users"] as? [String: [String: Any]] ?? [:]
        let ids = names.compactMap { users[$0]?["id"] as? String }
        try XCTSkipIf(ids.isEmpty, "no public users in fixtures.json")
        for id in ids {
            XCTAssertTrue(app.button(TestID.Login.user(id)).waitForExistence(timeout: 15), "public user \(id)")
        }
    }

    func testPasswordSignInByKeyboardLandsOnTheSidebarShell() throws {
        guard let account = QA.account() else { throw XCTSkip("no account") }
        connectToQAServer()
        let user = field(TestID.Login.username)
        user.padTap()
        user.typeText(account.name + "\n")             // Return moves to the password
        let password = field(TestID.Login.password)
        XCTAssertTrue(waitUntil(5, "the password field to take focus") { password.hasFocus || (password.value as? String) != nil })
        password.typeText(account.password + "\n")     // Return signs in
        app.element(TestID.Home.root).waitToExist(60)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "an iPad signs in to the sidebar shell")
    }

    func testWrongPasswordSaysSo() throws {
        guard let account = QA.account() else { throw XCTSkip("no account") }
        connectToQAServer()
        field(TestID.Login.username).padTap()
        field(TestID.Login.username).typeText(account.name)
        field(TestID.Login.password).padTap()
        field(TestID.Login.password).typeText("not-the-password")
        app.button(TestID.Login.signIn).padTap()
        XCTAssertTrue(app.element(TestID.Login.error).waitForExistence(timeout: 20))
        XCTAssertFalse(app.element(TestID.Home.root).exists)
    }

    func testQuickConnectShowsACodeTheServerCanApprove() throws {
        connectToQAServer()
        app.button(TestID.Login.modeSwitch).padTap()
        let code = app.element(TestID.Login.quickConnectCode)
        XCTAssertTrue(code.waitForExistence(timeout: 20), "a six-digit code")
        let digits = text(code).filter(\.isNumber)
        XCTAssertEqual(digits.count, 6, "code reads \(text(code))")
        // Approve it as this suite's account, as another device would.
        let api = try api()
        try api.request("POST", "/QuickConnect/Authorize?code=\(digits)&userId=\(api.userId)")
        app.element(TestID.Home.root).waitToExist(60)
    }
}
#endif
