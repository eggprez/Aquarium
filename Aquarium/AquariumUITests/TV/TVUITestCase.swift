//  Apple TV UI tests live in this folder (owner: the Apple TV agent). Every file here is
//  wrapped in `#if os(tvOS)` so the bundle still builds for the other platforms.
//  Subclass `TVUITestCase`. See Aquarium/TESTING.md.

#if os(tvOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

class TVUITestCase: AquariumUITestCase {
    override func setUpWithError() throws {
        // Apple TV only by compilation.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // `XCUIApplication.terminate()` on the Apple TV simulator takes about
        // two minutes every time (every teardown of the first runs, sent to
        // the background first or not), while the next test's `launch()` ends
        // the old process in a second or two. So the app is left for the next
        // launch, and the run script's `simctl terminate` ends the last one.
        app = nil
        try super.tearDownWithError()
    }
}
#endif
