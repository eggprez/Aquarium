//  The Mac player's own logic: the Playback menu's key gating
//  (`PlaybackCommands.gatedShortcut`), the C key, the menus' track rows,
//  ↑ / ↓ volume, Full Screen and Picture in Picture guards, the pointer clock
//  that hides the controls, and the player window's shape (`fittedContent`).

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Aquarium

@MainActor
final class MacPlayerTests: MacUnitTestCase {
    private var savedVolume = 1.0
    private var savedMuted = false
    private var savedSpeed = 1.0
    private var savedHide = 2.0
    private var player: PlayerModel { .shared }
    private var state: PlayerMacState { .shared }

    override func setUp() async throws {
        savedVolume = player.volume
        savedMuted = player.isMuted
        savedSpeed = player.speed
        savedHide = Preferences.shared.hideControlsAfter
    }

    override func tearDown() async throws {
        player.volume = savedVolume
        player.isMuted = savedMuted
        player.speed = savedSpeed
        Preferences.shared.hideControlsAfter = savedHide
        state.noteActivity()
    }

    // MARK: Key gating

    private func gate(_ key: KeyEquivalent, _ modifiers: EventModifiers = [], inPlayer: Bool?, yielded: Bool? = nil) -> KeyboardShortcut? {
        PlaybackCommands.gatedShortcut(key, modifiers, inPlayer: inPlayer, keysYielded: yielded)
    }

    func testKeysAreBoundWhileThePlayerWindowIsInFront() {
        XCTAssertEqual(gate(.space, inPlayer: true), KeyboardShortcut(.space, modifiers: []))
        XCTAssertEqual(gate(.leftArrow, .command, inPlayer: true), KeyboardShortcut(.leftArrow, modifiers: .command))
        XCTAssertEqual(gate("k", .command, inPlayer: true), KeyboardShortcut("k", modifiers: .command))
    }

    /// Regression: SpaceBarPausesWhileTypingSearch. Space, [ and ] were bound
    /// everywhere, so typing "star wars" into Search paused the film.
    /// Source: commit b723cea; Aquarium/Player/PlayerWindow.swift:183-195.
    func testBugSpaceBarPausesWhileTypingSearch() {
        for key: KeyEquivalent in [.space, "[", "]", "m", "f", "s", "c", "p", .upArrow, .downArrow] {
            XCTAssertNil(gate(key, inPlayer: nil), "\(key.character) is unbound with no player window in front")
            XCTAssertNil(gate(key, inPlayer: false))
        }
        XCTAssertNil(gate("[", .option, inPlayer: nil), "⌥[ types a quotation mark elsewhere")
    }

    /// Regression: CmdArrowSkipsInTextFieldsAndGuide. ⌘← and ⌘→ moved the film
    /// instead of the text cursor, and took Earlier/Later from the guide.
    /// Source: commit 9c6fb8c; Aquarium/Player/PlayerWindow.swift:189-193.
    func testBugCmdArrowSkipsInTextFieldsAndGuide() {
        XCTAssertNil(gate(.leftArrow, .command, inPlayer: nil))
        XCTAssertNil(gate(.rightArrow, .command, inPlayer: false))
    }

    /// Regression: BareKeysStealInspectorAndErrorCard. With the keyboard in
    /// the Stream Info inspector or the error card, Space paused instead of
    /// pressing Close and ↑/↓ changed the volume instead of scrolling.
    /// Source: commit 430f7d6; Aquarium/Player/PlayerWindow.swift:166-176.
    func testBugBareKeysStealInspectorAndErrorCard() {
        XCTAssertNil(gate(.space, inPlayer: true, yielded: true))
        XCTAssertNil(gate(.upArrow, inPlayer: true, yielded: true))
        XCTAssertNil(gate("c", inPlayer: true, yielded: true))
        // Keys with a modifier stay the player's.
        XCTAssertNotNil(gate(.leftArrow, .command, inPlayer: true, yielded: true))
        XCTAssertNotNil(gate("k", .command, inPlayer: true, yielded: true))
    }

    // MARK: C: toggle subtitles

    func testCTurnsOnTheTrackThatWasOnLast() {
        let options = [MacFixture.track(server: 7, av: 0, label: "English"),
                       MacFixture.track(server: 8, av: 1, label: "Spanish")]
        XCTAssertEqual(PlayerMacState.subtitleToTurnOn(options, lastOn: 8)?.serverIndex, 8)
    }

    func testCTurnsOnTheFirstNonForcedTrackTheFirstTime() {
        let options = [MacFixture.track(server: 10, av: 0, label: "English", forced: true),
                       MacFixture.track(server: 7, av: 1, label: "English")]
        XCTAssertEqual(PlayerMacState.subtitleToTurnOn(options, lastOn: nil)?.serverIndex, 7,
                       "a forced track is not what C means by subtitles on")
    }

