//  Browsing on the Apple TV: the Library tab and one library's grid,
//  Collections, Search, title pages (films, versions, extras and trailers,
//  shows with seasons and episodes), and a person's page.

#if os(tvOS)
import XCTest

final class TVBrowseTests: TVTestCase {
    // MARK: Library

    private func openLibrary(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let id = try Fixtures.require().libraryId(name)
        launchHome(file: file, line: line)
        openTab("libraries", title: "Library", anchor: TestID.Library.listRoot, file: file, line: line)
        Remote.press(.down)
        let tile = app.element(TestID.Library.tile(id))
        XCTAssertTrue(Remote.focus(on: tile, in: app), "no \(name) tile reachable", file: file, line: line)
        Remote.select()
        app.element(TestID.Library.page(id)).waitToExist(20, file: file, line: line)
        // Opens with nothing focused (testALibraryScreenOpensWithFocus); a
        // press brings it back, and the rest of each test goes on from there.
        XCTAssertTrue(recoverFocus(), "no focus on \(name)'s grid even after a press", file: file, line: line)
        return id
    }

    func testALibraryScreenOpensWithFocus() throws {
        // Seen in every run of this suite (2026-11-13): Fixture Films, Fixture
        // Photos and Collections open from the Library tab with no element
        // focused (no card lifted; XCUITest finds nothing with hasFocus) until
        // the remote is pressed. The title screen (`detailRoot`) holding a
        // library has no default focus, unlike a title page.
        let id = try Fixtures.require().libraryId("Fixture Films")
        launchHome()
        openTab("libraries", title: "Library", anchor: TestID.Library.listRoot)
        Remote.press(.down)
        XCTAssertTrue(Remote.focus(on: app.element(TestID.Library.tile(id)), in: app))
        Remote.select()
        app.element(TestID.Library.page(id)).waitToExist(20)
        app.element(TestID.Library.count).waitToExist(20)
        let focusedOnOpen = waitUntil("a card focused on opening", timeout: 10, fail: false) { [weak self] in self?.focused != nil }
        attachScreenshot("Fixture Films on opening")
        XCTExpectFailure("bug: a library opened from the Library tab (AppModel.push → detailRoot .library, LibraryView on tvOS) shows no focused card until a remote press; focus is lost on arrival")
        XCTAssertTrue(focusedOnOpen, "nothing focused on the library grid")
    }

    func testLibraryTabListsTheVideoLibrariesOnly() throws {
        let fx = try Fixtures.require()
        launchHome()
        openTab("libraries", title: "Library", anchor: TestID.Library.listRoot)
        for name in ["Fixture Films", "Fixture Shows", "Fixture Photos", "Collections"] {
            XCTAssertTrue(app.element(TestID.Library.tile(try fx.libraryId(name))).exists, "no \(name) tile")
        }
        // No music or books on a TV (FEATURE-LIST.md; master-fix-list asks to
        // confirm Music and Books are meant to be absent — this pins it).
        for name in ["Fixture Music", "Music", "Fixture Books", "Books"] {
            XCTAssertFalse(app.element(TestID.Library.tile(try fx.libraryId(name))).exists, "\(name) offered on the TV")
        }
    }

    func testAFilmLibraryGridOpensATitle() throws {
        _ = try openLibrary("Fixture Films")
        app.element(TestID.Library.count).waitToExist(20)
        XCTAssertTrue(focusedID.hasPrefix("item.card."), "grid opened with focus on \(focused?.summary ?? "nothing")")
        let opened = String(focusedID.dropFirst("item.card.".count))
        Remote.select()
        app.element(TestID.Detail.page(opened)).waitToExist(20)
        assertFocusPresent("a title from the grid")
        Remote.menu()
        app.element(TestID.Library.root).waitToExist(10)
        waitUntil("focus back on the card", timeout: 10) { [weak self] in self?.focusedID == TestID.Item.card(opened) }
    }

