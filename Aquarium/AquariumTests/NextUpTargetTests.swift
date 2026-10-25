//  Which episode "Add to Next Up" puts its date on.

import XCTest
@testable import Aquarium

final class NextUpTargetTests: XCTestCase {
    private func episode(_ season: Int, _ index: Int, played: Bool = false) -> BaseItem {
        let json = """
        {"Id": "s\(season)e\(index)", "Type": "Episode", "ParentIndexNumber": \(season), "IndexNumber": \(index),
         "UserData": {"Played": \(played)}}
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
}
