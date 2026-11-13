//  Live TV on an iPad: the section from the sidebar's Live group, the guide
//  at the iPad's density, tuning from a channel or a programme, and in the
//  player the channel buttons and the Channels pill whose line-up is a
//  popover off the pill on an iPad (3704e52).

#if os(iOS)
import XCTest

final class PadLiveTVTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    private func channels() throws -> [(id: String, name: String)] {
        guard let existing = try fx.raw["existing"] as? [String: Any],
              let live = existing["liveTv"] as? [String: Any],
              let list = live["channels"] as? [[String: Any]] else { throw XCTSkip("no live TV in fixtures.json") }
        return list.compactMap { c in (c["id"] as? String).map { ($0, c["name"] as? String ?? "") } }
    }

    private func openLiveTV() {
        launchHome()
        showSection("livetv")
        app.element(TestID.LiveTV.root).waitToExist(30)
        app.element(TestID.Guide.root).waitToExist(30)
    }

    func testGuideListsTheChannelsWithProgrammes() throws {
        let channels = try channels()
        openLiveTV()
        for channel in channels {
            XCTAssertTrue(app.element(TestID.Guide.channel(channel.id)).waitForExistence(timeout: 30), "\(channel.name)")
        }
        XCTAssertTrue(app.elements(prefix: "guide.programme.cell.").firstMatch.waitForExistence(timeout: 30), "programmes")
        XCTAssertTrue(app.element(TestID.LiveTV.title).exists, "the page's own heading")
        attachScreenshot("guide portrait")
        turn(.landscapeLeft)
        XCTAssertTrue(app.element(TestID.Guide.root).waitForExistence(timeout: 10))
        attachScreenshot("guide landscape")
    }

    func testFullWidthLiveTVHasNoBackButton() throws {
        // ipad-qa-findings.md: "Full width from the sidebar has no back
        // button, correctly".
        openLiveTV()
        XCTAssertFalse(app.button(TestID.Common.back).exists)
    }

    func testTuningAChannelPlaysItWithChannelButtonsAndPill() throws {
        let channels = try channels()
        openLiveTV()
        let cell = app.element(TestID.Guide.channel(channels[0].id))
        cell.padTap(30)
        player.waitToExist(40)
        waitForPlaying(60)
        showControls()
        XCTAssertTrue(app.button(TestID.Player.channelNext).exists, "next channel where a film has its skips")
        XCTAssertTrue(app.button(TestID.Player.channelPrevious).exists)
        XCTAssertFalse(app.button(TestID.Player.skipForward).exists, "no skips on a channel")
        XCTAssertTrue(app.button(TestID.Player.pillChannels).exists, "a Channels pill")
        app.button(TestID.Player.pillChannels).padTap()
        let row = app.element(TestID.Player.channelRow(channels[1].id))
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the line-up lists \(channels[1].name)")
        let panel = app.element(TestID.Player.panel)
        if panel.exists {
            XCTAssertLessThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.8, "a popover on an iPad")
        }
        attachScreenshot("channels popover")
        row.padTap()
        XCTAssertTrue(waitUntil(30, "the second channel to be tuned") {
            self.app.element(TestID.Player.title).label.contains(channels[1].name)
                || (try? self.api().sessions().first?.nowPlayingId) == channels[1].id
        })
        closePlayer()
    }

    func testNextChannelWraps() throws {
        let channels = try channels()
        openLiveTV()
        app.element(TestID.Guide.channel(channels[1].id)).padTap(30)
        player.waitToExist(40)
        waitForPlaying(60)
        tapControl(TestID.Player.channelNext)
        XCTAssertTrue(waitUntil(30, "wrapped to the first channel") {
            self.app.element(TestID.Player.title).label.contains(channels[0].name)
                || (try? self.api().sessions().first?.nowPlayingId) == channels[0].id
        })
        closePlayer()
    }

    func testProgrammeCellTunesItsChannel() throws {
        openLiveTV()
        let programme = app.elements(prefix: "guide.programme.cell.").firstMatch
        programme.padTap(30)
        player.waitToExist(40)
        closePlayer()
    }
}
#endif
