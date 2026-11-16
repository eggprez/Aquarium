//  What a download will weigh: the estimate quoted in the menus
//  (`DownloadSizes`), the totals the space check adds up, the check itself,
//  and how much of the disk is already spoken for by what is queued or
//  arriving. See Support/DownloadHarness.swift.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class DownloadSizeTests: DownloadTestCase {
    private let sizes = DownloadSizes.shared
    private let gb: Int64 = 1_000_000_000

    /// A 100-minute film far bigger than any rung, so a transcode is a transcode.
    private func bigFilm(_ id: String) -> BaseItem { film(id, size: 20 * gb, bitrate: 26_000_000) }

    /// What a 100-minute encode at a rung weighs: the rung's video bitrate
    /// and 192 kbps of sound, with 2% for the container.
    private func encode(_ videoBitrate: Double, minutes: Double = 100) -> Int64 {
        Int64((videoBitrate + 192_000) / 8 * minutes * 60 * 1.02)
    }

    private func bare(_ id: String, type: String = "Movie") -> BaseItem {
        item(#"{"Id":"\#(id)","Name":"Bare","Type":"\#(type)"}"#)
    }

    // MARK: One item

    func testAnOriginalWeighsWhatTheServersFileDoes() {
        XCTAssertEqual(JellyfinClient.estimateDownloadSize(item: film("f", size: 1_234_567_890), quality: original), 1_234_567_890)
    }

    func testATranscodeWeighsItsBitrateTimesItsLength() throws {
        let estimate = try XCTUnwrap(JellyfinClient.estimateDownloadSize(item: bigFilm("f"), quality: p720))
        XCTAssertEqual(Double(estimate), Double(encode(4_500_000)), accuracy: 2)
        let small = try XCTUnwrap(JellyfinClient.estimateDownloadSize(item: bigFilm("f"), quality: DownloadQualities.all[5]))
        XCTAssertEqual(Double(small), Double(encode(2_000_000)), accuracy: 2)
        XCTAssertLessThan(small, estimate)
    }

    func testAnEncodeThatWouldComeOutBiggerIsTheOriginalInstead() {
        // 500 MB at the 1080p rung would be several gigabytes: what comes
        // down is the file as it is, and that is the figure quoted.
        let small = film("f", size: 500_000_000)
        let rung = DownloadQualities.named("1080p · 9 Mbps (transcoded)")
        XCTAssertTrue(JellyfinClient.effectiveQuality(item: small, quality: rung).original)
        XCTAssertEqual(JellyfinClient.estimateDownloadSize(item: small, quality: rung), 500_000_000)
        XCTAssertFalse(JellyfinClient.effectiveQuality(item: bigFilm("g"), quality: rung).original)
        XCTAssertTrue(JellyfinClient.effectiveQuality(item: bigFilm("g"), quality: original).original)
    }

    func testAnEncodeOfALowBitrateSourceIsSizedAsTheServerWillMakeIt() throws {
        // Jellyfin takes the lower of the rung and the source's bitrate —
        // after inflating a low one two and a half times.
        let source = Self.videoSource(size: 9 * gb, bitrate: 1_192_000, container: "mkv", videoCodec: "mpeg2video")
        let low = item(#"{"Id":"f","Name":"Low","Type":"Movie","RunTimeTicks":60000000000,"MediaSources":[\#(source)]}"#)
        let estimate = try XCTUnwrap(JellyfinClient.estimateDownloadSize(item: low, quality: p720))
        XCTAssertEqual(Double(estimate), Double(encode(2_500_000)), accuracy: 2, "1 Mbps of picture is encoded at 2.5")
    }

    func testAnOriginalThatHasToBeRewrappedWeighsItsPictureAndOneSoundtrack() throws {
        // An MKV carries every soundtrack and subtitle it came with; the
        // rewrap brings down the picture and one soundtrack.
        let source = Self.videoSource(size: 8 * gb, bitrate: 6_000_000, container: "mkv")
        let mkv = item(#"{"Id":"f","Name":"MKV","Type":"Movie","RunTimeTicks":60000000000,"MediaSources":[\#(source)]}"#)
        let estimate = try XCTUnwrap(JellyfinClient.estimateDownloadSize(item: mkv, quality: original))
        XCTAssertEqual(Double(estimate), 6_000_000 / 8 * 6_000 * 1.02, accuracy: 2)
        XCTAssertEqual(JellyfinClient.remuxSize(item: mkv), estimate)

        // Never more than the file it is made from.
        let tiny = Self.videoSource(size: 1_000_000, bitrate: 6_000_000, container: "mkv")
        let capped = item(#"{"Id":"f","Name":"MKV","Type":"Movie","RunTimeTicks":60000000000,"MediaSources":[\#(tiny)]}"#)
        XCTAssertEqual(JellyfinClient.estimateDownloadSize(item: capped, quality: original), 1_000_000)
    }

    func testASongWeighsItsFileWhateverRungIsAsked() {
        let track = song("s", size: 31_000_000)
        XCTAssertEqual(JellyfinClient.estimateDownloadSize(item: track, quality: original), 31_000_000)
        XCTAssertEqual(JellyfinClient.estimateDownloadSize(item: track, quality: p720), 31_000_000,
                       "the rungs are picture sizes and mean nothing to a song")
        XCTAssertTrue(JellyfinClient.effectiveQuality(item: track, quality: p720).original)
    }

    func testASongThatMustBeEncodedWeighsItsLengthAt256k() throws {
        let ogg = item("""
        {"Id":"s","Name":"Song","Type":"Audio","RunTimeTicks":2400000000,
         "MediaSources":[{"Id":"s","Container":"wma","Size":9000000,"MediaStreams":[{"Index":0,"Type":"Audio","Codec":"wmav2"}]}]}
        """)
        let estimate = try XCTUnwrap(JellyfinClient.estimateDownloadSize(item: ogg, quality: original))
        XCTAssertEqual(Double(estimate), 240.0 * 256_000 / 8 * 1.02, accuracy: 2)
    }

    func testNothingToGoOnIsNoEstimate() {
        XCTAssertNil(JellyfinClient.estimateDownloadSize(item: bare("f"), quality: original))
        XCTAssertNil(JellyfinClient.estimateDownloadSize(item: bare("f"), quality: p720), "no length, no bitrate times length")
        XCTAssertNil(JellyfinClient.estimateDownloadSize(item: bare("s", type: "Audio"), quality: original))
        XCTAssertNil(JellyfinClient.estimateDownloadSize(item: film("f", size: 0), quality: original), "a size of nothing is no size")
    }

    // MARK: A batch

    func testATotalIsTheSumOfWhatCanBeEstimated() {
        let items = [film("a", size: 100), film("b", size: 250), bare("c")]
        XCTAssertEqual(DownloadManager.estimateTotal(items, quality: original), 350, "what can't be estimated is left out, not guessed")
        XCTAssertNil(DownloadManager.estimateTotal([bare("c"), bare("d")], quality: original), "none of them: nothing can be said")
        XCTAssertNil(DownloadManager.estimateTotal([], quality: original))
    }

    func testATotalPastWhatAnIntegerHoldsIsTooBigNotACrash() {
        // The sizes are the server's word.
        let absurd = (0..<6).map { film("f\($0)", size: Int64.max - 1, bitrate: 1_000_000_000) }
        XCTAssertEqual(DownloadManager.estimateTotal(absurd, quality: original), Int64.max / 2)
        let verdict = DownloadManager.checkSpace(for: absurd, quality: original)
        XCTAssertEqual(verdict?.fits, false, "and the headroom added to it still fits in the sum")
    }

    // MARK: The space check

    func testSomethingSmallFits() throws {
        let free = try XCTUnwrap(DownloadManager.freeSpace())
        try XCTSkipIf(free < 4 * (1 << 30), "this machine's disk is too full to say anything fits")
        let verdict = try XCTUnwrap(DownloadManager.checkSpace(for: [film("a", size: 1_000_000)], quality: original))
        XCTAssertTrue(verdict.fits)
        XCTAssertEqual(verdict.needed, 1_000_000)
        XCTAssertEqual(Double(verdict.free), Double(free), accuracy: Double(1 << 30), "nothing else is spoken for")
        XCTAssertTrue(verdict.alternatives.isEmpty, "nothing smaller need be offered")
    }

    func testSomethingTooBigOffersTheRungsThatWouldFit() throws {
        // A film bigger than any disk, at original quality.
        let huge = film("a", size: Int64.max / 8, bitrate: 1_000_000_000)
        let verdict = try XCTUnwrap(DownloadManager.checkSpace(for: [huge], quality: original))
        XCTAssertFalse(verdict.fits)
        XCTAssertEqual(verdict.needed, Int64.max / 8)
        let fitting = DownloadQualities.all.filter { rung in
            guard !rung.original, let need = DownloadManager.estimateTotal([huge], quality: rung) else { return false }
            return need + DownloadManager.spaceHeadroom <= verdict.free
        }
        XCTAssertEqual(verdict.alternatives, fitting)
        XCTAssertFalse(verdict.alternatives.contains { $0.original }, "the rung that was refused is not offered back")
        XCTAssertEqual(DownloadManager.spaceHeadroom, 1 << 30, "never fill the volume to the last byte")
    }

    func testNoVerdictWhenTheSizeIsUnknowable() {
        XCTAssertNil(DownloadManager.checkSpace(for: [bare("a")], quality: original),
                     "queues as before: the check is there to catch the obvious, not to be a new way to fail")
    }

    func testRoomIsMeasuredAfterWhatIsAlreadyOnItsWay() throws {
        // A second season queued before the first had arrived was measured
        // against room the first was about to fill.
        let small = film(newId(), size: 1_000_000)
        let free = try XCTUnwrap(DownloadManager.freeSpace())
        try XCTSkipIf(free < 4 * (1 << 30), "this machine's disk is too full to say anything fits")
        XCTAssertEqual(DownloadManager.checkSpace(for: [small], quality: original)?.fits, true)

        manager.enqueue(item: film(newId(), size: Int64.max / 8, bitrate: 1_000_000_000), quality: original)
        let verdict = try XCTUnwrap(DownloadManager.checkSpace(for: [small], quality: original))
        XCTAssertFalse(verdict.fits)
        XCTAssertEqual(verdict.free, 0, "all of it is spoken for")
    }

    // MARK: What is still to come

    func testBytesStillToComeAddsWhatIsArrivingAndWhatIsWaiting() async {
        XCTAssertEqual(manager.bytesStillToCome, 0)

        // Arriving, with a length: what is left of it, by the live count.
        let running = newId()
        seed(running, .downloading) { $0.totalBytes = 1_000 }
        await adopt(running, received: 400, expected: 1_000)
        XCTAssertEqual(manager.bytesStillToCome, 600)

        // A stream: against its projection, or failing that the estimate.
        seed(newId(), .queued) {
            $0.projectedBytes = 5_000
            $0.estimatedBytes = 9_000
            $0.receivedBytes = 1_000
        }
        XCTAssertEqual(manager.bytesStillToCome, 600 + 4_000)
        seed(newId(), .downloading) { $0.estimatedBytes = 300 }
        XCTAssertEqual(manager.bytesStillToCome, 600 + 4_000 + 300)
        // Past its estimate: nothing more is promised, and nothing is owed back.
        seed(newId(), .downloading) {
            $0.estimatedBytes = 300
            $0.receivedBytes = 900
        }
        XCTAssertEqual(manager.bytesStillToCome, 4_900)

        // Waiting, never started: the whole of its estimate.
        manager.enqueue(item: film(newId(), size: 70_000), quality: original)
        manager.enqueue(item: bare(newId()), quality: original)
        XCTAssertEqual(manager.bytesStillToCome, 74_900, "what can't be estimated adds nothing")

        // Finished and failed downloads promise nothing more.
        seed(newId(), .complete) { $0.totalBytes = 1 << 40 }
        seed(newId(), .error) { $0.estimatedBytes = 1 << 40 }
        XCTAssertEqual(manager.bytesStillToCome, 74_900)
    }

    func testAnEntryPutBackIsCountedOnceByItsRecord() {
        let id = newId()
        seed(id, .error) { $0.estimatedBytes = 2_000 }
        manager.retry(id)
        XCTAssertEqual(manager.bytesStillToCome, 2_000, "its record speaks for it; the queue entry adds nothing")
    }

    // MARK: The menus

    func testItemsHandedOverWithTheirFilesAnswerForTheOnesWithout() {
        let id = newId()
        let full = film(id, size: 123_456)
        let light = bare(id)
        XCTAssertNil(sizes.best(light).MediaSources, "nothing handed over yet: the item as it is")
        sizes.note([full, bare(newId())])
        XCTAssertEqual(sizes.best(light).MediaSources?.first?.Size, 123_456)

        // An item that carries its own files is the best copy of itself.
        let newer = film(id, size: 999)
        XCTAssertEqual(sizes.best(newer).MediaSources?.first?.Size, 999)
        // One without is never kept over one with.
        sizes.note([light])
        XCTAssertEqual(sizes.best(light).MediaSources?.first?.Size, 123_456)
    }

    func testWhatASeasonIsMadeOf() {
        let season = newId(), a = newId(), b = newId(), unsized = newId()
        XCTAssertNil(sizes.items(of: season), "not handed over: nothing to say")
        sizes.note([film(a, size: 10), bare(unsized), film(b, size: 20)], as: season)
        XCTAssertEqual(sizes.items(of: season)?.map(\.Id), [a, b], "in order, less what carries no files")
        XCTAssertEqual(sizes.bytes(sizes.items(of: season) ?? [], quality: original), 30)
    }

    func testWarmingFetchesOnce() async {
        let album = newId(), track = newId()
        var asked = 0
        await sizes.warm(album) {
            asked += 1
            return []
        }
        XCTAssertNil(sizes.items(of: album), "an empty answer is not an answer")
        for _ in 0..<3 {
            await sizes.warm(album) {
                asked += 1
                return [self.song(track, size: 5_000)]
            }
        }
        XCTAssertEqual(asked, 2, "once it is known it is not asked for again")
        XCTAssertEqual(sizes.items(of: album)?.map(\.Id), [track])
    }

    func testAMenuQuotesOnlyWhatDownloadingWouldAdd() {
        let fresh = newId(), here = newId(), waiting = newId(), failed = newId()
        seed(here, .complete)
        seed(failed, .error)
        manager.enqueue(item: film(waiting, size: 4_000), quality: original)
        let items = [film(fresh, size: 1_000), film(here, size: 2_000), film(waiting, size: 4_000), film(failed, size: 8_000)]
        XCTAssertEqual(sizes.bytes(items, quality: original), 9_000, "what is here or on its way is left out; a failure is not here")
        XCTAssertNil(sizes.bytes([film(here, size: 2_000), film(waiting, size: 4_000)], quality: original),
                     "nothing it would add: no figure")
        XCTAssertNil(sizes.bytes([bare(newId())], quality: original), "nothing to go on: no figure")
        XCTAssertNil(sizes.bytes([], quality: original))

        // A list item without its files is sized from the copy handed over.
        sizes.note([film(fresh, size: 1_000)])
        XCTAssertEqual(sizes.bytes([bare(fresh)], quality: original), 1_000)
    }

    func testTheWordsUnderAChoice() {
        XCTAssertNil(DownloadSizes.text(nil))
        XCTAssertNil(DownloadSizes.text(0))
        XCTAssertEqual(DownloadSizes.text(512), "About 512 B")
        XCTAssertEqual(DownloadSizes.text(3 << 20), "About 3.0 MiB")
        XCTAssertEqual(DownloadSizes.text(3 << 29), "About 1.50 GiB")
    }
}
#endif
