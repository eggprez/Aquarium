//  The music player's queue: what order things play in, and what shuffle,
//  repeat, Next, Previous, Play Next and Play Later do to it. Nothing here
//  waits for sound: each test reads the queue straight after the call that
//  changed it, before the player has opened anything.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicPlayerQueueTests: XCTestCase {
    private var player: MusicPlayer { .shared }
    private var savedAutoplay = true
    private var savedRepeat = MusicPlayer.RepeatMode.off

    override func setUp() async throws {
        MusicServer.install()
        savedAutoplay = Preferences.shared.musicAutoplay
        savedRepeat = player.repeatMode
        Preferences.shared.musicAutoplay = false
        player.stop(tellServer: false)
        player.repeatMode = .off
    }

    override func tearDown() async throws {
        player.stop(tellServer: false)
        MusicOnDevice.removeAll()
        player.repeatMode = savedRepeat
        Preferences.shared.musicAutoplay = savedAutoplay
        await settle()
        MusicServer.remove()
    }

    private var ids: [String] { player.queue.map(\.item.Id) }
    private func songs(_ n: Int) -> [BaseItem] { MusicFixture.songs((0..<n).map { "s\($0)" }) }

    // MARK: Starting

    func testPlayQueuesTheSongsAndStartsWhereAsked() {
        player.play(songs(4), startingAt: 2, title: "An Album")
        XCTAssertEqual(ids, ["s0", "s1", "s2", "s3"])
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.current?.Id, "s2")
        XCTAssertTrue(player.isActive)
        XCTAssertTrue(player.isBuffering, "nothing has been opened yet")
        XCTAssertEqual(player.queueTitle, "An Album")
        XCTAssertEqual(player.upNext.map(\.item.Id), ["s3"])
        XCTAssertTrue(player.hasUpNext)
        XCTAssertEqual(player.upNextCount, 1)
        XCTAssertEqual(player.duration, 200, "the song's own length until the file says otherwise")
        XCTAssertFalse(player.isShuffled)
        XCTAssertNil(player.station)
    }

    func testOnlyThingsTheMusicPlayerOpensAreQueued() {
        let film = MusicFixture.item("film", "A Film", type: "Movie")
        player.play([film] + songs(2) + [MusicFixture.book("book")])
        XCTAssertEqual(ids, ["s0", "s1", "book"])
    }

    func testNothingPlayableLeavesThePlayerAsItWas() {
        player.play([MusicFixture.item("film", "A Film", type: "Movie")])
        XCTAssertFalse(player.isActive)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentIndex)
    }

    func testStartIndexIsKeptInsideTheQueue() {
        player.play(songs(3), startingAt: 99)
        XCTAssertEqual(player.currentIndex, 2)
        player.play(songs(3), startingAt: -4)
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testPlayAtAPositionOpensThere() {
        player.play(songs(2), at: 42)
        XCTAssertEqual(player.position, 42)
    }

    func testANewQueueReplacesTheOldOne() {
        player.play(songs(5), startingAt: 3, shuffle: true, title: "First")
        player.play(MusicFixture.songs(["x", "y"]), title: "Second")
        XCTAssertEqual(ids, ["x", "y"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(player.queueTitle, "Second")
    }

    // MARK: Up next, and the counts drawn from it

    func testUpNextIsEmptyOnTheLastSongAndWithNothingPlaying() {
        XCTAssertEqual(player.upNext.count, 0)
        XCTAssertFalse(player.hasUpNext)
        XCTAssertEqual(player.upNextCount, 0)
        XCTAssertFalse(player.hasNext)
        player.play(songs(2), startingAt: 1)
        XCTAssertTrue(player.upNext.isEmpty)
        XCTAssertFalse(player.hasUpNext)
        XCTAssertEqual(player.upNextCount, 0)
    }

    // MARK: Shuffle

    func testStartingShuffledPutsTheChosenSongFirstAndKeepsEverySong() {
        player.play(songs(12), startingAt: 5, shuffle: true)
        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.current?.Id, "s5")
        XCTAssertEqual(Set(ids), Set((0..<12).map { "s\($0)" }))
        XCTAssertEqual(ids.count, 12)
    }

    func testTurningShuffleOffAfterAShuffledStartGivesTheChosenSongThenTheRestInOrder() {
        player.play(songs(6), startingAt: 3, shuffle: true)
        player.toggleShuffle()
        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(ids, ["s3", "s0", "s1", "s2", "s4", "s5"])
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testShuffleOnLeavesWhatHasPlayedAndTheCurrentSongInPlace() {
        player.play(songs(30), startingAt: 4)
        player.toggleShuffle()
        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(Array(ids[...4]), ["s0", "s1", "s2", "s3", "s4"])
        XCTAssertEqual(player.currentIndex, 4)
        XCTAssertEqual(Set(ids[5...]), Set((5..<30).map { "s\($0)" }))
        XCTAssertNotEqual(Array(ids[5...]), (5..<30).map { "s\($0)" }, "25 songs came back in the order they went in")
    }

    func testShuffleOffRestoresTheOrderWithThePlayheadOnTheSameSong() {
        player.play(songs(10), startingAt: 2)
        player.toggleShuffle()
        // Move on inside the shuffled order, then turn it off.
        player.skipNext()
        player.skipNext()
        let playing = player.current?.Id
        player.toggleShuffle()
        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(ids, (0..<10).map { "s\($0)" })
        XCTAssertEqual(player.current?.Id, playing)
    }

    func testSongsQueuedWhileShuffledKeepTheirPlacesWhenShuffleGoesOff() {
        player.play(songs(5), startingAt: 1)
        player.toggleShuffle()
        player.playNext([MusicFixture.song("next")])
        player.playLater([MusicFixture.song("later")])
        player.toggleShuffle()
        XCTAssertEqual(ids, ["s0", "s1", "next", "s2", "s3", "s4", "later"])
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testASongRemovedWhileShuffledStaysRemoved() {
        player.play(songs(6))
        player.toggleShuffle()
        let gone = player.upNext[2]
        player.remove(gone)
        player.toggleShuffle()
        XCTAssertFalse(ids.contains(gone.item.Id))
        XCTAssertEqual(ids.count, 5)
    }

    func testShuffleDoesNothingWithNothingPlaying() {
        player.toggleShuffle()
        XCTAssertFalse(player.isShuffled)
    }

    // MARK: Play Next and Play Later

    func testPlayNextGoesStraightAfterTheCurrentSongInTheOrderGiven() {
        player.play(songs(3), startingAt: 1)
        player.playNext(MusicFixture.songs(["a", "b"]))
        XCTAssertEqual(ids, ["s0", "s1", "a", "b", "s2"])
        XCTAssertEqual(player.currentIndex, 1)
        // A second lot goes ahead of the first: it is "next" now.
        player.playNext([MusicFixture.song("c")])
        XCTAssertEqual(ids, ["s0", "s1", "c", "a", "b", "s2"])
    }

    func testPlayLaterGoesOnTheEnd() {
        player.play(songs(2))
        player.playLater(MusicFixture.songs(["a", "b"]))
        XCTAssertEqual(ids, ["s0", "s1", "a", "b"])
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testPlayNextAndPlayLaterStartAQueueWhenNothingIsPlaying() {
        player.playNext(MusicFixture.songs(["a", "b"]))
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertTrue(player.isActive)
        player.stop(tellServer: false)
        player.playLater(MusicFixture.songs(["c"]))
        XCTAssertEqual(ids, ["c"])
        XCTAssertTrue(player.isActive)
    }

    func testPlayNextAndPlayLaterIgnoreWhatIsNotAudio() {
        player.play(songs(2))
        let film = MusicFixture.item("film", "A Film", type: "Movie")
        player.playNext([film])
        player.playLater([film])
        XCTAssertEqual(ids, ["s0", "s1"])
    }

    // MARK: Repeat

    func testRepeatCyclesOffAllOneAndIsRemembered() {
        XCTAssertEqual(MusicPlayer.RepeatMode.off.next, .all)
        XCTAssertEqual(MusicPlayer.RepeatMode.all.next, .one)
        XCTAssertEqual(MusicPlayer.RepeatMode.one.next, .off)
        player.repeatMode = .all
        XCTAssertEqual(Preferences.shared.musicRepeat, "all")
        player.repeatMode = .one
        XCTAssertEqual(Preferences.shared.musicRepeat, "one")
    }

    func testHasNextOnTheLastSongOnlyWhenRepeatingAll() {
        player.play(songs(2), startingAt: 1)
        XCTAssertFalse(player.hasNext)
        player.repeatMode = .one
        XCTAssertFalse(player.hasNext)
        player.repeatMode = .all
        XCTAssertTrue(player.hasNext)
        player.repeatMode = .off
        player.skipPrevious()
        XCTAssertTrue(player.hasNext, "a song follows the first one")
    }

    // MARK: Next and Previous

    func testNextWalksTheQueueAndStopsAtTheEnd() {
        player.play(songs(3))
        player.skipNext()
        XCTAssertEqual(player.currentIndex, 1)
        player.skipNext()
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertFalse(player.reachedEndOfQueue)
        player.skipNext()
        XCTAssertTrue(player.reachedEndOfQueue)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isBuffering)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.currentIndex, 2, "the last song stays on the card")
        XCTAssertEqual(ids, ["s0", "s1", "s2"], "the queue is still there to start over")
        XCTAssertTrue(player.isActive)
    }

    func testPlayAfterTheEndStartsTheQueueOver() {
        player.play(songs(3), startingAt: 2)
        player.skipNext()
        XCTAssertTrue(player.reachedEndOfQueue)
        player.togglePlayPause()
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertFalse(player.reachedEndOfQueue)

        player.skip(to: player.queue[2])
        player.skipNext()
        XCTAssertTrue(player.reachedEndOfQueue)
        player.resume()
        XCTAssertEqual(player.currentIndex, 0, "resume, which the lock screen sends, does the same")
    }

    func testNextOnTheLastSongWrapsWhenRepeatingAll() {
        player.repeatMode = .all
        player.play(songs(3), startingAt: 2)
        player.skipNext()
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertFalse(player.reachedEndOfQueue)
    }

    func testNextStepsPastRepeatOne() {
        player.repeatMode = .one
        player.play(songs(3))
        player.skipNext()
        XCTAssertEqual(player.currentIndex, 1, "a pressed Next moves on; only a song that ends repeats")
        player.skipNext()
        player.skipNext()
        XCTAssertTrue(player.reachedEndOfQueue, "and at the end it stops, as with repeat off")
    }

    func testPreviousGoesBackASongNearTheStartAndRestartsTheSongLaterOn() {
        player.play(songs(3), startingAt: 2)
        player.skipPrevious()
        XCTAssertEqual(player.currentIndex, 1)

        player.seek(to: 10)
        XCTAssertEqual(player.position, 10)
        player.skipPrevious()
        XCTAssertEqual(player.currentIndex, 1, "more than three seconds in, Previous is the top of this song")
        XCTAssertEqual(player.position, 0)

        player.skipPrevious()
        XCTAssertEqual(player.currentIndex, 0)
        player.skipPrevious()
        XCTAssertEqual(player.currentIndex, 0, "nothing before the first song")
        XCTAssertEqual(player.position, 0)
    }

    func testHasPreviousOnTheFirstSongOnlyOnceItHasPlayedAWhile() {
        player.play(songs(2))
        XCTAssertFalse(player.hasPrevious)
        player.seek(to: 5)
        XCTAssertTrue(player.hasPrevious)
        player.skipNext()
        XCTAssertTrue(player.hasPrevious)
    }

    func testNextAndPreviousDoNothingWithNothingPlaying() {
        player.skipNext()
        player.skipPrevious()
        XCTAssertFalse(player.isActive)
        XCTAssertNil(player.currentIndex)
    }

    // MARK: Seeking

    func testSeekStaysInsideTheSong() {
        player.play(songs(1))
        player.seek(to: -20)
        XCTAssertEqual(player.position, 0)
        player.seek(to: 5000)
        XCTAssertEqual(player.position, 199.75, accuracy: 0.001, "just short of the end, so the song still ends by itself")
        player.seek(to: 60)
        player.seek(by: 15)
        XCTAssertEqual(player.position, 75)
        player.seek(by: -100)
        XCTAssertEqual(player.position, 0)
    }

    // MARK: Changing the queue by hand

    func testJumpingToAQueuedSongPlaysItAndKeepsTheQueue() {
        player.play(songs(5))
        player.skip(to: player.queue[3])
        XCTAssertEqual(player.currentIndex, 3)
        XCTAssertEqual(ids.count, 5)
        // An entry that isn't in the queue is ignored.
        player.skip(to: MusicPlayer.Entry(MusicFixture.song("stranger")))
        XCTAssertEqual(player.currentIndex, 3)
    }

    func testTheSameSongQueuedTwiceIsTwoPlaces() {
        let song = MusicFixture.song("twice")
        player.play([song, MusicFixture.song("other"), song])
        XCTAssertNotEqual(player.queue[0], player.queue[2])
        player.skip(to: player.queue[2])
        XCTAssertEqual(player.currentIndex, 2)
        player.remove(player.queue[0])
        XCTAssertEqual(ids, ["other", "twice"])
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testRemovingASongKeepsThePlayheadOnWhatIsPlaying() {
        player.play(songs(5), startingAt: 2)
        player.remove(player.queue[0])
        XCTAssertEqual(ids, ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(player.current?.Id, "s2")
        player.remove(player.queue[3])
        XCTAssertEqual(ids, ["s1", "s2", "s3"])
        XCTAssertEqual(player.current?.Id, "s2")
    }

    func testRemovingTheSongPlayingMovesToTheOneAfterIt() {
        player.play(songs(3), startingAt: 1)
        player.remove(player.queue[1])
        XCTAssertEqual(ids, ["s0", "s2"])
        XCTAssertEqual(player.current?.Id, "s2")
        // The last one playing: back to the one before it.
        player.remove(player.queue[1])
        XCTAssertEqual(player.current?.Id, "s0")
        // The only one: the player closes.
        player.remove(player.queue[0])
        XCTAssertFalse(player.isActive)
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testMovingWithinUpNextCountsFromTheSongAfterTheCurrentOne() {
        player.play(songs(5), startingAt: 1)
        // Up Next is s2 s3 s4: take the first to the end.
        player.moveUpNext(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(ids, ["s0", "s1", "s3", "s4", "s2"])
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testClearingUpNextKeepsWhatHasPlayedAndTheCurrentSong() {
        player.play(songs(5), startingAt: 2)
        player.clearUpNext()
        XCTAssertEqual(ids, ["s0", "s1", "s2"])
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertFalse(player.hasUpNext)
    }

    func testReplacingWhatIsComingKeepsTheSongPlaying() {
        player.play(songs(4), startingAt: 1, title: "Album")
        player.toggleShuffle()
        player.replaceUpcoming(with: MusicFixture.songs(["m1", "m2"]), title: "A Mix", station: nil, offlineFallback: false)
        XCTAssertEqual(ids, ["s0", "s1", "m1", "m2"])
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.queueTitle, "A Mix")
        XCTAssertFalse(player.isShuffled, "a mix arrives in its own order")
        XCTAssertFalse(player.mixIsOfflineFallback)
    }

    func testReplacingWhatIsComingStartsAQueueWhenNothingIsPlaying() {
        player.replaceUpcoming(with: MusicFixture.songs(["m1", "m2"]), title: "A Mix", station: nil, offlineFallback: false)
        XCTAssertEqual(ids, ["m1", "m2"])
        XCTAssertEqual(player.queueTitle, "A Mix")
        XCTAssertTrue(player.isActive)
    }

    func testReplacingWithNothingChangesNothing() {
        player.play(songs(3), title: "Album")
        player.replaceUpcoming(with: [], title: "A Mix", station: nil, offlineFallback: true)
        XCTAssertEqual(ids, ["s0", "s1", "s2"])
        XCTAssertEqual(player.queueTitle, "Album")
    }

    // MARK: After the queue has run out

    func testSomethingQueuedAfterTheEndIsWhatPlayOpens() {
        player.play(songs(1))
        player.skipNext()
        XCTAssertTrue(player.reachedEndOfQueue)
        player.playLater([MusicFixture.song("more")])
        XCTAssertFalse(player.reachedEndOfQueue)
        player.resume()
        XCTAssertEqual(player.current?.Id, "more", "not the song that already ended")
    }

    // MARK: Stars

    func testAStarSetInThePlayerShowsOnEveryQueuedCopy() {
        let song = MusicFixture.song("star")
        player.play([song, MusicFixture.song("other"), song])
        player.markFavorite("star", true)
        XCTAssertEqual(player.queue.map { $0.item.userData.isFavorite }, [true, false, true])
        player.markFavorite("star", false)
        XCTAssertEqual(player.queue.map { $0.item.userData.isFavorite }, [false, false, false])
    }

    // MARK: Stopping

    func testStopClearsEverything() {
        player.play(songs(3), startingAt: 1, shuffle: true, title: "Album")
        player.setSleepTimer(minutes: 10)
        player.stop(tellServer: false)
        XCTAssertFalse(player.isActive)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentIndex)
        XCTAssertNil(player.current)
        XCTAssertNil(player.queueTitle)
        XCTAssertFalse(player.isShuffled)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertNil(player.sleepDeadline)
        XCTAssertFalse(player.reachedEndOfQueue)
    }

    func testStoppingWithNothingPlayingOwesTheServerNothing() {
        XCTAssertNil(player.stop())
    }

    func testMakingWayForAFilmStopsTheMusic() {
        player.play(songs(2))
        player.yield()
        XCTAssertFalse(player.isActive)
    }

    func testPauseAndResumeFollowThePlayButton() {
        player.play(songs(2))
        player.togglePlayPause()
        XCTAssertTrue(player.isPlaying, "still opening counts as not playing, so the button plays")
        player.togglePlayPause()
        XCTAssertFalse(player.isPlaying)
        player.resume()
        XCTAssertTrue(player.isPlaying)
        player.pause()
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: Sleep timer

    func testSleepTimerSetsADeadlineAndCanBeCalledOff() throws {
        player.play(songs(1))
        let before = Date()
        player.setSleepTimer(minutes: 30)
        let deadline = try XCTUnwrap(player.sleepDeadline)
        XCTAssertEqual(deadline.timeIntervalSince(before), 1800, accuracy: 5)
        // Setting it again replaces it.
        player.setSleepTimer(minutes: 5)
        XCTAssertEqual(try XCTUnwrap(player.sleepDeadline).timeIntervalSince(before), 300, accuracy: 5)
        player.cancelSleepTimer()
        XCTAssertNil(player.sleepDeadline)
    }

    func testSleepTimerRunningOutPausesAndClearsItself() async {
        let song = MusicFixture.song("sleepy")
        MusicOnDevice.add(song)
        player.play([song])
        await eventually("the song is playing") { player.isPlaying && !player.isBuffering }
        player.setSleepTimer(minutes: 0)
        XCTAssertNotNil(player.sleepDeadline)
        await eventually("the timer fired") { player.sleepDeadline == nil }
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.isActive, "paused, not closed: the queue is still there in the morning")
        XCTAssertEqual(player.current?.Id, "sleepy")
    }

    func testACancelledSleepTimerNeverPauses() async {
        let song = MusicFixture.song("awake")
        MusicOnDevice.add(song)
        player.play([song])
        await eventually("the song is playing") { player.isPlaying && !player.isBuffering }
        player.setSleepTimer(minutes: 0)
        player.cancelSleepTimer()
        await settle()
        XCTAssertNil(player.sleepDeadline)
        XCTAssertTrue(player.isPlaying)
    }

    // MARK: Stations in the queue

    private func station(_ pool: [BaseItem], title: String = "Rock Mix") -> LiveStation {
        LiveStation(
            title: title, seed: MusicFixture.genre("g", "Rock"), profile: MixProfile(open: true),
            isLocal: false, pool: pool
        )
    }

    func testAStationsSongsAreMarkedAsItsOwn() {
        let pool = songs(6)
        let live = station(pool)
        player.playStation(live, songs: Array(pool.prefix(3)), offlineFallback: true)
        XCTAssertTrue(player.station === live)
        XCTAssertEqual(player.queueTitle, "Rock Mix")
        XCTAssertEqual(player.queue.map(\.fromStation), [true, true, true])
        XCTAssertTrue(player.mixIsOfflineFallback)
    }

    func testSongsPutInByHandAreNotTheStations() {
        let pool = songs(6)
        player.playStation(station(pool), songs: Array(pool.prefix(4)))
        player.playNext([MusicFixture.song("mine")])
        XCTAssertEqual(player.queue.map(\.fromStation), [true, false, true, true, true])
        // One of the station's own, moved by hand, stays where it was put.
        player.moveUpNext(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(ids, ["s0", "s3", "mine", "s1", "s2"])
        XCTAssertEqual(player.queue.map(\.fromStation), [true, false, false, true, true])
    }

    func testClearingUpNextOrPlayingSomethingElseEndsTheStation() {
        let pool = songs(6)
        player.playStation(station(pool), songs: Array(pool.prefix(4)), offlineFallback: true)
        player.clearUpNext()
        XCTAssertNil(player.station)

        player.playStation(station(pool), songs: Array(pool.prefix(4)), offlineFallback: true)
        player.play(MusicFixture.songs(["x"]))
        XCTAssertNil(player.station)
        XCTAssertFalse(player.mixIsOfflineFallback)
    }

    func testAStationWithNothingToPlayIsNotStarted() {
        player.playStation(station([]), songs: [])
        XCTAssertNil(player.station)
        XCTAssertFalse(player.isActive)
    }

    func testAMixFromThePlayerHandsWhatIsComingToItsStation() {
        player.play(songs(3), startingAt: 1)
        let pool = MusicFixture.songs(["m1", "m2", "m3"])
        let live = station(pool, title: "Song Mix")
        player.replaceUpcoming(with: pool, title: "Song Mix", station: live, offlineFallback: true)
        XCTAssertEqual(ids, ["s0", "s1", "m1", "m2", "m3"])
        XCTAssertEqual(player.queue.map(\.fromStation), [false, false, true, true, true])
        XCTAssertTrue(player.station === live)
        XCTAssertTrue(player.mixIsOfflineFallback)
    }
}
#endif
