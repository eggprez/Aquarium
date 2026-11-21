//  The surface under an iPad's floating bar (`padBarSurface`, 2026-11-20):
//  the untinted blur the phone's bar has, rather than a tinted band.

#if os(iOS)
import XCTest
import UIKit
@testable import Aquarium

@MainActor
final class PadHeroBarBlurTests: PadUnitTestCase {
    /// Fails first if a new iPadOS stops answering to the filter's name,
    /// which would leave the bar on its paler fallback.
    func testVariableBlurUsesTheUntintedFilter() {
        let view = VariableBlurView(radius: 18, fullUntil: 0.75)
        view.frame = CGRect(x: 0, y: 0, width: 1032, height: 98)
        view.layoutIfNeeded()
        XCTAssertFalse((view.subviews.first?.layer.filters ?? []).isEmpty, "no variable-blur filter on the backdrop")
        XCTAssertNil(view.layer.mask, "fell back to the masked, tinted blur")
        for tint in view.subviews.dropFirst() {
            XCTAssertEqual(tint.alpha, 0, "the blur's tint is showing")
        }
    }

    /// The mask is a column one pixel wide, opaque at the top.
    func testMaskIsOpaqueAtTheTopAndClearAtTheBottom() throws {
        let mask = try XCTUnwrap(VariableBlurFilter.mask(height: 40, fullUntil: 0.35))
        let data = try XCTUnwrap(mask.dataProvider?.data as Data?)
        XCTAssertGreaterThan(data[3], 250, "the top row is not opaque")
        XCTAssertLessThan(data[mask.bytesPerRow * 39 + 3], 10, "the bottom row is not clear")
    }
}
#endif
