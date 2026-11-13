//  The iPad's numbers: the "Deep Water" metrics (2026-10-23, eff49a1), the
//  hero's height for a width, the Settings split, the title page's two
//  columns, and the player's non-compact chrome. Each is a branch on
//  `!Metrics.phoneLayout` that the iPhone never takes, so they are tested on
//  an iPad host only (`PadUnitTestCase` skips elsewhere).
//
//  Source for the numbers: the design record in memory `ipad-design-scheme.md`
//  ("gutter 28, shelf 32, row 16, grid 14, radius 14, sidebar 260" — the
//  sidebar later narrowed to 190–280 in 6344432) and the comments beside
//  each value in Views/Components.swift and Views/Theme.swift.

#if os(iOS)
import XCTest
import SwiftUI
@testable import Aquarium

@MainActor
final class PadMetricsTests: PadUnitTestCase {
    func testAnIPadIsNotLaidOutAsAPhone() {
        XCTAssertFalse(Metrics.phoneLayout)
        XCTAssertTrue(Metrics.wideScreen, "an iPad always has an iPad's width to spend")
    }

    func testDeepWaterSpacing() {
        XCTAssertEqual(Metrics.gutter, 28, "page margin")
        XCTAssertEqual(Metrics.shelfSpacing, 32, "between shelves")
        XCTAssertEqual(Metrics.rowSpacing, 16, "between cards on a shelf")
        XCTAssertEqual(Metrics.gridSpacing, 14, "between grid columns")
        XCTAssertEqual(Metrics.gridRowSpacing, 22)
        XCTAssertEqual(Metrics.shelfTitleSpacing, 12)
        XCTAssertEqual(Metrics.cardTextSpacing, 7)
        XCTAssertEqual(Metrics.shelfCardPadding, 0)
    }

    func testDeepWaterCardSizes() {
        // 30cbbc2: "iPad posters take the Mac's 136 pt minimum"; Deep Water
        // made the shelf poster 156 and Continue Watching's stills 300.
        XCTAssertEqual(Metrics.posterWidth, 156)
        XCTAssertEqual(Metrics.stillWidth, 156 * 1.62, accuracy: 0.001)
        XCTAssertEqual(Metrics.shelfStillWidth, 300)
    }

    func testCardRadiusIsFourteenWithNoPhoneRadius() {
        XCTAssertEqual(Theme.cornerRadius, 14)
    }

    func testTopBarKeepsNoFoldableCornerClearance() {
        XCTAssertEqual(Metrics.cornerClearance, 0)
    }

    func testGuideKeepsTheIPadDensity() {
        // "An iPad keeps the density it had": 5.5 points a minute rather
        // than the phone's half hour across the screen.
        XCTAssertEqual(Metrics.guideMinuteWidth, 5.5)
        XCTAssertEqual(Metrics.guideChannelColumnWidth, 172)
    }
}

/// `HeroHeader.height(forWidth:)`: on an iPad the hero follows the width as a
/// 2.4:1 band, between the phone's 300 and 560 (30cbbc2, "the hero follows
/// the width (2.4:1, 300-560 pt)").
@MainActor
final class PadHeroGeometryTests: PadUnitTestCase {
    func testUnmeasuredWidthIsTheFixedHeight() {
        XCTAssertEqual(HeroHeader.height(forWidth: 0), 300)
        XCTAssertEqual(HeroHeader.height, 300)
    }

    func testFollowsTheWidthAtTwoPointFourToOne() {
        XCTAssertEqual(HeroHeader.height(forWidth: 960), 400)
        XCTAssertEqual(HeroHeader.height(forWidth: 1180), (1180 / 2.4).rounded())
        // An 11-inch iPad held upright, full width.
        XCTAssertEqual(HeroHeader.height(forWidth: 820), (820 / 2.4).rounded())
    }

    func testNeverShorterThanThePhonesHero() {
        // A narrow window (a third of the screen, Stage Manager's smallest)
        // keeps 300 rather than a sliver.
        XCTAssertEqual(HeroHeader.height(forWidth: 375), 300)
        XCTAssertEqual(HeroHeader.height(forWidth: 600), 300)
    }

