//  The watch's side of the WatchLink protocol (Watch/WatchLink.swift):
//  what each message from the phone does, the phone's context (the sign-in
//  hand-off and the plan), the remote's state, a file joined from pieces,
//  and the queue of listening going to the phone or the server.
//
//  WatchConnectivity itself is not driven here: `handle` and `apply` are
//  called as the session delegate would, and what would go to the phone is
//  kept in `link.testOutbox`. The real link is a manual check (MANUAL.md).

import UIKit
import WatchConnectivity
import XCTest
@testable import AquariumWatch

final class WatchLinkTests: WatchUnitTestCase {
    override class var signsIn: Bool { false }

    /// The link keeps the newest context's build time across tests (and
    /// launches), so each test's context is built later than any before.
    private static var clock = Date().addingTimeInterval(24 * 60 * 60)
    private func later() -> Date {
        Self.clock = Self.clock.addingTimeInterval(60)
        return Self.clock
    }

    // MARK: The sign-in hand-off

    func testTheContextFromThePhoneSignsTheWatchIn() async {
        XCTAssertFalse(client.isSignedIn)
        link.apply(PhoneContext(revision: 1, credentials: WX.credentials, mirror: WatchMirrorPlan(), sentAt: later()))
        XCTAssertTrue(client.isSignedIn)
        XCTAssertEqual(client.account?.userName, "stub")
        XCTAssertNotNil(link.lastPhoneContextAt)
    }

    func testAContextWithNoSignInSignsTheWatchOut() {
        link.apply(PhoneContext(revision: 1, credentials: WX.credentials, sentAt: later()))
        link.apply(PhoneContext(revision: 2, credentials: nil, sentAt: later()))
        XCTAssertFalse(client.isSignedIn)
    }

    /// From WatchLink.lastContextSentAt: "The phone's revision restarts with
    /// each launch, so its clock is what orders them: the context the system
    /// kept from last time can land after a fresh one."
    func testAnOlderContextLandingLateIsIgnored() {
        let now = later()
        link.apply(PhoneContext(revision: 1, credentials: WX.credentials, mirror: WatchMirrorPlan(bookIds: ["new"]), sentAt: now))
        link.apply(PhoneContext(revision: 99, credentials: nil, mirror: WatchMirrorPlan(bookIds: ["old"]), sentAt: now.addingTimeInterval(-3600)))
        XCTAssertTrue(client.isSignedIn, "the late sign-out is old news")
        XCTAssertEqual(downloads.plan.bookIds, ["new"])
    }

    func testTheContextCarriesThePlanToTheDownloads() {
        let want = WatchDownloadRequest(kind: .album, id: "al", title: "A")
        let plan = WatchMirrorPlan(bookIds: ["b"], playlistIds: ["p"], wants: [want])
        link.apply(PhoneContext(revision: 1, credentials: WX.credentials, mirror: plan, sentAt: later()))
        XCTAssertEqual(downloads.plan, plan)
        XCTAssertEqual(downloads.plannedPlaylistIds, ["p"])
        let saved = UserDefaults.standard.data(forKey: "watch_plan").flatMap { try? JSONDecoder().decode(WatchMirrorPlan.self, from: $0) }
        XCTAssertEqual(saved, plan, "kept for the next launch")
    }

    func testAContextFromThePhoneAsADictionaryDecodes() throws {
        let packed = WatchSync.pack(PhoneContext(revision: 5, credentials: WX.credentials, sentAt: Date()))
        let back = try XCTUnwrap(WatchSync.unpack(PhoneContext.self, from: packed))
        XCTAssertEqual(back.credentials, WX.credentials)
    }

    // MARK: Messages from the phone

    func testDeleteMessagesGoByGroup() {
        client.install(WX.credentials)
        downloads.enqueue([WX.book("b")], reason: "book")
        downloads.enqueue([WX.song("s", albumId: "al")], reason: "album:al")
        link.handle(.deleteGroup(kind: .book, id: "b"))
        link.handle(.deleteGroup(kind: .album, id: "al"))
        XCTAssertTrue(downloads.records.isEmpty)
        downloads.enqueue([WX.song("x")], reason: "song")
        link.handle(.deleteAll)
        XCTAssertTrue(downloads.records.isEmpty)
    }