    func testTheGridKeepsPagingPastTheFirstPage() throws {
        // Regression (17206fe): the library grid stalled at 60. The Fixture
        // Films library is small, so this checks the count reads whole.
        _ = try openLibrary("Fixture Films")
        let count = app.element(TestID.Library.count)
        count.waitToExist(20)
        let numbers = count.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if numbers.count >= 2 { XCTAssertEqual(numbers[0], numbers[1], "\(count.label): not every title loaded") }
    }

    func testCollectionsOpenAndListTheirTitles() throws {
        let fx = try Fixtures.require()
        _ = try openLibrary("Collections")
        let sets = fx.raw["sets"] as? [String: Any]
        let collection = (sets?["FX Collection"] as? [String: Any])?["id"] as? String ?? ""
        let card = app.element(TestID.Item.card(collection))
        XCTAssertTrue(Remote.focus(on: card, in: app), "FX Collection not in Collections")
        Remote.select()
        let members = (sets?["FX Collection"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        for member in members {
            guard let id = member["id"] as? String else { continue }
            app.element(TestID.Item.card(id)).waitToExist(20)
        }
        if !waitUntil("focus on FX Collection", timeout: 10, fail: false, { [weak self] in self?.focused != nil }) {
            XCTExpectFailure("bug: a collection opened from Collections shows nothing focused until a remote press (same as a library grid)") {
                XCTFail("nothing focused on FX Collection")
            }
            XCTAssertTrue(recoverFocus(), "no focus on FX Collection even after a press")
        }
    }

    func testFolderOfPhotosOpensItsContents() throws {
        // Source: master-fix-list.md "[TV] Folder tiles open an empty page;
        // Play shows a raw 'Server error 400'; photos unreachable".
        _ = try openLibrary("Fixture Photos")
        attachScreenshot("Fixture Photos")
        // A folder is a card with a count badge rather than a running time:
        // the one that isn't FX Home Clip.
        let clip = (try Fixtures.require().raw["fixtures"] as? [String: Any]).flatMap { $0["photos"] as? [[String: Any]] }?
            .first { $0["name"] as? String == "FX Home Clip" }?["id"] as? String ?? ""
        let cards = app.elements(prefix: "item.card.")
        waitUntil("the library's cards", timeout: 20) { cards.count >= 2 }
        guard let folder = cards.allElementsBoundByIndex.first(where: { $0.identifier != TestID.Item.card(clip) }) else {
            return XCTFail("no folder in Fixture Photos")
        }
        let folderId = folder.identifier
        XCTAssertTrue(Remote.focus(on: folder, in: app))
        Remote.select()
        let opened = waitUntil("the folder's contents", timeout: 20, fail: false) { [weak self] in
            guard let self else { return false }
            return self.app.elements(prefix: "item.card.").count > 2 && !self.app.element(folderId).exists
        }
        attachScreenshot("the folder opened")
        XCTAssertTrue(opened, "the folder showed none of its contents")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Server error'")).firstMatch.exists)
        XCTAssertFalse(app.element(TestID.Library.empty).exists, "the folder opened empty")
    }

    // MARK: Search

    private func search(_ term: String, file: StaticString = #filePath, line: UInt = #line) {
        launchHome(file: file, line: line)
        openTab("search", title: "Search", anchor: TestID.Search.root, file: file, line: line)
        Remote.press(.down)
        let field = app.element(TestID.Search.field)
        XCTAssertTrue(Remote.focus(on: field, in: app), file: file, line: line)
        Remote.select()
        waitUntil("the keyboard", timeout: 10, file: file, line: line) { [weak self] in
            (self?.app.keyboards.count ?? 0) > 0 || (self?.focused?.elementType == .key)
        }
        app.typeText(term)
        Remote.menu()
    }

    func testSearchFindsTheLongFixtures() throws {
        let fx = try Fixtures.require()
        search("FX Long")
        app.element(TestID.Search.results).waitToExist(30)
        for key in ["film.long_direct", "film.long_multitrack", "show.long"] {
            app.element(TestID.Item.card(try fx.item(key).id)).waitToExist(20)
        }
        assertFocusPresent("search results")
        attachScreenshot("search FX Long")
    }

    func testSearchFindsAUnicodeTitle() throws {
        let id = try Fixtures.require().item("film.unicode_title").id
        search("Unicode")
        app.element(TestID.Item.card(id)).waitToExist(30)
    }

    func testSearchWithNoMatchSaysSo() {
        search("zzqqxx no such title")
        app.element(TestID.Search.empty).waitToExist(30)
        assertFocusPresent("an empty search")
    }

    func testSearchOffersNoMusicOnTheTV() throws {
        // FEATURE-LIST.md: "Mac and Apple TV have no music results at all".
        search("FX Band")
        let results = app.element(TestID.Search.results)
        let empty = app.element(TestID.Search.empty)
        waitUntil("an answer", timeout: 30) { results.exists || empty.exists }
        XCTAssertFalse(app.element(TestID.Search.musicResults).exists)
    }

    // MARK: Title pages

    func testAFilmPageHasEverythingAndFocusStartsOnPlay() throws {
        let film = try Fixtures.require().item("film.long_direct")
        launchDetail(film.id)
        // The name is the title's logo when it has one (FX Long Direct Play
        // does), so the typeset title may be absent: the hero carries it.
        XCTAssertTrue(app.element(TestID.Detail.title).exists || app.element(TestID.Detail.hero).exists, "no title or hero")
        for id in [TestID.Detail.overview, TestID.Detail.play, TestID.Detail.quality,
                   TestID.Detail.favorite, TestID.Detail.watched] {
            XCTAssertTrue(app.element(id).waitForExistence(timeout: 10), "\(id) missing")
        }
        XCTAssertEqual(focusedID, TestID.Detail.play, "the page should open on Play")
        XCTAssertTrue(app.element(TestID.Detail.facts).exists || app.element(TestID.Detail.genres).exists)
        // Down goes through the page and Up comes all the way back.
        press(.down, until: { [unowned self] in self.focusedID.hasPrefix("detail.cast.person.") }, max: 6)
        XCTAssertTrue(focusedID.hasPrefix("detail.cast.person."), "cast not reachable (on \(focused?.summary ?? "nothing"))")
        XCTAssertTrue(press(.up, until: { [unowned self] in self.focusedID == TestID.Detail.play || self.focusedID.hasPrefix("detail.action") }, max: 8),
                      "Up never came back to the buttons (regression faa8a89)")
    }

    func testQualityDialogListsTheRungsAndCancels() throws {
        let film = try Fixtures.require().item("film.long_direct")
        launchDetail(film.id)
        XCTAssertTrue(Remote.focus(on: app.button(TestID.Detail.quality), in: app))
        Remote.select()
        app.element(TestID.Detail.qualityCancel).waitToExist(10)
        for bitrate in [nil, 36_000_000, 10_000_000, 2_500_000] as [Int?] {
            XCTAssertTrue(app.element(TestID.Detail.qualityOption(bitrate)).exists, "no \(bitrate.map(String.init) ?? "original") rung")
        }
        Remote.menu()
        XCTAssertTrue(app.element(TestID.Detail.qualityCancel).waitToVanish(10))
        XCTAssertEqual(focusedID, TestID.Detail.quality)
    }

    func testQualityDialogPlaysAtTheChosenRung() throws {
        let film = try Fixtures.require().item("film.long_direct")
        launchDetail(film.id)
        XCTAssertTrue(Remote.focus(on: app.button(TestID.Detail.quality), in: app))
        Remote.select()
        let rung = app.element(TestID.Detail.qualityOption(2_500_000))
        rung.waitToExist(10)
        if !Remote.focus(on: rung, in: app, maxPresses: 10) {
            // The dialog's buttons don't report focus to XCUITest; they run
            // Original, 4K, 1440p, 1080p·16, 1080p·10, 720p, 480p from the top,
            // and the dialog opens on the first.
            Remote.press(.up, times: 8)
            Remote.press(.down, times: 6)
        }
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        let api = try self.api()
        waitUntil("a transcode session", timeout: 60) {
            guard let s = try? api.tvSessions().first(where: { $0.nowPlayingId == film.id }) else { return false }
            return (s.raw["PlayState"] as? [String: Any])?["PlayMethod"] as? String == "Transcode"
        }
    }

    func testFavoriteAndWatchedReachTheServer() throws {
        let film = try Fixtures.require().item("film.pcm_mov")
        let api = try self.api()
        try api.resetItem(film.id)
        defer { try? api.resetItem(film.id) }
        launchDetail(film.id)
        XCTAssertTrue(Remote.focus(on: app.button(TestID.Detail.favorite), in: app))
        Remote.select()
        waitUntil("favourite on the server", timeout: 15) { (try? api.userData(film.id).favorite) == true }
        XCTAssertTrue(Remote.focus(on: app.button(TestID.Detail.watched), in: app))
        Remote.select()
        waitUntil("played on the server", timeout: 15) { (try? api.userData(film.id).played) == true }
        assertFocusPresent("the title page after the toggles")
    }

    func testVersionsCanBeChosen() throws {
        // Source: master-fix-list.md "[TV, Pro Max #6] Multiple versions not
        // selectable"; fix-status.md verified a "Version" choice on the SE only.
        let film = try Fixtures.require().item("film.versions")
        launchDetail(film.id)
        attachScreenshot("FX Versions")
        // A control, not the title ("FX Versions") or its genre ("Versions").
        let version = app.buttons.matching(NSPredicate(
            format: "(label BEGINSWITH[c] 'version' OR identifier CONTAINS[c] 'version') AND NOT (label CONTAINS 'FX Versions')")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5), "no version choice on a title with 3 versions")
    }

    func testTrailerButtonOnAFilmWithLocalTrailersPlaysOne() throws {
        let film = try Fixtures.require().item("film.extras")
        launchDetail(film.id)
        let trailer = app.button(TestID.Detail.trailer)
        trailer.waitToExist(15)
        XCTAssertTrue(Remote.focus(on: trailer, in: app))
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        let api = try self.api()
        let local = (film.raw["localTrailers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        waitUntil("a trailer playing", timeout: 45) {
            guard let s = try? api.tvSessions().first(where: { $0.nowPlayingId != nil }) else { return false }
            return local.isEmpty || local.contains(s.nowPlayingId ?? "")
        }
    }

    func testAShowOpensOnPlayAndDownStartsTheSeasonsAtTheFirst() throws {
        // Regressions: e565adf (series page opens on Play, not Favorite) and
        // a2aa13b (Down from the buttons starts the seasons at the first
        // season, not the one under the middle of the button row). FX Long
        // Show's first season on the shelf is Specials.
        let fx = try Fixtures.require()
        let show = try fx.item("show.long")
        let specials = try fx.season("show.long", 0)
        let season1 = try fx.season("show.long", 1)
        launchDetail(show.id)
        waitUntil("focus on Play", timeout: 15) { [weak self] in self?.focusedID == TestID.Detail.play }
        app.element(TestID.Detail.seasons).waitToExist(15)
        Remote.press(.down)
        waitUntil("the first season focused", timeout: 10) { [weak self] in self?.focusedID == TestID.Detail.season(specials) }
        Remote.press(.right)
        waitUntil("Season 1 focused", timeout: 10) { [weak self] in self?.focusedID == TestID.Detail.season(season1) }
        Remote.select()
        app.element(TestID.Detail.page(season1)).waitToExist(20)
        let e1 = try fx.episode("show.long", season: 1, episode: 1)
        app.element(TestID.Detail.episode(e1)).waitToExist(20)
        assertFocusPresent("Season 1")
        Remote.menu()
        app.element(TestID.Detail.page(show.id)).waitToExist(10)
        assertFocusPresent("the show after the season")
    }

    func testPlayOnAShowStartsItsNextEpisode() throws {
        // Baseline Next Up for FX Long Show is S01E02 (in progress).
        let fx = try Fixtures.require()
        let show = try fx.item("show.long")
        let e2 = try fx.episode("show.long", season: 1, episode: 2)
        launchDetail(show.id)
        let upNext = app.element(TestID.Detail.upNext)
        XCTAssertTrue(upNext.waitForExistence(timeout: 15))
        waitUntil("focus on Play", timeout: 15) { [weak self] in self?.focusedID == TestID.Detail.play }
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30)
        XCTAssertNotNil(try api().tvWaitForPlayback(of: e2, timeout: 45), "Play on the show didn't start S01E02")
    }

    func testAnEpisodePage() throws {
        // No "Show › Season" trail on a TV (ItemDetailView: `#if !os(tvOS)`
        // around AncestorTrail); the title page is reached from the show.
        let fx = try Fixtures.require()
        let e1 = try fx.episode("show.short", season: 1, episode: 1)
        launchDetail(e1)
        XCTAssertTrue(app.button(TestID.Detail.play).waitForExistence(timeout: 15))
        XCTAssertFalse(app.element(TestID.Detail.ancestors).exists)
        XCTAssertFalse(app.button(TestID.Detail.trailer).exists, "episodes have no trailer")
    }

    func testDoubleEpisodeAndAMissingNumberAreShownAsTheyAre() throws {
        // show.short: E05-E06 is one file (IndexNumberEnd 6) and E07 is absent.
        let fx = try Fixtures.require()
        launchDetail(try fx.season("show.short", 1))
        let e5 = try fx.episode("show.short", season: 1, episode: 5)
        let row = app.element(TestID.Detail.episode(e5))
        row.waitToExist(20)
        attachScreenshot("Short Show season 1")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '5' AND label CONTAINS '6'")).firstMatch.exists,
                      "the double episode doesn't say 5–6")
    }

