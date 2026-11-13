//  Browsing on the phone: Home's rows (as suite-reset.py leaves them), the
//  hero, the libraries and a library's grid with its sort, filters, genre and
//  A–Z strip, Favorites, Collections, Search, and the photo library.

#if os(iOS)
import XCTest

final class PhoneHomeTests: PhoneUITestCase {
    /// The baseline rows (FIXTURES.md, "Baseline state"): Continue Watching
    /// holds FX Long Direct Play and Long Show S01E02; Next Up holds Long Show
    /// S01E02 then Short Show S01E03; a Latest row per fixture library.
    func testHomeShowsTheBaselineRows() throws {
        let fx = try Fixtures.require()
        let api = try self.api
        try api.setResume(try fx.item("film.long_direct").id, seconds: 300)
        launchHome()
        let resume = app.element(TestID.Home.shelf(TestID.Home.rowResume))
        app.reveal(resume)
        resume.waitToExist(30)
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("film.long_direct").id)).firstMatch.waitToExist(20)
        let nextUp = app.element(TestID.Home.shelf(TestID.Home.rowNextUp))
        app.reveal(nextUp)
        XCTAssertTrue(nextUp.exists, "Next Up row")
        let latest = app.element(TestID.Home.shelf(TestID.Home.rowLatest(try fx.libraryId("Fixture Films"))))
        app.reveal(latest)
        XCTAssertTrue(latest.exists, "Latest in Fixture Films")
        attachScreenshot("home (\(device.rawValue))")
    }

    func testHomeBarAndHeroFitTheScreen() throws {
        launchHome()
        assertOnScreen(app.button(TestID.Home.search), "Search")
        assertOnScreen(app.button(TestID.Home.refresh), "Refresh")
        let hero = app.element(TestID.Home.hero)
        hero.waitToExist(30)
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.play.")).firstMatch
        play.waitToExist(20)
        XCTAssertGreaterThanOrEqual(play.frame.minX, 0)
        XCTAssertLessThanOrEqual(play.frame.maxX, app.windows.firstMatch.frame.maxX)
    }

    func testHeroDetailsOpensTheTitle() throws {
        try standardOnly()
        launchHome()
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.details.")).firstMatch
        details.waitToExist(30)
        let id = String(details.identifier.dropFirst("home.hero.details.".count))
        details.tap()
        app.element(TestID.Detail.page(id)).waitToExist(30)
    }

    func testHeroSwipesToTheNextPage() throws {
        try standardOnly()
        launchHome()
        let hero = app.element(TestID.Home.hero)
        hero.waitToExist(30)
        app.element(TestID.Home.heroCurrentPage(0)).waitToExist(20)
        hero.swipeLeft()
        XCTAssertTrue(app.element(TestID.Home.heroCurrentPage(1)).waitForExistence(timeout: 10), "hero did not turn")
    }

    func testRefreshKeepsHome() throws {
        try standardOnly()
        launchHome()
        app.button(TestID.Home.refresh).tapNow(20)
        app.element(TestID.Home.root).waitToExist(30)
        app.element(TestID.Home.shelf(TestID.Home.rowResume)).waitToExist(30)
    }

    func testContinueWatchingCardOpensTheTitle() throws {
        try standardOnly()
        let film = try Fixtures.require().item("film.long_direct")
        try self.api.setResume(film.id, seconds: 300)
        launchHome()
        let card = app.buttons.matching(identifier: TestID.Item.card(film.id)).firstMatch
        app.reveal(card)
        card.tapNow(20)
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Detail.resumeProgress).waitForExistence(timeout: 10), "a started film shows how far through it is")
        XCTAssertEqual(app.button(TestID.Detail.play).label, "Resume")
    }

    func testSeeAllOpensTheLibrary() throws {
        try standardOnly()
        let films = try Fixtures.require().libraryId("Fixture Films")
        launchHome()
        let seeAll = app.button(TestID.Home.shelfSeeAll(TestID.Home.rowLatest(films)))
        app.reveal(seeAll)
        seeAll.tapNow(20)
        app.element(TestID.Library.root).waitToExist(30)
    }

    func testLibraryTileOpensTheLibrary() throws {
        try standardOnly()
        let films = try Fixtures.require().libraryId("Fixture Films")
        launchHome()
        let tile = app.button(TestID.Library.tile(films))
        app.reveal(tile)
        tile.tapNow(20)
        app.element(TestID.Library.root).waitToExist(30)
    }

    func testOnNowRowOpensLiveTV() throws {
        try standardOnly()
        launchHome()
        let seeAll = app.button(TestID.Home.shelfSeeAll(TestID.Home.rowLiveTV))
        app.reveal(seeAll)
        seeAll.tapNow(20)
        app.element(TestID.LiveTV.root).waitToExist(30)
    }

    /// Regression R-PM29 (master-fix-list Pro Max #29; open on main): the
    /// Continue Watching card of an episode named the show twice.
    func testContinueWatchingEpisodeCardNamesTheShowOnce() throws {
        let episode = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 2))
        launchHome()
        let card = app.buttons.matching(identifier: TestID.Item.card(episode)).firstMatch
        app.reveal(card)
        card.waitToExist(20)
        let count = card.label.components(separatedBy: "FX Long Show").count - 1
        XCTAssertLessThanOrEqual(count, 1, card.label)
    }

    func testSearchFromHomeAndBackLeavesNoEmptyBar() throws {
        // Regression R-b7ce99a: popping Search left an empty system bar over Home.
        try standardOnly()
        launchHome()
        app.button(TestID.Home.search).tapNow(20)
        app.element(TestID.Search.root).waitToExist(20)
        app.button(TestID.Search.back).tapNow(20)
        app.element(TestID.Home.root).waitToExist(20)
        let brand = app.element(TestID.Common.brand)
        XCTAssertTrue(brand.waitForExistence(timeout: 10))
        let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.frame.height > 1 && $0.frame.maxY <= brand.frame.minY + 1 }
        XCTAssertTrue(bars.isEmpty, "a navigation bar sits above Home's own bar")
    }
}

