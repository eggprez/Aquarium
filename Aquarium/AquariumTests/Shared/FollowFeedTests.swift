//  What the Follow widget is given to draw: `FollowSnapshot` and the widget's
//  configuration query (Shared/FollowTypes.swift), and `FollowFeed`, which
//  writes the snapshot from Home's rows.
//
//  iPhone and iPad only, where the widget is. The snapshot lives in the app
//  group container, which test mode does not keep apart, so what was there is
//  put back afterwards. Posters are served from this machine's loopback
//  address; the favourites request goes through the client's stub.

#if os(iOS)
import XCTest
@testable import Aquarium

/// The app group's snapshot, saved before a test and put back after.
@MainActor
private enum FollowFixture {
    private static var saved: FollowSnapshot?

    static func begin() throws {
        try XCTSkipIf(FollowSnapshot.artworkFile(for: "probe") == nil, "this build has no app group container")
        saved = FollowSnapshot.read()
        FollowFeed.shared.wipe()
    }

    static func end() {
        FollowFeed.shared.wipe()
        if let saved { FollowSnapshot.write(saved) }
        saved = nil
    }

    static func entry(_ id: String, title: String = "T", subtitle: String = "S", hasArtwork: Bool = false) -> FollowSnapshot.Entry {
        FollowSnapshot.Entry(id: id, title: title, subtitle: subtitle, fraction: nil, linkId: id, isSeries: false, hasArtwork: hasArtwork)
    }
}

// MARK: - The snapshot and the widget's choices

@MainActor
final class FollowSnapshotTests: XCTestCase {
    override func setUp() async throws { try FollowFixture.begin() }
    override func tearDown() async throws { FollowFixture.end() }

    func testASnapshotIsReadBackAsItWasWritten() throws {
        XCTAssertNil(FollowSnapshot.read(), "nothing to follow after a wipe")
        let entries = [
            FollowSnapshot.Entry(id: "show", title: "The Wire", subtitle: "Season 1: Episode 2 · 30 min left", fraction: 0.5,
                                 linkId: "episode", isSeries: true, hasArtwork: true),
            FollowFixture.entry("film", title: "Heat", subtitle: "Favorite"),
        ]
        let written = FollowSnapshot(entries: entries)
        FollowSnapshot.write(written)
        let read = try XCTUnwrap(FollowSnapshot.read())
        XCTAssertEqual(read.entries, entries)
        XCTAssertEqual(read.updatedAt.timeIntervalSince1970, written.updatedAt.timeIntervalSince1970, accuracy: 0.001)

        FollowSnapshot.write(nil)
        XCTAssertNil(FollowSnapshot.read())
        FollowSnapshot.write(nil)   // nothing there to remove: not an error
    }

    func testAPosterIsFiledUnderACleanedId() throws {
        let plain = try XCTUnwrap(FollowSnapshot.artworkFile(for: "0123abcd-ef"))
        XCTAssertEqual(plain.lastPathComponent, "follow-0123abcd-ef.jpg")
        let hostile = try XCTUnwrap(FollowSnapshot.artworkFile(for: "../../etc/pass wd?x=1"))
        XCTAssertEqual(hostile.lastPathComponent, "follow-etcpasswdx1.jpg", "an id can never name a file outside the folder")
        XCTAssertEqual(hostile.deletingLastPathComponent().path, plain.deletingLastPathComponent().path)
    }

    func testPruningKeepsOnlyThePostersStillFollowed() throws {
        let keep = try XCTUnwrap(FollowSnapshot.artworkFile(for: "keep"))
        let drop = try XCTUnwrap(FollowSnapshot.artworkFile(for: "drop"))
        let folder = keep.deletingLastPathComponent()
        let bystander = folder.appendingPathComponent("unit-test-bystander.jpg")
        let nearMiss = folder.appendingPathComponent("follow-notes.txt")
        for file in [keep, drop, bystander, nearMiss] { try Data([1, 2, 3]).write(to: file) }
        defer { for file in [bystander, nearMiss] { try? FileManager.default.removeItem(at: file) } }

        FollowSnapshot.pruneArtwork(keeping: ["keep", "never-saved"])
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        XCTAssertFalse(fm.fileExists(atPath: drop.path))
        XCTAssertTrue(fm.fileExists(atPath: bystander.path), "only this widget's posters are its to delete")
        XCTAssertTrue(fm.fileExists(atPath: nearMiss.path))

        FollowSnapshot.pruneArtwork(keeping: [])
        XCTAssertFalse(fm.fileExists(atPath: keep.path))
    }

