//  Settings rows on the phone that PhoneSettingsTests only finds, checked for
//  what they do: switches and choices on every page are kept across a
//  relaunch, the download stepper keeps to its range, Resume off starts a
//  title from the beginning, and a custom M3U playlist fills the Live TV
//  guide (served from this Mac by `PhoneTinyServer`).
//
//  The idioms (switch tapped at its trailing end, a Picker's option by
//  identifier or label, back to the list by the More tab) are in
//  PhoneASettingsSupport.swift.

#if os(iOS)
import XCTest

final class PhoneSettingsControlsTests: PhoneSettingsDriverCase {
    /// Flips a switch and returns what it is now.
    @discardableResult
    private func flip(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let was = isOn(settingSwitch(id, file: file, line: line))
        setSwitch(id, !was, file: file, line: line)
        return !was
    }

    /// Every page's rows, changed from what a fresh launch has, are what the
    /// pages show after the app is quit and opened again.
    func testSwitchesAndChoicesSurviveARelaunch() throws {
        try standardOnly()
        launchHome()
        var expected: [(page: String, id: String, on: Bool)] = []

        openSettings(page: "appearance")
        expected.append(("appearance", TestID.Settings.nextUpRewatching, flip(TestID.Settings.nextUpRewatching)))
        expected.append(("appearance", TestID.Settings.nextUpInProgress, flip(TestID.Settings.nextUpInProgress)))
        choose(TestID.Settings.nextUpDays, key: "30", label: "1 month")

        backToSettingsList()
        openSettingsPage("video")
        expected.append(("video", TestID.Settings.videoResume, flip(TestID.Settings.videoResume)))
        expected.append(("video", TestID.Settings.videoAutoplayNext, flip(TestID.Settings.videoAutoplayNext)))

        backToSettingsList()
        openSettingsPage("audio")
        choose(TestID.Settings.audioLanguage, key: "fre,fra", label: "French")

        backToSettingsList()
        openSettingsPage("subtitles")
        choose(TestID.Settings.subtitlesLanguage, key: "off", label: "Never")

        backToSettingsList()
        openSettingsPage("music")
        expected.append(("music", TestID.Settings.musicNormalizeVolume, flip(TestID.Settings.musicNormalizeVolume)))
        expected.append(("music", TestID.Settings.musicRomanize, flip(TestID.Settings.musicRomanize)))
        choose(TestID.Settings.musicMixSource, key: "jellyfin", label: "Jellyfin Instant Mix")

        backToSettingsList()
        openSettingsPage("downloads")
        expected.append(("downloads", TestID.Settings.downloadsWifiOnly, flip(TestID.Settings.downloadsWifiOnly)))
        attachScreenshot("settings changed")

        relaunchKeepingState()
        openSettings()
        var page = ""
        for row in expected {
            if row.page != page {
                if !page.isEmpty { backToSettingsList() }
                openSettingsPage(row.page)
                page = row.page
                if page == "appearance" { assertRow(TestID.Settings.nextUpDays, reads: "1 month", "after a relaunch") }
                if page == "music" { assertRow(TestID.Settings.musicMixSource, reads: "Jellyfin Instant Mix", "after a relaunch") }
            }
            assertSwitch(row.id, row.on, "after a relaunch")
        }
        backToSettingsList()
        openSettingsPage("audio")
        assertRow(TestID.Settings.audioLanguage, reads: "French", "after a relaunch")
        backToSettingsList()
        openSettingsPage("subtitles")
        assertRow(TestID.Settings.subtitlesLanguage, reads: "Never", "after a relaunch")
        attachScreenshot("after the relaunch")
    }

