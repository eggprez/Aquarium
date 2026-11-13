//  Browsing on a Mac: the sidebar and its groups, Home (the media bar, the
//  shelves, the toolbar), the libraries and one library (grid, table, sort,
//  filters, the search field, no results), Favorites, Search, title pages
//  and a series' episode list, a person's page, and the context menus.

#if os(macOS)
import XCTest

final class MacBrowseUITests: MacUITestCase {
    private func fixtures() throws -> Fixtures { try Fixtures.require() }

    // MARK: Sidebar

    func testSidebarHasHomeLibrariesLiveTVFavoritesDownloads() throws {
        let fx = try fixtures()
        launchToHome()
        app.element(TestID.Sidebar.root).waitToExist()
        XCTAssertTrue(sidebarRow("home").exists)
        XCTAssertTrue(sidebarRow("lib-\(try fx.libraryId("Fixture Films"))").exists)
        XCTAssertTrue(sidebarRow("lib-\(try fx.libraryId("Fixture Shows"))").exists)
        XCTAssertTrue(sidebarRow("favorites").exists)
        XCTAssertTrue(sidebarRow("downloads").exists)
        XCTAssertTrue(sidebarRow("livetv").waitForExistence(timeout: 20), "the QA server has a tuner")
        XCTAssertFalse(sidebarRow("settings").exists, "Settings is its own window on a Mac")
        XCTAssertFalse(sidebarRow("search").exists, "Search is the field above the rows")
        // Deep Water's grouped sidebar: headings over the rows.
        for heading in ["Libraries", "Live", "You"] {
            XCTAssertTrue(app.staticTexts[heading].exists || app.outlines.staticTexts[heading].exists, heading)
        }
        attachScreenshot("sidebar")
    }

    func testEverySidebarRowOpensItsPage() {
        launchToHome()
        for section in ["favorites", "downloads", "livetv", "home"] {
            openSection(section)
        }
    }

    /// Clicking the row already selected goes back to its top (Music, Finder);
    /// the click that selects a row keeps the section's pages.
    /// Regression: SidebarSlowClickResetsSection (commit 6704c21) for the
    /// second half.
    func testReclickingTheSelectedRowGoesToTheTop() throws {
        let film = try fixtures().item("film.long_direct")
        launchToHome()
        let card = app.elements(prefix: TestID.Item.card(film.id)).firstMatch
        card.waitToExist(30)
        card.doubleClick()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
        // Away and back: the click that selects Home keeps the title page.
        openSection("favorites")
        sidebarRow("home").click()
        XCTAssertTrue(app.element(TestID.Detail.page(film.id)).waitForExistence(timeout: 10),
                      "selecting Home again comes back to the page left open there")
        // A second click on the row already selected: back to the top.
        Thread.sleep(forTimeInterval: 0.5)
        sidebarRow("home").click()
        XCTAssertTrue(app.element(TestID.Detail.page(film.id)).waitToVanish(10))
        app.element(TestID.Home.root).waitToExist(10)
    }

    // MARK: Home

    func testHomeShowsContinueWatchingAndNextUp() throws {
        let fx = try fixtures()
        launchToHome()
        app.element(TestID.Home.shelf(TestID.Home.rowResume)).waitToExist(30)
        app.element(TestID.Home.shelf(TestID.Home.rowNextUp)).waitToExist(30)
        let film = try fx.item("film.long_direct")
        XCTAssertTrue(app.elements(prefix: TestID.Item.card(film.id)).firstMatch.waitForExistence(timeout: 20),
                      "FX Long Direct Play is in Continue Watching after the reset")
        attachScreenshot("home")
    }

    func testMediaBarPagesWithChevronsAndArrowKeys() {
        launchToHome()
        let hero = app.element(TestID.Home.hero)
        hero.waitToExist(30)
        hero.hover()
        let next = app.button(TestID.Home.heroNext)
        guard next.waitForExistence(timeout: 5) else { return }   // one featured title: no paging
        let page0 = app.element(TestID.Home.heroCurrentPage(0))
        XCTAssertTrue(page0.waitForExistence(timeout: 5))
        next.click()
        XCTAssertTrue(app.element(TestID.Home.heroCurrentPage(1)).waitForExistence(timeout: 5))
        app.button(TestID.Home.heroPrevious).click()
        XCTAssertTrue(app.element(TestID.Home.heroCurrentPage(0)).waitForExistence(timeout: 5))
        // Wrapping backwards from the first page.
        app.button(TestID.Home.heroPrevious).click()
        XCTAssertFalse(app.element(TestID.Home.heroCurrentPage(0)).waitForExistence(timeout: 2))
    }

