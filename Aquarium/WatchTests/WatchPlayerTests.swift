//  The watch's own player (Watch/WatchPlayer.swift): the queue and its
//  buttons, speed and its labels, keeping a book's place, counting a play
//  once, where a book opens, and the Smart Stack snapshot.
//
//  Audio itself is not opened here: `testLoad` puts the player where `play`
//  would have got to once the item opened and its seek landed. Playing real
//  audio is in the UI tests (WatchPlaybackTests).

import XCTest
@testable import AquariumWatch

final class WatchPlayerTests: WatchUnitTestCase {

    // MARK: Speed

    func testTheSpeedsOnOffer() {
        XCTAssertEqual(WatchPlayer.speeds, [0.75, 1, 1.25, 1.5, 1.75, 2])
    }

    func testTheSpeedStepsUpAndDown() {
        player.testLoad([WX.book("b")])
        player.speed = 1
        player.stepSpeed(1)
        XCTAssertEqual(player.speed, 1.25)
        player.stepSpeed(1)
        player.stepSpeed(1)
        XCTAssertEqual(player.speed, 1.75)
        player.stepSpeed(-1)
        XCTAssertEqual(player.speed, 1.5)
        player.speed = 0.75
        player.stepSpeed(-1)
        XCTAssertEqual(player.speed, 0.75, "nothing below the slowest")
    }

    /// Regression, master-fix-list "From Apple Watch": "Speed stops at 2× on
    /// the watch's own player; the phone remote wraps … WatchPlayer.swift:232".
    func testTheSpeedGoesRoundFromTheTop() {
        player.testLoad([WX.book("b")])
        player.speed = 2
        player.stepSpeed(1)
        XCTAssertEqual(player.speed, 0.75)
    }

    func testWholeSpeedsReadAsWholeNumbers() {
        XCTAssertEqual(NowPlayingScreen.speedLabel(1), "1×")
        XCTAssertEqual(NowPlayingScreen.speedLabel(2), "2×")
        XCTAssertEqual(NowPlayingScreen.speedLabel(0.75), "0.75×")
        XCTAssertEqual(NowPlayingScreen.speedLabel(1.5), "1.5×")
        XCTAssertEqual(PhonePlayerScreen.speedLabel(1), "1×")
        XCTAssertEqual(PhonePlayerScreen.speedLabel(1.5), "1.5×")
    }

    /// Regression, master-fix-list "Layout, all watches": "Speed label: 1.25×
    /// reads '1.2×', 1.75× reads '1.8×', on both players". Fixed on
    /// claude/qa-fix-list-cb0b58 (314251e), not on this branch.
    func testOnePointTwoFiveAndOnePointSevenFiveReadRight() {
        XCTExpectFailure("bug: %.2g shows 1.25× as 1.2× and 1.75× as 1.8× (NowPlayingScreen.speedLabel, PhonePlayerScreen.speedLabel)")
        XCTAssertEqual(NowPlayingScreen.speedLabel(1.25), "1.25×")
        XCTAssertEqual(NowPlayingScreen.speedLabel(1.75), "1.75×")
        XCTAssertEqual(PhonePlayerScreen.speedLabel(1.25), "1.25×")
        XCTAssertEqual(PhonePlayerScreen.speedLabel(1.75), "1.75×")
    }

    func testABooksSpeedIsRememberedAndASongsIsNot() {
        UserDefaults.standard.removeObject(forKey: "watch_book_speed")
        player.testLoad([WX.song("s")])
        player.speed = 1.5
        XCTAssertNil(UserDefaults.standard.object(forKey: "watch_book_speed"))
        player.testLoad([WX.book("b")])
        player.speed = 1.75
        XCTAssertEqual(UserDefaults.standard.double(forKey: "watch_book_speed"), 1.75)
    }

    // MARK: The queue

    func testTheQueueKnowsWhatIsNext() {
        player.testLoad([WX.song("a"), WX.song("b"), WX.song("c")], index: 1, position: 1)
        XCTAssertEqual(player.current?.Id, "b")
        XCTAssertTrue(player.hasNext)
        XCTAssertTrue(player.hasPrevious)
        XCTAssertEqual(player.upNextCount, 1)
        player.testLoad([WX.song("a")], position: 1)
        XCTAssertFalse(player.hasNext)
        XCTAssertFalse(player.hasPrevious)
        player.testLoad([WX.song("a")], position: 10)
        XCTAssertTrue(player.hasPrevious, "a few seconds in, Previous goes back to the top")
        XCTAssertEqual(player.upNextCount, 0)
    }

    func testPreviousPartWayInGoesToTheTop() {
        player.testLoad([WX.song("a"), WX.song("b")], index: 1, position: 40)
        player.skipPrevious()
        XCTAssertEqual(player.current?.Id, "b")
        XCTAssertEqual(player.position, 0)
    }

