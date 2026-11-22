//  `LibraryIndex`: the library kept on this device. What a sync asks the
//  server and makes of the answers, and what the copy then answers itself —
//  search, a show's seasons and episodes, a library grid sorted, filtered and
//  paged the way the server would, favourites, Home's rows.
//
//  The server is a small fake behind `RoutedStub`: it answers `/UserViews` and
//  the four questions the sync asks of `/Items` (everything in full, what was
//  saved since, the light sweep, and items by id), paged as Jellyfin pages.
//  No item here has an image tag, so the sync's artwork pass has nothing to
//  fetch and no request leaves the stub — except in the one test of that
//  pass, where the pictures are served from this machine's loopback address.

import XCTest
@testable import Aquarium

// MARK: - The fake server

private final class FakeLibraryServer: @unchecked Sendable {
    private let lock = NSLock()
    private var views: [BaseItem] = []
    private var contents: [String: [BaseItem]] = [:]
    /// What `MinDateLastSaved` finds, by library.
    private var savedSince: [String: [String]] = [:]
    private var failingStatus: Int?
    /// Held shut, the light sweep waits here; `reachedLight` says it got there.
    private var lightGate: DispatchSemaphore?
    private var lightReached = false

    func set(views: [BaseItem], contents: [String: [BaseItem]]) {
        lock.withLock {
            self.views = views
            self.contents = contents
        }
    }

    func update(_ library: String, _ edit: (inout [BaseItem]) -> Void) {
        lock.withLock { edit(&contents[library, default: []]) }
    }

    func setSaved(_ library: String, _ ids: [String]) { lock.withLock { savedSince[library] = ids } }
    func fail(with status: Int?) { lock.withLock { failingStatus = status } }

    func holdLightSweep() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock {
            lightGate = gate
            lightReached = false
        }
        return gate
    }

    var reachedLight: Bool { lock.withLock { lightReached } }

    func handle(_ request: URLRequest) -> (status: Int, body: Data)? {
        let path = request.url?.path ?? ""
        if let status = lock.withLock({ failingStatus }) { return (status, Data()) }
        if path == "/UserViews" { return (200, CoreItem.json(lock.withLock { views })) }
        guard path == "/Items" else { return nil }

        if let ids = RoutedStub.query(request, "Ids") {
            let wanted = Set(ids.split(separator: ",").map(String.init))
            let found = lock.withLock { contents.values.joined().filter { wanted.contains($0.Id) } }
            return (200, CoreItem.json(Array(found)))
        }
        guard let library = RoutedStub.query(request, "ParentId") else { return (200, CoreItem.json([])) }
        let isLight = RoutedStub.query(request, "EnableUserData") == "true"
        if isLight {
            let gate = lock.withLock { () -> DispatchSemaphore? in
                defer { lightGate = nil }
                if lightGate != nil { lightReached = true }
                return lightGate
            }
            _ = gate?.wait(timeout: .now() + 5)
        }
        var list = lock.withLock { contents[library] ?? [] }
        if isLight {
            list = list.map { full in
                var entry = BaseItem()
                entry.Id = full.Id
                entry.UserData = full.UserData
                return entry
            }
        } else if RoutedStub.query(request, "MinDateLastSaved") != nil {
            let saved = Set(lock.withLock { savedSince[library] ?? [] })
            list = list.filter { saved.contains($0.Id) }
        } else if RoutedStub.query(request, "Fields") == nil, RoutedStub.query(request, "IncludeItemTypes") != "MusicAlbum,AudioBook" {
            // Not a question the sync asks. (The one let through is the sweep
            // for album and book covers, which lists a music library.)
            list = []
        }
        let start = RoutedStub.query(request, "StartIndex").flatMap(Int.init) ?? 0
        let limit = RoutedStub.query(request, "Limit").flatMap(Int.init) ?? list.count
        let page = Array(list.dropFirst(start).prefix(limit))
        return (200, CoreItem.json(page, total: list.count))
    }
}

// MARK: - Pure parts

