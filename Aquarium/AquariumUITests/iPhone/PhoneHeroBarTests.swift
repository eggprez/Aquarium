//  The phone's floating bar on Home and on a title page (`PhoneHeroBar`):
//  the artwork runs up to the top of the screen under it, its buttons stay
//  clear of the clock and of the hero's own buttons, it stays put while the
//  page scrolls, and a title page's name turns up in it once the artwork has
//  gone. The foldable floats it too, clear of its front screen's dead touch
//  strip (DuoPoseTests checks the strip itself).

#if os(iOS)
import XCTest

final class PhoneHeroBarTests: PhoneUITestCase {
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// Where the status bar ends: 20 points on the home-button SE, 44 or
    /// more on everything with a notch or an island. The Duo's front screen
    /// keeps its clock in a column down the side; the top 24 points are the
    /// dead touch strip the bar stays below.
    private var statusBarBottom: CGFloat {
        switch device {
        case .small: 20
        case .duo: 24
        default: 44
        }
    }

    func testHomeHeroRunsUpUnderTheBar() throws {
        launchHome()
        let window = app.windows.firstMatch.frame
        let hero = any(TestID.Home.hero)
        hero.waitToExist(30)
        XCTAssertLessThanOrEqual(hero.frame.minY, window.minY + 1, "the hero starts below the top: \(hero.frame)")
        let brand = any(TestID.Common.brand)
        let search = app.button(TestID.Home.search)
        let refresh = app.button(TestID.Home.refresh)
        for (element, what) in [(brand, "wordmark"), (search, "Search"), (refresh, "Refresh")] {
            assertOnScreen(element, what)
            // Below the clock, and inside the artwork rather than above it.
            XCTAssertGreaterThanOrEqual(element.frame.minY, statusBarBottom, "\(what) sits in the status bar: \(element.frame)")
            XCTAssertLessThan(element.frame.maxY, hero.frame.maxY, "\(what) is not over the hero")
        }
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.play.")).firstMatch
        play.waitToExist(20)
        XCTAssertGreaterThan(play.frame.minY, search.frame.maxY, "the hero's Play sits under the bar")
        attachScreenshot("home bar over the hero (\(device.rawValue))")
    }

    func testHomeBarStaysWhileThePageScrolls() throws {
        try standardOnly()
        launchHome()
        let search = app.button(TestID.Home.search)
        search.waitToExist(30)
        let top = search.frame.minY
        app.swipeUp()
        app.swipeUp()
        XCTAssertEqual(search.frame.minY, top, accuracy: 1, "Search moved with the page")
        attachScreenshot("home bar scrolled (\(device.rawValue))")
        // The tap is the check that nothing scrolled over it: `isHittable`
        // says no for a bar floating over a scroll view even when it is not.
        search.tap()
        app.element(TestID.Search.root).waitToExist(20)
    }

    func testTitleArtworkRunsUpUnderTheBarAndBackStaysOnScroll() throws {
        launchHome()
        _ = try openFixture("show.long")
        let window = app.windows.firstMatch.frame
        let hero = any(TestID.Detail.hero)
        hero.waitToExist(30)
        XCTAssertLessThanOrEqual(hero.frame.minY, window.minY + 1, "the artwork starts below the top: \(hero.frame)")
        let back = app.button(TestID.Detail.back)
        assertOnScreen(back, "Back")
        XCTAssertGreaterThanOrEqual(back.frame.minY, statusBarBottom, "Back sits in the status bar: \(back.frame)")
        // Over the artwork the bar carries only the way back.
        XCTAssertFalse(any(TestID.Detail.barTitle).exists, "the title is in the bar over the artwork")
        let top = back.frame.minY
        for _ in 0..<3 { app.swipeUp() }
        // Scrolled, Back is on a glass disc and the bar still has no title:
        // nothing bare stands over the page (2026-11-22).
        XCTAssertFalse(any(TestID.Detail.barTitle).exists, "the title came into the bar on scroll")
        XCTAssertEqual(back.frame.minY, top, accuracy: 1, "Back moved with the page")
        assertOnScreen(back, "Back after scrolling")
        attachScreenshot("title bar scrolled (\(device.rawValue))")
        back.tap()
        XCTAssertTrue(app.element(TestID.Detail.root).waitToVanish(10) || app.element(TestID.Search.root).exists,
                      "Back did not leave the title")
    }
}
#endif
