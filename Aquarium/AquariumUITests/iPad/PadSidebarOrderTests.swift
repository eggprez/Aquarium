//  Settings › Appearance › Sidebar on an iPad: the order of the sidebar's
//  sections, changed by dragging a row by its handle. An iPad's sidebar
//  follows along while the page is open (TabBarSettingsView: "An iPad's
//  sidebar follows along live"), within its groups (PadSidebarGroup), and
//  Reset puts the default order back.
//
//  On its side, so the sidebar stands beside Settings and both can be read.
//  The order is the app's own test setting, which a clean launch starts
//  without.

#if os(iOS)
import XCTest

final class PadSidebarOrderTests: PadUITestCase {
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    private func openSidebarOrderPage() {
        launchHome()
        turn(.landscapeLeft)
        app.button(TestID.Sidebar.settings).padTap()
        app.element(TestID.Settings.root).waitToExist(20)
        let appearance = app.element(TestID.Settings.pageLink("appearance"))
        appearance.padTap()
        app.element(TestID.Settings.pageRoot("appearance")).waitToExist(15)
        let row = app.button(TestID.Settings.tabBar)
        XCTAssertTrue(reveal(row), "the Sidebar row")
        XCTAssertTrue(text(row).contains("Sidebar"), text(row))
        XCTAssertTrue(text(row).contains("Default"), "nothing changed yet: \(text(row))")
        row.padTap()
        app.element(TestID.TabBarSettings.root).waitToExist(15)
    }

    /// The section rows of the order page, top to bottom, by section id.
    private func orderRows() -> [String] {
        keysInOrder(prefix: "tabBarSettings.row.").filter { $0 != "home" }
    }

    func testDraggingARowReordersTheSidebarAndResetPutsItBack() throws {
        openSidebarOrderPage()
        XCTAssertTrue(app.element(TestID.TabBarSettings.home).exists, "Home is fixed at the top")
        XCTAssertFalse(app.button(TestID.TabBarSettings.reset).exists, "no Reset before anything is moved")
        let before = orderRows()
        try XCTSkipUnless(before.first == "music" && before.contains("books"),
                          "the order starts with Music, then Audiobooks, on this server: \(before)")
        let sidebarBefore = sidebarRowIds()
        let musicAt = { (ids: [String]) in ids.firstIndex(of: "music") ?? -1 }
        let booksAt = { (ids: [String]) in ids.firstIndex(of: "books") ?? -1 }
        XCTAssertLessThan(musicAt(sidebarBefore), booksAt(sidebarBefore), "Music above Audiobooks to begin with: \(sidebarBefore)")

        // Music's handle, dragged below the last row.
        let first = app.cells.containing(.any, identifier: TestID.TabBarSettings.row("music")).firstMatch
        let last = app.cells.containing(.any, identifier: TestID.TabBarSettings.row(before.last ?? "")).firstMatch
        let handle = first.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "a reorder handle on each row")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: handle.frame.midX - last.frame.midX, dy: last.frame.height * 0.6))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)

        XCTAssertTrue(waitUntil(10, "Music last on the page") { [self] in orderRows().last == "music" }, "rows: \(orderRows())")
        // The sidebar, beside the page, follows at once; Music keeps to its
        // group (Libraries), now after Audiobooks and every library.
        XCTAssertTrue(waitUntil(10, "the sidebar to follow") { [self] in
            let ids = sidebarRowIds()
            return musicAt(ids) > booksAt(ids)
        }, "sidebar: \(sidebarRowIds())")
        let after = sidebarRowIds()
        for library in after where library.hasPrefix("lib-") {
            XCTAssertLessThan(after.firstIndex(of: library) ?? 0, musicAt(after), "\(library) above Music now")
        }
        XCTAssertLessThan(musicAt(after), after.firstIndex(of: "livetv") ?? Int.max, "Music stays among the libraries, above Live TV")
        attachScreenshot("music moved last")

        let reset = app.button(TestID.TabBarSettings.reset)
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "Reset once the order is your own")
        reset.padTap()
        XCTAssertTrue(waitUntil(10, "the default order back") { [self] in orderRows() == before }, "rows: \(orderRows())")
        XCTAssertTrue(waitUntil(10, "the sidebar back") { [self] in sidebarRowIds() == sidebarBefore }, "sidebar: \(sidebarRowIds())")
        XCTAssertTrue(reset.waitToVanish(10), "Reset goes once there is nothing to reset")
    }

    /// The changed order is kept: Appearance's row says Custom, and after a
    /// relaunch the sidebar is still in it.
    func testAChangedOrderIsKept() throws {
        openSidebarOrderPage()
        let before = orderRows()
        try XCTSkipUnless(before.first == "music", "the order starts with Music on this server: \(before)")
        let first = app.cells.containing(.any, identifier: TestID.TabBarSettings.row("music")).firstMatch
        let last = app.cells.containing(.any, identifier: TestID.TabBarSettings.row(before.last ?? "")).firstMatch
        let handle = first.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.6,
            thenDragTo: last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: handle.frame.midX - last.frame.midX, dy: last.frame.height * 0.6)),
            withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitUntil(10, "Music last") { [self] in orderRows().last == "music" })
        goBack()
        let row = app.button(TestID.Settings.tabBar)
        XCTAssertTrue(waitUntil(10, "the row to say Custom") { [self] in text(row).contains("Custom") }, text(row))
        let moved = sidebarRowIds()

        app.terminate()
        launch(reset: false)
        app.element(TestID.Home.root).waitToExist(60)
        turn(.landscapeLeft)
        revealSidebar()
        app.button(TestID.Sidebar.row("music")).waitToExist(20)
        XCTAssertTrue(waitUntil(15, "the sidebar in the order chosen") { [self] in sidebarRowIds() == moved },
                      "after a relaunch: \(sidebarRowIds()), before: \(moved)")
    }
}
#endif
