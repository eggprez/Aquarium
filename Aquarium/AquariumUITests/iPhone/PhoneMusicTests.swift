//  Music on the phone: Discover and Library, an album (discs, codecs), an
//  artist, playing a song (mini player, Now Playing, queue, shuffle,
//  repeat, lyrics, favourite, next on the last track), Instant Mix and
//  stations, playlists and smart playlists, music search; and audiobooks.

#if os(iOS)
import XCTest

class PhoneMusicTestCase: PhoneUITestCase {
    func openMusic(file: StaticString = #filePath, line: UInt = #line) {
        tab("Music", file: file, line: line)
        app.element(TestID.Music.root).waitToExist(30, file: file, line: line)
    }

    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// An album's page from Music › Library › Albums.
    func openAlbum(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let album = try XCTUnwrap(PhoneFixtures.album(name), file: file, line: line)
        let id = try XCTUnwrap(album["id"] as? String)
        openMusic(file: file, line: line)
        let field = app.textFields[TestID.Music.searchField]
        field.tapNow(20, file: file, line: line)
        field.typeText(name)
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", [TestID.Music.card(id), TestID.Music.row(id)])).firstMatch
        card.tapNow(30, file: file, line: line)
        app.element(TestID.Music.album).waitToExist(30, file: file, line: line)
        return album
    }

