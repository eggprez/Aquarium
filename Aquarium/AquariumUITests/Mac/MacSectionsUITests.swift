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
        let first = mark.label
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(eventually(10) { self.app.element(TestID.Guide.timeMark(0)).label != first }, "⌘→ is later")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(eventually(10) { self.app.element(TestID.Guide.timeMark(0)).label == first }, "⌘T is now")
        app.typeKey(.leftArrow, modifierFlags: .command)
        XCTAssertTrue(eventually(10) { self.app.element(TestID.Guide.timeMark(0)).label != first }, "⌘← is earlier")
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
        for id in [TestID.Guide.menuPlay, TestID.Guide.menuInfo, TestID.Guide.menuCopyTitle] {
            XCTAssertTrue(app.menuItems.matching(identifier: id).firstMatch.waitForExistence(timeout: 5)
                          || app.element(id).exists, id)
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
        XCTAssertNotNil(try api.waitForPlayback(timeout: 60))
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
        app.element(TestID.Detail.download).tapWhenReady()
        let original = app.element(TestID.Detail.downloadQuality("Original quality"))
        if original.waitForExistence(timeout: 5) { original.click() }
        app.typeKey("j", modifierFlags: [.command, .option])
        app.element(TestID.Downloads.root).waitToExist(20)
        let card = app.element(TestID.Downloads.filmCard(film.id))
        XCTAssertTrue(card.waitForExistence(timeout: 120), "the download finished")
        card.rightClick()
        app.menuItems.matching(identifier: TestID.Downloads.filmCardDelete(film.id)).firstMatch.tapWhenReady()
        app.button(TestID.Downloads.deletionConfirm).tapWhenReady()
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
        app.element(TestID.Settings.option(TestID.Settings.videoEngine, "mpv")).tapWhenReady()
        settingsWindow.toolbars.buttons["General"].tapWhenReady()
        XCTAssertTrue(app.element(TestID.Settings.aboutEngine).waitForExistence(timeout: 10))
        let text = app.element(TestID.Settings.aboutEngine)
        XCTAssertTrue((text.value as? String ?? text.label).contains("mpv"))
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

    /// Open: NightModeToggleDoesNothing — Settings ▸ Video still offers Night
    /// mode, which the Mac's mpv build can't act on (no dynaudnorm). The fix
    /// (c13b11a) is on an unmerged branch. Source: master fix list.
    func testBugNightModeToggleDoesNothing() {
        launchToHome()
        app.typeKey(",", modifierFlags: .command)
        settingsWindow.waitToExist(20)
        settingsWindow.toolbars.buttons["Video"].tapWhenReady()
        XCTExpectFailure("bug: Settings ▸ Video offers Night mode, which mpv on the Mac cannot apply (Views/SettingsView.swift:444-447)")
        XCTAssertFalse(app.element(TestID.Settings.videoNightMode).waitForExistence(timeout: 5))
    }
}
#endif
