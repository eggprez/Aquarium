//  Helpers the newer Apple TV tests share beyond `TVSupport.swift`: a button
//  of a system dialog found by its label (XCUITest reports focus in one by
//  label only), a card on one particular Home row (the same title can be on
//  Continue Watching and Next Up at once), and a card's press-and-hold menu.

#if os(tvOS)
import XCTest

extension TVTestCase {
    /// Moves the selector in an open system dialog (an alert or a
    /// confirmation dialog) until the focused button's label contains
    /// `text`. True once it does. The dialog's buttons carry their
    /// identifiers, but focus inside one is only reported by label.
    @discardableResult
    func focusDialogButton(_ text: String) -> Bool {
        waitUntil("the dialog to take focus", timeout: 10, fail: false) { [weak self] in
            !(self?.focusedLabel ?? "").isEmpty
        }
        // Down through a column of buttons, back up past the top, then
        // sideways for the two-button layout.
        for move in [XCUIRemote.Button.down, .down, .down, .up, .up, .up, .up, .right, .left, .left] {
            if focusedLabel.localizedCaseInsensitiveContains(text) { return true }
            Remote.press(move)
        }
        return focusedLabel.localizedCaseInsensitiveContains(text)
    }

    /// The card for `itemId` that sits on the Home row `rowKey`
    /// (`TestID.Home.rowResume`, `rowNextUp`, …), or nil.
    func homeCard(_ itemId: String, onRow rowKey: String) -> XCUIElement? {
        let row = app.element(TestID.Home.shelf(rowKey))
        guard row.waitForExistence(timeout: 30) else { return nil }
        var found: XCUIElement?
        waitUntil("\(itemId)'s card on \(rowKey)", timeout: 20, fail: false) { [weak self] in
            guard let self else { return false }
            found = self.app.elements(prefix: TestID.Item.card(itemId)).allElementsBoundByIndex
                .first { $0.identifier == TestID.Item.card(itemId) && row.frame.intersects($0.frame) }
            return found != nil
        }
        return found
    }

    /// Focuses `card`, holds Select on it, and waits for the menu entry
    /// `entry` to show. False when the card can't be reached.
    @discardableResult
    func openCardMenu(_ card: XCUIElement, showing entry: String,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard Remote.focus(on: card, in: app) else {
            XCTFail("couldn't focus \(card.identifier) (on \(focused?.summary ?? "nothing"))", file: file, line: line)
            return false
        }
        Remote.longPress(.select, seconds: 1.2)
        let item = app.element(entry)
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the card's menu has no \(entry)", file: file, line: line)
        return item.exists
    }

    /// Moves the selector onto an entry of an open card menu and clicks it.
    func chooseMenuEntry(_ entry: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.element(entry)
        XCTAssertTrue(focusInColumn(item) || Remote.focus(on: item, in: app),
                      "can't reach \(entry) (on \(focused?.summary ?? "nothing"))", file: file, line: line)
        Remote.select()
    }
}
#endif
