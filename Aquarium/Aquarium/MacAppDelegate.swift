//  What AppKit still asks the application for on a Mac, that SwiftUI has no
//  modifier for: the Dock icon's menu, and the moment the app comes back to
//  the front.

#if os(macOS)
import AppKit
import Observation
import SwiftUI

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// When the app last asked the front page to refresh because it had just
    /// come back to the front. Set at launch so the first activation — the
    /// launch itself, whose pages are loading anyway — doesn't count.
    private var lastReturnRefresh = Date()

    /// Coming back to the app is the moment a page's answer is most likely to
    /// be stale, and a Mac never puts an app in the background the way a phone
    /// does — `scenePhase` stays `.active` from launch to quit — so the
    /// return-to-app refresh the other platforms get from the scene phase has
    /// to come from here. Once every five minutes at most: switching between
    /// this app and a browser to check a title isn't a reason to hit the
    /// server twice a minute.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date().timeIntervalSince(lastReturnRefresh) >= 5 * 60 else { return }
        lastReturnRefresh = Date()
        MainActor.assumeIsolated {
            guard JellyfinClient.shared.isSignedIn else { return }
            MacCommandRequests.shared.refresh += 1
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            watchPlayer()
            watchAlerts()
        }
    }

    /// A click on the Dock icon. AppKit only reopens an app that has no
    /// windows showing; one whose main window was closed while a title,
    /// Settings or the player stayed open got nothing. The main window comes
    /// back either way, as Music's does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard MacMainWindow.window == nil else { return true }
            MacMainWindow.show()
            return false
        }
    }

    /// The player's window, opened when playback starts from anywhere. The
    /// main window opens it too (see `RootView`), but it is the only view that
    /// did: started from a title's own window, the Item menu or the Dock menu
    /// with the main window closed, a film played with sound and no picture.
    /// Opening a `Window` scene that is already open only brings it forward,
    /// so the two never make a second one.
    @MainActor private func watchPlayer() {
        withObservationTracking {
            _ = PlayerModel.shared.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                if PlayerModel.shared.isActive, MacMainWindow.window == nil {
                    MacMainWindow.open(id: PlayerWindow.id)
                }
                self?.watchPlayer()
            }
        }
    }

    /// Errors, when there is no main window to put them on. `RootView` shows
    /// `pendingAlert` as a sheet on the main window; without one they were set
    /// and never seen. Here they are the standard alert instead.
    @MainActor private func watchAlerts() {
        withObservationTracking {
            _ = AppModel.shared.pendingAlert
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                if let alert = AppModel.shared.pendingAlert, MacMainWindow.window == nil {
                    let panel = NSAlert()
                    panel.messageText = alert.title
                    panel.informativeText = alert.message
                    panel.runModal()
                    if AppModel.shared.pendingAlert?.id == alert.id { AppModel.shared.pendingAlert = nil }
                }
                self?.watchAlerts()
            }
        }
    }

    /// The Dock icon's menu: what Continue Watching would lead with, then
    /// Search — the same entries the iPhone's home screen icon offers, and
    /// filled from the same place. See `AppModel.updateDockMenu`.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // Out through a local: NSMenu isn't Sendable, so `assumeIsolated`
        // won't return one.
        nonisolated(unsafe) let menu = NSMenu()
        MainActor.assumeIsolated {
            let items = AppModel.shared.dockMenuItems
            if !items.isEmpty {
                let heading = NSMenuItem(title: "Continue Watching", action: nil, keyEquivalent: "")
                heading.isEnabled = false
                menu.addItem(heading)
                for entry in items {
                    let title = entry.subtitle.map { "\(entry.title) — \($0)" } ?? entry.title
                    let item = NSMenuItem(title: title, action: #selector(playDockItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = entry.id
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
            let search = NSMenuItem(title: "Search", action: #selector(showSearch), keyEquivalent: "")
            search.target = self
            menu.addItem(search)
        }
        return menu
    }

    @objc private func playDockItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // The same link the iPhone's quick action and the Apple TV's top shelf
        // come in through, so one handler answers for all three.
        guard let url = URL(string: "aquarium://play/\(JellyfinClient.pathId(id))") else { return }
        Task { @MainActor in AppModel.shared.handle(url, fromApp: true) }
    }

    @objc private func showSearch() {
        Task { @MainActor in
            AppModel.shared.show(.search)
            MacCommandRequests.shared.focusSearch += 1
        }
    }
}
#endif
