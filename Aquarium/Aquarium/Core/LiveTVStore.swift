//  The channel line-up and its schedule, held once for the whole app.
//
//  Live TV is the one screen whose data costs real time to produce: a custom
//  M3U/XMLTV source is two downloads, and the guide half of it is an XML file
//  that runs to tens of megabytes covering a week of a few hundred channels.
//  Left in the view, all of that started when the tab was tapped — so the tab
//  was tapped and then nothing happened for a while, every time.
//
//  Here instead, it can be started the moment the app opens and be sitting in
//  memory by the time anyone asks for it, and switching away from the tab and
//  back costs nothing at all. See `warm()`, LiveTVView and IPTVSource.

import Foundation
import Observation

@MainActor
@Observable
final class LiveTVStore {
    static let shared = LiveTVStore()

    private(set) var channels: [BaseItem] = []
    private(set) var programmes: [BaseItem] = []
    /// `programmes` by channel id, in airtime order — what the guide's
    /// queries are answered from.
    private var programmesByChannel: [String: [BaseItem]] = [:]
    private(set) var error: String?
    private(set) var isLoading = false

    /// What the last custom-source load actually produced. Shown in Settings,
    /// where "the playlist loaded, and this many of its channels named a logo"
    /// is the difference between a broken app and a playlist that simply
    /// doesn't carry artwork.
    struct Summary: Sendable, Equatable {
        var channels: Int
        var withLogos: Int
        var programmes: Int
        var at: Date
    }
    private(set) var summary: Summary?

    /// The configuration the data in hand belongs to — source, URLs, and the
    /// manual-refresh counter. Anything that changes it invalidates the lot.
    private var loadedKey: String?
    /// When the data in hand was fetched. A Jellyfin channel list carries
    /// what is on *now*, which stops being true within the hour.
    private var loadedAt: Date?
    private var running: (key: String, task: Task<Void, Never>)?

    private init() {}

    /// Everything that decides what a load would return.
    static var key: String {
        let prefs = Preferences.shared
        // Jellyfin's channels belong to a server and a user; without them in
        // the key, signing in somewhere else showed the old server's line-up.
        // A custom playlist belongs to neither, and is not re-downloaded on
        // account of a sign-in.
        let account = prefs.liveTVSource == .custom
            ? ""
            : prefs.session.map { "\($0.server)|\($0.userId)" } ?? ""
        return [
            prefs.liveTVSource.rawValue,
            prefs.iptvPlaylistURL,
            prefs.iptvGuideURL,
            String(prefs.liveTVRefreshToken),
            account,
        ].joined(separator: "|")
    }

    /// How long a Jellyfin channel list's "on now" is trusted before the Live
    /// TV screen asks again on appearing.
    private static let jellyfinStaleAfter: TimeInterval = 10 * 60

    /// Forget everything — sign-out, or a session that expired. The next
    /// load starts from nothing rather than from the last account's channels.
    /// A custom playlist is kept: it belongs to this device's settings, not to
    /// the account, and is the expensive one to fetch again.
    func reset() {
        guard Preferences.shared.liveTVSource != .custom else { return }
        running?.task.cancel()
        running = nil
        isLoading = false
        loadedKey = nil
        loadedAt = nil
        channels = []
        programmes = []
        programmesByChannel = [:]
        error = nil
        summary = nil
    }

    /// Load unless this exact configuration is already in hand. What the Live
    /// TV screen calls on appearing: with the app's own warm-up already done,
    /// this returns without doing anything and the guide draws immediately.
    func ensureLoaded(key: String? = nil) async {
        let key = key ?? Self.key
        let stale = Preferences.shared.liveTVSource != .custom
            && (loadedAt.map { Date().timeIntervalSince($0) > Self.jellyfinStaleAfter } ?? true)
        if loadedKey == key, error == nil, !channels.isEmpty, !stale { return }
        await load(key: key)
    }

    /// Fetch again regardless — the auto-refresh timer, and coming back from a
    /// channel that has been playing for a while.
    func refresh(key: String? = nil) async {
        let key = key ?? Self.key
        loadedKey = nil
        await load(key: key)
    }

