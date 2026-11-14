//  How a station chooses and orders songs: genre and artist names, the
//  listener's points, the seed's profile, and the ranker's score and deal.
//  All of it is worked out from the songs handed in; no server, no player.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class StationEngineTests: XCTestCase {
    private var savedRomanize = true

    override func setUp() async throws {
        savedRomanize = Preferences.shared.musicRomanizeNames
        Preferences.shared.musicRomanizeNames = true
    }

    override func tearDown() async throws {
        Preferences.shared.musicRomanizeNames = savedRomanize
    }

    /// The dials as stations had them before points, less the luck: a score
    /// is the same every time.
    private let steady = MixPoints([.artist: 5, .genre: 6, .era: 3, .favorites: 2, .mostPlayed: 2])

    private func queenSong(_ id: String = "seed") -> BaseItem {
        MusicFixture.song(id, artist: "Queen", artistId: "q1", album: "A Night at the Opera", albumId: "al1", genres: ["Rock"], year: 1975)
    }

    // MARK: Genre names

    func testOneKeyForAGenreHoweverItIsSpelled() {
        for spelling in ["Rock", "ROCK", "Rockmusik", "Rock Music", "Musique Rock", "ロック", "рок", "摇滚"] {
            XCTAssertEqual(MusicNames.genreKey(spelling), "rock", spelling)
        }
        XCTAssertEqual(MusicNames.genreKey("Hip-Hop"), "hip hop")
        XCTAssertEqual(MusicNames.genreKey("Hip-Hop/Rap"), "hip hop")
        XCTAssertEqual(MusicNames.genreKey("Klassische Musik"), "classical")
        XCTAssertEqual(MusicNames.genreKey("Música Latina"), "latin", "accents are folded")
        XCTAssertEqual(MusicNames.genreKey("R&B"), "r&b")
        XCTAssertEqual(MusicNames.genreKey("Original Soundtrack"), "soundtrack")
    }

    func testAGenreTheTableDoesNotKnowKeepsItsOwnNameLessTheWordMusic() {
        XCTAssertEqual(MusicNames.genreKey("Shoegaze"), "shoegaze")
        XCTAssertEqual(MusicNames.genreKey("Shoegaze Music"), "shoegaze")
        XCTAssertEqual(MusicNames.genreKey("Dream_Pop"), "dream pop")
        XCTAssertEqual(MusicNames.genreKey("Music"), "music", "a tag that is only the filler word is kept, not emptied")
    }

    func testAGenreIsShownByItsEnglishNameOrAsWrittenCapitalised() {
        XCTAssertEqual(MusicNames.genreName("rockmusik"), "Rock")
        XCTAssertEqual(MusicNames.genreName("hip hop"), "Hip-Hop")
        XCTAssertEqual(MusicNames.genreName("Рок"), "Rock")
        XCTAssertEqual(MusicNames.genreName("ジャズ"), "Jazz")
        XCTAssertEqual(MusicNames.genreName("dream pop"), "Dream Pop")
    }

    func testAGenreInAnotherScriptThatNoTableKnowsIsShownInLatinLetters() {
        let shown = MusicNames.genreName("Шугейз")
        XCTAssertTrue(MusicNames.isLatin(shown), shown)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertEqual(String(shown.prefix(1)), shown.prefix(1).uppercased())
    }

    // MARK: Artist names

    func testLatinDetection() {
        XCTAssertTrue(MusicNames.isLatin("Björk"))
        XCTAssertTrue(MusicNames.isLatin("Sigur Rós 2"))
        XCTAssertFalse(MusicNames.isLatin("Кино"))
        XCTAssertFalse(MusicNames.isLatin("宇多田ヒカル"))
    }

    func testALatinNameIsLeftAlone() {
        XCTAssertEqual(MusicNames.artistName("Radiohead", sortName: "radiohead"), "Radiohead")
        XCTAssertEqual(MusicNames.artistName(""), "")
    }

    func testTheServersLatinSortNameIsUsedTurnedTheRightWayRound() {
        XCTAssertEqual(MusicNames.artistName("宇多田ヒカル", sortName: "Utada, Hikaru"), "Hikaru Utada")
        XCTAssertEqual(MusicNames.artistName("宇多田ヒカル", sortName: "Hikaru Utada"), "Hikaru Utada")
    }

    func testJapaneseWithKanjiIsNotGuessedAt() {
        XCTAssertEqual(MusicNames.artistName("宇多田ヒカル"), "宇多田ヒカル")
        XCTAssertEqual(MusicNames.artistName("宇多田ヒカル", sortName: "宇多田ヒカル"), "宇多田ヒカル")
    }

    func testCyrillicIsTransliterated() {
        XCTAssertEqual(MusicNames.artistName("Кино"), "Kino")
    }

    func testNothingIsRomanizedWhenTheSettingIsOff() {
        Preferences.shared.musicRomanizeNames = false
        XCTAssertEqual(MusicNames.artistName("Кино"), "Кино")
        XCTAssertEqual(MusicNames.artistName("宇多田ヒカル", sortName: "Utada, Hikaru"), "宇多田ヒカル")
    }

    // MARK: Keys

    func testAnArtistIsKnownByIdAndByName() {
        XCTAssertEqual(MusicKeys.artist(id: "q1", name: "Queen"), ["id:q1", "name:queen"])
        XCTAssertEqual(MusicKeys.artist(id: nil, name: "Queen"), ["name:queen"])
        XCTAssertEqual(MusicKeys.artist(id: "", name: ""), [])
    }

    func testASongsArtistsAreEveryoneCreditedOnIt() {
        var song = queenSong()
        song.ArtistItems = [NameGuidPair(Id: "q1", Name: "Queen"), NameGuidPair(Id: "b1", Name: "David Bowie")]
        song.Artists = ["Queen", "David Bowie"]
        XCTAssertEqual(MusicKeys.artists(of: song), ["id:q1", "name:queen", "id:b1", "name:david bowie"])
        XCTAssertEqual(MusicKeys.act(of: song), ["id:q1", "name:queen"], "the act is who it is billed to, not its guests")
        XCTAssertEqual(MusicKeys.lead(of: song), "queen")
    }

    func testASongWithNoAlbumArtistIsBilledToItsFirstArtist() {
        var song = MusicFixture.song("s", artist: nil)
        song.ArtistItems = [NameGuidPair(Id: "x1", Name: " Some Act "), NameGuidPair(Id: "x2", Name: "Guest")]
        XCTAssertEqual(MusicKeys.lead(of: song), "some act")
        XCTAssertEqual(MusicKeys.act(of: song), ["id:x1", "name: some act "])
        var bare = MusicFixture.song("t", artist: nil)
        bare.Artists = ["Only", "Names"]
        XCTAssertEqual(MusicKeys.lead(of: bare), "only, names")
        XCTAssertEqual(MusicKeys.act(of: bare), [])
    }

    func testASongsGenresAreKeysEachOnce() {
        let song = MusicFixture.song("s", genres: ["Rock", "Rockmusik", "Pop Music", "Shoegaze"])
        XCTAssertEqual(MusicKeys.genres(of: song), ["rock", "pop", "shoegaze"])
        var byItems = MusicFixture.song("t")
        byItems.GenreItems = [NameGuidPair(Id: "g1", Name: "Jazz"), NameGuidPair(Id: "g2", Name: nil)]
        XCTAssertEqual(MusicKeys.genres(of: byItems), ["jazz"])
        XCTAssertEqual(MusicKeys.genres(of: MusicFixture.song("u")), [])
    }

    // MARK: Points

    func testThePresetsSpendTheWholeBudget() {
        XCTAssertEqual(MixPoints.budget, 20)
        for preset in MixPoints.presets {
            XCTAssertEqual(preset.points.remaining, 0, preset.name)
            XCTAssertEqual(preset.points.presetName, preset.name)
        }
        XCTAssertEqual(MixPoints.presets.map(\.name), ["Balanced", "Familiar", "Discovery"])
    }

    func testBalancedComesToTheWeightsStationsAlwaysHad() {
        let p = MixPoints.balanced
        XCTAssertEqual(p.weight(.artist), 3.0, accuracy: 1e-9)
        XCTAssertEqual(p.weight(.genre), 4.0, accuracy: 1e-9)
        XCTAssertEqual(p.weight(.era), 1.5, accuracy: 1e-9)
        XCTAssertEqual(p.weight(.favorites), 0.6, accuracy: 1e-9)
        XCTAssertEqual(p.weight(.mostPlayed), 0.6, accuracy: 1e-9)
        XCTAssertEqual(p.weight(.discovery), 0, accuracy: 1e-9)
        XCTAssertEqual(p.weight(.surprise), 1.2, accuracy: 1e-9)
    }

    func testADialCannotTakeMoreThanTheBudgetHasLeft() {
        var p = MixPoints([.artist: 10])
        XCTAssertEqual(p.remaining, 10)
        p[.genre] = 30
        XCTAssertEqual(p[.genre], 10)
        XCTAssertEqual(p.remaining, 0)
        p[.era] = 4
        XCTAssertEqual(p[.era], 0, "nothing left to spend")
        p[.artist] = 2
        XCTAssertEqual(p.remaining, 8)
        p[.era] = -3
        XCTAssertEqual(p[.era], 0)
    }

    func testAnAllocationOverTheBudgetLosesPointsInTheDialsOwnOrder() {
        let p = MixPoints([.genre: 15, .artist: 15, .surprise: 15])
        XCTAssertEqual(p[.artist], 15)
        XCTAssertEqual(p[.genre], 5)
        XCTAssertEqual(p[.surprise], 0)
    }

    func testAnAllocationThatIsNoPresetIsCustom() {
        XCTAssertEqual(MixPoints([.artist: 20]).presetName, "Custom")
        XCTAssertEqual(MixPoints().presetName, "Custom")
    }

    func testPointsSurviveBeingStored() {
        let p = MixPoints([.artist: 1, .genre: 2, .era: 3, .favorites: 4, .mostPlayed: 5, .discovery: 2, .surprise: 3])
        XCTAssertEqual(Set(p.stored.keys), Set(MixPoints.Dial.allCases.map(\.rawValue)))
        XCTAssertEqual(MixPoints(stored: p.stored), p)
        XCTAssertNil(MixPoints(stored: "balanced"))
        XCTAssertNil(MixPoints(stored: nil))
        let partial = MixPoints(stored: ["artist": 3, "someNewDial": 9])
        XCTAssertEqual(partial?[.artist], 3)
        XCTAssertEqual(partial?.remaining, 17)
    }

    // MARK: The seed's profile

    func testAGenreSeedIsItsGenreAndNothingElse() {
        let profile = MixProfile(seed: MusicFixture.genre("g", "Rockmusik"))
        XCTAssertEqual(profile.genres, ["rock": 1])
        XCTAssertTrue(profile.artists.isEmpty)
        XCTAssertNil(profile.year)
        XCTAssertFalse(profile.isOpen)
    }

    func testAnArtistSeedIsTheArtistWithTheirSongsGenresAndNoDecade() {
        let seed = MusicFixture.artist("q1", "Queen")
        var duet = MusicFixture.song("d", artist: "Queen", artistId: "q1", genres: ["Rock", "Pop"], year: 1981)
        duet.ArtistItems?.append(NameGuidPair(Id: "b1", Name: "David Bowie"))
        let profile = MixProfile(seed: seed, members: [queenSong("a"), duet])
        XCTAssertTrue(profile.isArtistStation)
        XCTAssertEqual(profile.artists, ["id:q1", "name:queen"], "a guest on one song is not who the station is about")
        XCTAssertEqual(profile.genres, ["rock": 2, "pop": 1])
        XCTAssertNil(profile.year)
    }

    func testAnAlbumSeedTakesItsYearAndItsTracksArtistsAndGenres() {
        let profile = MixProfile(seed: MusicFixture.album("al1", "A Night at the Opera", year: 1975), members: [queenSong("a"), queenSong("b")])
        XCTAssertEqual(profile.albumId, "al1")
        XCTAssertEqual(profile.year, 1975)
        XCTAssertEqual(profile.artists, ["id:q1", "name:queen"])
        XCTAssertEqual(profile.genres, ["rock": 2])
        XCTAssertFalse(profile.isArtistStation)
    }

    func testAnAlbumWithNoYearTakesTheMiddleOneOfItsTracks() {
        let tracks = [1990, 1970, 1980].enumerated().map { MusicFixture.song("t\($0.offset)", year: $0.element) }
        XCTAssertEqual(MixProfile(seed: MusicFixture.album("al", "Collected"), members: tracks).year, 1980)
    }

    func testASongSeedIsMeasuredAgainstItself() {
        let profile = MixProfile(seed: queenSong())
        XCTAssertEqual(profile.songId, "seed")
        XCTAssertEqual(profile.albumId, "al1")
        XCTAssertEqual(profile.year, 1975)
        XCTAssertEqual(profile.artists, ["id:q1", "name:queen"])
        XCTAssertEqual(profile.genres, ["rock": 1])
    }

    func testGenreWordsLeaveOutFillerAndSingleLetters() {
        XCTAssertEqual(MixProfile.words("indie rock"), ["indie", "rock"])
        XCTAssertEqual(MixProfile.words("rock and roll"), ["rock", "roll"])
        XCTAssertEqual(MixProfile.words("r&b"), [])
    }

    func testGenreAffinityIsTheShareOfTheSeedsGenresCovered() {
        let profile = MixProfile(seed: MusicFixture.song("s", genres: ["Rock", "Jazz"]))
        XCTAssertEqual(profile.genreAffinity(["rock", "jazz"]), 1, accuracy: 1e-9)
        XCTAssertEqual(profile.genreAffinity(["rock"]), 0.5, accuracy: 1e-9)
        XCTAssertEqual(profile.genreAffinity(["pop"]), 0, accuracy: 1e-9)
        XCTAssertEqual(profile.genreAffinity([]), 0, accuracy: 1e-9)
    }

    func testASharedWordCountsForHalf() {
        let profile = MixProfile(seed: MusicFixture.song("s", genres: ["Indie Rock"]))
        // "rock" is one of the seed's two words, at half weight.
        XCTAssertEqual(profile.genreAffinity(["rock"]), 0.25, accuracy: 1e-9)
        XCTAssertEqual(profile.genreAffinity(["indie rock"]), 1, accuracy: 1e-9)
        XCTAssertEqual(MixProfile(open: true).genreAffinity(["rock"]), 0, accuracy: 1e-9)
    }

    func testLikenessAddsUpArtistGenreEraAndAlbum() {
        let profile = MixProfile(seed: queenSong())
        let twin = MusicFixture.song("twin", artist: "Queen", artistId: "q1", albumId: "al1", genres: ["Rock"], year: 1980)
        // 3 for the artist, 4 for the genre, 1.5 × (1 − 5/15) for five years off, a half for the album.
        XCTAssertEqual(try XCTUnwrap(profile.likeness(twin, points: .balanced)), 8.5, accuracy: 1e-9)
        let sameGenre = MusicFixture.song("g", artist: "Other", artistId: "o1", genres: ["Rock"])
        XCTAssertEqual(try XCTUnwrap(profile.likeness(sameGenre, points: .balanced)), 4.0, accuracy: 1e-9)
        let farOff = MusicFixture.song("f", artist: "Other", artistId: "o1", genres: ["Rock"], year: 2010)
        XCTAssertEqual(try XCTUnwrap(profile.likeness(farOff, points: .balanced)), 4.0, accuracy: 1e-9, "fifteen years or more off earns nothing for era")
    }

    func testNothingInCommonIsNoLikenessAtAll() {
        let profile = MixProfile(seed: queenSong())
        XCTAssertNil(profile.likeness(MusicFixture.song("p", artist: "Other", artistId: "o1", genres: ["Pop"], year: 1975), points: .balanced))
    }

    func testADialAtZeroStopsCountingButTheSongIsStillAlike() throws {
        let profile = MixProfile(seed: queenSong())
        let sameArtist = MusicFixture.song("a", artist: "Queen", artistId: "q1", genres: ["Disco"])
        let noArtistPoints = MixPoints([.genre: 10])
        XCTAssertEqual(try XCTUnwrap(profile.likeness(sameArtist, points: noArtistPoints)), 0, accuracy: 1e-9)
    }

    func testAnOpenStationLikesEverythingEqually() {
        XCTAssertEqual(MixProfile(open: true).likeness(MusicFixture.song("x", artist: nil), points: .balanced), 1)
    }

    // MARK: One act under several billings

    func testANameThatBeginsAnotherIsTheSameAct() {
        XCTAssertTrue(ArtistGroups.sameAct("tom petty", "tom petty and the heartbreakers"))
        XCTAssertTrue(ArtistGroups.sameAct("tom petty and the heartbreakers", "tom petty"))
        XCTAssertFalse(ArtistGroups.sameAct("air", "air supply"), "too short to be sure")
        XCTAssertFalse(ArtistGroups.sameAct("tom petty", "tom pettyfer"), "not at a word boundary")
        XCTAssertFalse(ArtistGroups.sameAct("tom petty", "tom petty"))
    }

    func testBillingsThatShareAnAlbumArtistAreOneAct() {
        var groups = ArtistGroups()
        XCTAssertEqual(groups.of(MusicFixture.song("1", artist: "Tom Petty", artistId: "p1")), "tom petty")
        XCTAssertEqual(groups.of(MusicFixture.song("2", artist: "Tom Petty and the Heartbreakers", artistId: "p2")), "tom petty")
        var side = MusicFixture.song("3", artist: "Mudcrutch", artistId: "m1")
        side.AlbumArtists?.append(NameGuidPair(Id: "p1", Name: "Tom Petty"))
        XCTAssertEqual(groups.of(side), "tom petty")
        XCTAssertEqual(groups.of(MusicFixture.song("4", artist: "Queen", artistId: "q1")), "queen")
        XCTAssertEqual(groups.of(MusicFixture.song("5", artist: "Mudcrutch", artistId: "m1")), "tom petty", "and stays so once decided")
    }

    // MARK: Scoring

    func testScoreOrdersByLikenessStarsAndPlays() {
        let profile = MixProfile(seed: queenSong())
        let twin = MusicFixture.song("twin", artist: "Queen", artistId: "q1", genres: ["Rock"], year: 1975)
        let loved = MusicFixture.song("loved", artist: "Queen", artistId: "q1", genres: ["Rock"], year: 1975, plays: 15)
        let starred = MusicFixture.song("starred", artist: "Other", artistId: "o1", genres: ["Rock"], favorite: true)
        let unlike = MusicFixture.song("unlike", artist: "Other", artistId: "o1", genres: ["Pop"])
        let scored = StationRanker.score(
            [unlike, starred, queenSong(), twin, loved, MusicFixture.song("barred")],
            profile: profile, exclude: ["barred"], points: steady
        )
        XCTAssertEqual(scored.map(\.song.Id), ["loved", "twin", "starred", "unlike"], "the seed itself and what is excluded are left out")
        XCTAssertEqual(scored[0].score, 9.1, accuracy: 1e-9, "8.5 alike, and all of the most-played dial at fifteen plays")
        XCTAssertEqual(scored[1].score, 8.5, accuracy: 1e-9)
        XCTAssertEqual(scored[2].score, 4.6, accuracy: 1e-9, "4 for the genre, 0.6 for the star")
        XCTAssertEqual(scored[3].score, -4, accuracy: 1e-9)
        XCTAssertEqual(scored.map(\.alike), [true, true, true, false])
        XCTAssertEqual(scored[2].artist, "other")
    }

    func testTheDiscoveryDialFavoursWhatHasNeverBeenPlayed() {
        let profile = MixProfile(open: true)
        let points = MixPoints([.discovery: 5])
        let scored = StationRanker.score(
            [MusicFixture.song("heard", plays: 3), MusicFixture.song("new")], profile: profile, points: points
        )
        XCTAssertEqual(scored.map(\.song.Id), ["new", "heard"])
        XCTAssertEqual(scored[0].score - scored[1].score, 2.0, accuracy: 1e-9)
    }

    func testTheSurpriseDialAddsEachSongsOwnLuck() {
        let points = MixPoints([.surprise: 2])
        let scored = StationRanker.score(
            MusicFixture.songs(["a", "b"]), profile: MixProfile(open: true), points: points, luck: ["a": 0.25, "b": 0.75]
        )
        XCTAssertEqual(scored.map(\.song.Id), ["b", "a"])
        XCTAssertEqual(scored[0].score, 1 + 1.2 * 0.75, accuracy: 1e-9)
        XCTAssertEqual(scored[1].score, 1 + 1.2 * 0.25, accuracy: 1e-9)
    }

    func testWhatHappenedInTheStationMovesTheScore() {
        let profile = MixProfile(seed: queenSong())
        let other = MusicFixture.song("o", artist: "Other", artistId: "o1", genres: ["Rock"])
        var session = StationSession()
        session.note(MusicFixture.song("o2", artist: "Other", artistId: "o1", genres: ["Rock"]), .finished)
        let plain = StationRanker.score([other], profile: profile, points: steady)[0].score
        let leaning = StationRanker.score([other], profile: profile, session: session, points: steady)[0].score
        XCTAssertEqual(leaning - plain, session.lean(for: other), accuracy: 1e-9)
        XCTAssertGreaterThan(leaning, plain)
    }

    // MARK: Dealing

    private func scored(
        _ id: String, _ artist: String, _ score: Double, album: String? = nil, year: Int? = nil,
        genres: [String]? = nil, alike: Bool = true
    ) -> StationRanker.Scored {
        let song = MusicFixture.song(id, artist: artist, artistId: "id-\(artist)", albumId: album, genres: genres, year: year)
        return StationRanker.Scored(song: song, score: score, alike: alike, artist: artist.lowercased())
    }

    private func deal(_ list: [StationRanker.Scored], _ count: Int, profile: MixProfile = MixProfile(open: true), after: [BaseItem] = []) -> [String] {
        StationRanker.sequence(list, count: count, profile: profile, after: after).map(\.Id)
    }

    func testNothingAskedForIsNothingDealt() {
        XCTAssertEqual(deal([scored("a", "A", 1)], 0), [])
        XCTAssertEqual(deal([], 5), [])
    }

    func testAnArtistIsSpacedOutRatherThanPlayedBackToBack() {
        let list = [
            scored("a1", "Alpha", 10), scored("a2", "Alpha", 9.9), scored("a3", "Alpha", 9.8),
            scored("b1", "Beta", 9), scored("b2", "Beta", 8.9), scored("c1", "Gamma", 8),
        ]
        XCTAssertEqual(deal(list, 6), ["a1", "b1", "c1", "a2", "b2", "a3"])
    }

    func testTheFirstPickFollowsOnFromWhatAlreadyPlayed() {
        let list = [scored("a1", "Alpha", 10), scored("b1", "Beta", 9)]
        let history = [MusicFixture.song("h", artist: "Alpha", artistId: "id-Alpha")]
        XCTAssertEqual(deal(list, 2, after: history), ["b1", "a1"])
        XCTAssertEqual(deal(list, 2), ["a1", "b1"])
    }

    func testOneActUnderTwoBillingsDoesNotFollowItself() {
        let list = [
            scored("p1", "Tom Petty", 10), scored("p2", "Tom Petty and the Heartbreakers", 9.9), scored("q", "Queen", 9),
        ]
        XCTAssertEqual(deal(list, 3), ["p1", "q", "p2"])
    }

    func testAnAlbumIsNotPlayedTwiceRunningWhenSomethingElseIsClose() {
        let list = [
            scored("x1", "Alpha", 10, album: "comp"), scored("x2", "Beta", 9.5, album: "comp"),
            scored("x3", "Gamma", 8.5, album: "other"),
        ]
        XCTAssertEqual(deal(list, 3), ["x1", "x3", "x2"])
    }

    func testAJumpOfDecadesWaitsForSomethingCloser() {
        let list = [
            scored("y1", "Alpha", 10, year: 1970), scored("y2", "Beta", 9.5, year: 2015), scored("y3", "Gamma", 9.0, year: 1975),
        ]
        XCTAssertEqual(deal(list, 3), ["y1", "y3", "y2"])
    }

    func testASharedGenreWithTheLastSongTipsACloseCall() {
        let list = [
            scored("g1", "Alpha", 10, genres: ["Rock"]), scored("g2", "Beta", 9.0, genres: ["Jazz"]),
            scored("g3", "Gamma", 8.8, genres: ["Rockmusik"]),
        ]
        XCTAssertEqual(deal(list, 3), ["g1", "g3", "g2"])
    }

    func testAThinStationIsToppedUpWithTheNearestOfTheRest() {
        var list = [scored("like1", "Alpha", 9), scored("like2", "Beta", 8)]
        list += (0..<30).map { scored("far\($0)", "Far \($0)", -4 - Double($0) / 100, alike: false) }
        let out = deal(list, 10)
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(Array(out.prefix(2)), ["like1", "like2"])
        XCTAssertEqual(Array(out.dropFirst(2)), (0..<8).map { "far\($0)" }, "the nearest of the unlike, best first")
    }

    func testOnlyAlikeSongsWhenThereAreEnough() {
        var list = (0..<25).map { scored("like\($0)", "Act \($0)", 9 - Double($0) / 100) }
        list += (0..<10).map { scored("far\($0)", "Far \($0)", -4, alike: false) }
        let out = deal(list, 30)
        XCTAssertEqual(out.count, 25, "a station of what is alike ends rather than pad itself")
        XCTAssertFalse(out.contains { $0.hasPrefix("far") })
    }

    func testNoArtistTakesMoreThanAQuarterOfTheDeal() {
        var list = (0..<20).map { scored("a\($0)", "Alpha", 50 - Double($0)) }
        for act in ["Beta", "Gamma", "Delta", "Eta", "Theta", "Iota"] {
            list += (0..<3).map { scored("\(act)\($0)", act, 10 - Double($0)) }
        }
        let out = deal(list, 12)
        XCTAssertEqual(out.count, 12)
        XCTAssertEqual(out.filter { $0.hasPrefix("a") }.count, 3)
    }

    func testTheCapGivesWayRatherThanCutAStationShort() {
        var list = (0..<20).map { scored("a\($0)", "Alpha", 50 - Double($0)) }
        list += (0..<3).map { scored("b\($0)", "Beta", 10 - Double($0)) }
        let out = deal(list, 12)
        XCTAssertEqual(out.count, 12)
        XCTAssertEqual(out.filter { $0.hasPrefix("b") }.count, 3)
    }

    func testAnArtistsOwnStationLetsThemHaveTwoFifths() {
        let profile = MixProfile(seed: MusicFixture.artist("id-Alpha", "Alpha"))
        var list = (0..<20).map { scored("a\($0)", "Alpha", 50 - Double($0)) }
        list += (0..<20).map { scored("o\($0)", "Other \($0)", 10 - Double($0) / 10) }
        let out = deal(list, 20, profile: profile)
        XCTAssertEqual(out.count, 20)
        XCTAssertEqual(out.filter { $0.hasPrefix("a") }.count, 8)
    }
}
#endif
