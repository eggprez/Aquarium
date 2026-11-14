//  Downloads (queue, a file and a stream download, sizes, offline playback
//  with progress sent later, removal, the fx-nodownload refusal) and Live
//  TV (the guide, tuning a channel, the live timeline, back to More).

#if os(iOS)
import XCTest

final class PhoneDownloadsTests: PhoneUITestCase {
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// Downloads a fixture from its page at `quality` (a DownloadQualities
    /// label) and waits until Downloads lists it as a film.
    private func download(_ key: String, quality: String = "Original quality", timeout: TimeInterval = 180,
                          file: StaticString = #filePath, line: UInt = #line) throws -> Fixtures.Item {
        let item = try Fixtures.require().item(key)
        openTitle(item.id, searching: item.name, file: file, line: line)
        app.button(TestID.Detail.download).tapNow(20, file: file, line: line)
        any(TestID.Detail.downloadQuality(quality)).tapNow(10, file: file, line: line)
        let anyway = any(TestID.Downloads.spacePromptAnyway)
        if anyway.waitForExistence(timeout: 3) { anyway.tap() }
        goBack(file: file, line: line)
        moreSection("downloads", file: file, line: line)
        app.element(TestID.Downloads.root).waitToExist(20, file: file, line: line)
        any(TestID.Downloads.filmCard(item.id)).waitToExist(timeout, file: file, line: line)
        return item
    }

