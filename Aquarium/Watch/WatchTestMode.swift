//  UI test mode for the watch app.
//
//  The watch has no sign-in screen of its own: the phone hands it one. In a
//  debug build launched with `-AquariumUITest YES` it can sign itself in
//  instead, from AQUARIUM_TEST_SERVER / _USER / _PASSWORD, keep its state
//  apart (a defaults suite of its own, tokens out of the keychain, its own
//  Application Support folder) and start from nothing with
//  `-AquariumTestReset YES`. Names: Shared/TestIDs/TestLaunch.swift.
//  In any other launch, and in a release build, nothing here runs.

import Foundation
import os

enum WatchTestMode {
    static let log = Logger(subsystem: "scottai.FellyJin.watchkitapp", category: "uitest")

    /// First thing in the app's init — see `AquariumWatchApp.testMode`.
    static func prepare() {
        #if DEBUG
        guard TestRuntime.isUITest else { return }
        let reset = TestLaunch.bool(TestLaunch.reset) == true
        if reset { TestDefaults.removeFolders() }
        TestDefaults.redirect(reset: reset)
        log.notice("UI test mode\(reset ? ", started clean" : "", privacy: .public)")
        if let server = TestLaunch.env(TestLaunch.serverEnv),
           let user = TestLaunch.env(TestLaunch.userEnv),
           let password = ProcessInfo.processInfo.environment[TestLaunch.passwordEnv] {
            Task { @MainActor in await signIn(server: server, user: user, password: password) }
        }
        #endif
    }

    #if DEBUG
    private struct Auth: Decodable {
        struct User: Decodable { let Id: String; let Name: String? }
        let AccessToken: String?
        let ServerId: String?
        let User: User?
    }

    /// What the phone would have sent, got from the server directly, and
    /// installed the way the phone's would be.
    @MainActor
    private static func signIn(server: String, user: String, password: String) async {
        let client = JellyfinClient.shared
        let address = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let account = client.account, account.server == address,
           account.userName.caseInsensitiveCompare(user) == .orderedSame {
            log.notice("UI test mode: already signed in as \(user, privacy: .public)")
            return
        }
        guard let url = URL(string: address + "/Users/AuthenticateByName") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.authHeaders()["Authorization"], forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": user, "Pw": password])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let auth = try JSONDecoder().decode(Auth.self, from: data)
            guard let token = auth.AccessToken, let id = auth.User?.Id else {
                log.error("UI test mode: the server gave no session")
                return
            }
            client.install(WatchCredentials(
                server: address, userId: id, userName: auth.User?.Name ?? user,
                serverId: auth.ServerId, token: token
            ))
            log.notice("UI test mode: signed in as \(user, privacy: .public) at \(address, privacy: .public)")
        } catch {
            log.error("UI test mode: sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
