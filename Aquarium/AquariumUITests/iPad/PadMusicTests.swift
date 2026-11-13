//  Music and audiobooks on an iPad: reached from the sidebar's Libraries
//  group; what is playing shows as a card at the foot of the sidebar
//  (PadSidebar.SidebarNowPlaying) rather than the phone's bar across the
//  page; Now Playing held to a column at regular width (1a32226); Songs A–Z
//  (6344432).

#if os(iOS)
import XCTest

final class PadMusicTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    private struct Track { let id: String; let name: String }

    private func album(_ name: String) throws -> (id: String, tracks: [Track]) {
        guard let music = try fx.raw["fixtures"] as? [String: Any],
              let entry = music["music"] as? [String: Any],
              let albums = entry["albums"] as? [[String: Any]],
              let album = albums.first(where: { $0["name"] as? String == name }),
              let id = album["id"] as? String else { throw XCTSkip("no album \(name)") }
        let tracks = (album["tracks"] as? [[String: Any]] ?? []).compactMap { t -> Track? in
            guard let id = t["id"] as? String else { return nil }
            return Track(id: id, name: t["name"] as? String ?? "")
        }
        return (id, tracks)
    }

    private func openMusic() {
        launchHome()
        showSection("music")
        app.element(TestID.Music.root).waitToExist(30)
    }

    private func openLibraryPage() {
        openMusic()
        let picker = app.segmentedControls[TestID.Music.pagePicker]
        if picker.waitForExistence(timeout: 10) {
            picker.buttons["Library"].padTap()
        } else {
            app.button(TestID.Music.page("library")).padTap()
        }
        app.element(TestID.Music.library).waitToExist(20)
    }

    private func openAlbum(_ name: String) throws -> (id: String, tracks: [Track]) {
        let album = try album(name)
        openLibraryPage()
        app.button(TestID.Music.libraryDoor("albums")).padTap()
        app.element(TestID.Music.albums).waitToExist(20)
        let card = app.elements(prefix: TestID.Music.card(album.id)).firstMatch
        XCTAssertTrue(reveal(card), "\(name) among the albums")
        card.padTap()
        app.element(TestID.Music.album).waitToExist(30)
        return album
    }

    func testMusicDiscoverAndLibraryPages() {
        openMusic()
        app.element(TestID.Music.listenNow).waitToExist(30)
        openLibraryPage()
        for door in ["playlists", "artists", "albums", "songs", "genres", "favorites", "downloaded"] {
            XCTAssertTrue(app.button(TestID.Music.libraryDoor(door)).exists, "the \(door) door")
        }
        attachScreenshot("music library")
    }

    func testAlbumPageGroupsDiscs() throws {
        _ = try openAlbum("FX Two Discs")
        XCTAssertTrue(app.element(TestID.Music.albumDisc(1)).exists || app.staticTexts["Disc 1"].exists, "disc 1 heading")
        XCTAssertTrue(reveal(app.element(TestID.Music.albumDisc(2))) || app.staticTexts["Disc 2"].exists, "disc 2 heading")
    }

    func testPlayingASongPutsTheNowPlayingCardInTheSidebar() throws {
        let album = try openAlbum("FX Formats")
        let song = app.button(TestID.Music.song(album.tracks[2].id))
        XCTAssertTrue(reveal(song))
        song.padTap()
        let card = app.element(TestID.Sidebar.nowPlaying)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the Now Playing card at the foot of the sidebar")
        XCTAssertTrue(card.frame.maxX <= sidebar.frame.maxX + 1, "in the sidebar column")
        let title = app.element(TestID.Sidebar.nowPlayingTitle)
        XCTAssertTrue(waitUntil(20, "the card to name the song") { title.label == album.tracks[2].name })
        XCTAssertFalse(app.element(TestID.MiniPlayer.root).exists, "no phone mini player across the page beside a sidebar")
        attachScreenshot("now playing card")
    }

    func testSidebarCardPlayPauseAndOpensNowPlaying() throws {
        let album = try openAlbum("FX Long Tracks")
        app.button(TestID.Music.song(album.tracks[0].id)).padTap()
        let toggle = app.button(TestID.Sidebar.nowPlayingPlayPause)
        toggle.waitToExist(30)
        XCTAssertTrue(waitUntil(20, "playing") { toggle.label == "Pause" })
        toggle.padTap()
        XCTAssertTrue(waitUntil(10, "paused") { toggle.label == "Play" })
        app.element(TestID.Sidebar.nowPlaying).padTap()
        let now = app.element(TestID.NowPlaying.root)
        now.waitToExist(15)
        // At regular width the player keeps to a centred column (1a32226).
        let playPause = app.button(TestID.NowPlaying.playPause)
        playPause.waitToExist(10)
        let window = app.frame
        XCTAssertEqual(playPause.frame.midX, window.midX, accuracy: 40, "transport centred")
        attachScreenshot("now playing")
        app.button(TestID.NowPlaying.close).padTap()
        XCTAssertTrue(now.waitToVanish(10))
    }

    func testNowPlayingQueueAndLyrics() throws {
        let album = try openAlbum("FX Two Discs")
        app.button(TestID.Music.song(album.tracks[0].id)).padTap()  // Disc One Opener: synced lyrics
        app.element(TestID.Sidebar.nowPlaying).padTap(30)
        app.element(TestID.NowPlaying.root).waitToExist(15)
        app.button(TestID.NowPlaying.queue).padTap()
        app.element(TestID.NowPlaying.queueRoot).waitToExist(10)
        XCTAssertTrue(app.elements(prefix: "nowPlaying.queue.row.").firstMatch.waitForExistence(timeout: 10),
                      "the rest of the album is queued")
        app.button(TestID.NowPlaying.queueClose).padTap()
        app.button(TestID.NowPlaying.lyrics).padTap()
        XCTAssertTrue(app.element(TestID.Lyrics.lines).waitForExistence(timeout: 20), "synced lyrics")
        attachScreenshot("lyrics")
    }

    /// Regression, 6344432 ("Songs sort by Name, not SortName: Jellyfin
    /// prefixes a song's SortName with disc/track numbers, so 'by name' was
    /// by track and the A–Z strip jumped to the wrong rows").
    func testSongsAToZJumpsToTheLetter() throws {
        let formats = try album("FX Formats")
        try XCTSkipUnless(formats.tracks.count > 1 && formats.tracks[1].name.hasPrefix("WAV"), "fixture changed")
        openLibraryPage()
        app.button(TestID.Music.libraryDoor("songs")).padTap()
        app.element(TestID.Music.songs).waitToExist(20)
        let index = app.element(TestID.Common.letterIndex)
        XCTAssertTrue(index.waitForExistence(timeout: 30), "the A–Z strip on Songs")
        let letters = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
        let target = "W"
        let i = CGFloat(letters.firstIndex(of: target)!)
        let h = index.frame.height
        let row = min(16, max(7, (h - 24) / 27))
        let top = max(0, (h - (row * 27 + 8)) / 2) + 4
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: top + (i + 0.5) * row)).tap()
        // "WAV 16-44" (FX Formats) is the library's only W title: the jump
        // must bring its row on screen. Waited on as an element predicate:
        // a closure walking every song row each poll stalled the runner.
        let wav = app.buttons.matching(identifier: TestID.Music.song(formats.tracks[1].id)).firstMatch
        // W is the last letter in this library, so the list ends on it: the
        // row is on screen (by its frame: a row in the last screenful is
        // not always "hittable" to XCUITest).
        let exists = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: wav)
        XCTAssertEqual(XCTWaiter().wait(for: [exists], timeout: 20), .completed, "WAV 16-44 loaded")
        let window = app.frame
        XCTAssertTrue(wav.frame.minY >= window.minY && wav.frame.maxY <= window.maxY + 1,
                      "the A–Z strip's W brings WAV 16-44 on screen: \(wav.frame)")
    }

    func testArtistPageFromTheAlbum() throws {
        _ = try openAlbum("FX Formats")
        let artist = app.button(TestID.Music.detailArtist)
        artist.padTap()
        app.element(TestID.Music.artist).waitToExist(30)
    }

    func testSongMenuOffersQueueActions() throws {
        let album = try openAlbum("FX Formats")
        let more = app.button(TestID.Music.songMore(album.tracks[0].id))
        XCTAssertTrue(reveal(more))
        more.padTap()
        XCTAssertTrue(app.button(TestID.Music.menuPlayNext).waitForExistence(timeout: 10))
        XCTAssertTrue(app.button(TestID.Music.menuGoToArtist).exists || app.button(TestID.Music.menuGoToAlbum).exists)
        app.button(TestID.Music.menuSongInfo).padTap()
        app.element(TestID.Music.songInfo).waitToExist(10)
        app.button(TestID.Music.songInfoDone).padTap()
    }
}

