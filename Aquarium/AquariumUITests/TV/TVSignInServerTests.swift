//  The server half of signing in on the Apple TV (Views/LoginView.swift
//  `connectedBanner`), beyond `TVSignInTests`: a plain-http server is marked
//  HTTP with the warning under it, and "Use a different server" goes back
//  to the address with the remote.

#if os(tvOS)
import XCTest

final class TVSignInServerTests: TVTestCase {
    /// The sign-in screen with the QA server's address typed and connected.
    /// As `TVSignInTests.connect`, which is private there.
    private func connect(file: StaticString = #filePath, line: UInt = #line) {
        launch(signIn: false)
        app.element(TestID.Login.root).waitToExist(30, file: file, line: line)
        assertFocusPresent("the sign-in screen", file: file, line: line)
        let field = app.element(TestID.Login.serverField)
        XCTAssertTrue(focusInColumn(field) || Remote.focus(on: field, in: app),
                      "couldn't focus the address (on \(focused?.summary ?? "nothing"))", file: file, line: line)
        Remote.select()
        waitUntil("the keyboard", timeout: 10, file: file, line: line) { [weak self] in (self?.app.keyboards.count ?? 0) > 0 }
        app.typeText(QA.server + "\n")
        if app.keyboards.count > 0 {
            Remote.menu()
            waitUntil("the keyboard to go", timeout: 10, file: file, line: line) { [weak self] in (self?.app.keyboards.count ?? 0) == 0 }
        }
        let banner = app.element(TestID.Login.serverBanner)
        waitUntil("the server to answer", timeout: 30, file: file, line: line) { [weak self] in
            guard let self else { return false }
            if banner.exists { return true }
            let plain = self.app.buttons["Connect without encryption"]
            if plain.exists { _ = Remote.focus(on: plain, in: self.app); Remote.select() }
            return banner.exists
        }
    }

    func testAPlainHTTPServerIsMarkedAndWarnedAbout() throws {
        guard !QA.server.lowercased().hasPrefix("https") else { throw XCTSkip("the QA server is on HTTPS") }
        connect()
        XCTAssertTrue(app.element(TestID.Login.serverSecurity).waitForExistence(timeout: 10), "no HTTP/HTTPS mark on the server")
        let warning = app.element(TestID.Login.serverInsecureWarning)
        XCTAssertTrue(warning.exists, "a plain-http server is not warned about")
        XCTAssertTrue(warning.label.localizedCaseInsensitiveContains("isn't encrypted"), warning.label)
        let detail = app.element(TestID.Login.serverDetail)
        XCTAssertTrue(detail.label.contains("Jellyfin"), "the server's version isn't named: \(detail.label)")
        attachScreenshot("plain http server")
    }

    func testUseADifferentServerGoesBackToTheAddress() {
        connect()
        let different = app.element(TestID.Login.differentServer)
        XCTAssertTrue(different.waitForExistence(timeout: 10))
        XCTAssertTrue(focusInColumn(different) || Remote.focus(on: different, in: app),
                      "can't reach Use a different server (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        XCTAssertTrue(app.element(TestID.Login.serverBanner).waitToVanish(10), "the server stayed chosen")
        XCTAssertTrue(app.element(TestID.Login.serverField).waitForExistence(timeout: 10), "no address field to type another")
        XCTAssertFalse(app.element(TestID.Login.username).exists, "the sign-in fields stayed for the old server")
        assertFocusPresent("the address after Use a different server")
    }
}
#endif
