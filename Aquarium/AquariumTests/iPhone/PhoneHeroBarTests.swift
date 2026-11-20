//  The phone's floating bar (`PhoneHeroBar`): its blur, which leans on a
//  filter UIKit does not publish, and when the bar is used at all.

#if os(iOS)
import XCTest
import UIKit
@testable import Aquarium

@MainActor
final class PhoneHeroBarUnitTests: PhoneUnitTestCase {
    /// The untinted blur is what lets the bar take the artwork's colours.
    /// Fails first if a new iOS stops answering to the filter's name, which
    /// would leave the bar on its paler fallback.
    func testVariableBlurUsesTheUntintedFilter() {
        let view = VariableBlurView(radius: 5, fullUntil: 0.35)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 50)
        view.layoutIfNeeded()
        let filters = view.subviews.first?.layer.filters ?? []
        XCTAssertFalse(filters.isEmpty, "no variable-blur filter on the backdrop")
        XCTAssertNil(view.layer.mask, "fell back to the masked, tinted blur")
        for tint in view.subviews.dropFirst() {
            XCTAssertEqual(tint.alpha, 0, "the blur's tint is showing")
        }
    }

    /// A foldable keeps the solid bar its status strips are built around.
    func testFloatsOnAPhoneButNotOnAFoldable() {
        if Metrics.phoneLayout, !FoldState.shared.isFoldable { XCTAssertTrue(PhoneHeroBar.applies) }
        if FoldState.shared.isFoldable { XCTAssertFalse(PhoneHeroBar.applies) }
    }

    /// The bar turns from white to the page's colour only once the artwork
    /// has gone from under it: Home's hero is the taller of the two.
    func testThresholdsSitPastTheArtwork() {
        XCTAssertGreaterThan(PhoneHeroBar.threshold(home: true), PhoneHeroBar.threshold(home: false))
        XCTAssertGreaterThan(PhoneHeroBar.threshold(home: false), Metrics.topBar)
    }
}
#endif
