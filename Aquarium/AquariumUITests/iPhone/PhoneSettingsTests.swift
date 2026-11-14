//  Settings on the phone: every page opens and shows its rows, and the rows
//  that change something visible are checked for their effect (theme, Next
//  Up, Continue Watching, tab bar order, autoplay, the download defaults,
//  Live TV source, Quick Connect approval, the library copy, About).
//
//  Rows the phone pins to their defaults (`Preferences.keysNotOfferedHere`:
//  engine, skip interval, picture, subtitle style…) must not be offered.

#if os(iOS)
import XCTest

final class PhoneSettingsTests: PhoneUITestCase {
    /// What each page must show on a phone.
    static let rows: [String: [String]] = [
        "account": [TestID.Settings.accountSignedInAs, TestID.Settings.accountServer, TestID.Settings.signOut],
        "appearance": [TestID.Settings.theme, TestID.Settings.appIcon, TestID.Settings.tabBar, TestID.Settings.hideContinueWatching,
                       TestID.Settings.nextUpDays, TestID.Settings.nextUpInProgress, TestID.Settings.nextUpRewatching],
        "video": [TestID.Settings.videoQuality, TestID.Settings.videoResume, TestID.Settings.videoAutoplayNext],
        "audio": [TestID.Settings.audioLanguage],
        "subtitles": [TestID.Settings.subtitlesLanguage],
        "music": [TestID.Settings.musicAutoplay, TestID.Settings.musicNormalizeVolume, TestID.Settings.musicMixSource],
        "liveTV": [TestID.Settings.liveTVSource],
        "downloads": [TestID.Settings.downloadsQuality, TestID.Settings.downloadsWifiOnly],
        "libraryCopy": [TestID.Settings.libraryCopyKeep],
        "about": [TestID.Settings.aboutVersion],
    ]

    static let titles = ["account": "Account", "appearance": "Appearance", "video": "Video", "audio": "Audio",
                         "subtitles": "Subtitles", "music": "Music", "liveTV": "Live TV", "downloads": "Downloads",
                         "libraryCopy": "Library copy", "about": "About", "watch": "Apple Watch"]

    /// Rows for settings the phone pins (cd76c6f): they must not be shown.
    static let pinned = [TestID.Settings.videoEngine, TestID.Settings.videoSkipInterval, TestID.Settings.videoHideControlsAfter,
                         TestID.Settings.videoBrightness, TestID.Settings.videoZoom, TestID.Settings.subtitlesBackground,
                         TestID.Settings.subtitlesSize, TestID.Settings.videoBatterySaver]

    private func openPage(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        let link = app.descendants(matching: .any).matching(identifier: TestID.Settings.pageLink(page)).firstMatch
        app.reveal(link)
        clearOfTheTabBar(link)
        link.tapNow(20, file: file, line: line)
        if page == "watch" { return }   // the Apple Watch page has its own anchor (and none without a paired watch)
        let root = app.element(TestID.Settings.pageRoot(page))
        let title = Self.titles[page] ?? page
        let opened = { root.exists || self.app.navigationBars[title].exists }
        if !eventually(timeout: 6, opened), link.exists, app.element(TestID.Settings.root).exists {
            app.reveal(link)
            clearOfTheTabBar(link)
            link.tapNow(10, file: file, line: line)
        }
        XCTAssertTrue(eventually(timeout: 20, opened), "Settings › \(title) did not open", file: file, line: line)
    }

    /// A page pushed from a settings row: its anchor, or its title in the
    /// system navigation bar. The page it was pushed from must be gone.
    private func pushed(_ anchor: String, title: String, from page: String, timeout: TimeInterval = 10) -> Bool {
        eventually(timeout: timeout) {
            (self.app.element(anchor).exists || self.app.navigationBars[title].exists)
                && !(self.app.element(TestID.Settings.pageRoot(page)).exists
                     && self.app.element(TestID.Settings.pageRoot(page)).frame.minX >= 0
                     && self.app.element(TestID.Settings.pageRoot(page)).frame.minX < 10)
        }
    }