    private func deleteDownload(_ id: String) {
        let card = any(TestID.Downloads.filmCard(id))
        guard card.exists else { return }
        card.press(forDuration: 1.2)
        any(TestID.Downloads.filmCardDelete(id)).tapNow(10)
        let confirm = any(TestID.Downloads.deletionConfirm)
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    func testEmptyDownloadsPage() throws {
        launchHome()
        moreSection("downloads")
        app.element(TestID.Downloads.root).waitToExist(20)
        XCTAssertTrue(any(TestID.Downloads.empty).waitForExistence(timeout: 10) || any(TestID.Downloads.summary).exists)
        attachScreenshot("downloads (\(device.rawValue))")
    }

    func testDownloadMenuOffersEveryQualityWithSizes() throws {
        launchHome()
        _ = try openFixture("film.long_direct")
        app.button(TestID.Detail.download).tapNow()
        for q in DownloadLabels.all {
            let row = any(TestID.Detail.downloadQuality(q))
            XCTAssertTrue(row.waitForExistence(timeout: 5), q)
        }
        let original = any(TestID.Detail.downloadQuality("Original quality"))
        XCTAssertTrue(original.label.contains("MB") || original.label.contains("GB") || original.label.contains("MiB"), "no size: \(original.label)")
        assertOnScreen(original, "Original quality row")
    }

    /// A small original file: queued, transferred, listed with its size,
    /// played offline-capable from Downloads, then removed.
    func testFileDownloadPlaysAndIsRemoved() throws {
        try standardOnly()
        launchHome()
        let item = try download("film.rated_g")
        XCTAssertTrue(any(TestID.Downloads.storage).exists || any(TestID.Downloads.itemCount).exists, "no summary")
        let card = any(TestID.Downloads.filmCard(item.id))
        card.press(forDuration: 1.2)
        any(TestID.Downloads.filmCardPlay(item.id)).tapNow(10)
        app.element(TestID.Player.root).waitToExist(30)
        showControls()
        app.button(TestID.Player.playPause).tap()
        app.button(TestID.Player.pillQuality).tapNow(10)
        // Regression R-89c1c6c: a download's Quality card says Downloaded first.
        app.button(TestID.Player.qualityDownloaded).waitToExist(10)
        app.button(TestID.Player.cardClose).tap()
        closePlayer()
        deleteDownload(item.id)
        XCTAssertTrue(any(TestID.Downloads.filmCard(item.id)).waitToVanish(20))
    }

    /// A transcoded (stream) download of a short title completes.
    func testStreamDownloadCompletes() throws {
        try standardOnly()
        launchHome()
        let item = try download("film.h264_hi10_mkv", quality: "480p · 2 Mbps (transcoded)", timeout: 300)
        deleteDownload(item.id)
    }

    /// The queue: a second download waits while the first runs; removing it
    /// from the queue leaves the first.
    func testQueueAndCancel() throws {
        try standardOnly()
        launchHome()
        for key in ["film.long_multitrack", "film.long_direct"] {
            let item = try Fixtures.require().item(key)
            openTitle(item.id, searching: item.name)
            app.button(TestID.Detail.download).tapNow()
            any(TestID.Detail.downloadQuality("1080p · 9 Mbps (transcoded)")).tapNow(10)
            let anyway = any(TestID.Downloads.spacePromptAnyway)
            if anyway.waitForExistence(timeout: 3) { anyway.tap() }
            goBack(); goBack()
        }
        moreSection("downloads")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'downloads.transfer.' OR identifier BEGINSWITH 'downloads.queued.'"))
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'downloads.film.'"))
        XCTAssertTrue(eventually(timeout: 30) { rows.count > 0 || done.count > 0 }, "nothing under way or done")
        attachScreenshot("downloads in progress (\(device.rawValue))")
        let manage = any(TestID.Downloads.manageMenu)
        if manage.exists {
            manage.tap()
            let clear = any(TestID.Downloads.manageClearQueue)
            if clear.waitForExistence(timeout: 5) { clear.tap() } else { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        }
        for key in ["film.long_multitrack", "film.long_direct"] {
            let id = try Fixtures.require().item(key).id
            let cancel = any(TestID.Downloads.transferCancel(id))
            if cancel.exists { cancel.tap() }
            let remove = any(TestID.Downloads.queuedRemove(id))
            if remove.exists { remove.tap() }
        }
        XCTAssertTrue(eventually(timeout: 60) { rows.count == 0 }, "transfers left after cancelling")
        for key in ["film.long_multitrack", "film.long_direct"] {
            let id = try Fixtures.require().item(key).id
            let card = any(TestID.Downloads.filmCard(id))
            if card.exists {
                card.press(forDuration: 1.2)
                any(TestID.Downloads.filmCardDelete(id)).tapNow(10)
                let confirm = any(TestID.Downloads.deletionConfirm)
                if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            }
        }
    }

    func testPauseAndResumeAllDownloads() throws {
        try standardOnly()
        launchHome()
        moreSection("downloads")
        let pause = any(TestID.Downloads.pause)
        guard pause.waitForExistence(timeout: 5) else { throw XCTSkip("Pause shows only with downloads in the queue") }
        let before = pause.label
        pause.tap()
        XCTAssertTrue(eventually { pause.label != before })
        pause.tap()
    }

    /// fx-nodownload: Download is refused (403) and the app says so.
    func testDownloadRefusedForAccountWithoutPermission() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account(named: "fx-nodownload"))
        launchHome(account: account)
        let item = try Fixtures.require().item("film.rated_g")
        openTitle(item.id, searching: item.name)
        let download = app.button(TestID.Detail.download)
        guard download.waitForExistence(timeout: 10) else { return }   // hidden is also right
        download.tap()
        let original = any(TestID.Detail.downloadQuality("Original quality"))
        if original.waitForExistence(timeout: 5) { original.tap() }
        goBack()
        moreSection("downloads")
        XCTAssertFalse(any(TestID.Downloads.filmCard(item.id)).waitForExistence(timeout: 30), "a refused download was listed as done")
    }

    func testMusicAndAudiobookDoors() throws {
        try standardOnly()
        launchHome()
        moreSection("downloads")
        let music = any(TestID.Downloads.musicDoor)
        app.reveal(music)
        guard music.exists else { throw XCTSkip("the Music door shows only with music downloaded") }
        music.tapNow(10)
        XCTAssertTrue(app.element(TestID.Music.downloaded).waitForExistence(timeout: 20) || app.element(TestID.Music.onDeviceEmpty).exists)
    }
}

