//  The press-and-hold menu on a Home card (Views/ItemContextMenu.swift), the
//  entries `TVHomeTests` doesn't press: Add to Favorites, Play from
//  Beginning, Go to Show, Go to Season, Episode Details on a Next Up card,
//  and Add Show to Next Up, which asks first (its dialog is
//  `NextUpChoiceDialog`; only its Cancel is pressed here, since both other
//  answers change the suite's baseline on the server).
//
//  Baseline (FIXTURES.md): FX Long Direct Play at 5:00 on Continue Watching;
//  Long Show S01E02 on Continue Watching and Next Up; Short Show S01E03 on
//  Next Up.

#if os(tvOS)
import XCTest

final class TVCardMenuTests: TVPlayerTestCase {
    func testAddToFavoritesFromTheCardMenuReachesTheServer() throws {
        let film = try Fixtures.require().item("film.long_direct").id
        let api = try self.api()
        try api.setFavorite(film, false)
        defer { try? api.setFavorite(film, false) }
        launchHome()
        let card = try XCTUnwrap(homeCard(film, onRow: TestID.Home.rowResume), "FX Long Direct Play not on Continue Watching")
        guard openCardMenu(card, showing: TestID.Item.menuFavorite) else { return }
        XCTAssertTrue(app.element(TestID.Item.menuFavorite).label.contains("Add to Favorites"),
                      app.element(TestID.Item.menuFavorite).label)
        chooseMenuEntry(TestID.Item.menuFavorite)
        waitUntil("the server to hold it as a favourite", timeout: 15) { (try? api.userData(film).favorite) == true }
        assertFocusPresent("Home after the card menu")
    }

    func testPlayFromBeginningIgnoresTheResumePoint() throws {
        // Only offered where there is something to go back past (the film is
        // at 5:00); `StreamOptions(resume: false)`.
        let film = try Fixtures.require().item("film.long_direct").id
        let api = try self.api()
        try api.setResume(film, seconds: 300)
        defer {
            closePlayer()
            waitUntil("the stop to be recorded", timeout: 20, fail: false) { [weak self] in self?.session(film) == nil }
            try? api.setResume(film, seconds: 300)
        }
        launchHome()
        let card = try XCTUnwrap(homeCard(film, onRow: TestID.Home.rowResume), "FX Long Direct Play not on Continue Watching")
        guard openCardMenu(card, showing: TestID.Item.menuPlayFromBeginning) else { return }
        XCTAssertTrue(app.element(TestID.Item.menuPlay).label.localizedCaseInsensitiveContains("resume"),
                      "the first entry resumes: \(app.element(TestID.Item.menuPlay).label)")
        chooseMenuEntry(TestID.Item.menuPlayFromBeginning)
        app.element(TestID.Player.root).waitToExist(30)
        waitForServerPlayback(of: film, pastSeconds: 1, timeout: 60)
        let position = reportedPosition(film) ?? .infinity
        XCTAssertLessThan(position, 120, "Play from Beginning opened at \(Int(position)) s, the resume point is 300")
    }

    func testGoToShowFromAnEpisodeCardOpensTheShow() throws {
        let fx = try Fixtures.require()
        let shortE3 = try fx.episode("show.short", season: 1, episode: 3)
        let show = try fx.item("show.short").id
        launchHome()
        let card = try XCTUnwrap(homeCard(shortE3, onRow: TestID.Home.rowNextUp), "Short Show S01E03 not on Next Up")
        guard openCardMenu(card, showing: TestID.Item.menuGoToShow) else { return }
        chooseMenuEntry(TestID.Item.menuGoToShow)
        app.element(TestID.Detail.page(show)).waitToExist(20)
        assertFocusPresent("the show's page from the card menu")
        Remote.menu()
        app.element(TestID.Home.root).waitToExist(15)
        assertFocusPresent("Home after leaving the show")
    }

