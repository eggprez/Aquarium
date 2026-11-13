//  Watch UI tests live in this folder (owner: the Watch agent). They compile
//  for watchOS only, with AquariumUITests/Shared and the identifier
//  catalogue. Subclass `WatchUITestCase`. See Aquarium/TESTING.md.
//
//  The watch signs itself in in test mode (no phone needed), so every test
//  starts clean as suite-watch on the QA server. The paired test iPhone has
//  no Aquarium on it, but the watch simulator reports the companion app
//  installed anyway; WatchDownloadUITests launches with
//  `-AquariumTestNoCompanion YES` so downloads come straight from the server.

import XCTest

class WatchUITestCase: AquariumUITestCase {
    /// Not terminated after each test: on the watchOS 27 simulator
    /// `XCUIApplication.terminate()` takes about two minutes to return, while
    /// the next test's `launch()` replaces the running copy in a second or two.
    /// The last test's copy is left running (harmless; `simctl terminate` ends it).
    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    /// Scrolls the list a little at a time (a plain swipe overshoots on a
    /// watch) until the element is on screen; down again if it went past.
    @discardableResult
    func reach(_ element: XCUIElement, tries: Int = 30) -> Bool {
        let window = app.windows.firstMatch
        for _ in 0..<tries {
            let screen = window.exists ? window.frame : CGRect(x: 0, y: 0, width: 208, height: 248)
            var up = true
            if element.exists {
                let mid = element.frame.midY
                // Well inside the screen, clear of the title and of the
                // bottom bar (whose button takes taps meant for the row
                // under it: master fix list).
                if mid > screen.minY + screen.height * 0.12, mid < screen.minY + screen.height * 0.62 { return true }
                up = mid >= screen.minY + screen.height * 0.62
            }
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.35))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.7))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        // Where scrolling can't move it further (the top or end of a list):
        // on screen is enough.
        return element.exists && window.frame.intersects(element.frame)
    }

    /// Launch clean and signed in, and wait for the home list to say so.
    @discardableResult
    func launchHome(reset: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        launch(reset: reset)
        app.element(TestID.Watch.root).waitToExist(60, file: file, line: line)
        app.element(TestID.Watch.rootState("signedIn")).waitToExist(60, file: file, line: line)
        return app
    }

    /// Scroll to an element and tap it.
    func open(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.element(id)
        if !target.waitForExistence(timeout: 5) { reach(target) }
        target.waitToExist(30, file: file, line: line)
        reach(target)
        if target.isHittable { target.tap() } else { target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    /// Back one page: the navigation bar's back button (top left).
    func back() {
        let button = app.navigationBars.buttons.firstMatch
        if button.waitForExistence(timeout: 5) { button.tap() } else { app.swipeRight() }
    }

    /// The text an element shows: its label, or its value when it has one.
    func text(_ id: String) -> String {
        let e = app.element(id)
        if !e.waitForExistence(timeout: 3) { reach(e, tries: 8) }
        guard e.waitForExistence(timeout: 5) else { return "" }
        let value = (e.value as? String) ?? ""
        return value.isEmpty ? e.label : e.label + " " + value
    }

    /// Waits until the element's text satisfies `test`.
    @discardableResult
    func waitForText(_ id: String, timeout: TimeInterval = 20, _ test: @escaping (String) -> Bool) -> String {
        let end = Date().addingTimeInterval(timeout)
        var last = ""
        repeat {
            last = text(id)
            if test(last) { return last }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return last
    }

    /// m:ss or h:mm:ss as seconds.
    static func seconds(_ clock: String) -> Double? {
        let parts = clock.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

/// The QA server's music and books, by name, from fixtures.json (the
/// generic `Fixtures.item` covers keyed entries only).
struct WatchFixtures {
    struct Track { let id: String; let name: String; let seconds: Double }
    struct Album { let id: String; let name: String; let tracks: [Track] }

    let albums: [Album]
    let books: [(id: String, name: String, seconds: Double)]
    let artists: [String: String]
    let genres: [String: String]
    let playlists: [String: String]

    static func require() throws -> WatchFixtures {
        let fx = try Fixtures.require()
        let fixtures = fx.raw["fixtures"] as? [String: Any] ?? [:]
        let music = fixtures["music"] as? [String: Any] ?? [:]
        let albums: [Album] = (music["albums"] as? [[String: Any]] ?? []).map { a in
            Album(id: a["id"] as? String ?? "", name: a["name"] as? String ?? "",
                  tracks: (a["tracks"] as? [[String: Any]] ?? []).map {
                      Track(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", seconds: $0["durationSeconds"] as? Double ?? 0)
                  })
        }
        let books = (fixtures["books"] as? [[String: Any]] ?? []).map {
            (id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", seconds: $0["durationSeconds"] as? Double ?? 0)
        }
        func byName(_ list: Any?) -> [String: String] {
            Dictionary((list as? [[String: Any]] ?? []).compactMap { e in
                (e["name"] as? String).flatMap { n in (e["id"] as? String).map { (n, $0) } }
            }, uniquingKeysWith: { a, _ in a })
        }
        let sets = fx.raw["sets"] as? [String: Any] ?? [:]
        var playlists: [String: String] = [:]
        for (name, value) in sets {
            if let v = value as? [String: Any], v["type"] as? String == "Playlist", let id = v["id"] as? String { playlists[name] = id }
        }
        let out = WatchFixtures(albums: albums, books: books, artists: byName(music["artists"]),
                                genres: byName(music["genres"]), playlists: playlists)
        guard !out.albums.isEmpty, !out.books.isEmpty else { throw XCTSkip("fixtures.json has no music or books") }
        return out
    }

    func album(_ name: String) throws -> Album {
        guard let a = albums.first(where: { $0.name == name }) else { throw XCTSkip("no album \(name) in fixtures.json") }
        return a
    }

    func book(_ name: String) throws -> (id: String, name: String, seconds: Double) {
        guard let b = books.first(where: { $0.name == name }) else { throw XCTSkip("no book \(name) in fixtures.json") }
        return b
    }
}
