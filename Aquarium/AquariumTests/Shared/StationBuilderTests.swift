//  How a station's pool is gathered: what the server is asked for each kind
//  of seed, when the downloads stand in for it, and how a pool is widened
//  once it runs low. The server is a stub with a small library.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class StationBuilderTests: XCTestCase {
    private let coverageKey = "music_tag_coverage"
    private var savedCoverage: Any?

    override func setUp() async throws {
        MusicServer.install()
        await OfflineMusicIndex.shared.ensureLoaded()
        savedCoverage = UserDefaults.standard.object(forKey: coverageKey)
        UserDefaults.standard.removeObject(forKey: coverageKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedCoverage, forKey: coverageKey)
        await MusicOnDevice.forgetEverything()
        MusicServer.remove()
    }

    private func rock(_ id: String, artist: String = "Queen", artistId: String = "queen", year: Int? = 1975) -> BaseItem {
        MusicFixture.song(id, artist: artist, artistId: artistId, genres: ["Rock"], year: year)
    }

    private func audioQueries(_ key: String) -> [String] {
        MusicServer.calls(to: "/Items").filter { $0.query["IncludeItemTypes"] == "Audio" }.compactMap { $0.query[key] }
    }

    // MARK: From the server

    func testASongsStationGathersItsMixItsArtistsMixSimilarArtistsAndEverySpellingOfItsGenre() async throws {
        let seed = rock("seed")
        var lib = MusicLibraryStub()
        lib.mixes["seed"] = [rock("m1"), rock("m2"), seed]
        lib.mixes["queen"] = [rock("m2"), rock("am1")]
        lib.similar["queen"] = [MusicFixture.artist("sim-a", "Sim A"), MusicFixture.artist("sim-b", "Sim B")]
        lib.byArtists["sim-a,sim-b"] = [rock("sim1", artist: "Sim A", artistId: "sim-a")]
        lib.byGenreIds["g-rock,g-rockmusik"] = [rock("gen1", artist: "Other", artistId: "other")]
        lib.install()

        let answer1 = await StationBuilder.build(from: seed, title: "Seed Mix")
        let station = try XCTUnwrap(answer1)
        XCTAssertFalse(station.isLocal)
        XCTAssertEqual(station.title, "Seed Mix")
        XCTAssertEqual(Set(station.pool.keys), ["seed", "m1", "m2", "am1", "sim1", "gen1"])
        XCTAssertEqual(station.profile.songId, "seed")
        XCTAssertEqual(station.profile.genres, ["rock": 1])
        XCTAssertEqual(MusicServer.calls(to: "/Items/seed/InstantMix").first?.query["Limit"], "150")
        XCTAssertEqual(MusicServer.calls(to: "/Items/queen/InstantMix").first?.query["Limit"], "80")
        XCTAssertEqual(audioQueries("GenreIds"), ["g-rock,g-rockmusik"], "\"Rock\" and \"Rockmusik\" are asked for together")
        XCTAssertFalse(station.upcoming(count: 10, after: [seed]).contains { $0.Id == "seed" }, "the seed opens the station; it is not dealt again")
    }

    func testBuildingAStationRecordsHowWellItsSongsAreTagged() async throws {
        var lib = MusicLibraryStub()
        lib.mixes["seed"] = [rock("m1"), MusicFixture.song("bare", artist: nil), rock("m3", year: nil)]
        lib.install()
        let answer2 = await StationBuilder.build(from: rock("seed"), title: "Mix")
        XCTAssertNotNil(answer2)
        let coverage = TagCoverage.recent
        XCTAssertEqual([coverage.songs, coverage.noArtist, coverage.noGenre, coverage.noYear], [3, 1, 1, 2])
    }

    func testAnArtistsStationIsMeasuredAgainstASampleOfTheirSongs() async throws {
        let seed = MusicFixture.artist("queen", "Queen")
        var lib = MusicLibraryStub()
        lib.mixes["queen"] = [rock("m1")]
        lib.byArtists["queen"] = [rock("own1"), MusicFixture.song("own2", artist: "Queen", artistId: "queen", genres: ["Pop"])]
        lib.similar["queen"] = [MusicFixture.artist("sim-a", "Sim A")]
        lib.byArtists["sim-a"] = [rock("sim1", artist: "Sim A", artistId: "sim-a")]
        lib.install()

        let answer3 = await StationBuilder.build(from: seed, title: "Queen")
        let station = try XCTUnwrap(answer3)
        XCTAssertTrue(station.profile.isArtistStation)
        XCTAssertEqual(station.profile.artists, ["id:queen", "name:queen"])
        XCTAssertEqual(station.profile.genres, ["rock": 1, "pop": 1])
        XCTAssertNil(station.profile.year)
        XCTAssertEqual(Set(station.pool.keys), ["m1", "sim1"], "the sample is for the profile; the pool is the mixes")
        XCTAssertEqual(MusicServer.calls(to: "/Items/queen/InstantMix").count, 1, "an artist's own mix is not asked for twice")
    }

    func testAnAlbumsStationReadsItsTracks() async throws {
        let seed = MusicFixture.album("al1", "A Night at the Opera", year: 1975)
        var lib = MusicLibraryStub()
        lib.mixes["al1"] = [rock("m1")]
        lib.byParent["al1"] = [rock("t1"), rock("t2")]
        lib.install()
        let answer4 = await StationBuilder.build(from: seed, title: "Opera")
        let station = try XCTUnwrap(answer4)
        XCTAssertEqual(station.profile.albumId, "al1")
        XCTAssertEqual(station.profile.year, 1975)
        XCTAssertEqual(station.profile.genres, ["rock": 2])
        XCTAssertEqual(station.profile.artists, ["id:queen", "name:queen"])
        XCTAssertEqual(Set(station.pool.keys), ["m1"])
        XCTAssertEqual(audioQueries("ParentId"), ["al1"])
    }

    func testAPlaylistSaysNothingAboutItselfSoItsMixSpeaksForIt() async throws {
        let seed = MusicFixture.playlist("pl1", "Road Trip")
        var lib = MusicLibraryStub()
        lib.mixes["pl1"] = [rock("m1"), MusicFixture.song("m2", artist: "ABBA", artistId: "abba", genres: ["Pop"], year: 1976)]
        lib.install()
        let answer5 = await StationBuilder.build(from: seed, title: "Road Trip")
        let station = try XCTUnwrap(answer5)
        XCTAssertEqual(station.profile.genres, ["rock": 1, "pop": 1])
        XCTAssertTrue(station.profile.artists.contains("id:abba"))
        XCTAssertEqual(Set(station.pool.keys), ["m1", "m2"])
    }

    func testAGenresStationAsksForEverySpellingTheLibraryHas() async throws {
        let seed = MusicFixture.genre("g-rock", "Rock")
        var lib = MusicLibraryStub()
        lib.byGenreIds["g-rock,g-rockmusik"] = [rock("r1"), rock("r2")]
        lib.mixes["g-rock"] = [rock("r3")]
        lib.install()
        let answer6 = await StationBuilder.build(from: seed, title: "Rock")
        let station = try XCTUnwrap(answer6)
        XCTAssertEqual(Set(station.pool.keys), ["r1", "r2", "r3"])
        XCTAssertEqual(station.profile.genres, ["rock": 1])
        XCTAssertEqual(MusicServer.calls(to: "/Items/g-rock/InstantMix").first?.query["Limit"], "100")
        let asked = MusicServer.calls(to: "/Items").first { $0.query["GenreIds"] != nil }?.query
        XCTAssertEqual(asked?["SortBy"], "Random")
        XCTAssertEqual(asked?["Limit"], "250")
    }

    func testAGenreTheLibraryDoesNotListIsAskedForByItsOwnIdOrFailingThatItsName() async throws {
        var lib = MusicLibraryStub()
        lib.byGenreIds["g-polka"] = [MusicFixture.song("p1", genres: ["Polka"])]
        lib.byGenreNames["Zydeco"] = [MusicFixture.song("z1", genres: ["Zydeco"])]
        lib.install()
        let answer7 = await StationBuilder.build(from: MusicFixture.genre("g-polka", "Polka"), title: "Polka")
        let byId = try XCTUnwrap(answer7)
        XCTAssertEqual(Set(byId.pool.keys), ["p1"])
        // A genre made up on this device from a tag: there is no id to ask by.
        let answer8 = await StationBuilder.build(from: MusicFixture.genre("fj-genre:zydeco", "Zydeco"), title: "Zydeco")
        let byName = try XCTUnwrap(answer8)
        XCTAssertEqual(Set(byName.pool.keys), ["z1"])
        XCTAssertEqual(audioQueries("Genres"), ["Zydeco"])
        XCTAssertTrue(MusicServer.calls.filter { $0.path.contains("fj-genre") }.isEmpty, "and nothing to ask the server for a mix of")
    }

    func testRediscoverIsStarredAndMostPlayedSongsNotHeardInSixWeeks() async throws {
        var lib = MusicLibraryStub()
        lib.favorites = [
            MusicFixture.song("fav-old", plays: 4, favorite: true, lastPlayed: MusicFixture.daysAgo(90)),
            MusicFixture.song("fav-new", plays: 4, favorite: true, lastPlayed: MusicFixture.daysAgo(1)),
            MusicFixture.song("fav-never", favorite: true),
        ]
        lib.mostPlayed = [
            MusicFixture.song("top-old", plays: 40, lastPlayed: MusicFixture.daysAgo(60)),
            MusicFixture.song("top-new", plays: 50, lastPlayed: MusicFixture.daysAgo(2)),
        ]
        lib.install()
        let answer9 = await StationBuilder.build(from: SpecialStation.rediscover.seed(cover: nil), title: "Rediscover")
        let station = try XCTUnwrap(answer9)
        XCTAssertEqual(Set(station.pool.keys), ["fav-old", "fav-never", "top-old"])
        XCTAssertTrue(station.profile.isOpen)
        XCTAssertFalse(station.isLocal)
    }

    func testDeepCutsIsUnplayedSongsByStarredAndMostPlayedArtists() async throws {
        var lib = MusicLibraryStub()
        lib.starredArtists = [MusicFixture.artist("starred", "Starred")]
        lib.mostPlayed = [
            MusicFixture.song("t1", artist: "Played", artistId: "played"),
            MusicFixture.song("t2", artist: "Starred", artistId: "starred"),
            MusicFixture.song("t3", artist: "Played Too", artistId: "played-too"),
        ]
        lib.unplayedByArtists["starred,played,played-too"] = MusicFixture.songs(["deep1", "deep2"])
        lib.install()
        let answer10 = await StationBuilder.build(from: SpecialStation.deepCuts.seed(cover: nil), title: "Deep Cuts")
        let station = try XCTUnwrap(answer10)
        XCTAssertEqual(Set(station.pool.keys), ["deep1", "deep2"])
        XCTAssertTrue(station.profile.isOpen)
        XCTAssertEqual(MusicServer.calls(to: "/Artists/AlbumArtists").first?.query["IsFavorite"], "true")
    }

    // MARK: From downloads

    func testWhenTheServerHasNothingTheDownloadsStandIn() async throws {
        MusicLibraryStub().install()
        let here = [rock("d1"), rock("d2")]
        MusicOnDevice.add(here)
        OfflineMusicIndex.shared.note(here)
        let answer11 = await StationBuilder.build(from: rock("seed"), title: "Mix")
        let station = try XCTUnwrap(answer11)
        XCTAssertTrue(station.isLocal)
        XCTAssertEqual(Set(station.pool.keys), ["d1", "d2"])
    }

    func testNothingOnTheServerAndNothingDownloadedIsNoStation() async {
        MusicLibraryStub().install()
        let station = await StationBuilder.build(from: rock("seed"), title: "Mix")
        XCTAssertNil(station)
        let deepCuts = await StationBuilder.build(from: SpecialStation.deepCuts.seed(cover: nil), title: "Deep Cuts")
        XCTAssertNil(deepCuts)
    }

    func testASeedThatOnlyExistsOnThisDeviceNeverAsksTheServer() async throws {
        var lib = MusicLibraryStub()
        lib.mixes["local-artist:queen"] = [rock("server-song")]
        lib.install()
        MusicOnDevice.add(rock("d1"))
        let answer12 = await StationBuilder.build(from: MusicFixture.artist("local-artist:queen", "Queen"), title: "Queen")
        let station = try XCTUnwrap(answer12)
        XCTAssertTrue(station.isLocal)
        XCTAssertEqual(Set(station.pool.keys), ["d1"])
        XCTAssertTrue(MusicServer.calls.filter { $0.path.hasSuffix("/InstantMix") }.isEmpty)
    }

    func testTheDownloadedPageAsksForDownloadsWhateverTheServerCouldDo() async throws {
        var lib = MusicLibraryStub()
        lib.mixes["seed"] = [rock("server-song")]
        lib.install()
        MusicOnDevice.add(rock("d1"))
        let answer13 = await StationBuilder.build(from: rock("seed"), title: "Mix", localOnly: true)
        let station = try XCTUnwrap(answer13)
        XCTAssertTrue(station.isLocal)
        XCTAssertEqual(Set(station.pool.keys), ["d1"])
        XCTAssertTrue(MusicServer.calls.filter { $0.path.hasSuffix("/InstantMix") }.isEmpty)
    }

    func testWithNoServerInReachTheStationIsBuiltFromDownloads() async throws {
        var lib = MusicLibraryStub()
        lib.mixes["seed"] = [rock("server-song")]
        lib.install()
        MusicOnDevice.add(rock("d1"))
        guard await MusicServer.setOffline(true) else {
            _ = await MusicServer.setOffline(false)
            throw XCTSkip("the client would not go offline here")
        }
        let station = await StationBuilder.build(from: rock("seed"), title: "Mix")
        let jellyfin = await MusicMixes.jellyfinMix(of: rock("seed"))
        let online = await MusicServer.setOffline(false)
        XCTAssertTrue(online, "back online for the tests that follow")
        XCTAssertEqual(station?.isLocal, true)
        XCTAssertEqual(station.map { Set($0.pool.keys) }, ["d1"])
        XCTAssertNil(jellyfin)
    }

    // MARK: Widening

    private func station(_ pool: [BaseItem], isLocal: Bool = false) -> LiveStation {
        LiveStation(title: "Mix", seed: rock("seed"), profile: MixProfile(open: true), isLocal: isLocal, pool: pool)
    }

    func testWideningAddsMoreLikeTheSongPlayingOnce() async {
        var lib = MusicLibraryStub()
        lib.mixes["now"] = [rock("w1"), rock("w2"), rock("a")]
        lib.similar["nina"] = [MusicFixture.artist("sim-a", "Sim A")]
        lib.byArtists["sim-a"] = [rock("w3", artist: "Sim A", artistId: "sim-a")]
        lib.install()
        let live = station([rock("a")])
        let playing = rock("now", artist: "Nina", artistId: "nina")
        let grew = await StationBuilder.widen(live, from: playing)
        XCTAssertTrue(grew)
        XCTAssertEqual(Set(live.pool.keys), ["a", "w1", "w2", "w3"])
        XCTAssertEqual(MusicServer.calls(to: "/Items/now/InstantMix").first?.query["Limit"], "60")
        let again = await StationBuilder.widen(live, from: playing)
        XCTAssertFalse(again)
        XCTAssertEqual(MusicServer.calls(to: "/Items/now/InstantMix").count, 1)
    }

    func testWideningThatFindsNothingNewSaysSo() async {
        var lib = MusicLibraryStub()
        lib.mixes["now"] = [rock("a")]
        lib.install()
        let live = station([rock("a")])
        let grew = await StationBuilder.widen(live, from: rock("now"))
        XCTAssertFalse(grew, "or the player would ask again after every deal, for ever")
        XCTAssertEqual(live.pool.count, 1)
    }

    func testAStationBuiltFromDownloadsIsNotWidenedFromTheServer() async {
        var lib = MusicLibraryStub()
        lib.mixes["now"] = [rock("w1")]
        lib.install()
        let live = station([rock("a")], isLocal: true)
        let grew = await StationBuilder.widen(live, from: rock("now"))
        XCTAssertFalse(grew)
        XCTAssertEqual(live.pool.count, 1)
        XCTAssertTrue(MusicServer.calls(to: "/Items/now/InstantMix").isEmpty)
    }
}
#endif
