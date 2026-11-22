//  Finding, waiting for, scrolling to and photographing elements by their
//  catalogue identifier.
//
//      app.element(TestID.Home.root).waitToExist()
//      app.button(TestID.Home.search).tapWhenReady()
//      app.scroll(to: app.element(TestID.Home.shelf(TestID.Home.rowNextUp)))
//      attachScreenshot("home")      // in an AquariumUITestCase

import XCTest

extension XCUIElement {
    /// Any element with this identifier, whatever its type. Anchors made by
    /// `.testAnchor` are `.other`; controls have their own types.
    func element(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func button(_ id: String) -> XCUIElement { descendants(matching: .button).matching(identifier: id).firstMatch }

    /// Every element whose identifier starts with `prefix` — the cards of a
    /// shelf, say (`TestID.Item.card("")` style prefixes).
    func elements(prefix: String) -> XCUIElementQuery {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }
}

extension XCUIElement {
    /// Fails the test (with the hierarchy attached by the base class) unless
    /// the element appears in time.
    @discardableResult
    func waitToExist(_ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !waitForExistence(timeout: timeout) {
            XCTFail("\(self) did not appear within \(Int(timeout)) s", file: file, line: line)
        }
        return self
    }

    /// True once the element is gone (or was never there).
    @discardableResult
    func waitToVanish(_ timeout: TimeInterval = 20) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Waits until the element exists and can be hit, then taps (clicks on a Mac).
    func tapWhenReady(_ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        waitToExist(timeout, file: file, line: line)
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: self)
        _ = XCTWaiter().wait(for: [hittable], timeout: timeout)
        #if os(macOS)
        click()
        #elseif os(tvOS)
        XCTFail("tvOS has no taps: use Remote.focus(on:) then Remote.select()", file: file, line: line)
        #else
        tap()
        #endif
    }
}

#if os(iOS) || os(watchOS)
extension XCUIApplication {
    /// Swipes the page up (or down) until `element` is hittable, at most
    /// `maxSwipes` times. Returns whether it got there.
    @discardableResult
    func scroll(to element: XCUIElement, up: Bool = true, maxSwipes: Int = 12) -> Bool {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes {
            if up { swipeUp() } else { swipeDown() }
            n += 1
        }
        return element.exists && element.isHittable
    }
}
#endif
