//  What AppKit still asks the application for on a Mac, that SwiftUI has no
//  modifier for: the Dock icon's menu, and the moment the app comes back to
//  the front.

#if os(macOS)
import AppKit
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

    /// The Dock icon's menu: what Continue Watching would lead with, then
    /// Search — the same entries the iPhone's home screen icon offers, and
    /// filled from the same place. See `AppModel.updateDockMenu`.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MainActor.assumeIsolated {
            let menu = NSMenu()
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
            return menu
        }
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
