//  The phone's floating bar (`PhoneHeroBar`) and the blur it shares with
//  `AppTopBar` (`BarBlur`): the filter UIKit does not publish, the part of
//  the bar left clear over artwork, the frame a foldable gives the bar, and
//  when the bar is used at all.

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
        XCTAssertTrue(view.usesFilter, "fell back to the masked, tinted blur")
        for tint in view.subviews.dropFirst() {
            XCTAssertEqual(tint.alpha, 0, "the blur's tint is showing")
        }
    }

    /// Every phone floats the bar, a foldable on either screen included;
    /// nothing else does.
    func testFloatsOnEveryPhone() {
        XCTAssertEqual(PhoneHeroBar.applies, Metrics.phoneLayout)
    }

    /// Over artwork the blur stops above the bar's own row: the mask is
    /// opaque at the top, clear from the row up to the bottom, so a face
    /// under the wordmark stays sharp.
    func testBarBlurLeavesTheBarRowClearOverArtwork() throws {
        // A 100-point view whose bottom 40 stay clear: full to 21, gone by 60.
        let mask = try XCTUnwrap(VariableBlurFilter.mask(height: 100, fullUntil: 0.35 * 0.6, endAt: 0.6))
        XCTAssertEqual(mask.height, 100)
        let alpha = try XCTUnwrap(Self.alphas(of: mask))
        XCTAssertEqual(alpha[0], 255, "not blurred at the top")
        XCTAssertEqual(alpha[15], 255, "the full-strength band ends early")
        XCTAssertLessThan(alpha[50], alpha[25], "the blur does not ease out")
        XCTAssertEqual(alpha[65], 0, "the bar's row is blurred")
        XCTAssertEqual(alpha[99], 0, "the bar's row is blurred")
        // To the bottom when nothing is kept clear, as before.
        let whole = try XCTUnwrap(VariableBlurFilter.mask(height: 100, fullUntil: 0.5))
        let all = try XCTUnwrap(Self.alphas(of: whole))
        XCTAssertEqual(all[45], 255)
        XCTAssertGreaterThan(all[80], 0)
        XCTAssertLessThan(all[99], 20)
    }

    /// A view told to leave more clear than it is tall blurs nothing, and
    /// one told to leave less keeps the filter rather than the fallback.
    func testVariableBlurWithAClearBottom() {
        let view = VariableBlurView(radius: 5, fullUntil: 0.35, clearBottom: 56)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 103)
        view.layoutIfNeeded()
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(view.usesFilter, "fell back to the masked blur")
        view.set(radius: 5, fullUntil: 0.35, clearBottom: 120)
        view.layoutIfNeeded()
        XCTAssertTrue(view.isHidden, "a blur with nothing above its clear part should hide")
    }

    /// Where the status bar takes no room above the bar — a foldable's front
    /// screen (the bar and its 24-point touch strip, 68) and its inside
    /// screen held sideways (the bar alone, 44) — the blur over artwork
    /// still shows: it was hidden there until the page scrolled.
    func testBarBlurIsNeverShorterThanItsLeast() {
        let clear = { (bar: CGFloat) in bar + 12 }
        // An iPhone 17: 59 of status bar above a 44-point bar. Unchanged,
        // as is a Pro with 62.
        XCTAssertEqual(VariableBlurView.reach(height: 103, clearBottom: clear(44), least: BarBlur.least), 47)
        XCTAssertEqual(VariableBlurView.reach(height: 106, clearBottom: clear(44), least: BarBlur.least), 50)
        // A foldable's front screen: nothing above the bar and its strip.
        XCTAssertEqual(VariableBlurView.reach(height: 68, clearBottom: clear(68), least: BarBlur.least), BarBlur.least)
        // Its inside screen sideways: the whole bar, which is shorter.
        XCTAssertEqual(VariableBlurView.reach(height: 44, clearBottom: clear(44), least: BarBlur.least), 44)
        // Its inside screen upright, where the bar is the 82-point strip.
        XCTAssertEqual(VariableBlurView.reach(height: 82, clearBottom: clear(0), least: BarBlur.least), 70)
        // An iPhone SE: 20 of status bar, which left 8 points of blur.
        XCTAssertEqual(VariableBlurView.reach(height: 64, clearBottom: clear(44), least: BarBlur.least), BarBlur.least)

        let view = VariableBlurView(radius: 5, fullUntil: 0.35, clearBottom: 80, least: BarBlur.least)
        view.frame = CGRect(x: 0, y: 0, width: 466, height: 68)
        view.layoutIfNeeded()
        XCTAssertFalse(view.isHidden, "no blur on a foldable's front screen until the page scrolls")
        XCTAssertTrue(view.usesFilter, "fell back to the masked blur")
        XCTAssertEqual(view.reach, BarBlur.least)
    }

    /// The blur is the thin one only at the very top of the page: it is the
    /// whole one once the page has moved `BarScroll.distance` points, part
    /// of the way there in between, and thin again back at the top. Pulling
    /// the page down past its top leaves it thin.
    func testBlurFollowsTheFirstPointsOfScrolling() {
        XCTAssertEqual(BarScroll.progress(offset: 0), 0)
        XCTAssertEqual(BarScroll.progress(offset: -40), 0, "rubber-banding past the top moved the blur")
        XCTAssertEqual(BarScroll.progress(offset: BarScroll.distance / 2), 0.5)
        XCTAssertEqual(BarScroll.progress(offset: BarScroll.distance), 1)
        XCTAssertEqual(BarScroll.progress(offset: 900), 1)
        XCTAssertLessThanOrEqual(BarScroll.distance, Metrics.topBar,
                                 "the blur should be whole before the page has moved a bar's height")
        let scroll = BarScroll()
        XCTAssertEqual(scroll.progress, 0)
        scroll.set(offset: 500)
        XCTAssertEqual(scroll.progress, 1)
        scroll.set(offset: 0)
        XCTAssertEqual(scroll.progress, 0, "the blur did not go back at the top of the page")
    }

    /// One blur that grows, not two crossfaded: on an iPhone 17 (59 of
    /// status bar, a 44-point bar, 22 past its foot) it goes from the 47
    /// points under the clock to all 125, and its strength with it. Its
    /// view is taller than that by `BarBlur.margin`, which it fades out in.
    func testBarBlurGrowsFromTheStripToTheWholeBar() {
        let under = BarBlur.overhang + BarBlur.margin
        let rest = BlurShape(radius: 5, fullUntil: 0.35, clearBottom: 44 + 12 + under, least: BarBlur.least)
        let height: CGFloat = 59 + 44 + under
        let whole: CGFloat = 59 + 44 + BarBlur.overhang
        let top = BlurShape.blend(rest, BarBlur.scrolled, progress: 0, height: height)
        XCTAssertEqual(top, BlurShape.Drawn(radius: 5, fullUntil: 0.35, reach: 47))
        let moved = BlurShape.blend(rest, BarBlur.scrolled, progress: 1, height: height)
        XCTAssertEqual(moved, BlurShape.Drawn(radius: 18, fullUntil: 0.75, reach: whole))
        let half = BlurShape.blend(rest, BarBlur.scrolled, progress: 0.5, height: height)
        XCTAssertEqual(half.reach, 86)
        XCTAssertEqual(half.radius, 11.5)
        XCTAssertEqual(half.fullUntil, 0.55, accuracy: 0.0001)
        // Out of range is the nearer end; no second blur is no change.
        XCTAssertEqual(BlurShape.blend(rest, BarBlur.scrolled, progress: 3, height: height), moved)
        XCTAssertEqual(BlurShape.blend(rest, nil, progress: 1, height: height), top)

        // The view itself, on a foldable's front screen (68 and 22 past).
        let view = VariableBlurView(radius: 5, fullUntil: 0.35)
        view.frame = CGRect(x: 0, y: 0, width: 466, height: 68 + under)
        view.set(radius: 5, fullUntil: 0.35, clearBottom: 68 + 12 + under, least: BarBlur.least,
                 scrolled: BarBlur.scrolled, progress: 0)
        view.layoutIfNeeded()
        XCTAssertEqual(view.reach, BarBlur.least)
        view.set(radius: 5, fullUntil: 0.35, clearBottom: 68 + 12 + under, least: BarBlur.least,
                 scrolled: BarBlur.scrolled, progress: 1)
        view.layoutIfNeeded()
        XCTAssertEqual(view.reach, 90)
        XCTAssertEqual(view.drawn.radius, 18)
        // The view fades out under the blur and is gone by its own foot:
        // it ended in a line across the artwork (soft above, sharp below).
        XCTAssertNotNil(view.mask, "the blur's view has no fade at its foot")
        XCTAssertEqual(view.fadeStops.from, 90 / (68 + under), accuracy: 0.0001)
        XCTAssertEqual(view.fadeStops.to, 1, accuracy: 0.0001)
        XCTAssertEqual(BarBlur.margin, VariableBlurView.fadeLength)
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(view.usesFilter, "fell back to the masked blur while growing")
    }

    /// The frame the bar takes below the status bar, which is what a page's
    /// artwork reaches up by: the bar and the front screen's dead touch strip
    /// where there is no status strip, nothing where the bar is the strip.
    func testBarLayoutHeightFollowsTheFold() {
        let fold = FoldState.shared
        let expected = fold.statusStrip == nil ? Metrics.topBar + fold.frontTouchStrip : 0
        XCTAssertEqual(TopBarFrame.layoutHeight(), expected)
        XCTAssertEqual(PhoneHeroBar.bleed(topInset: 59), 59 + expected)
        if fold.statusStrip == nil {
            XCTAssertEqual(TopBarFrame.layoutHeight(height: 70), 70 + fold.frontTouchStrip)
        }
    }

    /// One column of alphas, top row first.
    private static func alphas(of image: CGImage) -> [UInt8]? {
        let rows = image.height
        var data = [UInt8](repeating: 0, count: rows * 4)
        guard let context = CGContext(data: &data, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: rows))
        // A bitmap context's first row in memory is its top, as the image's is.
        return (0..<rows).map { data[$0 * 4 + 3] }
    }

    /// The bar turns from white to the page's colour only once the artwork
    /// has gone from under it: Home's hero is the taller of the two. (The
    /// blur does not wait for that — `testBlurFollowsTheFirstPointsOfScrolling`.)
    func testThresholdsSitPastTheArtwork() {
        XCTAssertGreaterThan(PhoneHeroBar.threshold(home: true), PhoneHeroBar.threshold(home: false))
        XCTAssertGreaterThan(PhoneHeroBar.threshold(home: false), Metrics.topBar)
    }
}
#endif
