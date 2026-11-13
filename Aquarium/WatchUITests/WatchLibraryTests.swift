//  Every page and row of the library on the watch, against the QA server's
//  fixtures: Audiobooks and a book's page, Music and its five lists, an
//  album, an artist, a genre, a playlist, and Search.

import XCTest

final class WatchLibraryTests: WatchUITestCase {
    func testAudiobooksAndABooksPage() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        open(TestID.Watch.rootDoor("books"))
        app.element(TestID.Watch.booksRoot).waitToExist()
        open(TestID.Watch.book(book.id))
        app.element(TestID.Watch.bookRoot).waitToExist()
        XCTAssertEqual(text(TestID.Watch.bookTitle), "FX Chaptered Audiobook")
        XCTAssertEqual(text(TestID.Watch.bookAuthor), "FX Author")
        // suite-reset leaves it at 6:40 of 15m.
        let time = waitForText(TestID.Watch.bookTime) { $0.contains("of") }
        XCTAssertTrue(time.hasPrefix("6:40 of"), time)
        XCTAssertTrue(text(TestID.Watch.bookPlay).contains("Resume"))
        XCTAssertTrue(reach(app.element(TestID.Watch.bookStartOver)))
        XCTAssertTrue(reach(app.element(TestID.Watch.detailDownloadStart)), "Download to Watch")
        for i in 0..<6 {
            XCTAssertTrue(reach(app.element(TestID.Watch.bookChapter(i))), "chapter \(i + 1)")
        }
        attachScreenshot("book page")
    }

    func testTheAudiobooksSortStepsThroughItsOrders() throws {
        launchHome()
        open(TestID.Watch.rootDoor("books"))
        app.element(TestID.Watch.booksRoot).waitToExist()
        let sort = app.element(TestID.Watch.booksSort)
        guard sort.waitForExistence(timeout: 10) else { throw XCTSkip("no sort control on this layout") }
        for _ in 0..<3 {
            sort.tap()
            app.element(TestID.Watch.booksRoot).waitToExist()
        }
        XCTAssertGreaterThan(app.elements(prefix: "watch.library.book.").count, 0)
    }

    func testMusicHasItsFiveListsAndShuffleAll() {
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        app.element(TestID.Watch.musicRoot).waitToExist()
        for door in ["playlists", "albums", "artists", "songs", "genres"] {
            XCTAssertTrue(reach(app.element(TestID.Watch.musicDoor(door))), "no \(door)")
        }
        XCTAssertTrue(reach(app.element(TestID.Watch.musicShuffleAll)))
    }

    func testAnAlbumsPageListsItsSongsInOrder() throws {
        let album = try WatchFixtures.require().album("FX Compilation")
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("albums"))
        app.element(TestID.Watch.albumsRoot).waitToExist()
        open(TestID.Watch.album(album.id))
        app.element(TestID.Watch.collectionRoot).waitToExist()
        XCTAssertEqual(text(TestID.Watch.collectionTitle), "FX Compilation")
        app.element(TestID.Watch.detailPlay).waitToExist()
        app.element(TestID.Watch.detailShuffle).waitToExist()
        XCTAssertTrue(reach(app.element(TestID.Watch.detailDownloadStart)), "Download to Watch, above the songs")
        var lastY: CGFloat = -1
        for track in album.tracks {
            let row = app.element(TestID.Watch.song(track.id))
            XCTAssertTrue(reach(row), "no \(track.name)")
            XCTAssertGreaterThanOrEqual(row.frame.minY, lastY - 400, "rows in track order")
            lastY = row.frame.minY
        }
        attachScreenshot("album")
    }

    func testTheAlbumsListPagesAndSorts() throws {
        let album = try WatchFixtures.require().album("FX Two Discs")
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("albums"))
        app.element(TestID.Watch.albumsRoot).waitToExist()
        XCTAssertTrue(reach(app.element(TestID.Watch.album(album.id))))
        let sort = app.element(TestID.Watch.albumsSort)
        if sort.waitForExistence(timeout: 5) {
            sort.tap()
            app.element(TestID.Watch.album(album.id)).waitToExist(30)
        }
    }

    func testAnArtistsPageListsTheirAlbums() throws {
        let fx = try WatchFixtures.require()
        guard let band = fx.artists["FX Band"] else { throw XCTSkip("no FX Band") }
        let formats = try fx.album("FX Formats")
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("artists"))
        app.element(TestID.Watch.artistsRoot).waitToExist()
        open(TestID.Watch.artist(band))
        app.element(TestID.Watch.artistRoot).waitToExist()
        app.element(TestID.Watch.detailPlay).waitToExist()
        XCTAssertTrue(reach(app.element(TestID.Watch.album(formats.id))))
    }

    /// Regression, master-fix-list "Layout, all watches" (low): "Music >
    /// Artists lists the audiobook author Mary Shelley". On the QA server the
    /// audiobooks' author is FX Author. Fixed on claude/qa-fix-list-cb0b58
    /// (352c592: Artists is the music library's), not on this branch.
    func testArtistsAreTheMusicLibrarysNotTheAudiobooksAuthors() throws {
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("artists"))
        app.element(TestID.Watch.artistsRoot).waitToExist()
        XCTAssertTrue(app.elements(prefix: "watch.library.artist.").firstMatch.waitForExistence(timeout: 30))
        // The server's AlbumArtists, as the watch asks for them, includes
        // FX Author and Mary Shelley (checked 2026-11-13).
        let author = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "FX Author")).firstMatch
        reach(author, tries: 40)
        XCTExpectFailure("bug: Music > Artists lists the audiobook author (JellyfinClient.albumArtists has no music-library ParentId)")
        XCTAssertFalse(author.exists, "an audiobook's author is not a music artist")
    }

    /// Regression, master-fix-list "Layout, all watches": "Sort button floats
    /// over the third row of Albums and Audiobooks, hides its text and takes
    /// its taps". Fixed on claude/qa-fix-list-cb0b58 (352c592), not here.
    func testTheAudiobooksSortControlCoversNoRow() throws {
        launchHome()
        open(TestID.Watch.rootDoor("books"))
        app.element(TestID.Watch.booksRoot).waitToExist()
        let sort = app.element(TestID.Watch.booksSort)
        guard sort.waitForExistence(timeout: 10) else { throw XCTSkip("no sort control") }
        let rows = app.elements(prefix: "watch.library.book.")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        let covered = rows.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.intersects(sort.frame) }
        XCTExpectFailure("bug: the Audiobooks sort button sits over a row and takes its taps (LibraryViews.swift BooksView toolbar .bottomBar)",
                         options: .nonStrict())
        XCTAssertTrue(covered.isEmpty, "rows under the sort button: \(covered.map(\.identifier))")
    }

    func testSongsList() throws {
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("songs"))
        app.element(TestID.Watch.songsRoot).waitToExist()
        let rows = app.elements(prefix: "watch.library.song.")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertGreaterThanOrEqual(rows.count, 3, "a screenful of songs (the list draws only what is near)")
    }

    /// A genre's page, through the first row of Genres. (The QA server has
    /// 135 genres; FX Rock is the 60th, past where a test can scroll a
    /// watch list in reasonable time, so the first genre stands in.)
    func testAGenresPage() throws {
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("genres"))
        app.element(TestID.Watch.genresRoot).waitToExist()
        let first = app.elements(prefix: "watch.library.genre.").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "genres listed")
        open(first.identifier)
        app.element(TestID.Watch.collectionRoot).waitToExist()
        XCTAssertTrue(app.elements(prefix: "watch.library.song.").firstMatch.waitForExistence(timeout: 30), "the genre's songs")
    }

    func testAPlaylistsPage() throws {
        let fx = try WatchFixtures.require()
        guard let list = fx.playlists["FX Music Playlist"] else { throw XCTSkip("no FX Music Playlist") }
        launchHome()
        open(TestID.Watch.rootDoor("playlists"))
        app.element(TestID.Watch.playlistsRoot).waitToExist()
        open(TestID.Watch.playlist(list))
        app.element(TestID.Watch.collectionRoot).waitToExist()
        XCTAssertEqual(text(TestID.Watch.collectionTitle), "FX Music Playlist")
        let opener = try fx.album("FX Two Discs").tracks[0]
        XCTAssertTrue(reach(app.element(TestID.Watch.song(opener.id))), "Disc One Opener, first in the playlist")
    }

    func testSearchFindsAlbumsBooksAndSongs() throws {
        let fx = try WatchFixtures.require()
        let longTracks = try fx.album("FX Long Tracks")
        launchHome()
        open(TestID.Watch.rootDoor("search"))
        app.element(TestID.Watch.searchRoot).waitToExist()
        let field = app.element(TestID.Watch.searchField)
        field.tapWhenReady()
        // The watch's text entry sheet: type and return.
        let typed = app.textFields.firstMatch.waitForExistence(timeout: 5) || app.keyboards.firstMatch.waitForExistence(timeout: 5)
        guard typed else { throw XCTSkip("no keyboard on this watch simulator: search is checked by hand (MANUAL.md)") }
        app.typeText("FX Long\n")
        let result = app.element(TestID.Watch.album(longTracks.id))
        if !result.waitForExistence(timeout: 20) { reach(result, tries: 8) }
        if !result.exists {
            let value = (app.element(TestID.Watch.searchField).value as? String) ?? ""
            let anyResult = app.elements(prefix: "watch.library.").firstMatch.exists
            guard anyResult || value.contains("FX Long") else {
                throw XCTSkip("the watch's text entry didn't submit under XCUITest (field reads '\(value)'): search is checked by hand (MANUAL.md)")
            }
        }
        XCTAssertTrue(result.exists, "FX Long Tracks found")
        attachScreenshot("search")
    }
}
