//  SharePlay's "start from whose progress?": what each device says of its own
//  spot (`SharedProgress`) and the rows the question offers (`ProgressChoice`).
//  Also the activity itself (what it sends, what the invitation shows), how
//  streams are matched, and what the player says when someone else acts.
//  The session itself needs FaceTime on two devices (MANUAL.md); the question
//  on screen is `PhoneSharePlayTests`.

#if !os(tvOS)
import GroupActivities
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Aquarium

final class SharePlayProgressTests: XCTestCase {
    private func report(_ name: String, _ seconds: Double, item: String = "film") -> SharedProgress {
        SharedProgress(itemId: item, name: name, seconds: seconds)
    }

    func testYouFirstThenEveryoneByNameThenTheBeginning() {
        let rows = ProgressChoice.options([report("Zoe", 2462), report("scott", 1390), report("Alex", 600)],
                                          itemId: "film", me: "Scott")
        XCTAssertEqual(rows.map(\.id), ["scott", "alex", "zoe", "beginning"])
        XCTAssertEqual(rows.map(\.title), ["scott (you) · 23:10", "Alex · 10:00", "Zoe · 41:02", "From the Beginning"])
        XCTAssertEqual(rows.map(\.seconds), [1390, 600, 2462, 0])
    }

    func testNobodyWithASpotMeansNothingToAsk() {
        XCTAssertEqual(ProgressChoice.options([report("Alex", 0), report("Scott", 12)], itemId: "film", me: "Scott"), [])
        XCTAssertEqual(ProgressChoice.options([], itemId: "film", me: "Scott"), [])
    }

    func testOnlyThisTitleAndEachPersonOnce() {
        // Two devices on one account, and a stale report for the last episode.
        let rows = ProgressChoice.options([report("Alex", 600), report("alex", 900), report("Sam", 300, item: "older")],
                                          itemId: "film", me: "Scott")
        XCTAssertEqual(rows.map(\.id), ["alex", "beginning"])
    }

    func testTheSpotSentIsTheServersAndFinishedMeansTheBeginning() {
        let halfway = SharedProgress.saved(itemId: "film", name: "Alex", positionTicks: 6_000 * 10_000_000, runTimeTicks: 12_000 * 10_000_000)
        XCTAssertEqual(halfway.seconds, 6_000)
        let finished = SharedProgress.saved(itemId: "film", name: "Alex", positionTicks: 11_500 * 10_000_000, runTimeTicks: 12_000 * 10_000_000)
        XCTAssertEqual(finished.seconds, 0, "past 90% is watched: starting again is from the top")
        let never = SharedProgress.saved(itemId: "film", name: "Alex", positionTicks: 0, runTimeTicks: nil)
        XCTAssertEqual(never.seconds, 0)
    }

    func testTheReportRoundTrips() throws {
        let sent = report("Alex", 600.5)
        let back = try JSONDecoder().decode(SharedProgress.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(back, sent)
    }

    // MARK: - The activity

    /// Two devices stream one film by two different addresses (direct play,
    /// a transcode, another base path): matched by the item id in them, read
    /// from the address alone since the coordinator may ask on any thread.
    func testStreamsAreMatchedByTheItemIdInTheAddress() {
        let id = "b7a2ad74f87ef390949afe560dcbd376"
        let direct = URL(string: "https://jf.example/Videos/\(id)/stream.mp4?Static=true&api_key=x")
        let hls = URL(string: "https://jf.example/jellyfin/videos/\(id)/master.m3u8?PlaySessionId=y")
        let dashed = URL(string: "http://10.0.0.2:8096/Videos/B7A2AD74-F87E-F390-949A-FE560DCBD376/stream.mkv")
        XCTAssertEqual(WatchTogetherActivity.itemId(in: direct), id)
        XCTAssertEqual(WatchTogetherActivity.itemId(in: hls), id)
        XCTAssertEqual(WatchTogetherActivity.itemId(in: dashed), id)
        XCTAssertNil(WatchTogetherActivity.itemId(in: URL(string: "https://jf.example/Audio/\(id)/universal")))
        XCTAssertNil(WatchTogetherActivity.itemId(in: nil))
    }

    /// The poster stays on the device that offers the title; the rest is sent.
    func testThePosterIsNotSent() throws {
        var activity = WatchTogetherActivity(itemId: "film", title: "Film", subtitle: "Show")
        activity.poster = Data([1, 2, 3])
        let back = try JSONDecoder().decode(WatchTogetherActivity.self, from: JSONEncoder().encode(activity))
        XCTAssertEqual(back.itemId, "film")
        XCTAssertEqual(back.title, "Film")
        XCTAssertEqual(back.subtitle, "Show")
        XCTAssertNil(back.poster)
    }

    /// No `aquarium://` fallback (Safari can't open it for someone without
    /// the app); the poster becomes the invitation's picture.
    func testTheInvitationHasThePosterAndNoAppOnlyLink() throws {
        var activity = WatchTogetherActivity(itemId: "film", title: "Film", subtitle: nil)
        XCTAssertNil(activity.metadata.fallbackURL)
        XCTAssertNil(activity.metadata.previewImage)
        XCTAssertEqual(activity.metadata.type, .watchTogether)
        activity.poster = try Self.onePixelPNG()
        XCTAssertNotNil(activity.metadata.previewImage)
    }

    func testWhatThePlayerSaysWhenSomeoneElseActs() {
        XCTAssertEqual(SharePlayCoordinator.notice(name: "Alex", paused: true), "Alex paused")
        XCTAssertEqual(SharePlayCoordinator.notice(name: nil, paused: false), "Someone played")
        XCTAssertEqual(SharePlayCoordinator.notice(name: "Alex", jumpedTo: 1390), "Alex jumped to 23:10")
        let gone = SharePlayCoordinator.unavailable("Firefly")
        XCTAssertTrue(gone.contains("\u{201C}Firefly\u{201D}"))
        XCTAssertTrue(gone.contains("left the session"))
    }

    private static func onePixelPNG() throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }
}
#endif