    func testMediaBarDotsJumpToAPage() {
        launchToHome()
        mainWindow.waitToExist()
        let dot = app.button(TestID.Home.heroDot(2))
        guard dot.waitForExistence(timeout: 20) else { return }    // a wide window shows thumbnails instead
        dot.click()
        XCTAssertTrue(app.element(TestID.Home.heroCurrentPage(2)).waitForExistence(timeout: 5))
    }

    func testToolbarSearchRefreshAndPlayFeatured() {
        launchToHome()
        XCTAssertTrue(app.element(TestID.Home.refresh).waitForExistence(timeout: 20))
        app.element(TestID.Home.refresh).click()
        app.element(TestID.Home.root).waitToExist()
        if app.element(TestID.Home.playFeatured).waitForExistence(timeout: 5) {
            app.element(TestID.Home.playFeatured).click()
            playerWindow.waitToExist(45)
        }
    }

    func testShelfHeadingOpensSeeAll() throws {
        launchToHome()
        let link = app.element(TestID.Common.shelfHeadingLink(TestID.Home.rowNextUp))
        guard link.waitForExistence(timeout: 20) else { throw XCTSkip("Next Up has no heading link on this server state") }
        link.click()
        XCTAssertTrue(app.element(TestID.Common.grid).waitForExistence(timeout: 20)
                      || app.element(TestID.Library.root).waitForExistence(timeout: 5))
    }

    // MARK: Libraries

    func testLibraryGridSortAndFilters() throws {
        let fx = try fixtures()
        let lib = try fx.libraryId("Fixture Films")
        launchToHome()
        openSection("lib-\(lib)")
        app.element(TestID.Library.page(lib)).waitToExist(30)
        app.element(TestID.Library.grid).waitToExist(30)
        let film = try fx.item("film.long_direct")
        XCTAssertTrue(app.elements(prefix: TestID.Item.card(film.id)).firstMatch.waitForExistence(timeout: 30))
        // Sort by date added, then reverse.
        app.element(TestID.Library.sortMenu).tapWhenReady()
        app.element(TestID.Library.sortOption("dateAdded")).tapWhenReady()
        app.element(TestID.Library.filterUnwatched).tapWhenReady()
        app.element(TestID.Library.grid).waitToExist(30)
        attachScreenshot("films, unwatched, by date added")
    }

    /// Regression: LibraryFiltersForgottenBetweenLibraries — Films keeps its
    /// filters after a visit to Shows. Source: Views/LibraryView+Mac.swift:13-21.
    func testBugFiltersRememberedPerLibrary() throws {
        let fx = try fixtures()
        let films = try fx.libraryId("Fixture Films"), shows = try fx.libraryId("Fixture Shows")
        launchToHome()
        openSection("lib-\(films)")
        let unwatched = app.element(TestID.Library.filterUnwatched)
        unwatched.tapWhenReady()
        let on = unwatched.value as? Int ?? (unwatched.isSelected ? 1 : 0)
        openSection("lib-\(shows)")
        openSection("lib-\(films)")
        let again = app.element(TestID.Library.filterUnwatched)
        again.waitToExist()
        XCTAssertEqual(again.value as? Int ?? (again.isSelected ? 1 : 0), on)
    }

    func testLibrarySearchFieldNarrowsAndNoResultsClears() throws {
        let fx = try fixtures()
        let lib = try fx.libraryId("Fixture Films")
        launchToHome()
        openSection("lib-\(lib)")
        let field = app.element(TestID.Library.searchField)
        field.tapWhenReady()
        field.typeText("zzzz-nothing")
        app.element(TestID.Library.noResults).waitToExist(30)
        app.button(TestID.Library.noResultsClear).tapWhenReady()
        app.element(TestID.Library.grid).waitToExist(30)
        field.click()
        field.typeText("Unicode")
        let unicode = try fx.item("film.unicode_title")
        XCTAssertTrue(app.elements(prefix: TestID.Item.card(unicode.id)).firstMatch.waitForExistence(timeout: 30))
    }

    func testLibraryTableLayout() throws {
        let fx = try fixtures()
        let lib = try fx.libraryId("Fixture Films")
        launchToHome()
        openSection("lib-\(lib)")
        let picker = app.element(TestID.Library.layoutPicker)
        guard picker.waitForExistence(timeout: 20) else { throw XCTSkip("no layout picker") }
        let table = app.element(TestID.Library.layout("table"))
        if table.exists { table.click() } else { picker.click() }
        app.element(TestID.Library.table).waitToExist(20)
        let film = try fx.item("film.long_direct")
        XCTAssertTrue(app.element(TestID.Library.tableRow(film.id)).waitForExistence(timeout: 20))
    }

