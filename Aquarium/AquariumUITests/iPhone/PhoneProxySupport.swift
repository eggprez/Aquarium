//  Tests that need a server they can slow down, make refuse, or take away:
//  the download queue, on-device music and the offline states.
//
//  They sign the app in through `Tools/qa-switch-proxy.py` (127.0.0.1:8177
//  in front of the QA server, switched by GETs on 8178), which
//  `Tools/run-tests.sh iphone` starts and stops. The test's own REST calls
//  (`api`) still go straight to the QA server, so they work while the app's
//  server is "down". Without the proxy these tests skip.

#if os(iOS)
import XCTest

enum PhoneProxy {
    static var port: Int { Int(QA.env["AQUARIUM_PHONE_PROXY_PORT"] ?? "") ?? 8177 }
    static var controlPort: Int { Int(QA.env["AQUARIUM_PHONE_PROXY_CONTROL"] ?? "") ?? port + 1 }
    /// What the app signs in to.
    static var server: String { "http://127.0.0.1:\(port)" }

    /// One GET on the control port; the proxy's state as it answers.
    @discardableResult
    static func control(_ path: String) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(controlPort)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let done = DispatchSemaphore(value: 0)
        var state: [String: Any]?
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, _ in
            if let data { state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return state
    }

    static var isRunning: Bool { control("/state")?["up"] != nil }
    /// Up, no cap, nothing refused.
    static func reset() { control("/reset") }
    /// The server goes away: nothing listens, open connections drop.
    static func cut() { control("/set?up=0") }
    static func restore() { control("/set?up=1") }
    /// Caps what the server sends for requests whose first line contains
    /// `matching` (stay above ~3 Mbps: a transfer still has to move).
    static func slow(_ bitsPerSecond: Int, matching: String) {
        control("/set?rate=\(bitsPerSecond)&throttle=\(matching)")
    }
    static func unslow() { control("/set?rate=0&throttle=") }
    /// Requests whose first line contains `matching` are answered `status`.
    /// 410 is one the app does not ask again for: the download fails at once.
    static func fail(_ matching: String, status: Int = 410) { control("/set?fail=\(matching)&status=\(status)") }
    static func stopFailing() { control("/set?fail=") }
    /// How many requests have been refused since the last reset.
    static var hits: Int { control("/state")?["hits"] as? Int ?? 0 }
}

