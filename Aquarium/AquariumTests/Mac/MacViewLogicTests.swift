//  The logic inside the Mac's own views (`*+Mac.swift`, `MacStyles`):
//  Home's media bar, shelf paging, the episode list, the library page's
//  filters, no-results page and selection menu, and the guide's type-select
//  and day label.

#if os(macOS)
import XCTest
@testable import Aquarium

@MainActor
final class MacViewLogicTests: MacUnitTestCase {
    // MARK: Home's media bar (HeroCarousel)

    func testHeroIsA2point4To1BandHeldBetween280And520() {
        XCTAssertEqual(HeroCarousel.height(forWidth: 0), HeroHeader.height, "before the first layout pass")
        XCTAssertEqual(HeroHeader.height, 340)
        XCTAssertEqual(HeroCarousel.height(forWidth: 960), 400)
        XCTAssertEqual(HeroCarousel.height(forWidth: 500), 280, "never too short for a title and two buttons")
        XCTAssertEqual(HeroCarousel.height(forWidth: 3000), 520, "never pushes the first shelf off a laptop")
    }

    func testHeroTurnsWrapAtBothEnds() {
        XCTAssertEqual(HeroCarousel.turned(0, by: -1, count: 5), 4)
        XCTAssertEqual(HeroCarousel.turned(4, by: 1, count: 5), 0)
        XCTAssertEqual(HeroCarousel.turned(2, by: 1, count: 5), 3)
        XCTAssertEqual(HeroCarousel.turned(0, by: 0, count: 0), 0)
    }

    // MARK: Shelves

    func testShelfEndsOnAWholeCard() {
        let fit = ShelfLayout.fit(available: 1000, minimum: 150, spacing: 16)
        XCTAssertEqual(fit.count, 6)
        XCTAssertLessThanOrEqual(CGFloat(fit.count) * fit.width + 16 * CGFloat(fit.count - 1), 1000)
        XCTAssertGreaterThanOrEqual(fit.width, 150)
    }

    func testShelfNarrowerThanOneCard() {
        let fit = ShelfLayout.fit(available: 100, minimum: 150, spacing: 16)
        XCTAssertEqual(fit.count, 1)
        XCTAssertEqual(fit.width, 150)
    }

    func testShelfWidthsAreWholePoints() {
        let fit = ShelfLayout.fit(available: 1003, minimum: 150, spacing: 16)
        XCTAssertEqual(fit.width, fit.width.rounded(.down))
    }

    // MARK: A season's episodes (MacEpisodeList)

    /// Regression: ReturnOnEpisodesPlaysRandomOne. Return or a double-click
    /// on episodes 3 to 5 played `Set.first` — any one of them. The earliest
    /// in the season's order plays. Source: commit 9c6fb8c;
    /// Aquarium/Views/EpisodeList+Mac.swift:87-92.
    func testBugReturnOnEpisodesPlaysRandomOne() {
        let episodes = (1...8).map { MacFixture.episode("e\($0)", number: $0) }
        for _ in 0..<20 {   // a Set's order changes with its hash seed; any order must give e3
            let ids: Set<String> = Set(["e5", "e3", "e4"].shuffled())
            XCTAssertEqual(MacEpisodeList.episodeToPlay(ids, in: episodes)?.Id, "e3")
        }
        XCTAssertNil(MacEpisodeList.episodeToPlay([], in: episodes))
        XCTAssertNil(MacEpisodeList.episodeToPlay(["gone"], in: episodes))
    }

    /// Regression: EpisodeListClipsLastRow. Counted alone, rows the system
    /// drew taller cut the last episode off in a frame that can't scroll; the
    /// measured height is a floor, never less than the counted one.
    /// Source: commit 6704c21; Aquarium/Views/EpisodeList+Mac.swift:38-46.
    func testBugEpisodeListClipsLastRow() {
        XCTAssertEqual(MacEpisodeList.listHeight(episodeCount: 10, measured: nil), 10 * 64 + 16)
        XCTAssertEqual(MacEpisodeList.listHeight(episodeCount: 10, measured: 900), 900, "the list's own measure wins when taller")
        XCTAssertEqual(MacEpisodeList.listHeight(episodeCount: 10, measured: 100), 656, "and never shrinks it below the count")
        XCTAssertEqual(MacEpisodeList.listHeight(episodeCount: 0, measured: nil), 16)
    }

