//  Title pages on the phone (films, shows, seasons, episodes, specials,
//  versions, extras, cast, More Like This), favourite and watched as the
//  server sees them, the press-and-hold menus on cards, and the Next Up
//  rules (Add to / Remove from Next Up).

#if os(iOS)
import XCTest

final class PhoneDetailTests: PhoneUITestCase {
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    func testFilmPageShowsItsFacts() throws {
        launchHome()
        _ = try openFixture("film.long_direct")
        for id in [TestID.Detail.hero, TestID.Detail.tagline, TestID.Detail.facts, TestID.Detail.actions] { XCTAssertTrue(any(id).exists, id) }
        for id in [TestID.Detail.play, TestID.Detail.favorite, TestID.Detail.download, TestID.Detail.more] { assertOnScreen(app.button(id), id) }
        app.reveal(any(TestID.Detail.overview))
        XCTAssertTrue(any(TestID.Detail.sourceInfo).exists || any(TestID.Detail.overview).exists)
        attachScreenshot("film page (\(device.rawValue))")
    }

    /// Regression R-2c20fe6-row: every action in the compact row is one line.
    func testActionRowIsOneLine() throws {
        launchHome()
        _ = try openFixture("film.long_direct")
        let row = any(TestID.Detail.actions)
        for id in [TestID.Detail.play, TestID.Detail.favorite, TestID.Detail.download, TestID.Detail.more] {
            let b = app.button(id)
            XCTAssertLessThanOrEqual(b.frame.height, row.frame.height + 1, "\(id) wraps")
            XCTAssertGreaterThanOrEqual(b.frame.minX, row.frame.minX - 1)
            XCTAssertLessThanOrEqual(b.frame.maxX, row.frame.maxX + 1, "\(id) runs off the row")
        }
    }

    func testFavouriteButtonReachesTheServer() throws {
        try standardOnly()
        let api = try self.api
        let film = try Fixtures.require().item("film.pcm_mov")
        try api.setFavorite(film.id, false)
        addTeardownBlock { try? api.setFavorite(film.id, false) }
        launchHome()
        openTitle(film.id, searching: film.name)
        app.button(TestID.Detail.favorite).tapNow()
        XCTAssertTrue(eventually { (try? api.userData(film.id).favorite) == true })
        app.button(TestID.Detail.favorite).tapNow()
        XCTAssertTrue(eventually { (try? api.userData(film.id).favorite) == false })
    }

    func testMarkWatchedFromTheMoreMenu() throws {
        try standardOnly()
        let api = try self.api
        let film = try Fixtures.require().item("film.pcm_mov")
        try api.markUnplayed(film.id)
        addTeardownBlock { try? api.markUnplayed(film.id) }
        launchHome()
        openTitle(film.id, searching: film.name)
        app.button(TestID.Detail.more).tapNow()
        any(TestID.Detail.watched).tapNow(10)
        XCTAssertTrue(eventually { (try? api.userData(film.id).played) == true })
    }

    /// Regression R-5c15003: the More menu opened at the first button.
    func testMoreMenuOpensBesideItsButton() throws {
        launchHome()
        _ = try openFixture("film.long_direct")
        app.button(TestID.Detail.more).tapNow()
        let watched = any(TestID.Detail.watched)
        watched.waitToExist(10)
        XCTAssertGreaterThan(watched.frame.maxX, app.button(TestID.Detail.play).frame.maxX, "menu anchored to the Play button")
        assertOnScreen(watched, "Mark watched")
    }

