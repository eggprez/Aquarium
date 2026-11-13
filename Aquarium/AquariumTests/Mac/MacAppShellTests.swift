//  The Mac's app-level behaviour: `MacAppDelegate` (return-to-app refresh,
//  the Dock menu, the Dock reopen, the Dock badge) and what `AppModel` does
//  differently on a Mac (toasts become alerts or nothing, the Dock menu's
//  Continue Watching, the offline shell).

#if os(macOS)
import AppKit
import XCTest
@testable import Aquarium

@MainActor
final class MacAppShellTests: MacUnitTestCase {
    private var snapshot: AppModelSnapshot!
    private var app: AppModel { .shared }

    override func setUp() async throws {
        snapshot = AppModelSnapshot()
        app.pendingAlert = nil
        app.toasts = []
    }

    override func tearDown() async throws {
        snapshot.restore()
        // Home rewrites the Dock menu on its next load.
        app.clearDockMenu()
    }

    // MARK: Return to the app

    func testBecomingActiveSoonAfterLaunchDoesNotRefresh() {
        let delegate = MacAppDelegate()
        let before = MacCommandRequests.shared.refresh
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(MacCommandRequests.shared.refresh, before, "the launch's own activation doesn't count")
    }

    /// Regression guard: a Mac's `scenePhase` never leaves `.active`, so the
    /// return-to-app refresh comes from the delegate, at most once every five
    /// minutes, and only signed in. Source: Aquarium/MacAppDelegate.swift:16-30.
    func testReturnAfterFiveMinutesRefreshesOnceWhenSignedIn() {
        let delegate = MacAppDelegate()
        delegate.lastReturnRefresh = Date().addingTimeInterval(-6 * 60)
        let before = MacCommandRequests.shared.refresh
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        let expected = JellyfinClient.shared.isSignedIn ? before + 1 : before
        XCTAssertEqual(MacCommandRequests.shared.refresh, expected)
        // A second return a moment later is within the five minutes.
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(MacCommandRequests.shared.refresh, expected)
        XCTAssertLessThan(Date().timeIntervalSince(delegate.lastReturnRefresh), 5, "the clock restarts")
    }

    func testReturnUnderFiveMinutesDoesNothing() {
        let delegate = MacAppDelegate()
        delegate.lastReturnRefresh = Date().addingTimeInterval(-4 * 60)
        let before = MacCommandRequests.shared.refresh
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(MacCommandRequests.shared.refresh, before)
    }

    // MARK: The Dock menu

    func testDockMenuWithNothingToContinueIsJustSearch() {
        app.clearDockMenu()
        let menu = MacAppDelegate().applicationDockMenu(NSApp)
        XCTAssertEqual(menu?.items.map(\.title), ["Search"])
        XCTAssertNotNil(menu?.items.first?.action)
    }

