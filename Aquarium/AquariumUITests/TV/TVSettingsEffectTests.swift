//  Settings whose effect is somewhere else: a quality, a resume switch and an
//  audio delay set in Settings (Views/TVSettingsView.swift), then read back
//  from what the player does and what the server hears; and the Seerr rows
//  of Settings → Account, against the stand-in Seerr server.

#if os(tvOS)
import XCTest

final class TVSettingsEffectTests: TVSettingsPagesCase {
    private var film: String { (try? Fixtures.require().item("film.long_direct").id) ?? "" }

    /// The same app again with what it wrote, opening a `play` link. Not
    /// `launchWithLink`: that marks this device's sessions as left over, and
    /// a relaunch that keeps its state keeps its device id.
    private func relaunchPlaying(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        launch(reset: false, environment: [TestLaunch.linkEnv: "aquarium://play/\(id)"])
        app.element(TestID.Player.root).waitToExist(60, file: file, line: line)
    }

    /// Out of the player, and the film's resume point back at the suite's
    /// baseline (5:00) once the server has heard the stop.
    private func leaveAndRestore(_ id: String) {
        closePlayer()
        waitUntil("the stop to be recorded", timeout: 20, fail: false) { [weak self] in self?.session(id) == nil }
        try? api().setResume(id, seconds: 300)
    }

    func testTheQualityChosenInSettingsIsWhatATitleOpensAt() throws {
        // A rung kept in Settings is where a title opens, and Auto leaves it
        // alone. A direct-playable MP4 opened with 5 Mbps chosen is
        // transcoded from the first frame.
        try Fixtures.require()
        try api().setResume(film, seconds: 300)
        defer { leaveAndRestore(film) }
        openSettings()
        openPage("video")
        pick(TestID.Settings.videoQuality, option: "stream(Optional(5000000))", backOn: TestID.Settings.pageRoot("video"))
        let row = app.element(TestID.Settings.videoQuality)
        waitUntil("the row to read 5 Mbps", timeout: 5) { row.label.contains("5 Mbps") }
        relaunchPlaying(film)
        waitUntil("the server to report a transcode", timeout: 60) { [weak self] in
            (self?.playState(self?.film)["PlayMethod"] as? String) == "Transcode"
        }
        openPanel("quality")
        waitUntil("5 Mbps to be the rung playing", timeout: 30) { [weak self] in
            self?.app.element(TestID.Player.qualityOption("5000000")).isSelected ?? false
        }
        XCTAssertFalse(app.element(TestID.Player.qualityAuto).isSelected, "Auto ticked beside a kept rung")
    }

    func testWithResumeOffATitleStartsFromTheTop() throws {
        // `PlayerModel.startPosition`: resume only when the option and the
        // Settings switch both say so. The server holds 5:00 for this film.
        try Fixtures.require()
        try api().setResume(film, seconds: 300)
        defer { leaveAndRestore(film) }
        openSettings()
        openPage("video")
        XCTAssertFalse(flip(TestID.Settings.videoResume), "resume is on by default")
        relaunchPlaying(film)
        waitForServerPlayback(of: film, pastSeconds: 1, timeout: 60)
        let position = reportedPosition(film) ?? .infinity
        XCTAssertLessThan(position, 120, "resume was off, and the film opened at \(Int(position)) s of the server's 300")
    }

