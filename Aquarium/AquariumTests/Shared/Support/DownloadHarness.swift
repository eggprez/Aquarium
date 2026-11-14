//  What the downloads unit tests (`Shared/Download…Tests.swift`) stand on.
//
//  `DownloadManager` is one object for the life of the process, with three
//  background sessions behind it. The tests never start a transfer on those.
//  They reach the manager the two ways the system does:
//
//  - through what a screen calls (`enqueue`, `retry`, `setPaused`, `delete`…),
//    with nobody signed in — or with the queue paused — so the pump starts
//    nothing; and
//  - through its URLSession delegate methods, which are the manager's whole
//    account of what a transfer did. A task of the harness's own session stands
//    in for one of the system's: either left unstarted and spoken for by hand
//    (`adopt`, `finish(_:with:)`), or run against `StubURLProtocol` so it ends
//    with a real status and a real file (`run`).
//
//  Records are put in with `DownloadManager.seedForTests`, the DEBUG seam at
//  the foot of Downloads.swift; the other two seams there stand in for the
//  path monitor and the once-a-minute stall sweep.
//
//  Signed in (`signedIn`), the app's shell does what it does at any sign-in:
//  probes the server, loads the libraries, and syncs watch state both ways —
//  in the background of whatever the test is doing. `setUp` gives the probe
//  an answer and waits for that catch-up to finish (`letTheShellCatchUp`)
//  before the test starts, so the only requests a test sees are its own.
//
//  The manager sweeps for itself too (eight seconds after launch, then every
//  minute), and puts back any record that says "downloading" or "queued" with
//  nothing running for it. A test that waits with such a record adopts it
//  first (`adopt`), which is what makes it a running transfer to the sweeps.

#if !os(tvOS)
import Foundation
import os
import XCTest
@testable import Aquarium

