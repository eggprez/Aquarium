//  More of Settings on an iPad, the pages PadSettingsTests only opens:
//  - Live TV: the source switch, the Custom playlist page (playlist address,
//    guide address, user agent, refresh interval, the channel-artwork check
//    and its report), Refresh now, and the "Last read" line once the
//    playlist has been read. The playlist, guide and logo come from a small
//    HTTP server inside the test (PadLocalServer).
//  - Subtitles: Forced only (a choice of the language row here; the separate
//    switch, `settings.subtitles.forcedOnly`, is the Mac's).
//  - Audio: the language, and no audio delay on an iPad (the Mac's and the
//    Apple TV's row); Measure Apple TV sync in its place.
//  - Music → Station mix: the preset, the dials and their budget, and the
//    warning under a dial when recent stations' songs lacked its tag.
//  - Library copy: the switch, the status and contents rows, Sync now, and
//    Delete with its confirmation and Cancel.
//  - About: the engine and the paragraph.
//
//  Everything here is the app's own test settings, which the next launch
//  starts without; nothing is changed on the server.

#if os(iOS)
import XCTest
import UIKit

final class PadSettingsMoreTests: PadUITestCase {
    private var local: PadLocalServer?

    override func tearDownWithError() throws {
        local?.stop()
        local = nil
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    private typealias Settings = TestID.Settings

    /// Home, the gear, then a first-level page (upright: one column).
    private func openSettingsPage(_ key: String, arguments: [String] = [],
                                  file: StaticString = #filePath, line: UInt = #line) {
        launchHome(arguments: arguments, file: file, line: line)
        openSettings(file: file, line: line)
        openPage(key, file: file, line: line)
    }

    private func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.button(TestID.Sidebar.settings)
        if !gear.exists || !gear.isHittable { revealSidebar() }
        gear.padTap(file: file, line: line)
        // The first page, or whichever page Settings was left on.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.' AND identifier ENDSWITH '.root'")).firstMatch
            .waitToExist(20, file: file, line: line)
    }

    private func openPage(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        let link = app.element(Settings.pageLink(key))
        _ = link.waitForExistence(timeout: 10)
        if !isOnScreen(link) { reveal(link) }
        link.padTap(file: file, line: line)
        app.element(Settings.pageRoot(key)).waitToExist(15, file: file, line: line)
    }

    /// A picker row and one of the options its menu lists.
    private func pick(_ row: String, option key: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.element(row)
        XCTAssertTrue(reveal(picker), "\(row) on the page", file: file, line: line)
        picker.padTap()
        tapMenuItem(Settings.option(row, key), label: label, file: file, line: line)
    }

    private func flip(_ toggle: XCUIElement, to on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(reveal(toggle), "\(toggle) on the page", file: file, line: line)
        guard ((toggle.value as? String) == "1") != on else { return }
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertTrue(waitUntil(5, "the switch \(on ? "on" : "off")", file: file, line: line) { ((toggle.value as? String) == "1") == on })
    }

    // MARK: Live TV, custom playlist

    /// Two channels, one with a logo; a guide of three programmes each, around now.
    private func serveLiveTV() throws -> PadLocalServer {
        let server = try PadLocalServer()
        local = server
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        server.set("/logo.png", type: "image/png", body: logo)
        server.set("/playlist.m3u", type: "audio/x-mpegurl", text: """
        #EXTM3U
        #EXTINF:-1 tvg-id="pad.one" tvg-logo="\(server.address)/logo.png",Pad Channel One
        \(server.address)/one.ts
        #EXTINF:-1 tvg-id="pad.two",Pad Channel Two
        \(server.address)/two.ts

        """)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMddHHmmss Z"
        let begin = Date().addingTimeInterval(-1800)
        var guide = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n<tv>\n"
        for channel in ["pad.one", "pad.two"] {
            guide += #"<channel id="\#(channel)"><display-name>\#(channel == "pad.one" ? "Pad Channel One" : "Pad Channel Two")</display-name></channel>"# + "\n"
        }
        for channel in ["pad.one", "pad.two"] {
            for slot in 0..<3 {
                let start = begin.addingTimeInterval(Double(slot) * 7200), stop = start.addingTimeInterval(7200)
                guide += #"<programme start="\#(stamp.string(from: start))" stop="\#(stamp.string(from: stop))" channel="\#(channel)">"#
                guide += "<title>Pad Programme \(slot + 1)</title><desc>From the test's own guide.</desc></programme>\n"
            }
        }
        guide += "</tv>\n"
        server.set("/guide.xml", type: "application/xml", text: guide)
        return server
    }

