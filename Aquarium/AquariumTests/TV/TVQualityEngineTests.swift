//  Auto quality and the engine, as the Apple TV build decides them: Auto as
//  this box's own choice (never synced; a box set up before Auto keeps its
//  rung), always mpv, and the mpv device profile the server is asked with.

#if os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class TVQualityEngineTests: TVUnitTestCase {
    private var prefs: Preferences { Preferences.shared }
    private var saved: (adaptive: Bool, bitrate: Int?, engine: EnginePolicy.Preference, power: Bool, speed: Bool)!

    override func setUp() async throws {
        saved = (prefs.adaptiveQuality, prefs.defaultBitrate, prefs.playbackEngine, prefs.powerAwareQuality, prefs.speedCheck)
    }

    override func tearDown() async throws {
        prefs.adaptiveQuality = saved.adaptive
        prefs.defaultBitrate = saved.bitrate
        prefs.playbackEngine = saved.engine
        prefs.powerAwareQuality = saved.power
        prefs.speedCheck = saved.speed
    }

    // MARK: Auto quality on the TV

    func testAutoSteersTheTVsStreamsWhenItIsTheTVsChoice() {
        prefs.adaptiveQuality = true
        XCTAssertTrue(PlayerModel.shared.adaptsQuality)
        XCTAssertEqual(PlayerModel.shared.qualitySelection, .auto)
        prefs.adaptiveQuality = false
        XCTAssertFalse(PlayerModel.shared.adaptsQuality, "a kept rung is never stepped")
    }

    func testAutoIsThisDevicesAndNeverSynced_regression5095d5e() {
        // Regression (commit 5095d5e): the synced Auto switch let the
        // iPhone's Auto step the TV's streams down. It no longer travels.
        XCTAssertFalse(CloudSync.syncedKeys.contains("adaptive"))
        XCTAssertFalse(CloudSync.syncedKeys.contains("default_bitrate"))
        prefs.adaptiveQuality = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: "adaptive") as? Bool, false, "kept on this device")
    }

    func testOpeningQualityIsOriginalUnderAutoAndTheRungOtherwise() {
        prefs.adaptiveQuality = true
        prefs.defaultBitrate = 10_000_000
        XCTAssertNil(prefs.openingBitrate, "Auto opens at the best there is and steps from there")
        prefs.adaptiveQuality = false
        XCTAssertEqual(prefs.openingBitrate, 10_000_000)
        prefs.defaultBitrate = nil
        XCTAssertNil(prefs.openingBitrate, "Direct Play")
    }

    func testTheQualityIsThisDevicesNotSynced() {
        // An Apple TV on Ethernet and a phone on cellular want different
        // answers: `default_bitrate` is a plain local default.
        prefs.defaultBitrate = 16_000_000
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "default_bitrate"), 16_000_000)
        prefs.defaultBitrate = nil
        XCTAssertNil(UserDefaults.standard.object(forKey: "default_bitrate"))
    }

    func testTheSpeedCheckIsAlwaysOnUnderAutoWithNoRowForIt() async {
        prefs.speedCheck = false
        XCTAssertTrue(PlayerModel.shared.checksSpeed, "the TV has no switch: Auto always checks")
        // A kept rung is never timed.
        prefs.adaptiveQuality = false
        var item = BaseItem()
        item.Id = "x"
        item.type = "Movie"
        let opening = await PlayerModel.shared.speedCheckedOpening(for: item, options: StreamOptions(), meta: StartMeta())
        XCTAssertNil(opening, "nothing timed: a kept rung opens where it was set")
    }

    func testChoosingInThePlayerIsKeptAndDecidesWhoSteers() async {
        prefs.adaptiveQuality = false
        prefs.defaultBitrate = 5_000_000
        await PlayerModel.shared.chooseQuality(.auto)
        XCTAssertNil(prefs.defaultBitrate)
        XCTAssertTrue(prefs.adaptiveQuality)
        XCTAssertTrue(PlayerModel.shared.adaptsQuality)
        await PlayerModel.shared.chooseQuality(.stream(2_500_000))
        XCTAssertEqual(prefs.defaultBitrate, 2_500_000)
        XCTAssertFalse(prefs.adaptiveQuality)
        XCTAssertFalse(PlayerModel.shared.adaptsQuality)
    }

    func testTheSettingsRowIsAutoOrTheKeptRung() {
        let row = SettingsView.qualityBinding
        row.wrappedValue = .stream(5_000_000)
        XCTAssertFalse(prefs.adaptiveQuality)
        XCTAssertEqual(prefs.defaultBitrate, 5_000_000)
        XCTAssertEqual(row.wrappedValue, .stream(5_000_000))
        row.wrappedValue = .stream(nil)
        XCTAssertFalse(prefs.adaptiveQuality, "Original is a kept rung, not Auto")
        XCTAssertEqual(row.wrappedValue, .stream(nil))
        row.wrappedValue = .auto
        XCTAssertTrue(prefs.adaptiveQuality)
        XCTAssertNil(prefs.defaultBitrate)
        XCTAssertEqual(row.wrappedValue, .auto)
    }

    // MARK: Auto on a box that had none

    private func scratchDefaults() -> UserDefaults {
        let name = "tv-auto-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testANewAppleTVStartsOnAuto() {
        let d = scratchDefaults()
        Preferences.settleTVAuto(in: d, signedIn: false)
        XCTAssertEqual(d.object(forKey: "adaptive") as? Bool, true)
    }

    func testAnAppleTVAlreadySetUpKeepsItsRung() {
        // Signed in, on Direct Play (no saved rung): stays there.
        let direct = scratchDefaults()
        direct.set(true, forKey: "adaptive")  // the old default, or a phone's
        Preferences.settleTVAuto(in: direct, signedIn: true)
        XCTAssertEqual(direct.object(forKey: "adaptive") as? Bool, false)
        // A saved rung, even signed out.
        let rung = scratchDefaults()
        rung.set(5_000_000, forKey: "default_bitrate")
        Preferences.settleTVAuto(in: rung, signedIn: false)
        XCTAssertEqual(rung.object(forKey: "adaptive") as? Bool, false)
        XCTAssertEqual(rung.integer(forKey: "default_bitrate"), 5_000_000)
    }

    func testTheChoiceIsSettledOnceAndAutoPickedLaterSticks() {
        let d = scratchDefaults()
        Preferences.settleTVAuto(in: d, signedIn: true)
        d.set(true, forKey: "adaptive")  // Auto chosen in Settings afterwards
        Preferences.settleTVAuto(in: d, signedIn: true)
        XCTAssertEqual(d.object(forKey: "adaptive") as? Bool, true, "the next launch undid the choice")
    }

    func testTheTVIsNeverOnABattery() {
        XCTAssertFalse(PowerSource.onBattery)
    }

    // MARK: The engine

    func testThisBuildIsTheAppleTVAndHasMPV() {
        XCTAssertEqual(EnginePolicy.Platform.current, .appleTV)
        XCTAssertTrue(PlayerModel.mpvAvailable, "the TV plays everything through libmpv")
        XCTAssertEqual(PlaybackEngineKind.platformDefault, .mpv)
        XCTAssertEqual(PlaybackEngineKind.mpv.title, "mpv")
    }

    func testEverythingIsMPVWhateverIsAsked() {
        var source = MediaSource(Container: "mp4", MediaStreams: [
            MediaStream(Index: 0, type: "Video", Codec: "h264"), MediaStream(Index: 1, type: "Audio", Codec: "aac"),
        ])
        source.DefaultAudioStreamIndex = 1
        for preference in EnginePolicy.Preference.allCases {
            for requiresApple in [false, true] {
                for live in [false, true] {
                    var r = EnginePolicy.Request(platform: .appleTV, mpvAvailable: true)
                    r.preference = preference
                    r.requiresApple = requiresApple
                    r.isLive = live
                    r.isHLS = live
                    r.source = source
                    XCTAssertEqual(EnginePolicy.choose(r), .mpv, "\(preference) apple=\(requiresApple) live=\(live)")
                }
            }
        }
    }

    func testTheModelChoosesMPVForAFilmEvenWithTheAppleSetting() {
        prefs.playbackEngine = .apple
        var item = BaseItem()
        item.Id = "film"
        item.type = "Movie"
        item.MediaSources = [MediaSource(Container: "mp4", MediaStreams: [MediaStream(Index: 0, type: "Video", Codec: "h264")])]
        XCTAssertEqual(PlayerModel.shared.chooseEngine(for: item, options: StreamOptions()), .mpv)
        XCTAssertEqual(PlayerModel.shared.chooseEngine(forExternal: URL(string: "http://example.invalid/live.m3u8")!), .mpv)
    }

    func testFullQualityRenderingOnMains() {
        XCTAssertEqual(EnginePolicy.powerProfile(platform: .appleTV, saver: .automatic, onBattery: false, lowPower: false,
                                                 thermal: .nominal), .quality)
        XCTAssertEqual(EnginePolicy.powerProfile(platform: .appleTV, saver: .automatic, onBattery: false, lowPower: false,
                                                 thermal: .serious), .battery, "heat still wins")
        XCTAssertEqual(PlayerModel.shared.mpvTuning, .plugged, "the large read-ahead, as on a Mac")
    }

    // MARK: The profile the server is asked with

    private func json(_ profile: DeviceProfile) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    }

    func testMPVProfileAsksForTheFileUntouched() throws {
        let p = try json(DeviceProfile.buildMPV(forceTranscode: false, maxBitrate: nil, stereoOnly: false))
        let direct = p["DirectPlayProfiles"] as? [[String: Any]] ?? []
        let video = try XCTUnwrap(direct.first { $0["Type"] as? String == "Video" })
        let containers = Set((video["Container"] as? String ?? "").split(separator: ",").map(String.init))
        XCTAssertTrue(containers.isSuperset(of: ["mkv", "mp4", "ts", "mov", "webm", "avi"]))
        XCTAssertNil(video["VideoCodec"], "every codec: mpv decodes what VideoToolbox won't")
        XCTAssertNil(video["AudioCodec"], "DTS and TrueHD too")
        XCTAssertEqual((p["CodecProfiles"] as? [Any])?.count, 0, "no size conditions without a chosen quality")
        let subs = p["SubtitleProfiles"] as? [[String: String]] ?? []
        for format in ["pgssub", "dvdsub", "dvbsub", "ass", "srt"] {
            XCTAssertTrue(subs.contains { $0["Format"] == format && $0["Method"] == "Embed" }, "\(format) drawn by mpv from the file")
        }
        XCTAssertFalse(subs.contains { $0["Method"] == "Encode" }, "never burnt in")
        XCTAssertEqual(p["MaxStreamingBitrate"] as? Int, 200_000_000)
    }

    func testMPVProfileForAChosenRungCapsSizeAndBits() throws {
        let p = try json(DeviceProfile.buildMPV(forceTranscode: true, maxBitrate: 5_000_000, stereoOnly: false))
        XCTAssertEqual((p["DirectPlayProfiles"] as? [Any])?.count, 0, "a forced transcode offers nothing to direct play")
        XCTAssertEqual(p["MaxStreamingBitrate"] as? Int, 5_000_000)
        let codecs = p["CodecProfiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(codecs.compactMap { $0["Codec"] as? String }), ["h264", "hevc"])
        let conditions = codecs.first?["Conditions"] as? [[String: Any]] ?? []
        XCTAssertTrue(conditions.contains { $0["Property"] as? String == "Width" && $0["Value"] as? String == "1280" })
        XCTAssertTrue(conditions.contains { $0["Property"] as? String == "Height" && $0["Value"] as? String == "720" })
    }

    func testMPVProfileKeepsSurroundUnlessStereoIsAsked() throws {
        let surround = try json(DeviceProfile.buildMPV(forceTranscode: false, maxBitrate: nil, stereoOnly: false))
        let stereo = try json(DeviceProfile.buildMPV(forceTranscode: false, maxBitrate: nil, stereoOnly: true))
        func hls(_ p: [String: Any]) -> [[String: Any]] {
            (p["TranscodingProfiles"] as? [[String: Any]] ?? []).filter { $0["Type"] as? String == "Video" }
        }
        XCTAssertTrue(hls(surround).allSatisfy { $0["MaxAudioChannels"] as? String == "8" }, "7.1 E-AC-3 passes out over HDMI")
        XCTAssertTrue(hls(surround).contains { ($0["AudioCodec"] as? String ?? "").contains("eac3") })
        XCTAssertTrue(hls(stereo).allSatisfy { $0["MaxAudioChannels"] as? String == "2" && $0["AudioCodec"] as? String == "aac" })
        XCTAssertTrue(hls(surround).allSatisfy { $0["BreakOnNonKeyFrames"] as? Bool == false },
                      "mpv stays black after a seek into a mid-GOP segment")
        XCTAssertTrue(hls(surround).allSatisfy { $0["Protocol"] as? String == "hls" })
    }
}
#endif
