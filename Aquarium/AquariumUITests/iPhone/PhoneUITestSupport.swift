//  What the iPhone UI tests share: which phone this is, how to get to a
//  section or a title, how to bring the player's controls up, and the
//  layout checks (nothing clipped, nothing under the keyboard).
//
//  Traps this works around (found 2026-11-13 on iOS 27.0):
//  - The system tab bar hands the `tab.item.*` identifiers to nothing, and a
//    plain `tap()` on a tab bar button lands on the tab to its left. Tabs are
//    tapped by the centre of their frame (`tab(_:)`).
//  - `XCUIApplication.open(aquarium://…)` relaunches the app with its launch
//    arguments, so a test-mode reset runs and the link arrives before the
//    sign-in: titles are reached through Search instead (`openTitle`).

#if os(iOS)
import XCTest

enum PhoneDevice: String {
    case small, standard, promax, duo

    /// From the simulator's name ("Aquarium Test iPhone SE", …), else the
    /// screen's size.
    static var current: PhoneDevice {
        let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        if name.contains("Duo") { return .duo }
        if name.contains("SE") { return .small }
        if name.contains("Pro Max") || name.contains("Plus") { return .promax }
        if !name.isEmpty { return .standard }
        let size = UIScreen.main.bounds.size
        let short = min(size.width, size.height)
        if short <= 375 { return .small }
        if short >= 430 { return .promax }
        return .standard
    }
}

extension PhoneUITestCase {
    var device: PhoneDevice { PhoneDevice.current }

    /// Functional tests whose layout does not depend on the screen run once,
    /// on the standard phone; the others report a skip. Set
    /// `AQUARIUM_PHONE_ALL_DEVICES=1` to run them everywhere.
    func standardOnly(_ why: String = "functional test: runs on the standard iPhone only") throws {
        if ProcessInfo.processInfo.environment["AQUARIUM_PHONE_ALL_DEVICES"] == "1" { return }
        try XCTSkipUnless(device == .standard, why)
    }

    func skipOnDuo(_ why: String) throws {
        try XCTSkipIf(device == .duo, why)
    }

    // MARK: Launch

    /// Launch clean, signed in, and wait for Home.
    func launchHome(account: QA.Account? = QA.account(), engine: String? = nil, arguments: [String] = []) {
        launch(account: account, engine: engine, arguments: arguments)
        app.element(TestID.Home.root).waitToExist(90)
    }

    var api: JellyfinAPI {
        get throws { try JellyfinAPI.signIn() }
    }

    // MARK: Moving about