final class PadBooksTests: PadUITestCase {
    private func bookId() throws -> String {
        guard let list = try fx.raw["fixtures"] as? [String: Any],
              let books = list["books"] as? [[String: Any]],
              let id = books.first(where: { $0["name"] as? String == "FX Chaptered Audiobook" })?["id"] as? String
        else { throw XCTSkip("no FX Chaptered Audiobook") }
        return id
    }

    func testAudiobooksSectionShowsContinueListening() throws {
        let id = try bookId()
        launchHome()
        showSection("books")
        app.element(TestID.Books.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Books.shelf("continueListening")).waitForExistence(timeout: 20),
                      "the baseline has the book at 6:40")
        XCTAssertTrue(app.elements(prefix: TestID.Books.card(id)).firstMatch.exists)
        attachScreenshot("audiobooks")
    }

    func testBookPageListsChaptersAndPlaysFromOne() throws {
        let id = try bookId()
        launchHome()
        showSection("books")
        let card = app.elements(prefix: TestID.Books.card(id)).firstMatch
        card.padTap(30)
        app.element(TestID.Books.detail).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Books.detailProgressText).waitForExistence(timeout: 10), "progress line")
        let chapter = app.button(TestID.Books.chapter(2))
        XCTAssertTrue(reveal(chapter), "Chapter 3's row")
        chapter.padTap()
        let card2 = app.element(TestID.Sidebar.nowPlaying)
        XCTAssertTrue(card2.waitForExistence(timeout: 30), "the sidebar card for the book")
        XCTAssertTrue(waitUntil(20, "the card's second line to name the chapter") {
            // The card's second line, beside its title in the sidebar column.
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Chapter 3'"))
                .allElementsBoundByIndex.contains { $0.frame.maxX <= card2.frame.maxX + 1 && $0.frame.minY >= card2.frame.minY - 1 }
        })
        app.button(TestID.Sidebar.nowPlayingPlayPause).padTap()
    }
}
#endif
