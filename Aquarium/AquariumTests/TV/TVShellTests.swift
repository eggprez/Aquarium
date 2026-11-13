//  The television's shell, as `AppModel` keeps it: the tab strip's sections,
//  the title screen that opens over everything (`detailRoot`), and the
//  trailer door, which on a TV is the YouTube app or nothing.

#if os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class TVShellTests: TVUnitTestCase {
    private var app: AppModel { AppModel.shared }

    override func tearDown() async throws {
        app.closeDetail()
    }

    // MARK: The tab strip

    func testStripIsHomeLibrariesSearchLiveTVSettings() {
        let prefs = Preferences.shared
        let saved = prefs.liveTVSource
        defer { prefs.liveTVSource = saved }
        prefs.liveTVSource = .custom
        XCTAssertEqual(app.sections.map(\.id), ["home", "libraries", "search", "livetv", "settings"])
        XCTAssertFalse(app.sections.contains(.music), "no Music tab on a television")
        XCTAssertFalse(app.sections.contains(.downloads), "nothing can be downloaded to a television")
        XCTAssertFalse(app.sections.contains(.more))
    }

    func testNeverAnOfflineShell() {
        // Nothing is downloaded on a TV, so there is no smaller app to fall
        // back to: the tabs stay and say the server is offline.
        XCTAssertFalse(app.isOfflineShell)
        app.selection = .search
        XCTAssertEqual(app.shownSelection, .search)
        app.selection = .home
    }

    // MARK: The title screen

    func testATitleOpensAsItsOwnScreenNotUnderTheStrip() {
        app.closeDetail()
        app.push(.item("film"))
        XCTAssertEqual(app.detailRoot, .item("film"))
        XCTAssertTrue(app.detailRoutes.isEmpty)
        // What it opens goes on its own stack.
        app.push(.person(id: "p", name: "Ada"))
        app.push(.item("other"))
        XCTAssertEqual(app.detailRoot, .item("film"))
        XCTAssertEqual(app.detailRoutes, [.person(id: "p", name: "Ada"), .item("other")])
        XCTAssertEqual(app.detailPath.count, 2)
    }

    func testALibraryOpensTheSameWay_regressionBackQuitTheApp() {
        // Regression (AppModel.push): a library pushed into the tab's stack sat
        // under the strip, focus walked up onto it, and Menu quit Aquarium.
        app.closeDetail()
        app.push(.library(id: "lib", name: "Films", collectionType: "movies"))
        XCTAssertEqual(app.detailRoot, .library(id: "lib", name: "Films", collectionType: "movies"))
    }

    func testMenuPoppingThePathTrimsTheRoutes() {
        app.closeDetail()
        app.push(.item("show"))
        app.push(.item("season"))
        app.push(.item("episode"))
        var path = app.detailPath
        path.removeLast()
        app.detailPath = path
        XCTAssertEqual(app.detailRoutes, [.item("season")])
    }

    func testCloseDetailEmptiesEverything() {
        app.push(.item("a"))
        app.push(.item("b"))
        app.closeDetail()
        XCTAssertNil(app.detailRoot)
        XCTAssertTrue(app.detailRoutes.isEmpty)
        XCTAssertEqual(app.detailPath.count, 0)
        XCTAssertNil(app.pendingEpisodeHighlight)
    }

    func testNextUpOpensTheShowWithTheSeasonOnTopAndTheEpisodePicked() {
        app.closeDetail()
        app.openNextUp(seriesId: "series", seasonId: "season", episodeId: "episode")
        XCTAssertEqual(app.detailRoot, .item("series"))
        XCTAssertEqual(app.detailRoutes, [.item("season")])
        XCTAssertEqual(app.detailPath.count, 1)
        XCTAssertEqual(app.pendingEpisodeHighlight, AppModel.EpisodeHighlight(seasonId: "season", episodeId: "episode"))
    }

    // MARK: Trailers

    private func film(remote: [String], local: Int = 0) -> BaseItem {
        var item = BaseItem()
        item.Id = "f"
        item.type = "Movie"
        item.LocalTrailerCount = local
        item.RemoteTrailers = remote.map { MediaUrl(Url: $0) }
        return item
    }

    func testYouTubeIdsAreReadFromEveryShape() {
        XCTAssertEqual(Trailers.youTubeID(URL(string: "https://www.youtube.com/watch?v=abc123")!), "abc123")
        XCTAssertEqual(Trailers.youTubeID(URL(string: "https://youtu.be/xyz")!), "xyz")
        XCTAssertEqual(Trailers.youTubeID(URL(string: "https://m.youtube.com/watch?feature=x&v=q9")!), "q9")
        XCTAssertNil(Trailers.youTubeID(URL(string: "https://vimeo.com/123")!))
        XCTAssertNil(Trailers.youTubeID(URL(string: "https://youtu.be/")!))
    }

    func testOnlyWebAddressesCountAsRemoteTrailers() {
        XCTAssertNil(Trailers.remote(film(remote: ["javascript:alert(1)", "file:///etc/hosts"])))
        XCTAssertEqual(Trailers.remote(film(remote: ["nonsense", "https://youtu.be/a"]))?.absoluteString, "https://youtu.be/a")
    }

    func testALocalTrailerAlwaysShowsTheButton() {
        XCTAssertTrue(Trailers.has(film(remote: [], local: 2)))
        var episode = film(remote: [], local: 2)
        episode.type = "Episode"
        XCTAssertFalse(Trailers.has(episode), "films and shows only")
    }

    func testTheYouTubeSchemeIsDeclared() {
        // Source: master-fix-list.md "[TV] Trailer button is shown for YouTube
        // trailers that tvOS cannot open"; fix-status.md says it was fixed by
        // declaring `youtube` in LSApplicationQueriesSchemes and hiding the
        // button unless the YouTube app answers. That fix
        // (claude/qa-fix-list-cb0b58) is not on this branch.
        let schemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        XCTAssertTrue(schemes.contains("youtube"), "declared: \(schemes)")
    }

    func testAYouTubeOnlyTrailerIsHiddenWithoutTheYouTubeApp() {
        // Same source. The simulator has no YouTube app, so a film whose
        // only trailer is on YouTube should show no Trailer button here.
        XCTAssertFalse(Trailers.has(film(remote: ["https://www.youtube.com/watch?v=yUQM7H4Swgw"])))
    }
}
#endif