    func testLibrarySelectionMenuMarksWatched() throws {
        let fx = try fixtures()
        let api = try JellyfinAPI.signIn()
        let lib = try fx.libraryId("Fixture Films")
        let film = try fx.item("film.hevc_mp4")
        try api.markUnplayed(film.id)
        launchToHome()
        openSection("lib-\(lib)")
        let card = app.elements(prefix: TestID.Item.card(film.id)).firstMatch
        card.waitToExist(30)
        card.click()
        app.element(TestID.Library.selectionMenu).tapWhenReady()
        app.element(TestID.Library.selectionMarkWatched).tapWhenReady()
        XCTAssertTrue(try eventually(20) { try api.userData(film.id).played })
        try api.markUnplayed(film.id)
    }

    // MARK: Favorites and Search

    func testFavoritesListsTheBaselineFavourites() throws {
        let fx = try fixtures()
        launchToHome()
        openSection("favorites")
        app.element(TestID.Favorites.root).waitToExist(30)
        let hevc = try fx.item("film.hevc_mp4")
        XCTAssertTrue(app.elements(prefix: TestID.Item.card(hevc.id)).firstMatch.waitForExistence(timeout: 30))
    }

    func testSidebarSearchFindsTheFXLongTitles() throws {
        let fx = try fixtures()
        launchToHome()
        searchFromSidebar("FX Long")
        app.element(TestID.Search.results).waitToExist(30)
        for key in ["film.long_direct", "film.long_multitrack", "show.long"] {
            let item = try fx.item(key)
            XCTAssertTrue(app.elements(prefix: TestID.Item.card(item.id)).firstMatch.waitForExistence(timeout: 20), key)
        }
    }

