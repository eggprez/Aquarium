//  Debug builds only: the Siri Remote, driven from the Mac.
//
//  The Simulator can't be given remote presses or touch-surface swipes by a
//  script, so a debug build listens for Darwin notifications and feeds them
//  to `RemoteInputView` as if they came from the remote:
//
//      xcrun simctl spawn booted notifyutil -p aquarium.remote.select
//
//  Names: select, playPause, menu, left, right, up, down (edge clicks), and
//  swipeLeft, swipeRight, swipeDown, swipeUp (a whole swipe, begun and
//  ended). `aquarium.debug.items` logs what Continue Watching and Next Up
//  hold, numbered, and `aquarium.debug.play.<n>` plays the nth of them — a
//  `aquarium://play` link would stop at the system's "Open in" prompt.
//  `aquarium.debug.tab.<tab>` opens the panel at that tab, and
//  `aquarium.debug.audio.next`, `.subs.next` and `.subs.off` do what the
//  panel's cards do — the focus engine takes nothing but real presses, so the
//  cards themselves can't be clicked from here.
//
//  Only the player's own view is reached this way. A panel's buttons belong to
//  the focus engine, which takes nothing but real presses.

#if os(tvOS) && DEBUG

import OSLog
import SwiftUI
import UIKit

@MainActor
enum RemoteDebugHook {
    /// The view on screen now; the player screen makes a new one each time.
    private static weak var target: RemoteInputView?
    private static var registered = false

    /// Posted with the `PlayerTab` to open, for `PlayerScreen`.
    static let openTab = Notification.Name("RemoteDebugHook.openTab")

    private static let names = [
        "select", "playPause", "menu", "left", "right", "up", "down",
        "swipeLeft", "swipeRight", "swipeDown", "swipeUp", "panelSwipeUp",
    ]

    static func attach(_ view: RemoteInputView) {
        target = view
    }

