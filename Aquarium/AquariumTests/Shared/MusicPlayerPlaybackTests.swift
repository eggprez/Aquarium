//  What the music player does as songs open, end and are skipped — the parts
//  that only happen once something is in the player. The songs are downloads
//  made of silence, so they open from the device with no server and no
//  sound; what is checked is the player's own account of things, the reports
//  it sends and what it tells a station.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicPlayerPlaybackTests: XCTestCase {
    private var player: MusicPlayer { .shared }
    private var savedAutoplay = true
    private var savedSource = MixSource.aquarium
    private var savedRepeat = MusicPlayer.RepeatMode.off

    override func setUp() async throws {
        MusicServer.install()
        savedAutoplay = Preferences.shared.musicAutoplay
        savedSource = Preferences.shared.mixSource
        savedRepeat = player.repeatMode
        Preferences.shared.musicAutoplay = false
        player.stop(tellServer: false)
        player.repeatMode = .off
        await OfflineMusicIndex.shared.ensureLoaded()
    }

    override func tearDown() async throws {
        player.stop(tellServer: false)
        MusicOnDevice.removeAll()
        player.repeatMode = savedRepeat
        Preferences.shared.musicAutoplay = savedAutoplay
        Preferences.shared.mixSource = savedSource
        await settle()
        MusicServer.remove()
    }

    /// A downloaded song whose file is `seconds` of silence.
    private func local(_ id: String, artist: String = "Artist", seconds: Double = 120) -> BaseItem {
        let song = MusicFixture.song(id, artist: artist, artistId: "id-\(artist)", genres: ["Rock"], seconds: seconds)
        MusicOnDevice.add(song, fileSeconds: seconds)
        return song
    }

    private func open() async {
        await eventually("the song opened") { player.isPlaying && !player.isBuffering }
    }

    // MARK: Opening

    func testADownloadedSongOpensFromTheDeviceWithoutAskingTheServerForAStream() async {
        player.play([local("here")])
        await open()
        XCTAssertTrue(player.isLocal)
        XCTAssertFalse(player.isTranscoding)
        XCTAssertNil(player.errorMessage)
        XCTAssertEqual(player.duration, 120, accuracy: 1, "the file's own length")
        XCTAssertTrue(MusicServer.calls.filter { $0.path.hasSuffix("/PlaybackInfo") }.isEmpty)
        await eventually("the server was told it started") { !MusicServer.calls(to: "/Sessions/Playing").isEmpty }
        XCTAssertEqual(MusicServer.calls(to: "/Sessions/Playing").first?.body?["ItemId"] as? String, "here")
    }

    func testASongTheServerCannotOpenIsSkippedForTheNextOne() async {
        // "gone" is not on the device and the server answers 404 for it.
        player.play([MusicFixture.song("gone"), local("here")])
        await eventually("moved on to the song that opens") { player.current?.Id == "here" && player.isPlaying }
        XCTAssertNil(player.errorMessage)
        XCTAssertEqual(player.queue.map(\.item.Id), ["gone", "here"], "skipped, not removed")
    }

    func testTheOnlySongFailingToOpenSaysSoAndStops() async {
        player.play([MusicFixture.song("gone")])
        await eventually("gave up") { player.errorMessage != nil }
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isBuffering)
        XCTAssertTrue(player.isActive)
    }

    // MARK: A song ending

    func testASongThatEndsHandsOverToTheNextAndIsCountedAsPlayed() async throws {
        let first = local("first", seconds: 0.5)
        let second = local("second")
        let before = OfflineMusicIndex.shared.facts["first"]?.playCount ?? 0
        player.play([first, second], title: "Album")
        await eventually("the second song is playing") { player.currentIndex == 1 }
        XCTAssertEqual(player.current?.Id, "second")
        XCTAssertFalse(player.reachedEndOfQueue)
        XCTAssertEqual(player.position, 0, accuracy: 1.5)
        XCTAssertEqual(player.duration, 120, accuracy: 1)
        XCTAssertEqual(OfflineMusicIndex.shared.facts["first"]?.playCount, before + 1, "counted on the device, for Top Songs with no server")
        XCTAssertNotNil(OfflineMusicIndex.shared.facts["first"]?.lastPlayed)
        await eventually("the download is marked played") { DownloadManager.shared.record(for: "first")?.played == true }
        await eventually("the server was told the first one stopped") {
            MusicServer.calls(to: "/Sessions/Playing/Stopped").contains { $0.body?["ItemId"] as? String == "first" }
        }
        let stopped = try XCTUnwrap(MusicServer.calls(to: "/Sessions/Playing/Stopped").first { $0.body?["ItemId"] as? String == "first" })
        let ticks = try XCTUnwrap(stopped.body?["PositionTicks"] as? NSNumber).doubleValue
        XCTAssertEqual(ticks / 10_000_000, 0.5, accuracy: 0.3, "reported at its end, which is what makes the server count it")
    }

    func testTheLastSongEndingStopsAtTheEndOfTheQueueAndPlayStartsOver() async {
        player.play([local("only", seconds: 0.5)])
        await eventually("the queue ran out") { player.reachedEndOfQueue }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, 0)
        XCTAssertTrue(player.isActive)
        XCTAssertEqual(player.current?.Id, "only")
        player.togglePlayPause()
        XCTAssertFalse(player.reachedEndOfQueue)
        XCTAssertEqual(player.currentIndex, 0)
        await eventually("it ran out again") { player.reachedEndOfQueue }
    }

    func testRepeatAllGoesRoundToTheFirstSong() async {
        player.repeatMode = .all
        let short = local("short", seconds: 0.5)
        let long = local("long")
        player.play([long, short], startingAt: 1)
        await eventually("back at the top") { player.currentIndex == 0 }
        XCTAssertFalse(player.reachedEndOfQueue)
        XCTAssertEqual(player.queue.count, 2)
    }

    func testRepeatOnePlaysTheSameSongAgain() async {
        player.repeatMode = .one
        player.play([local("again", seconds: 0.5), local("never")])
        // Twice round: each time it ends it is counted and opens again.
        let before = OfflineMusicIndex.shared.facts["again"]?.playCount ?? 0
        await eventually("heard twice") { (OfflineMusicIndex.shared.facts["again"]?.playCount ?? 0) >= before + 2 }
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertFalse(player.reachedEndOfQueue)
    }

    // MARK: Autoplay

    func testAutoplayCarriesOnWithTheServersMixWhenTheQueueRunsOut() async {
        Preferences.shared.musicAutoplay = true
        Preferences.shared.mixSource = .jellyfin
        let last = local("last", seconds: 0.5)
        let more = [local("more1"), MusicFixture.song("more2"), last]
        MusicServer.answer { call in
            call.path == "/Items/last/InstantMix" ? .items(more) : nil
        }
        player.play([last], title: "Album")
        await eventually("the mix was queued") { player.queue.count == 3 }
        XCTAssertEqual(player.queue.map(\.item.Id), ["last", "more1", "more2"], "the song that just played is not queued again")
        XCTAssertEqual(player.current?.Id, "more1")
        XCTAssertEqual(player.queueTitle, "Autoplay")
        XCTAssertFalse(player.reachedEndOfQueue)
        XCTAssertNil(player.station, "the server's mix plays as the server ordered it")
        XCTAssertEqual(player.queue.map(\.fromStation), [false, false, false])
    }

    func testAutoplayWithNothingToOfferEndsTheQueue() async {
        Preferences.shared.musicAutoplay = true
        Preferences.shared.mixSource = .jellyfin
        // The server has no mix and no downloads are like it but itself.
        player.play([local("alone", seconds: 0.5)])
        await eventually("the queue ran out") { player.reachedEndOfQueue }
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertFalse(player.isPlaying)
    }

    func testAutoplayOffEndsTheQueueWithoutAskingForAMix() async {
        player.play([local("only", seconds: 0.5)])
        await eventually("the queue ran out") { player.reachedEndOfQueue }
        XCTAssertTrue(MusicServer.calls.filter { $0.path.hasSuffix("/InstantMix") }.isEmpty)
    }

    func testABookEndingDoesNotAutoplay() async {
        Preferences.shared.musicAutoplay = true
        Preferences.shared.mixSource = .jellyfin
        let book = MusicFixture.book("short-book", seconds: 0.5)
        MusicOnDevice.add(book, fileSeconds: 0.5)
        player.play([book])
        await eventually("the book ended") { player.reachedEndOfQueue }
        XCTAssertTrue(MusicServer.calls.filter { $0.path.hasSuffix("/InstantMix") }.isEmpty)
    }

    // MARK: Skipping, and what the server hears

    func testSkippingASongReportsWhereItWasLeftNotItsEnd() async throws {
        player.play([local("skipped"), local("next")])
        await open()
        player.skipNext()
        await eventually("on the next song") { player.current?.Id == "next" && player.isPlaying }
        await eventually("the server was told the first one stopped") {
            MusicServer.calls(to: "/Sessions/Playing/Stopped").contains { $0.body?["ItemId"] as? String == "skipped" }
        }
        let stopped = try XCTUnwrap(MusicServer.calls(to: "/Sessions/Playing/Stopped").first { $0.body?["ItemId"] as? String == "skipped" })
        let ticks = try XCTUnwrap(stopped.body?["PositionTicks"] as? NSNumber).doubleValue
        XCTAssertLessThan(ticks / 10_000_000, 60, "a song heard for a moment is not reported as played through")
        XCTAssertNotEqual(DownloadManager.shared.record(for: "skipped")?.played, true)
        XCTAssertEqual(OfflineMusicIndex.shared.facts["skipped"]?.playCount ?? 0, 0, "a skip is not a play")
    }

    func testStoppingTellsTheServerAboutTheSongThatWasPlaying() async throws {
        player.play([local("stopped")])
        await open()
        let done = try XCTUnwrap(player.stop())
        await done.value
        XCTAssertFalse(player.isActive)
        XCTAssertEqual(MusicServer.calls(to: "/Sessions/Playing/Stopped").last?.body?["ItemId"] as? String, "stopped")
    }

    func testStoppingForASignOutTellsTheServerNothing() async {
        player.play([local("quiet")])
        await open()
        XCTAssertNil(player.stop(tellServer: false))
        await settle()
        XCTAssertTrue(MusicServer.calls(to: "/Sessions/Playing/Stopped").isEmpty)
    }

    func testPausingReportsProgressAsPaused() async {
        player.play([local("paused")])
        await open()
        player.pause()
        await eventually("progress went out") {
            MusicServer.calls(to: "/Sessions/Playing/Progress").contains { $0.body?["IsPaused"] as? Bool == true }
        }
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: A downloaded book keeps its place

    func testLeavingADownloadedBookSavesWhereItWasLeft() async throws {
        let book = MusicFixture.book("kept-book", seconds: 3600, chapters: [0, 900, 1800])
        MusicOnDevice.add(book, fileSeconds: 3)
        player.play([book], at: 1.5)
        await eventually("the book opened part-way") { player.isPlaying && player.position >= 1.4 }
        XCTAssertEqual(player.chapters.count, 3)
        player.stop(tellServer: false)
        let record = try XCTUnwrap(DownloadManager.shared.record(for: "kept-book"))
        XCTAssertGreaterThanOrEqual(record.resumeSeconds, 1.4)
        XCTAssertFalse(record.progressSynced, "and is owed to the server")
        XCTAssertEqual(player.resumePoint(for: book, explicit: nil), record.resumeSeconds)
    }

    // MARK: Stations listen back

    private func station(_ pool: [BaseItem]) -> LiveStation {
        LiveStation(title: "Mix", seed: MusicFixture.genre("g", "Rock"), profile: MixProfile(open: true), isLocal: false, pool: pool)
    }

    private func pool(_ n: Int) -> [BaseItem] {
        (0..<n).map { MusicFixture.song("p\($0)", artist: "Act \($0 % 12)", artistId: "act\($0 % 12)", genres: ["Rock"]) }
    }

    func testSkippingAStationsSongEarlyIsLearnedAndTheSongIsNotDealtAgain() async {
        let first = local("first", artist: "Skipped Act")
        let second = local("second", artist: "Other Act")
        let live = station([first, second] + pool(40))
        player.playStation(live, songs: [first, second])
        await open()
        player.skipNext()
        await eventually("the station heard about it") { live.session.reactions == 1 }
        XCTAssertEqual(live.session.passed, ["first"])
        XCTAssertEqual(live.session.artistLeanings.first?.name, "Skipped Act")
        XCTAssertEqual(live.session.artistLeanings.first?.points ?? 0, -1, accuracy: 1e-9)
        await eventually("up next was dealt again") { player.queue.count == 2 + MusicPlayer.stationDepth }
        XCTAssertEqual(player.current?.Id, "second")
        XCTAssertEqual(player.queue.filter { $0.item.Id == "first" }.count, 1, "only where it already played")
        XCTAssertEqual(Set(player.queue.map(\.item.Id)).count, player.queue.count, "nothing queued twice")
    }

    func testRemovingAStationsSongTopsUpNextBackUpAndKeepsHandPlacedSongs() async {
        let current = local("current")
        let songs = pool(60)
        let live = station([current] + songs)
        player.playStation(live, songs: [current] + songs.prefix(4))
        player.playNext([MusicFixture.song("mine")])
        XCTAssertEqual(player.queue.map(\.item.Id), ["current", "mine", "p0", "p1", "p2", "p3"])
        player.remove(player.queue[3])
        await eventually("up next was dealt again") { player.queue.count == 2 + MusicPlayer.stationDepth }
        XCTAssertEqual(player.queue[0].item.Id, "current")
        XCTAssertEqual(player.queue[1].item.Id, "mine", "what was put there by hand stays there")
        XCTAssertFalse(player.queue[1].fromStation)
        XCTAssertTrue(player.queue.dropFirst(2).allSatisfy(\.fromStation))
        XCTAssertFalse(player.queue.contains { $0.item.Id == "p1" }, "removed is not wanted again")
        XCTAssertEqual(live.session.passed, ["p1"])
        XCTAssertEqual(Set(player.queue.map(\.item.Id)).count, player.queue.count)
    }

    func testAStationRunningLowAsksTheServerForMoreLikeTheSongPlayingOnce() async {
        let current = local("current")
        let songs = pool(8)
        let wider = (0..<30).map { MusicFixture.song("w\($0)", artist: "Wide \($0)", artistId: "wide\($0)") }
        MusicServer.answer { call in
            call.path == "/Items/current/InstantMix" ? .items(wider) : nil
        }
        let live = station([current] + songs)
        player.playStation(live, songs: [current] + songs.prefix(4))
        player.remove(player.queue[2])
        await eventually("the pool grew and was dealt from") { player.queue.contains { $0.item.Id.hasPrefix("w") } }
        XCTAssertEqual(live.pool.count, 39)
        player.remove(player.queue[2])
        await eventually("dealt again") { live.session.reactions == 2 && player.queue.count == 1 + MusicPlayer.stationDepth }
        await settle()
        XCTAssertEqual(MusicServer.calls(to: "/Items/current/InstantMix").count, 1, "one song widens the pool once")
    }

    func testAShuffledStationIsLeftAsTheListenerShuffledIt() async {
        let current = local("current")
        let songs = pool(40)
        let live = station([current] + songs)
        player.playStation(live, songs: [current] + songs.prefix(6))
        player.toggleShuffle()
        let before = player.queue.map(\.item.Id)
        player.remove(player.queue[3])
        await settle()
        var expected = before
        expected.remove(at: 3)
        XCTAssertEqual(player.queue.map(\.item.Id), expected)
    }
}
#endif