final class LibraryIndexMergeTests: XCTestCase {
    private func table(_ items: [BaseItem]) -> [String: BaseItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.Id, $0) })
    }

    private func light(_ id: String, _ data: UserData? = nil) -> BaseItem {
        var entry = BaseItem()
        entry.Id = id
        entry.UserData = data
        return entry
    }

    func testFullItemsGoIntoTheTableAndCountAsAChange() {
        let a = CoreItem.movie("a")
        let merge = LibraryIndex.merge(full: [a], light: [light("a")], into: [:], known: nil, trackParents: false)
        XCTAssertEqual(merge.items["a"], a)
        XCTAssertEqual(merge.ids, ["a"])
        XCTAssertTrue(merge.changed)
        XCTAssertTrue(merge.missing.isEmpty)
        XCTAssertTrue(merge.parents.isEmpty)
    }

    func testNothingNewIsNoChange() {
        let a = CoreItem.movie("a"), b = CoreItem.movie("b")
        let merge = LibraryIndex.merge(full: [a], light: [light("a"), light("b")], into: table([a, b]),
                                       known: ["b", "a"], trackParents: true)
        XCTAssertFalse(merge.changed, "the same item saved again, and the same ids in another order, change nothing")
        XCTAssertEqual(merge.ids, ["a", "b"], "members follow the sweep's order")
    }

    func testAFullItemThatDiffersReplacesTheOldOne() {
        let old = CoreItem.movie("a", name: "Old")
        let new = CoreItem.movie("a", name: "New")
        let merge = LibraryIndex.merge(full: [new], light: [light("a")], into: table([old]), known: ["a"], trackParents: false)
        XCTAssertEqual(merge.items["a"]?.Name, "New")
        XCTAssertTrue(merge.changed)
    }

    func testTheSweepCarriesWatchedStateIntoItemsItDidNotRefetch() {
        let a = CoreItem.movie("a") { $0.Overview = "kept" }
        let merge = LibraryIndex.merge(full: [], light: [light("a", CoreItem.userData(played: true))],
                                       into: table([a]), known: ["a"], trackParents: false)
        XCTAssertEqual(merge.items["a"]?.userData.played, true)
        XCTAssertEqual(merge.items["a"]?.Overview, "kept", "only the user data is taken from the sweep")
        XCTAssertTrue(merge.changed)
    }

    func testListedButNotHeldIsMissingAndEmptyIdsAreSkipped() {
        let a = CoreItem.movie("a")
        let merge = LibraryIndex.merge(full: [], light: [light("a"), light("new"), light("")],
                                       into: table([a]), known: ["a"], trackParents: false)
        XCTAssertEqual(merge.missing, ["new"])
        XCTAssertEqual(merge.ids, ["a", "new"])
        XCTAssertTrue(merge.changed, "the membership grew")
    }

    func testAnItemTheSweepNoLongerListsIsAChange() {
        let a = CoreItem.movie("a"), b = CoreItem.movie("b")
        let merge = LibraryIndex.merge(full: [], light: [light("a")], into: table([a, b]), known: ["a", "b"], trackParents: false)
        XCTAssertEqual(merge.ids, ["a"])
        XCTAssertTrue(merge.changed)
        XCTAssertNotNil(merge.items["b"], "trimming what is gone is the sync's job, once every library is in")
    }

    func testParentsAreTrackedOnlyOnAnIncrementalSync() {
        let episode = CoreItem.episode("e", series: "show", season: "season", s: 1, e: 1)
        let film = CoreItem.movie("m")
        let first = LibraryIndex.merge(full: [episode, film], light: [], into: [:], known: nil, trackParents: false)
        XCTAssertTrue(first.parents.isEmpty)
        let later = LibraryIndex.merge(full: [episode, film], light: [], into: [:], known: nil, trackParents: true)
        XCTAssertEqual(later.parents, ["show", "season"])
    }

    func testSeasonsAreOrderedByNumberThenName() {
        var loose = CoreItem.make("s-parent", "Season", name: "Extras")
        loose.ParentId = "show"
        let derived = LibraryIndex.derive(table([
            CoreItem.season("s2", series: "show", number: 2),
            CoreItem.season("s0", series: "show", number: 0, name: "Specials"),
            CoreItem.season("s1", series: "show", number: 1),
            CoreItem.season("s-b", series: "show", number: nil, name: "Bonus"),
            loose,
            CoreItem.season("other", series: "other-show", number: 1),
        ]))
        XCTAssertEqual(derived.seasonsBySeries["show"], ["s0", "s1", "s2", "s-b", "s-parent"],
                       "numbered first in order, then the unnumbered by name; a season with no SeriesId files under its parent")
        XCTAssertEqual(derived.seasonsBySeries["other-show"], ["other"])
    }

    func testEpisodesAreOrderedBySeasonThenNumberThenNumericName() {
        let derived = LibraryIndex.derive(table([
            CoreItem.episode("e2-1", series: "show", season: "s2", s: 2, e: 1),
            CoreItem.episode("e1-10", series: "show", season: "s1", s: 1, e: 10),
            CoreItem.episode("e1-2", series: "show", season: "s1", s: 1, e: 2),
            CoreItem.episode("x10", series: "show", season: "s1", s: 1, e: nil, name: "Extra 10"),
            CoreItem.episode("x2", series: "show", season: "s1", s: 1, e: nil, name: "Extra 2"),
            CoreItem.episode("orphan", series: "show", season: nil, s: nil, e: 1),
            CoreItem.movie("film"),
        ]))
        XCTAssertEqual(derived.episodesBySeason["s1"], ["e1-2", "e1-10", "x2", "x10"],
                       "unnumbered last, and \"Extra 2\" before \"Extra 10\"")
        XCTAssertEqual(derived.episodesBySeason["s2"], ["e2-1"])
        XCTAssertEqual(derived.episodesBySeries["show"], ["e1-2", "e1-10", "x2", "x10", "e2-1", "orphan"],
                       "an episode with no season number sorts after every numbered season")
        XCTAssertNil(derived.episodesBySeason["film"])
    }

    @MainActor
    func testOnlyVideoLibrariesAreIndexed() {
        func view(_ type: String?) -> BaseItem { CoreItem.library("v", name: "V", type: type) }
        for type in ["movies", "tvshows", "homevideos", "musicvideos", "mixed", nil] as [String?] {
            XCTAssertTrue(LibraryIndex.isIndexable(view(type)), "\(type ?? "untyped")")
        }
        for type in ["boxsets", "playlists", "music", "audiobooks", "books", "podcasts", "livetv"] {
            XCTAssertFalse(LibraryIndex.isIndexable(view(type)), type)
        }
    }
}

// MARK: - Syncing and answering

@MainActor
final class LibraryIndexTests: XCTestCase {
    private var server: FakeLibraryServer!
    private var index: LibraryIndex { .shared }

    private let movies = CoreItem.library("lib-movies", name: "Films", type: "movies")
    private let shows = CoreItem.library("lib-tv", name: "Shows", type: "tvshows")
    private let music = CoreItem.library("lib-music", name: "Music", type: "music")

