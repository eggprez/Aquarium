//  Favorites on an iPad (the sidebar's You group) and the music pages a
//  sidebar reaches without More: playlists, the music search field, stations.

#if os(iOS)
import XCTest

final class PadFavoritesTests: PadUITestCase {
    func testFavoritesShowsTheBaselineAndFiltersByKind() throws {
        let film = try fx.item("film.hevc_mp4")          // favourite in the baseline
        let show = try fx.item("show.short")             // favourite series
        let episode = try episode("show.long", season: 2, episode: 1)
        launchHome()
        showSection("favorites")
        app.element(TestID.Favorites.root).waitToExist(20)
        let films = cardButton(film.id)
        XCTAssertTrue(films.waitForExistence(timeout: 30))
        XCTAssertTrue(cardButton(show.id).exists)
        app.button(TestID.Favorites.kind("Series")).padTap()
        XCTAssertTrue(films.waitToVanish(15), "Shows alone")
        XCTAssertTrue(cardButton(show.id).exists)
        app.button(TestID.Favorites.kind("Episode")).padTap()
        XCTAssertTrue(cardButton(episode.id).waitForExistence(timeout: 15))
        app.button(TestID.Favorites.kind("Movie")).padTap()
        XCTAssertTrue(films.waitForExistence(timeout: 15))
        attachScreenshot("favorites")
    }

    func testFavoriteAddedOnATitleAppearsHere() throws {
        let film = try fx.item("film.pcm_mov")
        let api = try api()
        try api.setFavorite(film.id, false)
        launchHome()
        openItem(film.id)
        app.button(TestID.Detail.favorite).padTap()
        XCTAssertTrue(waitUntil(15, "the favourite on the server") { (try? api.userData(film.id).favorite) == true })
        showSection("favorites")
        XCTAssertTrue(cardButton(film.id).waitForExistence(timeout: 30),
                      "Favorites reloads with the new one (2c20fe6: ItemMutations)")
        try api.setFavorite(film.id, false)
    }
}

final class PadMusicPagesTests: PadUITestCase {
    private func openLibraryDoor(_ door: String) {
        launchHome()
        showSection("music")
        let picker = app.segmentedControls[TestID.Music.pagePicker]
        if picker.waitForExistence(timeout: 10) { picker.buttons["Library"].padTap() }
        app.button(TestID.Music.libraryDoor(door)).padTap()
    }

    func testPlaylistsListTheSuitesOwnAndThePublicOnes() {
        openLibraryDoor("playlists")
        app.element(TestID.Playlists.root).waitToExist(30)
        XCTAssertTrue(app.staticTexts["FX Music Playlist"].waitForExistence(timeout: 20)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS 'FX Music Playlist'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'suite-ipad Playlist'")).firstMatch.waitForExistence(timeout: 10)
                      || app.staticTexts["suite-ipad Playlist"].exists, "the suite's own playlist")
        XCTAssertTrue(app.element(TestID.SmartPlaylists.heading).exists || app.button(TestID.SmartPlaylists.new).exists)
    }

    func testArtistsAndGenresDoors() {
        openLibraryDoor("artists")
        app.element(TestID.Music.artists).waitToExist(30)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'FX Band'")).firstMatch.waitForExistence(timeout: 20))
        app.navigationBars.buttons.firstMatch.padTap()
        app.button(TestID.Music.libraryDoor("genres")).padTap()
        app.element(TestID.Music.genres).waitToExist(30)
    }

    func testMusicSearchFieldFindsAnAlbum() {
        launchHome()
        showSection("music")
        let field = app.textFields[TestID.Music.searchField]
        field.padTap(30)
        field.typeText("Two Discs")
        app.element(TestID.Music.searchResults).waitToExist(30)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'FX Two Discs'")).firstMatch.waitForExistence(timeout: 20))
    }

    func testDiscoverHasStationsAndShuffle() {
        launchHome()
        showSection("music")
        app.element(TestID.Music.listenNow).waitToExist(30)
        XCTAssertTrue(app.button(TestID.Music.shuffleAll).waitForExistence(timeout: 20), "Shuffle all")
        XCTAssertTrue(reveal(app.element(TestID.Stations.shelf), maxSwipes: 8), "Your Stations")
    }
}
#endif
