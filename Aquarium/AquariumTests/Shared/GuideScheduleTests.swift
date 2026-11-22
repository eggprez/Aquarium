//  Feeds that list programmes on top of one another, and what the guide
//  makes of them — see `GuideSchedule`.

import XCTest
@testable import Aquarium

final class GuideScheduleTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(_ title: String, from: Double, to: Double, id: String = UUID().uuidString) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = title
        item.ExternalStart = base.addingTimeInterval(from * 60)
        item.ExternalEnd = base.addingTimeInterval(to * 60)
        return item
    }

    private func spans(_ items: [BaseItem]) -> [(String, Double, Double)] {
        items.map {
            ($0.title, $0.programStart!.timeIntervalSince(base) / 60, $0.programEnd!.timeIntervalSince(base) / 60)
        }
    }

    func testCleanScheduleIsLeftAlone() {
        let input = [programme("A", from: 0, to: 60), programme("B", from: 60, to: 120)]
        let out = GuideSchedule.resolved(input)
        XCTAssertEqual(out.map(\.Id), input.map(\.Id))
        XCTAssertEqual(spans(out).map(\.2), [60, 120])
    }

    func testExactDuplicateIsDropped() {
        let out = GuideSchedule.resolved([
            programme("A", from: 0, to: 60), programme("A", from: 0, to: 60), programme("B", from: 60, to: 120),
        ])
        XCTAssertEqual(out.map(\.title), ["A", "B"])
    }

    func testEntryInsideAnotherCutsItShort() {
        let out = GuideSchedule.resolved([
            programme("Show", from: 0, to: 60), programme("Bulletin", from: 15, to: 45), programme("Next", from: 60, to: 120),
        ])
        XCTAssertEqual(spans(out).map { "\($0.0) \($0.1)-\($0.2)" }, ["Show 0.0-15.0", "Bulletin 15.0-45.0", "Next 60.0-120.0"])
    }

    func testStrayBlockEndsWhereTheNextProgrammeStarts() {
        let out = GuideSchedule.resolved([
            programme("Block", from: -60, to: 300), programme("A", from: 0, to: 60), programme("B", from: 60, to: 120),
        ])
        XCTAssertEqual(spans(out).map { "\($0.0) \($0.1)-\($0.2)" }, ["Block -60.0-0.0", "A 0.0-60.0", "B 60.0-120.0"])
        // The block no longer claims to be on while A is.
        XCTAssertEqual(out[0].programEnd, out[1].programStart)
    }

    func testTwoStartingTogetherKeepTheShorter() {
        let out = GuideSchedule.resolved([
            programme("Block", from: 0, to: 360), programme("A", from: 0, to: 60), programme("B", from: 60, to: 120),
        ])
        XCTAssertEqual(out.map(\.title), ["A", "B"])
        let reversed = GuideSchedule.resolved([
            programme("A", from: 0, to: 60), programme("Block", from: 0, to: 360), programme("B", from: 60, to: 120),
        ])
        XCTAssertEqual(reversed.map(\.title), ["A", "B"])
    }

    func testUndatedEntryIsKept() {
        var undated = BaseItem()
        undated.Id = "x"
        undated.Name = "No times"
        let out = GuideSchedule.resolved([programme("A", from: 0, to: 60), undated])
        XCTAssertEqual(out.map(\.title), ["A", "No times"])
    }
}
