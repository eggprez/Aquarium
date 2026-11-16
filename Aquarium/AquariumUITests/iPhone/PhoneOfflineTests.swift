//  The server going away while the app is open, and the app opened with no
//  server: the "Offline — showing downloads" strip, the smaller shell
//  (Downloads and Settings), the Downloads page and downloaded music with
//  no server, and everything coming back when the server does.
//
//  The server is "cut" by the switch proxy the app is signed in through
//  (PhoneProxySupport.swift): it stops listening and drops its connections.
//  The QA server itself is never touched.

#if os(iOS)
import XCTest

final class PhoneOfflineTests: PhoneProxyTestCase {
    private var strip: XCUIElement { any(TestID.Shell.offlineBanner) }

    /// The tabs on offer. Online that is the system tab bar; the offline
    /// shell's two tabs are the app's own bar (buttons named `tab.item.*`).
    private var tabLabels: [String] {
        let own = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.item.'")).allElementsBoundByIndex.map(\.label)
        return Array(Set(app.tabBars.buttons.allElementsBoundByIndex.map(\.label) + own)).sorted()
    }

    /// A tab of the offline shell's own bar, by `AppSection.id`.
    private func offlineTab(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons.matching(identifier: TestID.Tab.item(id)).firstMatch.tapNow(10, file: file, line: line)
    }

    /// Cuts the server and waits for the app to say so. The app finds out
    /// from its next request to the server, so Home is asked to reload.
    private func goOffline(file: StaticString = #filePath, line: UInt = #line) {
        PhoneProxy.cut()
        let refresh = app.button(TestID.Home.refresh)
        for _ in 0..<6 where !strip.waitForExistence(timeout: 4) {
            if !refresh.exists, app.tabBars.buttons["Home"].exists { tab("Home", file: file, line: line) }
            if refresh.waitForExistence(timeout: 5), !strip.exists { refresh.tapIfThere() }
            if strip.waitForExistence(timeout: 12) { break }
        }
        strip.waitToExist(10, file: file, line: line)
    }

    /// Nothing downloaded: the strip appears, the app moves to Downloads
    /// (which says nothing is downloaded), the tabs shrink to what works
    /// without a server, and when the server returns so do Home and the tabs.
    func testServerLostThenBackWithNothingDownloaded() throws {
        launchThroughProxy()
        XCTAssertTrue(tabLabels.contains("Home"), "\(tabLabels)")
        goOffline()
        XCTAssertTrue(strip.label.contains("Offline — showing downloads"), strip.label)
        assertOnScreen(strip, "the offline strip")
        attachScreenshot("offline, nothing downloaded")

        app.element(TestID.Downloads.root).waitToExist(20)
        app.element(TestID.Downloads.empty).waitToExist(10)
        XCTAssertTrue(eventually(timeout: 10) { self.tabLabels == ["Downloads", "More"] },
                      "the offline shell is Downloads and More: \(tabLabels)")
        XCTAssertFalse(app.element(TestID.Home.root).exists, "Home still showing with no server")
        // The full-page "Server offline" state is not part of the phone's
        // offline shell: nothing listed there needs the server (MANUAL.md).
        XCTAssertFalse(app.element(TestID.Shell.offlineScreen).exists)
        // Nothing to manage and no music library to fetch: the page's menu is off.
        XCTAssertFalse(any(TestID.Downloads.manageMenu).isEnabled, "the Downloads menu is on with nothing to act on")
        XCTAssertFalse(any(TestID.Downloads.pause).exists)

        // The strip says when it will try again.
        XCTAssertTrue(eventually(timeout: 30) { self.strip.label.contains("Trying again in") },
                      "the strip never said when it would try again: \(strip.label)")

        PhoneProxy.restore()
        XCTAssertTrue(strip.waitToVanish(90), "still offline 90 s after the server came back")
        app.element(TestID.Home.root).waitToExist(30)
        XCTAssertTrue(eventually(timeout: 10) { self.tabLabels.contains("Home") && self.tabLabels.contains("Music") }, "\(tabLabels)")
    }

