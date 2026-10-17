//  Picture in Picture over the player layer, through
//  `AVPictureInPictureController`. It starts from the button in the title row
//  and, on an iPhone or iPad with `canStartPictureInPictureAutomaticallyFromInline`,
//  on its own when the app is swiped home while something plays. The chrome
//  reads `isPossible` before it draws the button and `isActive` for which
//  glyph.
//
//  On a Mac the picture floats in its own window and the player window
//  behind it would be a black rectangle, so the window is put away while the
//  picture is out and brought back when it returns — through the floating
//  window's "back to the app" button, its close button, or the stream ending.
//  AppKit has had the controller over an `AVPlayerLayer` since 10.15; this
//  is the behaviour `AVPlayerView`'s delegate used to carry.
//
//  Only an `AVPlayerLayer` can be put in the window: a stream on the mpv
//  engine is handed to AVPlayer first (`PlayerModel.handOverForPictureInPicture`),
//  with `startWhenPossible` starting the picture as soon as the new layer
//  plays, and goes back to mpv when the picture returns.

#if canImport(UIKit) || canImport(AppKit)

import AVKit
import Observation
import OSLog

@MainActor @Observable
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    /// Whether the system would start it right now: a video is playing on
    /// the layer and nothing else has the window.
    private(set) var isPossible = false
    private(set) var isActive = false

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    /// Start as soon as the system allows: set while a stream is being
    /// handed from mpv to AVPlayer for the picture, and given up after a
    /// while if the layer never plays.
    @ObservationIgnored private var wantsStart = false
    @ObservationIgnored private var wantsStartExpiry: Task<Void, Never>?

    #if os(macOS)
    /// Whether the player window was put away for the floating picture and
    /// owes a return.
    @ObservationIgnored private var hiddenWindow = false
    #endif

    /// Point the controller at the layer the picture is drawn on. Called
    /// once per layer; a new layer replaces the controller.
    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if let controller, controller.playerLayer === layer { return }
        observers.removeAll()
        guard let made = AVPictureInPictureController(playerLayer: layer) else { return }
        made.delegate = self
        #if os(iOS)
        made.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        controller = made
        observers = [
            made.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                Task { @MainActor in
                    guard let self else { return }
                    self.isPossible = possible
                    if possible, self.wantsStart {
                        self.wantsStart = false
                        self.wantsStartExpiry?.cancel()
                        controller.startPictureInPicture()
                    }
                }
            },
            made.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] controller, _ in
                let active = controller.isPictureInPictureActive
                Task { @MainActor in self?.isActive = active }
            },
        ]
    }

    func detach() {
        observers.removeAll()
        controller = nil
        isPossible = false
        isActive = false
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    /// Start the moment the system would allow it — once the AVPlayer layer
    /// a hand-over is building has a picture — or give up after a while.
    func startWhenPossible() {
        if let controller, controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }
        wantsStart = true
        wantsStartExpiry?.cancel()
        wantsStartExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.wantsStart = false
        }
    }

    // MARK: Delegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            #if os(macOS)
            self.putWindowAway()
            #endif
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            #if os(macOS)
            self.restoreWindow()
            #endif
            // A stream handed over for the picture goes back to mpv.
            PlayerModel.shared.pictureInPictureEnded()
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        PlayerModel.log.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
    }

    /// The button in the floating window that means "back to the app". On an
    /// iPhone the player screen is still up underneath — the app never tears
    /// it down behind the window — so there is nothing to restore; on a Mac
    /// the window comes back.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        #if os(macOS)
        Task { @MainActor in
            self.restoreWindow()
            completionHandler(true)
        }
        #else
        completionHandler(true)
        #endif
    }

    // MARK: The Mac window

    #if os(macOS)
    /// The picture is in its own floating window now. A full-screen window is
    /// left where it is — there is no hiding one gracefully.
    private func putWindowAway() {
        guard let window = PlayerMacState.shared.window, !window.styleMask.contains(.fullScreen) else { return }
        hiddenWindow = true
        window.orderOut(nil)
    }

    /// A window still hidden with a stream still playing is a player nobody
    /// can reach, so it comes back however the floating picture ended.
    private func restoreWindow() {
        guard hiddenWindow else { return }
        hiddenWindow = false
        guard let window = PlayerMacState.shared.window, PlayerModel.shared.isActive else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif
}

#endif
