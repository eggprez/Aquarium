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
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.watchrelay
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.channel
//      xcrun simctl spawn "iPhone Duo" notifyutil -p aquarium.debug.channel.next
//
//  `subs.next`, `subs.off`, `audio.next` step through the player's menus and
//  `subs.state`, `audio.state` log them; `quality.720` and `quality.auto` pick a quality.
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
    private static let names = ["openurl", "stop", "browse", "watchrelay", "channel", "channel.next", "channel.prev", "subs.next", "subs.off", "subs.state", "audio.next", "audio.state",
        "quality.720", "quality.auto",
    ]

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
        case "aquarium.debug.watchrelay":
            // Three rows as a bad night leaves them, for the Transfers page:
            // a paired simulator never finishes a send, so there is no
            // honest way to get one there.
            WatchLink.shared.debugSeedRelayRows()
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
        case "aquarium.debug.audio.next":
            let player = PlayerModel.shared
            let options = player.audioOptions
            if let i = options.firstIndex(where: { $0.id == player.selectedAudioOption }), options.count > 1 {
                player.selectAudio(options[(i + 1) % options.count])
            }
        case "aquarium.debug.audio.state":
            let player = PlayerModel.shared
            let list = player.audioOptions.map {
                "[server \($0.serverIndex.map(String.init) ?? "-") engine \($0.avIndex.map(String.init) ?? "-") \($0.label)]"
            }.joined(separator: " ")
            let selected = player.audioOptions.first { $0.id == player.selectedAudioOption }?.label ?? "none"
            PlayerModel.log.notice("audio: selected \(selected, privacy: .public) of \(list, privacy: .public)")
        case "aquarium.debug.quality.720":
            Task { await PlayerModel.shared.chooseQuality(.stream(4_000_000)) }
        case "aquarium.debug.quality.auto":
            Task { await PlayerModel.shared.chooseQuality(.auto) }
        case "aquarium.debug.subs.next":
            let player = PlayerModel.shared
            let options = player.subtitleOptions
            let i = options.firstIndex { $0.id == player.selectedSubtitleOption }
            if !options.isEmpty { player.selectSubtitles(options[i.map { ($0 + 1) % options.count } ?? 0]) }
        case "aquarium.debug.subs.off":
            PlayerModel.shared.selectSubtitles(nil)
        case "aquarium.debug.subs.state":
            let player = PlayerModel.shared
            let list = player.subtitleOptions.map {
                "[server \($0.serverIndex.map(String.init) ?? "-") engine \($0.avIndex.map(String.init) ?? "-") \($0.label)]"
            }.joined(separator: " ")
            let selected = player.subtitleOptions.first { $0.id == player.selectedSubtitleOption }?.label ?? "none"
            PlayerModel.log.notice("subtitles: selected \(selected, privacy: .public) of \(list, privacy: .public); transcoding \(player.isTranscoding)")
            let engineTracks = player.tracks.filter { $0.kind == .subtitle }.map {
                "[\($0.id) file \($0.fileIndex.map(String.init) ?? "-") \($0.title ?? "") / \($0.manifestName ?? "") \($0.isSelected ? "on" : "")]"
            }.joined(separator: " ")
            let query = (player.currentStreamURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? [])
                .filter { !["apikey", "api_key"].contains($0.name.lowercased()) }
                .map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
            PlayerModel.log.notice("subtitles: engine \(engineTracks, privacy: .public); \(player.currentStreamURL?.lastPathComponent ?? "", privacy: .public)?\(query, privacy: .public)")
        default:
            break
        }
    }
}
#endif
