//  Music and audiobooks on the device: a song's menu (Download,
//  Downloading…, Remove Download) and the mark on its row; Library ›
//  Downloaded and the pages behind its doors (artists, albums, songs,
//  genres, playlists, favourites, an album's own page, the stations built
//  from downloads); the Music and Audiobooks doors on the Downloads page;
//  a downloaded audiobook played and removed.
//
//  Through the switch proxy (PhoneProxySupport.swift), so a song's transfer
//  can be held long enough to see it under way. What these pages show with
//  no server is in PhoneOfflineTests.

#if os(iOS)
import XCTest

final class PhoneOnDeviceMusicTests: PhoneProxyTestCase {
    private func track(_ name: String) throws -> String { try XCTUnwrap(PhoneFixtures.track(name), name) }

    private func openDownloadedLibrary(file: StaticString = #filePath, line: UInt = #line) {
        openMusic(file: file, line: line)
        any(TestID.Music.page("library")).tapNow(10, file: file, line: line)
        app.element(TestID.Music.library).waitToExist(20, file: file, line: line)
        let door = any(TestID.Music.libraryDoor("downloaded"))
        app.reveal(door)
        door.tapNow(10, file: file, line: line)
        app.element(TestID.Music.downloaded).waitToExist(20, file: file, line: line)
    }

    /// Downloads a whole album from its page's "…" menu and waits for every
    /// song to be marked as on the device. Leaves the album's page showing.
    private func downloadAlbum(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let album = try openAlbum(name, file: file, line: line)
        let ids = tracks(album)
        any(TestID.Music.detailMore).tapNow(10, file: file, line: line)
        any(TestID.Music.menuDownload).tapNow(10, file: file, line: line)
        for id in ids {
            let mark = any(TestID.Music.downloadMark(id))
            app.reveal(mark)
            XCTAssertTrue(wait(for: mark, "exists == true AND label == 'Downloaded'", timeout: 90), "\(id) never arrived", file: file, line: line)
        }
        return ids
    }

    /// A song's "…" menu, start to finish: Download; while it is on its way
    /// the row is marked and the menu says Downloading… (which opens
    /// Downloads); once here the mark says Downloaded and the menu offers
    /// Remove Download, which takes it away again.
    func testSongMenuDownloadsAndRemoves() throws {
        let song = try track("Twelve Minutes")   // 8 MB: about 20 s at 3 Mbps
        PhoneProxy.slow(3_000_000, matching: "/Download")
        launchThroughProxy()
        _ = try openAlbum("FX Long Tracks")
        let more = any(TestID.Music.songMore(song))
        let mark = any(TestID.Music.downloadMark(song))
        XCTAssertFalse(mark.exists, "marked before anything was asked for")

        more.tapNow(10)
        let download = any(TestID.Music.menuDownload)
        download.waitToExist(10)
        XCTAssertFalse(any(TestID.Music.menuRemoveDownload).exists)
        download.tapNow(5)

        // On its way: marked on the row, and the menu says so.
        mark.waitToExist(20)
        XCTAssertTrue(["Downloading", "Waiting to download"].contains(mark.label), mark.label)
        assertOnScreen(mark, "the download mark")
        more.tapNow(10)
        let downloading = any(TestID.Music.menuDownloading)
        downloading.waitToExist(10)
        XCTAssertFalse(any(TestID.Music.menuDownload).exists, "Download offered for a song already on its way")
        attachScreenshot("song on its way")
        downloading.tapNow(5)
        app.element(TestID.Downloads.root).waitToExist(20)
        app.element(TestID.Downloads.transfer(song)).waitToExist(10)

        // Arrived.
        PhoneProxy.unslow()
        XCTAssertTrue(app.element(TestID.Downloads.transfer(song)).waitToVanish(60), "the song never finished")
        let door = any(TestID.Downloads.musicDoor)
        door.waitToExist(20)
        XCTAssertTrue(door.label.contains("1 song"), door.label)
        tab("Music")
        app.element(TestID.Music.album).waitToExist(20)
        XCTAssertTrue(wait(for: mark, "exists == true AND label == 'Downloaded'", timeout: 30), "not marked as downloaded")

        // Remove Download.
        more.tapNow(10)
        let remove = any(TestID.Music.menuRemoveDownload)
        remove.waitToExist(10)
        XCTAssertFalse(any(TestID.Music.menuDownload).exists)
        remove.tapNow(5)
        XCTAssertTrue(mark.waitToVanish(20), "still marked after Remove Download")
        more.tapNow(10)
        download.waitToExist(10)
        dismissMenu()
        wipeDownloads()
    }

