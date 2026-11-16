//  `ArtworkProbe`: the report in Settings that says why a channel's logo is
//  not showing. Each kind of answer a logo host can give, served from this
//  machine's loopback address, and the sentence the report makes of it.

import XCTest
@testable import Aquarium

final class ArtworkProbeTests: XCTestCase {
    private var server: LoopbackServer!

    override func setUpWithError() throws {
        server = try LoopbackServer()
        let png = CorePicture.png(width: 32, height: 32)
        server.setHandler { request in
            switch request.path {
            case "/logos/good.png": .data(png, type: "image/png; charset=binary")
            case "/logos/vector.svg": .text("<svg xmlns=\"http://www.w3.org/2000/svg\"/>", type: "image/svg+xml")
            case "/logos/page.png": .text("<html>hotlinking not allowed</html>", type: "text/html")
            case "/logos/refused.png": .status(403)
            default: .status(404)
            }
        }
    }

    override func tearDown() { server.stop() }

    private func channel(_ name: String, logo: String?) -> BaseItem {
        CoreItem.make("ch-\(name)", "TvChannel", name: name) { $0.ExternalLogoURL = logo }
    }

    func testEachKindOfAnswerGetsItsOwnSentence() async throws {
        let results = await ArtworkProbe.run(channels: [
            channel("Good", logo: "\(server.base)/logos/good.png"),
            channel("None", logo: nil),
            channel("Empty", logo: ""),
            channel("Blank", logo: "   "),
            channel("Vector", logo: "\(server.base)/logos/vector.svg"),
            channel("Page", logo: "\(server.base)/logos/page.png"),
            channel("Refused", logo: "\(server.base)/logos/refused.png"),
            channel("Missing", logo: "\(server.base)/logos/missing.png"),
        ])
        XCTAssertEqual(results.map(\.channel), ["Good", "None", "Empty", "Blank", "Vector", "Page", "Refused", "Missing"],
                       "asked all at once, reported in the order of the channel list")
        XCTAssertEqual(results.map(\.id), results.map(\.channel))
        XCTAssertEqual(results.map(\.ok).enumerated().filter { $0.offset != 4 }.map(\.element),
                       [true, false, false, false, false, false, false])

        let good = results[0]
        XCTAssertEqual(good.address, "\(server.base)/logos/good.png")
        XCTAssertTrue(good.outcome.hasPrefix("HTTP 200, image/png, "), good.outcome)
        XCTAssertTrue(good.outcome.hasSuffix(" — decoded fine"), good.outcome)

        for none in results[1...2] {
            XCTAssertNil(none.address)
            XCTAssertTrue(none.outcome.hasPrefix("no logo"), none.outcome)
        }
        XCTAssertEqual(results[3].outcome, "not a usable address")
        XCTAssertEqual(results[3].address, "   ")
        #if canImport(UIKit)
        // AppKit's NSImage reads SVG, so on a Mac this one decodes.
        XCTAssertTrue(results[4].outcome.hasSuffix("but it is SVG, which no Apple image decoder reads"), results[4].outcome)
        #endif
        XCTAssertTrue(results[5].outcome.hasSuffix("but it is text/html, which this device couldn't decode"), results[5].outcome)
        XCTAssertEqual(results[6].outcome, "HTTP 403 — the host refused or doesn't have it")
        XCTAssertEqual(results[7].outcome, "HTTP 404 — the host refused or doesn't have it")
    }

    func testLogosAreAskedForTheWayABrowserAsks() async {
        _ = await ArtworkProbe.run(channels: [channel("Good", logo: "\(server.base)/logos/good.png")])
        let request = server.requests.first
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.headers["user-agent"]?.contains("Safari"), true)
        XCTAssertEqual(request?.headers["accept"]?.contains("image/svg+xml"), true)
    }

    /// The server's own channels, still in the store just after the source
    /// changes to a custom playlist, are not the playlist's to report on.
    func testOnlyThePlaylistsChannelsAreChecked() {
        let fromServer = channel("Server", logo: nil)
        let fromPlaylist = CoreItem.make("iptv-0-pad.one", "TvChannel", name: "Pad One")
        XCTAssertEqual(ArtworkProbe.playlistChannels([fromServer, fromPlaylist]).map(\.title), ["Pad One"])
        XCTAssertTrue(ArtworkProbe.playlistChannels([fromServer]).isEmpty)
    }

    func testOnlyASampleIsProbed() async {
        let many = (0..<12).map { channel("C\($0)", logo: "\(server.base)/logos/good.png?c=\($0)") }
        let byDefault = await ArtworkProbe.run(channels: many)
        XCTAssertEqual(byDefault.map(\.channel), (0..<8).map { "C\($0)" }, "the first eight: short enough to read")
        let three = await ArtworkProbe.run(channels: many, sample: 3)
        XCTAssertEqual(three.count, 3)
        let none = await ArtworkProbe.run(channels: [])
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(server.requests.count, 11)
    }

    func testAHostThatIsNotThereIsSaidToBeUnreachable() async {
        let address = "\(server.base)/logos/good.png"
        server.stop()
        let results = await ArtworkProbe.run(channels: [channel("Gone", logo: address)])
        XCTAssertEqual(results.first?.ok, false)
        XCTAssertEqual(results.first?.address, address)
        XCTAssertEqual(results.first?.outcome.hasPrefix("couldn't be reached from this device: "), true)
    }
}