    func tracks(_ album: [String: Any]) -> [String] {
        (album["tracks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Plays a song from an album page and waits for the mini player.
    func playSong(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = any(TestID.Music.song(id))
        app.reveal(row)
        row.tapNow(20, file: file, line: line)
        app.element(TestID.MiniPlayer.root).waitToExist(30, file: file, line: line)
    }

    func openNowPlaying(file: StaticString = #filePath, line: UInt = #line) {
        any(TestID.MiniPlayer.expand).tapNow(20, file: file, line: line)
        app.element(TestID.NowPlaying.root).waitToExist(20, file: file, line: line)
    }
}

final class PhoneMusicTests: PhoneMusicTestCase {
    func testDiscoverShowsTheShelves() throws {
        launchHome()
        openMusic()
        app.element(TestID.Music.listenNow).waitToExist(30)
        any(TestID.Music.greeting).waitToExist(10)
        assertOnScreen(any(TestID.Music.shuffleAll), "Shuffle All")
        any(TestID.Music.shelf("new-in-your-library")).waitToExist(20)
        any(TestID.Stations.shelf).waitToExist(20)
        // Regression R-b4d8347: the search field must be visible without pulling down.
        assertOnScreen(app.textFields[TestID.Music.searchField], "music search field")
        attachScreenshot("music discover (\(device.rawValue))")
    }

    func testLibraryDoorsOpenEveryList() throws {
        try standardOnly()
        launchHome()
        openMusic()
        any(TestID.Music.page("library")).tapNow(10)
        app.element(TestID.Music.library).waitToExist(20)
        let roots = ["artists": TestID.Music.artists, "albums": TestID.Music.albums, "songs": TestID.Music.songs,
                     "genres": TestID.Music.genres, "playlists": TestID.Playlists.root, "favorites": TestID.Music.favorites]
        for (door, root) in roots {
            let d = any(TestID.Music.libraryDoor(door))
            app.reveal(d)
            d.tapNow(10)
            XCTAssertTrue(app.element(root).waitForExistence(timeout: 20), "\(door) did not open")
            goBack()
            app.element(TestID.Music.library).waitToExist(10)
        }
    }

    /// Reported by the Watch fixer (2026-11-13): `/Artists/AlbumArtists`
    /// with no music scope lists audiobook authors (FX Author, Mary Shelley)
    /// among Music › Artists. `MusicLibraryView.swift:219` asks the same way.
    func testArtistsListHasNoAudiobookAuthors() throws {
        launchHome()
        openMusic()
        any(TestID.Music.page("library")).tapNow(10)
        any(TestID.Music.libraryDoor("artists")).tapNow(10)
        app.element(TestID.Music.artists).waitToExist(20)
        let band = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'FX Band'")).firstMatch
        for _ in 0..<8 where !band.exists { app.swipeUp() }
        // Walk the whole list (it is short) looking for the authors.
        var seen = Set<String>()
        for _ in 0..<12 {
            for e in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'music.row.' OR identifier BEGINSWITH 'music.card.'")).allElementsBoundByIndex {
                seen.insert(e.label)
            }
            app.swipeUp()
        }
        let authors = seen.filter { $0.hasPrefix("FX Author") || $0.hasPrefix("Mary Shelley") }
        XCTExpectFailure("bug: Music › Artists lists audiobook authors (albumArtists called with no music scope)", options: .nonStrict())
        XCTAssertTrue(authors.isEmpty, "authors listed as artists: \(authors.sorted())")
    }

    func testSongsSortMenu() throws {
        try standardOnly()
        launchHome()
        openMusic()
        any(TestID.Music.page("library")).tapNow(10)
        any(TestID.Music.libraryDoor("songs")).tapNow(10)
        app.element(TestID.Music.songs).waitToExist(20)
        any(TestID.Music.sortMenu).tapNow(10)
        menuItem(TestID.Music.sortOption(MusicSortKeys.name), label: "Title").tapNow(10)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "music.song.")).firstMatch.waitForExistence(timeout: 20))
    }

    /// FX Two Discs: two discs, six songs.
    func testAlbumGroupsItsDiscs() throws {
        launchHome()
        let album = try openAlbum("FX Two Discs")
        any(TestID.Music.albumDisc(1)).waitToExist(20)
        app.reveal(any(TestID.Music.albumDisc(2)))
        XCTAssertTrue(any(TestID.Music.albumDisc(2)).exists)
        XCTAssertEqual(tracks(album).count, 6)
        assertOnScreen(any(TestID.Music.playBarPlay), "Play")
        assertOnScreen(any(TestID.Music.playBarShuffle), "Shuffle")
        attachScreenshot("album (\(device.rawValue))")
    }

    func testPlayingASongShowsTheMiniPlayerAndReportsIt() throws {
        let api = try self.api
        launchHome()
        let album = try openAlbum("FX Long Tracks")
        let first = try XCTUnwrap(tracks(album).first)
        playSong(first)
        XCTAssertNotNil(try api.waitForPlayback(of: first, timeout: 40), "the server never heard the song")
        assertOnScreen(app.element(TestID.MiniPlayer.root), "mini player")
        // Regression R-db310b3-a11y: the mini player's forward is "Next".
        XCTAssertEqual(any(TestID.MiniPlayer.next).label, "Next")
    }

    func testMiniPlayerPlayPause() throws {
        try standardOnly()
        let api = try self.api
        launchHome()
        let album = try openAlbum("FX Long Tracks")
        let first = try XCTUnwrap(tracks(album).first)
        playSong(first)
        _ = try api.waitForPlayback(of: first, timeout: 40)
        any(TestID.MiniPlayer.playPause).tapNow(10)
        XCTAssertTrue(eventually(timeout: 30) { (try? api.sessions().first { $0.nowPlayingId == first }?.isPaused) == true })
    }

    func testNowPlayingControls() throws {
        let api = try self.api
        launchHome()
        let album = try openAlbum("FX Formats")
        let ids = tracks(album)
        playSong(ids[0])
        openNowPlaying()
        for id in [TestID.NowPlaying.title, TestID.NowPlaying.playPause, TestID.NowPlaying.next, TestID.NowPlaying.previous,
                   TestID.NowPlaying.shuffle, TestID.NowPlaying.repeatMode, TestID.NowPlaying.scrubber, TestID.NowPlaying.queue] {
            assertOnScreen(any(id), id)
        }
        attachScreenshot("now playing (\(device.rawValue))")
        any(TestID.NowPlaying.next).tap()
        XCTAssertNotNil(try api.waitForPlayback(of: ids[1], timeout: 30), "Next did not go to the second song")
        any(TestID.NowPlaying.shuffle).tap()
        any(TestID.NowPlaying.repeatMode).tap()
        any(TestID.NowPlaying.close).tapNow(10)
        XCTAssertTrue(app.element(TestID.NowPlaying.root).waitToVanish(10))
    }

    func testQueueListsWhatComesNext() throws {
        try standardOnly()
        launchHome()
        let album = try openAlbum("FX Formats")
        let ids = tracks(album)
        playSong(ids[0])
        openNowPlaying()
        any(TestID.NowPlaying.queue).tapNow(10)
        app.element(TestID.NowPlaying.queueRoot).waitToExist(10)
        any(TestID.NowPlaying.queueRow(ids[1])).waitToExist(10)
        any(TestID.NowPlaying.queueRow(ids[1])).tap()
        XCTAssertNotNil(try self.api.waitForPlayback(of: ids[1], timeout: 30))
    }

    /// Regression R-f72bd13a: Next on the last song kept playing.
    func testNextOnTheLastSongStops() throws {
        try standardOnly()
        launchHome()
        let album = try openAlbum("FX Long Tracks")
        let last = try XCTUnwrap(tracks(album).last)
        playSong(last)
        openNowPlaying()
        let next = any(TestID.NowPlaying.next)
        next.waitToExist(10)
        // Either Next is off on the last song (nothing to go to), or it
        // stops / moves on. It must never start the last song again.
        if !next.isEnabled { return }
        next.tap()
        let api = try self.api
        XCTAssertTrue(eventually(timeout: 20) {
            guard let s = PhoneSessions.current(api, last) else { return true }
            return s.isPaused == true || (s.positionSeconds ?? 0) > 5
        }, "Next on the last song restarted it")
    }

    /// Disc One Opener has synced lyrics (6 lines); Disc One Middle plain.
    func testSyncedLyrics() throws {
        launchHome()
        _ = try openAlbum("FX Two Discs")
        let song = try XCTUnwrap(PhoneFixtures.track("Disc One Opener"))
        playSong(song)
        openNowPlaying()
        any(TestID.NowPlaying.lyrics).tapNow(10)
        app.element(TestID.Lyrics.root).waitToExist(20)
        any(TestID.Lyrics.line("0")).waitToExist(20)
        any(TestID.Lyrics.line("2")).tap()
        attachScreenshot("lyrics (\(device.rawValue))")
    }

    func testFavouriteFromNowPlayingReachesTheServer() throws {
        try standardOnly()
        let api = try self.api
        let song = try XCTUnwrap(PhoneFixtures.track("MP3 VBR"))
        try api.setFavorite(song, false)
        addTeardownBlock { try? api.setFavorite(song, false) }
        launchHome()
        _ = try openAlbum("FX Formats")
        playSong(song)
        openNowPlaying()
        any(TestID.NowPlaying.favorite).tapNow(10)
        XCTAssertTrue(eventually(timeout: 20) { (try? api.userData(song).favorite) == true })
    }

    func testInstantMixFromNowPlaying() throws {
        try standardOnly()
        let api = try self.api
        launchHome()
        _ = try openAlbum("FX Two Discs")
        let song = try XCTUnwrap(PhoneFixtures.track("Disc One Opener"))
        playSong(song)
        openNowPlaying()
        let mix = any(TestID.NowPlaying.instantMix)
        mix.tapNow(10)
        XCTAssertNotNil(try api.waitForPlayback(timeout: 30))
    }

    func testStationFromDiscover() throws {
        try standardOnly()
        let api = try self.api
        launchHome()
        openMusic()
        let station = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "stations.card.")).firstMatch
        station.tapNow(30)
        XCTAssertNotNil(try api.waitForPlayback(timeout: 40), "station never played")
        openNowPlaying()
        let leanings = any(TestID.NowPlaying.leanings)
        if leanings.waitForExistence(timeout: 5) {
            leanings.tap()
            app.element(TestID.Stations.leanings).waitToExist(10)
        }
    }

    func testShuffleAll() throws {
        try standardOnly()
        launchHome()
        openMusic()
        any(TestID.Music.shuffleAll).tapNow(20)
        app.element(TestID.MiniPlayer.root).waitToExist(30)
    }

    func testSongMenuOffersItsActions() throws {
        try standardOnly()
        launchHome()
        let album = try openAlbum("FX Formats")
        let id = try XCTUnwrap(tracks(album).first)
        any(TestID.Music.songMore(id)).tapNow(10)
        for item in [TestID.Music.menuPlayNext, TestID.Music.menuPlayLater, TestID.Music.menuStartStation,
                     TestID.Music.menuSongInfo, TestID.Music.menuFavorite, TestID.Music.menuAddToPlaylist] {
            XCTAssertTrue(any(item).waitForExistence(timeout: 5), item)
        }
        any(TestID.Music.menuSongInfo).tap()
        any(TestID.Music.songInfoDone).waitToExist(10)
        attachScreenshot("song info")
        any(TestID.Music.songInfoDone).tapNow(10)
    }

    func testArtistPageShowsTopSongsThenAlbums() throws {
        try standardOnly()
        launchHome()
        _ = try openAlbum("FX Formats")
        any(TestID.Music.detailArtist).tapNow(10)
        app.element(TestID.Music.artist).waitToExist(20)
        let top = any(TestID.Music.shelf("top-songs")), albums = any(TestID.Music.shelf("albums"))
        top.waitToExist(20)
        app.reveal(albums)
        XCTAssertTrue(albums.exists)
        XCTAssertLessThan(top.frame.minY, albums.frame.minY, "Top Songs comes before Albums")
    }

    func testPlaylistsListTheAccountsOwn() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account())
        launchHome()
        openMusic()
        any(TestID.Music.page("library")).tapNow(10)
        any(TestID.Music.libraryDoor("playlists")).tapNow(10)
        app.element(TestID.Playlists.root).waitToExist(20)
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "\(account.name) Playlist")).firstMatch
        mine.tapNow(20)
        app.element(TestID.Playlists.detail).waitToExist(20)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "music.song.")).count >= 3, true)
    }

    func testSmartPlaylistEditorSavesAndDeletes() throws {
        try standardOnly()
        launchHome()
        openMusic()
        any(TestID.Music.page("library")).tapNow(10)
        any(TestID.Music.libraryDoor("playlists")).tapNow(10)
        let new = any(TestID.SmartPlaylists.new)
        app.reveal(new)
        new.tapNow(10)
        app.element(TestID.SmartPlaylists.editor).waitToExist(10)
        let name = app.textFields[TestID.SmartPlaylists.editorName]
        name.tapNow(10)
        name.typeText("UITest Smart")
        any(TestID.SmartPlaylists.editorFavoritesOnly).tap()
        any(TestID.SmartPlaylists.editorSave).tapNow(10)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "smartPlaylists.row.", "UITest Smart")).firstMatch
        row.tapNow(20)
        app.element(TestID.SmartPlaylists.detail).waitToExist(20)
        any(TestID.SmartPlaylists.detailMore).tapNow(10)
        any(TestID.SmartPlaylists.detailDelete).tapNow(10)
        let confirm = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Delete'")).firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    func testMusicSearchFindsArtistsAlbumsSongs() throws {
        launchHome()
        openMusic()
        let field = app.textFields[TestID.Music.searchField]
        field.tapNow(10)
        field.typeText("FX")
        app.element(TestID.Music.searchResults).waitToExist(30)
        assertAboveKeyboard(field, "music search field")
        any(TestID.Music.searchCancel).tapNow(10)
    }

    /// Regression R-f41df90: the mini player covered the foot of a list.
    func testMiniPlayerDoesNotCoverTheEndOfAList() throws {
        launchHome()
        let album = try openAlbum("FX Formats")
        let ids = tracks(album)
        playSong(ids[0])
        let last = any(TestID.Music.song(ids[ids.count - 1]))
        for _ in 0..<6 { app.swipeUp() }
        let mini = app.element(TestID.MiniPlayer.root)
        XCTAssertTrue(last.exists && mini.exists)
        XCTAssertLessThanOrEqual(last.frame.maxY, mini.frame.minY + 1, "last song \(last.frame) under the mini player \(mini.frame)")
    }
}

