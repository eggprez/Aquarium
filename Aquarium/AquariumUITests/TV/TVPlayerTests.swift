//  The Apple TV player on mpv, driven by the remote: real XCUIRemote presses
//  for clicks, Menu, play/pause and the panel's focus; the app's debug hook
//  (TVHook) for the touch-surface swipes XCUIRemote can't make. What the
//  player did is read back from the QA server's session for this device,
//  and from the panel's own rows.

#if os(tvOS)
import XCTest

class TVPlayerTestCase: TVTestCase {
    /// The server's session for what this app is playing.
    func session(_ itemId: String? = nil) -> JellyfinAPI.Session? {
        (try? api().tvSessions())?.first { $0.nowPlayingId != nil && (itemId == nil || $0.nowPlayingId == itemId) }
    }

    func playState(_ itemId: String? = nil) -> [String: Any] {
        session(itemId)?.raw["PlayState"] as? [String: Any] ?? [:]
    }

    func reportedPosition(_ itemId: String) -> Double? { session(itemId)?.positionSeconds }

    /// The position the timeline says, from its accessibility value ("2
    /// minutes 5 seconds of 20 minutes"). Brings the bar up if it is down.
    /// The server only hears a paused player's position now and then, so the
    /// remote's moves are read here.
    func shownPosition() -> Double? {
        let scrubber = app.element(TestID.Player.scrubber)
        if !scrubber.exists { TVHook.remote("up"); _ = scrubber.waitForExistence(timeout: 5) }
        guard scrubber.exists, let value = scrubber.value as? String,
              let first = value.components(separatedBy: " of ").first else { return nil }
        var seconds = 0.0
        let words = first.split(separator: " ")
        for (i, w) in words.enumerated() where i + 1 < words.count {
            guard let n = Double(w) else { continue }
            let unit = words[i + 1]
            seconds += unit.hasPrefix("hour") ? n * 3600 : unit.hasPrefix("minute") ? n * 60 : n
        }
        return seconds
    }

    /// Plays `itemId` from `seconds` (the server's resume point, set first),
    /// and waits until the server hears it playing.
    func play(_ itemId: String, from seconds: Double = 0, engine: String? = nil,
              file: StaticString = #filePath, line: UInt = #line) throws {
        try api().setResume(itemId, seconds: seconds)
        launchPlaying(itemId, engine: engine, file: file, line: line)
        waitForServerPlayback(of: itemId, pastSeconds: max(0, seconds - 1), file: file, line: line)
    }

    /// Opens the panel at a tab through the debug hook, and waits for it.
    func openPanel(_ tab: String, file: StaticString = #filePath, line: UInt = #line) {
        TVHook.debug("tab.\(tab)")
        app.element(TestID.Player.panel).waitToExist(10, file: file, line: line)
        app.element(TestID.Player.panelTab(tab)).waitToExist(10, file: file, line: line)
        assertFocusPresent("the \(tab) tab", file: file, line: line)
    }

    /// Focuses a row of the open panel with real presses and clicks it.
    /// The panel's cards sit in a row under its tabs, wider than they are
    /// tall: a frame-led walk from a tab goes along the tabs (and changes the
    /// page). So Down first, into the cards, then sideways and down as needed.
    func pick(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.element(id)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no \(id)", file: file, line: line)
        if focusedID.hasPrefix("player.panel.tab.") { Remote.press(.down) }
        for _ in 0..<24 {
            if row.hasFocusInside { break }
            guard let current = focused, row.exists else { break }
            let from = current.frame, to = row.frame
            if to.minY >= from.maxY - 4 {
                Remote.press(.down)
            } else if to.maxY <= from.minY + 4 {
                Remote.press(.up)
            } else {
                Remote.press(to.midX > from.midX ? .right : .left)
            }
        }
        XCTAssertTrue(row.hasFocusInside, "couldn't focus \(id) (on \(focused?.summary ?? "nothing"))", file: file, line: line)
        Remote.select()
    }

    func closePlayer() {
        for _ in 0..<4 where app.element(TestID.Player.root).exists {
            Remote.menu()
            _ = app.element(TestID.Player.root).waitToVanish(3)
        }
    }
}

