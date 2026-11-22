//  Stream downloads — every transcoded download is one — as the manager
//  hears about them from AVFoundation: how far along (time, not bytes), where
//  the package is being written and where it landed, what is done with a
//  package nobody owns, and how a stream's transfer ends.
//
//  The tasks are real `AVAssetDownloadTask`s of a session of the tests' own,
//  made and never started; the tests speak for them through the manager's
//  delegate methods. Nobody is signed in, so what is put back in the queue
//  stays there. See Support/DownloadHarness.swift.

#if !os(tvOS)
import AVFoundation
import XCTest
@testable import Aquarium

@MainActor
final class DownloadStreamTests: DownloadTestCase {
    /// One session for every test, so its task numbers never repeat.
    private static let streams = AVAssetDownloadURLSession(
        configuration: .background(withIdentifier: "\(DownloadManager.sessionPrefix).tests.streams"),
        assetDownloadDelegate: nil, delegateQueue: .main
    )

    private var made: [URLSessionTask] = []

    override func setUp() async throws {
        try await super.setUp()
        try await stopMeasuring()
    }

    override func tearDown() async throws {
        for task in made { task.cancel() }
        made = []
        try await super.tearDown()
    }

    /// A stream task that is never started, carrying the item's id as the
    /// manager writes it on its own.
    private func streamTask(for id: String?) -> AVAssetDownloadTask {
        let asset = AVURLAsset(url: URL(string: "\(Self.host)/Videos/\(id ?? "none")/master.m3u8")!)
        let task = Self.streams.makeAssetDownloadTask(
            downloadConfiguration: AVAssetDownloadConfiguration(asset: asset, title: "Test")
        )
        task.taskDescription = id
        made.append(task)
        return task
    }

    @discardableResult
    private func seedStream(
        _ id: String, _ status: DownloadRecord.Status = .downloading, _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) -> DownloadRecord {
        seed(id, status, type: "Episode") {
            $0.transport = .hls
            $0.quality = "720p · 4.5 Mbps (transcoded)"
            $0.runTimeTicks = 1_000 * 10_000_000
            $0.sourceURL = "\(Self.host)/Videos/\(id)/master.m3u8?PlaySessionId=first"
            configure(&$0)
        }
    }

