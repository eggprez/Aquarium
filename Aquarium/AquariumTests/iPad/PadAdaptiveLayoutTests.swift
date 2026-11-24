//  What an iPad decides for itself about the window it is in: it turns
//  every way (a phone is portrait unless a screen asks), its grids are a
//  range of column widths that the sidebar and a turn add a column to or
//  take one from, a window narrowed to compact width gets the phone's
//  fixed three across, and it never floats the phone's bar.
//
//  Sources: Core/Orientation.swift (`OrientationLock.mask`),
//  Views/Components.swift (`PosterGrid`), Views/PhoneHeroBar.swift
//  (`PhoneHeroBar.applies`).

#if os(iOS)
import XCTest
import SwiftUI
@testable import Aquarium

@MainActor
final class PadOrientationTests: PadUnitTestCase {
    /// "Anything larger [than a phone] was never locked": every orientation,
    /// upside down included.
    func testAnIPadTurnsEveryWay() {
        XCTAssertEqual(OrientationLock.shared.mask, .all)
    }

    /// The player and the guide ask for the turn and give it back; on an
    /// iPad neither changes the answer.
    func testAScreenAskingForLandscapeChangesNothingOnAnIPad() {
        let lock = OrientationLock.shared
        lock.allowLandscape()
        XCTAssertEqual(lock.mask, .all, "asked for")
        lock.releaseLandscape()
        XCTAssertEqual(lock.mask, .all, "given back")
    }
}

@MainActor
final class PadGridTests: PadUnitTestCase {
    private func adaptive(_ items: [GridItem], file: StaticString = #filePath, line: UInt = #line) -> (min: CGFloat, max: CGFloat)? {
        XCTAssertEqual(items.count, 1, "one adaptive column description", file: file, line: line)
        guard let item = items.first, case let .adaptive(minimum, maximum) = item.size else {
            XCTFail("not an adaptive column: \(items)", file: file, line: line)
            return nil
        }
        return (minimum, maximum)
    }

    /// At regular width the column runs from the card's own width to half as
    /// wide again (the Mac's proportion), posters and stills alike.
    func testRegularWidthColumnsAreARange() throws {
        let posters = try XCTUnwrap(adaptive(PosterGrid.columns(wide: false, compact: false)))
        XCTAssertEqual(posters.min, Metrics.posterWidth)
        XCTAssertEqual(posters.max, Metrics.posterWidth * 1.5, accuracy: 0.001)
        let stills = try XCTUnwrap(adaptive(PosterGrid.columns(wide: true, compact: false)))
        XCTAssertEqual(stills.min, Metrics.stillWidth, accuracy: 0.001)
        XCTAssertEqual(stills.max, Metrics.stillWidth * 1.5, accuracy: 0.001)
        XCTAssertEqual(PosterGrid.columnMinimum(wide: false), 156)
        XCTAssertEqual(PosterGrid.columnMaximum(wide: false), 234, accuracy: 0.001)
    }

    /// The card fills whatever its column came to, so it has no width of
    /// its own at regular width.
    func testARegularWidthCardTakesTheColumnsWidth() {
        XCTAssertNil(PosterGrid.cardWidth(wide: false, compact: false))
        XCTAssertNil(PosterGrid.cardWidth(wide: true, compact: false))
        XCTAssertNil(PosterGrid.phoneColumns(wide: false, compact: false), "no fixed count at regular width")
    }

    /// An iPad window narrowed to compact width (Split View's third, Slide
    /// Over, a small Stage Manager window) gets the phone's grid: three
    /// posters or two stills across, flexible.
    func testACompactWindowGetsThePhonesFixedColumns() {
        XCTAssertEqual(PosterGrid.phoneColumns(wide: false, compact: true), 3)
        XCTAssertEqual(PosterGrid.phoneColumns(wide: true, compact: true), 2)
        let posters = PosterGrid.columns(wide: false, compact: true)
        XCTAssertEqual(posters.count, 3)
        for item in posters {
            guard case .flexible = item.size else { return XCTFail("a compact column is flexible: \(item.size)") }
        }
        XCTAssertEqual(PosterGrid.columns(wide: true, compact: true).count, 2)
        XCTAssertNil(PosterGrid.cardWidth(wide: false, compact: true), "sized by the fixed column")
    }
}

@MainActor
final class PadBarTests: PadUnitTestCase {
    /// An iPad floats its own bar (`padBarSurface`), never the phone's.
    func testThePhonesFloatingBarIsNotAnIPads() {
        XCTAssertFalse(PhoneHeroBar.applies)
    }
}
#endif