    func testDockMenuListsContinueWatchingThenSearch() throws {
        let film = MacFixture.film("aaaa", name: "FX Long Direct Play")
        let ep = MacFixture.episode("bbbb", series: "FX Long Show", season: 1, number: 2, name: "Long Episode 1.2")
        app.updateDockMenu(resume: [film], nextUp: [ep])
        let menu = try XCTUnwrap(MacAppDelegate().applicationDockMenu(NSApp))
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, "Continue Watching")
        XCTAssertFalse(menu.items[0].isEnabled, "the heading is not a command")
        XCTAssertEqual(titles[1], "FX Long Direct Play")
        XCTAssertTrue(titles[2].hasPrefix("FX Long Show — "), titles[2])
        XCTAssertTrue(titles[2].contains("Long Episode 1.2"))
        XCTAssertEqual(menu.items[1].representedObject as? String, "aaaa")
        XCTAssertEqual(menu.items[1].indentationLevel, 1)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertEqual(titles.last, "Search")
    }

    func testDockMenuItemsDedupeAndStopAtFive() {
        let items = (0..<8).map { MacFixture.film("f\($0)", name: "Film \($0)") }
        app.updateDockMenu(resume: Array(items.prefix(3)), nextUp: Array(items.prefix(2)) + Array(items.suffix(5)))
        XCTAssertEqual(app.dockMenuItems.map(\.id), ["f0", "f1", "f2", "f3", "f4"])
    }

    func testDockMenuEpisodeTitleIsTheShowAndSubtitleTheEpisode() {
        let ep = MacFixture.episode("e1", series: "FX Short Show", season: 1, number: 3, name: "Short Episode 3")
        app.updateDockMenu(resume: [], nextUp: [ep])
        XCTAssertEqual(app.dockMenuItems.first?.title, "FX Short Show")
        XCTAssertEqual(app.dockMenuItems.first?.subtitle?.hasSuffix("Short Episode 3"), true)
        let film = MacFixture.film("f", name: "FX HEVC MP4")
        app.updateDockMenu(resume: [film], nextUp: [])
        XCTAssertNil(app.dockMenuItems.first?.subtitle, "a film has no subtitle")
    }

    func testClearDockMenu() {
        app.updateDockMenu(resume: [MacFixture.film("x")], nextUp: [])
        app.clearDockMenu()
        XCTAssertTrue(app.dockMenuItems.isEmpty)
    }

    // MARK: Reopen from the Dock

    /// Regression: DockClickIgnoredWithOtherWindowsOpen. AppKit only reopens
    /// an app with no windows showing, so with a title or the player still
    /// open a Dock click brought nothing back. Source: commit 9c6fb8c;
    /// Aquarium/MacAppDelegate.swift:40-50.
    func testBugDockClickIgnoredWithOtherWindowsOpen() throws {
        guard MacMainWindow.window != nil else {
            throw XCTSkip("the host has no main window open to test the reopen against")
        }
        // With the main window there, AppKit's own handling is kept.
        XCTAssertTrue(MacAppDelegate().applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertTrue(MacAppDelegate().applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    }

    // MARK: The Dock badge

    /// Regression: DockBadgeStaleAfterCloseOrSignOut. The badge is the count
    /// of transfers still to finish, kept by the app delegate rather than the
    /// sidebar, so it is right with the main window closed or signed out.
    /// Source: commit a016c37; Aquarium/MacAppDelegate.swift:93-107.
    func testBugDockBadgeMatchesTransfersToFinish() {
        let count = DownloadManager.shared.transfersToFinish
        XCTAssertEqual(NSApp.dockTile.badgeLabel, count > 0 ? "\(count)" : nil)
    }

    // MARK: Toasts and alerts on a Mac

    func testErrorToastBecomesAnAlert() {
        app.toast("The download couldn't start", tone: .error)
        XCTAssertTrue(app.toasts.isEmpty, "a Mac shows an error as an alert, not a toast")
        XCTAssertEqual(app.pendingAlert?.title, "Download Problem")
        XCTAssertEqual(app.pendingAlert?.message, "The download couldn't start")
    }

    func testAlertTitles() {
        let cases: [(String, String)] = [
            ("Your session expired, sign in again", "Session Expired"),
            ("FX was signed out on another device", "Account Signed Out"),
            ("Couldn't add to favorites", "Couldn’t Update"),
            ("Couldn't mark as watched", "Couldn’t Update"),
            ("Nothing to play here", "Nothing to Play"),
            ("The server answered 500", "Something Went Wrong"),
        ]
        for (text, title) in cases {
            app.pendingAlert = nil
            app.toast(text, tone: .error)
            XCTAssertEqual(app.pendingAlert?.title, title, text)
        }
    }

    func testFooterMessagesAreNotSaid() {
        for text in ["The server can't be reached", "The server can’t be reached", "Back online",
                     "Switched to suite-mac", "Signed suite-mac out"] {
            app.toast(text, tone: .error)
            app.toast(text)
            XCTAssertNil(app.pendingAlert, text)
            XCTAssertTrue(app.toasts.isEmpty, text)
        }
    }

    func testSignOutFailureIsStillSaid() {
        app.toast("Signed out locally, but the server could not be told", tone: .error)
        XCTAssertNotNil(app.pendingAlert)
    }

    func testInfoToastStaysAToast() {
        app.toast("Added to the download queue")
        XCTAssertEqual(app.toasts.map(\.text), ["Added to the download queue"])
        XCTAssertNil(app.pendingAlert)
    }

    func testPresentAlertOnAMacIsAnAlert() {
        app.presentAlert(title: "Couldn't Mark as Watched", message: "1 of 2 items couldn't be updated.")
        XCTAssertEqual(app.pendingAlert?.title, "Couldn't Mark as Watched")
        XCTAssertTrue(app.toasts.isEmpty)
    }

    func testASecondAlertReplacesTheFirst() {
        app.presentAlert(title: "One", message: "1")
        app.presentAlert(title: "Two", message: "2")
        XCTAssertEqual(app.pendingAlert?.title, "Two")
    }

    // MARK: About

    func testAboutPanelHasAVersionAndAnEngine() {
        XCTAssertFalse(Bundle.appVersion.isEmpty)
        XCTAssertFalse(Bundle.appBuild.isEmpty)
        XCTAssertFalse(PlayerModel.shared.engineDescription.isEmpty)
    }
}
#endif
