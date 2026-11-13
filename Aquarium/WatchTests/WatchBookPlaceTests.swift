//  A book's place, kept on the watch and weighed against the server's
//  (WatchDownloads.noteProgress / markSynced / applyServerState,
//  WatchActions.refreshBookPositions, BookProgress). Commit 1228f45: "the
//  newest position wins".
//
//  Two known bugs on this branch, fixed on claude/qa-fix-list-cb0b58 and not
//  merged here (master-fix-list "From Apple Watch", top priority):
//  the server stores 0 for the first five minutes of a book
//  (MinAudiobookResume) and the refresh copied that 0 over the watch's own
//  place. The tests below expect the fixed behaviour, marked as expected
//  failures, and check the real resets that must still be taken.

import XCTest
@testable import AquariumWatch

final class WatchBookPlaceTests: WatchUnitTestCase {
    /// A book on the watch, at `seconds`, everything heard there already
    /// told to the server.
    private func bookOnWatch(_ id: String = "b", at seconds: Double, length: Double = 900, synced: Bool = true) {
        downloads.enqueue([WX.book(id, seconds: length)], reason: "book")
        downloads.testUpdate(id) { r in
            r.status = .complete
            r.positionTicks = WX.ticks(seconds)
            r.played = false
            r.progressSynced = synced
            r.localChangedAt = Date().addingTimeInterval(-60)
            r.lastPlayedAt = Date().addingTimeInterval(-60)
        }
    }

    private func place(_ id: String = "b") -> Double { Double(downloads.record(for: id)?.positionTicks ?? -1) / 10_000_000 }

    // MARK: Noting

    func testNotingAPlaceMarksItForTheServer() {
        bookOnWatch(at: 0)
        downloads.noteProgress(itemId: "b", positionSeconds: 87)
        let r = downloads.record(for: "b")!
        XCTAssertEqual(place(), 87, accuracy: 0.001)
        XCTAssertFalse(r.played)
        XCTAssertFalse(r.progressSynced)
        XCTAssertNotNil(r.localChangedAt)
        XCTAssertNotNil(r.lastPlayedAt)
    }

    /// 1228f45: "A book is finished with under five minutes left
    /// (BookProgress, shared by both devices and matching Jellyfin's
    /// default), not past 90%."
    func testUnderFiveMinutesLeftIsFinished() {
        bookOnWatch(at: 0, length: 3600)
        downloads.noteProgress(itemId: "b", positionSeconds: 3600 - 299)
        XCTAssertEqual(downloads.record(for: "b")?.played, true)
        bookOnWatch("c", at: 0, length: 7200)
        downloads.noteProgress(itemId: "c", positionSeconds: 6600)
        XCTAssertEqual(downloads.record(for: "c")?.played, false, "past 90% but more than five minutes left")
    }

    func testStartingAFinishedBookAgainIsNotFinished() {
        bookOnWatch(at: 0, length: 3600)
        downloads.testUpdate("b") { $0.played = true }
        downloads.noteProgress(itemId: "b", positionSeconds: 20)
        XCTAssertEqual(downloads.record(for: "b")?.played, true, "the first half-minute isn't a restart")
        downloads.noteProgress(itemId: "b", positionSeconds: 45)
        XCTAssertEqual(downloads.record(for: "b")?.played, false)
    }

    func testASongPast98PercentIsHeard() {
        downloads.enqueue([WX.song("s", seconds: 100)], reason: "song")
        downloads.noteProgress(itemId: "s", positionSeconds: 99)
        XCTAssertEqual(downloads.record(for: "s")?.played, true)
    }

    func testMarkSyncedOnlyCoversWhatTheServerHeard() {
        bookOnWatch(at: 0)
        downloads.noteProgress(itemId: "b", positionSeconds: 30)
        downloads.markSynced(itemId: "b", through: Date().addingTimeInterval(-60))
        XCTAssertEqual(downloads.record(for: "b")?.progressSynced, false, "moved on since that event")
        downloads.markSynced(itemId: "b", through: Date())
        XCTAssertEqual(downloads.record(for: "b")?.progressSynced, true)
    }