    override func setUp() async throws {
        CoreAccount.signIn()
        await CoreAccount.goOnline()
        Preferences.shared.keepsLibraryCopy = true
        let server = FakeLibraryServer()
        self.server = server
        RoutedStub.route { server.handle($0) }
    }

    override func tearDown() async throws {
        RoutedStub.route(nil)
        await CoreLibrary.wipeAndSettle()
        Preferences.shared.keepsLibraryCopy = false
        await ImageLoader.shared.setDiskEnabled(false)
        await CoreAccount.goOnline()
        await CoreAccount.signOut()
        server = nil
    }

    // A small library: five films and one show of two seasons.
    private var films: [BaseItem] {
        [
            CoreItem.movie("m-heat", name: "Heat") {
                $0.SortName = "heat"
                $0.DateCreated = "2024-03-01T00:00:00.0000000Z"
                $0.PremiereDate = "1995-12-15T00:00:00.0000000Z"
                $0.CommunityRating = 8.3
                $0.RunTimeTicks = 170 * 600_000_000
                $0.Genres = ["Crime", "Drama"]
                $0.BackdropImageTags = ["bd"]
                $0.UserData = CoreItem.userData(played: true, favorite: true)
            },
            CoreItem.movie("m-heatwave", name: "Heat Wave") {
                $0.SortName = "heat wave"
                $0.DateCreated = "2024-01-01T00:00:00.0000000Z"
                $0.PremiereDate = "2011-01-01T00:00:00.0000000Z"
                $0.CommunityRating = 5.1
                $0.RunTimeTicks = 90 * 600_000_000
                $0.Genres = ["Drama"]
            },
            CoreItem.movie("m-alien", name: "Alien") {
                $0.SortName = "alien"
                $0.DateCreated = "2024-02-01T00:00:00.0000000Z"
                $0.PremiereDate = "1979-05-25T00:00:00.0000000Z"
                $0.CommunityRating = 8.5
                $0.RunTimeTicks = 117 * 600_000_000
                $0.Genres = ["Horror"]
                $0.BackdropImageTags = []
                $0.UserData = CoreItem.userData(favorite: true, position: 6_000_000_000)
            },
            CoreItem.movie("m-thing", name: "The Thing") {
                // Sorted by what the server sorts by, not by the title shown.
                $0.SortName = "thing"
                $0.Genres = ["Horror"]
            },
            CoreItem.movie("m-preheat", name: "Preheat") {
                $0.SortName = "preheat"
                $0.DateCreated = "2023-06-01T00:00:00.0000000Z"
                $0.CommunityRating = 2.0
                $0.RunTimeTicks = 80 * 600_000_000
            },
        ]
    }

    private var television: [BaseItem] {
        [
            CoreItem.series("show", name: "The Wire") {
                $0.SortName = "wire"
                $0.BackdropImageTags = ["bd"]
                $0.UserData = CoreItem.userData(unplayed: 2)
            },
            CoreItem.series("show-done", name: "Done Show") {
                $0.SortName = "done show"
                $0.UserData = CoreItem.userData(played: true, unplayed: 0)
            },
            CoreItem.season("s2", series: "show", number: 2),
            CoreItem.season("s1", series: "show", number: 1),
            CoreItem.episode("e1-2", series: "show", season: "s1", s: 1, e: 2, name: "The Detail", seriesName: "The Wire"),
            CoreItem.episode("e1-1", series: "show", season: "s1", s: 1, e: 1, name: "The Target", seriesName: "The Wire") {
                $0.UserData = CoreItem.userData(played: true)
            },
            CoreItem.episode("e2-1", series: "show", season: "s2", s: 2, e: 1, name: "Heat", seriesName: "The Wire"),
        ]
    }

    private func load(films: [BaseItem]? = nil, television: [BaseItem]? = nil) async {
        server.set(views: [movies, shows, music],
                   contents: [movies.Id: films ?? self.films, shows.Id: television ?? self.television])
        await index.sync(force: true)
    }

    private func itemsRequests(_ matching: (URLRequest) -> Bool = { _ in true }) -> [URLRequest] {
        RoutedStub.requests.filter { $0.url?.path == "/Items" && matching($0) }
    }

    private func heavyRequests() -> [URLRequest] {
        itemsRequests { RoutedStub.query($0, "Fields") != nil && RoutedStub.query($0, "ParentId") != nil }
    }

    private func ids(_ response: ItemsResponse?) -> [String]? { response?.items.map(\.Id) }

    private func query(_ edit: (inout JellyfinClient.LibraryQuery) -> Void = { _ in }) -> JellyfinClient.LibraryQuery {
        var q = JellyfinClient.LibraryQuery(includeTypes: "Movie")
        edit(&q)
        return q
    }

    // MARK: Syncing

    func testNothingAnswersBeforeTheFirstSync() {
        XCTAssertFalse(index.isReady)
        XCTAssertNil(index.item("m-heat"))
        XCTAssertNil(index.search("heat", limit: 5))
        XCTAssertNil(index.seasons(seriesId: "show"))
        XCTAssertNil(index.episodes(seriesId: "show", seasonId: nil))
        XCTAssertNil(index.libraryItems(parentId: movies.Id, query: query()))
        XCTAssertNil(index.favorites(startIndex: 0, limit: 10, includeTypes: "Movie", sortBy: "SortName", sortOrder: "Ascending"))
        XCTAssertNil(index.spotlight(limit: 3))
        XCTAssertNil(index.savedViews)
    }

