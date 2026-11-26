//  `MusicFavoriteMarks`: what a music item's press-and-hold menu believes
//  about its favourite. The music pages keep the items they fetched, so an
//  album starred from the Albums grid used to keep offering "Add to
//  Favorites" (the iPad suite's PadMusicMoreTests found it, 2026-11-26).

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicFavoriteMarksTests: XCTestCase {
    private let marks = MusicFavoriteMarks.shared

    override func setUp() async throws { marks.reset() }
    override func tearDown() async throws { marks.reset() }

    private func album(favorite: Bool) -> BaseItem {
        var album = MusicFixture.album("al" + UUID().uuidString, "FX Formats")
        var data = UserData()
        data.IsFavorite = favorite
        album.UserData = data
        return album
    }

    func testWithNothingSetHereTheItemsOwnStateStands() {
        XCTAssertTrue(marks.isFavorite(album(favorite: true)))
        XCTAssertFalse(marks.isFavorite(album(favorite: false)))
    }

    func testWhatWasSetHereWinsOverTheStaleItem() {
        let stale = album(favorite: false)
        marks.set(stale.Id, true)
        XCTAssertTrue(marks.isFavorite(stale), "starred from the grid: the menu now offers Remove")
        marks.set(stale.Id, false)
        XCTAssertFalse(marks.isFavorite(stale), "and unstarred again, Add")

        let starred = album(favorite: true)
        marks.set(starred.Id, false)
        XCTAssertFalse(marks.isFavorite(starred), "unstarring an item fetched as a favourite")
    }

    func testOnlyTheItemSetIsChanged() {
        let one = album(favorite: false), other = album(favorite: false)
        marks.set(one.Id, true)
        XCTAssertFalse(marks.isFavorite(other))
    }

    func testResetGoesBackToTheItems() {
        let item = album(favorite: false)
        marks.set(item.Id, true)
        marks.reset()
        XCTAssertFalse(marks.isFavorite(item), "a sign-out leaves nothing of the last account's stars")
    }
}
#endif
