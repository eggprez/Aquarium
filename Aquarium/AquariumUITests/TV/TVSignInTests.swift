//  Signing in on the Apple TV (Views/LoginView.swift): the server address,
//  a password, the server's public users, Quick Connect approved from another
//  device (this test, through the API), and the errors on the way.

#if os(tvOS)
import XCTest

final class TVSignInTests: TVTestCase {
    /// Types into the field `id` with the on-screen keyboard, then puts the
    /// keyboard away with Menu (which keeps the text). Return on the TV's
    /// keyboard does not move on to the next field.
    private func type(_ text: String, into id: String, submit: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) {
        let field = app.element(id)
        XCTAssertTrue(focusInColumn(field) || Remote.focus(on: field, in: app), "couldn't focus \(id) (on \(focused?.summary ?? "nothing"))", file: file, line: line)
        Remote.select()
        waitUntil("the keyboard for \(id)", timeout: 10, file: file, line: line) { [weak self] in
            (self?.app.keyboards.count ?? 0) > 0
        }
        app.typeText(submit ? text + "\n" : text)
        if app.keyboards.count > 0 {
            Remote.menu()
            waitUntil("the keyboard to go", timeout: 10, file: file, line: line) { [weak self] in
                (self?.app.keyboards.count ?? 0) == 0
            }
        }
    }

    /// The sign-in screen, then the QA server's address, connected.
    private func connect(file: StaticString = #filePath, line: UInt = #line) {
        launch(signIn: false)
        app.element(TestID.Login.root).waitToExist(30, file: file, line: line)
        assertFocusPresent("the sign-in screen", file: file, line: line)
        type(QA.server, into: TestID.Login.serverField, submit: true, file: file, line: line)
        // A plain-http address may be asked about first.
        let banner = app.element(TestID.Login.serverBanner)
        waitUntil("the server to answer", timeout: 30, file: file, line: line) { [weak self] in
            guard let self else { return false }
            if banner.exists { return true }
            let plain = self.app.buttons["Connect without encryption"]
            if plain.exists { _ = Remote.focus(on: plain, in: self.app); Remote.select() }
            return banner.exists
        }
        XCTAssertTrue(app.element(TestID.Login.serverName).exists, file: file, line: line)
    }

    /// After connecting, a TV starts on Quick Connect (no keyboard needed);
    /// the switch under it goes to the password fields.
    private func usePassword(file: StaticString = #filePath, line: UInt = #line) {
        if app.element(TestID.Login.username).waitForExistence(timeout: 3) { return }
        let toggle = app.button(TestID.Login.modeSwitch)
        XCTAssertTrue(focusInColumn(toggle) || Remote.focus(on: toggle, in: app), "no mode switch", file: file, line: line)
        Remote.select()
        app.element(TestID.Login.username).waitToExist(10, file: file, line: line)
    }

    private func submit(file: StaticString = #filePath, line: UInt = #line) {
        let signIn = app.button(TestID.Login.signIn)
        if signIn.waitForExistence(timeout: 3), !app.element(TestID.Shell.root).exists {
            XCTAssertTrue(focusInColumn(signIn) || Remote.focus(on: signIn, in: app), "can't reach Sign in", file: file, line: line)
            Remote.select()
        }
    }

    func testPasswordSignInLandsOnHome() throws {
        guard let account = QA.account() else { throw XCTSkip("no suite account") }
        connect()
        usePassword()
        type(account.name, into: TestID.Login.username)
        type(account.password, into: TestID.Login.password)
        if !app.element(TestID.Shell.root).waitForExistence(timeout: 5) { submit() }
        app.element(TestID.Home.root).waitToExist(60)
        assertFocusPresent("Home after signing in")
    }

    func testAWrongPasswordSaysSoAndStaysPut() throws {
        guard let account = QA.account() else { throw XCTSkip("no suite account") }
        connect()
        usePassword()
        type(account.name, into: TestID.Login.username)
        type("definitely-not-the-password", into: TestID.Login.password)
        if !app.element(TestID.Login.error).waitForExistence(timeout: 5) { submit() }
        let error = app.element(TestID.Login.error)
        error.waitToExist(30)
        XCTAssertFalse(app.element(TestID.Shell.root).exists)
        // Sign in stays lit (screenshot), but XCUITest stops reporting focus
        // after the press; one more press shows the selector is still there.
        Remote.press(.up)
        assertFocusPresent("the sign-in screen after a wrong password")
        if error.label.contains("401") || error.label.contains("Server error") {
            // Seen 2026-11-13: "Server error 401 on /Users/AuthenticateByName".
            XCTExpectFailure("bug: a wrong password shows 'Server error 401 on /Users/AuthenticateByName' (login.status.error, LoginView) instead of saying the name or password is wrong")
        }
        XCTAssertFalse(error.label.contains("401"), "a raw status: \(error.label)")
        // Source: master-fix-list.md "[TV] Sign-in help text runs under the
        // focused password button" — visual, recorded for the eye.
        attachScreenshot("wrong password")
    }

