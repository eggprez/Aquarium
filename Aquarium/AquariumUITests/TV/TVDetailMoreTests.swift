//  Title pages beyond `TVBrowseTests` (Views/ItemDetailView.swift on tvOS):
//  a show's Add to Next Up, which asks first (only its Menu is pressed: both
//  answers change the suite's baseline on the server), and More Like This,
//  reached with the remote and opening another title.

#if os(tvOS)
import XCTest

final class TVDetailMoreTests: TVTestCase {
    func testAShowsAddToNextUpAsksAndMenuLeavesItAlone() throws {
        let fx = try Fixtures.require()
        let show = try fx.item("show.long").id
        let longE2 = try fx.episode("show.long", season: 1, episode: 2)
        let before = try api().userData(longE2)
        launchDetail(show)
        let add = app.button(TestID.Detail.addToNextUp)
        XCTAssertTrue(add.waitForExistence(timeout: 20), "a show's page has no Add to Next Up")
        XCTAssertFalse(app.element(TestID.Detail.watched).exists, "a show offers Mark watched (it is put on Next Up instead)")
        XCTAssertTrue(Remote.focus(on: add, in: app), "can't reach Add to Next Up (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        let cancel = app.element(TestID.Shell.nextUpCancel)
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Add to Next Up didn't ask how")
        XCTAssertTrue(app.element(TestID.Shell.nextUpFromLastWatched).exists)
        XCTAssertTrue(app.element(TestID.Shell.nextUpFromFirstEpisode).exists)
        attachScreenshot("show: add to next up question")
        Remote.menu()
        XCTAssertTrue(cancel.waitToVanish(10), "Menu left the question up")
        XCTAssertTrue(app.element(TestID.Detail.page(show)).exists, "Menu on the question left the page")
        assertFocusPresent("the show's page after the question")
        let after = try api().userData(longE2)
        XCTAssertEqual(after.played, before.played)
        XCTAssertEqual(after.positionSeconds, before.positionSeconds, accuracy: 1, "S01E02's position changed")
    }

    func testMoreLikeThisIsReachedWithTheRemoteAndOpensATitle() throws {
        let film = try Fixtures.require().item("film.long_direct").id
        launchDetail(film)
        let shelf = app.element(TestID.Detail.moreLikeThis)
        XCTAssertTrue(shelf.waitForExistence(timeout: 30), "no More Like This on a film's page")
        // Its cards, by frame: the anchor doesn't hand its children down.
        var cards: [XCUIElement] = []
        waitUntil("cards in More Like This", timeout: 30) { [weak self] in
            guard let self else { return false }
            cards = self.app.elements(prefix: "item.card.").allElementsBoundByIndex.filter {
                shelf.frame.intersects($0.frame) && $0.identifier != TestID.Item.card(film)
            }
            return !cards.isEmpty
        }
        guard let card = cards.first else { return }
        let other = String(card.identifier.dropFirst("item.card.".count))
        XCTAssertTrue(Remote.focus(on: card, in: app, maxPresses: 60), "More Like This can't be reached (on \(focused?.summary ?? "nothing"))")
        attachScreenshot("more like this")
        Remote.select()
        app.element(TestID.Detail.page(other)).waitToExist(20)
        assertFocusPresent("the title from More Like This")
        Remote.menu()
        app.element(TestID.Detail.page(film)).waitToExist(15)
        assertFocusPresent("back on the film")
    }
}
#endif
