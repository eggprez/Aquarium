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

    func testAccountMenuOffersAddSettingsAndSignOut() {
        launchToHome()
        app.element(TestID.Sidebar.accountMenu).tapWhenReady()
        for id in [TestID.Sidebar.accountMenuAdd, TestID.Sidebar.accountMenuSettings, TestID.Sidebar.accountMenuSignOut] {
            XCTAssertTrue(app.element(id).waitForExistence(timeout: 5), id)
        }
        dismissMenus()
    }

    func testSignOutAsksFirstAndCancelKeepsYouIn() {
        launchToHome()
        app.element(TestID.Sidebar.accountMenu).tapWhenReady()
        app.element(TestID.Sidebar.accountMenuSignOut).tapWhenReady()
        app.button(TestID.Shell.signOutCancel).tapWhenReady()
        XCTAssertTrue(app.element(TestID.Home.root).waitForExistence(timeout: 5))
        XCTAssertFalse(app.element(TestID.Shell.signedOut).exists)
    }

    func testSignOutReturnsToSignIn() {
        launchToHome()
        app.element(TestID.Sidebar.accountMenu).tapWhenReady()
        app.element(TestID.Sidebar.accountMenuSignOut).tapWhenReady()
        app.button(TestID.Shell.signOutConfirm).tapWhenReady()
        app.element(TestID.Shell.signedOut).waitToExist(30)
    }

    func testAddAccountOpensTheSignInSheet() {
        launchToHome()
        app.element(TestID.Sidebar.accountMenu).tapWhenReady()
        app.element(TestID.Sidebar.accountMenuAdd).tapWhenReady()
        app.element(TestID.Login.root).waitToExist(20)
        app.button(TestID.Login.cancel).tapWhenReady()
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
