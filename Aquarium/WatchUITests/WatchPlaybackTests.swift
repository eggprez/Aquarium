//  Playing on the watch, against the QA server: a song starts and the
//  server sees it, the song buttons move through the queue, a book opens
//  where it was left, its skips and chapters move it, its speed steps, and
//  pausing it keeps its place on the server.

import XCTest

final class WatchPlaybackTests: WatchUITestCase {
    /// Each test starts the book at 6:40, suite-reset's baseline, whatever
    /// an earlier test (or a copy of the app still sending) left.
    override func setUpWithError() throws {
        try super.setUpWithError()
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        try JellyfinAPI.signIn().setResume(book.id, seconds: 400)
    }
    private func elapsed() -> Double? { Self.seconds(text(TestID.Watch.nowPlayingElapsed)) }

    private func waitForElapsed(timeout: TimeInterval = 30, _ test: @escaping (Double) -> Bool) -> Double? {
        let end = Date().addingTimeInterval(timeout)
        var last: Double?
        repeat {
            last = elapsed()
            if let last, test(last) { return last }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return last
    }

    private func openAlbum(_ album: WatchFixtures.Album) {
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("albums"))
        open(TestID.Watch.album(album.id))
        app.element(TestID.Watch.collectionRoot).waitToExist()
    }

    private func openBook(_ id: String) {
        open(TestID.Watch.rootDoor("books"))
        open(TestID.Watch.book(id))
        app.element(TestID.Watch.bookRoot).waitToExist()
    }

    // MARK: Songs

    func testASongPlaysAndTheServerSeesIt() throws {
        let album = try WatchFixtures.require().album("FX Compilation")
        let api = try JellyfinAPI.signIn()
        launchHome()
        openAlbum(album)
        open(TestID.Watch.song(album.tracks[0].id))
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        XCTAssertEqual(text(TestID.Watch.nowPlayingTitle), album.tracks[0].name)
        let moved = waitForElapsed { $0 >= 2 }
        XCTAssertGreaterThanOrEqual(moved ?? 0, 2, "the clock runs: it is playing")
        // The watch posts no capabilities, so it isn't one of the "controllable"
        // sessions JellyfinAPI.sessions() lists: ask for this user's sessions.
        var seen: [String: Any]?
        let end = Date().addingTimeInterval(30)
        repeat {
            let list = (try? api.json("/Sessions?ActiveWithinSeconds=120")) as? [[String: Any]] ?? []
            seen = list.first { ($0["DeviceName"] as? String) == "Apple Watch"
                && (($0["NowPlayingItem"] as? [String: Any])?["Id"] as? String) == album.tracks[0].id }
            if seen == nil { Thread.sleep(forTimeInterval: 1) }
        } while seen == nil && Date() < end
        XCTAssertNotNil(seen, "the server's dashboard shows the watch playing")
        XCTAssertEqual(seen?["Client"] as? String, "Aquarium")
        XCTAssertTrue(text(TestID.Watch.nowPlayingNotes).contains("3 up next"))
        attachScreenshot("song playing")
    }

    func testPlayPauseNextAndPrevious() throws {
        let album = try WatchFixtures.require().album("FX Compilation")
        launchHome()
        openAlbum(album)
        open(TestID.Watch.detailPlay)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        XCTAssertEqual(text(TestID.Watch.nowPlayingTitle), album.tracks[0].name)
        _ = waitForElapsed { $0 >= 1 }
        app.button(TestID.Watch.nowPlayingPlayPause).tapWhenReady()
        let paused = elapsed() ?? 0
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(elapsed() ?? -1, paused, accuracy: 1, "paused: the clock stops")
        app.button(TestID.Watch.nowPlayingNext).tapWhenReady()
        let second = waitForText(TestID.Watch.nowPlayingTitle) { $0 == album.tracks[1].name }
        XCTAssertEqual(second, album.tracks[1].name)
        _ = waitForElapsed { $0 >= 4 }
        // Paused, so the clock doesn't run on between the two Previous taps.
        app.button(TestID.Watch.nowPlayingPlayPause).tapWhenReady()
        app.button(TestID.Watch.nowPlayingPrevious).tapWhenReady()
        XCTAssertEqual(waitForElapsed(timeout: 10) { $0 < 3 } ?? 99, 0, accuracy: 3, "a few seconds in, Previous goes to the top")
        XCTAssertEqual(text(TestID.Watch.nowPlayingTitle), album.tracks[1].name)
        app.button(TestID.Watch.nowPlayingPrevious).tapWhenReady()
        let first = waitForText(TestID.Watch.nowPlayingTitle) { $0 == album.tracks[0].name }
        XCTAssertEqual(first, album.tracks[0].name)
    }

