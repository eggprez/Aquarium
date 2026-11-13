//  The Mac's other sections and its Settings window: Live TV and the guide,
//  Downloads, Music (absent on the Mac for now), and Settings (⌘,).

#if os(macOS)
import XCTest

final class MacSectionsUITests: MacUITestCase {
    private func fixtures() throws -> Fixtures { try Fixtures.require() }

    private var channels: [(id: String, name: String)] {
        let live = (Fixtures.shared?.raw["existing"] as? [String: Any])?["liveTv"] as? [String: Any]
        return (live?["channels"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return (id, name)
        }
    }

    // MARK: Live TV and the guide

    func testGuideShowsTheQAChannels() throws {
        guard let first = channels.first else { throw XCTSkip("no live TV in fixtures.json") }
        launchToHome()
        openSection("livetv")
        app.element(TestID.Guide.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Guide.channel(first.id)).waitForExistence(timeout: 30))
        XCTAssertTrue(app.element(TestID.Guide.timeMark(0)).exists, "the pinned ruler")
        attachScreenshot("guide")
    }

    /// Regression: GuideRulerRuns90MinAhead — the ruler's first mark sits
    /// over the start of the programme rows, not ~546 pt to the left.
    /// Source: commit ac3e1c7; Views/TVGuideView.swift:533-555.
    func testBugGuideRulerRuns90MinAhead() throws {
        guard let first = channels.first else { throw XCTSkip("no live TV") }
        launchToHome()
        openSection("livetv")
        let mark = app.element(TestID.Guide.timeMark(0))
        mark.waitToExist(30)
        let channel = app.element(TestID.Guide.channel(first.id))
        channel.waitToExist(30)
        XCTAssertGreaterThanOrEqual(mark.frame.minX, channel.frame.maxX - 2, "the ruler starts where the programmes do")
    }

    func testGuideEarlierLaterNow() throws {
        launchToHome()
        openSection("livetv")
        app.element(TestID.Guide.root).waitToExist(30)
        let mark = app.element(TestID.Guide.timeMark(0))
        mark.waitToExist(30)
        // A Text's words are its value on a Mac, not its label.
        func firstMark() -> String {
            let m = app.element(TestID.Guide.timeMark(0))
            return (m.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? m.label
        }
        let first = firstMark()
        XCTAssertFalse(first.isEmpty)
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(eventually(10) { firstMark() != first }, "⌘→ is later")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(eventually(10) { firstMark() == first }, "⌘T is now")
        app.typeKey(.leftArrow, modifierFlags: .command)
        XCTAssertTrue(eventually(10) { firstMark() != first }, "⌘← is earlier")
    }

    func testProgrammePopoverAndContextMenu() throws {
        guard let first = channels.first else { throw XCTSkip("no live TV") }
        launchToHome()
        openSection("livetv")
        let cell = app.elements(prefix: "guide.programme.cell.").firstMatch
        cell.waitToExist(30)
        cell.click()
        app.element(TestID.Guide.info).waitToExist(10)
        XCTAssertTrue(app.element(TestID.Guide.infoPlay).exists)
        app.typeKey(.escape, modifierFlags: [])
        app.element(TestID.Guide.channel(first.id)).rightClick()
        for (id, title) in [(TestID.Guide.menuPlay, "Play Channel"), (TestID.Guide.menuInfo, "Show Info"),
                            (TestID.Guide.menuCopyTitle, "Copy Title")] {
            XCTAssertTrue(menuChoice(id, title: title).exists, title)
        }
        dismissMenus()   // Copy Title is left alone: it writes the shared clipboard.
    }

    func testPlayAChannel() throws {
        guard let first = channels.first else { throw XCTSkip("no live TV") }
        let api = try JellyfinAPI.signIn()
        launchToHome()
        openSection("livetv")
        app.element(TestID.Guide.channel(first.id)).waitToExist(30)
        app.element(TestID.Guide.channel(first.id)).doubleClick()
        playerWindow.waitToExist(60)
        XCTAssertNotNil(try api.macWaitForPlayback(timeout: 60))
        focusPlayerWindow()
        // Live: no Speed and no Slower/Faster.
        XCTAssertFalse(menuItem("Playback", id: TestID.Player.menuSlower, title: "Slower").isEnabled)
        dismissMenus()
    }

    func testTypeToSelectAChannel() throws {
        guard channels.count > 1, let second = channels.dropFirst().first else { throw XCTSkip("one channel") }
        launchToHome()
        openSection("livetv")
        app.element(TestID.Guide.root).waitToExist(30)
        app.element(TestID.Guide.channel(second.id)).waitToExist(30)
        app.element(TestID.Guide.root).click()
        app.typeText(second.name.lowercased())
        attachScreenshot("typed \(second.name)")
    }

    // MARK: Downloads

    func testDownloadsPageWhenEmpty() {
        launchToHome()
        openSection("downloads")
        app.element(TestID.Downloads.root).waitToExist(20)
        XCTAssertTrue(app.element(TestID.Downloads.empty).waitForExistence(timeout: 10)
                      || app.element(TestID.Downloads.list).exists)
    }

    /// F:film.rated_g — 20 s, direct download. Download it, see it finish on
    /// the Downloads page with the Dock badge gone, then delete it (confirmed).
    func testDownloadPlayAndDelete() throws {
        let film = try fixtures().item("film.rated_g")
        launchToHome()
        openTitle(named: film.name, id: film.id)
        clickCentre(app.element(TestID.Detail.download))
        // Chosen by typing its title: this pop-up menu's items aren't in
        // XCUITest's tree (see `openAccountMenu`), and on a Mac the title
        // carries the size ("Original quality — About 2.0 MiB").
        chooseInOpenMenu(typing: "Original quality")
        app.typeKey("j", modifierFlags: [.command, .option])
        app.element(TestID.Downloads.root).waitToExist(20)
        let card = app.element(TestID.Downloads.filmCard(film.id))
        XCTAssertTrue(card.waitForExistence(timeout: 120), "the download finished")
        card.rightClick()
        menuChoice(TestID.Downloads.filmCardDelete(film.id), title: "Delete…").click()
        // On a Mac the question is an alert (`downloadDeletionDialog`), and an
        // alert's buttons don't keep SwiftUI identifiers ("action-button-1"):
        // its Delete by title.
        app.sheets.buttons["Delete"].firstMatch.tapWhenReady()
        XCTAssertTrue(card.waitToVanish(20))
    }

    func testDownloadsManageMenu() {
        launchToHome()
        openSection("downloads")
        let manage = app.element(TestID.Downloads.manageMenu)
        guard manage.waitForExistence(timeout: 10) else { return }   // shown only with something to manage
        manage.click()
        XCTAssertTrue(app.element(TestID.Downloads.manageDeleteAll).waitForExistence(timeout: 5))
        dismissMenus()
    }

    // MARK: Music

    /// The Mac has no Music section yet (`AppModel.hasMusic` is iOS-only):
    /// the music libraries are not sidebar rows.
    func testNoMusicSectionOnTheMac() throws {
        let music = try fixtures().libraryId("Fixture Music")
        launchToHome()
        XCTAssertFalse(sidebarRow("music").exists)
        XCTAssertFalse(sidebarRow("lib-\(music)").exists)
    }

    // MARK: Settings

    func testSettingsWindowOpensWithCommandComma() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        for pane in ["General", "Account", "Video", "Audio", "Subtitles", "Live TV", "Storage"] {
            let tab = settingsWindow.toolbars.buttons[pane]
            XCTAssertTrue(tab.exists, pane)
        }
        attachScreenshot("settings")
    }

