//  How the records fold into shows, seasons and films for the Downloads page
//  (`DownloadGroups`), built from the records alone so it works with no
//  server to ask. See Support/DownloadHarness.swift.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadGroupsTests: DownloadTestCase {
    private func episode(
        _ name: String, show: String? = "Show", showId: String? = "show1", season: Int?, number: Int?,
        _ status: DownloadRecord.Status = .complete, _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) -> DownloadRecord {
        record(newId(), status, type: "Episode", name: name) {
            $0.series = show
            $0.seriesId = showId
            $0.season = season
            $0.episode = number
            configure(&$0)
        }
    }

    // MARK: Films

    /// The grid over downloaded films is headed "Movies", the word the rest
    /// of the app (and the Linux app) uses; it said "Films" until 2026-11-16.
    func testMoviesGridIsHeadedMovies() {
        XCTAssertEqual(DownloadGroups.moviesHeading, "Movies")
        XCTAssertEqual(DownloadGroups.showsHeading, "Shows")
    }

    func testFilmsAreFinishedVideoThatIsNotAnEpisodeAlphabetically() {
        let records = [
            record("f1", name: "zodiac"),
            record("f2", name: "Alien"),
            record("f3", name: "Éclair"),
            record("f4", .downloading, name: "Arriving"),
            record("f5", .error, name: "Failed"),
            record("s1", type: "Audio", name: "A Song"),
            record("b1", type: "AudioBook", name: "A Book"),
            episode("An Episode", season: 1, number: 1),
            record("f6", type: nil, name: "Heat"),
        ]
        XCTAssertEqual(DownloadGroups.films(records).map(\.name), ["Alien", "Éclair", "Heat", "zodiac"],
                       "as a person would file them, not by code point")
        XCTAssertTrue(DownloadGroups.films([]).isEmpty)
    }

    // MARK: Shows

    func testEpisodesGroupIntoTheirShowsAlphabetically() {
        let records = [
            episode("B1", show: "Beta", showId: "b", season: 1, number: 1),
            episode("A2", show: "alpha", showId: "a", season: 1, number: 2),
            episode("A1", show: "alpha", showId: "a", season: 1, number: 1),
            episode("Arriving", show: "alpha", showId: "a", season: 1, number: 3, .downloading),
            episode("Gone", show: "Gamma", showId: "g", season: 1, number: 1, .error),
            record("film", name: "A Film"),
            record("song", type: "Audio", name: "A Song") { $0.series = "alpha" },
        ]
        let shows = DownloadGroups.series(records)
        XCTAssertEqual(shows.map(\.title), ["alpha", "Beta"], "only shows with something finished")
        XCTAssertEqual(shows.map(\.id), ["a", "b"])
        XCTAssertEqual(shows[0].records.map(\.name), ["A1", "A2"])
        XCTAssertEqual(shows[0].subtitle, "1 season · 2 episodes")
        XCTAssertEqual(shows[1].subtitle, "1 season · 1 episode")
        XCTAssertTrue(DownloadGroups.series([]).isEmpty)
    }

    func testSeasonsAreCutInOrderWithSpecialsAndStraysLast() {
        let records = [
            episode("Special", season: 0, number: 1),
            episode("Stray", season: nil, number: nil),
            episode("S2E1", season: 2, number: 1),
            episode("S1E2", season: 1, number: 2),
            episode("S10E1", season: 10, number: 1),
            episode("S1E1", season: 1, number: 1),
            episode("S1 extra B", season: 1, number: nil),
            episode("S1 extra A", season: 1, number: nil),
        ]
        let show = DownloadGroups.series(records)[0]
        XCTAssertEqual(show.seasons.map(\.title), ["Season 1", "Season 2", "Season 10", "Specials", "Other episodes"])
        XCTAssertEqual(show.seasons.map(\.id), ["show1-1", "show1-2", "show1-10", "show1-0", "show1-none"])
        XCTAssertEqual(show.seasons[0].records.map(\.name), ["S1 extra A", "S1 extra B", "S1E1", "S1E2"],
                       "by number, and by name where there is none")
        XCTAssertEqual(show.records.map(\.name),
                       ["S1 extra A", "S1 extra B", "S1E1", "S1E2", "S2E1", "S10E1", "Special", "Stray"],
                       "what Play and Shuffle draw from, in watching order")
        XCTAssertEqual(show.subtitle, "5 seasons · 8 episodes")
    }

    func testRecordsFromBeforeSeriesIdsStillGroupByName() {
        let old1 = episode("One", show: "Old Show", showId: nil, season: 1, number: 1)
        let old2 = episode("Two", show: "Old Show", showId: "", season: 1, number: 2)
        let nameless = episode("Orphan", show: nil, showId: nil, season: nil, number: nil)
        XCTAssertEqual(DownloadGroups.key(for: old1), "name:Old Show")
        XCTAssertEqual(DownloadGroups.key(for: old2), "name:Old Show", "an empty id is no id")
        XCTAssertEqual(DownloadGroups.key(for: nameless), "name:Orphan", "its own title, rather than a show of nothing")
        XCTAssertEqual(DownloadGroups.key(for: episode("x", showId: "abc", season: 1, number: 1)), "abc")

        let shows = DownloadGroups.series([old1, old2, nameless])
        XCTAssertEqual(shows.map(\.title), ["Old Show", "Orphan"])
        XCTAssertEqual(shows[0].records.count, 2, "one show of two, not two shows of one")
        XCTAssertEqual(shows[0].id, "name:Old Show")
    }

    func testTwoShowsOfTheSameNameStayApart() {
        let shows = DownloadGroups.series([
            episode("Original", show: "The Office", showId: "uk", season: 1, number: 1),
            episode("Remake", show: "The Office", showId: "us", season: 1, number: 1),
        ])
        XCTAssertEqual(shows.count, 2)
        XCTAssertEqual(Set(shows.map(\.id)), ["uk", "us"])
    }

    // MARK: What a show and a season say about themselves

    func testCountsSizesAndWhereToStart() throws {
        let first = episode("S1E1", season: 1, number: 1) {
            $0.played = true
            $0.totalBytes = 1_000
        }
        let second = episode("S1E2", season: 1, number: 2) {
            $0.receivedBytes = 700
            $0.totalBytes = 500
        }
        let third = episode("S2E1", season: 2, number: 1) { $0.receivedBytes = 300 }
        var show = try XCTUnwrap(DownloadGroups.series([third, second, first]).first)
        XCTAssertEqual(show.unwatched, 2)
        XCTAssertEqual(show.bytes, 2_000, "the larger of the two counts for each")
        XCTAssertEqual(show.seasons.map(\.unwatched), [1, 1])
        XCTAssertEqual(show.seasons.map(\.bytes), [1_700, 300])
        XCTAssertEqual(show.resumePoint?.name, "S1E2", "the first not yet watched")

        show = try XCTUnwrap(DownloadGroups.series([first].map { rec in
            var seen = rec
            seen.played = true
            return seen
        }).first)
        XCTAssertEqual(show.resumePoint?.name, "S1E1", "all seen: from the top")
        XCTAssertEqual(show.unwatched, 0)
    }

    func testPostersFallBackToWhatThereIs() throws {
        let show = try XCTUnwrap(DownloadGroups.series([
            episode("S1E1", season: 1, number: 1) { $0.imageURL = "http://h/own1" },
            episode("S1E2", season: 1, number: 2) {
                $0.seasonImageURL = "http://h/season1"
                $0.seriesImageURL = "http://h/show"
            },
            episode("S2E1", season: 2, number: 1) { $0.imageURL = "http://h/own3" },
        ]).first)
        XCTAssertEqual(show.posterURL, "http://h/show", "the show's own poster, from whichever episode carries it")
        XCTAssertEqual(show.seasons[0].posterURL, "http://h/season1", "filled in from a later episode of the season")
        XCTAssertNil(show.seasons[1].posterURL, "none recorded: the view falls back to the show's")

        let bare = try XCTUnwrap(DownloadGroups.series([
            episode("S1E1", showId: "other", season: 1, number: 1),
            episode("S1E2", showId: "other", season: 1, number: 2) { $0.imageURL = "http://h/still" },
        ]).first)
        XCTAssertEqual(bare.posterURL, "http://h/still", "no show poster anywhere: an episode's still rather than nothing")
    }

    // MARK: Grouped once per change

    func testTheCurrentGroupsFollowTheManagersRecords() throws {
        XCTAssertTrue(DownloadGroups.current().series.isEmpty)
        XCTAssertTrue(DownloadGroups.current().films.isEmpty)
        let one = newId(), two = newId(), filmId = newId()
        seedEpisode(one, seriesId: "showA", series: "Show A", number: 1)
        seedEpisode(two, seriesId: "showA", series: "Show A", number: 2)
        seed(filmId, name: "Heat")
        seedEpisode(newId(), .downloading, seriesId: "showB", series: "Show B", number: 1)

        var now = DownloadGroups.current()
        XCTAssertEqual(now.series.map(\.id), ["showA"])
        XCTAssertEqual(now.series.first?.records.map(\.itemId), [one, two])
        XCTAssertEqual(now.films.map(\.itemId), [filmId])
        XCTAssertEqual(DownloadGroups.series(id: "showA")?.title, "Show A")
        XCTAssertNil(DownloadGroups.series(id: "showB"), "nothing of it has landed")

        // A song finishing is not a reason to regroup the films.
        let video = manager.videoRevision
        seed(newId(), type: "Audio", name: "Song")
        XCTAssertEqual(manager.videoRevision, video)
        XCTAssertEqual(DownloadGroups.current().films.map(\.itemId), [filmId])

        manager.setPlayed(one, played: true)
        XCTAssertEqual(DownloadGroups.series(id: "showA")?.unwatched, 1, "a change to an episode is seen at once")
        manager.delete([one, filmId])
        now = DownloadGroups.current()
        XCTAssertEqual(now.series.first?.records.map(\.itemId), [two])
        XCTAssertTrue(now.films.isEmpty)
        manager.delete(two)
        XCTAssertNil(DownloadGroups.series(id: "showA"))
    }
}
#endif
