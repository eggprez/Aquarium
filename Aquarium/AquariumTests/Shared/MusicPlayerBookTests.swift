//  Audiobooks in the music player: chapters, where a book opens, and speed.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicPlayerBookTests: XCTestCase {
    private var player: MusicPlayer { .shared }
    private var savedSpeed = 1.0
    private var savedAutoplay = true

    override func setUp() async throws {
        MusicServer.install()
        savedSpeed = Preferences.shared.audiobookSpeed
        savedAutoplay = Preferences.shared.musicAutoplay
        Preferences.shared.musicAutoplay = false
        Preferences.shared.audiobookSpeed = 1
        player.stop(tellServer: false)
    }

    override func tearDown() async throws {
        player.stop(tellServer: false)
        MusicOnDevice.removeAll()
        Preferences.shared.audiobookSpeed = savedSpeed
        Preferences.shared.musicAutoplay = savedAutoplay
        await settle()
        MusicServer.remove()
    }

    /// An hour, in four chapters of fifteen minutes.
    private var book: BaseItem { MusicFixture.book("book", seconds: 3600, chapters: [0, 900, 1800, 2700]) }

    // MARK: Chapters

    func testABooksChaptersComeWithIt() {
        player.play([book])
        XCTAssertEqual(player.chapters.count, 4)
        XCTAssertEqual(player.currentChapter?.Name, "Chapter 1")
        XCTAssertEqual(player.duration, 3600)
    }

    func testTheChapterIsTheOneThePositionIsInside() {
        player.play([book])
        player.seek(to: 899)
        XCTAssertEqual(player.currentChapter?.Name, "Chapter 1")
        player.seek(to: 899.6)
        XCTAssertEqual(player.currentChapter?.Name, "Chapter 2", "half a second early still counts: a seek to a chapter lands a touch short")
        player.seek(to: 2000)
        XCTAssertEqual(player.currentChapter?.Name, "Chapter 3")
        player.seek(to: 3500)
        XCTAssertEqual(player.currentChapter?.Name, "Chapter 4")
    }

    func testASongHasNoChapter() {
        player.play([MusicFixture.song("s")])
        XCTAssertTrue(player.chapters.isEmpty)
        XCTAssertNil(player.currentChapter)
    }

    func testNextOnABookIsTheNextChapterNotTheNextItem() {
        player.play([book, MusicFixture.song("after")])
        player.seek(to: 100)
        player.skipNext()
        XCTAssertEqual(player.position, 900)
        XCTAssertEqual(player.currentIndex, 0, "still the book")
        player.skipNext()
        XCTAssertEqual(player.position, 1800)
    }

    func testNextInTheLastChapterStaysPut() {
        player.play([book])
        player.seek(to: 3000)
        player.skipNext()
        XCTAssertEqual(player.position, 3000)
        XCTAssertFalse(player.reachedEndOfQueue, "a stray Next must not end the book")
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testPreviousOnABookIsTheTopOfTheChapterThenTheOneBefore() {
        player.play([MusicFixture.song("before"), book], startingAt: 1)
        player.seek(to: 1000)
        player.skipPrevious()
        XCTAssertEqual(player.position, 900, "well into chapter two: back to its start")
        player.skipPrevious()
        XCTAssertEqual(player.position, 0, "only just started it: the chapter before")
        player.skipPrevious()
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.currentIndex, 1, "and never out of the book")
    }

    func testABookWithoutChaptersSkipsThirtyOnAndFifteenBack() {
        player.play([MusicFixture.book("plain", seconds: 3600)])
        player.seek(to: 100)
        player.skipNext()
        XCTAssertEqual(player.position, 130)
        player.skipPrevious()
        XCTAssertEqual(player.position, 115)
        player.skipChapter(-1)
        XCTAssertEqual(player.position, 100)
    }

    // MARK: Where a book opens

    func testAnExplicitPositionWinsAndIsNeverNegative() {
        let left = MusicFixture.book("b", seconds: 3600, positionSeconds: 1200)
        XCTAssertEqual(player.resumePoint(for: left, explicit: 30), 30)
        XCTAssertEqual(player.resumePoint(for: left, explicit: 0), 0, "start over means the top")
        XCTAssertEqual(player.resumePoint(for: left, explicit: -5), 0)
    }

    func testABookOpensWhereTheServerSaysItWasLeft() {
        let left = MusicFixture.book("b", seconds: 3600, positionSeconds: 1200)
        XCTAssertEqual(player.resumePoint(for: left, explicit: nil), 1200)
    }

    func testABookLeftInItsLastMomentsOpensAtTheTop() {
        let done = MusicFixture.book("b", seconds: 3600, positionSeconds: 3590)
        XCTAssertEqual(player.resumePoint(for: done, explicit: nil), 0)
    }

    func testABookNeverStartedOrOfUnknownLengthOpensAtTheTop() {
        XCTAssertEqual(player.resumePoint(for: MusicFixture.book("b", seconds: 3600), explicit: nil), 0)
        var noLength = MusicFixture.book("b", seconds: 3600, positionSeconds: 500)
        noLength.RunTimeTicks = nil
        XCTAssertEqual(player.resumePoint(for: noLength, explicit: nil), 0)
    }

    func testASongAlwaysOpensAtTheTop() {
        var song = MusicFixture.song("s", seconds: 300)
        var data = UserData()
        data.PlaybackPositionTicks = 100 * 10_000_000
        song.UserData = data
        XCTAssertEqual(player.resumePoint(for: song, explicit: nil), 0)
    }

    func testADownloadedBookOpensWhereThisDeviceLeftIt() {
        // The server's copy of the position is older than the device's.
        let left = MusicFixture.book("dl-book", seconds: 3600, positionSeconds: 300)
        MusicOnDevice.add(left, positionSeconds: 1500)
        XCTAssertEqual(player.resumePoint(for: left, explicit: nil), 1500)
    }

    func testADownloadedBookAlreadyFinishedOpensAtTheTop() {
        let done = MusicFixture.book("dl-done", seconds: 3600, positionSeconds: 300)
        MusicOnDevice.add(done, played: true, positionSeconds: 1500)
        XCTAssertEqual(player.resumePoint(for: done, explicit: nil), 0)

        let nearEnd = MusicFixture.book("dl-near-end", seconds: 3600)
        MusicOnDevice.add(nearEnd, positionSeconds: 3400)
        XCTAssertEqual(player.resumePoint(for: nearEnd, explicit: nil), 0, "under five minutes left is finished")
    }

    func testADownloadedSongStillOpensAtTheTop() {
        let song = MusicFixture.song("dl-song", seconds: 300)
        MusicOnDevice.add(song, positionSeconds: 100)
        XCTAssertEqual(player.resumePoint(for: song, explicit: nil), 0)
    }

    // MARK: Speed

    func testABookOpensAtTheRememberedSpeedAndASongAtNormalSpeed() {
        Preferences.shared.audiobookSpeed = 1.5
        player.play([book, MusicFixture.song("s")])
        XCTAssertEqual(player.speed, 1.5)
        player.skip(to: player.queue[1])
        XCTAssertEqual(player.speed, 1)
        XCTAssertEqual(Preferences.shared.audiobookSpeed, 1.5, "a song's speed is not the book's to remember")
    }

    func testChangingSpeedOnABookIsRemembered() {
        player.play([book])
        player.speed = 1.25
        XCTAssertEqual(Preferences.shared.audiobookSpeed, 1.25)
    }

    func testChangingSpeedOnASongIsNotRemembered() {
        player.play([MusicFixture.song("s")])
        player.speed = 1.5
        XCTAssertEqual(player.speed, 1.5)
        XCTAssertEqual(Preferences.shared.audiobookSpeed, 1)
    }

    func testSteppingSpeedWalksTheListAndStopsAtItsEnds() {
        XCTAssertEqual(MusicPlayer.speeds, [0.75, 1, 1.25, 1.5, 1.75, 2])
        player.play([book])
        player.stepSpeed(1)
        XCTAssertEqual(player.speed, 1.25)
        player.stepSpeed(-1)
        player.stepSpeed(-1)
        XCTAssertEqual(player.speed, 0.75)
        player.stepSpeed(-1)
        XCTAssertEqual(player.speed, 0.75)
        for _ in 0..<10 { player.stepSpeed(1) }
        XCTAssertEqual(player.speed, 2)
    }

    func testSteppingFromASpeedNotOnTheListStartsFromNormal() {
        player.play([book])
        player.speed = 1.1
        player.stepSpeed(1)
        XCTAssertEqual(player.speed, 1.25)
    }
}
#endif
