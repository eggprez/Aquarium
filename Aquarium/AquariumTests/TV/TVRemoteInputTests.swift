//  The Siri Remote, read by `RemoteInputView`, and what `PlayerRemoteDriver`
//  makes of it (`RemoteRules`). See Player/TV/RemoteInput.swift and
//  Player/TV/TVPlayerScreen.swift.

#if os(tvOS)
import XCTest
import UIKit
import SwiftUI
@testable import Aquarium

/// A press of a given type: UIKit gives no initialiser for one.
private final class FakePress: UIPress {
    private let pressType: UIPress.PressType
    init(_ type: UIPress.PressType) {
        pressType = type
        super.init()
    }
    override var type: UIPress.PressType { pressType }
}

/// `RemoteEvent` has no equality; its description is enough to compare.
private func eventName(_ event: RemoteEvent) -> String {
    switch event {
    case .select: "select"
    case .arrow(let d):
        switch d {
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        @unknown default: "arrow?"
        }
    case .playPause: "playPause"
    case .menu: "menu"
    case .panChanged: "panChanged"
    case .panEnded: "panEnded"
    case .touchDown: "touchDown"
    case .panelTouchDown: "panelTouchDown"
    case .panelSwipeUp: "panelSwipeUp"
    }
}

@MainActor
final class TVRemoteInputTests: TVUnitTestCase {
    private var events: [String] = []

    private func view(enabled: Bool) -> RemoteInputView {
        let view = RemoteInputView()
        view.onEvent = { [weak self] in self?.events.append(eventName($0)) }
        view.isInputEnabled = enabled
        return view
    }

    override func setUp() async throws {
        events = []
    }

    // MARK: Presses → events

    func testEachButtonMapsToItsEventOnRelease() {
        let v = view(enabled: true)
        let mapping: [(UIPress.PressType, String)] = [
            (.select, "select"), (.playPause, "playPause"),
            (.leftArrow, "left"), (.rightArrow, "right"), (.upArrow, "up"), (.downArrow, "down"),
        ]
        for (type, expected) in mapping {
            events = []
            v.pressesBegan([FakePress(type)], with: nil)
            XCTAssertEqual(events, [], "\(expected) acted on press-down; it should act on release, like a button")
            v.pressesEnded([FakePress(type)], with: nil)
            XCTAssertEqual(events, [expected], "press type \(type.rawValue)")
        }
    }

    func testMenuIsNeverTakenHereSoPlayerScreenSeesIt() {
        // Regression (memory note tvos-sim-testing, 2026-10-11): swallowing Menu in
        // UIKit didn't stop the full-screen cover closing; only the SwiftUI
        // onExitCommand does, so Menu must go up the chain untouched.
        let v = view(enabled: true)
        v.pressesBegan([FakePress(.menu)], with: nil)
        v.pressesEnded([FakePress(.menu)], with: nil)
        v.pressesCancelled([FakePress(.menu)], with: nil)
        XCTAssertEqual(events, [])
    }

    func testDisabledViewTakesNothing() {
        let v = view(enabled: false)
        for type: UIPress.PressType in [.select, .playPause, .leftArrow, .rightArrow, .upArrow, .downArrow, .menu] {
            v.pressesEnded([FakePress(type)], with: nil)
        }
        XCTAssertEqual(events, [], "with a panel open the focus engine owns the remote")
    }

    func testCancelledPressDoesNothing() {
        let v = view(enabled: true)
        v.pressesBegan([FakePress(.select)], with: nil)
        v.pressesCancelled([FakePress(.select)], with: nil)
        XCTAssertEqual(events, [])
    }

    func testSeveralPressesAtOnceEachReported() {
        let v = view(enabled: true)
        v.pressesEnded([FakePress(.select), FakePress(.menu)], with: nil)
        XCTAssertEqual(events, ["select"], "Menu passed on, the select acted on")
    }

    // MARK: Focus and recognisers

    func testHoldsFocusOnlyWhileEnabled() {
        let v = view(enabled: false)
        XCTAssertFalse(v.canBecomeFocused)
        v.isInputEnabled = true
        XCTAssertTrue(v.canBecomeFocused)
        v.isInputEnabled = false
        XCTAssertFalse(v.canBecomeFocused)
    }

