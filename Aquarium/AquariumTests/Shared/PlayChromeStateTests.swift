//  The video player's chrome, under the views: when the controls put
//  themselves away and what keeps them up, the run of skips a double-tap
//  counts, the cards and the panel taking turns (`PlayerChromeState`), and
//  the small values and wording the engines and the Info page share.
//
//  Nothing here opens a stream. The timed parts use a hide interval of a
//  twentieth of a second, so a test waits well under a second.

import Foundation
import XCTest
@testable import Aquarium

@MainActor
final class PlayChromeStateTests: XCTestCase {
    private func playing(hideAfter: Double = 0.05) -> PlayerChromeState.HideContext {
        PlayerChromeState.HideContext(isPaused: false, voiceOver: false, hideAfter: hideAfter, hasError: false)
    }

    private func pause(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: What may hide the controls

    func testControlsMayHideOnlyWhilePlayingWithNoErrorAndNoVoiceOver() {
        XCTAssertTrue(playing().mayHide)
        XCTAssertFalse(PlayerChromeState.HideContext(isPaused: true, voiceOver: false, hideAfter: 4, hasError: false).mayHide)
        XCTAssertFalse(PlayerChromeState.HideContext(isPaused: false, voiceOver: true, hideAfter: 4, hasError: false).mayHide)
        XCTAssertFalse(PlayerChromeState.HideContext(isPaused: false, voiceOver: false, hideAfter: 4, hasError: true).mayHide)
    }

    func testControlsStartUpAndGoAfterTheInterval() async throws {
        let chrome = PlayerChromeState(showsTotalTime: false)
        XCTAssertTrue(chrome.controlsVisible, "a player opens with its controls up")
        chrome.show(playing())
        XCTAssertTrue(chrome.controlsVisible)
        try await pause(500)
        XCTAssertFalse(chrome.controlsVisible, "nothing touched for the interval: away they go")
    }

    func testPausedLoadingOrNeverKeepThemUp() async throws {
        let paused = PlayerChromeState(showsTotalTime: false)
        paused.show(PlayerChromeState.HideContext(isPaused: true, voiceOver: false, hideAfter: 0.05, hasError: false))
        var loadingContext = playing()
        loadingContext.isLoading = true
        let loading = PlayerChromeState(showsTotalTime: false)
        loading.show(loadingContext)
        let never = PlayerChromeState(showsTotalTime: false)
        never.show(playing(hideAfter: 0))
        try await pause(400)
        XCTAssertTrue(paused.controlsVisible, "a paused picture keeps its controls")
        XCTAssertTrue(loading.controlsVisible, "the clock starts once there is a picture moving")
        XCTAssertTrue(never.controlsVisible, "an interval of nothing is never")
    }

    func testAnOpenCardPanelOrScrubHoldsThemUp() async throws {
        let card = PlayerChromeState(showsTotalTime: false)
        card.menu = .audio
        card.show(playing())
        let panel = PlayerChromeState(showsTotalTime: false)
        panel.panel = .info
        panel.show(playing())
        let scrub = PlayerChromeState(showsTotalTime: false)
        scrub.scrub = 42
        scrub.show(playing())
        // Opened after the clock started: the clock must not put them away.
        let late = PlayerChromeState(showsTotalTime: false)
        late.show(playing())
        late.menu = .more
        try await pause(400)
        XCTAssertTrue(card.controlsVisible)
        XCTAssertTrue(panel.controlsVisible)
        XCTAssertTrue(scrub.controlsVisible)
        XCTAssertTrue(late.controlsVisible, "a card opened while the clock ran still holds the controls")
    }

    func testHoldStopsTheClockAndHidePutsThemAwayAtOnce() async throws {
        let chrome = PlayerChromeState(showsTotalTime: false)
        chrome.show(playing())
        chrome.holdControls()
        try await pause(400)
        XCTAssertTrue(chrome.controlsVisible, "held: no clock on them")
        chrome.hide()
        XCTAssertFalse(chrome.controlsVisible)
    }

    func testATapTogglesWhilePlayingAndOnlyShowsWhilePaused() {
        let chrome = PlayerChromeState(showsTotalTime: false)
        let context = playing(hideAfter: 60)
        chrome.toggle(context)
        XCTAssertFalse(chrome.controlsVisible, "up and free to hide: a tap puts them away")
        chrome.toggle(context)
        XCTAssertTrue(chrome.controlsVisible)
        let paused = PlayerChromeState.HideContext(isPaused: true, voiceOver: false, hideAfter: 60, hasError: false)
        chrome.toggle(paused)
        XCTAssertTrue(chrome.controlsVisible, "paused, a tap never hides them")
        chrome.hide()
    }

    // MARK: Cards and the panel

    func testOpeningThePanelClosesTheCard() {
        let chrome = PlayerChromeState(showsTotalTime: false)
        XCTAssertFalse(chrome.menuOpen)
        XCTAssertFalse(chrome.panelOpen)
        chrome.menu = .quality
        XCTAssertTrue(chrome.menuOpen)
        chrome.panel = .info
        XCTAssertTrue(chrome.panelOpen)
        XCTAssertNil(chrome.menu, "one thing over the picture at a time")
        chrome.menu = .upNext
        chrome.panel = nil
        XCTAssertEqual(chrome.menu, .upNext, "closing the panel leaves a card alone")
    }

    func testANewStreamStartsClean() {
        let chrome = PlayerChromeState(showsTotalTime: true)
        chrome.scrub = 10
        chrome.returnPoint = 5
        chrome.skipTotal = 30
        chrome.holdingDoubleSpeed = true
        chrome.edgeLevel = PlayerChromeState.EdgeLevel(kind: .volume, level: 0.4)
        chrome.panel = .info
        chrome.menu = .audio
        chrome.rippleOnce(forward: true)
        chrome.resetForNewStream()
        XCTAssertNil(chrome.scrub)
        XCTAssertNil(chrome.returnPoint)
        XCTAssertEqual(chrome.skipTotal, 0)
        XCTAssertNil(chrome.ripple)
        XCTAssertFalse(chrome.holdingDoubleSpeed)
        XCTAssertNil(chrome.edgeLevel)
        XCTAssertNil(chrome.panel)
        XCTAssertNil(chrome.menu)
        XCTAssertTrue(chrome.showsTotalTime, "which time the label shows is the viewer's choice, not the stream's")
    }

    // MARK: Skips, ripples and edge drags

    func testSkipsTheSameWayAddUpAndTheOtherWayStartsAgain() async throws {
        let chrome = PlayerChromeState(showsTotalTime: false)
        chrome.countSkip(10)
        chrome.countSkip(10)
        XCTAssertEqual(chrome.skipTotal, 20)
        chrome.countSkip(-10)
        XCTAssertEqual(chrome.skipTotal, -10, "back after forward is a new run")
        chrome.countSkip(-10)
        XCTAssertEqual(chrome.skipTotal, -20)
        try await pause(1000)
        XCTAssertEqual(chrome.skipTotal, 0, "the count goes a moment after the last skip")
    }

    func testTheDoubleTapRippleFades() async throws {
        let chrome = PlayerChromeState(showsTotalTime: false)
        chrome.rippleOnce(forward: false)
        XCTAssertEqual(chrome.ripple?.forward, false)
        try await pause(700)
        XCTAssertNil(chrome.ripple)
    }

    func testAnEdgeLevelStaysWhileDraggedAndFadesOnceLetGo() async throws {
        let chrome = PlayerChromeState(showsTotalTime: false)
        chrome.showEdgeLevel(PlayerChromeState.EdgeLevel(kind: .brightness, level: 0.25))
        try await pause(300)
        XCTAssertEqual(chrome.edgeLevel, PlayerChromeState.EdgeLevel(kind: .brightness, level: 0.25))
        chrome.fadeEdgeLevel()
        // Dragged again before the fade is due: the level stays.
        chrome.showEdgeLevel(PlayerChromeState.EdgeLevel(kind: .brightness, level: 0.5))
        try await pause(1000)
        XCTAssertEqual(chrome.edgeLevel?.level, 0.5)
        chrome.fadeEdgeLevel()
        try await pause(1100)
        XCTAssertNil(chrome.edgeLevel)
    }

    // MARK: The panel's pages

    func testEveryPanelPageHasAName() {
        XCTAssertEqual(PlayerTab.allCases.count, 8)
        XCTAssertEqual(PlayerTab.allCases.map(\.title),
                       ["Info", "Channels", "Audio", "Subtitles", "Quality", "Speed", "Sync", "Watch Together"])
        for tab in PlayerTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
            XCTAssertFalse(tab.symbol.isEmpty, "\(tab) has a symbol")
        }
        XCTAssertEqual(Set(PlayerTab.allCases.map(\.symbol)).count, 8, "no two pages share a symbol")
    }
}

