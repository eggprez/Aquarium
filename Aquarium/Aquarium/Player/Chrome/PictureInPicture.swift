//  Picture in Picture over the player layer, through
//  `AVPictureInPictureController`. It starts from the button in the title row
//  and, with `canStartPictureInPictureAutomaticallyFromInline`, on its own
//  when the app is swiped home while something plays. The chrome reads
//  `isPossible` before it draws the button and `isActive` for which glyph.
//
//  Only an `AVPlayerLayer` can be put in the window; when the mpv engine
//  arrives (phase 4) a stream on it hands over to AVPlayer first, as the plan
//  says.

#if os(iOS) || os(macOS)

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
                Task { @MainActor in self?.isPossible = possible }
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

    // MARK: Delegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        PlayerModel.log.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
    }

    /// The button in the floating window that means "back to the app". The
    /// player screen is still up underneath — the app never tears it down
    /// behind the window — so there is nothing to restore.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

#endif
