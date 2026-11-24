//  Now Playing on an iPad (the centred column opened from the sidebar's
//  card): what PadMusicTests leaves out. Next and Previous through an album,
//  Repeat letting Next wrap on the last song, Shuffle keeping the songs and
//  giving the album's order back, the star reaching the server, the sleep
//  timer set and turned off, Up Next's Clear, and an audiobook's own
//  transport (chapter name, the chapter buttons, ±15/30 s skips, speed).
//
//  Shuffle and Repeat say whether they are on only by colour, so these read
//  what they do instead: the queue's order and whether Next can be pressed.
//  Source: Music/NowPlayingView.swift, Music/MusicPlayer.swift.

#if os(iOS)
import XCTest

final class PadNowPlayingTests: PadMusicMoreTestCase {
    private var next: XCUIElement { app.button(TestID.NowPlaying.next) }
    private var previous: XCUIElement { app.button(TestID.NowPlaying.previous) }

    /// Up Next's song ids, read with the card open and the card put away
    /// again (the player under the card is hidden from accessibility).
    private func readQueue(file: StaticString = #filePath, line: UInt = #line) -> [String] {
        openQueue(file: file, line: line)
        _ = eventually(5) { [self] in !queueIds().isEmpty || app.element(TestID.NowPlaying.queueEmpty).exists }
        let ids = queueIds()
        closeQueue(file: file, line: line)
        return ids
    }

    func testNextAndPreviousStepThroughTheAlbum() throws {
        let album = try playTrack(0, of: "FX Long Tracks")
        try XCTSkipUnless(album.tracks.count == 2, "fixture changed")
        openNowPlaying()
        XCTAssertEqual(nowPlayingTitle, album.tracks[0].name)
        XCTAssertEqual(playingFrom, "FX Long Tracks")

        openQueue()
        XCTAssertTrue(waitUntil(10, "Up Next to hold the album's other song") { [self] in
            queueIds() == [album.tracks[1].id]
        }, "Up Next: \(queueIds())")
        XCTAssertEqual(app.element(TestID.NowPlaying.queueSource).label, "From FX Long Tracks")
        closeQueue()

        XCTAssertTrue(next.isEnabled, "something follows the first song")
        next.padTap()
        XCTAssertTrue(waitUntil(20, "Next to move to the second song") { [self] in nowPlayingTitle == album.tracks[1].name },
                      "now playing \(nowPlayingTitle)")
        XCTAssertTrue(waitUntil(10, "Next to be off on the last song") { [self] in !next.isEnabled })
        openQueue()
        XCTAssertTrue(app.element(TestID.NowPlaying.queueEmpty).waitForExistence(timeout: 10), "nothing after the last song")
        XCTAssertTrue(app.staticTexts["Nothing queued after this."].exists)
        XCTAssertFalse(app.button(TestID.NowPlaying.queueClear).exists, "nothing to clear")
        closeQueue()

        // Past 3 s Previous starts the song again; within them it goes back.
        // Twice, then, lands on the first song either way.
        previous.padTap()
        previous.padTap()
        XCTAssertTrue(waitUntil(20, "Previous to go back to the first song") { [self] in nowPlayingTitle == album.tracks[0].name },
                      "now playing \(nowPlayingTitle)")
        attachScreenshot("back on the first song")
    }

    /// On the last song Next is off. Repeat (all) turns it on and Up Next
    /// says the queue starts over; Repeat again (one) and again (off) leave
    /// nothing after the song.
    func testRepeatAllLetsNextWrapOnTheLastSong() throws {
        let album = try playTrack(1, of: "FX Long Tracks")
        openNowPlaying()
        XCTAssertEqual(nowPlayingTitle, album.tracks[1].name)
        XCTAssertTrue(waitUntil(10, "Next off on the last song") { [self] in !next.isEnabled })
        let repeatButton = app.button(TestID.NowPlaying.repeatMode)
        XCTAssertEqual(repeatButton.label, "Repeat")

        repeatButton.padTap()
        XCTAssertTrue(waitUntil(10, "Repeat all to give Next somewhere to go") { [self] in next.isEnabled })
        openQueue()
        XCTAssertTrue(app.staticTexts["The queue starts over from the top."].waitForExistence(timeout: 10),
                      "Up Next says the queue starts over")
        closeQueue()

        repeatButton.padTap()
        XCTAssertTrue(waitUntil(10, "Repeat one to take Next away again") { [self] in !next.isEnabled })
        repeatButton.padTap()
        XCTAssertTrue(waitUntil(10, "Repeat off: still nothing after the last song") { [self] in !next.isEnabled })
        openQueue()
        XCTAssertTrue(app.staticTexts["Nothing queued after this."].waitForExistence(timeout: 10))
        closeQueue()
    }