// MARK: - Values and wording

@MainActor
final class PlayEngineValuesTests: XCTestCase {
    private func stream(_ json: String) throws -> MediaStream {
        try JSONDecoder().decode(MediaStream.self, from: Data(json.utf8))
    }

    func testATrackIsCalledByItsTitleLanguageAndCodec() {
        XCTAssertEqual(EngineTrack(id: 3, kind: .audio).label, "Track 3", "nothing known: its number")
        let full = EngineTrack(id: 1, kind: .audio, title: "Commentary", language: "eng", codec: "ac3")
        XCTAssertEqual(full.label, "Commentary · English · AC3")
        let bare = EngineTrack(id: 2, kind: .subtitle, title: "", language: "fra")
        XCTAssertEqual(bare.label, "French", "an empty title is left out")
    }

    func testResolutionNeedsBothSides() {
        XCTAssertEqual(EngineStreamFacts(width: 1920, height: 1080).resolution, "1920×1080")
        XCTAssertNil(EngineStreamFacts(width: 1920).resolution)
        XCTAssertNil(EngineStreamFacts().resolution)
        XCTAssertEqual(PlayerModel.StreamFacts(width: 3840, height: 2160).resolution, "3840×2160")
        XCTAssertNil(PlayerModel.StreamFacts(height: 720).resolution)
    }

