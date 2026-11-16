//  `ImageLoader`: how wide a picture is asked for, what a fetch makes of each
//  kind of answer, which answers are remembered, when a copy already in
//  memory or on disk is used instead of the network, and the rules for the
//  artwork kept on disk for the library copy.
//
//  Pictures are served from this machine's loopback address. Every test uses
//  item ids of its own, because the loader is one shared actor.

import XCTest
@testable import Aquarium

final class ImageLoaderTests: XCTestCase {
    private var server: LoopbackServer!
    private let loader = ImageLoader.shared
    private var itemId = ""
    private var picture = Data()

    override func setUp() async throws {
        server = try LoopbackServer()
        itemId = "img" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        picture = CorePicture.png(width: 60, height: 90)
        servePictures()
    }

    override func tearDown() async throws {
        await loader.forgetDiskArtwork(for: [itemId, itemId + "b"])
        await loader.setDiskEnabled(false)
        server.stop()
    }

    /// Every address answers with the small poster.
    private func servePictures() {
        let picture = picture
        server.setHandler { _ in .data(picture, type: "image/png") }
    }

    /// A Jellyfin artwork address: item, image type, tag and width.
    private func artwork(_ width: Int, tag: String = "tag1", type: String = "Primary", item: String? = nil) -> URL {
        server.url("/Items/\(item ?? itemId)/Images/\(type)?maxWidth=\(width)&tag=\(tag)&quality=90")
    }

    private func kind(_ outcome: ImageLoader.Outcome) -> String {
        switch outcome {
        case .image: "image"
        case .absent: "absent"
        case .failed: "failed"
        }
    }

    private func fetch(_ url: URL) async -> String { kind(await loader.fetch(url)) }

    // MARK: Sizing

    func testRequestWidthRoundsUpToASteppedPixelWidth() {
        XCTAssertEqual(ImageLoader.requestWidth(points: 80, displayScale: 1), 80)
        XCTAssertEqual(ImageLoader.requestWidth(points: 81, displayScale: 1), 160)
        XCTAssertEqual(ImageLoader.requestWidth(points: 100, displayScale: 2), 240)
        XCTAssertEqual(ImageLoader.requestWidth(points: 160, displayScale: 3), 480)
        XCTAssertEqual(ImageLoader.requestWidth(points: 100, displayScale: 0), 160, "a scale of nothing is a scale of one")
        XCTAssertEqual(ImageLoader.requestWidth(points: 0, displayScale: 2), 0)
        // Dragging a window edge a few points is the same request.
        XCTAssertEqual(ImageLoader.requestWidth(points: 301, displayScale: 2), ImageLoader.requestWidth(points: 318, displayScale: 2))
    }

