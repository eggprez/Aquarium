//  `JellyfinClient` against canned answers, for unit tests on the iPhone,
//  iPad, Mac and Apple TV.
//
//      override func setUp() async throws { await ClientStub.install() }
//      override func tearDown() async throws { await ClientStub.remove() }
//
//  `install` routes the client's sessions through `StubURLProtocol` and signs
//  in a made-up account (server `ClientStub.server`), so requests carry a
//  token and go to a host that doesn't exist. The unit-test plan launches the
//  host app in UI test mode (`-AquariumUITest YES -AquariumTestReset YES`), so
//  this account lives in the test defaults suite and test token store, never
//  in the keychain; `install` refuses to run otherwise.

import Foundation
import XCTest
@testable import Aquarium

@MainActor
enum ClientStub {
    static let server = "http://stub.invalid"
    static let userId = "0123456789abcdef0123456789abcdef"
    static let token = "stub-token"

    static func install(file: StaticString = #filePath, line: UInt = #line) {
        guard TestRuntime.isUITest else {
            XCTFail("ClientStub needs the host app in test mode: run with TestPlans/Unit.xctestplan", file: file, line: line)
            return
        }
        StubURLProtocol.reset()
        JellyfinClient.testProtocolClasses = [StubURLProtocol.self]
        let client = JellyfinClient.shared
        client.resetConnections()
        let prefs = client.prefs
        _ = Keychain.store(token: token, server: server, userId: userId)
        prefs.session = SavedSession(server: server, userId: userId, userName: "stub", deviceId: prefs.deviceId, serverId: nil)
    }

    static func remove() {
        let client = JellyfinClient.shared
        Keychain.delete(server: server, userId: userId)
        client.prefs.session = nil
        JellyfinClient.testProtocolClasses = nil
        client.resetConnections()
        StubURLProtocol.reset()
    }
}
