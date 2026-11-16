//  The Live TV guide's data on the Apple TV: an XMLTV feed and an M3U
//  playlist as a custom source hands them over (Core/IPTVModels.swift), and
//  what `GuideSchedule` makes of the programmes before the grid draws them.

#if os(tvOS)
import XCTest
@testable import Aquarium

final class TVGuideTests: TVUnitTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE tv SYSTEM "xmltv.dtd">
    <tv>
      <channel id="one.example">
        <display-name>Channel One</display-name>
        <display-name>C1</display-name>
        <icon src="  " />
        <icon src="http://img.example/one.png" />
        <icon src="http://img.example/one-alt.png" />
      </channel>
      <channel id="two.example"><display-name>Channel Two</display-name></channel>
      <programme start="20271101180000 +0000" stop="20271101190000 +0000" channel="one.example">
        <title lang="en">News</title><title lang="fr">Infos</title>
        <sub-title>Evening</sub-title>
        <desc>The day's news.</desc>
      </programme>
      <programme start="20271101190000 +0100" stop="20271101200000 +0100" channel="one.example">
        <title>Drama</title>
        <episode-num system="xmltv_ns">4.11.</episode-num>
        <episode-num system="onscreen">S99E99</episode-num>
      </programme>
      <programme start="20271101193000Z" channel="two.example"><title>Open One</title></programme>
      <programme start="20271101203000 -05:00" channel="two.example"><title>Next</title>
        <episode-num system="onscreen">S2 E3</episode-num></programme>
      <programme start="20271101220000" stop="20271101210000" channel="two.example"><title>Backwards</title></programme>
      <programme start="nonsense" stop="20271101210000" channel="two.example"><title>Bad Date</title></programme>
      <programme start="20271101230000 +0000" stop="20271102000000 +0000" channel="two.example"></programme>
      <programme start="202711020000 +0000" channel="two.example"><title>Short Date</title></programme>
    </tv>
    """

    private func parsed() -> XMLTVParser { XMLTVParser.parse(Data(feed.utf8)) }

    func testChannelsTakeTheFirstNameAndTheFirstRealIcon() {
        let p = parsed()
        XCTAssertEqual(p.channelNames["one.example"], "Channel One")
        XCTAssertEqual(p.channelNames["two.example"], "Channel Two")
        XCTAssertEqual(p.channelIcons["one.example"], "http://img.example/one.png", "a blank icon is skipped")
        XCTAssertNil(p.channelIcons["two.example"])
    }

    func testProgrammesReadInEveryZoneShape() throws {
        let p = parsed()
        let news = try XCTUnwrap(p.programmes.first { $0.title == "News" })
        XCTAssertEqual(news.start, date("2027-11-01T18:00:00Z"))
        XCTAssertEqual(news.stop, date("2027-11-01T19:00:00Z"))
        XCTAssertEqual(news.subtitle, "Evening")
        XCTAssertEqual(news.desc, "The day's news.")
        XCTAssertEqual(news.channelId, "one.example")

        let drama = try XCTUnwrap(p.programmes.first { $0.title == "Drama" })
        XCTAssertEqual(drama.start, date("2027-11-01T18:00:00Z"), "+0100")
        XCTAssertEqual(drama.season, 5, "xmltv_ns is zero-based, and the first readable system wins")
        XCTAssertEqual(drama.episode, 12)

        let next = try XCTUnwrap(p.programmes.first { $0.title == "Next" })
        XCTAssertEqual(next.start, date("2027-11-02T01:30:00Z"), "-05:00 with a colon")
        XCTAssertEqual(next.season, 2)
        XCTAssertEqual(next.episode, 3)
    }

    func testTheFirstTitleWinsAcrossLanguages() {
        XCTAssertTrue(parsed().programmes.contains { $0.title == "News" })
        XCTAssertFalse(parsed().programmes.contains { $0.title == "Infos" })
    }

    func testAProgrammeWithNoStopRunsToTheNextOrHalfAnHour() throws {
        let p = parsed()
        let open = try XCTUnwrap(p.programmes.first { $0.title == "Open One" })
        XCTAssertEqual(open.start, date("2027-11-01T19:30:00Z"), "Z for UTC")
        XCTAssertEqual(open.stop, date("2027-11-02T00:00:00Z"), "until the next one on its channel")
        let last = try XCTUnwrap(p.programmes.first { $0.title == "Short Date" })
        XCTAssertEqual(last.start, date("2027-11-02T00:00:00Z"), "a time cut short to minutes")
        XCTAssertEqual(last.stop, date("2027-11-02T01:30:00Z"), "until Next, which starts later though listed earlier")
        let next = try XCTUnwrap(p.programmes.first { $0.title == "Next" })
        XCTAssertEqual(next.stop, date("2027-11-02T02:00:00Z"), "nothing follows: half an hour")
    }

    func testBrokenEntriesAreDropped() {
        let titles = parsed().programmes.map(\.title)
        XCTAssertFalse(titles.contains("Backwards"), "a stop before its start")
        XCTAssertFalse(titles.contains("Bad Date"))
        XCTAssertEqual(titles.count, 5, "the untitled programme is dropped too: \(titles)")
    }

    func testExternalEntitiesAreNeverResolved() {
        let hostile = """
        <?xml version="1.0"?>
        <!DOCTYPE tv [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <tv><channel id="a"><display-name>&xxe;</display-name></channel></tv>
        """
        let p = XMLTVParser.parse(Data(hostile.utf8))
        XCTAssertFalse((p.channelNames["a"] ?? "").contains("root:"))
    }

    // MARK: The playlist

    func testPlaylistEntries() throws {
        let text = """
        #EXTM3U x-tvg-url="http://example/guide.xml"
        #EXTINF:-1 tvg-id="one.example" tvg-name="One" tvg-logo="http://img/one.png" tvg-chno="101",Channel One HD
        #EXTGRP:News
        #EXTVLCOPT:http-user-agent=Thing
        http://stream.example/one.m3u8

        #EXTINF:-1,Bare Channel
        http://stream.example/bare.ts
        """
        let entries = M3UParser.parse(text)
        XCTAssertEqual(entries.count, 2)
        let one = try XCTUnwrap(entries.first)
        XCTAssertEqual(one.name, "Channel One HD")
        XCTAssertEqual(one.logoURL, "http://img/one.png")
        XCTAssertEqual(one.channelNumber, "101")
        XCTAssertEqual(one.streamURL, "http://stream.example/one.m3u8")
        XCTAssertEqual(entries[1].name, "Bare Channel")
        XCTAssertEqual(entries[1].streamURL, "http://stream.example/bare.ts")
    }

    // MARK: Scheduling what the feed gave

    private func items(_ programmes: [XMLTVProgramme]) -> [BaseItem] {
        programmes.sorted { $0.start < $1.start }.enumerated().map { i, p in
            var item = BaseItem()
            item.Id = "p\(i)"
            item.Name = p.title
            item.ExternalStart = p.start
            item.ExternalEnd = p.stop
            return item
        }
    }

    func testAFeedsOverlapsComeOutAsOneLineOfProgrammes() throws {
        let overlapping = """
        <tv>
          <programme start="20271101180000 +0000" stop="20271102000000 +0000" channel="c"><title>All Evening</title></programme>
          <programme start="20271101180000 +0000" stop="20271101190000 +0000" channel="c"><title>News</title></programme>
          <programme start="20271101190000 +0000" stop="20271101200000 +0000" channel="c"><title>Quiz</title></programme>
          <programme start="20271101190000 +0000" stop="20271101200000 +0000" channel="c"><title>Quiz</title></programme>
          <programme start="20271101193000 +0000" stop="20271101194500 +0000" channel="c"><title>Flash</title></programme>
        </tv>
        """
        let resolved = GuideSchedule.resolved(items(XMLTVParser.parse(Data(overlapping.utf8)).programmes))
        let titles = resolved.map(\.title)
        XCTAssertEqual(titles.filter { $0 == "Quiz" }.count, 1, "an exact duplicate is dropped")
        XCTAssertFalse(titles.contains("All Evening"), "a block starting with a programme keeps the shorter")
        for (a, b) in zip(resolved, resolved.dropFirst()) {
            XCTAssertLessThanOrEqual(try XCTUnwrap(a.programEnd), try XCTUnwrap(b.programStart),
                                     "\(a.title) runs into \(b.title): cells would draw over each other")
        }
    }
}
#endif
