//  "Deep Water" on the Mac (memory note ipad-design-scheme.md, ported
//  2026-10-23): the layout facts a screenshot reviewer would check first,
//  asserted, and a screenshot of each screen in light and dark kept with the
//  result for the eye (MANUAL.md says what to look for).

#if os(macOS)
import XCTest

final class MacDeepWaterUITests: MacUITestCase {
    private func fixtures() throws -> Fixtures { try Fixtures.require() }

    /// Settings ▸ General ▸ Theme.
    private func setTheme(_ raw: String) {
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["General"].tapWhenReady()
        app.element(TestID.Settings.theme).tapWhenReady()
        app.element(TestID.Settings.option(TestID.Settings.theme, raw)).tapWhenReady()
        app.typeKey("w", modifierFlags: .command)
    }

    func testHomeHeroBleedsAndCarriesAWhitePlay() {
        launchToHome()
        let hero = app.element(TestID.Home.hero)
        hero.waitToExist(30)
        XCTAssertEqual(hero.frame.maxX, mainWindow.frame.maxX, accuracy: 2, "the hero runs to the window's edge")
        XCTAssertGreaterThanOrEqual(hero.frame.height, 280)
        XCTAssertLessThanOrEqual(hero.frame.height, 520)
        XCTAssertTrue(app.elements(prefix: "home.hero.play.").firstMatch.waitForExistence(timeout: 10))
        attachScreenshot("home hero")
    }

    /// Regression: HeroPlayVanishesWhenWindowNotKey — `.borderedProminent`
    /// lost its fill in a window that isn't key, so the hero had no Play.
    /// The Play button is still there and hittable with Settings in front.
    /// Source: commit b723cea; Views/HomeView+Mac.swift:210-224.
    func testBugHeroPlayVanishesWhenWindowNotKey() {
        launchToHome()
        let play = app.elements(prefix: "home.hero.play.").firstMatch
        play.waitToExist(30)
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        XCTAssertTrue(play.exists)
        attachScreenshot("hero Play with the main window not key")
    }

    func testTitlePagePosterBesideTheFacts() throws {
        let film = try fixtures().item("film.long_direct")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        let art = app.element(TestID.Detail.artwork)
        let title = app.element(TestID.Detail.title)
        art.waitToExist(20)
        title.waitToExist(20)
        XCTAssertLessThan(art.frame.maxX, title.frame.minX + 1, "two columns: the poster, then the facts")
        attachScreenshot("title page")
    }

    func testLibraryHasAPinnedFilterHeaderWithACount() throws {
        let lib = try fixtures().libraryId("Fixture Films")
        launchToHome()
        openSection("lib-\(lib)")
        app.element(TestID.Library.filters).waitToExist(20)
        XCTAssertTrue(app.element(TestID.Library.count).waitForExistence(timeout: 20))
        let header = app.element(TestID.Library.filters).frame
        mainWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -800)
        XCTAssertEqual(app.element(TestID.Library.filters).frame.minY, header.minY, accuracy: 2, "pinned while the grid scrolls")
        attachScreenshot("library")
    }

    func testLibraryChipsOnHome() {
        launchToHome()
        if app.element(TestID.Library.chips).waitForExistence(timeout: 20) {
            XCTAssertGreaterThan(app.elements(prefix: "library.chip.").count, 0)
        }
    }

    func testScreensInLightAndDark() throws {
        let film = try fixtures().item("film.long_direct")
        launchToHome()
        for theme in ["light", "dark"] {
            setTheme(theme)
            mainWindow.click()
            openSection("home")
            attachScreenshot("home \(theme)")
            openTitle(named: film.name, id: film.id)
            attachScreenshot("title \(theme)")
            openSection("livetv")
            attachScreenshot("guide \(theme)")
        }
        setTheme("auto")
    }
}
#endif