    func testCappedSoTheFirstShelfStaysOnScreen() {
        // A 13-inch iPad on its side, or an external display.
        XCTAssertEqual(HeroHeader.height(forWidth: 1366), 560)
        XCTAssertEqual(HeroHeader.height(forWidth: 2560), 560)
    }

    func testMonotonicAcrossEveryWindowWidth() {
        var last: CGFloat = 0
        for width in stride(from: CGFloat(320), through: 1600, by: 10) {
            let h = HeroHeader.height(forWidth: width)
            XCTAssertGreaterThanOrEqual(h, last, "height fell at width \(width)")
            XCTAssertTrue((300...560).contains(h), "height \(h) out of range at width \(width)")
            last = h
        }
    }
}

/// Settings on iPad splits into list + page only with 720 points beside the
/// sidebar (6344432: "Settings on iPad splits only with 720 pt beside the
/// sidebar (list 320, or 280 when tight); narrower it is the phone's list").
@MainActor
final class PadSettingsSplitTests: PadUnitTestCase {
    func testSplitNeedsSevenHundredTwentyPoints() {
        XCTAssertEqual(SettingsView.splitMinimumWidth, 720)
    }
}

/// The player's chrome at an iPad's size (not compact), and the room it
/// keeps for an iPad window's own buttons (a6fcf5c, QA 2026-11-11 W1).
@MainActor
final class PadPlayerMetricsTests: PadUnitTestCase {
    func testRegularChromeMetrics() {
        XCTAssertEqual(PlayerMetrics.edge(compact: false), 28)
        XCTAssertEqual(PlayerMetrics.centreGlyph(compact: false), 52)
        XCTAssertEqual(PlayerMetrics.skipGlyph(compact: false), 38)
        XCTAssertEqual(PlayerMetrics.clusterSpacing(compact: false), 76)
        XCTAssertEqual(PlayerMetrics.previewWidth(compact: false), 220)
        XCTAssertFalse(PlayerMetrics.television)
        XCTAssertFalse(PlayerMetrics.isFullScreen, "only a Mac has a full-screen window")
    }

    func testCompactChromeIsSmallerThanRegular() {
        XCTAssertLessThan(PlayerMetrics.edge(compact: true), PlayerMetrics.edge(compact: false))
        XCTAssertLessThan(PlayerMetrics.centreGlyph(compact: true), PlayerMetrics.centreGlyph(compact: false))
        XCTAssertLessThan(PlayerMetrics.previewWidth(compact: true), PlayerMetrics.previewWidth(compact: false))
    }

    /// Regression, "iPad window controls cover the player's Back" (QA
    /// 2026-11-11 W1, fixed a6fcf5c): the inset is the window's buttons'
    /// room exactly when the window is smaller than the screen. The host
    /// app's window fills the simulator's screen, so it is zero here; the
    /// windowed case is in MANUAL.md (Stage Manager can't be driven from a
    /// unit test).
    func testTitleRowInsetMatchesWhetherTheWindowHasSystemControls() {
        let windowed = PlayerMetrics.windowHasSystemControls
        XCTAssertEqual(PlayerMetrics.titleLeadingInset(fullScreen: false), windowed ? 52 : 0)
        XCTAssertEqual(PlayerMetrics.titleLeadingInset(fullScreen: true), windowed ? 52 : 0,
                       "off a Mac the full-screen flag changes nothing")
    }

    func testAFullScreenHostWindowHasNoSystemControls() throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first, let window = scene.keyWindow ?? scene.windows.first else {
            throw XCTSkip("the host app has no window")
        }
        let full = window.bounds.size == scene.screen.bounds.size
        try XCTSkipUnless(full, "the host window is not full screen (Stage Manager is on in this simulator)")
        XCTAssertFalse(PlayerMetrics.windowHasSystemControls)
    }
}
#endif
