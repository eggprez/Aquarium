//  Watch Together on an iPad: Jellyfin SyncPlay from the player's "…" card
//  and from Settings, against the QA server. The other person in the group
//  is the test itself over the server's API (`SyncPlayBot`), so one
//  simulator sees this player follow somebody else's pause, play and jump.
//  The same card and coordinator as the iPhone's (PhoneSyncPlayTests); here
//  on the iPad's chrome, where "…" drops a card under the top bar and the
//  Settings row sits in the split list. SharePlay's session needs FaceTime
//  on two devices (MANUAL.md).

#if os(iOS)
import XCTest

final class PadSyncPlayTests: PadPlayerTestCase {
    /// Where the server says this app is in `itemId`, once it is at least
    /// `atLeast` seconds in.
    private func serverPosition(_ api: JellyfinAPI, _ itemId: String, atLeast: Double, timeout: TimeInterval) -> Double? {
        var found: Double?
        _ = eventually(timeout) {
            guard let p = (try? api.padSessions())?.first(where: { $0.nowPlayingId == itemId })?.positionSeconds,
                  p >= atLeast else { return false }
            found = p
            return true
        }
        return found
    }

    private func openMoreCard() -> XCUIElement {
        openCard(pill: TestID.Player.more, card: TestID.Player.cardMore)
    }

    /// Both ways of watching together are at the top of an episode's "…"
    /// card, inside it and tappable without scrolling (reported 2026-11-18
    /// on the iPhone: Watch Together was last, below the fold).
    func testAnEpisodeOffersBothWaysToWatchTogetherInTheMoreCard() throws {
        let e2 = try episode("show.long", season: 1, episode: 2)
        launchHome()
        play(e2.id)
        waitForPlaying()
        let card = openMoreCard()
        for id in [TestID.Player.sharePlayStart, TestID.Player.syncPlayStart] {
            let row = app.button(id)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(id) on an episode")
            XCTAssertTrue(card.frame.insetBy(dx: -1, dy: -1).contains(row.frame), "\(id) is outside the card: \(row.frame) in \(card.frame)")
            XCTAssertTrue(row.isHittable, "\(id) can't be tapped without scrolling")
        }
        attachScreenshot("watch together on an iPad")
        closeCard()
    }

