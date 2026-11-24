//  The press-and-hold menu's queue rows on an iPad, which PadContextMenuTests
//  only lists: Play Later on a film with nothing playing starts it (the
//  queue starts itself when idle, PlayerModel.startQueueIfIdle), and a
//  season chip's Play Next Episode and Play Season Later
//  (ItemContextMenu.playActions) play the right episode, the season's next
//  one waiting in the player's Up Next card.
//
//  Baseline (FIXTURES.md): FX Long Show S01E01 played, S01E02 in progress,
//  Season 2 not started (S02E01 a favourite, which is left alone).

#if os(iOS)
import XCTest

final class PadContextMenuMoreTests: PadUITestCase {
    /// Play Later with nothing playing puts the film on: the toast, then the
    /// player, and the server hears it.
    func testPlayLaterWithNothingPlayingStartsTheFilm() throws {
        let film = try fx.item("film.long_direct")
        let api = try api()
        launchHome()
        let target = cardButton(film.id)
        XCTAssertTrue(reveal(target), "the film in Continue Watching")
        contextMenu(on: target, waitingFor: TestID.Item.menuPlayLater)
        XCTAssertTrue(app.button(TestID.Item.menuPlayNext).exists, "Play Next beside it")
        app.button(TestID.Item.menuPlayLater).padTap()
        expectToast(containing: "Added to Up Next")
        player.waitToExist(40)
        XCTAssertNotNil(try api.waitForPlayback(of: film.id, timeout: 60), "the server never heard the film play")
        closePlayer()
    }

    /// Season 1's chip: Play Next Episode plays the first episode not
    /// watched, S01E02, not the opener.
    func testASeasonChipsPlayNextEpisodePlaysTheFirstUnwatched() throws {
        let show = try fx.item("show.long")
        let s1 = try season("show.long", 1)
        let e1 = try episode("show.long", season: 1, episode: 1)
        let e2 = try episode("show.long", season: 1, episode: 2)
        let api = try api()
        try? api.markPlayed(e1.id)
        launchHome()
        openItem(show.id)
        let chip = app.button(TestID.Detail.season(s1))
        XCTAssertTrue(reveal(chip))
        contextMenu(on: chip, waitingFor: TestID.Item.menuPlayNextEpisode)
        XCTAssertTrue(app.button(TestID.Item.menuPlaySeasonNext).exists, "a season's menu queues the season too")
        XCTAssertTrue(app.button(TestID.Item.menuPlaySeasonLater).exists)
        app.button(TestID.Item.menuPlayNextEpisode).padTap()
        player.waitToExist(40)
        XCTAssertNotNil(try api.waitForPlayback(of: e2.id, timeout: 60), "S01E02 (the first not watched) should be playing")
        closePlayer()
    }

    /// Season 2's chip, Play Season Later, with nothing playing: the toast,
    /// the season's first episode plays, and its second waits in Up Next.
    func testPlaySeasonLaterPlaysTheSeasonInOrder() throws {
        let show = try fx.item("show.long")
        let s2 = try season("show.long", 2)
        let first = try episode("show.long", season: 2, episode: 1)
        let second = try episode("show.long", season: 2, episode: 2)
        let api = try api()
        addTeardownBlock {
            // Season 2 back to not started; S02E01 stays the baseline's favourite.
            for id in [first.id, second.id] {
                try? api.setResume(id, seconds: 0)
                try? api.markUnplayed(id)
            }
        }
        launchHome()
        openItem(show.id)
        let chip = app.button(TestID.Detail.season(s2))
        XCTAssertTrue(reveal(chip))
        contextMenu(on: chip, waitingFor: TestID.Item.menuPlaySeasonLater)
        app.button(TestID.Item.menuPlaySeasonLater).padTap()
        expectToast(containing: "Added the season to Up Next")
        player.waitToExist(40)
        XCTAssertNotNil(try api.waitForPlayback(of: first.id, timeout: 60), "S02E01 should be playing")
        waitForPlaying()
        _ = openCard(pill: TestID.Player.pillUpNext, card: TestID.Player.cardUpNext)
        XCTAssertTrue(app.element(TestID.Player.upNextItem(second.id)).waitForExistence(timeout: 10), "S02E02 waits in Up Next")
        attachScreenshot("season queued")
        closePlayer()
    }
}
#endif
