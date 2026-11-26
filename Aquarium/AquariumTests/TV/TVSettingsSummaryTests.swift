//  The grey line beside each row of the Apple TV's first Settings page
//  (`SettingsSummary`, read by Views/TVSettingsView.swift), as the tvOS
//  build writes it: Video names the rung and never "Auto" (the TV has none,
//  5095d5e), Audio is the 60 fps delay and the downmix (the iPhone's is a
//  language), Subtitles and Live TV their choice. And the per-rate delay
//  rows' wording, which Settings → Audio reads one rate at a time.

#if os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class TVSettingsSummaryTests: TVUnitTestCase {
    private var prefs: Preferences { Preferences.shared }
    private var saved: (adaptive: Bool, bitrate: Int?, fill: Bool, delay: Double, byRate: [String: Double],
                        downmix: Bool, subs: String, forced: Bool, source: LiveTVSource)!

    override func setUp() async throws {
        saved = (prefs.adaptiveQuality, prefs.defaultBitrate, prefs.fillScreen, prefs.audioDelay, prefs.audioDelaysByRate,
                 prefs.stereoDownmix, prefs.subtitleLanguage, prefs.forcedSubtitlesOnly, prefs.liveTVSource)
        // A kept rung unless a test says Auto.
        prefs.adaptiveQuality = false
    }

    override func tearDown() async throws {
        prefs.adaptiveQuality = saved.adaptive
        prefs.defaultBitrate = saved.bitrate
        prefs.fillScreen = saved.fill
        prefs.audioDelay = saved.delay
        prefs.audioDelaysByRate = saved.byRate
        prefs.stereoDownmix = saved.downmix
        prefs.subtitleLanguage = saved.subs
        prefs.forcedSubtitlesOnly = saved.forced
        prefs.liveTVSource = saved.source
    }

    // MARK: Video

    func testVideoNamesAutoOrTheRung() {
        prefs.fillScreen = false
        prefs.adaptiveQuality = true
        prefs.defaultBitrate = nil
        XCTAssertEqual(SettingsSummary.video(prefs), "Auto")
        prefs.adaptiveQuality = false
        prefs.defaultBitrate = nil
        XCTAssertEqual(SettingsSummary.video(prefs), "Original")
        prefs.defaultBitrate = 5_000_000
        XCTAssertEqual(SettingsSummary.video(prefs), "720p")
        prefs.defaultBitrate = 36_000_000
        XCTAssertEqual(SettingsSummary.video(prefs), "4K")
        XCTAssertFalse(SettingsSummary.video(prefs).contains("Auto"), "a kept rung reads as Auto")
    }

    func testVideoAddsFillWhenTheFrameIsCropped() {
        prefs.defaultBitrate = 10_000_000
        prefs.fillScreen = true
        XCTAssertEqual(SettingsSummary.video(prefs), "1080p·10 · Fill")
        prefs.fillScreen = false
        XCTAssertEqual(SettingsSummary.video(prefs), "1080p·10")
    }

    func testABitrateOffTheLadderReadsCustom() {
        // A value synced from elsewhere that isn't one of the rungs.
        prefs.fillScreen = false
        prefs.defaultBitrate = 7_000_000
        XCTAssertEqual(SettingsSummary.video(prefs), "Custom")
    }

    // MARK: Audio

    func testAudioIsTheSixtyFrameDelayAndTheDownmix() {
        prefs.stereoDownmix = false
        prefs.audioDelay = 0
        XCTAssertEqual(SettingsSummary.audio(prefs), "In step", "the TV's audio summary is not a language")
        prefs.audioDelay = 0.05
        XCTAssertEqual(SettingsSummary.audio(prefs), "50 ms later")
        prefs.audioDelay = -0.12
        prefs.stereoDownmix = true
        XCTAssertEqual(SettingsSummary.audio(prefs), "120 ms earlier · Stereo")
    }

    func testAnotherRatesDelayIsNotTheSummarysAndHasItsOwnRow() {
        // The first page only ever shows the 60 fps one; each other rate is a
        // row on the Audio page, worded as `PlayerModel.audioDelayName`.
        prefs.audioDelay = 0
        prefs.audioDelaysByRate = [:]
        prefs.setAudioDelay(0.08, forRate: 24)
        XCTAssertEqual(SettingsSummary.audio(prefs).hasPrefix("In step"), true, SettingsSummary.audio(prefs))
        XCTAssertEqual(PlayerModel.audioDelayName(Int((prefs.audioDelay(forRate: 24) * 1000).rounded())), "Sound 80 ms later")
        XCTAssertEqual(PlayerModel.audioDelayName(Int((prefs.audioDelay(forRate: 25) * 1000).rounded())), "In step")
        prefs.setAudioDelay(0, forRate: 24)
        XCTAssertNil(prefs.audioDelaysByRate["24"], "a rate set back in step is forgotten, not kept as zero")
    }

    // MARK: Subtitles, Live TV

    func testSubtitlesSayTheChoice() {
        prefs.forcedSubtitlesOnly = false
        prefs.subtitleLanguage = ""
        XCTAssertEqual(SettingsSummary.subtitles(prefs), "File's choice")
        prefs.subtitleLanguage = "off"
        XCTAssertEqual(SettingsSummary.subtitles(prefs), "Never")
        prefs.subtitleLanguage = TrackPreference.forcedOnly
        prefs.forcedSubtitlesOnly = true
        XCTAssertEqual(SettingsSummary.subtitles(prefs), "Forced only", "forced only isn't said twice")
        prefs.subtitleLanguage = "eng"
        XCTAssertEqual(SettingsSummary.subtitles(prefs), "English · Forced only")
    }

    func testLiveTVSaysWhereTheChannelsComeFrom() {
        prefs.liveTVSource = .jellyfin
        XCTAssertEqual(SettingsSummary.liveTV(prefs), "Jellyfin")
        prefs.liveTVSource = .custom
        XCTAssertEqual(SettingsSummary.liveTV(prefs), "Custom playlist")
    }

    // MARK: The Next Up window's choices

    func testTheNextUpWindowReadsInWords() {
        XCTAssertEqual(Preferences.nextUpDayChoices, [0, 7, 14, 30, 90, 180, 365])
        XCTAssertEqual(Preferences.nextUpDayChoices.map(Preferences.nextUpDaysLabel),
                       ["Forever", "1 week", "2 weeks", "1 month", "3 months", "6 months", "1 year"])
    }
}
#endif
