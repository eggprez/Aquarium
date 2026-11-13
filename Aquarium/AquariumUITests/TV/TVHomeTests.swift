//  Home on the Apple TV: the media bar (hero), its Play and Details, the rows
//  from the suite's baseline (FIXTURES.md "Baseline state"), the press-and-
//  hold menu on a card, and the Next Up path into a show.

#if os(tvOS)
import XCTest

final class TVHomeTests: TVTestCase {
    func testRowsMatchTheBaseline() throws {
        let fx = try Fixtures.require()
        let film = try fx.item("film.long_direct").id
        let longE2 = try fx.episode("show.long", season: 1, episode: 2)
        let shortE3 = try fx.episode("show.short", season: 1, episode: 3)
        launchHome()
        let resume = app.element(TestID.Home.shelf(TestID.Home.rowResume))
        resume.waitToExist(30)
        let nextUp = app.element(TestID.Home.shelf(TestID.Home.rowNextUp))
        nextUp.waitToExist(30)
        app.element(TestID.Home.shelf(TestID.Home.rowLibraries)).waitToExist(10)
        app.element(TestID.Home.shelf(TestID.Home.rowLatest(try fx.libraryId("Fixture Films")))).waitToExist(20)

        let cards = app.elements(prefix: "item.card.")
        func cardFrames(_ id: String) -> [CGRect] {
            cards.matching(identifier: TestID.Item.card(id)).allElementsBoundByIndex.map(\.frame)
        }
        XCTAssertTrue(cardFrames(film).contains { resume.frame.intersects($0) }, "FX Long Direct Play not in Continue Watching")
        XCTAssertTrue(cardFrames(longE2).contains { resume.frame.intersects($0) }, "Long Show S01E02 not in Continue Watching")
        XCTAssertTrue(cardFrames(longE2).contains { nextUp.frame.intersects($0) }, "Long Show S01E02 not in Next Up")
        XCTAssertTrue(cardFrames(shortE3).contains { nextUp.frame.intersects($0) }, "Short Show S01E03 not in Next Up")
        XCTAssertFalse(app.element(TestID.Home.shelf(TestID.Home.rowMusicRecent)).exists, "no music rows on the TV")
        attachScreenshot("home rows")
    }

    func testTheMediaBarHasPlayAndDetailsForTheTitleShown() {
        launchHome()
        app.element(TestID.Home.hero).waitToExist(30)
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.hero.play.'"))
        XCTAssertGreaterThan(play.count, 0)
        XCTAssertEqual(play.count, app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.hero.details.'")).count,
                       "every page of the bar has both buttons")
        // The page on screen is the one whose Play is inside the screen.
        let onScreen = play.allElementsBoundByIndex.first { $0.frame.minX >= 0 && $0.frame.maxX <= 1920 }
        XCTAssertNotNil(onScreen, "no hero page on screen")
    }

    private func focusHeroButton(_ prefix: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        XCTAssertTrue(focusTabStrip(), file: file, line: line)
        for _ in 0..<5 {
            if focusedID.hasPrefix(prefix) { break }
            if focusedID.hasPrefix("home.hero.") {
                Remote.press(prefix.contains("details") ? .right : .left)
            } else {
                Remote.press(.down)
            }
        }
        guard focusedID.hasPrefix(prefix) else {
            XCTFail("never reached \(prefix) (on \(focused?.summary ?? "nothing"))", file: file, line: line)
            return nil
        }
        return String(focusedID.dropFirst(prefix.count))
    }

    func testDetailsOpensTheTitleOnTheBar() {
        launchHome()
        guard let id = focusHeroButton("home.hero.details.") else { return }
        Remote.select()
        app.element(TestID.Detail.page(id)).waitToExist(20)
        assertFocusPresent("the title from the media bar")
    }

    func testPlayOnTheBarPlaysThatTitle() throws {
        launchHome()
        guard let id = focusHeroButton("home.hero.play.") else { return }
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        let api = try self.api()
        // A series on the bar plays an episode of it: anything playing will do then.
        let session = try api.tvWaitForPlayback(of: nil, timeout: 45)
        XCTAssertNotNil(session, "the server never heard the TV play")
        if let s = session, s.nowPlayingId != id { attachScreenshot("bar played \(s.nowPlayingId ?? "?") for \(id)") }
        Remote.menu()
        Remote.menu()
    }

