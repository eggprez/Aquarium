//  `StreamResolver`: where an IPTV channel's address really leads, found by
//  reading redirects with HEAD and never asking for the playlist itself.
//  The far end is a web server on this machine's loopback address.

import XCTest
@testable import Aquarium

final class StreamResolverTests: XCTestCase {
    private var server: LoopbackServer!

    override func setUpWithError() throws { server = try LoopbackServer() }
    override func tearDown() { server.stop() }

    func testAnAddressThatAlreadySaysWhatItIsIsNeverAsked() async {
        for name in ["live.m3u8", "LIVE.M3U8", "list.m3u", "raw.ts", "film.mp4", "part.m4s", "film.mkv", "clip.webm", "dash.mpd"] {
            let url = server.url("/streams/\(name)?token=abc")
            let resolved = await StreamResolver.resolve(url)
            XCTAssertEqual(resolved.url, url, name)
            XCTAssertNil(resolved.contentType, name)
        }
        XCTAssertTrue(server.requests.isEmpty, "asking for a playlist starts a session on a channel server; it is left for the player")
    }

    func testARedirectToAPlaylistIsFollowedAndThePlaylistLeftAlone() async {
        server.setHandler { request in
            request.path == "/stream/42" ? .redirect(to: "/stream/42.m3u8?session=s1") : .text("#EXTM3U", type: "application/vnd.apple.mpegurl")
        }
        let resolved = await StreamResolver.resolve(server.url("/stream/42?mode=hls"))
        XCTAssertEqual(resolved.url, server.url("/stream/42.m3u8?session=s1"),
                       "AVFoundation is handed the address it would have arrived at, extension and all")
        XCTAssertNil(resolved.contentType)
        XCTAssertEqual(server.requests.map(\.target), ["/stream/42?mode=hls"], "one hop asked; the playlist itself never")
        XCTAssertEqual(server.requests.first?.method, "HEAD")
        XCTAssertEqual(server.requests.first?.headers["accept"], "*/*")
    }

    func testARelativeLocationIsResolvedAgainstTheAddressItCameFrom() async {
        server.setHandler { request in
            request.path == "/tv/channel" ? .redirect(to: "variants/hd.m3u8", status: 307) : .status(404)
        }
        let resolved = await StreamResolver.resolve(server.url("/tv/channel"))
        XCTAssertEqual(resolved.url, server.url("/tv/variants/hd.m3u8"))
    }

    func testSeveralHopsEndAtTheFirstAnswerThatIsNotARedirect() async {
        server.setHandler { request in
            switch request.path {
            case "/a": .redirect(to: "/b", status: 301)
            case "/b": .redirect(to: "/c")
            case "/c": .text("", type: "application/vnd.apple.mpegurl; charset=utf-8")
            default: .status(404)
            }
        }
        let resolved = await StreamResolver.resolve(server.url("/a"))
        XCTAssertEqual(resolved.url, server.url("/c"))
        XCTAssertEqual(resolved.contentType, "application/vnd.apple.mpegurl; charset=utf-8")
        XCTAssertFalse(resolved.isBareTransportStream)
        XCTAssertEqual(server.requests.map(\.path), ["/a", "/b", "/c"])
    }

    func testAnExtensionlessTransportStreamIsRecognisedByItsType() async {
        server.setHandler { _ in .text("", type: "video/MP2T") }
        let resolved = await StreamResolver.resolve(server.url("/channel/7"))
        XCTAssertEqual(resolved.url, server.url("/channel/7"))
        XCTAssertEqual(resolved.contentType, "video/MP2T")
        XCTAssertTrue(resolved.isBareTransportStream)
    }

    func testAServerThatRefusesHEADLeavesTheAddressAsItWas() async {
        server.setHandler { _ in .status(405) }
        let url = server.url("/channel/7")
        let resolved = await StreamResolver.resolve(url)
        XCTAssertEqual(resolved.url, url, "guessing from a 405 is worse than leaving the address alone")
        XCTAssertNil(resolved.contentType)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testARedirectLoopIsGivenUpOnAfterFiveHops() async {
        server.setHandler { request in
            let n = Int(request.path.dropFirst("/hop/".count)) ?? 0
            return .redirect(to: "/hop/\(n + 1)")
        }
        let resolved = await StreamResolver.resolve(server.url("/hop/0"))
        XCTAssertEqual(resolved.url, server.url("/hop/5"), "still an address to try: the one the walk had reached")
        XCTAssertNil(resolved.contentType)
        XCTAssertEqual(server.requests.map(\.path), ["/hop/0", "/hop/1", "/hop/2", "/hop/3", "/hop/4"])
    }

    func testAnUnreachableHostLeavesTheAddressAsItWas() async {
        let url = server.url("/channel/7")
        server.stop()
        let resolved = await StreamResolver.resolve(url)
        XCTAssertEqual(resolved.url, url)
        XCTAssertNil(resolved.contentType)
    }

    func testWhatCountsAsABareTransportStream() {
        func resolved(_ address: String, _ type: String?) -> StreamResolver.Resolved {
            StreamResolver.Resolved(url: URL(string: address)!, contentType: type)
        }
        XCTAssertTrue(resolved("http://h/live.ts", nil).isBareTransportStream)
        XCTAssertTrue(resolved("http://h/live.TS?x=1", "application/octet-stream").isBareTransportStream)
        XCTAssertTrue(resolved("http://h/live", "video/mp2t; charset=binary").isBareTransportStream)
        XCTAssertTrue(resolved("http://h/live", "video/mpeg").isBareTransportStream)
        XCTAssertFalse(resolved("http://h/live", nil).isBareTransportStream)
        XCTAssertFalse(resolved("http://h/live.m3u8", "application/vnd.apple.mpegurl").isBareTransportStream)
        XCTAssertFalse(resolved("http://h/live", "video/mp4").isBareTransportStream)
    }
}
