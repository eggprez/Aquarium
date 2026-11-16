//  Where the Mac's menu commands and windows send navigation: Go ▸ Back
//  (⌘[), Go ▸ Home and ⌘1…⌘9 (`showAtTop`), the guide's Earlier / Later / Now
//  gate, title windows (`ItemWindowNavigator`, `keyNavigator`,
//  `isWorkingWindow`), and window restoration's `Route` coding.

#if os(macOS)
import SwiftUI
import XCTest
@testable import Aquarium

@MainActor
final class MacNavigationTests: MacUnitTestCase {
    private var snapshot: AppModelSnapshot!
    private var app: AppModel { .shared }

    override func setUp() async throws {
        snapshot = AppModelSnapshot()
        app.keyNavigator = nil
        app.paths = [:]
        app.selection = .home
    }

    override func tearDown() async throws {
        snapshot.restore()
    }

    // MARK: Go ▸ Back

    func testBackIsDisabledAtTheTopOfASection() {
        XCTAssertFalse(MacCommands.canGoBack(app))
    }

    func testBackPopsOnePageOfTheShownSection() {
        app.push(.item("a"))
        app.push(.item("b"))
        XCTAssertTrue(MacCommands.canGoBack(app))
        MacCommands.goBack(app)
        XCTAssertEqual(app.path(for: .home).wrappedValue.count, 1)
        MacCommands.goBack(app)
        XCTAssertEqual(app.path(for: .home).wrappedValue.count, 0)
        XCTAssertFalse(MacCommands.canGoBack(app))
        MacCommands.goBack(app)   // nothing left: no crash, nothing changes
        XCTAssertEqual(app.path(for: .home).wrappedValue.count, 0)
    }

    func testBackInATitleWindowGoesBackThroughItsOwnPages() {
        let window = ItemWindowNavigator()
        window.push(.item("season"))
        app.push(.item("on-main"))      // before the window takes over
        app.keyNavigator = window
        XCTAssertTrue(MacCommands.canGoBack(app))
        MacCommands.goBack(app)
        XCTAssertTrue(window.path.isEmpty)
        XCTAssertEqual(app.path(for: .home).wrappedValue.count, 1, "the main window's stack is not touched")
        XCTAssertFalse(MacCommands.canGoBack(app), "a title window at its first page has no Back")
    }

    // MARK: Go ▸ Home, ⌘1…⌘9

    /// Regression: GoHomeDoesNothingFromPushedPage. Selecting the section
    /// already shown left the page pushed on it, so Go ▸ Home and ⌘1 from a
    /// season reached through Home did nothing. Source: commit 9c6fb8c;
    /// Views/MacCommands.swift:200-213, Core/AppModel.swift:995-999.
    func testBugGoHomeDoesNothingFromPushedPage() {
        app.push(.item("show"))
        app.push(.item("season"))
        app.showAtTop(.home)
        XCTAssertEqual(app.selection, .home)
        XCTAssertTrue(app.path(for: .home).wrappedValue.isEmpty)
    }

    func testShowAtTopKeepsOtherSectionsPages() {
        app.selection = .favorites
        app.push(.item("fav"))
        app.showAtTop(.home)
        XCTAssertEqual(app.selection, .home)
        XCTAssertEqual(app.path(for: .favorites).wrappedValue.count, 1)
    }

    func testPushingTheSamePageTwiceIsOnePage() {
        app.push(.item("a"))
        app.push(.item("a"))
        XCTAssertEqual(app.path(for: .home).wrappedValue.count, 1)
    }

    func testSearchStaysTheSelectionOnAMac() {
        app.show(.search)
        XCTAssertEqual(app.selection, .search)
        app.reconcileSelection()
        XCTAssertEqual(app.selection, .search, "Search has no row on a Mac but is a section all the same")
    }

    func testSidebarFieldReturnShowsSearch() {
        let before = app.sidebarSearchSubmitted
        app.showSearch("FX Long")
        XCTAssertEqual(app.selection, .search)
        XCTAssertEqual(app.sidebarSearchTerm, "FX Long")
        XCTAssertEqual(app.sidebarSearchSubmitted, before + 1)
        XCTAssertNotNil(app.sidebarSearchSubmittedAt)
    }