    /// The tab with this label ("Home", "Music", "Audiobooks", "Library",
    /// "More"), tapped by the middle of its frame.
    func tab(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        tabButton(label, file: file, line: line).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// A tab's button: the system tab bar's, or on the Duo's front screen
    /// the vertical pill in the trailing column (not a UITabBar).
    func tabButton(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let system = app.tabBars.buttons[label]
        let pill = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, TestID.Tab.item(Self.tabSection[label] ?? "")))
        var found: XCUIElement?
        _ = eventually(timeout: 20) {
            if system.exists { found = system; return true }
            // The pill's buttons sit at the trailing edge, one above another.
            found = pill.allElementsBoundByIndex.filter { $0.frame.width < 80 && $0.frame.height < 80 }
                .max { $0.frame.minX < $1.frame.minX }
            return found != nil
        }
        if found == nil { XCTFail("no \(label) tab", file: file, line: line) }
        return found ?? system
    }

    static let tabSection = ["Home": "home", "Music": "music", "Audiobooks": "books", "Library": "libraries", "More": "more"]

    /// A section reached through the More tab (Favorites, Collections,
    /// Live TV, Downloads, Settings…), by `AppSection.id`.
    func moreSection(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        tab("More", file: file, line: line)
        app.element(TestID.Shell.more).waitToExist(20, file: file, line: line)
        let row = app.descendants(matching: .any).matching(identifier: TestID.Shell.moreRow(id)).firstMatch
        app.reveal(row)
        row.tapNow(20, file: file, line: line)
    }

    /// Settings, from the More tab.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        moreSection("settings", file: file, line: line)
        app.element(TestID.Settings.root).waitToExist(20, file: file, line: line)
    }

    /// Search from Home's bar.
    @discardableResult
    func search(_ term: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !app.element(TestID.Search.field).exists {
            if !app.button(TestID.Home.search).exists { tab("Home", file: file, line: line) }
            app.button(TestID.Home.search).tapNow(30, file: file, line: line)
        }
        let field = app.element(TestID.Search.field)
        field.tapNow(20, file: file, line: line)
        field.typeText(term)
        return field
    }

    /// A title's page, found by searching for `term` and tapping its card.
    func openTitle(_ id: String, searching term: String, file: StaticString = #filePath, line: UInt = #line) {
        search(term, file: file, line: line)
        let card = app.buttons.matching(identifier: TestID.Item.card(id)).firstMatch
        card.waitToExist(30, file: file, line: line)
        if !card.isHittable { app.swipeUp() }
        card.tapNow(20, file: file, line: line)
        app.element(TestID.Detail.root).waitToExist(30, file: file, line: line)
    }

    /// A fixture's page: its name is searched for.
    func openFixture(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> Fixtures.Item {
        let item = try Fixtures.require().item(key)
        openTitle(item.id, searching: item.name, file: file, line: line)
        return item
    }

    /// Back from a pushed page (its own bar's back, else the system one).
    func goBack(file: StaticString = #filePath, line: UInt = #line) {
        for id in [TestID.Detail.back, TestID.Common.back, TestID.Search.back] {
            let window = app.windows.firstMatch.frame
            for b in app.buttons.matching(identifier: id).allElementsBoundByIndex
            where b.isOnScreen(in: window, bottomInset: 0) && b.frame.minY < window.midY {
                b.tap(); return
            }
        }
        let system = app.navigationBars.buttons.element(boundBy: 0)
        if system.exists { system.tap(); return }
        XCTFail("no back button", file: file, line: line)
    }

    // MARK: The player

    /// Play from the title page that is showing, and wait for the player.
    func playFromDetail(file: StaticString = #filePath, line: UInt = #line) {
        app.button(TestID.Detail.play).tapNow(30, file: file, line: line)
        app.element(TestID.Player.root).waitToExist(40, file: file, line: line)
    }

    /// Bring the controls up, if they are down. They leave the tree when
    /// hidden, so their absence is the signal (see TestID+Player).
    func showControls(file: StaticString = #filePath, line: UInt = #line) {
        let controls = app.element(TestID.Player.controls)
        if controls.exists { return }
        app.element(TestID.Player.video).waitToExist(30, file: file, line: line)
        // A single tap waits ~370 ms for a possible double tap; a tap that
        // lands in a gesture's dead moment is lost, so try a few times,
        // never tapping while the controls are up (that would hide them).
        for _ in 0..<4 where !controls.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
            if controls.waitForExistence(timeout: 3) { return }
        }
        controls.waitToExist(2, file: file, line: line)
    }

    /// Open a card from its pill (audio, subtitles, quality, upNext).
    func openPill(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        showControls(file: file, line: line)
        app.button(TestID.Player.pill(key)).tapNow(10, file: file, line: line)
        app.element(TestID.Player.card(key)).waitToExist(10, file: file, line: line)
    }

    func openPlayerMore(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            showControls(file: file, line: line)
            app.button(TestID.Player.more).tapNow(10, file: file, line: line)
            if app.element(TestID.Player.cardMore).waitForExistence(timeout: 4) { return }
        }
        app.element(TestID.Player.cardMore).waitToExist(2, file: file, line: line)
    }

    /// Close the player with its back button and wait for it to go.
    func closePlayer(file: StaticString = #filePath, line: UInt = #line) {
        showControls(file: file, line: line)
        app.button(TestID.Player.back).tapNow(10, file: file, line: line)
        XCTAssertTrue(app.element(TestID.Player.root).waitToVanish(20), "player did not close", file: file, line: line)
    }

    /// Seconds read off the elapsed label ("1:02:03", "4:12").
    func elapsedSeconds() -> Double? {
        let label = app.element(TestID.Player.elapsed)
        guard label.exists else { return nil }
        return PhoneTime.seconds(label.label.isEmpty ? (label.value as? String ?? "") : label.label)
    }

    /// Waits (polling the server) until the app's session reports a position
    /// past `seconds` for `itemId`.
    @discardableResult
    func waitForServerPosition(_ api: JellyfinAPI, itemId: String, atLeast seconds: Double, timeout: TimeInterval = 60) -> Double? {
        let end = Date().addingTimeInterval(timeout)
        var last: Double?
        while Date() < end {
            if let s = PhoneSessions.current(api, itemId), let p = s.positionSeconds {
                last = p
                if p >= seconds { return p }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return last
    }

    // MARK: Layout checks

    /// The element sits wholly inside the window (not clipped off an edge).
    func assertOnScreen(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let f = element.frame
        XCTAssertTrue(element.exists, "\(what) missing", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.minX, window.minX - 0.5, "\(what) clipped at the left: \(f)", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxX, window.maxX + 0.5, "\(what) clipped at the right: \(f) in \(window)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.minY, window.minY - 0.5, "\(what) clipped at the top: \(f)", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxY, window.maxY + 0.5, "\(what) clipped at the bottom: \(f) in \(window)", file: file, line: line)
    }

    /// The element is above the keyboard (when one is up).
    func assertAboveKeyboard(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        XCTAssertLessThanOrEqual(element.frame.maxY, keyboard.frame.minY + 0.5,
                                 "\(what) is under the keyboard: \(element.frame) vs keyboard \(keyboard.frame)", file: file, line: line)
    }

    func assertNoOverlap(_ a: XCUIElement, _ b: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard a.exists, b.exists else { return }
        XCTAssertFalse(a.frame.insetBy(dx: 1, dy: 1).intersects(b.frame.insetBy(dx: 1, dy: 1)),
                       "\(what): \(a.frame) overlaps \(b.frame)", file: file, line: line)
    }

    /// Turn the phone (the Duo's inner screen ignores this; see MANUAL.md).
    func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
    }

    /// Waits for a predicate on an element, without sleeping blindly.
    @discardableResult
    func wait(for element: XCUIElement, _ format: String, timeout: TimeInterval = 15) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    /// Polls a condition (a server state, say) until it holds.
    @discardableResult
    func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }
}

