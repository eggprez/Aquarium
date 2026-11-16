//  The stub itself, and an example of testing the client with it.

import XCTest
@testable import Aquarium

@MainActor
final class ClientStubTests: XCTestCase {
    override func setUp() async throws { ClientStub.install() }
    override func tearDown() async throws { ClientStub.remove() }

    func testOnlineCheckReadsPublicInfo() async {
        StubURLProtocol.stub("/System/Info/Public", json: #"{"Id":"stub-server","ServerName":"Stub","Version":"10.11.0"}"#)
        let online = await JellyfinClient.shared.checkOnline()
        XCTAssertTrue(online)
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.host, "stub.invalid")
        XCTAssertEqual(JellyfinClient.shared.session?.serverId, "stub-server", "first contact records the server's id")
    }

    func testUnreachableServerIsOffline() async {
        StubURLProtocol.stub("/System/Info/Public", StubURLProtocol.Response(error: .cannotConnectToHost))
        let online = await JellyfinClient.shared.checkOnline()
        XCTAssertFalse(online)
    }
}
