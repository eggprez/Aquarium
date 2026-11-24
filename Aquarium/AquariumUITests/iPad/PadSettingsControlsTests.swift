//  Settings rows on an iPad that PadSettingsTests and PadSettingsMoreTests
//  only open, checked for what they do: switches and choices on every page
//  kept across a relaunch; Downloads' "at once" stepper held to 1–6; Resume
//  off starting a title from the beginning; Home's "Hide Continue Watching"
//  taking the row off Home and giving it back; a quality rung chosen as the
//  default turning the speed check off; and the list's Watch Together and
//  iCloud rows.
//
//  Upright, so Settings is the one-column list (the split is
//  PadSettingsTests'). Everything changed here is the app's own test
//  settings, which a clean launch starts without; Resume off moves the
//  baseline film, and the base class puts it back before every test.

#if os(iOS)
import XCTest

final class PadSettingsControlsTests: PadUITestCase {
    private typealias Settings = TestID.Settings

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    // MARK: Getting about

    private func openSettingsList(file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.button(TestID.Sidebar.settings)
        if !gear.exists || !gear.isHittable { revealSidebar() }
        gear.padTap(file: file, line: line)
        app.element(Settings.root).waitToExist(20, file: file, line: line)
        // Back to the list if Settings was left on a page.
        let link = app.element(Settings.pageLink("appearance"))
        for _ in 0..<4 where !link.waitForExistence(timeout: 2) { goBack() }
        link.waitToExist(10, file: file, line: line)
    }

    private func openSettingsPage(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        openSettingsList(file: file, line: line)
        let link = app.element(Settings.pageLink(key))
        if !isOnScreen(link) { reveal(link) }
        link.padTap(file: file, line: line)
        app.element(Settings.pageRoot(key)).waitToExist(15, file: file, line: line)
    }

    private func toggle(_ id: String) -> XCUIElement {
        let control = app.switches[id]
        return control.exists ? control : app.element(id)
    }

    private func isOn(_ id: String) -> Bool { (toggle(id).value as? String) == "1" }

