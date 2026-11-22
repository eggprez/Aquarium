//  The tab strip and the focus engine across the app: every tab is reachable,
//  every page can be entered from the strip and left back to it, and focus
//  is never lost (nothing focused) or trapped (no way back up).

#if os(tvOS)
import XCTest

final class TVShellFocusTests: TVTestCase {
    private let tabs: [(id: String, title: String, anchor: String)] = [
        ("home", "Home", TestID.Home.root),
        ("libraries", "Library", TestID.Library.listRoot),
        ("search", "Search", TestID.Search.root),
        ("livetv", "Live TV", TestID.LiveTV.root),
        ("settings", "Settings", TestID.Settings.root),
    ]

    func testTheStripHasFiveTabsInOrder() {
        launchHome()
        let items = tabs.map { tab($0.id, title: $0.title) }
        for (item, t) in zip(items, tabs) {
            XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(t.title) tab")
        }
        let xs = items.map(\.frame.midX)
        XCTAssertEqual(xs, xs.sorted(), "tabs out of order: \(zip(tabs.map(\.title), xs).map { "\($0) \($1)" })")
        for missing in ["music", "books", "downloads", "favorites", "more"] {
            XCTAssertFalse(app.element(TestID.Tab.item(missing)).exists, "a \(missing) tab on the TV")
        }
    }

    func testEveryTabCanBeEnteredAndLeft() {
        launchHome()
        for t in tabs {
            openTab(t.id, title: t.title, anchor: t.anchor)
            assertPageEnterableAndLeavable(t.title)
            attachScreenshot(t.title)
        }
    }

    func testDownFromTheStripOnHomeReachesThePlayButton() {
        // Regression (f3ea7ed "tvOS Home: … reach it from above"; master-fix-list
        // "[TV] Home: Down from the tabs lands on Refresh; Play takes Down,
        // Down, Left" — Refresh first is kept as design, fix-status.md).
        launchHome()
        XCTAssertTrue(focusTabStrip())
        var reached = false
        for _ in 0..<4 {
            Remote.press(.down)
            if focusedID.hasPrefix("home.hero.play.") { reached = true; break }
            if focusedID.hasPrefix("home.hero.details.") { Remote.press(.left) }
            if focusedID.hasPrefix("home.hero.play.") { reached = true; break }
        }
        XCTAssertTrue(reached, "Play on the media bar not reached from the strip (ended on \(focused?.summary ?? "nothing"))")
    }

    func testOpeningALibraryKeepsFocusAndMenuGoesBackNotOut() throws {
        // Regression (AppModel.push comment): a library pushed under the strip
        // let focus walk onto the strip and Menu quit Aquarium. Also seen in
        // this suite's first run: focus read as "none" right after the open.
        let filmsId = try Fixtures.require().libraryId("Fixture Films")
        launchHome()
        openTab("libraries", title: "Library", anchor: TestID.Library.listRoot)
        Remote.press(.down)
        let films = app.element(TestID.Library.tile(filmsId))
        XCTAssertTrue(Remote.focus(on: films, in: app), "couldn't reach the Fixture Films tile")
        Remote.select()
        app.element(TestID.Library.root).waitToExist(20)
        // Focus on arrival is its own test (TVBrowseTests.testALibraryScreenOpensWithFocus,
        // a known bug); a press brings it back, and the rest is checked from there.
        XCTAssertTrue(recoverFocus(), "no focus on the library grid even after a press")
        XCTAssertFalse(app.element(TestID.Shell.root).isHittable && isTabFocused, "the strip has focus over a library")
        // Up from the grid's first row never reaches the strip: it's not there.
        press(.up, until: { false }, max: 6)
        XCTAssertFalse(isTabFocused)
        assertFocusPresent("the library grid after Up")
        Remote.menu()
        app.element(TestID.Library.listRoot).waitToExist(10)
        XCTAssertEqual(app.state, .runningForeground, "Menu left the app")
        assertFocusPresent("the library list after Menu")
    }

    func testMenuFromATitlePageReturnsToWhereItCameFrom() throws {
        let filmId = try Fixtures.require().item("film.long_direct").id
        launchHome()
        // The first Continue Watching card.
        let shelf = app.element(TestID.Home.shelf(TestID.Home.rowResume))
        shelf.waitToExist(20)
        let target = app.element(TestID.Item.card(filmId))
        XCTAssertTrue(Remote.focus(on: target, in: app), "couldn't reach a Continue Watching card")
        let before = focusedID
        Remote.select()
        app.element(TestID.Detail.root).waitToExist(20)
        assertFocusPresent("the title page")
        XCTAssertTrue(focusedID == TestID.Detail.play || focusedID.hasPrefix("detail."), "title page opened with focus on \(focused?.summary ?? "nothing")")
        Remote.menu()
        app.element(TestID.Home.root).waitToExist(10)
        XCTAssertTrue(app.element(TestID.Detail.root).waitToVanish(10))
        assertFocusPresent("Home after the title page")
        XCTAssertEqual(focusedID, before, "focus didn't come back to the card that opened the page")
    }
}
#endif
