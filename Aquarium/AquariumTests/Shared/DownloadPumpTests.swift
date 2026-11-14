//  The pump: which waiting download is started next, how many at once, and
//  what holds it — a pause, Wi-Fi only, one transcode at a time — and the
//  hand-off of the batch on the way to the background.
//
//  Signed in to the stub server, so the pump runs. Every download here is a
//  retry of a record that has no address of its own and no item kept for it,
//  which makes the pump's first step a question to the server
//  (`resolveThenStart`) — answered by `StubURLProtocol`, 404 unless stubbed.
//  So "started" is seen two ways without a transfer ever being made: the item
//  reads as downloading the instant its slot is taken, and the order of the
//  questions is the order of the starts.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadPumpTests: DownloadTestCase {
    override var signedIn: Bool { true }

    private static let unknown = "Couldn't ask the server about this item"

    /// The items the pump has asked the server about, in order.
    private var lookups: [String] {
        StubURLProtocol.requests.compactMap { request in
            guard let path = request.url?.path, path.hasPrefix("/Items/") else { return nil }
            return String(path.dropFirst("/Items/".count))
        }
    }

    private func isDownloading(_ id: String) -> Bool { manager.transferState(of: id) == .downloading }
    private func isWaiting(_ id: String) -> Bool { manager.transferState(of: id) == .queued }

    /// Failed downloads, queued again front to back in the order given, with
    /// the queue held so that none starts until the test lets it.
    private func queueHeld(_ ids: [String], type: String = "Movie", quality: String = "Original quality") {
        manager.setPaused(true)
        for id in ids { seed(id, .error, type: type) { $0.quality = quality } }
        for id in ids.reversed() { manager.retry(id) }
    }

    /// Every one of these looked up, refused, and left as a failure.
    private func allAnswered(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("the server has answered for every item", file: file, line: line) {
            ids.allSatisfy { self.manager.record(for: $0)?.status == .error && self.manager.transferState(of: $0) == nil }
        }
    }

    // MARK: Order and number

    func testOneAtATimeInQueueOrder() async {
        let a = newId(), b = newId(), c = newId()
        queueHeld([a, b, c])
        XCTAssertEqual(queued, [a, b, c])
        XCTAssertTrue(lookups.isEmpty, "held: nothing has started")

        manager.setPaused(false)
        XCTAssertTrue(isDownloading(a))
        XCTAssertTrue(isWaiting(b))
        XCTAssertTrue(isWaiting(c))
        XCTAssertEqual(queued, [b, c], "the one that started has left the queue")
        XCTExpectFailure("bug: transfersToFinish (the Downloads count and the Mac's Dock badge) leaves out an item whose lookup is in flight: it has left the queue and its record still says queued, so neither half counts it, Aquarium/Core/Downloads.swift:3668") {
            XCTAssertEqual(manager.transfersToFinish, 3)
        }

        await allAnswered([a, b, c])
        XCTAssertEqual(lookups, [a, b, c], "each started as the one before it ended, in the order they waited")
        XCTAssertTrue(queued.isEmpty)
    }

    func testAsManyAtOnceAsParallelDownloadsAllows() async {
        prefs.downloadConcurrency = 2
        let a = newId(), b = newId(), c = newId()
        queueHeld([a, b, c])
        manager.setPaused(false)
        XCTAssertTrue(isDownloading(a))
        XCTAssertTrue(isDownloading(b))
        XCTAssertTrue(isWaiting(c), "the third waits for a slot")
        await allAnswered([a, b, c])
    }

    func testAnItemTheServerCannotDescribeIsAFailureWithARetryNotGone() async throws {
        let id = newId()
        queueHeld([id])
        manager.setPaused(false)
        await allAnswered([id])
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.errorMessage, Self.unknown)
        XCTAssertEqual(manager.tally.failed.map(\.itemId), [id])
        XCTAssertFalse(manager.isQueuedOrRunning(id), "its slot is given back")
    }

    func testARetryWaitingOutItsDelayDoesNotHoldUpTheQueue() async throws {
        // At the front of the queue, not yet due: what is behind it starts,
        // and it is not started early.
        manager.setPaused(true)
        let waiting = newId(), behind = newId()
        seed(waiting, .downloading) { $0.createdAt = Date().addingTimeInterval(-60) }
        let task = await adopt(waiting)
        seed(behind, .error)
        manager.retry(behind)
        finish(task, with: URLError(.networkConnectionLost))
        await waitUntil("the dropped transfer is put back") { self.queued == [waiting, behind] }
        XCTAssertFalse(try XCTUnwrap(entry(waiting)).isDue(at: Date()))

        manager.setPaused(false)
        XCTAssertTrue(isDownloading(behind))
        XCTAssertTrue(isWaiting(waiting))
        await allAnswered([behind])
        XCTAssertEqual(lookups, [behind])
        XCTAssertEqual(queued, [waiting], "still waiting out its delay")
    }

    func testAStaleEntryForSomethingThatHasLandedIsDropped() async {
        let id = newId()
        queueHeld([id])
        // It landed meanwhile, by a transfer the saved queue never heard of.
        seed(id, .complete)
        manager.setPaused(false)
        XCTAssertFalse(isDownloading(id), "not fetched a second time")
        XCTAssertTrue(queued.isEmpty)
        await letCallbacksLand()
        XCTAssertEqual(manager.record(for: id)?.status, .complete)
        XCTAssertTrue(lookups.isEmpty)
    }

    // MARK: One transcode at a time

    func testOneTranscodeAtATimeLetsSongsPast() async {
        prefs.downloadConcurrency = 3
        prefs.transcodesOneAtATime = true
        let first = newId(), second = newId(), track = newId()
        manager.setPaused(true)
        seed(first, .error, type: "Movie") { $0.quality = self.p720.label }
        seed(second, .error, type: "Episode") { $0.quality = self.p720.label }
        seed(track, .error, type: "Audio") { $0.quality = self.p720.label }
        for id in [track, second, first] { manager.retry(id) }
        XCTAssertEqual(queued, [first, second, track])

        manager.setPaused(false)
        XCTAssertTrue(isDownloading(first))
        XCTAssertTrue(isWaiting(second), "a second encode waits for the first")
        XCTAssertTrue(isDownloading(track), "a song is no encode, whatever rung it was queued at")
        await allAnswered([first, second, track])
        XCTAssertEqual(lookups.last, second, "started once the first transcode was out of the way")
    }

    func testTranscodesRunSideBySideWithTheSwitchOff() async {
        prefs.downloadConcurrency = 3
        prefs.transcodesOneAtATime = false
        let first = newId(), second = newId()
        queueHeld([first, second], quality: p720.label)
        manager.setPaused(false)
        XCTAssertTrue(isDownloading(first))
        XCTAssertTrue(isDownloading(second))
        await allAnswered([first, second])
    }

    func testOriginalsAreNotHeldByTheTranscodeRule() async {
        prefs.downloadConcurrency = 3
        prefs.transcodesOneAtATime = true
        let first = newId(), second = newId()
        queueHeld([first, second], quality: "Original quality")
        manager.setPaused(false)
        XCTAssertTrue(isDownloading(first))
        XCTAssertTrue(isDownloading(second))
        await allAnswered([first, second])
    }

    // MARK: Pause

    func testNothingStartsWhilePaused() async {
        manager.setPaused(true)
        let fresh = newId(), failed = newId()
        // A fresh asking has everything it needs to start at once; only the
        // pause is holding it.
        XCTAssertTrue(manager.enqueue(item: film(fresh), quality: original))
        seed(failed, .error)
        manager.retry(failed)
        manager.handOffBeforeBackground()
        await letCallbacksLand()
        XCTAssertEqual(queued, [failed, fresh])
        XCTAssertTrue(isWaiting(fresh))
        XCTAssertTrue(isWaiting(failed))
        XCTAssertNil(manager.record(for: fresh), "never started, so never recorded")
        XCTAssertTrue(lookups.isEmpty)
        XCTAssertEqual(manager.pausedNote, " · downloads are paused")
    }

    func testAnItemPausedWhileItWasBeingLookedUpWaitsAtTheHead() async {
        // A pause stops what has a task, and this had none yet: it used to
        // start under a page that said "Paused".
        let id = newId(), behind = newId()
        StubURLProtocol.stub("/Items/\(id)", json: #"{"Id":"\#(id)","Name":"Film","Type":"Movie"}"#)
        queueHeld([behind])
        manager.setPaused(false)   // `behind` takes the slot and is asked about…
        await allAnswered([behind])
        seed(id, .error)
        manager.retry(id)
        XCTAssertTrue(isDownloading(id))

        manager.setPaused(true)
        await waitUntil("the lookup comes back to a paused queue") { self.queued == [id] }
        XCTAssertTrue(isWaiting(id))
        XCTAssertEqual(manager.record(for: id)?.status, .queued, "neither started nor written off")
        XCTAssertEqual(lookups, [behind, id])
    }

    // MARK: Called off mid-lookup

    func testACancelDuringTheLookupStartsNothing() async {
        let id = newId()
        StubURLProtocol.stub("/Items/\(id)", json: #"{"Id":"\#(id)","Name":"Film","Type":"Movie"}"#)
        queueHeld([id])
        manager.setPaused(false)
        XCTAssertTrue(isDownloading(id))

        manager.cancel(id)
        XCTAssertNil(manager.transferState(of: id))
        await waitUntil("the lookup is answered") { self.lookups == [id] }
        await letCallbacksLand()
        XCTAssertNil(manager.record(for: id), "not started, and not written off as a failure either")
        XCTAssertNil(manager.transferState(of: id))
        XCTAssertTrue(queued.isEmpty)
    }

    func testSigningOutCallsOffTheQueueAndWhatIsInFlight() async throws {
        let looking = newId(), waiting = newId(), fresh = newId(), finished = newId(), failed = newId()
        seed(finished, .complete)
        seed(failed, .error)
        queueHeld([looking, waiting])
        manager.enqueue(item: film(fresh), quality: original)
        let resume = DownloadManager.folder(for: failed).appendingPathComponent("resume.data")
        try Data("old request, old token".utf8).write(to: resume)
        manager.setPaused(false)
        XCTAssertTrue(isDownloading(looking))

        manager.endSession()
        XCTAssertTrue(queued.isEmpty, "the queue was built against the old server")
        XCTAssertFalse(manager.isPaused)
        XCTAssertNil(manager.record(for: looking), "unfinished downloads go, files and all")
        XCTAssertNil(manager.record(for: waiting))
        assertFolderGone(looking)
        XCTAssertEqual(manager.record(for: finished)?.status, .complete, "finished downloads are the person's files")
        XCTAssertEqual(manager.record(for: failed)?.status, .error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path), "resume data carries the old token")
        XCTAssertNil(manager.transferState(of: fresh))

        await waitUntil("the lookup is answered") { self.lookups == [looking] }
        await letCallbacksLand()
        XCTAssertNil(manager.record(for: looking), "the answer, arriving after the sign-out, writes nothing")
        XCTAssertNil(manager.transferState(of: looking))
        manager.flushPersisted()
        let saved = UserDefaults.standard.data(forKey: "download_queue")
            .flatMap { try? JSONDecoder().decode([QueuedDownload].self, from: $0) }
        XCTAssertEqual(saved?.count, 0)
    }

    // MARK: Wi-Fi only

    func testWiFiOnlyHoldsEverythingOnCellularUntilWiFiIsBack() async {
        prefs.downloadsWiFiOnly = true
        manager.setRouteForTests(satisfied: true, cellularOnly: true)
        let a = newId(), b = newId()
        for id in [a, b] { seed(id, .error) }
        manager.retry(b)
        manager.retry(a)
        XCTAssertTrue(isWaiting(a), "nothing starts on cellular")
        XCTAssertTrue(isWaiting(b))
        manager.handOffBeforeBackground()
        XCTAssertEqual(queued, [a, b], "nor is the batch handed to the system")
        XCTAssertTrue(lookups.isEmpty)

        manager.setRouteForTests(satisfied: true, cellularOnly: false)
        XCTAssertTrue(isDownloading(a), "Wi-Fi back: the queue goes")
        await allAnswered([a, b])
        XCTAssertEqual(lookups, [a, b])
    }

    func testCellularIsARouteWithWiFiOnlyOff() async {
        prefs.downloadsWiFiOnly = false
        manager.setRouteForTests(satisfied: true, cellularOnly: true)
        let id = newId()
        seed(id, .error)
        manager.retry(id)
        XCTAssertTrue(isDownloading(id))
        await allAnswered([id])
    }

    func testAPathWithNoInternetDoesNotHoldTheQueue() async {
        // A server on the local network, reached with no way out to the
        // internet, reads as "unsatisfied" — and downloads from it have
        // always worked. Only Wi-Fi-only-on-cellular holds the queue.
        manager.setRouteForTests(satisfied: false, cellularOnly: false)
        let id = newId()
        seed(id, .error)
        manager.retry(id)
        XCTAssertTrue(isDownloading(id))
        await allAnswered([id])
    }

    func testTurningWiFiOnlyOffOnCellularStartsTheQueue() async {
        prefs.downloadsWiFiOnly = true
        manager.setRouteForTests(satisfied: true, cellularOnly: true)
        // The manager follows the setting a turn of the main actor later.
        await letCallbacksLand()
        let id = newId()
        seed(id, .error)
        manager.retry(id)
        XCTAssertTrue(isWaiting(id))

        prefs.downloadsWiFiOnly = false
        await allAnswered([id])
        XCTAssertEqual(lookups, [id])
    }

    // MARK: Handing the batch to the system

    func testHandOffStartsTheWholeBatchPastTheParallelLimit() async {
        // A file task started from the background waits for the foreground,
        // so on the way out everything waiting is started at once.
        let songs = (0..<8).map { _ in newId() }
        queueHeld(songs, type: "Audio")
        manager.setPaused(false)
        XCTAssertEqual(songs.filter(isDownloading).count, 1, "in front: Parallel downloads is one")
        XCTAssertEqual(queued.count, 7)

        manager.handOffBeforeBackground()
        XCTAssertTrue(queued.isEmpty, "the whole batch is in the system's hands")
        XCTAssertEqual(songs.filter(isDownloading).count, 8)
        await allAnswered(songs)
        XCTAssertEqual(Set(lookups), Set(songs))
        XCTAssertEqual(lookups.count, 8, "each started once")
    }

    func testHandOffStopsAtSixteen() async {
        let songs = (0..<20).map { _ in newId() }
        queueHeld(songs, type: "Audio")
        manager.setPaused(false)
        manager.handOffBeforeBackground()
        XCTAssertEqual(songs.filter(isDownloading).count, 17, "the one running and sixteen handed over")
        XCTAssertEqual(queued, Array(songs.suffix(3)), "the rest wait, still in order")
        await allAnswered(songs)
        XCTAssertEqual(lookups.count, 20)
    }

    func testHandOffHoldsTranscodesToTheParallelLimit() async {
        // Each is an encode on the server, and nothing pings it while the
        // app is suspended: a season handed over at once was a dozen encodes
        // being stopped and restarted all night.
        prefs.transcodesOneAtATime = false
        let films = (0..<4).map { _ in newId() }, songs = (0..<3).map { _ in newId() }
        manager.setPaused(true)
        for id in films { seed(id, .error, type: "Movie") { $0.quality = self.p720.label } }
        for id in songs { seed(id, .error, type: "Audio") }
        for id in (films + songs).reversed() { manager.retry(id) }
        manager.setPaused(false)
        XCTAssertEqual(films.filter(isDownloading), [films[0]])

        manager.handOffBeforeBackground()
        XCTAssertEqual(films.filter(isDownloading), [films[0]], "one encode, as in front")
        XCTAssertEqual(songs.filter(isDownloading), songs, "files all go")
        XCTAssertEqual(queued, Array(films.dropFirst()))
        await allAnswered(films + songs)
    }

    func testHandOffRunsAsManyTranscodesAsParallelDownloads() async {
        prefs.transcodesOneAtATime = false
        prefs.downloadConcurrency = 2
        let films = (0..<4).map { _ in newId() }, songs = (0..<3).map { _ in newId() }
        manager.setPaused(true)
        for id in films { seed(id, .error, type: "Movie") { $0.quality = self.p720.label } }
        for id in songs { seed(id, .error, type: "Audio") }
        for id in (songs + films).reversed() { manager.retry(id) }
        manager.setPaused(false)
        XCTAssertEqual(songs.filter(isDownloading).count, 2)

        manager.handOffBeforeBackground()
        XCTAssertEqual(films.filter(isDownloading).count, 2)
        XCTAssertEqual(songs.filter(isDownloading).count, 3)
        XCTAssertEqual(queued, Array(films.suffix(2)))
        await allAnswered(films + songs)
    }

    func testHandOffLeavesARetryToWaitOutItsDelay() async throws {
        let waiting = newId(), song = newId()
        manager.setPaused(true)
        seed(waiting, .downloading, type: "Audio")
        let task = await adopt(waiting)
        finish(task, with: URLError(.timedOut))
        await waitUntil("the timed-out transfer is put back") { self.queued == [waiting] }
        seed(song, .error, type: "Audio")
        manager.retry(song)
        manager.setPaused(false)
        XCTAssertTrue(isDownloading(song))

        manager.handOffBeforeBackground()
        XCTAssertEqual(queued, [waiting], "not due, so not started early")
        await allAnswered([song])
    }

    func testHandOffWithNothingWaitingDoesNothing() async {
        manager.handOffBeforeBackground()
        XCTAssertTrue(queued.isEmpty)
        XCTAssertTrue(lookups.isEmpty)
    }
}
#endif