final class PhoneLibraryTests: PhoneUITestCase {
    static let sortLabels = ["name": "Name", "dateAdded": "Recently Added", "releaseDate": "Release Date",
                             "rating": "Rating", "runtime": "Runtime", "random": "Random"]

    private func openFilms() throws {
        let films = try Fixtures.require().libraryId("Fixture Films")
        launchHome()
        tab("Library")
        app.element(TestID.Library.listRoot).waitToExist(30)
        app.button(TestID.Library.tile(films)).tapNow(20)
        app.element(TestID.Library.root).waitToExist(30)
        app.element(TestID.Library.grid).waitToExist(30)
    }

    func testLibrariesListShowsEveryFixtureLibrary() throws {
        let fx = try Fixtures.require()
        launchHome()
        tab("Library")
        app.element(TestID.Library.listRoot).waitToExist(30)
        for name in ["Fixture Films", "Fixture Shows", "Fixture Photos"] {
            let tile = app.button(TestID.Library.tile(try fx.libraryId(name)))
            app.reveal(tile)
            XCTAssertTrue(tile.exists, name)
            assertOnScreen(tile, name)
        }
    }

    func testFilmsGridListsFixtures() throws {
        let fx = try Fixtures.require()
        try openFilms()
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("film.aac71_mp4").id)).firstMatch.waitToExist(30)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item.card."))
        XCTAssertGreaterThan(cards.count, 4)
        // Two columns at least on every phone, and nothing off the side.
        let first = cards.element(boundBy: 0)
        assertOnScreen(first, "first card")
        attachScreenshot("films grid (\(device.rawValue))")
    }

    func testSortByNameThenByDateAdded() throws {
        try standardOnly()
        try openFilms()
        let sort = app.descendants(matching: .any).matching(identifier: TestID.Library.sortMenu).firstMatch
        sort.tapNow(20)
        menuItem(TestID.Library.sortOption("name"), label: "Name").tapNow(10)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item.card."))
        XCTAssertTrue(eventually { cards.count > 2 })
        let firstByName = cards.element(boundBy: 0).label
        XCTAssertTrue(firstByName.hasPrefix("FX"), "fixture films sort first by name: \(firstByName)")
        // Reverse is the Mac's alone; on a phone, Recently Added reorders.
        sort.tapNow(10)
        menuItem(TestID.Library.sortOption("dateAdded"), label: "Recently Added").tapNow(10)
        XCTAssertTrue(eventually(timeout: 15) { cards.element(boundBy: 0).label != firstByName }, "a new sort changed nothing")
    }

    func testEverySortOptionLoads() throws {
        try standardOnly()
        try openFilms()
        for option in ["dateAdded", "releaseDate", "rating", "runtime", "random", "name"] {
            let sort = app.descendants(matching: .any).matching(identifier: TestID.Library.sortMenu).firstMatch
            sort.tapNow(20)
            menuItem(TestID.Library.sortOption(option), label: Self.sortLabels[option] ?? option).tapNow(10)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item.card.")).firstMatch
                .waitForExistence(timeout: 20), "nothing after sorting by \(option)")
            XCTAssertFalse(app.element(TestID.Library.error).exists, option)
        }
    }

    /// Unwatched hides the played FX Rated G; Favourites keeps only FX HEVC MP4.
    func testUnwatchedAndFavouritesFilters() throws {
        try standardOnly()
        let fx = try Fixtures.require()
        let api = try self.api
        try api.setFavorite(try fx.item("film.hevc_mp4").id, true)
        try api.markPlayed(try fx.item("film.rated_g").id)
        try openFilms()
        let filter = app.descendants(matching: .any).matching(identifier: TestID.Library.filterFavorites).firstMatch
        app.reveal(filter, up: false)
        filter.tapNow(20)
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("film.hevc_mp4").id)).firstMatch.waitToExist(30)
        XCTAssertTrue(eventually { !app.buttons.matching(identifier: TestID.Item.card(try! fx.item("film.aac71_mp4").id)).firstMatch.exists },
                      "a film that is not a favourite is still listed")
        filter.tap()
        let unwatched = app.descendants(matching: .any).matching(identifier: TestID.Library.filterUnwatched).firstMatch
        unwatched.tapNow(20)
        XCTAssertTrue(eventually { !app.buttons.matching(identifier: TestID.Item.card(try! fx.item("film.rated_g").id)).firstMatch.exists },
                      "a played film is still listed under Unwatched")
    }

    func testGenreFilter() throws {
        try standardOnly()
        let fx = try Fixtures.require()
        try openFilms()
        let menu = app.descendants(matching: .any).matching(identifier: TestID.Library.genreMenu).firstMatch
        app.reveal(menu, up: false)
        menu.tapNow(20)
        menuItem(TestID.Library.genre("Versions"), label: "Versions").tapNow(10)
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("film.versions").id)).firstMatch.waitToExist(30)
        XCTAssertTrue(eventually { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item.card.")).count <= 2 })
    }

    /// Regression R-dbd3662a: the grid stopped short of the library's end.
    func testGridPagesToTheEnd() throws {
        try standardOnly()
        try openFilms()
        let count = app.element(TestID.Library.count)
        for _ in 0..<15 where !(count.exists && count.isHittable) { app.swipeUp() }
        if count.exists {
            let numbers = count.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if numbers.count >= 2 { XCTAssertEqual(numbers[0], numbers[1], "grid stopped at \(count.label)") }
        }
    }

    func testLetterIndexJumps() throws {
        try openFilms()
        let sort = app.descendants(matching: .any).matching(identifier: TestID.Library.sortMenu).firstMatch
        sort.tapNow(20)
        menuItem(TestID.Library.sortOption("name"), label: "Name").tapNow(10)
        let strip = app.element(TestID.Common.letterIndex)
        guard strip.waitForExistence(timeout: 15) else {
            throw XCTSkip("no A–Z strip on a library this short")
        }
        assertOnScreen(strip, "A–Z strip")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        attachScreenshot("after A–Z tap (\(device.rawValue))")
    }

    func testShowsLibraryListsSeriesNotEpisodes() throws {
        try standardOnly()
        let fx = try Fixtures.require()
        launchHome()
        tab("Library")
        app.button(TestID.Library.tile(try fx.libraryId("Fixture Shows"))).tapNow(30)
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("show.long").id)).firstMatch.waitToExist(30)
        let episodeId = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 1))
        XCTAssertFalse(app.buttons.matching(identifier: TestID.Item.card(episodeId)).firstMatch.exists)
    }

    /// Regression R-PM4 (master-fix-list Pro Max #4; open on main): a folder
    /// or photo album opened an empty title page.
    func testPhotoAlbumOpensItsContents() throws {
        try standardOnly()
        let fx = try Fixtures.require()
        launchHome()
        tab("Library")
        app.button(TestID.Library.tile(try fx.libraryId("Fixture Photos"))).tapNow(30)
        app.element(TestID.Library.root).waitToExist(30)
        let albumId = try XCTUnwrap(PhoneFixtures.photo("FX Album"))
        let album = app.buttons.matching(identifier: TestID.Item.card(albumId)).firstMatch
        guard album.waitForExistence(timeout: 20) else {
            XCTExpectFailure("bug: photo albums are not listed in a home-videos library")
            XCTFail("FX Album not shown"); return
        }
        album.tap()
        let nested = try XCTUnwrap(PhoneFixtures.photo("Nested"))
        let opened = app.buttons.matching(identifier: TestID.Item.card(nested)).firstMatch.waitForExistence(timeout: 20)
        XCTExpectFailure("bug R-PM4: a photo album opens an empty title page instead of its contents")
        XCTAssertTrue(opened, "FX Album should list its photos and the Nested album")
    }

    func testHomeClipInPhotosLibraryPlays() throws {
        try standardOnly()
        let fx = try Fixtures.require()
        launchHome()
        tab("Library")
        app.button(TestID.Library.tile(try fx.libraryId("Fixture Photos"))).tapNow(30)
        let clip = try XCTUnwrap(PhoneFixtures.photo("FX Home Clip"))
        app.buttons.matching(identifier: TestID.Item.card(clip)).firstMatch.tapNow(30)
        app.element(TestID.Detail.root).waitToExist(30)
        playFromDetail()
        closePlayer()
    }
}

