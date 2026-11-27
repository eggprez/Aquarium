//  The real Seerr, Radarr and Sonarr beside the QA Jellyfin
//  (`AquariumQA/arr`, see its README: `up.sh` starts them and puts back any
//  title a test deleted, `down.sh` stops them). The live Delete from Server
//  tests on each platform use this, and skip when the stack is down.

import Foundation
import XCTest

/// The real Seerr, Radarr and Sonarr beside the QA Jellyfin.
enum ArrQA {
    static let seerr = "http://127.0.0.1:8194"
    /// Launch environment: Seerr connected at sign-in.
    static var environment: [String: String] { [TestLaunch.seerrEnv: seerr] }
    /// The same, opening a title page once signed in.
    static func environment(opening id: String) -> [String: String] {
        [TestLaunch.seerrEnv: seerr, TestLaunch.linkEnv: "aquarium://item/\(id)"]
    }

    /// Skips without the stack; the admin account and its API otherwise.
    static func start(file: StaticString = #filePath, line: UInt = #line) throws -> (QA.Account, JellyfinAPI) {
        try require(file: file, line: line)
        let account = try XCTUnwrap(admin, "qa-account.txt has no admin account", file: file, line: line)
        return (account, try JellyfinAPI.signIn(account, server: jellyfin))
    }

    /// The film or show of this name in the Arr libraries, as Jellyfin has it.
    static func itemId(_ name: String, _ kind: String, _ api: JellyfinAPI) throws -> String {
        let term = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
        let found = try api.json("/Items?Recursive=true&IncludeItemTypes=\(kind)&SearchTerm=\(term)&Fields=Path") as? [String: Any]
        let items = (found?["Items"] as? [[String: Any]] ?? []).filter { ($0["Path"] as? String)?.contains("/arr/media/") == true }
        return try XCTUnwrap(items.first?["Id"] as? String, "\(name) is not in the Arr libraries (run arr/up.sh)")
    }

    /// In progress and played just now, so it is the first card on Continue
    /// Watching (a resume point alone leaves the last-played date as it was,
    /// and the card at the far end of the row).
    static func putFirstOnContinueWatching(_ id: String, _ api: JellyfinAPI) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try api.request("POST", "/UserItems/\(id)/UserData?userId=\(api.userId)",
                        body: ["PlaybackPositionTicks": 80_000_000, "Played": false, "LastPlayedDate": now])
    }

    static func gone(_ id: String, _ api: JellyfinAPI) -> Bool { (try? api.json("/Items/\(id)")) == nil }

    /// A button of the open delete dialog, by its identifier or its words.
    static func button(_ app: XCUIApplication, _ id: String, _ label: String) -> XCUIElement {
        let byId = app.buttons.matching(identifier: id).firstMatch
        return byId.exists ? byId : app.buttons[label].firstMatch
    }

    /// Polls until `condition` holds or `timeout` passes.
    static func eventually(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return condition()
    }
    static let jellyfin = "http://127.0.0.1:8196"
    static var folder: URL { QA.folder.appendingPathComponent("arr", isDirectory: true) }

    static var admin: QA.Account? {
        guard let text = try? String(contentsOf: QA.folder.appendingPathComponent("qa-account.txt"), encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let user = fields["user"], let password = fields["password"] else { return nil }
        return QA.Account(name: user, password: password)
    }

    private static func get(_ url: String, key: String? = nil) -> (Int, Data)? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        if let key { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let done = DispatchSemaphore(value: 0)
        var answer: (Int, Data)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { answer = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        return answer
    }

    static func require(file: StaticString = #filePath, line: UInt = #line) throws {
        guard get(seerr + "/api/v1/settings/public")?.0 == 200, radarrHas(tmdb: 0) != nil else {
            throw XCTSkip("the real Seerr and Radarr aren't answering (AquariumQA/arr)", file: file, line: line)
        }
    }

    /// Nil when Radarr can't be asked.
    static func radarrHas(tmdb: Int) -> Bool? { has("radarr", 8198, "movie", "tmdbId", tmdb) }
    static func sonarrHas(tvdb: Int) -> Bool? { has("sonarr", 8199, "series", "tvdbId", tvdb) }

    private static func has(_ name: String, _ port: Int, _ list: String, _ field: String, _ id: Int) -> Bool? {
        guard let key = try? String(contentsOf: folder.appendingPathComponent("\(name).key"), encoding: .utf8),
              let (status, data) = get("http://127.0.0.1:\(port)/api/v3/\(list)", key: key.trimmingCharacters(in: .whitespacesAndNewlines)),
              status == 200, let titles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return titles.contains { $0[field] as? Int == id }
    }
}