    func testCTakesAForcedTrackWhenThatIsAllThereIs() {
        let options = [MacFixture.track(server: 10, av: 0, label: "English", forced: true)]
        XCTAssertEqual(PlayerMacState.subtitleToTurnOn(options, lastOn: nil)?.serverIndex, 10)
    }

    func testCWithNoTracksDoesNothing() {
        XCTAssertNil(PlayerMacState.subtitleToTurnOn([], lastOn: 3))
    }

    func testCWithAGoneTrackFallsBack() {
        let options = [MacFixture.track(server: 7, av: 0, label: "English")]
        XCTAssertEqual(PlayerMacState.subtitleToTurnOn(options, lastOn: 99)?.serverIndex, 7)
    }

    func testCycleSubtitlesWithNothingPlayingIsHarmless() {
        guard !player.isActive else { return }
        state.cycleSubtitles(player)
        XCTAssertNil(player.selectedSubtitleOption)
    }

    /// The C key end to end on the model, with tracks an engine would have
    /// reported (F:film.long_multitrack's English forced and English full).
    func testCKeyTogglesOffAndBackToTheSameTrack() throws {
        guard !player.isActive, !player.isLocal else { throw XCTSkip("something is playing in the host") }
        let savedTracks = player.subtitleTracks
        let savedSelected = player.selectedSubtitleTrack
        defer {
            player.setSubtitleTracks(savedTracks)
            player.setSelectedSubtitleTrack(savedSelected)
        }
        player.setSubtitleTracks([
            PlayerTrack(id: 0, label: "English Forced", language: "eng", isForced: true),
            PlayerTrack(id: 1, label: "English", language: "eng", isForced: false),
            PlayerTrack(id: 2, label: "Spanish", language: "spa", isForced: false),
        ])
        player.setSelectedSubtitleTrack(nil)
        state.cycleSubtitles(player)
        XCTAssertEqual(player.selectedSubtitleTrack, 1, "first time: the first track that isn't forced")
        player.selectSubtitles(player.subtitleOptions.first { $0.avIndex == 2 })
        XCTAssertEqual(player.selectedSubtitleTrack, 2)
        state.cycleSubtitles(player)
        XCTAssertNil(player.selectedSubtitleTrack, "C with subtitles on turns them off")
        state.cycleSubtitles(player)
        XCTAssertEqual(player.selectedSubtitleTrack, 2, "and C again brings back the one that was on")
    }

    // MARK: Chapters (the timeline's ticks and the scrub preview's name)

    func testChapterNameAtATime() {
        let saved = player.chapters
        defer { player.setChapters(saved) }
        // F:film.long_direct's chapters.
        player.setChapters([Chapter(id: 0, start: 0, title: "Recap"), Chapter(id: 1, start: 30, title: "Intro"),
                            Chapter(id: 2, start: 60, title: "Act One"), Chapter(id: 3, start: 400, title: "Intermission")])
        XCTAssertEqual(player.chapterStarts, [0, 30, 60, 400])
        XCTAssertEqual(player.chapterName(at: 0), "Recap")
        XCTAssertEqual(player.chapterName(at: 45), "Intro")
        XCTAssertEqual(player.chapterName(at: 60), "Act One")
        XCTAssertEqual(player.chapterName(at: 5000), "Intermission")
        player.setChapters([])
        XCTAssertNil(player.chapterName(at: 10))
    }

    // MARK: Track rows in the Playback menu and the picture's menu

    func testForcedTrackSaysSo() {
        XCTAssertEqual(PlayerMenuItems.trackTitle(MacFixture.track(server: 10, av: 2, label: "English", forced: true), isLocal: false),
                       "English (Forced)")
    }

    func testTrackNeedingANewStreamSaysSoWhenStreaming() {
        let t = MacFixture.track(server: 4, av: nil, label: "Deutsch · DTS 5.1")
        XCTAssertEqual(PlayerMenuItems.trackTitle(t, isLocal: false), "Deutsch · DTS 5.1 (reopens the stream)")
        XCTAssertEqual(PlayerMenuItems.trackTitle(t, isLocal: true), "Deutsch · DTS 5.1",
                       "a download asks before it streams, so the row doesn't say it")
    }

    func testPlainTrack() {
        XCTAssertEqual(PlayerMenuItems.trackTitle(MacFixture.track(server: 1, av: 0, label: "English · AAC"), isLocal: false),
                       "English · AAC")
    }