/// Signed in through the switch proxy, on the standard phone only.
class PhoneProxyTestCase: PhoneMusicTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try standardOnly()
        try XCTSkipUnless(PhoneProxy.isRunning,
                          "the switch proxy is not answering on \(PhoneProxy.controlPort): Tools/run-tests.sh iphone starts it (Tools/qa-switch-proxy.py)")
        PhoneProxy.reset()
    }

    override func tearDownWithError() throws {
        // The app first, so nothing it had under way meets the server coming back.
        app?.terminate()
        PhoneProxy.reset()
        try super.tearDownWithError()
    }

    /// Clean, signed in through the proxy, Home showing.
    func launchThroughProxy(file: StaticString = #filePath, line: UInt = #line) {
        launch(environment: [TestLaunch.serverEnv: PhoneProxy.server])
        app.element(TestID.Home.root).waitToExist(90, file: file, line: line)
    }

    // MARK: Downloads

    func openDownloads(file: StaticString = #filePath, line: UInt = #line) {
        let root = app.element(TestID.Downloads.root)
        if root.exists, !app.element(TestID.Downloads.seriesRoot).exists { return }
        // More keeps the page it last pushed: Downloads may already be there.
        tab("More", file: file, line: line)
        if root.waitForExistence(timeout: 3), !app.element(TestID.Downloads.seriesRoot).exists { return }
        if !app.element(TestID.Shell.more).exists { goBack(file: file, line: line) }
        moreSection("downloads", file: file, line: line)
        root.waitToExist(20, file: file, line: line)
    }

    /// Asks for a film from its page and comes back to Home. It is queued,
    /// not waited for.
    @discardableResult
    func queueFilm(_ key: String, quality: String = "Original quality",
                   file: StaticString = #filePath, line: UInt = #line) throws -> Fixtures.Item {
        let item = try Fixtures.require().item(key)
        openTitle(item.id, searching: item.name, file: file, line: line)
        app.button(TestID.Detail.download).tapNow(20, file: file, line: line)
        any(TestID.Detail.downloadQuality(quality)).tapNow(10, file: file, line: line)
        acceptSpacePrompt()
        goBack(file: file, line: line)
        goBack(file: file, line: line)
        return item
    }

    /// Asks for whole seasons of a show from the show's page (the Download
    /// menu has a submenu per season) and comes back to Home.
    func queueSeasons(of show: Fixtures.Item, seasonIds: [String], quality: String = "Original quality",
                      file: StaticString = #filePath, line: UInt = #line) {
        openTitle(show.id, searching: show.name, file: file, line: line)
        for season in seasonIds {
            app.button(TestID.Detail.download).tapNow(20, file: file, line: line)
            any(TestID.Detail.downloadSeason(season)).tapNow(10, file: file, line: line)
            // A submenu's rows lose their identifiers on iOS 27: by label
            // ("Original quality, About 11.9 MiB"), the one open submenu's.
            let byId = any(TestID.Detail.downloadSeasonQuality(season, quality))
            let choice = byId.waitForExistence(timeout: 2) ? byId
                : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", quality)).firstMatch
            choice.tapNow(10, file: file, line: line)
            acceptSpacePrompt()
            // The menu takes a moment to leave; the button is behind it till then.
            _ = choice.waitToVanish(5)
        }
        goBack(file: file, line: line)
        goBack(file: file, line: line)
    }

    func acceptSpacePrompt() {
        let anyway = any(TestID.Downloads.spacePromptAnyway)
        if anyway.waitForExistence(timeout: 2) { anyway.tap() }
    }

    /// Scrolls the element into view and taps the middle of it.
    func revealAndTap(_ element: XCUIElement, _ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        element.waitToExist(timeout, file: file, line: line)
        app.reveal(element)
        element.tapNow(5, file: file, line: line)
    }

    /// Holds a tile or row until its menu opens, then returns the entry.
    func heldMenu(on element: XCUIElement, item id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        element.waitToExist(20, file: file, line: line)
        app.reveal(element)
        let entry = any(id)
        for _ in 0..<3 where !entry.exists {
            element.press(forDuration: 1.2)
            if entry.waitForExistence(timeout: 4) { break }
        }
        entry.waitToExist(2, file: file, line: line)
        return entry
    }

    /// Closes an open menu without choosing from it.
    func dismissMenu() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }

    /// The Downloads page's "…" menu, opened.
    func openManageMenu(file: StaticString = #filePath, line: UInt = #line) {
        let manage = any(TestID.Downloads.manageMenu)
        manage.waitToExist(10, file: file, line: line)
        for _ in 0..<4 where manage.frame.minY < 60 || !manage.isOnScreen(in: app.windows.firstMatch.frame) { app.swipeDown() }
        manage.tapNow(5, file: file, line: line)
    }

    /// Leaves the device with nothing downloaded, queued or failed, so the
    /// next test (and the next launch's background sessions) start from nothing.
    func wipeDownloads(file: StaticString = #filePath, line: UInt = #line) {
        openDownloads(file: file, line: line)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH 'downloads.transfer.' OR identifier BEGINSWITH 'downloads.queued.' OR identifier BEGINSWITH 'downloads.failed.' OR identifier BEGINSWITH 'downloads.film.' OR identifier BEGINSWITH 'downloads.show.' OR identifier == 'downloads.door.music' OR identifier == 'downloads.door.audiobooks'"))
        for _ in 0..<3 {
            if eventually(timeout: 3, { rows.count == 0 }) { return }
            let clear = any(TestID.Downloads.queueClear)
            if clear.exists { revealAndTap(clear, 5, file: file, line: line) }
            openManageMenu(file: file, line: line)
            let all = any(TestID.Downloads.manageDeleteAll)
            if all.waitForExistence(timeout: 4) {
                all.tap()
                any(TestID.Downloads.deletionConfirm).tapNow(10, file: file, line: line)
            } else {
                dismissMenu()
            }
        }
        XCTAssertTrue(eventually(timeout: 20) { rows.count == 0 }, "downloads left behind", file: file, line: line)
    }
}
#endif
