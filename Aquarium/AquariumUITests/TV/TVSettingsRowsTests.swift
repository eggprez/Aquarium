//  Settings on the Apple TV, row by row (Views/TVSettingsView.swift): the
//  switches and choice lists `TVSettingsTests` only checks for existence,
//  what each writes back onto its row and the first page, what is kept over
//  a relaunch, and the rows that come and go with another setting.
//
//  `TVSettingsPagesCase` is how these (and `TVSettingsEffectTests`,
//  `TVRequestsSettingsTests`) get about in Settings: the same walk
//  `TVSettingsTests` does privately. It sits on the player's test case so a
//  test can set something in Settings and then watch what the player does.

#if os(tvOS)
import XCTest

class TVSettingsPagesCase: TVPlayerTestCase {
    /// Home, then the Settings tab with the selector in its rows.
    func enterSettings(file: StaticString = #filePath, line: UInt = #line) {
        openTab("settings", title: "Settings", anchor: TestID.Settings.root, file: file, line: line)
        Remote.press(.down)
        assertFocusPresent("Settings", file: file, line: line)
    }

    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        launchHome(file: file, line: line)
        enterSettings(file: file, line: line)
    }

    /// Moves the selector onto `id` and clicks it.
    func choose(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.element(id)
        XCTAssertTrue(focusInColumn(target) || Remote.focus(on: target, in: app),
                      "couldn't move focus onto \(id) (on \(focused?.summary ?? "nothing"))", file: file, line: line)
        Remote.select()
    }

    func openPage(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        choose(TestID.Settings.pageLink(page), file: file, line: line)
        app.element(TestID.Settings.pageRoot(page)).waitToExist(15, file: file, line: line)
        assertFocusPresent("Settings → \(page)", file: file, line: line)
    }

    func back(to anchor: String, file: StaticString = #filePath, line: UInt = #line) {
        Remote.menu()
        app.element(anchor).waitToExist(10, file: file, line: line)
        assertFocusPresent("back on \(anchor)", file: file, line: line)
    }

    /// Opens a choice row's list, clicks the option whose value is written
    /// `value` (as `String(describing:)` writes it), and waits to be back on
    /// the page the row is on.
    func pick(_ row: String, option value: String, backOn anchor: String,
              file: StaticString = #filePath, line: UInt = #line) {
        choose(row, file: file, line: line)
        app.element(TestID.TVSettings.choiceList).waitToExist(10, file: file, line: line)
        XCTAssertTrue(app.element(TestID.TVSettings.choiceOption(value)).waitForExistence(timeout: 10),
                      "no option \(value) in the list \(row) opens", file: file, line: line)
        choose(TestID.TVSettings.choiceOption(value), file: file, line: line)
        app.element(anchor).waitToExist(10, file: file, line: line)
    }

    /// Clicks a switch row and waits for it to read the other way. Returns
    /// whether it is now on.
    @discardableResult
    func flip(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let row = app.element(id)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(id)", file: file, line: line)
        let wasOn = row.label.hasSuffix("On")
        XCTAssertTrue(wasOn || row.label.hasSuffix("Off"), "\(id) reads neither On nor Off: \(row.label)", file: file, line: line)
        choose(id, file: file, line: line)
        waitUntil("\(id) to read \(wasOn ? "Off" : "On")", timeout: 5, file: file, line: line) {
            row.label.hasSuffix(wasOn ? "Off" : "On")
        }
        return !wasOn
    }
}

final class TVSettingsRowsTests: TVSettingsPagesCase {
    // MARK: The first page

    func testGeneralSwitchesFlipAndAreKeptOverARelaunch() {
        openSettings()
        let ids = [TestID.Settings.clearAbandoned, TestID.Settings.nextUpInProgress, TestID.Settings.nextUpRewatching]
        var now: [String: Bool] = [:]
        for id in ids { now[id] = flip(id) }
        // The same app again, keeping what it wrote.
        launch(reset: false)
        app.element(TestID.Home.root).waitToExist(60)
        assertFocusPresent("Home after the relaunch")
        enterSettings()
        for id in ids {
            let row = app.element(id)
            row.waitToExist(10)
            XCTAssertTrue(row.label.hasSuffix(now[id] == true ? "On" : "Off"), "\(id) didn't keep its setting: \(row.label)")
        }
    }