    /// A film and an album on the device, then no server: Downloads lists
    /// them, the film plays, the Music door opens the downloaded library and
    /// a song plays, a song that is here can still be removed, and marking
    /// the film watched waits to be synced until the server is back.
    func testDownloadsAndMusicWithNoServer() throws {
        let api = try self.api
        let film = try Fixtures.require().item("film.rated_r")   // unwatched at the baseline
        let album = try XCTUnwrap(PhoneFixtures.album("FX Compilation"))
        let songs = tracks(album)
        addTeardownBlock { [weak self] in
            self?.app?.terminate()
            try? api.markUnplayed(film.id)
            for id in songs { try? api.markUnplayed(id) }
        }
        launchThroughProxy()
        try queueFilm("film.rated_r")
        _ = try openAlbum("FX Compilation")
        any(TestID.Music.detailMore).tapNow(10)
        any(TestID.Music.menuDownload).tapNow(10)
        for id in songs {
            XCTAssertTrue(wait(for: any(TestID.Music.downloadMark(id)), "exists == true AND label == 'Downloaded'", timeout: 90), "\(id) never arrived")
        }
        openDownloads()
        let card = any(TestID.Downloads.filmCard(film.id))
        card.waitToExist(120)

        goOffline()
        app.element(TestID.Downloads.root).waitToExist(20)
        card.waitToExist(10)
        XCTAssertEqual(any(TestID.Downloads.itemCount).label, "5 items on this device")
        attachScreenshot("offline downloads")

        // With no server there is no "Download All Music", but what is here can be managed.
        openManageMenu()
        any(TestID.Downloads.manageDeleteAll).waitToExist(10)
        XCTAssertFalse(any(TestID.Downloads.manageDownloadAllMusic).exists, "Download All Music offered with no server")
        dismissMenu()

        // The film plays from the device.
        app.reveal(card)
        card.tapNow(5)
        app.element(TestID.Player.root).waitToExist(40)
        // Held at once: the film is 20 s long, and left to end it closes
        // the player and marks itself watched.
        showControls()
        app.button(TestID.Player.playPause).tapNow(5)
        app.element(TestID.Player.video).waitToExist(10)
        let timeline = any(TestID.Player.scrubber)
        timeline.waitToExist(10)
        XCTAssertTrue(((timeline.value as? String) ?? "").contains("of 20 seconds"), "the downloaded film has no length offline: \(String(describing: timeline.value))")
        XCTAssertFalse(app.element(TestID.Player.errorCard).exists, "the downloaded film reported an error with no server")
        closePlayer()

        // Marked watched offline: kept to send later, and Sync can't be pressed yet.
        heldMenu(on: card, item: TestID.Downloads.filmCardToggleWatched(film.id)).tapNow(5)
        let sync = any(TestID.Downloads.sync)
        for _ in 0..<3 where !sync.isOnScreen(in: app.windows.firstMatch.frame) { app.swipeDown() }
        sync.waitToExist(10)
        XCTAssertFalse(sync.isEnabled, "Sync can be pressed with no server")
        XCTAssertFalse(try api.userData(film.id).played, "watched reached the server while it was cut off")

        // Downloaded music, from the page's Music door.
        let door = any(TestID.Downloads.musicDoor)
        XCTAssertTrue(door.label.contains("4 songs"), door.label)
        revealAndTap(door)
        app.element(TestID.Music.downloaded).waitToExist(20)
        assertOnScreen(strip, "the offline strip on a pushed page")
        attachScreenshot("offline downloaded music")
        let songsDoor = any(TestID.Music.libraryDoor("songs"))
        app.reveal(songsDoor)
        songsDoor.tapNow(10)
        app.element(TestID.Music.onDeviceList("songs")).waitToExist(20)
        for id in songs { XCTAssertTrue(any(TestID.Music.song(id)).waitForExistence(timeout: 10), "song \(id) not listed offline") }
        any(TestID.Music.song(songs[0])).tapNow(10)
        app.element(TestID.MiniPlayer.root).waitToExist(30)
        any(TestID.MiniPlayer.playPause).tapNow(10)

        // A song's menu offline: it can be removed, and nothing offers a download.
        any(TestID.Music.songMore(songs[3])).tapNow(10)
        let remove = any(TestID.Music.menuRemoveDownload)
        remove.waitToExist(10)
        XCTAssertFalse(any(TestID.Music.menuDownload).exists, "Download offered with no server")
        remove.tapNow(5)
        goBack()
        goBack()
        app.element(TestID.Downloads.root).waitToExist(20)
        XCTAssertTrue(wait(for: door, "label CONTAINS '3 songs'", timeout: 20), door.label)

        // Back: the strip goes, and what was marked offline reaches the server.
        PhoneProxy.restore()
        XCTAssertTrue(strip.waitToVanish(90), "still offline 90 s after the server came back")
        XCTAssertTrue(eventually(timeout: 60) {
            if (try? api.userData(film.id).played) == true { return true }
            let sync = self.any(TestID.Downloads.sync)
            if sync.exists, sync.isEnabled { sync.tapNow(2) }
            return false
        }, "watched, marked offline, never reached the server")
        wipeDownloads()
    }

    /// The app opened with no server: it starts in the same smaller shell,
    /// on Downloads, with the strip; Settings still opens; and when the
    /// server returns the full app does, by itself.
    func testOpenedWithNoServer() throws {
        launchThroughProxy()
        app.terminate()
        PhoneProxy.cut()
        // The same signed-in state, and no server.
        launch(reset: false, environment: [TestLaunch.serverEnv: PhoneProxy.server])
        strip.waitToExist(60)
        app.element(TestID.Downloads.root).waitToExist(20)
        app.element(TestID.Downloads.empty).waitToExist(10)
        attachScreenshot("opened offline")
        XCTAssertFalse(app.element(TestID.Home.root).exists, "Home showing with no server")
        XCTAssertFalse(tabLabels.contains("Home") || tabLabels.contains("Music") || tabLabels.contains("Library"),
                       "server-only tabs offered offline: \(tabLabels)")
        XCTAssertFalse(app.element(TestID.Shell.offlineScreen).exists)

        // Settings works without the server.
        XCTAssertEqual(tabLabels, ["Downloads", "More"])
        offlineTab("more")
        app.element(TestID.Shell.more).waitToExist(10)
        any(TestID.Shell.moreRow("settings")).tapNow(10)
        app.element(TestID.Settings.root).waitToExist(20)
        assertOnScreen(strip, "the offline strip over Settings")

        PhoneProxy.restore()
        XCTAssertTrue(strip.waitToVanish(90), "still offline 90 s after the server came back")
        XCTAssertTrue(eventually(timeout: 30) { self.tabLabels.contains("Home") }, "\(tabLabels)")
    }
}
#endif
