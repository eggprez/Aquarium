//  More of Search on an iPad than PadSearchTests: the count line over a
//  video-only answer, and an audiobook found by the shared search opening
//  on the Audiobooks section's own page, its row lit in the sidebar
//  (SearchView.musicResults: `app.show(.books)` then the book).

#if os(iOS)
import XCTest

final class PadSearchMoreTests: PadUITestCase {
    private func search(_ term: String) {
        launchHome()
        app.button(TestID.Sidebar.searchRow).padTap()
        app.element(TestID.Search.root).waitToExist(20)
        let field = app.textFields[TestID.Search.field].exists
            ? app.textFields[TestID.Search.field] : app.searchFields[TestID.Search.field]
        field.waitToExist(10)
        field.padTap()
        field.typeText(term + "\n")
    }

    /// One film and no music: the plain count line, in the singular, and no
    /// "Films & TV" heading (that is only for a page that also has music).
    func testOneMatchIsCountedInTheSingular() throws {
        let unicode = try fx.item("film.unicode_title")
        search("Unicode")
        XCTAssertTrue(cardButton(unicode.id).waitForExistence(timeout: 30))
        let count = app.element(TestID.Search.resultCount)
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the count over the results")
        XCTAssertEqual(count.label, "1 result")
        XCTAssertFalse(app.element(TestID.Search.videoHeading).exists, "no Films & TV heading without music above it")
        XCTAssertFalse(app.element(TestID.Search.musicResults).exists)
    }

    func testAnAudiobookFoundBySearchOpensUnderAudiobooks() throws {
        guard let books = try fx.raw["fixtures"] as? [String: Any],
              let list = books["books"] as? [[String: Any]],
              let id = list.first(where: { $0["name"] as? String == "FX Chaptered Audiobook" })?["id"] as? String
        else { throw XCTSkip("no FX Chaptered Audiobook") }
        search("FX Chaptered")
        let shelf = app.element(TestID.Search.audiobooks)
        XCTAssertTrue(shelf.waitForExistence(timeout: 30), "an Audiobooks shelf in the results")
        let card = app.buttons.matching(identifier: TestID.Books.card(id)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the book on it")
        card.padTap()
        app.element(TestID.Books.detail).waitToExist(30)
        XCTAssertTrue(waitUntil(10, "Audiobooks lit in the sidebar") { [self] in
            app.button(TestID.Sidebar.row("books")).isSelected
        })
        XCTAssertFalse(app.button(TestID.Sidebar.row("home")).isSelected, "no longer over Home")
    }
}
#endif
