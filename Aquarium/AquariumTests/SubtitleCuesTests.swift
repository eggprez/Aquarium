import XCTest
@testable import Aquarium

final class SubtitleCuesTests: XCTestCase {
    func testSubRip() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i>\r\nthere\r\n\r\n2\r\n00:01:00,000 --> 00:01:02,000\r\n{\\an8}Up top\r\n"
        let cues = SubtitleCues.parse(srt, isASS: false)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], SubtitleCue(start: 1, end: 3.5, text: "Hello\nthere"))
        XCTAssertEqual(cues[1].text, "Up top")
        XCTAssertEqual(cues[1].start, 60)
    }

    func testWebVTT() {
        let vtt = "WEBVTT\n\n00:02.000 --> 00:04.000 line:90% align:center\nShort stamps\n"
        let cues = SubtitleCues.parse(vtt, isASS: false)
        XCTAssertEqual(cues, [SubtitleCue(start: 2, end: 4, text: "Short stamps")])
    }

    func testASS() {
        let ass = """
        [Script Info]
        Title: x
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,{\\i1}Well, yes{\\i0}\\Nand no
        Dialogue: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
        Comment: 0,0:00:10.00,0:00:11.00,Default,,0,0,0,,not shown
        """
        let cues = SubtitleCues.parse(ass, isASS: true)
        XCTAssertEqual(cues, [SubtitleCue(start: 5, end: 7.5, text: "Well, yes\nand no")])
    }

    func testWhatIsOnScreen() {
        let cues = [
            SubtitleCue(start: 1, end: 10, text: "long"),
            SubtitleCue(start: 2, end: 3, text: "short"),
            SubtitleCue(start: 20, end: 21, text: "later"),
        ]
        XCTAssertNil(SubtitleCues.text(in: cues, at: 0.5))
        XCTAssertEqual(SubtitleCues.text(in: cues, at: 2.5), "long\nshort")
        XCTAssertEqual(SubtitleCues.text(in: cues, at: 5), "long")
        XCTAssertNil(SubtitleCues.text(in: cues, at: 15))
        XCTAssertEqual(SubtitleCues.text(in: cues, at: 20), "later")
        XCTAssertNil(SubtitleCues.text(in: cues, at: 21))
    }
}
