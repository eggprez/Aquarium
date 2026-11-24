//  The player's logic as an iPad takes it: the handheld numbers of the
//  chrome that PadPlayerMetricsTests does not already hold (the timeline's
//  bar and thumb, where the moment overlays and the skip badge sit), which
//  pill an iPad's popover hangs off, and the engine and settings an iPad
//  is held to. The chrome's state machine (hiding, skips, ripple) and the
//  engine policy's rules are platform-neutral and tested in
//  AquariumTests/Shared (PlayChromeStateTests, EnginePolicyTests); what is
//  here is only what an iPad host answers differently.
//
//  Sources: Player/Chrome/PlayerChromeStyle.swift, Player/Chrome/PlayerChrome.swift,
//  Player/Engine/EnginePolicy.swift, Core/Preferences.swift
//  (`keysNotOfferedHere`, `pinSettingsNotOfferedHere`).

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class PadPlayerLogicMetricsTests: PadUnitTestCase {
    func testTimelineBarAndThumbGrowUnderAFinger() {
        XCTAssertEqual(PlayerMetrics.barHeight(scrubbing: false), 4)
        XCTAssertEqual(PlayerMetrics.barHeight(scrubbing: true), 8)
        XCTAssertEqual(PlayerMetrics.thumbSize(scrubbing: false), 14, "a thumb at rest, unlike a television's bare bar")
        XCTAssertEqual(PlayerMetrics.thumbSize(scrubbing: true), 20)
        XCTAssertEqual(PlayerMetrics.thumbRing, 0, "the accent ring is the television's")
        XCTAssertEqual(PlayerMetrics.timelineBand, 44, "a finger-sized band round a 4-point bar")
    }

    func testScrubPreviewRidesCloseAboveTheTimeline() {
        XCTAssertEqual(PlayerMetrics.previewCorner, 10)
        XCTAssertEqual(PlayerMetrics.previewLift, 18)
    }

    /// Skip intro and Up Next stand clear of the bottom band while the
    /// controls are up, lower over a channel (whose band has no times row),
    /// and near the foot of the picture with the controls away.
    func testMomentOverlaysLiftClearOfTheControls() {
        XCTAssertEqual(PlayerMetrics.overlayLift(controlsUp: true, live: false), 148)
        XCTAssertEqual(PlayerMetrics.overlayLift(controlsUp: true, live: true), 110)
        XCTAssertEqual(PlayerMetrics.overlayLift(controlsUp: false, live: false), 24)
        XCTAssertEqual(PlayerMetrics.overlayLift(controlsUp: false, live: true), 24)
    }

    /// A full-width iPad is not compact: the badge sits further in than a
    /// phone's (or an iPad narrowed to compact width).
    func testSkipBadgeSitsFurtherInAtRegularWidth() {
        XCTAssertEqual(PlayerMetrics.skipBadgeInset(compact: false), 72)
        XCTAssertEqual(PlayerMetrics.skipBadgeInset(compact: true), 36)
    }
}

/// On an iPad (regular width) the panel is a popover, not a sheet, and it
/// hangs off the pill it belongs to: Info off the Info pill, the line-up off
/// the Channels pill, every page opened from the "…" card off "…".
@MainActor
final class PadPlayerPopoverAnchorTests: PadUnitTestCase {
    func testEachPageHangsOffItsOwnPill() {
        XCTAssertEqual(PlayerChromeState.PanelAnchor.anchor(for: .info), .info)
        XCTAssertEqual(PlayerChromeState.PanelAnchor.anchor(for: .channels), .channels)
        for tab in PlayerTab.allCases where tab != .info && tab != .channels {
            XCTAssertEqual(PlayerChromeState.PanelAnchor.anchor(for: tab), .more, "\(tab) hangs off …")
        }
    }

    func testAFreshChromeHangsThePanelOffInfo() {
        XCTAssertEqual(PlayerChromeState(showsTotalTime: false).panelAnchor, .info)
    }
}

