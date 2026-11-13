//  The iPad shell's logic: how the sidebar groups the sections (Deep Water's
//  Browse / Libraries / Live / You, eff49a1), and how the selection follows
//  the shell when the window narrows to the phone's tab bar and widens again
//  (a98b494, "AppModel.usesSidebar follows the shell RootView actually lays
//  out (idiom and size class) instead of the idiom alone").

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class PadSidebarGroupTests: PadUnitTestCase {
    private let films = AppSection.library(id: "f", name: "Films", collectionType: "movies")
    private let shows = AppSection.library(id: "s", name: "Shows", collectionType: "tvshows")

    private var everything: [AppSection] {
        [.home, .music, .books, films, shows, .favorites, .collections, .liveTV, .downloads, .settings]
    }

    func testFourGroupsInOrder() {
        let groups = PadSidebarGroup.grouped(everything)
        XCTAssertEqual(groups.map(\.title), ["Browse", "Libraries", "Live", "You"])
    }

    func testBrowseHoldsHomeAndTheSearchRow() {
        let browse = PadSidebarGroup.grouped(everything)[0]
        XCTAssertEqual(browse.sections, [.home])
        XCTAssertTrue(browse.holdsSearch, "the Search row sits under Home")
    }

    func testLibrariesHoldMusicBooksEveryLibraryAndCollections() {
        let libraries = PadSidebarGroup.grouped(everything)[1]
        XCTAssertEqual(libraries.sections, [.music, .books, films, shows, .collections])
        XCTAssertFalse(libraries.holdsSearch)
    }

    func testLiveAndYou() {
        let groups = PadSidebarGroup.grouped(everything)
        XCTAssertEqual(groups[2].sections, [.liveTV])
        XCTAssertEqual(groups[3].sections, [.favorites, .downloads])
    }

    func testSettingsAndMoreAreNeverRows() {
        let all = PadSidebarGroup.grouped(everything + [.more]).flatMap(\.sections)
        XCTAssertFalse(all.contains(.settings), "Settings is the gear in the footer")
        XCTAssertFalse(all.contains(.more), "a sidebar has no More")
    }

    func testEmptyGroupsAreLeftOut() {
        // A server with no Live TV and nothing else: no "Live" eyebrow over nothing.
        let groups = PadSidebarGroup.grouped([.home, films, .favorites, .downloads, .settings])
        XCTAssertEqual(groups.map(\.title), ["Browse", "Libraries", "You"])
    }

    func testOfflineShellIsDownloadsAlone() {
        // Offline the sections are Downloads and Settings: one group, "You".
        let groups = PadSidebarGroup.grouped([.downloads, .settings])
        XCTAssertEqual(groups.map(\.title), ["You"])
        XCTAssertEqual(groups[0].sections, [.downloads])
    }

    func testGroupIdsAreTheirTitles() {
        XCTAssertEqual(PadSidebarGroup.grouped(everything).map(\.id), ["Browse", "Libraries", "Live", "You"])
    }
}

/// `AppModel.shellChanged(toSidebar:)` and `show(_:)`, driven on the shared
/// model the way RootView drives them when an iPad window crosses between
/// regular and compact width. Each test puts the model back as it found it.
@MainActor
final class PadShellSelectionTests: PadUnitTestCase {
    private var model: AppModel { AppModel.shared }
    private var savedSelection: AppSection = .home
    /// `setUp() async` runs before `PadUnitTestCase`'s skip, so it checks the
    /// idiom itself: on an iPhone host it must leave the shared model alone.
    private var onIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws {
        try await super.setUp()
        guard onIPad else { return }
        savedSelection = model.selection
        // The host app lays out a sidebar on an iPad at full width.
        model.shellChanged(toSidebar: true)
    }

    override func tearDown() async throws {
        if onIPad {
            model.shellChanged(toSidebar: true)
            model.selection = savedSelection
        }
        try await super.tearDown()
    }

    func testAnIPadAtFullWidthUsesTheSidebar() {
        XCTAssertTrue(model.usesSidebar)
    }

    func testShowSelectsASidebarSectionDirectly() {
        model.show(.favorites)
        XCTAssertEqual(model.selection, .favorites, "a sidebar has a row for Favorites; no trip through More")
    }

    /// Regression, a98b494 ("an iPad in Slide Over or a narrow split no
    /// longer selects sections its tab bar hasn't got"): narrowed to the tab
    /// bar, a section with no tab opens inside More.
    func testNarrowingToTheTabBarMovesASectionWithNoTabIntoMore() {
        model.selection = .favorites
        model.shellChanged(toSidebar: false)
        XCTAssertFalse(model.usesSidebar)
        XCTAssertFalse(model.tabSections.contains(.favorites), "Favorites is in More on the tab bar")
        XCTAssertEqual(model.selection, .more)
    }

    func testNarrowingKeepsASectionTheTabBarHas() {
        model.selection = .home
        model.shellChanged(toSidebar: false)
        XCTAssertEqual(model.selection, .home)
    }

    /// Widening again, More (which a sidebar has no row for) becomes what it
    /// had open — the window coming back from phone width lands where it was.
    func testWideningAgainBringsBackTheSectionMoreHadOpen() {
        model.selection = .favorites
        model.shellChanged(toSidebar: false)
        XCTAssertEqual(model.selection, .more)
        model.shellChanged(toSidebar: true)
        XCTAssertTrue(model.usesSidebar)
        XCTAssertEqual(model.selection, .favorites)
    }

    func testWideningFromMoreWithNothingOpenGoesHome() {
        model.shellChanged(toSidebar: false)
        model.selection = .more
        model.shellChanged(toSidebar: true)
        XCTAssertEqual(model.selection, .home)
    }

    func testRepeatingTheSameShellChangesNothing() {
        model.selection = .downloads
        model.shellChanged(toSidebar: true)
        XCTAssertEqual(model.selection, .downloads)
    }

    func testShowSearchOnAnIPadOpensItOverHome() {
        // Search is not a section on iOS; its sidebar row pushes it.
        model.show(.search)
        XCTAssertEqual(model.selection, .home)
        XCTAssertEqual(model.path(for: .home).wrappedValue.count, 1)
        model.path(for: .home).wrappedValue = .init()
    }

    func testSidebarListsSettingsLastAndNeverMore() {
        XCTAssertEqual(model.sections.first, .home)
        XCTAssertFalse(model.sections.contains(.more))
        if !model.isOfflineShell {
            XCTAssertEqual(model.sections.last, .settings)
        }
    }
}
#endif