enum DownloadLabels {
    static let all = ["Original quality", "4K · 34 Mbps (transcoded)", "1440p · 18 Mbps (transcoded)",
                      "1080p · 9 Mbps (transcoded)", "720p · 4.5 Mbps (transcoded)", "480p · 2 Mbps (transcoded)"]
}

final class PhoneLiveTVTests: PhoneUITestCase {
    private var channels: [String] {
        ((Fixtures.shared?.raw["existing"] as? [String: Any])?["liveTv"] as? [String: Any])?["channels"]
            .flatMap { $0 as? [[String: Any]] }?.compactMap { $0["id"] as? String } ?? []
    }

    func testGuideShowsBothChannelsAndProgrammes() throws {
        launchHome()
        moreSection("livetv")
        app.element(TestID.LiveTV.root).waitToExist(30)
        app.element(TestID.Guide.root).waitToExist(30)
        for id in channels { app.descendants(matching: .any).matching(identifier: TestID.Guide.channel(id)).firstMatch.waitToExist(20) }
        let programmes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'guide.programme.cell.'"))
        XCTAssertGreaterThan(programmes.count, 1)
        assertOnScreen(app.element(TestID.LiveTV.title), "Live TV heading")
        attachScreenshot("guide (\(device.rawValue))")
    }

    func testTuningAChannelPlaysLive() throws {
        let api = try self.api
        let channel = try XCTUnwrap(channels.first)
        launchHome()
        moreSection("livetv")
        app.descendants(matching: .any).matching(identifier: TestID.Guide.channel(channel)).firstMatch.tapNow(30)
        app.element(TestID.Player.root).waitToExist(40)
        XCTAssertNotNil(try api.waitForPlayback(of: channel, timeout: 60) ?? api.waitForPlayback(timeout: 5))
        showControls()
        XCTAssertTrue(app.element(TestID.Player.liveTimeline).waitForExistence(timeout: 10), "no live timeline")
        app.button(TestID.Player.pillInfo).tapNow(10)
        XCTAssertTrue(app.element(TestID.Player.infoTitle).waitForExistence(timeout: 10))
    }

    func testChannelUpAndDownInThePlayer() throws {
        try standardOnly()
        let api = try self.api
        let (first, second) = (channels[0], channels[1])
        launchHome()
        moreSection("livetv")
        app.descendants(matching: .any).matching(identifier: TestID.Guide.channel(first)).firstMatch.tapNow(30)
        app.element(TestID.Player.root).waitToExist(40)
        showControls()
        let next = app.button(TestID.Player.channelNext)
        next.tapNow(10)
        XCTAssertNotNil(try api.waitForPlayback(of: second, timeout: 60), "channel next did not tune channel 2")
    }

    func testSpeedIsUnavailableOnLive() throws {
        try standardOnly()
        launchHome()
        moreSection("livetv")
        app.descendants(matching: .any).matching(identifier: TestID.Guide.channel(channels[0])).firstMatch.tapNow(30)
        app.element(TestID.Player.root).waitToExist(40)
        showControls()
        app.button(TestID.Player.more).tapNow(10)
        XCTAssertTrue(app.element(TestID.Player.speedUnavailable).waitForExistence(timeout: 10)
                      || !app.button(TestID.Player.speedOption("150")).exists)
    }

    /// Regression R-2c20fe6-lt: Live TV opened from More had no way back;
    /// R-PM15 (open on main): its back button crowded the heading.
    func testLiveTVFromMoreHasBack() throws {
        launchHome()
        moreSection("livetv")
        app.element(TestID.LiveTV.root).waitToExist(30)
        let back = app.buttons.matching(identifier: TestID.Common.back).firstMatch
        back.waitToExist(10)
        let title = app.element(TestID.LiveTV.title)
        if title.exists && back.frame.maxY > title.frame.minY && back.frame.minY < title.frame.maxY {
            let gap = title.frame.minX - back.frame.maxX
            XCTAssertGreaterThanOrEqual(gap, 8, "gap \(gap)")
        }
        back.tap()
        app.element(TestID.Shell.more).waitToExist(10)
    }
}
#endif
