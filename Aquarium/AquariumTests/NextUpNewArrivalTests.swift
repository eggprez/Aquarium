//  Shows you are up to date on coming back to Next Up when a new episode
//  arrives.

import XCTest
@testable import Aquarium

final class NextUpNewArrivalTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
    private let day: TimeInterval = 24 * 60 * 60

    private func stamp(_ daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * day))
    }

    private func episode(_ series: String, added: Double? = nil, aired: Double? = nil) -> BaseItem {
        var fields = ["\"Id\": \"\(series)-ep\"", "\"Type\": \"Episode\"", "\"SeriesId\": \"\(series)\""]
        if let added { fields.append("\"DateCreated\": \"\(stamp(added))\"") }
        if let aired { fields.append("\"PremiereDate\": \"\(stamp(aired))\"") }
        return try! JSONDecoder().decode(BaseItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    func testAnEpisodeAddedThisWeekIsNew() {
        XCTAssertTrue(HomeRows.isNewArrival(episode("a", added: 3, aired: 4), window: 30 * day, now: now))
    }

    func testAnEpisodeAddedLongAgoIsNot() {
        XCTAssertFalse(HomeRows.isNewArrival(episode("a", added: 60, aired: 61), window: 30 * day, now: now))
    }

    func testAnOldEpisodeAddedTodayIsNot() {
        // A library imported again: everything was added today, and aired years ago.
        XCTAssertFalse(HomeRows.isNewArrival(episode("a", added: 0, aired: 900), window: 30 * day, now: now))
    }

    func testNoAirDateGoesByWhenItWasAdded() {
        XCTAssertTrue(HomeRows.isNewArrival(episode("a", added: 2), window: 30 * day, now: now))
    }

    func testNoAddedDateIsNotNew() {
        XCTAssertFalse(HomeRows.isNewArrival(episode("a", aired: 1), window: 30 * day, now: now))
    }

    func testTheWindowFollowsTheKeepSetting() {
        XCTAssertEqual(HomeRows.nextUpNewWindow(days: 7), 7 * day)
        XCTAssertEqual(HomeRows.nextUpNewWindow(days: 0), HomeRows.newEpisodeWindow)
        XCTAssertFalse(HomeRows.isNewArrival(episode("a", added: 10, aired: 10),
                                             window: HomeRows.nextUpNewWindow(days: 7), now: now))
    }

    func testACaughtUpShowWithANewEpisodeComesBackFirst() {
        // The server's row, cut off at a month, no longer has "old"; the
        // wider answer does, with an episode added yesterday.
        let row = [episode("recent", added: 200, aired: 200)]
        let everything = row + [episode("old", added: 1, aired: 1)]
        let merged = HomeRows.mergedNextUp(row: row, everything: everything, window: 30 * day, limit: 16, now: now)
        XCTAssertEqual(merged.map(\.SeriesId), ["old", "recent"])
    }

    func testOneCardPerShowAndTheLimitHolds() {
        let row = (0..<16).map { episode("s\($0)", added: 300) }
        let everything = row + [episode("new", added: 1)]
        let merged = HomeRows.mergedNextUp(row: row, everything: everything, window: 30 * day, limit: 16, now: now)
        XCTAssertEqual(merged.count, 16)
        XCTAssertEqual(merged.first?.SeriesId, "new")
        XCTAssertEqual(Set(merged.compactMap(\.SeriesId)).count, 16)
    }

    func testNothingNewLeavesTheServersOrder() {
        let row = [episode("b", added: 100), episode("a", added: 200)]
        let merged = HomeRows.mergedNextUp(row: row, everything: row, window: 30 * day, limit: 16, now: now)
        XCTAssertEqual(merged.map(\.SeriesId), ["b", "a"])
    }
}
