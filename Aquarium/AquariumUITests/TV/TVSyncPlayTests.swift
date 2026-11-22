//  Watch Together on the Apple TV: the panel's tab, with SharePlay and
//  SyncPlay in it, and SyncPlay against the QA server — the second person is
//  the test, over the server's API (`SyncPlayBot`). SharePlay's session needs
//  a FaceTime call (MANUAL.md); its orders reach mpv through the same seam
//  SyncPlay's do, which is what this drives.

#if os(tvOS)
import XCTest

final class TVSyncPlayTests: TVPlayerTestCase {
    func testThePanelHasAWatchTogetherTabWithSharePlayAndSyncPlay() throws {
        let id = try Fixtures.require().episode("show.long", season: 1, episode: 2)
        try play(id, from: 60)
        openPanel("together")
        XCTAssertTrue(app.element(TestID.Player.sharePlayStart).waitForExistence(timeout: 10), "no SharePlay on the Apple TV")
        XCTAssertTrue(app.element(TestID.Player.syncPlayStart).exists, "no SyncPlay on the Apple TV")
        attachScreenshot("watch together tab")
    }

    /// A group made from the panel is watching what is on; the remote's
    /// play/pause is the group's; someone else's jump and play move mpv.
    func testSyncPlayStartsAGroupAndFollowsIt() throws {
        let id = try Fixtures.require().episode("show.long", season: 1, episode: 3)
        let bot = SyncPlayBot(try api())
        defer { bot.leave() }
        try play(id, from: 60)
        openPanel("together")
        pick(TestID.Player.syncPlayStart)

        let new = app.buttons[TestID.Player.syncPlayNew].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 30), "SyncPlay never asked which group")
        attachScreenshot("which group")
        // With no group on the server it is the first button, where an
        // alert's focus starts. (XCUITest doesn't report focus inside one.)
        XCTAssertNil(bot.group(), "a group left over from another run")
        Remote.select()

        waitUntil("the group to be playing", timeout: 60) { bot.group()?.state == "Playing" }
        let group = try XCTUnwrap(bot.group())
        waitUntil("this Apple TV to be playing", timeout: 30) { [weak self] in self?.session(id)?.isPaused == false }

        Remote.playPause()
        waitUntil("the group to pause with the remote", timeout: 30) { bot.group()?.state == "Paused" }

        try bot.join(group.id)
        try bot.seek(to: 400)
        waitUntil("the jump to 6:40", timeout: 60) { [weak self] in abs((self?.shownPosition() ?? 0) - 400) < 3 }

        try bot.unpause()
        waitUntil("play, from there", timeout: 60) { [weak self] in
            guard let now = self?.session(id) else { return false }
            return now.isPaused == false && (now.positionSeconds ?? 0) >= 399
        }

        openPanel("together")
        XCTAssertTrue(app.element(TestID.Player.syncPlayLeave).waitForExistence(timeout: 10))
        XCTAssertFalse(app.element(TestID.Player.sharePlayStart).exists, "SharePlay is offered on top of SyncPlay")
        attachScreenshot("in a group")
        pick(TestID.Player.syncPlayLeave)
        waitUntil("this Apple TV to have left", timeout: 30) { (bot.group()?.people ?? 1) <= 1 }
    }
}
#endif
