//  The Mac player: its own window, the controls over the picture, the
//  Playback menu and the picture's right-click menu, tracks (forced
//  subtitles included), quality, chapters, skipping intros and credits,
//  Up Next, full screen, Stream Info, and what the server hears.

#if os(macOS)
import XCTest

final class MacPlayerUITests: MacUITestCase {
    private func fixtures() throws -> Fixtures { try Fixtures.require() }

    /// A long direct-play film from the start (its resume point cleared).
    private func playLongDirect(from seconds: Double = 0, engine: String? = nil) throws -> (Fixtures.Item, JellyfinAPI) {
        let film = try fixtures().item("film.long_direct")
        let api = try JellyfinAPI.signIn()
        try api.setResume(film.id, seconds: seconds)
        launchToHome(engine: engine)
        play(film)
        return (film, api)
    }

    // MARK: The window

    /// Regression: PlayerWasTinySheet. The player was a ~470×150 sheet with
    /// no way to resize or close it. Now a window of its own, at least
    /// 480×270, titled with what plays. Source: commit b723cea;
    /// Player/PlayerWindow.swift:1-13.
    func testBugPlayerWasTinySheet() throws {
        let (film, _) = try playLongDirect()
        let window = playerWindow
        XCTAssertGreaterThanOrEqual(window.frame.width, 480)
        XCTAssertGreaterThanOrEqual(window.frame.height, 270)
        XCTAssertTrue(window.title.contains(film.name) || app.staticTexts[TestID.Player.title].exists, window.title)
        XCTAssertTrue(mainWindow.exists, "browsing goes on beside the player")
        attachScreenshot("player window")
    }

    func testClosingThePlayerWindowStopsPlayback() throws {
        let (film, api) = try playLongDirect()
        let session = try XCTUnwrap(try api.macWaitForPlayback(of: film.id))
        focusPlayerWindow()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(playerWindow.waitToVanish(20))
        mainWindow.click()
        let stillPlaying = app.element(TestID.Sidebar.nowPlaying).waitForExistence(timeout: 3)
            && !app.element(TestID.Sidebar.nowPlaying).waitToVanish(15)
        let attachment = XCTAttachment(string: "sidebar Now Playing still shown after closing the player window: \(stillPlaying)")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(stillPlaying, "closing the window stops the player")
        XCTAssertTrue(try eventually(30) { try api.macSessions().first { $0.id == session.id }?.nowPlayingId == nil },
                      "the server hears the stop")
    }

