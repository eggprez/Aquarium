//  Signing in on a Mac: the password form, a wrong password, Quick Connect
//  approved from the server side, the sidebar's account menu and signing out.

#if os(macOS)
import XCTest

final class MacSignInUITests: MacUITestCase {
    private func launchSignedOut() {
        launch(signIn: false)
        app.element(TestID.Shell.signedOut).waitToExist(60)
        app.element(TestID.Login.root).waitToExist(20)
    }

    /// Server address, then Connect: the banner names the QA server.
    private func connect() {
        let field = app.textFields[TestID.Login.serverField]
        field.tapWhenReady()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(QA.server)
        app.button(TestID.Login.connect).tapWhenReady()
        app.element(TestID.Login.serverBanner).waitToExist(30)
    }

    func testPasswordSignInReachesHome() throws {
        let account = try XCTUnwrap(QA.account())
        launchSignedOut()
        connect()
        let user = app.textFields[TestID.Login.username]
        user.tapWhenReady()
        user.typeText(account.name)
        let password = app.secureTextFields[TestID.Login.password]
        password.tapWhenReady()
        password.typeText(account.password)
        app.button(TestID.Login.signIn).tapWhenReady()
        app.element(TestID.Home.root).waitToExist(60)
        XCTAssertTrue(sidebarRow("home").exists)
        attachScreenshot("signed in")
    }

    func testWrongPasswordSaysSoAndStays() throws {
        let account = try XCTUnwrap(QA.account())
        launchSignedOut()
        connect()
        let user = app.textFields[TestID.Login.username]
        user.tapWhenReady()
        user.typeText(account.name)
        let password = app.secureTextFields[TestID.Login.password]
        password.tapWhenReady()
        password.typeText("not-the-password\r")
        app.element(TestID.Login.error).waitToExist(30)
        XCTAssertFalse(app.element(TestID.Home.root).exists)
    }

    func testDisabledAccountIsRefused() throws {
        launchSignedOut()
        connect()
        let user = app.textFields[TestID.Login.username]
        user.tapWhenReady()
        user.typeText("fx-disabled")
        let password = app.secureTextFields[TestID.Login.password]
        password.tapWhenReady()
        password.typeText("anything\r")
        app.element(TestID.Login.error).waitToExist(30)
    }

    /// Quick Connect: the app shows a code, this suite's account approves it
    /// through the API (as a phone would), and the Mac signs itself in.
    func testQuickConnectSignsIn() throws {
        let api = try JellyfinAPI.signIn()
        launchSignedOut()
        connect()
        let picker = app.element(TestID.Login.modePicker)
        if picker.waitForExistence(timeout: 5) {
            let option = app.element(TestID.Login.modeOption("quickConnect"))
            if option.exists { option.click() } else { picker.radioButtons["Quick Connect"].click() }
        } else {
            app.element(TestID.Login.modeSwitch).tapWhenReady()
        }
        let code = app.element(TestID.Login.quickConnectCode)
        code.waitToExist(30)
        let digits = (code.value as? String ?? code.label).filter(\.isNumber)
        XCTAssertEqual(digits.count, 6, "a six-digit code: \(code.label)")
        try api.request("POST", "/QuickConnect/Authorize?code=\(digits)&userId=\(api.userId)")
        app.element(TestID.Home.root).waitToExist(60)
    }

    /// The menu's items can't be listed (see `openAccountMenu`), so each is
    /// chosen by its title and checked by what it does.
    func testAccountMenuOffersAddSettingsAndSignOut() throws {
        launchToHome()
        openAccountMenu()
        chooseInOpenMenu(typing: "Add Account")
        XCTAssertTrue(app.element(TestID.Login.root).waitForExistence(timeout: 10), "Add Account… opens the sign-in sheet")
        app.typeKey(.escape, modifierFlags: [])   // AutoFill's list, if it is up
        if !app.element(TestID.Login.root).waitToVanish(3) { app.typeKey(.escape, modifierFlags: []) }
        XCTAssertTrue(app.element(TestID.Login.root).waitToVanish(10))
        openAccountMenu()
        chooseInOpenMenu(typing: "Settings")
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings… opens Settings")
        app.typeKey("w", modifierFlags: .command)
        mainWindow.click()
        openAccountMenu()
        chooseInOpenMenu(typing: "Sign Out")
        app.button(TestID.Shell.signOutCancel).tapWhenReady(10)
        XCTAssertTrue(app.element(TestID.Home.root).exists, "Sign Out… asks first; Cancel keeps you in")
    }

    func testSignOutAsksFirstAndCancelKeepsYouIn() {
        launchToHome()
        signOutThroughSettings(confirm: false)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.element(TestID.Home.root).waitForExistence(timeout: 5))
        XCTAssertFalse(app.element(TestID.Shell.signedOut).exists)
    }

    func testSignOutReturnsToSignIn() {
        launchToHome()
        signOutThroughSettings(confirm: true)
        app.element(TestID.Shell.signedOut).waitToExist(30)
    }

    func testAddAccountOpensTheSignInSheet() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["Account"].tapWhenReady()
        app.element(TestID.Settings.addAccount).tapWhenReady()
        app.element(TestID.Login.root).waitToExist(20)
        // The username field has the keyboard, and the system's AutoFill
        // list drops down from it over the sheet's buttons, sometimes a
        // while after the sheet, and a click on Cancel landed on the list.
        // So Cancel is pressed with its key, Escape (`.cancelAction`): the
        // first Escape may only put the list away.
        for _ in 0..<3 where app.element(TestID.Login.root).exists {
            app.typeKey(.escape, modifierFlags: [])
            _ = app.element(TestID.Login.root).waitToVanish(3)
        }
        XCTAssertTrue(app.element(TestID.Login.root).waitToVanish(10))
    }

    /// The relaunch keeps the session: test mode keeps the token in its own
    /// defaults, not the keychain.
    func testRelaunchStaysSignedIn() {
        launchToHome()
        app.terminate()
        launch(reset: false, signIn: false)
        app.element(TestID.Home.root).waitToExist(60)
    }
}
#endif
