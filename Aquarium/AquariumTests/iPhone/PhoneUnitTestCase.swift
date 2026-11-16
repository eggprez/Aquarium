//  iPhone unit tests live in this folder (owner: the iPhone agent). Every file here
//  is wrapped in `#if os(iOS)` so the bundle still builds for the other platforms;
//  subclass `PhoneUnitTestCase` to have a test skip itself where it does not apply.
//  See Aquarium/TESTING.md.

#if os(iOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Aquarium

class PhoneUnitTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
    }
}
#endif