    /// A package where AVFoundation would write one, holding `bytes`.
    private func package(bytes: Int = 0) throws -> (path: String, url: URL) {
        let url = AppDirectory.url(.cachesDirectory)
            .appendingPathComponent("DownloadStreamTests-\(UUID().uuidString).movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("0"), withIntermediateDirectories: true)
        if bytes > 0 {
            try Data(count: bytes / 2).write(to: url.appendingPathComponent("0/a.frag"))
            try Data(count: bytes / 2).write(to: url.appendingPathComponent("0/b.frag"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (DownloadManager.homeRelativePath(url), url)
    }

    /// Something at a package's address that AVFoundation will not open: a
    /// file of nothing where a package of segments should be.
    private func brokenPackage() throws -> (path: String, url: URL) {
        let url = AppDirectory.url(.cachesDirectory)
            .appendingPathComponent("DownloadStreamTests-\(UUID().uuidString).movpkg", isDirectory: false)
        try Data(repeating: 0x5A, count: 2_000).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (DownloadManager.homeRelativePath(url), url)
    }

    /// A package's address with nothing at it: purged by the system, or
    /// never written, by the time the finish is looked at.
    private func missingPackage() -> (path: String, url: URL) {
        let url = AppDirectory.url(.cachesDirectory)
            .appendingPathComponent("DownloadStreamTests-\(UUID().uuidString).movpkg", isDirectory: true)
        return (DownloadManager.homeRelativePath(url), url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func time(_ seconds: Double) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Segments for `loaded` seconds of `total` have arrived.
    private func progress(_ task: AVAssetDownloadTask, loaded: Double, of total: Double) {
        manager.urlSession(
            Self.streams, assetDownloadTask: task, didLoad: time(loaded),
            totalTimeRangesLoaded: [NSValue(timeRange: time(loaded))], timeRangeExpectedToLoad: time(total)
        )
    }

    /// A stream for `id` that the manager counts as running, `loaded` of
    /// 1,000 seconds in.
    private func running(_ id: String, loaded: Double = 300) async -> AVAssetDownloadTask {
        let task = streamTask(for: id)
        progress(task, loaded: loaded, of: 1_000)
        await waitUntil("the stream of \(id) is taken up") { self.manager.transferState(of: id) == .downloading }
        return task
    }

    private func end(_ task: URLSessionTask, with error: (any Error)? = nil) {
        manager.urlSession(Self.streams, task: task, didCompleteWithError: error)
    }

    // MARK: How far along

    func testAStreamsProgressIsItsShareOfTheRunningTime() async throws {
        let id = newId()
        seedStream(id, .queued) { $0.estimatedBytes = 4_000_000 }
        _ = await running(id, loaded: 300)
        let live = try XCTUnwrap(manager.liveProgress[id])
        XCTAssertEqual(try XCTUnwrap(live.fraction), 0.3, accuracy: 0.0001, "exact: no estimate, nothing to overshoot")
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .downloading)
        XCTAssertEqual(try XCTUnwrap(manager.live(rec).fraction), 0.3, accuracy: 0.0001)
        XCTAssertEqual(manager.live(rec).progressTotal?.bytes, 4_000_000, "nothing on disk to project from yet: the estimate")
        XCTAssertEqual(manager.tally.running.map(\.itemId), [id])
    }

    func testProgressWithNoLengthToMeasureAgainstSaysNothing() async {
        let id = newId()
        seedStream(id, .error)
        progress(streamTask(for: id), loaded: 30, of: 0)
        await letCallbacksLand()
        XCTAssertNil(manager.transferState(of: id))
        XCTAssertEqual(manager.record(for: id)?.status, .error)
    }

    func testAStreamsSizeIsProjectedFromWhatHasArrivedAndSmoothed() async throws {
        // 30% of the running time is on disk as ~200 KB, so the whole is
        // nearer 680 KB than the megabyte guessed from the bitrate. The
        // projection moves most of the way there, not all of it at once.
        let id = newId()
        let written = try package(bytes: 200_000)
        seedStream(id) {
            $0.partialPath = written.path
            $0.estimatedBytes = 1_000_000
        }
        _ = await running(id, loaded: 300)
        await waitUntil("the package has been measured") { (self.manager.liveProgress[id]?.received ?? 0) >= 200_000 }

        let live = try XCTUnwrap(manager.liveProgress[id])
        let raw = Double(live.received) / 0.3
        let projected = Double(try XCTUnwrap(live.projected))
        XCTAssertGreaterThan(projected, raw, "not jumped to in one go")
        XCTAssertLessThan(projected, raw + (1_000_000 - raw) * 0.2, "but most of the way from the estimate")
        let row = manager.live(try XCTUnwrap(manager.record(for: id)))
        XCTAssertEqual(row.progressTotal?.bytes, live.projected, "the total the row writes beside the bar")
        XCTAssertEqual(row.progressTotal?.estimated, true)
        XCTAssertEqual(try XCTUnwrap(row.fraction), 0.3, accuracy: 0.0001, "the bar stays the share of the running time")
    }

    // MARK: Where the package is

    func testWhereAStreamIsBeingWrittenIsNotedAsItStarts() async throws {
        guard #available(iOS 18.0, macOS 14.0, *) else { throw XCTSkip("AVFoundation says so from iOS 18 and macOS 14") }
        let id = newId(), finished = newId()
        seedStream(id)
        seedStream(finished, .complete)
        let writing = try package(), other = try package()
        let task = await running(id)
        manager.urlSession(Self.streams, assetDownloadTask: task, willDownloadTo: writing.url)
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.partialPath, writing.path, "relative to home: the container moves between launches")
        XCTAssertNil(rec.hlsPath, "which stays what it has always been: where an attempt ended")
        XCTAssertEqual(recordOnDisk(id)?.partialPath, writing.path, "on disk, so a force-quit still leaves a package to resume")

        manager.urlSession(Self.streams, assetDownloadTask: streamTask(for: finished), willDownloadTo: other.url)
        XCTAssertNil(manager.record(for: finished)?.partialPath, "a finished download is not being written")
        manager.urlSession(Self.streams, assetDownloadTask: streamTask(for: newId()), willDownloadTo: other.url)
        XCTAssertTrue(exists(other.url))
    }

    func testWhereAStreamLandedIsNotedAndAnEarlierPackageGoes() async throws {
        let id = newId()
        let earlier = try package(bytes: 1_000), landed = try package(bytes: 2_000)
        seedStream(id) { $0.hlsPath = earlier.path }
        let task = await running(id)
        manager.urlSession(Self.streams, assetDownloadTask: task, didFinishDownloadingTo: landed.url)
        XCTAssertEqual(manager.record(for: id)?.hlsPath, landed.path)
        XCTAssertFalse(exists(earlier.url), "replaced: nothing points at it any more")
        XCTAssertTrue(exists(landed.url))

        // The same package reported again changes nothing.
        manager.urlSession(Self.streams, assetDownloadTask: task, didFinishDownloadingTo: landed.url)
        XCTAssertEqual(manager.record(for: id)?.hlsPath, landed.path)
        XCTAssertTrue(exists(landed.url))
    }

    func testAPackageNobodyOwnsIsRemoved() async throws {
        // Its download was deleted while AVFoundation was still writing it:
        // mid-transfer the record had no path to it for Delete to remove.
        let id = newId()
        seedStream(id)
        let task = await running(id)
        manager.cancel(id)
        let orphan = try package(bytes: 1_000), stranger = try package(bytes: 1_000)
        manager.urlSession(Self.streams, assetDownloadTask: task, didFinishDownloadingTo: orphan.url)
        XCTAssertFalse(exists(orphan.url), "rather than sitting on disk for good")
        XCTAssertNil(manager.record(for: id))

        manager.urlSession(Self.streams, assetDownloadTask: streamTask(for: newId()), didFinishDownloadingTo: stranger.url)
        XCTAssertFalse(exists(stranger.url))
    }

    // MARK: How a stream ends

    func testAStreamThatFinishesWithNowhereToPutItIsAFailure() async throws {
        let id = newId()
        seedStream(id)
        let task = await running(id, loaded: 1_000)
        end(task)
        await waitUntil("the finish is dealt with") { self.manager.record(for: id)?.status == .error }
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "The download finished with nowhere to put it")
        XCTAssertNil(manager.transferState(of: id), "its slot is given back")
    }

    func testAStreamThatFinishesIsRecordedWhereItLandedAtTheSizeItIs() async throws {
        #if os(macOS)
        // On a Mac AVURLAsset tells the truth about a made-up package (it
        // will not play), so the finish is refused; the iOS simulator says
        // yes to anything at a .movpkg address, which is what lets this run.
        throw XCTSkip("a made-up package does not pass for a real one on the Mac")
        #endif
        let id = newId()
        let writing = try package(bytes: 500), landed = try package(bytes: 200_000)
        seedStream(id) {
            $0.partialPath = writing.path
            $0.estimatedBytes = 9_000_000
            $0.projectedBytes = 7_000_000
            $0.errorMessage = "Interrupted — picking it back up"
            $0.verifyFailures = 1
            $0.autoRetries = 2
        }
        let task = await running(id, loaded: 990)
        manager.urlSession(Self.streams, assetDownloadTask: task, didFinishDownloadingTo: landed.url)
        end(task)
        await waitUntil("the stream is recorded as finished") { self.manager.record(for: id)?.status == .complete }

        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.hlsPath, landed.path)
        XCTAssertGreaterThanOrEqual(rec.totalBytes, 200_000, "what the package occupies, walked for")
        XCTAssertLessThan(rec.totalBytes, 300_000)
        XCTAssertEqual(rec.receivedBytes, rec.totalBytes)
        XCTAssertEqual(rec.loadedFraction, 1)
        XCTAssertEqual(rec.fraction, 1)
        XCTAssertEqual(rec.progressTotal?.bytes, rec.totalBytes)
        XCTAssertEqual(rec.progressTotal?.estimated, false, "the last word on its size is the package itself")
        XCTAssertNil(rec.projectedBytes)
        XCTAssertNil(rec.partialPath)
        XCTAssertFalse(exists(writing.url), "the package an earlier attempt was writing is not this one")
        XCTAssertNil(rec.errorMessage)
        XCTAssertEqual(rec.verifyFailures, 0)
        XCTAssertEqual(manager.mediaURL(for: rec)?.resolvingSymlinksInPath().path, landed.url.resolvingSymlinksInPath().path)
        XCTAssertEqual(try landed.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertNil(manager.transferState(of: id))
        XCTAssertNil(manager.liveProgress[id])
        XCTAssertTrue(queued.isEmpty)
        XCTAssertEqual(manager.tally.completeBytes, rec.totalBytes)
        XCTAssertEqual(recordOnDisk(id)?.status, .complete)

        // A late word from the task changes nothing about a finished download.
        end(task, with: URLError(.networkConnectionLost))
        progress(task, loaded: 100, of: 1_000)
        await letCallbacksLand()
        XCTAssertEqual(manager.record(for: id)?.status, .complete)
        XCTAssertTrue(queued.isEmpty)
    }

    func testAFileOfJunkWhereThePackageShouldBeIsNotADownload() async throws {
        let id = newId()
        let landed = try brokenPackage()
        seedStream(id)
        let task = await running(id, loaded: 1_000)
        manager.urlSession(Self.streams, assetDownloadTask: task, didFinishDownloadingTo: landed.url)
        end(task)
        await waitUntil("the finish is dealt with") { self.manager.record(for: id)?.status != .downloading }
        // AVURLAsset on the iOS simulator calls anything at a .movpkg address
        // playable, so finishStream looks at what is there first.
        XCTAssertNotEqual(manager.record(for: id)?.status, .complete)
    }

    func testMarkingAPackageThatHasGoneAsOneToKeepDoesNotRaise() throws {
        #if os(iOS)
        // The storage manager raises an Objective-C exception for a package
        // that is not on disk; keepFromPurge checks before handing it one.
        DownloadManager.keepFromPurge(missingPackage().url)
        #else
        throw XCTSkip("packages are marked to keep on iOS only")
        #endif
    }

    func testAStreamsFirstNotFoundIsTheServerNotReadyYet() async throws {
        // Jellyfin starts encoding when the first request comes in and can
        // answer it 404 before there is anything to send. One more go by
        // itself; a second "not found" is believed.
        let first = newId(), second = newId()
        seedStream(first)
        var task = await running(first, loaded: 0)
        end(task, with: URLError(.fileDoesNotExist))
        await waitUntil("it is put back") { self.queued == [first] }
        XCTAssertEqual(manager.record(for: first)?.errorMessage, "The server wasn't ready — trying again")
        XCTAssertEqual(manager.record(for: first)?.autoRetries, 1)
        XCTAssertEqual(manager.record(for: first)?.status, .queued)

        seedStream(second) { $0.autoRetries = 1 }
        task = await running(second, loaded: 0)
        end(task, with: URLError(.fileDoesNotExist))
        await waitUntil("it is a failure") { self.manager.record(for: second)?.status == .error }
        XCTAssertEqual(manager.record(for: second)?.errorMessage, URLError(.fileDoesNotExist).localizedDescription)
        XCTAssertEqual(queued, [first])
    }

    func testAStreamSwipedAwayIsPutBackWithItsPackage() async throws {
        let id = newId()
        let written = try package(bytes: 200_000)
        seedStream(id) { $0.partialPath = written.path }
        let task = await running(id, loaded: 400)
        end(task, with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }

        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.status, .queued)
        XCTAssertEqual(rec.errorMessage, "Interrupted — picking it back up")
        XCTAssertEqual(rec.autoRetries, 0)
        XCTAssertEqual(rec.partialPath, written.path, "what the next attempt resumes from")
        XCTAssertTrue(exists(written.url))
        XCTAssertEqual(entry(id)?.isRetry, true)
        XCTAssertEqual(rec.sourceURL, "\(Self.host)/Videos/\(id)/master.m3u8?PlaySessionId=first", "the same encode, carried on")
    }

    func testAPausedStreamKeepsItsPackageAndItsPlace() async throws {
        let id = newId()
        let written = try package(bytes: 200_000)
        seedStream(id) { $0.partialPath = written.path }
        let task = await running(id, loaded: 400)
        manager.setPaused(true)
        end(task, with: cancelled)
        await waitUntil("it is back in the queue") { self.queued == [id] }
        XCTAssertEqual(manager.record(for: id)?.errorMessage, "Paused")
        XCTAssertEqual(try XCTUnwrap(manager.record(for: id)?.loadedFraction), 0.4, accuracy: 0.0001)
        XCTAssertTrue(exists(written.url))
    }

    func testDeletingAStreamTakesThePackageItWasWriting() async throws {
        let id = newId()
        let written = try package(bytes: 1_000)
        seedStream(id) { $0.partialPath = written.path }
        _ = await running(id)
        manager.cancel(id)
        XCTAssertFalse(exists(written.url), "its bytes live outside its folder")
        XCTAssertNil(manager.record(for: id))
        XCTAssertNil(manager.transferState(of: id))
    }
}
#endif
