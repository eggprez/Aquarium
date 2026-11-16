//  Downloads to the watch (Watch/WatchDownloads.swift): queueing, who
//  carries a file (the phone or the watch), patience and asking again,
//  failure and retry, room on the disk, files landing and being measured,
//  deleting by group, and the records' own rules.
//
//  The wants list and its reconcile step are in WatchWantsTests; listening
//  kept on a record is in WatchBookPlaceTests.

import XCTest
@testable import AquariumWatch

final class WatchDownloadsTests: WatchUnitTestCase {

    // MARK: Queueing

    func testEnqueueKeepsAudioOnceWithItsReason() {
        let queued = downloads.enqueue([WX.song("a"), WX.song("a"), WX.album("al"), WX.book("b")], reason: "song")
        XCTAssertEqual(queued, 2)
        XCTAssertEqual(status("a"), .queued)
        XCTAssertEqual(downloads.record(for: "a")?.reasons, ["song"])
        XCTAssertEqual(downloads.record(for: "a")?.automatic, false)
        XCTAssertNil(downloads.record(for: "al"), "an album is not a file")
        XCTAssertEqual(downloads.record(for: "b")?.isAudiobook, true)
        XCTAssertEqual(downloads.inFlight.count, 2)
        XCTAssertTrue(downloads.isQueuedOrRunning("a"))
        XCTAssertFalse(downloads.isComplete("a"))
    }

    func testEnqueueAgainAddsAReasonAndQueuesAFailureAgain() {
        downloads.enqueue([WX.song("a")], reason: "song")
        downloads.testUpdate("a") { $0.status = .error; $0.attempts = 3; $0.errorMessage = "x" }
        let queued = downloads.enqueue([WX.song("a")], reason: "album:album-1")
        XCTAssertEqual(queued, 1)
        let r = downloads.record(for: "a")
        XCTAssertEqual(r?.reasons, ["song", "album:album-1"])
        XCTAssertEqual(r?.status, .queued)
        XCTAssertEqual(r?.attempts, 0)
        XCTAssertNil(r?.errorMessage)
    }

    func testATapClaimsWhatTheMirrorQueued() {
        downloads.enqueue([WX.book("b")], reason: "book", automatic: true)
        XCTAssertEqual(downloads.record(for: "b")?.automatic, true)
        downloads.enqueue([WX.book("b")], reason: "book")
        XCTAssertEqual(downloads.record(for: "b")?.automatic, false)
    }

    func testABookGainsItsChaptersWhenTheyCome() {
        downloads.enqueue([WX.book("b")], reason: "book")
        XCTAssertNil(downloads.record(for: "b")?.chapters)
        downloads.enqueue([WX.book("b", chapters: [0, 150])], reason: "book")
        XCTAssertEqual(downloads.record(for: "b")?.chapters?.count, 2)
    }

    func testTheRecordIsWrittenBesideItsFile() async throws {
        downloads.enqueue([WX.song("a", name: "Song A")], reason: "song")
        let meta = WatchDownloads.folder("a").appendingPathComponent("meta.json")
        let written = await eventually { FileManager.default.fileExists(atPath: meta.path) }
        XCTAssertTrue(written)
        let saved = try JSONDecoder().decode(WatchRecord.self, from: Data(contentsOf: meta))
        XCTAssertEqual(saved.name, "Song A")
        XCTAssertEqual(saved.reasons, ["song"])
        XCTAssertTrue(WatchDownloads.folder("a").path.contains("AquariumUITest"), "test mode keeps its own folder")
    }