final class TVPlayerTests: TVPlayerTestCase {
    private var film: String { (try? Fixtures.require().item("film.long_direct").id) ?? "" }

    // MARK: Engine

    func testTheTVPlaysThroughMPVEvenWhenAppleIsAsked() throws {
        try play(film, from: 120, engine: "apple")
        openPanel("info")
        // The TV's Info tab says the engine in its one stream line.
        let summary = app.element(TestID.Player.infoSummary)
        summary.waitToExist(15)
        waitUntil("the stream line to name mpv", timeout: 15) { summary.label.localizedCaseInsensitiveContains("mpv") }
        XCTAssertEqual(playState(film)["PlayMethod"] as? String, "DirectPlay", "an MP4 plays as the file on mpv")
    }

    // MARK: Transport

    func testPlayPauseButtonAndCentreClick() throws {
        try play(film, from: 120)
        Remote.playPause()
        waitUntil("the server to hear it paused", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == true }
        app.element(TestID.Player.controls).waitToExist(10)
        Remote.playPause()
        waitUntil("playing again", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == false }
        Remote.select()
        waitUntil("the centre click to pause", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == true }
        Remote.select()
        waitUntil("the centre click to play", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == false }
    }

    func testEdgeClicksSkipAndCountUp() throws {
        try play(film, from: 120)
        Remote.playPause()
        waitUntil("paused", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == true }
        let start = try XCTUnwrap(shownPosition())
        Remote.press(.right)
        Remote.press(.right)
        Remote.press(.right)
        let hud = app.element(TestID.Player.hudSkip)
        waitUntil("the running total", timeout: 5) { hud.exists && hud.label.contains("30") }
        waitUntil("the timeline to move +30 s", timeout: 15) { [weak self] in
            (self?.shownPosition() ?? 0) >= start + 29
        }
        Remote.press(.left)
        waitUntil("the timeline to move back 10 s", timeout: 15) { [weak self] in
            let p = self?.shownPosition() ?? 0
            return p >= start + 18 && p <= start + 22
        }
    }

    func testPausedSwipeScrubsAndMenuGoesBackToTheReturnPoint() throws {
        try play(film, from: 120)
        Remote.playPause()
        waitUntil("paused", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == true }
        let start = try XCTUnwrap(shownPosition())
        TVHook.remote("swipeRight")
        let scrubber = app.element(TestID.Player.scrubber)
        scrubber.waitToExist(10)
        Remote.select()  // jump there
        waitUntil("the jump", timeout: 15) { [weak self] in (self?.shownPosition() ?? 0) > start + 30 }
        // Menu while the bar is up undoes the jump.
        Remote.menu()
        waitUntil("back to where it was", timeout: 15) { [weak self] in
            abs((self?.shownPosition() ?? 0) - start) < 3
        }
        XCTAssertTrue(app.element(TestID.Player.root).exists, "Menu after a jump should undo it, not leave")
    }

    func testASwipeWhilePlayingMovesNothing() throws {
        // Regression (17206fe): a swipe meant for something else threw the film.
        try play(film, from: 120)
        let before = reportedPosition(film) ?? 120
        TVHook.remote("swipeRight")
        TVHook.remote("swipeRight")
        // Ten seconds of play is at most +12 s; a scrub would be +150 s each.
        waitUntil("the server to report again", timeout: 20) { [weak self] in
            (self?.reportedPosition(self?.film ?? "") ?? 0) > before + 2
        }
        XCTAssertLessThan(reportedPosition(film) ?? 0, before + 60, "the playing film was scrubbed by a swipe")
        XCTAssertFalse(app.element(TestID.Player.scrubPreview).exists)
    }

    func testDownWhileScrubbingDoesNotOpenThePanel() throws {
        // Regression (f6b43c9): a click down with a scrub waiting for its click
        // opened the panel over it.
        try play(film, from: 120)
        Remote.playPause()
        waitUntil("paused", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == true }
        TVHook.remote("swipeRight")
        app.element(TestID.Player.scrubber).waitToExist(10)
        TVHook.remote("down")
        XCTAssertFalse(app.element(TestID.Player.panel).waitForExistence(timeout: 3), "the panel opened over a waiting scrub")
    }

    // MARK: Menu, step by step

