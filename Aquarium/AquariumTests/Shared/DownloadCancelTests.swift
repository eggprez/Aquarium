//  Who stopped it. A transfer's "cancelled" comes back the same from four
//  places — the person, the app's own pause, the system's stop button, and
//  iOS cancelling every background transfer when the app is swiped away — and
//  what happens to the batch depends on telling them apart. Also Pause and
//  Resume, which are the app cancelling so as to carry on.
//
//  Transfers are stood in for by tasks spoken for by hand; nobody is signed
//  in, so what is put back in the queue stays there to be looked at.
//  See Support/DownloadHarness.swift.

#if !os(tvOS)
import AVFoundation
import XCTest
@testable import Aquarium

@MainActor
final class DownloadCancelTests: DownloadTestCase {
    private static let interrupted = "Interrupted — picking it back up"

    /// Three episodes arriving, started in order.
    private func threeRunning() async -> (ids: [String], tasks: [URLSessionDownloadTask]) {
        let ids = [newId(), newId(), newId()]
        var tasks: [URLSessionDownloadTask] = []
        for (n, id) in ids.enumerated() {
            seedEpisode(id, .downloading, number: n + 1) {
                $0.createdAt = Date().addingTimeInterval(Double(n) - 10)
                $0.sourceURL = "\(Self.host)/Items/\(id)/Download"
                $0.fileName = "Episode \(n + 1).mp4"
            }
            tasks.append(await adopt(id, received: Int64(n + 1) * 1_000, expected: 10_000))
        }
        return (ids, tasks)
    }

    // MARK: Swiped away

    func testSwipeAwayPutsEveryTransferBackNotAway() async throws {
        // iOS cancels every background transfer when the app is swiped away.
        // Read as the person's cancel, each was written off where it stood,
        // and after a few relaunches nothing was left of a batch.
        let (ids, tasks) = await threeRunning()
        for n in [2, 0, 1] { finish(tasks[n], with: cancelled) }
        await waitUntil("all three are back in the queue") { self.queued.count == 3 }

        XCTAssertEqual(queued, ids, "in the order they were started, whatever order the cancels came in")
        XCTAssertFalse(manager.isPaused, "nobody paused anything")
        for (n, id) in ids.enumerated() {
            let rec = try XCTUnwrap(manager.record(for: id), "still a download")
            XCTAssertEqual(rec.status, .queued)
            XCTAssertEqual(rec.errorMessage, Self.interrupted)
            XCTAssertEqual(rec.autoRetries, 0, "the app going away is not the transfer's failure")
            XCTAssertEqual(rec.receivedBytes, Int64(n + 1) * 1_000, "with what it had fetched")
            XCTAssertTrue(folderExists(id))
            let entry = try XCTUnwrap(entry(id))
            XCTAssertTrue(entry.isRetry, "a replay, which resumes, not a fresh start")
            XCTAssertEqual(entry.reason, Self.interrupted)
            XCTAssertEqual(entry.episode, n + 1)
            let wait = try XCTUnwrap(entry.retryAt).timeIntervalSinceNow
            XCTAssertLessThan(wait, 3, "picked up in a moment, not after a failure's wait")
            XCTAssertEqual(manager.transferState(of: id), .queued)
            XCTAssertNil(manager.liveProgress[id])
        }
        XCTAssertTrue(manager.tally.failed.isEmpty)
        XCTAssertEqual(manager.transfersToFinish, 3)
        XCTAssertEqual(recordOnDisk(ids[0])?.status, .queued, "and on disk, for the launch that follows")
    }

    func testSwipeAwayIsNotCountedHoweverManyTimes() async throws {
        // Five strikes ends a download that keeps failing; being swiped away
        // is not a strike, so one on its last go still comes back.
        let id = newId()
        seed(id, .downloading) { $0.autoRetries = 5 }
        let task = await adopt(id)
        finish(task, with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued)
        XCTAssertEqual(rec.autoRetries, 5)
    }