    func testPhoneProgressAndFailureReachTheRecord() {
        client.install(WX.credentials)
        link.testSetPhone(reachable: true, companion: true)
        downloads.enqueue([WX.song("a"), WX.song("b")], reason: "song")
        downloads.testUpdate("a") { $0.estimatedBytes = 100 }
        link.handle(.fetchProgress(itemId: "a", fraction: 0.25))
        XCTAssertEqual(downloads.fraction("a")!, 0.25, accuracy: 0.01)
        link.handle(.fetchFailed(itemId: "b", reason: "Server error 500"))
        XCTAssertEqual(status("b"), .error)
        XCTAssertEqual(downloads.record(for: "b")?.errorMessage, "Server error 500")
    }

    /// 3a32a24 "Transfers can be cancelled by hand, on the watch too": the
    /// phone's cancel is the same as Cancel here.
    func testACancelOnThePhoneIsACancelHere() {
        client.install(WX.credentials)
        link.testSetPhone(reachable: true, companion: true)
        downloads.keep(WatchDownloadRequest(kind: .album, id: "al", title: "A"), items: [WX.song("a", albumId: "al")])
        link.handle(.cancelled(itemId: "a"))
        XCTAssertNil(downloads.record(for: "a"))
        XCTAssertTrue(downloads.testDeclined.contains("a"), "or the next pass asks the phone for it again")
    }

    func testWhatOnlyThePhoneHearsIsIgnoredHere() {
        let ignored: [WatchMessage] = [
            .progress([]), .fetch(itemId: "x"), .fetchMany(itemIds: ["x"]), .cancelFetch(itemId: "x"),
            .playlistRemoved(id: "p"), .wantRemoved(key: "k"), .requestContext, .requestPlayback, .remote(.play),
            .logs(WatchLogChunk(id: "i", name: "n", index: 0, count: 1, data: Data())),
        ]
        for m in ignored { link.handle(m) }
        XCTAssertEqual(sent, [])
        XCTAssertTrue(downloads.records.isEmpty)
    }

