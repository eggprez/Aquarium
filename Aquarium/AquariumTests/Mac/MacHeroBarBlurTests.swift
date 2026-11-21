//  The blur under the Mac's window toolbar on Home and a title page
//  (`HeroBarBlur`, 2026-11-20): its untinted variable blur leans on a filter
//  AppKit does not publish, and AppKit builds the layers it goes on only
//  after the first layout.

#if os(macOS)
import AppKit
import XCTest
@testable import Aquarium

@MainActor
final class MacHeroBarBlurTests: MacUnitTestCase {
    /// Fails first if a new macOS stops answering to the filter's name, or
    /// moves the backdrop layer, which would leave the toolbar on the paler
    /// masked fallback.
    func testVariableBlurFindsTheBackdropOnceAppKitHasBuiltIt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let blur = VariableBlurView(radius: 6, fullUntil: 0.4)
        blur.frame = NSRect(x: 0, y: 0, width: 600, height: 52)
        window.contentView?.addSubview(blur)
        window.orderBack(nil)
        defer { window.close() }
        let applied = expectation(description: "filter applied")
        func check(_ tries: Int) {
            blur.layoutSubtreeIfNeeded()
            if blur.usesFilter { applied.fulfill() }
            else if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check(tries - 1) } }
        }
        check(20)
        wait(for: [applied], timeout: 5)
        XCTAssertNil(blur.layer?.mask, "fell back to the masked blur")
    }

    /// The mask is a column one pixel wide, opaque at the top.
    func testMaskIsOpaqueAtTheTopAndClearAtTheBottom() throws {
        let mask = try XCTUnwrap(VariableBlurFilter.mask(height: 50, fullUntil: 0.4))
        XCTAssertEqual(mask.width, 1)
        XCTAssertEqual(mask.height, 50)
        let data = try XCTUnwrap(mask.dataProvider?.data as Data?)
        let row = mask.bytesPerRow
        XCTAssertGreaterThan(data[3], 250, "the top row is not opaque")
        XCTAssertLessThan(data[row * 49 + 3], 10, "the bottom row is not clear")
    }
}
#endif