    func testAnUntouchedPictureIsNeutral() {
        XCTAssertTrue(PictureAdjustment().isNeutral)
        XCTAssertTrue(PictureAdjustment.neutral.isNeutral)
        var adjusted = PictureAdjustment()
        adjusted.gamma = -5
        XCTAssertFalse(adjusted.isNeutral)
    }

    func testAStreamFailureWorthOneMoreGo() {
        XCTAssertFalse(AVEngine.isRecoverableStreamFailure(nil))
        XCTAssertTrue(AVEngine.isRecoverableStreamFailure(NSError(domain: "CoreMediaErrorDomain", code: -12889)))
        XCTAssertTrue(AVEngine.isRecoverableStreamFailure(URLError(.timedOut)))
        XCTAssertTrue(AVEngine.isRecoverableStreamFailure(URLError(.networkConnectionLost)))
        XCTAssertFalse(AVEngine.isRecoverableStreamFailure(URLError(.badURL)))
        XCTAssertFalse(AVEngine.isRecoverableStreamFailure(NSError(domain: "CoreMediaErrorDomain", code: -1)),
                       "a media error that is about the media")
        XCTAssertFalse(AVEngine.isRecoverableStreamFailure(NSError(domain: "SomethingElse", code: -12889)),
                       "the code only means it in CoreMedia's domain")
    }