    func testSwipeAwayKeepsTheMeansToCarryOn() async throws {
        let id = newId()
        seed(id, .downloading)
        let task = await adopt(id)
        let resume = Data("where the file transfer had got to".utf8)
        finish(task, with: URLError(.cancelled, userInfo: [NSURLSessionDownloadTaskResumeData: resume]))
        await waitUntil("it is back in the queue") { self.queued == [id] }
        let kept = DownloadManager.folderPath(for: id).appendingPathComponent("resume.data")
        XCTAssertEqual(try Data(contentsOf: kept), resume)
        XCTAssertEqual(try kept.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       "it has the request, token and all, inside it")
    }

    func testSwipeAwayPutsTheRunningOnesAheadOfTheWaitingOnes() async {
        let w1 = newId(), w2 = newId()
        manager.enqueue(items: [film(w1), film(w2)], quality: original)
        let (ids, tasks) = await threeRunning()
        for task in tasks.reversed() { finish(task, with: cancelled) }
        await waitUntil("everything is in the queue") { self.queued.count == 5 }
        XCTAssertEqual(queued, ids + [w1, w2], "what had started goes first, in its own order")
    }

    func testACancelHeardAfterARelaunchIsStillAnInterruption() async throws {
        // The process that started the transfer is gone; the task's last
        // word arrives at one that has never seen it, with the item's id
        // written on it.
        let id = newId()
        seed(id, .downloading)
        finish(handTask(for: id), with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        XCTAssertEqual(manager.record(for: id)?.errorMessage, Self.interrupted)
    }

    func testATaskWithNothingWrittenOnItIsMatchedByItsAddress() async throws {
        let id = newId()
        let address = "\(Self.host)/Items/\(id)/Download"
        seed(id, .downloading) { $0.sourceURL = address }
        finish(handTask(for: nil, url: address), with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        XCTAssertEqual(manager.record(for: id)?.status, .queued)
    }

    func testATaskNobodyKnowsIsNobodysDownload() async {
        let bystander = newId()
        seed(bystander, .downloading)
        await adopt(bystander)
        finish(handTask(for: newId()), with: cancelled)
        finish(handTask(for: nil, url: "\(Self.host)/Items/unknown/Download"), with: cancelled)
        await letCallbacksLand()
        XCTAssertTrue(queued.isEmpty)
        XCTAssertEqual(manager.records.map(\.itemId), [bystander])
        XCTAssertEqual(manager.transferState(of: bystander), .downloading)
    }

    func testSwipeAwayWithNoNetworkWaitsForOne() async throws {
        let id = newId()
        seed(id, .downloading)
        let task = await adopt(id)
        manager.setRouteForTests(satisfied: false, cellularOnly: false)
        finish(task, with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "\(Self.interrupted) — waiting for a connection")
        let wait = try XCTUnwrap(entry(id)?.retryAt).timeIntervalSinceNow
        XCTAssertEqual(wait, 90, accuracy: 5, "tried anyway after a while, in case nothing says the network is back")

        manager.setRouteForTests(satisfied: true, cellularOnly: false)
        XCTAssertNil(entry(id)?.retryAt, "the network coming back frees it at once")
    }

    // MARK: The person

    func testThePersonsCancelRemovesTheDownloadForGood() async throws {
        let id = newId()
        seed(id, .downloading) { $0.fileName = "Film.mp4" }
        let task = await adopt(id)
        try Data("part of a film".utf8).write(to: DownloadManager.folder(for: id).appendingPathComponent("resume.data"))

        manager.cancel(id)
        XCTAssertNil(manager.record(for: id), "kept as a cancelled record it was listed nowhere and sat on disk")
        XCTAssertNil(manager.transferState(of: id))
        XCTAssertNil(manager.liveProgress[id])

        // The task's own cancel, coming back, and a last progress callback
        // that was already on its way: neither brings it back.
        finish(task, with: cancelled)
        manager.urlSession(Self.session, downloadTask: task, didWriteData: 10, totalBytesWritten: 5_000,
                           totalBytesExpectedToWrite: 10_000)
        await letCallbacksLand()
        XCTAssertNil(manager.record(for: id))
        XCTAssertTrue(queued.isEmpty, "not picked back up as an interruption")
        XCTAssertNil(manager.transferState(of: id))
        assertFolderGone(id)
    }

    func testThePersonsCancelOfOneLeavesTheRestOfTheBatch() async {
        let (ids, tasks) = await threeRunning()
        manager.cancel(ids[1])
        finish(tasks[1], with: cancelled)
        await letCallbacksLand()
        XCTAssertEqual(Set(manager.records.map(\.itemId)), [ids[0], ids[2]])
        XCTAssertEqual(manager.transferState(of: ids[0]), .downloading)
        XCTAssertEqual(manager.transferState(of: ids[2]), .downloading)
        XCTAssertTrue(queued.isEmpty)
    }

    func testCancelOfSomethingWaitingTakesItOutOfTheQueue() {
        let a = newId(), b = newId()
        manager.enqueue(items: [film(a), film(b)], quality: original)
        manager.cancel(a)
        XCTAssertEqual(queued, [b])
        XCTAssertNil(manager.record(for: a))
    }

    func testCancelLeavesAFinishedDownloadAlone() {
        let id = newId()
        seed(id, .complete)
        manager.cancel(id)
        XCTAssertEqual(manager.record(for: id)?.status, .complete)
        XCTAssertTrue(folderExists(id))
    }

    func testACancelledRecordFromBeforeARelaunchStaysCancelled() async {
        // Cancelled from the app, and the app was gone before the task's own
        // cancel came back: still the person's cancel.
        let id = newId()
        seed(id, .canceled)
        finish(handTask(for: id), with: cancelled)
        await letCallbacksLand()
        XCTAssertEqual(manager.record(for: id)?.status, .canceled)
        XCTAssertTrue(queued.isEmpty)
    }

    func testACancelArrivingForAFinishedDownloadChangesNothing() async {
        let id = newId()
        seed(id, .complete)
        finish(handTask(for: id), with: cancelled)
        await letCallbacksLand()
        XCTAssertEqual(manager.record(for: id)?.status, .complete)
        XCTAssertTrue(queued.isEmpty)
    }

    func testWordFromATaskThatHasBeenReplacedIsIgnored() async {
        // After a relaunch the old task's cancel can turn up once the item
        // is running again on a new one.
        let id = newId()
        seed(id, .downloading)
        let old = handTask(for: id)
        await adopt(id)
        finish(old, with: cancelled)
        await letCallbacksLand()
        XCTAssertEqual(manager.record(for: id)?.status, .downloading)
        XCTAssertEqual(manager.transferState(of: id), .downloading, "the running transfer keeps its slot")
        XCTAssertTrue(queued.isEmpty)
    }

    // MARK: The system's stop button

    func testTheSystemsStopButtonPausesAndKeepsTheBatch() async throws {
        let waiting = newId()
        manager.enqueue(item: film(waiting), quality: original)
        let id = newId()
        seed(id, .downloading)
        let task = await adopt(id, received: 6_000, expected: 10_000)
        finish(task, with: cancelledFromSystemControls)
        await waitUntil("it is back in the queue") { self.queued.count == 2 }

        XCTAssertTrue(manager.isPaused, "stop means stop: the next in the queue is not started in its place")
        XCTAssertEqual(queued, [id, waiting], "and what was waiting is still there to resume")
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued, "not marked cancelled: Resume brings it back")
        XCTAssertEqual(rec.errorMessage, "Paused")
        XCTAssertEqual(rec.receivedBytes, 6_000)
        XCTAssertEqual(rec.autoRetries, 0)
        XCTAssertEqual(entry(id)?.reason, "Paused")

        manager.setPaused(false)
        XCTAssertNil(entry(id)?.reason)
        XCTAssertNil(entry(id)?.retryAt)
    }

    // MARK: Pause and resume

    func testPauseSetsRunningTransfersAsideInTheOrderTheyStarted() async throws {
        let waiting = newId()
        manager.enqueue(item: film(waiting), quality: original)
        let (ids, tasks) = await threeRunning()

        manager.setPaused(true)
        XCTAssertTrue(manager.isPaused)
        XCTAssertEqual(manager.pausedNote, " · downloads are paused")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "downloads.paused"), "kept across launches")
        // The cancels the pause sent, coming back in no particular order.
        for n in [1, 2, 0] {
            finish(tasks[n], with: URLError(.cancelled, userInfo: [NSURLSessionDownloadTaskResumeData: Data([UInt8(n)])]))
        }
        await waitUntil("all three are back in the queue") { self.queued.count == 4 }

