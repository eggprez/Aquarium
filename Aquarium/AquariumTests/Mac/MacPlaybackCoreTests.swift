//  Shared Core / Player logic as it behaves on a Mac: the engine policy with
//  the QA fixtures' files, mpv's TLS settings, the direct-play profile, the
//  download folders, and the preferences test mode keeps apart.

#if os(macOS)
import XCTest
@testable import Aquarium

@MainActor
final class MacPlaybackCoreTests: MacUnitTestCase {
    // MARK: Engine policy on the Mac

    private func stream(_ index: Int, _ type: String, _ codec: String, forced: Bool = false) -> MediaStream {
        var s = MediaStream(Index: index, type: type, Codec: codec)
        s.IsForced = forced
        return s
    }

    private func mac(_ source: MediaSource? = nil, preference: EnginePolicy.Preference = .automatic) -> EnginePolicy.Request {
        var r = EnginePolicy.Request(platform: .mac, mpvAvailable: PlayerModel.mpvAvailable, source: source)
        r.preference = preference
        return r
    }

    func testThisBuildIsAMacWithMPV() {
        XCTAssertEqual(EnginePolicy.Platform.current, .mac)
        XCTAssertTrue(PlayerModel.mpvAvailable, "libmpv is compiled into the Mac build")
        XCTAssertEqual(PlaybackEngineKind.platformDefault, .apple)
    }

    /// F:film.long_direct — H.264/AAC MP4 with mov_text: AVPlayer.
    func testLongDirectPlayIsApple() {
        let s = MediaSource(Container: "mp4", MediaStreams: [stream(0, "Video", "h264"), stream(1, "Audio", "aac"),
                                                             stream(2, "Subtitle", "mov_text")], DefaultAudioStreamIndex: 1)
        var r = mac(s)
        r.subtitleStreamIndex = 2
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    /// F:film.dts_mkv and F:film.truehd_mkv — audio AVFoundation can't decode: mpv.
    func testDTSAndTrueHDGoToMPV() {
        for codec in ["dts", "truehd"] {
            let s = MediaSource(Container: "mkv", MediaStreams: [stream(0, "Video", "h264"), stream(1, "Audio", codec)],
                                DefaultAudioStreamIndex: 1)
            XCTAssertEqual(EnginePolicy.choose(mac(s)), .mpv, codec)
        }
    }

    /// F:film.image_subs — PGS chosen on hardware video: mpv draws it rather
    /// than the server burning it in.
    func testPictureSubtitlesGoToMPV() {
        let s = MediaSource(Container: "mkv", MediaStreams: [stream(0, "Video", "h264"), stream(1, "Audio", "aac"),
                                                             stream(2, "Subtitle", "PGSSUB")], DefaultAudioStreamIndex: 1)
        var r = mac(s)
        r.subtitleStreamIndex = 2
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r.subtitleStreamIndex = -1
        XCTAssertEqual(EnginePolicy.choose(r), .apple, "subtitles off: nothing to draw")
    }

    func testPictureInPictureForcesAppleEvenWithMPVChosen() {
        var r = mac(nil, preference: .mpv)
        r.requiresApple = true
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    func testMacSettingIsHonoured() {
        XCTAssertEqual(EnginePolicy.choose(mac(nil, preference: .mpv)), .mpv, "unlike the iPad, a Mac can be told mpv")
        XCTAssertEqual(EnginePolicy.choose(mac(nil, preference: .apple)), .apple)
    }

    /// A stream download (an AVFoundation package) is AVPlayer's whatever the setting.
    func testStreamDownloadIsAppleOnTheMac() {
        var r = mac(nil, preference: .mpv)
        r.isDownload = true
        r.isHLS = true
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    func testWholeFileMKVDownloadIsMPV() {
        var r = mac()
        r.isDownload = true
        r.fileContainer = "mkv"
        XCTAssertEqual(EnginePolicy.choose(r), .mpv)
        r.fileContainer = "mp4"
        XCTAssertEqual(EnginePolicy.choose(r), .apple)
    }

    func testEngineDescriptionFollowsTheSetting() {
        guard !PlayerModel.shared.isActive else { return }
        let saved = Preferences.shared.playbackEngine
        defer { Preferences.shared.playbackEngine = saved }
        Preferences.shared.playbackEngine = .mpv
        XCTAssertEqual(PlayerModel.shared.engineDescription, "mpv")
        Preferences.shared.playbackEngine = .apple
        XCTAssertEqual(PlayerModel.shared.engineDescription, "AVFoundation")
        Preferences.shared.playbackEngine = .automatic
        XCTAssertTrue(PlayerModel.shared.engineDescription.hasPrefix("Automatic"))
    }

    // MARK: mpv TLS

    func testTLSRootsShipInTheMacApp() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "tls-roots", ofType: "pem"),
                                 "tls-roots.pem must be in the app, or mpv has no roots to verify against")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertGreaterThan(text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1, 50)
    }

