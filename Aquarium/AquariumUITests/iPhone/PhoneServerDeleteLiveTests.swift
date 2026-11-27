//  Delete from Server against the real thing: the QA Jellyfin, and a real
//  Seerr, Radarr and Sonarr beside it (`AquariumQA/arr`, see its README).
//  Every test skips when that stack isn't running. The deleting tests each
//  use up a title; `arr/setup.py` puts them back.

#if os(iOS)
import XCTest

final class PhoneServerDeleteLiveTests: PhoneUITestCase {
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private var admin: JellyfinAPI!
    private var account: QA.Account!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try standardOnly()
        try ArrQA.require()
        account = try XCTUnwrap(ArrQA.admin, "qa-account.txt has no admin account")
        admin = try JellyfinAPI.signIn(account, server: ArrQA.jellyfin)
    }

    /// The film or show of this name in the Arr libraries, as Jellyfin has it.
    private func itemId(_ name: String, _ kind: String) throws -> String {
        let term = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
        let found = try admin.json("/Items?Recursive=true&IncludeItemTypes=\(kind)&SearchTerm=\(term)&Fields=Path") as? [String: Any]
        let items = (found?["Items"] as? [[String: Any]] ?? []).filter { ($0["Path"] as? String)?.contains("/arr/media/") == true }
        return try XCTUnwrap(items.first?["Id"] as? String, "\(name) is not in the Arr libraries (run arr/setup.py)")
    }

    private func gone(_ id: String) -> Bool { (try? admin.json("/Items/\(id)")) == nil }

    /// The film's own page, signed in as the admin and connected to the real
    /// Seerr, with Delete from Server… chosen from its More menu.
    private func askToDelete(_ id: String, named name: String) throws {
        launch(account: account, environment: [TestLaunch.seerrEnv: ArrQA.seerr])
        app.element(TestID.Home.root).waitToExist(90)
        openTitle(id, searching: name)
        app.button(TestID.Detail.more).tapNow(20)
        any(TestID.Detail.deleteFromServer).tapNow(15)
    }

    private func dialogButton(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    func testAFilmOnRadarrOffersJellyfinSeerrAndBoth() throws {
        try askToDelete(itemId("Nosferatu", "Movie"), named: "Nosferatu")
        XCTAssertTrue(dialogButton("Delete from Jellyfin").waitForExistence(timeout: 20), "Jellyfin's way is not offered")
        attachScreenshot("delete dialog, real Seerr")
        XCTAssertTrue(dialogButton("Delete from Seerr").exists, "Seerr's way is not offered")
        XCTAssertTrue(dialogButton("Delete from Both").exists, "Both is not offered")
    }

    func testSeerrAloneTakesTheFilmOffRadarr() throws {
        let id = try itemId("Metropolis", "Movie")
        try askToDelete(id, named: "Metropolis")
        dialogButton("Delete from Seerr").tapNow(20)
        XCTAssertTrue(eventually(timeout: 30) { ArrQA.radarrHas(tmdb: 19) == false }, "Radarr still has the film")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ArrQA.folder.appendingPathComponent("media/movies/Metropolis (1927)/Metropolis (1927).mkv").path))
    }

    func testBothTakesTheFilmOffRadarrAndOutOfJellyfin() throws {
        let id = try itemId("Safety Last", "Movie")
        try askToDelete(id, named: "Safety Last")
        dialogButton("Delete from Both").tapNow(20)
        XCTAssertTrue(eventually(timeout: 30) { ArrQA.radarrHas(tmdb: 22596) == false }, "Radarr still has the film")
        XCTAssertTrue(eventually(timeout: 30) { self.gone(id) }, "Jellyfin still lists the film")
    }

    func testBothTakesAShowOffSonarrAndOutOfJellyfin() throws {
        let id = try itemId("Spaced", "Series")
        try askToDelete(id, named: "Spaced")
        dialogButton("Delete from Both").tapNow(20)
        XCTAssertTrue(eventually(timeout: 30) { ArrQA.sonarrHas(tvdb: 72658) == false }, "Sonarr still has the show")
        XCTAssertTrue(eventually(timeout: 30) { self.gone(id) }, "Jellyfin still lists the show")
    }
}

/// The real Seerr, Radarr and Sonarr beside the QA Jellyfin.
enum ArrQA {
    static let seerr = "http://127.0.0.1:8194"
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
#endif
