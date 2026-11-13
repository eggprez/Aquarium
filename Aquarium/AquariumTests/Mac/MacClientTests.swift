//  `JellyfinClient` from a Mac, against `StubURLProtocol`: the requests the
//  Mac's own pages make (the library search field, the account avatars) and
//  the shared calls whose past bugs showed on the Mac.

#if os(macOS)
import XCTest
@testable import Aquarium

@MainActor
final class MacClientTests: MacUnitTestCase {
    override func setUp() async throws { ClientStub.install() }
    override func tearDown() async throws { ClientStub.remove() }

    private var client: JellyfinClient { .shared }
    private let emptyItems = #"{"Items":[],"TotalRecordCount":0}"#

    private func query(of request: URLRequest?) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in URLComponents(url: request?.url ?? URL(string: "x:")!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name, default: []].append(item.value ?? "")
        }
        return out
    }

    /// Regression: MacLibrarySearchOnOldUsersRoute. The Mac library page's
    /// search used `/Users/{id}/Items`, which Jellyfin 12 dropped.
    /// Source: commit 3713344; Core/JellyfinClient+LibrarySearch.swift:40.
    func testBugMacLibrarySearchOnOldUsersRoute() async throws {
        StubURLProtocol.stub("/Items", json: emptyItems)
        var q = JellyfinClient.LibraryQuery()
        q.unwatched = true
        q.favorites = true
        q.genre = "Test Pattern"
        _ = try await client.libraryItems(parentId: "lib-films", query: q, searchTerm: "  FX Long  ")
        let req = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(req.url?.path, "/Items")
        let params = query(of: req)
        XCTAssertEqual(params["userId"], [ClientStub.userId])
        XCTAssertEqual(params["ParentId"], ["lib-films"])
        XCTAssertEqual(params["searchTerm"], ["FX Long"], "trimmed")
        XCTAssertEqual(params["Recursive"], ["true"])
        XCTAssertEqual(params["Filters"], ["IsUnplayed"])
        XCTAssertEqual(params["IsFavorite"], ["true"])
        XCTAssertEqual(params["Genres"], ["Test Pattern"])
        XCTAssertNotNil(params["ExcludeItemTypes"], "no type named: the non-video types are left out")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasPrefix("/Users/") == true })
    }

    /// Regression (same commit): the account avatar used `/Users/{id}/Images/Primary`.
    func testBugAvatarOnOldUsersRoute() throws {
        let account = SavedSession(server: "http://127.0.0.1:8196", userId: "u1", userName: "suite-mac", deviceId: "d", serverId: nil)
        let url = try XCTUnwrap(JellyfinClient.avatarURL(for: account, width: 52))
        XCTAssertEqual(url.path, "/UserImage")
        XCTAssertEqual(query(of: URLRequest(url: url))["userId"], ["u1"])
        XCTAssertEqual(query(of: URLRequest(url: url))["maxWidth"], ["52"])
    }

    /// Regression: SkipCreditsNeverShows. `includeSegmentTypes=Intro,Outro`
    /// came back with Intro alone, so the Mac's Skip Credits (S, and the
    /// Playback menu) never appeared. Source: commit 5a0e2d7 (player report
    /// B3); Core/JellyfinClient.swift:1911-1917.
    func testBugSkipCreditsNeverShows() async throws {
        let id = "b7a2ad74f87ef390949afe560dcbd376"
        StubURLProtocol.stub("/MediaSegments/\(id)", json: #"""
        {"Items":[{"Type":"Intro","StartTicks":300000000,"EndTicks":600000000},
                  {"Type":"Outro","StartTicks":11000000000,"EndTicks":11700000000},
                  {"Type":"Intro","StartTicks":5,"EndTicks":5}]}
        """#)
        let segments = try await client.mediaSegments(itemId: id)
        let params = query(of: StubURLProtocol.requests.last)
        XCTAssertEqual(params["includeSegmentTypes"], ["Intro", "Outro"], "one parameter per type")
        XCTAssertEqual(segments.map(\.type), ["Intro", "Outro"], "an empty segment is dropped")
        XCTAssertEqual(segments[0].start, 30)
        XCTAssertEqual(segments[0].end, 60)
        XCTAssertTrue(segments[1].isOutro)
    }

    func testSegmentsNotAvailableIsNoSegments() async throws {
        StubURLProtocol.stub("/MediaSegments/x", status: 404)
        let segments = try await client.mediaSegments(itemId: "x")
        XCTAssertTrue(segments.isEmpty)
    }

    /// Regression: TrackChoiceIgnoredWithoutMediaSourceId. PlaybackInfo
    /// without a MediaSourceId ignores AudioStreamIndex, so a track picked in
    /// Playback ▸ Audio reopened with the old one. Source: commit ca154f3;
    /// memory note jellyfin-track-index-needs-source-id.md; player report B1.
    func testBugTrackChoiceIgnoredWithoutMediaSourceId() async throws {
        let id = "f6f6e804b2ee239f33a1131a01e91ab9"
        StubURLProtocol.stub("/Items/\(id)/PlaybackInfo", method: "POST", status: 500)
        _ = try? await client.resolvePlayback(itemId: id, audioStreamIndex: 3, subtitleStreamIndex: 10, mediaSourceId: id)
        let req = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path == "/Items/\(id)/PlaybackInfo" })
        let body = try XCTUnwrap(StubURLProtocol.jsonBody(of: req))
        XCTAssertEqual(body["MediaSourceId"] as? String, id)
        XCTAssertEqual(body["AudioStreamIndex"] as? Int, 3)
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, 10)
        XCTAssertEqual(body["UserId"] as? String, ClientStub.userId)
    }

    func testEmptyMediaSourceIdIsNotSent() async throws {
        StubURLProtocol.stub("/Items/x/PlaybackInfo", method: "POST", status: 500)
        _ = try? await client.resolvePlayback(itemId: "x", mediaSourceId: "")
        let req = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path == "/Items/x/PlaybackInfo" })
        XCTAssertNil(StubURLProtocol.jsonBody(of: req)?["MediaSourceId"] as? String)
    }

    /// Regression: ShowPlayOffersS1E1. Play on a show asked Next Up, which
    /// works forward from the last *watched* episode, and offered S1E1 over
    /// an episode left part-way. Source: commit 1ccddf1;
    /// Core/JellyfinClient.swift:1445-1475.
    func testBugShowPlayOffersS1E1() async throws {
        let series = "efed9aca103e64b168c17c55836cb5e0"
        StubURLProtocol.stub("/UserItems/Resume", json: #"""
        {"Items":[{"Id":"film-left-partway","Type":"Movie","Name":"Other"},
                  {"Id":"s01e02","Type":"Episode","Name":"Long Episode 1.2","SeriesId":"\#(series)"}],"TotalRecordCount":2}
        """#)
        StubURLProtocol.stub("/Shows/NextUp", json: #"{"Items":[{"Id":"s01e01","Type":"Episode","SeriesId":"\#(series)"}],"TotalRecordCount":1}"#)
        let next = try await client.seriesNextUp(seriesId: series)
        XCTAssertEqual(next?.Id, "s01e02", "the episode in progress, not the first unwatched")
    }

    func testShowWithNothingInProgressFallsBackToNextUp() async throws {
        StubURLProtocol.stub("/UserItems/Resume", json: emptyItems)
        StubURLProtocol.stub("/Shows/NextUp", json: #"{"Items":[{"Id":"s01e03","Type":"Episode","SeriesId":"s"}],"TotalRecordCount":1}"#)
        let next = try await client.seriesNextUp(seriesId: "s")
        XCTAssertEqual(next?.Id, "s01e03")
    }

    /// Regression guard: the Mac names itself after the computer, and macOS
    /// writes "Scott’s MacBook Pro" with a curly apostrophe; a non-ASCII
    /// header was answered 400 before the password was looked at. Every
    /// request's Authorization header is plain ASCII. Source: comment at
    /// Core/JellyfinClient.swift:355-365.
    func testAuthorizationHeaderIsASCIIOnAMac() async throws {
        StubURLProtocol.stub("/System/Info/Public", json: #"{"Id":"stub-server"}"#)
        _ = await client.checkOnline()
        let req = try XCTUnwrap(StubURLProtocol.requests.last)
        let header = try XCTUnwrap(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(header.unicodeScalars.allSatisfy(\.isASCII), header)
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains("Client=\"Aquarium\""), header)
        XCTAssertTrue(header.contains("DeviceId=\""), header)
    }

    func testFavoriteAndWatchedRequests() async throws {
        StubURLProtocol.stub("/UserFavoriteItems/abc", method: "POST", json: "{}")
        StubURLProtocol.stub("/UserFavoriteItems/abc", method: "DELETE", json: "{}")
        try await client.setFavorite("abc", favorite: true)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "POST")
        try await client.setFavorite("abc", favorite: false)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "DELETE")
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.url?.path == "/UserFavoriteItems/abc" })
    }
}
#endif