    /// Shuffle keeps the song playing and reorders only what comes after it;
    /// off again, the album's order is back.
    func testShuffleKeepsTheSongsAndOffGivesTheAlbumsOrderBack() throws {
        let album = try playTrack(0, of: "FX Two Discs")
        try XCTSkipUnless(album.tracks.count >= 4, "fixture changed")
        let rest = album.tracks.dropFirst().map(\.id)
        openNowPlaying()
        XCTAssertEqual(readQueue(), rest, "Up Next in the album's order")

        let shuffle = app.button(TestID.NowPlaying.shuffle)
        XCTAssertEqual(shuffle.label, "Shuffle")
        shuffle.padTap()
        let shuffled = readQueue()
        XCTAssertEqual(Set(shuffled), Set(rest), "the same songs after it, shuffled: \(shuffled)")
        XCTAssertEqual(shuffled.count, rest.count)
        XCTAssertEqual(nowPlayingTitle, album.tracks[0].name, "the song playing stays")

        shuffle.padTap()
        XCTAssertTrue(waitUntil(10, "the album's order back") { [self] in readQueue() == rest })
        attachScreenshot("shuffle off")
    }

    /// The star beside the title makes the song a favourite on the server,
    /// and takes it away again.
    func testTheStarReachesTheServer() throws {
        let formats = try fixtureAlbum("FX Formats")
        try XCTSkipUnless(formats.tracks.count > 1, "fixture changed")
        let song = formats.tracks[1].id
        let server = try api()
        try server.setFavorite(song, false)
        addTeardownBlock { try? server.setFavorite(song, false) }
        try playTrack(1, of: "FX Formats")
        openNowPlaying()
        let star = app.button(TestID.NowPlaying.favorite)
        star.padTap()
        XCTAssertTrue(waitUntil(20, "the song a favourite on the server") { (try? server.userData(song).favorite) == true })
        star.padTap()
        XCTAssertTrue(waitUntil(20, "the favourite taken away") { (try? server.userData(song).favorite) == false })
    }

    /// The moon's menu: 15 minutes sets it and the button says how long is
    /// left; Turn off puts it back to "Sleep Timer".
    func testSleepTimerIsSetAndTurnedOff() throws {
        try playTrack(0, of: "FX Long Tracks")
        openNowPlaying()
        let moon = app.button(TestID.NowPlaying.sleepTimer)
        XCTAssertEqual(moon.label, "Sleep Timer")
        moon.padTap()
        tapMenuRow(TestID.NowPlaying.sleepOption(15), beginning: "15 minutes")
        XCTAssertTrue(waitUntil(10, "the timer to be set") { ["Sleep in 14 min", "Sleep in 15 min"].contains(moon.label) },
                      "reads \(moon.label)")
        moon.padTap()
        tapMenuRow(TestID.NowPlaying.sleepOff, beginning: "Turn off")
        XCTAssertTrue(waitUntil(10, "the timer to be off") { moon.label == "Sleep Timer" }, "reads \(moon.label)")
    }

    /// Clear empties Up Next; the song playing plays on.
    func testClearEmptiesUpNext() throws {
        let album = try playTrack(0, of: "FX Two Discs")
        openNowPlaying()
        openQueue()
        XCTAssertEqual(app.element(TestID.NowPlaying.queueSource).label, "From FX Two Discs")
        let clear = app.button(TestID.NowPlaying.queueClear)
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "Clear while songs are queued")
        clear.padTap()
        XCTAssertTrue(app.element(TestID.NowPlaying.queueEmpty).waitForExistence(timeout: 10), "Up Next emptied")
        XCTAssertTrue(clear.waitToVanish(5), "and Clear goes with it")
        closeQueue()
        XCTAssertEqual(nowPlayingTitle, album.tracks[0].name, "the song playing is not cleared")
        XCTAssertTrue(waitUntil(10, "Next off with nothing after") { [self] in !next.isEnabled })
    }
}

/// An audiobook in Now Playing: the chapter under the scrubber, the chapter
/// buttons at the foot in place of Lyrics and the queue, back 15 and
/// forward 30 in place of Previous and Next, and Speed where Shuffle is.
final class PadNowPlayingBookTests: PadMusicMoreTestCase {
    private func bookId() throws -> String {
        guard let list = try fx.raw["fixtures"] as? [String: Any],
              let books = list["books"] as? [[String: Any]],
              let id = books.first(where: { $0["name"] as? String == "FX Chaptered Audiobook" })?["id"] as? String
        else { throw XCTSkip("no FX Chaptered Audiobook") }
        return id
    }