        XCTAssertEqual(queued, ids + [waiting], "pushed onto the front in turn they came back 3, 2, 1")
        for (n, id) in ids.enumerated() {
            let rec = try XCTUnwrap(manager.record(for: id))
            XCTAssertEqual(rec.status, .queued)
            XCTAssertEqual(rec.errorMessage, "Paused")
            XCTAssertEqual(rec.autoRetries, 0, "a pause is nobody's failure")
            XCTAssertEqual(rec.receivedBytes, Int64(n + 1) * 1_000, "kept, to carry on from")
            XCTAssertEqual(entry(id)?.reason, "Paused")
            XCTAssertEqual(entry(id)?.isRetry, true)
            let kept = DownloadManager.folderPath(for: id).appendingPathComponent("resume.data")
            XCTAssertEqual(try Data(contentsOf: kept), Data([UInt8(n)]))
        }
        XCTAssertTrue(manager.tally.running.isEmpty)
        XCTAssertTrue(manager.tally.failed.isEmpty)
    }

    func testResumeFreesWhatThePauseHeld() async throws {
        let (ids, tasks) = await threeRunning()
        manager.setPaused(true)
        for task in tasks { finish(task, with: cancelled) }
        await waitUntil("all three are back in the queue") { self.queued.count == 3 }
        XCTAssertTrue(manager.queue.allSatisfy { $0.retryAt != nil })

        manager.setPaused(false)
        XCTAssertFalse(manager.isPaused)
        XCTAssertEqual(manager.pausedNote, "")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "downloads.paused"))
        XCTAssertEqual(queued, ids)
        XCTAssertTrue(manager.queue.allSatisfy { $0.retryAt == nil && $0.reason == nil && $0.isDue(at: Date()) },
                      "ready to go the moment the queue runs")
        XCTAssertTrue(manager.queue.allSatisfy(\.isRetry), "and to pick up from what each had")
    }

    func testAPauseLiftedBeforeItsCancelCameBackIsNotShownAsPaused() async throws {
        let id = newId()
        seed(id, .downloading)
        let task = await adopt(id)
        manager.setPaused(true)
        manager.setPaused(false)
        finish(task, with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        let entry = try XCTUnwrap(entry(id))
        XCTAssertNil(entry.reason, "the row said Paused under a running queue")
        XCTAssertTrue(entry.isDue(at: Date()), "and waited while something behind it took its place")
        XCTAssertNil(manager.record(for: id)?.errorMessage)
        XCTAssertEqual(manager.record(for: id)?.status, .queued)
    }

    func testAPauseDoesNotUseUpADownloadsGoes() async throws {
        let id = newId()
        seed(id, .downloading) { $0.autoRetries = 5 }
        let task = await adopt(id)
        manager.setPaused(true)
        finish(task, with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued, "on its last go, and still not written off by a pause")
        XCTAssertEqual(rec.autoRetries, 5)
    }

    func testPausingTwiceIsOnePause() async {
        let id = newId()
        seed(id, .downloading)
        let task = await adopt(id)
        manager.setPaused(true)
        manager.setPaused(true)
        finish(task, with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        XCTAssertEqual(queued, [id])
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "Paused")
    }

    func testAFileThatLandsUnderAPauseIsStillFinished() async throws {
        // A pause holds what has not arrived; it does not un-finish what has.
        let id = newId()
        seed(id, .downloading, type: "Audio") { $0.fileName = "song.wav" }
        manager.setPaused(true)
        StubURLProtocol.stub("/files/\(id)", .init(headers: ["Content-Type": "audio/wav"], body: Self.wav()))
        run(for: id, path: "/files/\(id)")
        await waitUntil("the song has landed") { self.manager.record(for: id)?.status == .complete }
        XCTAssertTrue(queued.isEmpty)
        XCTAssertTrue(manager.isPaused)
        XCTAssertNil(manager.transferState(of: id))
    }

    func testSomethingQueuedUnderAPauseWaits() {
        manager.setPaused(true)
        let id = newId()
        XCTAssertTrue(manager.enqueue(item: film(id), quality: original))
        XCTAssertEqual(manager.transferState(of: id), .queued)
        XCTAssertEqual(manager.pausedNote, " · downloads are paused", "what the toast adds, so it is known why")
    }

    // MARK: Parallel downloads lowered

    func testLoweringParallelDownloadsSetsAsideTheOnesLeastFarAlong() async throws {
        // The limit used to be read only when starting the next one, so
        // going from 3 to 1 left all three running.
        prefs.downloadConcurrency = 3
        await letCallbacksLand()
        let ids = [newId(), newId(), newId()]
        var tasks: [URLSessionDownloadTask] = []
        for (n, share) in [Int64(5_000), 9_000, 1_000].enumerated() {
            seedEpisode(ids[n], .downloading, number: n + 1) { $0.createdAt = Date().addingTimeInterval(Double(n) - 10) }
            tasks.append(await adopt(ids[n], received: share, expected: 10_000))
        }

        prefs.downloadConcurrency = 1
        await letCallbacksLand()
        XCTAssertFalse(manager.isPaused)
        // The manager's cancels, coming back — and, for the one it left
        // running, a cancel that is not the manager's at all.
        for task in tasks { finish(task, with: cancelled) }
        await waitUntil("all three are back in the queue") { self.queued.count == 3 }

        XCTAssertEqual(manager.record(for: ids[0])?.errorMessage, "Waiting for a free slot")
        XCTAssertEqual(manager.record(for: ids[2])?.errorMessage, "Waiting for a free slot")
        XCTAssertEqual(manager.record(for: ids[1])?.errorMessage, "Interrupted — picking it back up",
                       "the one furthest along was left running: its cancel was somebody else's")
        XCTAssertEqual(queued, ids, "set aside like a pause: kept, and in the order they started")
        for id in ids {
            XCTAssertEqual(manager.record(for: id)?.status, .queued)
            XCTAssertEqual(manager.record(for: id)?.autoRetries, 0, "giving up a slot is not a failure")
        }
        XCTAssertEqual(manager.record(for: ids[0])?.receivedBytes, 5_000)
    }

    func testRaisingParallelDownloadsSetsNothingAside() async throws {
        prefs.downloadConcurrency = 2
        await letCallbacksLand()
        let (ids, tasks) = await threeRunning()
        prefs.downloadConcurrency = 4
        await letCallbacksLand()
        for task in tasks { finish(task, with: cancelled) }
        await waitUntil("all three are back in the queue") { self.queued.count == 3 }
        for id in ids {
            XCTAssertEqual(manager.record(for: id)?.errorMessage, Self.interrupted, "none of these cancels was the manager's")
        }
    }

    // MARK: What a failure is

    func testClassifyCancels() {
        let app = DownloadManager.classify(URLError(.cancelled))
        XCTAssertEqual(app.kind, .cancelled)
        XCTAssertFalse(app.fromSystemControls)
        XCTAssertFalse(app.isConnectivity)
        XCTAssertEqual(app.summary, "Cancelled")

        let system = DownloadManager.classify(cancelledFromSystemControls)
        XCTAssertEqual(system.kind, .cancelled)
        XCTAssertTrue(system.fromSystemControls, "the Live Activity's button hands back Cocoa's user-cancelled")

        // AVFoundation wraps what it hands over; the layer underneath says it.
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
        ])
        XCTAssertTrue(DownloadManager.classify(wrapped).fromSystemControls)
        let wrappedURL = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ])
        XCTAssertEqual(DownloadManager.classify(wrappedURL).kind, .cancelled)
        XCTAssertFalse(DownloadManager.classify(wrappedURL).fromSystemControls)
    }

    func testClassifyTheNetworkGoingAway() {
        let lost: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .callIsActive, .backgroundSessionWasDisconnected, .secureConnectionFailed,
        ]
        for code in lost {
            let failure = DownloadManager.classify(URLError(code))
            XCTAssertEqual(failure.kind, .transient, "\(code.rawValue)")
            XCTAssertTrue(failure.isConnectivity, "\(code.rawValue)")
            XCTAssertEqual(failure.summary, "The connection was lost", "\(code.rawValue)")
        }
        XCTAssertEqual(DownloadManager.classify(URLError(.timedOut)).summary, "The server stopped answering")
        XCTAssertTrue(DownloadManager.classify(URLError(.timedOut)).isConnectivity)
        for code in [URLError.Code.dataNotAllowed, .internationalRoamingOff] {
            let failure = DownloadManager.classify(URLError(code))
            XCTAssertEqual(failure.summary, "Cellular data isn't allowed")
            XCTAssertEqual(failure.kind, .transient)
            XCTAssertTrue(failure.isConnectivity)
        }
    }

    func testClassifyWhatIsNotWorthAnotherGo() {
        let codes: [URLError.Code] = [
            .userAuthenticationRequired, .badURL, .unsupportedURL, .fileDoesNotExist,
            .cannotCreateFile, .cannotWriteToFile, .noPermissionsToReadFile, .cannotOpenFile,
        ]
        for code in codes {
            let failure = DownloadManager.classify(URLError(code))
            XCTAssertEqual(failure.kind, .permanent, "\(code.rawValue)")
            XCTAssertFalse(failure.isConnectivity)
            XCTAssertEqual(failure.notFound, code == .fileDoesNotExist, "\(code.rawValue)")
            XCTAssertEqual(failure.summary, URLError(code).localizedDescription)
        }
        let full = DownloadManager.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        XCTAssertEqual(full.kind, .permanent)
        XCTAssertEqual(full.summary, "This device is out of space")
        let fullStream = DownloadManager.classify(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue))
        XCTAssertEqual(fullStream.kind, .permanent)
        XCTAssertEqual(fullStream.summary, "This device is out of space")
    }

    func testClassifyReadsThroughToTheErrorUnderneath() {
        // What AVFoundation hands over for a stream says nothing; the URL
        // error under it says everything.
        let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        let middle = NSError(domain: "CoreMediaErrorDomain", code: -12938, userInfo: [NSUnderlyingErrorKey: inner])
        let outer = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSUnderlyingErrorKey: middle, NSLocalizedDescriptionKey: "The operation could not be completed",
        ])
        let failure = DownloadManager.classify(outer)
        XCTAssertEqual(failure.kind, .transient)
        XCTAssertTrue(failure.isConnectivity)
        XCTAssertEqual(failure.summary, "The connection was lost")
        XCTAssertEqual(failure.detail.components(separatedBy: " ← ").count, 3, failure.detail)
        XCTAssertTrue(failure.detail.hasPrefix("\(AVFoundationErrorDomain) -11800: The operation could not be completed"))
        XCTAssertTrue(failure.detail.contains("NSURLErrorDomain -1005"), failure.detail)
    }

    func testClassifyTakesAnythingElseAsWorthAnotherGoInTheInnermostWords() {
        let inner = NSError(domain: "CoreMediaErrorDomain", code: -12660, userInfo: [
            NSLocalizedDescriptionKey: "HTTP 503: Service Unavailable",
        ])
        let outer = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSUnderlyingErrorKey: inner, NSLocalizedDescriptionKey: "The operation could not be completed",
        ])
        let failure = DownloadManager.classify(outer)
        XCTAssertEqual(failure.kind, .transient)
        XCTAssertFalse(failure.isConnectivity)
        XCTAssertFalse(failure.notFound)
        XCTAssertEqual(failure.summary, "HTTP 503: Service Unavailable")

        let plain = DownloadManager.classify(URLError(.badServerResponse))
        XCTAssertEqual(plain.kind, .transient)
        XCTAssertFalse(plain.isConnectivity)
    }

    func testClassifyStopsAtSixLayers() {
        var error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        for depth in 0..<8 {
            error = NSError(domain: "Layer", code: depth, userInfo: [NSUnderlyingErrorKey: error])
        }
        let failure = DownloadManager.classify(error)
        XCTAssertEqual(failure.detail.components(separatedBy: " ← ").count, 6)
        XCTAssertEqual(failure.kind, .transient, "a cancel eight layers down is not looked for")
    }
}
#endif
