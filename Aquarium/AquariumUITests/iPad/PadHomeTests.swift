//  Home on an iPad: the edge-to-edge hero with a white Resume and, on its
//  side, thumbnails instead of dots (Deep Water, eff49a1); the shelves; the
//  library chip strip in place of My Media tiles; Search and Refresh in the
//  floating bar.

#if os(iOS)
import XCTest

final class PadHomeTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    /// The hero's pages, left to right.
    private func heroPages() -> [XCUIElement] {
        app.elements(prefix: "home.hero.page.").allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func heroItemIds() -> [String] {
        heroPages().map { String($0.identifier.dropFirst("home.hero.page.".count)) }
    }

    /// The page on screen: the one under the middle of the hero. The bar
    /// turns every 8 s, so this is read just before it is used.
    private func visibleHeroId() -> String {
        let hero = app.element(TestID.Home.hero)
        hero.waitToExist(30)
        app.elements(prefix: "home.hero.page.").firstMatch.waitToExist(30)
        let mid = hero.frame.midX
        let page = heroPages().first { $0.frame.minX <= mid && $0.frame.maxX >= mid } ?? heroPages().first
        return page.map { String($0.identifier.dropFirst("home.hero.page.".count)) } ?? ""
    }

    func testHeroShowsWithPlayAndDetails() {
        launchHome()
        app.element(TestID.Home.hero).waitToExist(30)
        let id = visibleHeroId()
        XCTAssertTrue(app.button(TestID.Home.heroPlay(id)).waitForExistence(timeout: 10))
        XCTAssertTrue(app.button(TestID.Home.heroDetails(id)).exists)
        attachScreenshot("hero portrait")
    }

    func testHeroIsEdgeToEdgeAtTwoPointFourToOne() {
        launchHome()
        turn(.landscapeLeft)
        let hero = app.element(TestID.Home.hero)
        hero.waitToExist(30)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(waitUntil(10, "hero to lay out") { hero.frame.width > 0 })
        // The hero runs under the sidebar to the screen's far edge.
        XCTAssertEqual(hero.frame.maxX, window.maxX, accuracy: 2, "hero reaches the trailing edge")
        let ratio = hero.frame.width / hero.frame.height
        XCTAssertGreaterThan(ratio, 1.6, "a band, not a box: \(hero.frame)")
        attachScreenshot("hero landscape")
    }

    /// Thumbnails where there is room (an iPad on its side, width >= 900),
    /// dots elsewhere (HomeView.swift HeroCarousel.pageThumbs).
    func testThumbnailsInLandscapeDotsInPortrait() throws {
        launchHome()
        app.elements(prefix: "home.hero.page.").firstMatch.waitToExist(30)
        let ids = heroItemIds()
        try XCTSkipIf(ids.count < 2, "the hero has one page today")
        turn(.landscapeLeft)
        let thumb = app.button(TestID.Home.heroThumb(ids[1]))
        XCTAssertTrue(thumb.waitForExistence(timeout: 15), "thumbnails in landscape")
        turn(.portrait)
        XCTAssertTrue(thumb.waitToVanish(10), "no thumbnails upright on an 11-inch iPad")
        XCTAssertTrue(app.elements(prefix: "home.hero.currentPage.").firstMatch.exists, "dots in portrait")
    }

    func testThumbnailTurnsTheHeroToItsPage() throws {
        launchHome()
        turn(.landscapeLeft)
        app.elements(prefix: "home.hero.page.").firstMatch.waitToExist(30)
        let ids = heroItemIds()
        try XCTSkipIf(ids.count < 3, "fewer than three hero pages")
        app.button(TestID.Home.heroThumb(ids[2])).padTap()
        app.element(TestID.Home.heroCurrentPage(2)).waitToExist(10)
        XCTAssertTrue(app.button(TestID.Home.heroThumb(ids[2])).isSelected)
    }

    func testSwipingTheHeroTurnsThePage() throws {
        launchHome()
        app.elements(prefix: "home.hero.page.").firstMatch.waitToExist(30)
        try XCTSkipIf(heroItemIds().count < 2, "one hero page")
        // The bar turns by itself every 8 s, so this reads where it is and
        // waits for the next page, which the swipe brings at once.
        let current = app.elements(prefix: "home.hero.currentPage.").firstMatch
        current.waitToExist(10)
        let before = current.identifier
        app.element(TestID.Home.hero).swipeLeft()
        XCTAssertTrue(waitUntil(5, "the hero to turn") {
            let now = self.app.elements(prefix: "home.hero.currentPage.").firstMatch
            return now.exists && now.identifier != before
        })
    }

    func testHeroDetailsOpensTheTitle() {
        launchHome()
        let id = visibleHeroId()
        app.button(TestID.Home.heroDetails(id)).padTap()
        app.element(TestID.Detail.root).waitToExist(30)
    }

    func testHeroPlayStartsThePlayer() {
        launchHome()
        let id = visibleHeroId()
        app.button(TestID.Home.heroPlay(id)).padTap()
        player.waitToExist(40)
        closePlayer()
    }

    func testContinueWatchingAndNextUpShelves() throws {
        let fx = try fx
        let film = try fx.item("film.long_direct")
        let e2 = try episode("show.long", season: 1, episode: 2)
        launchHome()
        let resume = app.element(TestID.Home.shelf(TestID.Home.rowResume))
        XCTAssertTrue(reveal(resume), "Continue Watching is on Home")
        XCTAssertTrue(cardButton(film.id).waitForExistence(timeout: 10),
                      "the baseline's film in progress")
        XCTAssertTrue(cardButton(e2.id).exists, "Long Show S01E02 in progress")
        let nextUp = app.element(TestID.Home.shelf(TestID.Home.rowNextUp))
        XCTAssertTrue(reveal(nextUp), "Next Up is on Home")
        attachScreenshot("shelves")
    }

    func testLatestShelfPerLibrary() throws {
        let films = try fx.libraryId("Fixture Films")
        launchHome()
        let latest = app.element(TestID.Home.shelf(TestID.Home.rowLatest(films)))
        XCTAssertTrue(reveal(latest, maxSwipes: 20), "Latest in Fixture Films")
    }

    /// Deep Water replaced My Media tiles with a strip of library chips.
    func testLibraryChipsOpenALibrary() throws {
        let films = try fx.libraryId("Fixture Films")
        launchHome()
        let chip = app.button(TestID.Library.chip(films))
        XCTAssertTrue(reveal(chip), "a chip for Fixture Films")
        chip.padTap()
        app.element(TestID.Library.page(films)).waitToExist(30)
    }

    func testShelfSeeAllOpensTheWholeRow() throws {
        let films = try fx.libraryId("Fixture Films")
        launchHome()
        let seeAll = app.button(TestID.Home.shelfSeeAll(TestID.Home.rowLatest(films)))
        try XCTSkipUnless(reveal(seeAll, maxSwipes: 20), "Latest in Fixture Films has no See All")
        seeAll.padTap()
        app.element(TestID.Library.root).waitToExist(30)
    }

    func testRefreshAndSearchInTheFloatingBar() {
        launchHome()
        app.button(TestID.Home.refresh).padTap()
        app.element(TestID.Home.root).waitToExist(30)
        app.button(TestID.Home.search).padTap()
        app.element(TestID.Search.root).waitToExist(20)
    }

    func testCardOpensItsTitle() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let card = cardButton(film.id)
        XCTAssertTrue(reveal(card))
        card.padTap()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
    }

    func testLiveTVAndMusicShelvesOnHome() {
        launchHome()
        let live = app.element(TestID.Home.shelf(TestID.Home.rowLiveTV))
        XCTAssertTrue(reveal(live, maxSwipes: 25), "On Now: the QA server's channels")
        let music = app.element(TestID.Home.shelf(TestID.Home.rowMusicRecent))
        let newMusic = app.element(TestID.Home.shelf(TestID.Home.rowMusicNew))
        XCTAssertTrue(reveal(music, maxSwipes: 25) || reveal(newMusic, maxSwipes: 25), "a music shelf on Home")
    }

    func testHomeInBothOrientations() {
        launchHome()
        for o in [UIDeviceOrientation.landscapeLeft, .portrait] {
            turn(o)
            app.element(TestID.Home.hero).waitToExist(20)
            XCTAssertTrue(app.element(TestID.Home.root).exists)
            attachScreenshot("home \(o.isLandscape ? "landscape" : "portrait")")
        }
    }
}
#endif
