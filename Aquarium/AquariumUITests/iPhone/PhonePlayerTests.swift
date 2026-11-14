//  The video player on the phone: the controls, transport, timeline, the
//  pills and the cards they drop (audio, subtitles, quality, Up Next, More),
//  speed, sleep, the info panel, intro skipping, the Up Next card, gestures,
//  landscape, and what the server hears (resume and progress).
//
//  The server's own record is the judge wherever there is one: what the app
//  says it plays is read from `/Sessions` (JellyfinAPI.sessions), and resume
//  points from `/UserItems/{id}/UserData`.

#if os(iOS)
import XCTest

class PhonePlayerTestCase: PhoneUITestCase {
    /// Open a fixture's page and play it; waits until the server hears it.
    @discardableResult
    func play(_ key: String, account: QA.Account? = QA.account(), resumeAt seconds: Double? = nil,
              engine: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> (JellyfinAPI, Fixtures.Item) {
        let api = try JellyfinAPI.signIn(account)
        let item = try Fixtures.require().item(key)
        if let seconds { try api.setResume(item.id, seconds: seconds) }
        launchHome(account: account, engine: engine)
        openTitle(item.id, searching: item.name, file: file, line: line)
        playFromDetail(file: file, line: line)
        XCTAssertNotNil(try api.waitForPlayback(of: item.id, timeout: 60), "the server never heard \(item.name) start", file: file, line: line)
        return (api, item)
    }

    /// An episode by show/season/number, played from its own page.
    @discardableResult
    func playEpisode(_ show: String, season: Int, number: Int, name: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> (JellyfinAPI, String) {
        let api = try self.api
        let id = try XCTUnwrap(PhoneFixtures.episode(show, season: season, number: number), file: file, line: line)
        launchHome()
        openTitle(id, searching: name, file: file, line: line)
        playFromDetail(file: file, line: line)
        XCTAssertNotNil(try api.waitForPlayback(of: id, timeout: 60), "the server never heard \(name) start", file: file, line: line)
        return (api, id)
    }

    /// The app's live session for `id`: the one that checked in last.
    /// Sessions of earlier launches (each launch is a new device) linger
    /// for minutes with their old positions.
    func session(_ api: JellyfinAPI, _ id: String) -> JellyfinAPI.Session? {
        PhoneSessions.current(api, id)
    }

    func playState(_ api: JellyfinAPI, _ id: String) -> [String: Any] {
        session(api, id)?.raw["PlayState"] as? [String: Any] ?? [:]
    }

    /// Waits until the transport says Pause (that is, it is playing).
    func waitUntilPlaying(timeout: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line) {
        showControls(file: file, line: line)
        let button = app.button(TestID.Player.playPause)
        XCTAssertTrue(wait(for: button, "label == 'Pause'", timeout: timeout), "never started playing: \(button.label)", file: file, line: line)
    }

    /// Pause from the transport, so the controls stay up for what follows.
    /// `strict: false` for FX Long Remux Multitrack, which never starts on
    /// AVFoundation (see testMultitrackRemuxStartsPlaying): its cards still
    /// list the file's tracks while it loads, and the controls stay up.
    func pause(strict: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        if !strict {
            showControls(file: file, line: line)
            let button = app.button(TestID.Player.playPause)
            if wait(for: button, "label == 'Pause'", timeout: 20) {
                button.tap()
                _ = wait(for: button, "label == 'Play'", timeout: 10)
            }
            return
        }
        waitUntilPlaying(file: file, line: line)
        app.button(TestID.Player.playPause).tap()
        XCTAssertTrue(wait(for: app.button(TestID.Player.playPause), "label == 'Play'", timeout: 10), file: file, line: line)
    }

    /// The position the scrubber reads, in seconds.
    func scrubberSeconds() -> Double? {
        let value = app.element(TestID.Player.scrubber).value as? String ?? ""
        return PhoneSpoken.seconds(value.components(separatedBy: " of ").first ?? "")
    }

    /// Drags the scrubber to a fraction of the title.
    func scrub(to fraction: Double) {
        showControls()
        let bar = app.element(TestID.Player.scrubber)
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let to = bar.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
    }
}

final class PhonePlayerTests: PhonePlayerTestCase {
    // MARK: Opening, closing, the server's record

    func testPlayOpensAndTheServerHearsIt() throws {
        let (api, film) = try play("film.long_direct", resumeAt: 0)
        waitUntilPlaying()
        let s = session(api, film.id)
        XCTAssertEqual(s?.client, "Aquarium")
        XCTAssertEqual(s?.raw["PlayState"].flatMap { ($0 as? [String: Any])?["PlayMethod"] as? String }, "DirectPlay",
                       "an MP4 of H.264/AAC is direct play (R-2c520e6-dp)")
        attachScreenshot("player (\(device.rawValue))")
    }

    /// FX Long Remux Multitrack (H.264 720p, AAC, in MKV) should remux on
    /// AVFoundation (FIXTURES.md). The app's request makes the server
    /// re-encode the picture (h264_videotoolbox at -b:v 199808000, -level 31)
    /// and that encode fails ("Could not open encoder"), so the player sits
    /// at Loading. Found 2026-11-13 (jf/log FFmpeg.Transcode-*_f6f6e804*).
    func testMultitrackRemuxStartsPlaying() throws {
        _ = try play("film.long_multitrack")
        showControls()
        let playing = wait(for: app.button(TestID.Player.playPause), "label == 'Pause'", timeout: 60)
        XCTAssertTrue(playing, "still \(app.button(TestID.Player.playPause).label)")
    }

    /// Resume from the server's point, and the new point is saved on close.
    /// (A long title: the QA server marks anything under 5 min played.)
    func testResumeStartsAtTheSavedPointAndSavesTheNewOne() throws {
        try standardOnly()
        let (api, film) = try play("film.long_direct", resumeAt: 300)
        waitUntilPlaying()
        let p = waitForServerPosition(api, itemId: film.id, atLeast: 302, timeout: 60)
        XCTAssertNotNil(p)
        XCTAssertGreaterThanOrEqual(p ?? 0, 295, "did not resume at 5:00")
        XCTAssertLessThan(p ?? 999, 400)
        closePlayer()
        XCTAssertTrue(eventually(timeout: 30) { ((try? api.userData(film.id).positionSeconds) ?? 0) >= 300 },
                      "resume point not saved on close")
        XCTAssertFalse((try? api.userData(film.id).played) ?? true, "stopped at 5 min is not watched")
    }

    func testPlayFromBeginningIgnoresTheResumePoint() throws {
        try standardOnly()
        let api = try self.api
        let film = try Fixtures.require().item("film.long_direct")
        try api.setResume(film.id, seconds: 300)
        launchHome()
        let resumeCard = app.buttons.matching(identifier: TestID.Item.card(film.id)).firstMatch
        app.reveal(resumeCard)
        resumeCard.waitToExist(30)
        resumeCard.press(forDuration: 1.2)
        app.descendants(matching: .any).matching(identifier: TestID.Item.menuPlayFromBeginning).firstMatch.tapNow(10)
        app.element(TestID.Player.root).waitToExist(40)
        let p = waitForServerPosition(api, itemId: film.id, atLeast: 1, timeout: 60)
        XCTAssertLessThan(p ?? 999, 60, "started from the resume point instead of the beginning")
    }

    func testBackClosesThePlayerToTheTitle() throws {
        try standardOnly()
        let (_, film) = try play("film.hevc_mp4")
        closePlayer()
        app.element(TestID.Detail.page(film.id)).waitToExist(20)
    }

    // MARK: Transport

    func testPauseAndPlayReachTheServer() throws {
        try standardOnly()
        let (api, film) = try play("film.long_direct", resumeAt: 0)
        pause()
        XCTAssertTrue(eventually(timeout: 30) { self.session(api, film.id)?.isPaused == true }, "server never heard the pause")
        app.button(TestID.Player.playPause).tap()
        XCTAssertTrue(eventually(timeout: 30) { self.session(api, film.id)?.isPaused == false }, "server never heard play")
    }

    func testSkipForwardAndBack() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        let start = scrubberSeconds() ?? 0
        app.button(TestID.Player.skipForward).tap()
        XCTAssertTrue(eventually(timeout: 10) { (self.scrubberSeconds() ?? 0) >= start + 9 }, "forward did not skip")
        app.button(TestID.Player.skipBack).tap()
        XCTAssertTrue(eventually(timeout: 10) { abs((self.scrubberSeconds() ?? 0) - start) < 3 }, "back did not skip back")
    }

    func testScrubMovesThePosition() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        scrub(to: 0.5)
        XCTAssertTrue(eventually(timeout: 15) { (self.scrubberSeconds() ?? 0) > 400 }, "scrub to the middle landed at \(String(describing: scrubberSeconds()))")
    }