enum MusicSortKeys {
    static let name = "SortName"
}

final class PhoneAudiobookTests: PhoneMusicTestCase {
    func testAudiobooksTabShowsContinueListening() throws {
        launchHome()
        tab("Audiobooks")
        app.element(TestID.Books.root).waitToExist(30)
        let book = try XCTUnwrap(PhoneFixtures.book("FX Chaptered Audiobook"))
        any(TestID.Books.shelf("continueListening")).waitToExist(20)
        any(TestID.Books.card(book)).waitToExist(20)
        attachScreenshot("audiobooks (\(device.rawValue))")
    }

    func testBookPageListsChaptersAndResumes() throws {
        let api = try self.api
        let book = try XCTUnwrap(PhoneFixtures.book("FX Chaptered Audiobook"))
        try api.setResume(book, seconds: 400)
        launchHome()
        tab("Audiobooks")
        visible(TestID.Books.card(book), timeout: 30).tapNow(5)
        app.element(TestID.Books.detail).waitToExist(20)
        let chapters = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'books.detail.chapter.'"))
        for _ in 0..<6 where chapters.count < 6 { app.swipeUp() }
        attachScreenshot("book page")
        XCTAssertGreaterThanOrEqual(chapters.count, 6, "six chapters listed")
        for _ in 0..<6 where !any(TestID.Books.detailPlay).exists { app.swipeDown() }
        any(TestID.Books.detailPlay).tapNow(10)
        let p = waitForServerPosition(api, itemId: book, atLeast: 395, timeout: 40)
        XCTAssertGreaterThanOrEqual(p ?? 0, 395, "did not resume at 6:40")
        openNowPlaying()
        any(TestID.NowPlaying.speed).waitToExist(10)
        assertOnScreen(any(TestID.NowPlaying.chapter), "chapter line")
    }

