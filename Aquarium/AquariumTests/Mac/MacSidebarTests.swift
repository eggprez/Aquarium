//  The Mac sidebar: its groups and their order (which ⌘1…⌘9 follow), the
//  row menus, the re-click rule, the Downloads badge, and the sections and
//  symbols a Mac shows.

#if os(macOS)
import XCTest
@testable import Aquarium

@MainActor
final class MacSidebarTests: MacUnitTestCase {
    private let films = MacFixture.library("f", name: "Films", type: "movies")
    private let shows = MacFixture.library("s", name: "Shows", type: "tvshows")
    private let home = MacFixture.library("h", name: "Home Videos", type: "homevideos")

    // MARK: Groups

    func testGroupsAreTopLibrariesLiveYou() {
        let groups = MacSidebarGroup.grouped([.home, films, .favorites, .liveTV, shows, .downloads, .collections])
        XCTAssertEqual(groups.map(\.title), [nil, "Libraries", "Live", "You"])
        XCTAssertEqual(groups[0].sections, [.home])
        XCTAssertEqual(groups[1].sections, [films, shows, .collections])
        XCTAssertEqual(groups[2].sections, [.liveTV])
        XCTAssertEqual(groups[3].sections, [.favorites, .downloads])
    }

    func testEmptyGroupsAreDropped() {
        let groups = MacSidebarGroup.grouped([.home, films])
        XCTAssertEqual(groups.map(\.title), [nil, "Libraries"])
    }

    func testSettingsAndMoreNeverGetARow() {
        let groups = MacSidebarGroup.grouped([.home, .settings, .more, films])
        XCTAssertFalse(groups.flatMap(\.sections).contains(.settings))
        XCTAssertFalse(groups.flatMap(\.sections).contains(.more))
    }

    func testGroupIdsAreStableAndUnique() {
        let ids = MacSidebarGroup.grouped([.home, films, .liveTV, .downloads]).map(\.id)
        XCTAssertEqual(ids, ["top", "Libraries", "Live", "You"])
    }

    /// Regression: CmdNumberOutOfSidebarOrder. ⌘1…⌘9 followed
    /// `app.sections`, which an iPhone's synced tab order can shuffle: with
    /// Live TV first there, ⌘2 opened Live TV while the sidebar's second row
    /// was a library. Source: commit 9c6fb8c; Views/MacCommands.swift:112-116.
    func testBugCmdNumberOutOfSidebarOrder() {
        let shuffled: [AppSection] = [.home, .liveTV, .downloads, films, .favorites, shows]
        let order = MacCommands.sidebarOrder(shuffled)
        XCTAssertEqual(order, [.home, films, shows, .liveTV, .downloads, .favorites],
                       "grouped under their headings; within a group, the sections' own order")
        XCTAssertEqual(order[1], films, "⌘2 is the second row the sidebar draws")
    }

    func testSidebarOrderLeavesSearchOut() {
        XCTAssertFalse(MacCommands.sidebarOrder([.home, .search, films]).contains(.search),
                       "Search is the field above the rows, never a numbered row")
    }

    // MARK: Row menus

    func testOpenInNewWindowOnlyForLibrariesFavoritesCollections() {
        XCTAssertEqual(MacSidebarRows.windowRoute(for: films), .library(id: "f", name: "Films", collectionType: "movies"))
        XCTAssertEqual(MacSidebarRows.windowRoute(for: .favorites), .section(.favorites))
        XCTAssertEqual(MacSidebarRows.windowRoute(for: .libraries), .section(.libraries))
        XCTAssertEqual(MacSidebarRows.windowRoute(for: .collections), .section(.collections))
        for none: AppSection in [.home, .liveTV, .downloads, .search] {
            XCTAssertNil(MacSidebarRows.windowRoute(for: none), "\(none.id) has no window of its own")
        }
    }

    // MARK: Re-click

    func testClickThatMovedTheSelectionIsNotAReclick() {
        let now = Date()
        XCTAssertTrue(MacSidebarRows.endsSelectingClick(awaitsTap: true, changedAt: now.addingTimeInterval(-0.1), now: now))
    }

    /// Regression: SidebarSlowClickResetsSection. A click held longer than
    /// 0.4 s on a row it was selecting counted as a re-click and threw away
    /// the pages it had come back for. Source: commit 6704c21 (first 9c6fb8c);
    /// Views/MacSidebar.swift:56-61.
    func testBugSidebarSlowClickResetsSection() {
        let now = Date()
        XCTAssertTrue(MacSidebarRows.endsSelectingClick(awaitsTap: true, changedAt: now.addingTimeInterval(-1.5), now: now),
                      "an unhurried 1.5 s press still ends the click that selected the row")
    }

    func testTapLongAfterAnArrowKeyMoveIsAReclick() {
        let now = Date()
        XCTAssertFalse(MacSidebarRows.endsSelectingClick(awaitsTap: true, changedAt: now.addingTimeInterval(-30), now: now))
    }

    func testSecondTapOnSelectedRowIsAReclick() {
        XCTAssertFalse(MacSidebarRows.endsSelectingClick(awaitsTap: false, changedAt: Date(), now: Date()))
    }

    // MARK: Badge

    func testDownloadsBadgeIsTheTransferCount() {
        XCTAssertEqual(MacSidebarRows.badge(for: .downloads, transfersToFinish: 3), 3)
        XCTAssertEqual(MacSidebarRows.badge(for: .downloads, transfersToFinish: 0), 0)
        XCTAssertEqual(MacSidebarRows.badge(for: .home, transfersToFinish: 3), 0)
        XCTAssertEqual(MacSidebarRows.badge(for: films, transfersToFinish: 3), 0)
    }

    // MARK: Section symbols on the Mac

    func testMacSymbols() {
        XCTAssertEqual(AppSection.books.symbol, "headphones")
        XCTAssertEqual(AppSection.libraries.symbol, "rectangle.stack")
        XCTAssertEqual(AppSection.liveTV.symbol, "play.tv")
        XCTAssertEqual(home.symbol, "video")
        XCTAssertEqual(MacFixture.library("m", name: "MV", type: "musicvideos").symbol, "music.note.tv")
        XCTAssertEqual(films.symbol, "film")
        XCTAssertEqual(shows.symbol, "tv")
        XCTAssertEqual(MacFixture.library("x", name: "X", type: nil).symbol, "folder")
    }

    func testSectionIdsMatchTheTestIDCatalogue() {
        XCTAssertEqual(TestID.Sidebar.row(films.id), "sidebar.row.lib-f")
        XCTAssertEqual(TestID.MacMenu.section(AppSection.liveTV.id), "macMenu.view.section.livetv")
    }

    // MARK: Sections

    func testMacSidebarHasNoSettingsOrSearchRow() {
        let sections = AppModel.shared.sections
        XCTAssertFalse(sections.contains(.settings), "a Mac keeps Settings in its own window")
        XCTAssertFalse(sections.contains(.search), "a Mac's search is the sidebar field")
        XCTAssertFalse(sections.contains(.more))
        XCTAssertFalse(sections.contains(.music), "no Music section on the Mac yet")
        XCTAssertFalse(sections.contains(.books))
    }
}
#endif
