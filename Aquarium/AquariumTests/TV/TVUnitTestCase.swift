//  Apple TV unit tests live in this folder (owner: the Apple TV agent). Every file here
//  is wrapped in `#if os(tvOS)` so the bundle still builds for the other platforms;
//  subclass `TVUnitTestCase` to have a test skip itself where it does not apply.
//  See Aquarium/TESTING.md.

#if os(tvOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Aquarium

class TVUnitTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Compiled for the Apple TV only; nothing to skip.
    }
}
#endif