    func testTrackIdentifiersUseTheServerIndex() {
        let t = MacFixture.track(server: 10, av: 2, label: "x")
        XCTAssertEqual(TestID.Player.menuSubtitleOption(TestID.Player.trackKey(t.id)), "player.menu.subtitles.10")
        let engineOnly = MacFixture.track(server: nil, av: 2, label: "x")
        XCTAssertEqual(engineOnly.id, -3)
        XCTAssertTrue(engineOnly.needsNewStream == false)
    }

    // MARK: Speed, the [ and ] keys

    func testSpeedSteps() {
        player.speed = 1
        player.stepSpeed(1)
        XCTAssertEqual(player.speed, 1.25)
        player.stepSpeed(-1)
        player.stepSpeed(-1)
        XCTAssertEqual(player.speed, 0.75)
        for _ in 0..<10 { player.stepSpeed(-1) }
        XCTAssertEqual(player.speed, 0.5, "Slower stops at the slowest")
        for _ in 0..<10 { player.stepSpeed(1) }
        XCTAssertEqual(player.speed, 2, "Faster stops at the fastest")
    }

    func testSpeedNames() {
        XCTAssertEqual(PlayerModel.speedName(1), "Normal")
        XCTAssertEqual(PlayerModel.speeds, [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        XCTAssertEqual(TestID.Player.speedKey(1.25), "125")
    }

    // MARK: ↑ / ↓ volume

    func testVolumeStepsFivePercentAndClamps() {
        player.volume = 0.5
        state.stepVolume(player, by: 0.05)
        XCTAssertEqual(player.volume, 0.55, accuracy: 0.0001)
        player.volume = 0.98
        state.stepVolume(player, by: 0.05)
        XCTAssertEqual(player.volume, 1)
        player.volume = 0.02
        state.stepVolume(player, by: -0.05)
        XCTAssertEqual(player.volume, 0)
    }

    func testVolumeUpUnmutesButDownDoesNot() {
        player.volume = 0.5
        player.isMuted = true
        state.stepVolume(player, by: -0.05)
        XCTAssertTrue(player.isMuted)
        state.stepVolume(player, by: 0.05)
        XCTAssertFalse(player.isMuted, "↑ while muted means I want to hear this")
    }

    func testVolumeIsRemembered() {
        player.volume = 0.42
        XCTAssertEqual(Preferences.shared.volume, 0.42, accuracy: 0.0001)
    }

    // MARK: Full screen and Picture in Picture

    /// Regression: FullScreenMenuFullScreensMainWindow. With no player
    /// window, Full Screen fell back to the key window and put the main
    /// window into full screen. Source: commit 430f7d6;
    /// Aquarium/Player/PlayerMacMenus.swift:96-104.
    func testBugFullScreenMenuFullScreensMainWindow() throws {
        guard state.window == nil else { throw XCTSkip("a player window is open in the host") }
        let main = MacMainWindow.window
        let wasFull = main?.styleMask.contains(.fullScreen)
        state.toggleFullScreen()
        XCTAssertEqual(main?.styleMask.contains(.fullScreen), wasFull, "no player window: nothing goes full screen")
        XCTAssertFalse(state.isFullScreen)
    }

    /// Regression: the player window put away for Picture in Picture (ordered
    /// out, not closed, not minimised) is never brought back by Full Screen
    /// or the sidebar's Now Playing strip — it came back black. Source:
    /// commit 430f7d6; PlayerMacMenus.swift:106-113, MacSidebar.swift:228-233.
    func testBugHiddenForPictureInPictureIsDetected() throws {
        guard state.window == nil else { throw XCTSkip("a player window is open in the host") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        state.window = window
        defer { state.window = nil }
        XCTAssertTrue(state.isHiddenForPictureInPicture, "never shown, not minimised: put away")
        state.toggleFullScreen()
        XCTAssertFalse(window.styleMask.contains(.fullScreen), "Full Screen does nothing while it is put away")
        XCTAssertFalse(state.isFullScreen)
    }

    func testNoWindowIsNotHiddenForPictureInPicture() throws {
        guard state.window == nil else { throw XCTSkip("a player window is open in the host") }
        XCTAssertFalse(state.isHiddenForPictureInPicture)
    }

    func testPictureInPictureMenuIsOffWithNoController() throws {
        guard state.pictureInPicture == nil else { throw XCTSkip("the player screen is up in the host") }
        XCTAssertFalse(state.canPictureInPicture)
        state.togglePictureInPicture()   // no controller: nothing happens, nothing crashes
    }

    func testStreamInfoAndPanelRequests() {
        let shows = state.showsStreamInfo
        let panel = state.togglePanelRequest
        state.showsStreamInfo.toggle()
        state.togglePanelRequest += 1
        XCTAssertNotEqual(state.showsStreamInfo, shows)
        XCTAssertEqual(state.togglePanelRequest, panel + 1)
        state.showsStreamInfo = shows
    }

    // MARK: The pointer clock

    func testPointerLeavingHidesTheControls() {
        state.noteActivity()
        XCTAssertTrue(state.controlsVisible)
        state.pointerLeft()
        XCTAssertFalse(state.controlsVisible)
        state.noteActivity()
        XCTAssertTrue(state.controlsVisible, "moving the pointer brings them back")
    }

    func testControlsHideAfterTheSettingsInterval() async throws {
        Preferences.shared.hideControlsAfter = 0.3
        state.pointerLeft()
        state.noteActivity()
        XCTAssertTrue(state.controlsVisible)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertFalse(state.controlsVisible, "resting pointer: the controls go after the interval")
    }

    func testMacHidesControlsSoonerThanATouchScreen() {
        XCTAssertEqual(Preferences.defaultHideControlsAfter, 2)
    }

    // MARK: The player window's shape

    func testWindowTakesThePicturesShapeKeepingWidthAndTop() throws {
        let content = NSRect(x: 100, y: 100, width: 960, height: 600)
        let fitted = try XCTUnwrap(PlayerWindow.fittedContent(content, picture: CGSize(width: 1920, height: 1080), maxContentHeight: 2000))
        XCTAssertEqual(fitted.width, 960)
        XCTAssertEqual(fitted.height, 540)
        XCTAssertEqual(fitted.maxY, content.maxY, "pinned at the title bar")
        XCTAssertEqual(fitted.minX, content.minX)
    }

    func testWindowShrinksBothWaysRatherThanRunOffTheScreen() throws {
        let content = NSRect(x: 0, y: 0, width: 1600, height: 900)
        let fitted = try XCTUnwrap(PlayerWindow.fittedContent(content, picture: CGSize(width: 1080, height: 1920), maxContentHeight: 1000))
        XCTAssertEqual(fitted.height, 1000)
        XCTAssertEqual(fitted.width, 562.5, accuracy: 0.01)
    }

    func testWindowAlreadyTheRightShapeIsLeftAlone() {
        let content = NSRect(x: 0, y: 0, width: 1280, height: 720)
        XCTAssertNil(PlayerWindow.fittedContent(content, picture: CGSize(width: 1920, height: 1080), maxContentHeight: nil))
        XCTAssertNil(PlayerWindow.fittedContent(content.insetBy(dx: 0, dy: 0.4), picture: CGSize(width: 1920, height: 1080), maxContentHeight: nil),
                     "within a point is close enough")
    }

    func testNoPictureSizeNoChange() {
        XCTAssertNil(PlayerWindow.fittedContent(NSRect(x: 0, y: 0, width: 800, height: 600), picture: .zero, maxContentHeight: nil))
    }

    // MARK: Up Next and Stop After

    /// Regression: StopAfterOfferedOnFilm. A film on its own has nothing to
    /// stop before; Playback ▸ Sleep ▸ Stop After This is gated on
    /// `hasUpNext`. Source: commit d5792c6 (master fix list Pro Max #11);
    /// Aquarium/Player/PlayerModel.swift:1018-1021, PlayerMacMenus.swift:341.
    func testBugStopAfterOfferedOnFilm() throws {
        guard !player.isActive else { throw XCTSkip("something is playing in the host") }
        let savedQueue = player.queue
        defer { player.queue = savedQueue }
        player.queue = []
        if player.upNext == nil, player.upNextLocalId == nil {
            XCTAssertFalse(player.hasUpNext)
        }
        player.queue = [MacFixture.film("q1")]
        XCTAssertTrue(player.hasUpNext, "something queued by hand is something to stop before")
    }

    func testStopAfterWordingFollowsTheItem() throws {
        guard !player.isActive else { throw XCTSkip("something is playing in the host") }
        XCTAssertEqual(player.stopAfterTitle, "Stop after this")
    }

    func testDisplayTitleForAnEpisodeNamesTheShow() {
        let ep = MacFixture.episode("e", series: "FX Long Show", season: 1, number: 2, name: "Long Episode 1.2")
        let title = PlayerModel.displayTitle(ep)
        XCTAssertTrue(title.hasPrefix("FX Long Show"), title)
        XCTAssertTrue(title.hasSuffix("Long Episode 1.2"), title)
        XCTAssertEqual(PlayerModel.displayTitle(MacFixture.film("f", name: "FX HEVC MP4")), "FX HEVC MP4")
    }
}
#endif
