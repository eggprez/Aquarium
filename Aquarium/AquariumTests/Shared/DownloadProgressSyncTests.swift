//  Watch state noted against a download while the server was out of reach,
//  going back to it (`OfflineProgress`): what is sent, in what order, what
//  the server's own newer account overrides, what happens to a download whose
//  item the server has dropped, and what a deleted download still owes.
//  Signed in to the stub server; every answer is `StubURLProtocol`'s.
//  See Support/DownloadHarness.swift.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadProgressSyncTests: DownloadTestCase {
    override var signedIn: Bool { true }

    private let minute: Int64 = 600_000_000

    override func setUp() async throws {
        try await super.setUp()
        for path in ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"] {
            StubURLProtocol.stub(path, method: "POST", status: 204)
        }
    }

    /// A finished download of this account's with watch state the server
    /// hasn't heard.
    @discardableResult
    private func unsent(
        _ id: String, type: String = "Movie", _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) -> DownloadRecord {
        seed(id, .complete, type: type) {
            $0.runTimeTicks = 100 * self.minute
            $0.progressSynced = false
            $0.progressRevision = 1
            $0.progressChangedAt = Date().addingTimeInterval(-3_600)
            $0.ownerUserId = ClientStub.userId
            configure(&$0)
        }
    }

    /// What the server says of these ids when asked for the lot.
    private func serverHas(_ items: [String]) {
        StubURLProtocol.stub("/Items", json: #"{"Items":[\#(items.joined(separator: ","))]}"#)
    }

    private func serverItem(_ id: String, lastPlayed: Date? = nil, position: Int64 = 0, played: Bool = false) -> String {
        let date = lastPlayed.map { #","LastPlayedDate":"\#(ISO8601DateFormatter().string(from: $0))""# } ?? ""
        return #"{"Id":"\#(id)","Name":"Film","Type":"Movie","RunTimeTicks":60000000000,"UserData":{"Played":\#(played),"PlaybackPositionTicks":\#(position)\#(date)}}"#
    }

    private func accepts(_ method: String, _ path: String, status: Int = 204) {
        StubURLProtocol.stub(path, method: method, status: status)
    }

    /// "METHOD path" of every request that changes something on the server.
    private var writes: [String] {
        StubURLProtocol.requests.compactMap { request in
            guard let method = request.httpMethod, method != "GET", let path = request.url?.path else { return nil }
            return "\(method) \(path)"
        }
    }

    private func body(of write: String) -> [String: Any]? {
        StubURLProtocol.requests
            .last { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" == write }
            .flatMap(StubURLProtocol.jsonBody(of:))
    }

    // MARK: Nothing to do

    func testNothingNotedAsksTheServerNothing() async {
        seed(newId(), .complete)
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path == "/System/Info/Public" }, "not even a probe")
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(OfflineProgress.pendingCount, 0)
    }

    func testAnotherAccountsStateIsNotSentFromThisOne() async {
        // With nothing to say whose it was, signing in as someone else sent
        // it to them.
        let id = newId()
        unsent(id) {
            $0.played = true
            $0.ownerUserId = "someone-else"
        }
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced + result.failed, 0)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, false, "still theirs to send")
        XCTAssertEqual(OfflineProgress.pendingCount, 0, "and not counted here, or the number never came down")
    }

    func testSignedOutSendsNothing() async {
        unsent(newId()) { $0.played = true }
        ClientStub.remove()
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced + result.failed, 0)
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: What is sent

    func testAWatchedFlagGoesToThePlayedItemsEndpoint() async {
        let id = newId()
        unsent(id) {
            $0.played = true
            $0.positionTicks = 0
        }
        serverHas([serverItem(id)])
        accepts("POST", "/UserPlayedItems/\(id)")
        XCTAssertEqual(OfflineProgress.pendingCount, 1)

        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.gone, 0)
        XCTAssertEqual(writes, ["POST /UserPlayedItems/\(id)"], "watched needs no stopped report")
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
        XCTAssertEqual(OfflineProgress.pendingCount, 0)
        XCTAssertEqual(recordOnDisk(id)?.progressSynced, true)
    }

    func testAResumePointGoesAsAStoppedReport() async throws {
        let id = newId()
        unsent(id) { $0.positionTicks = 10 * self.minute }
        serverHas([serverItem(id)])
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(writes, ["POST /Sessions/Playing/Stopped"], "there is no set-position endpoint that does it alone")
        let report = try XCTUnwrap(body(of: "POST /Sessions/Playing/Stopped"))
        XCTAssertEqual(report["ItemId"] as? String, id)
        XCTAssertEqual((report["PositionTicks"] as? NSNumber)?.int64Value, 10 * minute)
        XCTAssertEqual(report["IsPaused"] as? Bool, true)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
    }

    func testUnwatchingIsSaidBeforeTheResumePoint() async {
        // The server keeps its tick through a stopped report, so the un-mark
        // goes first, in so many words.
        let id = newId()
        unsent(id) {
            $0.unplayedPending = true
            $0.positionTicks = 5 * self.minute
        }
        serverHas([serverItem(id, played: true)])
        accepts("DELETE", "/UserPlayedItems/\(id)")
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(writes, ["DELETE /UserPlayedItems/\(id)", "POST /Sessions/Playing/Stopped"])
        XCTAssertEqual(manager.record(for: id)?.unplayedPending, false)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
    }

    func testUnwatchedFromTheTopSendsOnlyTheUnmark() async {
        let id = newId()
        seed(id, .complete) { $0.ownerUserId = ClientStub.userId }
        manager.setPlayed(id, played: false)
        serverHas([serverItem(id, played: true)])
        accepts("DELETE", "/UserPlayedItems/\(id)")
        await OfflineProgress.sync()
        XCTAssertEqual(writes, ["DELETE /UserPlayedItems/\(id)"], "a stopped report at nothing would say nothing")
    }

    func testSeveralGoInOneSyncAndAFailureWaitsForTheNext() async {
        let fine = newId(), refused = newId()
        unsent(fine) { $0.played = true }
        unsent(refused) { $0.played = true }
        serverHas([serverItem(fine), serverItem(refused)])
        accepts("POST", "/UserPlayedItems/\(fine)")
        accepts("POST", "/UserPlayedItems/\(refused)", status: 500)

        var result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(manager.record(for: fine)?.progressSynced, true)
        XCTAssertEqual(manager.record(for: refused)?.progressSynced, false, "kept, to go next time")
        XCTAssertEqual(OfflineProgress.pendingCount, 1)

        accepts("POST", "/UserPlayedItems/\(refused)")
        result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(OfflineProgress.pendingCount, 0)
    }

    func testAResumePointThatDoesNotLandIsNotMarkedSent() async {
        let id = newId()
        unsent(id) { $0.positionTicks = 10 * self.minute }
        serverHas([serverItem(id)])
        StubURLProtocol.stub("/Sessions/Playing/Stopped", method: "POST", status: 500)
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, false, "a server blip must not drop the resume point for good")
    }

    func testWithTheServerOutOfReachEverythingWaits() async {
        unsent(newId()) { $0.played = true }
        unsent(newId()) { $0.positionTicks = self.minute }
        StubURLProtocol.stub("/System/Info/Public", status: 500)
        let result = await OfflineProgress.sync()
        // Back before anything is checked: the client's own account of
        // whether there is a server must not outlive this test.
        stubServerIdentity()
        let back = await JellyfinClient.shared.checkOnline()
        XCTAssertTrue(back)

        XCTAssertEqual(result.synced, 0)
        XCTAssertEqual(result.failed, 2)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(OfflineProgress.pendingCount, 2)
    }

    func testTwoSyncsAtOnceSendEachThingOnce() async {
        // The shell syncs at launch and each time the app is come back to;
        // the player syncs as it closes; the Downloads page has a button.
        // Nothing keeps two of them from running together.
        let id = newId()
        unsent(id) { $0.positionTicks = 10 * self.minute }
        serverHas([serverItem(id)])
        async let first = OfflineProgress.sync()
        async let second = OfflineProgress.sync()
        _ = await (first, second)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
        XCTAssertEqual(writes, ["POST /Sessions/Playing/Stopped"], "the second sync waits for the first and sends nothing of its own")
    }

    // MARK: Whose account is newer

    func testPlayedSomewhereElseSinceTheServersAccountWins() async throws {
        // Left at ten minutes offline and finished on the TV meanwhile: sent
        // regardless, it went back to ten minutes.
        let id = newId()
        unsent(id) { $0.positionTicks = 10 * self.minute }
        serverHas([serverItem(id, lastPlayed: Date(), position: 0, played: true)])
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertTrue(writes.isEmpty, "nothing is sent")
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertTrue(rec.played)
        XCTAssertEqual(rec.positionTicks, 0)
        XCTAssertTrue(rec.progressSynced)
    }

    func testPlayedHereSinceThisDevicesAccountWins() async {
        let id = newId()
        unsent(id) { $0.positionTicks = 10 * self.minute }
        serverHas([serverItem(id, lastPlayed: Date().addingTimeInterval(-7_200), position: 99, played: false)])
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(writes, ["POST /Sessions/Playing/Stopped"])
        XCTAssertEqual(manager.record(for: id)?.positionTicks, 10 * minute)
    }

    // MARK: An item the server has dropped

    func testAnEpisodeGoneForGoodStopsWaitingToBeSent() async throws {
        // The watched flag went to the old id, the server said 404, and
        // every sync after counted it as a failure: "Syncing 1 item", for ever.
        let id = newId()
        unsent(id, type: "Episode") {
            $0.played = true
            $0.series = "Show"
            $0.seriesId = "show1"
            $0.season = 1
            $0.episode = 2
        }
        serverHas([])
        StubURLProtocol.stub("/Shows/show1/Episodes", json: #"{"Items":[{"Id":"other","Type":"Episode","ParentIndexNumber":1,"IndexNumber":3}]}"#)
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.gone, 1)
        XCTAssertEqual(result.synced, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(writes.isEmpty, "there is nothing to tell")
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertTrue(rec.progressSynced)
        XCTAssertTrue(rec.played, "the device's own copy keeps what it knows")
        XCTAssertEqual(OfflineProgress.pendingCount, 0)
    }

    func testAWholeSeriesGoneIsGoneToo() async {
        let id = newId()
        unsent(id, type: "Episode") {
            $0.played = true
            $0.seriesId = "dropped"
            $0.season = 1
            $0.episode = 1
        }
        serverHas([])   // and /Shows/dropped/Episodes answers 404
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.gone, 1)
        XCTAssertEqual(result.failed, 0)
    }

    func testAnEpisodeBackUnderANewIdHasItsStateSentThere() async throws {
        let old = newId(), new = newId()
        unsent(old, type: "Episode") {
            $0.played = true
            $0.seriesId = "show1"
            $0.season = 1
            $0.episode = 2
        }
        serverHas([])
        StubURLProtocol.stub("/Shows/show1/Episodes", json: """
        {"Items":[{"Id":"\(old)","Type":"Episode","ParentIndexNumber":1,"IndexNumber":2},
                  {"Id":"wrong","Type":"Episode","ParentIndexNumber":2,"IndexNumber":2},
                  {"Id":"\(new)","Type":"Episode","ParentIndexNumber":1,"IndexNumber":2}]}
        """)
        accepts("POST", "/UserPlayedItems/\(new)")
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(result.gone, 0)
        XCTAssertEqual(writes, ["POST /UserPlayedItems/\(new)"])
        XCTAssertEqual(manager.record(for: old)?.progressSynced, true)
        // The download itself moves over at the next launch, when nothing
        // can be playing it.
        XCTAssertNotNil(manager.record(for: old))
        let moves = UserDefaults.standard.dictionary(forKey: "downloads.pendingRekeys") as? [String: String]
        XCTAssertEqual(moves?[old], new)
    }

    func testAFilmBackUnderANewIdIsFoundByNameAndLength() async throws {
        let old = newId(), new = newId()
        unsent(old) {
            $0.name = "Heat"
            $0.positionTicks = 10 * self.minute
        }
        // The one answer serves both questions: the ids asked for (the old
        // one is not among them) and the search by name.
        StubURLProtocol.stub("/Items", json: """
        {"Items":[{"Id":"remake","Name":"Heat","Type":"Movie","RunTimeTicks":\(90 * minute)},
                  {"Id":"\(new)","Name":"Heat","Type":"Movie","RunTimeTicks":\(100 * minute + 20_000_000)}]}
        """)
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(writes, ["POST /Sessions/Playing/Stopped"])
        XCTAssertEqual(body(of: "POST /Sessions/Playing/Stopped")?["ItemId"] as? String, new, "not the remake")
        let search = try XCTUnwrap(StubURLProtocol.requests.last { $0.url?.query?.contains("searchTerm=Heat") == true })
        XCTAssertTrue(search.url?.query?.contains("IncludeItemTypes=Movie") == true)
    }

    func testAMoveTheServerRefusesIsTriedAgainNextTime() async {
        let old = newId(), new = newId()
        unsent(old, type: "Episode") {
            $0.played = true
            $0.seriesId = "show1"
            $0.season = 1
            $0.episode = 2
        }
        serverHas([])
        StubURLProtocol.stub("/Shows/show1/Episodes", json: #"{"Items":[{"Id":"\#(new)","Type":"Episode","ParentIndexNumber":1,"IndexNumber":2}]}"#)
        accepts("POST", "/UserPlayedItems/\(new)", status: 500)
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(manager.record(for: old)?.progressSynced, false)
    }

    func testADownloadIsOnlyMovedOnceTheServerSaysTheOldIdHasGone() async {
        let gone = newId(), still = newId()
        StubURLProtocol.stub("/Items/\(still)", json: serverItem(still))
        manager.noteFoundUnderNewId(still, newId: "elsewhere")
        manager.noteFoundUnderNewId(gone, newId: "replacement")   // /Items/<gone> answers 404
        manager.noteFoundUnderNewId(gone, newId: gone)
        func moves() -> [String: String] {
            UserDefaults.standard.dictionary(forKey: "downloads.pendingRekeys") as? [String: String] ?? [:]
        }
        await waitUntil("the server has said the old id is gone") { moves()[gone] != nil }
        await waitUntil("the server has answered for the other") {
            StubURLProtocol.requests.contains { $0.url?.path == "/Items/\(still)" }
        }
        await letCallbacksLand()
        XCTAssertEqual(moves()[gone], "replacement")
        XCTAssertNil(moves()[still], "never on a guess")
    }

    // MARK: What a deleted download still owes

    func testWhatADeletedDownloadOwedIsSentAndSettled() async {
        let id = newId()
        unsent(id) { $0.played = true }
        manager.delete(id)
        XCTAssertEqual(OfflineProgress.pendingCount, 1)
        serverHas([serverItem(id)])
        accepts("POST", "/UserPlayedItems/\(id)")

        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(writes, ["POST /UserPlayedItems/\(id)"])
        XCTAssertTrue(manager.owedProgress.isEmpty)
        XCTAssertEqual(OfflineProgress.pendingCount, 0)
    }

    func testWhatIsOwedForAnItemTheServerHasDroppedIsLetGo() async {
        let id = newId()
        unsent(id) { $0.played = true }
        manager.delete(id)
        serverHas([])   // and the played-items endpoint answers 404
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(manager.owedProgress.isEmpty, "gone from the server: there is nothing to tell")
    }

    func testWhatIsOwedStaysOwedThroughAFailure() async {
        let id = newId()
        unsent(id) { $0.played = true }
        manager.delete(id)
        serverHas([serverItem(id)])
        accepts("POST", "/UserPlayedItems/\(id)", status: 500)
        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(manager.owedProgress.map(\.itemId), [id])
    }

    func testWhatIsOwedIsNotSentOverANewerPlayElsewhereOrANewerDownload() async {
        // Played on the TV since: the old account of it would take it back.
        let elsewhere = newId()
        unsent(elsewhere) { $0.positionTicks = self.minute }
        manager.delete(elsewhere)
        // Downloaded again and watched further: the record says something newer.
        let again = newId()
        unsent(again) { $0.positionTicks = self.minute }
        manager.delete(again)
        unsent(again) { $0.positionTicks = 30 * self.minute }
        XCTAssertEqual(manager.owedProgress.count, 2)
        serverHas([serverItem(elsewhere, lastPlayed: Date(), played: true), serverItem(again)])

        let result = await OfflineProgress.sync()
        XCTAssertEqual(result.synced, 3)
        XCTAssertEqual(writes, ["POST /Sessions/Playing/Stopped"], "one report: the newer download's")
        XCTAssertEqual((body(of: "POST /Sessions/Playing/Stopped")?["PositionTicks"] as? NSNumber)?.int64Value, 30 * minute)
        XCTAssertTrue(manager.owedProgress.isEmpty)
    }

    // MARK: Taking the server's state

    func testRefreshTakesTheServersStateForWhatHasNothingUnsent() async {
        let synced = newId(), waiting = newId(), theirs = newId()
        seed(synced, .complete) { $0.ownerUserId = ClientStub.userId }
        unsent(waiting) { $0.positionTicks = self.minute }
        seed(theirs, .complete) { $0.ownerUserId = "someone-else" }
        serverHas([
            serverItem(synced, position: 7 * minute, played: false),
            serverItem(waiting, position: 0, played: true),
            serverItem(theirs, position: 0, played: true),
        ])
        await OfflineProgress.refreshFromServer()
        XCTAssertEqual(manager.record(for: synced)?.positionTicks, 7 * minute, "watched on another device: seen here too")
        XCTAssertEqual(manager.record(for: synced)?.progressSynced, true)
        XCTAssertEqual(manager.record(for: waiting)?.positionTicks, minute, "unsent local changes are newer")
        XCTAssertEqual(manager.record(for: waiting)?.played, false)
        XCTAssertEqual(manager.record(for: theirs)?.played, false, "another account's is not this one's to overwrite")
        let asked = StubURLProtocol.requests
            .filter { $0.url?.path == "/Items" }
            .compactMap { $0.url?.query }
            .filter { $0.contains("Ids=") }
        XCTAssertTrue(asked.contains { $0.contains(synced) })
        XCTAssertFalse(asked.contains { $0.contains(waiting) }, "only what could take the answer is asked about")
        XCTAssertFalse(asked.contains { $0.contains(theirs) })
    }

    // MARK: A sitting with the server in reach

    func testASittingIsOneStartProgressAndOneStop() async throws {
        // Each beat used to be a stopped report: one episode from the
        // device's own copy was logged as dozens of plays.
        let id = newId()
        seed(id, .complete) {
            $0.runTimeTicks = 100 * self.minute
            $0.ownerUserId = ClientStub.userId
        }
        let sitting = OfflineProgress.Session(itemId: id)
        XCTAssertFalse(sitting.started)

        await OfflineProgress.push(sitting, paused: false)
        XCTAssertTrue(writes.isEmpty, "nothing noted yet, nothing to say")

        manager.noteProgress(itemId: id, positionSeconds: 60)
        await OfflineProgress.push(sitting, paused: false)
        XCTAssertTrue(sitting.started)
        XCTAssertEqual(writes, ["POST /Sessions/Playing"])
        var report = try XCTUnwrap(body(of: "POST /Sessions/Playing"))
        XCTAssertEqual(report["PlaySessionId"] as? String, sitting.playSessionId, "a session of its own")
        XCTAssertEqual(report["ItemId"] as? String, id)
        XCTAssertEqual((report["PositionTicks"] as? NSNumber)?.int64Value, minute)
        XCTAssertEqual(report["IsPaused"] as? Bool, false)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true, "the server has it")

        manager.noteProgress(itemId: id, positionSeconds: 120)
        await OfflineProgress.push(sitting, paused: true)
        XCTAssertEqual(writes, ["POST /Sessions/Playing", "POST /Sessions/Playing/Progress"])
        report = try XCTUnwrap(body(of: "POST /Sessions/Playing/Progress"))
        XCTAssertEqual(report["PlaySessionId"] as? String, sitting.playSessionId)
        XCTAssertEqual(report["IsPaused"] as? Bool, true)

        manager.noteProgress(itemId: id, positionSeconds: 180)
        await OfflineProgress.end(sitting)
        XCTAssertEqual(writes, ["POST /Sessions/Playing", "POST /Sessions/Playing/Progress", "POST /Sessions/Playing/Stopped"])
        report = try XCTUnwrap(body(of: "POST /Sessions/Playing/Stopped"))
        XCTAssertEqual((report["PositionTicks"] as? NSNumber)?.int64Value, 3 * minute)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
        XCTAssertEqual(OfflineProgress.pendingCount, 0)
    }

    func testAStartTheServerDidNotHearIsTriedAgainOnTheNextBeat() async {
        let id = newId()
        unsent(id) { $0.positionTicks = self.minute }
        let sitting = OfflineProgress.Session(itemId: id)
        StubURLProtocol.stub("/Sessions/Playing", method: "POST", status: 500)
        await OfflineProgress.push(sitting, paused: false)
        XCTAssertFalse(sitting.started)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, false)

        StubURLProtocol.stub("/Sessions/Playing", method: "POST", status: 204)
        await OfflineProgress.push(sitting, paused: false)
        XCTAssertTrue(sitting.started)
        XCTAssertEqual(writes, ["POST /Sessions/Playing", "POST /Sessions/Playing"], "a start again, not progress on nothing")
    }

    func testASittingTheServerNeverHeardIsSaidInOneReportAtTheEnd() async {
        let id = newId()
        unsent(id) { $0.positionTicks = 10 * self.minute }
        serverHas([serverItem(id)])
        let sitting = OfflineProgress.Session(itemId: id)
        await OfflineProgress.end(sitting)
        XCTAssertEqual(writes, ["POST /Sessions/Playing/Stopped"], "left to the sync, which says it once")
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
    }

    func testFinishingDuringASittingLeavesTheWatchedFlagForTheSync() async {
        // The server applies its own threshold to the position it is sent;
        // the flag is said in so many words afterwards.
        let id = newId()
        unsent(id) {
            $0.played = true
            $0.positionTicks = 99 * self.minute
        }
        serverHas([serverItem(id)])
        accepts("POST", "/UserPlayedItems/\(id)")
        let sitting = OfflineProgress.Session(itemId: id)
        await OfflineProgress.push(sitting, paused: false)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, false)

        await OfflineProgress.end(sitting)
        XCTAssertEqual(writes, ["POST /Sessions/Playing", "POST /Sessions/Playing/Stopped", "POST /UserPlayedItems/\(id)"])
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
    }

    func testASittingThatOutlastsItsAccountStopsSending() async {
        let id = newId()
        unsent(id) { $0.positionTicks = self.minute }
        let sitting = OfflineProgress.Session(itemId: id)
        // Signed in as someone else on the same server.
        let prefs = JellyfinClient.shared.prefs
        var other = prefs.session
        other?.userId = "ffffffffffffffffffffffffffffffff"
        prefs.session = other
        await OfflineProgress.push(sitting, paused: false)
        XCTAssertTrue(writes.isEmpty, "the reports would go under whoever is signed in now")
        XCTAssertFalse(sitting.started)
    }
}
#endif
