//  Driving the iPhone app from a script, in debug builds only.
//
//  The simulator can be given a URL with `simctl openurl`, but a custom scheme
//  arrives behind the system's "Open in Aquarium?" prompt, which nothing
//  headless can press. This takes the same URL by the back door: write it to
//  the app's defaults and post a Darwin notification, and it is handed to
//  `AppModel.handle` exactly as the system would have.
//
//      xcrun simctl spawn "iPhone Duo" defaults write scottai.FellyJin debug_url "aquarium://item/<id>"
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.openurl
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.stop
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.browse
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.channel
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.channel.next
//
//  `channel` tunes the guide's first channel the way the guide does, as the
//  Apple TV's hook of the same name does; `channel.next` and `channel.prev`
//  are the buttons beside play on a channel.
//
//  The Apple TV has a fuller one of these — see Player/TV/RemoteDebugHook.swift.

#if os(iOS) && DEBUG
import Foundation
import OSLog

@MainActor
enum DebugLinkHook {
    private static var registered = false
    private static let names = ["openurl", "stop", "browse", "channel", "channel.next", "channel.prev"]

    static func start() {
        guard !registered else { return }
        registered = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in names {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    guard let raw = name?.rawValue as String? else { return }
                    Task { @MainActor in DebugLinkHook.received(raw) }
                },
                "aquarium.debug.\(name)" as CFString,
                nil, .deliverImmediately
            )
        }
        FoldState.log.notice("debug link hook listening")
    }

    private static func received(_ full: String) {
        FoldState.log.notice("debug link hook received \(full, privacy: .public)")
        switch full {
        case "aquarium.debug.openurl":
            guard let raw = UserDefaults.standard.string(forKey: "debug_url"), let url = URL(string: raw) else { return }
            // As the app's own: a play link from outside opens the page instead.
            AppModel.shared.handle(url, fromApp: true)
        case "aquarium.debug.stop":
            PlayerModel.shared.stop(reason: "debug hook")
        case "aquarium.debug.browse":
            AppModel.shared.tentBrowsing = true
        case "aquarium.debug.channel":
            Task {
                await LiveTVStore.shared.ensureLoaded()
                guard let first = LiveTVStore.shared.channels.first else {
                    PlayerModel.log.notice("no channels in the guide")
                    return
                }
                PlayerModel.shared.playChannel(first)
            }
        case "aquarium.debug.channel.next":
            PlayerModel.shared.switchChannel(by: 1)
        case "aquarium.debug.channel.prev":
            PlayerModel.shared.switchChannel(by: -1)
        default:
            break
        }
    }
}
#endif
