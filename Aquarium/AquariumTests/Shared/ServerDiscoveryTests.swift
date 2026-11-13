//  What a LAN discovery reply may offer, and whose progress goes where.

import XCTest
@testable import Aquarium

final class ServerDiscoveryTests: XCTestCase {
    private let server = inet_addr("192.168.1.10")

    func testAnIPAddressMustBeTheSender() {
        XCTAssertTrue(ServerDiscovery.accepts(address: "http://192.168.1.10:8096", from: server))
        XCTAssertTrue(ServerDiscovery.accepts(address: "https://192.168.1.10:8920/jellyfin", from: server))
        XCTAssertFalse(ServerDiscovery.accepts(address: "http://192.168.1.66:8096", from: server))
        XCTAssertFalse(ServerDiscovery.accepts(address: "https://203.0.113.9", from: server))
    }

    func testAHostnameCannotBeCheckedSoItIsOffered() {
        XCTAssertTrue(ServerDiscovery.accepts(address: "https://jellyfin.example.com", from: server))
    }

    func testOnlyWebAddressesWithAHost() {
        XCTAssertFalse(ServerDiscovery.accepts(address: "ftp://192.168.1.10", from: server))
        XCTAssertFalse(ServerDiscovery.accepts(address: "file:///etc/passwd", from: server))
        XCTAssertFalse(ServerDiscovery.accepts(address: "192.168.1.10:8096", from: server))
        XCTAssertFalse(ServerDiscovery.accepts(address: "http://", from: server))
    }

    func testWatchEventsGoOnlyToTheirOwnAccount() {
        var event = WatchProgressEvent(itemId: "a", positionTicks: 0, played: false, isAudiobook: true)
        XCTAssertTrue(event.belongs(to: "server|parent"), "an event from before accounts were recorded")
        event.accountKey = "server|parent"
        XCTAssertTrue(event.belongs(to: "server|parent"))
        XCTAssertFalse(event.belongs(to: "server|child"))
        XCTAssertFalse(event.belongs(to: nil))
    }

    func testAWatchEventFromAnOlderBuildStillDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","itemId":"a","positionTicks":5,"played":false,"isAudiobook":false,"streamed":false,"at":0}"#
        let event = try JSONDecoder().decode(WatchProgressEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.accountKey)
    }
}
