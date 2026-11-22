//  What the iPad UI tests share: launching to Home, the sidebar, opening a
//  title by link, turning the iPad, the player's controls, and waiting on
//  conditions (never on the clock).
//
//  Everything here drives the app the way a person would, apart from
//  `openItem`, which uses the app's own `aquarium://item/<id>` link (the one
//  Spotlight, Handoff and the widgets use) so a test about a title page does
//  not first have to find the title.

#if os(iOS)
import XCTest
import UIKit

extension PadUITestCase {
    // MARK: Fixtures and the server

    var fx: Fixtures { get throws { try Fixtures.require() } }

    func api() throws -> JellyfinAPI { try JellyfinAPI.signIn() }

    /// An episode of a fixture show, by season and episode number, as the
    /// fixture manifest lists it.
    func episode(_ showKey: String, season: Int, episode: Int) throws -> (id: String, name: String) {
        let show = try fx.item(showKey)
        for s in show.raw["seasons"] as? [[String: Any]] ?? [] {
            guard (s["index"] as? Int ?? s["indexNumber"] as? Int) == season else { continue }
            for e in s["episodes"] as? [[String: Any]] ?? [] {
                let index = e["index"] as? Int ?? e["indexNumber"] as? Int
                if index == episode, let id = e["id"] as? String {
                    return (id, e["name"] as? String ?? "")
                }
            }
        }
        throw XCTSkip("no S\(season)E\(episode) of \(showKey) in fixtures.json")
    }

    /// A season of a fixture show by number.
    func season(_ showKey: String, _ number: Int) throws -> String {
        let show = try fx.item(showKey)
        for s in show.raw["seasons"] as? [[String: Any]] ?? [] {
            if (s["index"] as? Int ?? s["indexNumber"] as? Int) == number, let id = s["id"] as? String { return id }
        }
        throw XCTSkip("no season \(number) of \(showKey) in fixtures.json")
    }

    // MARK: Launching

    /// Clean, signed in as this suite, Home on screen.
    @discardableResult
    func launchHome(engine: String? = nil, arguments: [String] = [],
                    file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        launch(engine: engine, arguments: arguments)
        app.element(TestID.Home.root).waitToExist(60, file: file, line: line)
        return app
    }

    // MARK: The sidebar

    var sidebar: XCUIElement { app.element(TestID.Sidebar.root) }

    /// Selects a section by its sidebar row and waits for its page.
    func showSection(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.button(TestID.Sidebar.row(id))
        if !row.exists || !row.isHittable { revealSidebar() }
        if !row.isHittable { _ = scrollSidebar(to: row) }
        row.padTap(file: file, line: line)
        app.element(TestID.Shell.section(id)).waitToExist(30, file: file, line: line)
    }

    /// Brings a collapsed sidebar back, by the toggle the page draws.
    func revealSidebar() {
        guard !sidebar.exists || !app.button(TestID.Sidebar.collapse).isHittable else { return }
        for id in [TestID.Sidebar.show, TestID.Detail.showSidebar] {
            let toggle = app.button(id)
            if toggle.exists, toggle.isHittable { toggle.padTap(); break }
        }
        // The system's own toggle, on pages with a navigation bar.
        let system = app.navigationBars.buttons["Show Sidebar"]
        if !app.button(TestID.Sidebar.collapse).exists, system.exists { system.padTap() }
        app.button(TestID.Sidebar.collapse).waitToExist(10)
    }

    @discardableResult
    func scrollSidebar(to element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes {
            sidebar.swipeUp()
            n += 1
        }
        return element.exists && element.isHittable
    }

