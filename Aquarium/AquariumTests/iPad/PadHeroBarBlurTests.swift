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
        XCTAssertTrue(view.usesFilter, "fell back to the masked, tinted blur")
        for tint in view.subviews.dropFirst() {
            XCTAssertEqual(tint.alpha, 0, "the blur's tint is showing")
        }
    }

    /// At the top of the page only the status bar's strip is blurred; once
    /// the page has moved the blur reaches past the bar (2026-11-21: it used
    /// to wait for the hero to scroll away, and crossfaded when it did).
    func testBlurGrowsFromTheStatusStripAsThePageMoves() {
        let inset: CGFloat = 24, bar = Metrics.topBar
        let whole = inset + bar + BarBlur.overhang
        // The view is taller than the blur ever gets, so it never ends in a line.
        let height = whole + BarBlur.margin
        let rest = BlurShape(radius: 5, fullUntil: 0.35, clearBottom: height - inset)
        XCTAssertEqual(BlurShape.blend(rest, BarBlur.scrolled, progress: 0, height: height).reach, inset)
        XCTAssertEqual(BlurShape.blend(rest, BarBlur.scrolled, progress: 1, height: height).reach, whole)
        let half = BlurShape.blend(rest, BarBlur.scrolled, progress: BarScroll.progress(offset: BarScroll.distance / 2),
                                   height: height)
        XCTAssertEqual(half.reach, (inset + whole) / 2)
        XCTAssertEqual(half.radius, 11.5)
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