    func testMenuStepsBackPanelThenBarThenOut() throws {
        try play(film, from: 120)
        TVHook.remote("swipeDown")
        app.element(TestID.Player.panel).waitToExist(10)
        Remote.menu()
        XCTAssertTrue(app.element(TestID.Player.panel).waitToVanish(10), "Menu didn't put the panel away")
        XCTAssertTrue(app.element(TestID.Player.root).exists, "Menu with the panel open left the player")
        if app.element(TestID.Player.controls).exists {
            Remote.menu()
            XCTAssertTrue(app.element(TestID.Player.controls).waitToVanish(10), "Menu didn't hide the bar")
            XCTAssertTrue(app.element(TestID.Player.root).exists)
        }
        Remote.menu()
        XCTAssertTrue(app.element(TestID.Player.root).waitToVanish(15), "Menu with nothing up didn't leave the player")
        assertFocusPresent("Home after the player")
    }

    // MARK: The panel

    func testSwipeDownOpensInfoWithAFilmsTabs() throws {
        try play(film, from: 120)
        TVHook.remote("swipeDown")
        app.element(TestID.Player.panel).waitToExist(10)
        waitUntil("the Info tab focused", timeout: 10) { [weak self] in
            self?.app.element(TestID.Player.panelTab("info")).hasFocusInside ?? false
        }
        for tab in ["info", "audio", "subtitles", "quality", "speed", "sync", "picture"] {
            XCTAssertTrue(app.element(TestID.Player.panelTab(tab)).exists, "no \(tab) tab on a film")
        }
        XCTAssertFalse(app.element(TestID.Player.panelTab("channels")).exists, "Channels on a film")
        app.element(TestID.Player.infoTitle).waitToExist(10)
        XCTAssertTrue(app.element(TestID.Player.infoSummary).exists)
        attachScreenshot("info tab")
        // Right moves along the tabs, Down into the cards, Up back to the tab.
        Remote.press(.right)
        waitUntil("Audio focused", timeout: 5) { [weak self] in self?.app.element(TestID.Player.panelTab("audio")).hasFocusInside ?? false }
        Remote.press(.down)
        waitUntil("a card focused", timeout: 5) { [weak self] in (self?.focusedID ?? "").hasPrefix("player.audio.option.") }
        Remote.press(.up)
        waitUntil("back on the tab", timeout: 5) { [weak self] in self?.app.element(TestID.Player.panelTab("audio")).hasFocusInside ?? false }
        // Menu from a card goes back to its tab, then from the tabs away.
        Remote.press(.down)
        Remote.menu()
        waitUntil("Menu to go from the card to the tab", timeout: 5) { [weak self] in
            self?.app.element(TestID.Player.panelTab("audio")).hasFocusInside ?? false
        }
        XCTAssertTrue(app.element(TestID.Player.panel).exists)
        Remote.menu()
        XCTAssertTrue(app.element(TestID.Player.panel).waitToVanish(10))
    }

    func testSwipeUpFromTheTabsPutsThePanelAway() throws {
        try play(film, from: 120)
        TVHook.remote("swipeDown")
        app.element(TestID.Player.panel).waitToExist(10)
        waitUntil("the Info tab focused", timeout: 10) { [weak self] in
            self?.app.element(TestID.Player.panelTab("info")).hasFocusInside ?? false
        }
        TVHook.remote("panelSwipeUp")
        XCTAssertTrue(app.element(TestID.Player.panel).waitToVanish(10), "a swipe up from the tabs left the panel open")
    }

    func testInfoNamesTheFileTheChapterAndHDRRange() throws {
        try play(film, from: 450)
        openPanel("info")
        app.element(TestID.Player.infoTitle).waitToExist(10)
        XCTAssertTrue(app.element(TestID.Player.infoTitle).label.contains("FX Long Direct Play"))
        let summary = app.element(TestID.Player.infoSummary)
        XCTAssertTrue(summary.label.localizedCaseInsensitiveContains("mpv"), summary.label)
        let chapter = app.element(TestID.Player.infoFact("chapter"))
        if chapter.waitForExistence(timeout: 10) {
            XCTAssertTrue(chapter.label.contains("Act Two"), "450 s is in Act Two: \(chapter.label)")
        }
    }

    // MARK: Tracks

