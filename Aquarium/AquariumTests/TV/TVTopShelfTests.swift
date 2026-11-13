//  The Top Shelf: what the app writes into the shared group container
//  (`TopShelf` in Core/TopShelfStore.swift) and the snapshot both sides read
//  (Shared/TopShelfSnapshot.swift). The extension's own provider runs in its
//  own process and only turns the snapshot into cells; on a real home screen
//  it is a manual check (MANUAL.md).
//
//  Poster downloads go through `URLSession.shared`, so `StubURLProtocol` is
//  registered globally for these tests, and the session is the stub account
//  (`ClientStub`), whose server is `http://stub.invalid`.

#if os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class TVTopShelfTests: TVUnitTestCase {
    private var directory: URL!
    private var manifest: URL!
    private var images: URL!

    override func setUp() async throws {
        guard let dir = TopShelfPaths.directory, let man = TopShelfPaths.manifest, let img = TopShelfPaths.images else {
            throw XCTSkip("no app group container in this build (group.scottai.FellyJin not entitled)")
        }
        directory = dir
        manifest = man
        images = img
        ClientStub.install()
        URLProtocol.registerClass(StubURLProtocol.self)
        await drainPendingClears()
    }

    /// `TopShelf.clear()` runs in a task of its own, and a sign-out (the
    /// stub account removed by the last test) starts one. Left alone it lands
    /// in the middle of the next test's publish and empties the shelf. So a
    /// clear of our own is sent and waited for: it queues behind any pending.
    private func drainPendingClears() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TopShelf.clear()
        let gone = expectation(for: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: self.directory.path) },
                               evaluatedWith: nil)
        await fulfillment(of: [gone], timeout: 10)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        ClientStub.remove()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Helpers

    private func episode(_ n: Int, series: String = "Show", progress: Double? = nil, tag: String? = nil) -> BaseItem {
        var item = BaseItem()
        item.Id = "ep\(n)"
        item.Name = "Episode \(n)"
        item.type = "Episode"
        item.SeriesId = "series\(n)"
        item.SeriesName = "\(series) \(n)"
        item.SeriesPrimaryImageTag = tag ?? "tag\(n)"
        item.RunTimeTicks = 600 * 10_000_000
        if let progress {
            item.UserData = UserData(PlaybackPositionTicks: Int64(progress * 600 * 10_000_000))
        }
        return item
    }

    private func stubPoster(seriesId: String, status: Int = 200) {
        StubURLProtocol.stub("/Items/\(seriesId)/Images/Primary",
                             StubURLProtocol.Response(status: status, headers: ["Content-Type": "image/jpeg"],
                                                      body: Data("jpeg-\(seriesId)".utf8)))
    }

    private func readSnapshot() throws -> TopShelfSnapshot {
        try JSONDecoder().decode(TopShelfSnapshot.self, from: Data(contentsOf: manifest))
    }

    private func posterRequests() -> [URLRequest] {
        StubURLProtocol.requests.filter { $0.url?.path.hasSuffix("/Images/Primary") == true }
    }

    // MARK: Publishing

    func testPublishWritesTheSeriesPostersAndManifest() async throws {
        let items = [episode(1, progress: 0.25), episode(2)]
        items.forEach { stubPoster(seriesId: $0.SeriesId!) }
        await TopShelf.publish(items)

        let snapshot = try readSnapshot()
        XCTAssertEqual(snapshot.entries.map(\.id), ["ep1", "ep2"], "the episode id, which the link carries back")
        XCTAssertEqual(snapshot.entries.map(\.title), ["Show 1", "Show 2"], "the series name under a series poster")
        XCTAssertEqual(snapshot.entries.map(\.image), ["series1-tag1.jpg", "series2-tag2.jpg"])
        guard snapshot.entries.count == 2 else { return }
        XCTAssertEqual(snapshot.entries[0].progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.entries[1].progress, 0, "not started")
        XCTAssertLessThan(abs(snapshot.generated.timeIntervalSinceNow), 60)
        for entry in snapshot.entries {
            let data = try Data(contentsOf: images.appendingPathComponent(entry.image))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "jpeg-series\(entry.id.dropFirst(2))")
        }
    }

    func testPosterIsTheSeriesNotTheEpisodeStill() async throws {
        // A 16:9 still in a 2:3 cell: the reason `posterURL` asks for the
        // series first (see TopShelfStore.swift).
        let item = episode(3)
        stubPoster(seriesId: "series3")
        await TopShelf.publish([item])
        let request = try XCTUnwrap(posterRequests().first)
        XCTAssertEqual(request.url?.path, "/Items/series3/Images/Primary")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "tag" }?.value, "tag3")
        XCTAssertGreaterThanOrEqual(Int(query.first { $0.name == "maxWidth" }?.value ?? "") ?? 0, 400,
                                    "at least 400 px: twice the cell for a 2x screen")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no token goes with a poster fetch")
    }

    func testAtMostTenPosters() async throws {
        let items = (1...14).map { episode($0) }
        items.forEach { stubPoster(seriesId: $0.SeriesId!) }
        await TopShelf.publish(items)
        XCTAssertEqual(try readSnapshot().entries.count, 10)
        XCTAssertEqual(posterRequests().count, 10, "nothing fetched past the tenth")
    }

    func testAPosterThatFailsLeavesItsEntryOut() async throws {
        stubPoster(seriesId: "series1")
        stubPoster(seriesId: "series2", status: 404)
        await TopShelf.publish([episode(1), episode(2)])
        XCTAssertEqual(try readSnapshot().entries.map(\.id), ["ep1"], "a cell with no picture is worse than none")
    }

    func testAnItemWithNoArtworkAtAllIsLeftOut() async throws {
        var bare = BaseItem()
        bare.Id = "film"
        bare.Name = "No Art"
        bare.type = "Movie"
        stubPoster(seriesId: "series1")
        await TopShelf.publish([bare, episode(1)])
        XCTAssertEqual(try readSnapshot().entries.map(\.id), ["ep1"])
    }

    func testAPosterAlreadyOnDiskIsNotFetchedAgain() async throws {
        stubPoster(seriesId: "series1")
        await TopShelf.publish([episode(1)])
        XCTAssertEqual(posterRequests().count, 1)
        StubURLProtocol.reset()
        stubPoster(seriesId: "series1")
        await TopShelf.publish([episode(1, progress: 0.5)])
        XCTAssertEqual(posterRequests().count, 0, "same tag, same file")
        XCTAssertEqual(try readSnapshot().entries.first?.progress ?? 0, 0.5, accuracy: 0.001, "the manifest still moves on")
    }

    func testChangedArtworkArrivesUnderANewNameAndTheOldOneIsSwept() async throws {
        stubPoster(seriesId: "series1")
        await TopShelf.publish([episode(1, tag: "old")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.appendingPathComponent("series1-old.jpg").path))
        await TopShelf.publish([episode(1, tag: "new")])
        let files = try FileManager.default.contentsOfDirectory(atPath: images.path)
        XCTAssertEqual(files, ["series1-new.jpg"], "posters the shelf no longer names are pruned")
    }

    func testIdsFromTheServerCannotEscapeTheImagesFolder() async throws {
        var item = episode(1)
        item.SeriesId = "../../evil"
        item.SeriesPrimaryImageTag = "a/b"
        StubURLProtocol.stub("/Items/..%2F..%2Fevil/Images/Primary", StubURLProtocol.Response(body: Data("x".utf8)))
        // Whatever path the stub sees, nothing may be written outside `images`.
        await TopShelf.publish([item])
        let parent = images.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertEqual(Set(siblings).subtracting(["images", "nextup.json"]), [], "something was written beside the images")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [] {
            XCTAssertFalse(name.contains("/"))
            XCTAssertFalse(name.hasPrefix(".."))
        }
    }

    func testSignedOutPublishesNothing() async throws {
        ClientStub.remove()
        stubPoster(seriesId: "series1")
        await TopShelf.publish([episode(1)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        ClientStub.install()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    func testClearTakesTheShelfAway() async throws {
        stubPoster(seriesId: "series1")
        await TopShelf.publish([episode(1)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        TopShelf.clear()
        let gone = expectation(for: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: self.directory.path) },
                               evaluatedWith: nil)
        await fulfillment(of: [gone], timeout: 10)
    }

    func testRefreshAsksNextUpAndPublishesIt() async throws {
        StubURLProtocol.stub("/Shows/NextUp", json: """
        {"Items":[{"Id":"ep9","Name":"E9","Type":"Episode","SeriesId":"series9","SeriesName":"Refreshed",
                   "SeriesPrimaryImageTag":"t9","UserData":{"Played":false}}],"TotalRecordCount":1}
        """)
        stubPoster(seriesId: "series9")
        await TopShelf.refresh()
        let snapshot = try readSnapshot()
        XCTAssertEqual(snapshot.entries.map(\.title), ["Refreshed"])
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.url?.path == "/Shows/NextUp" })
    }

    // MARK: The snapshot both processes read

    func testSnapshotRoundTripsAndKeepsItsKeys() throws {
        let snapshot = TopShelfSnapshot(entries: [.init(id: "a", title: "T", image: "a-t.jpg", progress: 0.4)],
                                        generated: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["entries", "generated"])
        let entry = try XCTUnwrap((json["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["id", "title", "image", "progress"],
                       "the extension decodes these names; renaming one empties the shelf")
        let back = try JSONDecoder().decode(TopShelfSnapshot.self, from: data)
        XCTAssertEqual(back.entries.first?.image, "a-t.jpg")
        XCTAssertEqual(back.generated, snapshot.generated)
    }

    func testPathsAndLinks() throws {
        XCTAssertEqual(TopShelfPaths.appGroup, "group.scottai.FellyJin")
        XCTAssertEqual(manifest.lastPathComponent, "nextup.json")
        XCTAssertEqual(images.lastPathComponent, "images")
        XCTAssertEqual(manifest.deletingLastPathComponent(), directory)
        XCTAssertEqual(TopShelfPaths.link("item", "abc")?.absoluteString, "aquarium://item/abc")
        XCTAssertEqual(TopShelfPaths.link("play", "abc")?.absoluteString, "aquarium://play/abc")
        XCTAssertTrue(AppModel.linkSchemes.contains("aquarium"))
        XCTAssertTrue(AppModel.linkSchemes.contains("fellyjin"), "shelves written before the rename")
    }

    func testTheAppDeclaresTheSchemeTheShelfLinksUse() throws {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("aquarium"), "a shelf cell's link would open nothing")
    }

    func testTheExtensionShipsInsideTheApp() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let appex = plugins.appendingPathComponent("TopShelf.appex")
        let bundle = try XCTUnwrap(Bundle(url: appex), "TopShelf.appex is not embedded")
        let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        XCTAssertEqual(ext?["NSExtensionPointIdentifier"] as? String, "com.apple.tv-top-shelf")
        XCTAssertEqual((ext?["NSExtensionPrincipalClass"] as? String)?.hasSuffix("TopShelfProvider"), true)
    }
}
#endif
