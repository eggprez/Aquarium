//  The Siri Remote, read directly, while the player's controls are what is in
//  charge.
//
//  SwiftUI on tvOS offers the remote's buttons (`onPlayPauseCommand`,
//  `onMoveCommand`, `onExitCommand`) but not its touch surface, and scrubbing
//  is a swipe on the touch surface. It also can't tell a click on the edge of
//  the clickpad — a ten-second jump — from a swipe, which it only sees as a
//  focus move. So while no panel is open, an invisible UIKit view holds focus
//  and reads the remote itself: presses by type, and swipes through a pan
//  recogniser on indirect touches. When a panel opens it stops accepting focus
//  and SwiftUI's focus engine takes over the panel's buttons as usual.
//
//  Two things stay with it while a panel is open. Menu, should a press ever
//  reach it: focus handed on late leaves it here, and a press passed up from
//  here would dismiss the whole player. And a swipe up, read from the window
//  because the touches go to whichever panel button has focus.

#if os(tvOS)

import SwiftUI
import UIKit

enum RemoteEvent {
    /// A click in the centre of the clickpad.
    case select
    /// A click on an edge of the clickpad, or the arrow buttons.
    case arrow(MoveCommandDirection)
    case playPause
    case menu
    /// A finger moving on the touch surface: how far since it went down, in
    /// touch-surface points, and how fast.
    case panChanged(translation: CGPoint, velocity: CGPoint)
    case panEnded(translation: CGPoint, velocity: CGPoint)
    /// A finger resting on the touch surface without moving yet.
    case touchDown
    /// With a panel open: a finger went down, and a swipe up ended.
    case panelTouchDown
    case panelSwipeUp
}

struct RemoteInput: UIViewRepresentable {
    /// Whether this holds focus and takes the remote. Off while a panel's
    /// buttons are what the remote should reach.
    var isEnabled: Bool
    /// Whether a panel is open, for the swipe up that closes it.
    var panelOpen = false
    var onEvent: (RemoteEvent) -> Void

    func makeUIView(context: Context) -> RemoteInputView {
        let view = RemoteInputView()
        view.onEvent = onEvent
        view.isInputEnabled = isEnabled
        view.panelOpen = panelOpen
        return view
    }

    func updateUIView(_ view: RemoteInputView, context: Context) {
        view.onEvent = onEvent
        view.isInputEnabled = isEnabled
        view.panelOpen = panelOpen
    }
}

final class RemoteInputView: UIView {
    var onEvent: (RemoteEvent) -> Void = { _ in }

    var isInputEnabled = false {
        didSet {
            guard isInputEnabled != oldValue else { return }
            pan.isEnabled = isInputEnabled
            // Coming back from a panel: take focus again, or the next click
            // goes nowhere. Going to one, nothing: the panel claims focus
            // itself. Asking UIKit to re-evaluate here was tried and is worse —
            // it undoes the panel's claim and then finds nothing to focus,
            // since the window's answer is the app underneath the full-screen
            // player.
            guard isInputEnabled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.setNeedsFocusUpdate()
                self?.updateFocusIfNeeded()
            }
        }
    }

    var panelOpen = false {
        didSet { panelPan.isEnabled = panelOpen }
    }

    /// On the window, not this view: with a panel open the touches go to the
    /// focused button, and only an ancestor of it sees them. Alongside the
    /// focus engine's own reading of the swipe, never instead of it.
    private lazy var panelPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panelPanned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delegate = self
        pan.isEnabled = false
        return pan
    }()

    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        return pan
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addGestureRecognizer(pan)
        pan.isEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFocused: Bool { isInputEnabled }


    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        panelPan.view?.removeGestureRecognizer(panelPan)
        newWindow?.addGestureRecognizer(panelPan)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if DEBUG
        if window != nil { RemoteDebugHook.attach(self) }
        #endif
        guard window != nil, isInputEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
    }

    // MARK: - Presses

    /// Everything this view acts on is acted on when the press ends, the way a
    /// button does, and swallowed rather than passed on — Menu passed on would
    /// dismiss the player out from under the model.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let mapped = map(press.type) else {
                unhandled.insert(press)
                continue
            }
            onEvent(mapped)
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { map($0.type) == nil }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { map($0.type) == nil }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func map(_ type: UIPress.PressType) -> RemoteEvent? {
        // See the top of the file: Menu is never passed up from here.
        if type == .menu { return .menu }
        guard isInputEnabled else { return nil }
        switch type {
        case .select: return .select
        case .playPause: return .playPause
        case .menu: return .menu
        case .leftArrow: return .arrow(.left)
        case .rightArrow: return .arrow(.right)
        case .upArrow: return .arrow(.up)
        case .downArrow: return .arrow(.down)
        default: return nil
        }
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if isInputEnabled, touches.contains(where: { $0.type == .indirect }) {
            onEvent(.touchDown)
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self)
        let velocity = pan.velocity(in: self)
        switch pan.state {
        case .began, .changed:
            onEvent(.panChanged(translation: translation, velocity: velocity))
        case .ended:
            onEvent(.panEnded(translation: translation, velocity: velocity))
        case .cancelled, .failed:
            onEvent(.panEnded(translation: .zero, velocity: .zero))
        default:
            break
        }
    }

    @objc private func panelPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            onEvent(.panelTouchDown)
        case .ended:
            let t = pan.translation(in: pan.view)
            if t.y < -60, abs(t.y) > abs(t.x) * 1.3 { onEvent(.panelSwipeUp) }
        default:
            break
        }
    }
}

extension RemoteInputView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

#endif
