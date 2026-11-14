//  The Info panel's line of facts on the television (`InfoTab.facts`).

#if os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class TVPanelFactsTests: TVUnitTestCase {
    private func item(_ json: String) -> BaseItem {
        try! JSONDecoder().decode(BaseItem.self, from: Data(json.utf8))
    }

    /// A 20-second clip read "0m" in Info: it reads in seconds, as the rest
    /// of the app does (`Format.ticks`).
    func testShortRuntimeReadsSeconds() {
        let clip = item(#"{"Id":"c","Type":"Movie","RunTimeTicks":200000000}"#)
        XCTAssertEqual(InfoTab.facts(clip), "20s")
    }

    func testLongRuntimeReadsHoursAndMinutes() {
        let film = item(#"{"Id":"f","Type":"Movie","RunTimeTicks":80400000000,"ProductionYear":2001}"#)
        XCTAssertEqual(InfoTab.facts(film), "2001  ·  2h 14m")
    }
}
#endif
