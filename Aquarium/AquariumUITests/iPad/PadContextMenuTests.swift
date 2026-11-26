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
        for id in [TestID.Item.menuFavorite, TestID.Item.menuWatched,
                   TestID.Item.menuPlayFromBeginning, TestID.Item.menuDownload] {
            XCTAssertTrue(app.element(id).exists, "\(id) in the menu")
        }
        XCTAssertFalse(app.element(TestID.Item.menuOpenInNewWindow).exists, "a Mac's command, not an iPad's")
        // A card opens its title with a tap, so its menu has no Details.
        XCTAssertFalse(app.element(TestID.Item.menuDetails).exists)
        XCTAssertFalse(app.element(TestID.Item.menuDeleteFromServer).exists, "the test account may not delete from the server, so Delete from Server is not offered")
        attachScreenshot("film menu")
    }

    func testPlayFromTheMenuStartsThePlayer() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target))
        contextMenu(on: target, waitingFor: TestID.Item.menuPlay)
        app.button(TestID.Item.menuPlay).padTap()
        player.waitToExist(40)
        closePlayer()
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
        waitForPlaying()
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
        // The system draws a submenu's rows; by identifier, or by the words.
        let original = app.button(TestID.Item.menuDownloadQuality("original-quality"))
        XCTAssertTrue(original.waitForExistence(timeout: 10)
                      || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Original'")).firstMatch.exists,
                      "Original among the download qualities")
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
        // A longer hold than the shelves need: the grid's card carries the zoom
        // transition's source as well.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 2.5)
        let menu = app.button(TestID.Item.menuPlay).waitForExistence(timeout: 10)
        let opened = app.element(TestID.Detail.page(film.id)).exists
        attachScreenshot("grid card held")
        // 3 of 3 runs on 2026-11-13 (1.2 s and 2.5 s holds): the title opened
        // and no menu came, while the same hold on a Home shelf card gives
        // the menu. Checked by hand the same day: not an app bug. A real
        // 1.6 s touch on a Fixture Films grid card (simulator, upright) lifts
        // it and shows the menu, and grid and shelf cards apply the same
        // modifiers in the same order (`.posterZoomSource` then
        // `.itemContextMenu`, Components.swift `card` and `tile`). Only
        // XCUITest's press on the grid misses it; MANUAL.md has the check.
        XCTExpectFailure("XCUITest: its press on a library grid card opens the title; a real long press gives the menu", strict: false)
        XCTAssertFalse(opened, "holding a grid card opened the title instead of its menu")
        XCTAssertTrue(menu, "the menu on a library grid card")
        guard menu else { return }
        XCTAssertTrue(app.button(TestID.Item.menuFavorite).exists)
    }
}
#endif
