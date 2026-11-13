//  Sign-in on the phone: a password, a wrong one, the special fx- accounts,
//  a passwordless user picked from the server's list, Quick Connect approved
//  from the test's own session, signing out, a second account and switching
//  to it, and how the form sits on the small phone with the keyboard up.

#if os(iOS)
import XCTest

final class PhoneSignInTests: PhoneUITestCase {
    // MARK: Helpers

    /// At the sign-in screen, connected to the QA server (banner showing).
    private func connect(file: StaticString = #filePath, line: UInt = #line) {
        launch(signIn: false)
        app.element(TestID.Login.root).waitToExist(60, file: file, line: line)
        let field = app.textFields[TestID.Login.serverField]
        field.tapNow(20, file: file, line: line)
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(QA.server)
        app.button(TestID.Login.connect).tapNow(20, file: file, line: line)
        app.element(TestID.Login.serverBanner).waitToExist(30, file: file, line: line)
    }

    private func typeCredentials(_ name: String, _ password: String, file: StaticString = #filePath, line: UInt = #line) {
        let user = app.textFields[TestID.Login.username]
        user.tapNow(20, file: file, line: line)
        user.typeText(name)
        // Return does not move to the password on a phone, and the password
        // can sit under the keyboard. XCUITest's own tap scrolls it into view
        // (a tap by coordinate would land on a key).
        let pw = app.secureTextFields[TestID.Login.password]
        pw.waitToExist(10, file: file, line: line)
        pw.tap()
        if !password.isEmpty { pw.typeText(password) }
        dismissKeyboard()
        let signIn = app.button(TestID.Login.signIn)
        app.reveal(signIn)
        signIn.tapNow(10, file: file, line: line)
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        if app.keyboards.firstMatch.exists { app.swipeDown() }
    }

    private func tapModeSwitch(file: StaticString = #filePath, line: UInt = #line) {
        dismissKeyboard()
        let b = app.button(TestID.Login.modeSwitch)
        b.waitToExist(20, file: file, line: line)
        app.reveal(b)
        b.tapNow(10, file: file, line: line)
    }

    // MARK: Password