    private func setToggle(_ id: String, _ on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let control = toggle(id)
        XCTAssertTrue(reveal(control), "\(id) on the page", file: file, line: line)
        guard isOn(id) != on else { return }
        let inner = control.switches.firstMatch
        if inner.exists { inner.tap() } else { control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertTrue(waitUntil(5, "\(id) \(on ? "on" : "off")", file: file, line: line) { [self] in isOn(id) == on },
                      file: file, line: line)
    }

    /// Flips a switch and returns what it is now.
    @discardableResult
    private func flip(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        _ = reveal(toggle(id))
        let now = !isOn(id)
        setToggle(id, now, file: file, line: line)
        return now
    }

    private func choose(_ row: String, key: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.element(row)
        XCTAssertTrue(reveal(picker), "\(row) on the page", file: file, line: line)
        picker.padTap(file: file, line: line)
        tapMenuItem(Settings.option(row, key), label: label, file: file, line: line)
        XCTAssertTrue(waitUntil(5, "\(row) to read \(label)", file: file, line: line) { [self] in
            text(app.element(row)).contains(label)
        }, "reads \(text(app.element(row)))", file: file, line: line)
    }

    private func assertRow(_ row: String, reads label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.element(row)
        XCTAssertTrue(reveal(element), "\(row) on the page", file: file, line: line)
        XCTAssertTrue(text(element).contains(label), "\(row) reads \(text(element)), not \(label)", file: file, line: line)
    }

    private func relaunchKeepingState(file: StaticString = #filePath, line: UInt = #line) {
        app.terminate()
        launch(reset: false)
        app.element(TestID.Home.root).waitToExist(60, file: file, line: line)
    }

    // MARK: Kept across a relaunch

    func testSwitchesAndChoicesSurviveARelaunch() throws {
        launchHome()
        var expected: [(page: String, id: String, on: Bool)] = []

        openSettingsPage("appearance")
        expected.append(("appearance", Settings.nextUpRewatching, flip(Settings.nextUpRewatching)))
        expected.append(("appearance", Settings.nextUpInProgress, flip(Settings.nextUpInProgress)))
        choose(Settings.nextUpDays, key: "30", label: "1 month")

        openSettingsPage("video")
        expected.append(("video", Settings.videoResume, flip(Settings.videoResume)))
        expected.append(("video", Settings.videoAutoplayNext, flip(Settings.videoAutoplayNext)))

        openSettingsPage("audio")
        choose(Settings.audioLanguage, key: "fre,fra", label: "French")

        openSettingsPage("subtitles")
        choose(Settings.subtitlesLanguage, key: "off", label: "Never")

        openSettingsPage("music")
        expected.append(("music", Settings.musicAutoplay, flip(Settings.musicAutoplay)))
        expected.append(("music", Settings.musicNormalizeVolume, flip(Settings.musicNormalizeVolume)))
        expected.append(("music", Settings.musicLosslessOnCellular, flip(Settings.musicLosslessOnCellular)))
        expected.append(("music", Settings.musicRomanize, flip(Settings.musicRomanize)))
        choose(Settings.musicMixSource, key: "jellyfin", label: "Jellyfin Instant Mix")

        openSettingsPage("downloads")
        expected.append(("downloads", Settings.downloadsWifiOnly, flip(Settings.downloadsWifiOnly)))
        choose(Settings.downloadsQuality, key: "720p-4-5-mbps-transcoded", label: "720p · 4.5 Mbps (transcoded)")
        attachScreenshot("settings changed")

        relaunchKeepingState()
        var page = ""
        for row in expected {
            if row.page != page {
                openSettingsPage(row.page)
                page = row.page
                if page == "appearance" { assertRow(Settings.nextUpDays, reads: "1 month") }
                if page == "music" { assertRow(Settings.musicMixSource, reads: "Jellyfin Instant Mix") }
                if page == "downloads" { assertRow(Settings.downloadsQuality, reads: "720p") }
            }
            XCTAssertTrue(reveal(toggle(row.id)), "\(row.id) after the relaunch")
            XCTAssertEqual(isOn(row.id), row.on, "\(row.id) after the relaunch")
        }
        openSettingsPage("audio")
        assertRow(Settings.audioLanguage, reads: "French")
        openSettingsPage("subtitles")
        assertRow(Settings.subtitlesLanguage, reads: "Never")
        attachScreenshot("after the relaunch")
    }

    // MARK: Downloads

    /// Never below one at once nor above six, and the number is kept.
    func testDownloadsAtOnceStaysInItsRangeAndIsKept() throws {
        launchHome()
        openSettingsPage("downloads")
        let stepper = app.element(Settings.downloadsConcurrency)
        XCTAssertTrue(reveal(stepper))
        let shown = { () -> Int? in
            let value = self.app.element(Settings.value(Settings.downloadsConcurrency))
            let words = value.exists ? self.text(value) : self.text(stepper)
            return words.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.last
        }
        XCTAssertNotNil(shown(), "the stepper shows a number")
        let minus = app.steppers.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'decrement'")).firstMatch
        let plus = app.steppers.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'increment'")).firstMatch
        XCTAssertTrue(minus.waitForExistence(timeout: 10) && plus.exists, "the stepper's − and +")
        for _ in 0..<7 { minus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(eventually(5) { shown() == 1 }, "never below one: \(String(describing: shown()))")
        XCTAssertFalse(minus.isEnabled, "− is off at one")
        plus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(eventually(5) { shown() == 2 }, "one more: \(String(describing: shown()))")
        for _ in 0..<8 { plus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(eventually(5) { shown() == 6 }, "never above six: \(String(describing: shown()))")
        XCTAssertFalse(plus.isEnabled, "+ is off at six")
        minus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(eventually(5) { shown() == 5 })

        relaunchKeepingState()
        openSettingsPage("downloads")
        XCTAssertTrue(reveal(app.element(Settings.downloadsConcurrency)))
        XCTAssertTrue(eventually(10) { shown() == 5 }, "not kept across a relaunch: \(String(describing: shown()))")
    }

    // MARK: Video

    /// Resume off: Play starts at the beginning however far in the server
    /// says you are (the baseline's 5:00).
    func testResumeOffStartsFromTheBeginning() throws {
        let film = try fx.item("film.long_direct")
        let api = try api()
        try api.setResume(film.id, seconds: 300)
        launchHome()
        openSettingsPage("video")
        setToggle(Settings.videoResume, false)
        play(film.id)
        waitForPlaying()
        let at = elapsedSeconds() ?? 999
        XCTAssertLessThan(at, 60, "started at \(at) s with Resume off, not at the 5:00 resume point")
        var server: Double = -1
        XCTAssertTrue(eventually(60) {
            server = api.padPlaying(film.id)?.positionSeconds ?? -1
            return server >= 0
        }, "the server never heard the film play")
        XCTAssertLessThan(server, 60, "the server has it at \(server) s")
        closePlayer()
    }

    /// A rung chosen as the default quality is held for every stream, so the
    /// speed check (which picks a rung for you) is off until Auto is back.
    func testAQualityRungTurnsTheSpeedCheckOffAndAutoBringsItBack() throws {
        launchHome()
        openSettingsPage("video")
        let check = toggle(Settings.videoSpeedCheck)
        XCTAssertTrue(reveal(check))
        XCTAssertTrue(check.isEnabled, "the speed check can be set while the quality is Auto")
        choose(Settings.videoQuality, key: "5000000", label: "5 Mbps · 720p")
        XCTAssertTrue(waitUntil(5, "the speed check off") { [self] in !toggle(Settings.videoSpeedCheck).isEnabled })
        choose(Settings.videoQuality, key: "auto", label: "Auto")
        XCTAssertTrue(waitUntil(5, "the speed check back") { [self] in toggle(Settings.videoSpeedCheck).isEnabled })
    }

    // MARK: Home

    /// Appearance › Home › Hide Continue Watching takes the row off Home at
    /// once (Home answers from the same preference) and gives it back.
    func testHidingContinueWatchingTakesTheRowOffHome() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let resume = app.element(TestID.Home.shelf(TestID.Home.rowResume))
        XCTAssertTrue(reveal(resume), "the baseline has Continue Watching")

        openSettingsPage("appearance")
        setToggle(Settings.hideContinueWatching, true)
        showSection("home")
        let nextUp = app.element(TestID.Home.shelf(TestID.Home.rowNextUp))
        XCTAssertTrue(reveal(nextUp), "Home is drawn (its Next Up row)")
        XCTAssertFalse(resume.exists, "Continue Watching is still on Home")
        XCTAssertFalse(app.element(TestID.Home.shelf(TestID.Home.rowResume)).exists)
        attachScreenshot("home without continue watching")

        openSettingsPage("appearance")
        setToggle(Settings.hideContinueWatching, false)
        showSection("home")
        XCTAssertTrue(reveal(app.element(TestID.Home.shelf(TestID.Home.rowResume))), "Continue Watching back")
        XCTAssertTrue(cardButton(film.id).waitForExistence(timeout: 10), "with the film in progress on it")
    }

    // MARK: The list's own rows

    /// Watch Together's SyncPlay row reads Off with no group; iCloud's switch
    /// is off and can't be turned on in test mode (iCloud key-value sync is
    /// off there), and the footer says why.
    func testWatchTogetherAndICloudRowsInTheList() throws {
        launchHome()
        openSettingsList()
        let syncPlay = app.button(Settings.syncPlay)
        XCTAssertTrue(reveal(syncPlay), "a SyncPlay row")
        XCTAssertTrue(syncPlay.label.contains("SyncPlay"), syncPlay.label)
        XCTAssertTrue(syncPlay.label.contains("Off"), "no group yet: \(syncPlay.label)")
        XCTAssertTrue(app.staticTexts["WATCH TOGETHER"].exists || app.staticTexts["Watch Together"].exists,
                      "under a Watch Together heading")

        let cloud = toggle(Settings.cloudSync)
        XCTAssertTrue(reveal(cloud), "the iCloud row")
        XCTAssertTrue(cloud.label.contains("Sync settings with iCloud"), cloud.label)
        XCTAssertFalse(cloud.isEnabled, "iCloud is unavailable in test mode, so the switch is off")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Not signed in to iCloud on this device"))
                        .firstMatch.exists, "the footer says why")
        XCTAssertFalse(app.element(Settings.pageLink("watch")).exists, "the Apple Watch row is the iPhone's")
    }
}
#endif