    func testADelaySetOverTheClipIsShownOnItsRowAndNoOther() {
        // The Sync tab over the 24 fps clip moves the 24 fps offset
        // (`PlayerModel.audioDelayScope`); Settings → Audio lists one a rate.
        openSettings()
        openPage("audio")
        choose(TestID.TVSettings.audioDelay(24))
        let play = app.element(TestID.TVSettings.syncTestPlay)
        play.waitToExist(10)
        // A system alert: its buttons report focus by label only.
        for move in [nil, XCUIRemote.Button.up, .down, .down] {
            if let move { Remote.press(move) }
            if focusedLabel.localizedCaseInsensitiveContains("play") || play.hasFocus { break }
        }
        XCTAssertTrue(focusedLabel.localizedCaseInsensitiveContains("play") || play.hasFocus,
                      "Play not focused in the warning (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        app.element(TestID.Player.syncCodeImage).waitToExist(30)
        TVHook.remote("swipeDown")
        app.element(TestID.Player.panel).waitToExist(10)
        let value = app.element(TestID.Player.syncValue)
        value.waitToExist(10)
        pick(TestID.Player.syncStep(50))
        waitUntil("the reading to say 50 ms", timeout: 10) { value.label.contains("50 ms") }
        closePlayer()
        XCTAssertTrue(app.element(TestID.Player.root).waitToVanish(15), "the clip didn't close")
        app.element(TestID.Settings.pageRoot("audio")).waitToExist(10)
        let row24 = app.element(TestID.TVSettings.audioDelay(24))
        waitUntil("the 24 fps row to show 50 ms", timeout: 10) { row24.label.contains("50 ms") }
        for fps in [25, 30, 50, 60] {
            let other = app.element(TestID.TVSettings.audioDelay(fps))
            XCTAssertTrue(other.label.contains("In step"), "the \(fps) fps delay moved with the 24 fps one: \(other.label)")
        }
        assertFocusPresent("Settings → Audio after the clip")
    }
}

// MARK: - Seerr in Settings → Account

final class TVRequestsSettingsTests: TVSettingsPagesCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SeerrQA.require()
    }

    private var seerrTab: XCUIElement { tab("requests", title: "Seerr") }

    func testAConnectedSeerrShowsItsRowsAndDisconnectTakesTheTabAway() throws {
        markSessionsStale()
        launch(environment: SeerrQA.environment)
        app.element(TestID.Home.root).waitToExist(60)
        assertFocusPresent("Home after launch")
        XCTAssertTrue(focusTabStrip())
        waitUntil("the Seerr tab", timeout: 40) { [weak self] in self?.seerrTab.exists ?? false }
        enterSettings()
        openPage("account")
        let server = app.element(TestID.Requests.settingsServer)
        XCTAssertTrue(server.waitForExistence(timeout: 10), "no Seerr server row while connected")
        let host = URL(string: SeerrQA.server)?.host ?? "127.0.0.1"
        XCTAssertTrue(server.label.contains(host), server.label)
        let connection = app.element(TestID.Requests.settingsConnection)
        XCTAssertTrue(connection.label.hasSuffix(SeerrQA.server.lowercased().hasPrefix("https") ? "HTTPS" : "HTTP"), connection.label)
        XCTAssertTrue(app.element(TestID.Requests.settingsPosters).exists)
        XCTAssertFalse(app.element(TestID.Requests.settingsConnect).exists, "Connect offered while connected")
        attachScreenshot("Seerr rows in Account")

        choose(TestID.Requests.settingsDisconnect)
        XCTAssertTrue(app.element(TestID.Requests.settingsConnect).waitForExistence(timeout: 20), "Disconnect left the Seerr rows")
        XCTAssertFalse(server.exists)
        assertFocusPresent("Account after disconnecting")
        back(to: TestID.Settings.root)
        XCTAssertTrue(focusTabStrip(max: 25))
        waitUntil("the Seerr tab to leave the strip", timeout: 15) { [weak self] in !(self?.seerrTab.exists ?? true) }
    }

    func testTheConnectFormOpensAndMenuLeavesItUnconnected() {
        openSettings()
        openPage("account")
        choose(TestID.Requests.settingsConnect)
        app.element(TestID.Requests.connectRoot).waitToExist(15)
        assertFocusPresent("the Seerr form")
        XCTAssertTrue(app.element(TestID.Requests.connectAddress).exists)
        let connect = app.button(TestID.Requests.connectContinue)
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "Connect is live with no address typed")
        attachScreenshot("Connect to Seerr")
        Remote.menu()
        XCTAssertTrue(app.element(TestID.Requests.connectRoot).waitToVanish(10), "Menu left the form up")
        XCTAssertTrue(app.element(TestID.Requests.settingsConnect).exists, "left without connecting")
        XCTAssertFalse(app.element(TestID.Requests.settingsServer).exists)
        assertFocusPresent("Account after leaving the Seerr form")
    }

    func testConnectingFromSettingsWithTheKeyboardAddsTheSeerrTab() {
        // The whole way a household sets it up on the TV: the address typed
        // with the on-screen keyboard, the plain-http warning, the app's own
        // Quick Connect exchange, then the rows in Account and the tab.
        openSettings()
        openPage("account")
        choose(TestID.Requests.settingsConnect)
        app.element(TestID.Requests.connectRoot).waitToExist(15)
        let field = app.element(TestID.Requests.connectAddress)
        XCTAssertTrue(focusInColumn(field) || Remote.focus(on: field, in: app),
                      "couldn't focus the address (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        waitUntil("the keyboard", timeout: 10) { [weak self] in (self?.app.keyboards.count ?? 0) > 0 }
        app.typeText(SeerrQA.server)
        if app.keyboards.count > 0 {
            Remote.menu()  // puts the keyboard away and keeps the text
            waitUntil("the keyboard to go", timeout: 10) { [weak self] in (self?.app.keyboards.count ?? 0) == 0 }
        }
        XCTAssertTrue(app.element(TestID.Requests.connectRoot).exists, "Menu on the keyboard closed the form")
        let connect = app.button(TestID.Requests.connectContinue)
        waitUntil("Connect to enable", timeout: 5) { connect.isEnabled }
        XCTAssertTrue(press(.down, until: { isFocused(on: connect) }, max: 4) || Remote.focus(on: connect, in: app),
                      "can't reach Connect (on \(focused?.summary ?? "nothing"))")
        Remote.select()

        let anyway = app.button(TestID.Requests.connectAnyway)
        let server = app.element(TestID.Requests.settingsServer)
        let failure = app.element(TestID.Requests.connectError)
        waitUntil("an answer from the stand-in", timeout: 40) { anyway.exists || server.exists || failure.exists }
        XCTAssertFalse(failure.exists, "the form refused: \(failure.exists ? failure.label : "")")
        if anyway.exists {
            attachScreenshot("plain http warning")
            XCTAssertTrue(app.element(TestID.Requests.connectInsecure).exists)
            XCTAssertTrue(focusInColumn(anyway) || Remote.focus(on: anyway, in: app), "can't reach Connect Anyway")
            Remote.select()
        }
        XCTAssertTrue(server.waitForExistence(timeout: 60), "never connected")
        XCTAssertFalse(app.element(TestID.Requests.connectRoot).exists, "the form stayed up after connecting")
        assertFocusPresent("Account after connecting")
        back(to: TestID.Settings.root)
        XCTAssertTrue(focusTabStrip(max: 25))
        waitUntil("the Seerr tab", timeout: 15) { [weak self] in self?.seerrTab.exists ?? false }
    }
}
#endif
