//  The Seerr connection: how it signs in, what it keeps, where its cookie
//  goes, and what it does when the session runs out.

import XCTest
@testable import Aquarium

/// Answers for requests to the made-up Seerr host, from a closure, with
/// headers (the plain stub's answers are per path and Seerr's sign-in is all
/// about one `Set-Cookie`). Everything else is left to `StubURLProtocol`.
final class SeerrStub: URLProtocol {
    struct Answer {
        var status = 200
        var json = "{}"
        var headers: [String: String] = [:]
        var error: URLError.Code?
    }
    typealias Handler = @Sendable (URLRequest) -> Answer

    static let host = "seerr.invalid"
    static let server = "https://seerr.invalid"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }
    /// "POST /api/v1/request", in order.
    static var calls: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" } }

    static func route(_ handler: Handler?) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    /// Forget what has been seen so far, keeping the routing.
    static func forget() { lock.withLock { recorded = [] } }

    static func body(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var read = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                read.append(buffer, count: n)
            }
            data = read
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(host) == true && lock.withLock { handler != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var seen = request
        if seen.httpBody == nil, let body = Self.body(request) {
            seen.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded.append(seen)
            return Self.handler
        }
        let answer = handler?(seen) ?? Answer(status: 404)
        if let code = answer.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        var headers = answer.headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
enum SeerrFixture {
    nonisolated static let settings = #"{"initialized":true,"applicationTitle":"Seerr","mediaServerType":2,"movie4kEnabled":true,"series4kEnabled":false,"partialRequestsEnabled":true,"cacheImages":false}"#
    /// `ClientStub.userId`, where a closure off the main actor can read it.
    nonisolated static let jellyfinUserId = "0123456789abcdef0123456789abcdef"
    nonisolated static func user(jellyfinId: String = jellyfinUserId, permissions: Int = 32) -> String {
        #"{"id":7,"displayName":"stub","permissions":\#(permissions),"jellyfinUserId":"\#(jellyfinId)"}"#
    }

    /// A Jellyfin account (the plain stub's) with Seerr's host routed too.
    static func install() {
        ClientStub.install()
        JellyfinClient.testProtocolClasses = [SeerrStub.self, StubURLProtocol.self]
        JellyfinClient.shared.resetConnections()
        SeerrClient.shared.resetForTests()
        // The Jellyfin side of Quick Connect: on, and it knows the code.
        StubURLProtocol.stub("/QuickConnect/Enabled", json: "true")
        StubURLProtocol.stub("/QuickConnect/Authorize", method: "POST", json: "true")
    }

    static func remove() {
        if let session = Preferences.shared.session { SeerrClient.forget(session) }
        SeerrStub.route(nil)
        SeerrClient.shared.resetForTests()
        ClientStub.remove()
    }

    /// A Seerr that signs in by Quick Connect and hands out `cookie`; every
    /// other request goes to `rest`.
    static func route(cookie: String = "s%3Afirst", rest: @escaping SeerrStub.Handler = { _ in SeerrStub.Answer(status: 404) }) {
        SeerrStub.route { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/api/v1/settings/public"):
                return SeerrStub.Answer(json: settings)
            case ("POST", "/api/v1/auth/jellyfin/quickconnect/initiate"):
                return SeerrStub.Answer(json: #"{"code":"123456","secret":"ABCDEF0123456789"}"#)
            case ("POST", "/api/v1/auth/jellyfin/quickconnect/authenticate"):
                return SeerrStub.Answer(json: user(), headers: ["Set-Cookie": "connect.sid=\(cookie); Path=/; HttpOnly"])
            default:
                return rest(request)
            }
        }
    }

    /// Connected, with the sign-in's own requests forgotten.
    static func connect(rest: @escaping SeerrStub.Handler) async throws {
        route(rest: rest)
        try await SeerrClient.shared.connectWithQuickConnect(to: SeerrStub.server)
        SeerrStub.forget()
    }
}

@MainActor
final class SeerrClientTests: XCTestCase {
    override func setUp() async throws { SeerrFixture.install() }
    override func tearDown() async throws { SeerrFixture.remove() }

    private var seerr: SeerrClient { .shared }

    // MARK: - Finding the server

    func testProbeTriesHTTPSFirstAndMarksAFallback() async throws {
        SeerrStub.route { request in
            request.url?.scheme == "https"
                ? SeerrStub.Answer(error: .cannotConnectToHost)
                : SeerrStub.Answer(json: SeerrFixture.settings)
        }
        let probe = try await seerr.probe(address: "seerr.invalid/")
        XCTAssertEqual(probe.server, "http://seerr.invalid")
        XCTAssertFalse(probe.secure)
        XCTAssertTrue(probe.fellBackToHTTP)
        XCTAssertEqual(SeerrStub.requests.map { $0.url?.scheme }, ["https", "http"])
    }

    func testProbeNeverDropsToHTTPAfterABadCertificate() async {
        SeerrStub.route { request in
            request.url?.scheme == "https"
                ? SeerrStub.Answer(error: .serverCertificateUntrusted)
                : SeerrStub.Answer(json: SeerrFixture.settings)
        }
        do {
            _ = try await seerr.probe(address: "seerr.invalid")
            XCTFail("a failed certificate must stop the search")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("certificate"))
        }
        XCTAssertEqual(SeerrStub.requests.map { $0.url?.scheme }, ["https"], "plain http was never tried")
    }

    func testProbeTurnsDownWhatIsNotAJellyfinSeerr() async {
        SeerrStub.route { _ in SeerrStub.Answer(json: #"{"hello":"world"}"#) }
        await assertProbeFails(containing: "not as a Seerr server")
        SeerrStub.route { _ in SeerrStub.Answer(json: #"{"initialized":true,"mediaServerType":1}"#) }
        await assertProbeFails(containing: "Plex")
        SeerrStub.route { _ in SeerrStub.Answer(json: #"{"initialized":false,"mediaServerType":4}"#) }
        await assertProbeFails(containing: "setup")
    }

    private func assertProbeFails(containing text: String, line: UInt = #line) async {
        do {
            _ = try await seerr.probe(address: "https://seerr.invalid")
            XCTFail("expected a refusal", line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, line: line)
        }
    }

    // MARK: - Signing in

    func testQuickConnectSignsInWithoutAPassword() async throws {
        SeerrFixture.route()
        let connection = try await seerr.connectWithQuickConnect(to: SeerrStub.server)

        XCTAssertEqual(SeerrStub.calls, [
            "POST /api/v1/auth/jellyfin/quickconnect/initiate",
            "POST /api/v1/auth/jellyfin/quickconnect/authenticate",
        ])
        // The code Seerr got from Jellyfin was approved with this device's
        // own Jellyfin session.
        let approval = StubURLProtocol.requests.first { $0.url?.path == "/QuickConnect/Authorize" }
        XCTAssertEqual(approval?.url?.query, "code=123456")
        XCTAssertTrue(approval?.value(forHTTPHeaderField: "Authorization")?.contains(ClientStub.token) == true)
        XCTAssertEqual(SeerrStub.body(SeerrStub.requests[1])?["secret"] as? String, "ABCDEF0123456789")

        XCTAssertEqual(connection.cookie, "s%3Afirst")
        XCTAssertEqual(connection.userId, 7)
        XCTAssertTrue(seerr.isConnected)
        // Nothing about Jellyfin went to Seerr, and no password anywhere.
        for request in SeerrStub.requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains(ClientStub.token) == true)
        }
    }

    func testTheSessionIsKeptInTheKeychainSlotAndNowhereElse() async throws {
        SeerrFixture.route()
        try await seerr.connectWithQuickConnect(to: SeerrStub.server)
        let stored = Keychain.token(server: "seerr|" + ClientStub.server, userId: ClientStub.userId)
        XCTAssertTrue(stored?.contains("s%3Afirst") == true)
        XCTAssertTrue(stored?.contains(SeerrStub.server.replacingOccurrences(of: "/", with: "\\/")) == true
            || stored?.contains(SeerrStub.server) == true)
        // Not in the defaults: only the keychain (the test store, in a test).
        let defaults = UserDefaults.standard.dictionaryRepresentation()
            .filter { !$0.key.hasPrefix("uitest_") }
        XCTAssertFalse(defaults.values.contains { "\($0)".contains("s%3Afirst") })
        // And it comes back after everything in memory is dropped.
        seerr.resetForTests()
        XCTAssertEqual(seerr.connection?.cookie, "s%3Afirst")
    }

    func testAnotherJellyfinUsersSessionIsRefused() async {
        SeerrStub.route { request in
            switch request.url?.path ?? "" {
            case "/api/v1/auth/jellyfin/quickconnect/initiate":
                return SeerrStub.Answer(json: #"{"code":"123456","secret":"ABCDEF0123456789"}"#)
            case "/api/v1/auth/jellyfin/quickconnect/authenticate":
                return SeerrStub.Answer(json: SeerrFixture.user(jellyfinId: "ffffffffffffffffffffffffffffffff"),
                                        headers: ["Set-Cookie": "connect.sid=s%3Asomeone; Path=/"])
            default: return SeerrStub.Answer()
            }
        }
        do {
            try await seerr.connectWithQuickConnect(to: SeerrStub.server)
            XCTFail("a session for a different Jellyfin user must not be kept")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("different Jellyfin user"))
        }
        XCTAssertNil(seerr.connection)
    }

    func testACodeJellyfinDoesNotKnowMeansADifferentJellyfinServer() async {
        StubURLProtocol.stub("/QuickConnect/Authorize", method: "POST", status: 404)
        SeerrFixture.route()
        do {
            try await seerr.connectWithQuickConnect(to: SeerrStub.server)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("different Jellyfin server"))
        }
        XCTAssertFalse(SeerrStub.calls.contains { $0.hasSuffix("/authenticate") }, "nothing was finished")
        XCTAssertNil(seerr.connection)
    }

    func testAnOlderSeerrFallsBackToThePassword() async throws {
        SeerrStub.route { request in
            switch request.url?.path ?? "" {
            case "/api/v1/auth/jellyfin/quickconnect/initiate":
                return SeerrStub.Answer(status: 404)
            case "/api/v1/auth/jellyfin":
                return SeerrStub.Answer(json: SeerrFixture.user(), headers: ["Set-Cookie": "connect.sid=s%3Apw; Path=/"])
            default: return SeerrStub.Answer()
            }
        }
        do {
            try await seerr.connectWithQuickConnect(to: SeerrStub.server)
            XCTFail("expected quickConnectUnavailable")
        } catch {
            XCTAssertEqual(error as? SeerrError, .quickConnectUnavailable)
        }
        try await seerr.connectWithPassword(to: SeerrStub.server, username: "stub", password: "hunter2")
        let sent = SeerrStub.body(SeerrStub.requests.last!)
        XCTAssertEqual(sent?["username"] as? String, "stub")
        XCTAssertEqual(sent?["password"] as? String, "hunter2")
        XCTAssertEqual(seerr.connection?.cookie, "s%3Apw")
        // The password was sent and not kept.
        let stored = Keychain.token(server: "seerr|" + ClientStub.server, userId: ClientStub.userId) ?? ""
        XCTAssertFalse(stored.contains("hunter2"))
    }

    func testAWrongPasswordSaysSo() async {
        SeerrStub.route { _ in SeerrStub.Answer(status: 401, json: #"{"message":"INVALID_CREDENTIALS"}"#) }
        do {
            try await seerr.connectWithPassword(to: SeerrStub.server, username: "stub", password: "nope")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That user name or password isn't right.")
        }
    }

    // MARK: - Where the cookie goes

    func testTheCookieGoesOnRequestsToSeerrOnly() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer(json: #"{"page":1,"results":[]}"#) }
        _ = try await seerr.search("the matrix: reloaded?")
        let sent = SeerrStub.requests.last!
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Cookie"), "connect.sid=s%3Afirst")
        XCTAssertEqual(sent.url?.query, "query=the%20matrix%3A%20reloaded%3F&page=1", "escaped down to unreserved characters")
        // Jellyfin never sees it.
        _ = await JellyfinClient.shared.checkOnline()
        for request in StubURLProtocol.requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        // A picture comes from the Seerr server too, never from TMDB.
        XCTAssertEqual(seerr.imageURL("/abc.jpg", size: .poster)?.absoluteString,
                       "https://seerr.invalid/imageproxy/tmdb/t/p/w342/abc.jpg")
    }

    func testRefreshingBringsPermissionsUpToDate() async throws {
        try await SeerrFixture.connect { request in
            switch request.url?.path ?? "" {
            case "/api/v1/settings/public": return SeerrStub.Answer(json: SeerrFixture.settings)
            case "/api/v1/auth/me": return SeerrStub.Answer(json: SeerrFixture.user(permissions: 2))
            default: return SeerrStub.Answer(status: 404)
            }
        }
        XCTAssertFalse(seerr.connection?.rights.contains(.admin) == true)
        await seerr.refreshAccount()
        XCTAssertTrue(seerr.connection?.rights.contains(.admin) == true)
        XCTAssertEqual(seerr.connection?.settings?.movie4kEnabled, true)
        XCTAssertEqual(seerr.connection?.cookie, "s%3Afirst", "the session is untouched")
    }

    func testNoPicturesWithoutAConnection() {
        XCTAssertNil(seerr.imageURL("/abc.jpg", size: .poster))
    }

    func testCSRFTokenIsEchoedOnWrites() async throws {
        try await SeerrFixture.connect { request in
            if request.httpMethod == "GET" {
                return SeerrStub.Answer(json: #"{"movie":{},"tv":{}}"#,
                                        headers: ["Set-Cookie": "XSRF-TOKEN=tok123; Path=/, _csrf=sec456; Path=/; HttpOnly"])
            }
            return SeerrStub.Answer(status: 201, json: #"{"id":1,"status":1,"type":"movie"}"#)
        }
        _ = try await seerr.quota()
        _ = try await seerr.request(.movie, tmdbId: 603)
        let write = SeerrStub.requests.last!
        XCTAssertEqual(write.value(forHTTPHeaderField: "X-XSRF-TOKEN"), "tok123")
        let cookie = write.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookie.contains("connect.sid=s%3Afirst"))
        XCTAssertTrue(cookie.contains("_csrf=sec456"))
        XCTAssertTrue(cookie.contains("XSRF-TOKEN=tok123"))
    }

    // MARK: - A session that ran out

    func testARefusalWithADeadSessionRenewsOnceAndRetries() async throws {
        let renewed = Flag()
        try await SeerrFixture.connect { _ in SeerrStub.Answer(status: 404) }
        SeerrFixture.route(cookie: "s%3Asecond") { request in
            let fresh = request.value(forHTTPHeaderField: "Cookie")?.contains("s%3Asecond") == true
            if fresh { renewed.set() }
            switch request.url?.path ?? "" {
            case "/api/v1/auth/me": return SeerrStub.Answer(status: fresh ? 200 : 403, json: SeerrFixture.user())
            case "/api/v1/search": return fresh ? SeerrStub.Answer(json: #"{"results":[{"id":603,"mediaType":"movie","title":"The Matrix"}]}"#)
                                               : SeerrStub.Answer(status: 403, json: #"{"message":"You do not have permission to access this endpoint"}"#)
            default: return SeerrStub.Answer(status: 404)
            }
        }
        let page = try await seerr.search("matrix")
        XCTAssertEqual(page.results?.first?.displayTitle, "The Matrix")
        XCTAssertTrue(renewed.isSet)
        XCTAssertEqual(seerr.connection?.cookie, "s%3Asecond", "the new session replaced the old in the keychain")
        XCTAssertEqual(SeerrStub.calls, [
            "GET /api/v1/search",
            "GET /api/v1/auth/me",
            "POST /api/v1/auth/jellyfin/quickconnect/initiate",
            "POST /api/v1/auth/jellyfin/quickconnect/authenticate",
            "GET /api/v1/search",
        ])
        XCTAssertFalse(seerr.needsReconnect)
    }

    func testARealRefusalIsNotMistakenForADeadSession() async throws {
        try await SeerrFixture.connect { request in
            switch request.url?.path ?? "" {
            case "/api/v1/auth/me": return SeerrStub.Answer(json: SeerrFixture.user())
            default: return SeerrStub.Answer(status: 403, json: #"{"message":"Movie Quota exceeded."}"#)
            }
        }
        do {
            _ = try await seerr.request(.movie, tmdbId: 603)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("used all your requests"))
        }
        XCTAssertFalse(SeerrStub.calls.contains { $0.contains("quickconnect") }, "no sign-in was attempted")
        XCTAssertEqual(seerr.connection?.cookie, "s%3Afirst")
    }

    func testWhenRenewalFailsSettingsIsToldToReconnect() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer(status: 404) }
        SeerrStub.route { _ in SeerrStub.Answer(status: 403) }
        do {
            _ = try await seerr.search("matrix")
            XCTFail("expected needsReconnect")
        } catch {
            XCTAssertEqual(error as? SeerrError, .needsReconnect)
        }
        XCTAssertTrue(seerr.needsReconnect)
        XCTAssertFalse(seerr.isConnected)
        XCTAssertNotNil(seerr.connection, "the address is kept, so reconnecting is one press")
    }

    // MARK: - Requests

    func testRequestBodies() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer(status: 201, json: #"{"id":4,"status":2,"type":"tv"}"#) }
        let before = seerr.requestsChanged
        _ = try await seerr.request(.movie, tmdbId: 603, seasons: [1], is4K: true)
        var body = SeerrStub.body(SeerrStub.requests.last!)
        XCTAssertEqual(body?["mediaType"] as? String, "movie")
        XCTAssertEqual(body?["mediaId"] as? Int, 603)
        XCTAssertEqual(body?["is4k"] as? Bool, true)
        XCTAssertNil(body?["seasons"], "a film has no seasons to ask for")

        let made = try await seerr.request(.tv, tmdbId: 1396, seasons: [2, 3])
        body = SeerrStub.body(SeerrStub.requests.last!)
        XCTAssertEqual(body?["seasons"] as? [Int], [2, 3])
        XCTAssertEqual(made.requestStatus, .approved)
        XCTAssertEqual(seerr.requestsChanged, before + 2, "lists that show requests are told")
    }

    func testMyRequestsAsksForThisAccountsOnly() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer(json: #"{"pageInfo":{"results":0},"results":[]}"#) }
        _ = try await seerr.myRequests()
        XCTAssertEqual(SeerrStub.requests.last?.url?.query, "take=40&skip=0&sort=added&requestedBy=7")
    }

    func testCancelDeletesTheRequest() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer(status: 204, json: "") }
        try await seerr.cancel(SeerrRequest(id: 12))
        XCTAssertEqual(SeerrStub.calls.last, "DELETE /api/v1/request/12")
    }

    func testBrowseRowsOfOneKindAreGivenTheirKind() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer(json: #"{"results":[{"id":603,"title":"The Matrix"}]}"#) }
        let films = try await seerr.browse(.popularMovies)
        XCTAssertEqual(films.results?.first?.kind, .movie)
        XCTAssertEqual(SeerrStub.requests.last?.url?.path, "/api/v1/discover/movies")
        let shows = try await seerr.browse(.upcomingTV)
        XCTAssertEqual(shows.results?.first?.kind, .tv)
        XCTAssertEqual(SeerrStub.requests.last?.url?.path, "/api/v1/discover/tv/upcoming")
    }

    // MARK: - Leaving

    func testDisconnectTellsSeerrAndForgets() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer(json: #"{"status":"ok"}"#) }
        await seerr.disconnect()
        XCTAssertEqual(SeerrStub.calls.last, "POST /api/v1/auth/logout")
        XCTAssertNil(seerr.connection)
        XCTAssertNil(Keychain.token(server: "seerr|" + ClientStub.server, userId: ClientStub.userId))
    }

    func testSigningOutOfJellyfinTakesTheSeerrSessionWithIt() async throws {
        try await SeerrFixture.connect { _ in SeerrStub.Answer() }
        StubURLProtocol.stub("/Sessions/Logout", method: "POST", status: 204)
        await JellyfinClient.shared.logout()
        XCTAssertNil(Keychain.token(server: "seerr|" + ClientStub.server, userId: ClientStub.userId))
        XCTAssertNil(seerr.connection)
    }

    // MARK: - The shell

    func testRequestsSectionExistsOnlyWhileConnected() async throws {
        XCTAssertFalse(AppModel.shared.sections.contains(.requests))
        try await SeerrFixture.connect { _ in SeerrStub.Answer() }
        XCTAssertTrue(AppModel.shared.sections.contains(.requests))
        await seerr.disconnect()
        XCTAssertFalse(AppModel.shared.sections.contains(.requests))
    }
}

/// A switch a `@Sendable` closure can throw.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