    func testAnUnreadableMessageIsAnsweredNotOK() {
        let done = expectation(description: "replied")
        link.session(.default, didReceiveMessage: ["aquarium": Data("nonsense".utf8)]) { reply in
            XCTAssertEqual(WatchSync.unpack(WatchReply.self, from: reply)?.ok, false)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: The remote's state

    func testWhatThePhoneIsPlayingIsKeptWithoutItsCover() throws {
        let cover = try XCTUnwrap(Self.png())
        link.take(playback: PhonePlaybackState(itemId: "s", title: "Song", isPlaying: true, artwork: cover))
        XCTAssertEqual(link.phonePlayback?.itemId, "s")
        XCTAssertNil(link.phonePlayback?.artwork)
        XCTAssertEqual(link.phoneArtwork?.itemId, "s")
        XCTAssertNotNil(link.phonePlaybackAt)
        XCTAssertNil(link.remoteError)
        link.take(playback: nil)
        XCTAssertNil(link.phonePlayback)
    }

    func testAPhoneMessageWithPlaybackUpdatesTheRemote() {
        link.handle(.phonePlayback(PhonePlaybackState(itemId: "t", title: "T")))
        XCTAssertEqual(link.phonePlayback?.title, "T")
    }

    func testTheRemoteSaysWhenThePhoneIsOutOfReach() {
        link.take(playback: PhonePlaybackState(itemId: "s", title: "S", isPlaying: false, position: 10))
        link.remote(.play)
        XCTAssertEqual(link.remoteError, "iPhone out of reach")
        XCTAssertEqual(link.phonePlayback?.isPlaying, false, "no guess drawn for a command that never left")
        link.requestPlayback()
        XCTAssertEqual(link.remoteError, "iPhone out of reach")
        XCTAssertFalse(link.remoteBusy)
    }

    func testChoosingTheiPhoneSourceAsksForItsPlayback() {
        link.take(playback: nil)
        XCTAssertNil(link.remoteError)
        WatchMode.shared.source = .phone
        XCTAssertEqual(UserDefaults.standard.string(forKey: "watch_source"), "phone")
        XCTAssertEqual(link.remoteError, "iPhone out of reach", "asked, and told the phone is away")
        WatchMode.shared.source = .watch
        XCTAssertEqual(UserDefaults.standard.string(forKey: "watch_source"), "watch")
        XCTAssertEqual(WatchSource.phone.label, "iPhone")
        XCTAssertEqual(WatchSource.watch.label, "Watch")
        XCTAssertFalse(WatchSource.phone.symbol.isEmpty)
    }

    /// Regression, f72bd13: "the remote's optimistic guess carries the clock
    /// forward instead of winding it back".
    func testTheRemotesGuessCarriesTheClockForward() throws {
        link.testSetPhone(reachable: true, companion: true)
        let said = Date().addingTimeInterval(-5)
        link.take(playback: PhonePlaybackState(itemId: "s", title: "S", isPlaying: true, position: 10, duration: 100, speed: 1, artwork: Self.png(), at: said))
        link.testOutbox = []
        link.remote(.pause)
        let guess = try XCTUnwrap(link.phonePlayback)
        XCTAssertFalse(guess.isPlaying)
        XCTAssertEqual(guess.position, 15, accuracy: 0.5, "where it had got to, not where the phone last said")
        XCTAssertGreaterThan(guess.at, said)
        XCTAssertEqual(sent, ["remote:pause"])
        XCTAssertFalse(link.remoteBusy)
    }

    func testEachRemoteCommandIsDrawnAtOnce() throws {
        link.testSetPhone(reachable: true, companion: true)
        link.take(playback: PhonePlaybackState(itemId: "s", title: "S", isPlaying: false, position: 40, duration: 100, speed: 1, artwork: Self.png()))
        link.remote(.play)
        XCTAssertEqual(link.phonePlayback?.isPlaying, true)
        link.remote(.togglePlayPause)
        XCTAssertEqual(link.phonePlayback?.isPlaying, false)
        link.remote(.seekTo(70))
        XCTAssertEqual(link.phonePlayback?.position, 70)
        link.remote(.seekBy(-100))
        XCTAssertEqual(link.phonePlayback?.position, 0)
        link.remote(.setSpeed(1.5))
        XCTAssertEqual(link.phonePlayback?.speed, 1.5)
        link.remote(.next)
        link.remote(.previous)
        link.remote(.instantMix)
        XCTAssertEqual(sent.suffix(3), ["remote:next", "remote:previous", "remote:instantMix"])
    }

    func testANewItemWithoutItsCoverAsksForItOnce() {
        link.testSetPhone(reachable: true, companion: true)
        link.take(playback: PhonePlaybackState(itemId: "new", title: "N"))
        link.take(playback: PhonePlaybackState(itemId: "new", title: "N"))
        XCTAssertEqual(sent, ["requestPlayback"])
    }

    func testTheRemotesSpeedGoesRound() {
        var s = 1.0
        var seen: [Double] = []
        for _ in 0..<6 { s = PhonePlayerScreen.nextSpeed(after: s); seen.append(s) }
        XCTAssertEqual(seen, [1.25, 1.5, 1.75, 2, 0.75, 1])
        XCTAssertEqual(PhonePlayerScreen.nextSpeed(after: 1.1), 1, "an odd speed goes back to normal")
    }

    // MARK: A file in pieces

    private func folder() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("pieces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    private func piece(_ text: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("transfer-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func meta(_ index: Int, of count: Int, total: Int, pieceBytes: Int = 4) -> [String: Any] {
        [WatchFileTransfer.pieceKey: index, WatchFileTransfer.piecesKey: count,
         WatchFileTransfer.pieceBytesKey: NSNumber(value: pieceBytes), WatchFileTransfer.bytesKey: NSNumber(value: total)]
    }

    func testPiecesJoinInOrderWhicheverOrderTheyArrive() throws {
        let dir = try folder()
        let inbox = try folder()
        XCTAssertNil(WatchLink.takePiece(try piece("BBBB", in: inbox), metadata: meta(1, of: 3, total: 10), send: "s1", itemId: "x", folder: dir))
        XCTAssertNil(WatchLink.takePiece(try piece("AAAA", in: inbox), metadata: meta(0, of: 3, total: 10), send: "s1", itemId: "x", folder: dir))
        let whole = try XCTUnwrap(WatchLink.takePiece(try piece("CC", in: inbox), metadata: meta(2, of: 3, total: 10), send: "s1", itemId: "x", folder: dir))
        XCTAssertEqual(String(decoding: try Data(contentsOf: whole), as: UTF8.self), "AAAABBBBCC")
        WatchLink.removeIncoming(in: dir)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// From takePiece: "A write cut short by a kill is trimmed back and done
    /// again from its piece, which is removed only once it is in."
    func testAHalfWrittenPieceIsTrimmedAndWrittenAgain() throws {
        let dir = try folder()
        let incoming = dir.appendingPathComponent("incoming-s1", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("AAAABB".utf8).write(to: incoming.appendingPathComponent("partial"))
        try Data("BBBB".utf8).write(to: incoming.appendingPathComponent("1.part"))
        let whole = try XCTUnwrap(WatchLink.takePiece(try piece("CC", in: try folder()), metadata: meta(2, of: 3, total: 10), send: "s1", itemId: "x", folder: dir))
        XCTAssertEqual(String(decoding: try Data(contentsOf: whole), as: UTF8.self), "AAAABBBBCC")
    }

    func testAPieceWithoutItsPlaceIsRefused() throws {
        let dir = try folder()
        XCTAssertNil(WatchLink.takePiece(try piece("A", in: try folder()), metadata: [:], send: "s", itemId: "x", folder: dir))
        XCTAssertNil(WatchLink.takePiece(try piece("A", in: try folder()), metadata: nil, send: "s", itemId: "x", folder: dir))
    }

    func testASendLeftBehindGoesAfterAnHour() throws {
        let dir = try folder()
        let stale = dir.appendingPathComponent("incoming-old", isDirectory: true)
        let fresh = dir.appendingPathComponent("incoming-recent", isDirectory: true)
        for d in [stale, fresh] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: stale.path)
        _ = WatchLink.takePiece(try piece("AAAA", in: try folder()), metadata: meta(0, of: 2, total: 8), send: "new", itemId: "x", folder: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    static func png() -> Data? {
        // A 1×1 PNG.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
    }
}

// MARK: - The listening queue

/// WatchSyncQueue: listening goes to the phone first, the server second,
/// and is kept until one of them takes it.
final class WatchSyncQueueTests: WatchUnitTestCase {
    private func event(_ id: String, at seconds: Double = 30, played: Bool = false, book: Bool = true,
                       heard: Date = Date(), account: String? = nil) -> WatchProgressEvent {
        WatchProgressEvent(itemId: id, positionTicks: WX.ticks(seconds), played: played, isAudiobook: book, at: heard, accountKey: account)
    }

    func testAPositionReplacesTheOneWaitingButAPlayIsKept() {
        sync.add(event("b", at: 10))
        sync.add(event("b", at: 20))
        sync.add(event("s", played: true, book: false))
        sync.add(event("s", played: true, book: false))
        XCTAssertEqual(sync.pending.filter { $0.itemId == "b" }.map(\.positionTicks), [WX.ticks(20)], "a book paused ten times is one place")
        XCTAssertEqual(sync.pending.filter { $0.itemId == "s" }.count, 2, "each play counts")
        XCTAssertTrue(sync.hasPending(for: "b"))
        XCTAssertFalse(sync.hasPending(for: "z"))
    }

    func testEventsAreMarkedWithWhoHeardThem() {
        sync.add(event("b"))
        XCTAssertEqual(sync.pending.first?.accountKey, WX.accountKey)
        sync.add(event("c", account: "other|user"))
        XCTAssertEqual(sync.pending.last?.accountKey, "other|user")
    }

    func testTheQueueSurvivesARelaunch() throws {
        sync.add(event("b", at: 42))
        let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: "watch_pending_events"))
        let events = try JSONDecoder().decode([WatchProgressEvent].self, from: saved)
        XCTAssertEqual(events.map(\.itemId), ["b"])
    }

    func testNothingGoesWithNoPhoneAndNoNetwork() async {
        sync.add(event("b"))
        await sync.flush()
        XCTAssertEqual(sync.pending.count, 1)
        XCTAssertNil(sync.lastFlushedAt)
    }

    /// Regression, 1228f45: "The phone answers the watch only once the server
    /// has the position, naming what it delivered; the rest stays pending on
    /// the watch."
    func testThePhoneSettlesOnlyWhatItNames() async {
        link.testSetPhone(reachable: true, companion: true)
        link.testEventReply = { events in WatchReply(ok: true, delivered: events.filter { $0.itemId == "a" }.map(\.id)) }
        sync.add(event("a"))
        sync.add(event("b"))
        let settled = await eventually { self.sync.pending.map(\.itemId) == ["b"] }
        XCTAssertTrue(settled, "\(sync.pending.map(\.itemId))")
        XCTAssertEqual(sync.lastRoute, "iPhone")
        XCTAssertNotNil(sync.lastFlushedAt)
    }

    func testAnOlderPhoneThatSaysOKTookTheLot() async {
        link.testSetPhone(reachable: true, companion: true)
        link.testEventReply = { _ in WatchReply(ok: true, delivered: nil) }
        sync.add(event("a"))
        let settled = await eventually { self.sync.pending.isEmpty }
        XCTAssertTrue(settled)
    }

    func testAPhoneThatDoesntAnswerLeavesItForTheServer() async {
        link.testSetPhone(reachable: true, companion: true)
        link.testEventReply = { _ in nil }
        downloads.testSetNetwork(up: true, wifi: true)
        WatchStub.on("/System/Info/Public", json: "{}")
        WatchStub.on("/UserPlayedItems/s", method: "POST", json: "")
        sync.add(event("s", played: true, book: false))
        let done = await eventually { self.sync.pending.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(sync.lastRoute, "server")
    }

    func testStraightToTheServerWhenThePhoneIsAway() async {
        downloads.testSetNetwork(up: true, wifi: true)
        WatchStub.on("/System/Info/Public", json: "{}")
        WatchStub.on("/Items", items: [WX.book("b", seconds: 3600)])
        WatchStub.on("/Sessions/Playing/Stopped", method: "POST", json: "")
        downloads.enqueue([WX.book("b", seconds: 3600)], reason: "book")
        downloads.noteProgress(itemId: "b", positionSeconds: 30)
        sync.add(event("b", at: 30))
        let done = await eventually { self.sync.pending.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(WatchStub.requests(path: "/Sessions/Playing/Stopped").count, 1)
        XCTAssertEqual(downloads.record(for: "b")?.progressSynced, true, "the record knows the server has it")
    }

    func testAnEventTheServerWillNeverTakeIsDropped() async {
        downloads.testSetNetwork(up: true, wifi: true)
        WatchStub.on("/System/Info/Public", json: "{}")
        WatchStub.on("/UserPlayedItems/gone", method: "POST", status: 404)
        sync.add(event("gone", played: true, book: false))
        let done = await eventually { self.sync.pending.isEmpty }
        XCTAssertTrue(done)
    }

    func testAnEventRefusedForTheSignInIsKept() async {
        downloads.testSetNetwork(up: true, wifi: true)
        WatchStub.on("/System/Info/Public", json: "{}")
        WatchStub.on("/UserPlayedItems/s", method: "POST", status: 401)
        sync.add(event("s", played: true, book: false))
        await sync.flush()
        await settle(0.3)
        XCTAssertEqual(sync.pending.count, 1)
    }

    func testAServerHiccupStopsTheRestForNow() async {
        downloads.testSetNetwork(up: true, wifi: true)
        WatchStub.on("/System/Info/Public", json: "{}")
        WatchStub.on("/UserPlayedItems/a", method: "POST", status: 503)
        WatchStub.on("/UserPlayedItems/b", method: "POST", json: "")
        sync.add(event("a", played: true, book: false))
        sync.add(event("b", played: true, book: false))
        await sync.flush()
        await settle(0.3)
        XCTAssertEqual(Set(sync.pending.map(\.itemId)), ["a", "b"])
    }

    /// Regression, e929365: "events … only go to the server under [their
    /// account]. Others wait for that account".
    func testAnotherAccountsEventWaits() async {
        downloads.testSetNetwork(up: true, wifi: true)
        WatchStub.on("/System/Info/Public", json: "{}")
        WatchStub.on("/UserPlayedItems/s", method: "POST", json: "")
        sync.add(event("s", played: true, book: false, account: "http://elsewhere|someone"))
        await sync.flush()
        await settle(0.3)
        XCTAssertEqual(sync.pending.count, 1)
        XCTAssertTrue(WatchStub.requests(path: "/UserPlayedItems/s").isEmpty)
    }

    func testABookNotedButNeverQueuedIsSentToo() async {
        link.testSetPhone(reachable: true, companion: true)
        var seen: [WatchProgressEvent] = []
        link.testEventReply = { events in seen = events; return WatchReply(ok: true, delivered: events.map(\.id)) }
        downloads.enqueue([WX.book("b", seconds: 3600)], reason: "book")
        downloads.noteProgress(itemId: "b", positionSeconds: 120)
        await sync.flush()
        _ = await eventually { !seen.isEmpty }
        XCTAssertEqual(seen.map(\.itemId), ["b"])
        XCTAssertEqual(seen.first?.positionTicks, WX.ticks(120))
        XCTAssertEqual(downloads.record(for: "b")?.progressSynced, true)
    }
}
