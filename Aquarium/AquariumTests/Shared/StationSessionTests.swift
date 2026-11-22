//  A station while it plays: how a song leaving the player is read, what the
//  station leans toward after it, what it will and won't deal again, and the
//  two stations that are about the account rather than one thing.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class StationSessionTests: XCTestCase {
    private func song(_ id: String, _ artist: String, _ artistId: String, genres: [String]? = ["Rock"]) -> BaseItem {
        MusicFixture.song(id, artist: artist, artistId: artistId, genres: genres)
    }

    // MARK: How a song leaving the player reads

    func testASongHeardToTheEndIsFinishedHoweverItLeft() {
        XCTAssertEqual(ListenReaction(heard: 10, duration: 200, finished: true, skipped: false), .finished)
        XCTAssertEqual(ListenReaction(heard: 185, duration: 200, finished: false, skipped: true), .finished, "nine tenths heard is the whole song")
        XCTAssertEqual(ListenReaction(heard: 500, duration: 200, finished: false, skipped: false), .finished)
    }

    func testASkipIsJudgedByHowMuchWasHeard() {
        XCTAssertEqual(ListenReaction(heard: 10, duration: 200, finished: false, skipped: true), .skippedEarly)
        XCTAssertEqual(ListenReaction(heard: 40, duration: 200, finished: false, skipped: true), .skippedEarly, "under a quarter")
        XCTAssertEqual(ListenReaction(heard: 20, duration: 30, finished: false, skipped: true), .skippedEarly, "under thirty seconds, however short the song")
        XCTAssertEqual(ListenReaction(heard: 60, duration: 200, finished: false, skipped: true), .skippedMid)
        XCTAssertEqual(ListenReaction(heard: 130, duration: 200, finished: false, skipped: true), .heardMost)
        XCTAssertEqual(ListenReaction(heard: 0, duration: 0, finished: false, skipped: true), .skippedEarly)
    }

    func testStoppingPartWayOnlyEverCountsForTheSong() {
        XCTAssertEqual(ListenReaction(heard: 100, duration: 200, finished: false, skipped: false), .heardMost)
        XCTAssertNil(ListenReaction(heard: 80, duration: 200, finished: false, skipped: false))
        XCTAssertNil(ListenReaction(heard: 80, duration: 0, finished: false, skipped: false))
    }

    // MARK: Leanings

    func testAFinishedSongLeansTowardItsArtistAndGenre() {
        var session = StationSession()
        let queen = song("q", "Queen", "q1")
        session.note(queen, .finished)
        XCTAssertEqual(session.reactions, 1)
        XCTAssertEqual(session.artists, ["id:q1": 1, "name:queen": 1])
        XCTAssertEqual(session.genres, ["rock": 0.5])
        XCTAssertTrue(session.passed.isEmpty)
        XCTAssertEqual(session.lean(for: queen), 3 * tanh(0.5) + 2 * tanh(0.25), accuracy: 1e-9)
        XCTAssertEqual(session.lean(for: song("x", "Nobody", "n1", genres: ["Jazz"])), 0, accuracy: 1e-9)
    }

    func testASkipLeansAwayAndTheSongIsNotOfferedAgain() {
        var session = StationSession()
        let queen = song("q", "Queen", "q1")
        session.note(queen, .skippedEarly)
        XCTAssertEqual(session.passed, ["q"])
        XCTAssertLessThan(session.lean(for: song("q2", "Queen", "q1")), 0)
        session.note(song("m", "Mid", "m1"), .skippedMid)
        session.note(song("r", "Removed", "r1"), .removed)
        session.note(song("h", "Heard", "h1"), .heardMost)
        XCTAssertEqual(session.passed, ["q", "m", "r"], "heard most of it: it may come round again")
        XCTAssertEqual(session.reactions, 4)
    }

    func testEachReactionWeighsWhatItShould() {
        func artistPoints(_ reaction: ListenReaction) -> Double {
            var s = StationSession()
            s.note(song("q", "Queen", "q1"), reaction)
            return s.artists["id:q1"] ?? 0
        }
        XCTAssertEqual(artistPoints(.finished), 1)
        XCTAssertEqual(artistPoints(.heardMost), 0.4)
        XCTAssertEqual(artistPoints(.skippedMid), -0.5)
        XCTAssertEqual(artistPoints(.removed), -0.6)
        XCTAssertEqual(artistPoints(.skippedEarly), -1)
    }

    func testEarlierReactionsFadeAsNewOnesArrive() {
        var session = StationSession()
        session.note(song("q", "Queen", "q1"), .finished)
        session.note(song("a", "Abba", "a1", genres: ["Pop"]), .finished)
        XCTAssertEqual(session.artists["id:q1"] ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(session.artists["id:a1"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(session.genres["rock"] ?? 0, 0.45, accuracy: 1e-9)

        var quick = StationSession(decay: 0.5)
        quick.note(song("q", "Queen", "q1"), .finished)
        quick.note(song("a", "Abba", "a1"), .finished)
        XCTAssertEqual(quick.artists["id:q1"] ?? 0, 0.5, accuracy: 1e-9)
    }

    func testTwoSkipsOfOneArtistOutweighOneFinish() {
        var session = StationSession()
        session.note(song("q1", "Queen", "q1"), .finished)
        session.note(song("q2", "Queen", "q1"), .skippedEarly)
        session.note(song("q3", "Queen", "q1"), .skippedEarly)
        XCTAssertLessThan(session.lean(for: song("q4", "Queen", "q1")), 0)
    }

    func testASongIsJudgedByItsStrongestArtistAndItsGenresOnAverage() {
        var session = StationSession()
        session.note(song("a", "Liked", "l1", genres: ["Rock"]), .finished)
        session.note(song("b", "Disliked", "d1", genres: ["Jazz"]), .skippedEarly)
        var both = song("c", "Liked", "l1", genres: ["Rock", "Jazz"])
        both.ArtistItems?.append(NameGuidPair(Id: "d1", Name: "Disliked"))
        let artist = -1.0 // the skip is the stronger of the two
        let genre = (0.45 + -0.4) / 2
        XCTAssertEqual(session.lean(for: both), 3 * tanh(artist / 2) + 2 * tanh(genre / 2), accuracy: 1e-9)
    }

    func testArtistLeaningsNameEachArtistOnceMostPointsFirst() {
        var session = StationSession()
        session.note(song("q", "Queen", "q1"), .finished)
        var plain = MusicFixture.song("p", artist: nil)
        plain.AlbumArtist = "The Plain Ones"
        session.note(plain, .heardMost)
        session.note(song("x", "Skipped", "s1"), .skippedEarly)
        let leanings = session.artistLeanings
        XCTAssertEqual(leanings.map(\.name), ["Queen", "The Plain Ones", "Skipped"])
        XCTAssertEqual(leanings[0].points, 0.81, accuracy: 1e-9)
        XCTAssertEqual(leanings[1].points, 0.36, accuracy: 1e-9)
        XCTAssertEqual(leanings[2].points, -1, accuracy: 1e-9)
        XCTAssertEqual(leanings[0].id, "Queen")
    }

    func testGenreLeaningsAreByKeyMostPointsFirstThenByName() {
        var session = StationSession()
        session.note(song("a", "A", "a1", genres: ["Rockmusik", "Pop"]), .finished)
        session.note(song("b", "B", "b1", genres: ["Jazz"]), .skippedEarly)
        XCTAssertEqual(session.genreLeanings.map(\.name), ["pop", "rock", "jazz"])
        XCTAssertEqual(session.genreLeanings.map(\.points), [0.45, 0.45, -0.4])
    }

    // MARK: The station and its pool

    private func station(_ pool: [BaseItem]) -> LiveStation {
        LiveStation(title: "Mix", seed: MusicFixture.genre("g", "Rock"), profile: MixProfile(open: true), isLocal: false, pool: pool)
    }

    private func pool(_ n: Int) -> [BaseItem] {
        (0..<n).map { MusicFixture.song("s\($0)", artist: "Act \($0 % 10)", artistId: "act\($0 % 10)") }
    }

    func testThePoolHoldsSongsOnlyAndEachOnce() {
        let live = station(pool(3) + [MusicFixture.album("al", "An Album"), MusicFixture.book("book")])
        XCTAssertEqual(Set(live.pool.keys), ["s0", "s1", "s2"])
        var renamed = MusicFixture.song("s0", "A Different Name")
        renamed.ProductionYear = 1999
        live.add([renamed, MusicFixture.song("s9")])
        XCTAssertEqual(live.pool.count, 4)
        XCTAssertEqual(live.pool["s0"]?.Name, "Song s0", "the first copy is the one kept")
    }

    func testUpcomingLeavesOutWhatPlayedWhatIsBarredAndWhatWasPassedOn() {
        let songs = pool(12)
        let live = station(songs)
        live.session.note(songs[4], .skippedEarly)
        let next = live.upcoming(count: 20, after: [songs[0], songs[1]], exclude: ["s2", "s3"])
        XCTAssertEqual(Set(next.map(\.Id)), Set((5..<12).map { "s\($0)" }))
        XCTAssertEqual(next.count, 7, "and nothing twice")
    }

    func testUpcomingDealsOnlyAsManyAsAsked() {
        let live = station(pool(40))
        XCTAssertEqual(live.upcoming(count: 25, after: []).count, 25)
        XCTAssertEqual(live.upcoming(count: 0, after: []).count, 0)
    }

    func testDealingAgainWithNothingLearnedGivesTheSameOrder() {
        let live = station(pool(40))
        let first = live.upcoming(count: 25, after: []).map(\.Id)
        XCTAssertEqual(live.upcoming(count: 25, after: []).map(\.Id), first, "each song's luck is drawn once, not per deal")
    }

    func testRemainingCountsWhatCouldStillBeOffered() {
        let songs = pool(10)
        let live = station(songs)
        XCTAssertEqual(live.remaining(excluding: []), 10)
        XCTAssertEqual(live.remaining(excluding: ["s0", "s1", "elsewhere"]), 8)
        live.session.note(songs[2], .removed)
        XCTAssertEqual(live.remaining(excluding: ["s0", "s1"]), 7)
        XCTAssertEqual(live.remaining(excluding: ["s2"]), 9, "passed on and already queued is still one song")
    }

    func testAStationLeansTowardAnArtistTheListenerKeepsFinishing() {
        // Twenty by one act, twenty by another; nothing to choose between them
        // until the listener finishes three by the first.
        let liked = (0..<20).map { MusicFixture.song("l\($0)", artist: "Liked \($0 % 5)", artistId: "liked", genres: ["Rock"]) }
        let other = (0..<20).map { MusicFixture.song("o\($0)", artist: "Other \($0 % 5)", artistId: "other", genres: ["Jazz"]) }
        let live = station(liked + other)
        for s in liked.prefix(3) { live.session.note(s, .finished) }
        for s in other.prefix(3) { live.session.note(s, .skippedEarly) }
        let next = live.upcoming(count: 10, after: Array(liked.prefix(3)))
        XCTAssertGreaterThan(next.filter { $0.Id.hasPrefix("l") }.count, 5, "\(next.map(\.Id))")
        XCTAssertFalse(next.contains { ["o0", "o1", "o2"].contains($0.Id) })
    }

    // MARK: Rediscover and Deep Cuts

    func testASpecialStationsSeedSaysWhichItIs() {
        let seed = SpecialStation.deepCuts.seed(cover: nil)
        XCTAssertEqual(seed.Id, "fj-station:deepCuts")
        XCTAssertEqual(seed.Name, "Deep Cuts")
        XCTAssertEqual(SpecialStation(seed: seed), .deepCuts)
        XCTAssertEqual(SpecialStation(seed: SpecialStation.rediscover.seed(cover: nil)), .rediscover)
        XCTAssertNil(SpecialStation(seed: MusicFixture.song("s")))
        XCTAssertNil(SpecialStation(seed: MusicFixture.item("fj-station:unheardOf", "?", type: "Audio")))
    }

    func testASpecialStationsSeedWearsItsCoversArtwork() {
        var cover = MusicFixture.song("c", albumId: "al9")
        cover.AlbumPrimaryImageTag = "tag9"
        cover.ExternalLogoURL = "file:///cover.jpg"
        let seed = SpecialStation.rediscover.seed(cover: cover)
        XCTAssertEqual(seed.AlbumId, "al9")
        XCTAssertEqual(seed.AlbumPrimaryImageTag, "tag9")
        XCTAssertEqual(seed.ExternalLogoURL, "file:///cover.jpg")
        XCTAssertFalse(seed.isSong, "it is a tile, not something to play")
    }

    func testBothSpecialStationsAreOfferedAndNamed() {
        XCTAssertEqual(SpecialStation.available(), [.rediscover, .deepCuts])
        XCTAssertEqual(SpecialStation.rediscover.title, "Rediscover")
        XCTAssertEqual(SpecialStation.deepCuts.title, "Deep Cuts")
        XCTAssertFalse(SpecialStation.rediscover.subtitle.isEmpty)
        XCTAssertNotEqual(SpecialStation.rediscover.subtitle, SpecialStation.deepCuts.subtitle)
    }

    // MARK: What the tags leave out

    func testADialsNoteSaysHowManySongsLackItsTag() {
        var coverage = TagCoverage()
        coverage.songs = 200
        coverage.noArtist = 8
        coverage.noGenre = 61
        coverage.noYear = 10
        XCTAssertNil(coverage.note(for: .artist), "four in a hundred is not worth saying")
        XCTAssertEqual(coverage.note(for: .genre)?.hasPrefix("31% of the songs"), true, "30.5 rounds up")
        XCTAssertEqual(coverage.note(for: .genre)?.contains("no genre tag"), true)
        XCTAssertEqual(coverage.note(for: .era)?.contains("5% of the songs"), true)
        XCTAssertEqual(coverage.note(for: .era)?.contains("no year tag"), true)
        for dial in [MixPoints.Dial.favorites, .mostPlayed, .discovery, .surprise] {
            XCTAssertNil(coverage.note(for: dial), "\(dial) reads no tag")
        }
    }

    func testNoNoteBeforeAnyStationHasPlayed() {
        XCTAssertNil(TagCoverage().note(for: .genre))
    }

    func testCoverageAddsUpTheLastFiveStations() {
        let key = "music_tag_coverage"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(TagCoverage.recent.songs, 0)

        var noArtist = MusicFixture.song("a", artist: nil, genres: ["Rock"], year: 1990)
        noArtist.Artists = nil
        let full = MusicFixture.song("b", genres: ["Rock"], year: 1990)
        let noGenre = MusicFixture.song("c", year: 1990)
        let bare = MusicFixture.song("d")
        TagCoverage.record([noArtist, full, noGenre, bare])
        var recent = TagCoverage.recent
        XCTAssertEqual([recent.songs, recent.noArtist, recent.noGenre, recent.noYear], [4, 1, 2, 1])

        TagCoverage.record([BaseItem]())
        XCTAssertEqual(TagCoverage.recent.songs, 4, "a station with nothing in it is not counted")

        for _ in 0..<5 { TagCoverage.record([full, full]) }
        recent = TagCoverage.recent
        XCTAssertEqual([recent.songs, recent.noArtist, recent.noGenre, recent.noYear], [10, 0, 0, 0], "the first has dropped off the end")
    }
}
#endif
