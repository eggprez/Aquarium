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
}
#endif