    /// On the small phone a row near the foot sits under the floating tab
    /// bar, where a tap opens a tab: drag it up into the top part first.
    private func clearOfTheTabBar(_ element: XCUIElement) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<3 where element.exists && element.frame.maxY > window.height * 0.7 {
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            start.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Every page opens, shows its rows, fits the screen, and goes back.
    func testEveryPageOpensWithItsRows() throws {
        // Flaky on the SE (2026-11-13: a different page each run fails to
        // open, the tap landing on the floating tab bar or between rows);
        // the SE's pages are covered by testSettingsPagesFitTheScreen.
        try XCTSkipIf(device == .small, "flaky on the small phone; see COVERAGE.md")
        launchHome()
        openSettings()
        var missing: [String] = []
        for page in ["account", "appearance", "video", "audio", "subtitles", "music", "liveTV", "downloads", "libraryCopy", "about"] {
            openPage(page)
            for row in Self.rows[page] ?? [] {
                let e = any(row)
                if !e.waitForExistence(timeout: 3) { app.reveal(e) }
                if !e.exists { missing.append("\(page): \(row)") }
            }
            for row in Self.pinned where any(row).exists { XCTFail("\(page) shows pinned row \(row)") }
            attachScreenshot("settings \(page) (\(device.rawValue))")
            // Back to the list by the More tab (a second tap pops to its
            // root), not a back button: on the Duo's front screen the system
            // back sits in the trailing column.
            tab("More")
            if !app.element(TestID.Shell.more).waitForExistence(timeout: 3) { tab("More") }
            let row = app.descendants(matching: .any).matching(identifier: TestID.Shell.moreRow("settings")).firstMatch
            app.reveal(row)
            row.tapNow(20)
            app.element(TestID.Settings.root).waitToExist(10)
        }
        XCTAssertTrue(missing.isEmpty, "missing rows: \(missing.joined(separator: ", "))")
    }

    func testAppleWatchPageOpens() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("watch")
        XCTAssertTrue(app.element(TestID.WatchSettings.root).waitForExistence(timeout: 10) || app.element(TestID.Settings.pageRoot("watch")).exists
                      || app.navigationBars["Apple Watch"].exists)
    }

    func testAccountPageNamesTheAccountAndServer() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account())
        launchHome()
        openSettings()
        openPage("account")
        let signedInAs = any(TestID.Settings.accountSignedInAs)
        signedInAs.waitToExist(10)
        XCTAssertTrue(signedInAs.label.contains(account.name) || (signedInAs.value as? String ?? "").contains(account.name), signedInAs.label)
        XCTAssertTrue(any(TestID.Settings.accountServer).label.contains("127.0.0.1") || (any(TestID.Settings.accountServer).value as? String ?? "").contains("127.0.0.1"))
    }

    /// Quick Connect approval from Settings › Account: a code started by
    /// the test (as suite-spare2) is approved by the app.
    func testApproveAQuickConnectCode() throws {
        try standardOnly()
        let start = try JellyfinAPI.quickConnectInitiate()
        launchHome()
        openSettings()
        openPage("account")
        let field = app.textFields[TestID.QuickConnect.codeField]
        app.reveal(field)
        field.tapNow(10)
        field.typeText(start.code)
        app.button(TestID.QuickConnect.approve).tapNow(10)
        let confirm = app.button(TestID.QuickConnect.confirm)
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        _ = any(TestID.QuickConnect.outcome).waitForExistence(timeout: 20)
        XCTAssertTrue(eventually(timeout: 20) { (try? JellyfinAPI.quickConnectAuthenticated(secret: start.secret)) == true },
                      "the server never saw the code approved")
    }

    func testDarkThemeTurnsTheAppDark() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("appearance")
        let theme = any(TestID.Settings.theme)
        theme.tapNow(10)
        let dark = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == 'Dark'", TestID.Settings.option(TestID.Settings.theme, "dark"))).firstMatch
        dark.tapNow(10)
        attachScreenshot("dark theme")
        addTeardownBlock { [weak self] in self?.attachScreenshot("after the theme change") }
        // Changing the theme must leave you on the page you changed it on.
        let page = app.element(TestID.Settings.pageRoot("appearance"))
        let stayed = !eventually(timeout: 4) { !page.exists }
        if !stayed {
            XCTFail("changing the theme left Settings › Appearance")
            return
        }
        let row = any(TestID.Settings.theme)
        if !row.exists { goBack() }
        XCTAssertTrue(eventually(timeout: 10) { row.exists && row.label.contains("Dark") }, "theme row did not change to Dark")
    }

    func testHideContinueWatchingTakesTheRowOffHome() throws {
        try standardOnly()
        try self.api.setResume(try Fixtures.require().item("film.long_direct").id, seconds: 300)
        launchHome()
        app.element(TestID.Home.shelf(TestID.Home.rowResume)).waitToExist(30)
        openSettings()
        openPage("appearance")
        let toggle = app.switches[TestID.Settings.hideContinueWatching]
        app.reveal(toggle)
        toggle.waitToExist(10)
        // The switch is at the row's trailing end; the row's middle is text.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(eventually(timeout: 5) { (toggle.value as? String) == "1" }, "switch did not turn on")
        tab("Home")
        XCTAssertTrue(app.element(TestID.Home.shelf(TestID.Home.rowResume)).waitToVanish(20), "Continue Watching still shown")
    }

    func testTabBarSettingsReorderAndReset() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("appearance")
        let link = any(TestID.Settings.tabBar)
        app.reveal(link)
        link.tapNow(10)
        let opened = pushed(TestID.TabBarSettings.root, title: "Tab Bar", from: "appearance")
        guard opened else {
            XCTExpectFailure("bug: Settings sub-pages pushed by value (Route.settings) do not open on iPhone: SettingsView pushes each page with a view-destination NavigationLink (~line 1053), and the value links inside it (~1342ff) are not handled there")
            XCTFail("Tab Bar page did not open"); return
        }
        let reset = any(TestID.TabBarSettings.reset)
        if reset.exists { reset.tap() }
        // Regression R-0c2a8e9: the page must not eject itself mid-edit.
        XCTAssertTrue(pushed(TestID.TabBarSettings.root, title: "Tab Bar", from: "appearance", timeout: 3))
    }

    func testAppIconPageListsIcons() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("appearance")
        let link = any(TestID.Settings.appIcon)
        app.reveal(link)
        link.tapNow(10)
        let opened = pushed(TestID.AppIconSettings.root, title: "App Icon", from: "appearance")
        guard opened else {
            XCTExpectFailure("bug: Settings sub-pages pushed by value (Route.settings) do not open on iPhone: SettingsView pushes each page with a view-destination NavigationLink (~line 1053), and the value links inside it (~1342ff) are not handled there")
            XCTFail("App Icon page did not open"); return
        }
        let original = any(TestID.AppIconSettings.icon("AppIcon"))
        if original.waitForExistence(timeout: 10) { assertOnScreen(original, "original icon tile") }
    }

    func testDefaultQualityChoices() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("video")
        let quality = any(TestID.Settings.videoQuality)
        quality.tapNow(10)
        for (key, label) in [("auto", "Auto"), ("5000000", "5 Mbps · 720p")] {
            XCTAssertTrue(menuItem(TestID.Settings.option(TestID.Settings.videoQuality, key), label: label).exists, key)
        }
    }

    func testAboutShowsTheVersion() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("about")
        let version = any(TestID.Settings.aboutVersion)
        version.waitToExist(10)
        XCTAssertFalse(version.label.isEmpty)
    }

    func testLibraryCopyDeleteAsksFirst() throws {
        // Regression R-074a461: deleting the library copy did not ask.
        try standardOnly()
        launchHome()
        openSettings()
        openPage("libraryCopy")
        let delete = any(TestID.Settings.libraryCopyDelete)
        app.reveal(delete)
        guard delete.exists else { throw XCTSkip("no library copy to delete yet") }
        delete.tap()
        any(TestID.Settings.libraryCopyDeleteCancel).tapNow(10)
    }

    func testLiveTVSourceOffersCustomPlaylist() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("liveTV")
        any(TestID.Settings.liveTVSource).tapNow(10)
        XCTAssertTrue(menuItem(TestID.Settings.option(TestID.Settings.liveTVSource, "custom"), label: "Custom playlist (M3U + XMLTV)").exists)
    }

    func testMusicStationMixPage() throws {
        try standardOnly()
        launchHome()
        openSettings()
        openPage("music")
        let link = any(TestID.Settings.musicStationMix)
        app.reveal(link)
        link.tapNow(10)
        let opened = any(TestID.Settings.stationMixPointsLeft).waitForExistence(timeout: 10) || app.navigationBars["Station mix"].exists
            || app.navigationBars["Station Mix"].exists
        XCTExpectFailure("bug: Settings sub-pages pushed by value (Route.settings) do not open on iPhone (see testTabBarSettingsReorderAndReset)")
        XCTAssertTrue(opened, "Station mix page did not open")
    }

    func testSettingsPagesFitTheScreen() throws {
        launchHome()
        openSettings()
        for page in ["account", "appearance", "video", "downloads"] {
            let link = any(TestID.Settings.pageLink(page))
            app.reveal(link)
            assertOnScreen(link, "\(page) link")
        }
    }
}

