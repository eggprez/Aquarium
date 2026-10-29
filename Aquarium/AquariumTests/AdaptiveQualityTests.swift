//  Adaptive quality's reading of which rungs leave a file untouched, and the
//  power cap that acts on it at once.

import XCTest
@testable import Aquarium

@MainActor
final class AdaptiveQualityTests: XCTestCase {
    private func source(bitrate: Int?, width: Int?, height: Int?) -> MediaSource {
        var s = MediaSource(Container: "mkv", MediaStreams: [
            MediaStream(Index: 0, type: "Video", Codec: "h264"),
        ])
        s.Bitrate = bitrate
        s.MediaStreams?[0].Width = width
        s.MediaStreams?[0].Height = height
        return s
    }

    private func index(of bitrate: Int?) -> Int { Quality.rungIndex(bitrate) }

    // MARK: Quality.untouchedRung

    func testModest1080pFileIsUntouchedDownToTheSmaller1080pRung() {
        let s = source(bitrate: 6_000_000, width: 1920, height: 1080)
        XCTAssertEqual(Quality.untouchedRung(for: s), index(of: 10_000_000))
    }

    func testHeavy4KFileIsUntouchedOnlyAtThe4KRung() {
        let s = source(bitrate: 30_000_000, width: 3840, height: 2160)
        XCTAssertEqual(Quality.untouchedRung(for: s), index(of: 36_000_000))
    }

    func testFileOverEveryRungIsUntouchedOnlyAsDirectPlay() {
        let s = source(bitrate: 80_000_000, width: 3840, height: 2160)
        XCTAssertEqual(Quality.untouchedRung(for: s), 0)
    }

    func testSmallFileIsUntouchedOnEveryRung() {
        let s = source(bitrate: 1_500_000, width: 720, height: 480)
        XCTAssertEqual(Quality.untouchedRung(for: s), Quality.choices.count - 1)
    }

    func testFileThatSaysTooLittleSkipsNothing() {
        XCTAssertEqual(Quality.untouchedRung(for: nil), 0)
        XCTAssertEqual(Quality.untouchedRung(for: source(bitrate: nil, width: 1920, height: 1080)), 0)
        XCTAssertEqual(Quality.untouchedRung(for: source(bitrate: 6_000_000, width: nil, height: nil)), 0)
    }

    // MARK: The power cap

    func testLowPowerLeavesAnOriginalAlreadyUnderTheCapAlone() {
        let adaptive = AdaptiveQuality()
        adaptive.begin(inherited: false, ceiling: nil, powerCap: nil, untouched: index(of: 10_000_000))
        XCTAssertFalse(adaptive.notePower(thermal: .nominal, lowPower: true, currentBitrate: nil))
    }

    func testLowPowerStepsAnOriginalOverTheCapStraightToIt() {
        let adaptive = AdaptiveQuality()
        adaptive.begin(inherited: false, ceiling: nil, powerCap: nil, untouched: 0)
        XCTAssertTrue(adaptive.notePower(thermal: .nominal, lowPower: true, currentBitrate: nil))
        let decision = adaptive.decide(currentBitrate: nil)
        XCTAssertEqual(decision?.bitrate, 10_000_000)
        XCTAssertEqual(decision?.isDrop, true)
    }
}