    static func start() {
        guard !registered else { return }
        registered = true
        PlayerModel.log.notice("remote hook listening")
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let debug = ["debug.items", "debug.state", "debug.nearEnd", "debug.channel", "debug.audio.next", "debug.subs.next", "debug.subs.off", "debug.syncTest"]
            + (0..<16).map { "debug.play.\($0)" }
            + (PlayerTab.allCases.map(\.rawValue) + ["none"]).map { "debug.tab.\($0)" }
        for name in names + debug {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    guard let raw = name?.rawValue as String? else { return }
                    Task { @MainActor in RemoteDebugHook.received(raw) }
                },
                "aquarium.\(name.hasPrefix("debug.") ? name : "remote." + name)" as CFString,
                nil, .deliverImmediately
            )
        }
    }

    private static func received(_ full: String) {
        PlayerModel.log.notice("remote hook received \(full, privacy: .public)")
        if full == "aquarium.debug.items" {
            Task { await logItems() }
            return
        }
        if full.hasPrefix("aquarium.debug.play."), let n = Int(full.split(separator: ".").last ?? "") {
            Task {
                // The list as last logged: Continue Watching reorders itself
                // every time something plays.
                if listed.isEmpty { listed = await candidates() }
                guard n < listed.count else { return }
                await AppModel.shared.play(itemId: listed[n].Id)
            }
            return
        }
        if full.hasPrefix("aquarium.debug.tab.") {
            let tab = PlayerTab(rawValue: String(full.dropFirst("aquarium.debug.tab.".count)))
            NotificationCenter.default.post(name: openTab, object: tab)
            return
        }
        let player = PlayerModel.shared
        switch full {
        case "aquarium.debug.audio.next":
            let options = player.audioOptions
            if let i = options.firstIndex(where: { $0.id == player.selectedAudioOption }), options.count > 1 {
                player.selectAudio(options[(i + 1) % options.count])
            }
            return
        case "aquarium.debug.subs.next":
            let options = player.subtitleOptions
            let i = options.firstIndex { $0.id == player.selectedSubtitleOption }
            if !options.isEmpty { player.selectSubtitles(options[i.map { ($0 + 1) % options.count } ?? 0]) }
            return
        case "aquarium.debug.state":
            let focused = target?.window?.windowScene?.focusSystem?.focusedItem
            PlayerModel.log.notice("focus: \(focused.map { String(describing: type(of: $0)) + " " + String(describing: $0).prefix(160) } ?? "nothing", privacy: .public)")
            PlayerModel.log.notice("state: active=\(player.isActive) opening=\(player.isOpening) buffering=\(player.isBuffering) paused=\(player.isPaused) position=\(player.position, format: .fixed(precision: 1)) duration=\(player.duration, format: .fixed(precision: 1)) error=\(player.errorMessage ?? "none", privacy: .public) delay=\(player.audioDelayMilliseconds)ms applied=\(Int((player.appliedAudioDelay * 1000).rounded()))ms mpv=\(Int((player.debugEngineAudioDelay * 1000).rounded()))ms avsync=\(player.debugAVSync, privacy: .public)s")
            return
        case "aquarium.debug.channel":
            // The guide's first channel, the way the guide tunes it.
            Task {
                await LiveTVStore.shared.ensureLoaded()
                guard let first = LiveTVStore.shared.channels.first else {
                    PlayerModel.log.notice("no channels in the guide")
                    return
                }
                PlayerModel.log.notice("channels: \(LiveTVStore.shared.channels.count)")
                player.playChannel(first)
            }
            return
        case "aquarium.debug.syncTest":
            Task { await player.playSyncTest() }
            return
        case "aquarium.debug.nearEnd":
            player.seek(to: max(0, player.duration - 75))
            return
        case "aquarium.debug.subs.off":
            player.selectSubtitles(nil)
            return
        default:
            break
        }
        let name = String(full.dropFirst("aquarium.remote.".count))
        // Menu and the panel's swipe up reach the view with a panel open too.
        let always = name == "menu" || name == "panelSwipeUp"
        guard let view = target, view.window != nil, view.isInputEnabled || always else {
            PlayerModel.log.notice("remote hook: \(name, privacy: .public) ignored, no player input")
            return
        }
        PlayerModel.log.notice("remote hook: \(name, privacy: .public)")
        switch name {
        case "select": view.onEvent(.select)
        case "playPause": view.onEvent(.playPause)
        case "menu": view.onEvent(.menu)
        case "left": view.onEvent(.arrow(.left))
        case "right": view.onEvent(.arrow(.right))
        case "up": view.onEvent(.arrow(.up))
        case "down": view.onEvent(.arrow(.down))
        case "swipeLeft": Task { await swipe(view, dx: -600, dy: 0) }
        case "swipeRight": Task { await swipe(view, dx: 600, dy: 0) }
        case "swipeDown": Task { await swipe(view, dx: 0, dy: 400) }
        case "swipeUp": Task { await swipe(view, dx: 0, dy: -400) }
        case "panelSwipeUp":
            view.onEvent(.panelTouchDown)
            view.onEvent(.panelSwipeUp)
        default: break
        }
    }

    /// A finger going down, travelling in ten steps, and lifting.
    private static func swipe(_ view: RemoteInputView, dx: CGFloat, dy: CGFloat) async {
        view.onEvent(.touchDown)
        var last = CGPoint.zero
        for step in 1...10 {
            last = CGPoint(x: dx * CGFloat(step) / 10, y: dy * CGFloat(step) / 10)
            view.onEvent(.panChanged(translation: last, velocity: .zero))
            try? await Task.sleep(for: .milliseconds(20))
        }
        view.onEvent(.panEnded(translation: last, velocity: .zero))
    }

    /// Continue Watching, then Next Up: sixteen things that certainly play.
    private static func candidates() async -> [BaseItem] {
        let client = JellyfinClient.shared
        let resume = (try? await client.resume()) ?? []
        let nextUp = (try? await client.nextUp()) ?? []
        return Array(resume.prefix(8) + nextUp.prefix(8))
    }

    /// What `debug.items` last logged, which `debug.play.<n>` indexes.
    private static var listed: [BaseItem] = []

    private static func logItems() async {
        listed = await candidates()
        for (n, item) in listed.enumerated() {
            PlayerModel.log.notice("item \(n) \(item.Id, privacy: .public) \(item.title, privacy: .public)")
        }
    }
}

#endif
