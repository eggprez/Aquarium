//  What the settings tests that change rows share (PhoneSettingsControlsTests):
//  opening a settings page, flipping a switch, picking from a row's menu,
//  relaunching with the state kept, and a few bytes of HTTP server for a
//  custom Live TV playlist.
//
//  The idioms are the ones PhoneSettingsTests settled on (2026-11-13): a
//  switch is tapped at its trailing end, a Picker's row is tapped and its
//  options found by identifier or by label, and the way back to the Settings
//  list is the More tab, not a back button.

#if os(iOS)
import XCTest
import Network

class PhoneSettingsDriverCase: PhoneUITestCase {
    static let pageTitles = ["account": "Account", "appearance": "Appearance", "video": "Video", "audio": "Audio",
                             "subtitles": "Subtitles", "music": "Music", "liveTV": "Live TV", "downloads": "Downloads",
                             "libraryCopy": "Library copy", "about": "About", "watch": "Apple Watch"]

    func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Everything an element says: its label and its value.
    func said(_ element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return element.label + " " + (element.value as? String ?? "")
    }

    /// On the small phone a row near the foot sits under the floating tab
    /// bar, where a tap opens a tab: drag it up into the top part first.
    func clearOfTheTabBar(_ element: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0..<3 where element.exists && element.frame.maxY > window.frame.height * 0.7 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
    }

    /// Brings a row into view, clear of the tab bar.
    @discardableResult
    func bring(_ element: XCUIElement) -> XCUIElement {
        if !element.waitForExistence(timeout: 3) { app.reveal(element) }
        if element.exists, !element.isOnScreen(in: app.windows.firstMatch.frame) { app.reveal(element) }
        clearOfTheTabBar(element)
        return element
    }

    /// A page of Settings, from the Settings list.
    func openSettingsPage(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        let link = any(TestID.Settings.pageLink(page))
        bring(link)
        link.tapNow(20, file: file, line: line)
        let root = app.element(page == "watch" ? TestID.WatchSettings.root : TestID.Settings.pageRoot(page))
        let title = Self.pageTitles[page] ?? page
        let opened = { root.exists || self.app.navigationBars[title].exists }
        if !eventually(timeout: 6, opened), link.exists, app.element(TestID.Settings.root).exists {
            bring(link)
            link.tapNow(10, file: file, line: line)
        }
        XCTAssertTrue(eventually(timeout: 20, opened), "Settings › \(title) did not open", file: file, line: line)
    }

    /// Settings, then one of its pages.
    func openSettings(page: String, file: StaticString = #filePath, line: UInt = #line) {
        openSettings(file: file, line: line)
        openSettingsPage(page, file: file, line: line)
    }

    /// Back to the Settings list from any page under it: the More tab pops
    /// to its list, and Settings is opened again. (Not a back button: on the
    /// Duo's front screen the system one sits in the trailing column.)
    func backToSettingsList(file: StaticString = #filePath, line: UInt = #line) {
        tab("More", file: file, line: line)
        if !app.element(TestID.Shell.more).waitForExistence(timeout: 3) { tab("More", file: file, line: line) }
        let row = any(TestID.Shell.moreRow("settings"))
        app.reveal(row)
        row.tapNow(20, file: file, line: line)
        app.element(TestID.Settings.root).waitToExist(10, file: file, line: line)
    }

    // MARK: Switches

    func settingSwitch(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let toggle = app.switches[id]
        bring(toggle)
        toggle.waitToExist(10, file: file, line: line)
        return toggle
    }

    func isOn(_ toggle: XCUIElement) -> Bool { (toggle.value as? String) == "1" }