    /// What a channel closing asks for.
    ///
    /// A Jellyfin channel list carries what is on right now, so it is worth
    /// asking again after watching something. A custom playlist doesn't — its
    /// schedule came down whole with the playlist and is refreshed on its own
    /// timer — and re-downloading a guide that can run to tens of megabytes
    /// every time a channel is closed is the stall this whole class exists to
    /// remove.
    func refreshAfterPlayback() async {
        guard Preferences.shared.liveTVSource != .custom else { return }
        await refresh()
    }

    /// Start the first load in the background, without waiting for it.
    ///
    /// Called as the app opens, and only for the custom source: that is the
    /// one that costs real time, and it needs neither a server nor a session
    /// to go ahead. Jellyfin's own channels are a single request to a server
    /// that may not even have Live TV configured, so they stay where they
    /// were — asked for when the tab is opened.
    func warm() {
        guard Preferences.shared.liveTVSource == .custom else { return }
        Task { await ensureLoaded() }
    }

    private func load(key: String) async {
        // A second caller for the same configuration waits on the first rather
        // than starting a rival fetch — the warm-up at launch and the tab being
        // tapped a moment later are exactly that pair.
        if let running, running.key == key {
            await running.task.value
            return
        }
        running?.task.cancel()
        isLoading = true
        let task = Task { await self.perform(key: key) }
        running = (key, task)
        await task.value
        if running?.key == key {
            running = nil
            isLoading = false
        }
    }

    private func perform(key: String) async {
        let prefs = Preferences.shared
        if prefs.liveTVSource == .custom {
            do {
                let loaded = try await IPTVSource.load(
                    playlistURLString: prefs.iptvPlaylistURL,
                    guideURLString: prefs.iptvGuideURL
                )
                guard !Task.isCancelled else { return }
                channels = loaded.channels
                programmes = loaded.programmes
                programmesByChannel = loaded.byChannel
                error = nil
                loadedKey = key
                loadedAt = Date()
                summary = Summary(
                    channels: loaded.channels.count,
                    withLogos: loaded.channels.filter { ($0.ExternalLogoURL ?? "").isEmpty == false }.count,
                    programmes: loaded.programmes.count,
                    at: Date()
                )
            } catch {
                guard !Task.isCancelled else { return }
                channels = []
                programmes = []
                programmesByChannel = [:]
                summary = nil
                self.error = error.localizedDescription
            }
            return
        }

        do {
            let fetched = try await JellyfinClient.shared.channels()
            guard !Task.isCancelled else { return }
            channels = fetched
            programmes = []
            programmesByChannel = [:]
            error = nil
            loadedKey = key
            loadedAt = Date()
            summary = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// The custom source's schedule, filtered to a set of channels and a time
    /// window — the guide's `programsProvider`. Nil for Jellyfin channels,
    /// which have a server to ask instead.
    ///
    /// `@Sendable` and built from a plain array copy so the filtering runs
    /// wherever the guide's task runs rather than on the main actor: a real
    /// XMLTV feed is a few thousand programmes, each asked for its start and
    /// end, and that ran between the tab being tapped and the screen appearing.
    var programsProvider: (@Sendable ([String], Date, Date) async throws -> [BaseItem])? {
        guard Preferences.shared.liveTVSource == .custom else { return nil }
        let byChannel = programmesByChannel
        return { ids, start, end in
            await Self.programmes(in: byChannel, channels: ids, from: start, to: end)
        }
    }

    /// The filter itself, `@concurrent` because the closure above is an
    /// async function type, and under this project's approachable concurrency
    /// those run on whatever actor calls them — the guide's task, which is the
    /// main one.
    @concurrent
    private nonisolated static func programmes(
        in byChannel: [String: [BaseItem]], channels ids: [String], from start: Date, to end: Date
    ) async -> [BaseItem] {
        var out: [BaseItem] = []
        for id in Set(ids) {
            for item in byChannel[id] ?? [] {
                guard let programStart = item.programStart, let programEnd = item.programEnd else { continue }
                // In airtime order, so nothing after this one can be in the window.
                if programStart >= end { break }
                if programEnd > start { out.append(item) }
            }
        }
        return out
    }
}
