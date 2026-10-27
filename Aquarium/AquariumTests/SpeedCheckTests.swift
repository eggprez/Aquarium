//  The speed check's three judgements: what counts as home, which stream a
//  measured speed carries, and which episode may reuse the last one's speed.

import XCTest
@testable import Aquarium

final class SpeedCheckTests: XCTestCase {
    // MARK: Home

    func testPrivateLoopbackAndLinkLocalAddressesAreHome() {
        for host in ["192.168.1.20", "10.0.0.5", "172.20.1.1", "127.0.0.1", "169.254.3.4",
                     "::1", "[fe80::1]", "fd12:3456::1", "nas.local", "localhost"] {
            XCTAssertTrue(SpeedCheck.isHomeAddress(host), host)
        }
    }

    func testPublicAndTailscaleAddressesAreNotHome() {
        for host in ["8.8.8.8", "172.32.0.1", "100.101.102.103", "2001:db8::1", "jellyfin.example.com"] {
            XCTAssertFalse(SpeedCheck.isHomeAddress(host), host)
        }
    }

    // MARK: What fits

    private func source(bitrate: Int?) -> MediaSource {
        var s = MediaSource(Container: "mkv")
        s.Bitrate = bitrate
        return s
    }

    func testFileThatFitsPlaysAsItIs() {
        // 10 Mbps measured, 7 to spend: a 6 Mbps file goes untouched.
        XCTAssertNil(Quality.fitting(10_000_000, source: source(bitrate: 6_000_000)))
    }

    func testFileTooBigGetsTheHighestRungThatFits() {
        // 3.2 Mbps measured, 2.24 to spend: nothing fits, so the smallest.
        XCTAssertEqual(Quality.fitting(3_200_000, source: source(bitrate: 7_700_000)), 2_500_000)
        // 8 Mbps measured, 5.6 to spend: 720p.
        XCTAssertEqual(Quality.fitting(8_000_000, source: source(bitrate: 20_000_000)), 5_000_000)
        // 30 Mbps measured, 21 to spend: 1440p.
        XCTAssertEqual(Quality.fitting(30_000_000, source: source(bitrate: 40_000_000)), 20_000_000)
    }

    func testUnknownFileOnAFastLinkPlaysAsItIs() {
        XCTAssertNil(Quality.fitting(100_000_000, source: nil))
        XCTAssertEqual(Quality.fitting(10_000_000, source: nil), 5_000_000)
    }

    // MARK: The next episode

    private func episode(_ id: String, series: String = "s", season: Int, episode: Int) -> BaseItem {
        var item = try! JSONDecoder().decode(BaseItem.self, from: Data(#"{"Id":"\#(id)"}"#.utf8))
        item.SeriesId = series
        item.ParentIndexNumber = season
        item.IndexNumber = episode
        return item
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testNextInSeasonAndFirstOfNextSeasonFollow() {
        let memory = SpeedMemory(item: episode("a", season: 1, episode: 5), bitsPerSecond: 4e6, interface: .wifi, at: start)
        XCTAssertTrue(memory.isFollowed(by: episode("b", season: 1, episode: 6), interface: .wifi, at: start))
        XCTAssertTrue(memory.isFollowed(by: episode("c", season: 2, episode: 1), interface: .wifi, at: start))
    }

    func testAnythingElseIsCheckedAfresh() {
        let memory = SpeedMemory(item: episode("a", season: 1, episode: 5), bitsPerSecond: 4e6, interface: .wifi, at: start)
        // Skipped ahead, went back, another series.
        XCTAssertFalse(memory.isFollowed(by: episode("b", season: 1, episode: 7), interface: .wifi, at: start))
        XCTAssertFalse(memory.isFollowed(by: episode("c", season: 1, episode: 4), interface: .wifi, at: start))
        XCTAssertFalse(memory.isFollowed(by: episode("d", series: "t", season: 1, episode: 6), interface: .wifi, at: start))
        // Moved to cellular, or came back much later.
        XCTAssertFalse(memory.isFollowed(by: episode("b", season: 1, episode: 6), interface: .cellular, at: start))
        XCTAssertFalse(memory.isFollowed(by: episode("b", season: 1, episode: 6), interface: .wifi,
                                         at: start.addingTimeInterval(SpeedCheck.memoryLifetime + 1)))
    }

    func testCarriedMemoryFollowsOnFromTheNewEpisode() {
        let memory = SpeedMemory(item: episode("a", season: 1, episode: 5), bitsPerSecond: 4e6, interface: .wifi, at: start)
            .carried(to: episode("b", season: 1, episode: 6))
        XCTAssertEqual(memory.itemId, "b")
        XCTAssertEqual(memory.at, start)
        XCTAssertTrue(memory.isFollowed(by: episode("c", season: 1, episode: 7), interface: .wifi, at: start))
    }
}
