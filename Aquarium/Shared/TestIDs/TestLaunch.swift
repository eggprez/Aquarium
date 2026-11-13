//  How a UI test launches the app, and what the app does differently then.
//
//  Compiled into the apps (iPhone, iPad, Mac, Apple TV, Watch) and into the
//  UI-test bundles, so the launcher and the app agree on every name.
//
//  Test mode exists only in a DEBUG build, and only when the launch says so
//  (`-AquariumUITest YES`, or `AQUARIUM_UITEST=1` in the environment). In any
//  other launch, and in every release build, nothing here changes anything:
//  `TestRuntime.isUITest` is false and every helper below returns what the
//  app would have used anyway.
//
//  In test mode the app keeps its own state apart from the real one, which
//  matters on the Mac, where the debug build shares a container with the
//  copy the developer actually uses:
//
//  - `UserDefaults.standard` is redirected to the suite `TestLaunch.defaultsSuite`
//    (preferences, saved sessions, the device id: a test run is its own device
//    on the server).
//  - Tokens are kept in that suite instead of the keychain (`TestKeychain`):
//    no simulator keychain, no iCloud Keychain, no entitlement needed.
//  - Application Support, Caches and Documents get an `AquariumUITest`
//    folder of their own (`AppDirectory`).
//  - iCloud key-value sync, Spotlight and background download sessions are
//    kept off the real ones (see Core/TestMode.swift).
//
//  Starting clean (`-AquariumTestReset YES`) only ever removes that suite and
//  those folders.

import Foundation

enum TestLaunch {
    /// The switch: launch argument `-AquariumUITest YES`.
    static let flag = "AquariumUITest"
    /// The same switch as an environment variable, "1".
    static let flagEnv = "AQUARIUM_UITEST"

    /// `-AquariumTestReset YES`: forget everything test mode kept last time
    /// (defaults suite, test tokens, test folders) before anything reads it.
    static let reset = "AquariumTestReset"

    /// Sign in at launch, without the sign-in screen. All three, or none.
    /// Environment variables, so a password never sits in a scheme or a
    /// launch argument list. Skipped when that user is already signed in
    /// (a relaunch within a test that did not reset).
    static let serverEnv = "AQUARIUM_TEST_SERVER"
    static let userEnv = "AQUARIUM_TEST_USER"
    static let passwordEnv = "AQUARIUM_TEST_PASSWORD"

    /// `-AquariumTestEngine automatic|apple|mpv`: the player engine
    /// preference, as Settings would set it (iPhone, iPad, Mac, Apple TV).
    /// The engine policy still has the last word where it pins one (iPad).
    static let engine = "AquariumTestEngine"

    /// `-AquariumTestAnimations NO`: UIKit animations off (iOS, tvOS). On by
    /// default even in test mode; the launcher turns them off.
    static let animations = "AquariumTestAnimations"

    /// Where test mode keeps its preferences.
    static let defaultsSuite = "scottai.FellyJin.uitest"
    /// The folder test mode keeps its files in, inside each of Application
    /// Support, Caches and Documents.
    static let folder = "AquariumUITest"

    /// The launch argument `-name value`, read straight from the process
    /// rather than from defaults, so it can be read before the defaults
    /// are redirected.
    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-" + name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func bool(_ name: String) -> Bool? {
        guard let raw = argument(name)?.lowercased() else { return nil }
        return ["yes", "true", "1"].contains(raw)
    }

    static func env(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
    }
}

enum TestRuntime {
    /// A debug build, launched by a UI test. Read once.
    static let isUITest: Bool = {
        #if DEBUG
        return TestLaunch.bool(TestLaunch.flag) == true || TestLaunch.env(TestLaunch.flagEnv) == "1"
        #else
        return false
        #endif
    }()
}

/// Where the app keeps its files: the system's folder, or in test mode a
/// folder of test mode's own inside it.
enum AppDirectory {
    static func url(_ directory: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
        #if DEBUG
        if TestRuntime.isUITest {
            let own = base.appendingPathComponent(TestLaunch.folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            return own
        }
        #endif
        return base
    }
}

#if DEBUG
import ObjectiveC

/// Test mode's preferences, and how the app is pointed at them.
enum TestDefaults {
    /// Kept alive for as long as the redirect stands.
    private static var suite: UserDefaults?

    /// Make `UserDefaults.standard` (and `@AppStorage`, which reads it) answer
    /// with the test suite for the rest of the process. Called once, first
    /// thing, in test mode only. With `reset`, the suite is emptied first.
    static func redirect(reset: Bool) {
        guard suite == nil, let defaults = UserDefaults(suiteName: TestLaunch.defaultsSuite) else { return }
        if reset { defaults.removePersistentDomain(forName: TestLaunch.defaultsSuite) }
        suite = defaults
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return }
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// The test folders, emptied. Only ever the `AquariumUITest` folders.
    static func removeFolders() {
        for directory: FileManager.SearchPathDirectory in [.applicationSupportDirectory, .cachesDirectory, .documentDirectory] {
            let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: base.appendingPathComponent(TestLaunch.folder, isDirectory: true))
        }
    }
}

/// Tokens in test mode: in the test suite, not the keychain.
enum TestKeychain {
    private static func key(_ account: String) -> String { "uitest_token.\(account)" }
    static func store(_ token: String, account: String) { UserDefaults.standard.set(token, forKey: key(account)) }
    static func token(account: String) -> String? { UserDefaults.standard.string(forKey: key(account)) }
    static func delete(account: String) { UserDefaults.standard.removeObject(forKey: key(account)) }
}
#endif