    /// Regression: MpvAcceptsAnyCertificate. mpv 0.41 defaults to
    /// `tls-verify=no` and sent the Authorization header to any certificate.
    /// Source: commit f1e01de; memory note mpv-tls-verification.md;
    /// Aquarium/Player/Engine/MPVEngine.swift:371-381.
    func testBugMpvAcceptsAnyCertificate() throws {
        #if canImport(Libmpv)
        let engine = try XCTUnwrap(MPVEngine(layer: MPVMetalLayer()), "libmpv started")
        defer { engine.shutdown() }
        XCTAssertEqual(engine.debugValue("tls-verify"), "yes")
        let ca = try XCTUnwrap(engine.debugValue("tls-ca-file"))
        XCTAssertEqual(ca, Bundle.main.path(forResource: "tls-roots", ofType: "pem"))
        #else
        throw XCTSkip("no libmpv in this build")
        #endif
    }

    func testMPVOptionsTheMacKeepsShared() throws {
        #if canImport(Libmpv)
        let engine = try XCTUnwrap(MPVEngine(layer: MPVMetalLayer()))
        defer { engine.shutdown() }
        XCTAssertEqual(engine.debugValue("hwdec"), "videotoolbox")
        XCTAssertEqual(engine.debugValue("audio-exclusive"), "no", "on a Mac exclusive audio would hog the output device")
        XCTAssertEqual(engine.debugValue("sid"), "no", "subtitles are chosen by the player, not by the file's flags")
        engine.shutdown()
        XCTAssertNil(engine.debugValue("tls-verify"), "nothing to ask once shut down")
        #else
        throw XCTSkip("no libmpv in this build")
        #endif
    }

    // MARK: Direct play on the Mac

    func testMP4PlaysAsAFileAndMKVDoesNot() {
        let mp4 = MediaSource(Container: "mp4", MediaStreams: [stream(0, "Video", "h264"), stream(1, "Audio", "aac")], DefaultAudioStreamIndex: 1)
        let mkv = MediaSource(Container: "mkv", MediaStreams: [stream(0, "Video", "h264"), stream(1, "Audio", "aac")], DefaultAudioStreamIndex: 1)
        XCTAssertTrue(DeviceProfile.canDirectPlay(mp4))
        XCTAssertFalse(DeviceProfile.canDirectPlay(mkv), "AVFoundation can't open MKV: the server remuxes it")
    }

    /// Regression: DolbyVisionGreenPurple. Dolby Vision is claimed only where
    /// the device presents HDR; a DOVI-only picture on anything else drew
    /// green and purple. Source: commit 2c520e6; Core/DeviceProfile.swift:141-155.
    func testBugDolbyVisionGreenPurple() {
        var video = stream(0, "Video", "hevc")
        video.VideoRangeType = "DOVI"
        let dovi = MediaSource(Container: "mp4", MediaStreams: [video, stream(1, "Audio", "aac")], DefaultAudioStreamIndex: 1)
        XCTAssertEqual(DeviceProfile.canDirectPlay(dovi), DeviceProfile.playsDolbyVision,
                       "a DOVI-only file plays as a file exactly where this Mac has the Dolby path")
    }

    // MARK: HLS subtitles