    /// Chapter 3 of the book, from its page, then Now Playing.
    private func playChapterThree() throws -> String {
        let id = try bookId()
        let server = try api()
        // The baseline's 6:40 (FIXTURES.md), put back whatever this moved it to.
        addTeardownBlock { try? server.setResume(id, seconds: 400) }
        launchHome()
        showSection("books")
        app.elements(prefix: TestID.Books.card(id)).firstMatch.padTap(30)
        app.element(TestID.Books.detail).waitToExist(30)
        let chapter = app.button(TestID.Books.chapter(2))
        XCTAssertTrue(reveal(chapter), "Chapter 3's row")
        chapter.padTap()
        app.element(TestID.Sidebar.nowPlaying).waitToExist(30)
        openNowPlaying()
        return id
    }

    private var chapterLabel: String { app.element(TestID.NowPlaying.chapter).label }

    func testABooksFootStepsThroughChapters() throws {
        _ = try playChapterThree()
        let chapter = app.element(TestID.NowPlaying.chapter)
        XCTAssertTrue(chapter.waitForExistence(timeout: 20), "the chapter under the scrubber")
        XCTAssertTrue(waitUntil(15, "Chapter 3 named") { [self] in chapterLabel == "Chapter 3" }, "reads \(chapterLabel)")
        XCTAssertTrue(app.button(TestID.NowPlaying.nextChapter).exists, "the chapter buttons at the foot")
        XCTAssertTrue(app.button(TestID.NowPlaying.previousChapter).exists)
        XCTAssertFalse(app.button(TestID.NowPlaying.queue).exists, "a book has no queue button")
        XCTAssertFalse(app.button(TestID.NowPlaying.shuffle).exists, "nor Shuffle: Speed is in its place")
        XCTAssertTrue(app.button(TestID.NowPlaying.speed).exists)

        app.button(TestID.NowPlaying.nextChapter).padTap()
        XCTAssertTrue(waitUntil(15, "Chapter 4") { [self] in chapterLabel == "Chapter 4" }, "reads \(chapterLabel)")
        XCTAssertGreaterThanOrEqual(nowPlayingElapsed() ?? 0, 449, "at Chapter 4's 7:30")
        // Well into the chapter (30 s on), the previous-chapter button goes
        // back to the top of this one, as a track skip does.
        next.padTap()
        XCTAssertTrue(waitUntil(10, "30 s into Chapter 4") { [self] in (nowPlayingElapsed() ?? 0) >= 478 })
        app.button(TestID.NowPlaying.previousChapter).padTap()
        XCTAssertTrue(waitUntil(15, "back to the top of Chapter 4") { [self] in
            let now = nowPlayingElapsed() ?? 0
            return now >= 449 && now < 460
        }, "at \(nowPlayingElapsed() ?? -1)")
        XCTAssertEqual(chapterLabel, "Chapter 4")
    }

    /// The transport's outer buttons are the glyphs' 30 s and 15 s.
    func testABooksSkipsAreThirtyForwardAndFifteenBack() throws {
        _ = try playChapterThree()
        XCTAssertEqual(next.label, "Skip forward 30 seconds")
        XCTAssertTrue(waitUntil(20, "the book to be playing") { [self] in (nowPlayingElapsed() ?? 0) >= 300 })
        let before = nowPlayingElapsed() ?? 0
        next.padTap()
        XCTAssertTrue(waitUntil(10, "30 s on") { [self] in (nowPlayingElapsed() ?? 0) >= before + 28 },
                      "from \(before) to \(nowPlayingElapsed() ?? -1)")
        let ahead = nowPlayingElapsed() ?? 0
        app.button(TestID.NowPlaying.previous).padTap()
        XCTAssertTrue(waitUntil(10, "15 s back") { [self] in
            let now = nowPlayingElapsed() ?? 0
            return now <= ahead - 12 && now >= ahead - 20
        }, "from \(ahead) to \(nowPlayingElapsed() ?? -1)")
    }

    /// Speed 1.5×: the book's clock runs half again as fast as the wall's.
    /// Fourteen seconds of book inside eleven of waiting can't happen at 1×.
    func testABooksSpeedMenuSpeedsItUp() throws {
        _ = try playChapterThree()
        XCTAssertTrue(waitUntil(20, "the book to be playing") { [self] in (nowPlayingElapsed() ?? 0) >= 301 })
        let speed = app.button(TestID.NowPlaying.speed)
        XCTAssertEqual(speed.label, "Speed")
        speed.padTap()
        tapMenuRow(TestID.NowPlaying.speedOption("1.5"), beginning: "1.5")
        let start = nowPlayingElapsed() ?? 0
        XCTAssertTrue(eventually(11) { [self] in (nowPlayingElapsed() ?? 0) >= start + 14 },
                      "1.5×: from \(start) the clock only reached \(nowPlayingElapsed() ?? -1)")
    }

    private var next: XCUIElement { app.button(TestID.NowPlaying.next) }
}
#endif
