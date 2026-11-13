//  Mac UI tests live in this folder (owner: the Mac agent). Every file here is
//  wrapped in `#if os(macOS)` so the bundle still builds for the other platforms.
//  Subclass `MacUITestCase`. See Aquarium/TESTING.md.

#if os(macOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

class MacUITestCase: AquariumUITestCase {
    override func setUpWithError() throws {
        // The debug build shares its bundle id (and so its container) with the
        // copy of Aquarium in real use, and launching the test build would
        // quit that copy. Test mode keeps the data apart; this keeps the
        // running app alive.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "scottai.FellyJin")
        if !running.isEmpty {
            throw XCTSkip("Aquarium is running on this Mac: quit it before running the Mac UI tests")
        }
        try super.setUpWithError()
    }

    /// Notes the time for `macSessions`, which leaves out the sessions of
    /// earlier launches — see there.
    @discardableResult
    override func launch(reset: Bool = true, signIn: Bool = true, account: QA.Account? = QA.account(),
                         engine: String? = nil, arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        if reset { JellyfinAPI.macLaunchedAt = Date() }
        return super.launch(reset: reset, signIn: signIn, account: account, engine: engine,
                            arguments: arguments, environment: environment)
    }
}
#endif