    func testEveryAudioTrackIsListedAndOneCanBeChosen() throws {
        let fx = try Fixtures.require()
        let multi = try fx.item("film.long_multitrack").id
        let audio = try fx.streams("film.long_multitrack", type: "Audio").compactMap { $0["index"] as? Int }
        try play(multi, from: 60)
        openPanel("audio")
        for index in audio {
            XCTAssertTrue(app.element(TestID.Player.audioOption(String(index))).waitForExistence(timeout: 10), "audio track \(index) missing")
        }
        waitUntil("the default (index 1) selected", timeout: 10) { [weak self] in
            self?.app.element(TestID.Player.audioOption("1")).isSelected ?? false
        }
        pick(TestID.Player.audioOption("2"))
        waitUntil("Spanish selected", timeout: 20) { [weak self] in self?.app.element(TestID.Player.audioOption("2")).isSelected ?? false }
        // jellyfin-track-index-needs-source-id.md: compare what the server heard.
        waitUntil("the server to report audio 2", timeout: 30) { [weak self] in
            (self?.playState(multi)["AudioStreamIndex"] as? Int) == 2
        }
    }

    func testEverySubtitleKindIsListedAndNoneClaimsTheServerDrawsIt() throws {
        // Source: master-fix-list.md "[TV] Subtitle rows say 'Drawn by the
        // server · reopens the stream' on direct play, where neither is true".
        let fx = try Fixtures.require()
        let multi = try fx.item("film.long_multitrack").id
        let subs = try fx.streams("film.long_multitrack", type: "Subtitle").compactMap { $0["index"] as? Int }
        try play(multi, from: 60)
        openPanel("subtitles")
        XCTAssertTrue(app.element(TestID.Player.subtitlesOff).waitForExistence(timeout: 10))
        for index in subs {
            let codec = (try? fx.stream("film.long_multitrack", index: index)["codec"] as? String) ?? "?"
            XCTAssertTrue(app.element(TestID.Player.subtitleOption(String(index))).waitForExistence(timeout: 10),
                          "subtitle \(index) (\(codec)) missing")
        }
        attachScreenshot("subtitle rows")
        let claims = subs.filter { app.element(TestID.Player.subtitleOption(String($0))).label.contains("Drawn by the server") }
        if !claims.isEmpty {
            XCTExpectFailure("bug: on mpv direct play the subtitle rows say 'Drawn by the server · reopens the stream' (Player/Chrome/PlayerPanel.swift:1117), though mpv draws them from the file")
        }
        XCTAssertEqual(claims, [], "rows claiming a server burn-in on direct play")
    }

    func testAPictureSubtitleStaysDirectPlayOnMPV() throws {
        let fx = try Fixtures.require()
        let multi = try fx.item("film.long_multitrack").id
        try play(multi, from: 60)
        openPanel("subtitles")
        pick(TestID.Player.subtitleOption("14"))  // PGS deu
        waitUntil("PGS selected", timeout: 20) { [weak self] in self?.app.element(TestID.Player.subtitleOption("14")).isSelected ?? false }
        waitUntil("the server to report subtitle 14", timeout: 30) { [weak self] in
            (self?.playState(multi)["SubtitleStreamIndex"] as? Int) == 14
        }
        XCTAssertEqual(playState(multi)["PlayMethod"] as? String, "DirectPlay", "PGS needs no burn-in on mpv")
        pick(TestID.Player.subtitlesOff)
        waitUntil("Off selected", timeout: 20) { [weak self] in self?.app.element(TestID.Player.subtitlesOff).isSelected ?? false }
    }

    func testAnASSAndAWebVTTAndAVobSubTrackCanEachBeShown() throws {
        let multi = try Fixtures.require().item("film.long_multitrack").id
        try play(multi, from: 60)
        openPanel("subtitles")
        for index in [9, 13, 15] {
            pick(TestID.Player.subtitleOption(String(index)))
            waitUntil("track \(index) selected", timeout: 20) { [weak self] in
                self?.app.element(TestID.Player.subtitleOption(String(index))).isSelected ?? false
            }
            XCTAssertTrue(app.element(TestID.Player.root).exists)
            XCTAssertFalse(app.element(TestID.Player.errorCard).exists, "track \(index) broke the stream")
        }
    }