    func testPlayAtASetQualityMenu() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("film.long_direct")
        app.button(TestID.Detail.more).tapNow()
        any(TestID.Detail.quality).tapNow(10)
        let rung = menuItem(TestID.Detail.qualityOption(5_000_000), label: "5 Mbps · 720p")
        XCTAssertTrue(rung.exists)
        rung.tapNow(5)
        app.element(TestID.Player.root).waitToExist(40)
    }

    /// FX Extras: two local trailers and a behind-the-scenes feature.
    func testTrailerPlays() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("film.extras")
        app.button(TestID.Detail.more).tapNow()
        any(TestID.Detail.trailer).tapNow(10)
        app.element(TestID.Player.root).waitToExist(40)
    }

    /// Regression R-PM6 (open on main): a title with several versions had
    /// no way to pick one.
    func testVersionsCanBeChosen() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("film.versions")
        app.button(TestID.Detail.more).tapNow()
        let versionChoice = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'version' OR label CONTAINS '2160p' OR label CONTAINS '480p'")).firstMatch
        let offered = versionChoice.waitForExistence(timeout: 5)
        XCTExpectFailure("bug R-PM6: a film with three versions offers no choice of version")
        XCTAssertTrue(offered)
    }

    func testCastOpensThePersonPage() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("film.long_direct")
        let ada = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH 'Ada Fixture'", "detail.cast.person.")).firstMatch
        app.reveal(ada)
        ada.tapNow(10)
        app.element(TestID.Person.root).waitToExist(20)
        any(TestID.Person.films).waitToExist(20)
    }

    func testMoreLikeThisShelf() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("film.long_direct")
        let shelf = any(TestID.Detail.moreLikeThis)
        app.reveal(shelf)
        XCTAssertTrue(shelf.exists)
    }

    /// Long Show: Specials, Season 1 (4), Season 2 (3). The page names the
    /// episode Play starts (S01E02, in progress at the baseline).
    func testShowPageListsSeasonsAndEpisodes() throws {
        let api = try self.api
        let e2 = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 2))
        try api.setResume(e2, seconds: 200)
        launchHome()
        _ = try openFixture("show.long")
        any(TestID.Detail.upNext).waitToExist(20)
        let seasons = any(TestID.Detail.seasons)
        app.reveal(seasons)
        for index in [0, 1, 2] {
            let id = try XCTUnwrap(PhoneFixtures.season("show.long", index))
            XCTAssertTrue(any(TestID.Detail.season(id)).exists, "season \(index)")
        }
        attachScreenshot("show page (\(device.rawValue))")
    }

    /// Regression R-1ccddf1: a show's Play started S1E1 while an episode
    /// was in progress.
    func testShowPlayResumesTheInProgressEpisode() throws {
        try standardOnly()
        let api = try self.api
        let e2 = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 2))
        try api.setResume(e2, seconds: 200)
        launchHome()
        _ = try openFixture("show.long")
        XCTAssertEqual(app.button(TestID.Detail.play).label, "Resume")
        app.button(TestID.Detail.play).tapNow()
        XCTAssertNotNil(try api.waitForPlayback(of: e2, timeout: 60), "Play started another episode")
    }

    func testSeasonPageListsItsEpisodes() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("show.long")
        let season2 = try XCTUnwrap(PhoneFixtures.season("show.long", 2))
        let s = any(TestID.Detail.season(season2))
        app.reveal(s)
        s.tapNow(10)
        for n in 1...3 {
            let ep = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 2, number: n))
            let row = any(TestID.Detail.episode(ep))
            app.reveal(row)
            XCTAssertTrue(row.exists, "S02E0\(n)")
        }
    }

    func testSpecialsSeasonOpens() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("show.long")
        let specials = try XCTUnwrap(PhoneFixtures.season("show.long", 0))
        let s = any(TestID.Detail.season(specials))
        app.reveal(s)
        s.tapNow(10)
        let special = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 0, number: 1))
        let row = any(TestID.Detail.episode(special))
        app.reveal(row)
        XCTAssertTrue(row.exists)
    }

    /// Short Show: E05-E06 is one double-episode file, E07 is absent.
    func testShortShowListsTheDoubleEpisodeOnce() throws {
        try standardOnly()
        launchHome()
        _ = try openFixture("show.short")
        any(TestID.Detail.season(try XCTUnwrap(PhoneFixtures.season("show.short", 1)))).tapNow(20)
        let double = try XCTUnwrap(PhoneFixtures.episode("show.short", season: 1, number: 5))
        let row = any(TestID.Detail.episode(double))
        app.reveal(row)
        XCTAssertTrue(row.exists)
        XCTAssertNil(PhoneFixtures.episode("show.short", season: 1, number: 7))
    }

    func testEpisodePlayGlyphPlaysThatEpisode() throws {
        try standardOnly()
        let api = try self.api
        launchHome()
        _ = try openFixture("show.short")
        any(TestID.Detail.season(try XCTUnwrap(PhoneFixtures.season("show.short", 1)))).tapNow(20)
        let e4 = try XCTUnwrap(PhoneFixtures.episode("show.short", season: 1, number: 4))
        let play = any(TestID.Detail.episodePlay(e4))
        app.reveal(play)
        play.tapNow(10)
        XCTAssertNotNil(try api.waitForPlayback(of: e4, timeout: 60))
    }

    func testEpisodePageShowsItsShowAndSeason() throws {
        try standardOnly()
        launchHome()
        let e1 = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 1))
        openTitle(e1, searching: "Long Episode 1.1")
        any(TestID.Detail.ancestors).waitToExist(10)
        let show = try Fixtures.require().item("show.long")
        any(TestID.Item.ancestor(show.id)).tapNow(10)
        app.element(TestID.Detail.page(show.id)).waitToExist(20)
    }

    /// Regression R-SE-rows (open on main): episode rows truncated their
    /// titles on the small phone.
    func testEpisodeRowsShowTheirTitles() throws {
        launchHome()
        _ = try openFixture("show.long")
        let season1 = any(TestID.Detail.season(try XCTUnwrap(PhoneFixtures.season("show.long", 1))))
        app.reveal(season1)
        season1.tapNow(20)
        let e3 = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 3))
        let row = any(TestID.Detail.episode(e3))
        row.waitToExist(20)
        app.reveal(row)
        assertOnScreen(row, "episode row")
        attachScreenshot("episode rows (\(device.rawValue))")
    }

    func testBlockedTitleForTheKidAccountShowsAnError() throws {
        try standardOnly()
        // fx-kid can't search for it, so its page is reached as the suite
        // account first; signing in as fx-kid hides it from search outright.
        let kid = try XCTUnwrap(QA.account(named: "fx-kid"))
        launchHome(account: kid)
        search("FX Rated R")
        app.element(TestID.Search.empty).waitToExist(30)
    }
}

