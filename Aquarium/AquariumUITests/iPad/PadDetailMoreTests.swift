//  More of a title's page on an iPad than PadDetailTests reaches: the
//  tagline and studios from the server's metadata, the line saying which
//  episode a show's Play points at ("Carry on with" / "Up next"), the resume
//  bar, the title arriving in the floating bar once the header has scrolled
//  away (ItemDetailView.padBar), and a show's Download menu offering the
//  whole series and each season.
//
//  Fixture facts (fixtures.json): every film's tagline is "<name>: a
//  synthetic fixture." and its studio "Aquarium Test Labs"; at the baseline
//  FX Long Show is at S01E02 (in progress) and FX Short Show at S01E03
//  (E01 and E02 played).

#if os(iOS)
import XCTest

final class PadDetailMoreTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testTaglineAndStudiosComeFromTheServer() throws {
        let film = try fx.item("film.rated_g")
        launchHome()
        openItem(film.id)
        let tagline = app.element(TestID.Detail.tagline)
        XCTAssertTrue(tagline.waitForExistence(timeout: 20), "a tagline under the title")
        XCTAssertEqual(tagline.label, "FX Rated G: a synthetic fixture.")
        let studios = app.element(TestID.Detail.studios)
        XCTAssertTrue(reveal(studios), "the studios line")
        XCTAssertTrue(studios.label.contains("Aquarium Test Labs"), "reads \(studios.label)")
    }

    /// A show's page says which episode Play is pointing at: "Carry on with"
    /// for one started, "Up next" for one not, with the episode's name.
    func testAShowsPageSaysWhichEpisodePlayPointsAt() throws {
        let long = try fx.item("show.long")
        let e2 = try episode("show.long", season: 1, episode: 2)
        let short = try fx.item("show.short")
        let e3 = try episode("show.short", season: 1, episode: 3)
        launchHome()

        openItem(long.id)
        let line = app.element(TestID.Detail.upNext)
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the line on FX Long Show")
        XCTAssertTrue(line.label.contains("Carry on with"), "S01E02 is in progress: \(line.label)")
        XCTAssertTrue(line.label.contains(e2.name), "names \(e2.name): \(line.label)")
        XCTAssertTrue(app.element(TestID.Detail.resumeProgress).exists, "a resume bar for the episode in progress")
        XCTAssertTrue(app.button(TestID.Detail.play).label.localizedCaseInsensitiveContains("resume"),
                      "Play resumes it: \(app.button(TestID.Detail.play).label)")

        openItem(short.id)
        let next = app.element(TestID.Detail.upNext)
        XCTAssertTrue(waitUntil(20, "the line on FX Short Show") { next.exists && next.label.contains(e3.name) },
                      "reads \(next.label)")
        XCTAssertTrue(next.label.contains("Up next"), "S01E03 has not been started: \(next.label)")
        XCTAssertFalse(app.element(TestID.Detail.resumeProgress).exists, "no resume bar for an episode not started")
    }

    /// A film not started has no resume bar; one in progress has it.
    func testTheResumeBarIsOnlyOnAFilmInProgress() throws {
        let started = try fx.item("film.long_direct")
        let fresh = try fx.item("film.pcm_mov")
        let api = try api()
        try api.setResume(fresh.id, seconds: 0)
        try? api.markUnplayed(fresh.id)
        launchHome()
        openItem(started.id)
        XCTAssertTrue(app.element(TestID.Detail.resumeProgress).waitForExistence(timeout: 20), "the baseline's 5:00")
        openItem(fresh.id)
        app.button(TestID.Detail.play).waitToExist(20)
        XCTAssertFalse(app.element(TestID.Detail.resumeProgress).exists, "nothing to resume")
        XCTAssertFalse(app.button(TestID.Detail.play).label.localizedCaseInsensitiveContains("resume"))
    }

    /// The iPad's floating bar carries only Back at the top of the page; the
    /// title joins it once the header has gone 80 pt up, and leaves again at
    /// the top.
    func testTheTitleJoinsTheBarOnceTheHeaderHasScrolledAway() throws {
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        let barTitle = app.element(TestID.Detail.barTitle)
        XCTAssertTrue(app.button(TestID.Detail.back).waitForExistence(timeout: 10))
        XCTAssertFalse(barTitle.exists, "no title in the bar over the header")

        let window = app.windows.firstMatch
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.75))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.3))
        for _ in 0..<3 where !barTitle.exists {
            low.press(forDuration: 0.05, thenDragTo: high)
        }
        XCTAssertTrue(barTitle.waitForExistence(timeout: 5), "the title in the bar once the header is gone")
        XCTAssertEqual(barTitle.label, "FX Long Direct Play")
        attachScreenshot("title in the bar")

        for _ in 0..<6 { high.press(forDuration: 0.05, thenDragTo: low) }
        XCTAssertTrue(barTitle.waitToVanish(5), "the title leaves the bar at the top of the page")
    }

    /// A row of a menu the system draws: by identifier, or where that did not
    /// reach it, by how its words begin.
    private func menuRow(_ id: String, beginning words: String) -> XCUIElement {
        let byId = app.buttons.matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 3) { return byId }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    /// A show's Download menu: the whole series, then every season it has
    /// (Season 1 and Season 2 checked), each with the qualities inside.
    func testAShowsDownloadMenuOffersTheWholeSeriesAndEachSeason() throws {
        let show = try fx.item("show.long")
        let s1 = try season("show.long", 1)
        let s2 = try season("show.long", 2)
        launchHome()
        openItem(show.id)
        let download = app.element(TestID.Detail.download)
        XCTAssertTrue(reveal(download), "Download on a show's page")
        download.padTap()
        XCTAssertTrue(menuRow(TestID.Detail.downloadSeries, beginning: "Whole Series").waitForExistence(timeout: 10),
                      "Whole Series")
        for (title, id) in [("Season 1", s1), ("Season 2", s2)] {
            XCTAssertTrue(menuRow(TestID.Detail.downloadSeason(id), beginning: title).exists, "\(title) in the menu")
        }
        attachScreenshot("series download menu")
        let first = menuRow(TestID.Detail.downloadSeason(s1), beginning: "Season 1")
        first.padTap()
        let original = menuRow(TestID.Detail.downloadSeasonQuality(s1, "Original quality"), beginning: "Original")
        XCTAssertTrue(original.waitForExistence(timeout: 10), "Season 1's qualities, Original first")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "720p")).firstMatch.exists,
                      "and the transcoded rungs")
        // Put the menu away without downloading anything.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.97)).tap()
    }
}
#endif
