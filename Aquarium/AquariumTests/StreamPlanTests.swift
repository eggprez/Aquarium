//  The stream resolver's choice between the file and a transcode, and the
//  device profile's reading of what AVFoundation can open.

import XCTest
@testable import Aquarium

final class StreamPlanTests: XCTestCase {
    private func stream(_ index: Int, _ type: String, codec: String, depth: Int? = nil, profile: String? = nil) -> MediaStream {
        MediaStream(Index: index, type: type, Codec: codec, BitDepth: depth, Profile: profile)
    }

    private func source(container: String?, video: String = "h264", audio: String = "aac",
                        directPlay: Bool = true, directStream: Bool = true, transcodingUrl: String? = "/t.m3u8") -> MediaSource {
        MediaSource(
            Container: container, TranscodingUrl: transcodingUrl,
            SupportsDirectPlay: directPlay, SupportsDirectStream: directStream,
            MediaStreams: [stream(0, "Video", codec: video), stream(1, "Audio", codec: audio)])
    }

    // MARK: The resolver's rule

    func testForcedTranscodeTakesTheServersStream() {
        XCTAssertEqual(StreamPlan.decide(source: source(container: "mp4"), forceTranscode: true, live: false, engineCanOpen: true), .transcode)
    }

    func testServerOfferingNeitherDirectRouteIsATranscode() {
        let s = source(container: "mkv", directPlay: false, directStream: false)
        XCTAssertEqual(StreamPlan.decide(source: s, forceTranscode: false, live: false, engineCanOpen: true), .transcode)
    }

    func testFileTheEngineCannotOpenIsAskedForAgain() {
        XCTAssertEqual(StreamPlan.decide(source: source(container: "mkv"), forceTranscode: false, live: false, engineCanOpen: false), .escalate)
    }

    func testLiveWithNoContainerIsAskedForAgain() {
        XCTAssertEqual(StreamPlan.decide(source: source(container: ""), forceTranscode: false, live: true, engineCanOpen: true), .escalate)
        XCTAssertEqual(StreamPlan.decide(source: source(container: ""), forceTranscode: false, live: false, engineCanOpen: true), .direct, "a library file with no container is left alone")
    }

    func testPlayableFileIsDirect() {
        XCTAssertEqual(StreamPlan.decide(source: source(container: "mp4"), forceTranscode: false, live: false, engineCanOpen: true), .direct)
    }

    // MARK: What AVFoundation opens

    func testMP4WithH264AndAACDirectPlays() {
        XCTAssertTrue(DeviceProfile.canDirectPlay(source(container: "mp4")))
    }

    func testMatroskaIsRemuxedByTheServer() {
        XCTAssertFalse(DeviceProfile.canDirectPlay(source(container: "mkv")))
        XCTAssertFalse(DeviceProfile.canDirectPlay(source(container: "matroska,webm")))
    }

    func testDTSAndVP9NeedTheServer() {
        XCTAssertFalse(DeviceProfile.canDirectPlay(source(container: "mp4", audio: "dts")))
        XCTAssertFalse(DeviceProfile.canDirectPlay(source(container: "mp4", video: "vp9")))
    }

    func testTenBitH264HasNoHardwareDecoder() {
        let s = MediaSource(Container: "mp4", MediaStreams: [
            stream(0, "Video", codec: "h264", depth: 10, profile: "High 10"), stream(1, "Audio", codec: "aac"),
        ])
        XCTAssertFalse(DeviceProfile.canDirectPlay(s))
    }

    func testUndescribedSourceIsGivenTheBenefitOfTheDoubt() {
        XCTAssertTrue(DeviceProfile.canDirectPlay(MediaSource()))
    }
}