    func testSidecarSubtitlesAreListed() throws {
        // film.sidecar_subs: 7 external files, indexes 0–6.
        let sidecar = try Fixtures.require().item("film.sidecar_subs").id
        try play(sidecar, from: 10)
        openPanel("subtitles")
        for index in 0...6 {
            XCTAssertTrue(app.element(TestID.Player.subtitleOption(String(index))).waitForExistence(timeout: 15),
                          "sidecar subtitle \(index) missing")
        }
        pick(TestID.Player.subtitleOption("2"))  // .en.forced.srt
        waitUntil("the forced sidecar selected", timeout: 20) { [weak self] in
            self?.app.element(TestID.Player.subtitleOption("2")).isSelected ?? false
        }
    }

    func testForcedSubtitlesComeOnByThemselvesForForeignAudio() throws {
        // film.forced_foreign: Japanese audio only, an English Forced track
        // flagged default. hls-subtitle-timing.md: "None → Forced subtitles
        // did nothing" was a real report.
        let fx = try Fixtures.require()
        let foreign = try fx.item("film.forced_foreign").id
        let forced = try fx.streams("film.forced_foreign", type: "Subtitle").first { $0["forced"] as? Bool == true }?["index"] as? Int
        let forcedIndex = try XCTUnwrap(forced)
        try play(foreign, from: 5)
        openPanel("subtitles")
        let row = app.element(TestID.Player.subtitleOption(String(forcedIndex)))
        row.waitToExist(15)
        XCTAssertTrue(row.label.contains("Forced"), row.label)
        waitUntil("the forced track on by itself", timeout: 20) { row.isSelected }
    }

    // MARK: Quality

    func testQualityTabHasNoAutoAndPickingARungTranscodes() throws {
        try play(film, from: 120)
        openPanel("quality")
        XCTAssertFalse(app.element(TestID.Player.qualityAuto).exists, "Auto offered on the TV (5095d5e)")
        XCTAssertFalse(app.element(TestID.Player.qualityNote).exists)
        let original = app.element(TestID.Player.qualityOption(TestID.Player.qualityOriginalKey))
        original.waitToExist(10)
        XCTAssertTrue(original.isSelected, "direct play is what's playing")
        pick(TestID.Player.qualityOption("2500000"))
        waitUntil("the server to report a transcode", timeout: 60) { [weak self] in
            (self?.playState(self?.film)["PlayMethod"] as? String) == "Transcode"
        }
        // The same title reopened keeps its place (f6b43c9).
        XCTAssertGreaterThan(reportedPosition(film) ?? 0, 100, "the reopen started from the top")
    }

    func testAQualityChangeWhilePausedStaysPaused() throws {
        // Source: qa-2026-11-11-player/REPORT.md B2 "Changing quality while
        // paused starts playback" (fixed for iPhone/iPad; never run on TV).
        try play(film, from: 120)
        Remote.playPause()
        waitUntil("paused", timeout: 20) { [weak self] in self?.session(self?.film)?.isPaused == true }
        openPanel("quality")
        pick(TestID.Player.qualityOption("5000000"))
        waitUntil("the reopen to reach the server", timeout: 60) { [weak self] in
            (self?.playState(self?.film)["PlayMethod"] as? String) == "Transcode"
        }
        XCTAssertEqual(session(film)?.isPaused, true, "the quality change started playback")
    }

    func testAReopenDoesNotAddToThePlayCount() throws {
        // Source: master-fix-list.md round 2 "[TV, Pro Max #27] Every stream
        // reopen adds to PlayCount (1 to 9 over two viewings)".
        let api = try self.api()
        let before = try api.userData(film).playCount
        try play(film, from: 120)
        openPanel("quality")
        pick(TestID.Player.qualityOption("5000000"))
        waitUntil("the transcode", timeout: 60) { [weak self] in (self?.playState(self?.film)["PlayMethod"] as? String) == "Transcode" }
        Remote.menu()
        openPanel("quality")
        pick(TestID.Player.qualityOption(TestID.Player.qualityOriginalKey))
        waitUntil("direct play again", timeout: 60) { [weak self] in (self?.playState(self?.film)["PlayMethod"] as? String) == "DirectPlay" }
        closePlayer()
        waitUntil("the stop to be recorded", timeout: 20) { (try? api.tvSessions().first { $0.nowPlayingId == self.film }) == nil }
        XCTAssertLessThanOrEqual(try api.userData(film).playCount, before + 1, "reopens counted as plays")
    }

