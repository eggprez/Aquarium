//  When an iPad title page's bar takes the title: once the page has scrolled
//  a bar's worth (80 pt) off its top (`PastHeroWatcher`). The bar never took
//  it on the iPad until 2026-11-26, because the scroll probe's preference
//  stopped arriving; PadDetailMoreTests.testTheTitleJoinsTheBarOnceTheHeaderHasScrolledAway
//  is the check on screen.

#if os(iOS)
import XCTest
@testable import Aquarium

final class PadBarTitleTests: XCTestCase {
    func testNotPastAtTheTopOrWithinABarsWorth() {
        XCTAssertFalse(PastHeroWatcher.isPast(offset: 0))
        XCTAssertFalse(PastHeroWatcher.isPast(offset: 80))
        XCTAssertFalse(PastHeroWatcher.isPast(offset: -40), "pulled down past the top")
    }

    func testPastOnceTheHeaderHasGoneABarsWorthUp() {
        XCTAssertTrue(PastHeroWatcher.isPast(offset: 81))
        XCTAssertTrue(PastHeroWatcher.isPast(offset: 600))
    }
}
#endif
