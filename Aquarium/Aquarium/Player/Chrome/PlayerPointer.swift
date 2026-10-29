//  How the picture is driven by a pointer on a Mac: the one piece of the
//  chrome that is about a mouse rather than a finger, kept out of the shared
//  views as a small adapter.
//
//  - The controls follow the pointer. They come up when it moves over the
//    picture and go a couple of seconds after it stops, never while the
//    stream is paused, a panel is open or the pointer is on them — that
//    clock is `PlayerMacState`'s, read by `PlayerChrome`.
//  - Vertical scroll is volume and two fingers sideways is a scrub, the way
//    IINA and mpv behave. The scroll is taken by a local event monitor
//    because SwiftUI has no scroll-wheel modifier; it is left alone while the
//    pointer is on the controls, whose pill row scrolls sideways itself.
//  - A double-click on the picture is full screen, as in QuickTime Player;
//    that one is a SwiftUI gesture in `PlayerGestureLayer`.

#if os(macOS)

import AppKit
import SwiftUI

/// Installs the scroll-wheel monitor for the life of the player screen.
struct PlayerPointerAdapter: NSViewRepresentable {
    let player: PlayerModel
    let chrome: PlayerChromeState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view, player: player, chrome: chrome)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.install(on: view, player: player, chrome: chrome)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private weak var player: PlayerModel?
        private weak var chrome: PlayerChromeState?
        private var monitor: Any?
        /// Seconds of sideways scroll not yet turned into a seek — see
        /// `scroll`.
        private var pendingSeek: Double = 0

        func install(on view: NSView, player: PlayerModel, chrome: PlayerChromeState) {
            self.view = view
            self.player = player
            self.chrome = chrome
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                // AppKit calls a local monitor on the main thread. The result
                // goes out through a local because NSEvent isn't Sendable and
                // `assumeIsolated` won't return one.
                nonisolated(unsafe) var result: NSEvent? = event
                MainActor.assumeIsolated { result = self?.handle(event) ?? event }
                return result
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window,
                  let player, player.isActive, let chrome else { return event }
            // The adapter's own view is a point in the hosting view; what
            // counts is the window's content, which the picture fills.
            guard let content = window.contentView else { return event }
            let point = content.convert(event.locationInWindow, from: nil)
            guard content.bounds.contains(point) else { return event }
            // Over the controls the scroll is theirs: the pill row scrolls.
            guard !chrome.pointerOnControls else { return event }
            PlayerMacState.shared.noteActivity()
            return scroll(event, player: player)
        }

        /// Either physical direction is read the way the trackpad is set —
        /// fingers up is louder, fingers right is forward — and momentum is
        /// ignored so a flick does not run on.
        private func scroll(_ event: NSEvent, player: PlayerModel) -> NSEvent? {
            guard event.momentumPhase == [] else { return nil }
            if event.phase == .ended || event.phase == .cancelled {
                flushSeek(player)
                return nil
            }
            let inverted = event.isDirectionInvertedFromDevice
            let precise = event.hasPreciseScrollingDeltas
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if abs(dx) > abs(dy) {
                guard !player.isLive else { return nil }
                let forward = inverted ? dx : -dx
                // A tenth of a second a point, five seconds a wheel notch:
                // a hand's width of trackpad is about twenty seconds.
                pendingSeek += forward * (precise ? 0.1 : 5)
                // Settled in whole seconds as the gesture runs, rather than
                // one seek per event, which the player would have to queue.
                if abs(pendingSeek) >= 2 || event.phase == [] { flushSeek(player) }
                return nil
            }
            if dy != 0 {
                let up = inverted ? -dy : dy
                PlayerMacState.shared.stepVolume(player, by: up * (precise ? 0.004 : 0.05))
            }
            return nil
        }

        private func flushSeek(_ player: PlayerModel) {
            guard abs(pendingSeek) >= 0.5 else { return }
            let delta = pendingSeek
            pendingSeek = 0
            player.seek(by: delta)
        }
    }
}

#endif