    // MARK: Speed and picture

    func testSpeedTabChangesTheRate() throws {
        try play(film, from: 120)
        openPanel("speed")
        pick(TestID.Player.speedOption("150"))
        waitUntil("1.5× selected", timeout: 10) { [weak self] in self?.app.element(TestID.Player.speedOption("150")).isSelected ?? false }
        pick(TestID.Player.speedOption("100"))
    }

    func testPictureTabStepsAndResets() throws {
        try play(film, from: 120)
        openPanel("picture")
        let increase = app.element(TestID.Player.pictureIncrease("gamma"))
        increase.waitToExist(10)
        let slider = app.element(TestID.Player.pictureSlider("gamma"))
        let before = slider.value as? String
        pick(TestID.Player.pictureIncrease("gamma"))
        waitUntil("gamma to move", timeout: 10) { (slider.value as? String) != before }
        pick(TestID.Player.pictureReset)
        waitUntil("gamma back", timeout: 10) { (slider.value as? String) == before }
    }

    // MARK: Intro, credits, Up Next

    func testSkipIntroAppearsAndSkipsTheIntro() throws {
        // film.long_direct: Intro 30–60. The centre click is Skip while it shows.
        try play(film, from: 26)
        let skip = app.element(TestID.Player.skipIntro)
        skip.waitToExist(30)
        Remote.select()
        waitUntil("past the intro", timeout: 30) { [weak self] in (self?.reportedPosition(self?.film ?? "") ?? 0) >= 59 }
        XCTAssertTrue(skip.waitToVanish(15))
    }

    func testSkipCreditsAppearsAtTheOutro() throws {
        // Regression: qa-2026-11-11-player B3 / master-fix-list "Skip Credits
        // never appears" (includeSegmentTypes sent once with a comma).
        // The debug hook's nearEnd puts it 75 s from the end: 1125 s, inside
        // the Outro segment (1100–1170).
        try play(film, from: 600)
        TVHook.debug("nearEnd")
        app.element(TestID.Player.skipCredits).waitToExist(40)
    }

    func testUpNextCardPlaysTheNextEpisode() throws {
        let fx = try Fixtures.require()
        let e3 = try fx.episode("show.short", season: 1, episode: 3)
        let e4 = try fx.episode("show.short", season: 1, episode: 4)
        try play(e3, from: 0)
        TVHook.debug("nearEnd")
        let card = app.element(TestID.Player.upNextCard)
        card.waitToExist(60)
        Remote.select()  // "Click to play now"
        XCTAssertNotNil(try api().tvWaitForPlayback(of: e4, timeout: 60), "Up Next didn't start S01E04")
    }

    func testMenuOnTheUpNextCardStopsAutoplay() throws {
        let fx = try Fixtures.require()
        let e3 = try fx.episode("show.short", season: 1, episode: 3)
        let e4 = try fx.episode("show.short", season: 1, episode: 4)
        try play(e3, from: 0)
        TVHook.debug("nearEnd")
        let card = app.element(TestID.Player.upNextCard)
        card.waitToExist(60)
        Remote.menu()
        XCTAssertTrue(card.waitToVanish(10), "Menu didn't cancel the Up Next card")
        XCTAssertTrue(app.element(TestID.Player.root).exists, "Menu on the card left the player")
        XCTAssertNil(try api().tvWaitForPlayback(of: e4, timeout: 20), "autoplay went on after Menu")
    }

    // MARK: What the server is told

    func testResumeIsReportedToTheServer() throws {
        // Long title (qa-server-short-title-resume.md): 20 min.
        let api = try self.api()
        try play(film, from: 300)
        waitForServerPlayback(of: film, pastSeconds: 306, timeout: 60)
        closePlayer()
        waitUntil("the stop to be recorded", timeout: 30) {
            guard let d = try? api.userData(self.film) else { return false }
            return d.positionSeconds >= 305 && !d.played
        }
        assertFocusPresent("Home after stopping")
    }
}
#endif