    func testEverySettingsPaneOpens() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        for (pane, id) in [("Video", "video"), ("Audio", "audio"), ("Subtitles", "subtitles"),
                           ("Live TV", "liveTV"), ("Account", "account"), ("General", "general")] {
            settingsWindow.toolbars.buttons[pane].tapWhenReady()
            XCTAssertTrue(app.element(TestID.Settings.pageRoot(id)).waitForExistence(timeout: 10), pane)
        }
    }

    func testVideoSettingsChangeTheEngine() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["Video"].tapWhenReady()
        let engine = app.element(TestID.Settings.videoEngine)
        engine.tapWhenReady()
        menuChoice(TestID.Settings.option(TestID.Settings.videoEngine, "mpv"), title: "mpv").click()
        app.typeKey("w", modifierFlags: .command)
        // The Mac shows the engine in the About panel (Settings has no About page).
        chooseMenu("Aquarium", id: TestID.MacMenu.about, title: "About Aquarium")
        let credits = app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'Playback engine'")).firstMatch
        XCTAssertTrue(credits.waitForExistence(timeout: 10))
        XCTAssertTrue((credits.value as? String ?? "").hasPrefix("Playback engine: mpv"), credits.value as? String ?? "")
        app.typeKey("w", modifierFlags: .command)
    }

    func testSettingsSignOutAsks() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["Account"].tapWhenReady()
        app.element(TestID.Settings.signOut).tapWhenReady()
        app.button(TestID.Settings.signOutCancel).tapWhenReady()
        XCTAssertTrue(app.element(TestID.Home.root).exists)
    }

    /// Regression: AddAccountSheetOpensBehindSettings. Account ▸ + brings the
    /// main window forward with the sign-in sheet on it. Source: commit
    /// a016c37; Views/SettingsView.swift:1906.
    func testBugAddAccountSheetOpensBehindSettings() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["Account"].tapWhenReady()
        app.element(TestID.Settings.addAccount).tapWhenReady()
        app.element(TestID.Login.root).waitToExist(20)
        XCTAssertTrue(app.element(TestID.Login.root).isHittable, "the sheet is in front, not behind Settings")
        app.button(TestID.Login.cancel).tapWhenReady()
    }

    /// Regression: NightModeToggleDoesNothing — Settings ▸ Video offered Night
    /// mode, which neither engine on a Mac can act on (AVPlayer has no
    /// compressor; MPVKit's FFmpeg has no dynaudnorm). Source: master fix
    /// list; Views/SettingsView.swift `pictureSection`.
    func testBugNightModeToggleDoesNothing() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["Video"].tapWhenReady()
        XCTAssertTrue(app.element(TestID.Settings.videoFraming).waitForExistence(timeout: 10), "the Video pane is showing")
        XCTAssertFalse(app.element(TestID.Settings.videoNightMode).waitForExistence(timeout: 5))
    }
}
#endif
