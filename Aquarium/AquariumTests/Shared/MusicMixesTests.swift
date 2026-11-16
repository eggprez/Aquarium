//  The one door every mix goes through: Shuffle All, Start Station and
//  Instant Mix, from the source chosen in Settings (the server's Instant Mix
//  or Aquarium's own station) or from downloads. What is checked is what
//  ends up queued in the player and what kind of mix it says it is.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicMixesTests: XCTestCase {
    private var player: MusicPlayer { .shared }
    private var savedSource = MixSource.aquarium
    private var savedAutoplay = true

    override func setUp() async throws {
        MusicServer.install()
        await OfflineMusicIndex.shared.ensureLoaded()
        savedSource = Preferences.shared.mixSource
        savedAutoplay = Preferences.shared.musicAutoplay
        Preferences.shared.musicAutoplay = false
        player.stop(tellServer: false)
    }

    override func tearDown() async throws {
        player.stop(tellServer: false)
        Preferences.shared.mixSource = savedSource
        Preferences.shared.musicAutoplay = savedAutoplay
        await settle()
        await MusicOnDevice.forgetEverything()
        MusicServer.remove()
    }

    private func rock(_ id: String, artist: String = "Queen", artistId: String = "queen") -> BaseItem {
        MusicFixture.song(id, artist: artist, artistId: artistId, genres: ["Rock"], year: 1975)
    }

    private var queued: [String] { player.queue.map(\.item.Id) }
    private var mixCalls: [MusicServer.Call] { MusicServer.calls.filter { $0.path.hasSuffix("/InstantMix") } }

    /// A server with a mix of "seed", and enough around it for a station.
    private func library() -> MusicLibraryStub {
        var lib = MusicLibraryStub()
        lib.mixes["seed"] = [rock("m1"), rock("seed"), MusicFixture.album("al", "Not a song"), rock("m2")]
        lib.byGenreIds["g-rock,g-rockmusik"] = (0..<30).map { rock("g\($0)", artist: "Act \($0)", artistId: "act\($0)") }
        return lib
    }

    // MARK: The server's own mix

    func testTheServersMixOfASongStartsWithTheSongAndHasItOnce() async throws {
        Preferences.shared.mixSource = .jellyfin
        library().install()
        let answer1 = await MusicMixes.jellyfinMix(of: rock("seed"))
        let mix = try XCTUnwrap(answer1)
        XCTAssertEqual(mix.map(\.Id), ["seed", "m1", "m2"], "songs only")
        XCTAssertEqual(mixCalls.first?.query["Limit"], "100")
    }

    func testTheServersMixOfAnAlbumIsTheMixAsItCame() async throws {
        Preferences.shared.mixSource = .jellyfin
        var lib = MusicLibraryStub()
        lib.mixes["al1"] = [rock("m1"), rock("m2")]
        lib.install()
        let answer2 = await MusicMixes.jellyfinMix(of: MusicFixture.album("al1", "Album"), limit: 40)
        let mix = try XCTUnwrap(answer2)
        XCTAssertEqual(mix.map(\.Id), ["m1", "m2"])
        XCTAssertEqual(mixCalls.first?.query["Limit"], "40")
    }

    func testAMixWithNothingButTheSeedIsNoMix() async {
        Preferences.shared.mixSource = .jellyfin
        var lib = MusicLibraryStub()
        lib.mixes["seed"] = [rock("seed")]
        lib.mixes["al1"] = []
        lib.install()
        let ofSong = await MusicMixes.jellyfinMix(of: rock("seed"))
        XCTAssertNil(ofSong)
        let ofAlbum = await MusicMixes.jellyfinMix(of: MusicFixture.album("al1", "Album"))
        XCTAssertNil(ofAlbum)
        let unanswered = await MusicMixes.jellyfinMix(of: rock("unknown"))
        XCTAssertNil(unanswered, "a server that fails is no mix either")
    }

    func testTheServerIsNotAskedWhenAquariumsOwnMixIsChosen() async {
        Preferences.shared.mixSource = .aquarium
        library().install()
        let mix = await MusicMixes.jellyfinMix(of: rock("seed"))
        XCTAssertNil(mix)
        XCTAssertTrue(mixCalls.isEmpty)
    }

    func testTheServerIsNotAskedForAMixOfSomethingItDoesNotHave() async {
        Preferences.shared.mixSource = .jellyfin
        library().install()
        let seeds = [
            SpecialStation.rediscover.seed(cover: nil), MusicFixture.artist("local-artist:queen", "Queen"),
            MusicFixture.genre("fj-genre:rock", "Rock"), MusicFixture.song(""),
        ]
        for seed in seeds {
            let mix = await MusicMixes.jellyfinMix(of: seed)
            XCTAssertNil(mix, seed.Id)
        }
        XCTAssertTrue(mixCalls.isEmpty)
    }

    // MARK: Start Station

    func testStartStationWithTheServersMixPlaysItAsItCame() async {
        Preferences.shared.mixSource = .jellyfin
        library().install()
        let started = await MusicMixes.startStation(from: rock("seed"), title: "Seed Station")
        XCTAssertTrue(started.started)
        XCTAssertFalse(started.isLocal)
        XCTAssertEqual(queued, ["seed", "m1", "m2"])
        XCTAssertEqual(player.queueTitle, "Seed Station")
        XCTAssertNil(player.station, "the server's order, not a station that re-deals")
        XCTAssertFalse(player.mixIsOfflineFallback)
    }

    func testStartStationWithAquariumsMixPlaysAStationThatOpensWithTheSeed() async throws {
        Preferences.shared.mixSource = .aquarium
        library().install()
        let started = await MusicMixes.startStation(from: rock("seed"), title: "Seed Station")
        XCTAssertTrue(started.started)
        XCTAssertFalse(started.isLocal)
        let station = try XCTUnwrap(player.station)
        XCTAssertEqual(station.title, "Seed Station")
        XCTAssertEqual(queued.first, "seed")
        XCTAssertEqual(queued.filter { $0 == "seed" }.count, 1)
        XCTAssertEqual(queued.count, 1 + MusicPlayer.stationDepth)
        XCTAssertTrue(player.queue.allSatisfy(\.fromStation))
        XCTAssertEqual(Set(queued).count, queued.count)
        XCTAssertFalse(player.mixIsOfflineFallback)
    }

    func testAStationOfAnArtistHasNoSongToOpenWith() async throws {
        Preferences.shared.mixSource = .aquarium
        var lib = MusicLibraryStub()
        lib.mixes["queen"] = (0..<12).map { rock("q\($0)") }
        lib.install()
        let started = await MusicMixes.startStation(from: MusicFixture.artist("queen", "Queen"), title: "Queen")
        XCTAssertTrue(started.started)
        XCTAssertEqual(Set(queued), Set((0..<12).map { "q\($0)" }))
        XCTAssertEqual(player.station?.profile.isArtistStation, true)
    }

    func testStartStationFallsBackToDownloadsAndSaysSo() async {
        Preferences.shared.mixSource = .jellyfin
        MusicLibraryStub().install()
        let here = [rock("d1"), rock("d2"), rock("d3")]
        MusicOnDevice.add(here)
        OfflineMusicIndex.shared.note(here)
        let started = await MusicMixes.startStation(from: rock("d1"), title: "Mix")
        XCTAssertTrue(started.started)
        XCTAssertTrue(started.isLocal)
        XCTAssertEqual(queued.first, "d1")
        XCTAssertEqual(Set(queued), ["d1", "d2", "d3"])
        XCTAssertTrue(player.mixIsOfflineFallback, "the player says the mix is from this device")
        XCTAssertEqual(player.station?.isLocal, true)
    }

    func testAStationAskedForFromDownloadsIsNotCalledAFallback() async {
        Preferences.shared.mixSource = .jellyfin
        library().install()
        let here = [rock("seed"), rock("d2")]
        MusicOnDevice.add(here)
        OfflineMusicIndex.shared.note(here)
        let started = await MusicMixes.startStation(from: rock("seed"), title: "Mix", localOnly: true)
        XCTAssertTrue(started.started)
        XCTAssertTrue(started.isLocal)
        XCTAssertEqual(Set(queued), ["seed", "d2"])
        XCTAssertFalse(player.mixIsOfflineFallback, "downloads were what was asked for")
        XCTAssertTrue(mixCalls.isEmpty)
    }

    func testNothingToMixStartsNothing() async {
        Preferences.shared.mixSource = .jellyfin
        MusicLibraryStub().install()
        let started = await MusicMixes.startStation(from: rock("seed"), title: "Mix")
        XCTAssertFalse(started.started)
        XCTAssertFalse(player.isActive)
        let local = await MusicMixes.startStation(from: rock("seed"), title: "Mix", localOnly: true)
        XCTAssertFalse(local.started)
        XCTAssertTrue(local.isLocal)
    }

    // MARK: Instant Mix, from the player

    /// Something playing from this device, with two songs after it.
    private func playSomething() async {
        let now = rock("seed")
        MusicOnDevice.add(now)
        player.play([now, rock("next1"), rock("next2")], title: "Album")
        await eventually("the song opened") { player.isPlaying && !player.isBuffering }
    }

    func testInstantMixWithTheServersMixReplacesWhatWasComingAndKeepsTheSongPlaying() async {
        Preferences.shared.mixSource = .jellyfin
        library().install()
        await playSomething()
        let started = await MusicMixes.instantMix(from: rock("seed"))
        XCTAssertTrue(started.started)
        XCTAssertFalse(started.isLocal)
        XCTAssertEqual(queued, ["seed", "m1", "m2"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertTrue(player.isPlaying, "what is playing carries on")
        XCTAssertEqual(player.queueTitle, "Song seed Mix")
        XCTAssertNil(player.station)
    }

    func testInstantMixWithAquariumsMixHandsWhatIsComingToAStation() async throws {
        Preferences.shared.mixSource = .aquarium
        library().install()
        await playSomething()
        let started = await MusicMixes.instantMix(from: rock("seed"))
        XCTAssertTrue(started.started)
        XCTAssertFalse(started.isLocal)
        XCTAssertEqual(queued.first, "seed")
        XCTAssertEqual(queued.count, 1 + MusicPlayer.stationDepth)
        XCTAssertFalse(queued.contains("next1"))
        XCTAssertEqual(queued.filter { $0 == "seed" }.count, 1)
        XCTAssertEqual(player.queue.map(\.fromStation), [false] + Array(repeating: true, count: MusicPlayer.stationDepth))
        XCTAssertEqual(try XCTUnwrap(player.station).title, "Song seed Mix")
        XCTAssertFalse(player.mixIsOfflineFallback)
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testInstantMixWithNothingToOfferLeavesTheQueueAlone() async {
        Preferences.shared.mixSource = .jellyfin
        MusicLibraryStub().install()
        await playSomething()
        // The only download is the song itself: nothing to follow it with.
        let started = await MusicMixes.instantMix(from: rock("seed"))
        XCTAssertFalse(started.started)
        XCTAssertEqual(queued, ["seed", "next1", "next2"])
        XCTAssertEqual(player.queueTitle, "Album")
    }

    func testInstantMixFromDownloadsWhenTheServerHasNoneSaysItIsAFallback() async {
        Preferences.shared.mixSource = .jellyfin
        MusicLibraryStub().install()
        let here = [rock("d1"), rock("d2")]
        MusicOnDevice.add(here)
        OfflineMusicIndex.shared.note(here)
        await playSomething()
        let started = await MusicMixes.instantMix(from: rock("seed"))
        XCTAssertTrue(started.started)
        XCTAssertTrue(started.isLocal)
        XCTAssertEqual(queued.first, "seed")
        XCTAssertEqual(Set(queued.dropFirst()), ["d1", "d2"])
        XCTAssertTrue(player.mixIsOfflineFallback)
    }

    // MARK: Shuffle All

    func testShuffleAllPlaysTheServersSongsShuffled() async throws {
        var lib = MusicLibraryStub()
        lib.anySongs = (0..<40).map { rock("s\($0)") } + [MusicFixture.album("al", "Not a song")]
        lib.install()
        let started = await MusicMixes.shuffleAll()
        XCTAssertTrue(started.started)
        XCTAssertFalse(started.isLocal)
        XCTAssertEqual(Set(queued), Set((0..<40).map { "s\($0)" }))
        XCTAssertEqual(queued.count, 40)
        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(player.queueTitle, "Shuffle All")
        XCTAssertNil(player.station, "a shuffle, not a station: nothing is learned")
        let asked = try XCTUnwrap(MusicServer.calls(to: "/Items").first { $0.query["IncludeItemTypes"] == "Audio" && $0.query["Limit"] == "500" }?.query)
        XCTAssertEqual(asked["SortBy"], "Random")
        XCTAssertEqual(asked["Limit"], "500")
    }

    func testShuffleAllFallsBackToDownloadsWhenTheServerSendsNothing() async {
        MusicLibraryStub().install()
        MusicOnDevice.add([rock("d1"), rock("d2"), rock("d3")])
        let started = await MusicMixes.shuffleAll()
        XCTAssertTrue(started.started)
        XCTAssertTrue(started.isLocal)
        XCTAssertEqual(Set(queued), ["d1", "d2", "d3"])
        XCTAssertTrue(player.isShuffled)
    }

    func testShuffleAllOfDownloadsNeverAsksTheServer() async {
        var lib = MusicLibraryStub()
        lib.anySongs = [rock("server-song")]
        lib.install()
        MusicOnDevice.add([rock("d1"), rock("d2")])
        let started = await MusicMixes.shuffleAll(localOnly: true)
        XCTAssertTrue(started.isLocal)
        XCTAssertEqual(Set(queued), ["d1", "d2"])
        XCTAssertTrue(MusicServer.calls(to: "/Items").filter { $0.query["IncludeItemTypes"] == "Audio" && $0.query["SortBy"] == "Random" }.isEmpty)
    }

    func testShuffleAllWithNoMusicAnywhereStartsNothing() async {
        MusicLibraryStub().install()
        let started = await MusicMixes.shuffleAll()
        XCTAssertFalse(started.started)
        XCTAssertTrue(started.isLocal)
        XCTAssertFalse(player.isActive)
    }
}
#endif
