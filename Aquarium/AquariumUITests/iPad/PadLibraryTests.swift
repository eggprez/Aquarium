//  A library on an iPad: the pinned glass header with the count, the filter
//  chips and the iPad's own name search (Deep Water, eff49a1); the grid in
//  both orientations; collections; photos.

#if os(iOS)
import XCTest

final class PadLibraryTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    /// Fixture Films. `wide` turns the iPad on its side first: upright, the
    /// 610-point column puts the name field over the end of the chip strip
    /// (Favorites and Genre sit under it until the strip is swiped).
    private func openFilms(wide: Bool = false) throws -> String {
        let id = try fx.libraryId("Fixture Films")
        launchHome()
        if wide { turn(.landscapeLeft) }
        app.button(TestID.Sidebar.row("lib-\(id)")).waitToExist(30)
        showSection("lib-\(id)")
        app.element(TestID.Library.grid).waitToExist(30)
        return id
    }

    private func cards() -> [XCUIElement] {
        app.elements(prefix: "item.card.").allElementsBoundByIndex
    }

    func testGridAndCountInTheHeader() throws {
        _ = try openFilms()
        let count = app.element(TestID.Library.count)
        count.waitToExist(20)
        XCTAssertNotNil(count.label.range(of: #"\d+"#, options: .regularExpression), "count reads \(count.label)")
        XCTAssertTrue(app.element(TestID.Library.filters).exists, "the filter chips")
        XCTAssertGreaterThan(cards().count, 4)
    }

    func testGridHasMoreColumnsInLandscape() throws {
        _ = try openFilms()
        let first = app.elements(prefix: "item.card.").firstMatch
        first.waitToExist(20)
        func perRow() -> Int {
            let all = cards().filter { $0.frame.width > 40 }
            guard let top = all.map(\.frame.minY).min() else { return 0 }
            return all.filter { abs($0.frame.minY - top) < 4 }.count
        }
        let portrait = perRow()
        turn(.landscapeLeft)
        XCTAssertTrue(eventually(10) { perRow() > portrait }, "landscape \(perRow()) vs portrait \(portrait) across")
        attachScreenshot("grid landscape")
    }

    func testSearchFieldFiltersByName() throws {
        let films = try fx
        let unicode = try films.item("film.unicode_title")
        let direct = try films.item("film.long_direct")
        _ = try openFilms()
        let field = app.textFields[TestID.Library.searchField]
        field.padTap()
        field.typeText("Unicode")
        XCTAssertTrue(cardButton(unicode.id).waitForExistence(timeout: 20))
        XCTAssertTrue(cardButton(direct.id).waitToVanish(20),
                      "other films filtered out")
        app.button(TestID.Library.searchClear).padTap()
        XCTAssertTrue(cardButton(direct.id).waitForExistence(timeout: 20))
    }

    func testUnwatchedFilterHidesPlayedFilms() throws {
        let played = try fx.item("film.rated_g")      // played in the baseline
        _ = try openFilms(wide: true)
        let field = app.textFields[TestID.Library.searchField]
        field.padTap()
        field.typeText("Rated G")
        cardButton(played.id).waitToExist(20)
        app.button(TestID.Library.filterUnwatched).padTap()
        XCTAssertTrue(cardButton(played.id).waitToVanish(20))
        app.button(TestID.Library.filterUnwatched).padTap()
        XCTAssertTrue(cardButton(played.id).waitForExistence(timeout: 20))
    }

    func testFavoritesFilter() throws {
        let fav = try fx.item("film.hevc_mp4")        // a favourite in the baseline
        let other = try fx.item("film.pcm_mov")
        _ = try openFilms(wide: true)
        app.button(TestID.Library.filterFavorites).padTap()
        XCTAssertTrue(cardButton(fav.id).waitForExistence(timeout: 20))
        XCTAssertTrue(cardButton(other.id).waitToVanish(20))
    }

    func testGenreMenuFilters() throws {
        let subs = try fx.item("film.sidecar_subs")   // genre Subtitles
        let direct = try fx.item("film.long_direct")  // genre Long Form
        _ = try openFilms(wide: true)
        app.button(TestID.Library.genreMenu).padTap()
        menuItem(TestID.Library.genre("Subtitles"), label: "Subtitles").padTap()
        XCTAssertTrue(cardButton(subs.id).waitForExistence(timeout: 20))
        XCTAssertTrue(cardButton(direct.id).waitToVanish(20))
        app.button(TestID.Library.genreMenu).padTap()
        menuItem(TestID.Library.genreAll, label: "All genres").padTap()
        XCTAssertTrue(cardButton(direct.id).waitForExistence(timeout: 20))
    }

    /// The sort chip's menu. Reverse Order is the Mac's alone.
    func testSortMenu() throws {
        _ = try openFilms(wide: true)
        let chip = app.button(TestID.Library.sortMenu)
        chip.padTap()
        let release = menuItem(TestID.Library.sortOption("releaseDate"), label: "Release Date")
        XCTAssertTrue(release.waitForExistence(timeout: 10), "sort options")
        XCTAssertTrue(menuItem(TestID.Library.sortOption("name"), label: "Name").exists)
        release.padTap()
        XCTAssertTrue(waitUntil(10, "the chip to name the sort") { chip.label.contains("Release Date") })
        XCTAssertFalse(app.button(TestID.Library.sortReverse).exists, "no Reverse Order on an iPad")
    }

    /// Upright the chip strip runs under the name field; every chip can
    /// still be reached by swiping the strip.
    func testEveryFilterChipCanBeReachedUpright() throws {
        _ = try openFilms()
        let favorites = app.button(TestID.Library.filterFavorites)
        let field = app.textFields[TestID.Library.searchField]
        favorites.waitToExist(20)
        if favorites.frame.maxX > field.frame.minX {
            app.button(TestID.Library.filterUnwatched).swipeLeft()
        }
        XCTAssertTrue(waitUntil(5, "Favorites clear of the name field") {
            favorites.frame.maxX <= field.frame.minX + 1 && favorites.frame.minX >= self.sidebar.frame.maxX
        }, "Favorites \(favorites.frame) under the field \(field.frame)")
        attachScreenshot("chips upright")
    }

    func testCardOpensTitleAndBackReturnsToTheGrid() throws {
        let direct = try fx.item("film.long_direct")
        let id = try openFilms()
        let card = cardButton(direct.id)
        XCTAssertTrue(reveal(card))
        card.padTap()
        app.element(TestID.Detail.page(direct.id)).waitToExist(30)
        app.button(TestID.Detail.back).padTap()
        app.element(TestID.Library.page(id)).waitToExist(20)
    }

    func testShowsLibraryOpensASeries() throws {
        let shows = try fx.libraryId("Fixture Shows")
        let show = try fx.item("show.long")
        launchHome()
        app.button(TestID.Sidebar.row("lib-\(shows)")).waitToExist(30)
        showSection("lib-\(shows)")
        let card = cardButton(show.id)
        XCTAssertTrue(reveal(card))
        card.padTap()
        app.element(TestID.Detail.page(show.id)).waitToExist(30)
    }

    /// 56a1825: "Jellyfin's box sets get a section of their own … a sidebar
    /// row on iPad". FX Collection holds four titles.
    func testCollectionsSectionListsFXCollection() throws {
        let set = try fx.raw["sets"] as? [String: Any]
        guard let collection = set?["FX Collection"] as? [String: Any], let id = collection["id"] as? String,
              let items = collection["items"] as? [[String: Any]] else { throw XCTSkip("no FX Collection") }
        launchHome()
        let row = app.button(TestID.Sidebar.row("collections"))
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a Collections row")
        showSection("collections")
        let card = cardButton(id)
        XCTAssertTrue(reveal(card), "FX Collection's card")
        card.padTap()
        // A collection opens as a grid of what is in it.
        let first = items.compactMap { $0["id"] as? String }.first ?? ""
        let opened = cardButton(first).waitForExistence(timeout: 30)
        XCTAssertTrue(opened, "FX Collection's titles")
    }
}

/// Photos (Fixture Photos: FX Album with a Nested album). "Photos still
/// unreachable" (master-fix-list.md iPad #8, TV, Pro Max #4); fixed on
/// claude/qa-fix-list-cb0b58 as 5209e95, not on main.
final class PadPhotosTests: PadUITestCase {
    /// ipad-qa-findings.md "raw folder names 'home', 'photos' with a film
    /// icon" (fixed on claude/qa-fix-list-cb0b58, not on main): Fixture
    /// Photos lists its folder by the folder's name on disk.
    func testPhotoFolderIsNotShownByItsRawFolderName() throws {
        let photos = try fx.libraryId("Fixture Photos")
        launchHome()
        app.button(TestID.Sidebar.row("lib-\(photos)")).waitToExist(30)
        showSection("lib-\(photos)")
        app.element(TestID.Library.grid).waitToExist(30)
        let raw = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item.card.' AND label BEGINSWITH 'photos'")).firstMatch
        _ = raw.waitForExistence(timeout: 15)
        attachScreenshot("fixture photos")
        XCTAssertFalse(raw.exists, "card reads \(raw.label)")
    }

    func testPhotoAlbumOpensAsAGridOfPhotos() throws {
        let photos = try fx.libraryId("Fixture Photos")
        guard let list = try fx.raw["fixtures"] as? [String: Any],
              let entries = list["photos"] as? [[String: Any]],
              let album = entries.first(where: { $0["name"] as? String == "FX Album" })?["id"] as? String,
              let photo = entries.first(where: { $0["type"] as? String == "Photo" && ($0["path"] as? String ?? "").contains("FX Album/") && !($0["path"] as? String ?? "").contains("Nested") })?["id"] as? String
        else { throw XCTSkip("no FX Album in fixtures.json") }
        launchHome()
        app.button(TestID.Sidebar.row("lib-\(photos)")).waitToExist(30)
        showSection("lib-\(photos)")
        // The library's top level is FX Home Clip and the folder FX Album
        // lives in (shown by its folder name), then the album.
        var albumCard = cardButton(album)
        if !albumCard.waitForExistence(timeout: 15) {
            let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item.card.' AND label BEGINSWITH[c] 'photos'")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10), "the folder holding FX Album")
            folder.padTap()
            albumCard = cardButton(album)
        }
        // Until claude/fix-tv the folder opened as a title page (detail.page),
        // not a grid, so FX Album was never reached.
        guard albumCard.waitForExistence(timeout: 20) else {
            attachScreenshot("folder opened")
            XCTFail("FX Album in Fixture Photos (the folder opened as \(app.elements(prefix: "detail.page.").firstMatch.identifier))")
            return
        }
        albumCard.padTap()
        XCTAssertTrue(cardButton(photo).waitForExistence(timeout: 30), "a photo of FX Album in its grid")
        attachScreenshot("photo album")
    }
}
#endif
