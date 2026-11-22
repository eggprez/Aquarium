//  Mac unit tests live in this folder (owner: the Mac agent). Every file here
//  is wrapped in `#if os(macOS)` so the bundle still builds for the other platforms;
//  subclass `MacUnitTestCase` to have a test skip itself where it does not apply.
//  See Aquarium/TESTING.md.

#if os(macOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Aquarium

class MacUnitTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Compiled for the Mac only; nothing to skip.
    }
}
#endif
