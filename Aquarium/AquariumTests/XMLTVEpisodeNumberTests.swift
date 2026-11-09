//  The episode numbers a feed writes, in the shapes they come in — see
//  `XMLTVParser.parseEpisodeNumber` and `BaseItem.programmeEpisodeLine`.

import XCTest
@testable import Aquarium

final class XMLTVEpisodeNumberTests: XCTestCase {
    private func parse(_ text: String, _ system: String?) -> (Int?, Int)? {
        XMLTVParser.parseEpisodeNumber(text, system: system).map { ($0.season, $0.episode) }
    }

    func testXMLTVNSIsZeroBasedAndMayBePartial() {
        XCTAssertTrue(parse("4.11.", "xmltv_ns")! == (5, 12))
        XCTAssertTrue(parse(" . 3 . ", "xmltv_ns")! == (nil, 4))
        XCTAssertTrue(parse("0.0.0/2", "xmltv_ns")! == (1, 1))
        XCTAssertNil(parse("4..", "xmltv_ns"))
    }

    func testOnscreenShapes() {
        XCTAssertTrue(parse("S05E12", "onscreen")! == (5, 12))
        XCTAssertTrue(parse("S5 E12", "onscreen")! == (5, 12))
        XCTAssertTrue(parse("5x12", "onscreen")! == (5, 12))
        XCTAssertTrue(parse("Ep. 7", "onscreen")! == (nil, 7))
        XCTAssertNil(parse("EP24A1234", "dd_progid"))
    }

    func testLineUnderTheTitle() {
        var item = BaseItem()
        XCTAssertNil(item.programmeEpisodeLine)
        item.IndexNumber = 12
        XCTAssertEqual(item.programmeEpisodeLine, "Episode 12")
        item.ParentIndexNumber = 5
        XCTAssertEqual(item.programmeEpisodeLine, "S5 E12")
        item.EpisodeTitle = "Reunion"
        XCTAssertEqual(item.programmeEpisodeLine, "Reunion")
        item.EpisodeTitle = " "
        XCTAssertEqual(item.programmeEpisodeLine, "S5 E12")
    }
}