    func testTheServersPublicUsersAreOffered() throws {
        let users = try Fixtures.require().raw["users"] as? [String: [String: Any]] ?? [:]
        connect()
        for name in ["fx-guest", "fx-public"] {
            guard let id = users[name]?["id"] as? String else { continue }
            XCTAssertTrue(app.element(TestID.Login.user(id)).waitForExistence(timeout: 15), "\(name) not offered")
        }
        if let id = users["suite-tv"]?["id"] as? String {
            XCTAssertFalse(app.element(TestID.Login.user(id)).exists, "a hidden user is listed")
        }
    }

    func testAPasswordlessUserSignsStraightInAndSeesOnlyTheirLibrary() throws {
        let fx = try Fixtures.require()
        let users = fx.raw["users"] as? [String: [String: Any]] ?? [:]
        guard let guest = users["fx-guest"]?["id"] as? String else { throw XCTSkip("no fx-guest") }
        connect()
        let row = app.element(TestID.Login.user(guest))
        XCTAssertTrue(focusInColumn(row) || Remote.focus(on: row, in: app))
        Remote.select()
        // This server answers HasPassword true even for fx-guest (checked on
        // /Users/Public, 2026-11-13), so the app asks; an empty one is right.
        if !app.element(TestID.Home.root).waitForExistence(timeout: 5) {
            app.element(TestID.Login.password).waitToExist(10)
            submit()
        }
        app.element(TestID.Home.root).waitToExist(60)
        openTab("libraries", title: "Library", anchor: TestID.Library.listRoot)
        XCTAssertTrue(app.element(TestID.Library.tile(try fx.libraryId("Fixture Films"))).waitForExistence(timeout: 20))
        XCTAssertFalse(app.element(TestID.Library.tile(try fx.libraryId("Fixture Shows"))).exists, "fx-guest sees Fixture Shows")
        XCTAssertFalse(app.element(TestID.Tab.item("livetv")).exists, "fx-guest has no Live TV")
    }

    func testQuickConnectSignsInOnceApprovedElsewhere() throws {
        let api = try self.api()
        connect()
        let code = app.element(TestID.Login.quickConnectCode)
        if !code.waitForExistence(timeout: 5) {
            let toggle = app.button(TestID.Login.modeSwitch)
            XCTAssertTrue(focusInColumn(toggle) || Remote.focus(on: toggle, in: app), "no Quick Connect switch")
            Remote.select()
        }
        code.waitToExist(20)
        app.element(TestID.Login.quickConnectWaiting).waitToExist(10)
        let digits = code.label.filter(\.isNumber)
        XCTAssertEqual(digits.count, 6, "code label \(code.label)")
        // Another device approves it, as Settings → Quick Connect does.
        try api.request("POST", "/QuickConnect/Authorize?code=\(digits)&userId=\(api.userId)")
        app.element(TestID.Home.root).waitToExist(60)
        assertFocusPresent("Home after Quick Connect")
    }

    func testADisabledAccountIsRefusedInPlainWords() throws {
        guard let disabled = QA.account(named: "fx-disabled") else { throw XCTSkip("no fx-disabled password") }
        connect()
        usePassword()
        type(disabled.name, into: TestID.Login.username)
        type(disabled.password, into: TestID.Login.password)
        if !app.element(TestID.Login.error).waitForExistence(timeout: 5) { submit() }
        let error = app.element(TestID.Login.error)
        error.waitToExist(30)
        attachScreenshot("disabled account")
        if error.label.contains("403") || error.label.contains("Server error") {
            // Seen 2026-11-13: "Server error 403 on /Users/AuthenticateByName".
            XCTExpectFailure("bug: signing in as a disabled account (fx-disabled) shows 'Server error 403 on /Users/AuthenticateByName' (login.status.error, LoginView) instead of saying the account is disabled")
        }
        XCTAssertFalse(error.label.contains("403"), "a raw status: \(error.label)")
    }
}
#endif
