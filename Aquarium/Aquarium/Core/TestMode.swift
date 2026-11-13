//  UI test mode for the iPhone, iPad, Mac and Apple TV app.
//
//  A debug build launched with `-AquariumUITest YES` keeps its state apart
//  from the real app's, can start from nothing, and signs itself in without
//  the sign-in screen. The names of the switches, and what is kept apart, are
//  in Shared/TestIDs/TestLaunch.swift; the UI tests' launcher is
//  AquariumUITests/Shared/TestApp.swift; Aquarium/TESTING.md has the lot.
//
//  `prepare` runs first thing in the app's init, before any singleton has
//  read a preference. In any other launch, and in a release build, it does
//  nothing.

import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

enum TestMode {
    static let log = Logger(subsystem: "scottai.FellyJin", category: "uitest")

    /// Called once, from `AquariumApp`'s first stored property, so it runs
    /// before the `@State` properties that create the app's singletons.
    static func prepare() {
        #if DEBUG
        guard TestRuntime.isUITest else { return }
        let reset = TestLaunch.bool(TestLaunch.reset) == true
        if reset { TestDefaults.removeFolders() }
        TestDefaults.redirect(reset: reset)
        log.notice("UI test mode\(reset ? ", started clean" : "", privacy: .public)")

        if let raw = TestLaunch.argument(TestLaunch.engine),
           let engine = EnginePolicy.Preference(rawValue: raw) {
            UserDefaults.standard.set(engine.rawValue, forKey: "player_engine")
        }

        #if os(iOS) || os(tvOS)
        if TestLaunch.bool(TestLaunch.animations) == false {
            UIView.setAnimationsEnabled(false)
        }
        #endif

        if let server = TestLaunch.env(TestLaunch.serverEnv),
           let user = TestLaunch.env(TestLaunch.userEnv),
           let password = ProcessInfo.processInfo.environment[TestLaunch.passwordEnv] {
            Task { @MainActor in
                await signIn(server: server, user: user, password: password)
                openLaunchLink()
            }
        } else {
            Task { @MainActor in openLaunchLink() }
        }
        #endif
    }

    #if DEBUG
    /// `TestLaunch.linkEnv`: the link a test asked to open, handed to the app
    /// the way a Top Shelf cell's link is, once signed in.
    @MainActor
    private static func openLaunchLink() {
        guard let raw = TestLaunch.env(TestLaunch.linkEnv), let url = URL(string: raw) else { return }
        log.notice("UI test mode: opening \(raw, privacy: .public)")
        AppModel.shared.handle(url, fromApp: true)
    }
    #endif

    #if DEBUG
    /// The sign-in the sign-in screen would have made, with the same call.
    /// Not again when that user is already the one signed in.
    @MainActor
    private static func signIn(server: String, user: String, password: String) async {
        let client = JellyfinClient.shared
        let address = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let s = client.session, s.server == address,
           s.userName.caseInsensitiveCompare(user) == .orderedSame,
           Keychain.token(server: s.server, userId: s.userId) != nil {
            log.notice("UI test mode: already signed in as \(user, privacy: .public)")
            return
        }
        let replacing = client.session != nil
        do {
            _ = try await client.login(server: address, username: user, password: password)
            if replacing { AppModel.shared.accountChanged() }
            log.notice("UI test mode: signed in as \(user, privacy: .public) at \(address, privacy: .public)")
        } catch {
            log.error("UI test mode: sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