    func testABookNotedButNeverQueuedGoesFromItsRecord() {
        bookOnWatch(at: 0, length: 3600)
        downloads.noteProgress(itemId: "b", positionSeconds: 120)
        let events = downloads.unsentBookEvents(except: [])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.positionTicks, WX.ticks(120))
        XCTAssertEqual(events.first?.played, false)
        XCTAssertEqual(events.first?.isAudiobook, true)
        XCTAssertTrue(downloads.unsentBookEvents(except: ["b"]).isEmpty, "already queued")
        downloads.testUpdate("b") { $0.played = true }
        XCTAssertEqual(downloads.unsentBookEvents(except: []).first?.positionTicks, WX.ticks(3600), "a finish goes as the whole length")
    }

    func testTheBookPlayingNowIsLeftToThePlayer() {
        bookOnWatch(at: 0)
        downloads.noteProgress(itemId: "b", positionSeconds: 60)
        player.testLoad([downloads.record(for: "b")!.asItem], position: 60)
        XCTAssertTrue(downloads.unsentBookEvents(except: []).isEmpty)
    }

    // MARK: The server's word

    func testASyncedBookTakesTheServersPlace() {
        bookOnWatch(at: 400)
        downloads.applyServerState(itemId: "b", positionTicks: WX.ticks(600), played: false, lastPlayed: Date())
        XCTAssertEqual(place(), 600, accuracy: 0.001)
    }

    func testListeningNotYetToldWinsOverAnOlderServer() {
        bookOnWatch(at: 400, synced: false)
        downloads.applyServerState(itemId: "b", positionTicks: WX.ticks(100), played: false, lastPlayed: Date().addingTimeInterval(-3600))
        XCTAssertEqual(place(), 400, accuracy: 0.001)
    }

    func testANewerPlayElsewhereWinsOverListeningNotYetTold() {
        bookOnWatch(at: 400, synced: false)
        downloads.applyServerState(itemId: "b", positionTicks: WX.ticks(700), played: false, lastPlayed: Date())
        XCTAssertEqual(place(), 700, accuracy: 0.001)
        XCTAssertEqual(downloads.record(for: "b")?.progressSynced, true)
    }

    func testAnEventStillQueuedKeepsTheWatchsPlace() {
        bookOnWatch(at: 400)
        sync.add(WatchProgressEvent(itemId: "b", positionTicks: WX.ticks(400), played: false, isAudiobook: true))
        downloads.applyServerState(itemId: "b", positionTicks: WX.ticks(10), played: false, lastPlayed: Date())
        XCTAssertEqual(place(), 400, accuracy: 0.001)
    }

    /// Regression, master-fix-list "From Apple Watch" (top priority): "Forgets
    /// its place in the first 5 minutes of any book: the server stores 0
    /// under MinAudiobookResume and refreshBookPositions copies that over the
    /// watch's record; 1:27 became Play from the start (2/2).
    /// WatchDownloads.swift:925". Fixed on claude/qa-fix-list-cb0b58
    /// (f50fc11, dec4915), not on this branch.
    func testABooksEarlyPlaceSurvivesTheServersZero() {
        bookOnWatch(at: 87)
        downloads.applyServerState(itemId: "b", positionTicks: 0, played: false, lastPlayed: Date())
        XCTExpectFailure("bug: the server's MinAudiobookResume 0 overwrites the watch's place at 1:27 (WatchDownloads.applyServerState)")
        XCTAssertEqual(place(), 87, accuracy: 0.001)
    }

    /// dec4915: "the server has no date on a book only ever reported stopped,
    /// so 0:46 still fell to Play."
    func testABooksEarlyPlaceSurvivesAnUndatedZero() {
        bookOnWatch(at: 46)
        downloads.applyServerState(itemId: "b", positionTicks: 0, played: false, lastPlayed: nil)
        XCTExpectFailure("bug: an undated server 0 overwrites the watch's place at 0:46 (WatchDownloads.applyServerState)")
        XCTAssertEqual(place(), 46, accuracy: 0.001)
    }

    /// Telling the server's early 0 from a real reset: once the server has
    /// held a place for the book, its 0 is somebody starting over.
    func testAZeroAfterTheServerHeldAPlaceIsAReset() {
        bookOnWatch(at: 87)
        downloads.applyServerState(itemId: "b", positionTicks: WX.ticks(500), played: false, lastPlayed: Date())
        XCTAssertEqual(place(), 500, accuracy: 0.001)
        downloads.testUpdate("b") { $0.positionTicks = WX.ticks(87) }
        downloads.applyServerState(itemId: "b", positionTicks: 0, played: false, lastPlayed: Date())
        XCTAssertEqual(place(), 0, "the server had a place for it: a 0 now is meant")
    }

    func testAZeroPastTheEarlyWindowIsAReset() {
        bookOnWatch(at: 600)
        downloads.applyServerState(itemId: "b", positionTicks: 0, played: false, lastPlayed: Date())
        XCTAssertEqual(place(), 0, "the server keeps places past five minutes, so this 0 is meant")
    }

    func testAFinishOnTheServerIsTaken() {
        bookOnWatch(at: 87)
        downloads.applyServerState(itemId: "b", positionTicks: 0, played: true, lastPlayed: Date())
        XCTAssertEqual(downloads.record(for: "b")?.played, true)
    }

    // MARK: Asking the server

    func testRefreshAsksForTheBooksOnTheWatchAndAppliesThem() async {
        bookOnWatch(at: 400)
        WatchStub.on("/Items", query: ["Ids": "b"], items: [WX.book("b", position: 650, lastPlayed: WX.serverDate(Date()))])
        let items = await WatchActions.refreshBookPositions()
        XCTAssertEqual(items.map(\.Id), ["b"])
        XCTAssertEqual(place(), 650, accuracy: 0.001)
    }

    func testRefreshAsksNothingOfflineSignedOutOrWithNoBooks() async {
        var items = await WatchActions.refreshBookPositions()
        XCTAssertTrue(items.isEmpty)
        bookOnWatch(at: 400)
        WatchStub.fail("/System/Info/Public")
        _ = await client.checkOnline()
        items = await WatchActions.refreshBookPositions()
        XCTAssertTrue(items.isEmpty)
        client.signOut()
        items = await WatchActions.refreshBookPositions(ids: ["b"])
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(WatchStub.requests(path: "/Items").isEmpty)
    }

    func testRefreshWithATimeoutReturnsWhatCameInTime() async {
        bookOnWatch(at: 400)
        WatchStub.on("/Items", items: [WX.book("b", position: 700)])
        let items = await WatchActions.refreshBookPositions(ids: ["b"], timeout: .seconds(2))
        XCTAssertEqual(items.first?.Id, "b")
    }

    /// The master-fix-list case end to end: the place 1:27 on the watch, the
    /// server's list says 0 with a date, the refresh runs.
    func testRefreshKeepsAnEarlyPlace() async {
        bookOnWatch(at: 87)
        WatchStub.on("/Items", items: [WX.book("b", position: 0, lastPlayed: WX.serverDate(Date()))])
        await WatchActions.refreshBookPositions()
        XCTExpectFailure("bug: refreshBookPositions copies the server's early 0 over 1:27 (WatchDownloads.applyServerState)")
        XCTAssertEqual(place(), 87, accuracy: 0.001)
    }

    // MARK: BookProgress, the shared rules

    func testFinishedMeansUnderFiveMinutesLeft() {
        XCTAssertTrue(BookProgress.isFinished(position: 3400, duration: 3600))
        XCTAssertFalse(BookProgress.isFinished(position: 3200, duration: 3600))
        XCTAssertFalse(BookProgress.isFinished(position: 0, duration: 100), "not started is not finished")
        XCTAssertFalse(BookProgress.isFinished(position: 10, duration: 0))
        XCTAssertTrue(BookProgress.isFinished(positionTicks: WX.ticks(3400), runTimeTicks: WX.ticks(3600)))
    }

    func testStaleMeansStartedElsewhereSince() {
        let heard = Date()
        XCTAssertFalse(BookProgress.isStale(eventAt: heard, serverLastPlayed: nil))
        XCTAssertFalse(BookProgress.isStale(eventAt: heard, serverLastPlayed: heard.addingTimeInterval(4)), "within the clocks' slack")
        XCTAssertTrue(BookProgress.isStale(eventAt: heard, serverLastPlayed: heard.addingTimeInterval(60)))
    }

    func testTakesServer() {
        let now = Date()
        XCTAssertTrue(BookProgress.takesServer(synced: true, localChangedAt: now, serverLastPlayed: nil))
        XCTAssertFalse(BookProgress.takesServer(synced: false, localChangedAt: now, serverLastPlayed: nil))
        XCTAssertTrue(BookProgress.takesServer(synced: false, localChangedAt: nil, serverLastPlayed: now))
        XCTAssertTrue(BookProgress.takesServer(synced: false, localChangedAt: now, serverLastPlayed: now.addingTimeInterval(60)))
        XCTAssertFalse(BookProgress.takesServer(synced: false, localChangedAt: now, serverLastPlayed: now.addingTimeInterval(3)))
    }

    func testTheServersDatesRead() throws {
        let a = try XCTUnwrap(BookProgress.date(fromServer: "2026-11-12T10:00:00.1234567Z"))
        let b = try XCTUnwrap(BookProgress.date(fromServer: "2026-11-12T10:00:00Z"))
        XCTAssertEqual(a.timeIntervalSince(b), 0.1234567, accuracy: 0.0001, "seven places of fraction")
        let noZone = try XCTUnwrap(BookProgress.date(fromServer: "2026-11-12T10:00:00.5"))
        XCTAssertEqual(noZone.timeIntervalSince(b), 0.5, accuracy: 0.001, "no zone is UTC")
        let offset = try XCTUnwrap(BookProgress.date(fromServer: "2026-11-12T11:00:00+01:00"))
        XCTAssertEqual(offset, b)
        XCTAssertNil(BookProgress.date(fromServer: nil))
        XCTAssertNil(BookProgress.date(fromServer: "  "))
        XCTAssertNil(BookProgress.date(fromServer: "yesterday"))
    }

    func testVideoProgressFinishedPast90Percent() {
        XCTAssertTrue(VideoProgress.isFinished(positionTicks: 91, runTimeTicks: 100))
        XCTAssertFalse(VideoProgress.isFinished(positionTicks: 90, runTimeTicks: 100))
        XCTAssertFalse(VideoProgress.isFinished(positionTicks: 0, runTimeTicks: 100))
        XCTAssertFalse(VideoProgress.isFinished(positionTicks: 50, runTimeTicks: 0))
    }
}