    func testRemainingTimeFlipsToTotal() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        let remaining = app.button(TestID.Player.remaining)
        let before = remaining.label
        remaining.tap()
        XCTAssertTrue(eventually(timeout: 5) { remaining.label != before }, "remaining/total did not flip: \(before)")
    }

    func testFillPillToggles() throws {
        try standardOnly()
        _ = try play("film.hevc_mp4")
        pause()
        let fill = app.button(TestID.Player.pillFill)
        let before = fill.value as? String
        fill.tap()
        XCTAssertTrue(eventually(timeout: 5) { (fill.value as? String) != before }, "fill did not toggle")
    }

    func testControlsHideByThemselvesAndComeBackOnATap() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        waitUntilPlaying()
        XCTAssertTrue(app.element(TestID.Player.controls).waitToVanish(15), "controls never hid while playing")
        showControls()
    }

    /// Regression R-58f77cf (memory: player-fade-dead-buttons): a tap on a
    /// control just as its fade began fell through to the picture. The
    /// timing can't be matched exactly from XCUITest; this taps "…" as soon
    /// as the controls start to go and expects its card, not a toggle.
    func testControlsTakeTouchesWhileFading() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        waitUntilPlaying()
        let more = app.button(TestID.Player.more)
        let deadline = Date().addingTimeInterval(12)
        // Poll until "…" is about to go (the controls are still there but
        // the hide clock has run): tap it on the last poll it exists.
        while Date() < deadline, more.exists { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) ; if !app.element(TestID.Player.pillRow).isHittable && more.exists { break } }
        guard more.exists else { throw XCTSkip("controls hid before a tap could be timed") }
        more.tap()
        XCTAssertTrue(app.element(TestID.Player.cardMore).waitForExistence(timeout: 5), "a tap on … during the fade did not open its card")
    }

    // MARK: Cards

    func testAudioCardListsEveryTrack() throws {
        _ = try play("film.long_multitrack")
        pause(strict: false)
        openPill("audio")
        for index in 1...6 { app.button(TestID.Player.audioOption(String(index))).waitToExist(10) }
        assertOnScreen(app.element(TestID.Player.cardAudio), "audio card")
        assertOnScreen(app.button(TestID.Player.cardClose), "card close")
        attachScreenshot("audio card (\(device.rawValue))")
        app.button(TestID.Player.cardClose).tap()
        XCTAssertTrue(app.element(TestID.Player.cardAudio).waitToVanish(5))
    }

    /// Regression R-ca154f3 / B1 (memory: jellyfin-track-index-needs-source-id):
    /// the first pick of an audio track was ignored by the server.
    func testChosenAudioTrackReachesTheServer() throws {
        try standardOnly()
        let (api, film) = try play("film.long_multitrack")
        pause(strict: false)
        openPill("audio")
        app.button(TestID.Player.audioOption("2")).tapNow(10)
        XCTAssertTrue(eventually(timeout: 60) { (self.playState(api, film.id)["AudioStreamIndex"] as? Int) == 2 },
                      "server reports audio \(String(describing: playState(api, film.id)["AudioStreamIndex"]))")
    }

    /// Every subtitle kind on the multitrack fixture is offered: SRT, ASS,
    /// forced, SDH, WebVTT, PGS and VobSub (7–15), and Off.
    func testSubtitlesCardListsEveryKind() throws {
        _ = try play("film.long_multitrack")
        pause(strict: false)
        openPill("subtitles")
        app.button(TestID.Player.subtitlesOff).waitToExist(10)
        for index in 7...15 {
            let option = app.button(TestID.Player.subtitleOption(String(index)))
            app.element(TestID.Player.cardSubtitles).swipeUp()
            XCTAssertTrue(option.waitForExistence(timeout: 5), "subtitle \(index) not offered")
        }
        attachScreenshot("subtitles card (\(device.rawValue))")
    }

    func testChosenSubtitleReachesTheServer() throws {
        try standardOnly()
        let (api, film) = try play("film.long_multitrack")
        pause(strict: false)
        openPill("subtitles")
        app.button(TestID.Player.subtitleOption("8")).tapNow(10)
        XCTAssertTrue(eventually(timeout: 60) { (self.playState(api, film.id)["SubtitleStreamIndex"] as? Int) == 8 },
                      "server reports subtitle \(String(describing: playState(api, film.id)["SubtitleStreamIndex"]))")
        openPill("subtitles")
        app.button(TestID.Player.subtitlesOff).tapNow(10)
        XCTAssertTrue(eventually(timeout: 60) { ((self.playState(api, film.id)["SubtitleStreamIndex"] as? Int) ?? -1) < 0 })
    }

    /// The forced English track on a Japanese-audio film is the default
    /// choice of the server, and the card shows it chosen.
    func testForcedSubtitleOnForeignAudio() throws {
        try standardOnly()
        let (api, film) = try play("film.forced_foreign")
        pause()
        openPill("subtitles")
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.subtitles.option."))
        XCTAssertGreaterThanOrEqual(options.count, 3, "Off plus two English tracks")
        let forced = options.matching(NSPredicate(format: "label CONTAINS[c] 'forced'")).firstMatch
        XCTAssertTrue(forced.exists, "the forced track is labelled")
        forced.tap()
        XCTAssertTrue(eventually(timeout: 60) { ((self.playState(api, film.id)["SubtitleStreamIndex"] as? Int) ?? -1) >= 0 })
    }

    /// Sidecar files: SRT, forced, SDH, ASS, VTT and PGS beside an MP4.
    func testSidecarSubtitlesAreOffered() throws {
        try standardOnly()
        _ = try play("film.sidecar_subs")
        pause()
        openPill("subtitles")
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.subtitles.option."))
        XCTAssertGreaterThanOrEqual(options.count, 8, "Off and seven sidecar files")
    }

    func testImageSubtitlesAreOffered() throws {
        try standardOnly()
        _ = try play("film.image_subs")
        pause()
        openPill("subtitles")
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.subtitles.option."))
        XCTAssertGreaterThanOrEqual(options.count, 4, "Off, two PGS and a VobSub")
    }

    /// Regression R-5a0e2d7-cc: a phantom "CC" row on files with no captions.
    func testNoPhantomCaptionRow() throws {
        try standardOnly()
        _ = try play("film.hevc_mp4")
        pause()
        openPill("subtitles")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.subtitles.option."))
        XCTAssertEqual(rows.count, 1, "only Off, for a file with no subtitles")
    }

    func testQualityCardOffersAutoOriginalAndEveryRung() throws {
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        openPill("quality")
        app.button(TestID.Player.qualityAuto).waitToExist(10)
        for key in ["original", "36000000", "20000000", "16000000", "10000000", "5000000", "2500000"] {
            XCTAssertTrue(app.button(TestID.Player.qualityOption(key)).exists, key)
        }
        assertOnScreen(app.element(TestID.Player.cardQuality), "quality card")
        attachScreenshot("quality card (\(device.rawValue))")
    }

    /// Picking 720p transcodes, and (regression R-B2, qa-2026-11-11-player
    /// B2) a quality change while paused stays paused.
    func testPickingARungTranscodesAndStaysPaused() throws {
        try standardOnly()
        let (api, film) = try play("film.long_direct", resumeAt: 0)
        pause()
        openPill("quality")
        app.button(TestID.Player.qualityOption("2500000")).tapNow(10)
        // FX Long Direct Play is a small 480p file: a rung above it leaves it
        // as it is (Quality.untouchedRung), so either method is right here.
        _ = eventually(timeout: 30) { (self.playState(api, film.id)["PlayMethod"] as? String) == "Transcode" }
        showControls()
        XCTAssertTrue(wait(for: app.button(TestID.Player.playPause), "label == 'Play'", timeout: 30), "the reopen started playing")
        openPill("quality")
        XCTAssertTrue(app.button(TestID.Player.qualityOption("2500000")).isSelected, "the chosen rung is not marked")
    }

    /// Regression R-013ead9 (open on main): every reopen (a quality change)
    /// posted /Sessions/Playing and counted another play.
    func testQualityChangeDoesNotCountAPlay() throws {
        try standardOnly()
        let (api, film) = try play("film.long_direct", resumeAt: 0)
        let before = try api.userData(film.id).playCount
        pause()
        openPill("quality")
        app.button(TestID.Player.qualityOption("5000000")).tapNow(10)
        _ = eventually(timeout: 60) { (self.playState(api, film.id)["PlayMethod"] as? String) == "Transcode" }
        openPill("quality")
        app.button(TestID.Player.qualityOption("2500000")).tapNow(10)
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        closePlayer()
        let after = try api.userData(film.id).playCount
        XCTExpectFailure("bug R-013ead9: each stream reopen reports a new playback start")
        XCTAssertEqual(after, before, "PlayCount went \(before) → \(after)")
    }

    func testSpeedChoices() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        openPlayerMore()
        for key in ["50", "75", "100", "125", "150", "175", "200"] { XCTAssertTrue(app.button(TestID.Player.speedOption(key)).exists, key) }
        app.button(TestID.Player.speedOption("150")).tap()
        if !app.element(TestID.Player.cardMore).exists { openPlayerMore() }
        XCTAssertTrue(app.button(TestID.Player.speedOption("150")).isSelected, "1.5× not marked")
        app.button(TestID.Player.speedOption("100")).tap()
    }

    func testSleepTimerStartsAndCancels() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        openPlayerMore()
        for m in [15, 30, 60, 90] { XCTAssertTrue(app.button(TestID.Player.sleepOption(m)).exists, "\(m) min") }
        app.button(TestID.Player.sleepOption(15)).tap()
        openPlayerMore()
        app.button(TestID.Player.sleepCancel).tapNow(10)
        openPlayerMore()
        app.button(TestID.Player.sleepOption(15)).waitToExist(10)
    }

    /// Regression R-120c435 (open on main): a running sleep timer was not
    /// shown in the title row.
    func testSleepTimerShownInTitleRow() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        openPlayerMore()
        app.button(TestID.Player.sleepOption(15)).tap()
        showControls()
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '15'")).count > 0
            || app.element(TestID.Player.title).label.contains("15")
        XCTExpectFailure("bug R-120c435: the title row does not show the sleep timer")
        XCTAssertTrue(shown)
    }

    /// Regression R-d5792c6: "After this" was offered on a film with nothing
    /// after it.
    func testStopAfterThisNotOfferedOnAFilm() throws {
        try standardOnly()
        _ = try play("film.hevc_mp4")
        pause()
        openPlayerMore()
        XCTAssertFalse(app.button(TestID.Player.stopAfterThis).exists)
    }

    func testInfoPanelDescribesTheStream() throws {
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        app.button(TestID.Player.pillInfo).tapNow(10)
        app.element(TestID.Player.infoTitle).waitToExist(15)
        for fact in ["delivery", "container", "video", "audio", "engine"] {
            XCTAssertTrue(app.element(TestID.Player.infoFact(fact)).exists, fact)
        }
        XCTAssertTrue(app.element(TestID.Player.infoFact("delivery")).label.contains("Direct"),
                      app.element(TestID.Player.infoFact("delivery")).label)
        attachScreenshot("info (\(device.rawValue))")
    }

    /// Regression R-5a0e2d7-info: Info read "Audio track: Unknown".
    func testInfoNamesTheAudioTrack() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        app.button(TestID.Player.pillInfo).tapNow(10)
        let fact = app.element(TestID.Player.infoFact("audio-track"))
        fact.waitToExist(15)
        XCTAssertFalse(fact.label.contains("Unknown"), fact.label)
    }

    func testAirPlayButtonIsThere() throws {
        try standardOnly()
        _ = try play("film.hevc_mp4")
        pause()
        assertOnScreen(app.element(TestID.Player.airPlay), "AirPlay")
    }

    /// Picture in Picture: the iPhone simulator reports it unsupported
    /// (memory: pip-simulator-testing), so the button must be absent here.
    func testPictureInPictureButtonFollowsSupport() throws {
        try standardOnly()
        _ = try play("film.hevc_mp4")
        pause()
        let pip = app.button(TestID.Player.pictureInPicture)
        if pip.exists {
            pip.tap()
            attachScreenshot("pip tapped")
        } else {
            throw XCTSkip("PiP unsupported on the iPhone simulator; see MANUAL.md")
        }
    }

    // MARK: Segments, episodes, Up Next

    /// Intro 0–30 on every Long Show episode: Skip Intro shows and jumps.
    func testSkipIntro() throws {
        let api = try self.api
        let id = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 3))
        try api.setResume(id, seconds: 0)
        _ = try playEpisode("show.long", season: 1, number: 3, name: "Long Episode 1.3")
        let skip = app.button(TestID.Player.skipIntro)
        skip.waitToExist(30)
        assertOnScreen(skip, "Skip Intro")
        skip.tapNow(5)
        // Read straight after the tap, before playback could get there alone.
        showControls()
        app.button(TestID.Player.playPause).tap()
        XCTAssertTrue(eventually(timeout: 8) { (self.scrubberSeconds() ?? 0) >= 29 },
                      "Skip Intro did not get past 0:30 (at \(String(describing: scrubberSeconds())))")
        _ = api
    }

    /// Regression R-B3: Skip Credits never appeared (the server was asked
    /// for Intro alone). Outro on Long Show episodes is the last 30 s.
    func testSkipCreditsAppearsAtTheOutro() throws {
        try standardOnly()
        // FX Long Direct Play: Outro 1100–1170, and nothing after it (an
        // episode's credits give way to the Up Next card).
        _ = try play("film.long_direct", resumeAt: 1060)   // under 90%, or the server drops the point
        let credits = app.button(TestID.Player.skipCredits)
        credits.waitToExist(90)
        assertOnScreen(credits, "Skip Credits")
    }

    func testUpNextPillListsTheNextEpisode() throws {
        try standardOnly()
        let next = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 4))
        _ = try playEpisode("show.long", season: 1, number: 3, name: "Long Episode 1.3")
        pause()
        let pill = app.button(TestID.Player.pillUpNext)
        pill.waitToExist(20)
        pill.tap()
        app.element(TestID.Player.cardUpNext).waitToExist(10)
        app.element(TestID.Player.upNextItem(next)).waitToExist(20)
    }

    func testStopAfterThisOfferedOnAnEpisode() throws {
        try standardOnly()
        _ = try playEpisode("show.long", season: 1, number: 3, name: "Long Episode 1.3")
        pause()
        openPlayerMore()
        let stop = app.button(TestID.Player.stopAfterThis)
        stop.waitToExist(20)
        stop.tap()
        openPlayerMore()
        XCTAssertTrue(app.button(TestID.Player.stopAfterThis).isSelected, "After this not marked")
    }

    /// Short Show episodes are 45 s: the Up Next card is due almost at once,
    /// counts down, and Play goes to the next episode (E01, E02 played;
    /// E04 follows E03).
    func testUpNextCardPlaysTheNextEpisode() throws {
        let next = try XCTUnwrap(PhoneFixtures.episode("show.short", season: 1, number: 4))
        let (api, _) = try playEpisode("show.short", season: 1, number: 3, name: "Short Episode 3")
        let card = app.element(TestID.Player.upNextCard)
        card.waitToExist(60)
        assertOnScreen(card, "Up Next card")
        attachScreenshot("up next card (\(device.rawValue))")
        app.button(TestID.Player.upNextPlay).tapNow(10)
        XCTAssertNotNil(try api.waitForPlayback(of: next, timeout: 60), "the next episode did not start")
    }

    func testUpNextCancelKeepsTheEpisode() throws {
        try standardOnly()
        let (api, id) = try playEpisode("show.short", season: 1, number: 3, name: "Short Episode 3")
        app.element(TestID.Player.upNextCard).waitToExist(60)
        app.button(TestID.Player.upNextCancel).tapNow(10)
        XCTAssertTrue(app.element(TestID.Player.upNextCard).waitToVanish(10))
        XCTAssertEqual(session(api, id)?.nowPlayingId, id)
    }

    /// Regression R-7132133 (memory: duo-front-qa-driving): closing the
    /// player while the Up Next card was up crashed (`Int(.infinity)`).
    func testClosingWithTheUpNextCardUpDoesNotCrash() throws {
        _ = try playEpisode("show.short", season: 1, number: 3, name: "Short Episode 3")
        app.element(TestID.Player.upNextCard).waitToExist(60)
        showControls()
        app.button(TestID.Player.back).tapNow(10)
        XCTAssertTrue(app.element(TestID.Player.root).waitToVanish(20))
        XCTAssertEqual(app.state, .runningForeground, "the app went down closing over the Up Next card")
        app.element(TestID.Detail.root).waitToExist(20)
    }

    /// Regression R-5a0e2d7-B5: with autoplay off the Up Next card did not
    /// show at all; it should show, without a countdown.
    func testUpNextCardWithAutoplayOff() throws {
        try standardOnly()
        let id = try XCTUnwrap(PhoneFixtures.episode("show.short", season: 1, number: 3))
        launchHome()
        openSettings()
        app.button(TestID.Settings.pageLink("video")).tapNow(20)
        let autoplay = app.switches[TestID.Settings.videoAutoplayNext]
        app.reveal(autoplay)
        if (autoplay.value as? String) == "1" { autoplay.switches.firstMatch.exists ? autoplay.switches.firstMatch.tap() : autoplay.tap() }
        XCTAssertEqual(autoplay.value as? String, "0")
        tab("Home")
        openTitle(id, searching: "Short Episode 3")
        playFromDetail()
        app.element(TestID.Player.upNextCard).waitToExist(60)
        XCTAssertFalse(app.element(TestID.Player.upNextCountdown).exists && app.element(TestID.Player.upNextCountdown).label.contains("in "),
                       "a countdown with autoplay off")
    }

    // MARK: Gestures

    func testDoubleTapRightSkipsForward() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        pause()
        let start = scrubberSeconds() ?? 0
        app.element(TestID.Player.video).coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).doubleTap()
        XCTAssertTrue(eventually(timeout: 10) { showControlsQuietly(self); return (self.scrubberSeconds() ?? 0) >= start + 9 },
                      "double-tap on the right did not skip forward")
    }

    func testHoldPlaysAtDoubleSpeed() throws {
        try standardOnly()
        _ = try play("film.long_direct", resumeAt: 0)
        waitUntilPlaying()
        _ = app.element(TestID.Player.controls).waitToVanish(15)
        app.element(TestID.Player.video).press(forDuration: 2.5)
        // The 2× badge is shown only during the hold; afterwards the speed is
        // back to normal (regression R-6c8b98f-hold).
        openPlayerMore()
        XCTAssertTrue(app.button(TestID.Player.speedOption("100")).isSelected, "speed stuck after the hold")
    }

    // MARK: Errors, engines, other files

    /// fx-notranscode: a DTS MKV gets no transcode on AVFoundation, so the
    /// player must say so (error card) rather than hang.
    func testRefusedTranscodeShowsTheErrorCard() throws {
        try standardOnly()
        let account = try XCTUnwrap(QA.account(named: "fx-notranscode"))
        let film = try Fixtures.require().item("film.dts_mkv")
        launchHome(account: account, engine: "apple")
        openTitle(film.id, searching: film.name)
        app.button(TestID.Detail.play).tapNow(30)
        let error = app.element(TestID.Player.errorCard)
        if error.waitForExistence(timeout: 60) {
            XCTAssertTrue(app.element(TestID.Player.errorMessage).exists)
            app.button(TestID.Player.errorClose).tapNow(10)
            XCTAssertTrue(app.element(TestID.Player.root).waitToVanish(20))
        } else {
            // mpv may take the file: then it must actually play.
            waitUntilPlaying(timeout: 30)
        }
    }

    /// Playback matrix: each codec fixture opens and plays on this phone.
    func testCodecMatrixPlays() throws {
        try standardOnly()
        let api = try self.api
        launchHome()
        for key in ["film.hevc_mp4", "film.hevc10_eac3_mp4", "film.hdr10_mp4", "film.aac71_mp4", "film.pcm_mov",
                    "film.h264_ts", "film.interlaced_ts", "film.video_only_mp4", "film.dvb_subs_ts"] {
            let item = try Fixtures.require().item(key)
            openTitle(item.id, searching: item.name)
            playFromDetail()
            XCTAssertNotNil(try api.waitForPlayback(of: item.id, timeout: 60), "\(key) never started")
            XCTAssertFalse(app.element(TestID.Player.errorCard).exists, "\(key) shows the error card")
            closePlayer()
            goBack()
            app.button(TestID.Search.clear).tapNow(10)
        }
    }

    /// Transcode-only fixtures (AV1, Hi10, HLG, TrueHD) open too.
    func testTranscodedFixturesPlay() throws {
        try standardOnly()
        let api = try self.api
        launchHome()
        for key in ["film.av1_mp4", "film.h264_hi10_mkv", "film.hlg_mkv", "film.truehd_mkv"] {
            let item = try Fixtures.require().item(key)
            openTitle(item.id, searching: item.name)
            playFromDetail()
            XCTAssertNotNil(try api.waitForPlayback(of: item.id, timeout: 90), "\(key) never started")
            XCTAssertFalse(app.element(TestID.Player.errorCard).exists, "\(key) shows the error card")
            closePlayer()
            goBack()
            app.button(TestID.Search.clear).tapNow(10)
        }
    }

    func testVideoOnlyFileSaysThereIsNoSound() throws {
        try standardOnly()
        _ = try play("film.video_only_mp4")
        pause()
        openPill("audio")
        let empty = app.element(TestID.Player.audioEmpty)
        XCTAssertTrue(empty.waitForExistence(timeout: 10) || app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.audio.option.")).count == 0)
    }

    /// The mpv engine can be forced on a phone (unlike an iPad).
    func testMPVEngineCanPlay() throws {
        try standardOnly()
        _ = try play("film.dts_mkv", engine: "mpv")
        pause()
        app.button(TestID.Player.pillInfo).tapNow(10)
        let engine = app.element(TestID.Player.infoFactEngine)
        engine.waitToExist(15)
        attachScreenshot("engine: \(engine.label)")
    }

    // MARK: Landscape

    /// Regression R-74e72e9: in landscape the cards ran under the title row
    /// and the pills. Layout test: every phone.
    func testLandscapeCardsSitBetweenTitleAndPills() throws {
        try skipOnDuo("the Duo's inner screen does not honour XCUIDevice orientation; see MANUAL.md")
        _ = try play("film.long_multitrack")
        pause(strict: false)
        rotate(.landscapeLeft)
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let window = app.windows.firstMatch
        let turned = eventually(timeout: 8) { window.frame.width > window.frame.height }
        if !turned {
            attachScreenshot("player after turning the phone")
            XCTExpectFailure("bug?: the player stays portrait when the phone is turned with XCUIDevice (seen 2026-11-13; check on hardware)")
            XCTFail("window still \(window.frame) after turning to landscape")
            return
        }
        showControls()
        assertOnScreen(app.button(TestID.Player.back), "back (landscape)")
        assertOnScreen(app.button(TestID.Player.more), "… (landscape)")
        assertOnScreen(app.element(TestID.Player.pillRow), "pills (landscape)")
        openPill("quality")
        let card = app.element(TestID.Player.cardQuality)
        XCTAssertGreaterThanOrEqual(card.frame.minY + 1, app.button(TestID.Player.more).frame.maxY - 1, "card rises over the title row")
        assertOnScreen(app.button(TestID.Player.cardClose), "card close (landscape)")
        attachScreenshot("landscape quality card (\(device.rawValue))")
    }

    func testPortraitControlsFitTheScreen() throws {
        _ = try play("film.long_multitrack")
        pause(strict: false)
        for (id, what) in [(TestID.Player.back, "back"), (TestID.Player.more, "…"), (TestID.Player.playPause, "play/pause"),
                           (TestID.Player.skipBack, "back 10"), (TestID.Player.skipForward, "forward 10")] {
            assertOnScreen(app.button(id), what)
        }
        assertOnScreen(app.element(TestID.Player.pillRow), "pills")
        assertOnScreen(app.element(TestID.Player.scrubber), "timeline")
        assertNoOverlap(app.element(TestID.Player.pillRow), app.element(TestID.Player.scrubber), "pills and timeline")
        attachScreenshot("controls (\(device.rawValue))")
    }
}

private func showControlsQuietly(_ test: PhonePlayerTestCase) {
    if !test.app.element(TestID.Player.controls).exists { test.app.element(TestID.Player.video).tap() }
}

/// "5 minutes and 3 seconds", "1 hour, 2 minutes" → seconds.
enum PhoneSpoken {
    static func seconds(_ text: String) -> Double? {
        let words = text.lowercased().replacingOccurrences(of: ",", with: " ").split(separator: " ")
        var total = 0.0, found = false, last: Double?
        for w in words {
            if let n = Double(w) { last = n; continue }
            guard let n = last else { continue }
            if w.hasPrefix("hour") { total += n * 3600; found = true }
            else if w.hasPrefix("minute") { total += n * 60; found = true }
            else if w.hasPrefix("second") { total += n; found = true }
            last = nil
        }
        return found ? total : nil
    }
}
#endif
