//  What the Apple TV UI tests share beyond `Remote`: waiting on conditions,
//  the app's debug hooks posted from the runner, deep links, and the focus
//  checks every screen gets ("focus is never lost or trapped").
//
//  Nothing here sleeps for a fixed time: every wait is a predicate polled by
//  XCTWaiter until it holds or the timeout passes.

#if os(tvOS)
import XCTest
import Darwin

// MARK: - Debug hooks

/// Darwin notifications from the test runner into the app's DEBUG hooks
/// (`Player/TV/RemoteDebugHook.swift`). `notify_post` from inside the runner
/// reaches the app on the same simulator (see the memory note on tvOS
/// simulator testing); `xcrun simctl spawn … notifyutil` can't be used while
/// a test session owns the device.
///
/// `remote(...)` feeds `RemoteInputView` as the remote would — including the
/// touch-surface swipes XCUIRemote can't make. `debug(...)` asks for a state
/// line, a tab, the next track, the sync clip and so on.
enum TVHook {
    private typealias NotifyPost = @convention(c) (UnsafePointer<CChar>) -> UInt32

    private static let notifyPost: NotifyPost? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "notify_post") else { return nil }
        return unsafeBitCast(symbol, to: NotifyPost.self)
    }()

    static func post(_ name: String) {
        _ = name.withCString { notifyPost?($0) }
    }

    /// `select`, `playPause`, `menu`, `left`, `right`, `up`, `down`,
    /// `swipeLeft`, `swipeRight`, `swipeDown`, `swipeUp`, `panelSwipeUp`.
    static func remote(_ name: String) { post("aquarium.remote.\(name)") }

    /// `items`, `state`, `nearEnd`, `channel`, `audio.next`, `subs.next`,
    /// `subs.off`, `syncTest`, `syncTest.<fps>`, `play.<n>`, `tab.<tab|none>`.
    static func debug(_ name: String) { post("aquarium.debug.\(name)") }
}

// MARK: - Waiting

extension XCTestCase {
    /// Polls `condition` until it holds. Fails the test (unless `fail` is
    /// false) when it doesn't within `timeout`. Returns whether it held.
    @discardableResult
    func waitUntil(_ what: @autoclosure () -> String, timeout: TimeInterval = 20, fail: Bool = true,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @escaping () -> Bool) -> Bool {
        if condition() { return true }
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let held = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        if !held, fail {
            XCTFail("timed out after \(Int(timeout)) s waiting for \(what())", file: file, line: line)
        }
        return held
    }
}

extension XCUIElement {
    /// The element's identifier, label and value, for failure messages.
    var summary: String {
        guard exists else { return "<gone>" }
        return "\(elementType.rawValue) id=\(identifier) label=\(label) value=\(String(describing: value ?? ""))"
    }

    var hasFocusInside: Bool {
        hasFocus || descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }
}

// MARK: - Fixtures beyond `item(_:)`

extension Fixtures {
    /// An episode's id: `episode("show.long", season: 1, episode: 2)`.
    func episode(_ show: String, season: Int, episode: Int) throws -> String {
        let seasons = try item(show).raw["seasons"] as? [[String: Any]] ?? []
        guard let s = seasons.first(where: { $0["index"] as? Int == season }),
              let e = (s["episodes"] as? [[String: Any]] ?? []).first(where: { $0["index"] as? Int == episode }),
              let id = e["id"] as? String
        else { throw XCTSkip("no \(show) S\(season)E\(episode) in fixtures.json") }
        return id
    }

    func season(_ show: String, _ season: Int) throws -> String {
        let seasons = try item(show).raw["seasons"] as? [[String: Any]] ?? []
        guard let id = seasons.first(where: { $0["index"] as? Int == season })?["id"] as? String
        else { throw XCTSkip("no \(show) season \(season)") }
        return id
    }

