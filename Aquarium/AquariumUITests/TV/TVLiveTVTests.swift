//  Live TV on the Apple TV: the guide grid (Views/TVGuideView.swift) against
//  the QA server's two M3U channels, tuning from it, and the player on a
//  channel: the top and bottom edges change channel, the Channels tab, no
//  scrubbing.

#if os(tvOS)
import XCTest

final class TVLiveTVTests: TVTestCase {
    private func openGuide(file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let channels = try Fixtures.require().liveChannels
        guard channels.count >= 2 else { throw XCTSkip("the QA server has no live channels in fixtures.json") }
        launchHome(file: file, line: line)
        openTab("livetv", title: "Live TV", anchor: TestID.LiveTV.root, file: file, line: line)
        app.element(TestID.Guide.root).waitToExist(30, file: file, line: line)
        Remote.press(.down)
        assertFocusPresent("the guide", file: file, line: line)
        return channels
    }

    func testTheGuideListsEveryChannelWithProgrammes() throws {
        let channels = try openGuide()
        for id in channels {
            app.element(TestID.Guide.channel(id)).waitToExist(20)
        }
        waitUntil("programme cells", timeout: 30) { [weak self] in
            (self?.app.elements(prefix: "guide.programme.cell.").count ?? 0) >= 4
        }
        XCTAssertTrue(app.element(TestID.Guide.timeMark(0)).exists, "no time ruler")
        XCTAssertFalse(app.element(TestID.Guide.errorBanner).exists)
        attachScreenshot("guide")
    }

    func testTheGuideScrollsLaterAndComesBack() throws {
        _ = try openGuide()
        let firstMark = app.element(TestID.Guide.timeMark(0))
        firstMark.waitToExist(20)
        let before = firstMark.label
        press(.right, until: { false }, max: 8)
        assertFocusPresent("the guide after moving right")
        XCTAssertTrue(focusedID.hasPrefix("guide.programme.cell."), "right from a channel goes into its programmes")
        press(.left, until: { [unowned self] in self.focusedID.hasPrefix("guide.channel.cell.") }, max: 12)
        XCTAssertTrue(focusedID.hasPrefix("guide.channel.cell."), "Left never got back to the channel column")
        XCTAssertEqual(firstMark.label, before)
    }

    func testUpFromTheGuideReachesTheStrip() throws {
        _ = try openGuide()
        XCTAssertTrue(focusTabStrip(max: 15), "focus trapped in the guide (on \(focused?.summary ?? "nothing"))")
    }

    func testTuningAChannelAndChangingItWithTheEdges() throws {
        let channels = try openGuide()
        let first = app.element(TestID.Guide.channel(channels[0]))
        XCTAssertTrue(Remote.focus(on: first, in: app))
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        let api = try self.api()
        let session = try api.tvWaitForPlayback(of: nil, timeout: 60)
        XCTAssertNotNil(session, "the server never heard the channel play")
        let firstPlaying = session?.nowPlayingId
        // On a channel, the top edge is the next channel.
        TVHook.remote("up")
        waitUntil("another channel to play", timeout: 60) {
            guard let now = try? api.tvSessions().first(where: { $0.nowPlayingId != nil })?.nowPlayingId else { return false }
            return now != firstPlaying
        }
        showControls()
        app.element(TestID.Player.liveTimeline).waitToExist(10)
        XCTAssertFalse(app.element(TestID.Player.scrubber).exists, "a channel has no scrubber")
    }

    func testTheChannelsTabListsTheLineUp() throws {
        let channels = try openGuide()
        XCTAssertTrue(Remote.focus(on: app.element(TestID.Guide.channel(channels[1])), in: app))
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        TVHook.debug("tab.channels")
        app.element(TestID.Player.panel).waitToExist(10)
        for id in channels { app.element(TestID.Player.channelRow(id)).waitToExist(10) }
        XCTAssertFalse(app.element(TestID.Player.panelTab("quality")).exists, "a channel has no Quality tab")
        XCTAssertTrue(app.element(TestID.Player.panelTab("channels")).exists)
        let row = app.element(TestID.Player.channelRow(channels[0]))
        XCTAssertTrue(Remote.focus(on: row, in: app))
        Remote.select()
        let api = try self.api()
        waitUntil("channel 1 playing", timeout: 60) {
            (try? api.tvSessions().first(where: { $0.nowPlayingId != nil })?.nowPlayingId) == channels[0]
        }
    }

    func testMenuLeavesAChannelBackToTheGuide() throws {
        let channels = try openGuide()
        XCTAssertTrue(Remote.focus(on: app.element(TestID.Guide.channel(channels[0])), in: app))
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        _ = try api().tvWaitForPlayback(of: nil, timeout: 60)
        Remote.menu()
        if app.element(TestID.Player.root).exists { Remote.menu() }
        XCTAssertTrue(app.element(TestID.Player.root).waitToVanish(15))
        app.element(TestID.Guide.root).waitToExist(10)
        assertFocusPresent("the guide after a channel")
    }
}
#endif