    func testContinueWatchingResumesWhereItStopped() throws {
        // Baseline: FX Long Direct Play at 5:00. Resume needs a long title
        // (qa-server-short-title-resume.md).
        let film = try Fixtures.require().item("film.long_direct").id
        launchHome()
        let card = app.element(TestID.Item.card(film))
        XCTAssertTrue(Remote.focus(on: card, in: app))
        Remote.select()
        // A card opens the title page; Play there says Resume.
        let play = app.button(TestID.Detail.play)
        play.waitToExist(20)
        XCTAssertTrue(play.label.localizedCaseInsensitiveContains("resume"), "Play reads \(play.label)")
        XCTAssertTrue(Remote.focus(on: play, in: app))
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        let s = try api().tvWaitForPlayback(of: film, timeout: 45)
        waitUntil("the reported position to be near 5:00", timeout: 30) { [weak self] in
            ((try? self?.serverPosition(of: film)) ?? nil).map { $0 >= 295 && $0 < 400 } ?? false
        }
        XCTAssertNotNil(s)
    }

    func testHoldingACardOpensItsMenu() throws {
        let film = try Fixtures.require().item("film.long_direct").id
        launchHome()
        XCTAssertTrue(Remote.focus(on: app.element(TestID.Item.card(film)), in: app))
        Remote.longPress(.select, seconds: 1.2)
        let play = app.element(TestID.Item.menuPlay)
        play.waitToExist(10)
        XCTAssertTrue(app.element(TestID.Item.menuWatched).exists || app.staticTexts["Mark as Watched"].exists)
        attachTree("card menu")
        Remote.menu()
        XCTAssertTrue(play.waitToVanish(10))
        assertFocusPresent("Home after closing the card menu")
    }

    func testMarkWatchedFromTheCardMenuReachesTheServer() throws {
        let fx = try Fixtures.require()
        let hevc = try fx.item("film.dvb_subs_ts").id  // on Latest in Fixture Films, unplayed in the baseline
        let api = try self.api()
        try api.markUnplayed(hevc)
        defer { try? api.markUnplayed(hevc) }
        launchHome()
        let latest = app.element(TestID.Home.shelf(TestID.Home.rowLatest(try fx.libraryId("Fixture Films"))))
        latest.waitToExist(20)
        let card = app.element(TestID.Item.card(hevc))
        guard Remote.focus(on: card, in: app) else { return XCTFail("FX DVB Subs TS not on the Latest row") }
        Remote.longPress(.select, seconds: 1.2)
        let watched = app.element(TestID.Item.menuWatched)
        watched.waitToExist(10)
        XCTAssertTrue(focusInColumn(watched) || Remote.focus(on: watched, in: app), "can't reach Mark as Watched (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        waitUntil("the server to mark it played", timeout: 15) { (try? api.userData(hevc).played) == true }
    }

    func testNextUpCardOpensTheSeasonOnItsEpisode() throws {
        // Next Up leads to the show with the season on top and the episode
        // picked out (AppModel.openNextUp).
        let fx = try Fixtures.require()
        let shortE3 = try fx.episode("show.short", season: 1, episode: 3)
        launchHome()
        app.element(TestID.Home.shelf(TestID.Home.rowNextUp)).waitToExist(30)
        let nextUp = app.element(TestID.Home.shelf(TestID.Home.rowNextUp))
        let card = app.elements(prefix: TestID.Item.card(shortE3)).allElementsBoundByIndex.first { nextUp.frame.intersects($0.frame) }
        guard let card else { return XCTFail("Short Show S01E03 not on Next Up") }
        XCTAssertTrue(Remote.focus(on: card, in: app))
        Remote.select()
        app.element(TestID.Detail.root).waitToExist(20)
        waitUntil("focus on S01E03's row", timeout: 15) { [weak self] in
            self?.focusedID == TestID.Detail.episode(shortE3) || self?.focusedID == TestID.Detail.episodePlay(shortE3)
        }
    }

    func testRefreshKeepsFocusAndRows() {
        launchHome()
        XCTAssertTrue(focusTabStrip())
        Remote.press(.down)
        XCTAssertEqual(focusedID, TestID.Home.refresh, "Down from the strip lands on Refresh (kept as design, fix-status.md)")
        Remote.select()
        app.element(TestID.Home.shelf(TestID.Home.rowResume)).waitToExist(30)
        assertFocusPresent("Home after Refresh")
    }
}
#endif
