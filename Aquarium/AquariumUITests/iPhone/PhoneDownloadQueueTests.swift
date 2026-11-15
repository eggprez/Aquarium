//  The Downloads page with something going on: a transfer under way and
//  others waiting (progress, status, pause, resume, cancel, remove, clear),
//  a queue longer than the page lists, downloads the server refuses (the
//  failed rows, retry, delete, retry all, clear), a downloaded film's menu
//  and Delete watched, and a downloaded show's own page.
//
//  All through the switch proxy (see PhoneProxySupport.swift): slowed, a
//  transfer stays "downloading" long enough to look at; told to refuse
//  `/Download`, a download fails at once. Every test ends with nothing on
//  the device and the account's watch state as it found it.

#if os(iOS)
import XCTest

final class PhoneDownloadQueueTests: PhoneProxyTestCase {
    private func label(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private var queuedRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH 'downloads.queued.' AND NOT (identifier BEGINSWITH 'downloads.queued.remove.')"))
    }

    /// Says no to the "Delete …?" question. On a phone it is a popover with
    /// the one button and no Cancel (see MANUAL.md): a tap away from it is
    /// the no. Cancel is pressed where the system does show one.
    private func cancelDeletion() {
        let confirm = any(TestID.Downloads.deletionConfirm)
        confirm.waitToExist(10)
        let cancel = any(TestID.Downloads.deletionCancel)
        if cancel.exists {
            cancel.tapNow(2)
        } else {
            let window = app.windows.firstMatch
            let y = confirm.frame.midY < window.frame.midY ? 0.8 : 0.12
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: y)).tap()
        }
        XCTAssertTrue(confirm.waitToVanish(10), "the delete question stayed up")
    }

    // MARK: A transfer and its queue

    /// Four episodes asked for at once, one at a time over a slow line: the
    /// first is under way with its bar and its figures, the rest wait in
    /// order; Pause puts the running one back, Resume carries on, Cancel
    /// and Remove take one each, Clear takes the rest, and a pause with
    /// nothing left says so.
    func testTransferQueuePauseCancelAndClear() throws {
        let show = try Fixtures.require().item("show.long")
        let season = try XCTUnwrap(PhoneFixtures.season("show.long", 1))
        let e = try (1...4).map { try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: $0)) }
        PhoneProxy.slow(5_000_000, matching: "/Download")
        launchThroughProxy()
        queueSeasons(of: show, seasonIds: [season])
        openDownloads()

        // Under way.
        app.element(TestID.Downloads.downloadingSection).waitToExist(40)
        app.element(TestID.Downloads.transfer(e[0])).waitToExist(20)
        any(TestID.Downloads.transferProgress(e[0])).waitToExist(10)
        let status = any(TestID.Downloads.transferStatus(e[0]))
        status.waitToExist(10)
        XCTAssertTrue(wait(for: status, "label CONTAINS '%' AND label CONTAINS ' / '", timeout: 30), "no share and size: \(status.label)")
        let first = status.label
        XCTAssertTrue(eventually(timeout: 20) { status.label != first }, "the figures never moved from \(first)")
        any(TestID.Downloads.transferCancel(e[0])).waitToExist(5)
        attachScreenshot("a transfer and its queue")

        // Waiting, in order.
        app.element(TestID.Downloads.queueSection).waitToExist(10)
        XCTAssertTrue(label("Up next · 3").exists, "queue heading")
        for id in e[1...] {
            app.element(TestID.Downloads.queued(id)).waitToExist(5)
            XCTAssertTrue(any(TestID.Downloads.queuedRemove(id)).exists, "no Remove for \(id)")
        }
        XCTAssertLessThan(app.element(TestID.Downloads.queued(e[1])).frame.minY, app.element(TestID.Downloads.queued(e[3])).frame.minY)
        XCTAssertFalse(any(TestID.Downloads.queueMore).exists, "three waiting is not 'and more'")

        // Pause: the running one goes back to the head of the queue.
        let pause = any(TestID.Downloads.pause)
        XCTAssertEqual(pause.label, "Pause")
        revealAndTap(pause)
        XCTAssertTrue(wait(for: pause, "label == 'Resume'"), "Pause did not become Resume")
        XCTAssertTrue(app.element(TestID.Downloads.transfer(e[0])).waitToVanish(20), "still transferring while paused")
        app.element(TestID.Downloads.queued(e[0])).waitToExist(10)
        XCTAssertFalse(app.element(TestID.Downloads.pausedSection).exists, "the Paused note is for an empty queue")

        // Resume: it carries on.
        revealAndTap(pause)
        XCTAssertTrue(wait(for: pause, "label == 'Pause'"))
        app.element(TestID.Downloads.transfer(e[0])).waitToExist(30)

        // Cancel the one under way: the next takes its place.
        revealAndTap(any(TestID.Downloads.transferCancel(e[0])))
        XCTAssertTrue(app.element(TestID.Downloads.transfer(e[0])).waitToVanish(20), "cancelled transfer still listed")
        app.element(TestID.Downloads.transfer(e[1])).waitToExist(40)

        // Remove one from the queue, then clear what is left of it.
        revealAndTap(any(TestID.Downloads.queuedRemove(e[3])))
        XCTAssertTrue(app.element(TestID.Downloads.queued(e[3])).waitToVanish(10))
        XCTAssertTrue(app.element(TestID.Downloads.queued(e[2])).exists)
        revealAndTap(any(TestID.Downloads.queueClear))
        XCTAssertTrue(app.element(TestID.Downloads.queueSection).waitToVanish(10), "Clear left a queue")
        XCTAssertTrue(app.element(TestID.Downloads.transfer(e[1])).exists, "Clear took the running transfer too")

        // Paused with nothing waiting: the page says why nothing starts.
        for _ in 0..<3 where !pause.isOnScreen(in: app.windows.firstMatch.frame) { app.swipeDown() }
        pause.tapNow(5)
        app.element(TestID.Downloads.queued(e[1])).waitToExist(20)
        revealAndTap(any(TestID.Downloads.queuedRemove(e[1])))
        app.element(TestID.Downloads.pausedSection).waitToExist(10)
        attachScreenshot("paused, nothing waiting")
        XCTAssertEqual(pause.label, "Resume")
        for _ in 0..<3 where !pause.isOnScreen(in: app.windows.firstMatch.frame) { app.swipeDown() }
        pause.tapNow(5)
        XCTAssertTrue(app.element(TestID.Downloads.pausedSection).waitToVanish(10))
        XCTAssertTrue(pause.waitToVanish(10), "Pause shows with nothing to pause")
        app.element(TestID.Downloads.empty).waitToExist(10)
        wipeDownloads()
    }

    /// A whole music library queued and paused: the page lists the head of
    /// the queue and counts the rest, the Music tab says songs are on their
    /// way, and Delete all (asked twice: once cancelled) empties it.
    func testLongQueueIsCountedNotListed() throws {
        PhoneProxy.slow(3_000_000, matching: "/Download")
        launchThroughProxy()
        openDownloads()
        openManageMenu()
        any(TestID.Downloads.manageDownloadAllMusic).tapNow(10)
        // "Download all music?" — the songs counted and weighed first.
        let go = app.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download ' AND label CONTAINS 'song'")).firstMatch
        go.waitToExist(60)
        attachScreenshot("download all music")
        go.tap()
        let pause = any(TestID.Downloads.pause)
        pause.tapNow(20)
        XCTAssertTrue(wait(for: pause, "label == 'Resume'"))
        XCTAssertTrue(app.element(TestID.Downloads.downloadingSection).waitToVanish(20))

        app.element(TestID.Downloads.queueSection).waitToExist(10)
        let more = any(TestID.Downloads.queueMore)
        more.waitToExist(10)
        XCTAssertNotNil(more.label.range(of: #"^and \d+ more waiting$"#, options: .regularExpression), more.label)
        XCTAssertEqual(queuedRows.count, 25, "the page lists the first 25")
        app.reveal(more)
        attachScreenshot("and more waiting")

        // The Music tab's strip, and where it goes.
        openMusic()
        let banner = any(TestID.Music.downloadBanner)
        banner.waitToExist(20)
        XCTAssertNotNil(banner.label.range(of: #"Downloading \d+ songs"#, options: .regularExpression), banner.label)
        assertOnScreen(banner.staticTexts.firstMatch, "the downloading strip")
        // By its words: the strip's own frame takes in the bar above it.
        banner.staticTexts.firstMatch.tapNow(5)
        app.element(TestID.Downloads.root).waitToExist(20)

        // Delete all: asked first, and Cancel means no.
        openManageMenu()
        any(TestID.Downloads.manageDeleteAll).tapNow(10)
        cancelDeletion()
        XCTAssertTrue(app.element(TestID.Downloads.queueSection).exists, "cancelled, yet the queue went")
        openManageMenu()
        any(TestID.Downloads.manageDeleteAll).tapNow(10)
        any(TestID.Downloads.deletionConfirm).tapNow(10)
        XCTAssertTrue(app.element(TestID.Downloads.queueSection).waitToVanish(20), "Delete all left the queue")
        XCTAssertTrue(any(TestID.Downloads.musicDoor).waitToVanish(20), "songs left on the device")
        openMusic()
        XCTAssertTrue(banner.waitToVanish(10), "the strip outlived the queue")
        wipeDownloads()
    }

    // MARK: Failed

    /// Three downloads the server refuses: each is listed with what the
    /// server said, Retry and a bin; Retry all asks for them again (and is
    /// refused again); Clear removes them; and once the server relents,
    /// Retry on a row brings the film down.
    func testFailedDownloadsRetryDeleteAndClear() throws {
        let fx = try Fixtures.require()
        let films = try ["film.rated_pg13", "film.rated_r", "film.rated_nc17"].map { try fx.item($0) }
        PhoneProxy.fail("/Download", status: 410)
        launchThroughProxy()
        for key in ["film.rated_pg13", "film.rated_r", "film.rated_nc17"] { try queueFilm(key) }
        openDownloads()

        app.element(TestID.Downloads.failedSection).waitToExist(60)
        for film in films {
            app.element(TestID.Downloads.failed(film.id)).waitToExist(60)
            let message = any(TestID.Downloads.failedMessage(film.id))
            XCTAssertEqual(message.label, "Server answered 410")
            XCTAssertTrue(any(TestID.Downloads.failedRetry(film.id)).exists)
            XCTAssertTrue(any(TestID.Downloads.failedDelete(film.id)).exists)
        }
        XCTAssertTrue(label("Failed · 3").exists, "failed heading")
        XCTAssertEqual(any(TestID.Downloads.failedRetryAll).label, "Retry all 3")
        XCTAssertFalse(any(TestID.Downloads.failedMore).exists)
        app.reveal(any(TestID.Downloads.failedClear))
        attachScreenshot("failed downloads")
        for film in films { XCTAssertFalse(any(TestID.Downloads.filmCard(film.id)).exists, "a refused download is listed as a film") }

        // The bin takes one.
        revealAndTap(any(TestID.Downloads.failedDelete(films[2].id)))
        XCTAssertTrue(app.element(TestID.Downloads.failed(films[2].id)).waitToVanish(10))
        XCTAssertEqual(any(TestID.Downloads.failedRetryAll).label, "Retry all 2")

        // Retry all: both are asked for again, refused again, listed again.
        let refused = PhoneProxy.hits
        revealAndTap(any(TestID.Downloads.failedRetryAll))
        XCTAssertTrue(eventually(timeout: 60) { PhoneProxy.hits >= refused + 2 }, "Retry all asked the server \(PhoneProxy.hits - refused) time(s)")
        for film in films[..<2] { app.element(TestID.Downloads.failed(film.id)).waitToExist(30) }

        // Clear failed.
        revealAndTap(any(TestID.Downloads.failedClear))
        XCTAssertTrue(app.element(TestID.Downloads.failedSection).waitToVanish(10), "Clear failed left some")
        app.element(TestID.Downloads.empty).waitToExist(10)

        // One alone has no "all" buttons; Retry on its row works once the server does.
        try queueFilm("film.rated_nc17")
        openDownloads()
        app.element(TestID.Downloads.failed(films[2].id)).waitToExist(60)
        XCTAssertFalse(any(TestID.Downloads.failedRetryAll).exists, "Retry all for one failure")
        XCTAssertFalse(any(TestID.Downloads.failedClear).exists, "Clear failed for one failure")
        PhoneProxy.stopFailing()
        revealAndTap(any(TestID.Downloads.failedRetry(films[2].id)))
        any(TestID.Downloads.filmCard(films[2].id)).waitToExist(90)
        XCTAssertFalse(app.element(TestID.Downloads.failedSection).exists)
        wipeDownloads()
    }

    // MARK: A downloaded film

    /// The summary counts it; its menu plays it and marks it watched; then
    /// Delete watched in the page's menu offers exactly it, asks, takes
    /// Cancel for an answer, and deletes on the second asking.
    func testFilmMenuAndDeleteWatched() throws {
        let api = try self.api
        let film = try Fixtures.require().item("film.rated_pg13")   // unwatched at the baseline
        addTeardownBlock { [weak self] in
            self?.app?.terminate()
            try? api.markUnplayed(film.id)
        }
        launchThroughProxy()
        try queueFilm("film.rated_pg13")
        openDownloads()
        let card = any(TestID.Downloads.filmCard(film.id))
        card.waitToExist(120)
        app.element(TestID.Downloads.filmsSection).waitToExist(5)
        XCTAssertEqual(any(TestID.Downloads.itemCount).label, "1 item on this device")
        let storage = any(TestID.Downloads.storage)
        XCTAssertTrue(wait(for: storage, "label MATCHES '.*[0-9] [KMG]i?B · .* free'"), storage.label)

        // Nothing watched yet: the page's menu has no Delete watched.
        openManageMenu()
        any(TestID.Downloads.manageDeleteAll).waitToExist(10)
        XCTAssertFalse(any(TestID.Downloads.manageDeleteWatched).exists, "Delete watched with nothing watched")
        dismissMenu()

        // The film's own menu.
        let toggle = heldMenu(on: card, item: TestID.Downloads.filmCardToggleWatched(film.id))
        XCTAssertEqual(toggle.label, "Mark watched")
        XCTAssertTrue(any(TestID.Downloads.filmCardPlay(film.id)).exists)
        XCTAssertTrue(any(TestID.Downloads.filmCardDelete(film.id)).exists)
        attachScreenshot("film menu")
        toggle.tapNow(5)
        XCTAssertTrue(toggle.waitToVanish(10))
        XCTAssertEqual(heldMenu(on: card, item: TestID.Downloads.filmCardToggleWatched(film.id)).label, "Mark unwatched")
        dismissMenu()
        XCTAssertTrue(toggle.waitToVanish(10))

        // Delete watched.
        openManageMenu()
        let watched = any(TestID.Downloads.manageDeleteWatched)
        watched.waitToExist(10)
        XCTAssertTrue(watched.label.hasPrefix("Delete watched · 1"), watched.label)
        watched.tapNow(5)
        cancelDeletion()
        XCTAssertTrue(card.exists, "cancelled, yet the film went")
        openManageMenu()
        watched.tapNow(10)
        any(TestID.Downloads.deletionConfirm).tapNow(10)
        XCTAssertTrue(card.waitToVanish(20), "Delete watched left the film")
        app.element(TestID.Downloads.empty).waitToExist(10)
        wipeDownloads()
    }

    // MARK: A downloaded show

    /// A special and a season of a show: its tile's menu, then its own page
    /// (name, counts, size, unwatched; a season's menu; an episode's menu;
    /// Play and Shuffle; the Delete menu by season, watched, and whole show).
    func testDownloadedShowPage() throws {
        let api = try self.api
        let show = try Fixtures.require().item("show.long")
        let specials = try XCTUnwrap(PhoneFixtures.season("show.long", 0))
        let second = try XCTUnwrap(PhoneFixtures.season("show.long", 2))
        let special = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 0, number: 1))
        let e = try (1...3).map { try XCTUnwrap(PhoneFixtures.episode("show.long", season: 2, number: $0)) }
        // None of the four is watched or started at the baseline.
        addTeardownBlock { [weak self] in
            self?.app?.terminate()
            for id in [special] + e { try? api.markUnplayed(id) }
        }
        let (key0, key2) = ("\(show.id)-0", "\(show.id)-2")   // DownloadSeason.id

        launchThroughProxy()
        queueSeasons(of: show, seasonIds: [specials, second])
        openDownloads()
        let tile = any(TestID.Downloads.showCard(show.id))
        tile.waitToExist(180)
        let pending = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH 'downloads.transfer.' OR identifier BEGINSWITH 'downloads.queued.'"))
        XCTAssertTrue(eventually(timeout: 240) { pending.count == 0 }, "the four episodes never all arrived")
        app.element(TestID.Downloads.showsSection).waitToExist(5)
        XCTAssertEqual(any(TestID.Downloads.itemCount).label, "4 items on this device")

        // The tile's menu, and its Delete asked and refused.
        let open = heldMenu(on: tile, item: TestID.Downloads.showCardOpen(show.id))
        for id in [TestID.Downloads.showCardPlay(show.id), TestID.Downloads.showCardShuffle(show.id), TestID.Downloads.showCardDelete(show.id)] {
            XCTAssertTrue(any(id).exists, id)
        }
        any(TestID.Downloads.showCardDelete(show.id)).tapNow(5)
        cancelDeletion()
        heldMenu(on: tile, item: TestID.Downloads.showCardOpen(show.id)).tapNow(5)
        _ = open

        // The show's page.
        app.element(TestID.Downloads.seriesRoot).waitToExist(20)
        XCTAssertEqual(any(TestID.Downloads.seriesTitle).label, show.name)
        XCTAssertEqual(any(TestID.Downloads.seriesSubtitle).label, "2 seasons · 4 episodes")
        XCTAssertNotNil(any(TestID.Downloads.seriesSize).label.range(of: #"^[0-9.]+ [MG]i?B$"#, options: .regularExpression), any(TestID.Downloads.seriesSize).label)
        XCTAssertEqual(any(TestID.Downloads.seriesUnwatched).label, "4 unwatched")
        XCTAssertEqual(any(TestID.Downloads.seriesPlay).label, "Play next")
        for id in [TestID.Downloads.seriesPlay, TestID.Downloads.seriesShuffle, TestID.Downloads.seriesDeleteMenu] {
            assertOnScreen(any(id), id)
        }
        assertNoOverlap(any(TestID.Downloads.seriesPlay), any(TestID.Downloads.seriesShuffle), "Play and Shuffle")
        assertNoOverlap(any(TestID.Downloads.seriesShuffle), any(TestID.Downloads.seriesDeleteMenu), "Shuffle and Delete")
        app.element(TestID.Downloads.season(key0)).waitToExist(10)
        attachScreenshot("downloaded show")

        // A season's menu; its Delete asked and refused.
        revealAndTap(any(TestID.Downloads.seasonMenu(key2)))
        any(TestID.Downloads.seasonPlay(key2)).waitToExist(10)
        XCTAssertTrue(any(TestID.Downloads.seasonShuffle(key2)).exists)
        any(TestID.Downloads.seasonDelete(key2)).tapNow(5)
        cancelDeletion()
        for id in e { XCTAssertTrue(any(TestID.Downloads.row(id)).exists, "cancelled, yet episode \(id) went") }

        // An episode's menu: watched, then another deleted.
        revealAndTap(any(TestID.Downloads.rowMenu(e[0])))
        let toggle = any(TestID.Downloads.rowToggleWatched(e[0]))
        toggle.waitToExist(10)
        XCTAssertEqual(toggle.label, "Mark watched")
        XCTAssertTrue(any(TestID.Downloads.rowPlay(e[0])).exists)
        XCTAssertTrue(any(TestID.Downloads.rowDelete(e[0])).exists)
        toggle.tapNow(5)
        XCTAssertTrue(toggle.waitToVanish(10))
        revealAndTap(any(TestID.Downloads.rowMenu(e[1])))
        any(TestID.Downloads.rowDelete(e[1])).tapNow(10)
        XCTAssertTrue(any(TestID.Downloads.row(e[1])).waitToVanish(10), "deleted episode still listed")
        for _ in 0..<3 where !any(TestID.Downloads.seriesTitle).isOnScreen(in: app.windows.firstMatch.frame) { app.swipeDown() }
        XCTAssertEqual(any(TestID.Downloads.seriesSubtitle).label, "2 seasons · 3 episodes")
        XCTAssertEqual(any(TestID.Downloads.seriesUnwatched).label, "2 unwatched")

        // Play, then Shuffle: each opens the player.
        any(TestID.Downloads.seriesPlay).tapNow(10)
        app.element(TestID.Player.root).waitToExist(40)
        closePlayer()
        any(TestID.Downloads.seriesShuffle).tapNow(10)
        app.element(TestID.Player.root).waitToExist(40)
        closePlayer()
        app.element(TestID.Downloads.seriesRoot).waitToExist(10)

        // The Delete menu: every season, the watched ones, the whole show.
        let menu = any(TestID.Downloads.seriesDeleteMenu)
        menu.tapNow(10)
        let deleteWatched = any(TestID.Downloads.seriesDeleteWatched)
        deleteWatched.waitToExist(10)
        XCTAssertTrue(deleteWatched.label.hasPrefix("Delete watched · 1"), deleteWatched.label)
        XCTAssertEqual(any(TestID.Downloads.seriesDeleteSeason(key0)).label, "Delete Specials · 1")
        XCTAssertEqual(any(TestID.Downloads.seriesDeleteSeason(key2)).label, "Delete Season 2 · 2")
        XCTAssertTrue(any(TestID.Downloads.seriesDeleteAll).exists)
        attachScreenshot("show delete menu")
        deleteWatched.tapNow(5)
        any(TestID.Downloads.deletionConfirm).tapNow(10)
        XCTAssertTrue(any(TestID.Downloads.row(e[0])).waitToVanish(10), "the watched episode stayed")
        XCTAssertFalse(any(TestID.Downloads.seriesUnwatched).label.isEmpty)

        menu.tapNow(10)
        any(TestID.Downloads.seriesDeleteSeason(key0)).tapNow(10)
        any(TestID.Downloads.deletionConfirm).tapNow(10)
        XCTAssertTrue(app.element(TestID.Downloads.season(key0)).waitToVanish(10), "Specials stayed")
        XCTAssertEqual(any(TestID.Downloads.seriesSubtitle).label, "1 season · 1 episode")
        XCTAssertTrue(any(TestID.Downloads.seriesShuffle).waitToVanish(5), "Shuffle for one episode")

        // The whole show: the page goes with its last episode.
        menu.tapNow(10)
        any(TestID.Downloads.seriesDeleteAll).tapNow(10)
        any(TestID.Downloads.deletionConfirm).tapNow(10)
        XCTAssertTrue(app.element(TestID.Downloads.seriesRoot).waitToVanish(20), "the show's page stayed after Delete the whole show")
        app.element(TestID.Downloads.root).waitToExist(10)
        XCTAssertTrue(tile.waitToVanish(10))
        wipeDownloads()
    }

    /// One episode of a show: no Shuffle for one, and deleting it from its
    /// row leaves the page saying there is nothing left, with a way back.
    func testLastEpisodeDeletedLeavesAnEmptyShowPage() throws {
        let show = try Fixtures.require().item("show.long")
        let specials = try XCTUnwrap(PhoneFixtures.season("show.long", 0))
        let special = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 0, number: 1))
        launchThroughProxy()
        queueSeasons(of: show, seasonIds: [specials])
        openDownloads()
        let tile = any(TestID.Downloads.showCard(show.id))
        tile.waitToExist(120)
        // One episode: the tile's menu has no Shuffle.
        heldMenu(on: tile, item: TestID.Downloads.showCardOpen(show.id)).waitToExist(5)
        XCTAssertFalse(any(TestID.Downloads.showCardShuffle(show.id)).exists, "Shuffle for one episode")
        dismissMenu()
        XCTAssertTrue(any(TestID.Downloads.showCardOpen(show.id)).waitToVanish(10))
        tile.tapNow(5)
        app.element(TestID.Downloads.seriesRoot).waitToExist(20)
        XCTAssertEqual(any(TestID.Downloads.seriesSubtitle).label, "1 season · 1 episode")
        XCTAssertEqual(any(TestID.Downloads.seriesUnwatched).label, "1 unwatched")
        XCTAssertFalse(any(TestID.Downloads.seriesShuffle).exists, "Shuffle for one episode")
        revealAndTap(any(TestID.Downloads.rowMenu(special)))
        any(TestID.Downloads.rowDelete(special)).tapNow(10)
        app.element(TestID.Downloads.seriesEmpty).waitToExist(10)
        attachScreenshot("nothing left here")
        goBack()
        app.element(TestID.Downloads.empty).waitToExist(10)
        wipeDownloads()
    }
}
#endif
