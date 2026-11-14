//  The download queue as the screens drive it: what goes in, in what order,
//  what is refused, and what Cancel, Clear and Retry do to it. Nobody is
//  signed in, so the pump starts nothing and the queue stands where it is put.
//  See Support/DownloadHarness.swift.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadQueueTests: DownloadTestCase {
    // MARK: Going in

    func testItemsWaitInTheOrderTheyWereAsked() {
        let a = newId(), b = newId(), c = newId()
        XCTAssertTrue(manager.enqueue(item: film(a, name: "A"), quality: original))
        XCTAssertTrue(manager.enqueue(item: film(b, name: "B"), quality: original))
        XCTAssertTrue(manager.enqueue(item: film(c, name: "C"), quality: original))
        XCTAssertEqual(queued, [a, b, c])
        XCTAssertEqual(manager.transferState(of: a), .queued)
        XCTAssertTrue(manager.isQueuedOrRunning(c))
        XCTAssertNil(manager.record(for: a), "a waiting item has no record until it starts")
        XCTAssertEqual(manager.transfersToFinish, 3, "waiting items count, though they have no record")
    }

    func testNothingWaitingReadsAsNeither() {
        let a = newId()
        XCTAssertNil(manager.transferState(of: a))
        XCTAssertFalse(manager.isQueuedOrRunning(a))
        XCTAssertEqual(manager.transfersToFinish, 0)
    }

    func testEntryCarriesWhatItsRowShows() throws {
        let id = newId()
        manager.enqueue(item: episodeItem(id, series: "The Bear", season: 2, number: 4), quality: p720)
        let entry = try XCTUnwrap(entry(id))
        XCTAssertEqual(entry.title, "The Bear · Season 2: Episode 4 · Episode 4")
        XCTAssertEqual(entry.series, "The Bear")
        XCTAssertEqual(entry.season, 2)
        XCTAssertEqual(entry.episode, 4)
        XCTAssertEqual(entry.quality, "720p · 4.5 Mbps (transcoded)")
        XCTAssertEqual(entry.type, "Episode")
        XCTAssertFalse(entry.isRetry)
        XCTAssertNil(entry.retryAt)
        XCTAssertNil(entry.reason)
        XCTAssertNil(entry.asStream)
        XCTAssertEqual(entry.id, id)
    }

    func testDisplayTitles() {
        XCTAssertEqual(DownloadManager.displayTitle(film("f", name: "Heat")), "Heat")
        XCTAssertEqual(
            DownloadManager.displayTitle(episodeItem("e", series: "Show", season: 0, number: 2)),
            "Show · Specials: Episode 2 · Episode 2"
        )
        let noNumbers = item(#"{"Id":"e","Name":"Pilot","Type":"Episode","SeriesName":"Show"}"#)
        XCTAssertEqual(DownloadManager.displayTitle(noNumbers), "Show · Pilot")
        let noSeries = item(#"{"Id":"e","Name":"Pilot","Type":"Episode"}"#)
        XCTAssertEqual(DownloadManager.displayTitle(noSeries), "Pilot")
    }

    func testTheSameItemIsNotQueuedTwice() {
        let id = newId()
        XCTAssertTrue(manager.enqueue(item: film(id), quality: original))
        XCTAssertFalse(manager.enqueue(item: film(id), quality: p720), "already waiting")
        XCTAssertEqual(queued, [id])
        XCTAssertEqual(entry(id)?.quality, original.label, "the first asking stands")
    }

    func testAFinishedDownloadIsNotQueuedAgain() {
        let id = newId()
        seed(id, .complete)
        XCTAssertFalse(manager.enqueue(item: film(id), quality: original))
        XCTAssertTrue(queued.isEmpty)
    }

    func testAFailedDownloadCanBeAskedForAfresh() {
        let id = newId()
        seed(id, .error)
        XCTAssertTrue(manager.enqueue(item: film(id), quality: original))
        XCTAssertEqual(queued, [id])
        XCTAssertEqual(entry(id)?.isRetry, false, "a fresh asking, built from the item, not a replay")
    }

    func testAnEpisodeAlreadyHereUnderAnOldIdIsNotQueued() {
        // Deleted from the server and added back, the episode has a new id;
        // the copy on the device is still that episode.
        seedEpisode(newId(), seriesId: "showA", season: 3, number: 7)
        let again = episodeItem(newId(), seriesId: "showA", season: 3, number: 7)
        XCTAssertFalse(manager.enqueue(item: again, quality: original))
        let other = episodeItem(newId(), seriesId: "showB", season: 3, number: 7)
        XCTAssertTrue(manager.enqueue(item: other, quality: original), "another show's S3E7 is another episode")
    }

    // MARK: Batches

    func testBatchSkipsWhatIsHereOrWaitingAndKeepsItsOrder() {
        let a = newId(), b = newId(), c = newId(), done = newId(), waiting = newId()
        seed(done, .complete)
        manager.enqueue(item: film(waiting), quality: original)
        let result = manager.enqueue(
            items: [film(a), film(done), film(b), film(a), film(waiting), film(c)], quality: p720
        )
        XCTAssertEqual(result.queued, 3)
        XCTAssertEqual(result.skipped, 3, "one downloaded, one named twice, one already waiting")
        XCTAssertEqual(queued, [waiting, a, b, c])
        XCTAssertEqual(manager.queue.dropFirst().map(\.quality), Array(repeating: p720.label, count: 3))
    }

    func testEmptyBatchQueuesNothing() {
        let result = manager.enqueue(items: [], quality: original)
        XCTAssertEqual(result.queued, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(queued.isEmpty)
    }

    func testASeasonQueuesInEpisodeOrder() {
        let ids = (1...12).map { _ in newId() }
        let season = ids.enumerated().map { episodeItem($0.element, number: $0.offset + 1) }
        let result = manager.enqueue(items: season, quality: original)
        XCTAssertEqual(result.queued, 12)
        XCTAssertEqual(queued, ids)
        XCTAssertEqual(manager.queue.map(\.episode), Array(1...12))
        XCTAssertEqual(manager.transfersToFinish, 12)
    }

    // MARK: Whose the queue is

    func testBacklogOfSongsAndBooksIsCountedApart() async {
        manager.enqueue(items: [song(newId()), song(newId()), film(newId())], quality: original)
        manager.enqueue(item: song(newId(), type: "AudioBook"), quality: original)
        XCTAssertEqual(manager.audioBacklog(books: false), 2)
        XCTAssertEqual(manager.audioBacklog(books: true), 1)

        // One arriving counts with the ones waiting.
        let running = newId()
        seed(running, .downloading, type: "Audio")
        await adopt(running)
        XCTAssertEqual(manager.audioBacklog(books: false), 3)
        XCTAssertEqual(manager.audioBacklog(books: true), 1)
    }

    func testARunningTransferReadsAsDownloadingNotQueued() async {
        let id = newId()
        seed(id, .downloading)
        await adopt(id)
        XCTAssertEqual(manager.transferState(of: id), .downloading)
        XCTAssertTrue(manager.isQueuedOrRunning(id))
        XCTAssertFalse(manager.enqueue(item: film(id), quality: original), "already on its way")
        XCTAssertEqual(manager.transfersToFinish, 1)
    }

    // MARK: Coming out

    func testCancelQueuedTakesOneEntryOut() {
        let a = newId(), b = newId(), c = newId()
        manager.enqueue(items: [film(a), film(b), film(c)], quality: original)
        manager.cancelQueued(b)
        XCTAssertEqual(queued, [a, c])
        XCTAssertFalse(manager.isQueuedOrRunning(b))
        XCTAssertNil(manager.transferState(of: b))
        XCTAssertTrue(manager.enqueue(item: film(b), quality: original), "and it can be asked for again")
        XCTAssertEqual(queued, [a, c, b])
    }

    func testCancelQueuedOfAnEntryThatHadStartedTakesItsRecordAndFiles() throws {
        // Put back by a pause or a stall, an entry has a record and part of
        // a file behind it; both go with it.
        let id = newId()
        seed(id, .error) { $0.receivedBytes = 4_000 }
        let partial = DownloadManager.folder(for: id).appendingPathComponent("resume.data")
        try Data("partial".utf8).write(to: partial)
        manager.retry(id)
        XCTAssertEqual(queued, [id])

        manager.cancelQueued(id)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertNil(manager.record(for: id))
        assertFolderGone(id)
    }

    func testClearQueueEmptiesItAndTakesWhatHadStarted() {
        let fresh = newId(), started = newId(), finished = newId(), failed = newId()
        seed(finished, .complete)
        seed(failed, .error)
        seed(started, .error)
        manager.enqueue(items: [film(fresh), film(newId())], quality: original)
        manager.retry(started)

        XCTAssertEqual(manager.clearQueue(), 3)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertNil(manager.record(for: started), "an entry that had started takes its record with it")
        assertFolderGone(started)
        XCTAssertEqual(manager.record(for: finished)?.status, .complete)
        XCTAssertEqual(manager.record(for: failed)?.status, .error, "a failure not in the queue is not the queue's")
        XCTAssertNil(manager.transferState(of: fresh))
        XCTAssertEqual(manager.clearQueue(), 0)
    }

    func testClearQueueLiftsAPause() {
        manager.setPaused(true)
        manager.enqueue(item: film(newId()), quality: original)
        manager.clearQueue()
        XCTAssertFalse(manager.isPaused, "nothing left to hold back")
    }

    // MARK: Retry

    func testRetryGoesToTheFrontWithACleanSlate() throws {
        let a = newId(), b = newId(), failed = newId()
        manager.enqueue(items: [film(a), film(b)], quality: original)
        seed(failed, .error, name: "Heat") {
            $0.errorMessage = "The connection was lost — stopped after 5 attempts"
            $0.autoRetries = 5
            $0.quality = "720p · 4.5 Mbps (transcoded)"
        }

        manager.retry(failed)
        XCTAssertEqual(queued, [failed, a, b], "something already asked for and watched fail goes first")
        let rec = try XCTUnwrap(manager.record(for: failed))
        XCTAssertEqual(rec.status, .queued)
        XCTAssertNil(rec.errorMessage)
        XCTAssertEqual(rec.autoRetries, 0, "a tap gets the full run of automatic goes behind it")
        let entry = try XCTUnwrap(entry(failed))
        XCTAssertTrue(entry.isRetry)
        XCTAssertEqual(entry.title, "Heat")
        XCTAssertEqual(entry.quality, "720p · 4.5 Mbps (transcoded)", "replayed at the quality it was asked for")
        XCTAssertEqual(entry.type, "Movie")
        XCTAssertNil(entry.retryAt, "now, not after a wait")
        XCTAssertEqual(recordOnDisk(failed)?.status, .queued)
    }

    func testRetryOfSomethingAlreadyWaitingDoesNothing() {
        let id = newId()
        seed(id, .error)
        manager.retry(id)
        manager.retry(id)
        XCTAssertEqual(queued, [id])
    }

    func testRetryOfAnUnknownItemDoesNothing() {
        manager.retry(newId())
        XCTAssertTrue(queued.isEmpty)
    }

    func testRetryAllFailedTakesEveryFailureAndNothingElse() {
        let one = newId(), two = newId(), finished = newId()
        seed(one, .error)
        seed(two, .error)
        seed(finished, .complete)
        XCTAssertEqual(manager.retryAllFailed(), 2)
        XCTAssertEqual(Set(queued), [one, two])
        XCTAssertEqual(manager.record(for: finished)?.status, .complete)
        XCTAssertTrue(manager.tally.failed.isEmpty)
        XCTAssertEqual(manager.retryAllFailed(), 0)
    }

    // MARK: Kept for the next launch

    func testTheQueueIsWrittenForTheNextLaunch() throws {
        let a = newId(), b = newId()
        manager.enqueue(items: [film(a), episodeItem(b, number: 2)], quality: p720)
        manager.flushPersisted()
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "download_queue"))
        let saved = try JSONDecoder().decode([QueuedDownload].self, from: data)
        XCTAssertEqual(saved, manager.queue)
        XCTAssertEqual(saved.map(\.itemId), [a, b])

        manager.cancelQueued(a)
        manager.flushPersisted()
        let after = try JSONDecoder().decode(
            [QueuedDownload].self, from: try XCTUnwrap(UserDefaults.standard.data(forKey: "download_queue"))
        )
        XCTAssertEqual(after.map(\.itemId), [b])
    }

    func testWaitingItemsAreKeptBesideTheQueueTrimmed() throws {
        // The address a waiting download is fetched from is built from the
        // item, so the item is kept too — without what only a title page reads.
        let filmId = newId(), songId = newId()
        let heavy = film(filmId, extra: #","Overview":"A long synopsis","Genres":["Drama"],"Taglines":["One"]"#)
        XCTAssertEqual(heavy.Overview, "A long synopsis")
        manager.enqueue(items: [heavy, song(songId)], quality: original)
        manager.flushPersisted()

        let file = DownloadManager.rootPath.appendingPathComponent("queued-items.json")
        var kept = try JSONDecoder().decode([String: BaseItem].self, from: Data(contentsOf: file))
        XCTAssertEqual(Set(kept.keys), [filmId, songId])
        let keptFilm = try XCTUnwrap(kept[filmId])
        XCTAssertNil(keptFilm.Overview)
        XCTAssertNil(keptFilm.Genres)
        XCTAssertNil(keptFilm.Taglines)
        XCTAssertEqual(keptFilm.MediaSources?.first?.Size, 500_000_000, "what the address and the size are built from stays")
        XCTAssertEqual(keptFilm.MediaSources?.first?.streams.count, 2)
        XCTAssertEqual(kept[songId]?.MediaSources?.first?.streams.map(\.type), ["Audio"], "a song keeps its sound alone")

        manager.cancelQueued(songId)
        manager.flushPersisted()
        kept = try JSONDecoder().decode([String: BaseItem].self, from: Data(contentsOf: file))
        XCTAssertEqual(Set(kept.keys), [filmId])
    }

    // MARK: Small parts

    func testAnEntryIsDueWhenItsWaitIsOver() {
        var entry = QueuedDownload(itemId: "a", title: "A", quality: original.label)
        let now = Date()
        XCTAssertTrue(entry.isDue(at: now), "no wait means now")
        entry.retryAt = now.addingTimeInterval(-1)
        XCTAssertTrue(entry.isDue(at: now))
        entry.retryAt = now
        XCTAssertTrue(entry.isDue(at: now))
        entry.retryAt = now.addingTimeInterval(30)
        XCTAssertFalse(entry.isDue(at: now))
        XCTAssertTrue(entry.isDue(at: now.addingTimeInterval(31)))
    }

    func testATaskIsNamedBySessionAndNumber() {
        let one = handTask(for: "a"), two = handTask(for: "a")
        let first = DownloadTaskKey(Self.session, one)
        XCTAssertEqual(first.id, one.taskIdentifier)
        XCTAssertEqual(first, DownloadTaskKey(Self.session, one))
        XCTAssertNotEqual(first, DownloadTaskKey(Self.session, two))
        // The same number in another session is another transfer.
        var elsewhere = first
        elsewhere.session = "\(DownloadManager.sessionPrefix).downloads"
        XCTAssertNotEqual(first, elsewhere)
        XCTAssertEqual(first.session, "", "a session with no identifier of its own")
    }

    func testSessionsInTestModeHaveNamesOfTheirOwn() {
        XCTAssertTrue(DownloadManager.sessionPrefix.hasSuffix(".uitest"), DownloadManager.sessionPrefix)
        XCTAssertTrue(DownloadManager.sessionPrefix.hasPrefix(DownloadManager.bundleID))
    }
}
#endif