    func testEpisodeRowAnchors() {
        XCTAssertEqual(MacEpisodeList.anchor(for: "abc"), "episode-row-abc")
    }

    // MARK: Library filters remembered per library

    /// Regression: LibraryFiltersForgottenBetweenLibraries. One page is
    /// handed library after library; without per-library keys Films lost its
    /// sort and filters after a look at Shows. Source: comment at
    /// Aquarium/Views/LibraryView+Mac.swift:13-21.
    func testBugLibraryFiltersForgottenBetweenLibraries() {
        let films = "test-films-\(UUID().uuidString)", shows = "test-shows-\(UUID().uuidString)"
        defer { LibraryFilters().save(for: films); LibraryFilters().save(for: shows) }
        var f = LibraryFilters()
        f.sort = .rating
        f.unwatchedOnly = true
        f.genre = "Test Pattern"
        f.save(for: films)
        var s = LibraryFilters()
        s.reversed = true
        s.favouritesOnly = true
        s.save(for: shows)
        XCTAssertEqual(LibraryFilters.load(for: films), f)
        XCTAssertEqual(LibraryFilters.load(for: shows), s)
    }

    func testDefaultFiltersLeaveNothingBehind() {
        let id = "test-lib-\(UUID().uuidString)"
        var f = LibraryFilters()
        f.sort = .dateAdded
        f.save(for: id)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "libraryFilters.\(id)"))
        LibraryFilters().save(for: id)
        XCTAssertNil(UserDefaults.standard.data(forKey: "libraryFilters.\(id)"), "a library put back the way it started has no record")
        XCTAssertEqual(LibraryFilters.load(for: id), LibraryFilters())
    }

    func testCorruptFiltersLoadAsDefaults() {
        let id = "test-lib-\(UUID().uuidString)"
        UserDefaults.standard.set(Data("not json".utf8), forKey: "libraryFilters.\(id)")
        defer { UserDefaults.standard.removeObject(forKey: "libraryFilters.\(id)") }
        XCTAssertEqual(LibraryFilters.load(for: id), LibraryFilters())
    }

    // MARK: Nothing matched

    /// Regression: EmptyLibraryBlamesFilters. The empty page blamed filters
    /// that weren't on. Source: commit b723cea;
    /// Aquarium/Views/LibraryView+Mac.swift:164-196.
    func testBugEmptyLibraryBlamesFilters() {
        XCTAssertEqual(LibraryNoResults.clearLabel(hasFilters: false), "Clear Search")
        XCTAssertEqual(LibraryNoResults.description(searchTerm: "zzz", hasFilters: false),
                       "Check the spelling or try a different search.")
        XCTAssertFalse(LibraryNoResults.description(searchTerm: "zzz", hasFilters: false).contains("filter"))
    }

    func testNoResultsWording() {
        XCTAssertEqual(LibraryNoResults.title(searchTerm: ""), "No Results")
        XCTAssertEqual(LibraryNoResults.title(searchTerm: "FX"), "No Results for “FX”")
        XCTAssertEqual(LibraryNoResults.clearLabel(hasFilters: true), "Clear Filters")
        XCTAssertEqual(LibraryNoResults.description(searchTerm: "FX", hasFilters: true),
                       "Nothing in this library matches the search and the filters.")
        XCTAssertEqual(LibraryNoResults.description(searchTerm: "", hasFilters: true),
                       "Nothing in this library matches the filters.")
    }

    // MARK: Acting on a selection

    func testSelectionMenuOffersOnlyWhatChangesSomething() {
        let watchedFav = MacFixture.film("a", played: true, favorite: true)
        let fresh = MacFixture.film("b")
        XCTAssertEqual(LibrarySelectionMenu.offers(for: [watchedFav]),
                       .init(markWatched: false, markUnwatched: true, addFavorite: false, removeFavorite: true))
        XCTAssertEqual(LibrarySelectionMenu.offers(for: [fresh]),
                       .init(markWatched: true, markUnwatched: false, addFavorite: true, removeFavorite: false))
        XCTAssertEqual(LibrarySelectionMenu.offers(for: [watchedFav, fresh]),
                       .init(markWatched: true, markUnwatched: true, addFavorite: true, removeFavorite: true),
                       "a mixed selection is offered both ways")
        XCTAssertEqual(LibrarySelectionMenu.offers(for: []),
                       .init(markWatched: false, markUnwatched: false, addFavorite: false, removeFavorite: false))
    }

    // MARK: Library paging

    /// Regression: LibraryPagingStopsShort. Sorts where many items share a
    /// value let the server order ties differently per page ("62 of 92").
    /// Source: commit dbd3662; Aquarium/Views/LibraryView.swift:166-177.
    func testBugLibraryPagingStopsShort() {
        for sort in LibraryView.SortOption.allCases {
            switch sort {
            case .name, .random:
                XCTAssertFalse(sort.tiebroken.contains("SortName,SortName"))
            default:
                XCTAssertTrue(sort.tiebroken.hasSuffix(",SortName"), sort.rawValue)
            }
        }
    }

    // MARK: The guide (TVGuide+Mac)

    func testTypeSelectJoinsQuickKeystrokes() {
        let t = GuideTypeSelect()
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.append("B"), "b")
        XCTAssertEqual(t.append("B"), "bb")
        XCTAssertEqual(t.append("c"), "bbc")
        XCTAssertFalse(t.isEmpty)
        t.reset()
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.append("q"), "q")
    }

    func testTypeSelectStartsOverAfterAPause() async throws {
        let t = GuideTypeSelect()
        _ = t.append("q")
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.append("x"), "x")
    }

    func testTypeSelectMatchesPrefixThenNumberThenContains() {
        let channels = [
            MacFixture.channel("1", name: "QA Channel 1", number: "1"),
            MacFixture.channel("2", name: "UK: BBC One", number: "101"),
            MacFixture.channel("3", name: "News | World", number: "7"),
        ]
        XCTAssertEqual(GuideTypeSelect.match("qa", in: channels), 0)
        XCTAssertEqual(GuideTypeSelect.match("bbc", in: channels), 1, "the line-up's prefix is skipped")
        XCTAssertEqual(GuideTypeSelect.match("world", in: channels), 2)
        XCTAssertEqual(GuideTypeSelect.match("10", in: channels), 1, "by channel number")
        XCTAssertEqual(GuideTypeSelect.match("one", in: channels), 1, "contained, as a last resort")
        XCTAssertNil(GuideTypeSelect.match("zzz", in: channels))
        XCTAssertNil(GuideTypeSelect.match("", in: channels))
    }

    func testGuideDayLabel() {
        let now = Date()
        XCTAssertEqual(GuideDayLabel.label(for: now), "Today")
        XCTAssertEqual(GuideDayLabel.label(for: now.addingTimeInterval(86_400)), "Tomorrow")
        XCTAssertEqual(GuideDayLabel.label(for: now.addingTimeInterval(-86_400)), "Yesterday")
        let later = GuideDayLabel.label(for: now.addingTimeInterval(5 * 86_400))
        XCTAssertFalse(["Today", "Tomorrow", "Yesterday"].contains(later))
        XCTAssertFalse(later.isEmpty)
    }

    func testGuideSelectionIsAValue() {
        XCTAssertEqual(GuideSelection(row: 1, column: 2), GuideSelection(row: 1, column: 2))
        XCTAssertNotEqual(GuideSelection(row: 1, column: 2), GuideSelection(row: 2, column: 1))
    }

    func testDoubleClickIntervalIsTheSystems() {
        XCTAssertEqual(GuideClicks.doubleClickInterval, .seconds(NSEvent.doubleClickInterval))
    }

    func testGuidePreferenceKeysTakeTheLatest() {
        var v: CGFloat = 0
        GuideHorizontalOffsetKey.reduce(value: &v) { 42 }
        XCTAssertEqual(v, 42)
        GuideRulerWidthKey.reduce(value: &v) { 7 }
        XCTAssertEqual(v, 7)
    }
}
#endif