    /// Puts a switch on or off (a no-op when it already is) and waits for it
    /// to say so. Returns what it was before.
    @discardableResult
    func setSwitch(_ id: String, _ on: Bool, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let toggle = settingSwitch(id, file: file, line: line)
        let was = isOn(toggle)
        if was != on {
            // The switch is at the row's trailing end; the row's middle is text.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertTrue(eventually(timeout: 5) { self.isOn(toggle) == on }, "\(id) did not turn \(on ? "on" : "off")", file: file, line: line)
        return was
    }

    func assertSwitch(_ id: String, _ on: Bool, _ why: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let toggle = settingSwitch(id, file: file, line: line)
        XCTAssertEqual(isOn(toggle), on, "\(id) \(why)", file: file, line: line)
    }

    // MARK: Pickers

    /// Opens a Picker row's menu and picks the option with this key (the
    /// catalogue's `option(row, key)`), found by its label where the menu
    /// drops identifiers. Waits for the row to read the label.
    func choose(_ row: String, key: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = any(row)
        bring(picker)
        picker.tapNow(10, file: file, line: line)
        let option = menuItem(TestID.Settings.option(row, key), label: label)
        XCTAssertTrue(option.exists, "\(row) offers no “\(label)”", file: file, line: line)
        option.tapNow(8, file: file, line: line)
        XCTAssertTrue(eventually(timeout: 10) { self.said(self.any(row)).contains(label) },
                      "\(row) does not read “\(label)” after picking it: \(said(any(row)))", file: file, line: line)
    }

    func assertRow(_ row: String, reads label: String, _ why: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let picker = any(row)
        bring(picker)
        XCTAssertTrue(eventually(timeout: 10) { self.said(picker).contains(label) },
                      "\(row) should read “\(label)” \(why): \(said(picker))", file: file, line: line)
    }

    // MARK: Steppers

    /// The + or − of the stepper in the row with this identifier ("Increment"
    /// or "Decrement"): the one on the row's own line, since a page can have
    /// several steppers.
    func stepperButton(_ id: String, _ which: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = any(id)
        bring(row)
        row.waitToExist(10, file: file, line: line)
        let inside = row.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", which, which)).firstMatch
        if inside.exists { return inside }
        let frame = row.frame
        let all = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", which, which)).allElementsBoundByIndex
        if let sameLine = all.first(where: { $0.frame.midY >= frame.minY - 1 && $0.frame.midY <= frame.maxY + 1 }) { return sameLine }
        XCTFail("no \(which) button in \(id)", file: file, line: line)
        return inside
    }

    // MARK: Questions

    /// Says no to a confirmation: its Cancel where it has one, else a tap
    /// outside it (on an iPhone with iOS 27 a confirmation is a popover with
    /// no Cancel button; see MANUAL.md).
    func sayNo(cancel id: String) {
        let cancel = any(id)
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
    }

    // MARK: Relaunch

    /// Quit and open again with everything kept (defaults, sign-in), and wait
    /// for Home.
    func relaunchKeepingState(file: StaticString = #filePath, line: UInt = #line) {
        app.terminate()
        launch(reset: false)
        app.element(TestID.Home.root).waitToExist(90, file: file, line: line)
    }

    /// The newest toast's words, once one shows.
    func toastText(timeout: TimeInterval = 8) -> String? {
        let text = any(TestID.Shell.toastText)
        guard text.waitForExistence(timeout: timeout) else { return nil }
        return (try? text.snapshot().label) ?? text.label
    }
}

/// A few bytes of HTTP on a local port, for the app to fetch a custom Live TV
/// playlist and guide from. The simulator shares this Mac's network, so the
/// app reaches it at 127.0.0.1.
final class PhoneTinyServer {
    typealias Route = (type: String, body: Data)

    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue

    var base: String { "http://127.0.0.1:\(port)" }

    /// Skips the test when no port can be opened here.
    init(routes: [String: Route]) throws {
        let queue = DispatchQueue(label: "aquarium.uitests.tiny-server")
        guard let listener = try? NWListener(using: .tcp, on: .any) else {
            throw XCTSkip("could not open a local port to serve a playlist from")
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            PhoneTinyServer.serve(connection, routes: routes)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw XCTSkip("could not open a local port to serve a playlist from")
        }
        self.port = port
        self.listener = listener
        self.queue = queue
    }

    func stop() { listener.cancel() }

    private static func serve(_ connection: NWConnection, routes: [String: Route]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?").first.map(String.init) ?? target
            var head: String
            var body = Data()
            if let route = routes[path] {
                body = route.body
                head = "HTTP/1.1 200 OK\r\nContent-Type: \(route.type)\r\n"
            } else {
                head = "HTTP/1.1 404 Not Found\r\n"
            }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var answer = Data(head.utf8)
            answer.append(body)
            connection.send(content: answer, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
