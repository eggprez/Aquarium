//  The phone's shell, under the views: the Home Screen's press-and-hold menu
//  (`QuickActions`), the App Icon shelves (`AppIconChoice`), and where a
//  letter of the A–Z strip lands (`LetterIndex`).
//
//  None of it opens a screen. The press on the Home Screen icon itself, and
//  iOS's own "you have changed the icon" alert, are in MANUAL.md.

#if os(iOS)
import XCTest
import UIKit
@testable import Aquarium

// MARK: - Quick actions

@MainActor
final class PhoneQuickActionsTests: PhoneUnitTestCase {
    private var saved: [UIApplicationShortcutItem]?

    override func setUp() async throws {
        try await super.setUp()
        saved = UIApplication.shared.shortcutItems
    }

    override func tearDown() async throws {
        UIApplication.shared.shortcutItems = saved
        try await super.tearDown()
    }

    private func item(_ json: String) -> BaseItem { PhoneJSON.item(json) }

    func testAnEpisodeLeadsTheMenuByItsShowThenSearch() throws {
        let episode = item(#"{"Id":"ep1","Name":"The Pilot","Type":"Episode","SeriesName":"Show","ParentIndexNumber":2,"IndexNumber":3}"#)
        QuickActions.update(resume: [episode], nextUp: [])
        let items = try XCTUnwrap(UIApplication.shared.shortcutItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].type, QuickActions.playType)
        XCTAssertEqual(items[0].localizedTitle, "Show", "an episode is named by its show")
        XCTAssertEqual(items[0].localizedSubtitle, "Season 2: Episode 3 · The Pilot")
        XCTAssertEqual(items[0].userInfo?[QuickActions.itemKey] as? String, "ep1")
        XCTAssertEqual(items[1].type, QuickActions.searchType)
        XCTAssertEqual(items[1].localizedTitle, "Search")
        XCTAssertNil(items[1].localizedSubtitle)
    }