    /// Regression, WatchRecord's key-by-key decoder: "a field added later
    /// never empties the folder written by the build before".
    func testARecordFromAnOlderBuildStillReads() throws {
        let r = try JSONDecoder().decode(WatchRecord.self, from: Data(#"{"itemId":"x"}"#.utf8))
        XCTAssertEqual(r.name, "Untitled")
        XCTAssertEqual(r.type, "Audio")
        XCTAssertEqual(r.reasons, ["song"])
        XCTAssertEqual(r.status, .queued)
        XCTAssertEqual(r.fileName, "audio.m4a")
        XCTAssertTrue(r.progressSynced)
        XCTAssertFalse(r.automatic)
    }

    func testARecordAsAnItemPlaysWithNoServer() {
        downloads.enqueue([WX.song("a", name: "A", albumId: "al", album: "Al", artist: "FX Band", track: 3, disc: 2, seconds: 60, imageTag: "t")], reason: "song")
        let item = downloads.record(for: "a")!.asItem
        XCTAssertEqual(item.Id, "a")
        XCTAssertEqual(item.title, "A")
        XCTAssertTrue(item.isSong)
        XCTAssertEqual(item.MediaType, "Audio")
        XCTAssertEqual(item.AlbumId, "al")
        XCTAssertEqual(item.artistLine, "FX Band")
        XCTAssertEqual(item.IndexNumber, 3)
        XCTAssertEqual(item.ParentIndexNumber, 2)
        XCTAssertEqual(item.runtimeSeconds, 60)
        XCTAssertEqual(item.ImageTags?["Primary"], "t")
    }

    func testWhereABookOrSongOpens() {
        downloads.enqueue([WX.book("b", seconds: 3600, position: 87), WX.song("s", seconds: 100, position: 99)], reason: "song")
        XCTAssertEqual(downloads.record(for: "b")!.resumeSeconds, 87, accuracy: 0.001)
        XCTAssertEqual(downloads.record(for: "s")!.resumeSeconds, 0, "a song past 98% starts again")
        downloads.testUpdate("b") { $0.positionTicks = WX.ticks(3400) }
        XCTAssertEqual(downloads.record(for: "b")!.resumeSeconds, 0, "under five minutes left is finished")
        downloads.testUpdate("b") { $0.positionTicks = WX.ticks(600); $0.played = true }
        XCTAssertEqual(downloads.record(for: "b")!.resumeSeconds, 0)
        XCTAssertNil(downloads.record(for: "b")!.progressFraction)
        downloads.testUpdate("b") { $0.played = false }
        XCTAssertEqual(downloads.record(for: "b")!.progressFraction!, 600.0 / 3600, accuracy: 0.0001)
    }

    // MARK: Who carries it

    func testWithAPhoneAppEverythingIsAskedOfThePhone() {
        link.testSetPhone(reachable: false, companion: true)
        downloads.enqueue([WX.song("a")], reason: "song")
        XCTAssertEqual(sent, ["fetch:a"])
        let r = downloads.record(for: "a")
        XCTAssertEqual(r?.status, .downloading)
        XCTAssertNotNil(r?.relayAskedAt)
        XCTAssertEqual(downloads.awaitingPhone, ["a"])
    }

    /// The WatchMessage.fetchMany note: "a playlist's worth of songs asked for
    /// one message at a time swamps the link" — and WatchDownloads.enqueue:
    /// "fifteen hundred songs queued one save at a time held the main thread
    /// long enough for the watch to kill the app".
    func testALongListGoesInMessagesOfTwoHundred() {
        link.testSetPhone(reachable: true, companion: true)
        let songs = (0..<450).map { WX.song("s\($0)") }
        downloads.enqueue(songs, reason: "playlist:p")
        let messages = link.testOutbox ?? []
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(askedOfPhone.count, 450)
        XCTAssertEqual(Set(askedOfPhone).count, 450)
        if case .fetchMany(let first)? = messages.first { XCTAssertEqual(first.count, 200) } else { XCTFail("\(messages)") }
    }

    func testAskedForThingsGoBeforeTheMirrors() {
        downloads.enqueue([WX.song("mirror")], reason: "playlist:p", automatic: true)
        downloads.enqueue([WX.song("tapped")], reason: "song")
        link.testSetPhone(reachable: true, companion: true)
        downloads.pump()
        XCTAssertEqual(askedOfPhone, ["tapped", "mirror"])
    }

    func testNoPhoneAppAndNoNetworkLeavesItWaiting() {
        downloads.enqueue([WX.song("a")], reason: "song")
        XCTAssertEqual(status("a"), .queued)
        XCTAssertEqual(sent, [])
    }

    func testSignedOutNothingMoves() {
        client.signOut()
        link.testSetPhone(reachable: true, companion: true)
        downloads.enqueue([WX.song("a")], reason: "song")
        XCTAssertEqual(sent, [])
        XCTAssertEqual(status("a"), .queued)
    }

    // MARK: Patience with the phone

    private func askPhone(_ id: String, reachable: Bool) {
        link.testSetPhone(reachable: reachable, companion: true)
        downloads.enqueue([WX.song(id)], reason: "song")
        link.testOutbox = []
    }

    func testAQuietPhoneInReachIsAskedAgainLessOftenEachTime() {
        askPhone("a", reachable: true)
        downloads.testUpdate("a") { $0.relayAskedAt = Date().addingTimeInterval(-6 * 60) }
        downloads.pump()
        XCTAssertEqual(sent, ["fetch:a"], "five minutes' silence: asked again")
        downloads.pump()
        XCTAssertEqual(sent, ["fetch:a"], "not again straight away: the wait doubled")
    }

    func testAPhoneAwayIsAskedAgainOnlyOnceItsPatienceRunsOut() {
        askPhone("a", reachable: false)
        downloads.testUpdate("a") { $0.relayAskedAt = Date().addingTimeInterval(-10 * 60) }
        downloads.pump()
        XCTAssertEqual(sent, [])
        downloads.testUpdate("a") { $0.relayAskedAt = Date().addingTimeInterval(-25 * 60) }
        downloads.pump()
        XCTAssertEqual(sent, ["fetch:a"], "past twenty minutes, asked again even away")
        XCTAssertEqual(status("a"), .downloading, "with no network of its own the watch keeps waiting on the phone")
    }

    /// From the WatchDownloads.reaskPhone note: "a real watch, whose path
    /// monitor always says down, never takes the item back to fetch itself;
    /// without asking again it waits forever" (memory: watch-network-reality).
    func testWithThePathMonitorDownTheWatchNeverTakesItBack() {
        askPhone("a", reachable: false)
        downloads.testUpdate("a") { $0.relayAskedAt = Date().addingTimeInterval(-3 * 60 * 60) }
        downloads.pump()
        XCTAssertFalse(sent.contains("cancelFetch:a"))
        XCTAssertEqual(status("a"), .downloading)
    }

    func testAPhoneAwayPastItsPatienceHandsTheItemToTheWatch() {
        downloads.testSetNetwork(up: true, wifi: true)
        askPhone("a", reachable: false)
        downloads.testUpdate("a") { $0.relayAskedAt = Date().addingTimeInterval(-25 * 60) }
        downloads.pump()
        XCTAssertTrue(sent.contains("cancelFetch:a"), "\(sent)")
        XCTAssertEqual(status("a"), .queued)
        XCTAssertNil(downloads.record(for: "a")?.relayAskedAt)
        XCTAssertFalse(askedOfPhone.contains("a"), "given up on the phone for the hour")
    }

    /// Regression, 05ce303 "Watch: the phone carries every download": the
    /// watch "silently took every download back from the phone — 1,418
    /// cancels in one phone launch" whenever its path monitor said Wi-Fi.
    /// Now it never takes anything back on the path monitor's word.
    func testThePathMonitorsWordAloneNeverTakesBackFromThePhone() {
        downloads.testSetNetwork(up: true, wifi: true)
        askPhone("a", reachable: true)
        downloads.testUpdate("a") { $0.relayAskedAt = Date().addingTimeInterval(-60 * 60) }
        downloads.pump()
        XCTAssertFalse(sent.contains("cancelFetch:a"), "\(sent)")
        XCTAssertEqual(status("a"), .downloading)

        askPhone("b", reachable: false)
        downloads.testUpdate("b") { $0.relayAskedAt = Date().addingTimeInterval(-10 * 60) }
        downloads.pump()
        XCTAssertFalse(sent.contains("cancelFetch:b"), "away, but within its patience")
    }

    func testPhoneProgressMovesTheBarAndStartsItsPatienceAgain() {
        askPhone("a", reachable: false)
        let old = Date().addingTimeInterval(-10 * 60)
        downloads.testUpdate("a") { $0.relayAskedAt = old; $0.estimatedBytes = 1000 }
        downloads.notePhoneProgress(itemId: "a", fraction: 0.5)
        XCTAssertEqual(downloads.fraction("a")!, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(downloads.record(for: "a")!.relayAskedAt!, old)
        downloads.notePhoneProgress(itemId: "a", fraction: 1.5)
        XCTAssertEqual(downloads.fraction("a")!, 0.99, accuracy: 0.001, "never shown done before it lands")
        downloads.notePhoneProgress(itemId: "unknown", fraction: 0.5)
        XCTAssertNil(downloads.fraction("unknown"))
    }

    func testThePhoneGivingUpWithNoNetworkSaysWhy() {
        askPhone("a", reachable: false)
        downloads.phoneFailed(itemId: "a", reason: "The server said no")
        let r = downloads.record(for: "a")
        XCTAssertEqual(r?.status, .error)
        XCTAssertEqual(r?.errorMessage, "The server said no")
        XCTAssertNil(r?.relayAskedAt)
        XCTAssertEqual(downloads.failed.map(\.itemId), ["a"])
    }

    func testThePhoneGivingUpWithANetworkLetsTheWatchTry() {
        downloads.testSetNetwork(up: true, wifi: true)
        askPhone("a", reachable: false)
        downloads.phoneFailed(itemId: "a", reason: "x")
        XCTAssertEqual(status("a"), .queued)
        XCTAssertEqual(sent, [], "not asked of the phone again for an hour")
    }

    func testAPhoneFailureForSomethingNotAskedIsIgnored() {
        downloads.enqueue([WX.song("a")], reason: "song")
        downloads.phoneFailed(itemId: "a", reason: "x")
        XCTAssertEqual(status("a"), .queued)
    }

    func testSyncNowAsksThePhoneAgainForEverythingAwaiting() {
        link.testSetPhone(reachable: true, companion: true)
        downloads.enqueue([WX.song("a"), WX.song("b")], reason: "song")
        link.testOutbox = []
        downloads.syncNow()
        XCTAssertEqual(Set(askedOfPhone), ["a", "b"])
    }

    // MARK: Failure and retry

    func testAFailedTransferIsTriedThreeTimes() {
        downloads.testSetNetwork(up: true, wifi: true)
        downloads.enqueue([WX.song("a")], reason: "song")
        downloads.failed(itemId: "a", message: "Server error 500")
        XCTAssertEqual(status("a"), .queued)
        XCTAssertEqual(downloads.record(for: "a")?.attempts, 1)
        downloads.failed(itemId: "a", message: "Server error 500")
        XCTAssertEqual(status("a"), .queued)
        downloads.failed(itemId: "a", message: "Server error 500")
        XCTAssertEqual(status("a"), .error)
        XCTAssertEqual(downloads.record(for: "a")?.errorMessage, "Server error 500")
    }

    func testAFailureWithNoWayToTryAgainIsFailedAtOnce() {
        downloads.enqueue([WX.song("a")], reason: "song")
        downloads.failed(itemId: "a", message: "The watch's sign-in was refused")
        XCTAssertEqual(status("a"), .error)
    }

    func testAFailureHereGoesToThePhoneNext() {
        downloads.testSetNetwork(up: true, wifi: true)
        downloads.enqueue([WX.song("a")], reason: "song")
        link.testSetPhone(reachable: true, companion: true)
        downloads.failed(itemId: "a", message: "x")
        XCTAssertEqual(askedOfPhone, ["a"])
        XCTAssertEqual(status("a"), .downloading)
    }

    func testRetryQueuesAFailureAgainFromNothing() {
        downloads.enqueue([WX.song("a"), WX.song("b")], reason: "song")
        downloads.testUpdate("a") { $0.status = .error; $0.attempts = 3; $0.errorMessage = "x"; $0.relayAskedAt = Date() }
        downloads.testUpdate("b") { $0.status = .error }
        downloads.retry("a")
        XCTAssertEqual(status("a"), .queued)
        XCTAssertEqual(downloads.record(for: "a")?.attempts, 0)
        XCTAssertNil(downloads.record(for: "a")?.relayAskedAt)
        downloads.retryAllFailed()
        XCTAssertEqual(status("b"), .queued)
        downloads.retry("missing")
    }

    // MARK: Room

    func testWhatDoesntFitFailsWithTheSizesAndComesBackWhenThereIsRoom() {
        WatchDownloads.testFreeBytes = 600 * 1024 * 1024
        downloads.enqueue([WX.book("big", seconds: 10 * 3600)], reason: "book")
        let r = downloads.record(for: "big")
        XCTAssertEqual(r?.status, .error)
        XCTAssertEqual(r?.lackedSpace, true)
        XCTAssertTrue(r?.errorMessage?.hasPrefix("Not enough space: needs") == true, r?.errorMessage ?? "")
        WatchDownloads.testFreeBytes = 4 * 1024 * 1024 * 1024
        downloads.pump()
        XCTAssertEqual(status("big"), .queued)
        XCTAssertEqual(downloads.record(for: "big")?.lackedSpace, false)
    }

    func testWhatIsAlreadyComingTakesItsRoomFirst() {
        link.testSetPhone(reachable: true, companion: true)
        WatchDownloads.testFreeBytes = 2 * 1024 * 1024 * 1024
        downloads.enqueue([WX.book("first", seconds: 20 * 3600)], reason: "book")
        XCTAssertEqual(status("first"), .downloading, "about 1.1 GB fits in 1.5 GB usable")
        downloads.enqueue([WX.book("second", seconds: 20 * 3600)], reason: "book")
        XCTAssertEqual(status("second"), .error, "the first's room is spoken for")
        XCTAssertEqual(askedOfPhone, ["first"])
    }

    // MARK: Landing

    private func landFile(_ id: String, runtime: Double, fileSeconds: Double) async throws {
        downloads.enqueue([WX.song(id, seconds: runtime)], reason: "song")
        let url = try WX.audioFile(seconds: fileSeconds, in: WatchDownloads.folder(id), name: "audio.wav")
        await downloads.landed(itemId: id, at: url, bytes: 1234)
    }

    func testAWholeFileIsBelieved() async throws {
        try await landFile("a", runtime: 30, fileSeconds: 30)
        let r = try XCTUnwrap(downloads.record(for: "a"))
        XCTAssertEqual(r.status, .complete)
        XCTAssertEqual(r.fileName, "audio.wav")
        XCTAssertEqual(r.bytes, 1234)
        XCTAssertNotNil(downloads.mediaURL(for: r))
        XCTAssertEqual(downloads.totalBytes, 1234)
        XCTAssertEqual(downloads.songs.map(\.itemId), ["a"])
        let values = try WatchDownloads.folder("a").appendingPathComponent("audio.wav").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAFileWithinThreePercentIsWhole() async throws {
        try await landFile("a", runtime: 30, fileSeconds: 29.4)
        XCTAssertEqual(status("a"), .complete)
    }

    /// Regression, the WatchDownloads header: "a stream that ends early looks
    /// exactly like one that finished. So every file that lands is opened and
    /// its length compared with the item's: short by more than a few percent
    /// and it is thrown away and asked for again, up to three times." (Memory:
    /// duo-device-download-forensics, "99% = playlist sliver past the encode".)
    func testAShortFileIsThrownAwayAndAskedForAgainThreeTimes() async throws {
        try await landFile("a", runtime: 30, fileSeconds: 10)
        XCTAssertEqual(status("a"), .queued)
        XCTAssertEqual(downloads.record(for: "a")?.attempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: WatchDownloads.folder("a").appendingPathComponent("audio.wav").path))
        for _ in 0..<2 {
            let url = try WX.audioFile(seconds: 10, in: WatchDownloads.folder("a"), name: "audio.wav")
            await downloads.landed(itemId: "a", at: url, bytes: 1)
        }
        XCTAssertEqual(status("a"), .error)
        XCTAssertEqual(downloads.record(for: "a")?.errorMessage, "The file arrived incomplete")
    }

    func testAFileWithNoKnownLengthGivesTheRecordItsLength() async throws {
        downloads.enqueue([WX.song("a", seconds: 0)], reason: "song")
        let url = try WX.audioFile(seconds: 5, in: WatchDownloads.folder("a"), name: "audio.wav")
        await downloads.landed(itemId: "a", at: url, bytes: 1)
        XCTAssertEqual(status("a"), .complete)
        XCTAssertEqual(Double(downloads.record(for: "a")!.runTimeTicks) / 10_000_000, 5, accuracy: 0.2)
    }

    func testAFileForNothingIsRemoved() async throws {
        let url = try WX.audioFile(seconds: 1, in: WatchDownloads.folder("ghost"))
        await downloads.landed(itemId: "ghost", at: url, bytes: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAFileFromThePhoneTakesTheAudioFilesPlace() async throws {
        askPhone("a", reachable: true)
        downloads.testUpdate("a") { $0.runTimeTicks = WX.ticks(2) }
        let folder = WatchDownloads.folder("a")
        // The record's folder is made by enqueue's background write, which
        // nothing here waits for.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("audio.m4a"))
        let incoming = try WX.audioFile(seconds: 2, in: folder, name: "received-x.wav")
        await downloads.receivedFromPhone(itemId: "a", at: incoming, bytes: 99)
        XCTAssertEqual(status("a"), .complete)
        XCTAssertEqual(downloads.record(for: "a")?.fileName, "audio.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path), "the old file is gone")
        XCTAssertNil(downloads.record(for: "a")?.relayAskedAt)
    }

    /// From WatchDownloads.receivedFromPhone: "Arrived twice — a phone that
    /// resent, or a watch that fetched for itself in the meantime. The file
    /// already here stays." (and WatchLink: "Cleared out first, it was left
    /// with none").
    func testASecondDeliveryLeavesTheFileThatIsThere() async throws {
        try await landFile("a", runtime: 2, fileSeconds: 2)
        let again = try WX.audioFile(seconds: 2, in: WatchDownloads.folder("a"), name: "received-y.wav")
        await downloads.receivedFromPhone(itemId: "a", at: again, bytes: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: WatchDownloads.folder("a").appendingPathComponent("audio.wav").path))
        XCTAssertEqual(downloads.record(for: "a")?.bytes, 1234)
    }

    func testAFileFromThePhoneForNothingIsRemoved() async throws {
        let url = try WX.audioFile(seconds: 1, in: WatchDownloads.folder("ghost"), name: "received-z.wav")
        await downloads.receivedFromPhone(itemId: "ghost", at: url, bytes: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAMissingFileIsNoMediaURL() async throws {
        try await landFile("a", runtime: 2, fileSeconds: 2)
        try FileManager.default.removeItem(at: WatchDownloads.folder("a").appendingPathComponent("audio.wav"))
        XCTAssertNil(downloads.mediaURL(for: downloads.record(for: "a")!))
    }

    // MARK: Cancel and delete

    func testCancelForgetsAQueuedItem() async {
        downloads.enqueue([WX.song("a")], reason: "song")
        let meta = WatchDownloads.folder("a").appendingPathComponent("meta.json")
        _ = await eventually { FileManager.default.fileExists(atPath: meta.path) }
        downloads.cancel("a")
        XCTAssertNil(downloads.record(for: "a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: WatchDownloads.folder("a").path))
    }

    /// A record is written to disk off the main thread (`writeMeta`, detached)
    /// while a cancel removes its folder at once. A cancel landing before the
    /// write — a plan that drops an automatic item the moment the mirror
    /// queued it, or a phone's cancel crossing the ask — can leave meta.json
    /// behind, and `loadRecords` brought the cancelled item back at the next
    /// launch. Fixed by `metaGeneration`: a background write is dropped if its
    /// item was removed after it was scheduled.
    func testACancelRightAfterQueueingLeavesNothingForTheNextLaunch() async {
        downloads.enqueue([WX.song("race")], reason: "song")
        downloads.cancel("race")
        await settle(0.5)
        let meta = WatchDownloads.folder("race").appendingPathComponent("meta.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meta.path), "a cancelled record would come back at launch")
    }

    func testCancellingWhatThePhoneIsFetchingTellsThePhone() {
        askPhone("a", reachable: true)
        downloads.cancel("a")
        XCTAssertTrue(sent.contains("cancelFetch:a"), "\(sent)")
    }

    func testDeleteRemovesTheFileAndItsPlaceInPlaylists() {
        let list = WX.playlist("p")
        downloads.keep(playlist: list, songs: [WX.song("a"), WX.song("b")])
        downloads.delete("a")
        XCTAssertNil(downloads.record(for: "a"))
        XCTAssertEqual(downloads.playlists.first?.itemIds, ["b"])
    }

    func testRemovingAnAlbumLeavesTheSongsAKeptPlaylistAlsoHolds() {
        downloads.keep(playlist: WX.playlist("p"), songs: [WX.song("s1", albumId: "al")])
        downloads.enqueue([WX.song("s1", albumId: "al"), WX.song("s2", albumId: "al")], reason: "album:al")
        downloads.enqueue([WX.song("s3", albumId: "al")], reason: "song")
        downloads.deleteAlbum("al")
        XCTAssertNil(downloads.record(for: "s2"))
        XCTAssertNil(downloads.record(for: "s3"), "a song kept on its own goes with its album")
        XCTAssertEqual(downloads.record(for: "s1")?.reasons, ["playlist:p"])
    }

    func testRemovingAPlaylistTellsThePhoneUnlessThePhoneAsked() {
        downloads.keep(playlist: WX.playlist("p"), songs: [WX.song("a")])
        downloads.deletePlaylist("p")
        XCTAssertTrue(sent.contains("playlistRemoved:p"))
        XCTAssertNil(downloads.record(for: "a"))
        XCTAssertTrue(downloads.playlists.isEmpty)
    }

    /// Regression, c08deb9: "a playlist switched off at the phone is no
    /// longer reported back to it, which could turn a switch flipped on again
    /// back off."
    func testAPlaylistThePhoneSwitchedOffIsNotToldBack() {
        downloads.keep(playlist: WX.playlist("p"), songs: [WX.song("a")])
        downloads.delete(group: .playlist, id: "p")
        XCTAssertTrue(downloads.playlists.isEmpty)
        XCTAssertFalse(sent.contains("playlistRemoved:p"), "\(sent)")
    }

    func testAPlaylistTakenOffHereIsntPutBackByAnOldPlan() async {
        downloads.keep(playlist: WX.playlist("p"), songs: [WX.song("a")])
        downloads.deletePlaylist("p")
        downloads.apply(plan: WatchMirrorPlan(playlistIds: ["p"]))
        XCTAssertEqual(downloads.plannedPlaylistIds, [], "set aside while the phone catches up")
        await downloads.mirrorSettled(within: .seconds(3))
        XCTAssertTrue(downloads.playlists.isEmpty)
        // A plan that no longer names it: the phone has caught up.
        downloads.apply(plan: WatchMirrorPlan())
        downloads.apply(plan: WatchMirrorPlan(playlistIds: ["p"]))
        XCTAssertEqual(downloads.plannedPlaylistIds, ["p"])
    }

    func testRemovingLooseSongsLeavesAlbums() {
        downloads.enqueue([WX.song("loose", albumId: nil)], reason: "song")
        downloads.enqueue([WX.song("kept")], reason: "album:album-1")
        downloads.testUpdate("loose") { $0.status = .complete }
        downloads.testUpdate("kept") { $0.status = .complete }
        downloads.deleteLooseSongs()
        XCTAssertNil(downloads.record(for: "loose"))
        XCTAssertNotNil(downloads.record(for: "kept"))
    }

    func testRemovingEverythingLetsTheWantsAndPlaylistsGoOnBothSides() {
        downloads.keep(WatchDownloadRequest(kind: .album, id: "al", title: "Al"), items: [WX.song("s1", albumId: "al")])
        downloads.keep(playlist: WX.playlist("p"), songs: [WX.song("s2")])
        downloads.enqueue([WX.book("b")], reason: "book")
        downloads.deleteEverything()
        XCTAssertTrue(downloads.records.isEmpty)
        XCTAssertTrue(downloads.playlists.isEmpty)
        XCTAssertTrue(downloads.testWantContents.isEmpty)
        XCTAssertTrue(sent.contains("wantRemoved:album:al"), "\(sent)")
        XCTAssertTrue(sent.contains("playlistRemoved:p"), "\(sent)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: WatchDownloads.folder("s1").path))
    }

    func testADeleteFromThePhoneGoesByGroup() {
        downloads.enqueue([WX.book("b")], reason: "book")
        downloads.enqueue([WX.song("s", albumId: "al")], reason: "album:al")
        downloads.enqueue([WX.song("l", albumId: nil)], reason: "song")
        downloads.testUpdate("l") { $0.status = .complete }
        downloads.delete(group: .book, id: "b")
        downloads.delete(group: .album, id: "al")
        downloads.delete(group: .songs, id: "songs")
        XCTAssertTrue(downloads.records.isEmpty)
    }

    // MARK: Following the phone's playlists

    func testAPlaylistFromThePhoneIsKeptAndFollowed() async {
        downloads.receivedFromPhone(playlist: WatchPlaylistContents(id: "p", name: "Road", imageTag: "t", songs: [WX.song("a"), WX.song("b")]))
        downloads.apply(plan: WatchMirrorPlan(playlistIds: ["p"]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertEqual(downloads.playlists.first?.name, "Road")
        XCTAssertEqual(downloads.playlists.first?.automatic, true)
        XCTAssertEqual(downloads.record(for: "a")?.reasons, ["playlist:p"])
        XCTAssertEqual(downloads.record(for: "a")?.automatic, true)
        XCTAssertTrue(WatchStub.requests(path: "/Playlists/p/Items").isEmpty, "the phone's word, not the server asked")

        // The phone's list without b: b goes.
        downloads.receivedFromPhone(playlist: WatchPlaylistContents(id: "p", name: "Road", imageTag: nil, songs: [WX.song("a")]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertNil(downloads.record(for: "b"))
        XCTAssertEqual(downloads.playlists.first?.itemIds, ["a"])
    }

    func testAPlaylistIsAskedOfTheServerWhenThePhoneSentNone() async {
        WatchStub.on("/Playlists/p/Items", items: [WX.song("a")])
        WatchStub.on("/Items/p", body: WX.itemJSON(WX.playlist("p", name: "From Server")))
        downloads.apply(plan: WatchMirrorPlan(playlistIds: ["p"]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertEqual(downloads.playlists.first?.name, "From Server")
        XCTAssertNotNil(downloads.record(for: "a"))
    }

    func testBooksInProgressFromThePhoneAreQueuedForTheWatch() async {
        downloads.receivedFromPhone(books: WatchBooksContents(books: [WX.book("b")]))
        downloads.apply(plan: WatchMirrorPlan(bookIds: ["b"]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertEqual(downloads.record(for: "b")?.automatic, true)
        XCTAssertEqual(downloads.record(for: "b")?.reasons, ["book"])
        XCTAssertTrue(WatchStub.requests(path: "/Items/b").isEmpty)
    }

    func testABookThePlanStopsNamingLeavesTheQueueUnlessTapped() async {
        downloads.receivedFromPhone(books: WatchBooksContents(books: [WX.book("b"), WX.book("t")]))
        downloads.apply(plan: WatchMirrorPlan(bookIds: ["b", "t"]))
        await downloads.mirrorSettled(within: .seconds(5))
        downloads.enqueue([WX.book("t")], reason: "book")   // tapped as well
        downloads.apply(plan: WatchMirrorPlan(bookIds: []))
        XCTAssertNil(downloads.record(for: "b"))
        XCTAssertNotNil(downloads.record(for: "t"))
    }

    // MARK: What the phone is told

    func testTheInventoryCountsEachByteOnce() async throws {
        try await landFile("s1", runtime: 1, fileSeconds: 1)
        try await landFile("s2", runtime: 1, fileSeconds: 1)
        downloads.keep(playlist: WX.playlist("p", name: "P"), songs: [WX.song("s1")])
        downloads.enqueue([WX.song("loose", albumId: nil)], reason: "song")
        downloads.enqueue([WX.book("b", name: "Book")], reason: "book")
        let inv = downloads.inventory()
        XCTAssertEqual(inv.groups.map(\.kind), [.album, .book, .playlist, .songs])
        guard inv.groups.count == 4 else { return }
        let album = inv.groups[0]
        XCTAssertEqual(album.id, "album-1")
        XCTAssertEqual(album.count, 1, "s1 is the playlist's")
        XCTAssertEqual(album.complete, 1)
        XCTAssertEqual(inv.groups[2].bytes, 1234)
        XCTAssertEqual(inv.itemCount, 2)
        XCTAssertEqual(inv.totalBytes, 2468)
        XCTAssertEqual(inv.inFlight, 2)
        XCTAssertFalse(inv.truncated)
    }

    func testTheInventoryIsCutToFitAMessage() throws {
        let songs = (0..<500).map { WX.song("s\($0)", albumId: "al\($0)", album: String(repeating: "Long album title ", count: 6)) }
        downloads.enqueue(songs, reason: "song")
        let inv = downloads.inventory()
        XCTAssertTrue(inv.truncated)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(inv).count, 50_000)
        XCTAssertEqual(inv.inFlight, 500, "the totals stay whole")
    }

    // MARK: What the pages read

    func testListsThePagesRead() async throws {
        try await landFile("s1", runtime: 1, fileSeconds: 1)
        downloads.enqueue([WX.book("b1", name: "Zed", position: 10), WX.book("b2", name: "Alpha")], reason: "book")
        for id in ["b1", "b2"] {
            let url = try WX.audioFile(seconds: 1, in: WatchDownloads.folder(id), name: "audio.wav")
            downloads.testUpdate(id) { $0.runTimeTicks = WX.ticks(1) }
            await downloads.landed(itemId: id, at: url, bytes: 1)
        }
        downloads.testUpdate("b1") { $0.runTimeTicks = WX.ticks(3600); $0.lastPlayedAt = Date() }
        XCTAssertEqual(downloads.books.map(\.name), ["Alpha", "Zed"])
        XCTAssertEqual(downloads.booksInProgress.map(\.itemId), ["b1"])
        XCTAssertEqual(downloads.albums.map(\.Id), ["album-1"])
        XCTAssertEqual(downloads.albumTracks(albumId: "album-1").map(\.Id), ["s1"])
        XCTAssertEqual(downloads.complete.count, 3)
    }

    func testProgressOfASet() {
        downloads.enqueue([WX.song("a"), WX.song("b")], reason: "song")
        downloads.testUpdate("a") { $0.status = .complete }
        downloads.testUpdate("b") { $0.status = .error }
        let p = downloads.progress(of: ["a", "b", "c"])
        XCTAssertEqual(p.total, 3)
        XCTAssertEqual(p.done, 1)
        XCTAssertEqual(p.failed, 1)
        XCTAssertEqual(p.arriving, 0)
        XCTAssertFalse(p.all)
        XCTAssertTrue(p.any)
        XCTAssertEqual(p.percent, 33)
        XCTAssertEqual(downloads.progress(of: []).total, 0)
    }
}