final class PhoneFavoritesAndCollectionsTests: PhoneUITestCase {
    func testFavoritesListsTheBaselineAndFiltersByKind() throws {
        try standardOnly()
        let fx = try Fixtures.require()
        let api = try self.api
        try api.setFavorite(try fx.item("film.hevc_mp4").id, true)
        try api.setFavorite(try fx.item("show.short").id, true)
        launchHome()
        moreSection("favorites")
        app.element(TestID.Favorites.root).waitToExist(30)
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("film.hevc_mp4").id)).firstMatch.waitToExist(30)
        app.buttons.matching(identifier: TestID.Item.card(try fx.item("show.short").id)).firstMatch.waitToExist(10)
        let films = app.descendants(matching: .any).matching(identifier: TestID.Favorites.kind("movie")).firstMatch
        films.tapNow(20)
        XCTAssertTrue(eventually { !app.buttons.matching(identifier: TestID.Item.card(try! fx.item("show.short").id)).firstMatch.exists },
                      "Films kind still lists a series")
    }

    /// Regression R-2c20fe6: a favourite made on a title page did not reach
    /// the Favorites page.
    func testFavouriteFromTitleAppearsInFavorites() throws {
        try standardOnly()
        let api = try self.api
        let film = try Fixtures.require().item("film.aac71_mp4")
        try api.setFavorite(film.id, false)
        addTeardownBlock { try? api.setFavorite(film.id, false) }
        launchHome()
        _ = try openFixture("film.aac71_mp4")
        app.button(TestID.Detail.favorite).tapNow(20)
        XCTAssertTrue(eventually { (try? api.userData(film.id).favorite) == true }, "server never got the favourite")
        goBack(); goBack()
        moreSection("favorites")
        app.buttons.matching(identifier: TestID.Item.card(film.id)).firstMatch.waitToExist(30)
    }

    /// Regression R-56a1825: collections were unreachable and their page empty.
    func testCollectionsListAndOpen() throws {
        try standardOnly()
        let sets = try Fixtures.require().raw["sets"] as? [String: [String: Any]] ?? [:]
        let collection = try XCTUnwrap(sets["FX Collection"]?["id"] as? String)
        launchHome()
        moreSection("collections")
        let card = app.buttons.matching(identifier: TestID.Item.card(collection)).firstMatch
        card.tapNow(30)
        let grid = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item.card."))
        XCTAssertTrue(eventually { grid.count >= 4 }, "FX Collection should list its four titles")
    }
}