    /// The section ids the sidebar lists, top to bottom.
    func sidebarRowIds() -> [String] {
        let rows = app.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.row."))
            .allElementsBoundByIndex
        return rows.sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("sidebar.row.".count)) }
    }

    // MARK: Pages

    /// Opens a title's page through the app's own link.
    @discardableResult
    func openItem(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let url = URL(string: "aquarium://item/\(id)")!
        // Through the system, to the app as it is running. `app.open(url)`
        // relaunches the app, which in test mode starts clean and drops the
        // link before the sign-in has finished.
        XCUIDevice.shared.system.open(url)
        // A system prompt can stand between the link and the app on some
        // systems; its Open button answers it.
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.padTap() }
        let page = app.element(TestID.Detail.page(id))
        page.waitToExist(40, file: file, line: line)
        // The actions arrive with the item, after the skeleton.
        app.element(TestID.Detail.actions).waitToExist(40, file: file, line: line)
        return page
    }

    /// A card (poster or still) as the button it is. Every card also has a
    /// `.testAnchor` of the same name behind it, which takes no touches.
    func cardButton(_ itemId: String) -> XCUIElement {
        app.buttons.matching(identifier: TestID.Item.card(itemId)).firstMatch
    }

    /// Whether `element` is on screen: hittable for a control; for an anchor
    /// (`.other`, which never takes a touch), its middle inside the window
    /// clear of the top bar.
    func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if element.isHittable { return true }
        // Not hittable can mean "under its own anchor" (see `padTap`), so
        // the frame decides.
        let window = app.frame.insetBy(dx: 0, dy: 60)
        let f = element.frame
        return !f.isEmpty && window.contains(CGPoint(x: f.midX, y: min(f.midY, f.minY + 40)))
    }

    /// Scrolls the page in front until `element` is on screen, down the page
    /// first and then back up.
    @discardableResult
    func reveal(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        if isOnScreen(element) { return true }
        let window = app.windows.firstMatch
        // In the detail column, clear of the sidebar and the hero's pager.
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.72))
        let up = window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.32))
        for _ in 0..<maxSwipes {
            start.press(forDuration: 0.05, thenDragTo: up)
            if isOnScreen(element) { return true }
        }
        for _ in 0..<(maxSwipes * 2) {
            up.press(forDuration: 0.05, thenDragTo: start)
            if isOnScreen(element) { return true }
        }
        return isOnScreen(element)
    }

    /// Scrolls inside `container` (a card, a popover) until `element` is
    /// hittable — a swipe on the whole app would land on the picture.
    @discardableResult
    func reveal(_ element: XCUIElement, in container: XCUIElement, maxSwipes: Int = 6) -> Bool {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes && container.exists {
            container.swipeUp(velocity: .slow)
            n += 1
        }
        return element.exists && element.isHittable
    }

    // MARK: Orientation

    var isLandscape: Bool { app.frame.width > app.frame.height }

    func turn(_ orientation: UIDeviceOrientation, file: StaticString = #filePath, line: UInt = #line) {
        XCUIDevice.shared.orientation = orientation
        let wantWide = orientation.isLandscape
        let window: XCUIElement = app
        let turned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let f = window.frame
                return wantWide ? f.width > f.height : f.height > f.width
            }, object: nil)
        if XCTWaiter().wait(for: [turned], timeout: 15) != .completed {
            XCTFail("the window did not turn to \(wantWide ? "landscape" : "portrait")", file: file, line: line)
        }
    }

    // MARK: Waiting

    /// Waits until `condition` holds, polling; fails with `message` if it never does.
    @discardableResult
    func waitUntil(_ timeout: TimeInterval = 20, _ message: @autoclosure () -> String = "condition",
                   file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let ok = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        if !ok { XCTFail("timed out after \(Int(timeout)) s waiting for \(message())", file: file, line: line) }
        return ok
    }

    /// The same, without failing: whether it came true in time.
    func eventually(_ timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// An element's accessibility label, or its value as text.
    func text(_ element: XCUIElement) -> String {
        let value = (element.value as? String) ?? ""
        return [element.label, value].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: The player

    var player: XCUIElement { app.element(TestID.Player.root) }

    /// Opens the title and presses Play (or Resume) on its page.
    func play(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        openItem(id, file: file, line: line)
        let play = app.button(TestID.Detail.play)
        reveal(play)
        play.padTap(file: file, line: line)
        player.waitToExist(40, file: file, line: line)
    }

    /// The controls over the picture, brought up if they had hidden.
    func showControls(file: StaticString = #filePath, line: UInt = #line) {
        let controls = app.element(TestID.Player.controls)
        if controls.exists, app.button(TestID.Player.playPause).isHittable { return }
        app.element(TestID.Player.video).waitToExist(20, file: file, line: line)
        app.element(TestID.Player.video).padTap()
        controls.waitToExist(10, file: file, line: line)
    }

    /// Taps a control over the picture, bringing the controls up first. The
    /// controls hide on their own 4 s after a touch and a tap on the picture
    /// toggles them, so this tries a few times rather than trusting one look.
    func tapControl(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.button(id)
        let video = app.element(TestID.Player.video)
        for _ in 0..<4 {
            if control.exists && control.isHittable {
                control.tap()
                return
            }
            // Up but fading, or gone: a tap on the picture brings them back
            // (or puts them away; the next turn of the loop brings them back).
            if video.exists { video.tap() }
            _ = eventually(3) { control.exists && control.isHittable }
        }
        XCTFail("\(id) was not there to tap", file: file, line: line)
    }

    /// Whether play/pause says it is playing (its label reads "Pause").
    func isPlaying() -> Bool {
        let button = app.button(TestID.Player.playPause)
        return button.exists && button.label.localizedCaseInsensitiveContains("pause")
    }

    /// Waits for the stream to be playing (not loading).
    func waitForPlaying(_ timeout: TimeInterval = 45, file: StaticString = #filePath, line: UInt = #line) {
        showControls(file: file, line: line)
        waitUntil(timeout, "the player to be playing", file: file, line: line) { [self] in isPlaying() }
    }

    /// The position the scrubber reports, in seconds, read from the elapsed time.
    func elapsedSeconds() -> Double? {
        let elapsed = app.element(TestID.Player.elapsed)
        if !elapsed.exists, app.element(TestID.Player.video).exists, !app.element(TestID.Player.controls).exists {
            app.element(TestID.Player.video).tap()
            _ = elapsed.waitForExistence(timeout: 3)
        }
        guard elapsed.exists else { return nil }
        return Self.seconds(in: text(elapsed))
    }

    /// "1:02:03", "12:34", "0:05" → seconds; the first such run in the text.
    /// Also reads the spoken form the timeline's labels use: "5 minutes,
    /// 3 seconds", "1 hour 2 minutes".
    static func seconds(in text: String) -> Double? {
        if let match = text.range(of: #"\d+(:\d{2}){1,2}"#, options: .regularExpression) {
            let parts = text[match].split(separator: ":").compactMap { Double($0) }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        var total: Double = 0
        var found = false
        for (unit, scale) in [("hour", 3600.0), ("minute", 60.0), ("second", 1.0)] {
            if let r = text.range(of: #"(\d+)\s*"# + unit, options: .regularExpression) {
                let number = text[r].prefix { $0.isNumber }
                total += (Double(number) ?? 0) * scale
                found = true
            }
        }
        return found ? total : nil
    }

    /// Closes the player with its own Back and waits for it to go.
    func closePlayer(file: StaticString = #filePath, line: UInt = #line) {
        guard player.exists else { return }
        // A short title may have ended and closed the player by itself.
        let video = app.element(TestID.Player.video)
        if !video.waitForExistence(timeout: 3) {
            if player.waitToVanish(10) { return }
        }
        let back = app.button(TestID.Player.back)
        for _ in 0..<4 {
            if back.exists && back.isHittable { back.tap(); break }
            if !player.exists { return }
            if video.exists { video.tap() }
            _ = eventually(3) { back.exists && back.isHittable }
        }
        if !player.waitToVanish(20) { XCTFail("the player did not close", file: file, line: line) }
    }

    /// Opens a pill's card and waits for it.
    func openCard(pill: String, card: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        tapControl(pill, file: file, line: line)
        let element = app.element(card)
        element.waitToExist(15, file: file, line: line)
        return element
    }

    /// Every option button under a prefix (`player.audio.option.` …).
    func options(_ prefix: String) -> [XCUIElement] {
        app.elements(prefix: prefix).allElementsBoundByIndex.filter { $0.elementType == .button || $0.elementType == .cell || $0.elementType == .other }
    }

    // MARK: Context menus

    /// Presses and holds `element` until its context menu is up.
    func contextMenu(on element: XCUIElement, waitingFor item: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        element.waitToExist(20, file: file, line: line)
        // At its middle: a card's own anchor makes `press` refuse it as
        // not hittable (see `padTap`).
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.2)
        app.button(item).waitToExist(10, file: file, line: line)
    }
}
#endif

#if os(iOS)
extension XCUIElement {
    /// Waits for the element and taps it. A card's `.testAnchor` sits inside
    /// the card's button with the same name, and accessibility hit-testing
    /// (which `isHittable` and `tap()` ask) lands on the anchor rather than
    /// the button, so XCUITest calls the card "not hittable" though a finger
    /// presses it fine. Such an element is tapped at its middle instead.
    func padTap(_ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        waitToExist(timeout, file: file, line: line)
        guard exists else { return }
        if isHittable {
            tap()
        } else {
            coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
#endif

#if os(iOS)
extension PadUITestCase {
    /// A row of a SwiftUI `Menu` as the system draws it: on an iPad the
    /// identifier set on the row does not reach the menu's own button, so
    /// this falls back to the row's words.
    /// Puts the on-screen keyboard away with its own key (bottom right on an
    /// iPad), so whatever it covered can be reached.
    func dismissKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let hide = keyboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'keyboard'")).allElementsBoundByIndex
            .max { $0.frame.maxX + $0.frame.maxY < $1.frame.maxX + $1.frame.maxY }
        hide?.tap()
        _ = keyboard.waitToVanish(5)
    }

    func menuItem(_ id: String, label: String) -> XCUIElement {
        let byId = app.buttons.matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 3) { return byId }
        return app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
#endif

#if os(iOS)
extension JellyfinAPI {
    /// This account's sessions, most recently active first, the test's own
    /// left out. `sessions()` in the shared client asks with
    /// `ControllableByUserId`, which Jellyfin 12.2 answers with an empty list
    /// for an app that takes no remote control (the QA server, 2026-11-13),
    /// so the iPad tests ask for every active session and filter by user.
    /// Every test run is a new device, so older runs' sessions can still be
    /// listed for a few minutes: the most recent is the app under test.
    func padSessions(activeWithinSeconds: Int = 120) throws -> [Session] {
        let list = try json("/Sessions?ActiveWithinSeconds=\(activeWithinSeconds)") as? [[String: Any]] ?? []
        let mine = list.filter { ($0["UserId"] as? String) == userId && ($0["DeviceId"] as? String) != Self.deviceId }
        let sorted = mine.sorted { ($0["LastActivityDate"] as? String ?? "") > ($1["LastActivityDate"] as? String ?? "") }
        return sorted.map { s in
            let playing = s["NowPlayingItem"] as? [String: Any]
            let state = s["PlayState"] as? [String: Any]
            let ticks = (state?["PositionTicks"] as? Int64) ?? (state?["PositionTicks"] as? Int).map(Int64.init)
            return Session(
                id: s["Id"] as? String ?? "", client: s["Client"] as? String ?? "",
                deviceName: s["DeviceName"] as? String ?? "", deviceId: s["DeviceId"] as? String ?? "",
                userName: s["UserName"] as? String ?? "", nowPlayingId: playing?["Id"] as? String,
                positionSeconds: ticks.map { Double($0) / 10_000_000 }, isPaused: state?["IsPaused"] as? Bool, raw: s)
        }
    }

    /// A session playing `itemId` whose position is within `tolerance` of
    /// `seconds` — the app's own, told apart from earlier test runs' devices
    /// (each run is a new device, and their sessions linger, some still
    /// listed as playing the same fixture) by where it is in the title.
    func padSession(playing itemId: String, near seconds: Double, tolerance: Double = 20) -> Session? {
        (try? padSessions())?.first {
            $0.nowPlayingId == itemId && abs(($0.positionSeconds ?? -1000) - seconds) <= tolerance
        }
    }

    /// The most recent session playing `itemId` (or anything, with nil).
    func padPlaying(_ itemId: String? = nil) -> Session? {
        (try? padSessions())?.first { $0.nowPlayingId != nil && (itemId == nil || $0.nowPlayingId == itemId) }
    }
}
#endif
