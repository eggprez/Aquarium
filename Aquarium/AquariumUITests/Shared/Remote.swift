//  The Siri Remote, for Apple TV UI tests.
//
//      Remote.press(.down, times: 3)
//      Remote.focus(on: app.element(TestID.Home.heroPlay(id)), in: app)
//      Remote.select()
//
//  The app's own debug hook (Player/TV/RemoteDebugHook.swift) is the other
//  way to drive the player from outside; these are the real presses.

#if os(tvOS)
import XCTest

enum Remote {
    static func press(_ button: XCUIRemote.Button, times: Int = 1, pause: TimeInterval = 0.25) {
        for _ in 0..<times {
            XCUIRemote.shared.press(button)
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
    }

    static func select() { press(.select) }
    static func menu() { press(.menu) }
    static func playPause() { press(.playPause) }
    static func longPress(_ button: XCUIRemote.Button, seconds: TimeInterval = 1) {
        XCUIRemote.shared.press(button, forDuration: seconds)
    }

    /// The element that has focus now, if any.
    static func focused(in app: XCUIApplication) -> XCUIElement? {
        let el = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return el.exists ? el : nil
    }

    /// Moves focus towards `target` with the arrows, judging by frames, until
    /// it (or something inside it) has focus. Returns whether it got there.
    @discardableResult
    static func focus(on target: XCUIElement, in app: XCUIApplication, maxPresses: Int = 40) -> Bool {
        guard target.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<maxPresses {
            if target.hasFocus { return true }
            if target.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists { return true }
            guard let current = focused(in: app) else { press(.down); continue }
            let from = current.frame, to = target.frame
            let dx = to.midX - from.midX, dy = to.midY - from.midY
            if abs(dy) > max(from.height, 1) / 2, abs(dy) >= abs(dx) * 0.5 {
                press(dy > 0 ? .down : .up)
            } else if abs(dx) > 1 {
                press(dx > 0 ? .right : .left)
            } else {
                press(dy > 0 ? .down : .up)
            }
        }
        return target.hasFocus
    }
}
#endif