    func testFirstSyncCopiesEveryVideoLibrary() async {
        await load()
        XCTAssertTrue(index.isReady)
        XCTAssertFalse(index.isSyncing)
        XCTAssertNil(index.syncProgress, "progress is cleared when the sync ends")
        XCTAssertNil(index.lastError)
        XCTAssertNotNil(index.lastSynced)
        XCTAssertEqual(index.itemCount, 12)
        XCTAssertEqual(index.item("m-heat")?.Name, "Heat")
        XCTAssertEqual(index.savedViews?.map(\.Id), [movies.Id, shows.Id, music.Id], "every library is kept for the offline shell")

        let heavy = heavyRequests()
        XCTAssertEqual(Set(heavy.compactMap { RoutedStub.query($0, "ParentId") }), [movies.Id, shows.Id],
                       "music is not part of the copy")
        for request in heavy {
            XCTAssertNil(RoutedStub.query(request, "MinDateLastSaved"), "a first sync asks for everything")
            XCTAssertEqual(RoutedStub.query(request, "SortBy"), "SortName,DateCreated", "paged in an order that holds still")
            XCTAssertEqual(RoutedStub.query(request, "Recursive"), "true")
            XCTAssertEqual(RoutedStub.query(request, "IncludeItemTypes"), "Movie,Series,Season,Episode,Video,BoxSet")
            XCTAssertEqual(RoutedStub.query(request, "Fields"), JellyfinClient.indexFields)
        }
        let light = itemsRequests { RoutedStub.query($0, "EnableUserData") == "true" }
        XCTAssertEqual(light.count, 2, "one light sweep per library")
        XCTAssertEqual(RoutedStub.query(light[0], "EnableImages"), "false")
        XCTAssertEqual(RoutedStub.query(light[0], "Limit"), "2000")
    }

    func testALargeLibraryIsFetchedAPageAtATime() async {
        let many = (0..<650).map { CoreItem.movie(String(format: "m%04d", $0)) }
        await load(films: many, television: [])
        XCTAssertEqual(index.itemCount, 650)
        let starts = heavyRequests()
            .filter { RoutedStub.query($0, "ParentId") == movies.Id }
            .compactMap { RoutedStub.query($0, "StartIndex") }
        XCTAssertEqual(starts, ["0", "300", "600"], "300 a page, each starting where the last ended")
        XCTAssertEqual(index.libraryItems(parentId: movies.Id, query: query { $0.limit = 1 })?.total, 650)
    }

