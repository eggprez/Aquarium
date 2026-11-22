//  The stand-in Seerr server (`Tools/seerr-mock.py`), as the UI tests see it.
//
//  It answers the parts of Seerr's API the app uses and signs users in
//  against the QA Jellyfin server, so the app's own Quick Connect exchange is
//  what connects it. `Tools/run-tests.sh` starts it when it isn't running; a
//  test skips when it doesn't answer (`SeerrQA.require()`).
//
//      try SeerrQA.require()                    // skip without the server; start clean
//      launch(environment: SeerrQA.environment) // the app connects at launch
//      SeerrQA.requests()                       // what has been asked for

import Foundation
import XCTest

enum SeerrQA {
    /// Env `AQUARIUM_SEERR_MOCK` overrides it.
    static var server: String {
        if let s = QA.env["AQUARIUM_SEERR_MOCK"], !s.isEmpty { return s }
        return "http://127.0.0.1:8197"
    }

    /// Hand this to `launch(environment:)` to start with Requests connected.
    static var environment: [String: String] { [TestLaunch.seerrEnv: server] }

    /// Skips the test when the stand-in isn't answering, and forgets every
    /// request made by the test before.
    static func require(file: StaticString = #filePath, line: UInt = #line) throws {
        guard call("GET", "/api/v1/settings/public") != nil else {
            throw XCTSkip("the Seerr stand-in isn't answering at \(server) (Tools/seerr-mock.py)", file: file, line: line)
        }
        _ = call("POST", "/__test/reset")
    }

    /// Every request the stand-in holds, oldest first.
    static func requests() -> [[String: Any]] {
        (call("GET", "/__test/state") as? [String: Any])?["requests"] as? [[String: Any]] ?? []
    }

    /// How many times the app has asked for `path` (below `/api/v1`) since
    /// the last reset. The stand-in keeps the last 400 calls.
    static func callCount(_ path: String) -> Int {
        let calls = (call("GET", "/__test/state") as? [String: Any])?["calls"] as? [[String: Any]] ?? []
        return calls.filter { ($0["path"] as? String) == "/api/v1" + path }.count
    }

    static var sessionCount: Int {
        (call("GET", "/__test/state") as? [String: Any])?["sessions"] as? Int ?? 0
    }

    /// Throw every session away, as Seerr does after thirty days.
    static func expireSessions() { _ = call("POST", "/__test/expire") }
    /// Seerr's Cache Images setting; `require()` turns it back on.
    static func cacheImages(_ on: Bool) { _ = call("POST", "/__test/images/\(on ? "on" : "off")") }
    /// Every browse row (Trending, Popular…) answers this many seconds late;
    /// `reset` puts it back to 0.
    static func slowRows(_ seconds: Int) { _ = call("POST", "/__test/discover/slow?seconds=\(seconds)") }
    static func approve(_ id: Int) { _ = call("POST", "/__test/approve/\(id)") }
    static func decline(_ id: Int) { _ = call("POST", "/__test/decline/\(id)") }

    /// Make a request as a Jellyfin user who has already connected.
    @discardableResult
    static func request(as user: String, type: String, tmdbId: Int, seasons: [Int] = []) -> Int? {
        var path = "/__test/request?user=\(user)&type=\(type)&id=\(tmdbId)"
        if !seasons.isEmpty { path += "&seasons=" + seasons.map(String.init).joined(separator: ",") }
        return (call("POST", path) as? [String: Any])?["id"] as? Int
    }

    /// The Jellyfin id of a library title, by kind and TMDB id.
    static func libraryId(_ kind: String, tmdbId: Int) -> String? {
        let library = call("GET", "/__test/library") as? [String: Any]
        return (library?["\(kind)-\(tmdbId)"] as? [String: Any])?["id"] as? String
    }

    private static func call(_ method: String, _ path: String) -> Any? {
        guard let url = URL(string: server + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        var result: Any?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [String: Any]()
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return result
    }
}