    func testTheWidgetsChoicesComeFromTheSnapshot() async throws {
        let query = FollowableQuery()
        var suggested = try await query.suggestedEntities()
        XCTAssertTrue(suggested.isEmpty, "no snapshot, nothing to pick")
        var found = try await query.entities(for: ["a"])
        XCTAssertTrue(found.isEmpty)

        FollowSnapshot.write(FollowSnapshot(entries: [
            FollowFixture.entry("a", title: "Alien", subtitle: "42 min left"),
            FollowFixture.entry("b", title: "Brazil", subtitle: "Favorite"),
            FollowFixture.entry("c", title: "Casablanca", subtitle: "Favorite"),
        ]))
        suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(suggested.map(\.title), ["Alien", "Brazil", "Casablanca"])
        XCTAssertEqual(suggested.first?.subtitle, "42 min left")

        found = try await query.entities(for: ["c", "gone", "a"])
        XCTAssertEqual(found.map(\.id), ["c", "a"], "in the order asked, without what is no longer followed")
        let fallback = await query.defaultResult()
        XCTAssertNil(fallback, "an unconfigured tile follows whatever is first, not a fixed title")
    }

    func testTheConfigurationIntentCarriesTheChosenTitle() {
        XCTAssertNil(FollowTitleIntent().title)
        let entity = FollowableEntity(FollowFixture.entry("a", title: "Alien", subtitle: "42 min left"))
        let intent = FollowTitleIntent(title: entity)
        XCTAssertEqual(intent.title?.id, "a")
        XCTAssertEqual(intent.title?.title, "Alien")
        XCTAssertEqual(FollowSnapshot.widgetKind, "scottai.FellyJin.follow")
    }
}

// MARK: - The feed

@MainActor
final class FollowFeedTests: XCTestCase {
    private var server: LoopbackServer!
    private let feed = FollowFeed.shared

    override func setUp() async throws {
        try FollowFixture.begin()
        run = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        server = try LoopbackServer()
        let poster = CorePicture.png(width: 600, height: 900)
        server.setHandler { request in
            request.path.hasSuffix("/Images/Primary") && !request.path.contains("no-poster")
                ? .data(poster, type: "image/png") : .status(404)
        }
        // Artwork addresses point at the loopback server; the client's own
        // requests are answered by the stub.
        CoreAccount.signIn(server: server.base)
        await CoreAccount.goOnline()
        stubFavorites([])
    }

    override func tearDown() async throws {
        FollowFixture.end()
        await CoreAccount.signOut()
        server.stop()
    }