final class PhoneContextMenuTests: PhoneUITestCase {
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func holdCard(_ id: String) {
        let card = app.buttons.matching(identifier: TestID.Item.card(id)).firstMatch
        app.reveal(card)
        card.waitToExist(30)
        card.press(forDuration: 1.2)
    }

    func testFilmCardMenuOffersItsActions() throws {
        let film = try Fixtures.require().item("film.long_direct")
        try self.api.setResume(film.id, seconds: 300)
        launchHome()
        holdCard(film.id)
        for item in [TestID.Item.menuPlay, TestID.Item.menuPlayFromBeginning,
                     TestID.Item.menuFavorite, TestID.Item.menuWatched, TestID.Item.menuDownload] {
            XCTAssertTrue(any(item).waitForExistence(timeout: 5), item)
        }
        attachScreenshot("card menu (\(device.rawValue))")
        any(TestID.Item.menuPlay).tap()
        app.element(TestID.Player.root).waitToExist(40)
    }

    func testCardMenuFavouriteAndWatched() throws {
        try standardOnly()
        let api = try self.api
        let film = try Fixtures.require().item("film.long_direct")
        try api.setResume(film.id, seconds: 300)
        try api.setFavorite(film.id, false)
        addTeardownBlock { try? api.setFavorite(film.id, false); try? api.markUnplayed(film.id); try? api.setResume(film.id, seconds: 300) }
        launchHome()
        holdCard(film.id)
        any(TestID.Item.menuFavorite).tapNow(10)
        XCTAssertTrue(eventually { (try? api.userData(film.id).favorite) == true })
        holdCard(film.id)
        any(TestID.Item.menuWatched).tapNow(10)
        XCTAssertTrue(eventually { (try? api.userData(film.id).played) == true })
    }