    func testCastLeadsToAPersonPage() throws {
        let film = try Fixtures.require().item("film.long_direct")
        launchDetail(film.id)
        press(.down, until: { [unowned self] in self.focusedID.hasPrefix("detail.cast.person.") }, max: 6)
        let personId = String(focusedID.dropFirst("detail.cast.person.".count))
        XCTAssertFalse(personId.isEmpty)
        Remote.select()
        app.element(TestID.Person.root).waitToExist(20)
        app.element(TestID.Person.name).waitToExist(10)
        waitUntil("the person's films", timeout: 20) { [weak self] in self?.app.element(TestID.Person.films).exists ?? false }
        let focusedOnOpen = waitUntil("focus on the person page", timeout: 10, fail: false) { [weak self] in self?.focused != nil }
        if !focusedOnOpen {
            XCTExpectFailure("bug: a person page opened from a cast face (PersonView on tvOS) shows nothing focused until a remote press") {
                XCTFail("nothing focused on the person page")
            }
            XCTAssertTrue(recoverFocus(), "no focus on the person page even after a press")
        }
        Remote.menu()
        app.element(TestID.Detail.page(film.id)).waitToExist(10)
    }

    func testABlockedTitleSaysSoInPlainWords() throws {
        // Source: fix-status.md "Blocked title raw error — Fixed, unverified"
        // (fx-kid run not done). fx-kid can't see FX Rated R.
        let rated = try Fixtures.require().item("film.rated_r").id
        guard let kid = QA.account(named: "fx-kid") else { throw XCTSkip("no fx-kid password") }
        launch(account: kid, environment: [TestLaunch.linkEnv: "aquarium://item/\(rated)"])
        let error = app.element(TestID.Detail.error)
        let page = app.element(TestID.Detail.page(rated))
        waitUntil("the page or its error", timeout: 60) { error.exists || page.exists }
        attachScreenshot("blocked title")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Server error' OR label CONTAINS '404'")).firstMatch.exists,
                       "a raw server error is shown")
    }
}
#endif
