//  Watch unit tests (owner: the Watch agent). Hosted by the watch app, so
//  `@testable import AquariumWatch` reaches Watch/*.swift and the Shared/
//  types compiled into it. `StubURLProtocol` (AquariumTests/Shared/Support)
//  is compiled in here too. TestPlans/WatchUnit.xctestplan launches the host
//  in UI test mode, so the account below never reaches the keychain.

import XCTest
@testable import AquariumWatch

@MainActor
final class WatchClientStubTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(TestRuntime.isUITest, "run with TestPlans/WatchUnit.xctestplan")
        StubURLProtocol.reset()
        JellyfinClient.shared.useTestProtocols([StubURLProtocol.self])
        JellyfinClient.shared.install(WatchCredentials(
            server: "http://stub.invalid", userId: "0123456789abcdef0123456789abcdef",
            userName: "stub", serverId: nil, token: "stub-token"
        ))
    }

    override func tearDown() async throws {
        JellyfinClient.shared.signOut()
        JellyfinClient.shared.useTestProtocols(nil)
        StubURLProtocol.reset()
    }

    func testOnlineCheckAsksTheServer() async {
        StubURLProtocol.stub("/System/Info/Public", json: #"{"Id":"stub-server"}"#)
        let online = await JellyfinClient.shared.checkOnline()
        XCTAssertTrue(online)
        let auth = StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.contains("Token=\"stub-token\""), auth)
    }

    func testSharedTypesAreReachable() {
        // A Shared/ type, compiled into the watch app.
        let creds = WatchCredentials(server: "s", userId: "u", userName: "n", serverId: nil, token: "t")
        XCTAssertEqual(creds.userName, "n")
    }
}