/// Passes a real task's callbacks on to the manager, as its own sessions would.
private final class DownloadForwarder: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let manager: DownloadManager
    /// Tasks a test speaks for by hand; whatever the session says about them
    /// (their cancel at the end of a test) is not passed on.
    let byHand = OSAllocatedUnfairLock(initialState: Set<Int>())

    init(manager: DownloadManager) { self.manager = manager }

    private func passesOn(_ task: URLSessionTask) -> Bool {
        !byHand.withLock { $0.contains(task.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard passesOn(downloadTask) else { return }
        manager.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten,
                           totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard passesOn(downloadTask) else { return }
        manager.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard passesOn(task) else { return }
        manager.urlSession(session, task: task, didCompleteWithError: error)
    }
}

/// Base class of the downloads tests: a manager with nothing in it, nobody
/// signed in, the queue running and a network to run it on.
@MainActor
class DownloadTestCase: XCTestCase {
    static let host = "http://stub.invalid"

    let manager = DownloadManager.shared
    let prefs = Preferences.shared

    private static let forwarder = DownloadForwarder(manager: DownloadManager.shared)
    /// One session for every test, so its task numbers never repeat: the
    /// manager remembers the tasks it has heard the last of by session and
    /// number.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: cfg, delegate: forwarder, delegateQueue: queue)
    }()

    private var savedConcurrency = 1
    private var savedOneTranscode = true
    private var savedWiFiOnly = false
    private var handTasks: [URLSessionTask] = []

    /// Signed in to the stub server for the test (`ClientStub`). Off by
    /// default: signed out, the pump starts nothing.
    var signedIn: Bool { false }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(TestRuntime.isUITest, "needs the host app in test mode (TestPlans/Unit.xctestplan)")
        savedConcurrency = prefs.downloadConcurrency
        savedOneTranscode = prefs.transcodesOneAtATime
        savedWiFiOnly = prefs.downloadsWiFiOnly
        ClientStub.remove()
        clean()
        prefs.downloadConcurrency = 1
        prefs.transcodesOneAtATime = true
        prefs.downloadsWiFiOnly = false
        if signedIn {
            ClientStub.install()
            // The identity the probe will find, so finding it changes nothing.
            var session = prefs.session
            session?.serverId = Self.serverId
            prefs.session = session
            stubServerIdentity()
            await letTheShellCatchUp()
        }
    }

    static let serverId = "stub-server"

    /// The answer to the client's "is anyone there" probe. Unanswered, the
    /// shell's own probe at sign-in calls the server offline a moment later,
    /// and an offline client starts no downloads.
    func stubServerIdentity() {
        StubURLProtocol.stub("/System/Info/Public", json: #"{"Id":"\#(Self.serverId)","ServerName":"Stub"}"#)
    }

    /// Whether the host app's shell syncs at sign-in here; found out the
    /// first time it is waited for.
    private static var shellCatchesUp = true

    /// Wait for the shell's sign-in catch-up to get past its sync of watch
    /// state, which is its last word to the server. A record with something
    /// unsent is what shows it: the shell's sync asks about it, is told the
    /// server has no such item, and marks it as no longer waiting.
    private func letTheShellCatchUp() async {
        guard Self.shellCatchesUp else { return }
        let marker = newId()
        StubURLProtocol.stub("/Items", json: #"{"Items":[]}"#)
        seed(marker, .complete) {
            $0.progressSynced = false
            $0.ownerUserId = ClientStub.userId
        }
        let deadline = Date().addingTimeInterval(3)
        while manager.record(for: marker)?.progressSynced == false, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if manager.record(for: marker)?.progressSynced == false {
            Self.shellCatchesUp = false
        } else {
            await letCallbacksLand()
        }
        manager.flushPersisted()
        manager.delete(marker)
        manager.settleOwed(marker)
        StubURLProtocol.reset()
        stubServerIdentity()
    }

    override func tearDown() async throws {
        guard TestRuntime.isUITest else { return }
        for task in handTasks { task.cancel() }
        handTasks = []
        // Signed out first, so that nothing the clean-up frees a slot for starts.
        ClientStub.remove()
        clean()
        prefs.downloadConcurrency = savedConcurrency
        prefs.transcodesOneAtATime = savedOneTranscode
        prefs.downloadsWiFiOnly = savedWiFiOnly
        try await super.tearDown()
    }

    private func clean() {
        manager.deleteEverything()
        manager.setPaused(false)
        for owed in manager.owedProgress { manager.settleOwed(owed.itemId) }
        manager.setRouteForTests(satisfied: true, cellularOnly: false)
        manager.flushPersisted()
        // Whatever a delete left behind (see `deleteRace`), so that one
        // test's leavings are never the next one's findings. The test-mode
        // folder only: `setUp` skips outside test mode.
        let fm = FileManager.default
        let root = DownloadManager.rootPath
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != "queued-items.json" {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    // MARK: Waiting

    /// Poll until `condition` holds; fail the test if it never does.
    func waitUntil(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Long enough for a callback's hop to the main actor to have run, for a
    /// test of something that must *not* happen.
    func letCallbacksLand() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// End whatever measuring of stream packages an earlier test left
    /// running. The manager measures every three seconds for as long as a
    /// stream is arriving, one measurer at a time; one still asleep from the
    /// last test would make this test's first measurement wait for it.
    /// Coming forward is what restarts it, and with nothing arriving the new
    /// one ends at once.
    func stopMeasuring() async throws {
        manager.appBecameActive()
        await letCallbacksLand()
    }

    // MARK: Records

    /// A 32-character id, as Jellyfin's are.
    func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    func record(
        _ id: String, _ status: DownloadRecord.Status = .complete, type: String? = "Movie", name: String = "Film",
        _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) -> DownloadRecord {
        var rec = DownloadRecord(itemId: id, title: name, name: name, type: type)
        rec.status = status
        rec.quality = "Original quality"
        configure(&rec)
        return rec
    }

    @discardableResult
    func seed(
        _ id: String, _ status: DownloadRecord.Status = .complete, type: String? = "Movie", name: String = "Film",
        _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) -> DownloadRecord {
        let rec = record(id, status, type: type, name: name, configure)
        manager.seedForTests(rec)
        return rec
    }

    /// An episode's record: season `season`, number `number` of the show `seriesId`.
    @discardableResult
    func seedEpisode(
        _ id: String, _ status: DownloadRecord.Status = .complete, seriesId: String? = "show1", series: String = "Show",
        season: Int? = 1, number: Int, _ configure: (inout DownloadRecord) -> Void = { _ in }
    ) -> DownloadRecord {
        seed(id, status, type: "Episode", name: "Episode \(number)") {
            $0.series = series
            $0.seriesId = seriesId
            $0.season = season
            $0.episode = number
            configure(&$0)
        }
    }

    /// meta.json as it is on disk now, once the manager's writes have drained.
    func recordOnDisk(_ id: String) -> DownloadRecord? {
        manager.flushPersisted()
        let meta = DownloadManager.folderPath(for: id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: meta) else { return nil }
        return try? JSONDecoder().decode(DownloadRecord.self, from: data)
    }

    func folderExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: DownloadManager.folderPath(for: id).path)
    }

    /// What is left in a download's folder once the manager's writes have
    /// drained; nil when the folder has gone.
    func leftBehind(_ id: String) -> [String]? {
        manager.flushPersisted()
        return try? FileManager.default.contentsOfDirectory(atPath: DownloadManager.folderPath(for: id).path)
    }

    static let deleteRace = "bug: delete() removes a download's folder while a meta.json write it has only just queued "
        + "(stopTransfers marking the record cancelled, or any save a moment before) is still on its way; when the write "
        + "lands mid-removal the folder is left behind holding meta.json until the next launch, Aquarium/Core/Downloads.swift:2051"

    /// The folder of a download deleted while it was unfinished has gone
    /// with it. Not every time — see `deleteRace` — so a pass is accepted
    /// and a failure is the known one.
    func assertFolderGone(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let left = leftBehind(id)
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure(Self.deleteRace, options: options) {
            XCTAssertNil(left, "left behind in the folder: \(left ?? [])", file: file, line: line)
        }
    }

    /// The queue's item ids, front first.
    var queued: [String] { manager.queue.map(\.itemId) }

    func entry(_ id: String) -> QueuedDownload? { manager.queue.first { $0.itemId == id } }

    // MARK: Items

    func item(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> BaseItem {
        do {
            return try JSONDecoder().decode(BaseItem.self, from: Data(json.utf8))
        } catch {
            XCTFail("could not decode the item: \(error)\n\(json)", file: file, line: line)
            return BaseItem()
        }
    }

    /// A film the phone can keep as the file it is: H.264 and AAC in an MP4,
    /// `size` bytes at `bitrate`, `minutes` long.
    func film(
        _ id: String, name: String = "Film", size: Int64 = 500_000_000, bitrate: Int = 6_000_000,
        minutes: Int = 100, extra: String = ""
    ) -> BaseItem {
        item("""
        {"Id":"\(id)","Name":"\(name)","Type":"Movie","RunTimeTicks":\(Int64(minutes) * 600_000_000)\(extra),
         "MediaSources":[\(Self.videoSource(size: size, bitrate: bitrate))]}
        """)
    }

    func episodeItem(
        _ id: String, seriesId: String = "show1", series: String = "Show", season: Int = 1, number: Int,
        size: Int64 = 300_000_000, minutes: Int = 40
    ) -> BaseItem {
        item("""
        {"Id":"\(id)","Name":"Episode \(number)","Type":"Episode","SeriesId":"\(seriesId)","SeriesName":"\(series)",
         "ParentIndexNumber":\(season),"IndexNumber":\(number),"RunTimeTicks":\(Int64(minutes) * 600_000_000),
         "MediaSources":[\(Self.videoSource(size: size, bitrate: 4_000_000))]}
        """)
    }

    /// A song the phone plays as it is: `size` bytes of FLAC.
    func song(_ id: String, name: String = "Song", type: String = "Audio", size: Int64 = 30_000_000, minutes: Int = 4) -> BaseItem {
        item("""
        {"Id":"\(id)","Name":"\(name)","Type":"\(type)","MediaType":"Audio","Album":"Album","AlbumId":"album1",
         "AlbumArtist":"Band","IndexNumber":3,"ParentIndexNumber":1,"RunTimeTicks":\(Int64(minutes) * 600_000_000),
         "MediaSources":[{"Id":"\(id)","Container":"flac","Size":\(size),"Bitrate":900000,
           "MediaStreams":[{"Index":0,"Type":"Audio","Codec":"flac","Channels":2},
                           {"Index":1,"Type":"EmbeddedImage","Codec":"mjpeg"}]}]}
        """)
    }

    static func videoSource(size: Int64, bitrate: Int, container: String = "mp4", videoCodec: String = "h264") -> String {
        """
        {"Id":"src","Container":"\(container)","Size":\(size),"Bitrate":\(bitrate),"DefaultAudioStreamIndex":1,
         "MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"\(videoCodec)","Width":1920,"Height":1080,"BitRate":\(max(0, bitrate - 192_000))},
          {"Index":1,"Type":"Audio","Codec":"aac","Channels":2,"Language":"eng","BitRate":192000}]}
        """
    }

    var original: DownloadQuality { DownloadQualities.all[0] }
    var p720: DownloadQuality { DownloadQualities.named("720p · 4.5 Mbps (transcoded)") }

    // MARK: Transfers

    /// A task that is never started, to speak for by hand. It carries the
    /// item's id the way the manager writes it on its own tasks.
    func handTask(for id: String?, url: String? = nil) -> URLSessionDownloadTask {
        let address = URL(string: url ?? "\(Self.host)/Items/\(id ?? "none")/Download")!
        let task = Self.session.downloadTask(with: address)
        task.taskDescription = id
        Self.forwarder.byHand.withLock { _ = $0.insert(task.taskIdentifier) }
        handTasks.append(task)
        return task
    }

    /// The first progress callback of a transfer for `id`: from here the
    /// manager counts it as running, with this task behind it.
    @discardableResult
    func adopt(
        _ id: String, received: Int64 = 1_000, expected: Int64 = 10_000,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> URLSessionDownloadTask {
        let task = handTask(for: id)
        manager.urlSession(
            Self.session, downloadTask: task, didWriteData: received,
            totalBytesWritten: received, totalBytesExpectedToWrite: expected
        )
        await waitUntil("the transfer of \(id) is taken up", file: file, line: line) {
            self.manager.transferState(of: id) == .downloading
        }
        return task
    }

    /// The task's last word, as the session would deliver it.
    func finish(_ task: URLSessionTask, with error: any Error) {
        manager.urlSession(Self.session, task: task, didCompleteWithError: error)
    }

    /// What iOS hands back for every transfer when the app is swiped away,
    /// and for a task the app cancelled itself.
    var cancelled: URLError { URLError(.cancelled) }

    /// What the system's own Live Activity hands back when its stop button
    /// is pressed.
    var cancelledFromSystemControls: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }

    /// A real transfer for `id`, answered by `StubURLProtocol` — stub
    /// `path` first. Its callbacks reach the manager as a background
    /// session's would.
    @discardableResult
    func run(for id: String, path: String, describe: Bool = true) -> URLSessionDownloadTask {
        let task = Self.session.downloadTask(with: URL(string: Self.host + path)!)
        if describe { task.taskDescription = id }
        task.resume()
        return task
    }

    /// Half a second of silence as a WAV file: the smallest thing
    /// AVFoundation will open and find a sound track with a length in.
    static func wav(seconds: Double = 0.5) -> Data {
        let rate: UInt32 = 8_000
        let samples = UInt32(Double(rate) * seconds)
        let bytes = samples * 2
        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
        put16(1); put16(1); put32(rate); put32(rate * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }
}
#endif