    /// An album downloaded whole, then Library › Downloaded: its doors open
    /// the on-device lists, an album there opens its on-device page and
    /// plays, the stations shelf shuffles the downloads, and the Downloads
    /// page's Music door leads to the same place.
    func testDownloadedLibraryAndItsPages() throws {
        launchThroughProxy()
        let ids = try downloadAlbum("FX Compilation")
        let album = try XCTUnwrap(PhoneFixtures.album("FX Compilation")?["id"] as? String)
        goBack()
        any(TestID.Music.searchCancel).tapIfThere()

        openDownloadedLibrary()
        any(TestID.Music.shelfTitle("recently-downloaded")).waitToExist(20)
        any(TestID.Stations.shuffleDownloads).waitToExist(20)
        attachScreenshot("library downloaded")

        // Songs: the four, and one plays.
        func door(_ key: String, _ kind: String) {
            let d = any(TestID.Music.libraryDoor(key))
            let list = app.element(TestID.Music.onDeviceList(kind))
            app.element(TestID.Music.downloaded).waitToExist(10)
            app.reveal(d)
            // A tap while the page before is still sliding away is lost.
            for _ in 0..<3 where !list.exists {
                d.tapNow(10)
                if list.waitForExistence(timeout: 6) { break }
            }
            XCTAssertTrue(list.waitForExistence(timeout: 5), "\(key) did not open the on-device list")
        }
        door("songs", "songs")
        for id in ids { XCTAssertTrue(any(TestID.Music.song(id)).waitForExistence(timeout: 10), "song \(id) not listed") }
        assertOnScreen(any(TestID.Music.playBarPlay), "Play")
        any(TestID.Music.song(ids[0])).tapNow(10)
        app.element(TestID.MiniPlayer.root).waitToExist(30)
        any(TestID.MiniPlayer.playPause).tapNow(10)
        goBack()

        // Albums: the one, and its on-device page.
        door("albums", "albums")
        any(TestID.Music.card(album)).tapNow(20)
        app.element(TestID.Music.onDeviceCollection).waitToExist(20)
        for id in ids { XCTAssertTrue(any(TestID.Music.song(id)).waitForExistence(timeout: 10)) }
        app.reveal(any(TestID.Music.detailFooter))
        XCTAssertTrue(any(TestID.Music.detailFooter).exists, "no footer")
        XCTAssertTrue(any(TestID.Music.detailMore).exists)
        attachScreenshot("on-device album")
        goBack()
        app.element(TestID.Music.onDeviceList("albums")).waitToExist(10)
        goBack()

        // Artists.
        door("artists", "artists")
        XCTAssertTrue(app.elements(prefix: "music.row.").firstMatch.waitForExistence(timeout: 10), "no artist of the downloaded songs")
        XCTAssertFalse(any(TestID.Music.empty).exists)
        goBack()

        // Genres: a genre opens the songs of it that are here.
        door("genres", "genres")
        let genre = app.elements(prefix: "music.onDevice.genre.").firstMatch
        genre.waitToExist(20)
        genre.tapNow(5)
        app.element(TestID.Music.onDeviceCollection).waitToExist(20)
        XCTAssertTrue(app.elements(prefix: "music.song.").firstMatch.waitForExistence(timeout: 10), "a genre with no songs")
        goBack()
        app.element(TestID.Music.onDeviceList("genres")).waitToExist(10)
        goBack()

        // Favourites: none of the four is one.
        door("favorites", "favorites")
        any(TestID.Music.empty).waitToExist(10)
        goBack()
        door("playlists", "playlists")
        goBack()

        // Shuffle All from downloads.
        app.element(TestID.Music.downloaded).waitToExist(10)
        any(TestID.Stations.shuffleDownloads).tapNow(10)
        XCTAssertTrue(wait(for: any(TestID.MiniPlayer.playPause), "exists == true", timeout: 20))
        any(TestID.MiniPlayer.playPause).tapNow(10)

        // The Downloads page's door comes here too.
        openDownloads()
        let musicDoor = any(TestID.Downloads.musicDoor)
        musicDoor.waitToExist(10)
        XCTAssertTrue(musicDoor.label.contains("4 songs"), musicDoor.label)
        XCTAssertEqual(any(TestID.Downloads.itemCount).label, "4 items on this device")
        revealAndTap(musicDoor)
        app.element(TestID.Music.downloaded).waitToExist(20)
        goBack()
        wipeDownloads()
    }

