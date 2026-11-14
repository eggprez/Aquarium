//  What a transfer that stops does next: put back for another go, after how
//  long, how many times, and when it is left as a failure with a Retry on it.
//  And the other end of a transfer — a file that arrives and is checked
//  before it is called a download.
//
//  Failures are delivered to the manager's own delegate methods: by hand for
//  errors, and by a real task answered by `StubURLProtocol` where the server's
//  status or the file itself is the point. Nobody is signed in, so whatever
//  is put back stays in the queue. See Support/DownloadHarness.swift.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadFailureTests: DownloadTestCase {
    /// A transfer for `id` that was running and then stopped with `error`.
    private func fail(
        _ id: String, with error: any Error, type: String? = "Movie",
        _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) async {
        seed(id, .downloading, type: type, configure)
        let task = await adopt(id)
        finish(task, with: error)
        await waitUntil("the failure of \(id) is dealt with") { self.manager.record(for: id)?.status != .downloading }
    }

    /// Seconds from now until the entry may start.
    private func delay(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> TimeInterval {
        guard let at = entry(id)?.retryAt else {
            XCTFail("\(id) has no wait on it", file: file, line: line)
            return -1
        }
        return at.timeIntervalSinceNow
    }

    // MARK: Put back for another go

    func testADroppedConnectionIsTriedAgainByItself() async throws {
        let id = newId()
        await fail(id, with: URLError(.networkConnectionLost)) { $0.quality = "720p · 4.5 Mbps (transcoded)" }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued, "not a row in the failed list")
        XCTAssertEqual(rec.errorMessage, "The connection was lost — trying again")
        XCTAssertEqual(rec.autoRetries, 1)
        XCTAssertEqual(queued, [id])
        let entry = try XCTUnwrap(entry(id))
        XCTAssertTrue(entry.isRetry, "picks up from what had arrived")
        XCTAssertEqual(entry.reason, "The connection was lost — trying again")
        XCTAssertEqual(entry.quality, "720p · 4.5 Mbps (transcoded)")
        XCTAssertFalse(entry.isDue(at: Date()), "after a wait, not at once")
        XCTAssertEqual(delay(id), 5, accuracy: 3)
        XCTAssertEqual(manager.transferState(of: id), .queued, "waiting, with its slot given back")
        XCTAssertTrue(manager.tally.failed.isEmpty)
    }

    func testEachFailureInARowWaitsLonger() async throws {
        let waits: [TimeInterval] = [5, 15, 45, 120, 300]
        let error = URLError(.badServerResponse)
        let words = DownloadManager.classify(error).summary
        for (already, wait) in waits.enumerated() {
            let id = newId()
            await fail(id, with: error) { $0.autoRetries = already }
            let rec = try XCTUnwrap(manager.record(for: id))
            XCTAssertEqual(rec.status, .queued, "go \(already + 1)")
            XCTAssertEqual(rec.autoRetries, already + 1)
            XCTAssertEqual(rec.errorMessage, "\(words) — trying again")
            XCTAssertEqual(delay(id), wait, accuracy: 3, "go \(already + 1)")
        }
    }

    func testTheSixthFailureInARowIsLeftAsAFailure() async throws {
        let id = newId()
        await fail(id, with: URLError(.timedOut)) { $0.autoRetries = 5 }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .error)
        XCTAssertEqual(rec.errorMessage, "The server stopped answering — stopped after 5 attempts")
        XCTAssertTrue(queued.isEmpty, "it stops and asks")
        XCTAssertEqual(manager.tally.failed.map(\.itemId), [id])
        XCTAssertEqual(recordOnDisk(id)?.status, .error)

        // The button gives it the full run again.
        manager.retry(id)
        XCTAssertEqual(manager.record(for: id)?.autoRetries, 0)
        XCTAssertEqual(queued, [id])
    }

    func testAttemptsThatGotSomewhereStartTheCountAgain() async {
        // A long download over a link that keeps dropping is not bounded by
        // five goes; one that fails from the same place every time is.
        let moving = newId(), stuck = newId()
        seed(moving, .downloading) { $0.autoRetries = 4 }
        seed(stuck, .downloading) { $0.autoRetries = 4 }
        await adopt(moving, received: 5 << 20, expected: 100 << 20)
        await adopt(stuck, received: 200_000, expected: 100 << 20)
        XCTAssertEqual(manager.record(for: moving)?.autoRetries, 0, "a few megabytes is progress")
        XCTAssertEqual(manager.record(for: stuck)?.autoRetries, 4, "one more segment and dying is not")
    }

    func testAnUnrecognisedErrorGetsItsGoes() async throws {
        let id = newId()
        let odd = NSError(domain: "CoreMediaErrorDomain", code: -12345, userInfo: [NSLocalizedDescriptionKey: "Something odd"])
        await fail(id, with: odd)
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued, "a retry is cheap; a download stopped on a hunch is not")
        XCTAssertEqual(rec.errorMessage, "Something odd — trying again")
        XCTAssertEqual(rec.autoRetries, 1)
    }

    // MARK: No network is not a failure

    func testWithNoNetworkItWaitsForOneAndIsNotCounted() async throws {
        manager.setRouteForTests(satisfied: false, cellularOnly: false)
        let id = newId()
        await fail(id, with: URLError(.notConnectedToInternet)) { $0.autoRetries = 5 }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued, "a phone with no signal is not evidence the download is broken")
        XCTAssertEqual(rec.autoRetries, 5, "or a long train journey would use up every go")
        XCTAssertEqual(rec.errorMessage, "The connection was lost — waiting for a connection")
        XCTAssertEqual(delay(id), 90, accuracy: 5)

        manager.setRouteForTests(satisfied: true, cellularOnly: false)
        XCTAssertNil(entry(id)?.retryAt, "back: it goes now")
        XCTAssertEqual(queued, [id])
    }

    func testWiFiOnlyOnCellularCountsAsNoNetwork() async throws {
        prefs.downloadsWiFiOnly = true
        manager.setRouteForTests(satisfied: true, cellularOnly: true)
        let id = newId()
        await fail(id, with: URLError(.dataNotAllowed))
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.autoRetries, 0)
        XCTAssertEqual(rec.errorMessage, "Cellular data isn't allowed — waiting for a connection")
        XCTAssertEqual(delay(id), 90, accuracy: 5)
    }

    func testCellularWithWiFiOnlyOffIsANetwork() async throws {
        prefs.downloadsWiFiOnly = false
        manager.setRouteForTests(satisfied: true, cellularOnly: true)
        let id = newId()
        await fail(id, with: URLError(.networkConnectionLost))
        XCTAssertEqual(manager.record(for: id)?.autoRetries, 1)
        XCTAssertEqual(delay(id), 5, accuracy: 3)
    }

    func testTheServerAnsweringAgainFreesEveryWait() async {
        let a = newId(), b = newId()
        await fail(a, with: URLError(.timedOut))
        await fail(b, with: URLError(.networkConnectionLost)) { $0.autoRetries = 3 }
        XCTAssertTrue(manager.queue.allSatisfy { !$0.isDue(at: Date()) })
        manager.connectivityChanged(online: false)
        XCTAssertTrue(manager.queue.allSatisfy { $0.retryAt != nil }, "going offline frees nothing")
        manager.connectivityChanged(online: true)
        XCTAssertEqual(manager.queue.count, 2)
        XCTAssertTrue(manager.queue.allSatisfy { $0.retryAt == nil })
    }

    // MARK: No point trying again

    func testAnErrorNotWorthRetryingIsAFailureAtOnce() async throws {
        let id = newId()
        let error = URLError(.cannotWriteToFile)
        await fail(id, with: error)
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .error)
        XCTAssertEqual(rec.errorMessage, error.localizedDescription)
        XCTAssertEqual(rec.autoRetries, 0)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertNil(manager.transferState(of: id))
    }

    func testOutOfSpaceIsSaidInSoManyWords() async throws {
        let id = newId()
        await fail(id, with: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        XCTAssertEqual(manager.record(for: id)?.status, .error)
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "This device is out of space")
        XCTAssertTrue(queued.isEmpty, "not retried five times over eight minutes")
    }

    func testAFileNotFoundIsBelievedFirstTime() async throws {
        // Only a stream's first request gets the benefit of the doubt.
        let id = newId()
        await fail(id, with: URLError(.fileDoesNotExist))
        XCTAssertEqual(manager.record(for: id)?.status, .error)
        XCTAssertTrue(queued.isEmpty)
    }

    func testAFailureFreesItsSlotAndItsLiveCounts() async {
        let id = newId()
        seed(id, .downloading)
        let task = await adopt(id, received: 2_500, expected: 10_000)
        XCTAssertNotNil(manager.liveProgress[id])
        finish(task, with: URLError(.cannotWriteToFile))
        await waitUntil("it has failed") { self.manager.record(for: id)?.status == .error }
        XCTAssertNil(manager.liveProgress[id])
        XCTAssertFalse(manager.isQueuedOrRunning(id))
        XCTAssertEqual(manager.transfersToFinish, 0)
    }

    // MARK: What the server answered

    private func answer(
        _ status: Int, for id: String, _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) async {
        seed(id, .downloading) {
            $0.fileName = "Film.mp4"
            configure(&$0)
        }
        StubURLProtocol.stub("/files/\(id)", status: status, json: #"{"error":"no"}"#)
        run(for: id, path: "/files/\(id)")
        await waitUntil("the answer \(status) is dealt with") { self.manager.record(for: id)?.status != .downloading }
    }

    func testAServerThatIsUnwellIsAskedAgain() async throws {
        for status in [500, 502, 503] {
            let id = newId()
            await answer(status, for: id)
            let rec = try XCTUnwrap(manager.record(for: id))
            XCTAssertEqual(rec.status, .queued, "\(status)")
            XCTAssertEqual(rec.errorMessage, "Server answered \(status) — trying again")
            XCTAssertEqual(rec.autoRetries, 1)
            XCTAssertEqual(delay(id), 5, accuracy: 3)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: DownloadManager.folderPath(for: id).appendingPathComponent("Film.mp4").path),
                "the error page is not kept as the film"
            )
        }
    }

    func testAnUnwellServerEndsAsAFailureOnceTheGoesAreUsed() async throws {
        let id = newId()
        await answer(503, for: id) { $0.autoRetries = 5 }
        XCTAssertEqual(manager.record(for: id)?.status, .error)
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "Server answered 503 — stopped after 5 attempts")
    }

    func testARefusalIsGivenOneMoreGoThenBelieved() async throws {
        // Not found, timed out, too many at once, a token renewed since: on
        // a first go these are as often the server catching up as a refusal.
        for status in [401, 403, 404, 408, 416, 429] {
            let first = newId()
            await answer(status, for: first)
            XCTAssertEqual(manager.record(for: first)?.status, .queued, "\(status), first go")
            XCTAssertEqual(manager.record(for: first)?.errorMessage, "Server answered \(status) — trying again")
            XCTAssertEqual(manager.record(for: first)?.autoRetries, 1)

            let second = newId()
            await answer(status, for: second) { $0.autoRetries = 1 }
            XCTAssertEqual(manager.record(for: second)?.status, .error, "\(status), second go")
            XCTAssertEqual(manager.record(for: second)?.errorMessage, "Server answered \(status)")
            XCTAssertFalse(queued.contains(second))
        }
    }

    func testAnyOtherRefusalIsAFailureAtOnce() async throws {
        let id = newId()
        await answer(400, for: id)
        XCTAssertEqual(manager.record(for: id)?.status, .error)
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "Server answered 400")
        XCTAssertEqual(manager.record(for: id)?.autoRetries, 0)
        XCTAssertTrue(queued.isEmpty)
    }

    func testResumeDataTheServerNoLongerHonoursIsDropped() async throws {
        // It carries the old request, header and all: 401, 403 and 416 can
        // only be got past by starting over. A 404 keeps it.
        for (status, kept) in [(401, false), (403, false), (416, false), (404, true)] {
            let id = newId()
            let resume = DownloadManager.folder(for: id).appendingPathComponent("resume.data")
            try Data("old request".utf8).write(to: resume)
            await answer(status, for: id)
            XCTAssertEqual(FileManager.default.fileExists(atPath: resume.path), kept, "\(status)")
        }
    }

    func testAConnectionThatDropsMidTransferIsPutBack() async throws {
        let id = newId()
        seed(id, .downloading) { $0.fileName = "Film.mp4" }
        StubURLProtocol.stub("/files/\(id)", .init(error: .networkConnectionLost))
        run(for: id, path: "/files/\(id)")
        await waitUntil("it is back in the queue") { self.queued == [id] }
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "The connection was lost — trying again")
    }

    // MARK: A file that arrives is checked before it is called a download

    private func arrive(
        _ body: Data, for id: String, type: String, fileName: String,
        _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) async {
        seed(id, .downloading, type: type, name: "Title") {
            $0.fileName = fileName
            configure(&$0)
        }
        StubURLProtocol.stub("/files/\(id)", .init(headers: ["Content-Type": "application/octet-stream"], body: body))
        run(for: id, path: "/files/\(id)")
        await waitUntil("the arrival of \(id) is checked") {
            guard let rec = self.manager.record(for: id) else { return false }
            return rec.status != .downloading && !(rec.status == .error && rec.errorMessage == nil)
        }
    }

    private static let junk = Data(repeating: 0x5A, count: 4_096)

    func testASongThatOpensIsADownload() async throws {
        let id = newId()
        let wav = Self.wav()
        await arrive(wav, for: id, type: "Audio", fileName: "song.wav") {
            $0.verifyFailures = 1
            $0.errorMessage = "The first copy arrived incomplete"
        }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .complete)
        XCTAssertNil(rec.errorMessage)
        XCTAssertEqual(rec.verifyFailures, 0)
        XCTAssertEqual(rec.receivedBytes, Int64(wav.count))
        XCTAssertEqual(rec.totalBytes, Int64(wav.count), "the file itself is the last word on its size")
        XCTAssertEqual(rec.fraction, 1)
        XCTAssertNil(rec.needsMPV)

        let url = try XCTUnwrap(manager.mediaURL(for: rec))
        XCTAssertEqual(url.lastPathComponent, "song.wav")
        XCTAssertEqual(try Data(contentsOf: url), wav)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       "media can be fetched again; it has no place in a backup")
        XCTAssertTrue(queued.isEmpty)
        XCTAssertNil(manager.transferState(of: id))
        XCTAssertEqual(manager.tally.songs, 1)
        XCTAssertEqual(manager.tally.completeBytes, Int64(wav.count))
        XCTAssertEqual(recordOnDisk(id)?.status, .complete)
    }

    func testAFileThatWontOpenIsFetchedOnceMore() async throws {
        // 200, connection closed, file handed over — and an MP4 with no
        // index in it. Not reported: fetched again, with the reason shown.
        let id = newId()
        await arrive(Self.junk, for: id, type: "Movie", fileName: "Film.mp4")
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued)
        XCTAssertEqual(rec.errorMessage, "The first copy arrived incomplete")
        XCTAssertEqual(rec.verifyFailures, 1)
        XCTAssertEqual(rec.receivedBytes, 0)
        XCTAssertEqual(rec.totalBytes, 0)
        XCTAssertEqual(queued, [id])
        XCTAssertEqual(entry(id)?.isRetry, true)
        XCTAssertNil(entry(id)?.asStream)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: DownloadManager.folderPath(for: id).appendingPathComponent("Film.mp4").path),
            "the file that would not open is not left looking downloaded"
        )
        XCTAssertNil(manager.mediaURL(for: rec))
    }

    func testAFilmThatWontOpenTwiceIsFetchedRewrappedAsAStream() async throws {
        let id = newId()
        await arrive(Self.junk, for: id, type: "Movie", fileName: "Film.mp4") { $0.verifyFailures = 1 }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued)
        XCTAssertEqual(rec.errorMessage, "The original file wouldn't open — fetching it rewrapped")
        XCTAssertEqual(rec.verifyFailures, 2)
        let entry = try XCTUnwrap(entry(id))
        XCTAssertEqual(entry.asStream, true, "the same bytes, the other way down")
        XCTAssertFalse(entry.isRetry, "built afresh from the item, not replayed from the address that failed")
        XCTAssertEqual(queued, [id])
    }

    func testASongThatWontOpenTwiceIsAFailure() async throws {
        // A song has no other way down.
        let id = newId()
        await arrive(Self.junk, for: id, type: "Audio", fileName: "song.flac") { $0.verifyFailures = 1 }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .error)
        XCTAssertEqual(rec.errorMessage, "The file arrived incomplete twice and wouldn't open")
        XCTAssertEqual(rec.verifyFailures, 2)
        XCTAssertTrue(queued.isEmpty)
    }

    func testAFilmAlreadyRewrappedThatWontOpenTwiceIsAFailure() async throws {
        let id = newId()
        await arrive(Self.junk, for: id, type: "Movie", fileName: "Film.mp4") { $0.verifyFailures = 2 }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .error)
        XCTAssertEqual(rec.errorMessage, "The file arrived incomplete twice and wouldn't open")
        XCTAssertTrue(queued.isEmpty)
    }

    func testAWholeFileAVFoundationWontOpenIsKeptForMPV() async throws {
        // Every byte the server said it had, and AVFoundation still refuses
        // it: 10-bit H.264, say. Nothing was lost on the way.
        let id = newId()
        await arrive(Self.junk, for: id, type: "Movie", fileName: "Film.mp4") {
            $0.estimatedBytes = Int64(Self.junk.count)
        }
        let rec = try XCTUnwrap(manager.record(for: id))
        if PlayerModel.mpvAvailable {
            XCTAssertEqual(rec.status, .complete)
            XCTAssertEqual(rec.needsMPV, true)
            XCTAssertEqual(rec.totalBytes, Int64(Self.junk.count))
            XCTAssertEqual(rec.verifyFailures, 0)
            XCTAssertNotNil(manager.mediaURL(for: rec))
            XCTAssertTrue(queued.isEmpty)
        } else {
            XCTAssertEqual(rec.status, .queued, "with no mpv to play it, it is fetched again")
            XCTAssertEqual(rec.errorMessage, "The first copy arrived incomplete")
        }
    }

    func testASongIsNeverKeptForMPV() async throws {
        let id = newId()
        await arrive(Self.junk, for: id, type: "Audio", fileName: "song.flac") {
            $0.estimatedBytes = Int64(Self.junk.count)
        }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued)
        XCTAssertNil(rec.needsMPV)
    }

    func testARecordWithNoFileNameStillHasSomewhereToPutTheFile() async throws {
        let id = newId()
        seed(id, .downloading, type: "Movie", name: "Up: 1/2") { $0.fileName = "" }
        StubURLProtocol.stub("/files/\(id)", .init(body: Self.junk))
        run(for: id, path: "/files/\(id)")
        await waitUntil("the arrival is checked") { self.manager.record(for: id)?.status == .queued }
        XCTAssertEqual(manager.record(for: id)?.fileName, "Up_ 1_2.mp4")
    }

    func testAFileForADownloadDeletedMeanwhileIsThrownAway() async throws {
        let id = newId()
        seed(id, .downloading) { $0.fileName = "Film.mp4" }
        manager.delete(id)
        StubURLProtocol.stub("/files/\(id)", .init(body: Self.wav()))
        run(for: id, path: "/files/\(id)")
        await waitUntil("the transfer has been answered") {
            StubURLProtocol.requests.contains { $0.url?.path == "/files/\(id)" }
        }
        await letCallbacksLand()
        XCTAssertNil(manager.record(for: id))
        assertFolderGone(id)
    }

    // MARK: Progress

    func testProgressIsShownLiveAndWrittenRarely() async throws {
        let id = newId()
        seed(id, .queued)
        let task = await adopt(id, received: 2_500, expected: 10_000)
        XCTAssertEqual(manager.liveProgress[id], .init(received: 2_500, total: 10_000, fraction: nil))
        var rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .downloading, "the first byte makes it a running transfer")
        XCTAssertEqual(rec.fraction, 0.25)
        XCTAssertEqual(manager.tally.running.map(\.itemId), [id])

        // Thousands of callbacks a second come to two redraws: one inside
        // the half second is dropped before it reaches the main actor.
        manager.urlSession(Self.session, downloadTask: task, didWriteData: 1, totalBytesWritten: 3_000,
                           totalBytesExpectedToWrite: 10_000)
        await letCallbacksLand()
        XCTAssertEqual(manager.liveProgress[id]?.received, 2_500)

        try await Task.sleep(for: .milliseconds(600))
        manager.urlSession(Self.session, downloadTask: task, didWriteData: 1, totalBytesWritten: 9_000,
                           totalBytesExpectedToWrite: 10_000)
        await waitUntil("the later count is shown") { self.manager.liveProgress[id]?.received == 9_000 }
        rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.receivedBytes, 2_500, "the record itself is rewritten every ten seconds, not every redraw")
        XCTAssertEqual(manager.live(rec).receivedBytes, 9_000, "the row reads the live count laid over it")
        XCTAssertEqual(manager.live(rec).fraction, 0.9)
        XCTAssertEqual(recordOnDisk(id)?.receivedBytes, 2_500)
    }

    func testATransferOfUnknownLengthKeepsItsEstimate() async throws {
        // A transcode is sent with no length; the estimate stays the bar's
        // denominator.
        let id = newId()
        seed(id, .downloading) { $0.estimatedBytes = 8_000 }
        await adopt(id, received: 2_000, expected: -1)
        let rec = manager.live(try XCTUnwrap(manager.record(for: id)))
        XCTAssertEqual(rec.totalBytes, 0)
        XCTAssertEqual(rec.fraction, 0.25)
        XCTAssertEqual(rec.progressTotal?.bytes, 8_000)
        XCTAssertEqual(rec.progressTotal?.estimated, true)
    }

    func testLiveCountsLaidOverARecordWithNone() {
        let rec = record(newId(), .downloading) { $0.receivedBytes = 7 }
        XCTAssertEqual(manager.live(rec), rec)
    }

    func testAStreamsBytesAreCountedFromItsPackageOnDisk() async throws {
        // The task's own counter starts again on a resume and is not carried
        // across a relaunch; what is on disk is the count. With nothing
        // heard from the task, the share is told from the bytes too — never
        // backwards, and never done.
        func package(bytes: Int) throws -> String {
            let url = AppDirectory.url(.cachesDirectory)
                .appendingPathComponent("DownloadFailureTests-\(UUID().uuidString).movpkg", isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("0"), withIntermediateDirectories: true)
            try Data(count: bytes / 2).write(to: url.appendingPathComponent("0/a.frag"))
            try Data(count: bytes / 2).write(to: url.appendingPathComponent("0/b.frag"))
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return DownloadManager.homeRelativePath(url)
        }
        try await stopMeasuring()
        let early = newId(), nearlyDone = newId()
        let small = try package(bytes: 200_000), large = try package(bytes: 400_000)
        seed(early, .downloading) {
            $0.transport = .hls
            $0.partialPath = small
            $0.estimatedBytes = 2_000_000
            $0.loadedFraction = 0.02
        }
        seed(nearlyDone, .downloading) {
            $0.transport = .hls
            $0.hlsPath = large
            $0.estimatedBytes = 100_000
            $0.projectedBytes = 300_000
        }
        await adopt(early, received: 1, expected: -1)
        await adopt(nearlyDone, received: 1, expected: -1)

        manager.measureStreamsSoon()
        manager.measureStreamsSoon()   // harmless to call often
        await waitUntil("both packages have been measured") {
            (self.manager.liveProgress[early]?.received ?? 0) >= 200_000
                && (self.manager.liveProgress[nearlyDone]?.received ?? 0) >= 400_000
        }
        let first = try XCTUnwrap(manager.liveProgress[early])
        XCTAssertLessThan(first.received, 300_000, "what the two files occupy, give or take a block")
        XCTAssertEqual(try XCTUnwrap(first.fraction), Double(first.received) / 2_000_000, accuracy: 0.001,
                       "against the size estimated so far")
        let second = try XCTUnwrap(manager.liveProgress[nearlyDone])
        XCTAssertEqual(second.fraction, 0.99, "more on disk than was projected is still not finished")
        XCTAssertEqual(second.projected, 300_000, "and the projection is left alone: a share made from it would only confirm it")
        XCTAssertEqual(manager.live(try XCTUnwrap(manager.record(for: early))).receivedBytes, first.received)
        XCTAssertEqual(manager.record(for: early)?.status, .downloading)
    }

    func testTheSystemIsToldItMaySuspendOnlyOnceTheQueueIsOnDisk() async throws {
        // A wake that started the next download and was suspended a moment
        // later kept that item in the saved queue, and the next launch
        // started it a second time.
        let id = newId()
        manager.flushPersisted()
        manager.enqueue(item: film(id), quality: original)
        var saved: [String]?
        var calls = 0
        manager.setBackgroundCompletionHandler({
            calls += 1
            saved = UserDefaults.standard.data(forKey: "download_queue")
                .flatMap { try? JSONDecoder().decode([QueuedDownload].self, from: $0) }?.map(\.itemId)
        }, for: Self.session.configuration.identifier ?? "")
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: Self.session)
        await waitUntil("the system's handler is called") { calls > 0 }
        XCTAssertEqual(saved, [id], "written before the handler, not a second later")

        // Once per wake.
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: Self.session)
        await letCallbacksLand()
        XCTAssertEqual(calls, 1)
    }

    // MARK: The sweep

    func testTheSweepPicksUpRecordsNothingIsDoingAnythingAbout() async throws {
        // What an interrupted run leaves: records that say "downloading" or
        // "queued" with no task, no queue entry and no slot.
        let lostRunning = newId(), lostWaiting = newId(), running = newId(), finished = newId(), failed = newId()
        seed(running, .downloading)
        await adopt(running)
        seed(lostRunning, .downloading) {
            $0.createdAt = Date().addingTimeInterval(-20)
            $0.autoRetries = 5
        }
        seed(lostWaiting, .queued) { $0.createdAt = Date().addingTimeInterval(-10) }
        seed(finished, .complete)
        seed(failed, .error)

        await manager.sweepForTests()
        XCTAssertEqual(queued, [lostRunning, lostWaiting], "in the order they had been started")
        for id in [lostRunning, lostWaiting] {
            XCTAssertEqual(manager.record(for: id)?.status, .queued)
            XCTAssertEqual(manager.record(for: id)?.errorMessage, "Interrupted — picking it back up")
            XCTAssertEqual(entry(id)?.isRetry, true)
        }
        XCTAssertEqual(manager.record(for: lostRunning)?.autoRetries, 5, "the app going away is not an attempt")
        XCTAssertEqual(manager.record(for: running)?.status, .downloading, "a transfer that is moving is left alone")
        XCTAssertEqual(manager.transferState(of: running), .downloading)
        XCTAssertEqual(manager.record(for: finished)?.status, .complete)
        XCTAssertEqual(manager.record(for: failed)?.status, .error, "a failure waits for its Retry")

        // And again: what is now waiting is waiting on something.
        await manager.sweepForTests()
        XCTAssertEqual(queued, [lostRunning, lostWaiting])
    }

    func testTheSweepPutsThingsRightEvenWithNoNetwork() async throws {
        manager.setRouteForTests(satisfied: false, cellularOnly: false)
        let lost = newId()
        seed(lost, .downloading)
        await manager.sweepForTests()
        XCTAssertEqual(queued, [lost])
        XCTAssertEqual(manager.record(for: lost)?.errorMessage, "Interrupted — picking it back up — waiting for a connection")
    }

    // MARK: A file that has gone

    func testADownloadWhoseFileHasGoneBecomesAFailureWithARetry() throws {
        let id = newId(), unfinished = newId()
        seed(id, .complete) {
            $0.fileName = "Film.mp4"
            $0.receivedBytes = 9_000
            $0.totalBytes = 9_000
        }
        seed(unfinished, .queued)
        manager.markMissing(id)
        manager.markMissing(unfinished)
        manager.markMissing(newId())
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .error, "not a tile that looks downloaded and does nothing when tapped")
        XCTAssertEqual(rec.errorMessage, "The file is no longer on this device")
        XCTAssertEqual(rec.receivedBytes, 0)
        XCTAssertEqual(manager.record(for: unfinished)?.status, .queued, "only a finished download can be missing")
        XCTAssertEqual(manager.tally.failed.map(\.itemId), [id])
        XCTAssertEqual(manager.retryAllFailed(), 1)
    }
}
#endif