final class PhoneSearchTests: PhoneUITestCase {
    /// FIXTURES.md: "FX Long" finds the long film, the multitrack film, the
    /// long show (and the album, in music).
    func testSearchFindsTheFXLongTitles() throws {
        let fx = try Fixtures.require()
        launchHome()
        search("FX Long")
        for key in ["film.long_direct", "film.long_multitrack", "show.long"] {
            app.buttons.matching(identifier: TestID.Item.card(try fx.item(key).id)).firstMatch.waitToExist(30)
        }
        assertOnScreen(app.element(TestID.Search.field), "search field")
        assertAboveKeyboard(app.element(TestID.Search.field), "search field")
        attachScreenshot("search (\(device.rawValue))")
    }

    func testSearchFindsMusicToo() throws {
        try standardOnly()
        launchHome()
        search("FX Long")
        app.element(TestID.Search.musicResults).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Search.videoHeading).exists)
    }

    func testUnicodeSearch() throws {
        try standardOnly()
        let film = try Fixtures.require().item("film.unicode_title")
        launchHome()
        search("Unicode")
        let card = app.buttons.matching(identifier: TestID.Item.card(film.id)).firstMatch
        card.waitToExist(30)
        assertOnScreen(card, "long unicode title card")
    }

    func testNoMatchesSaysSo() throws {
        try standardOnly()
        launchHome()
        search("zzqqxx nothing")
        app.element(TestID.Search.empty).waitToExist(30)
    }

    func testRecentSearchesAreKeptAndCleared() throws {
        try standardOnly()
        launchHome()
        let field = search("FX HEVC")
        app.element(TestID.Search.results).waitToExist(30)
        field.typeText("\n")
        app.button(TestID.Search.clear).tapNow(10)
        app.element(TestID.Search.recent("FX HEVC")).waitToExist(10)
        app.button(TestID.Search.recentsClear).tapNow(10)
        XCTAssertTrue(app.element(TestID.Search.recent("FX HEVC")).waitToVanish(10))
    }

    func testClearEmptiesTheField() throws {
        try standardOnly()
        launchHome()
        let field = search("FX")
        app.button(TestID.Search.clear).tapNow(10)
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue, value)
    }

    /// Regression R-PM35 (master-fix-list Pro Max #35; open on main):
    /// coming back to Search and typing appended to the old term.
    func testTypingAfterReturningReplacesTheOldTerm() throws {
        try standardOnly()
        launchHome()
        search("FX Long")
        app.element(TestID.Search.results).waitToExist(30)
        app.button(TestID.Search.back).tapNow(10)
        app.button(TestID.Home.search).tapNow(20)
        let field = app.element(TestID.Search.field)
        field.tapNow(10)
        field.typeText("Unicode")
        let value = field.value as? String ?? ""
        XCTAssertEqual(value, "Unicode")
    }

    /// Regression R-PM34 (open on main): collections are not found.
    func testSearchFindsTheCollection() throws {
        try standardOnly()
        let sets = try Fixtures.require().raw["sets"] as? [String: [String: Any]] ?? [:]
        let collection = try XCTUnwrap(sets["FX Collection"]?["id"] as? String)
        launchHome()
        search("FX Collection")
        let found = app.buttons.matching(identifier: TestID.Item.card(collection)).firstMatch.waitForExistence(timeout: 20)
        XCTExpectFailure("bug R-PM34: Search asks only for films, shows and episodes")
        XCTAssertTrue(found)
    }
}

