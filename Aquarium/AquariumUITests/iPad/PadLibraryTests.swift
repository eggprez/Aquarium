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

    private func openFilms() throws -> String {
        let id = try fx.libraryId("Fixture Films")
        launchHome()
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
        _ = try openFilms()
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
        _ = try openFilms()
        app.button(TestID.Library.filterFavorites).padTap()
        XCTAssertTrue(cardButton(fav.id).waitForExistence(timeout: 20))
        XCTAssertTrue(cardButton(other.id).waitToVanish(20))
    }

    func testGenreMenuFilters() throws {
        let subs = try fx.item("film.sidecar_subs")   // genre Subtitles
        let direct = try fx.item("film.long_direct")  // genre Long Form
        _ = try openFilms()
        app.button(TestID.Library.genreMenu).padTap()
        let option = app.button(TestID.Library.genre("Subtitles"))
        option.padTap()
        XCTAssertTrue(cardButton(subs.id).waitForExistence(timeout: 20))
        XCTAssertTrue(cardButton(direct.id).waitToVanish(20))
        app.button(TestID.Library.genreMenu).padTap()
        app.button(TestID.Library.genreAll).padTap()
        XCTAssertTrue(cardButton(direct.id).waitForExistence(timeout: 20))
    }

    func testSortMenuAndReverse() throws {
        _ = try openFilms()
        app.button(TestID.Library.sortMenu).padTap()
        let options = app.elements(prefix: "library.sort.option.")
        XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 10), "sort options")
        let names = options.allElementsBoundByIndex.map(\.identifier)
        XCTAssertTrue(names.contains(where: { $0.hasSuffix(".name") || $0.contains("name") }), "\(names)")
        let reverse = app.button(TestID.Library.sortReverse)
        if reverse.exists {
            let before = cards().first?.identifier
            reverse.padTap()
            XCTAssertTrue(eventually(15) { self.cards().first?.identifier != before }, "the order turned round")
        } else {
            options.firstMatch.padTap()
        }
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
        XCTExpectFailure("bug: a collection shows none of its titles (master-fix-list iPad #7; 5209e95 not on main)", strict: false)
        XCTAssertTrue(opened, "FX Collection's titles")
    }
}

/// Photos (Fixture Photos: FX Album with a Nested album). "Photos still
/// unreachable" (master-fix-list.md iPad #8, TV, Pro Max #4); fixed on
/// claude/qa-fix-list-cb0b58 as 5209e95, not on main.
final class PadPhotosTests: PadUITestCase {
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
        let albumCard = cardButton(album)
        XCTAssertTrue(albumCard.waitForExistence(timeout: 30), "FX Album in Fixture Photos")
        albumCard.padTap()
        let opened = cardButton(photo).waitForExistence(timeout: 30)
        XCTExpectFailure("bug: photo albums open with no photos (master-fix-list iPad #8; 5209e95 not on main)", strict: false)
        XCTAssertTrue(opened, "a photo of FX Album in its grid")
        attachScreenshot("photo album")
    }
}
#endif
