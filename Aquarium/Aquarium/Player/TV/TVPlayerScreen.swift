//  The Apple TV player's input layer: the Siri Remote, read into the shared
//  chrome. Everything on screen is `PlayerChrome` and the components under
//  `Player/Chrome/`, drawn with the television's `PlayerMetrics`; this file is
//  only how the remote drives them.
//
//  The remote works the way it does in Apple's own apps:
//
//  - click the centre to pause or play, and to bring up the bar;
//  - click the left or right edge to go back or forward ten seconds;
//  - paused, swipe left or right to scrub, with a thumbnail of where
//    you'll land, then click to jump there or press Menu to go back. Only
//    paused: playing, a swipe moves nothing, so a thumb resting on the
//    remote or a swipe meant for the panel can't throw the film somewhere
//    else — the edge clicks are how to move while it plays. After a jump,
//    Menu returns to where the playhead was, for as long as the bar is up;
//  - each click left or right shows how far it has gone, run together;
//  - swipe down for the panel (Info, Audio, Subtitles, Quality, Speed, Sync,
//    Picture); Menu, or a swipe up from its tabs, puts it away again;
//  - on a channel, click the top or bottom edge to change channel;
//  - Menu steps back: the panel away, out of a scrub, then the bar away,
//    then out.
//
//  While the bar is up with nothing else open, `RemoteInput` holds focus and
//  reads the remote itself — see there for why. Menu is the exception: it
//  arrives as SwiftUI's exit command, below. A panel or the error card takes
//  focus from it, and SwiftUI's focus engine drives those as usual.

#if os(tvOS)

import SwiftUI

