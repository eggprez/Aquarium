//  The base class of every UI test.
//
//  - Skips (not fails) when the QA server doesn't answer, or this suite has
//    no account, so a machine without the QA server reports skips.
//  - Attaches a screenshot and the element tree to every failure.
//  - `continueAfterFailure = false`: the first failure ends the test.
//
//  Subclass the platform's own case (`PhoneUITestCase`, `PadUITestCase`,
//  `MacUITestCase`, `TVUITestCase`, `WatchUITestCase`), which also skips on
//  the wrong device.

import XCTest

class AquariumUITestCase: XCTestCase {
    /// The app as last launched by `launch`.
    var app: XCUIApplication!

    /// Whether this test needs the QA server. Override with false for a test
    /// that only looks at the sign-in screen.
    class var needsServer: Bool { true }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        if Self.needsServer {
            guard QA.isReachable() else { throw XCTSkip("QA server not answering at \(QA.server)") }
            guard QA.account() != nil else {
                throw XCTSkip("no password for suite-\(QA.suite) in \(QA.folder.path)/suite-accounts.txt")
            }
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }

    /// Launch in test mode — see `TestApp.launch`.
    @discardableResult
    func launch(reset: Bool = true, signIn: Bool = true, account: QA.Account? = QA.account(),
                engine: String? = nil, arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        app = TestApp.launch(reset: reset, signIn: signIn, account: account, engine: engine,
                             arguments: arguments, environment: environment)
        return app
    }

    func attachScreenshot(_ name: String = "screen") {
        for (index, shot) in Self.screenshots(of: app ?? XCUIApplication()).enumerated() {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = index == 0 ? name : "\(name) \(index + 1)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// The app's screenshot; on a Mac, every display's instead. There an
    /// app's own screenshot failed outright ("Failed to create screenshot.
    /// Image creation failed") with its window on a second display, which
    /// failed the test that asked for it.
    static func screenshots(of app: XCUIApplication) -> [XCUIScreenshot] {
        #if os(macOS)
        XCUIScreen.screens.map { $0.screenshot() }
        #else
        [app.screenshot()]
        #endif
    }

    /// Set while `record` is adding its attachments. Taking the screenshot
    /// can itself fail ("Failed to create screenshot", seen on a Mac whose
    /// app window is on a second display), and that failure is recorded
    /// through here again: without this, screenshot after screenshot until
    /// the runner's stack ran out and it crashed.
    private var isAttachingToIssue = false

    override func record(_ issue: XCTIssue) {
        var issue = issue
        if let app, !isAttachingToIssue {
            isAttachingToIssue = true
            defer { isAttachingToIssue = false }
            for (index, image) in Self.screenshots(of: app).enumerated() {
                let shot = XCTAttachment(screenshot: image)
                shot.name = index == 0 ? "failure screenshot" : "failure screenshot \(index + 1)"
                shot.lifetime = .keepAlways
                issue.add(shot)
            }
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "element tree"
            tree.lifetime = .keepAlways
            issue.add(tree)
        }
        super.record(issue)
    }
}