    /// A group made from the player is watching what the player has on;
    /// pausing here pauses the group; someone else's jump and play move this
    /// player; the card then offers Leave and no SharePlay or speed chips.
    func testSyncPlayStartsAGroupAndFollowsIt() throws {
        let e3 = try episode("show.long", season: 1, episode: 3)
        let api = try api()
        let bot = SyncPlayBot(api)
        addTeardownBlock {
            bot.leave()
            try? api.resetItem(e3.id)
        }
        launchHome()
        play(e3.id)
        waitForPlaying()
        _ = openMoreCard()
        app.button(TestID.Player.syncPlayStart).padTap(10)

        // An alert's buttons can be listed twice (a button inside a button): firstMatch.
        let new = app.buttons[TestID.Player.syncPlayNew].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 30), "SyncPlay never asked which group")
        XCTAssertTrue(app.staticTexts["SyncPlay"].firstMatch.exists)
        XCTAssertTrue(app.buttons[TestID.Player.syncPlayCancel].firstMatch.exists, "the question can be turned down")
        attachScreenshot("which group")
        new.tap()

        XCTAssertTrue(eventually(60) { bot.group()?.state == "Playing" }, "the group never played: \(String(describing: bot.group()))")
        let group = try XCTUnwrap(bot.group())
        XCTAssertGreaterThanOrEqual(group.people, 1)
        waitForPlaying()

        tapControl(TestID.Player.playPause)
        XCTAssertTrue(eventually(30) { bot.group()?.state == "Paused" }, "pausing here didn't pause the group")
        tapControl(TestID.Player.playPause)
        XCTAssertTrue(eventually(30) { bot.group()?.state == "Playing" }, "playing here didn't play the group")
        waitForPlaying()
        tapControl(TestID.Player.playPause)
        XCTAssertTrue(eventually(30) { bot.group()?.state == "Paused" }, "the group didn't pause again")

        // Someone else joins and jumps to 6:40: this player goes there.
        try bot.join(group.id)
        try bot.seek(to: 400)
        let landed = serverPosition(api, e3.id, atLeast: 399, timeout: 60)
        XCTAssertEqual(landed ?? -1, 400, accuracy: 3, "didn't follow the jump")
        try bot.unpause()
        waitForPlaying(60)
        XCTAssertGreaterThanOrEqual(serverPosition(api, e3.id, atLeast: 402, timeout: 60) ?? -1, 402, "not playing on from the jump")

        _ = openMoreCard()
        let leave = app.button(TestID.Player.syncPlayLeave)
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "Leave in the card while in a group")
        XCTAssertFalse(app.button(TestID.Player.sharePlayStart).exists, "SharePlay is offered on top of SyncPlay")
        XCTAssertFalse(app.button(TestID.Player.speedOption(TestID.Player.speedKey(1.5))).exists, "a group plays at normal speed")
        attachScreenshot("in a group")
        leave.padTap()
        XCTAssertTrue(eventually(30) { (bot.group()?.people ?? 1) <= 1 }, "this iPad is still in the group")
    }

    /// Settings' SyncPlay row (under Watch Together, in the iPad's list)
    /// reads Off, asks the same question with nothing playing, and joining a
    /// group that is watching something opens it here at the group's spot.
    func testJoiningFromSettingsOpensWhatTheGroupIsWatching() throws {
        let e4 = try episode("show.long", season: 1, episode: 4)
        let api = try api()
        let bot = SyncPlayBot(api)
        addTeardownBlock {
            bot.leave()
            try? api.resetItem(e4.id)
        }
        try bot.create("iPad test night")
        try bot.putOn(e4.id, at: 120)
        launchHome()
        app.button(TestID.Sidebar.settings).padTap()
        app.element(TestID.Settings.root).waitToExist(20)
        let row = app.button(TestID.Settings.syncPlay)
        XCTAssertTrue(reveal(row), "a SyncPlay row in Settings")
        XCTAssertTrue(row.label.contains("SyncPlay") && row.label.contains("Off"), "the row reads \(row.label)")
        row.padTap()
        let join = app.buttons[TestID.Player.syncPlayGroup("iPad test night")].firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 30), "the group isn't offered")
        XCTAssertTrue(join.label.hasPrefix("Join"), join.label)
        attachScreenshot("join from settings")
        join.tap()
        player.waitToExist(60)
        XCTAssertNotNil(try api.waitForPlayback(of: e4.id, timeout: 60), "the group's title never opened here")
        XCTAssertGreaterThanOrEqual(serverPosition(api, e4.id, atLeast: 119, timeout: 60) ?? -1, 119, "not opened at the group's 2:00")
    }

    /// Cancel on the question leaves nobody in a group and the row at Off.
    func testCancellingTheQuestionFromSettingsJoinsNothing() throws {
        let bot = SyncPlayBot(try api())
        launchHome()
        app.button(TestID.Sidebar.settings).padTap()
        app.element(TestID.Settings.root).waitToExist(20)
        let row = app.button(TestID.Settings.syncPlay)
        XCTAssertTrue(reveal(row))
        row.padTap()
        let cancel = app.buttons[TestID.Player.syncPlayCancel].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "the question came")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                           "Whatever you play next is put on for the group")).firstMatch.exists,
                      "with nothing playing it says what a new group would do")
        cancel.tap()
        XCTAssertTrue(cancel.waitToVanish(10))
        XCTAssertNil(bot.group(), "a group was made: \(String(describing: bot.group()))")
        XCTAssertTrue(row.label.contains("Off"), "the row reads \(row.label)")
    }
}
#endif