/// The engine on an iPad: AVFoundation unless the file needs mpv, and the
/// settings with no row here kept at their defaults.
@MainActor
final class PadEngineTests: PadUnitTestCase {
    func testThisIsAnIPadToThePolicy() {
        XCTAssertEqual(EnginePolicy.Platform.current, .iPad)
        XCTAssertEqual(PlaybackEngineKind.platformDefault, .apple)
        XCTAssertEqual(PlaybackEngineKind.apple.title, "AVFoundation", "what Info's Engine row reads")
    }

    func testAnIPadPlaysOnAVFoundationByDefault() {
        let plain = EnginePolicy.Request(platform: .iPad, mpvAvailable: true)
        XCTAssertEqual(EnginePolicy.choose(plain), .apple)
        var channel = plain
        channel.isLive = true
        channel.isHLS = true
        XCTAssertEqual(EnginePolicy.choose(channel), .apple, "every channel is AVPlayer's")
    }

    func testPictureInPictureAndAirPlayAreAlwaysAVFoundations() {
        var request = EnginePolicy.Request(platform: .iPad, preference: .mpv, mpvAvailable: true)
        XCTAssertEqual(EnginePolicy.choose(request), .mpv, "the policy itself honours a preference")
        request.requiresApple = true
        XCTAssertEqual(EnginePolicy.choose(request), .apple, "asking for PiP is asking for the engine")
    }

    /// An iPad draws mpv cheaply, as a phone does, unless told Never; heat
    /// wins over the setting.
    func testAnIPadDrawsMpvCheaplyUnlessToldNever() {
        XCTAssertEqual(EnginePolicy.powerProfile(platform: .iPad, saver: .automatic, onBattery: false,
                                                 lowPower: false, thermal: .nominal), .battery)
        XCTAssertEqual(EnginePolicy.powerProfile(platform: .iPad, saver: .never, onBattery: true,
                                                 lowPower: true, thermal: .nominal), .quality)
        XCTAssertEqual(EnginePolicy.powerProfile(platform: .iPad, saver: .never, onBattery: false,
                                                 lowPower: false, thermal: .serious), .battery, "heat wins")
    }

    /// An iPad's Settings has no engine, skip-interval, hide-after, hold-2×,
    /// edge-gesture, subtitle-look or picture rows, so those keys are pinned
    /// to their defaults at launch and whenever another device's choices
    /// arrive through iCloud.
    func testTheKeysWithNoRowOnAnIPad() {
        let keys = Preferences.keysNotOfferedHere
        for key in ["player_engine", "player_battery_saver", "player_skip_interval", "player_hide_after",
                    "player_hold_2x", "player_edge_gestures", "sub_font_size", "sub_bg", "subs_forced_only",
                    "picture_brightness", "picture_zoom", "picture_aspect", "player_night_mode", "stereo_downmix"] {
            XCTAssertTrue(keys.contains(key), "\(key) is pinned")
        }
        for key in ["autoplay_next", "resume_playback", "player_show_remaining"] {
            XCTAssertFalse(keys.contains(key), "\(key) has a row (or a tap in the player) and is the person's to set")
        }
    }

    /// The pinned values themselves, read off the app's live preferences: the
    /// launch pinned them, whatever a test run left behind.
    func testThePinnedSettingsAreAtTheirDefaults() {
        let prefs = Preferences.shared
        XCTAssertEqual(prefs.playbackEngine, .automatic)
        XCTAssertEqual(prefs.skipInterval, 10)
        XCTAssertEqual(prefs.hideControlsAfter, Preferences.defaultHideControlsAfter)
        XCTAssertTrue(prefs.holdForDoubleSpeed)
        XCTAssertFalse(prefs.edgeGestures)
        XCTAssertFalse(prefs.forcedSubtitlesOnly)
    }

    func testControlsHideAfterFourSecondsWhereAFingerFindsThem() {
        XCTAssertEqual(Preferences.defaultHideControlsAfter, 4)
        XCTAssertEqual(Preferences.skipIntervals, [10, 15, 30])
        XCTAssertTrue(Preferences.hideControlsChoices.contains(Preferences.defaultHideControlsAfter))
    }
}
#endif