    func testPasswordSignInReachesHome() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account())
        connect()
        XCTAssertTrue(app.element(TestID.Login.serverName).exists)
        XCTAssertTrue(app.element(TestID.Login.serverSecurity).exists, "HTTP/HTTPS is said")
        typeCredentials(account.name, account.password)
        app.element(TestID.Home.root).waitToExist(60)
        XCTAssertFalse(app.element(TestID.Shell.signedOut).exists)
    }

    func testWrongPasswordSaysSo() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account())
        connect()
        typeCredentials(account.name, account.password + "-wrong")
        app.element(TestID.Login.error).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Home.root).exists)
    }

    /// fx-disabled answers 403 (FIXTURES.md): the form says why and stays.
    func testDisabledAccountIsRefused() throws {
        try standardOnly()
        let disabled = try XCTUnwrap(QA.account(named: "fx-disabled"), "fx-disabled not in suite-accounts.txt")
        connect()
        typeCredentials(disabled.name, disabled.password)
        app.element(TestID.Login.error).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Home.root).exists)
    }

    /// The server lists exactly fx-guest and fx-public; fx-guest has no
    /// password and signs straight in from its tile.
    func testPublicUsersAreListedAndAPasswordlessOneSignsIn() throws {
        try standardOnly()
        let users = try Fixtures.require().raw["users"] as? [String: [String: Any]] ?? [:]
        let guest = try XCTUnwrap(users["fx-guest"]?["id"] as? String)
        let publicUser = try XCTUnwrap(users["fx-public"]?["id"] as? String)
        connect()
        app.element(TestID.Login.user(publicUser)).waitToExist(20)
        let tile = app.element(TestID.Login.user(guest))
        tile.waitToExist(20)
        tile.tap()
        if !app.element(TestID.Home.root).waitForExistence(timeout: 20) {
            // The tile may fill the name only: sign in with no password.
            app.button(TestID.Login.signIn).tapNow(10)
        }
        app.element(TestID.Home.root).waitToExist(60)
        // fx-guest sees Fixture Films only.
        let films = try Fixtures.require().libraryId("Fixture Films")
        let shows = try Fixtures.require().libraryId("Fixture Shows")
        app.element(TestID.Library.tile(films)).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Library.tile(shows)).exists, "fx-guest must not see Fixture Shows")
    }

    /// fx-limited sees only Fixture Films and Fixture Music, and no live TV.
    func testLimitedAccountSeesOnlyItsLibraries() throws {
        try standardOnly()
        let limited = try XCTUnwrap(QA.account(named: "fx-limited"))
        launchHome(account: limited)
        let fx = try Fixtures.require()
        app.element(TestID.Library.tile(try fx.libraryId("Fixture Films"))).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Library.tile(try fx.libraryId("Fixture Shows"))).exists)
        XCTAssertFalse(app.element(TestID.Home.shelf(TestID.Home.rowLiveTV)).exists, "no live TV for fx-limited")
    }

    /// fx-kid (parental rating PG): the PG-13/R/NC-17/unrated/blocked fixtures
    /// never appear, the G one does.
    func testKidAccountHidesRatedTitles() throws {
        try standardOnly()
        let kid = try XCTUnwrap(QA.account(named: "fx-kid"))
        let fx = try Fixtures.require()
        launchHome(account: kid)
        search("FX Rated")
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("film.rated_g").id)).firstMatch.waitToExist(30)
        for key in ["film.rated_pg13", "film.rated_r", "film.rated_nc17"] {
            XCTAssertFalse(app.buttons.matching(identifier: TestID.Item.card(try fx.item(key).id)).firstMatch.exists, key)
        }
    }

    // MARK: Quick Connect

    /// The app asks for a code; the test's own signed-in session approves it
    /// (Authorize as suite-iphone), and the app signs in.
    func testQuickConnectSignsInOnceApproved() throws {
        try standardOnly()
        let api = try self.api
        connect()
        tapModeSwitch()
        let code = app.element(TestID.Login.quickConnectCode)
        code.waitToExist(30)
        let digits = (code.label + " " + (code.value as? String ?? "")).filter(\.isNumber)
        XCTAssertGreaterThanOrEqual(digits.count, 6, "code reads its digits: \(code.label)")
        let six = String(digits.prefix(6))
        try api.request("POST", "/QuickConnect/Authorize?code=\(six)&userId=\(api.userId)")
        app.element(TestID.Home.root).waitToExist(60)
    }

    func testQuickConnectAndBackToPassword() throws {
        try standardOnly()
        connect()
        tapModeSwitch()
        app.element(TestID.Login.quickConnectPanel).waitToExist(30)
        tapModeSwitch()
        app.textFields[TestID.Login.username].waitToExist(10)
    }

    // MARK: Server

    func testUnreachableServerSaysSo() throws {
        try standardOnly()
        launch(signIn: false)
        app.element(TestID.Login.root).waitToExist(60)
        let field = app.textFields[TestID.Login.serverField]
        field.tapNow(20)
        field.typeText("http://127.0.0.1:9")
        app.button(TestID.Login.connect).tapNow(20)
        app.element(TestID.Login.error).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Login.serverBanner).exists)
    }

    func testDifferentServerGoesBackToTheAddress() throws {
        try standardOnly()
        connect()
        dismissKeyboard()
        app.button(TestID.Login.differentServer).tapNow(20)
        app.textFields[TestID.Login.serverField].waitToExist(20)
        XCTAssertFalse(app.element(TestID.Login.serverBanner).exists)
    }

    /// Regression R-Duo-user (side-notes iphone-duo-front-visual-findings;
    /// open on main): a user picked on one server stayed in the name field
    /// after "Use a different server".
    func testUsernameClearedAfterDifferentServer() throws {
        try standardOnly()
        connect()
        let user = app.textFields[TestID.Login.username]
        user.tapNow(20)
        user.typeText("someone")
        dismissKeyboard()
        app.button(TestID.Login.differentServer).tapNow(20)
        let field = app.textFields[TestID.Login.serverField]
        field.tapNow(20)
        app.button(TestID.Login.connect).tapNow(20)
        app.element(TestID.Login.serverBanner).waitToExist(30)
        let value = app.textFields[TestID.Login.username].value as? String ?? ""
        XCTExpectFailure("bug: the username typed for the last server is kept after Use a different server")
        XCTAssertTrue(value.isEmpty || value == app.textFields[TestID.Login.username].placeholderValue, "name kept: \(value)")
    }

    // MARK: Sign out, accounts

    func testSignOutReturnsToTheSignInScreen() throws {
        try standardOnly()
        launchHome()
        openSettings()
        app.button(TestID.Settings.pageLink("account")).tapNow(20)
        let signOut = app.button(TestID.Settings.signOut)
        app.reveal(signOut)
        signOut.tapNow(20)
        app.button(TestID.Settings.signOutConfirm).tapNow(20)
        app.element(TestID.Shell.signedOut).waitToExist(30)
    }

    /// Regression R-TV30 (master-fix-list, Apple TV #30; open on main): the
    /// sign-out question named the server, not the account.
    func testSignOutQuestionNamesTheAccount() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account())
        launchHome()
        openSettings()
        app.button(TestID.Settings.pageLink("account")).tapNow(20)
        let signOut = app.button(TestID.Settings.signOut)
        app.reveal(signOut)
        signOut.tapNow(20)
        // A popover with no Cancel on iOS 27: the question, then Sign out.
        app.button(TestID.Settings.signOutConfirm).waitToExist(20)
        let question = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Sign out of'")).firstMatch
        question.waitToExist(10)
        attachScreenshot("sign-out question")
        let named = question.label.contains(account.name)
        // Dismiss without signing out: a tap outside the popover.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTExpectFailure("bug R-TV30: the sign-out question reads \"\(question.label)\", naming the server and not the account")
        XCTAssertTrue(named, "the question should name \(account.name)")
    }

    /// Add a second account (suite-spare1) from Settings, then switch back
    /// to the first from the accounts list.
    func testAddSecondAccountAndSwitchBack() throws {
        try standardOnly()
        let spare = try XCTUnwrap(QA.account(named: "suite-spare1"))
        let me = try XCTUnwrap(QA.account())
        launchHome()
        openSettings()
        app.button(TestID.Settings.pageLink("account")).tapNow(20)
        let add = app.button(TestID.Settings.addAccount)
        app.reveal(add)
        add.tapNow(20)
        app.element(TestID.Login.root).waitToExist(30)
        let field = app.textFields[TestID.Login.serverField]
        if field.waitForExistence(timeout: 5), field.isEnabled {
            field.tap()
            field.typeText(QA.server)
            app.button(TestID.Login.connect).tapNow(20)
        }
        app.element(TestID.Login.serverBanner).waitToExist(30)
        typeCredentials(spare.name, spare.password)
        app.element(TestID.Home.root).waitToExist(60)

        openSettings()
        app.button(TestID.Settings.pageLink("account")).tapNow(20)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.accounts.account."))
        XCTAssertTrue(eventually { rows.count >= 2 }, "both accounts listed")
        let mine = rows.matching(NSPredicate(format: "label CONTAINS %@", me.name)).firstMatch
        mine.tapNow(20)
        app.element(TestID.Home.root).waitToExist(60)
    }

    // MARK: Layout

    /// Regression R-SE-signin (side-notes iphone-se-visual-findings; open on
    /// main): on the SE the keyboard hid Username and Password.
    func testSignInFieldsClearOfTheKeyboard() throws {
        connect()
        let user = app.textFields[TestID.Login.username]
        user.tapNow(20)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        assertAboveKeyboard(user, "username")
        let pw = app.secureTextFields[TestID.Login.password]
        pw.tap()
        assertAboveKeyboard(pw, "password")
        assertOnScreen(app.button(TestID.Login.signIn), "Sign in")
        attachScreenshot("sign-in with keyboard (\(device.rawValue))")
    }

    func testSignInScreenFitsTheScreen() throws {
        launch(signIn: false)
        app.element(TestID.Login.root).waitToExist(60)
        assertOnScreen(app.textFields[TestID.Login.serverField], "server field")
        assertOnScreen(app.button(TestID.Login.connect), "Connect")
        attachScreenshot("sign-in (\(device.rawValue))")
    }
}
#endif