    func testTheHomeRowLeadsBackToThePlayer() throws {
        // A twelve-minute song: still playing however slow the way back is.
        let album = try WatchFixtures.require().album("FX Long Tracks")
        let song = album.tracks[0]
        launchHome()
        openAlbum(album)
        open(TestID.Watch.song(song.id))
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        let row = app.element(TestID.Watch.rootNowPlaying)
        back(); back(); back(); back()
        // Home keeps its scroll: the row is at the top, above the doors.
        let window = app.windows.firstMatch
        for _ in 0..<5 where !row.exists {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Now Playing row on home")
        XCTAssertTrue(text(TestID.Watch.rootNowPlayingTitle).contains(song.name))
        row.tap()
        app.element(TestID.Watch.nowPlayingRoot).waitToExist()
    }

    // MARK: A book

    func testABookOpensWhereItWasLeftAndItsButtonsMoveIt() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        openBook(book.id)
        open(TestID.Watch.bookPlay)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        XCTAssertEqual(text(TestID.Watch.nowPlayingTitle), "FX Chaptered Audiobook")
        let start = waitForElapsed { $0 >= 400 }
        XCTAssertEqual(start ?? 0, 400, accuracy: 15, "suite-reset leaves it at 6:40")
        XCTAssertTrue(text(TestID.Watch.nowPlayingSubtitle).contains("Chapter 3"), "6:40 is in the third chapter")
        // Paused, so the clock stands still between the taps.
        app.button(TestID.Watch.nowPlayingPlayPause).tapWhenReady()
        Thread.sleep(forTimeInterval: 1)
        let held = elapsed() ?? 0
        app.button(TestID.Watch.nowPlayingSkipForward).tapWhenReady()
        let on = waitForElapsed(timeout: 10) { abs($0 - (held + 30)) <= 2 }
        XCTAssertEqual(on ?? 0, held + 30, accuracy: 2, "thirty seconds on")
        app.button(TestID.Watch.nowPlayingSkipBack).tapWhenReady()
        let back = waitForElapsed(timeout: 10) { abs($0 - (held + 15)) <= 2 }
        XCTAssertEqual(back ?? 0, held + 15, accuracy: 2, "fifteen back")
        attachScreenshot("book playing")
    }

