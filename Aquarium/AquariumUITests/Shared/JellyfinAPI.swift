//  A small Jellyfin REST client for the tests themselves: put an account's
//  state where a test needs it, and read back what the server saw the app do.
//
//      let api = try JellyfinAPI.signIn()            // this suite's account
//      try api.markUnplayed(film.id); try api.setResume(film.id, seconds: 0)
//      ... drive the app ...
//      let data = try api.userData(film.id)
//      XCTAssertGreaterThan(data.positionSeconds, 30)
//      XCTAssertTrue(try api.sessions().contains { $0.client == "Aquarium" })
//
//  It signs in as its own device ("Aquarium UI Tests"), so its session is
//  never mistaken for the app's. Synchronous on purpose: tests read better
//  without `await` everywhere, and nothing here is on the main thread's
//  critical path. Endpoints are the ones QA/suite-reset.py uses (Jellyfin 10.9+).
//
//  For a full return to the suite's starting state run
//  `python3 -I suite-reset.py suite-<name>` in the QA folder before the run
//  (Tools/run-tests.sh does); these calls are for one item at a time.

import Foundation
import XCTest

final class JellyfinAPI {
    let server: String
    let userId: String
    let token: String
    static let deviceId = "aquarium-ui-tests"

    enum Failure: Error, CustomStringConvertible {
        case status(Int, String)
        case noAnswer(String)
        var description: String {
            switch self {
            case .status(let code, let path): "HTTP \(code) for \(path)"
            case .noAnswer(let path): "no answer for \(path)"
            }
        }
    }

    private init(server: String, userId: String, token: String) {
        self.server = server
        self.userId = userId
        self.token = token
    }

    /// Signs in as `account` (default: this suite's). Skips when there is no
    /// account to use.
    static func signIn(_ account: QA.Account? = QA.account(), server: String = QA.server) throws -> JellyfinAPI {
        guard let account else { throw XCTSkip("no password for suite-\(QA.suite) in \(QA.folder.path)/suite-accounts.txt") }
        let data = try call(server: server, token: nil, "POST", "/Users/AuthenticateByName",
                            body: ["Username": account.name, "Pw": account.password])
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let token = json["AccessToken"] as? String,
              let user = (json["User"] as? [String: Any])?["Id"] as? String
        else { throw Failure.noAnswer("/Users/AuthenticateByName") }
        return JellyfinAPI(server: server, userId: user, token: token)
    }

    // MARK: - Plumbing

    private static func header(_ token: String?) -> String {
        var h = "MediaBrowser Client=\"Aquarium UI Tests\", Device=\"UI Tests\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }

    @discardableResult
    private static func call(server: String, token: String?, _ method: String, _ path: String,
                             body: Any? = nil, timeout: TimeInterval = 15) throws -> Data {
        guard let url = URL(string: server + path) else { throw Failure.noAnswer(path) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(header(token), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?) = (nil, nil)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            result = (data, response)
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 2)
        guard let http = result.1 as? HTTPURLResponse else { throw Failure.noAnswer(path) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode, path) }
        return result.0 ?? Data()
    }

    @discardableResult
    func request(_ method: String, _ path: String, body: Any? = nil) throws -> Data {
        try Self.call(server: server, token: token, method, path, body: body)
    }

    func json(_ path: String) throws -> Any {
        let data = try request("GET", path)
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    private var user: String { "userId=\(userId)" }

    // MARK: - Watch state

    func markPlayed(_ itemId: String) throws { try request("POST", "/UserPlayedItems/\(itemId)?\(user)") }
    func markUnplayed(_ itemId: String) throws { try request("DELETE", "/UserPlayedItems/\(itemId)?\(user)") }
    func setFavorite(_ itemId: String, _ on: Bool = true) throws {
        try request(on ? "POST" : "DELETE", "/UserFavoriteItems/\(itemId)?\(user)")
    }

    /// Where playback would resume, in seconds (0 clears it). Sent with
    /// Played=false so the item is in progress rather than finished.
    func setResume(_ itemId: String, seconds: Double) throws {
        try request("POST", "/UserItems/\(itemId)/UserData?\(user)",
                    body: ["PlaybackPositionTicks": Int64(seconds * 10_000_000), "Played": false])
    }

    /// Unplayed, not a favourite, no resume point.
    func resetItem(_ itemId: String) throws {
        try? markUnplayed(itemId)
        try? setFavorite(itemId, false)
        try setResume(itemId, seconds: 0)
    }

    struct UserData {
        let played: Bool
        let favorite: Bool
        let positionSeconds: Double
        let playCount: Int
    }

    func userData(_ itemId: String) throws -> UserData {
        let j = try json("/UserItems/\(itemId)/UserData?\(user)") as? [String: Any] ?? [:]
        return UserData(
            played: j["Played"] as? Bool ?? false,
            favorite: j["IsFavorite"] as? Bool ?? false,
            positionSeconds: Double(j["PlaybackPositionTicks"] as? Int64 ?? Int64(j["PlaybackPositionTicks"] as? Int ?? 0)) / 10_000_000,
            playCount: j["PlayCount"] as? Int ?? 0
        )
    }

    // MARK: - What the server saw

    struct Session {
        let id: String
        let client: String
        let deviceName: String
        let deviceId: String
        let userName: String
        let nowPlayingId: String?
        let positionSeconds: Double?
        let isPaused: Bool?
        let raw: [String: Any]
    }

    /// This account's sessions, the test's own excluded, most recent first.
    /// Not `ControllableByUserId`: that leaves out every session that does not
    /// support remote control, which is the app's (found 2026-11-13).
    func sessions(activeWithinSeconds: Int = 300) throws -> [Session] {
        let list = (try json("/Sessions?ActiveWithinSeconds=\(activeWithinSeconds)") as? [[String: Any]] ?? [])
            .sorted { ($0["LastActivityDate"] as? String ?? "") > ($1["LastActivityDate"] as? String ?? "") }
        return list.compactMap { s in
            guard (s["UserId"] as? String) == userId, (s["DeviceId"] as? String) != Self.deviceId else { return nil }
            let playing = s["NowPlayingItem"] as? [String: Any]
            let state = s["PlayState"] as? [String: Any]
            let ticks = (state?["PositionTicks"] as? Int64) ?? (state?["PositionTicks"] as? Int).map(Int64.init)
            return Session(
                id: s["Id"] as? String ?? "",
                client: s["Client"] as? String ?? "",
                deviceName: s["DeviceName"] as? String ?? "",
                deviceId: s["DeviceId"] as? String ?? "",
                userName: s["UserName"] as? String ?? "",
                nowPlayingId: playing?["Id"] as? String,
                positionSeconds: ticks.map { Double($0) / 10_000_000 },
                isPaused: state?["IsPaused"] as? Bool,
                raw: s
            )
        }
    }

    /// Waits until the server reports the app playing `itemId` (or anything,
    /// with nil), polling every half second.
    func waitForPlayback(of itemId: String? = nil, timeout: TimeInterval = 30) throws -> Session? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let s = try sessions().first(where: { $0.nowPlayingId != nil && (itemId == nil || $0.nowPlayingId == itemId) }) {
                return s
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Ends the test's own server session.
    func signOut() { try? request("POST", "/Sessions/Logout") }
}
