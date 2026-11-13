//  Regressions for problems found on an iPad, each named after its bug and
//  citing where it was recorded. Those still open on main are wrapped in
//  XCTExpectFailure("bug: …") so the suite stays green while they are, and
//  turns their expected failure into an unexpected pass once fixed.
//
//  Sources: git log (6344432 "iPad: hero first page…", d5792c6 "iPad hero
//  fix", 5a0e2d7, a6fcf5c), qa-2026-11-11-player/REPORT.md, the side-session
//  master-fix-list.md / fix-status.md / ipad-qa-findings.md (2026-11-03), and
//  the memory notes named on each test.

#if os(iOS)
import XCTest

final class PadRegressionTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    // MARK: Home's hero

    /// 6344432: "The page view gave only the first page the sidebar's safe
    /// area, so the first title of every draw sat 105 pt right of the rest."
    /// Every page's Play must sit at the same place within its page.
    func testHeroFirstPageSitsWhereTheOthersDo() throws {
        launchHome()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            turn(orientation)
            let pages = app.elements(prefix: "home.hero.page.").allElementsBoundByIndex
            XCTAssertTrue(waitUntil(20, "the hero's pages") { pages.count > 0 && pages[0].frame.width > 0 })
            try XCTSkipIf(pages.count < 2, "one hero page")
            var offsets: [CGFloat] = []
            for page in pages {
                let id = String(page.identifier.dropFirst("home.hero.page.".count))
                let play = app.button(TestID.Home.heroPlay(id))
                guard play.exists else { continue }
                offsets.append(play.frame.minX - page.frame.minX)
            }
            XCTAssertGreaterThanOrEqual(offsets.count, 2)
            let spread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
            XCTAssertLessThan(spread, 2, "Play sits \(offsets) into its page (\(orientation.isLandscape ? "landscape" : "portrait"))")
        }
    }

    /// d5792c6: "Hero carousel uses a plain HStack so iPad pages take their
    /// real width" (a lazy stack left "six slivers side by side with their
    /// buttons crushed"). Each page is the bar's width plus the sidebar it
    /// runs under; none is a sliver.
    func testHeroPagesTakeTheirRealWidth() throws {
        launchHome()
        turn(.landscapeLeft)
        let hero = app.element(TestID.Home.hero)
        hero.waitToExist(30)
        let pages = app.elements(prefix: "home.hero.page.").allElementsBoundByIndex
        try XCTSkipIf(pages.isEmpty, "no hero")
        let window = app.frame
        for page in pages {
            XCTAssertEqual(page.frame.width, window.width, accuracy: 2,
                           "\(page.identifier) is \(page.frame.width) wide in a \(window.width) window")
            let id = String(page.identifier.dropFirst("home.hero.page.".count))
            XCTAssertGreaterThan(app.button(TestID.Home.heroPlay(id)).frame.width, 60, "Play is not crushed")
        }
    }

    /// 30cbbc2: "Home's hero timer restarts on every page turn and stops
    /// while Home is out of sight." With a title pushed over Home the bar
    /// does not turn behind it.
    func testHeroDoesNotTurnBehindAPushedTitle() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        let current = app.elements(prefix: "home.hero.currentPage.").firstMatch
        current.waitToExist(30)
        let card = cardButton(film.id)
        XCTAssertTrue(reveal(card))
        card.padTap()
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
        // Home's anchor stays in the tree under the pushed page; its page
        // index must not move while it is hidden.
        let before = current.exists ? current.identifier : ""
        try XCTSkipIf(before.isEmpty, "Home's hero leaves the tree under a pushed page")
        // Waits out more than the 8 s turn for a change that must not come.
        let turned = eventually(12) {
            let now = self.app.elements(prefix: "home.hero.currentPage.").firstMatch
            return now.exists && now.identifier != before
        }
        XCTAssertFalse(turned, "the hero turned while a title was over Home")
    }

    // MARK: Title pages

    /// master-fix-list.md iPad: "Portrait title page: Quality wraps alone
    /// onto a second row" (every title with a Trailer). Fixed on
    /// claude/qa-fix-list-cb0b58 (4775e86), not on main.
    func testQualityDoesNotWrapAloneBesideThePosterInPortrait() throws {
        let film = try fx.item("film.extras")   // has trailers
        launchHome()
        openItem(film.id)
        let quality = app.button(TestID.Detail.quality)
        quality.waitToExist(20)
        let others = [TestID.Detail.play, TestID.Detail.favorite, TestID.Detail.watched, TestID.Detail.trailer]
            .map { app.button($0) }.filter(\.exists)
        let alone = !others.contains { abs($0.frame.minY - quality.frame.minY) < 12 }
        attachScreenshot("portrait actions")
        XCTExpectFailure("bug: Quality wraps alone onto its own row in portrait (4775e86 not on main)", strict: false)
        XCTAssertFalse(alone, "Quality shares a row with another action")
    }

    /// ipad-qa-findings.md bug 10 / master-fix-list: "Raw server paths in
    /// errors for qa-kid: a blocked title reads 'Server error 404 on
    /// /Items/…' with Try again". Fixed on claude/qa-fix-list-cb0b58
    /// (4775e86, "An item this account can't see offers no Try again"), not on main.
    func testBlockedTitleSaysSoInPlainWords() throws {
        guard let kid = QA.account(named: "fx-kid") else { throw XCTSkip("no fx-kid password") }
        let blocked = try fx.item("film.rated_r")
        launch(account: kid)
        app.element(TestID.Home.root).waitToExist(60)
        XCUIDevice.shared.system.open(URL(string: "aquarium://item/\(blocked.id)")!)
        let error = app.element(TestID.Detail.error)
        XCTAssertTrue(error.waitForExistence(timeout: 30), "a blocked title's page shows its error")
        let words = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        attachScreenshot("blocked title")
        XCTExpectFailure("bug: blocked title shows the raw server path and Try again (4775e86 not on main)", strict: false)
        XCTAssertFalse(words.contains("/Items/"), "raw path in: \(words)")
        XCTAssertFalse(app.button(TestID.Common.errorStateRetry).exists, "Try again can't help a 404")
    }

    // MARK: Sidebar

    /// master-fix-list.md iPad: "Default text size: 'Home Videos & Phot…'
    /// truncates in the sidebar". Fixed on claude/qa-fix-list-cb0b58
    /// (4775e86, "two-line a long name"), not on main. The row's text gets
    /// less width than the same words in Home's chip.
    func testLongLibraryNameIsNotCutInTheSidebar() throws {
        let homeVideos = try fx.libraryId("Home Videos & Photos")
        launchHome()
        let row = app.button(TestID.Sidebar.row("lib-\(homeVideos)"))
        row.waitToExist(30)
        let chip = app.button(TestID.Library.chip(homeVideos))
        XCTAssertTrue(reveal(chip))
        let rowText = row.staticTexts["Home Videos & Photos"]
        let chipText = chip.staticTexts["Home Videos & Photos"]
        guard rowText.exists, chipText.exists else { throw XCTSkip("text elements not exposed") }
        let lines = rowText.frame.height / 18
        let cut = lines < 1.5 && rowText.frame.width < chipText.frame.width * 0.85
        XCTExpectFailure("bug: 'Home Videos & Photos' truncated in the sidebar (4775e86 not on main)", strict: false)
        XCTAssertFalse(cut, "row text \(rowText.frame.size) vs chip text \(chipText.frame.size)")
    }

    // MARK: Player

    /// QA 2026-11-11 B4, fixed 5a0e2d7: "Toasts are drawn over the player on
    /// iPhone and iPad. They were under it." Watch Together with no FaceTime
    /// call says "Start a FaceTime call first".
    func testPlayerMessagesShowOverThePlayer() throws {
        let film = try fx.item("film.hevc_mp4")
        launchHome()
        play(film.id)
        waitForPlaying()
        _ = openCardFor(TestID.Player.more, TestID.Player.cardMore)
        let together = app.button(TestID.Player.sharePlayStart)
        try XCTSkipUnless(reveal(together, in: app.element(TestID.Player.cardMore)), "no Watch Together row")
        together.padTap()
        let toast = app.element(TestID.Shell.toastText)
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "the player's message is seen")
        XCTAssertTrue(player.exists)
        attachScreenshot("toast over player")
    }

    /// QA 2026-11-11 B6, fixed 5a0e2d7: "A quality change silently turns off
    /// 'Stop after this episode'."
    func testStopAfterThisSurvivesAQualityChange() throws {
        let e3 = try episode("show.short", season: 1, episode: 3)
        launchHome()
        play(e3.id)
        waitForPlaying()
        _ = openCardFor(TestID.Player.more, TestID.Player.cardMore)
        let stop = app.button(TestID.Player.stopAfterThis)
        reveal(stop, in: app.element(TestID.Player.cardMore))
        stop.padTap()
        _ = openCardFor(TestID.Player.pillQuality, TestID.Player.cardQuality)
        let rungs = app.elements(prefix: "player.quality.option.").allElementsBoundByIndex
            .filter { !$0.identifier.hasSuffix(".auto") && !$0.identifier.hasSuffix(".original") }
        guard let rung = rungs.last else { return XCTFail("no rungs") }
        rung.padTap()
        waitForPlaying(60)
        tapControl(TestID.Player.pillInfo)
        let after = app.element(TestID.Player.infoFact("after-this"))
        XCTAssertTrue(after.waitForExistence(timeout: 15), "'After this: Stop' kept across the reopen")
    }

    /// Memory player-fade-dead-buttons.md (58f77cf): the controls must take
    /// a tap for as long as they can be seen. Deterministic part: a pill
    /// pressed while the controls are up opens its card (the timed tap at
    /// the edge of the fade is in MANUAL.md).
    func testPillTakesATapWhileTheControlsAreUp() throws {
        let film = try fx.item("film.hevc_mp4")
        launchHome()
        play(film.id)
        waitForPlaying()
        showControls()
        app.button(TestID.Player.pillAudio).padTap()
        XCTAssertTrue(app.element(TestID.Player.cardAudio).waitForExistence(timeout: 5))
    }

    /// master-fix-list.md iPad "Chosen sidecar SRT never draws on the Apple
    /// engine, 3 of 3" (fixed on main by b5c81c7, "A sidecar subtitle
    /// delivered in the HLS manifest was never matched to its menu entry").
    /// Choosing the English sidecar must leave it chosen (Info) after the reopen.
    func testChosenSidecarSubtitleStaysChosen() throws {
        let film = try fx.item("film.sidecar_subs")
        launchHome()
        play(film.id)
        waitForPlaying(60)
        _ = openCardFor(TestID.Player.pillSubtitles, TestID.Player.cardSubtitles)
        let rows = app.elements(prefix: "player.subtitles.option.").allElementsBoundByIndex
            .filter { $0.identifier != TestID.Player.subtitlesOff }
        guard let spanish = rows.first(where: { $0.label.localizedCaseInsensitiveContains("Spa") }) else {
            return XCTFail("no Spanish sidecar among \(rows.map(\.label))")
        }
        spanish.padTap()
        waitForPlaying(60)
        tapControl(TestID.Player.pillInfo)
        let subs = app.element(TestID.Player.infoFact("subtitles"))
        XCTAssertTrue(waitUntil(30, "Info to name the Spanish track") { self.text(subs).localizedCaseInsensitiveContains("Spa") })
    }

    private func openCardFor(_ pill: String, _ card: String) -> XCUIElement {
        tapControl(pill)
        let element = app.element(card)
        element.waitToExist(15)
        return element
    }
}
#endif
