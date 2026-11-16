//  The QA Jellyfin server, as the UI tests see it.
//
//  Nothing here is in the repo but names: the server's address comes from the
//  environment or fixtures.json, and passwords are read at run time from
//  suite-accounts.txt in the QA folder. A test run on a machine without that
//  folder skips (see `AquariumUITestCase`) instead of failing.
//
//  Environment (set in the test plan, or from the command line with the
//  `TEST_RUNNER_` prefix, e.g. `TEST_RUNNER_AQUARIUM_SUITE=ipad`):
//  - AQUARIUM_SUITE       which suite account to use: iphone, ipad, mac, tv,
//                          watch (the test plans set it). Account "suite-<suite>".
//  - AQUARIUM_QA_DIR       the QA folder. Default
//                          ~/Library/Application Support/AquariumQA (the host's
//                          home, also from inside a simulator).
//  - AQUARIUM_QA_SERVER    the server. Default: fixtures.json's server.url, then
//                          http://127.0.0.1:8196.
//  - AQUARIUM_FIXTURES     fixtures.json, if not the one in the QA folder.
//  - AQUARIUM_QA_USER / AQUARIUM_QA_PASSWORD   override the account outright.

import Foundation

enum QA {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The developer's home, also when this runs inside a simulator.
    static var hostHome: String {
        env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
    }

    static var folder: URL {
        if let dir = env["AQUARIUM_QA_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return URL(fileURLWithPath: hostHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/AquariumQA", isDirectory: true)
    }

    static var server: String {
        if let s = env["AQUARIUM_QA_SERVER"], !s.isEmpty { return s }
        return Fixtures.shared?.serverURL ?? "http://127.0.0.1:8196"
    }

    /// The suite this run belongs to, from the test plan.
    static var suite: String {
        if let s = env["AQUARIUM_SUITE"], !s.isEmpty { return s }
        #if os(tvOS)
        return "tv"
        #elseif os(macOS)
        return "mac"
        #elseif os(watchOS)
        return "watch"
        #else
        return "iphone"
        #endif
    }

    struct Account {
        let name: String
        let password: String
    }

    /// This suite's own account, so its watch state never touches another's.
    static func account() -> Account? {
        if let user = env["AQUARIUM_QA_USER"], let pw = env["AQUARIUM_QA_PASSWORD"] {
            return Account(name: user, password: pw)
        }
        return account(named: "suite-\(suite)")
    }

    /// Any account listed in suite-accounts.txt (suite-*, fx-*). `fx-guest`
    /// has no password.
    static func account(named name: String) -> Account? {
        guard let pw = passwords()[name] else { return nil }
        return Account(name: name, password: pw)
    }

    /// `name=password` lines; `#` starts a comment.
    static func passwords() -> [String: String] {
        let file = folder.appendingPathComponent("suite-accounts.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    /// Whether the server answers /health within a few seconds.
    static func isReachable(timeout: TimeInterval = 4) -> Bool {
        guard let url = URL(string: server + "/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { data, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            _ = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return ok
    }
}