/// Reads ids out of fixtures.json's nested entries (seasons, photos, books,
/// music), which the shared `Fixtures` does not lift out.
enum PhoneFixtures {
    static var raw: [String: Any] { Fixtures.shared?.raw["fixtures"] as? [String: Any] ?? [:] }

    static func episode(_ show: String, season: Int, number: Int) -> String? {
        guard let seasons = (raw[show] as? [String: Any])?["seasons"] as? [[String: Any]] else { return nil }
        for s in seasons where (s["index"] as? Int) == season {
            for e in s["episodes"] as? [[String: Any]] ?? [] where (e["index"] as? Int) == number {
                return e["id"] as? String
            }
        }
        return nil
    }

    static func season(_ show: String, _ index: Int) -> String? {
        let seasons = (raw[show] as? [String: Any])?["seasons"] as? [[String: Any]] ?? []
        return seasons.first { ($0["index"] as? Int) == index }?["id"] as? String
    }

    static func photo(_ name: String) -> String? {
        (raw["photos"] as? [[String: Any]])?.first { ($0["name"] as? String) == name }?["id"] as? String
    }

    static func book(_ name: String) -> String? {
        (raw["books"] as? [[String: Any]])?.first { ($0["name"] as? String) == name }?["id"] as? String
    }

    static var music: [String: Any] { raw["music"] as? [String: Any] ?? [:] }

    static func album(_ name: String) -> [String: Any]? {
        (music["albums"] as? [[String: Any]])?.first { ($0["name"] as? String) == name }
    }

    static func track(_ name: String) -> String? {
        for album in music["albums"] as? [[String: Any]] ?? [] {
            for t in album["tracks"] as? [[String: Any]] ?? [] where (t["name"] as? String) == name { return t["id"] as? String }
        }
        return nil
    }

    static func artist(_ name: String) -> String? {
        let artists = music["artists"]
        if let list = artists as? [[String: Any]] { return list.first { ($0["name"] as? String) == name }?["id"] as? String }
        if let map = artists as? [String: Any] { return (map[name] as? [String: Any])?["id"] as? String ?? map[name] as? String }
        return nil
    }
}
#endif