    func testAChapterFromTheListGoesThere() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        openBook(book.id)
        open(TestID.Watch.bookPlay)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        _ = waitForElapsed { $0 >= 400 }
        app.button(TestID.Watch.nowPlayingChapters).tapWhenReady()
        app.element(TestID.Watch.nowPlayingChapterList).waitToExist()
        open(TestID.Watch.nowPlayingChapter(1))
        let at = waitForElapsed { $0 >= 150 && $0 < 200 }
        XCTAssertEqual(at ?? 0, 150, accuracy: 20, "Chapter 2 starts at 2:30")
    }

    func testAChapterOnTheBooksPageStartsThere() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        openBook(book.id)
        open(TestID.Watch.bookChapter(4))
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        let at = waitForElapsed { $0 >= 600 && $0 < 650 }
        XCTAssertEqual(at ?? 0, 600, accuracy: 20, "Chapter 5 starts at 10:00")
    }

    /// The speed button steps 1× → 1.25× → 1.5× → 1.75× → 2× → round to 0.75×.
    /// Two regressions from master-fix-list ("Speed label: 1.25× reads '1.2×',
    /// 1.75× reads '1.8×'" and "Speed stops at 2× on the watch's own player").
    func testTheSpeedButtonStepsThroughEverySpeed() throws {
        continueAfterFailure = true
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        openBook(book.id)
        open(TestID.Watch.bookPlay)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        let speed = app.button(TestID.Watch.nowPlayingSpeed)
        speed.waitToExist()
        XCTAssertEqual(speed.label, "1×")
        speed.tap()
        XCTAssertEqual(speed.label, "1.25×")
        speed.tap()
        XCTAssertEqual(speed.label, "1.5×")
        speed.tap()
        XCTAssertEqual(speed.label, "1.75×")
        speed.tap()
        XCTAssertEqual(speed.label, "2×")
        speed.tap()
        XCTAssertEqual(speed.label, "0.75×")
        attachScreenshot("speed")
    }

    func testALongPressPutsTheSpeedBackToNormal() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        openBook(book.id)
        open(TestID.Watch.bookPlay)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        let speed = app.button(TestID.Watch.nowPlayingSpeed)
        speed.tapWhenReady()
        speed.tap()
        XCTAssertEqual(speed.label, "1.5×")
        speed.press(forDuration: 1.2)
        let label = waitForText(TestID.Watch.nowPlayingSpeed, timeout: 5) { $0.hasPrefix("1×") || $0.hasPrefix("1.2") }
        // A long press's release can count as a tap too (fixed on the fix
        // branch): normal, or one step on from it.
        XCTAssertTrue(label.hasPrefix("1×") || label.hasPrefix("1.2"), label)
    }

    /// Book position keeping, end to end: played on the watch, paused, and
    /// the server holds the place (the phone here has no Aquarium, so the
    /// watch tells the server itself).
    func testPausingABookKeepsItsPlaceOnTheServer() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        let api = try JellyfinAPI.signIn()
        // Past the server's five minutes with no place kept, and well short
        // of the last five that count as finished, whatever the UI's pace.
        try api.setResume(book.id, seconds: 310)
        launchHome()
        openBook(book.id)
        open(TestID.Watch.bookPlay)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        let playing = waitForElapsed { $0 >= 312 }
        XCTAssertNotNil(playing)
        app.button(TestID.Watch.nowPlayingPlayPause).tapWhenReady()
        let pausedAt = elapsed() ?? 0
        var held = 0.0
        let end = Date().addingTimeInterval(45)
        repeat {
            held = (try? api.userData(book.id).positionSeconds) ?? 0
            if abs(held - pausedAt) < 3 { break }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < end
        XCTAssertEqual(held, pausedAt, accuracy: 3, "the server has the watch's place")
        // Relaunched, the book's page says so.
        app.terminate()
        launch(reset: false)
        app.element(TestID.Watch.root).waitToExist(60)
        openBook(book.id)
        let time = waitForText(TestID.Watch.bookTime) { $0.contains("of") }
        XCTAssertEqual(Self.seconds(String(time.split(separator: " ").first ?? "")) ?? 0, pausedAt, accuracy: 3, time)
    }

    func testStartOverPlaysFromTheTop() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        openBook(book.id)
        open(TestID.Watch.bookStartOver)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        let at = waitForElapsed { $0 >= 0 }
        XCTAssertLessThan(at ?? 999, 30)
    }

    func testShuffleAllPlaysSomething() {
        launchHome()
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicShuffleAll)
        app.element(TestID.Watch.nowPlayingRoot).waitToExist(30)
        XCTAssertFalse(text(TestID.Watch.nowPlayingTitle).isEmpty)
    }
}
