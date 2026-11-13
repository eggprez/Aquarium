//  iPad UI tests live in this folder (owner: the iPad agent). Every file here is
//  wrapped in `#if os(iOS)` so the bundle still builds for the other platforms.
//  Subclass `PadUITestCase`. See Aquarium/TESTING.md.

#if os(iOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

class PadUITestCase: AquariumUITestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        try super.setUpWithError()
    }
}
#endif