    // MARK: Go ▸ Earlier / Later / Now

    func testGuideCommandsOnlyWhileTheGuideIsInFront() throws {
        app.selection = .liveTV
        guard app.shownSelection == .liveTV else {
            throw XCTSkip("the host is in the offline shell, which has no Live TV")
        }
        XCTAssertTrue(MacCommands.isGuideShowing(app, inPlayer: nil))
        XCTAssertTrue(MacCommands.isGuideShowing(app, inPlayer: false))
    }

    /// Regression: CmdArrowSkipsInTextFieldsAndGuide. ⌘← / ⌘→ belong to the
    /// player while its window is in front, and to the guide only when the
    /// guide is: never both. Source: commit 9c6fb8c; Views/MacCommands.swift:215-226.
    func testBugGuideKeysYieldToThePlayerWindow() throws {
        app.selection = .liveTV
        guard app.shownSelection == .liveTV else { throw XCTSkip("offline shell") }
        XCTAssertFalse(MacCommands.isGuideShowing(app, inPlayer: true))
    }

    func testGuideCommandsOffWithAPageOverTheGuide() throws {
        app.selection = .liveTV
        guard app.shownSelection == .liveTV else { throw XCTSkip("offline shell") }
        app.push(.item("programme"))
        XCTAssertFalse(MacCommands.isGuideShowing(app, inPlayer: nil))
    }

    func testGuideCommandsOffWithATitleWindowInFront() throws {
        app.selection = .liveTV
        guard app.shownSelection == .liveTV else { throw XCTSkip("offline shell") }
        let window = ItemWindowNavigator()
        app.keyNavigator = window
        XCTAssertFalse(MacCommands.isGuideShowing(app, inPlayer: nil))
    }

    func testGuideCommandsOffElsewhere() {
        app.selection = .home
        XCTAssertFalse(MacCommands.isGuideShowing(app, inPlayer: nil))
    }

    // MARK: Title windows

    func testNavigatorPushAndBack() {
        let n = ItemWindowNavigator()
        n.push(.item("show"))
        n.push(.item("season"))
        XCTAssertEqual(n.routes, [.item("show"), .item("season")])
        n.goBack()
        XCTAssertEqual(n.routes, [.item("show")])
        XCTAssertEqual(n.path.count, 1)
        n.goBack()
        n.goBack()
        XCTAssertTrue(n.path.isEmpty)
        XCTAssertTrue(n.routes.isEmpty)
    }

    func testNavigatorNavigateGoesBackToAPageAlreadyBehind() {
        let n = ItemWindowNavigator()
        n.push(.item("show"))
        n.push(.item("season"))
        n.push(.item("episode"))
        n.navigate(to: .item("show"))
        XCTAssertEqual(n.routes, [.item("show")], "a link up to the show pops back to it rather than pushing a copy")
        XCTAssertEqual(n.path.count, 1)
    }

    func testNavigatorNavigateToTheTopPageDoesNothing() {
        let n = ItemWindowNavigator()
        n.push(.item("show"))
        n.navigate(to: .item("show"))
        XCTAssertEqual(n.routes, [.item("show")])
    }

    func testNavigatorNavigatePushesWhatIsNotBehind() {
        let n = ItemWindowNavigator()
        n.push(.item("episode"))
        n.navigate(to: .item("season"))
        XCTAssertEqual(n.routes, [.item("episode"), .item("season")])
    }

    func testNavigatorBackButtonBindingTrimsRoutes() {
        let n = ItemWindowNavigator()
        n.push(.item("a"))
        n.push(.item("b"))
        var shorter = n.path
        shorter.removeLast()
        n.pathBinding.wrappedValue = shorter
        XCTAssertEqual(n.routes, [.item("a")])
    }