    /// Regression, f72bd13: "Next on the last track stops the player … rather
    /// than leaving the song playing under a stopped screen."
    func testNextOnTheLastSongStops() {
        player.testLoad([WX.song("a")], position: 5)
        player.skipNext()
        XCTAssertFalse(player.isActive)
        XCTAssertNil(player.current)
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testPlayLaterAddsToAQueueThatIsUp() {
        player.testLoad([WX.song("a")])
        player.playLater([WX.song("b"), WX.album("not-audio")])
        XCTAssertEqual(player.queue.map(\.item.Id), ["a", "b"])
    }

    func testPlayLeavesOutWhatIsntAudioAndShuffleKeepsTheChosenFirst() {
        player.play([WX.album("x")])
        XCTAssertFalse(player.isActive, "nothing playable, nothing played")
        let requests = player.playRequests
        let songs = (0..<20).map { WX.song("s\($0)") }
        player.play(songs, startingAt: 7, shuffle: true, title: "Mix")
        XCTAssertEqual(player.current?.Id, "s7")
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(player.queue.count, 20)
        XCTAssertEqual(player.queueTitle, "Mix")
        XCTAssertEqual(player.playRequests, requests &+ 1, "the shell brings the player up")
        player.testReset()
    }

    func testSeekStaysInsideTheItem() {
        player.testLoad([WX.book("b", seconds: 900)], position: 10)
        player.seek(by: -60)
        XCTAssertEqual(player.position, 0)
        player.seek(to: 5000)
        XCTAssertEqual(player.position, 900)
        player.seek(by: -15)
        XCTAssertEqual(player.position, 885)
    }

    // MARK: Chapters

    func testChapterSkipsAndTheCurrentChapter() {
        player.testLoad([WX.book("b", seconds: 900, chapters: [0, 150, 300, 450])], position: 160)
        XCTAssertEqual(player.currentChapter?.Name, "Chapter 2")
        player.skipChapter(1)
        XCTAssertEqual(player.position, 300)
        player.skipChapter(-1)
        XCTAssertEqual(player.position, 150, "at the start of a chapter, back goes to the one before")
        player.seek(to: 200)
        player.skipChapter(-1)
        XCTAssertEqual(player.position, 150, "part-way in, back goes to its start")
        player.seek(to: 10)
        player.skipChapter(-1)
        XCTAssertEqual(player.position, 0)
    }

    func testWithNoChaptersTheSkipsAreThirtyAndFifteen() {
        player.testLoad([WX.book("b", seconds: 900)], position: 100)
        player.skipChapter(1)
        XCTAssertEqual(player.position, 130)
        player.skipChapter(-1)
        XCTAssertEqual(player.position, 115)
    }

    // MARK: Keeping a book's place

    private func bookOnWatch(_ id: String = "b", length: Double = 900) -> BaseItem {
        downloads.enqueue([WX.book(id, seconds: length)], reason: "book")
        downloads.testUpdate(id) { $0.status = .complete }
        return downloads.record(for: id)!.asItem
    }

    func testPausingABookNotesItsPlaceAndQueuesItForTheServer() {
        let book = bookOnWatch()
        player.testLoad([book], position: 87)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(Double(downloads.record(for: "b")!.positionTicks) / 10_000_000, 87, accuracy: 0.01)
        let event = sync.pending.first { $0.itemId == "b" }
        XCTAssertEqual(event?.positionTicks, WX.ticks(87))
        XCTAssertEqual(event?.played, false)
        XCTAssertEqual(event?.isAudiobook, true)
        XCTAssertEqual(event?.streamed, false)
    }

    /// Regression, 1228f45: "No position is recorded until the seek to the
    /// resume point lands, so an early pause no longer writes 0."
    func testAPauseBeforeTheSeekLandsWritesNothing() {
        let book = bookOnWatch()
        downloads.testUpdate("b") { $0.positionTicks = WX.ticks(400) }
        player.testLoad([book], position: 0, positionKnown: false)
        player.pause()
        XCTAssertEqual(downloads.record(for: "b")?.positionTicks, WX.ticks(400))
        XCTAssertTrue(sync.pending.isEmpty)
    }

    func testAStreamedBookSaysSo() {
        player.testLoad([WX.book("b")], position: 30, streamed: true)
        player.pause()
        XCTAssertEqual(sync.pending.first?.streamed, true)
    }

    /// Regression, 1228f45: "The minute tick only ever sends a position, so
    /// pausing near the end no longer zeroes the book or counts a play every
    /// minute."
    func testTheMinuteNoteNearTheEndIsOnlyAPosition() {
        _ = bookOnWatch(length: 3600)
        player.testLoad([downloads.record(for: "b")!.asItem], position: 3500)
        player.note(finished: false, periodic: true)
        let event = sync.pending.first
        XCTAssertEqual(event?.played, false)
        XCTAssertEqual(event?.positionTicks, WX.ticks(3500))
    }

    /// Regression, f72bd13: "The watch counts a play once even when paused in
    /// the closing stretch."
    func testABookPausedInItsLastMinutesThenFinishedCountsOnce() {
        _ = bookOnWatch(length: 3600)
        player.testLoad([downloads.record(for: "b")!.asItem], position: 3500)
        player.pause()
        player.note(finished: true)
        let plays = sync.pending.filter { $0.itemId == "b" && $0.played }
        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays.first?.positionTicks, WX.ticks(3600), "a finish goes as the whole length")
        XCTAssertEqual(downloads.record(for: "b")?.played, true)
    }