    func testAFilmIsNamedByItsOwnTitle() throws {
        let film = item(#"{"Id":"f1","Name":"FX Long","Type":"Movie"}"#)
        let other = item(#"{"Id":"f2","Name":"Second","Type":"Movie"}"#)
        QuickActions.update(resume: [film, other], nextUp: [])
        let first = try XCTUnwrap(UIApplication.shared.shortcutItems?.first)
        XCTAssertEqual(first.localizedTitle, "FX Long")
        XCTAssertEqual(first.localizedSubtitle, "Continue watching")
        XCTAssertEqual(first.userInfo?[QuickActions.itemKey] as? String, "f1", "only the first of Continue Watching")
    }

    func testNextUpStandsInWhenNothingIsPartWay() throws {
        let next = item(#"{"Id":"ep9","Name":"Next One","Type":"Episode","SeriesName":"Other Show","IndexNumber":4}"#)
        QuickActions.update(resume: [], nextUp: [next])
        let first = try XCTUnwrap(UIApplication.shared.shortcutItems?.first)
        XCTAssertEqual(first.localizedTitle, "Other Show")
        XCTAssertEqual(first.localizedSubtitle, "Episode 4 · Next One", "no season number: the episode alone")
        XCTAssertEqual(first.userInfo?[QuickActions.itemKey] as? String, "ep9")
    }

    func testNothingToCarryOnWithLeavesOnlySearch() throws {
        QuickActions.update(resume: [], nextUp: [])
        let items = try XCTUnwrap(UIApplication.shared.shortcutItems)
        XCTAssertEqual(items.map(\.type), [QuickActions.searchType])
        QuickActions.clear()
        XCTAssertEqual(UIApplication.shared.shortcutItems?.count ?? 0, 0, "signed out: no menu at all")
    }

    func testEachEntryStandsForTheAppsOwnLink() {
        let play = UIApplicationShortcutItem(type: QuickActions.playType, localizedTitle: "x", localizedSubtitle: nil,
                                             icon: nil, userInfo: [QuickActions.itemKey: "abc123" as NSString])
        XCTAssertEqual(QuickActions.url(for: play)?.absoluteString, "aquarium://play/abc123")
        let search = UIApplicationShortcutItem(type: QuickActions.searchType, localizedTitle: "Search")
        XCTAssertEqual(QuickActions.url(for: search)?.absoluteString, "aquarium://search")
        let noId = UIApplicationShortcutItem(type: QuickActions.playType, localizedTitle: "x")
        XCTAssertNil(QuickActions.url(for: noId), "a play entry with no item is no link")
        let stranger = UIApplicationShortcutItem(type: "someone.else", localizedTitle: "x")
        XCTAssertNil(QuickActions.url(for: stranger))
        // The link is one the app accepts.
        XCTAssertTrue(AppModel.linkSchemes.contains("aquarium"))
    }

    func testAnIdThatIsNotOneCleanSegmentIsEscaped() {
        let odd = UIApplicationShortcutItem(type: QuickActions.playType, localizedTitle: "x", localizedSubtitle: nil,
                                            icon: nil, userInfo: [QuickActions.itemKey: "a/b c" as NSString])
        let url = QuickActions.url(for: odd)
        XCTAssertNotNil(url)
        XCTAssertFalse(url?.absoluteString.contains("a/b c") ?? true, "the id is percent-escaped, not a second path segment")
    }
}

// MARK: - App icons

@MainActor
final class PhoneAppIconChoiceTests: PhoneUnitTestCase {
    func testEveryIconHasItsOwnIdAndThePrimaryComesFirst() {
        let all = AppIconChoice.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "no two icons share an id")
        XCTAssertEqual(AppIconChoice.yearRound.first?.icons.first, AppIconChoice.classic)
        XCTAssertNil(AppIconChoice.classic.iconName)
        XCTAssertEqual(AppIconChoice.classic.id, "AppIcon")
        XCTAssertEqual(AppIconChoice.classic.preview, "IconPreview")
        XCTAssertEqual(AppIconChoice.all.first { $0.iconName == "AppIcon-Gold" }?.preview, "IconPreview-Gold")
    }

    /// An alternate the Info.plist does not list is one iOS refuses to set.
    func testEveryAlternateIsOneTheAppShips() throws {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternates = try XCTUnwrap(icons?["CFBundleAlternateIcons"] as? [String: Any], "no alternate icons in Info.plist")
        for icon in AppIconChoice.all {
            guard let name = icon.iconName else { continue }
            XCTAssertNotNil(alternates[name], "\(name) is offered but not built into the app")
        }
    }

    func testEveryTileHasAPreviewPicture() {
        for icon in AppIconChoice.all {
            XCTAssertNotNil(UIImage(named: icon.preview), "no \(icon.preview) in the asset catalog")
        }
    }

    func testEachHolidayHasOneIconAndOnlyTheSeasonalOnesHaveHolidays() {
        let seasonal = AppIconChoice.seasonal
        XCTAssertTrue(seasonal.allSatisfy { $0.holiday != nil })
        XCTAssertTrue(AppIconChoice.yearRound.flatMap(\.icons).allSatisfy { $0.holiday == nil })
        for holiday in Holiday.allCases {
            XCTAssertEqual(seasonal.filter { $0.holiday == holiday }.count, 1, holiday.rawValue)
        }
        for icon in AppIconChoice.yearRound.flatMap(\.icons) {
            XCTAssertNil(icon.lastDay, "\(icon.title) is offered all year: no last day")
        }
    }

    func testInSeasonShelfComesFirstAndHoldsOnlyIconsInTheirWindow() {
        let shelves = AppIconChoice.shelves
        let yearRound = AppIconChoice.yearRound.map(\.title)
        XCTAssertEqual(Array(shelves.map(\.title).suffix(yearRound.count)), yearRound, "the year-round shelves, in order, last")
        XCTAssertLessThanOrEqual(shelves.count, yearRound.count + 1)
        guard shelves.count > yearRound.count else { return }
        XCTAssertEqual(shelves[0].title, "In Season")
        XCTAssertFalse(shelves[0].icons.isEmpty)
        for icon in shelves[0].icons {
            XCTAssertNotNil(icon.holiday?.window(around: .now), "\(icon.title) is out of season")
            XCTAssertNotNil(icon.lastDay)
        }
        let ends = shelves[0].icons.compactMap(\.lastDay)
        XCTAssertEqual(ends, ends.sorted(), "the one going soonest first")
    }
}

// MARK: - The A–Z strip

@MainActor
final class PhoneLetterIndexTests: PhoneUnitTestCase {
    private func item(_ json: String) -> BaseItem { PhoneJSON.item(json) }

    func testTheStripRunsFromHashToZ() {
        XCTAssertEqual(LetterIndexBar.letters.count, 27)
        XCTAssertEqual(LetterIndexBar.letters.first, "#")
        XCTAssertEqual(LetterIndexBar.letters[1], "A")
        XCTAssertEqual(LetterIndexBar.letters.last, "Z")
        XCTAssertEqual(LetterIndex.minimumCount, 20)
    }

    func testTheKeyIsTheSortNameExceptForASong() {
        XCTAssertEqual(LetterIndex.key(item(#"{"Id":"f","Name":"The Long Winter","SortName":"Long Winter, The","Type":"Movie"}"#)),
                       "long winter, the")
        XCTAssertEqual(LetterIndex.key(item(#"{"Id":"f","Name":"Bare Name","Type":"Movie"}"#)), "bare name")
        XCTAssertEqual(LetterIndex.key(item(#"{"Id":"s","Name":"Zebra Song","SortName":"0001 - 0003 - Zebra Song","Type":"Audio"}"#)),
                       "zebra song", "a song's sort name starts with its disc and track")
        XCTAssertEqual(LetterIndex.key(item(#"{"Id":"x"}"#)), "")
    }

    func testWhereANameFallsAgainstALetter() {
        XCTAssertTrue(LetterIndex.isAtOrAfter("apple", "#"), "# is before everything")
        XCTAssertTrue(LetterIndex.isAtOrAfter("apple", "A"))
        XCTAssertFalse(LetterIndex.isAtOrAfter("apple", "B"))
        XCTAssertTrue(LetterIndex.isAtOrAfter("zebra", "B"))
        XCTAssertTrue(LetterIndex.isAtOrAfter("émile", "E"), "accents are read as their letter")
        XCTAssertFalse(LetterIndex.isAtOrAfter("émile", "F"))
        XCTAssertFalse(LetterIndex.isAtOrAfter("1984", "A"), "digits sort before the letters")
    }

    func testTheFirstNameAtOrAfterALetter() {
        let names = ["1984", "Alpha", "Bravo", "Delta", "Echo"].enumerated().map { i, name in
            item("{\"Id\":\"\(i)\",\"Name\":\"\(name)\",\"Type\":\"Movie\"}")
        }
        XCTAssertEqual(LetterIndex.first(in: names, atOrAfter: "#")?.Name, "1984")
        XCTAssertEqual(LetterIndex.first(in: names, atOrAfter: "B")?.Name, "Bravo")
        XCTAssertEqual(LetterIndex.first(in: names, atOrAfter: "C")?.Name, "Delta", "no C: the next name after it")
        XCTAssertNil(LetterIndex.first(in: names, atOrAfter: "Z"), "past the end: nowhere to go")
        XCTAssertNil(LetterIndex.first(in: [], atOrAfter: "#"))
    }
}
#endif