    func testNextUpWindowListsItsChoicesAndKeepsOne() {
        openSettings()
        let row = app.element(TestID.Settings.nextUpDays)
        row.waitToExist(10)
        XCTAssertTrue(row.label.contains("Forever"), "a clean launch keeps shows on Next Up forever: \(row.label)")
        choose(TestID.Settings.nextUpDays)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        for days in [0, 7, 14, 30, 90, 180, 365] {
            XCTAssertTrue(app.element(TestID.TVSettings.choiceOption(String(days))).exists, "no \(days)-day choice")
        }
        choose(TestID.TVSettings.choiceOption("30"))
        app.element(TestID.Settings.root).waitToExist(10)
        waitUntil("the row to read 1 month", timeout: 5) { row.label.contains("1 month") }
        assertFocusPresent("Settings after choosing")
    }

    func testTheICloudRowIsASwitchOrSaysUnavailable() {
        // One or the other, never both and never neither: a switch where the
        // Apple TV's user has iCloud, a fact where it hasn't (the simulator).
        openSettings()
        let toggle = app.element(TestID.Settings.cloudSync)
        let unavailable = app.element(TestID.Settings.cloudUnavailable)
        XCTAssertNotEqual(toggle.exists, unavailable.exists, "the iCloud row is both or neither")
        if unavailable.exists {
            XCTAssertTrue(unavailable.label.contains("Unavailable"), unavailable.label)
        } else {
            XCTAssertTrue(toggle.label.hasSuffix("On") || toggle.label.hasSuffix("Off"), toggle.label)
        }
    }

    func testTheFirstPageSaysWhereEachPageStands() {
        // Each row of the first page carries its page's summary in grey.
        openSettings()
        let name = QA.account()?.name ?? "suite-tv"
        let account = app.element(TestID.Settings.pageLink("account"))
        XCTAssertTrue(account.label.contains(name), account.label)
        XCTAssertTrue(account.label.contains("Connected"), account.label)
        let about = app.element(TestID.Settings.pageLink("about"))
        XCTAssertTrue(about.label.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil, "About shows no version: \(about.label)")
        XCTAssertFalse(app.element(TestID.Settings.pageLink("audio")).label.contains("Stereo"), "no downmix on a clean launch")
    }

    // MARK: Account

    func testAccountPageGivesTheConnectionFacts() {
        openSettings()
        openPage("account")
        let connection = app.element(TestID.Settings.accountConnection)
        connection.waitToExist(10)
        let secure = QA.server.lowercased().hasPrefix("https")
        XCTAssertTrue(connection.label.hasSuffix(secure ? "HTTPS" : "HTTP"), connection.label)
        XCTAssertTrue(app.element(TestID.Settings.accountStatus).label.contains("Connected"),
                      app.element(TestID.Settings.accountStatus).label)
        XCTAssertTrue(app.element(TestID.Settings.accountIdentity).exists)
        XCTAssertTrue(app.element(TestID.Settings.accountAccessToken).exists)
        XCTAssertFalse(app.element(TestID.Settings.accountNotConnected).exists)
    }

    func testTheAccountsListHasThisAccountAndClickingItAsksNothing() {
        openSettings()
        openPage("account")
        let name = QA.account()?.name ?? "suite-tv"
        let rows = app.elements(prefix: "settings.accounts.account.")
        waitUntil("the accounts list", timeout: 10) { rows.count >= 1 }
        XCTAssertEqual(rows.count, 1, "a clean launch has one account")
        let mine = rows.firstMatch
        XCTAssertTrue(mine.label.contains(name), mine.label)
        // The account in use has nothing to switch to or sign out of here.
        choose(mine.identifier)
        XCTAssertFalse(app.element(TestID.TVSettings.accountActionsCancel).waitForExistence(timeout: 3),
                       "the current account opened the switch dialog")
        XCTAssertTrue(app.element(TestID.Settings.pageRoot("account")).exists)
        assertFocusPresent("Account after clicking the current account")
    }