    private func stubFavorites(_ items: [BaseItem]) {
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json(items)))
    }

    private var favoriteRequests: Int {
        StubURLProtocol.requests.filter { $0.url?.path == "/Items" && ($0.url?.query ?? "").contains("IsFavorite") }.count
    }

    /// The snapshot once the feed has written one with `count` entries.
    private func written(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async -> [FollowSnapshot.Entry] {
        let arrived = await CoreWait.until { FollowSnapshot.read()?.entries.count == count }
        XCTAssertTrue(arrived, "the feed never wrote \(count) entries (it wrote \(FollowSnapshot.read()?.entries.count ?? -1))", file: file, line: line)
        return FollowSnapshot.read()?.entries ?? []
    }

    private let minute: Int64 = 600_000_000

    /// Ids of this run's own for anything with a poster. The image loader
    /// answers a request from a copy it already holds of the same item, image
    /// and tag, whatever address it came from — so a second run of a test in
    /// one process (`-test-iterations`) would otherwise be handed the first
    /// run's picture and never ask this run's server.
    private var run = ""

    func testAPartWatchedFilmSaysHowMuchIsLeft() async {
        let film = CoreItem.movie("film", name: "Heat") {
            $0.RunTimeTicks = 100 * 600_000_000
            $0.UserData = CoreItem.userData(position: 58 * 600_000_000)
        }
        feed.update(resume: [film], nextUp: [])
        let entry = await written(1).first
        XCTAssertEqual(entry?.id, "film")
        XCTAssertEqual(entry?.linkId, "film")
        XCTAssertEqual(entry?.title, "Heat")
        XCTAssertEqual(entry?.subtitle, "42 min left")
        XCTAssertEqual(entry?.fraction ?? 0, 0.58, accuracy: 0.001)
        XCTAssertEqual(entry?.isSeries, false)
        XCTAssertEqual(entry?.hasArtwork, false, "no image tag, no poster")
    }

    func testAnEpisodeIsFollowedAsItsShow() async {
        let episode = CoreItem.episode("ep7", series: "show", season: "s2", s: 2, e: 3, name: "Hot Shots", seriesName: "The Wire") {
            $0.RunTimeTicks = 60 * 600_000_000
            $0.UserData = CoreItem.userData(position: 30 * 600_000_000)
        }
        // The same show is also up next: one tile, the part-watched one.
        let next = CoreItem.episode("ep8", series: "show", season: "s2", s: 2, e: 4, seriesName: "The Wire")
        let other = CoreItem.episode("x1", series: "other", season: "o1", s: 0, e: 1, name: "Pilot", seriesName: "Other Show")
        feed.update(resume: [episode], nextUp: [next, other])
        let entries = await written(2)
        XCTAssertEqual(entries.map(\.id), ["show", "other"], "a tile set to a show keeps following it as the episodes go by")
        XCTAssertEqual(entries.map(\.linkId), ["ep7", "x1"], "a tap opens the episode")
        XCTAssertEqual(entries.map(\.title), ["The Wire", "Other Show"])
        XCTAssertEqual(entries.map(\.isSeries), [true, true])
        XCTAssertEqual(entries[0].subtitle, "Season 2: Episode 3 · 30 min left")
        XCTAssertEqual(entries[0].fraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(entries[1].subtitle, "Specials: Episode 1 · Pilot")
        XCTAssertNil(entries[1].fraction, "nothing to show a playhead for")
    }

    func testTheServersPercentageWinsAndIsCapped() async {
        let byPercent = CoreItem.movie("a") {
            $0.RunTimeTicks = 100 * 600_000_000
            var data = CoreItem.userData(position: 10 * 600_000_000)
            data.PlayedPercentage = 40
            $0.UserData = data
        }
        let over = CoreItem.movie("b") {
            var data = CoreItem.userData()
            data.PlayedPercentage = 140
            $0.UserData = data
        }
        let pastTheEnd = CoreItem.movie("c") {
            $0.RunTimeTicks = 10 * 600_000_000
            $0.UserData = CoreItem.userData(position: 12 * 600_000_000)
        }
        let unknownLength = CoreItem.movie("d") { $0.UserData = CoreItem.userData(position: 5 * 600_000_000) }
        feed.update(resume: [byPercent, over, pastTheEnd, unknownLength], nextUp: [])
        let entries = await written(4)
        XCTAssertEqual(entries[0].fraction ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(entries[0].subtitle, "90 min left")
        XCTAssertEqual(entries[1].fraction, 1)
        XCTAssertEqual(entries[1].subtitle, "Continue watching", "no runtime to count down from")
        XCTAssertEqual(entries[2].fraction, 1)
        XCTAssertEqual(entries[2].subtitle, "Continue watching", "nothing left is not \"0 min left\"")
        XCTAssertNil(entries[3].fraction)
    }

    func testLessThanAMinuteLeftIsStillAMinute() async {
        let film = CoreItem.movie("film") {
            $0.RunTimeTicks = 100 * 600_000_000
            $0.UserData = CoreItem.userData(position: 100 * 600_000_000 - 100_000_000)   // ten seconds from the end
        }
        feed.update(resume: [film], nextUp: [])
        let entry = await written(1).first
        XCTAssertEqual(entry?.subtitle, "1 min left")
    }

    func testSomethingUpNextWithNoEpisodeNumberJustSaysSo() async {
        feed.update(resume: [], nextUp: [CoreItem.movie("loose", name: "Loose Video")])
        let entry = await written(1).first
        XCTAssertEqual(entry?.subtitle, "Up next")
        XCTAssertEqual(entry?.title, "Loose Video")
    }

    func testFavouritesFillInAfterTheRowsAndAreAskedForOnce() async {
        let heat = CoreItem.movie("heat", name: "Heat")
        stubFavorites([heat, CoreItem.series("show", name: "The Wire"), CoreItem.movie("alien", name: "Alien")])
        feed.update(resume: [heat], nextUp: [])
        var entries = await written(3)
        XCTAssertEqual(entries.map(\.id), ["heat", "show", "alien"], "a favourite already in a row is not listed twice")
        XCTAssertEqual(entries.map(\.subtitle), ["Continue watching", "Favorite", "Favorite"])
        XCTAssertEqual(entries[1].isSeries, true)
        XCTAssertEqual(favoriteRequests, 1)
        let asked = StubURLProtocol.requests.last { ($0.url?.query ?? "").contains("IsFavorite") }?.url?.query ?? ""
        XCTAssertTrue(asked.contains("Limit=8"), asked)

        // Home loads often; the favourites are a request of their own.
        feed.update(resume: [CoreItem.movie("solo")], nextUp: [])
        entries = await written(4)
        XCTAssertEqual(entries.map(\.id), ["solo", "heat", "show", "alien"], "the ones already fetched are used again")
        XCTAssertEqual(entries[1].subtitle, "Favorite", "out of Continue Watching, it is still a favourite")
        XCTAssertEqual(favoriteRequests, 1)
    }

    func testNoMoreThanTwentyFourTitles() async {
        let many = (0..<40).map { CoreItem.movie("m\($0)") }
        feed.update(resume: many, nextUp: [])
        let entries = await written(24)
        XCTAssertEqual(entries.map(\.id), (0..<24).map { "m\($0)" })
    }

    func testPostersAreSavedSmallBesideTheSnapshotAndPrunedWithIt() async throws {
        let filmId = "film\(run)", showId = "show\(run)"
        let film = CoreItem.movie(filmId, name: "Heat") { $0.ImageTags = ["Primary": "tagA"] }
        let episode = CoreItem.episode("ep1", series: showId, season: "s1", s: 1, e: 1) { $0.SeriesPrimaryImageTag = "tagS" }
        let missing = CoreItem.movie("no-poster\(run)", name: "Lost") { $0.ImageTags = ["Primary": "tagB"] }
        feed.update(resume: [film, episode, missing], nextUp: [])
        var entries = await written(3)
        XCTAssertEqual(entries.map(\.hasArtwork), [true, true, false], "a poster the server cannot give is no poster")

        let filmPoster = try XCTUnwrap(FollowSnapshot.artworkFile(for: filmId))
        let showPoster = try XCTUnwrap(FollowSnapshot.artworkFile(for: showId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: showPoster.path), "an episode's tile carries its show's poster")
        let saved = try XCTUnwrap(UIImage(data: Data(contentsOf: filmPoster)))
        XCTAssertEqual(max(saved.size.width, saved.size.height) * saved.scale, 300, "saved small: the long side at 300")
        XCTAssertEqual(saved.size.width * saved.scale, 200)
        XCTAssertTrue(server.requests.contains { $0.path == "/Items/\(showId)/Images/Primary" })

        // The film drops out of Home's rows: its poster goes with it.
        feed.update(resume: [episode], nextUp: [])
        entries = await written(1)
        XCTAssertEqual(entries.first?.hasArtwork, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filmPoster.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: showPoster.path))
        XCTAssertEqual(server.requests(to: "/Items/\(showId)/Images/Primary").count, 1, "a poster already saved is kept, not fetched again")
    }

    func testALaterUpdateReplacesAnEarlierOneStillRunning() async {
        feed.update(resume: (0..<10).map { CoreItem.movie("old\($0)") }, nextUp: [])
        feed.update(resume: [CoreItem.movie("new")], nextUp: [])
        let entries = await written(1)
        XCTAssertEqual(entries.map(\.id), ["new"])
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(FollowSnapshot.read()?.entries.map(\.id), ["new"], "the cancelled one never writes over it")
    }

    func testWipeLeavesNothingToFollow() async throws {
        let film = CoreItem.movie("film\(run)") { $0.ImageTags = ["Primary": "tagA"] }
        stubFavorites([CoreItem.movie("fav")])
        feed.update(resume: [film], nextUp: [])
        _ = await written(2)
        let poster = try XCTUnwrap(FollowSnapshot.artworkFile(for: "film\(run)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: poster.path))

        feed.wipe()
        XCTAssertNil(FollowSnapshot.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: poster.path))

        // And the favourites of the account that left are not carried over.
        stubFavorites([])
        feed.update(resume: [CoreItem.movie("solo")], nextUp: [])
        let entries = await written(1)
        XCTAssertEqual(entries.map(\.id), ["solo"])
        XCTAssertEqual(favoriteRequests, 2, "asked afresh for whoever signs in next")
    }

    func testFavouritesAreNotAskedForWithTheServerAway() async {
        await CoreAccount.goOffline()
        stubFavorites([CoreItem.movie("fav")])
        feed.update(resume: [CoreItem.movie("solo")], nextUp: [])
        let entries = await written(1)
        XCTAssertEqual(entries.map(\.id), ["solo"])
        XCTAssertEqual(favoriteRequests, 0)
        await CoreAccount.goOnline()
    }
}
#endif
