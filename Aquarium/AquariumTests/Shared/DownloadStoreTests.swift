//  Record keeping: what is written beside a download and where, what Delete
//  takes with it (and what "Delete watched" must not lose), the counts the
//  Downloads page shows, and the watch state noted against a download while
//  the server is out of reach. Nobody is signed in unless a test says so.
//  See Support/DownloadHarness.swift.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadStoreTests: DownloadTestCase {
    private let hour: Int64 = 36_000_000_000

    /// A file of `bytes` in the download's own folder, named as the record names it.
    @discardableResult
    private func putFile(_ name: String, for id: String, bytes: Int = 64) throws -> URL {
        let url = DownloadManager.folder(for: id).appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    /// A stream package where AVFoundation would put one: outside the
    /// download's folder, named relative to the app's home.
    private func makePackage() throws -> (path: String, url: URL) {
        let url = AppDirectory.url(.cachesDirectory)
            .appendingPathComponent("DownloadStoreTests-\(UUID().uuidString).movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(count: 128).write(to: url.appendingPathComponent("0.frag"))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (DownloadManager.homeRelativePath(url), url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: On disk

    func testARecordIsWrittenAsMetaJSONInItsOwnFolder() throws {
        let id = newId()
        let rec = seedEpisode(id, .complete, number: 3) {
            $0.fileName = "Episode 3.mp4"
            $0.totalBytes = 5_000
            $0.ownerUserId = "user1"
        }
        let disk = try XCTUnwrap(recordOnDisk(id))
        XCTAssertEqual(disk.itemId, id)
        XCTAssertEqual(disk.status, .complete)
        XCTAssertEqual(disk.title, rec.title)
        XCTAssertEqual(disk.series, "Show")
        XCTAssertEqual(disk.episode, 3)
        XCTAssertEqual(disk.fileName, "Episode 3.mp4")
        XCTAssertEqual(disk.totalBytes, 5_000)
        XCTAssertEqual(disk.ownerUserId, "user1")
        XCTAssertEqual(
            DownloadManager.folderPath(for: id).deletingLastPathComponent().standardizedFileURL,
            DownloadManager.rootPath.standardizedFileURL
        )
    }

    func testTheLastStateSavedIsTheOneLeftOnDisk() throws {
        let id = newId()
        seed(id, .downloading)
        for n in 1...20 { seed(id, .downloading) { $0.receivedBytes = Int64(n) } }
        seed(id, .error) { $0.errorMessage = "last" }
        let disk = try XCTUnwrap(recordOnDisk(id))
        XCTAssertEqual(disk.status, .error)
        XCTAssertEqual(disk.errorMessage, "last")
        XCTAssertEqual(manager.records.filter { $0.itemId == id }.count, 1, "saved again, not added again")
    }

    func testRecordsAreNewestFirstAndFoundById() {
        let ids = (0..<6).map { _ in newId() }
        for id in ids { seed(id, .complete, name: id) }
        XCTAssertEqual(manager.records.map(\.itemId), ids.reversed())
        for id in ids { XCTAssertEqual(manager.record(for: id)?.name, id) }

        // The lookup keeps its place through a change, a delete and an add.
        seed(ids[2], .error, name: "changed")
        XCTAssertEqual(manager.records.map(\.itemId), ids.reversed(), "a record saved again keeps its place")
        manager.delete(ids[3])
        let late = newId()
        seed(late, .complete, name: late)
        XCTAssertNil(manager.record(for: ids[3]))
        XCTAssertEqual(manager.record(for: ids[2])?.name, "changed")
        XCTAssertEqual(manager.record(for: late)?.name, late)
        for id in [ids[0], ids[1], ids[4], ids[5]] { XCTAssertEqual(manager.record(for: id)?.name, id) }
        XCTAssertNil(manager.record(for: newId()))
    }

    func testRevisionsSayWhenToBuildAgain() {
        let records = manager.recordsRevision, video = manager.videoRevision
        seed(newId(), .complete, type: "Audio")
        XCTAssertNotEqual(manager.recordsRevision, records)
        XCTAssertEqual(manager.videoRevision, video, "a song finishing is not a reason to regroup the films")
        seed(newId(), .complete, type: "Movie")
        XCTAssertNotEqual(manager.videoRevision, video)
    }

    func testFoldersAreMadeOnlyWhenSomethingIsToBeWritten() {
        let id = newId()
        XCTAssertFalse(exists(DownloadManager.folderPath(for: id)), "asking where is not making")
        let made = DownloadManager.folder(for: id)
        XCTAssertTrue(exists(made))
        XCTAssertEqual(made.standardizedFileURL, DownloadManager.folderPath(for: id).standardizedFileURL)
        try? FileManager.default.removeItem(at: made)
    }

    func testAStreamsPlaceIsKeptRelativeToHome() throws {
        // The container is moved between launches; only the relative path
        // survives.
        let package = try makePackage()
        XCTAssertFalse(package.path.hasPrefix("/"), package.path)
        XCTAssertEqual(
            DownloadManager.hlsURL(forRelativePath: package.path).resolvingSymlinksInPath().path,
            package.url.resolvingSymlinksInPath().path
        )
        // AVFoundation hands over a URL relative to home; that is taken as it is.
        let relative = URL(fileURLWithPath: "Library/x.movpkg", relativeTo: URL(fileURLWithPath: NSHomeDirectory()))
        XCTAssertEqual(DownloadManager.homeRelativePath(relative), "Library/x.movpkg")
        // Somewhere not under home is left as it was given.
        XCTAssertEqual(DownloadManager.homeRelativePath(URL(fileURLWithPath: "/elsewhere/x.movpkg")), "/elsewhere/x.movpkg")
    }

    // MARK: Where the media is

    func testMediaURLOfAFileDownload() throws {
        let id = newId()
        let rec = seed(id, .complete) { $0.fileName = "Film.mp4" }
        XCTAssertNil(manager.mediaURL(for: rec), "the record says so; the disk doesn't")
        let file = try putFile("Film.mp4", for: id)
        XCTAssertEqual(manager.mediaURL(for: rec)?.standardizedFileURL, file.standardizedFileURL)

        XCTAssertNil(manager.mediaURL(for: record(id, .downloading) { $0.fileName = "Film.mp4" }), "not until it is finished")
        XCTAssertNil(manager.mediaURL(for: record(id, .complete)), "a record that names no file has none")
    }

    func testMediaURLOfAStreamDownload() throws {
        let package = try makePackage()
        let id = newId()
        let rec = seed(id, .complete) {
            $0.transport = .hls
            $0.hlsPath = package.path
        }
        XCTAssertEqual(manager.mediaURL(for: rec)?.resolvingSymlinksInPath().path, package.url.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: package.url)
        XCTAssertNil(manager.mediaURL(for: rec), "purged by the system: gone")
    }

    // MARK: Delete

    func testDeleteTakesTheRecordTheFolderAndThePackage() throws {
        let id = newId(), other = newId()
        let finished = try makePackage(), partial = try makePackage()
        seed(id, .complete) {
            $0.transport = .hls
            $0.hlsPath = finished.path
            $0.partialPath = partial.path
        }
        try putFile("subtitles.json", for: id)
        seed(other, .complete) { $0.fileName = "Other.mp4" }
        let otherFile = try putFile("Other.mp4", for: other)
        let before = manager.recordsRevision
        manager.flushPersisted()

        manager.delete(id)
        XCTAssertNil(manager.record(for: id))
        XCTAssertFalse(folderExists(id))
        XCTAssertFalse(exists(finished.url), "a stream's bytes live outside its folder; they go too")
        XCTAssertFalse(exists(partial.url))
        XCTAssertNil(recordOnDisk(id))
        XCTAssertNotEqual(manager.recordsRevision, before)
        XCTAssertEqual(manager.record(for: other)?.status, .complete)
        XCTAssertTrue(exists(otherFile))
    }

    func testDeletingASetCountsOnlyWhatWasThere() {
        let a = newId(), b = newId(), c = newId()
        for id in [a, b, c] { seed(id, .complete) }
        XCTAssertEqual(manager.delete([a, newId(), c, a]), 2, "what the confirmation says")
        XCTAssertEqual(manager.records.map(\.itemId), [b])
        XCTAssertEqual(manager.delete([]), 0)
    }

    func testDeleteOfSomethingRunningStopsItToo() async {
        let id = newId()
        seed(id, .downloading)
        await adopt(id)
        manager.delete(id)
        XCTAssertNil(manager.record(for: id))
        XCTAssertNil(manager.transferState(of: id))
        XCTAssertNil(manager.liveProgress[id])
        XCTAssertEqual(manager.transfersToFinish, 0)
    }

    func testDeleteEverythingTakesFilesFailuresAndTheQueue() throws {
        let done = newId(), failed = newId(), started = newId(), waiting = newId()
        seed(done, .complete) { $0.fileName = "Film.mp4" }
        try putFile("Film.mp4", for: done)
        seed(failed, .error)
        seed(started, .error)
        manager.retry(started)
        manager.enqueue(item: film(waiting), quality: original)
        manager.setPaused(true)
        manager.flushPersisted()

        XCTAssertEqual(manager.deleteEverything(), 2, "the two records left once the queue has taken its own")
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertFalse(manager.isPaused)
        XCTAssertEqual(manager.totalBytesOnDisk, 0)
        for id in [done, failed] { XCTAssertFalse(folderExists(id)) }
        assertFolderGone(started)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: DownloadManager.rootPath.path)) ?? []
        XCTAssertEqual(left.filter { $0 != "queued-items.json" && $0 != started }, [],
                       "nothing of any finished or failed download is left under the root")
    }

    // MARK: Delete watched

    func testWatchedIsFinishedFilmsAndEpisodesThatHaveBeenPlayed() {
        let film = newId(), episode = newId()
        seed(film, .complete) { $0.played = true }
        seedEpisode(episode, .complete, number: 1) { $0.played = true }
        seed(newId(), .complete) { $0.played = false }
        seed(newId(), .complete, type: "Audio") { $0.played = true }
        seed(newId(), .complete, type: "AudioBook") { $0.played = true }
        seed(newId(), .error) { $0.played = true }
        XCTAssertEqual(Set(manager.tally.watched.map(\.itemId)), [film, episode],
                       "a song that has been played is not one that is finished with")
    }

    func testDeleteWatchedKeepsWhatTheServerIsStillOwed() throws {
        // Watched on a plane, deleted before landing: the record was the
        // only copy of that, and deleting it used to take it too.
        let changed = Date().addingTimeInterval(-600)
        let unsent = newId(), sent = newId(), unwatched = newId()
        seed(unsent, .complete) {
            $0.played = true
            $0.positionTicks = 0
            $0.progressSynced = false
            $0.ownerUserId = "user1"
            $0.progressChangedAt = changed
        }
        seed(sent, .complete) { $0.played = true }
        seed(unwatched, .complete)
        XCTAssertEqual(manager.pendingSyncCount, 0, "another account's: not this one's to send")

        let watched = manager.tally.watched.map(\.itemId)
        XCTAssertEqual(Set(watched), [unsent, sent])
        XCTAssertEqual(manager.delete(watched), 2)

        XCTAssertEqual(manager.records.map(\.itemId), [unwatched])
        XCTAssertEqual(manager.owedProgress.count, 1, "only what had not been sent is owed")
        let owed = try XCTUnwrap(manager.owedProgress.first)
        XCTAssertEqual(owed.itemId, unsent)
        XCTAssertTrue(owed.played)
        XCTAssertEqual(owed.positionTicks, 0)
        XCTAssertFalse(owed.unplayedPending)
        XCTAssertEqual(owed.ownerUserId, "user1", "and it stays that account's")
        XCTAssertEqual(owed.changedAt, changed)

        // Kept across launches.
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "downloads.owedProgress"))
        XCTAssertEqual(try JSONDecoder().decode([DownloadManager.OwedProgress].self, from: data).map(\.itemId), [unsent])

        manager.settleOwed(unsent)
        XCTAssertTrue(manager.owedProgress.isEmpty)
    }

    func testOwedProgressIsCountedForWhoeverItBelongsTo() {
        ClientStub.install()
        defer { ClientStub.remove() }
        let mine = newId(), theirs = newId(), anyones = newId(), stillHere = newId()
        for (id, owner) in [(mine, ClientStub.userId), (theirs, "someone-else"), (anyones, nil)] as [(String, String?)] {
            seed(id, .complete) {
                $0.positionTicks = 600_000_000
                $0.progressSynced = false
                $0.ownerUserId = owner
            }
        }
        seed(stillHere, .complete) {
            $0.progressSynced = false
            $0.ownerUserId = ClientStub.userId
        }
        XCTAssertEqual(manager.pendingSyncCount, 3, "this account's two and the one from before owners were kept")
        XCTAssertEqual(Set(manager.unsyncedRecords.map(\.itemId)), [mine, anyones, stillHere])
        XCTAssertEqual(manager.tally.unsynced, 4)

        manager.delete([mine, theirs, anyones])
        XCTAssertEqual(manager.owedProgress.count, 3)
        XCTAssertEqual(manager.pendingSyncCount, 3, "one record and two owed; another account's is not counted")
        XCTAssertEqual(OfflineProgress.pendingCount, 3)
    }

    func testOwedProgressIsKeptOncePerItem() {
        let id = newId()
        for position in [Int64(100), 200] {
            seed(id, .complete) {
                $0.positionTicks = position
                $0.progressSynced = false
            }
            manager.delete(id)
        }
        XCTAssertEqual(manager.owedProgress.map(\.positionTicks), [200], "the later account of it replaces the earlier")
    }

    func testAnUnfinishedDownloadCancelledOwesWhatItHadNoted() {
        // Cancel deletes; so does taking a started entry out of the queue.
        let id = newId()
        seed(id, .error) {
            $0.positionTicks = 50
            $0.progressSynced = false
        }
        manager.cancel(id)
        XCTAssertEqual(manager.owedProgress.map(\.itemId), [id])
    }

    // MARK: The counts on the Downloads page

    func testTally() {
        let first = newId(), second = newId(), third = newId()
        for (n, id) in [first, second, third].enumerated() {
            seedEpisode(id, .downloading, number: n + 1) { $0.receivedBytes = 100 }
        }
        seed(newId(), .error) { $0.receivedBytes = 40 }
        seed(newId(), .queued) { $0.receivedBytes = 7 }
        seed(newId(), .complete) {
            $0.receivedBytes = 900
            $0.totalBytes = 1_000
        }
        seed(newId(), .complete, type: "Audio") { $0.totalBytes = 50 }
        seed(newId(), .complete, type: "Audio") { $0.receivedBytes = 60 }
        seed(newId(), .complete, type: "AudioBook") {
            $0.totalBytes = 500
            $0.progressSynced = false
        }
        manager.enqueue(item: film(newId()), quality: original)

        let tally = manager.tally
        XCTAssertEqual(tally.running.map(\.itemId), [first, second, third],
                       "in the order they were started, not newest first")
        XCTAssertEqual(tally.failed.count, 1)
        XCTAssertEqual(tally.completeCount, 4)
        XCTAssertEqual(tally.completeBytes, 1_000 + 50 + 60 + 500, "the larger of the two counts for each")
        XCTAssertEqual(tally.partialBytes, 300 + 40 + 7, "what unfinished transfers already hold")
        XCTAssertEqual(tally.songs, 2)
        XCTAssertEqual(tally.books, 1)
        XCTAssertEqual(tally.unsynced, 1)
        XCTAssertTrue(tally.watched.isEmpty)
        XCTAssertEqual(manager.totalBytesOnDisk, 1_610 + 347, "Delete All frees the partial files too")
        XCTAssertEqual(manager.transfersToFinish, 4, "three running and one waiting")
    }

    func testTallyFollowsTheRecords() {
        let id = newId()
        XCTAssertEqual(manager.tally.completeCount, 0)
        seed(id, .complete) { $0.totalBytes = 10 }
        XCTAssertEqual(manager.tally.completeCount, 1)
        XCTAssertEqual(manager.tally.completeCount, 1, "asked twice, counted once")
        manager.setPlayed(id, played: true)
        XCTAssertEqual(manager.tally.watched.map(\.itemId), [id])
        manager.delete(id)
        XCTAssertEqual(manager.tally.completeCount, 0)
        XCTAssertEqual(manager.totalBytesOnDisk, 0)
    }

    // MARK: Finding a download again

    func testAnEpisodeIsMatchedByItsPlaceInItsShow() {
        let old = newId()
        seedEpisode(old, .complete, seriesId: "showA", season: 2, number: 5)
        seedEpisode(newId(), .error, seriesId: "showA", season: 2, number: 6)
        let again = episodeItem(newId(), seriesId: "showA", season: 2, number: 5)
        XCTAssertEqual(manager.completeRecord(matching: again)?.itemId, old, "same show, season and number: the same episode")
        XCTAssertNil(manager.completeRecord(matching: episodeItem(newId(), seriesId: "showB", season: 2, number: 5)),
                     "two shows can share a name and an S2E5")
        XCTAssertNil(manager.completeRecord(matching: episodeItem(newId(), seriesId: "showA", season: 2, number: 6)),
                     "a failed download is not a download")
        XCTAssertNil(manager.completeRecord(matching: item(#"{"Id":"x","Type":"Episode","SeriesId":"showA"}"#)),
                     "an episode with no numbers is matched by its id or not at all")
    }

    func testAFilmIsMatchedByNameAndLength() {
        let old = newId()
        seed(old, .complete, type: "Movie", name: "Heat") { $0.runTimeTicks = 100 * 600_000_000 }
        func heat(minutes: Int, seconds: Int = 0, name: String = "Heat") -> BaseItem {
            item(#"{"Id":"\#(newId())","Name":"\#(name)","Type":"Movie","RunTimeTicks":\#(Int64(minutes * 60 + seconds) * 10_000_000)}"#)
        }
        XCTAssertEqual(manager.completeRecord(matching: heat(minutes: 100))?.itemId, old)
        XCTAssertEqual(manager.completeRecord(matching: heat(minutes: 100, seconds: 4))?.itemId, old,
                       "the same file scanned again")
        XCTAssertNil(manager.completeRecord(matching: heat(minutes: 100, seconds: 6)), "a remake is not the same film")
        XCTAssertNil(manager.completeRecord(matching: heat(minutes: 100, name: "Heat 2")))
        XCTAssertNil(manager.completeRecord(matching: item(#"{"Id":"x","Name":"Heat","Type":"Movie"}"#)),
                     "no length to compare")
        XCTAssertNil(manager.completeRecord(matching: item(#"{"Id":"x","Name":"Heat","Type":"Series","RunTimeTicks":60000000000}"#)))
    }

    func testTheRecordUnderTheItemsOwnIdDecides() {
        // Under its own id and unfinished, the item is not downloaded —
        // whatever else on the device looks like it.
        let id = newId()
        seedEpisode(newId(), .complete, seriesId: "showA", season: 1, number: 1)
        seedEpisode(id, .error, seriesId: "showA", season: 1, number: 1)
        XCTAssertNil(manager.completeRecord(matching: episodeItem(id, seriesId: "showA", season: 1, number: 1)))
        seedEpisode(id, .complete, seriesId: "showA", season: 1, number: 1)
        XCTAssertEqual(manager.completeRecord(matching: episodeItem(id, seriesId: "showA", season: 1, number: 1))?.itemId, id)
    }

    func testAnotherAccountsDownloadIsNotMatched() {
        ClientStub.install()
        defer { ClientStub.remove() }
        seedEpisode(newId(), .complete, seriesId: "showA", season: 1, number: 1) { $0.ownerUserId = "someone-else" }
        let wanted = episodeItem(newId(), seriesId: "showA", season: 1, number: 1)
        XCTAssertNil(manager.completeRecord(matching: wanted), "a wrong match plays the wrong account's copy")
        let mine = newId()
        seedEpisode(mine, .complete, seriesId: "showA", season: 1, number: 1) { $0.ownerUserId = ClientStub.userId }
        XCTAssertEqual(manager.completeRecord(matching: wanted)?.itemId, mine)
        XCTAssertTrue(manager.belongsToCurrentAccount(record(newId())), "from before owners were kept: anyone's")
    }

    func testMovingADownloadToItsItemsNewId() throws {
        let old = newId(), new = newId()
        seed(old, .complete) {
            $0.fileName = "Film.mp4"
            $0.positionTicks = 42
            $0.progressRevision = 3
        }
        try putFile("Film.mp4", for: old)

        manager.rekey(old, to: new)
        XCTAssertNil(manager.record(for: old))
        XCTAssertFalse(folderExists(old))
        let rec = try XCTUnwrap(manager.record(for: new))
        XCTAssertEqual(rec.status, .complete)
        XCTAssertEqual(rec.positionTicks, 42)
        XCTAssertFalse(rec.progressSynced, "its watch state is owed to the item that exists now")
        XCTAssertEqual(rec.progressRevision, 4)
        XCTAssertNotNil(manager.mediaURL(for: rec), "the file came with it")
        XCTAssertEqual(recordOnDisk(new)?.itemId, new)
    }

    func testADownloadIsNotMovedOntoAnotherOrWhileUnfinished() throws {
        let old = newId(), taken = newId(), unfinished = newId()
        seed(old, .complete, name: "Old")
        seed(taken, .complete, name: "Taken")
        seed(unfinished, .error)
        manager.rekey(old, to: taken)
        XCTAssertEqual(manager.record(for: old)?.name, "Old")
        XCTAssertEqual(manager.record(for: taken)?.name, "Taken")
        manager.rekey(unfinished, to: newId())
        XCTAssertEqual(manager.record(for: unfinished)?.status, .error)
        manager.rekey(old, to: old)
        XCTAssertEqual(manager.record(for: old)?.name, "Old")
        manager.rekey(newId(), to: newId())
        XCTAssertEqual(manager.records.count, 3)
    }

    func testEpisodesOfAShowAreInWatchingOrder() {
        func add(_ season: Int?, _ number: Int, seriesId: String? = "showA", series: String = "Show A",
                 _ status: DownloadRecord.Status = .complete) -> String {
            let id = newId()
            seedEpisode(id, status, seriesId: seriesId, series: series, season: season, number: number)
            return id
        }
        let special = add(0, 1), loose = add(nil, 9), s2e1 = add(2, 1), s1e2 = add(1, 2), s1e1 = add(1, 1)
        _ = add(1, 3, .error)
        _ = add(1, 1, seriesId: "showB", series: "Show B")
        let unnumbered = add(1, 4, seriesId: nil)

        XCTAssertEqual(
            manager.episodes(ofSeries: "showA", seriesName: "Show A").map(\.itemId),
            [s1e1, s1e2, unnumbered, s2e1, special, loose],
            "specials and seasonless episodes last, so autoplay doesn't go from a special back to S1E1"
        )
        XCTAssertEqual(manager.episodes(ofSeries: nil, seriesName: "Show A").count, 6, "by name where there is no id")
        XCTAssertEqual(manager.episodes(ofSeries: "showB", seriesName: nil).count, 1)
        XCTAssertTrue(manager.episodes(ofSeries: "showC", seriesName: "Show C").isEmpty)
        XCTAssertTrue(manager.episodes(ofSeries: nil, seriesName: nil).isEmpty)
    }

    // MARK: Watch state noted here

    func testNotingWhereAFilmWasLeft() throws {
        let id = newId()
        seed(id, .complete) { $0.runTimeTicks = 2 * self.hour }
        manager.noteProgress(itemId: id, positionSeconds: 600)
        var rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.positionTicks, 6_000_000_000)
        XCTAssertFalse(rec.played)
        XCTAssertFalse(rec.progressSynced, "flagged to go to the server")
        XCTAssertEqual(rec.progressRevision, 1)
        XCTAssertEqual(try XCTUnwrap(rec.progressChangedAt).timeIntervalSinceNow, 0, accuracy: 5)
        XCTAssertEqual(rec.resumeSeconds, 600)
        XCTAssertEqual(manager.unsyncedRecords.map(\.itemId), [id])
        XCTAssertEqual(manager.pendingSyncCount, 1)
        XCTAssertEqual(recordOnDisk(id)?.positionTicks, 6_000_000_000)

        manager.noteProgress(itemId: id, positionSeconds: -5)
        rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.positionTicks, 0)
        XCTAssertEqual(rec.progressRevision, 2)
        manager.noteProgress(itemId: newId(), positionSeconds: 5)
        XCTAssertEqual(manager.records.count, 1)
    }

    func testWatchingPastTheServersThresholdMarksItWatched() throws {
        let id = newId()
        seed(id, .complete) {
            $0.runTimeTicks = 2 * self.hour
            $0.unplayedPending = true
        }
        manager.noteProgress(itemId: id, positionSeconds: 2 * 3_600 * 0.89)
        XCTAssertEqual(manager.record(for: id)?.played, false)
        XCTAssertEqual(manager.record(for: id)?.unplayedPending, true)
        manager.noteProgress(itemId: id, positionSeconds: 2 * 3_600 * 0.95)
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertTrue(rec.played)
        XCTAssertFalse(rec.unplayedPending, "watched again: nothing to un-mark")
        XCTAssertEqual(rec.resumeSeconds, 0)
    }

    func testSayingItIsNotWatchedOwesTheServerAnUnmark() throws {
        let id = newId()
        seed(id, .complete) {
            $0.runTimeTicks = 2 * self.hour
            $0.played = true
        }
        manager.noteProgress(itemId: id, positionSeconds: 60, played: false)
        var rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertFalse(rec.played)
        XCTAssertTrue(rec.unplayedPending, "a resume point alone can't say it")
        manager.noteProgress(itemId: id, positionSeconds: 60, played: true)
        rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertTrue(rec.played)
        XCTAssertFalse(rec.unplayedPending)
    }

    func testAFinishedBookStartedAgainIsNoLongerFinished() throws {
        let book = newId(), film = newId()
        seed(book, .complete, type: "AudioBook") {
            $0.runTimeTicks = 10 * self.hour
            $0.played = true
        }
        seed(film, .complete) {
            $0.runTimeTicks = 2 * self.hour
            $0.played = true
        }
        manager.noteProgress(itemId: book, positionSeconds: 20)
        XCTAssertEqual(manager.record(for: book)?.played, true, "half a minute in is a look, not a second listen")
        manager.noteProgress(itemId: book, positionSeconds: 120)
        let rec = try XCTUnwrap(manager.record(for: book))
        XCTAssertFalse(rec.played, "or it would open at 0:00 every time from here on")
        XCTAssertTrue(rec.unplayedPending)
        XCTAssertEqual(rec.resumeSeconds, 120)

        manager.noteProgress(itemId: film, positionSeconds: 120)
        XCTAssertEqual(manager.record(for: film)?.played, true, "a watched film stays watched")

        // A book is done with five minutes left, not at 90%.
        manager.noteProgress(itemId: book, positionSeconds: 9.5 * 3_600)
        XCTAssertEqual(manager.record(for: book)?.played, false)
        manager.noteProgress(itemId: book, positionSeconds: 10 * 3_600 - 240)
        XCTAssertEqual(manager.record(for: book)?.played, true)
    }

    func testMarkSyncedOnlyIfNothingHasMovedSince() throws {
        let id = newId()
        seed(id, .complete) { $0.runTimeTicks = 2 * self.hour }
        manager.noteProgress(itemId: id, positionSeconds: 60, played: false)
        let sent = try XCTUnwrap(manager.record(for: id)).progressRevision
        // Playback carried on while the sync was talking to the server.
        manager.noteProgress(itemId: id, positionSeconds: 90)
        manager.markSynced(id, revision: sent)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, false, "the newer state goes next time")

        manager.markSynced(id, revision: sent + 1)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
        XCTAssertEqual(manager.record(for: id)?.positionTicks, 900_000_000)
        XCTAssertEqual(manager.pendingSyncCount, 0)

        manager.setPlayed(id, played: false)
        XCTAssertEqual(manager.record(for: id)?.unplayedPending, true)
        manager.markSynced(id)
        XCTAssertEqual(manager.record(for: id)?.progressSynced, true)
        XCTAssertEqual(manager.record(for: id)?.unplayedPending, false)
        manager.markSynced(newId())
    }

    func testTheServersStateIsTakenOnlyOverWhatHasBeenSent() throws {
        let synced = newId(), unsent = newId(), theirs = newId()
        seed(synced, .complete)
        seed(unsent, .complete) {
            $0.positionTicks = 5
            $0.progressSynced = false
        }
        seed(theirs, .complete) { $0.ownerUserId = "someone-else" }

        manager.applyServerState(itemId: synced, positionTicks: 700, played: true)
        var rec = try XCTUnwrap(manager.record(for: synced))
        XCTAssertEqual(rec.positionTicks, 700)
        XCTAssertTrue(rec.played)
        XCTAssertTrue(rec.progressSynced, "the server telling us, not us telling the server")
        XCTAssertEqual(rec.progressRevision, 0)

        let before = manager.recordsRevision
        manager.applyServerState(itemId: synced, positionTicks: 700, played: true)
        XCTAssertEqual(manager.recordsRevision, before, "nothing different, nothing written")

        manager.applyServerState(itemId: unsent, positionTicks: 700, played: true)
        rec = try XCTUnwrap(manager.record(for: unsent))
        XCTAssertEqual(rec.positionTicks, 5, "unsent local changes are newer")
        XCTAssertFalse(rec.played)

        manager.applyServerState(itemId: theirs, positionTicks: 700, played: true)
        XCTAssertEqual(manager.record(for: theirs)?.positionTicks, 0, "another account's record takes nothing from this one")
    }

    func testTakingTheServersNewerStateOverUnsentState() throws {
        let id = newId()
        seed(id, .complete) {
            $0.positionTicks = 5
            $0.progressSynced = false
            $0.unplayedPending = true
            $0.progressRevision = 4
        }
        manager.takeServerState(itemId: id, positionTicks: 900, played: true, revision: 3)
        XCTAssertEqual(manager.record(for: id)?.positionTicks, 5, "moved on since it was read: left for next time")

        manager.takeServerState(itemId: id, positionTicks: 900, played: true, revision: 4)
        let rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertEqual(rec.positionTicks, 900)
        XCTAssertTrue(rec.played)
        XCTAssertTrue(rec.progressSynced)
        XCTAssertFalse(rec.unplayedPending)
    }

    func testMarkingWatchedAndUnwatchedByHand() throws {
        let id = newId()
        seed(id, .complete) {
            $0.runTimeTicks = 2 * self.hour
            $0.positionTicks = self.hour
        }
        manager.setPlayed(id, played: true)
        var rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertTrue(rec.played)
        XCTAssertEqual(rec.positionTicks, 0)
        XCTAssertFalse(rec.unplayedPending)
        XCTAssertFalse(rec.progressSynced)
        XCTAssertEqual(rec.progressRevision, 1)

        manager.setPlayed(id, played: false)
        rec = try XCTUnwrap(manager.record(for: id))
        XCTAssertFalse(rec.played)
        XCTAssertTrue(rec.unplayedPending, "the server has to be told in so many words")
        XCTAssertEqual(rec.positionTicks, 0, "or its stopped report at 100% marks it watched again")
        XCTAssertEqual(rec.progressRevision, 2)
        XCTAssertNotNil(rec.progressChangedAt)
        manager.setPlayed(newId(), played: true)
        XCTAssertEqual(manager.records.count, 1)
    }

    // MARK: Keeping up with the server

    func testAdoptRewritesFinishedDownloadsOnly() {
        let done = newId(), arriving = newId()
        seed(done, .complete, name: "Old Name")
        seed(arriving, .error, name: "Old Name")
        let before = manager.recordsRevision
        manager.adopt([film(done, name: "Old Name"), film(newId(), name: "Not here")])
        XCTAssertEqual(manager.recordsRevision, before, "nothing different, nothing written")

        manager.adopt([film(done, name: "New Name"), film(arriving, name: "New Name")])
        XCTAssertEqual(manager.record(for: done)?.name, "New Name")
        XCTAssertEqual(manager.record(for: done)?.title, "New Name")
        XCTAssertEqual(manager.record(for: done)?.status, .complete)
        XCTAssertEqual(manager.record(for: arriving)?.name, "Old Name", "not finished: left as it was")
        XCTAssertEqual(recordOnDisk(done)?.name, "New Name")
    }

    // MARK: Pictures kept beside the media

    func testAPictureOnThisDeviceWinsOverTheServersAddress() throws {
        let id = newId()
        let remote = "http://server.invalid/Items/\(id)/Images/Primary?tag=t1"
        let local = DownloadArtwork.file(itemId: id, kind: .primary)
        XCTAssertEqual(local.lastPathComponent, "art-primary")
        XCTAssertEqual(DownloadArtwork.file(itemId: id, kind: .season).lastPathComponent, "art-season")
        XCTAssertEqual(DownloadArtwork.file(itemId: id, kind: .series).lastPathComponent, "art-series")
        XCTAssertEqual(local.deletingLastPathComponent().standardizedFileURL,
                       DownloadManager.folderPath(for: id).standardizedFileURL)

        var rec = seedEpisode(id, .complete, number: 1) {
            $0.imageURL = remote
            $0.seriesImageURL = "http://server.invalid/Items/show/Images/Primary?tag=s"
        }
        try Data("jpeg".utf8).write(to: local)
        XCTAssertEqual(rec.artURL, local.absoluteString, "no network needed for a picture that is here")
        XCTAssertEqual(rec.seriesArtURL, "http://server.invalid/Items/show/Images/Primary?tag=s",
                       "and the server's address for one that isn't")
        XCTAssertNil(rec.seasonArtURL)

        // Deleted and downloaded again: the answer is asked of the disk afresh.
        manager.delete(id)
        rec = seedEpisode(id, .complete, number: 1) { $0.imageURL = remote }
        XCTAssertEqual(rec.artURL, remote)
    }

    func testPicturesAreTheSameWhateverTheServerIsCalled() {
        XCTAssertEqual(
            DownloadArtwork.key("http://a.example/Items/1/Images/Primary?maxWidth=640&tag=abc"),
            DownloadArtwork.key("https://b.example:8920/Items/1/Images/Primary?tag=abc&quality=90")
        )
        XCTAssertNotEqual(
            DownloadArtwork.key("http://a.example/Items/1/Images/Primary?tag=abc"),
            DownloadArtwork.key("http://a.example/Items/1/Images/Primary?tag=def")
        )
        XCTAssertEqual(DownloadArtwork.key("http://a.example/Items/1/Images/Primary"), "/Items/1/Images/Primary#")
        XCTAssertNil(DownloadArtwork.key(nil))
    }

    func testNothingIsFetchedForAPictureAlreadyHereOrADownloadThatHasGone() async throws {
        // No folder: the download was deleted while this was on its way.
        let gone = record(newId(), .complete) { $0.imageURL = "http://server.invalid/Items/x/Images/Primary?tag=t" }
        let reached = await DownloadArtwork.cache(gone)
        XCTAssertTrue(reached)
        XCTAssertFalse(folderExists(gone.itemId), "writing a picture would bring the folder back for good")

        // Already on disk, or already a file: nothing to ask the server for.
        let id = newId()
        let here = seed(id, .complete) {
            $0.imageURL = "http://server.invalid/Items/\(id)/Images/Primary?tag=t"
            $0.seriesImageURL = DownloadArtwork.file(itemId: id, kind: .primary).absoluteString
        }
        let kept = Data("jpeg".utf8)
        try kept.write(to: DownloadArtwork.file(itemId: id, kind: .primary))
        let again = await DownloadArtwork.cache(here)
        XCTAssertTrue(again)
        XCTAssertEqual(try Data(contentsOf: DownloadArtwork.file(itemId: id, kind: .primary)), kept)
        XCTAssertFalse(exists(DownloadArtwork.file(itemId: id, kind: .series)))
    }
}
#endif