    /// The number of downloads at once stays between 1 and 6, and is kept.
    func testDownloadsAtOnceStaysInItsRangeAndIsKept() throws {
        try standardOnly()
        launchHome()
        openSettings(page: "downloads")
        let shown = { () -> Int? in
            let value = self.any(TestID.Settings.value(TestID.Settings.downloadsConcurrency))
            let text = value.exists ? self.said(value) : self.said(self.any(TestID.Settings.downloadsConcurrency))
            return text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.last
        }
        XCTAssertNotNil(shown(), "the stepper shows no number")
        let minus = stepperButton(TestID.Settings.downloadsConcurrency, "Decrement")
        for _ in 0..<7 { minus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(eventually(timeout: 5) { shown() == 1 }, "never below one at once: \(String(describing: shown()))")
        let plus = stepperButton(TestID.Settings.downloadsConcurrency, "Increment")
        plus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(eventually(timeout: 5) { shown() == 2 }, "one more: \(String(describing: shown()))")
        for _ in 0..<8 { plus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(eventually(timeout: 5) { shown() == 6 }, "never above six: \(String(describing: shown()))")
        minus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(eventually(timeout: 5) { shown() == 5 })

        relaunchKeepingState()
        openSettings(page: "downloads")
        XCTAssertTrue(eventually(timeout: 10) { shown() == 5 }, "not kept across a relaunch: \(String(describing: shown()))")
    }

    /// Settings › Video › Resume off: Play starts at the beginning however
    /// far in the server says you are.
    func testResumeOffStartsFromTheBeginning() throws {
        try standardOnly()
        let api = try self.api
        let film = try Fixtures.require().item("film.long_direct")
        try api.setResume(film.id, seconds: 300)
        addTeardownBlock { try? api.resetItem(film.id) }
        launchHome()
        openSettings(page: "video")
        setSwitch(TestID.Settings.videoResume, false)
        _ = try openFixture("film.long_direct")
        playFromDetail()
        let p = waitForServerPosition(api, itemId: film.id, atLeast: 1, timeout: 60)
        XCTAssertNotNil(p, "the server never heard the film play")
        XCTAssertLessThan(p ?? 999, 60, "started from the 5:00 resume point with Resume off")
    }

    /// Settings › Live TV › Custom playlist: the guide lists the playlist's
    /// channels, and Settings says what the playlist held.
    func testACustomPlaylistFillsTheGuide() throws {
        try standardOnly()
        let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-id="aq.one" tvg-chno="1",Aquarium One
        http://127.0.0.1:9/one.m3u8
        #EXTINF:-1 tvg-id="aq.two" tvg-chno="2",Aquarium Two
        http://127.0.0.1:9/two.m3u8
        """
        let server = try PhoneTinyServer(routes: ["/aq.m3u": ("audio/x-mpegurl", Data(playlist.utf8))])
        defer { server.stop() }

        launchHome()
        openSettings(page: "liveTV")
        choose(TestID.Settings.liveTVSource, key: "custom", label: "Custom playlist (M3U + XMLTV)")
        let row = any(TestID.Settings.liveTVCustomPlaylist)
        bring(row)
        row.tapNow(10)
        app.element(TestID.Settings.pageRoot("customPlaylist")).waitToExist(10)
        let field = app.textFields[TestID.Settings.liveTVPlaylistURL]
        field.tapNow(10)
        field.typeText("\(server.base)/aq.m3u\n")
        XCTAssertTrue(eventually(timeout: 5) { (field.value as? String ?? "").contains("/aq.m3u") }, "the address was not typed")

        tab("More")
        if !app.element(TestID.Shell.more).waitForExistence(timeout: 3) { tab("More") }
        let liveTV = any(TestID.Shell.moreRow("livetv"))
        app.reveal(liveTV)
        liveTV.tapNow(20)
        app.element(TestID.LiveTV.root).waitToExist(30)
        for id in ["iptv-0-aq.one", "iptv-1-aq.two"] {
            XCTAssertTrue(any(TestID.Guide.channel(id)).waitForExistence(timeout: 30), "the guide has no \(id)")
        }
        attachScreenshot("guide from the playlist")

        backToSettingsList()
        openSettingsPage("liveTV")
        let summary = any(TestID.Settings.liveTVPlaylistSummary)
        bring(summary)
        XCTAssertTrue(eventually(timeout: 10) { self.said(summary).contains("2 channels") },
                      "Settings does not say what the playlist held: \(said(summary))")
        assertRow(TestID.Settings.liveTVCustomPlaylist, reads: "127.0.0.1", "the row names the playlist's host")
    }
}
#endif