    private func pans(on view: UIView) -> [UIPanGestureRecognizer] {
        (view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
    }

    func testTouchSurfacePanIsIndirectAndFollowsEnabled() throws {
        let v = view(enabled: false)
        let pan = try XCTUnwrap(pans(on: v).first)
        XCTAssertEqual(pan.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirect.rawValue)],
                       "only the remote's touch surface, never a direct touch")
        XCTAssertFalse(pan.isEnabled)
        v.isInputEnabled = true
        XCTAssertTrue(pan.isEnabled)
    }

    func testPanelSwipeUpRecogniserLivesOnTheWindowWhilePanelOpen() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let v = view(enabled: true)
        window.addSubview(v)
        defer { v.removeFromSuperview() }
        // The window's recogniser sees touches that go to the panel's
        // focused button; this view's own doesn't.
        let windowPan = try XCTUnwrap(pans(on: window).first { $0.cancelsTouchesInView == false })
        XCTAssertEqual(windowPan.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirect.rawValue)])
        XCTAssertFalse(windowPan.isEnabled, "off while no panel is open")
        v.panelOpen = true
        XCTAssertTrue(windowPan.isEnabled)
        v.panelOpen = false
        XCTAssertFalse(windowPan.isEnabled)
        XCTAssertTrue(windowPan.delegate === v)
        XCTAssertTrue(v.gestureRecognizer(windowPan, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()),
                      "alongside the focus engine's own reading of the swipe, never instead of it")
    }

    func testMovingToAnotherWindowTakesTheRecogniserAlong() throws {
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let v = view(enabled: true)
        first.addSubview(v)
        let firstCount = pans(on: first).count
        second.addSubview(v)
        XCTAssertEqual(pans(on: first).count, firstCount - 1)
        XCTAssertEqual(pans(on: second).filter { $0.cancelsTouchesInView == false }.count, 1)
        v.removeFromSuperview()
    }

    // MARK: Menu, step by step

    private func menu(panelOpen: Bool = false, hasError: Bool = false, scrubbing: Bool = false,
                      hasReturnPoint: Bool = false, upNextShowing: Bool = false,
                      controlsVisible: Bool = false, paused: Bool = false) -> RemoteRules.MenuStep {
        RemoteRules.menuStep(panelOpen: panelOpen, hasError: hasError, scrubbing: scrubbing, hasReturnPoint: hasReturnPoint,
                             upNextShowing: upNextShowing, controlsVisible: controlsVisible, paused: paused)
    }

    func testMenuStepsBackOneThingAtATime() {
        // Everything at once: the panel goes first.
        XCTAssertEqual(menu(panelOpen: true, hasError: true, scrubbing: true, hasReturnPoint: true,
                            upNextShowing: true, controlsVisible: true), .closePanel)
        XCTAssertEqual(menu(hasError: true, scrubbing: true, hasReturnPoint: true), .stopOnError)
        XCTAssertEqual(menu(scrubbing: true, hasReturnPoint: true, upNextShowing: true), .cancelScrub)
        XCTAssertEqual(menu(hasReturnPoint: true, upNextShowing: true, controlsVisible: true), .returnToPoint)
        XCTAssertEqual(menu(upNextShowing: true, controlsVisible: true), .cancelAutoplay)
        XCTAssertEqual(menu(controlsVisible: true, paused: false), .hideControls)
        XCTAssertEqual(menu(controlsVisible: false), .stop)
    }

    func testMenuWhilePausedWithTheBarUpLeavesThePlayer() {
        // Paused, the bar never hides by itself, so Menu doesn't spend a
        // press hiding it: out it goes.
        XCTAssertEqual(menu(controlsVisible: true, paused: true), .stop)
    }

    // MARK: Select and Down

    func testSelectPriorities() {
        XCTAssertEqual(RemoteRules.selectStep(scrubbing: true, upNextShowing: true, segmentActive: true), .commitScrub)
        XCTAssertEqual(RemoteRules.selectStep(scrubbing: false, upNextShowing: true, segmentActive: true), .playNextNow)
        XCTAssertEqual(RemoteRules.selectStep(scrubbing: false, upNextShowing: false, segmentActive: true), .skipSegment,
                       "Skip Intro holds the centre click while an intro plays")
        XCTAssertEqual(RemoteRules.selectStep(scrubbing: false, upNextShowing: false, segmentActive: false), .togglePlayPause)
    }

    func testDownOverAWaitingScrubDoesNotOpenThePanel() {
        // Regression (f6b43c9 "tvOS player: … scrub and panel fixes"): a click
        // down with a scrub waiting for its click opened the panel over it.
        XCTAssertEqual(RemoteRules.downStep(isLive: false, scrubbing: true), .keepScrub)
        XCTAssertEqual(RemoteRules.downStep(isLive: false, scrubbing: false), .openPanel)
        XCTAssertEqual(RemoteRules.downStep(isLive: true, scrubbing: false), .previousChannel)
    }

    // MARK: Swipes

    func testVerticalSwipes() {
        XCTAssertEqual(RemoteRules.swipe(CGPoint(x: 0, y: 400)), .down)
        XCTAssertEqual(RemoteRules.swipe(CGPoint(x: 0, y: -400)), .up)
        XCTAssertEqual(RemoteRules.swipe(CGPoint(x: 0, y: 60)), .none, "60 points is not yet a swipe")
        XCTAssertEqual(RemoteRules.swipe(CGPoint(x: 0, y: 61)), .down)
        XCTAssertEqual(RemoteRules.swipe(CGPoint(x: 100, y: 120)), .none, "a diagonal is not vertical enough")
        XCTAssertEqual(RemoteRules.swipe(CGPoint(x: 100, y: 131)), .down)
        XCTAssertEqual(RemoteRules.swipe(CGPoint(x: 600, y: 0)), .none)
    }

    func testScrubStartsOnlyPausedAndSideways() {
        // Regression (17206fe): "Scrubbing only while paused … Playing, a
        // swipe moves nothing; the edge clicks skip."
        let sideways = CGPoint(x: 40, y: 5)
        XCTAssertTrue(RemoteRules.startsScrub(sideways, paused: true, canScrub: true))
        XCTAssertFalse(RemoteRules.startsScrub(sideways, paused: false, canScrub: true))
        XCTAssertFalse(RemoteRules.startsScrub(sideways, paused: true, canScrub: false))
        XCTAssertFalse(RemoteRules.startsScrub(CGPoint(x: 24, y: 0), paused: true, canScrub: true), "a resting thumb")
        XCTAssertFalse(RemoteRules.startsScrub(CGPoint(x: 40, y: 50), paused: true, canScrub: true), "mostly vertical")
        XCTAssertTrue(RemoteRules.startsScrub(CGPoint(x: -40, y: 0), paused: true, canScrub: true), "leftwards too")
    }

    func testPanelSwipeUp() {
        XCTAssertTrue(RemoteRules.isPanelSwipeUp(CGPoint(x: 0, y: -61)))
        XCTAssertFalse(RemoteRules.isPanelSwipeUp(CGPoint(x: 0, y: -60)))
        XCTAssertFalse(RemoteRules.isPanelSwipeUp(CGPoint(x: 0, y: 200)))
        XCTAssertFalse(RemoteRules.isPanelSwipeUp(CGPoint(x: 100, y: -120)))
    }

    func testScrubRateIsAnEighthOfTheItemWithAMinuteFloor() {
        // Regression (17206fe): it was a quarter, and a two-hour film moved
        // half an hour for one swipe. A full swipe is 1000 points.
        XCTAssertEqual(RemoteRules.secondsPerPoint(duration: 7200) * 1000, 900, accuracy: 0.001)
        XCTAssertEqual(RemoteRules.secondsPerPoint(duration: 1200) * 1000, 150, accuracy: 0.001)
        XCTAssertEqual(RemoteRules.secondsPerPoint(duration: 45) * 1000, 60, accuracy: 0.001)
        XCTAssertEqual(RemoteRules.secondsPerPoint(duration: 0) * 1000, 60, accuracy: 0.001)
    }

    func testScrubStaysInsideTheItem() {
        XCTAssertEqual(RemoteRules.clamp(-30, duration: 600), 0)
        XCTAssertEqual(RemoteRules.clamp(300, duration: 600), 300)
        XCTAssertEqual(RemoteRules.clamp(9999, duration: 600), 599, "short of the last second, which would end it")
        XCTAssertEqual(RemoteRules.clamp(10, duration: 0), 0)
    }

    func testNothingToScrubOnLiveOrWhileOpening() {
        XCTAssertTrue(RemoteRules.canScrub(isLive: false, duration: 600, isOpening: false))
        XCTAssertFalse(RemoteRules.canScrub(isLive: true, duration: 600, isOpening: false))
        XCTAssertFalse(RemoteRules.canScrub(isLive: false, duration: 0, isOpening: false))
        XCTAssertFalse(RemoteRules.canScrub(isLive: false, duration: 600, isOpening: true))
    }

    func testReturnPointOnlyAfterARealJump() {
        XCTAssertTrue(RemoteRules.leavesReturnPoint(from: 58, to: 300))
        XCTAssertTrue(RemoteRules.leavesReturnPoint(from: 300, to: 58))
        XCTAssertFalse(RemoteRules.leavesReturnPoint(from: 58, to: 58.9))
    }

    func testPanelOpensOnSyncOverTheSyncClip() {
        // Regression (bffc9e7): the clip says "Swipe down to adjust audio sync".
        XCTAssertEqual(RemoteRules.openingTab(isSyncTest: true), .sync)
        XCTAssertEqual(RemoteRules.openingTab(isSyncTest: false), .info)
    }

    // MARK: The debug hook's names

    func testPanelTabsCoverEveryPage() {
        XCTAssertEqual(PlayerTab.allCases.map(\.rawValue),
                       ["info", "channels", "audio", "subtitles", "quality", "speed", "sync", "picture"])
        for tab in PlayerTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertNotNil(UIImage(systemName: tab.symbol), "\(tab) symbol \(tab.symbol) is not an SF Symbol here")
        }
    }
}
#endif