    func testGoToSeasonFromAnEpisodeCardOpensTheSeason() throws {
        let fx = try Fixtures.require()
        let shortE3 = try fx.episode("show.short", season: 1, episode: 3)
        let season = try fx.season("show.short", 1)
        launchHome()
        let card = try XCTUnwrap(homeCard(shortE3, onRow: TestID.Home.rowNextUp), "Short Show S01E03 not on Next Up")
        guard openCardMenu(card, showing: TestID.Item.menuGoToSeason) else { return }
        XCTAssertTrue(app.element(TestID.Item.menuGoToSeason).label.contains("Season 1"),
                      app.element(TestID.Item.menuGoToSeason).label)
        chooseMenuEntry(TestID.Item.menuGoToSeason)
        app.element(TestID.Detail.page(season)).waitToExist(20)
        app.element(TestID.Detail.episode(shortE3)).waitToExist(20)
        assertFocusPresent("the season's page from the card menu")
    }

    func testANextUpCardOffersTheEpisodesOwnPage() throws {
        // A Next Up card opens the season (`AppModel.openNextUp`), so its menu
        // has "Episode Details" for the episode itself (`menuOpensDetails`).
        let fx = try Fixtures.require()
        let shortE3 = try fx.episode("show.short", season: 1, episode: 3)
        launchHome()
        let card = try XCTUnwrap(homeCard(shortE3, onRow: TestID.Home.rowNextUp), "Short Show S01E03 not on Next Up")
        guard openCardMenu(card, showing: TestID.Item.menuDetails) else { return }
        XCTAssertTrue(app.element(TestID.Item.menuDetails).label.contains("Episode Details"),
                      app.element(TestID.Item.menuDetails).label)
        chooseMenuEntry(TestID.Item.menuDetails)
        app.element(TestID.Detail.page(shortE3)).waitToExist(20)
        assertFocusPresent("the episode's page")
    }

    func testAddShowToNextUpAsksAndMenuLeavesItAlone() throws {
        // On Continue Watching (not the Next Up row) an episode offers its
        // show for Next Up, and asks which way before touching the server.
        let fx = try Fixtures.require()
        let longE2 = try fx.episode("show.long", season: 1, episode: 2)
        let api = try self.api()
        let before = try api.userData(longE2)
        launchHome()
        let card = try XCTUnwrap(homeCard(longE2, onRow: TestID.Home.rowResume), "Long Show S01E02 not on Continue Watching")
        guard openCardMenu(card, showing: TestID.Item.menuAddToNextUp) else { return }
        XCTAssertFalse(app.element(TestID.Item.menuRemoveFromNextUp).exists, "Remove from Next Up offered off the Next Up row")
        chooseMenuEntry(TestID.Item.menuAddToNextUp)
        let cancel = app.element(TestID.Shell.nextUpCancel)
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Add to Next Up didn't ask how")
        XCTAssertTrue(app.element(TestID.Shell.nextUpFromLastWatched).exists)
        XCTAssertTrue(app.element(TestID.Shell.nextUpFromFirstEpisode).exists)
        attachScreenshot("add to next up question")
        Remote.menu()
        XCTAssertTrue(cancel.waitToVanish(10), "Menu left the question up")
        assertFocusPresent("Home after the Next Up question")
        let after = try api.userData(longE2)
        XCTAssertEqual(after.played, before.played, "the episode's watched state changed")
        XCTAssertEqual(after.positionSeconds, before.positionSeconds, accuracy: 1, "the episode's position changed")
    }

    func testTheNextUpRowsMenuOffersRemovalAndNotAdding() throws {
        // `menuRemovesFromNextUp`: on Next Up itself the show is already
        // there. Only looked at; removing it would change the baseline.
        let shortE3 = try Fixtures.require().episode("show.short", season: 1, episode: 3)
        launchHome()
        let card = try XCTUnwrap(homeCard(shortE3, onRow: TestID.Home.rowNextUp), "Short Show S01E03 not on Next Up")
        guard openCardMenu(card, showing: TestID.Item.menuRemoveFromNextUp) else { return }
        XCTAssertFalse(app.element(TestID.Item.menuAddToNextUp).exists, "Add to Next Up offered on the Next Up row")
        Remote.menu()
        XCTAssertTrue(app.element(TestID.Item.menuRemoveFromNextUp).waitToVanish(10))
    }
}
#endif