    func testCustomPlaylistFieldsArtworkCheckAndLastRead() throws {
        let server = try serveLiveTV()
        openSettingsPage("liveTV")

        // Jellyfin to begin with: no Custom playlist row.
        XCTAssertFalse(app.element(Settings.liveTVCustomPlaylist).exists, "no Custom playlist row while the source is Jellyfin")
        XCTAssertTrue(app.element(Settings.liveTVRefreshNow).exists)
        pick(Settings.liveTVSource, option: "custom", label: "Custom playlist (M3U + XMLTV)")
        let customRow = app.element(Settings.liveTVCustomPlaylist)
        XCTAssertTrue(customRow.waitForExistence(timeout: 10), "the Custom playlist row once the source is custom")
        XCTAssertTrue(text(customRow).contains("Not set"), "reads \(text(customRow))")
        XCTAssertFalse(app.element(Settings.liveTVPlaylistSummary).exists, "nothing read yet")

        // The Custom playlist page.
        customRow.padTap()
        app.element(Settings.pageRoot("customPlaylist")).waitToExist(15)
        let playlist = app.textFields[Settings.liveTVPlaylistURL]
        let guide = app.textFields[Settings.liveTVGuideURL]
        let agent = app.textFields[Settings.liveTVUserAgent]
        XCTAssertEqual(playlist.placeholderValue, "https://example.com/playlist.m3u")
        XCTAssertEqual(guide.placeholderValue, "Optional")
        XCTAssertEqual(agent.placeholderValue, "VLC/3.0.20 LibVLC/3.0.20", "the default it sends when left empty")

        // Before any channel is loaded the artwork check says so.
        let check = app.button(Settings.liveTVArtworkCheck)
        XCTAssertTrue(reveal(check))
        XCTAssertEqual(check.label, "Check channel artwork")
        check.padTap()
        let none = app.element(Settings.liveTVArtworkEmpty)
        XCTAssertTrue(none.waitForExistence(timeout: 15), "No channels loaded yet")
        XCTAssertTrue(none.label.hasPrefix("No channels loaded yet"), "reads \(none.label)")
        XCTAssertTrue(waitUntil(10, "the button to offer again") { check.label == "Check channel artwork again" })

        XCTAssertTrue(reveal(playlist))
        replaceText(in: playlist, with: "\(server.address)/playlist.m3u")
        replaceText(in: guide, with: "\(server.address)/guide.xml")
        replaceText(in: agent, with: "PadTests/1.0")
        dismissKeyboard()
        XCTAssertEqual(playlist.value as? String, "\(server.address)/playlist.m3u")
        XCTAssertEqual(guide.value as? String, "\(server.address)/guide.xml")
        XCTAssertEqual(agent.value as? String, "PadTests/1.0")
        pick(Settings.liveTVRefreshInterval, option: "30", label: "30 minutes")
        XCTAssertTrue(waitUntil(5, "the interval chosen") { [self] in text(app.element(Settings.liveTVRefreshInterval)).contains("30 minutes") },
                      "reads \(text(app.element(Settings.liveTVRefreshInterval)))")
        attachScreenshot("custom playlist")

        // Back on Live TV the row names the playlist's host.
        goBack()
        app.element(Settings.pageRoot("liveTV")).waitToExist(10)
        XCTAssertTrue(waitUntil(10, "the row to name the host") { [self] in text(customRow).contains("127.0.0.1") }, "reads \(text(customRow))")
        let refresh = app.element(Settings.liveTVRefreshNow)
        XCTAssertTrue(reveal(refresh))
        refresh.padTap()
        expectToast(containing: "Refreshing Live TV")

        // Live TV reads the playlist: the two channels, from the test's server.
        showSection("livetv")
        app.element(TestID.LiveTV.root).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Guide.channel("iptv-0-pad.one")).waitForExistence(timeout: 40), "Pad Channel One in the guide")
        XCTAssertTrue(app.element(TestID.Guide.channel("iptv-1-pad.two")).exists, "Pad Channel Two in the guide")
        XCTAssertTrue(server.requests.contains("/playlist.m3u"), "asked for: \(server.requests)")
        XCTAssertTrue(server.requests.contains("/guide.xml"), "asked for: \(server.requests)")
        attachScreenshot("custom guide")

        // Settings again: what was read, in a line.
        openSettings()
        if !app.element(Settings.pageRoot("liveTV")).exists { openPage("liveTV") }
        let summary = app.element(Settings.liveTVPlaylistSummary)
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "the Last read line")
        XCTAssertEqual(summary.label, "Last read: 2 channels · 1 with artwork · 6 programmes in the guide.")

        // And the artwork check has channels to report on.
        app.element(Settings.liveTVCustomPlaylist).padTap()
        app.element(Settings.pageRoot("customPlaylist")).waitToExist(15)
        XCTAssertEqual(app.textFields[Settings.liveTVPlaylistURL].value as? String, "\(server.address)/playlist.m3u", "the address kept")
        let again = app.button(Settings.liveTVArtworkCheck)
        XCTAssertTrue(reveal(again))
        again.padTap()
        let one = app.element(Settings.liveTVArtworkResult("pad-channel-one"))
        let two = app.element(Settings.liveTVArtworkResult("pad-channel-two"))
        XCTAssertTrue(one.waitForExistence(timeout: 30), "a line for Pad Channel One")
        XCTAssertTrue(two.waitForExistence(timeout: 10), "a line for Pad Channel Two")
        reveal(two)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'decoded fine'")).firstMatch.exists,
                      "the logo the server gave decodes")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'no logo'")).firstMatch.exists,
                      "and the channel with no tvg-logo is said to have none")
        XCTAssertFalse(app.element(Settings.liveTVArtworkEmpty).exists)
        XCTAssertTrue(server.requests.contains("/logo.png"), "asked for: \(server.requests)")
        attachScreenshot("artwork check")
    }

    // MARK: Subtitles and audio

    func testSubtitlesForcedOnlyIsAChoiceOfTheLanguageRow() {
        openSettingsPage("subtitles")
        XCTAssertFalse(app.element(Settings.subtitlesForcedOnly).exists, "the separate Forced only switch is the Mac's")
        let row = app.element(Settings.subtitlesLanguage)
        XCTAssertTrue(text(row).contains("File's choice"), "reads \(text(row))")
        pick(Settings.subtitlesLanguage, option: "forced", label: "Forced only")
        XCTAssertTrue(waitUntil(5, "Forced only chosen") { [self] in text(row).contains("Forced only") }, "reads \(text(row))")
        // The first page's row says where the page stands.
        goBack()
        let link = app.element(Settings.pageLink("subtitles"))
        XCTAssertTrue(waitUntil(10, "the Subtitles row to say so") { [self] in text(link).contains("Forced only") }, "reads \(text(link))")

        // Kept across a relaunch.
        launch(reset: false)
        app.element(TestID.Home.root).waitToExist(60)
        openSettings()
        XCTAssertTrue(waitUntil(10, "the Subtitles row after a relaunch") { [self] in text(app.element(Settings.pageLink("subtitles"))).contains("Forced only") },
                      "reads \(text(app.element(Settings.pageLink("subtitles"))))")
        openPage("subtitles")
        pick(Settings.subtitlesLanguage, option: "off", label: "Never")
        XCTAssertTrue(waitUntil(5, "Never chosen") { [self] in text(app.element(Settings.subtitlesLanguage)).contains("Never") })
    }

    func testAudioPageHasALanguageAndNoDelayOnAnIPad() {
        openSettingsPage("audio")
        XCTAssertFalse(app.element(Settings.audioDelay).exists, "no audio delay on an iPad: it has nothing between it and its speaker")
        XCTAssertFalse(app.element(Settings.audioDownmix).exists)
        XCTAssertTrue(app.element(Settings.audioMeasureSync).exists, "Measure Apple TV sync in its place")
        let row = app.element(Settings.audioLanguage)
        XCTAssertTrue(text(row).contains("File's choice"), "reads \(text(row))")
        pick(Settings.audioLanguage, option: "fre,fra", label: "French")
        XCTAssertTrue(waitUntil(5, "French chosen") { [self] in text(row).contains("French") }, "reads \(text(row))")
        goBack()
        let link = app.element(Settings.pageLink("audio"))
        XCTAssertTrue(waitUntil(10, "the Audio row to say French") { [self] in text(link).contains("French") }, "reads \(text(link))")
    }

    // MARK: Station mix

    private func dialValue(_ dial: String) -> String {
        text(app.element(Settings.value(Settings.stationMixDial(dial))))
    }

    private func stepper(_ dial: String, _ direction: String) -> XCUIElement {
        app.buttons["\(Settings.stationMixDial(dial))-\(direction)"]
    }

    private func openStationMix(arguments: [String] = []) {
        openSettingsPage("music", arguments: arguments)
        let row = app.element(Settings.musicStationMix)
        XCTAssertTrue(reveal(row), "the Station mix row")
        XCTAssertTrue(text(row).contains("Balanced"), "everyone starts Balanced: \(text(row))")
        row.padTap()
        app.element(Settings.pageRoot("stationMix")).waitToExist(15)
    }

    func testStationMixPresetAndDialsShareOneBudget() {
        openStationMix()
        let left = app.element(Settings.stationMixPointsLeft)
        XCTAssertTrue(reveal(left))
        XCTAssertTrue(left.label.hasPrefix("0 of 20 points left to spend."), "reads \(left.label)")
        XCTAssertFalse(app.elements(prefix: "settings.stationMix.dialWarning.").firstMatch.exists, "no warnings before any station has played")
        let balanced = ["artist": "5", "genre": "6", "era": "3", "favorites": "2", "mostPlayed": "2", "discovery": "0", "surprise": "2"]
        for (dial, points) in balanced {
            XCTAssertTrue(reveal(app.element(Settings.stationMixDial(dial))), "the \(dial) dial")
            XCTAssertEqual(dialValue(dial), points, "Balanced: \(dial)")
        }

        // A preset sets every dial.
        pick(Settings.stationMixPreset, option: "discovery", label: "Discovery")
        XCTAssertTrue(waitUntil(5, "Discovery's dials") { [self] in dialValue("discovery") == "8" }, "discovery reads \(dialValue("discovery"))")
        for (dial, points) in ["artist": "2", "genre": "5", "era": "2", "favorites": "0", "mostPlayed": "0", "surprise": "3"] {
            reveal(app.element(Settings.stationMixDial(dial)))
            XCTAssertEqual(dialValue(dial), points, "Discovery: \(dial)")
        }

        // The budget is spent: a dial can't go up until another comes down.
        let artistUp = stepper("artist", "Increment"), artistDown = stepper("artist", "Decrement")
        XCTAssertTrue(reveal(artistUp))
        XCTAssertFalse(artistUp.isEnabled, "no points left to add")
        artistDown.tap()
        XCTAssertTrue(waitUntil(5, "artist down to 1") { [self] in dialValue("artist") == "1" })
        reveal(left)
        XCTAssertTrue(left.label.hasPrefix("1 of 20 points left to spend."), "reads \(left.label)")
        let preset = app.element(Settings.stationMixPreset)
        reveal(preset)
        XCTAssertTrue(text(preset).contains("Custom"), "off a preset it reads Custom: \(text(preset))")

        // The freed point goes to another dial, and that is the budget again.
        let eraUp = stepper("era", "Increment")
        XCTAssertTrue(reveal(eraUp))
        XCTAssertTrue(eraUp.isEnabled)
        eraUp.tap()
        XCTAssertTrue(waitUntil(5, "era up to 3") { [self] in dialValue("era") == "3" })
        XCTAssertFalse(eraUp.isEnabled, "spent again")
        reveal(left)
        XCTAssertTrue(left.label.hasPrefix("0 of 20 points left to spend."), "reads \(left.label)")
        attachScreenshot("station mix")

        // Back to a preset; Music's row follows.
        pick(Settings.stationMixPreset, option: "familiar", label: "Familiar")
        XCTAssertTrue(waitUntil(5, "Familiar's dials") { [self] in dialValue("favorites") == "5" })
        goBack()
        let row = app.element(Settings.musicStationMix)
        XCTAssertTrue(waitUntil(10, "Music's row to say Familiar") { [self] in text(row).contains("Familiar") }, "reads \(text(row))")
    }

    /// The warning under a dial comes from what recent stations chose from
    /// (`TagCoverage`, kept in the settings as `music_tag_coverage`): here a
    /// pool of 100 songs, 60 with no genre and 3 with no year, handed in as a
    /// launch argument the way `defaults write` would.
    func testStationMixDialWarnsWhenRecentStationsLackedItsTag() {
        let coverage = "<array><array><integer>100</integer><integer>0</integer><integer>60</integer><integer>3</integer></array></array>"
        openStationMix(arguments: ["-music_tag_coverage", coverage])
        let warning = app.element(Settings.stationMixDialWarning("genre"))
        XCTAssertTrue(reveal(warning), "a warning under Genre")
        XCTAssertEqual(warning.label, "60% of the songs your recent stations chose from have no genre tag, so these points have less to work with.")
        XCTAssertFalse(app.element(Settings.stationMixDialWarning("artist")).exists, "every song had an artist")
        XCTAssertFalse(app.element(Settings.stationMixDialWarning("era")).exists, "3% is under the 5% worth saying")
        XCTAssertFalse(app.element(Settings.stationMixDialWarning("favorites")).exists, "a dial that reads no tag has no warning")
        attachScreenshot("station mix warning")
    }

    // MARK: Library copy

    func testLibraryCopyStatusRowsSyncAndDelete() {
        openSettingsPage("libraryCopy")
        let keep = app.switches[Settings.libraryCopyKeep]
        keep.waitToExist(10)
        if (keep.value as? String) != "1" {
            XCTAssertFalse(app.element(Settings.libraryCopyStatus).exists, "no status rows while the copy is off")
            XCTAssertFalse(app.element(Settings.libraryCopySyncNow).exists)
            flip(keep, to: true)
        }
        let status = app.element(Settings.libraryCopyStatus)
        let contents = app.element(Settings.libraryCopyContents)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the Status row")
        XCTAssertTrue(contents.waitForExistence(timeout: 10), "the Saved row")
        XCTAssertTrue(contents.label.contains("items · "), "reads \(contents.label)")
        XCTAssertTrue(contents.label.hasSuffix("of artwork"), "reads \(contents.label)")

        // Turning it on reads the libraries: Reading <library>…, then Saving
        // artwork (which can run for minutes), then Synced.
        XCTAssertTrue(waitUntil(120, "the libraries to be read (status: \(status.label); saved: \(contents.label))") {
            !contents.label.contains(" 0 items") && (status.label.contains("Synced") || status.label.contains("Saving artwork"))
        }, "status: \(status.label); saved: \(contents.label)")
        let sync = app.button(Settings.libraryCopySyncNow)
        XCTAssertTrue(reveal(sync), "Sync now")
        attachScreenshot("library copy")

        // Delete asks first; Cancel keeps the copy.
        let delete = app.button(Settings.libraryCopyDelete)
        XCTAssertTrue(reveal(delete))
        delete.padTap()
        XCTAssertTrue(app.staticTexts["Delete the saved copy of your library?"].waitForExistence(timeout: 10))
        cancelDialog(cancel: Settings.libraryCopyDeleteCancel, confirm: Settings.libraryCopyDeleteConfirm)
        XCTAssertFalse(contents.label.contains(" 0 items"), "Cancel kept the copy: \(contents.label)")

        delete.padTap()
        app.button(Settings.libraryCopyDeleteConfirm).padTap()
        XCTAssertTrue(waitUntil(15, "the copy emptied") { contents.label.contains(" 0 items") }, "saved: \(contents.label)")
        XCTAssertTrue(waitUntil(10, "Not synced yet") { status.label.contains("Not synced yet") }, "status: \(status.label)")

        // Off: the rows go, and the first page says so.
        flip(keep, to: false)
        XCTAssertTrue(status.waitToVanish(10), "no status rows once the copy is off")
        goBack()
        let link = app.element(Settings.pageLink("libraryCopy"))
        XCTAssertTrue(waitUntil(10, "the Library copy row to say Off") { [self] in text(link).contains("Off") }, "reads \(text(link))")
    }

    // MARK: About

    func testAboutSaysWhatTheAppIsAndItsEngine() {
        openSettingsPage("about")
        let engine = app.element(Settings.aboutEngine)
        XCTAssertTrue(reveal(engine))
        XCTAssertTrue(text(engine).contains("Playback engine"), "reads \(text(engine))")
        XCTAssertGreaterThan(text(engine).count, "Playback engine ".count, "the engine is named: \(text(engine))")
        let about = app.element(Settings.aboutText)
        XCTAssertTrue(reveal(about))
        XCTAssertTrue(about.label.hasPrefix("Built with AI"), "reads \(about.label)")
        XCTAssertTrue(about.label.contains("Jellyfin client"), "reads \(about.label)")
        let version = app.element(Settings.aboutVersion)
        XCTAssertTrue(text(version).range(of: #"\d+(\.\d+)* \(\d+\)"#, options: .regularExpression) != nil, "version (build): \(text(version))")
    }
}
#endif