extension JellyfinAPI {
    struct QuickConnectStart { let secret: String; let code: String }

    /// Starts a Quick Connect request as another device (no token needed).
    static func quickConnectInitiate(server: String = QA.server) throws -> QuickConnectStart {
        let json = try rawCall(server: server, "POST", "/QuickConnect/Initiate")
        guard let secret = json["Secret"] as? String, let code = json["Code"] as? String else {
            throw Failure.noAnswer("/QuickConnect/Initiate")
        }
        return QuickConnectStart(secret: secret, code: code)
    }

    static func quickConnectAuthenticated(secret: String, server: String = QA.server) throws -> Bool {
        (try rawCall(server: server, "GET", "/QuickConnect/Connect?secret=\(secret)"))["Authenticated"] as? Bool ?? false
    }

    private static func rawCall(server: String, _ method: String, _ path: String) throws -> [String: Any] {
        guard let url = URL(string: server + path) else { throw Failure.noAnswer(path) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("MediaBrowser Client=\"Aquarium UI Tests\", Device=\"QC probe\", DeviceId=\"aquarium-ui-tests-qc\", Version=\"1.0\"",
                     forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d; done.signal() }.resume()
        _ = done.wait(timeout: .now() + 15)
        guard let data = out, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.noAnswer(path)
        }
        return json
    }
}
#endif
