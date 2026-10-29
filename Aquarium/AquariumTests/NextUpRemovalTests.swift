//  Which shows the day limit takes off Next Up, and which episodes count as
//  played for it.

import XCTest
@testable import Aquarium

final class NextUpRemovalTests: XCTestCase {
    private func episode(_ series: String, lastPlayed: String? = nil) -> BaseItem {
        var json = "{\"Id\": \"\(series)-ep\", \"Type\": \"Episode\", \"SeriesId\": \"\(series)\""
        if let lastPlayed { json += ", \"UserData\": {\"LastPlayedDate\": \"\(lastPlayed)\"}" }
        return try! JSONDecoder().decode(BaseItem.self, from: Data((json + "}").utf8))
    }

    func testARealDateCounts() {
        XCTAssertTrue(HomeRows.hasPlayedDate(episode("a", lastPlayed: "2026-10-22T18:07:01.0441200Z")))
    }

    func testTheRemovedDateDoesNot() {
        XCTAssertFalse(HomeRows.hasPlayedDate(episode("a", lastPlayed: HomeRows.notPlayedDate)))
        // As the server hands it back.
        XCTAssertFalse(HomeRows.hasPlayedDate(episode("a", lastPlayed: "0001-01-01T00:00:00.0000000Z")))
    }

    func testNoDateDoesNot() {
        XCTAssertFalse(HomeRows.hasPlayedDate(episode("a")))
    }

    func testShowsPastTheLimitAreTheOnesLeftOut() {
        let kept = [episode("a"), episode("b")]
        let everything = [episode("a"), episode("b"), episode("c"), episode("d")]
        XCTAssertEqual(HomeRows.expiredFromNextUp(everything: everything, kept: kept), ["c", "d"])
    }

    func testNothingLeftOutIsNothingToRemove() {
        let row = [episode("a"), episode("b")]
        XCTAssertEqual(HomeRows.expiredFromNextUp(everything: row, kept: row), [])
    }

    func testTwoAnswersAtTheirLengthLimitRemoveNothing() {
        // Both cut at the same length: the difference is where each stopped,
        // not the date — "z" may well be inside the limit.
        let kept = [episode("a"), episode("b")]
        let everything = [episode("a"), episode("z")]
        XCTAssertEqual(HomeRows.expiredFromNextUp(everything: everything, kept: kept), [])
    }

    func testAnEmptyCutAnswerRemovesEverything() {
        let everything = [episode("a"), episode("b")]
        XCTAssertEqual(HomeRows.expiredFromNextUp(everything: everything, kept: []), ["a", "b"])
    }
}
