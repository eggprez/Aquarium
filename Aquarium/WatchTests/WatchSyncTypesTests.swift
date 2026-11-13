//  The vocabulary of the phone↔watch link (Shared/WatchSyncTypes.swift):
//  every message and context encoded and decoded both ways, what a side one
//  build behind sends, and the listening rules both ends share.
//
//  The same file is compiled into the phone; AquariumTests/Shared/
//  WatchLinkWireTests.swift decodes the same golden payloads there, so the
//  two sides are held to one wire format.

import XCTest
@testable import AquariumWatch

final class WatchSyncTypesTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let packed = WatchSync.pack(value)
        XCTAssertEqual(Array(packed.keys), [WatchSync.key], file: file, line: line)
        return try XCTUnwrap(WatchSync.unpack(T.self, from: packed), file: file, line: line)
    }

    /// The same value, encoded with sorted keys, before and after.
    private func assertSameWire<T: Codable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let back = try roundTrip(value, file: file, line: line)
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        XCTAssertEqual(try e.encode(value), try e.encode(back), "\(T.self) changed on the way", file: file, line: line)
    }

    // MARK: Packing

    func testPackPutsOneJSONPayloadUnderTheOneKey() throws {
        let packed = WatchSync.pack(WatchMessage.requestInventory)
        XCTAssertEqual(WatchSync.key, "aquarium")
        let data = try XCTUnwrap(packed["aquarium"] as? Data)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data))
    }

    func testUnpackIgnoresAnythingElse() {
        XCTAssertNil(WatchSync.unpack(WatchMessage.self, from: [:]))
        XCTAssertNil(WatchSync.unpack(WatchMessage.self, from: ["aquarium": "not data"]))
        XCTAssertNil(WatchSync.unpack(WatchMessage.self, from: ["aquarium": Data("{}".utf8)]))
        XCTAssertNil(WatchSync.unpack(PhoneContext.self, from: ["other": Data()]))
    }

    // MARK: Every message, both ways

    func testEveryMessageRoundTrips() throws {
        let request = WatchDownloadRequest(kind: .album, id: "a1", title: "Album")
        let event = WatchProgressEvent(itemId: "b1", positionTicks: 123, played: false, isAudiobook: true, streamed: true,
                                       at: Date(timeIntervalSince1970: 1_000), accountKey: WX.accountKey)
        let state = PhonePlaybackState(itemId: "s1", title: "Song", subtitle: "Artist", isAudiobook: false, isVideo: false,
                                       isPlaying: true, position: 12, duration: 200, speed: 1.25, hasNext: true,
                                       hasPrevious: false, upNextCount: 3, isOfflineMix: true, chapter: "One",
                                       volume: 0.5, artwork: Data([1, 2, 3]), at: Date(timeIntervalSince1970: 2_000))
        let chunk = WatchLogChunk(id: "x", name: "watch.log", index: 1, count: 3, data: Data([9, 9]))
        let messages: [WatchMessage] = [
            .deleteGroup(kind: .playlist, id: "p1"), .deleteAll, .download(request), .requestInventory, .requestLogs,
            .fetchProgress(itemId: "i1", fraction: 0.25), .fetchFailed(itemId: "i1", reason: "nope"),
            .deleteWant(request), .cancelled(itemId: "i2"),
            .progress([event]), .fetch(itemId: "i3"), .fetchMany(itemIds: ["a", "b"]), .cancelFetch(itemId: "i4"),
            .playlistRemoved(id: "p2"), .wantRemoved(key: "album:a1"), .requestContext, .logs(chunk),
            .phonePlayback(state), .phonePlayback(nil), .requestPlayback,
            .remote(.play), .remote(.pause), .remote(.togglePlayPause), .remote(.next), .remote(.previous),
            .remote(.seekTo(42)), .remote(.seekBy(-15)), .remote(.setSpeed(1.75)), .remote(.instantMix),
        ]
        for message in messages {
            let back = try roundTrip(message)
            XCTAssertEqual(WatchUnitTestCase.describe(back), WatchUnitTestCase.describe(message))
            try assertSameWire(message)
        }
    }

    func testRepliesRoundTrip() throws {
        let context = PhoneContext(revision: 3, credentials: WX.credentials, mirror: WatchMirrorPlan(bookIds: ["b"], playlistIds: ["p"]))
        let ids = [UUID(), UUID()]
        let reply = WatchReply(ok: true, note: "n", context: context, delivered: ids, playback: nil)
        let back = try roundTrip(reply)
        XCTAssertTrue(back.ok)
        XCTAssertEqual(back.delivered, ids)
        XCTAssertEqual(back.context?.credentials, WX.credentials)
        XCTAssertEqual(back.context?.mirror.playlistIds, ["p"])
        // From a phone too old to name what reached the server.
        let old = try XCTUnwrap(try? JSONDecoder().decode(WatchReply.self, from: Data(#"{"ok":true}"#.utf8)))
        XCTAssertNil(old.delivered)
        XCTAssertNil(old.context)
    }

    // MARK: Phone → watch: the context

    func testPhoneContextRoundTripsWithEverything() throws {
        let want = WatchDownloadRequest(kind: .artist, id: "ar", title: "FX Band")
        let plan = WatchMirrorPlan(bookIds: ["b1"], playlistIds: ["p1", "p2"], wants: [want])
        try assertSameWire(PhoneContext(revision: 9, credentials: WX.credentials, mirror: plan, sentAt: Date(timeIntervalSince1970: 5)))
    }

    /// Regression, f66fe9c "Watch sync … decode key by key so a side one build
    /// behind doesn't drop the whole update": a phone that sends no mirror and
    /// no sentAt still signs the watch in.
    func testPhoneContextFromAnOlderPhoneStillDecodes() throws {
        let json = #"{"revision":4,"credentials":{"server":"http://s","userId":"u","userName":"n","token":"t"}}"#
        let context = try JSONDecoder().decode(PhoneContext.self, from: Data(json.utf8))
        XCTAssertEqual(context.revision, 4)
        XCTAssertEqual(context.credentials?.token, "t")
        XCTAssertNil(context.credentials?.serverId)
        XCTAssertEqual(context.mirror, WatchMirrorPlan())
    }

    func testPhoneContextWithoutCredentialsMeansSignedOut() throws {
        let context = try JSONDecoder().decode(PhoneContext.self, from: Data(#"{"revision":1}"#.utf8))
        XCTAssertNil(context.credentials)
    }

    func testMirrorPlanFromBeforeWantsDecodes() throws {
        let plan = try JSONDecoder().decode(WatchMirrorPlan.self, from: Data(#"{"bookIds":["b"]}"#.utf8))
        XCTAssertEqual(plan.bookIds, ["b"])
        XCTAssertEqual(plan.playlistIds, [])
        XCTAssertEqual(plan.wants, [])
    }

    // MARK: Watch → phone: the context

    func testWatchContextRoundTrips() throws {
        let group = WatchStorageGroup(id: "a", kind: .album, title: "A", subtitle: "B", count: 3, bytes: 10, complete: 2)
        let inventory = WatchInventory(groups: [group], itemCount: 2, totalBytes: 10, freeBytes: 99, inFlight: 1, truncated: true)
        let want = WatchWantState(key: "album:a", count: 3, complete: 2, failed: 1, needsContents: false)
        try assertSameWire(WatchContext(revision: 2, inventory: inventory, awaitingPhone: ["x"], playlistIds: ["p"],
                                        wants: [want], signedIn: true, sentAt: Date(timeIntervalSince1970: 7)))
    }

    func testWatchContextFromAnOlderWatchDecodes() throws {
        let json = #"{"revision":1,"inventory":{},"signedIn":false}"#
        let context = try JSONDecoder().decode(WatchContext.self, from: Data(json.utf8))
        XCTAssertNil(context.awaitingPhone)
        XCTAssertNil(context.playlistIds)
        XCTAssertNil(context.wants)
        XCTAssertEqual(context.inventory.groups, [])
        XCTAssertEqual(context.inventory.inFlight, 0)
        XCTAssertFalse(context.inventory.truncated)
        XCTAssertNil(context.inventory.freeBytes)
    }

    func testPhonePlaybackStateFromAnOlderPhoneDecodes() throws {
        let state = try JSONDecoder().decode(PhonePlaybackState.self, from: Data(#"{"itemId":"x"}"#.utf8))
        XCTAssertEqual(state.title, "")
        XCTAssertEqual(state.speed, 1)
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(state.volume)
    }

    // MARK: The remote's clock

    func testPhonePlaybackRunsOnFromItsTimeWhilePlaying() {
        let at = Date(timeIntervalSince1970: 1_000)
        var state = PhonePlaybackState(itemId: "x", title: "t", isPlaying: true, position: 10, duration: 100, speed: 1.5, at: at)
        XCTAssertEqual(state.position(now: at.addingTimeInterval(4)), 16, accuracy: 0.001)
        XCTAssertEqual(state.position(now: at.addingTimeInterval(500)), 100, "never past the end")
        XCTAssertEqual(state.position(now: at.addingTimeInterval(-5)), 10, "a clock behind adds nothing")
        state.isPlaying = false
        XCTAssertEqual(state.position(now: at.addingTimeInterval(4)), 10)
        state.isPlaying = true
        state.duration = 0
        XCTAssertEqual(state.position(now: at.addingTimeInterval(4)), 16, accuracy: 0.001, "no length: no ceiling")
    }

    func testWithoutArtworkComparesOnlyWhatMatters() {
        let a = PhonePlaybackState(itemId: "x", title: "t", artwork: Data([1]), at: Date())
        let b = PhonePlaybackState(itemId: "x", title: "t", artwork: nil, at: Date().addingTimeInterval(9))
        XCTAssertEqual(a.withoutArtwork, b.withoutArtwork)
        XCTAssertNil(a.withoutArtwork.artwork)
    }

    // MARK: Requests and groups

    func testDownloadRequestKeysAndReasons() {
        let cases: [(WatchDownloadRequest.Kind, String)] = [
            (.album, "album:i"), (.playlist, "playlist:i"), (.book, "book"), (.song, "song"), (.artist, "artist:i"), (.genre, "genre:i"),
        ]
        for (kind, reason) in cases {
            let r = WatchDownloadRequest(kind: kind, id: "i", title: "T")
            XCTAssertEqual(r.key, "\(kind.rawValue):i")
            XCTAssertEqual(r.reason, reason)
            XCTAssertFalse(kind.label.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
        }
        XCTAssertEqual(WatchDownloadRequest.Kind.book.label, "Audiobook")
    }

    func testStorageGroupKindsHaveLabelsAndSymbols() {
        for kind in [WatchStorageGroup.Kind.album, .playlist, .book, .songs] {
            XCTAssertFalse(kind.label.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
        }
        XCTAssertEqual(WatchStorageGroup.Kind.book.label, "Audiobook")
    }

    func testWantStateIdentifiesByKey() {
        XCTAssertEqual(WatchWantState(key: "song:x", count: 1, complete: 0).id, "song:x")
    }

    // MARK: Events belong to their account

    /// Regression, e929365 "Offline progress … events and queue entries record
    /// their account and only go to the server under it. Entries from older
    /// builds have no owner and still go to whoever is signed in."
    func testEventsGoOnlyUnderTheirOwnAccount() {
        var e = WatchProgressEvent(itemId: "x", positionTicks: 1, played: false, isAudiobook: true)
        XCTAssertTrue(e.belongs(to: "s|a"), "an event from before accounts goes to anyone")
        XCTAssertTrue(e.belongs(to: nil))
        e.accountKey = "s|a"
        XCTAssertTrue(e.belongs(to: "s|a"))
        XCTAssertFalse(e.belongs(to: "s|b"))
        XCTAssertFalse(e.belongs(to: nil))
    }

    // MARK: What a download is fetched as

    private func source(container: String, codec: String?, size: Int64?) -> BaseItem {
        var item = WX.song("x", seconds: 600)
        var s = MediaSource()
        s.Id = "ms"
        s.ETag = "tag"
        s.Container = container
        s.Size = size
        if let codec {
            var stream = MediaStream()
            stream.type = "Audio"
            stream.Codec = codec
            s.MediaStreams = [stream]
        }
        item.MediaSources = [s]
        return item
    }

    func testTheServersOwnFileWhenTheWatchCanPlayIt() {
        let encoded = JellyfinClient.estimatedBytes(for: WX.song("x", seconds: 600))
        XCTAssertEqual(WatchDownloadSource.originalExtension(for: source(container: "m4b", codec: "aac", size: encoded), encodedBytes: encoded), "m4b")
        XCTAssertEqual(WatchDownloadSource.originalExtension(for: source(container: "mp3", codec: "mp3", size: encoded), encodedBytes: encoded), "mp3")
        XCTAssertEqual(WatchDownloadSource.originalExtension(for: source(container: "mov,mp4,m4a", codec: "alac", size: encoded), encodedBytes: encoded), "m4a",
                       "mp4 is kept as m4a")
    }

    func testAnEncodeWhenTheWatchCantPlayItOrItIsMuchBigger() {
        let encoded: Int64 = 10_000_000
        XCTAssertNil(WatchDownloadSource.originalExtension(for: source(container: "flac", codec: "flac", size: 1), encodedBytes: encoded))
        XCTAssertNil(WatchDownloadSource.originalExtension(for: source(container: "m4a", codec: "opus", size: 1), encodedBytes: encoded))
        XCTAssertNil(WatchDownloadSource.originalExtension(for: source(container: "mp3", codec: "mp3", size: encoded * 2), encodedBytes: encoded))
        XCTAssertEqual(WatchDownloadSource.originalExtension(for: source(container: "mp3", codec: "mp3", size: encoded * 3 / 2), encodedBytes: encoded), "mp3",
                       "half as big again is still the original")
        XCTAssertNil(WatchDownloadSource.originalExtension(for: WX.song("x"), encodedBytes: encoded), "no source, no original")
    }

    func testTheOriginalsQuery() {
        let q = WatchDownloadSource.originalQuery(for: source(container: "mp3", codec: "mp3", size: 1), deviceId: "dev")
        let byName = Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(byName, ["static": "true", "deviceId": "dev", "mediaSourceId": "ms", "Tag": "tag"])
    }

    func testForWatchKeepsOnlyWhatTheWatchUses() {
        var item = source(container: "mp3", codec: "mp3", size: 1)
        item.Genres = ["g"]
        item.Taglines = ["t"]
        item.BackdropImageTags = ["b"]
        item.ImageBlurHashes = ["Primary": ["a": "b"]]
        let slim = item.forWatch
        XCTAssertNil(slim.MediaSources)
        XCTAssertNil(slim.Genres)
        XCTAssertNil(slim.Taglines)
        XCTAssertNil(slim.BackdropImageTags)
        XCTAssertNil(slim.ImageBlurHashes)
        XCTAssertEqual(slim.Id, item.Id)
        XCTAssertEqual(slim.RunTimeTicks, item.RunTimeTicks)
        XCTAssertEqual(slim.Artists, item.Artists)
    }

    func testFileTransferNamesAreStable() {
        // The phone writes these and the watch reads them: a rename on one
        // side only would drop every file.
        XCTAssertEqual(WatchFileTransfer.kindKey, "kind")
        XCTAssertEqual(WatchFileTransfer.itemKey, "item")
        XCTAssertEqual(WatchFileTransfer.playlistKind, "playlist")
        XCTAssertEqual(WatchFileTransfer.booksKind, "books")
        XCTAssertEqual(WatchFileTransfer.downloadKind, "download")
        XCTAssertEqual(WatchFileTransfer.logsKind, "logs")
        XCTAssertEqual(WatchFileTransfer.pieceBytes, 16 * 1024 * 1024)
    }

    func testFileContentsRoundTrip() throws {
        let songs = [WX.song("a"), WX.song("b")]
        let list = try JSONDecoder().decode(WatchPlaylistContents.self,
                                            from: JSONEncoder().encode(WatchPlaylistContents(id: "p", name: "P", imageTag: "t", songs: songs)))
        XCTAssertEqual(list.songs.map(\.Id), ["a", "b"])
        let books = try JSONDecoder().decode(WatchBooksContents.self, from: JSONEncoder().encode(WatchBooksContents(books: [WX.book("k")])))
        XCTAssertEqual(books.books.first?.isAudiobook, true)
        let request = WatchDownloadRequest(kind: .album, id: "a", title: "A")
        let dl = try JSONDecoder().decode(WatchDownloadContents.self,
                                          from: JSONEncoder().encode(WatchDownloadContents(request: request, items: songs)))
        XCTAssertEqual(dl.request, request)
        XCTAssertEqual(dl.items.count, 2)
    }

    // MARK: Golden payloads (the phone's tests decode the same strings)

    func testGoldenPayloadsDecode() throws {
        for (name, json) in WatchWireGolden.all {
            XCTAssertNotNil(WatchWireGolden.decode(name, json), "golden payload \(name) no longer decodes")
        }
    }
}

/// Payloads as the wire carries them, written out by hand. A field renamed
/// on one side breaks these here and in the phone's copy of the test.
enum WatchWireGolden {
    static let all: [(String, String)] = [
        ("phoneContext", #"{"revision":12,"credentials":{"server":"http://127.0.0.1:8196","userId":"u1","userName":"suite-watch","serverId":"s1","token":"tok"},"mirror":{"bookIds":["b1"],"playlistIds":["p1"],"wants":[{"kind":"album","id":"a1","title":"FX Two Discs"}]},"sentAt":784000000}"#),
        ("watchContext", #"{"revision":3,"inventory":{"groups":[{"id":"a1","kind":"album","title":"FX Two Discs","count":6,"bytes":1000,"complete":4}],"itemCount":4,"totalBytes":1000,"freeBytes":5000,"inFlight":2,"truncated":false},"awaitingPhone":["s5","s6"],"playlistIds":["p1"],"wants":[{"key":"album:a1","count":6,"complete":4,"failed":0,"needsContents":false}],"signedIn":true,"sentAt":784000001}"#),
        ("fetchMany", #"{"fetchMany":{"itemIds":["s5","s6"]}}"#),
        ("progress", #"{"progress":{"_0":[{"id":"7C9A1D5E-3B1F-4F55-9F0D-2E5B6C7D8E9F","itemId":"b1","positionTicks":870000000,"played":false,"isAudiobook":true,"streamed":false,"at":784000002,"accountKey":"http://127.0.0.1:8196|u1"}]}}"#),
        ("deleteWant", #"{"deleteWant":{"_0":{"kind":"artist","id":"ar1","title":"FX Band"}}}"#),
        ("remoteSpeed", #"{"remote":{"_0":{"setSpeed":{"_0":1.25}}}}"#),
        ("reply", #"{"ok":true,"delivered":["7C9A1D5E-3B1F-4F55-9F0D-2E5B6C7D8E9F"]}"#),
    ]

    static func decode(_ name: String, _ json: String) -> Any? {
        let data = Data(json.utf8)
        let d = JSONDecoder()
        switch name {
        case "phoneContext": return try? d.decode(PhoneContext.self, from: data)
        case "watchContext": return try? d.decode(WatchContext.self, from: data)
        case "reply": return try? d.decode(WatchReply.self, from: data)
        default: return try? d.decode(WatchMessage.self, from: data)
        }
    }
}