enum PhoneTime {
    /// "1:02:03" / "4:12" / "-4:12" → seconds.
    static func seconds(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: "-− ")).components(separatedBy: ",").first ?? text
        let parts = clean.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
#endif

#if os(iOS)
// MARK: - Fast taps and scrolling
//
// SwiftUI elements on iOS 27 report `hittable == false` (hit point {-1,-1})
// even when plainly on screen, so the shared `tapWhenReady` waits out its
// whole timeout before every tap, and `app.scroll(to:)` swipes its maximum.
// These go by existence and by the frame instead.

extension XCUIElement {
    /// Waits for the element to exist, then taps it.
    /// By the middle of its frame: `tap()` refuses an element XCUITest calls
    /// not hittable, which here is most of them.
    func tapNow(_ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        waitToExist(timeout, file: file, line: line)
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Whether the frame is inside `window`, clear of `bottomInset` (the tab bar).
    func isOnScreen(in window: CGRect, bottomInset: CGFloat = 90) -> Bool {
        guard exists else { return false }
        let f = frame
        return !f.isEmpty && f.minY >= window.minY && f.maxY <= window.maxY - bottomInset
            && f.minX >= window.minX - 1 && f.maxX <= window.maxX + 1
    }
}

extension XCUIApplication {
    /// Swipes until the element's frame is on screen. Returns whether it is.
    @discardableResult
    func reveal(_ element: XCUIElement, up: Bool = true, maxSwipes: Int = 10) -> Bool {
        let window = windows.firstMatch.frame
        var n = 0
        while !element.isOnScreen(in: window) && n < maxSwipes {
            if element.exists, element.frame.maxY < window.midY, up { swipeDown() }
            else if up { swipeUp() } else { swipeDown() }
            n += 1
        }
        return element.isOnScreen(in: window)
    }
}
#endif

#if os(iOS)
extension PhoneUITestCase {
    /// An item in an open SwiftUI menu: by identifier where the menu hands it
    /// on, else by its label (a Picker's rows inside a Menu lose theirs).
    func menuItem(_ id: String, label: String, timeout: TimeInterval = 8) -> XCUIElement {
        let byId = app.descendants(matching: .any).matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 2) { return byId }
        let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        _ = byLabel.waitForExistence(timeout: timeout)
        return byLabel
    }
}
#endif

#if os(iOS)
enum PhoneSessions {
    /// Of the sessions playing `itemId`, the one that checked in last.
    static func current(_ api: JellyfinAPI, _ itemId: String) -> JellyfinAPI.Session? {
        let playing = ((try? api.sessions()) ?? []).filter { $0.nowPlayingId == itemId }
        return playing.max { a, b in
            (a.raw["LastPlaybackCheckIn"] as? String ?? "") < (b.raw["LastPlaybackCheckIn"] as? String ?? "")
        }
    }
}
#endif

#if os(iOS)
extension PhoneUITestCase {
    /// The first element with this identifier whose frame is on screen (the
    /// same card can sit in several shelves, some scrolled out of sight).
    func visible(_ id: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let all = app.descendants(matching: .any).matching(identifier: id)
        let window = app.windows.firstMatch.frame
        var found: XCUIElement?
        _ = eventually(timeout: timeout) {
            found = all.allElementsBoundByIndex.first { $0.isOnScreen(in: window) }
            return found != nil
        }
        if found == nil { XCTFail("no \(id) on screen", file: file, line: line) }
        return found ?? all.firstMatch
    }
}
#endif
