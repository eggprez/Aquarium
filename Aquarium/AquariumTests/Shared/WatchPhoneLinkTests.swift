//  The phone's side of the watch link (Core/WatchLink.swift), owned by the
//  Watch suite: the same wire as the watch reads, what the phone makes of
//  the watch's context, the watch's log arriving in pieces, the listening it
//  hands over (kept, de-duplicated and forwarded to the server), and the
//  wants list's statuses. iPhone only: an iPad, a Mac and a TV have no watch.
//
//  WatchConnectivity is not driven: `apply`, `take` are called as the
//  session delegate would. The phone↔watch round trip on a real pair is in
//  WatchUITests/MANUAL.md.

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class WatchPhoneWireTests: XCTestCase {
    /// The same payloads WatchTests/WatchSyncTypesTests.swift decodes on the
    /// watch: one wire for both sides.
    static let golden: [(String, String)] = [
        ("phoneContext", #"{"revision":12,"credentials":{"server":"http://127.0.0.1:8196","userId":"u1","userName":"suite-watch","serverId":"s1","token":"tok"},"mirror":{"bookIds":["b1"],"playlistIds":["p1"],"wants":[{"kind":"album","id":"a1","title":"FX Two Discs"}]},"sentAt":784000000}"#),
        ("watchContext", #"{"revision":3,"inventory":{"groups":[{"id":"a1","kind":"album","title":"FX Two Discs","count":6,"bytes":1000,"complete":4}],"itemCount":4,"totalBytes":1000,"freeBytes":5000,"inFlight":2,"truncated":false},"awaitingPhone":["s5","s6"],"playlistIds":["p1"],"wants":[{"key":"album:a1","count":6,"complete":4,"failed":0,"needsContents":false}],"signedIn":true,"sentAt":784000001}"#),
        ("fetchMany", #"{"fetchMany":{"itemIds":["s5","s6"]}}"#),
        ("progress", #"{"progress":{"_0":[{"id":"7C9A1D5E-3B1F-4F55-9F0D-2E5B6C7D8E9F","itemId":"b1","positionTicks":870000000,"played":false,"isAudiobook":true,"streamed":false,"at":784000002,"accountKey":"http://127.0.0.1:8196|u1"}]}}"#),
        ("deleteWant", #"{"deleteWant":{"_0":{"kind":"artist","id":"ar1","title":"FX Band"}}}"#),
        ("remoteSpeed", #"{"remote":{"_0":{"setSpeed":{"_0":1.25}}}}"#),
        ("reply", #"{"ok":true,"delivered":["7C9A1D5E-3B1F-4F55-9F0D-2E5B6C7D8E9F"]}"#),
    ]

    func testTheWatchsPayloadsDecodeOnThePhone() throws {
        let d = JSONDecoder()
        for (name, json) in Self.golden {
            let data = Data(json.utf8)
            switch name {
            case "phoneContext":
                let c = try d.decode(PhoneContext.self, from: data)
                XCTAssertEqual(c.credentials?.userName, "suite-watch")
                XCTAssertEqual(c.mirror.wants.first?.key, "album:a1")
            case "watchContext":
                let c = try d.decode(WatchContext.self, from: data)
                XCTAssertEqual(c.awaitingPhone, ["s5", "s6"])
                XCTAssertEqual(c.wants?.first?.complete, 4)
            case "reply":
                XCTAssertEqual(try d.decode(WatchReply.self, from: data).delivered?.count, 1)
            default:
                XCTAssertNoThrow(try d.decode(WatchMessage.self, from: data), name)
            }
        }
    }

    func testWhatThePhoneSendsTheWatchCanRead() throws {
        let plan = WatchMirrorPlan(bookIds: ["b"], playlistIds: ["p"], wants: [WatchDownloadRequest(kind: .song, id: "s", title: "S")])
        let context = PhoneContext(revision: 1, credentials: WatchCredentials(server: "http://s", userId: "u", userName: "n", serverId: nil, token: "t"), mirror: plan)
        let packed = WatchSync.pack(context)
        let json = try XCTUnwrap(packed[WatchSync.key] as? Data)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["revision", "credentials", "mirror", "sentAt"], "the keys the watch decodes")
        let messages: [WatchMessage] = [.deleteGroup(kind: .album, id: "a"), .deleteAll, .requestInventory, .requestLogs,
                                        .fetchProgress(itemId: "i", fraction: 0.5), .fetchFailed(itemId: "i", reason: "r"),
                                        .cancelled(itemId: "i"), .phonePlayback(nil)]
        for m in messages { XCTAssertNotNil(WatchSync.unpack(WatchMessage.self, from: WatchSync.pack(m))) }
    }
}

@MainActor
final class WatchPhoneLinkTests: XCTestCase {
    private var link: WatchLink { .shared }

    override func setUp() async throws {
        try XCTSkipUnless(TestRuntime.isUITest, "run with TestPlans/Unit.xctestplan (the host must be in test mode)")
    }

    // MARK: The watch's context

    func testTheWatchsContextBecomesWhatSettingsShows() {
        let group = WatchStorageGroup(id: "a1", kind: .album, title: "A", subtitle: nil, count: 2, bytes: 10, complete: 1)
        let want = WatchWantState(key: "album:a1", count: 2, complete: 1)
        let context = WatchContext(revision: 1, inventory: WatchInventory(groups: [group], itemCount: 1, totalBytes: 10),
                                   awaitingPhone: [], playlistIds: ["p1"], wants: [want], signedIn: true)
        link.apply(WatchSync.pack(context))
        XCTAssertEqual(link.inventory?.groups.map(\.id), ["a1"])
        XCTAssertTrue(link.watchSignedIn)
        XCTAssertEqual(link.watchPlaylistIds, ["p1"])
        XCTAssertEqual(link.wantStates["album:a1"]?.complete, 1)
        XCTAssertNotNil(link.wantsReportedAt)
        XCTAssertTrue(link.keepsOnWatch("p1"))
    }

    func testAnOlderWatchsPlaylistsAreReadFromItsInventory() {
        let list = WatchStorageGroup(id: "p2", kind: .playlist, title: "P", subtitle: nil, count: 1, bytes: 1, complete: 1)
        let context = WatchContext(revision: 1, inventory: WatchInventory(groups: [list]), awaitingPhone: nil, playlistIds: nil, wants: nil, signedIn: false)
        link.apply(WatchSync.pack(context))
        XCTAssertEqual(link.watchPlaylistIds, ["p2"])
        XCTAssertFalse(link.watchSignedIn)
    }

    func testSomethingElseInTheContextIsIgnored() {
        let before = link.inventoryAt
        link.apply(["other": 1])
        XCTAssertEqual(link.inventoryAt, before)
    }

    // MARK: The watch's log, in pieces

    func testTheWatchsLogArrivesInPiecesAndIsKept() throws {
        let text = (0..<2000).map { "line \($0) of the watch's log" }.joined(separator: "\n")
        let packed = try (Data(text.utf8) as NSData).compressed(using: .lzfse) as Data
        let third = packed.count / 3 + 1
        let name = "AquariumWatch-unit-\(UUID().uuidString).log"
        let pieces = stride(from: 0, to: packed.count, by: third).map { packed.subdata(in: $0..<min($0 + third, packed.count)) }
        // Out of order: the second piece first.
        for i in [1, 0, 2] where i < pieces.count {
            link.take(WatchLogChunk(id: name, name: "../../" + name, index: i, count: pieces.count, data: pieces[i]))
        }
        let file = try XCTUnwrap(link.watchLogs.first { $0.lastPathComponent == name }, "kept under its own name, never outside the folder")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        link.deleteWatchLog(file)
        XCTAssertFalse(link.watchLogs.contains(file))
    }

    // MARK: Listening handed over

    private func event(_ item: String, at: Date, played: Bool = false, book: Bool = true) -> WatchProgressEvent {
        WatchProgressEvent(itemId: item, positionTicks: Int64(at.timeIntervalSince1970), played: played, isAudiobook: book, at: at)
    }

    private func pending(_ item: String) -> [WatchProgressEvent] { link.pendingEvents.filter { $0.itemId == item } }

    /// Signed out here, so nothing is forwarded and what is kept can be read.
    func testANewerPlaceReplacesAnOlderOneAndALateOldOneIsDropped() throws {
        try XCTSkipIf(JellyfinClient.shared.isSignedIn, "the host is signed in: events would be forwarded")
        let book = "book-\(UUID().uuidString)"
        let t = Date()
        link.take([event(book, at: t)])
        link.take([event(book, at: t.addingTimeInterval(60))])
        XCTAssertEqual(pending(book).map(\.at), [t.addingTimeInterval(60)])
        link.take([event(book, at: t.addingTimeInterval(-60))])
        XCTAssertEqual(pending(book).map(\.at), [t.addingTimeInterval(60)], "older than one waiting: settled at once")
    }

    func testTheSameEventTwiceIsTakenOnce() throws {
        try XCTSkipIf(JellyfinClient.shared.isSignedIn, "the host is signed in: events would be forwarded")
        let song = "song-\(UUID().uuidString)"
        let e = event(song, at: Date(), played: true, book: false)
        link.take([e])
        link.take([e])
        XCTAssertEqual(pending(song).count, 1)
        link.take([event(song, at: Date(), played: true, book: false)])
        XCTAssertEqual(pending(song).count, 2, "two plays are two plays")
    }

    func testPlacesForDifferentAccountsAreKeptApart() throws {
        try XCTSkipIf(JellyfinClient.shared.isSignedIn, "the host is signed in: events would be forwarded")
        let book = "book-\(UUID().uuidString)"
        var a = event(book, at: Date())
        a.accountKey = "s|a"
        var b = event(book, at: Date().addingTimeInterval(5))
        b.accountKey = "s|b"
        link.take([a, b])
        XCTAssertEqual(Set(pending(book).compactMap(\.accountKey)), ["s|a", "s|b"])
    }

    // MARK: Forwarding to the server (the stub)

    func testAStalePlaceIsDroppedNotSent() async throws {
        ClientStub.install()
        defer { ClientStub.remove() }
        let book = "stale-\(UUID().uuidString)"
        let lastPlayed = ISO8601DateFormatter().string(from: Date())
        StubURLProtocol.stub("/Items", json: #"{"Items":[{"Id":"\#(book)","Type":"AudioBook","RunTimeTicks":36000000000,"UserData":{"PlaybackPositionTicks":100,"LastPlayedDate":"\#(lastPlayed)"}}]}"#)
        link.take([event(book, at: Date().addingTimeInterval(-3600))])
        let end = Date().addingTimeInterval(10)
        while !pending(book).isEmpty, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(pending(book).isEmpty, "settled")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path == "/Sessions/Playing/Stopped" }, "never sent")
    }

    func testASongHeardOnTheWatchIsCountedAsAPlay() async throws {
        ClientStub.install()
        defer { ClientStub.remove() }
        let song = "song-\(UUID().uuidString)"
        StubURLProtocol.stub("/UserPlayedItems/\(song)", method: "POST", json: "{}")
        link.take([event(song, at: Date(), played: true, book: false)])
        let end = Date().addingTimeInterval(10)
        while !pending(song).isEmpty, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(pending(song).isEmpty)
        let post = StubURLProtocol.requests.first { $0.url?.path == "/UserPlayedItems/\(song)" }
        XCTAssertEqual(post?.httpMethod, "POST")
        XCTAssertNotNil(post?.url?.query?.range(of: "datePlayed="), "counted with the date it was heard")
    }

    // MARK: The wants list, as Settings shows it

    func testAWantsStatusReadsFromTheWatchsReport() {
        let album = WatchWant(request: WatchDownloadRequest(kind: .album, id: "a", title: "A"))
        let book = WatchWant(request: WatchDownloadRequest(kind: .book, id: "b", title: "B"))
        XCTAssertEqual(album.status(nil).text, "Waiting for the watch")
        XCTAssertEqual(album.status(WatchWantState(key: "album:a", count: 0, complete: 0, needsContents: true)).text, "Being looked up")
        XCTAssertTrue(album.status(WatchWantState(key: "album:a", count: 0, complete: 0)).done)
        XCTAssertEqual(album.status(WatchWantState(key: "album:a", count: 9, complete: 4)).text, "4 of 9 on the watch")
        XCTAssertEqual(album.status(WatchWantState(key: "album:a", count: 9, complete: 4, failed: 2)).text, "4 of 9 on the watch · 2 failed for now")
        XCTAssertEqual(album.status(WatchWantState(key: "album:a", count: 9, complete: 9)).text, "On the watch")
        XCTAssertTrue(album.status(WatchWantState(key: "album:a", count: 9, complete: 9)).done)
        XCTAssertEqual(book.status(WatchWantState(key: "book:b", count: 1, complete: 0)).text, "Arriving")
        XCTAssertEqual(book.status(WatchWantState(key: "book:b", count: 1, complete: 0, failed: 1)).text, "Arriving, failed for now")
        XCTAssertEqual(album.id, "album:a")
    }

    /// 3a32a24: "a send that stops moving says so".
    func testASendThatStopsMovingIsCalledStuck() {
        var item = RelayItem(id: "x", stage: .sending, movedAt: Date().addingTimeInterval(-11 * 60))
        XCTAssertTrue(item.isStuck)
        XCTAssertFalse(item.isStuck(at: Date().addingTimeInterval(-11 * 60 + 60)))
        item.stage = .downloading
        XCTAssertFalse(item.isStuck, "only a send can be stuck")
        item = RelayItem(id: "y", stage: .sending, movedAt: nil)
        XCTAssertFalse(item.isStuck)
        XCTAssertTrue(RelayItem.Stage.delivered.isFinished)
        XCTAssertTrue(RelayItem.Stage.failed.isFinished)
        XCTAssertFalse(RelayItem.Stage.waiting.isFinished)
    }
}
#endif
