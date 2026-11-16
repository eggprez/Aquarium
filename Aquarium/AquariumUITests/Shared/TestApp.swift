//  Launching the app in test mode. See Shared/TestIDs/TestLaunch.swift for
//  what each switch does inside the app, and Aquarium/TESTING.md.
//
//      let app = TestApp.launch()                       // clean, signed in as this suite
//      let app = TestApp.launch(signIn: false)          // clean, at the sign-in screen
//      let app = TestApp.launch(reset: false)           // relaunch, keeping state
//      let app = TestApp.launch(engine: "mpv")          // force the player engine

import Foundation
import XCTest

enum TestApp {
    static func configure(_ app: XCUIApplication, reset: Bool = true, signIn: Bool = true,
                          account: QA.Account? = QA.account(), server: String = QA.server,
                          engine: String? = nil, animations: Bool = false,
                          arguments: [String] = [], environment: [String: String] = [:]) {
        app.launchArguments += ["-\(TestLaunch.flag)", "YES"]
        if reset { app.launchArguments += ["-\(TestLaunch.reset)", "YES"] }
        if !animations { app.launchArguments += ["-\(TestLaunch.animations)", "NO"] }
        if let engine { app.launchArguments += ["-\(TestLaunch.engine)", engine] }
        #if os(macOS)
        // No windows brought back from the last run.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launchArguments += arguments
        app.launchEnvironment[TestLaunch.flagEnv] = "1"
        if signIn, let account {
            app.launchEnvironment[TestLaunch.serverEnv] = server
            app.launchEnvironment[TestLaunch.userEnv] = account.name
            app.launchEnvironment[TestLaunch.passwordEnv] = account.password
        }
        for (k, v) in environment { app.launchEnvironment[k] = v }
    }

    @discardableResult
    static func launch(reset: Bool = true, signIn: Bool = true, account: QA.Account? = QA.account(),
                       engine: String? = nil, animations: Bool = false,
                       arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        configure(app, reset: reset, signIn: signIn, account: account, engine: engine,
                  animations: animations, arguments: arguments, environment: environment)
        app.launch()
        return app
    }
}