    func testImageRequestsLookLikeABrowsers() {
        let request = ImageLoader.imageRequest(URL(string: "http://logos.invalid/a.png")!)
        XCTAssertEqual(request.url?.absoluteString, "http://logos.invalid/a.png")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept")?.hasPrefix("image/avif,image/webp,image/png"), true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari"), true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent")?.contains("Aquarium"), false)
    }

    // MARK: Answers

    func testAPictureIsFetchedOnceAndThenHeld() async {
        let url = artwork(400)
        let before = await loader.cached(url)
        XCTAssertNil(before)
        let first = await fetch(url)
        XCTAssertEqual(first, "image")
        let held = await loader.cached(url)
        XCTAssertNotNil(held)
        let again = await loader.load(url)
        XCTAssertNotNil(again)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?.headers["accept"]?.hasPrefix("image/avif"), true, "asked the way a browser asks")
    }

    func testManyCallersForOnePictureShareOneRequest() async {
        let url = artwork(400)
        let outcomes = await withTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { await self.fetch(url) } }
            var all: [String] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertEqual(outcomes, Array(repeating: "image", count: 8))
        XCTAssertEqual(server.requests.count, 1, "a poster that appears in three rows is fetched once")
    }

    func testANarrowerRequestIsAnsweredFromTheWiderCopyInMemory() async {
        _ = await fetch(artwork(400))
        let narrower = await fetch(artwork(320))
        XCTAssertEqual(narrower, "image")
        let cachedNarrow = await loader.cached(artwork(160))
        XCTAssertNotNil(cachedNarrow)
        XCTAssertEqual(server.requests.count, 1)

        _ = await fetch(artwork(800))
        XCTAssertEqual(server.requests.count, 2, "a wider one is a new fetch")
        _ = await fetch(artwork(320, tag: "tag2"))
        XCTAssertEqual(server.requests.count, 3, "a new tag is a new picture")
        _ = await fetch(artwork(320, type: "Logo"))
        XCTAssertEqual(server.requests.count, 4, "and a logo is not the poster")
    }

    func testForgetAndPurgeDropWhatIsHeld() async {
        let url = artwork(400)
        _ = await fetch(url)
        await loader.forget(url)
        let afterForget = await loader.cached(url)
        XCTAssertNil(afterForget)
        let narrowAfterForget = await loader.cached(artwork(320))
        XCTAssertNil(narrowAfterForget, "the wider copy it would have used is gone")

        _ = await fetch(url)
        await loader.purge()
        let afterPurge = await loader.cached(url)
        XCTAssertNil(afterPurge)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testNoPictureThereIsRememberedAndNotAskedAgain() async {
        for status in [404, 403] {
            server.setHandler { _ in .status(status) }
            let url = artwork(400, tag: "missing\(status)")
            let first = await fetch(url)
            XCTAssertEqual(first, "absent", "\(status)")
            let second = await fetch(url)
            XCTAssertEqual(second, "absent")
            XCTAssertEqual(server.requests(to: url.path).filter { $0.target.contains("missing\(status)") }.count, 1,
                           "a library scrolled back and forth must not send the same 404 again and again")
            let nothing = await loader.load(url)
            XCTAssertNil(nothing)
        }
    }

    func testAHostUnderLoadIsAFailureAndIsAskedAgain() async {
        for status in [500, 503, 429] {
            server.setHandler { _ in .status(status) }
            let url = artwork(400, tag: "busy\(status)")
            let first = await fetch(url)
            XCTAssertEqual(first, "failed", "\(status): not now is not the same as not here")
            servePictures()
            let second = await fetch(url)
            XCTAssertEqual(second, "image", "\(status)")
        }
    }

    func testABodyThatWillNotDecodeIsWorthAnotherLook() async {
        server.setHandler { _ in .text("<html>proxy error</html>", type: "image/png") }
        let url = artwork(400)
        let first = await fetch(url)
        XCTAssertEqual(first, "failed", "cut short far more often than a broken file on the server")
        servePictures()
        let second = await fetch(url)
        XCTAssertEqual(second, "image")
    }

    func testAnUnreachableHostIsAFailure() async {
        let url = artwork(400)
        server.stop()
        let outcome = await fetch(url)
        XCTAssertEqual(outcome, "failed")
    }

    func testAFileOnThisDeviceIsReadDirectlyAndNeverWrittenOff() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(itemId).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let missing = await fetch(file)
        XCTAssertEqual(missing, "absent")
        try picture.write(to: file)
        let found = await fetch(file)
        XCTAssertEqual(found, "image", "a download's artwork can land at any moment; its absence is not remembered")
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: Decoding

    func testAnOversizedPictureFromAHostThatCannotSizeItIsScaledDown() async {
        let huge = CorePicture.png(width: 2400, height: 300)
        server.setHandler { _ in .data(huge, type: "image/png") }
        let image = await loader.load(server.url("/logos/\(itemId).png"))
        XCTAssertEqual(image.map(CorePicture.longestSide), 1024, "a channel logo is whatever file the host had")
    }

    func testAnAddressThatClaimsAWidthIsTrustedOnlySoFar() async {
        let huge = CorePicture.png(width: 5000, height: 20)
        server.setHandler { _ in .data(huge, type: "image/png") }
        let image = await loader.load(server.url("/logos/\(itemId).png?maxwidth=30000"))
        XCTAssertEqual(image.map(CorePicture.longestSide), 4096, "any host can write maxwidth= in a query")
    }

    func testAPictureAlreadySmallEnoughKeepsItsSize() async {
        let image = await loader.load(server.url("/logos/\(itemId)-small.png"))
        XCTAssertEqual(image.map(CorePicture.longestSide), 90)
    }

    // MARK: Kept on disk

    func testWithTheCopyOffNothingIsSaved() async {
        await loader.setDiskEnabled(false)
        _ = await fetch(artwork(400))
        let files = await loader.savedArtworkFiles(for: [itemId])
        XCTAssertTrue(files.isEmpty)
        let saved = await loader.saveToDisk(artwork(400))
        XCTAssertFalse(saved)
    }

    func testAFetchedPictureIsFiledByItemTypeTagAndWidth() async throws {
        await loader.setDiskEnabled(true)
        let usageBefore = await loader.diskUsage()
        _ = await fetch(artwork(400))
        let files = await loader.savedArtworkFiles(for: [itemId, "someone-else"])
        let file = try XCTUnwrap(files[itemId])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(file.lastPathComponent, "\(itemId)_Primary_tag1_400")
        XCTAssertEqual(try Data(contentsOf: file), picture)
        let usage = await loader.diskUsage()
        XCTAssertEqual(usage - usageBefore, Int64(picture.count))
        let logos = await loader.savedArtworkFiles(for: [itemId], type: "Logo")
        XCTAssertTrue(logos.isEmpty)
    }

    func testOnlyServerArtworkWithATagIsKept() async {
        await loader.setDiskEnabled(true)
        _ = await fetch(server.url("/Items/\(itemId)/Images/Primary?maxWidth=400"))   // no tag: nothing says when it changes
        _ = await fetch(server.url("/logos/\(itemId).png?tag=t&maxWidth=400"))        // not an item's artwork
        let files = await loader.savedArtworkFiles(for: [itemId])
        XCTAssertTrue(files.isEmpty)
    }

    func testWhatCountsAsAlreadyOnDisk() async {
        await loader.setDiskEnabled(true)
        _ = await fetch(artwork(400))
        var missing = await loader.missingOnDisk([artwork(400)])
        XCTAssertEqual(missing, [])
        missing = await loader.missingOnDisk([artwork(520)])
        XCTAssertEqual(missing, [], "three quarters of the width asked for is indistinguishable on a card")
        missing = await loader.missingOnDisk([artwork(540)])
        XCTAssertEqual(missing, [artwork(540)], "less is visibly soft")
        missing = await loader.missingOnDisk([artwork(400, tag: "tag2")])
        XCTAssertEqual(missing, [artwork(400, tag: "tag2")], "a new tag is a new picture")
        let other = artwork(400, item: itemId + "b")
        missing = await loader.missingOnDisk([other, other, artwork(800, item: itemId + "b"), server.url("/logos/x.png")])
        XCTAssertEqual(missing, [other], "each slot once, and nothing that could not be filed anyway")
    }

    func testASavedCopyAnswersWithNoServer() async {
        await loader.setDiskEnabled(true)
        _ = await fetch(artwork(400))
        await loader.purge()
        server.setHandler { _ in .status(500) }

        let sameSize = await fetch(artwork(400))
        XCTAssertEqual(sameSize, "image")
        let smaller = await fetch(artwork(160))
        XCTAssertEqual(smaller, "image")
        XCTAssertEqual(server.requests.count, 1, "big enough on disk: the server is not asked")

        let larger = await fetch(artwork(1600))
        XCTAssertEqual(larger, "image", "too small to be the answer, but better than nothing when the server fails")
        XCTAssertEqual(server.requests.count, 2, "and the server was asked for the better one first")
    }

    func testAWiderOrNewerPictureReplacesTheSavedOne() async throws {
        await loader.setDiskEnabled(true)
        _ = await fetch(artwork(400))
        let firstFile = await loader.savedArtworkFiles(for: [itemId])[itemId]
        let first = try XCTUnwrap(firstFile)

        _ = await fetch(artwork(320, tag: "tag1"))
        var now = await loader.savedArtworkFiles(for: [itemId])[itemId]
        XCTAssertEqual(now?.lastPathComponent, "\(itemId)_Primary_tag1_400", "a narrower one changes nothing")

        _ = await fetch(artwork(800))
        now = await loader.savedArtworkFiles(for: [itemId])[itemId]
        XCTAssertEqual(now?.lastPathComponent, "\(itemId)_Primary_tag1_800")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the narrower file is deleted")

        _ = await fetch(artwork(160, tag: "tag2"))
        now = await loader.savedArtworkFiles(for: [itemId])[itemId]
        XCTAssertEqual(now?.lastPathComponent, "\(itemId)_Primary_tag2_160", "a new tag replaces the old picture whatever its width")
        let usage = await loader.savedArtworkFiles(for: [itemId]).count
        XCTAssertEqual(usage, 1)
    }

    func testSaveToDiskKeepsPicturesAndNothingElse() async {
        await loader.setDiskEnabled(true)
        var saved = await loader.saveToDisk(artwork(400))
        XCTAssertTrue(saved)
        let files = await loader.savedArtworkFiles(for: [itemId])
        XCTAssertEqual(files[itemId]?.lastPathComponent, "\(itemId)_Primary_tag1_400")
        let notDecoded = await loader.cached(artwork(400))
        XCTAssertNil(notDecoded, "saved without being decoded for display")

        saved = await loader.saveToDisk(artwork(320))
        XCTAssertTrue(saved)
        XCTAssertEqual(server.requests.count, 1, "already there, wide enough: not fetched again")

        let other = itemId + "b"
        server.setHandler { _ in .text("<html><body>Sign in</body></html>", type: "text/html") }
        saved = await loader.saveToDisk(artwork(400, item: other))
        XCTAssertFalse(saved, "an error page is not filed as a poster")
        server.setHandler { _ in .status(404) }
        saved = await loader.saveToDisk(artwork(400, item: other))
        XCTAssertFalse(saved)
        server.setHandler { _ in .data(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]), type: "image/jpeg") }
        saved = await loader.saveToDisk(artwork(400, item: other))
        XCTAssertTrue(saved, "told by its first bytes, without decoding every one")
        saved = await loader.saveToDisk(server.url("/logos/x.png"))
        XCTAssertFalse(saved, "nothing to file a playlist's logo under")
    }

    func testTheArtworkOfItemsThatAreGoneComesOffTheDisk() async throws {
        await loader.setDiskEnabled(true)
        let other = itemId + "b"
        _ = await fetch(artwork(400))
        _ = await fetch(artwork(320, type: "Logo"))
        _ = await fetch(artwork(400, item: other))
        let posterFile = await loader.savedArtworkFiles(for: [itemId])[itemId]
        let logoFile = await loader.savedArtworkFiles(for: [itemId], type: "Logo")[itemId]
        let poster = try XCTUnwrap(posterFile)
        let logo = try XCTUnwrap(logoFile)

        await loader.forgetDiskArtwork(for: [])
        await loader.forgetDiskArtwork(for: [itemId, "never-saved"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: poster.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logo.path), "every picture of the item, not only its poster")
        let gone = await loader.savedArtworkFiles(for: [itemId])
        XCTAssertTrue(gone.isEmpty)
        let kept = await loader.savedArtworkFiles(for: [other])
        XCTAssertEqual(kept.count, 1, "its neighbour's stays")
        let missing = await loader.missingOnDisk([artwork(400)])
        XCTAssertEqual(missing, [artwork(400)])
    }
}
