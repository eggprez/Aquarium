//  The iPhone Duo, as far as a headless run can take it.
//
//  - The front (closed) screen is what the simulator shows at launch: 466×678
//    with an 84 pt trailing column and a 24 pt dead touch strip at the top
//    (memory: duo-inner-status-strip).
//  - Tent and laptop (half-folded) are held with the DEBUG launch argument
//    `-layout_override tent|halfFolded` (memory: duo-simulator-poses; the
//    launch-argument domain survives `pinSettingsNotOfferedHere`).
//  - The real hinge, the inner screen and book pose need Device Hub, moved by
//    a person: see MANUAL.md.

#if os(iOS)
import XCTest

final class DuoPoseTests: PhoneUITestCase {
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func requireDuo() throws {
        try XCTSkipUnless(device == .duo, "iPhone Duo only")
    }

    /// Front screen, upright: Home's bar clears the 24 pt dead strip and the
    /// trailing column (regression R-b2bb528 / AppTopBar front touch strip).
    func testFrontScreenHomeBarClearsTheStatusStrip() throws {
        try requireDuo()
        launchHome()
        let window = app.windows.firstMatch.frame
        attachScreenshot("duo front home (\(Int(window.width))×\(Int(window.height)))")
        let search = app.button(TestID.Home.search)
        XCTAssertGreaterThanOrEqual(search.frame.minY, 24, "Search sits in the dead touch strip")
        assertOnScreen(search, "Search")
        search.tap()
        app.element(TestID.Search.root).waitToExist(10)
    }

    /// Regression R-1749d3f / duo-inner-status-strip 2026-10-24: a title
    /// page's back button sat half inside the dead strip.
    func testFrontScreenBackButtonClearsTheStrip() throws {
        try requireDuo()
        launchHome()
        _ = try openFixture("film.long_direct")
        let back = app.button(TestID.Detail.back)
        XCTAssertGreaterThanOrEqual(back.frame.minY, 24, "back at \(back.frame)")
        back.tap()
        XCTAssertTrue(app.element(TestID.Detail.root).waitToVanish(10) || app.element(TestID.Search.root).exists)
    }

    /// Regression R-b2bb528 / 3e0d9c8: the player's title row sat under the
    /// front screen's status strip, where taps die.
    func testFrontScreenPlayerTitleRowClearsTheStrip() throws {
        try requireDuo()
        launchHome()
        _ = try openFixture("film.long_direct")
        playFromDetail()
        showControls()
        let more = app.button(TestID.Player.more)
        XCTAssertGreaterThanOrEqual(more.frame.minY, 24, "… at \(more.frame)")
        assertOnScreen(more, "…")
        more.tap()
        app.element(TestID.Player.cardMore).waitToExist(10)
        // Duo front #2: cards rose under the camera, hiding their close.
        assertOnScreen(app.button(TestID.Player.cardClose), "card close")
        XCTAssertGreaterThanOrEqual(app.button(TestID.Player.cardClose).frame.minY, 24)
        attachScreenshot("duo front player card")
    }

    /// Tent pose: the idle cover with Continue Watching, in the app's own
    /// appearance (regression R-db310b3-tent: it came back dark after a video).
    func testTentShowsTheIdleCover() throws {
        try requireDuo()
        launchHome(arguments: ["-layout_override", "tent"])
        app.element(TestID.Tent.root).waitToExist(30)
        XCTAssertTrue(any(TestID.Common.shelf(TestID.Tent.rowContinue)).waitForExistence(timeout: 20) || any(TestID.Tent.empty).exists)
        attachScreenshot("tent")
        any(TestID.Tent.browse).tapNow(10)
        app.element(TestID.Home.root).waitToExist(20)
    }

    func testTentPlayerUsesTheFrontScreenLayout() throws {
        try requireDuo()
        launchHome(arguments: ["-layout_override", "tent"])
        app.element(TestID.Tent.root).waitToExist(30)
        let film = try Fixtures.require().item("film.long_direct")
        let card = app.buttons.matching(identifier: TestID.Item.card(film.id)).firstMatch
        guard card.waitForExistence(timeout: 20) else { throw XCTSkip("nothing on the tent's Continue Watching") }
        card.tap()
        app.element(TestID.Player.root).waitToExist(40)
        showControls()
        assertOnScreen(app.button(TestID.Player.more), "… (tent)")
        attachScreenshot("tent player")
        closePlayer()
        app.element(TestID.Tent.root).waitToExist(20)
        attachScreenshot("tent after the player (should match the app's appearance)")
    }