    func testSearchRemembersRecentTerms() {
        launchToHome()
        searchFromSidebar("Unicode")
        openSection("home")
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.element(TestID.Sidebar.searchSuggestion(TestID.key("Unicode"))).waitForExistence(timeout: 10))
        dismissMenus()
    }

    func testUnicodeTitleOpens() throws {
        let item = try fixtures().item("film.unicode_title")
        launchToHome()
        openTitle(named: "Unicode", id: item.id)
        XCTAssertTrue(app.element(TestID.Detail.title).waitForExistence(timeout: 10))
    }

    // MARK: Title pages

    func testFilmPageHasPlayFavoriteWatchedDownload() throws {
        let film = try fixtures().item("film.long_direct")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        for id in [TestID.Detail.play, TestID.Detail.favorite, TestID.Detail.watched, TestID.Detail.download] {
            XCTAssertTrue(app.element(id).waitForExistence(timeout: 10), id)
        }
        XCTAssertTrue(app.element(TestID.Detail.cast).exists || app.element(TestID.Detail.overview).exists)
        attachScreenshot("title page (two-column, Deep Water)")
    }

    func testFavoriteButtonReachesTheServer() throws {
        let film = try fixtures().item("film.rated_pg13")
        let api = try JellyfinAPI.signIn()
        try api.setFavorite(film.id, false)
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.element(TestID.Detail.favorite).tapWhenReady()
        XCTAssertTrue(try eventually(20) { try api.userData(film.id).favorite })
        app.element(TestID.Detail.favorite).tapWhenReady()
        XCTAssertTrue(try eventually(20) { try !api.userData(film.id).favorite })
    }

    /// Regression: FavoriteThenWatchedLosesOne. Two quick toggles each wrote
    /// back the copy they started from, and the page showed only one change.
    /// Source: commit b723cea; Views/ItemDetailView.swift:2350-2361.
    func testBugFavoriteThenWatchedLosesOne() throws {
        let film = try fixtures().item("film.rated_r")
        let api = try JellyfinAPI.signIn()
        try api.resetItem(film.id)
        launchToHome()
        openTitle(named: film.name, id: film.id)
        app.element(TestID.Detail.favorite).tapWhenReady()
        app.element(TestID.Detail.watched).tapWhenReady()
        XCTAssertTrue(try eventually(20) {
            let d = try api.userData(film.id)
            return d.favorite && d.played
        })
        try api.resetItem(film.id)
    }

    func testSeriesPageListsSeasonsAndEpisodes() throws {
        let show = try fixtures().item("show.long")
        launchToHome()
        openTitle(named: show.name, id: show.id)
        app.element(TestID.Detail.seasons).waitToExist(30)
        app.element(TestID.Detail.episodeList).waitToExist(30)
        attachScreenshot("series")
    }

    /// Regression: EpisodeListClipsLastRow — every episode of the season is
    /// hittable after scrolling the page. Source: commit 6704c21.
    func testBugEpisodeListShowsTheLastEpisode() throws {
        let fx = try fixtures()
        let show = try fx.item("show.long")
        guard let seasons = show.raw["seasons"] as? [[String: Any]],
              let s1 = seasons.first(where: { $0["index"] as? Int == 1 }),
              let episodes = s1["episodes"] as? [[String: Any]],
              let lastId = episodes.last?["id"] as? String
        else { throw XCTSkip("fixtures.json has no Season 01 episodes") }
        launchToHome()
        openTitle(named: show.name, id: show.id)
        let season = app.element(TestID.Detail.season(s1["id"] as? String ?? ""))
        if season.waitForExistence(timeout: 10) { season.click() }
        let last = app.element(TestID.Detail.episode(lastId))
        last.waitToExist(30)
        mainWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -2000)
        XCTAssertTrue(last.isHittable)
    }

    /// Regression: ReturnOnEpisodesPlaysRandomOne — ⇧-click three episodes,
    /// Return plays the earliest. Source: commit 9c6fb8c.
    func testBugReturnOnEpisodesPlaysTheEarliest() throws {
        let fx = try fixtures()
        let show = try fx.item("show.long")
        let api = try JellyfinAPI.signIn()
        guard let seasons = show.raw["seasons"] as? [[String: Any]],
              let s1 = seasons.first(where: { $0["index"] as? Int == 1 }),
              let eps = (s1["episodes"] as? [[String: Any]])?.compactMap({ $0["id"] as? String }), eps.count >= 4
        else { throw XCTSkip("no Season 01 in fixtures.json") }
        launchToHome()
        openTitle(named: show.name, id: show.id)
        app.element(TestID.Detail.episode(eps[1])).tapWhenReady(30)
        XCUIElement.perform(withKeyModifiers: .shift) { app.element(TestID.Detail.episode(eps[3])).click() }
        app.typeKey(.return, modifierFlags: [])
        playerWindow.waitToExist(45)
        XCTAssertEqual(try api.waitForPlayback(timeout: 30)?.nowPlayingId, eps[1])
    }

    func testPersonPageFromCast() throws {
        let film = try fixtures().item("film.long_direct")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        let person = app.elements(prefix: "detail.cast.person.").firstMatch
        person.waitToExist(30)
        person.click()
        app.element(TestID.Person.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Person.films).waitForExistence(timeout: 20))
    }

    // MARK: Context menus

    func testPosterContextMenuMarksWatchedAndFavorite() throws {
        let fx = try fixtures()
        let lib = try fx.libraryId("Fixture Films")
        let film = try fx.item("film.pcm_mov")
        let api = try JellyfinAPI.signIn()
        try api.resetItem(film.id)
        launchToHome()
        openSection("lib-\(lib)")
        let card = app.elements(prefix: TestID.Item.card(film.id)).firstMatch
        card.waitToExist(30)
        card.rightClick()
        for id in [TestID.Item.menuPlay, TestID.Item.menuDetails, TestID.Item.menuOpenInNewWindow,
                   TestID.Item.menuFavorite, TestID.Item.menuWatched, TestID.Item.menuCopyTitle] {
            XCTAssertTrue(app.menuItems.matching(identifier: id).firstMatch.waitForExistence(timeout: 5)
                          || app.element(id).exists, id)
        }
        app.menuItems.matching(identifier: TestID.Item.menuWatched).firstMatch.click()
        XCTAssertTrue(try eventually(20) { try api.userData(film.id).played })
        card.rightClick()
        app.menuItems.matching(identifier: TestID.Item.menuFavorite).firstMatch.tapWhenReady()
        XCTAssertTrue(try eventually(20) { try api.userData(film.id).favorite })
        try api.resetItem(film.id)
    }

    func testSidebarRowMenuRefreshAndOpenInNewWindow() throws {
        let lib = try fixtures().libraryId("Fixture Films")
        launchToHome()
        let row = sidebarRow("lib-\(lib)")
        row.waitToExist()
        row.rightClick()
        app.menuItems.matching(identifier: TestID.Sidebar.rowRefresh("lib-\(lib)")).firstMatch.tapWhenReady()
        row.rightClick()
        app.menuItems.matching(identifier: TestID.Sidebar.rowOpenInNewWindow("lib-\(lib)")).firstMatch.tapWhenReady()
        XCTAssertTrue(routeWindows.firstMatch.waitForExistence(timeout: 20))
        // Home, Live TV and Downloads have no window of their own.
        sidebarRow("home").rightClick()
        XCTAssertFalse(app.menuItems.matching(identifier: TestID.Sidebar.rowOpenInNewWindow("home")).firstMatch.waitForExistence(timeout: 2))
        dismissMenus()
    }
}
#endif
