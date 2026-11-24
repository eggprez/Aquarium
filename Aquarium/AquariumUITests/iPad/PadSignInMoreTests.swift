//  The server banner on an iPad's sign-in card, which PadSignInTests reads
//  only for its name and address: the QA server is plain HTTP, so the
//  banner marks it HTTP and says what that means, and "Use a different
//  server" goes back to the address field with the form gone
//  (LoginView.connectedBanner, useDifferentServer).

#if os(iOS)
import XCTest

final class PadSignInMoreTests: PadUITestCase {
    private func connectToQAServer() {
        launch(signIn: false)
        app.element(TestID.Shell.signedOut).waitToExist(30)
        let server = app.textFields[TestID.Login.serverField]
        server.padTap()
        server.typeText(QA.server)
        app.button(TestID.Login.connect).padTap()
        app.element(TestID.Login.serverBanner).waitToExist(30)
    }

    func testAPlainHTTPServerIsMarkedAndExplained() throws {
        try XCTSkipUnless(QA.server.hasPrefix("http://"), "the QA server is not plain HTTP here: \(QA.server)")
        connectToQAServer()
        XCTAssertTrue(app.element(TestID.Login.serverSecurity).exists, "the security pill")
        XCTAssertTrue(app.staticTexts["HTTP"].exists, "the pill reads HTTP")
        let warning = app.element(TestID.Login.serverInsecureWarning)
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "a word on what plain HTTP means")
        XCTAssertTrue(warning.label.hasPrefix("This connection isn't encrypted."), warning.label)
        attachScreenshot("http server")
    }

    func testADifferentServerGoesBackToTheAddress() throws {
        connectToQAServer()
        XCTAssertTrue(app.textFields[TestID.Login.username].waitForExistence(timeout: 10)
                      || app.secureTextFields[TestID.Login.password].exists, "the form for this server")
        app.button(TestID.Login.differentServer).padTap()
        XCTAssertTrue(app.element(TestID.Login.serverBanner).waitToVanish(10), "the banner goes")
        XCTAssertTrue(app.textFields[TestID.Login.serverField].waitForExistence(timeout: 10), "the address field is back")
        XCTAssertFalse(app.textFields[TestID.Login.username].exists, "no user name for a server not chosen")
        XCTAssertFalse(app.secureTextFields[TestID.Login.password].exists)
        XCTAssertFalse(app.element(TestID.Home.root).exists)
    }
}
#endif