    func testChapterRowPlaysFromThere() throws {
        try standardOnly()
        let api = try self.api
        let book = try XCTUnwrap(PhoneFixtures.book("FX Chaptered Audiobook"))
        launchHome()
        tab("Audiobooks")
        visible(TestID.Books.card(book), timeout: 30).tapNow(5)
        let chapter = any(TestID.Books.chapter(3))
        for _ in 0..<6 where !chapter.exists { app.swipeUp() }
        chapter.tapNow(10)
        let p = waitForServerPosition(api, itemId: book, atLeast: 450, timeout: 40)
        XCTAssertGreaterThanOrEqual(p ?? 0, 449)
    }

    func testAudiobookSpeedMenu() throws {
        try standardOnly()
        let book = try XCTUnwrap(PhoneFixtures.book("FX Chaptered Audiobook"))
        launchHome()
        tab("Audiobooks")
        visible(TestID.Books.card(book), timeout: 30).tapNow(5)
        any(TestID.Books.detailPlay).tapNow(20)
        openNowPlaying()
        any(TestID.NowPlaying.speed).tapNow(10)
        any(TestID.NowPlaying.speedOption("1.25")).tapNow(10)
        any(TestID.NowPlaying.speed).tapNow(10)
        any(TestID.NowPlaying.speedOption("1.0")).tapNow(10)
    }

    /// Jellyfin lists each file of a multi-file book as its own book.
    func testMultiFileBookPartsAreListed() throws {
        try standardOnly()
        let part = try XCTUnwrap(PhoneFixtures.book("Part 2"))
        launchHome()
        tab("Audiobooks")
        let all = any(TestID.Books.shelf("allBooks"))
        app.reveal(all)
        XCTAssertTrue(any(TestID.Books.card(part)).waitForExistence(timeout: 20) || app.reveal(any(TestID.Books.card(part))))
    }
}
#endif
