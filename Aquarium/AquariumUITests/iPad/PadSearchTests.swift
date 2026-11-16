//  Search on an iPad: reached from the sidebar's Search row and Home's bar,
//  results as a grid in the detail column, music results above video, recent
//  terms, and the hardware keyboard's Return.

#if os(iOS)
import XCTest

final class PadSearchTests: PadUITestCase {
    private func openSearch() -> XCUIElement {
        launchHome()
        app.button(TestID.Sidebar.searchRow).padTap()
        app.element(TestID.Search.root).waitToExist(20)
        let field = app.textFields[TestID.Search.field].exists
            ? app.textFields[TestID.Search.field] : app.searchFields[TestID.Search.field]
        field.waitToExist(10)
        return field
    }

    private func search(_ term: String) {
        let field = openSearch()
        field.padTap()
        field.typeText(term + "\n")
    }

    func testFindsTheFXLongTitles() throws {
        let fx = try fx
        search("FX Long")
        let results = app.element(TestID.Search.results)
        results.waitToExist(30)
        for key in ["film.long_direct", "film.long_multitrack", "show.long"] {
            XCTAssertTrue(cardButton(try fx.item(key).id).waitForExistence(timeout: 20),
                          "\(key) in the results")
        }
        attachScreenshot("FX Long")
    }

    func testResultsSitInTheDetailColumnBesideTheSidebar() throws {
        search("FX Long")
        app.element(TestID.Search.results).waitToExist(30)
        XCTAssertTrue(sidebar.exists)
        let card = app.elements(prefix: "item.card.").firstMatch
        card.waitToExist(20)
        XCTAssertGreaterThan(card.frame.minX, sidebar.frame.maxX, "results are beside the sidebar, not under it")
    }

    func testUnicodeTitleIsFound() throws {
        let unicode = try fx.item("film.unicode_title")
        search("Unicode")
        XCTAssertTrue(cardButton(unicode.id).waitForExistence(timeout: 30))
    }

    func testMusicResultsAboveFilmsAndTV() {
        search("FX")
        let music = app.element(TestID.Search.musicResults)
        XCTAssertTrue(music.waitForExistence(timeout: 30), "artists, albums and songs matched")
        let heading = app.element(TestID.Search.videoHeading)
        if heading.waitForExistence(timeout: 10) {
            XCTAssertLessThan(music.frame.minY, heading.frame.minY, "music above \"Films & TV\"")
        }
    }

    func testNoMatchesSaysSo() {
        search("zzqqxxnothing")
        XCTAssertTrue(app.element(TestID.Search.empty).waitForExistence(timeout: 30))
    }

    func testResultOpensItsTitle() throws {
        let film = try fx.item("film.long_direct")
        search("FX Long Direct")
        let card = cardButton(film.id)
        card.padTap(30)
        app.element(TestID.Detail.page(film.id)).waitToExist(30)
    }

    func testRecentTermsAreKeptAndCleared() {
        search("FX Versions")
        app.element(TestID.Search.results).waitToExist(30)
        app.button(TestID.Search.clear).padTap()
        let recent = app.element(TestID.Search.recent("FX Versions"))
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "the term is offered again")
        app.button(TestID.Search.recentsClear).padTap()
        XCTAssertTrue(recent.waitToVanish(10))
    }

    func testHomeBarSearchOpensTheSameSearch() {
        launchHome()
        app.button(TestID.Home.search).padTap()
        app.element(TestID.Search.root).waitToExist(20)
        app.button(TestID.Search.back).padTap()
        app.element(TestID.Home.root).waitToExist(20)
    }
}
#endif