/// Applied to the chrome by `PlayerChrome`: `RemoteInput` behind it, and the
/// play/pause and exit commands on it, so a Menu press with the panel open
/// reaches the panel's own handler first.
struct PlayerRemoteDriver: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    let chrome: PlayerChromeState
    /// A touch on the remote: keeps the controls up a while longer.
    let onInteract: () -> Void
    let onHide: () -> Void

    /// Whether the finger now on the remote went down with focus on the
    /// panel's tabs.
    @State private var swipeBeganOnTabs = false
    /// Where the scrubber was when the current swipe began.
    @State private var scrubAnchor: Double = 0
    /// How far the current swipe had gone when the scrub began: the scrub
    /// moves from there, not from where the finger went down.
    @State private var scrubStartX: Double = 0
    /// Where the playhead was when the scrub began.
    @State private var scrubOrigin: Double = 0
    @State private var panning = false

    func body(content: Content) -> some View {
        content
            .background {
                RemoteInput(isEnabled: remoteInCharge, panelOpen: chrome.panelOpen, onEvent: handle)
                    .ignoresSafeArea()
            }
            .onPlayPauseCommand { player.togglePlayPause() }
            // Menu comes this way rather than through `RemoteInput`: the
            // full-screen cover the player sits in closes on a Menu press
            // unless a handler on the SwiftUI side claims it, and swallowing
            // the press in UIKit was found not to stop that. With the panel
            // open its own handler, nearer the focused button, gets there
            // first.
            .onExitCommand { handle(.menu) }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: RemoteDebugHook.openTab)) {
                chrome.panel = $0.object as? PlayerTab
            }
            #endif
    }

    /// The remote goes to `RemoteInput` unless something focusable needs it.
    private var remoteInCharge: Bool {
        !chrome.panelOpen && player.errorMessage == nil
    }

    // MARK: - The remote

    private func handle(_ event: RemoteEvent) {
        switch event {
        case .touchDown:
            onInteract()

        case .select:
            if let scrub = chrome.scrub {
                commit(scrub)
            } else if player.shouldShowUpNext {
                Task { await player.playNextNow() }
            } else if player.activeSegment != nil {
                player.skipSegment()
            } else {
                player.togglePlayPause()
                onInteract()
            }

        case .playPause:
            if let scrub = chrome.scrub {
                commit(scrub)
                player.resume()
            } else {
                player.togglePlayPause()
                onInteract()
            }

        case .menu:
            if chrome.panelOpen {
                chrome.panel = nil
            } else if player.errorMessage != nil {
                player.stop(reason: "error card")
            } else if chrome.scrub != nil {
                chrome.scrub = nil
                onInteract()
            } else if let point = chrome.returnPoint {
                // Undo the jump: back to where the playhead was before it.
                chrome.returnPoint = nil
                player.seek(to: point)
                onInteract()
            } else if player.shouldShowUpNext {
                player.cancelAutoplay()
            } else if chrome.controlsVisible, !player.isPaused {
                onHide()
            } else {
                player.stop(reason: "menu")
            }

        case .arrow(let direction):
            arrow(direction)

        case .panelTouchDown:
            swipeBeganOnTabs = chrome.panelTabsFocused

        case .panelSwipeUp:
            // From the tabs only: from the choices below them, a swipe up is
            // the focus engine's, back to the tabs.
            if chrome.panelOpen, swipeBeganOnTabs { chrome.panel = nil }

        case .panChanged(let translation, _):
            if !panning {
                panning = true
                scrubAnchor = chrome.scrub ?? player.position
                scrubStartX = 0
            }
            onInteract()
            if chrome.scrub == nil {
                // Paused only, and a short swipe that is mostly sideways.
                // Playing, nothing: the film was too easy to throw with a
                // swipe meant for something else, and the edge clicks skip.
                let x = abs(translation.x), y = abs(translation.y)
                guard player.isPaused, x > 24 && x > y, canScrub else { return }
                chrome.scrub = player.position
                scrubAnchor = player.position
                scrubOrigin = player.position
                scrubStartX = Double(translation.x)
            }
            chrome.scrub = clamp(scrubAnchor + (Double(translation.x) - scrubStartX) * secondsPerPoint)

        case .panEnded(let translation, _):
            panning = false
            guard chrome.scrub == nil else {
                // The scrubber stays where the swipe left it, waiting for a
                // click; another swipe carries on from there.
                scrubAnchor = chrome.scrub ?? player.position
                return
            }
            let vertical = abs(translation.y) > abs(translation.x) * 1.3
            if vertical, translation.y > 60 {
                chrome.panel = openingTab
            } else if vertical, translation.y < -60 {
                onHide()
            }
        }
    }

    private func arrow(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            let delta = direction == .left ? -prefs.skipInterval : prefs.skipInterval
            if let scrub = chrome.scrub {
                chrome.scrub = clamp(scrub + Double(delta))
                scrubAnchor = chrome.scrub ?? scrubAnchor
            } else if canScrub {
                player.seek(by: Double(delta))
                chrome.countSkip(delta)
            }
            onInteract()
        case .up:
            if player.isLive { player.switchChannel(by: 1) }
            onInteract()
        case .down:
            if player.isLive {
                player.switchChannel(by: -1)
                onInteract()
            } else if chrome.scrub != nil {
                // Not over a scrub waiting for its click, as a swipe down
                // isn't either: the panel would cover the knob, and the
                // scrub would still be armed once it was put away.
                onInteract()
            } else {
                chrome.panel = openingTab
            }
        @unknown default:
            break
        }
    }

    /// The tab a swipe or press down opens on. The sync test's picture says
    /// a swipe down adjusts the sync, so there it is Sync rather than Info.
    private var openingTab: PlayerTab { player.isSyncTest ? .sync : .info }

    private var canScrub: Bool { !player.isLive && player.duration > 0 && !player.isOpening }

    /// A full swipe across the touch surface moves an eighth of the item,
    /// never less than a minute. It was a quarter, which overshot: a
    /// two-hour film moved half an hour for one swipe.
    private var secondsPerPoint: Double { max(player.duration / 8, 60) / 1000 }

    private func clamp(_ seconds: Double) -> Double {
        min(max(0, seconds), max(0, player.duration - 1))
    }

    private func commit(_ seconds: Double) {
        if abs(seconds - scrubOrigin) > 1 { chrome.returnPoint = scrubOrigin }
        player.seek(to: seconds)
        chrome.scrub = nil
        onInteract()
    }
}

#endif
