//  The press-and-hold menu every card carries, on an iPad: from Home's
//  shelves, a library grid and a season chip (whose menu is the way to the
//  season's page now that the poster is gone, ItemDetailView.padSeasonChip).
//  On an iPad with a pointer the same menu is a secondary click (MANUAL.md).

#if os(iOS)
import XCTest

final class PadContextMenuTests: PadUITestCase {
    func testFilmMenuHasThePlayAndLibraryActions() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuPlay)
        for id in [TestID.Item.menuDetails, TestID.Item.menuFavorite, TestID.Item.menuWatched,
                   TestID.Item.menuPlayFromBeginning, TestID.Item.menuDownload] {
            XCTAssertTrue(app.element(id).exists, "\(id) in the menu")
        }
        XCTAssertFalse(app.element(TestID.Item.menuOpenInNewWindow).exists, "a Mac's command, not an iPad's")
        attachScreenshot("film menu")
    }

    func testDetailsFromTheMenuOpensTheTitle() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuDetails)
        app.button(TestID.Item.menuDetails).padTap()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
    }

    func testFavoriteFromTheMenuReachesTheServer() throws {
        let film = try fx.item("film.long_direct")
        let api = try api()
        try api.setFavorite(film.id, false)
        launchHome()
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuFavorite)
        app.button(TestID.Item.menuFavorite).padTap()
        XCTAssertTrue(waitUntil(15, "favourite on the server") { (try? api.userData(film.id).favorite) == true })
        try api.setFavorite(film.id, false)
    }

    func testPlayFromBeginningStartsAtZero() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuPlayFromBeginning)
        app.button(TestID.Item.menuPlayFromBeginning).padTap()
        player.waitToExist(40)
        showControls()
        let start = elapsedSeconds() ?? 999
        XCTAssertLessThan(start, 60, "from the beginning, not the 5:00 resume point (read \(start) s)")
        closePlayer()
    }

    func testEpisodeMenuGoesToShowAndSeason() throws {
        let e2 = try episode("show.long", season: 1, episode: 2)
        let show = try fx.item("show.long")
        launchHome()
        let target = cardButton(e2.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuGoToShow)
        XCTAssertTrue(app.button(TestID.Item.menuGoToSeason).exists)
        XCTAssertTrue(app.button(TestID.Item.menuRemoveFromNextUp).exists || app.button(TestID.Item.menuWatched).exists)
        app.button(TestID.Item.menuGoToShow).padTap()
        app.element(TestID.Detail.page(show.id)).waitToExist(30)
    }

    func testSeasonChipMenuOpensTheSeasonsPage() throws {
        let show = try fx.item("show.long")
        let s2 = try season("show.long", 2)
        launchHome()
        openItem(show.id)
        let chip = app.button(TestID.Detail.season(s2))
        XCTAssertTrue(reveal(chip))
        contextMenu(on: chip, waitingFor: TestID.Item.menuDetails)
        app.button(TestID.Item.menuDetails).padTap()
        app.element(TestID.Detail.page(s2)).waitToExist(30)
    }

    func testDownloadSubmenuListsQualities() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuDownload)
        app.button(TestID.Item.menuDownload).padTap()
        XCTAssertTrue(app.button(TestID.Item.menuDownloadQuality("original-quality")).waitForExistence(timeout: 10))
        attachScreenshot("download submenu")
    }

    func testLibraryGridCardHasTheMenuToo() throws {
        let films = try fx.libraryId("Fixture Films")
        let film = try fx.item("film.hevc_mp4")
        launchHome()
        app.button(TestID.Sidebar.row("lib-\(films)")).waitToExist(30)
        showSection("lib-\(films)")
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuPlay)
        XCTAssertTrue(app.button(TestID.Item.menuFavorite).exists)
    }
}
#endif
