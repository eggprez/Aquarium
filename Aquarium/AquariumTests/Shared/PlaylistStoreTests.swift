//  The server's playlists as the app keeps them: listed once, and made,
//  renamed, deleted, added to, taken from and reordered through the server,
//  with the list in hand kept right after each change. The server is a stub.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class PlaylistStoreTests: XCTestCase {
    private var store: PlaylistStore { .shared }

    /// What the stubbed server holds, changed by the requests it is sent.
    private final class Shelf: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [BaseItem] = []
        var lists: [BaseItem] {
            get { lock.lock(); defer { lock.unlock() }; return held }
            set { lock.lock(); held = newValue; lock.unlock() }
        }
    }

    private let shelf = Shelf()

    override func setUp() async throws {
        MusicServer.install()
        store.reset()
        shelf.lists = [
            MusicFixture.playlist("pl1", "Road Trip", count: 3),
            MusicFixture.playlist("pl2", "Sunday", count: 10),
        ]
        let shelf = shelf
        MusicServer.answer { call in
            switch (call.method, call.path) {
            case ("GET", "/Items") where call.query["IncludeItemTypes"] == "Playlist":
                return .items(shelf.lists)
            case ("POST", "/Playlists"):
                shelf.lists.append(MusicFixture.playlist("new1", call.body?["Name"] as? String ?? "", count: 2))
                return .json(#"{"Id":"new1"}"#)
            case ("POST", _) where call.path.hasPrefix("/Playlists/"), ("DELETE", _):
                return .ok
            default:
                return nil
            }
        }
    }

    override func tearDown() async throws {
        store.reset()
        MusicServer.remove()
    }

    private var listings: Int {
        MusicServer.calls(to: "/Items", method: "GET").filter { $0.query["IncludeItemTypes"] == "Playlist" }.count
    }

    // MARK: Listing

    func testTheListIsAskedForOnceAndThenKept() async {
        XCTAssertTrue(store.playlists.isEmpty)
        await store.ensureLoaded()
        XCTAssertEqual(store.playlists.map(\.Id), ["pl1", "pl2"])
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isLoading)
        await store.ensureLoaded()
        XCTAssertEqual(listings, 1)
        await store.refresh()
        XCTAssertEqual(listings, 2, "refresh always asks")
    }

    func testTheServerIsAskedForPlaylistsByName() async {
        await store.ensureLoaded()
        let asked = MusicServer.calls(to: "/Items").first { $0.query["IncludeItemTypes"] == "Playlist" }?.query ?? [:]
        XCTAssertEqual(asked["userId"], ClientStub.userId)
        XCTAssertEqual(asked["SortBy"], "SortName")
        XCTAssertEqual(asked["SortOrder"], "Ascending")
        XCTAssertEqual(asked["Recursive"], "true")
    }

    func testPlaylistsOfVideoAreLeftOut() async {
        var films = MusicFixture.playlist("plv", "Film Night")
        films.MediaType = "Video"
        var untyped = MusicFixture.playlist("plu", "Untyped")
        untyped.MediaType = nil
        shelf.lists += [films, untyped]
        await store.ensureLoaded()
        XCTAssertEqual(store.playlists.map(\.Id), ["pl1", "pl2", "plu"], "one that doesn't say is taken to be music")
    }

    func testAFailedRefreshKeepsTheListAndSaysWhy() async {
        await store.ensureLoaded()
        MusicServer.answer { call in call.path == "/System/Info/Public" ? nil : .status(500) }
        await store.refresh()
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.playlists.map(\.Id), ["pl1", "pl2"])
        XCTAssertFalse(store.isLoading)
    }

    func testAListThatNeverLoadedIsAskedForAgain() async {
        MusicServer.answer { call in call.path == "/System/Info/Public" ? nil : .status(500) }
        await store.ensureLoaded()
        XCTAssertNotNil(store.lastError)
        let shelf = shelf
        MusicServer.answer { call in
            call.path == "/Items" && call.query["IncludeItemTypes"] == "Playlist" ? .items(shelf.lists) : nil
        }
        await store.ensureLoaded()
        XCTAssertEqual(store.playlists.count, 2)
        XCTAssertNil(store.lastError)
    }

    func testResetForgetsTheList() async {
        await store.ensureLoaded()
        store.reset()
        XCTAssertTrue(store.playlists.isEmpty)
        await store.ensureLoaded()
        XCTAssertEqual(listings, 2)
    }

    // MARK: Making one

    func testCreatingAPlaylistSendsItsNameAndSongsAndListsItAfterwards() async throws {
        await store.ensureLoaded()
        let changes = ItemMutations.shared.revision
        let id = try await store.create(name: "Fresh", itemIds: ["a", "b"])
        XCTAssertEqual(id, "new1")
        let sent = try XCTUnwrap(MusicServer.calls(to: "/Playlists", method: "POST").first?.body)
        XCTAssertEqual(sent["Name"] as? String, "Fresh")
        XCTAssertEqual(sent["Ids"] as? [String], ["a", "b"])
        XCTAssertEqual(sent["UserId"] as? String, ClientStub.userId)
        XCTAssertEqual(sent["MediaType"] as? String, "Audio")
        XCTAssertEqual(store.playlists.map(\.Id), ["pl1", "pl2", "new1"])
        XCTAssertEqual(store.playlists.last?.Name, "Fresh")
        XCTAssertEqual(ItemMutations.shared.revision, changes + 1, "pages showing playlists are told")
    }

    func testAServerThatMakesAPlaylistWithoutSayingWhichIsAnError() async {
        MusicServer.answer { call in call.path == "/Playlists" ? .json("{}") : nil }
        let changes = ItemMutations.shared.revision
        do {
            _ = try await store.create(name: "Lost", itemIds: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(ItemMutations.shared.revision, changes)
    }

    // MARK: Changing one

    func testRenamingChangesTheNameHereWithoutListingAgain() async throws {
        await store.ensureLoaded()
        try await store.rename("pl1", to: "Long Drive")
        let sent = try XCTUnwrap(MusicServer.calls(to: "/Playlists/pl1", method: "POST").first)
        XCTAssertEqual(sent.body?["Name"] as? String, "Long Drive")
        XCTAssertEqual(store.playlists.map(\.Name), ["Long Drive", "Sunday"])
        XCTAssertEqual(listings, 1)
    }

    func testDeletingTakesItOffTheList() async throws {
        await store.ensureLoaded()
        try await store.delete("pl1")
        XCTAssertEqual(MusicServer.calls(to: "/Items/pl1", method: "DELETE").count, 1)
        XCTAssertEqual(store.playlists.map(\.Id), ["pl2"])
        XCTAssertEqual(listings, 1)
    }

    func testAddingSongsSendsThemAndKeepsTheCountRight() async throws {
        await store.ensureLoaded()
        try await store.add(["a", "b"], to: "pl1")
        let sent = try XCTUnwrap(MusicServer.calls(to: "/Playlists/pl1/Items", method: "POST").first)
        XCTAssertEqual(sent.query["ids"], "a,b")
        XCTAssertEqual(sent.query["userId"], ClientStub.userId)
        XCTAssertEqual(store.playlists[0].ChildCount, 5)
        XCTAssertEqual(store.playlists[0].RecursiveItemCount, 5)
        XCTAssertEqual(store.playlists[1].ChildCount, 10)
        XCTAssertEqual(listings, 1, "the count is kept here; nothing is listed again yet")
    }

    func testAChangedPlaylistIsListedAgainTheNextTimeTheListIsWanted() async throws {
        await store.ensureLoaded()
        try await store.add(["a"], to: "pl1")
        // The server's own count, and the cover it makes from the songs.
        shelf.lists[0].ChildCount = 4
        await store.ensureLoaded()
        XCTAssertEqual(listings, 2)
        XCTAssertEqual(store.playlists[0].ChildCount, 4)
        await store.ensureLoaded()
        XCTAssertEqual(listings, 2, "and only the once")
    }

    func testRemovingSongsGoesByEntryAndTheCountNeverGoesBelowNothing() async throws {
        await store.ensureLoaded()
        try await store.remove(entryIds: ["e1", "e2"], from: "pl1")
        let sent = try XCTUnwrap(MusicServer.calls(to: "/Playlists/pl1/Items", method: "DELETE").first)
        XCTAssertEqual(sent.query["entryIds"], "e1,e2")
        XCTAssertEqual(store.playlists[0].ChildCount, 1)
        try await store.remove(entryIds: ["e3", "e4", "e5"], from: "pl1")
        XCTAssertEqual(store.playlists[0].ChildCount, 0)
        XCTAssertEqual(store.playlists[0].RecursiveItemCount, 0)
    }

    func testAddingOrRemovingNothingAsksTheServerNothing() async throws {
        await store.ensureLoaded()
        try await store.add([], to: "pl1")
        try await store.remove(entryIds: [], from: "pl1")
        XCTAssertTrue(MusicServer.calls(to: "/Playlists/pl1/Items").isEmpty)
        XCTAssertEqual(store.playlists[0].ChildCount, 3)
    }

    func testMovingASongSendsItsEntryAndItsNewPlace() async throws {
        try await store.move(entryId: "e7", in: "pl1", to: 3)
        XCTAssertEqual(MusicServer.calls(to: "/Playlists/pl1/Items/e7/Move/3", method: "POST").count, 1)
        try await store.move(entryId: "e7", in: "pl1", to: -2)
        XCTAssertEqual(MusicServer.calls(to: "/Playlists/pl1/Items/e7/Move/0", method: "POST").count, 1, "never a place before the first")
    }

    func testAChangeTheServerRefusesLeavesTheListAsItWas() async {
        await store.ensureLoaded()
        MusicServer.answer { call in call.path == "/System/Info/Public" ? nil : .status(500) }
        let changes = ItemMutations.shared.revision
        do { try await store.rename("pl1", to: "Nope"); XCTFail("rename should throw") } catch {}
        do { try await store.delete("pl1"); XCTFail("delete should throw") } catch {}
        do { try await store.add(["a"], to: "pl1"); XCTFail("add should throw") } catch {}
        do { try await store.remove(entryIds: ["e1"], from: "pl1"); XCTFail("remove should throw") } catch {}
        do { try await store.move(entryId: "e1", in: "pl1", to: 1); XCTFail("move should throw") } catch {}
        XCTAssertEqual(store.playlists.map(\.Name), ["Road Trip", "Sunday"])
        XCTAssertEqual(store.playlists[0].ChildCount, 3)
        XCTAssertEqual(ItemMutations.shared.revision, changes)
    }

    func testChangingAPlaylistThatIsNotOnTheListStillGoesToTheServer() async throws {
        // Nothing loaded: the page that asked knows the id from elsewhere.
        try await store.rename("elsewhere", to: "Renamed")
        try await store.add(["a"], to: "elsewhere")
        XCTAssertEqual(MusicServer.calls(to: "/Playlists/elsewhere", method: "POST").count, 1)
        XCTAssertEqual(MusicServer.calls(to: "/Playlists/elsewhere/Items", method: "POST").count, 1)
        XCTAssertTrue(store.playlists.isEmpty)
    }

    // MARK: A playlist's songs

    func testAPlaylistsSongsComeFromItsOwnRoute() async throws {
        MusicServer.answer { call in
            call.path == "/Playlists/pl1/Items" ? .items(MusicFixture.songs(["a", "b"])) : nil
        }
        let songs = try await JellyfinClient.shared.playlistItems(playlistId: "pl1")
        XCTAssertEqual(songs.map(\.Id), ["a", "b"])
        XCTAssertTrue(MusicServer.calls(to: "/Items").filter { $0.query["ParentId"] == "pl1" }.isEmpty, "the second route is only for when the first fails")
    }

    func testAPlaylistTheStrictRouteRefusesIsReadTheWayTheWebClientDoes() async throws {
        MusicServer.answer { call in
            if call.path == "/Playlists/pl1/Items" { return .status(403) }
            if call.path == "/Items", call.query["ParentId"] == "pl1" { return .items(MusicFixture.songs(["a"])) }
            return nil
        }
        let songs = try await JellyfinClient.shared.playlistItems(playlistId: "pl1")
        XCTAssertEqual(songs.map(\.Id), ["a"])
    }

    func testAPlaylistNeitherRouteWillOpenFailsWithTheFirstRefusal() async {
        MusicServer.answer { call in
            if call.path == "/Playlists/pl1/Items" { return .status(403) }
            return call.path == "/Items" && call.query["ParentId"] == "pl1" ? .status(500) : nil
        }
        do {
            _ = try await JellyfinClient.shared.playlistItems(playlistId: "pl1")
            XCTFail("expected an error")
        } catch APIError.server(let status, _) {
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
#endif
