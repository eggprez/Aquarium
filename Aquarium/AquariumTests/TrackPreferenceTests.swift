//  Which tracks to ask the server for, from the file's own list.

import XCTest
@testable import Aquarium

final class TrackPreferenceTests: XCTestCase {
    private func stream(_ index: Int, _ type: String, lang: String?, forced: Bool = false, isDefault: Bool = false) -> MediaStream {
        MediaStream(Index: index, type: type, Language: lang, IsDefault: isDefault, IsForced: forced)
    }

    /// English default audio, Japanese audio, English and Japanese subtitles
    /// plus an English forced track.
    private var film: MediaSource {
        MediaSource(
            MediaStreams: [
                stream(0, "Video", lang: nil),
                stream(1, "Audio", lang: "eng", isDefault: true),
                stream(2, "Audio", lang: "jpn"),
                stream(3, "Subtitle", lang: "eng"),
                stream(4, "Subtitle", lang: "eng", forced: true),
                stream(5, "Subtitle", lang: "jpn"),
            ],
            DefaultAudioStreamIndex: 1
        )
    }

    private func choose(saved: Preferences.TrackChoice? = nil, audio: String = "", sub: String = "", forcedOnly: Bool = false)
        -> (audio: Int?, subtitle: Int?) {
        TrackPreference.preferredStreams(
            in: film, saved: saved,
            settings: .init(audioLanguage: audio, subtitleLanguage: sub, forcedSubtitlesOnly: forcedOnly))
    }

    func testNothingSetLeavesEverythingToTheServer() {
        let c = choose()
        XCTAssertNil(c.audio)
        XCTAssertNil(c.subtitle)
    }

    func testDefaultAudioIsLeftUnnamed() {
        XCTAssertNil(choose(audio: "en").audio, "the server sends it anyway; naming it could cost the direct play")
    }

    func testAudioLanguageFromSettings() {
        XCTAssertEqual(choose(audio: "jpn").audio, 2)
    }

    func testSavedChoiceBeatsSettings() {
        let c = choose(saved: .init(audio: "jpn", sub: "jpn"), audio: "en", sub: "en")
        XCTAssertEqual(c.audio, 2)
        XCTAssertEqual(c.subtitle, 5)
    }

    func testSubtitleOffIsSaidOutLoud() {
        XCTAssertEqual(choose(sub: "off").subtitle, -1)
        XCTAssertEqual(choose(saved: .init(audio: nil, sub: "off")).subtitle, -1)
    }

    func testForcedOnlyPicksTheForcedTrackOfTheSound() {
        XCTAssertEqual(choose(sub: TrackPreference.forcedOnly).subtitle, 4, "English sound, English forced track")
    }

    func testForcedOnlyWithNoForcedTrackForTheSoundIsNone() {
        // Japanese sound: the forced track is English, which is no help.
        XCTAssertEqual(choose(audio: "jpn", sub: TrackPreference.forcedOnly).subtitle, -1)
    }

    func testForcedOnlyTakesAForcedTrackWithNoLanguage() {
        let source = MediaSource(
            MediaStreams: [
                stream(1, "Audio", lang: "eng", isDefault: true),
                stream(2, "Subtitle", lang: "eng"),
                stream(3, "Subtitle", lang: nil, forced: true),
            ],
            DefaultAudioStreamIndex: 1
        )
        let c = TrackPreference.preferredStreams(
            in: source, saved: nil, settings: .init(subtitleLanguage: TrackPreference.forcedOnly))
        XCTAssertEqual(c.subtitle, 3)
    }

    func testPlainSubtitlePreferredOverForced() {
        XCTAssertEqual(choose(sub: "en").subtitle, 3)
    }

    func testForcedOnlyWhenAudioAlreadyMatches() {
        XCTAssertEqual(choose(audio: "en", sub: "en", forcedOnly: true).subtitle, 4)
        XCTAssertEqual(choose(audio: "jpn", sub: "en", forcedOnly: true).subtitle, 4, "the sound is in the preferred language, so only the signs")
        XCTAssertEqual(choose(audio: "fra", sub: "en", forcedOnly: true).subtitle, 3, "a language the file lacks: the sound isn't understood, so the full track")
    }

    func testSavedLanguageTheFileLacksFallsThroughToSettings() {
        XCTAssertEqual(choose(saved: .init(audio: "fra", sub: "fra"), audio: "jpn", sub: "jpn").subtitle, 5)
    }

    func testDefaultSubtitleInsideAnMP4IsLeftUnnamed() {
        var s = film
        s.MediaStreams?[3].Codec = "mov_text"
        s.DefaultSubtitleStreamIndex = 3
        let c = TrackPreference.preferredStreams(in: s, saved: nil, settings: .init(subtitleLanguage: "en"))
        XCTAssertNil(c.subtitle, "AVPlayer reads it from the file; naming it would cost the direct play")
    }

    func testDefaultSRTIsStillNamed() {
        var s = film
        s.MediaStreams?[3].Codec = "subrip"
        s.DefaultSubtitleStreamIndex = 3
        let c = TrackPreference.preferredStreams(in: s, saved: nil, settings: .init(subtitleLanguage: "en"))
        XCTAssertEqual(c.subtitle, 3, "unasked, the server never puts it in the stream")
    }

    func testForcedOnlyNamesAForcedDefault() {
        var s = film
        s.MediaStreams?[4].Codec = "subrip"
        s.DefaultSubtitleStreamIndex = 4
        let c = TrackPreference.preferredStreams(
            in: s, saved: nil, settings: .init(subtitleLanguage: TrackPreference.forcedOnly))
        XCTAssertEqual(c.subtitle, 4)
    }
}
