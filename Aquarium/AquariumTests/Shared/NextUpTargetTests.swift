//  Which episodes "Add to Next Up" offers and dates, and where it puts a
//  show started over on the row.

import XCTest
@testable import Aquarium

final class NextUpTargetTests: XCTestCase {
    private func episode(
        _ season: Int, _ index: Int, played: Bool = false, position: Int64 = 0, lastPlayed: String? = nil
    ) -> BaseItem {
        let date = lastPlayed.map { ", \"LastPlayedDate\": \"\($0)\"" } ?? ""
        let json = """
        {"Id": "s\(season)e\(index)", "Type": "Episode", "ParentIndexNumber": \(season), "IndexNumber": \(index),
         "UserData": {"Played": \(played), "PlaybackPositionTicks": \(position)\(date)}}
        """
        return try! JSONDecoder().decode(BaseItem.self, from: Data(json.utf8))
    }

    func testNothingWatchedIsTheFirstEpisode() {
        let show = [episode(1, 1), episode(1, 2), episode(1, 3)]
        XCTAssertEqual(HomeRows.nextUpTarget(show)?.Id, "s1e1")
    }

    func testTheOneAfterTheLastWatched() {
        let show = [episode(1, 1, played: true), episode(1, 2), episode(1, 3, played: true), episode(1, 4)]
        XCTAssertEqual(HomeRows.nextUpTarget(show)?.Id, "s1e4")
    }

    func testCarriesIntoTheNextSeason() {
        let show = [episode(1, 1, played: true), episode(1, 2, played: true), episode(2, 1)]
        XCTAssertEqual(HomeRows.nextUpTarget(show)?.Id, "s2e1")
    }

    func testEverythingWatchedIsNothing() {
        let show = [episode(1, 1, played: true), episode(1, 2, played: true)]
        XCTAssertNil(HomeRows.nextUpTarget(show))
    }

    func testSpecialsAreSkipped() {
        let show = [episode(0, 1), episode(1, 1, played: true), episode(1, 2)]
        XCTAssertEqual(HomeRows.nextUpTarget(show)?.Id, "s1e2")
    }

    func testAShowOfOnlySpecialsStillHasOne() {
        let show = [episode(0, 1, played: true), episode(0, 2)]
        XCTAssertEqual(HomeRows.nextUpTarget(show)?.Id, "s0e2")
    }

    func testLastWatchedIsDatedNotTheOneOffered() {
        let show = [episode(1, 1, played: true), episode(1, 2, played: true), episode(1, 3)]
        XCTAssertEqual(HomeRows.lastWatched(show)?.Id, "s1e2")
    }

    func testNothingWatchedHasNoLastWatched() {
        XCTAssertNil(HomeRows.lastWatched([episode(1, 1), episode(1, 2)]))
    }

    func testFirstEpisodeSkipsSpecials() {
        let show = [episode(0, 1), episode(1, 1, played: true), episode(1, 2)]
        XCTAssertEqual(HomeRows.firstEpisode(show)?.Id, "s1e1")
    }

    func testStartedOverShowsGoToTheFrontNewestFirst() {
        let row = [
            episode(3, 4),
            episode(2, 2, lastPlayed: "2026-10-01T00:00:00Z"),
            episode(1, 1, lastPlayed: "2026-10-20T00:00:00Z"),
            episode(5, 5),
        ]
        XCTAssertEqual(HomeRows.newStartsFirst(row).map(\.Id), ["s1e1", "s2e2", "s3e4", "s5e5"])
    }

    func testStartedOrClearedEpisodesKeepTheirPlace() {
        let row = [
            episode(3, 4),
            episode(1, 1, position: 50_000_000, lastPlayed: "2026-10-20T00:00:00Z"),
            episode(2, 1, lastPlayed: HomeRows.notPlayedDate),
        ]
        XCTAssertEqual(HomeRows.newStartsFirst(row).map(\.Id), ["s3e4", "s1e1", "s2e1"])
    }
}
