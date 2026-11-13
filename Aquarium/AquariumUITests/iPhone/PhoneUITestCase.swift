//  iPhone UI tests live in this folder (owner: the iPhone agent). Every file here is
//  wrapped in `#if os(iOS)` so the bundle still builds for the other platforms.
//  Subclass `PhoneUITestCase`. See Aquarium/TESTING.md.

#if os(iOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

class PhoneUITestCase: AquariumUITestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        try super.setUpWithError()
    }
}
#endif