    func testASongIsHeardPastNinetyPercentAndCountedOnce() {
        player.testLoad([WX.song("s", seconds: 100)], position: 95)
        player.pause()
        player.note(finished: true)
        XCTAssertEqual(sync.pending.filter { $0.itemId == "s" && $0.played }.count, 1)
    }

    func testASongStoppedHalfWayIsNotAPlay() {
        player.testLoad([WX.song("s", seconds: 100)], position: 50)
        player.pause()
        XCTAssertTrue(sync.pending.isEmpty)
    }

    func testCheckpointNotesAPlayingBookOnTheWayToTheBackground() {
        player.testLoad([WX.book("b", seconds: 900)], position: 300, playing: true)
        player.checkpoint()
        XCTAssertEqual(sync.pending.first?.positionTicks, WX.ticks(300))
        sync.testReset()
        player.testLoad([WX.song("s")], position: 10, playing: true)
        player.checkpoint()
        XCTAssertTrue(sync.pending.isEmpty, "only a book")
    }

    func testTheClockNotesABooksPlaceAsItPlays() {
        _ = bookOnWatch()
        player.testLoad([downloads.record(for: "b")!.asItem], position: 0, playing: true)
        player.tick(42)
        XCTAssertEqual(player.position, 42)
        XCTAssertEqual(Double(downloads.record(for: "b")!.positionTicks) / 10_000_000, 42, accuracy: 0.01)
        XCTAssertEqual(sync.pending.first?.positionTicks, WX.ticks(42), "and once a minute, the server")
        player.tick(.nan)
        XCTAssertEqual(player.position, 42)
    }

    func testTheClockIgnoresTicksBeforeTheSeekLands() {
        player.testLoad([WX.book("b")], position: 400, playing: true, positionKnown: false)
        player.tick(0)
        XCTAssertEqual(player.position, 400)
    }

    // MARK: Where a book opens

    func testWhereABookOpens() {
        XCTAssertEqual(player.resumePoint(for: WX.book("b"), explicit: 150), 150, "a chapter tapped")
        XCTAssertEqual(player.resumePoint(for: WX.song("s", position: 50), explicit: nil), 0, "songs start at the top")
        XCTAssertEqual(player.resumePoint(for: WX.book("x", seconds: 900, position: 87), explicit: nil), 87, accuracy: 0.01)
        XCTAssertEqual(player.resumePoint(for: WX.book("x", seconds: 900, position: 87, played: true), explicit: nil), 0)
        XCTAssertEqual(player.resumePoint(for: WX.book("x", seconds: 900, position: 800), explicit: nil), 0, "finished by the server's rule")
        _ = bookOnWatch()
        downloads.testUpdate("b") { $0.positionTicks = WX.ticks(321) }
        XCTAssertEqual(player.resumePoint(for: WX.book("b", position: 10), explicit: nil), 321, accuracy: 0.01,
                       "the record, not a list row loaded an hour ago")
        XCTAssertEqual(player.resumePoint(for: WX.book("b"), explicit: -5), 0)
    }

    // MARK: The Smart Stack

    func testTheCardRedrawsOnlyWhenItChanges() {
        let a = ListeningSnapshot(itemId: "a", title: "A", subtitle: "x", isAudiobook: true, isPlaying: true, position: 100, duration: 3600)
        XCTAssertFalse(WatchPlayer.worthRedrawing(nil, over: nil))
        XCTAssertTrue(WatchPlayer.worthRedrawing(a, over: nil))
        XCTAssertTrue(WatchPlayer.worthRedrawing(nil, over: a))
        var b = a
        b.position = 130
        XCTAssertFalse(WatchPlayer.worthRedrawing(b, over: a), "half a minute of a long book moves nothing")
        b.position = 170
        XCTAssertTrue(WatchPlayer.worthRedrawing(b, over: a))
        b = a; b.isPlaying = false
        XCTAssertTrue(WatchPlayer.worthRedrawing(b, over: a))
        b = a; b.subtitle = "y"
        XCTAssertTrue(WatchPlayer.worthRedrawing(b, over: a))
        b = a; b.itemId = "z"
        XCTAssertTrue(WatchPlayer.worthRedrawing(b, over: a))
    }

    func testStopClearsEverything() {
        player.testLoad([WX.song("a"), WX.song("b")], position: 10)
        player.stop()
        XCTAssertFalse(player.isActive)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.currentIndex)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertTrue(player.chapters.isEmpty)
    }
}
