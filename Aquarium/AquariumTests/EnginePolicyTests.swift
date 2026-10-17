//  The engine policy, as the plan writes it down: AVPlayer by default on a
//  battery, mpv when the file or the viewer asks for something AVPlayer
//  cannot give, mpv always on Apple TV.

import XCTest
@testable import Aquarium

final class EnginePolicyTests: XCTestCase {
    private func stream(_ index: Int, _ type: String, codec: String) -> MediaStream {
        MediaStream(Index: index, type: type, Codec: codec)
    }

    private func source(video: String = "hevc", audio: String = "aac", subtitles: [String] = []) -> MediaSource {
        var streams = [stream(0, "Video", codec: video), stream(1, "Audio", codec: audio)]
        for (i, codec) in subtitles.enumerated() { streams.append(stream(2 + i, "Subtitle", codec: codec)) }
        return MediaSource(Container: "mkv", MediaStreams: streams, DefaultAudioStreamIndex: 1)
    }

    private func request(
        platform: EnginePolicy.Platform = .iPhone, mpv: Bool = true, source: MediaSource? = nil
    ) -> EnginePolicy.Request {
        EnginePolicy.Request(platform: platform, mpvAvailable: mpv, source: source)
    }

    func testAppleTVAlwaysMPV() {
        XCTAssertEqual(EnginePolicy.choose(request(platform: .appleTV)), .mpv)
    }

    func testWithoutMPVEverythingIsApple() {
        var r = request(platform: .appleTV, mpv: false, source: source(audio: "dts", subtitles: ["pgssub"]))
        r.subtitleStreamIndex = 2
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    func testPreferenceWins() {
        var r = request()
        r.preference = .mpv
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r.preference = .apple
        r.picture.brightness = 20
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    func testPlainFileIsApple() {
        XCTAssertEqual(EnginePolicy.choose(request(source: source())), .apple)
    }

    func testPictureSubtitleOnHardwareVideoIsMPV() {
        var r = request(source: source(subtitles: ["subrip", "pgssub"]))
        r.subtitleStreamIndex = 3
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r.subtitleStreamIndex = 2
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "a text subtitle AVPlayer can draw changes nothing")
    }

    func testPictureSubtitleOnSoftwareVideoStaysApple() {
        var r = request(source: source(video: "vp9", subtitles: ["pgssub"]))
        r.subtitleStreamIndex = 2
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "the server transcodes the picture anyway")
        r = request(source: source(video: "av1", subtitles: ["pgssub"]))
        r.subtitleStreamIndex = 2
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
        r.decodesAV1 = true
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
    }

    func testDTSAndTrueHDAreMPV() {
        XCTAssertEqual(EnginePolicy.choose(request(source: source(audio: "dts"))), .mpv)
        XCTAssertEqual(EnginePolicy.choose(request(source: source(audio: "truehd"))), .mpv)
        XCTAssertEqual(EnginePolicy.choose(request(source: source(audio: "eac3"))), .apple)
    }

    func testChosenAudioTrackIsTheOneJudged() {
        var streams = source().streams
        streams.append(stream(5, "Audio", codec: "dts"))
        let s = MediaSource(Container: "mkv", MediaStreams: streams, DefaultAudioStreamIndex: 1)
        var r = request(source: s)
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "the default track is AAC")
        r.audioStreamIndex = 5
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
    }

    func testPictureControlsNeedMPV() {
        var r = request(source: source())
        r.picture.saturation = -10
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r = request(source: source())
        r.framing = .zoom(1.3)
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r.framing = .fill
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "fill is AVPlayer's video gravity")
    }

    func testAudioDelayOnHLSNeedsMPV() {
        var r = request(source: source())
        r.audioDelay = 0.1
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "a file composes on AVPlayer")
        r.isHLS = true
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
    }

    func testDownloadsInContainersAVFoundationWontOpen() {
        var r = request()
        r.isDownload = true
        r.fileContainer = "mkv"
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r.fileContainer = "mp4"
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    func testLiveIsApple() {
        var r = request(source: nil)
        r.isLive = true
        r.isHLS = true
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    func testExternalFileByItsExtension() {
        var r = request(source: nil)
        r.isExternalFile = true
        r.isLive = true
        r.fileContainer = EnginePolicy.fileContainer(of: URL(string: "https://example.net/film.MKV")!)
        XCTAssertEqual(EnginePolicy.choose(r), .mpv, "nothing remuxes a bare address")
        r.fileContainer = EnginePolicy.fileContainer(of: URL(string: "https://example.net/film.mp4")!)
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
        r.fileContainer = EnginePolicy.fileContainer(of: URL(string: "https://example.net/live/stream.m3u8?x=1")!)
        r.isHLS = true
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "a playlist channel is AVPlayer's")
        XCTAssertNil(EnginePolicy.fileContainer(of: URL(string: "https://example.net/stream")!))
    }

    func testPictureInPictureAirPlayAndSharePlayNeedApple() {
        var r = request(source: source(audio: "dts", subtitles: ["pgssub"]))
        r.subtitleStreamIndex = 2
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r.requiresApple = true
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "the hand-over case")
        r.preference = .mpv
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "even over the setting: nothing else can do it")
        r.platform = .appleTV
        XCTAssertEqual(EnginePolicy.choose(r), .mpv, "the Apple TV has no AVPlayer engine to hand to")
    }

    func testMacIsAppleByDefaultToo() {
        XCTAssertEqual(EnginePolicy.choose(request(platform: .mac, source: source())), .apple)
        XCTAssertEqual(EnginePolicy.choose(request(platform: .mac, source: source(audio: "truehd"))), .mpv)
    }

    // MARK: The render profile

    private func profile(
        _ platform: EnginePolicy.Platform, saver: EnginePolicy.BatterySaver = .automatic,
        onBattery: Bool = false, lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal
    ) -> PowerProfile {
        EnginePolicy.powerProfile(platform: platform, saver: saver, onBattery: onBattery, lowPower: lowPower, thermal: thermal)
    }

    func testHandheldsDrawCheaplyByDefault() {
        XCTAssertEqual(profile(.iPhone), .battery)
        XCTAssertEqual(profile(.iPad), .battery)
        XCTAssertEqual(profile(.appleTV), .quality)
    }

    func testMacFollowsItsPowerSource() {
        XCTAssertEqual(profile(.mac), .quality)
        XCTAssertEqual(profile(.mac, onBattery: true), .battery)
        XCTAssertEqual(profile(.mac, lowPower: true), .battery)
    }

    func testBatterySaverSettingWins() {
        XCTAssertEqual(profile(.iPhone, saver: .never), .quality)
        XCTAssertEqual(profile(.mac, saver: .always), .battery)
        XCTAssertEqual(profile(.appleTV, saver: .always), .battery)
    }

    func testThermalPressureWinsOverEverything() {
        XCTAssertEqual(profile(.appleTV, saver: .never, thermal: .serious), .battery)
        XCTAssertEqual(profile(.mac, saver: .never, thermal: .critical), .battery)
        XCTAssertEqual(profile(.mac, saver: .never, thermal: .fair), .quality, "a warning is adaptive quality's, not the renderer's")
    }
}