    func testAddAccountOpensSignInAndCancelComesBack() {
        openSettings()
        openPage("account")
        choose(TestID.Settings.addAccount)
        app.element(TestID.Login.root).waitToExist(15)
        assertFocusPresent("the add-account sign-in")
        let cancel = app.button(TestID.Login.cancel)
        cancel.waitToExist(10)
        XCTAssertTrue(focusInColumn(cancel) || Remote.focus(on: cancel, in: app),
                      "can't reach Cancel (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        XCTAssertTrue(app.element(TestID.Login.root).waitToVanish(10), "Cancel left the sign-in screen up")
        app.element(TestID.Settings.pageRoot("account")).waitToExist(10)
        XCTAssertTrue(app.element(TestID.Settings.accountSignedInAs).label.contains(QA.account()?.name ?? "suite-tv"),
                      "still signed in as before")
        assertFocusPresent("Account after cancelling Add Account")
    }

    func testSyncPlayInSettingsAsksWhichGroupAndMenuLeavesItOff() {
        // Settings → Account → SyncPlay…, with nothing playing: the question
        // is put by the shell (`SyncPlayPrompt(whilePlaying: false)`).
        openSettings()
        openPage("account")
        let row = app.element(TestID.Settings.syncPlay)
        row.waitToExist(10)
        XCTAssertTrue(row.label.contains("Off"), row.label)
        choose(TestID.Settings.syncPlay)
        let new = app.buttons[TestID.Player.syncPlayNew].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 30), "SyncPlay never asked which group")
        XCTAssertTrue(app.buttons[TestID.Player.syncPlayCancel].firstMatch.exists)
        attachScreenshot("SyncPlay from Settings")
        Remote.menu()
        XCTAssertTrue(new.waitToVanish(10), "Menu left the question up")
        XCTAssertTrue(row.label.contains("Off"), "no group was joined: \(row.label)")
        XCTAssertFalse(app.element(TestID.Player.root).exists)
        assertFocusPresent("Account after the SyncPlay question")
    }

    // MARK: Video

    func testFramingChoiceShowsOnItsRowAndOnTheFirstPage() {
        openSettings()
        openPage("video")
        let row = app.element(TestID.Settings.videoFraming)
        XCTAssertTrue(row.label.contains("Fit"), row.label)
        pick(TestID.Settings.videoFraming, option: "true", backOn: TestID.Settings.pageRoot("video"))
        waitUntil("the row to read Fill", timeout: 5) { row.label.contains("Fill") }
        back(to: TestID.Settings.root)
        let link = app.element(TestID.Settings.pageLink("video"))
        waitUntil("Video's summary to say Fill", timeout: 5) { link.label.contains("Fill") }
    }

    func testResumeAndAutoplaySwitchesFlip() {
        openSettings()
        openPage("video")
        XCTAssertTrue(app.element(TestID.Settings.videoResume).label.hasSuffix("On"), "resume is on by default")
        XCTAssertFalse(flip(TestID.Settings.videoResume))
        XCTAssertTrue(flip(TestID.Settings.videoResume))
        let autoplay = flip(TestID.Settings.videoAutoplayNext)
        XCTAssertNotEqual(flip(TestID.Settings.videoAutoplayNext), autoplay)
        assertFocusPresent("Video after the switches")
    }

    func testAudioLanguageListStartsWithTheFilesOwnAndKeepsAChoice() {
        openSettings()
        openPage("video")
        choose(TestID.Settings.audioLanguage)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        // "" is the file's own order; then the languages by their codes.
        for code in ["", "eng", "fre,fra", "jpn"] {
            XCTAssertTrue(app.element(TestID.TVSettings.choiceOption(code)).exists, "no '\(code)' in the audio languages")
        }
        XCTAssertFalse(app.element(TestID.TVSettings.choiceOption("off")).exists, "audio has no 'never'")
        choose(TestID.TVSettings.choiceOption("jpn"))
        app.element(TestID.Settings.pageRoot("video")).waitToExist(10)
        let row = app.element(TestID.Settings.audioLanguage)
        waitUntil("the row to read Japanese", timeout: 5) { row.label.contains("Japanese") }
    }

    func testZoomAndAspectAreListedAndResetPutsThemBack() {
        openSettings()
        openPage("video")
        let video = TestID.Settings.pageRoot("video")
        let reset = app.element(TestID.Settings.videoResetPicture)
        let zoom = app.element(TestID.Settings.videoZoom)
        let aspect = app.element(TestID.Settings.videoAspect)
        XCTAssertFalse(reset.isEnabled, "nothing to reset on a clean launch")
        XCTAssertTrue(zoom.label.contains("None"), zoom.label)
        XCTAssertTrue(aspect.label.contains("File's own"), aspect.label)
        // The options are named by their values, as the list writes them.
        pick(TestID.Settings.videoZoom, option: String(describing: 1 + Double(5) / 10), backOn: video)
        waitUntil("zoom to read 1.5×", timeout: 5) { zoom.label.contains("1.5") }
        waitUntil("Reset picture to enable", timeout: 5) { reset.isEnabled }
        pick(TestID.Settings.videoAspect, option: String(describing: 16.0 / 9), backOn: video)
        waitUntil("aspect to read 16:9", timeout: 5) { aspect.label.contains("16:9") }
        choose(TestID.Settings.videoResetPicture)
        waitUntil("zoom back to None", timeout: 5) { zoom.label.contains("None") }
        XCTAssertTrue(aspect.label.contains("File's own"), aspect.label)
        waitUntil("Reset picture to disable again", timeout: 5) { !reset.isEnabled }
    }

    // MARK: Audio

    func testStereoDownmixShowsOnTheFirstPage() {
        openSettings()
        openPage("audio")
        XCTAssertTrue(flip(TestID.Settings.audioDownmix), "downmix is off on a clean launch")
        back(to: TestID.Settings.root)
        let link = app.element(TestID.Settings.pageLink("audio"))
        waitUntil("Audio's summary to say Stereo", timeout: 5) { link.label.contains("Stereo") }
    }

    func testEveryDelayRowReadsInStepOnACleanLaunch() {
        openSettings()
        openPage("audio")
        for fps in [24, 25, 30, 50, 60] {
            let row = app.element(TestID.TVSettings.audioDelay(fps))
            row.waitToExist(10)
            XCTAssertTrue(row.label.contains("\(fps) fps"), "the \(fps) fps row doesn't name its rate: \(row.label)")
            XCTAssertTrue(row.label.contains("In step"), "a delay is set on a clean launch: \(row.label)")
        }
    }

    // MARK: Subtitles

    func testSubtitleSizeBackgroundLanguageAndForcedOnly() {
        openSettings()
        openPage("subtitles")
        let page = TestID.Settings.pageRoot("subtitles")
        flip(TestID.Settings.subtitlesForcedOnly)
        let size = app.element(TestID.Settings.subtitlesSize)
        choose(TestID.Settings.subtitlesSize)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        for value in [60.0, 80.0, 100.0, 120.0, 150.0, 180.0] {
            XCTAssertTrue(app.element(TestID.TVSettings.choiceOption(String(describing: value))).exists, "no \(Int(value))% size")
        }
        choose(TestID.TVSettings.choiceOption(String(describing: 150.0)))
        app.element(page).waitToExist(10)
        waitUntil("size to read 150%", timeout: 5) { size.label.contains("150%") }
        let background = app.element(TestID.Settings.subtitlesBackground)
        pick(TestID.Settings.subtitlesBackground, option: "box", backOn: page)
        waitUntil("background to read Solid strip", timeout: 5) { background.label.contains("Solid strip") }
        // Language: the file's own, never, forced only, then the languages.
        choose(TestID.Settings.subtitlesLanguage)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        for code in ["", "off", "forced", "eng"] {
            XCTAssertTrue(app.element(TestID.TVSettings.choiceOption(code)).exists, "no '\(code)' in the subtitle languages")
        }
        choose(TestID.TVSettings.choiceOption("off"))
        app.element(page).waitToExist(10)
        back(to: TestID.Settings.root)
        let link = app.element(TestID.Settings.pageLink("subtitles"))
        waitUntil("Subtitles' summary to say Never", timeout: 5) { link.label.contains("Never") }
    }

    func testAChoiceListOpensOnTheCurrentChoice() {
        // `SettingChoiceList.defaultFocus`: the selector starts on the tick,
        // not at the top of the list.
        openSettings()
        openPage("subtitles")
        let chosen = String(describing: 150.0)
        pick(TestID.Settings.subtitlesSize, option: chosen, backOn: TestID.Settings.pageRoot("subtitles"))
        choose(TestID.Settings.subtitlesSize)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        let current = app.element(TestID.TVSettings.choiceOption(chosen))
        current.waitToExist(10)
        waitUntil("the list to open on 150%", timeout: 10) { [weak self] in self?.isFocused(on: current) ?? false }
        Remote.menu()
        app.element(TestID.Settings.pageRoot("subtitles")).waitToExist(10)
        assertFocusPresent("Subtitles after leaving the list")
    }

    // MARK: Live TV

    func testACustomSourceBringsThePlaylistRowsAndTheServerTakesThemAway() {
        openSettings()
        openPage("liveTV")
        let page = TestID.Settings.pageRoot("liveTV")
        let playlistRows = [TestID.Settings.liveTVPlaylistURL, TestID.Settings.liveTVGuideURL, TestID.Settings.liveTVUserAgent,
                            TestID.Settings.liveTVRefreshInterval, TestID.Settings.liveTVArtworkCheck]
        for id in playlistRows { XCTAssertFalse(app.element(id).exists, "\(id) shown for the server's tuner") }
        XCTAssertTrue(app.element(TestID.Settings.liveTVRefreshNow).exists)

        pick(TestID.Settings.liveTVSource, option: "custom", backOn: page)
        for id in playlistRows { XCTAssertTrue(app.element(id).waitForExistence(timeout: 10), "\(id) missing for a playlist") }
        XCTAssertTrue(app.element(TestID.Settings.liveTVPlaylistURL).label.contains("Not set"),
                      app.element(TestID.Settings.liveTVPlaylistURL).label)
        XCTAssertTrue(app.element(TestID.Settings.liveTVUserAgent).label.contains("Default"),
                      app.element(TestID.Settings.liveTVUserAgent).label)
        attachScreenshot("Live TV, custom playlist")

        // A text row asks with the system's keyboard alert; Menu leaves it unset.
        choose(TestID.Settings.liveTVPlaylistURL)
        let save = app.element(TestID.TVSettings.textEntrySave)
        XCTAssertTrue(save.waitForExistence(timeout: 10), "the playlist row didn't ask for an address")
        XCTAssertTrue(app.element(TestID.TVSettings.textEntryCancel).exists)
        Remote.menu()
        if save.exists { Remote.menu() }  // the keyboard first, then the alert
        XCTAssertTrue(save.waitToVanish(10))
        XCTAssertTrue(app.element(TestID.Settings.liveTVPlaylistURL).label.contains("Not set"), "Menu saved something")
        assertFocusPresent("Live TV after cancelling the address")

        pick(TestID.Settings.liveTVSource, option: "jellyfin", backOn: page)
        for id in playlistRows { XCTAssertTrue(app.element(id).waitToVanish(10), "\(id) still shown for the server's tuner") }
    }

    func testCheckingArtworkWithNoPlaylistSaysThereAreNoChannels() {
        openSettings()
        openPage("liveTV")
        pick(TestID.Settings.liveTVSource, option: "custom", backOn: TestID.Settings.pageRoot("liveTV"))
        choose(TestID.Settings.liveTVArtworkCheck)
        let empty = app.element(TestID.Settings.liveTVArtworkEmpty)
        XCTAssertTrue(empty.waitForExistence(timeout: 20), "the check said nothing")
        XCTAssertTrue(empty.label.contains("No channels"), empty.label)
        let check = app.element(TestID.Settings.liveTVArtworkCheck)
        waitUntil("the row to offer the check again", timeout: 10) { check.label.contains("again") }
    }

    func testRefreshNowSaysItIsRefreshing() {
        openSettings()
        openPage("liveTV")
        choose(TestID.Settings.liveTVRefreshNow)
        let toast = app.element(TestID.Shell.toastText)
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "Refresh now said nothing")
        XCTAssertTrue(toast.label.contains("Refreshing Live TV"), toast.label)
        assertFocusPresent("Live TV after Refresh now")
    }

    // MARK: Library copy

    func testKeepingALibraryCopySyncsItAndDeleteEmptiesIt() {
        openSettings()
        openPage("libraryCopy")
        let status = app.element(TestID.Settings.libraryCopyStatus)
        let contents = app.element(TestID.Settings.libraryCopyContents)
        XCTAssertFalse(status.exists, "a copy is kept on a clean launch")
        XCTAssertTrue(flip(TestID.Settings.libraryCopyKeep))
        for id in [TestID.Settings.libraryCopyStatus, TestID.Settings.libraryCopyContents,
                   TestID.Settings.libraryCopySyncNow, TestID.Settings.libraryCopyDelete] {
            XCTAssertTrue(app.element(id).waitForExistence(timeout: 10), "\(id) missing while a copy is kept")
        }
        func holdsNothing() -> Bool {
            contents.label.range(of: #"(^|[^0-9,.])0 items"#, options: .regularExpression) != nil
        }
        waitUntil("the first sync to finish", timeout: 240) { status.label.contains("Synced") }
        XCTAssertFalse(holdsNothing(), "synced, and nothing saved: \(contents.label)")
        attachScreenshot("library copy synced")
        choose(TestID.Settings.libraryCopyDelete)
        waitUntil("the copy to be emptied", timeout: 15) { holdsNothing() }
        assertFocusPresent("Library copy after Delete")
        XCTAssertFalse(flip(TestID.Settings.libraryCopyKeep))
        XCTAssertTrue(status.waitToVanish(10), "the status row stayed with the switch off")
    }
}
#endif