    /// Regression: HLSSubtitlesTenSecondsLate. fMP4 segments with WebVTT in
    /// the manifest showed cues 10 s late on AVPlayer; H.264 streams are asked
    /// for TS. Source: commit e62f2c9; memory note hls-subtitle-timing.md;
    /// Core/JellyfinClient.swift:2220-2247.
    func testBugHLSSubtitlesTenSecondsLate() throws {
        let source = MediaSource(Container: "mkv", MediaStreams: [stream(0, "Video", "h264"), stream(1, "Audio", "aac"),
                                                                  stream(2, "Subtitle", "subrip", forced: true)],
                                 DefaultAudioStreamIndex: 1)
        let url = try XCTUnwrap(URL(string: "http://s/videos/x/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Hls&SegmentContainer=mp4&AudioStreamIndex=1"))
        let out = JellyfinClient.subtitleTimedSegments(url, source: source, audioStreamIndex: 1)
        let items = URLComponents(url: out, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "SegmentContainer" }?.value, "ts")
    }

    func testHEVCOrNoSubtitlesKeepFMP4() throws {
        let hevc = MediaSource(Container: "mkv", MediaStreams: [stream(0, "Video", "hevc"), stream(1, "Audio", "aac")], DefaultAudioStreamIndex: 1)
        let url = try XCTUnwrap(URL(string: "http://s/m.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Hls&SegmentContainer=mp4"))
        XCTAssertEqual(JellyfinClient.subtitleTimedSegments(url, source: hevc, audioStreamIndex: nil), url)
        let h264 = MediaSource(Container: "mkv", MediaStreams: [stream(0, "Video", "h264"), stream(1, "Audio", "aac")], DefaultAudioStreamIndex: 1)
        let off = try XCTUnwrap(URL(string: "http://s/m.m3u8?SubtitleStreamIndex=-1&SubtitleMethod=Hls&SegmentContainer=mp4"))
        XCTAssertEqual(JellyfinClient.subtitleTimedSegments(off, source: h264, audioStreamIndex: nil), off)
    }

    // MARK: Downloads on the Mac

    func testDownloadsLiveInTestModesOwnFolder() {
        let root = DownloadManager.rootPath.path
        XCTAssertTrue(root.contains("/Library/Application Support/AquariumUITest/"), root)
        XCTAssertTrue(root.hasSuffix("FellyJin/Downloads"), "the pre-Aquarium folder name, kept so old downloads are found")
        XCTAssertFalse(root.contains("/Containers/"), "unsandboxed in tests: never the real app's container")
    }

    func testDownloadFolderPerItemIsDirectlyUnderTheRoot() {
        XCTAssertEqual(DownloadManager.folderName(for: "b7a2ad74f87ef390949afe560dcbd376"), "b7a2ad74f87ef390949afe560dcbd376")
        let escaped = DownloadManager.folderName(for: "../../etc")
        XCTAssertFalse(escaped.contains("/"), escaped)
        XCTAssertEqual(DownloadManager.folderPath(for: "abc").deletingLastPathComponent().standardizedFileURL,
                       DownloadManager.rootPath.standardizedFileURL)
        XCTAssertEqual(DownloadManager.folderName(for: ""), "item")
    }

    func testRootIsMadeWhenAskedFor() {
        let root = DownloadManager.root
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let values = try? root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values?.isExcludedFromBackup, true, "nothing under the downloads belongs in a backup")
    }

    // MARK: Preferences in test mode

    func testTestModeIsOnAndStateIsApart() {
        XCTAssertTrue(TestRuntime.isUITest)
        XCTAssertTrue(AppDirectory.url(.applicationSupportDirectory).path.hasSuffix("AquariumUITest"))
        XCTAssertTrue(AppDirectory.url(.cachesDirectory).path.hasSuffix("AquariumUITest"))
    }

    func testFillScreenPreferenceRoundTrips() {
        let saved = Preferences.shared.fillScreen
        defer { Preferences.shared.fillScreen = saved }
        Preferences.shared.fillScreen = !saved
        XCTAssertEqual(Preferences.shared.fillScreen, !saved)
    }

    func testMacDeviceNameIsTheComputersName() {
        XCTAssertFalse(JellyfinClient.deviceName.isEmpty)
    }
}
#endif
