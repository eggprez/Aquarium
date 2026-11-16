//  The "Deep Water" design as ported to the Mac (2026-10-23): the tokens it
//  set. Source: memory note ipad-design-scheme.md ("Ported to the Mac").
//  What the design looks like is checked by screenshots in the UI suite and
//  by eye (MANUAL.md); these pin the numbers a regression would change.

#if os(macOS)
import SwiftUI
import XCTest
@testable import Aquarium

@MainActor
final class MacDeepWaterTests: MacUnitTestCase {
    func testCardRadiusIsFourteen() {
        XCTAssertEqual(Theme.cornerRadius, 14)
    }

    func testMacMetrics() {
        XCTAssertEqual(Metrics.posterWidth, 168)
        XCTAssertEqual(Metrics.stillWidth, 168 * 1.62, accuracy: 0.001)
        XCTAssertEqual(Metrics.rowSpacing, 16)
        XCTAssertEqual(Metrics.gridSpacing, 16)
        XCTAssertEqual(Metrics.gridRowSpacing, 26)
        XCTAssertEqual(Metrics.shelfSpacing, 30)
        XCTAssertEqual(Metrics.shelfTitleSpacing, 10)
    }

    func testMacUsesTheSystemAccentAndLinkColour() {
        XCTAssertEqual(Theme.accent, Color.accentColor)
        XCTAssertEqual(Theme.link, Color.accentColor, "a link on a Mac is the accent colour")
    }

    func testSidebarGroupHeadingsAreDeepWaters() {
        let groups = MacSidebarGroup.grouped([.home, .library(id: "a", name: "A", collectionType: "movies"),
                                              .liveTV, .favorites])
        XCTAssertEqual(groups.compactMap(\.title), ["Libraries", "Live", "You"],
                       "Browse is the untitled top group on the Mac; the account stays the footer menu")
    }

    func testHeroUsesThumbnailsOnAWideWindow() {
        // `HeroCarousel` shows thumbnails at 900 pt and wider, dots below.
        XCTAssertEqual(HeroCarousel.height(forWidth: 900), 375)
        XCTAssertEqual(HeroCarousel.height(forWidth: 899), 375, "rounded: the band is continuous across the switch")
    }
}
#endif