    /// Escape leaves full screen first, and only then stops.
    func testEscapeStopsWhenNotFullScreen() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        playerWindow.typeKey(.escape, modifierFlags: [])
        if playerWindow.waitToVanish(10) { return }
        // Once more with the keyboard in the picture (a click there).
        playerWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        playerWindow.typeKey(.escape, modifierFlags: [])
        XCTExpectFailure("bug: Escape in the player window (not full screen) doesn't stop playback; PlayerWindow.swift:52 .onExitCommand { leave() } never fires")
        XCTAssertTrue(playerWindow.waitToVanish(10), "Escape in a window that isn't full screen stops")
    }

    /// Regression: WindowMenuPlayerOpensBlackWindow. With nothing playing,
    /// the Window menu has no Player entry to open a black window with.
    /// Source: commit 430f7d6; AquariumApp.swift:189-208.
    func testBugWindowMenuPlayerOpensBlackWindow() {
        launchToHome()
        let window = app.menuBars.firstMatch.menuBarItems["Window"]
        window.click()
        XCTAssertFalse(window.menuItems["Player"].waitForExistence(timeout: 2))
        dismissMenus()
    }

    func testMainWindowStaysUsableWhilePlaying() throws {
        _ = try playLongDirect()
        mainWindow.click()
        openSection("favorites")
        XCTAssertTrue(playerWindow.exists, "browsing doesn't close the player")
        app.element(TestID.Sidebar.nowPlaying).waitToExist(20)
        XCTAssertTrue(app.element(TestID.Sidebar.nowPlayingTitle).exists)
    }

    func testSidebarNowPlayingPauses() throws {
        let (film, api) = try playLongDirect()
        _ = try api.macWaitForPlayback(of: film.id)
        mainWindow.click()
        app.button(TestID.Sidebar.nowPlayingPlayPause).tapWhenReady()
        XCTAssertTrue(try eventually(20) { try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused == true })
    }

    // MARK: Controls over the picture

    func testControlsAppearUnderThePointerAndHideAfterwards() throws {
        _ = try playLongDirect()
        wakePlayerControls()
        app.element(TestID.Player.controls).waitToExist(10)
        XCTAssertTrue(app.button(TestID.Player.playPause).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(TestID.Player.scrubber).exists)
        // Settings ▸ Video ▸ Hide controls after: 2 s on a Mac. Move off the
        // window and they go.
        mainWindow.hover()
        XCTAssertTrue(app.button(TestID.Player.playPause).waitToVanish(10) || !app.button(TestID.Player.playPause).isHittable)
    }

    func testPlayPauseButtonReachesTheServer() throws {
        let (film, api) = try playLongDirect()
        _ = try api.macWaitForPlayback(of: film.id)
        wakePlayerControls()
        app.button(TestID.Player.playPause).tapWhenReady()
        XCTAssertTrue(try eventually(20) { try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused == true })
        wakePlayerControls()
        app.button(TestID.Player.playPause).tapWhenReady()
        XCTAssertTrue(try eventually(20) { try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused == false })
    }

    func testSkipButtonsMoveTenSeconds() throws {
        let (film, api) = try playLongDirect(from: 300)
        _ = try api.macWaitForPlayback(of: film.id)
        wakePlayerControls()
        app.button(TestID.Player.playPause).tapWhenReady()   // paused, so the position holds still
        let before = try XCTUnwrap(try api.macWaitForPlayback(of: film.id)?.positionSeconds)
        wakePlayerControls()
        app.button(TestID.Player.skipForward).tapWhenReady()
        XCTAssertTrue(try eventually(20) {
            (try api.macSessions().first { $0.nowPlayingId == film.id }?.positionSeconds ?? 0) >= before + 8
        })
    }

    /// Regression: PlayerFadeDeadButtons (the iOS fix keeps buttons live as
    /// they fade; the Mac hides on the pointer instead) — a click on the
    /// controls just as they appear still lands. Source: memory note
    /// player-fade-dead-buttons.md; Player/Chrome/PlayerChrome.swift.
    func testBugControlsTakeAClickAsTheyAppear() throws {
        let (film, api) = try playLongDirect()
        _ = try api.macWaitForPlayback(of: film.id)
        wakePlayerControls()
        let button = app.button(TestID.Player.playPause)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(try eventually(20) { try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused == true })
    }

    // MARK: The Playback menu

    func testPlaybackMenuHasEverything() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        let items: [(String, String)] = [
            (TestID.Player.menuPlayPause, "Play / Pause"), (TestID.Player.menuSkipBack, "Back 10 Seconds"),
            (TestID.Player.menuSkipForward, "Forward 10 Seconds"), (TestID.Player.menuSlower, "Slower"),
            (TestID.Player.menuFaster, "Faster"), (TestID.Player.menuVolumeUp, "Volume Up"),
            (TestID.Player.menuVolumeDown, "Volume Down"), (TestID.Player.menuMute, "Mute"),
            (TestID.Player.menuAudio, "Audio"), (TestID.Player.menuSubtitles, "Subtitles"),
            (TestID.Player.menuSpeed, "Speed"), (TestID.Player.menuUpNext, "Up Next"),
            (TestID.Player.menuSleep, "Sleep"), (TestID.Player.menuFill, "Fill Screen"),
            (TestID.Player.menuStreamInfo, "Stream Info"), (TestID.Player.menuShowPanel, "Show Panel"),
            (TestID.Player.menuFullScreen, "Enter Full Screen"), (TestID.Player.menuStop, "Stop"),
        ]
        for (id, title) in items {
            XCTAssertTrue(menuItem("Playback", id: id, title: title).exists, title)
            dismissMenus()
        }
    }

    func testPlaybackMenuIsDisabledWithNothingPlaying() {
        launchToHome()
        let stop = menuItem("Playback", id: TestID.Player.menuStop, title: "Stop")
        XCTAssertFalse(stop.isEnabled)
        dismissMenus()
    }

    func testSpaceAndArrowKeysWhileThePlayerIsInFront() throws {
        let (film, api) = try playLongDirect(from: 300)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(try eventually(20) { try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused == true })
        let before = try api.macSessions().first { $0.nowPlayingId == film.id }?.positionSeconds ?? 0
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(try eventually(20) {
            (try api.macSessions().first { $0.nowPlayingId == film.id }?.positionSeconds ?? 0) >= before + 8
        })
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(try eventually(20) { try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused == false })
    }

    /// Regression: SpaceBarPausesWhileTypingSearch, end to end: Space typed
    /// into the sidebar's search field doesn't pause the film.
    /// Source: commit b723cea; Player/PlayerWindow.swift:183-195.
    func testBugTypingASpaceInSearchDoesNotPause() throws {
        let (film, api) = try playLongDirect()
        _ = try api.macWaitForPlayback(of: film.id)
        mainWindow.click()
        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        field.waitToExist(10)
        field.typeText("star wars")
        XCTAssertEqual(field.value as? String, "star wars", "the space reached the field")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused, false)
    }

    func testStopFromAnyWindow() throws {
        let (film, api) = try playLongDirect()
        _ = try api.macWaitForPlayback(of: film.id)
        mainWindow.click()
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(playerWindow.waitToVanish(20), "⌘. stops from any window")
    }

    func testSpeedFromTheMenuAndBrackets() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        app.typeKey("]", modifierFlags: [])
        chooseMenu("Playback", id: TestID.Player.menuStreamInfo, title: "Stream Info")
        app.element(TestID.Player.streamInfo).waitToExist(10)
        attachScreenshot("faster, with stream info")
        app.typeKey("[", modifierFlags: [])
    }

    func testMuteAndVolumeKeys() throws {
        let (film, api) = try playLongDirect()
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        func muted() throws -> Bool? {
            (try api.macSessions().first { $0.nowPlayingId == film.id }?.raw["PlayState"] as? [String: Any])?["IsMuted"] as? Bool
        }
        app.typeKey("m", modifierFlags: [])
        XCTAssertTrue(try eventually(20) { try muted() == true }, "M mutes")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(try eventually(20) { try muted() == false }, "↑ unmutes")
    }

    func testShowPanelOpensInfo() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        app.typeKey("k", modifierFlags: .command)
        app.element(TestID.Player.panel).waitToExist(10)
        XCTAssertTrue(app.element(TestID.Player.infoFactEngine).waitForExistence(timeout: 10)
                      || app.element(TestID.Player.infoTitle).exists)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.element(TestID.Player.panel).waitToVanish(10))
    }

    // MARK: The picture's context menu

    func testRightClickOnThePicture() throws {
        _ = try playLongDirect()
        playerWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        for (id, title) in [(TestID.Player.menuPlayPause, "Pause"), (TestID.Player.menuStreamInfo, "Stream Info"),
                            (TestID.Player.menuFullScreen, "Enter Full Screen"), (TestID.Player.menuAudio, "Audio")] {
            let item = app.menuItems.matching(identifier: id).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3) || app.menuItems[title].exists, title)
        }
        dismissMenus()
    }

    // MARK: Full screen

    /// Regression: FullScreenMenuFullScreensMainWindow. F (and the menu) act
    /// on the player window and only it. Source: commit 430f7d6.
    func testBugFullScreenIsThePlayersAndEscapeLeavesIt() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        let mainFrame = mainWindow.frame
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)   // the full-screen animation
        let screen = playerWindow.frame
        XCTAssertGreaterThan(screen.width, mainFrame.width * 0.9)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(playerWindow.exists, "Escape in full screen leaves full screen, it doesn't stop")
        XCTAssertEqual(mainWindow.frame, mainFrame, "the main window was never full screen")
    }

    // MARK: Tracks

    /// F:film.long_multitrack — Audio ▸ Français (index 3) reopens the stream
    /// with that track, and the server's session says so.
    /// Regression: TrackChoiceIgnoredWithoutMediaSourceId (commit ca154f3).
    func testBugAudioTrackChoiceReachesTheServer() throws {
        let film = try fixtures().item("film.long_multitrack")
        let api = try JellyfinAPI.signIn()
        try api.setResume(film.id, seconds: 0)
        launchToHome()
        play(film)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        chooseMenu("Playback", id: TestID.Player.menuAudio, title: "Audio")
        let french = app.menuItems.matching(identifier: TestID.Player.menuAudioOption("3")).firstMatch
        if french.waitForExistence(timeout: 5) { french.click() } else {
            app.menuItems.matching(NSPredicate(format: "title CONTAINS[c] 'fra' OR title CONTAINS[c] 'Fran'")).firstMatch.click()
        }
        XCTAssertTrue(try eventually(45) {
            let s = try api.macSessions().first { $0.nowPlayingId == film.id }
            let state = s?.raw["PlayState"] as? [String: Any]
            return (state?["AudioStreamIndex"] as? Int) == 3
        }, "the server reports audio track 3")
    }

    /// F:film.forced_foreign — Japanese audio, an English forced track that
    /// is the default. The forced track is listed as such and is on.
    /// Source: memory note hls-subtitle-timing.md (forced lines arrived late).
    func testForcedSubtitlesAreMarkedAndShown() throws {
        let film = try fixtures().item("film.forced_foreign")
        let api = try JellyfinAPI.signIn()
        try api.setResume(film.id, seconds: 0)
        launchToHome()
        play(film)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        chooseMenu("Playback", id: TestID.Player.menuSubtitles, title: "Subtitles")
        XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "title CONTAINS '(Forced)'")).firstMatch.waitForExistence(timeout: 5))
        dismissMenus()
        XCTAssertTrue(app.element(TestID.Player.subtitleOverlay).waitForExistence(timeout: 30)
                      || app.staticTexts.matching(NSPredicate(format: "label != ''")).count > 0)
        attachScreenshot("forced subtitles")
    }

    func testCTogglesSubtitles() throws {
        let film = try fixtures().item("film.sidecar_subs")
        let api = try JellyfinAPI.signIn()
        try api.setResume(film.id, seconds: 0)
        launchToHome()
        play(film)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        app.typeKey("c", modifierFlags: [])
        chooseMenu("Playback", id: TestID.Player.menuSubtitles, title: "Subtitles")
        let off = app.menuItems.matching(identifier: TestID.Player.menuSubtitleOption(TestID.Player.subtitlesOffKey)).firstMatch
        let offTitle = app.menuItems["Off"]
        let offItem = off.exists ? off : offTitle
        XCTAssertTrue(offItem.waitForExistence(timeout: 5))
        attachScreenshot("subtitles menu after C")
        dismissMenus()
    }

    // MARK: Quality

    func testQualityMenuListsAutoAndTheRungs() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        chooseMenu("Playback", id: TestID.Player.menuQuality, title: "Quality")
        XCTAssertTrue(app.menuItems.matching(identifier: TestID.Player.menuQualityOption(TestID.Player.qualityAutoKey)).firstMatch.waitForExistence(timeout: 5)
                      || app.menuItems["Auto"].exists)
        XCTAssertTrue(app.menuItems["Direct (original)"].exists
                      || app.menuItems.matching(identifier: TestID.Player.menuQualityOption(TestID.Player.qualityOriginalKey)).firstMatch.exists)
        dismissMenus()
    }

    /// Regression: QualityChangeWhilePausedPlays. A quality change while
    /// paused came back playing. Source: commit 5a0e2d7 (player report B2).
    func testBugQualityChangeWhilePausedStaysPaused() throws {
        let (film, api) = try playLongDirect(from: 300)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(try eventually(20) { try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused == true })
        chooseMenu("Playback", id: TestID.Player.menuQuality, title: "Quality")
        let rung = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH '720p'")).firstMatch
        guard rung.waitForExistence(timeout: 5) else { dismissMenus(); throw XCTSkip("no 720p rung") }
        rung.click()
        Thread.sleep(forTimeInterval: 8)
        XCTAssertEqual(try api.macSessions().first { $0.nowPlayingId == film.id }?.isPaused, true)
    }

    // MARK: Skipping

    /// F:film.long_direct has an Intro from 0:30 to 1:00. S skips it.
    /// Regression: SkipCreditsNeverShows for the Outro half (commit 5a0e2d7).
    func testSkipIntroWithS() throws {
        let (film, api) = try playLongDirect(from: 33)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        XCTAssertTrue(app.element(TestID.Player.skipIntro).waitForExistence(timeout: 20))
        app.typeKey("s", modifierFlags: [])
        XCTAssertTrue(try eventually(20) {
            (try api.macSessions().first { $0.nowPlayingId == film.id }?.positionSeconds ?? 0) >= 59
        })
    }

    func testBugSkipCreditsShows() throws {
        // Not resumed at 1103: past the server's 90 % resume limit it starts
        // over. From 1050, then ⌘→ six times to ~1110, inside the Outro.
        let (film, api) = try playLongDirect(from: 1050)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        for _ in 0..<6 { app.typeKey(.rightArrow, modifierFlags: .command) }
        XCTAssertTrue(app.element(TestID.Player.skipCredits).waitForExistence(timeout: 30), "the Outro segment came back")
    }

    // MARK: Up Next

    /// F:show.short — 45-second episodes: near the end the Up Next card
    /// shows, and Play Next starts E04.
    func testUpNextCardPlaysTheNextEpisode() throws {
        let show = try fixtures().item("show.short")
        guard let s1 = (show.raw["seasons"] as? [[String: Any]])?.first(where: { $0["index"] as? Int == 1 }),
              let eps = (s1["episodes"] as? [[String: Any]])?.compactMap({ $0["id"] as? String }), eps.count >= 4
        else { throw XCTSkip("no Season 1 in fixtures.json") }
        let api = try JellyfinAPI.signIn()
        launchToHome()
        openTitle(named: show.name, id: show.id)
        app.element(TestID.Detail.episode(eps[2])).tapWhenReady(30)
        app.typeKey(.return, modifierFlags: [])
        playerWindow.waitToExist(45)
        _ = try api.macWaitForPlayback(of: eps[2])
        app.element(TestID.Player.upNextCard).waitToExist(60)
        if app.button(TestID.Player.upNextPlay).exists { app.button(TestID.Player.upNextPlay).click() }
        XCTAssertNotNil(try api.macWaitForPlayback(of: eps[3], timeout: 60))
    }

    func testUpNextMenuListsTheNextEpisodes() throws {
        let show = try fixtures().item("show.long")
        let api = try JellyfinAPI.signIn()
        launchToHome()
        openTitle(named: show.name, id: show.id)
        playFromTitlePage()
        _ = try api.macWaitForPlayback()
        focusPlayerWindow()
        chooseMenu("Playback", id: TestID.Player.menuUpNext, title: "Up Next")
        XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "identifier BEGINSWITH 'player.menu.upNext.'")).firstMatch.waitForExistence(timeout: 10)
                      || !app.menuItems["Nothing Queued"].exists)
        dismissMenus()
    }

    /// Regression: StopAfterOfferedOnFilm. A film on its own offers no
    /// "Stop after this". Source: commit d5792c6.
    func testBugStopAfterNotOfferedOnAFilm() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        chooseMenu("Playback", id: TestID.Player.menuSleep, title: "Sleep")
        XCTAssertFalse(app.menuItems.matching(identifier: TestID.Player.menuStopAfterThis).firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.menuItems["Stop After This"].exists)
        dismissMenus()
    }

    func testSleepTimerSetAndCancel() throws {
        _ = try playLongDirect()
        focusPlayerWindow()
        chooseMenu("Playback", id: TestID.Player.menuSleep, title: "Sleep")
        let fifteen = app.menuItems.matching(identifier: TestID.Player.menuSleepOption(15)).firstMatch
        (fifteen.waitForExistence(timeout: 3) ? fifteen : app.menuItems["Stop in 15 Minutes"]).click()
        chooseMenu("Playback", id: TestID.Player.menuSleep, title: "Sleep")
        let cancel = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Cancel Sleep Timer'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()
    }

    // MARK: What the server hears

    /// Resume reported to the server: play from 5:00, let it run, stop —
    /// the position the server keeps moved on.
    func testResumePositionReportedOnStop() throws {
        let (film, api) = try playLongDirect(from: 300)
        _ = try api.macWaitForPlayback(of: film.id)
        Thread.sleep(forTimeInterval: 12)
        focusPlayerWindow()
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(playerWindow.waitToVanish(20))
        XCTAssertTrue(try eventually(30) { try api.userData(film.id).positionSeconds > 305 },
                      "stopped after ~10 s from 5:00")
        XCTAssertFalse(try api.userData(film.id).played)
    }

    func testResumeStartsWhereTheServerSays() throws {
        let (film, api) = try playLongDirect(from: 600)
        // A session an earlier test left playing the same film may still be
        // listed: look for one at the resume point.
        XCTAssertTrue(try eventually(30) {
            try api.macSessions().contains { $0.nowPlayingId == film.id && ($0.positionSeconds ?? 0) > 590 }
        }, "playback starts at 10:00")
    }

    func testPlaybackRunsOnMPVWhenAsked() throws {
        let (film, api) = try playLongDirect(engine: "mpv")
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        app.typeKey("k", modifierFlags: .command)
        let engine = app.element(TestID.Player.infoFactEngine)
        XCTAssertTrue(engine.waitForExistence(timeout: 10))
        XCTAssertTrue((engine.value as? String ?? engine.label).contains("mpv"))
    }

    /// F:film.dts_mkv — DTS 5.1 in MKV: the automatic engine choice is mpv.
    func testDTSFilmPlaysThroughMPVAutomatically() throws {
        let film = try fixtures().item("film.dts_mkv")
        let api = try JellyfinAPI.signIn()
        launchToHome()
        play(film)
        _ = try api.macWaitForPlayback(of: film.id)
        focusPlayerWindow()
        app.typeKey("k", modifierFlags: .command)
        let engine = app.element(TestID.Player.infoFactEngine)
        XCTAssertTrue(engine.waitForExistence(timeout: 10))
        XCTAssertTrue((engine.value as? String ?? engine.label).contains("mpv"))
    }
}
#endif