    func testPushWithATitleWindowInFrontOpensInThatWindow() {
        let window = ItemWindowNavigator()
        app.keyNavigator = window
        app.push(.item("cast-member"))
        XCTAssertEqual(window.routes, [.item("cast-member")])
        XCTAssertTrue(app.path(for: .home).wrappedValue.isEmpty, "the main window behind stays where it was")
    }

    func testNavigateWithATitleWindowInFrontUsesThatWindow() {
        let window = ItemWindowNavigator()
        window.push(.item("show"))
        window.push(.item("season"))
        app.keyNavigator = window
        app.navigate(to: .item("show"))
        XCTAssertEqual(window.routes, [.item("show")])
    }

    /// Regression: AlertsToastsRefreshHitEveryWindow. Every window shares one
    /// model, so a toast, an alert and ⌘R happened in all of them at once.
    /// Only the window being worked in acts. Source: commit a016c37;
    /// Views/ItemWindow.swift:79-88.
    func testBugAlertsToastsRefreshHitEveryWindow() {
        let window = ItemWindowNavigator()
        let other = ItemWindowNavigator()
        XCTAssertTrue(app.isWorkingWindow(nil), "no title window in front: the main window is the one")
        XCTAssertFalse(app.isWorkingWindow(window))
        app.keyNavigator = window
        XCTAssertFalse(app.isWorkingWindow(nil), "the main window stands down")
        XCTAssertTrue(app.isWorkingWindow(window))
        XCTAssertFalse(app.isWorkingWindow(other))
    }

    // MARK: Window restoration

    func testRoutesSurviveEncodingForWindowRestoration() throws {
        let routes: [Route] = [
            .item("abc"),
            .library(id: "lib", name: "Films", collectionType: "movies"),
            .library(id: "lib2", name: "Mixed", collectionType: nil),
            .section(.favorites),
            .section(.library(id: "x", name: "Shows", collectionType: "tvshows")),
            .search("star wars"),
            .person(id: "p", name: "Ada Fixture"),
            .downloadedSeries("series-key"),
        ]
        for route in routes {
            let data = try JSONEncoder().encode(route)
            XCTAssertEqual(try JSONDecoder().decode(Route.self, from: data), route)
        }
    }

    // MARK: Requests the menus make

    func testCommandRequestsAreCounters() {
        let r = MacCommandRequests.shared
        let before = (r.focusSearch, r.refresh, r.guideEarlier, r.guideLater, r.guideNow)
        r.refresh += 1
        r.guideEarlier += 1
        r.guideLater += 1
        r.guideNow += 1
        r.focusSearch += 1
        XCTAssertEqual(r.refresh, before.1 + 1)
        XCTAssertEqual(r.guideEarlier, before.2 + 1)
        XCTAssertEqual(r.guideLater, before.3 + 1)
        XCTAssertEqual(r.guideNow, before.4 + 1)
        XCTAssertEqual(r.focusSearch, before.0 + 1)
    }

    func testItemMenuActionsCallThrough() {
        var calls: [String] = []
        let actions = ItemMenuActions(
            title: "FX Long Direct Play", canPlay: true, playLabel: "Resume", isFavorite: false, isWatched: nil,
            play: { calls.append("play") }, toggleFavorite: { calls.append("fav") },
            toggleWatched: { calls.append("watched") }, openInNewWindow: { calls.append("window") })
        actions.play(); actions.toggleFavorite(); actions.toggleWatched(); actions.openInNewWindow()
        XCTAssertEqual(calls, ["play", "fav", "watched", "window"])
        XCTAssertNil(actions.isWatched, "a series is marked a season at a time: Item ▸ Mark as Watched is disabled")
    }

    // MARK: The main window

    func testMainWindowIsFoundByItsSceneId() {
        XCTAssertEqual(MacMainWindow.id, "main")
        if let window = MacMainWindow.window {
            XCTAssertTrue(window.identifier?.rawValue.hasPrefix("main-") == true)
            XCTAssertTrue(window.isVisible || window.isMiniaturized)
        }
        XCTAssertEqual(PlayerWindow.id, "player")
        XCTAssertEqual(ItemWindow.id, "item")
        XCTAssertEqual(RouteWindow.id, "route")
    }
}
#endif