    func testALaterSyncAsksOnlyForWhatChanged() async {
        await load()
        RoutedStub.route { [server] in server!.handle($0) }   // clears the recorded requests

        server.update(movies.Id) { list in
            // Watched elsewhere: no metadata saved, so only the sweep says so.
            if let i = list.firstIndex(where: { $0.Id == "m-heatwave" }) { list[i].UserData = CoreItem.userData(played: true) }
            // Deleted on the server.
            list.removeAll { $0.Id == "m-preheat" }
            // Added, and missed by the date filter.
            list.append(CoreItem.movie("m-new", name: "Newcomer"))
        }
        server.update(shows.Id) { list in
            // An episode saved again, and its show's count changed with it —
            // which saving the episode does not re-save.
            if let i = list.firstIndex(where: { $0.Id == "e1-2" }) { list[i].Name = "The Detail (Remastered)" }
            if let i = list.firstIndex(where: { $0.Id == "show" }) { list[i].ChildCount = 9 }
        }
        server.setSaved(shows.Id, ["e1-2"])
        await index.sync(force: true)

        XCTAssertNil(index.lastError)
        XCTAssertEqual(index.item("m-heatwave")?.userData.played, true)
        XCTAssertNil(index.item("m-preheat"), "gone from the server, gone from the copy")
        XCTAssertEqual(index.item("m-new")?.Name, "Newcomer", "listed by the sweep and fetched by id")
        XCTAssertEqual(index.item("e1-2")?.Name, "The Detail (Remastered)")
        XCTAssertEqual(index.item("show")?.ChildCount, 9, "the parents of what changed are fetched again")
        XCTAssertEqual(index.itemCount, 12)
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query())),
                       ["m-alien", "m-heat", "m-heatwave", "m-new", "m-thing"])

        let heavy = heavyRequests()
        XCTAssertFalse(heavy.isEmpty)
        for request in heavy {
            XCTAssertNotNil(RoutedStub.query(request, "MinDateLastSaved"), "only what was saved since the last sync")
        }
        let byId = itemsRequests { RoutedStub.query($0, "Ids") != nil }.compactMap { RoutedStub.query($0, "Ids") }
        XCTAssertEqual(byId.count, 2)
        XCTAssertTrue(byId.contains("m-new"))
        XCTAssertTrue(byId.contains { Set($0.split(separator: ",").map(String.init)) == ["show", "s1"] })
    }

    func testTheCursorIsWoundBackTwoMinutes() async throws {
        await load()
        RoutedStub.route { [server] in server!.handle($0) }
        let before = JellyfinClient.shared.serverNow
        await index.sync(force: true)
        let stamp = try XCTUnwrap(heavyRequests().first.flatMap { RoutedStub.query($0, "MinDateLastSaved") })
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let since = try XCTUnwrap(formatter.date(from: stamp))
        // The first sync started a moment before `before`; its cursor is that
        // start less two minutes, to the second.
        XCTAssertEqual(since.timeIntervalSince(before), -120, accuracy: 10)
    }

    func testASyncSoonAfterAnotherIsSkippedUnlessForced() async {
        await load()
        RoutedStub.route { [server] in server!.handle($0) }
        await index.sync()
        XCTAssertTrue(heavyRequests().isEmpty, "the app becomes active far more often than a library changes")
        await index.sync(minimumGap: 0)
        XCTAssertFalse(heavyRequests().isEmpty)
    }

    func testWithTheSettingOffNothingIsAsked() async {
        Preferences.shared.keepsLibraryCopy = false
        await load()
        XCTAssertFalse(index.isReady)
        XCTAssertTrue(itemsRequests().isEmpty)
    }

    func testAFailedFirstSyncSaysWhyAndStaysEmpty() async {
        server.fail(with: 500)
        await load()
        XCTAssertFalse(index.isReady)
        XCTAssertNotNil(index.lastError)
        XCTAssertNil(index.syncProgress)
        XCTAssertFalse(JellyfinClient.shared.isOffline, "an error from the server is not the server being away")
    }

    func testAFailedLaterSyncKeepsTheCopyItHad() async {
        await load()
        server.fail(with: 500)
        await index.sync(force: true)
        XCTAssertNotNil(index.lastError)
        XCTAssertTrue(index.isReady)
        XCTAssertEqual(index.itemCount, 12)
        server.fail(with: nil)
        await index.sync(force: true)
        XCTAssertNil(index.lastError, "the next sync that works clears the message")
    }

    func testALibraryRemovedFromTheServerLeavesTheCopy() async {
        await load()
        server.set(views: [movies], contents: [movies.Id: films])
        await index.sync(force: true)
        XCTAssertNil(index.item("show"))
        XCTAssertNil(index.seasons(seriesId: "show"))
        XCTAssertNil(index.libraryItems(parentId: shows.Id, query: query { $0.includeTypes = "Series" }))
        XCTAssertEqual(index.itemCount, 5)
        XCTAssertEqual(index.savedViews?.map(\.Id), [movies.Id])
    }

    func testAWatchedFlagSetDuringASyncSurvivesIt() async {
        await load()
        let gate = server.holdLightSweep()
        let sync = Task { await index.sync(force: true) }
        let reached = await CoreWait.until { self.server.reachedLight }
        XCTAssertTrue(reached, "the sync never reached its light sweep")
        // The sync is waiting on the server with its own snapshot of the table.
        index.patchUserData("m-thing") { $0.Played = true }
        gate.signal()
        await sync.value
        XCTAssertEqual(index.item("m-thing")?.userData.played, true,
                       "the sync's older answer must not undo a tap made while it ran")
    }

    func testWipeForgetsTheLot() async {
        await load()
        index.keepHome(sections: [.resume], resume: films, nextUp: [], latest: [], hero: [])
        index.keepLibraries(video: [movies, shows], music: [music], books: [], liveTV: true)
        index.wipe()
        XCTAssertFalse(index.isReady)
        XCTAssertEqual(index.itemCount, 0)
        XCTAssertNil(index.lastSynced)
        XCTAssertNil(index.item("m-heat"))
        XCTAssertNil(index.homeCopy())
        XCTAssertFalse(index.hasHomeCopy)
        XCTAssertNil(index.savedLibraries)
        XCTAssertNil(index.savedViews)
    }

    // MARK: The setting, and the pictures

    func testTurningTheSettingOnSyncsAndOffForgets() async {
        server.set(views: [movies], contents: [movies.Id: films])
        index.setEnabled(true)
        let ready = await CoreWait.until { self.index.isReady && !self.index.isSyncing }
        XCTAssertTrue(ready, "turning the copy on starts the first sync")
        XCTAssertEqual(index.itemCount, 5)

        index.setEnabled(false)
        XCTAssertFalse(index.isReady)
        XCTAssertEqual(index.itemCount, 0)
    }

    func testTheHeroBackdropIsAskedForAtASizeTheScreenCanUse() {
        let width = LibraryIndex.heroBackdropWidth
        XCTAssertGreaterThanOrEqual(width, HeroHeader.backdropWidth, "never less than the hero's fixed width")
        XCTAssertLessThanOrEqual(width, 3840, "and never past 4K")
    }

    func testPostersLogosStillsAndBackdropsAreSavedBesideTheCopy() async throws {
        let pictures = try LoopbackServer()
        defer { pictures.stop() }
        let png = CorePicture.png(width: 40, height: 60)
        pictures.setHandler { _ in .data(png, type: "image/png") }
        // Signed in to an address that serves pictures; the sync's own
        // requests still go through the stub.
        await CoreAccount.signOut()
        CoreAccount.signIn(server: pictures.base)
        RoutedStub.route { [server] in server!.handle($0) }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let film = "film\(unique)", show = "show\(unique)", episode = "ep\(unique)", plain = "plain\(unique)", album = "album\(unique)"
        server.set(views: [movies, shows, music], contents: [
            movies.Id: [
                CoreItem.movie(film) {
                    $0.ImageTags = ["Primary": "p1", "Logo": "l1"]
                    $0.BackdropImageTags = ["b1"]
                },
                CoreItem.movie(plain),
            ],
            shows.Id: [
                CoreItem.series(show) { $0.ImageTags = ["Primary": "p2"] },
                CoreItem.episode(episode, series: show, season: nil, s: 1, e: 1) { $0.ImageTags = ["Primary": "p3"] },
            ],
            music.Id: [CoreItem.make(album, "MusicAlbum") { $0.ImageTags = ["Primary": "p4"] }],
        ])
        await index.sync(force: true)

        let loader = ImageLoader.shared
        let saved = await CoreWait.until {
            let posters = await loader.savedArtworkFiles(for: [film, show, episode])
            let backdrop = await loader.savedArtworkFiles(for: [film], type: "Backdrop")
            return posters.count == 3 && backdrop.count == 1 && self.index.artworkProgress == nil
        }
        XCTAssertTrue(saved, "the pictures never reached the disk")
        let logos = await loader.savedArtworkFiles(for: [film], type: "Logo")
        XCTAssertEqual(logos.count, 1, "the title logo a Home hero draws")
        let none = await loader.savedArtworkFiles(for: [plain])
        XCTAssertTrue(none.isEmpty, "nothing is asked for an item with no artwork")
        let settled = await CoreWait.until { self.index.artworkBytes >= Int64(png.count) * 5 }
        XCTAssertTrue(settled, "Settings is told how much the pictures take: \(index.artworkBytes)")

        let asked = Set(pictures.requests.map(\.path))
        XCTAssertTrue(asked.isSuperset(of: [
            "/Items/\(film)/Images/Primary", "/Items/\(film)/Images/Logo", "/Items/\(film)/Images/Backdrop",
            "/Items/\(show)/Images/Primary", "/Items/\(episode)/Images/Primary",
        ]), "\(asked)")
        XCTAssertFalse(asked.contains("/Items/\(plain)/Images/Primary"))
        #if os(iOS)
        // Music is not in the copy, but its album covers are saved with the rest.
        let covers = await CoreWait.until { await loader.savedArtworkFiles(for: [album]).count == 1 }
        XCTAssertTrue(covers, "the album cover was not saved")
        #endif

        // A second sync fetches none of them again.
        let before = pictures.requests.count
        await index.sync(force: true)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(pictures.requests.count, before, "what is on disk is not fetched twice")

        // The film leaves the server: its pictures leave the disk.
        server.update(movies.Id) { $0.removeAll { $0.Id == film } }
        await index.sync(force: true)
        let gone = await CoreWait.until {
            let poster = await loader.savedArtworkFiles(for: [film])
            let backdrop = await loader.savedArtworkFiles(for: [film], type: "Backdrop")
            return poster.isEmpty && backdrop.isEmpty
        }
        XCTAssertTrue(gone, "a removed film kept its artwork")
        let kept = await loader.savedArtworkFiles(for: [show, episode])
        XCTAssertEqual(kept.count, 2)
        await loader.forgetDiskArtwork(for: [show, episode, album])
    }

    // MARK: Search

    func testSearchPutsExactThenPrefixThenContainsAndFilmsBeforeEpisodes() async {
        await load()
        XCTAssertEqual(index.search("heat", limit: 10)?.map(\.Id), ["m-heat", "m-heatwave", "m-preheat", "e2-1"],
                       "\"play heat\" is the film, not the film called Heat Wave, nor the episode called Heat")
        XCTAssertEqual(index.search("  HEAT ", limit: 2)?.map(\.Id), ["m-heat", "m-heatwave"], "trimmed, any case, and no more than asked")
    }

    func testSearchFindsEpisodesByTheirShowLast() async {
        await load()
        XCTAssertEqual(index.search("wire", limit: 10)?.map(\.Id), ["show", "e2-1", "e1-2", "e1-1"],
                       "the show itself, then its episodes by name")
    }

    func testSearchLeavesOutSeasonsAndAnswersEmptyForNothing() async {
        await load()
        XCTAssertEqual(index.search("season", limit: 10)?.map(\.Id), [])
        XCTAssertEqual(index.search("   ", limit: 10)?.map(\.Id), [])
        XCTAssertEqual(index.search("zzz", limit: 10)?.map(\.Id), [])
    }

    // MARK: A show's page

    func testSeasonsAndEpisodesComeBackInOrder() async {
        await load()
        XCTAssertEqual(index.seasons(seriesId: "show")?.map(\.Id), ["s1", "s2"])
        XCTAssertEqual(index.episodes(seriesId: "show", seasonId: "s1")?.map(\.Id), ["e1-1", "e1-2"])
        XCTAssertEqual(index.episodes(seriesId: "show", seasonId: nil)?.map(\.Id), ["e1-1", "e1-2", "e2-1"])
        XCTAssertNil(index.seasons(seriesId: "show-done"), "nil, not empty, where the copy has nothing: the server is asked")
        XCTAssertNil(index.episodes(seriesId: "show", seasonId: "nope"))
    }

    // MARK: A library grid

    func testGridSortsByNameTheWayTheServerDoes() async {
        await load()
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query())),
                       ["m-alien", "m-heat", "m-heatwave", "m-preheat", "m-thing"])
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query { $0.sortOrder = "Descending" })),
                       ["m-thing", "m-preheat", "m-heatwave", "m-heat", "m-alien"])
    }

    func testGridSortsByOtherFieldsWithMissingValuesLast() async {
        await load()
        func order(_ field: String, _ direction: String) -> [String]? {
            ids(index.libraryItems(parentId: movies.Id, query: query {
                $0.sortBy = field
                $0.sortOrder = direction
            }))
        }
        XCTAssertEqual(order("DateCreated", "Descending"), ["m-heat", "m-alien", "m-heatwave", "m-preheat", "m-thing"])
        XCTAssertEqual(order("DateCreated", "Ascending"), ["m-preheat", "m-heatwave", "m-alien", "m-heat", "m-thing"],
                       "no date goes last whichever way the list runs")
        XCTAssertEqual(order("CommunityRating", "Descending"), ["m-alien", "m-heat", "m-heatwave", "m-preheat", "m-thing"])
        XCTAssertEqual(order("Runtime", "Ascending"), ["m-preheat", "m-heatwave", "m-alien", "m-heat", "m-thing"])
        XCTAssertEqual(order("PremiereDate", "Ascending"), ["m-alien", "m-heat", "m-heatwave", "m-preheat", "m-thing"],
                       "the two with no premiere date last, by name")
    }

    func testGridFilters() async {
        await load()
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query { $0.unwatched = true })),
                       ["m-alien", "m-heatwave", "m-preheat", "m-thing"])
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query { $0.favorites = true })), ["m-alien", "m-heat"])
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query { $0.genre = "Horror" })), ["m-alien", "m-thing"])
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query {
            $0.genre = "Drama"
            $0.unwatched = true
        })), ["m-heatwave"])
        XCTAssertEqual(ids(index.libraryItems(parentId: shows.Id, query: query {
            $0.includeTypes = "Series"
            $0.unwatched = true
        })), ["show"], "a show is unwatched while it has episodes left, whatever its own flag says")
        XCTAssertEqual(ids(index.libraryItems(parentId: shows.Id, query: query { $0.includeTypes = "Series,Season" })),
                       ["show-done", "s1", "s2", "show"], "only the kinds asked for, in name order")
    }

    func testGridPages() async {
        await load()
        let first = index.libraryItems(parentId: movies.Id, query: query { $0.limit = 2 })
        XCTAssertEqual(ids(first), ["m-alien", "m-heat"])
        XCTAssertEqual(first?.total, 5)
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query {
            $0.startIndex = 4
            $0.limit = 2
        })), ["m-thing"])
        let past = index.libraryItems(parentId: movies.Id, query: query { $0.startIndex = 40 })
        XCTAssertEqual(ids(past), [])
        XCTAssertEqual(past?.total, 5)
    }

    func testNameLessThanCountsWhereALetterStarts() async {
        await load()
        let beforeP = index.libraryItems(parentId: movies.Id, query: query {
            $0.nameLessThan = "P"
            $0.limit = 1
        })
        XCTAssertEqual(beforeP?.total, 3, "alien, heat, heat wave sort before p")
        XCTAssertEqual(index.libraryItems(parentId: movies.Id, query: query { $0.nameLessThan = "a" })?.total, 0)
        XCTAssertEqual(index.libraryItems(parentId: movies.Id, query: query { $0.nameLessThan = "u" })?.total, 5,
                       "The Thing is filed under t, its sort name")
    }

    func testAGridWithNoKindsNamedIsOnlyAnsweredOffline() async {
        await load()
        var open = JellyfinClient.LibraryQuery()
        open.includeTypes = nil
        XCTAssertNil(index.libraryItems(parentId: shows.Id, query: open), "online, the server lists a mixed library by folder")
        XCTAssertNil(index.libraryItems(parentId: movies.Id, query: query { $0.includeTypes = "Movie,PhotoAlbum" }),
                     "photo albums are not in the copy")
        XCTAssertNil(index.libraryItems(parentId: "not-a-library", query: query()))

        await CoreAccount.goOffline()
        XCTAssertTrue(JellyfinClient.shared.isOffline)
        XCTAssertEqual(ids(index.libraryItems(parentId: shows.Id, query: open)), ["show-done", "show"],
                       "films, shows and loose videos; not seasons or episodes")
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: query { $0.includeTypes = "Movie,PhotoAlbum" }))?.count, 5)
    }

    func testTheClientAnswersAGridFromTheCopy() async throws {
        await load()
        RoutedStub.route { [server] in server!.handle($0) }
        let response = try await JellyfinClient.shared.libraryItems(parentId: movies.Id, query: query { $0.limit = 3 })
        XCTAssertEqual(response.items.map(\.Id), ["m-alien", "m-heat", "m-heatwave"])
        XCTAssertTrue(itemsRequests().isEmpty, "no request: the copy had the answer")
    }

    func testRandomIsDrawnAfreshForAFirstPageAndHeldForTheRest() async {
        let many = (0..<30).map { CoreItem.movie(String(format: "m%02d", $0)) }
        await load(films: many, television: [])
        func page(_ start: Int) -> [String] {
            ids(index.libraryItems(parentId: movies.Id, query: query {
                $0.sortBy = "Random"
                $0.startIndex = start
                $0.limit = 10
            })) ?? []
        }
        let whole = page(0) + page(10) + page(20)
        XCTAssertEqual(Set(whole).count, 30, "pages after the first continue the same draw: nothing twice, nothing skipped")

        let first = page(0)
        let redraws = (0..<6).map { _ in page(0) }
        XCTAssertTrue(redraws.contains { $0 != first }, "every first page is a new draw")
    }

    // MARK: Favourites

    func testFavouritesComeFromEveryLibrary() async {
        await load()
        server.update(shows.Id) { list in
            if let i = list.firstIndex(where: { $0.Id == "show" }) { list[i].UserData = CoreItem.userData(favorite: true, unplayed: 2) }
        }
        await index.sync(force: true)
        let all = index.favorites(startIndex: 0, limit: 10, includeTypes: "Movie,Series", sortBy: "SortName", sortOrder: "Ascending")
        XCTAssertEqual(ids(all), ["m-alien", "m-heat", "show"])
        let films = index.favorites(startIndex: 1, limit: 10, includeTypes: "Movie", sortBy: "SortName", sortOrder: "Descending")
        XCTAssertEqual(ids(films), ["m-alien"])
        XCTAssertEqual(films?.total, 2)
    }

    // MARK: Changes made here

    func testAChangeMadeHereShowsAtOnceInGridsAlreadySorted() async {
        await load()
        let unwatched = query { $0.unwatched = true }
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: unwatched))?.contains("m-thing"), true)
        _ = index.favorites(startIndex: 0, limit: 10, includeTypes: "Movie", sortBy: "SortName", sortOrder: "Ascending")

        index.patchUserData("m-thing") {
            $0.Played = true
            $0.IsFavorite = true
        }
        XCTAssertEqual(index.item("m-thing")?.userData.played, true)
        XCTAssertEqual(ids(index.libraryItems(parentId: movies.Id, query: unwatched))?.contains("m-thing"), false,
                       "the cached order is thrown away with the change")
        XCTAssertEqual(ids(index.favorites(startIndex: 0, limit: 10, includeTypes: "Movie", sortBy: "SortName", sortOrder: "Ascending")),
                       ["m-alien", "m-heat", "m-thing"])

        index.patchUserData("no-such-item") { $0.Played = true }
        XCTAssertNil(index.item("no-such-item"))
    }

    func testMarkingAFavouriteThroughTheClientReachesTheCopy() async throws {
        await load()
        StubURLProtocol.stub("/UserFavoriteItems/m-preheat", method: "POST", json: "{}")
        RoutedStub.route(nil)   // the plain stub answers this one
        try await JellyfinClient.shared.setFavorite("m-preheat", favorite: true)
        XCTAssertEqual(index.item("m-preheat")?.userData.isFavorite, true)
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/UserFavoriteItems/m-preheat" })
    }

    // MARK: Home

    func testHomeIsHandedBackAsItWasKeptBeforeTheCopyIsRead() {
        let film = CoreItem.movie("m-heatwave") { $0.UserData = CoreItem.userData(position: 100) }
        index.keepHome(sections: [.resume, .nextUp, .latest], resume: [film], nextUp: [], latest: [(movies, [film])], hero: [film])
        XCTAssertTrue(index.hasHomeCopy)
        let copy = index.homeCopy()
        XCTAssertEqual(copy?.sections, ["resume", "nextUp", "latest"])
        XCTAssertEqual(copy?.resume, [film])
        XCTAssertEqual(copy?.latest.first?.library.Id, movies.Id)
        XCTAssertEqual(copy?.hero, [film])
    }

    func testHomeFollowsTheCopysWatchedState() async {
        await load()
        // As Home last drew them: all three part-watched or up next.
        let heat = CoreItem.movie("m-heat") { $0.UserData = CoreItem.userData(position: 50) }       // finished since
        let alien = CoreItem.movie("m-alien") { $0.UserData = CoreItem.userData(position: 50) }     // further along since
        let wave = CoreItem.movie("m-heatwave") { $0.UserData = CoreItem.userData(position: 70) }   // the copy holds no position
        let seen = CoreItem.episode("e1-1", series: "show", season: "s1", s: 1, e: 1)
        let next = CoreItem.episode("e1-2", series: "show", season: "s1", s: 1, e: 2)
        let stranger = CoreItem.movie("m-elsewhere") { $0.UserData = CoreItem.userData(position: 9) }
        index.keepHome(sections: [.resume], resume: [heat, alien, wave, stranger], nextUp: [seen, next],
                       latest: [(movies, [heat, wave])], hero: [alien])

        let copy = index.homeCopy()
        XCTAssertEqual(copy?.resume.map(\.Id), ["m-alien", "m-heatwave", "m-elsewhere"], "finished since: out of Continue Watching")
        XCTAssertEqual(copy?.resume.first?.userData.positionTicks, 6_000_000_000, "further along: says so")
        XCTAssertEqual(copy?.resume[1].userData.positionTicks, 70, "a copy that was never told keeps Home's own position")
        XCTAssertEqual(copy?.resume[2].userData.positionTicks, 9, "and so does an item the copy does not hold")
        XCTAssertEqual(copy?.nextUp.map(\.Id), ["e1-2"])
        XCTAssertEqual(copy?.latest.first?.items.map(\.Id), ["m-heat", "m-heatwave"], "a latest row keeps what is finished")
        XCTAssertEqual(copy?.latest.first?.items.first?.userData.played, true)
        XCTAssertEqual(copy?.hero.first?.userData.positionTicks, 6_000_000_000)
    }

    func testHomeAndLibrariesAreNeverShownToAnotherAccount() async {
        index.keepHome(sections: [.resume], resume: films, nextUp: [], latest: [], hero: [])
        index.keepLibraries(video: [movies, shows], music: [music], books: [], liveTV: true)
        XCTAssertEqual(index.savedLibraries?.video.map(\.Id), [movies.Id, shows.Id])
        XCTAssertEqual(index.savedLibraries?.music.map(\.Id), [music.Id])
        XCTAssertEqual(index.savedLibraries?.liveTV, true)

        // Someone else signs in on this device.
        await CoreAccount.signOut()
        CoreAccount.signIn()
        XCTAssertNil(index.homeCopy())
        XCTAssertNil(index.savedLibraries)
    }

    // MARK: The media bar

    func testSpotlightOffersOnlyFilmsAndShowsWithABackdrop() async {
        await load()
        for _ in 0..<5 {
            XCTAssertEqual(Set(index.spotlight(limit: 10)?.map(\.Id) ?? []), ["m-heat", "show"])
        }
        XCTAssertEqual(index.spotlight(limit: 1)?.count, 1)
    }

    func testSpotlightIsNilWhenNothingHasABackdrop() async {
        await load(films: [CoreItem.movie("plain")], television: [])
        XCTAssertNil(index.spotlight(limit: 3))
    }
}