    func testARecoverableFailureIsFoundUnderWhatWrapsIt() {
        let inner = NSError(domain: "CoreMediaErrorDomain", code: -12888)
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertTrue(AVEngine.isRecoverableStreamFailure(outer))
        let dull = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                           userInfo: [NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -1)])
        XCTAssertFalse(AVEngine.isRecoverableStreamFailure(dull))
    }

    func testWhichPicturesDecodeInHardware() throws {
        XCTAssertTrue(EnginePolicy.videoDecodesInHardware(nil, decodesAV1: false), "undescribed: the benefit of the doubt")
        XCTAssertTrue(EnginePolicy.videoDecodesInHardware(try stream(#"{"Type":"Video"}"#), decodesAV1: false))
        XCTAssertTrue(EnginePolicy.videoDecodesInHardware(try stream(#"{"Type":"Video","Codec":"HEVC"}"#), decodesAV1: false))
        XCTAssertTrue(EnginePolicy.videoDecodesInHardware(try stream(#"{"Type":"Video","Codec":"h264"}"#), decodesAV1: false))
        XCTAssertFalse(EnginePolicy.videoDecodesInHardware(try stream(#"{"Type":"Video","Codec":"av1"}"#), decodesAV1: false))
        XCTAssertTrue(EnginePolicy.videoDecodesInHardware(try stream(#"{"Type":"Video","Codec":"av1"}"#), decodesAV1: true))
        XCTAssertFalse(EnginePolicy.videoDecodesInHardware(try stream(#"{"Type":"Video","Codec":"vp9"}"#), decodesAV1: true))
        XCTAssertFalse(EnginePolicy.videoDecodesInHardware(try stream(#"{"Type":"Video","Codec":"mpeg2video"}"#), decodesAV1: true))
    }

    func testAFilesContainerIsItsExtension() {
        XCTAssertEqual(EnginePolicy.fileContainer(of: URL(fileURLWithPath: "/tmp/Film.MKV")), "mkv")
        XCTAssertEqual(EnginePolicy.fileContainer(of: URL(fileURLWithPath: "/tmp/film.mp4")), "mp4")
        XCTAssertNil(EnginePolicy.fileContainer(of: URL(fileURLWithPath: "/tmp/film")))
    }

    func testAWarmOrSavingDeviceIsHeldToARung() {
        XCTAssertNil(AdaptiveQuality.powerRung(thermal: .nominal, lowPower: false))
        XCTAssertNil(AdaptiveQuality.powerRung(thermal: .fair, lowPower: false))
        XCTAssertEqual(AdaptiveQuality.powerRung(thermal: .nominal, lowPower: true), 10_000_000)
        XCTAssertEqual(AdaptiveQuality.powerRung(thermal: .serious, lowPower: false), 10_000_000)
        XCTAssertEqual(AdaptiveQuality.powerRung(thermal: .critical, lowPower: false), 5_000_000)
        XCTAssertEqual(AdaptiveQuality.powerRung(thermal: .critical, lowPower: true), 5_000_000, "the lower of the two")
    }

    func testBitratesReadInMegabits() {
        XCTAssertEqual(PlayerStreamRows.mbps(12_400_000), "12 Mbps")
        XCTAssertEqual(PlayerStreamRows.mbps(10_000_000), "10 Mbps")
        XCTAssertEqual(PlayerStreamRows.mbps(4_300_000), "4.3 Mbps")
        XCTAssertEqual(PlayerStreamRows.mbps(800_000), "0.8 Mbps")
    }

    func testFrameRatesAndSpeedsAreNamed() {
        XCTAssertEqual(PlayerModel.frameRateName(25), "25 fps")
        XCTAssertEqual(PlayerModel.frameRateName(23.976), "23.976 fps")
        XCTAssertEqual(PlayerModel.frameRateName(59.94), "59.94 fps")
        XCTAssertEqual(PlayerModel.frameRateName(60, unit: "Hz"), "60 Hz")
        XCTAssertEqual(PlayerModel.speedName(1), "Normal")
        XCTAssertEqual(PlayerModel.speedName(1.5), "1.5×")
        XCTAssertEqual(PlayerModel.speedName(2), "2×")
        XCTAssertTrue(PlayerModel.speeds.contains(1))
        XCTAssertEqual(PlayerModel.speeds, PlayerModel.speeds.sorted())
    }

    func testAudioOffsetsAreNamedBothWays() {
        XCTAssertEqual(PlayerModel.audioDelayName(0), "In step")
        XCTAssertEqual(PlayerModel.audioDelayName(-150), "Sound 150 ms earlier")
        XCTAssertEqual(PlayerModel.audioDelayName(50), "Sound 50 ms later")
        XCTAssertEqual(PlayerModel.audioDelayShortName(0), "in step")
        XCTAssertEqual(PlayerModel.audioDelayShortName(-150), "150 ms earlier")
        XCTAssertEqual(PlayerModel.audioDelayShortName(50), "50 ms later")
        XCTAssertEqual(PlayerModel.audioDelays.first, -500)
        XCTAssertEqual(PlayerModel.audioDelays.last, 500)
        XCTAssertEqual(PlayerModel.audioDelays.count, 21, "fifty at a time either side of zero")
        XCTAssertTrue(PlayerModel.audioDelays.contains(0))
    }

    func testTitlesOfWhatIsPlayingAndOfUpNextRows() throws {
        let episode = try JSONDecoder().decode(BaseItem.self, from: Data(#"""
        {"Id":"e1","Name":"The One","Type":"Episode","SeriesName":"Show","ParentIndexNumber":2,"IndexNumber":3}
        """#.utf8))
        let label = try XCTUnwrap(episode.episodeLabel)
        XCTAssertEqual(PlayerModel.displayTitle(episode), "Show · \(label) · The One")
        XCTAssertEqual(PlayerModel.upNextRowTitle(episode), "\(label) · The One", "the series is the one playing: not said again")
        let film = try JSONDecoder().decode(BaseItem.self, from: Data(#"{"Id":"f1","Name":"A Film","Type":"Movie"}"#.utf8))
        XCTAssertEqual(PlayerModel.displayTitle(film), "A Film")
        XCTAssertEqual(PlayerModel.upNextRowTitle(film), "A Film")
        let unnumbered = try JSONDecoder().decode(BaseItem.self, from: Data(#"{"Id":"e2","Name":"Special","Type":"Episode","SeriesName":"Show"}"#.utf8))
        XCTAssertEqual(PlayerModel.displayTitle(unnumbered), "Show · Special")
        XCTAssertEqual(PlayerModel.upNextRowTitle(unnumbered), "Special")
    }

    // MARK: "Forced only"

    private struct Sub: Equatable {
        var id: Int
        var language: String?
        var forced: Bool
    }

    private func forced(_ tracks: [Sub], audio: String?) -> Sub? {
        TrackPreference.forcedPick(tracks, audioLanguage: audio, language: { $0.language }, isForced: { $0.forced })
    }

    func testForcedOnlyTakesTheForcedTrackInTheLanguageBeingHeard() {
        let tracks = [
            Sub(id: 0, language: "eng", forced: false),
            Sub(id: 1, language: "spa", forced: true),
            Sub(id: 2, language: "eng", forced: true),
        ]
        XCTAssertEqual(forced(tracks, audio: "eng")?.id, 2)
        XCTAssertEqual(forced(tracks, audio: "spa")?.id, 1)
        XCTAssertNil(forced(tracks, audio: "fre"), "no forced track in French, and none unlabelled: nothing")
    }

    func testForcedOnlyFallsBackToAnUnlabelledForcedTrack() {
        let tracks = [
            Sub(id: 0, language: "eng", forced: false),
            Sub(id: 1, language: "und", forced: true),
            Sub(id: 2, language: nil, forced: true),
        ]
        XCTAssertEqual(forced(tracks, audio: "jpn")?.id, 1, "the file doesn't say what language: that one")
        XCTAssertEqual(forced(tracks, audio: nil)?.id, 1)
        XCTAssertEqual(forced([Sub(id: 5, language: "", forced: true)], audio: "")?.id, 5)
        XCTAssertNil(forced([Sub(id: 0, language: "eng", forced: false)], audio: "eng"), "nothing forced, nothing shown")
    }

    func testAnIdReadsTheSameWithOrWithoutDashes() {
        XCTAssertEqual(SyncPlayWire.normal("A8362222-FD8A-43fd-95de-0c785e5150b9"), "a8362222fd8a43fd95de0c785e5150b9")
        XCTAssertEqual(SyncPlayWire.ticks(1.5), 15_000_000)
        XCTAssertEqual(SyncPlayWire.ticks(-3), 0, "never before the start")
    }
}
