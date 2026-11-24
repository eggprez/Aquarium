//  Live TV beyond the guide grid (`TVLiveTVTests`): the Info tab over a
//  channel, which says what is on and what comes next from the guide
//  (PlayerPanel `InfoTab.live`), and the Live TV tab with a custom playlist
//  source and no playlist, which says so in place of an empty guide
//  (Views/LiveTVView.swift, `LiveTV.empty`).

#if os(tvOS)
import XCTest

final class TVLiveTVMoreTests: TVSettingsPagesCase {
    func testInfoOverAChannelNamesTheProgrammeAndWhatComesNext() throws {
        let channels = try Fixtures.require().liveChannels
        guard !channels.isEmpty else { throw XCTSkip("the QA server has no live channels in fixtures.json") }
        launchHome()
        openTab("livetv", title: "Live TV", anchor: TestID.LiveTV.root)
        app.element(TestID.Guide.root).waitToExist(30)
        Remote.press(.down)
        let channel = app.element(TestID.Guide.channel(channels[0]))
        XCTAssertTrue(Remote.focus(on: channel, in: app), "can't reach the first channel")
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        XCTAssertNotNil(try api().tvWaitForPlayback(of: nil, timeout: 60), "the server never heard the channel play")
        openPanel("info")
        let title = app.element(TestID.Player.infoTitle)
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Info names nothing over a channel")
        XCTAssertFalse(title.label.isEmpty)
        waitUntil("the programmes coming up", timeout: 30) { [weak self] in
            (self?.app.elements(prefix: "player.info.upcoming.").count ?? 0) >= 1
        }
        XCTAssertLessThanOrEqual(app.elements(prefix: "player.info.upcoming.").count, 3, "more than three coming up")
        XCTAssertFalse(app.element(TestID.Player.stopAfterThis).exists, "a channel offers Autoplay")
        attachScreenshot("info over a channel")
    }

    func testACustomSourceWithNoPlaylistSaysThereAreNoChannels() {
        openSettings()
        openPage("liveTV")
        pick(TestID.Settings.liveTVSource, option: "custom", backOn: TestID.Settings.pageRoot("liveTV"))
        back(to: TestID.Settings.root)
        XCTAssertTrue(focusTabStrip(max: 25))
        openTab("livetv", title: "Live TV", anchor: TestID.LiveTV.root)
        let empty = app.element(TestID.LiveTV.empty)
        let error = app.element(TestID.LiveTV.error)
        waitUntil("Live TV to say it has no channels", timeout: 30) { empty.exists || error.exists }
        XCTAssertFalse(app.element(TestID.Guide.root).exists, "a guide drawn with no channels")
        if empty.exists {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'playlist'")).firstMatch.exists,
                          "the empty page doesn't point at the playlist setting")
        }
        attachScreenshot("live tv, no playlist")
        XCTAssertTrue(focusTabStrip(max: 15), "focus trapped on the empty Live TV page")
    }
}
#endif
