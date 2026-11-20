//  Watch Together on the iPhone: where it is in the "…" card, and Jellyfin
//  SyncPlay against the QA server. The second person in the group is the
//  test itself, over the server's API (`SyncPlayBot`), so one simulator is
//  enough to see this player follow somebody else's pause, play and jump.
//  SharePlay's session needs FaceTime on two devices (MANUAL.md).

#if os(iOS)
import XCTest

final class PhoneSyncPlayTests: PhonePlayerTestCase {
    /// Reported 2026-11-18: "TV shows doesn't seem to have SharePlay
    /// available". An episode's "…" card has the most in it (After this), and
    /// Watch Together was last, below the fold. It is first now, with both
    /// ways of doing it.
    func testAnEpisodeOffersBothWaysToWatchTogetherWithoutScrolling() throws {
        _ = try playEpisode("show.long", season: 1, number: 2, name: "Long Episode 1.2")
        waitUntilPlaying()
        openPlayerMore()
        let card = app.element(TestID.Player.cardMore)
        for id in [TestID.Player.sharePlayStart, TestID.Player.syncPlayStart] {
            let row = app.button(id)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(id) on an episode")
            XCTAssertTrue(card.frame.insetBy(dx: -1, dy: -1).contains(row.frame), "\(id) is outside the card: \(row.frame) in \(card.frame)")
            XCTAssertTrue(row.isHittable, "\(id) can't be tapped without scrolling")
        }
        attachScreenshot("watch together on an episode (\(device.rawValue))")
    }

    /// A group made from the player is watching what the player has on;
    /// pausing here pauses the group; someone else's jump and play move this
    /// player; leaving leaves.
    func testSyncPlayStartsAGroupAndFollowsIt() throws {
        try standardOnly()
        let (api, id) = try playEpisode("show.long", season: 1, number: 3, name: "Long Episode 1.3")
        let bot = SyncPlayBot(api)
        defer { bot.leave() }
        waitUntilPlaying()
        openPlayerMore()
        app.button(TestID.Player.syncPlayStart).tapNow(10)

        // iOS lists each alert button twice (a button inside a button): firstMatch.
        let new = app.buttons[TestID.Player.syncPlayNew].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 30), "SyncPlay never asked which group")
        XCTAssertTrue(app.staticTexts["SyncPlay"].firstMatch.exists)
        attachScreenshot("which group")
        new.tap()

        // The server has the group, and once this device has said it is
        // ready, has it playing.
        XCTAssertTrue(eventually(timeout: 60) { bot.group()?.state == "Playing" }, "the group never played: \(String(describing: bot.group()))")
        let group = try XCTUnwrap(bot.group())
        waitUntilPlaying()

        // Pause here is pause for the group, and play is play.
        app.button(TestID.Player.playPause).tapNow(10)
        XCTAssertTrue(eventually(timeout: 30) { bot.group()?.state == "Paused" }, "the group didn't pause")
        showControls()
        app.button(TestID.Player.playPause).tapNow(10)
        XCTAssertTrue(eventually(timeout: 30) { bot.group()?.state == "Playing" }, "the group didn't play again")
        waitUntilPlaying()
        app.button(TestID.Player.playPause).tapNow(10)
        XCTAssertTrue(eventually(timeout: 30) { bot.group()?.state == "Paused" }, "the group didn't pause again")

        // Someone else joins and jumps to 6:40: this player goes there.
        try bot.join(group.id)
        try bot.seek(to: 400)
        // Still paused: the server hears where it landed.
        let landed = waitForServerPosition(api, itemId: id, atLeast: 399, timeout: 60)
        XCTAssertEqual(landed ?? -1, 400, accuracy: 3, "didn't follow the jump")

        // And when they press play, it plays, from there.
        try bot.unpause()
        waitUntilPlaying(timeout: 60)
        XCTAssertGreaterThanOrEqual(waitForServerPosition(api, itemId: id, atLeast: 402, timeout: 60) ?? -1, 402, "not playing on from the jump")

        // The card says where this device is, and lets it leave.
        openPlayerMore()
        let leave = app.button(TestID.Player.syncPlayLeave)
        XCTAssertTrue(leave.waitForExistence(timeout: 10))
        XCTAssertFalse(app.button(TestID.Player.sharePlayStart).exists, "SharePlay is offered on top of SyncPlay")
        XCTAssertFalse(app.button(TestID.Player.speedOption("150")).exists, "the group's speed is normal")
        attachScreenshot("in a group")
        leave.tapNow(10)
        XCTAssertTrue(eventually(timeout: 30) { (bot.group()?.people ?? 1) <= 1 }, "this device is still in the group")
    }

    /// Settings › SyncPlay asks the same question with nothing playing, and
    /// joining a group that is watching something opens it here.
    func testJoiningFromSettingsOpensWhatTheGroupIsWatching() throws {
        try standardOnly()
        let api = try self.api
        let id = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 4))
        let bot = SyncPlayBot(api)
        defer { bot.leave() }
        try bot.create("Test night")
        try bot.putOn(id, at: 120)
        launchHome()
        openSettings()
        // A plain tap: XCUITest scrolls a list row into view itself, which
        // a swipe from here overshoots.
        let row = app.button(TestID.Settings.syncPlay)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no SyncPlay row in Settings")
        row.tap()
        let join = app.buttons[TestID.Player.syncPlayGroup("Test night")].firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 30), "the group isn't offered")
        attachScreenshot("join from settings")
        join.tap()
        app.element(TestID.Player.root).waitToExist(60)
        XCTAssertNotNil(try api.waitForPlayback(of: id, timeout: 60), "the group's title never opened here")
        XCTAssertGreaterThanOrEqual(waitForServerPosition(api, itemId: id, atLeast: 119, timeout: 60) ?? -1, 119, "not opened at the group's 2:00")
    }
}
#endif