    /// A downloaded audiobook: its page says it is on this device, its cover
    /// is badged, the Downloads page's Audiobooks door lists it, it plays
    /// from there, and Remove download takes it away.
    func testDownloadedAudiobookDoorPlayAndRemove() throws {
        let api = try self.api
        let book = try XCTUnwrap(PhoneFixtures.book("Part 1"))   // 2 MB, untouched at the baseline
        addTeardownBlock { [weak self] in
            self?.app?.terminate()
            try? api.markUnplayed(book)
        }
        launchThroughProxy()
        tab("Audiobooks")
        app.element(TestID.Books.root).waitToExist(30)
        let card = any(TestID.Books.card(book))
        app.reveal(card)
        visible(TestID.Books.card(book), timeout: 30).tapNow(5)
        app.element(TestID.Books.detail).waitToExist(20)
        any(TestID.Books.detailMore).tapNow(10)
        any(TestID.Music.menuDownload).tapNow(10)
        let line = any(TestID.Music.downloadLine(book))
        XCTAssertTrue(wait(for: line, "exists == true AND label == 'On this device'", timeout: 90), "the book never arrived")
        attachScreenshot("audiobook on this device")
        goBack()
        let badge = any(TestID.Music.downloadBadge(book))
        XCTAssertTrue(wait(for: badge, "exists == true AND label == 'Downloaded'", timeout: 20), "no badge on the cover")

        openDownloads()
        let door = any(TestID.Downloads.audiobooksDoor)
        door.waitToExist(10)
        XCTAssertTrue(door.label.contains("1 audiobook"), door.label)
        XCTAssertFalse(any(TestID.Downloads.musicDoor).exists, "a Music door with no songs")
        revealAndTap(door)
        app.element(TestID.Books.downloaded).waitToExist(20)
        let group = app.elements(prefix: "music.downloadedSongs.album.").firstMatch
        group.waitToExist(10)
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'music.downloadedSongs.album.play.'")).firstMatch
        play.tapNow(10)
        app.element(TestID.MiniPlayer.root).waitToExist(30)
        any(TestID.MiniPlayer.playPause).tapNow(10)
        attachScreenshot("downloaded audiobooks")

        // Press and hold the book's heading: Remove download.
        let remove = any(TestID.Music.downloadedAlbumRemove)
        for _ in 0..<3 where !remove.exists {
            group.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0)).withOffset(CGVector(dx: 0, dy: 32)).press(forDuration: 1.2)
            if remove.waitForExistence(timeout: 4) { break }
        }
        remove.tapNow(5)
        any(TestID.Books.empty).waitToExist(10)
        goBack()
        app.element(TestID.Downloads.root).waitToExist(10)
        XCTAssertTrue(door.waitToVanish(10), "the Audiobooks door outlived the book")
        wipeDownloads()
    }
}

extension XCUIElement {
    /// Taps the element if it is there; nothing otherwise.
    func tapIfThere() {
        if exists { coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }
}
#endif
