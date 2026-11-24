//  What every platform's player chrome is built from (`Player/Chrome/PlayerParts.swift`):
//  the scrub thumbnails cut from Jellyfin's trickplay sheets, and a live
//  channel's schedule (what is on now, what comes after) for the Info card
//  and the live timeline. Against `ClientStub`; the sheet is a PNG drawn here,
//  four solid colours in a 2 × 2 grid, so a thumbnail's colour says which
//  cell was cut.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Aquarium

@MainActor
final class PlayTrickplayStoreTests: XCTestCase {
    override func setUp() async throws { ClientStub.install() }
    override func tearDown() async throws { ClientStub.remove() }

    private static let cellWidth = 4, cellHeight = 3
    /// The colours of the four cells, left to right then down.
    private static let sheet0: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
    private static let sheet1: [[UInt8]] = [[0, 255, 255], [255, 0, 255], [255, 255, 255], [0, 0, 0]]

    private func png(_ colours: [[UInt8]]) throws -> Data {
        let w = Self.cellWidth * 2, h = Self.cellHeight * 2
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (i, c) in colours.enumerated() {
            context.setFillColor(red: CGFloat(c[0]) / 255, green: CGFloat(c[1]) / 255, blue: CGFloat(c[2]) / 255, alpha: 1)
            // CoreGraphics counts rows from the bottom; the sheet's from the top.
            let col = i % 2, row = i / 2
            context.fill(CGRect(x: col * Self.cellWidth, y: h - (row + 1) * Self.cellHeight,
                                width: Self.cellWidth, height: Self.cellHeight))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The middle pixel of an image, drawn into a known layout.
    private func colour(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let o = ((h / 2) * w + w / 2) * 4
        return [pixels[o], pixels[o + 1], pixels[o + 2]]
    }

    private var info: TrickplayInfo {
        TrickplayInfo(itemId: "film", width: Self.cellWidth, height: Self.cellHeight, tileWidth: 2, tileHeight: 2,
                      interval: 10_000, thumbnailCount: 6)
    }

    private func thumbnail(_ store: TrickplayStore, at seconds: Double) async throws -> CGImage? {
        for _ in 0..<50 {
            if let image = store.thumbnail(at: seconds) { return image }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func sheetsAsked() -> [String] {
        StubURLProtocol.requests.compactMap(\.url?.path).filter { $0.hasPrefix("/Videos/film/Trickplay/") }
    }

    func testAThumbnailIsItsCellCutFromItsSheet() async throws {
        StubURLProtocol.stub("/Videos/film/Trickplay/4/0.jpg", .init(headers: ["Content-Type": "image/png"], body: try png(Self.sheet0)))
        StubURLProtocol.stub("/Videos/film/Trickplay/4/1.jpg", .init(headers: ["Content-Type": "image/png"], body: try png(Self.sheet1)))
        let store = TrickplayStore()
        store.reset(info)
        XCTAssertNil(store.thumbnail(at: 25), "nothing to cut before the sheet arrives")

        // 25 s at one every 10 s is the third thumbnail: sheet 0, bottom left.
        let third = try await thumbnail(store, at: 25)
        let image = try XCTUnwrap(third, "the sheet never arrived")
        XCTAssertEqual(image.width, Self.cellWidth)
        XCTAssertEqual(image.height, Self.cellHeight)
        XCTAssertEqual(colour(image), Self.sheet0[2])
        XCTAssertEqual(colour(try XCTUnwrap(store.thumbnail(at: 12))), Self.sheet0[1], "12 s: the second, top right")

        // 45 s is the fifth: the next sheet, which was asked for ahead.
        let fifth = try await thumbnail(store, at: 45)
        XCTAssertEqual(colour(try XCTUnwrap(fifth)), Self.sheet1[0])
        // Past the last thumbnail: the last one (the sixth), not a sheet that isn't there.
        let last = try await thumbnail(store, at: 9_999)
        XCTAssertEqual(colour(try XCTUnwrap(last)), Self.sheet1[1])

        let asked = sheetsAsked()
        XCTAssertEqual(Set(asked), ["/Videos/film/Trickplay/4/0.jpg", "/Videos/film/Trickplay/4/1.jpg"])
        XCTAssertEqual(asked.count, 2, "each sheet is fetched once")
    }

    func testNoDescriptionOrNoSpacingIsNoThumbnail() {
        let store = TrickplayStore()
        XCTAssertNil(store.thumbnail(at: 10), "no trickplay for this title")
        var broken = info
        broken.interval = 0
        store.reset(broken)
        XCTAssertNil(store.thumbnail(at: 10))
        XCTAssertTrue(sheetsAsked().isEmpty, "nothing asked of the server")
    }

    func testANewTitleForgetsTheOldSheets() async throws {
        StubURLProtocol.stub("/Videos/film/Trickplay/4/0.jpg", .init(headers: ["Content-Type": "image/png"], body: try png(Self.sheet0)))
        let store = TrickplayStore()
        store.reset(info)
        let first = try await thumbnail(store, at: 0)
        XCTAssertNotNil(first)
        var other = info
        other.itemId = "other"
        store.reset(other)
        XCTAssertEqual(store.info?.itemId, "other")
        XCTAssertNil(store.thumbnail(at: 0), "the first title's sheet is not this one's")
        store.reset(nil)
        XCTAssertNil(store.info)
    }
}

@MainActor
final class PlayChannelScheduleTests: XCTestCase {
    override func setUp() async throws {
        ClientStub.install()
        try XCTSkipIf(Preferences.shared.liveTVSource == .custom, "a custom playlist answers schedules itself")
    }
    override func tearDown() async throws { ClientStub.remove() }

    private func stamp(_ minutesFromNow: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(minutesFromNow * 60))
    }

    private func programme(_ id: String, from start: Double, to end: Double) -> String {
        "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Program\",\"ChannelId\":\"ch1\",\"StartDate\":\"\(stamp(start))\",\"EndDate\":\"\(stamp(end))\"}"
    }

    func testOnNowAndWhatComesAfterInAirtimeOrder() async throws {
        // Out of order, as nothing promises they come sorted.
        let items = [
            programme("later", from: 90, to: 150),
            programme("now", from: -20, to: 30),
            programme("earlier", from: -80, to: -20),
            programme("next", from: 30, to: 90),
        ].joined(separator: ",")
        StubURLProtocol.stub("/LiveTv/Programs", json: "{\"Items\":[\(items)]}")
        var channel = BaseItem()
        channel.Id = "ch1"
        channel.type = "TvChannel"

        let schedule = ChannelSchedule()
        let loading = Task { await schedule.load(for: channel) }
        defer { loading.cancel() }
        for _ in 0..<50 where schedule.programmes.isEmpty { try await Task.sleep(for: .milliseconds(100)) }

        XCTAssertEqual(schedule.programmes.map(\.Id), ["earlier", "now", "next", "later"])
        XCTAssertEqual(schedule.now?.Id, "now")
        XCTAssertEqual(schedule.upcoming.map(\.Id), ["next", "later"])
        // Picked by its query: the host app may ask for programmes of its own.
        let queries = StubURLProtocol.requests.compactMap(\.url).filter { $0.path == "/LiveTv/Programs" }
            .map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        let query = try XCTUnwrap(queries.last { q in q.contains { $0.name == "ChannelIds" && $0.value == "ch1" } },
                                  "the schedule was never asked for this channel")
        XCTAssertEqual(query.first { $0.name == "UserId" }?.value, ClientStub.userId)
        XCTAssertNotNil(query.first { $0.name == "MinEndDate" }?.value, "a window of time, not the whole guide")

        loading.cancel()
        await schedule.load(for: nil)
        XCTAssertTrue(schedule.programmes.isEmpty, "no channel, no schedule")
        XCTAssertNil(schedule.now)
    }

    func testABlankGuideHasNothingOn() async throws {
        StubURLProtocol.stub("/LiveTv/Programs", json: #"{"Items":[]}"#)
        var channel = BaseItem()
        channel.Id = "ch2"
        let schedule = ChannelSchedule()
        let loading = Task { await schedule.load(for: channel) }
        defer { loading.cancel() }
        for _ in 0..<30 where !StubURLProtocol.requests.contains(where: { $0.url?.path == "/LiveTv/Programs" }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(schedule.now)
        XCTAssertTrue(schedule.upcoming.isEmpty)
    }
}
