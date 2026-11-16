//  A person's page on an iPad, reached from a title's cast: the header, the
//  name in the bar, the shelf of their films, and a film opening from it.
//  The fixture people carry no birth date, birthplace or biography (the
//  fixture libraries take their metadata from .nfo files alone), so the
//  facts line, the biography and its Read More are checked absent here and
//  listed in MANUAL.md for a server that has them.

#if os(iOS)
import XCTest

final class PadPersonTests: PadUITestCase {
    private func ada() throws -> String {
        guard let people = try fx.raw["people"] as? [String: [String: Any]],
              let id = people["Ada Fixture"]?["id"] as? String else { throw XCTSkip("no Ada Fixture in fixtures.json") }
        return id
    }

    func testPersonPageShowsTheirFilmsAndOpensOne() throws {
        let person = try ada()
        let film = try fx.item("film.long_direct")
        launchHome()
        openItem(film.id)
        XCTAssertTrue(reveal(app.element(TestID.Detail.cast), maxSwipes: 15), "Cast & Crew on the page")
        let card = app.elements(prefix: TestID.Detail.castPerson(person)).firstMatch
        card.waitToExist(10)
        if !isOnScreen(card) { reveal(card) }
        card.padTap()

        app.element(TestID.Person.page(person)).waitToExist(30)
        XCTAssertTrue(app.element(TestID.Person.root).exists)
        XCTAssertTrue(app.element(TestID.Person.header).exists, "the header")
        XCTAssertTrue(app.staticTexts["Ada Fixture"].waitForExistence(timeout: 10), "the name, in the bar")
        XCTAssertFalse(app.element(TestID.Person.name).exists, "the name under the portrait is the Apple TV's")
        let films = app.element(TestID.Person.films)
        XCTAssertTrue(films.waitForExistence(timeout: 30), "the shelf of their films")
        XCTAssertFalse(app.element(TestID.Person.empty).exists)
        XCTAssertFalse(app.element(TestID.Person.error).exists)
        // Nothing the server has no word on.
        XCTAssertFalse(app.element(TestID.Person.facts).exists, "no born/died line for a person without one")
        XCTAssertFalse(app.element(TestID.Person.bio).exists, "no biography for a person without one")
        XCTAssertFalse(app.element(TestID.Person.bioToggle).exists)
        XCTAssertFalse(app.element(TestID.Person.openInNewWindow).exists, "a Mac's command")
        attachScreenshot("person")

        // Every fixture film credits Ada Fixture: the first on the shelf opens.
        let prefix = TestID.Item.card("")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20), "a film on the shelf")
        let onShelf = cards.allElementsBoundByIndex.first { films.frame.insetBy(dx: 0, dy: -2).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let poster = try XCTUnwrap(onShelf, "a poster inside the Films shelf")
        let opened = String(poster.identifier.dropFirst(prefix.count))
        poster.padTap()
        app.element(TestID.Detail.page(opened)).waitToExist(30)
    }
}
#endif
