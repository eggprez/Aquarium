//  Which way round the phone is allowed to be.
//
//  Every screen in this app is a column you scroll down — a grid of posters, a
//  list of episodes, a page of settings — and a phone held sideways shows less
//  of all of them, with the tab bar eating what is left. So the shell is
//  portrait and stays portrait.
//
//  Two things are genuinely wider than they are tall and ask for the turn: the
//  TV guide, which is hours across as well as channels down, and the player,
//  which is what a phone gets turned sideways *for*. Each says so for itself
//  with `allowsLandscape()`, and the lock goes back on when it leaves.
//
//  iPad and Mac are untouched: a window that is already landscape has nothing
//  to be locked out of.

import SwiftUI

#if os(iOS)
import UIKit

@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    /// How many screens on show right now want the turn. A count rather than a
    /// flag because they nest: opening a channel from the guide puts the
    /// player on top of it, and the player closing must not take the guide's
    /// permission away with it.
    private var wanting = 0

    /// The mask UIKit was last actually asked for, and whether a request is
    /// already queued. Both exist for the same reason — see `scheduleApply`.
    private var lastRequested: UIInterfaceOrientationMask?
    private var pendingApply: Task<Void, Never>?
    /// Waiting for a scene to become active — see `apply`.
    private var activationObserver: NSObjectProtocol?

    private init() {}

    /// What UIKit is told when it asks the delegate. A phone is portrait unless
    /// something on screen has asked otherwise; anything larger was never
    /// locked.
    var mask: UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        return wanting > 0 ? .allButUpsideDown : .portrait
    }

    func allowLandscape() {
        wanting += 1
        scheduleApply()
    }

    func releaseLandscape() {
        wanting = max(0, wanting - 1)
        scheduleApply()
    }

    /// Tell UIKit what the count now means — but not this instant.
    ///
    /// A view holding the permission can be torn down and rebuilt *by the
    /// rotation itself*: the layout changes, SwiftUI rebuilds that part of the
    /// tree, and the guide's `onDisappear` and `onAppear` arrive one after the
    /// other in the middle of the turn. Applied immediately, the disappear half
    /// asked UIKit for portrait while the phone was halfway into landscape —
    /// which is the rotation that starts, snaps back, and leaves the screen
    /// stuck showing a layout for an orientation it is no longer in. Deferred,
    /// the pair cancels out and UIKit is never told anything happened.
    ///
    /// The delay is also why `lastRequested` is worth keeping: with the count
    /// settling back to where it started there is nothing to ask for, and a
    /// redundant `requestGeometryUpdate` mid-rotation is exactly the disruption
    /// this is avoiding.
    private func scheduleApply() {
        pendingApply?.cancel()
        pendingApply = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.pendingApply = nil
            self.apply()
        }
    }

    /// Asking for the mask again is not enough on its own: UIKit only re-reads
    /// it when something tells it to, so leaving the guide would leave the
    /// phone sideways until it was physically turned back. The geometry update
    /// is what actually rotates it, and the second call is what makes UIKit ask
    /// the delegate again rather than trusting what it last heard.
    private func apply() {
        let wanted = mask
        guard wanted != lastRequested else { return }
        // Active first; an inactive one (a notification pulled down, the
        // app switcher half-open) will do. With neither — the request came
        // while the app was in the background — it waits for a scene to come
        // back rather than being dropped, which left the phone in whatever
        // orientation it had until something else asked.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
        else {
            applyWhenActive()
            return
        }
        lastRequested = wanted
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: wanted))
    }

    /// Try again the next time a scene is activated. Once: the observer goes
    /// as soon as it fires.
    private func applyWhenActive() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let lock = OrientationLock.shared
                if let observer = lock.activationObserver {
                    NotificationCenter.default.removeObserver(observer)
                    lock.activationObserver = nil
                }
                lock.apply()
            }
        }
    }
}

/// Holds the phone's permission to turn sideways for as long as the view it is
/// attached to is on screen.
///
/// The flag is not belt and braces: a tab bar sends `onAppear` again when you
/// come back to a tab it never told to disappear, and a permission taken twice
/// and given back once is a phone that stays free to rotate for the rest of the
/// session. One view, one hold.
private struct AllowsLandscape: ViewModifier {
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !holding else { return }
                holding = true
                OrientationLock.shared.allowLandscape()
            }
            .onDisappear {
                guard holding else { return }
                holding = false
                OrientationLock.shared.releaseLandscape()
            }
    }
}
#endif

extension View {
    /// Marks a screen that is worth turning the phone for. Nothing anywhere
    /// else — see `OrientationLock`.
    @ViewBuilder
    func allowsLandscape() -> some View {
        #if os(iOS)
        modifier(AllowsLandscape())
        #else
        self
        #endif
    }
}