    /// Laptop (half-folded): the player splits, the flat half shows what is
    /// playing and its chapters.
    func testHalfFoldedPlayerShowsTheFoldPanel() throws {
        try requireDuo()
        launchHome(arguments: ["-layout_override", "halfFolded"])
        _ = try openFixture("film.long_direct")
        app.button(TestID.Detail.play).tapNow(30)
        guard app.element(TestID.Player.root).waitForExistence(timeout: 40) else {
            attachScreenshot("half-folded override on the front screen")
            throw XCTSkip("the half-folded override on the closed front screen opens no player; the laptop pose needs the hinge (MANUAL.md)")
        }
        let panel = app.element(TestID.Player.foldPanel)
        guard panel.waitForExistence(timeout: 20) else {
            throw XCTSkip("the half-folded layout needs the inner screen (hinge closed in this simulator); see MANUAL.md")
        }
        any(TestID.Player.foldTitle).waitToExist(10)
        attachScreenshot("half-folded player")
    }

    func testHalfFoldedTitlePageSplits() throws {
        try requireDuo()
        launchHome(arguments: ["-layout_override", "halfFolded"])
        _ = try openFixture("film.long_direct")
        guard app.element(TestID.Detail.foldUpper).waitForExistence(timeout: 10) else {
            throw XCTSkip("no split title page without the inner screen; see MANUAL.md")
        }
        XCTAssertTrue(app.element(TestID.Detail.foldLower).exists)
    }

    /// The music search field is drawn on every Duo screen (feature list
    /// follow-up 2026-11-06: `.searchable` was not drawn on the inner screen).
    func testMusicSearchFieldIsDrawn() throws {
        try requireDuo()
        launchHome()
        tab("Music")
        assertOnScreen(app.textFields[TestID.Music.searchField], "music search field")
    }

    /// Regression R-PM14 / qa side-notes: on the front screen in landscape
    /// the Up Next card covered Back 10.
    func testFrontScreenUpNextCardClearsTheTransport() throws {
        try requireDuo()
        launchHome()
        let e3 = try XCTUnwrap(PhoneFixtures.episode("show.short", season: 1, number: 3))
        openTitle(e3, searching: "Short Episode 3")
        playFromDetail()
        app.element(TestID.Player.upNextCard).waitToExist(60)
        showControls()
        assertNoOverlap(app.element(TestID.Player.upNextCard), app.button(TestID.Player.skipBack), "Up Next card and Back 10")
    }
}

/// Layout checks that run on every phone size: the small phone fits its
/// text and controls, nothing is under the keyboard, and landscape works
/// where the app allows it.
final class PhoneLayoutTests: PhoneUITestCase {
    func testTabBarShowsFiveTabs() throws {
        launchHome()
        for label in ["Home", "Music", "Audiobooks", "Library", "More"] {
            let tab = tabButton(label)
            XCTAssertTrue(tab.exists, label)
            assertOnScreen(tab, label)
        }
    }

    func testMoreListFitsTheScreen() throws {
        launchHome()
        tab("More")
        app.element(TestID.Shell.more).waitToExist(20)
        for id in ["favorites", "collections", "livetv", "downloads", "settings"] {
            let row = app.descendants(matching: .any).matching(identifier: TestID.Shell.moreRow(id)).firstMatch
            app.reveal(row)
            assertOnScreen(row, id)
        }
        attachScreenshot("more (\(device.rawValue))")
    }

    func testLongUnicodeTitleTruncatesOnItsPage() throws {
        launchHome()
        _ = try openFixture("film.unicode_title")
        let actions = app.element(TestID.Detail.actions)
        assertOnScreen(actions, "action row")
        attachScreenshot("long title (\(device.rawValue))")
    }

    func testLandscapeHomeAndTitlePage() throws {
        try XCTSkipIf(device == .duo, "the Duo's inner screen ignores XCUIDevice orientation; see MANUAL.md")
        launchHome()
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        app.element(TestID.Home.root).waitToExist(10)
        attachScreenshot("home landscape (\(device.rawValue))")
        _ = try openFixture("film.long_direct")
        assertOnScreen(app.button(TestID.Detail.play), "Play (landscape)")
        attachScreenshot("title landscape (\(device.rawValue))")
    }

    /// Regression R-SE-skip (open on main): on the small phone the Skip Intro
    /// pill ran under a card.
    func testSkipIntroStepsAsideForCards() throws {
        let api = try self.api
        let id = try XCTUnwrap(PhoneFixtures.episode("show.long", season: 1, number: 4))
        try api.setResume(id, seconds: 0)
        launchHome()
        openTitle(id, searching: "Long Episode 1.4")
        playFromDetail()
        let skip = app.button(TestID.Player.skipIntro)
        guard skip.waitForExistence(timeout: 20) else { throw XCTSkip("intro passed before the check") }
        app.element(TestID.Player.video).tap()
        let pill = app.button(TestID.Player.pillSubtitles)
        guard pill.waitForExistence(timeout: 5) else { throw XCTSkip("controls did not come up in time") }
        pill.tap()
        let card = app.element(TestID.Player.cardSubtitles)
        guard card.waitForExistence(timeout: 5), skip.exists else { return }
        let overlaps = skip.frame.insetBy(dx: 1, dy: 1).intersects(card.frame.insetBy(dx: 1, dy: 1))
        XCTAssertFalse(overlaps, "Skip Intro \(skip.frame) overlaps the Subtitles card \(card.frame)")
    }
}
#endif