    func testEpisodeCardMenuGoesToShowAndSeason() throws {
        try standardOnly()
        let e2 = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 2))
        try self.api.setResume(e2, seconds: 200)
        launchHome()
        holdCard(e2)
        any(TestID.Item.menuGoToShow).waitToExist(10)
        XCTAssertTrue(any(TestID.Item.menuGoToSeason).exists)
        any(TestID.Item.menuGoToShow).tap()
        app.element(TestID.Detail.page(try Fixtures.require().item("show.long").id)).waitToExist(20)
    }

    func testDownloadSubmenuListsEveryQuality() throws {
        try standardOnly()
        let film = try Fixtures.require().item("film.long_direct")
        try self.api.setResume(film.id, seconds: 300)
        launchHome()
        holdCard(film.id)
        any(TestID.Item.menuDownload).tapNow(10)
        // Submenu rows lose their identifiers; their labels start with the rung.
        for (key, start) in [("original-quality", "Original"), ("1080p-9-mbps-transcoded", "1080p"), ("480p-2-mbps-transcoded", "480p")] {
            let byId = any(TestID.Item.menuDownloadQuality(key))
            let byLabel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
            XCTAssertTrue(byId.waitForExistence(timeout: 3) || byLabel.waitForExistence(timeout: 3), key)
        }
    }

    // MARK: Next Up

    /// Remove from Next Up takes Short Show off the row and off the server's
    /// Next Up (regression R-a9528ef).
    func testRemoveFromNextUp() throws {
        try standardOnly()
        let api = try self.api
        let show = try Fixtures.require().item("show.short")
        // Back to the baseline: E01 and E02 watched, so E03 is next.
        for n in [1, 2] { try api.markPlayed(try XCTUnwrap(PhoneFixtures.episode("show.short", season: 1, number: n))) }
        launchHome()
        let shelf = app.element(TestID.Home.shelf(TestID.Home.rowNextUp))
        app.reveal(shelf)
        // Whichever Short Show episode Next Up offers (earlier tests move it).
        // An anchor has no children: find the card by where it sits.
        shelf.waitToExist(30)
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item.card.' AND label CONTAINS 'FX Short Show'"))
        var found: XCUIElement?
        _ = eventually(timeout: 30) {
            found = candidates.allElementsBoundByIndex.first { $0.frame.midY > shelf.frame.minY && $0.frame.midY < shelf.frame.maxY }
            return found != nil
        }
        let card = try XCTUnwrap(found, "no Short Show card on Next Up")
        let e3 = String(card.identifier.dropFirst("item.card.".count))
        card.press(forDuration: 1.2)
        any(TestID.Item.menuRemoveFromNextUp).tapNow(10)
        XCTAssertTrue(eventually(timeout: 20) {
            !candidates.allElementsBoundByIndex.contains { $0.frame.midY > shelf.frame.minY && $0.frame.midY < shelf.frame.maxY }
        }, "still on Next Up")
        let ids = (try api.json("/Shows/NextUp?userId=\(api.userId)&Limit=50") as? [String: Any])?["Items"] as? [[String: Any]] ?? []
        XCTAssertFalse(ids.contains { ($0["Id"] as? String) == e3 || ($0["SeriesId"] as? String) == show.id }, "the server still offers it")
    }

    /// Add to Next Up from the last watched episode (memory:
    /// jellyfin-next-up-rules): the show comes to the front of the row.
    func testAddToNextUpFromLastWatched() throws {
        try standardOnly()
        let api = try self.api
        let show = try Fixtures.require().item("show.short")
        launchHome()
        openTitle(show.id, searching: show.name)
        app.button(TestID.Detail.more).tapNow()
        app.descendants(matching: .any).matching(identifier: TestID.Detail.addToNextUp).firstMatch.tapNow(10)
        any(TestID.Shell.nextUpFromLastWatched).tapNow(10)
        let ids = { ((try? api.json("/Shows/NextUp?userId=\(api.userId)&Limit=50")) as? [String: Any])?["Items"] as? [[String: Any]] ?? [] }
        XCTAssertTrue(eventually(timeout: 20) { (ids().first?["SeriesId"] as? String) == show.id }, "Short Show is not first on Next Up")
    }

    /// From the first episode: the show is marked unwatched and S1E1 is
    /// offered. (Memory jellyfin-next-up-rules: the series-wide DELETE may do
    /// nothing on 12.2.)
    func testAddToNextUpFromTheFirstEpisode() throws {
        try standardOnly()
        let api = try self.api
        let show = try Fixtures.require().item("show.short")
        let e1 = try XCTUnwrap(PhoneFixtures.episode("show.short", season: 1, number: 1))
        try api.markPlayed(e1)
        launchHome()
        openTitle(show.id, searching: show.name)
        app.button(TestID.Detail.more).tapNow()
        app.descendants(matching: .any).matching(identifier: TestID.Detail.addToNextUp).firstMatch.tapNow(10)
        any(TestID.Shell.nextUpFromFirstEpisode).tapNow(10)
        XCTAssertTrue(eventually(timeout: 20) { (try? api.userData(e1).played) == false }, "S1E1 is still marked watched on the server")
    }

    func testAddToNextUpCancel() throws {
        try standardOnly()
        let show = try Fixtures.require().item("show.long")
        launchHome()
        openTitle(show.id, searching: show.name)
        app.button(TestID.Detail.more).tapNow()
        app.descendants(matching: .any).matching(identifier: TestID.Detail.addToNextUp).firstMatch.tapNow(10)
        let cancel = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == 'Cancel'", TestID.Shell.nextUpCancel)).firstMatch
        any(TestID.Shell.nextUpFromLastWatched).waitToExist(10)
        if cancel.waitForExistence(timeout: 2) { cancel.tap() } else {
            // A popover with no Cancel row: a tap outside it.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        }
        XCTAssertTrue(any(TestID.Shell.nextUpFromLastWatched).waitToVanish(10))
        XCTAssertTrue(app.element(TestID.Detail.root).exists)
    }
}
#endif