    /// A media stream of a fixture film, by its server index.
    func stream(_ key: String, index: Int) throws -> [String: Any] {
        let sources = try item(key).raw["mediaSources"] as? [[String: Any]] ?? []
        guard let s = (sources.first?["streams"] as? [[String: Any]] ?? []).first(where: { $0["index"] as? Int == index })
        else { throw XCTSkip("no stream \(index) on \(key)") }
        return s
    }

    func streams(_ key: String, type: String) throws -> [[String: Any]] {
        let sources = try item(key).raw["mediaSources"] as? [[String: Any]] ?? []
        return (sources.first?["streams"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == type }
    }

    var liveChannels: [String] {
        let existing = raw["existing"] as? [String: Any]
        let live = existing?["liveTv"] as? [String: Any]
        return (live?["channels"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

// MARK: - The base of every Apple TV UI test in this folder

class TVTestCase: TVUITestCase {
    /// This suite's REST client, signed in on first use.
    private var _api: JellyfinAPI?
    func api() throws -> JellyfinAPI {
        if let _api { return _api }
        let client = try JellyfinAPI.signIn()
        _api = client
        return client
    }

    override func tearDownWithError() throws {
        _api?.signOut()
        _api = nil
        try super.tearDownWithError()
    }

    // MARK: Launch

    /// Clean, signed in as this suite, with Home on screen and something
    /// focused.
    /// Every Aquarium session this account has now: what the next launch
    /// must not be mistaken for.
    func markSessionsStale() {
        JellyfinAPI.tvStaleDevices = []
        if let all = try? api().tvSessions(activeWithinSeconds: 600) {
            JellyfinAPI.tvStaleDevices = Set(all.map(\.deviceId))
        }
    }

    @discardableResult
    func launchHome(engine: String? = nil, arguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        markSessionsStale()
        launch(engine: engine, arguments: arguments)
        app.element(TestID.Home.root).waitToExist(60, file: file, line: line)
        assertFocusPresent("Home after launch", file: file, line: line)
        return app
    }

    // MARK: Focus

    var focused: XCUIElement? { Remote.focused(in: app) }

    var focusedID: String { focused?.identifier ?? "" }

    var focusedLabel: String { focused?.label ?? "" }

    /// "Focus is never lost": something on screen holds focus.
    func assertFocusPresent(_ context: String, timeout: TimeInterval = 10,
                            file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("something focused on \(context)", timeout: timeout, file: file, line: line) { [weak self] in
            self?.focused != nil
        }
    }

    /// Where a screen opens with nothing focused (a known bug on library,
    /// collection and person screens, see `TVBrowseTests`): a press brings
    /// the selector back. True once something has focus.
    @discardableResult
    func recoverFocus() -> Bool {
        for button in [XCUIRemote.Button.right, .down, .left] {
            if focused != nil { return true }
            Remote.press(button)
            if waitUntil("focus after a press", timeout: 3, fail: false, { [weak self] in self?.focused != nil }) { return true }
        }
        return focused != nil
    }

    /// Up and Down only, judged by the target's middle against the focused
    /// element's: for a single column (Settings, a choice list, a dialog),
    /// where `Remote.focus` can stall on frames that overlap sideways.
    @discardableResult
    func focusInColumn(_ target: XCUIElement, maxPresses: Int = 30) -> Bool {
        guard target.waitForExistence(timeout: 10) else { return false }
        var last: CGFloat?
        for _ in 0..<maxPresses {
            if target.hasFocusInside { return true }
            guard let current = focused else { Remote.press(.down); continue }
            let dy = target.frame.midY - current.frame.midY
            if let last, last == current.frame.midY, abs(dy) < 2 { break }
            last = current.frame.midY
            Remote.press(dy > 0 ? .down : .up)
        }
        return target.hasFocusInside
    }

    /// Presses `button` until `condition` holds, at most `max` times. True
    /// when it got there. Each press waits for focus to settle first.
    @discardableResult
    func press(_ button: XCUIRemote.Button, until condition: () -> Bool, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if condition() { return true }
            Remote.press(button)
        }
        return condition()
    }

    /// Up to the tab strip. True once a tab item has focus.
    @discardableResult
    func focusTabStrip(max: Int = 12) -> Bool {
        press(.up, until: { [unowned self] in isTabFocused }, max: max)
    }

    var isTabFocused: Bool {
        guard let f = focused else { return false }
        return f.identifier.hasPrefix("tab.item.") || f.elementType == .tab
            || app.tabBars.firstMatch.exists && app.tabBars.firstMatch.hasFocusInside && f.frame.minY < 200
    }

    /// The tab strip's item for a section (`TestID.Tab.item`), by identifier,
    /// or by its title where the tab bar doesn't carry the identifier.
    func tab(_ section: String, title: String) -> XCUIElement {
        let byId = app.descendants(matching: .any).matching(identifier: TestID.Tab.item(section)).firstMatch
        if byId.exists { return byId }
        return app.tabBars.buttons[title].firstMatch
    }

    /// Opens a tab by walking the strip with the remote, then steps down into
    /// the page. Fails when the page's anchor doesn't show.
    func openTab(_ section: String, title: String, anchor: String,
                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(focusTabStrip(), "couldn't reach the tab strip (focus on \(focused?.summary ?? "nothing"))",
                      file: file, line: line)
        let target = tab(section, title: title)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no tab \(title)", file: file, line: line)
        var moved = 0
        while !target.hasFocus, moved < 8 {
            guard let current = focused else { break }
            Remote.press(target.frame.midX > current.frame.midX ? .right : .left)
            moved += 1
        }
        XCTAssertTrue(target.hasFocus, "tab \(title) never took focus", file: file, line: line)
        app.element(anchor).waitToExist(30, file: file, line: line)
    }

    /// Down from the strip into the page, and back up: the page is reachable
    /// and doesn't trap the selector.
    func assertPageEnterableAndLeavable(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        Remote.press(.down)
        assertFocusPresent("\(context) after Down from the strip", file: file, line: line)
        XCTAssertFalse(isTabFocused, "Down from the strip left focus on the strip on \(context)", file: file, line: line)
        XCTAssertTrue(focusTabStrip(max: 20), "Up from \(context) never reached the strip again (trapped on \(focused?.summary ?? "nothing"))",
                      file: file, line: line)
    }

    // MARK: Opening things

    /// Launches clean and has the app open an `aquarium://` link once signed
    /// in (`TestLaunch.linkEnv`), the way a Top Shelf cell does. `item` shows
    /// the title page; `play` starts it on a TV. (`XCUIApplication.open`
    /// doesn't reach the app on tvOS: it sat on Home for 37 s.)
    @discardableResult
    func launchWithLink(_ action: String, _ id: String, engine: String? = nil, arguments: [String] = [],
                        reset: Bool = true) -> XCUIApplication {
        markSessionsStale()
        launch(reset: reset, engine: engine, arguments: arguments,
               environment: [TestLaunch.linkEnv: "aquarium://\(action)/\(id)"])
        return app
    }

    /// A title page by item id, through the link the Top Shelf uses.
    func launchDetail(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        launchWithLink("item", id)
        app.element(TestID.Detail.page(id)).waitToExist(60, file: file, line: line)
        assertFocusPresent("the title page", file: file, line: line)
    }

    /// Starts a title through the `play` link and waits for the player.
    func launchPlaying(_ id: String, engine: String? = nil, arguments: [String] = [],
                       file: StaticString = #filePath, line: UInt = #line) {
        launchWithLink("play", id, engine: engine, arguments: arguments)
        app.element(TestID.Player.root).waitToExist(60, file: file, line: line)
    }

    // MARK: The player

    /// The position the server last heard from this app's session, if any.
    func serverPosition(of itemId: String) throws -> Double? {
        try api().tvSessions().first { $0.nowPlayingId == itemId }?.positionSeconds
    }

    /// Waits until the server says the app is playing `itemId` (unpaused)
    /// at or past `seconds`.
    @discardableResult
    func waitForServerPlayback(of itemId: String, pastSeconds seconds: Double = 0.5, timeout: TimeInterval = 45,
                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
        waitUntil("the server to report \(itemId) playing past \(seconds) s", timeout: timeout, file: file, line: line) { [weak self] in
            guard let self, let s = try? self.api().tvSessions().first(where: { $0.nowPlayingId == itemId }) else { return false }
            return (s.positionSeconds ?? 0) >= seconds
        }
    }

    /// The player's controls band, brought up by a click if it isn't.
    func showControls(file: StaticString = #filePath, line: UInt = #line) {
        if app.element(TestID.Player.controls).exists { return }
        TVHook.remote("up")
        waitUntil("the player's controls", timeout: 10, file: file, line: line) { [weak self] in
            self?.app.element(TestID.Player.controls).exists ?? false
        }
    }

    /// The value of an Info fact, from its "<label>, <value>" accessibility label.
    func infoFact(_ key: String) -> String? {
        let el = app.element(TestID.Player.infoFact(key))
        guard el.exists else { return nil }
        let label = el.label
        guard let comma = label.firstIndex(of: ",") else { return label }
        return label[label.index(after: comma)...].trimmingCharacters(in: .whitespaces)
    }

    // MARK: Evidence

    /// The element tree, attached to the test, for a screen worth recording.
    func attachTree(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "tree: \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif

#if os(tvOS)
import XCTest

// MARK: - Sessions the server sees

/// `JellyfinAPI.tvSessions()` asks with `ControllableByUserId`, and the server
/// answers that with remote-controllable sessions only. Aquarium doesn't
/// offer remote control, so it never returns the app's session (checked
/// against the QA server 2026-11-13: [] with the filter, the app's sessions
/// without). These ask without the filter; a non-admin sees only its own.
extension JellyfinAPI {
    /// Devices whose sessions belong to an app a previous launch left behind
    /// (every clean launch is a new device id). Set by `TVTestCase` just
    /// before it launches; their sessions are never this test's.
    nonisolated(unsafe) static var tvStaleDevices: Set<String> = []

    /// Most recently active first, and only sessions heard from in the last
    /// `activeWithinSeconds`: every clean launch is a new device id, and the
    /// app a previous test left playing stays "now playing" on the server
    /// until it stops reporting.
    func tvSessions(activeWithinSeconds: Int = 120) throws -> [Session] {
        let list = (try json("/Sessions?ActiveWithinSeconds=\(activeWithinSeconds)") as? [[String: Any]] ?? [])
            .sorted { ($0["LastActivityDate"] as? String ?? "") > ($1["LastActivityDate"] as? String ?? "") }
        return list.compactMap { s in
            guard (s["UserId"] as? String) == userId, (s["DeviceId"] as? String) != Self.deviceId,
                  !Self.tvStaleDevices.contains(s["DeviceId"] as? String ?? "") else { return nil }
            let playing = s["NowPlayingItem"] as? [String: Any]
            let state = s["PlayState"] as? [String: Any]
            let ticks = (state?["PositionTicks"] as? Int64) ?? (state?["PositionTicks"] as? Int).map(Int64.init)
            return Session(
                id: s["Id"] as? String ?? "", client: s["Client"] as? String ?? "",
                deviceName: s["DeviceName"] as? String ?? "", deviceId: s["DeviceId"] as? String ?? "",
                userName: s["UserName"] as? String ?? "", nowPlayingId: playing?["Id"] as? String,
                positionSeconds: ticks.map { Double($0) / 10_000_000 }, isPaused: state?["IsPaused"] as? Bool, raw: s
            )
        }
        .filter { $0.client == "Aquarium" }
    }

    /// Waits (polling, as `waitForPlayback` does) until this account's
    /// Aquarium session plays `itemId`, or anything with nil.
    func tvWaitForPlayback(of itemId: String? = nil, timeout: TimeInterval = 30) throws -> Session? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let s = try tvSessions().first(where: { $0.nowPlayingId != nil && (itemId == nil || $0.nowPlayingId == itemId) }) {
                return s
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }
}
#endif
