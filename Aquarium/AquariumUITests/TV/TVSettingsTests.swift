//  Settings on the Apple TV (Views/TVSettingsView.swift): every page opens
//  and gives focus back, the choice lists, the rows a TV must not offer,
//  and settings whose effect can be seen elsewhere in the app.

#if os(tvOS)
import XCTest

final class TVSettingsTests: TVTestCase {
    private func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        launchHome(file: file, line: line)
        openTab("settings", title: "Settings", anchor: TestID.Settings.root, file: file, line: line)
        Remote.press(.down)
        assertFocusPresent("Settings", file: file, line: line)
    }

    /// Moves the selector onto `id` and clicks it.
    private func choose(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.element(id)
        XCTAssertTrue(focusInColumn(target) || Remote.focus(on: target, in: app), "couldn't move focus onto \(id) (on \(focused?.summary ?? "nothing"))",
                      file: file, line: line)
        Remote.select()
    }

    private func openPage(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        choose(TestID.Settings.pageLink(page), file: file, line: line)
        app.element(TestID.Settings.pageRoot(page)).waitToExist(15, file: file, line: line)
        assertFocusPresent("Settings → \(page)", file: file, line: line)
    }

    private func back(to anchor: String, file: StaticString = #filePath, line: UInt = #line) {
        Remote.menu()
        app.element(anchor).waitToExist(10, file: file, line: line)
        assertFocusPresent("back on \(anchor)", file: file, line: line)
    }

    // MARK: Pages

    func testEveryPageOpensAndMenuComesBack() {
        openSettings()
        for page in ["account", "video", "audio", "subtitles", "liveTV", "libraryCopy", "about"] {
            openPage(page)
            attachScreenshot("settings \(page)")
            back(to: TestID.Settings.root)
            XCTAssertTrue(focusedID.hasPrefix("settings."), "focus after leaving \(page) went to \(focused?.summary ?? "nothing")")
        }
        XCTAssertTrue(focusTabStrip(max: 20), "Up from the first page never reached the tab strip")
    }

    func testThePanelDescribesTheFocusedRow() {
        openSettings()
        let title = app.element(TestID.TVSettings.panelTitle)
        title.waitToExist(10)
        XCTAssertTrue(Remote.focus(on: app.element(TestID.Settings.pageLink("video")), in: app))
        waitUntil("the panel to say Video", timeout: 5) { title.label == "Video" }
        XCTAssertTrue(Remote.focus(on: app.element(TestID.Settings.pageLink("about")), in: app))
        waitUntil("the panel to say About", timeout: 5) { title.label == "About" }
    }

    // MARK: Video

    func testDefaultQualityListsEveryRungAndKeepsTheChoice() {
        openSettings()
        openPage("video")
        choose(TestID.Settings.videoQuality)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        for value in ["nil", "Optional(36000000)", "Optional(20000000)", "Optional(16000000)",
                      "Optional(10000000)", "Optional(5000000)", "Optional(2500000)"] {
            XCTAssertTrue(app.element(TestID.TVSettings.choiceOption(value)).exists, "no \(value) in the quality list")
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Auto'")).firstMatch.exists,
                       "Auto is not offered on the TV (commit 5095d5e: nothing steers the TV's quality)")
        choose(TestID.TVSettings.choiceOption("Optional(5000000)"))
        app.element(TestID.Settings.pageRoot("video")).waitToExist(10)
        let row = app.element(TestID.Settings.videoQuality)
        waitUntil("the row to read 5 Mbps", timeout: 5) { row.label.contains("5 Mbps") }
        // Put it back for the rest of the suite.
        choose(TestID.Settings.videoQuality)
        choose(TestID.TVSettings.choiceOption("nil"))
    }

    func testNoEngineBatteryOrAdaptiveRows() {
        // The TV plays through mpv alone, on mains, with no Auto (c964e31
        // "tvOS Settings: … no adaptive switch").
        openSettings()
        openPage("video")
        for id in [TestID.Settings.videoEngine, TestID.Settings.videoBatterySaver, TestID.Settings.videoPowerAwareQuality,
                   TestID.Settings.videoSpeedCheck] {
            XCTAssertFalse(app.element(id).exists, "\(id) is offered on the TV")
        }
        for id in [TestID.Settings.videoFraming, TestID.Settings.videoBrightness, TestID.Settings.videoContrast,
                   TestID.Settings.videoSaturation, TestID.Settings.videoGamma, TestID.Settings.videoZoom,
                   TestID.Settings.videoAspect, TestID.Settings.videoResetPicture, TestID.Settings.videoResume,
                   TestID.Settings.videoAutoplayNext, TestID.Settings.audioLanguage] {
            XCTAssertTrue(app.element(id).exists, "\(id) missing from Video")
        }
    }

    func testNightModeIsNotOfferedWhereItCannotWork() {
        // Source: master-fix-list.md round 2, "[TV] Night mode offered as 'On'
        // in Settings but the mpv build can't do it"; fix-status.md: "TV Video
        // settings: row gone" — on claude/qa-fix-list-cb0b58, not merged here.
        // MPVKit's LGPL FFmpeg has no audio compressor (PLAYER-OVERHAUL-PLAN
        // phase 6), so the row can only ever lie.
        openSettings()
        openPage("video")
        XCTExpectFailure("bug: Settings → Video on tvOS still offers Night mode (Views/TVSettingsView.swift:286), which this mpv build refuses")
        XCTAssertFalse(app.element(TestID.Settings.videoNightMode).exists, "Night mode row offered")
    }

    func testPictureAdjustmentEnablesReset() {
        openSettings()
        openPage("video")
        let reset = app.element(TestID.Settings.videoResetPicture)
        XCTAssertFalse(reset.isEnabled, "nothing to reset on a clean launch")
        choose(TestID.Settings.videoGamma)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        choose(TestID.TVSettings.choiceOption("20.0"))  // a Double, as String(describing:) writes it
        app.element(TestID.Settings.pageRoot("video")).waitToExist(10)
        waitUntil("Reset picture to enable", timeout: 5) { reset.isEnabled }
        choose(TestID.Settings.videoResetPicture)
        waitUntil("Reset picture to disable again", timeout: 5) { !reset.isEnabled }
        XCTAssertTrue(app.element(TestID.Settings.videoGamma).label.contains("0"), app.element(TestID.Settings.videoGamma).label)
    }

    // MARK: Audio

    func testAudioHasADelayRowPerClipRate() {
        openSettings()
        openPage("audio")
        for fps in [24, 25, 30, 50, 60] {
            XCTAssertTrue(app.element(TestID.TVSettings.audioDelay(fps)).exists, "no \(fps) fps row")
        }
        XCTAssertTrue(app.element(TestID.Settings.audioDownmix).exists)
    }

    func testTheSyncClipWarnsBeforeFlashing() {
        // Regression (17206fe): "A 'Flashing images' alert before the audio
        // sync clip, every time."
        openSettings()
        openPage("audio")
        choose(TestID.TVSettings.audioDelay(24))
        app.element(TestID.TVSettings.syncTestCancel).waitToExist(10)
        XCTAssertTrue(app.element(TestID.TVSettings.syncTestPlay).exists)
        Remote.menu()
        XCTAssertTrue(app.element(TestID.TVSettings.syncTestPlay).waitToVanish(10))
        XCTAssertFalse(app.element(TestID.Player.root).exists, "cancelled, nothing plays")
        assertFocusPresent("Audio after cancelling the warning")
        choose(TestID.TVSettings.audioDelay(24))
        app.element(TestID.TVSettings.syncTestCancel).waitToExist(10)
    }

    // MARK: Subtitles, Live TV, Library copy, Account, About

    func testSubtitlePageRows() {
        openSettings()
        openPage("subtitles")
        for id in [TestID.Settings.subtitlesLanguage, TestID.Settings.subtitlesSize, TestID.Settings.subtitlesBackground] {
            XCTAssertTrue(app.element(id).exists, "\(id) missing")
        }
        choose(TestID.Settings.subtitlesLanguage)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        assertFocusPresent("the subtitle language list")
        Remote.menu()
        app.element(TestID.Settings.pageRoot("subtitles")).waitToExist(10)
    }

    func testLiveTVSourceChoices() {
        openSettings()
        openPage("liveTV")
        choose(TestID.Settings.liveTVSource)
        app.element(TestID.TVSettings.choiceList).waitToExist(10)
        XCTAssertTrue(app.element(TestID.TVSettings.choiceOption("jellyfin")).exists)
        XCTAssertTrue(app.element(TestID.TVSettings.choiceOption("custom")).exists)
        Remote.menu()
        app.element(TestID.Settings.pageRoot("liveTV")).waitToExist(10)
    }

    func testAccountPageSaysWhoAndWhere() {
        openSettings()
        openPage("account")
        let signedIn = app.element(TestID.Settings.accountSignedInAs)
        signedIn.waitToExist(10)
        XCTAssertTrue(signedIn.label.contains(QA.account()?.name ?? "suite-tv"), signedIn.label)
        XCTAssertTrue(app.element(TestID.Settings.accountServer).label.contains("127.0.0.1"), app.element(TestID.Settings.accountServer).label)
        XCTAssertTrue(app.element(TestID.Settings.signOut).exists)
    }

    func testSignOutDialogNamesTheAccount() {
        // Source: master-fix-list.md round 2, "[TV] Sign-out dialog names the
        // server, not the account".
        openSettings()
        openPage("account")
        choose(TestID.Settings.signOut)
        let cancel = app.element(TestID.Settings.signOutCancel)
        cancel.waitToExist(10)
        let name = QA.account()?.name ?? "suite-tv"
        let mentionsAccount = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists
            || app.alerts.firstMatch.label.contains(name)
            || app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists
        attachScreenshot("sign-out dialog")
        XCTAssertTrue(mentionsAccount, "the sign-out question doesn't name \(name)")
        Remote.menu()
        XCTAssertTrue(cancel.waitToVanish(10))
        XCTAssertTrue(app.element(TestID.Settings.pageRoot("account")).exists, "still signed in")
    }

    func testSignOutReturnsToTheSignInScreen() {
        openSettings()
        openPage("account")
        choose(TestID.Settings.signOut)
        app.element(TestID.Settings.signOutConfirm).waitToExist(10)
        choose(TestID.Settings.signOutConfirm)
        app.element(TestID.Shell.signedOut).waitToExist(20)
        assertFocusPresent("the sign-in screen after signing out")
    }

    func testAboutSaysMPV() {
        // c964e31: "About's playback engine … say mpv on tvOS".
        openSettings()
        openPage("about")
        let engine = app.element(TestID.Settings.aboutEngine)
        engine.waitToExist(10)
        XCTAssertTrue(engine.label.localizedCaseInsensitiveContains("mpv"), engine.label)
        XCTAssertFalse(app.element(TestID.Settings.aboutVersion).label.contains("1.0.0"), "the version read is the bundle's")
    }

    func testHideContinueWatchingTakesTheRowOffHome() {
        openSettings()
        let toggle = app.element(TestID.Settings.hideContinueWatching)
        XCTAssertTrue(toggle.label.hasSuffix("Off"), toggle.label)
        choose(TestID.Settings.hideContinueWatching)
        waitUntil("the toggle to read On", timeout: 5) { toggle.label.hasSuffix("On") }
        XCTAssertTrue(focusTabStrip(max: 25))
        openTab("home", title: "Home", anchor: TestID.Home.root)
        XCTAssertTrue(app.element(TestID.Home.shelf(TestID.Home.rowResume)).waitToVanish(15),
                      "Continue Watching is still on Home")
    }

    func testNoMusicPageOnTheTV() {
        // FEATURE-LIST.md: "Mac and Apple TV have no music … at all".
        openSettings()
        XCTAssertFalse(app.element(TestID.Settings.pageLink("music")).exists)
        XCTAssertFalse(app.element(TestID.Settings.pageLink("downloads")).exists, "nothing downloads to a TV")
        XCTAssertFalse(app.element(TestID.Settings.pageLink("watch")).exists)
    }
}
#endif
