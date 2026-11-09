//  Watching a downloaded file records position and watched state locally; this
//  pushes it back to Jellyfin whenever the server is reachable. A port of
//  progress.rs.
//
//  Resume points go back as a playback-stopped report (the same call a live
//  session makes when you close the player), and watched flags go to the
//  played-items endpoint. Runs automatically at app start, on coming back to
//  the app, after local playback, and manually from the Downloads view.
//
//  A download played while the server is reachable is reported the way a
//  stream is instead — one start, progress on the beat, one stop — under a
//  session of its own: see `Session`.

import Foundation

#if !os(tvOS)

enum OfflineProgress {
    struct Result: Sendable {
        var synced: Int
        var failed: Int
        /// Records whose item the server no longer has under any id. Their
        /// watch state stays on the device and is no longer waiting to go.
        var gone = 0
    }

    @MainActor
    static var pendingCount: Int {
        DownloadManager.shared.pendingSyncCount
    }

    @discardableResult
    @MainActor
    static func sync() async -> Result {
        let client = JellyfinClient.shared
        guard client.isSignedIn else { return Result(synced: 0, failed: 0) }
        let manager = DownloadManager.shared
        let pending = manager.unsyncedRecords
        let owner = client.session?.userId
        let owed = manager.owedProgress.filter { $0.ownerUserId == nil || $0.ownerUserId == owner }
        guard !pending.isEmpty || !owed.isEmpty else { return Result(synced: 0, failed: 0) }
        guard await client.checkOnline() else {
            return Result(synced: 0, failed: pending.count + owed.count)
        }

        // Played somewhere else since it was last touched here: the server's
        // account is the newer one. Sent regardless, an episode left at ten
        // minutes offline and finished on the TV meanwhile went back to ten
        // minutes. Asked once for the lot; unanswered, everything goes as
        // before.
        let lookup = try? await client.itemsByIds(pending.map(\.itemId) + owed.map(\.itemId))
        let lastPlayed = Dictionary((lookup ?? []).map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
        func serverIsNewer(_ id: String, than changed: Date?) -> BaseItem? {
            guard let item = lastPlayed[id], let changed,
                  let played = Format.parseDate(item.userData.LastPlayedDate),
                  played.timeIntervalSince(changed) > BookProgress.clockSlack else { return nil }
            return item
        }

        var synced = 0
        var failed = 0
        var gone = 0
        for record in pending {
            if let newer = serverIsNewer(record.itemId, than: record.progressChangedAt) {
                manager.takeServerState(
                    itemId: record.itemId, positionTicks: newer.userData.positionTicks,
                    played: newer.userData.played, revision: record.progressRevision
                )
                synced += 1
                continue
            }
            // An id the lookup answered without is one the server no longer
            // has; asked anyway when the lookup itself failed.
            if lookup == nil || lastPlayed[record.itemId] != nil {
                do {
                    try await send(
                        itemId: record.itemId, played: record.played, unplayedPending: record.unplayedPending,
                        positionTicks: record.positionTicks, with: client
                    )
                    // Against what was sent: newer progress noted during the
                    // await leaves the record unsynced.
                    manager.markSynced(record.itemId, revision: record.progressRevision)
                    synced += 1
                    continue
                } catch APIError.server(let status, _) where status == 404 {
                    // Gone under this id: settled below.
                } catch {
                    failed += 1
                    continue
                }
            }
            switch await settleGone(record, with: client, manager: manager) {
            case .moved: synced += 1
            case .gone: gone += 1
            case .failed: failed += 1
            }
        }
        let current = Set(pending.map(\.itemId))
        for entry in owed {
            // An item downloaded again has a record saying something newer,
            // sent above; this would only take it back.
            if !current.contains(entry.itemId), serverIsNewer(entry.itemId, than: entry.changedAt) == nil {
                do {
                    try await send(
                        itemId: entry.itemId, played: entry.played, unplayedPending: entry.unplayedPending,
                        positionTicks: entry.positionTicks, with: client
                    )
                } catch APIError.server(let status, _) where status == 404 {
                    // Gone from the server: there is nothing to tell.
                } catch {
                    failed += 1
                    continue
                }
            }
            manager.settleOwed(entry.itemId)
            synced += 1
        }
        return Result(synced: synced, failed: failed, gone: gone)
    }

    private enum GoneOutcome { case moved, gone, failed }

    /// A record whose item the server has dropped under the id the download
    /// was made with. A file renamed or replaced by an upgrade comes back
    /// under a new id; deleted outright, it comes back under none. Either
    /// way the record used to stay unsynced for good — the watched flag went
    /// to the old id, the server said 404, and every sync after counted it
    /// as a failure: "Syncing 1 item", for ever.
    ///
    /// Found under a new id, the state goes there and the download is moved
    /// over at the next launch (see `DownloadManager.rekey`). Found nowhere,
    /// there is nothing to tell, the way an owed entry's 404 is read below;
    /// the device's own copy keeps what it knows.
    @MainActor
    private static func settleGone(
        _ record: DownloadRecord, with client: JellyfinClient, manager: DownloadManager
    ) async -> GoneOutcome {
        do {
            guard let replacement = try await replacement(for: record, with: client) else {
                manager.markSynced(record.itemId, revision: record.progressRevision)
                return .gone
            }
            try await send(
                itemId: replacement.Id, played: record.played, unplayedPending: record.unplayedPending,
                positionTicks: record.positionTicks, with: client
            )
            manager.noteFoundUnderNewId(record.itemId, newId: replacement.Id, confirmedGone: true)
            manager.markSynced(record.itemId, revision: record.progressRevision)
            return .moved
        } catch {
            return .failed
        }
    }

    /// The server's item for a download whose id it no longer has, by what
    /// the download is — the same strict match as `completeRecord(matching:)`,
    /// asked the other way round and of the server itself, since the device's
    /// copy of the library may still hold the old id.
    @MainActor
    private static func replacement(for record: DownloadRecord, with client: JellyfinClient) async throws -> BaseItem? {
        if record.isEpisode {
            guard let seriesId = record.seriesId, let season = record.season, let episode = record.episode else {
                return nil
            }
            let episodes: [BaseItem]
            do {
                episodes = try await client.episodes(seriesId: seriesId, seasonId: nil, fromServer: true)
            } catch APIError.server(let status, _) where status == 404 {
                // The whole series is gone, not just the file.
                return nil
            }
            return episodes.first {
                $0.Id != record.itemId && $0.ParentIndexNumber == season && $0.IndexNumber == episode
            }
        }
        guard record.type == "Movie", record.runTimeTicks > 0 else { return nil }
        let films = try await client.search(record.name, limit: 10, types: "Movie").items
        return films.first {
            $0.Id != record.itemId && $0.title == record.name
                && abs(($0.RunTimeTicks ?? 0) - record.runTimeTicks) < 5 * 10_000_000
        }
    }

    /// One item's state, said to the server. Throws unless all of it landed.
    @MainActor
    private static func send(
        itemId: String, played: Bool, unplayedPending: Bool, positionTicks: Int64,
        with client: JellyfinClient
    ) async throws {
        if played {
            try await client.markPlayed(itemId, played: true)
        } else {
            // Un-watched here: said first, since the server keeps its
            // tick through a stopped report and the next refresh would
            // otherwise put it straight back.
            if unplayedPending {
                try await client.markPlayed(itemId, played: false)
            }
            // A stopped report is how Jellyfin records a resume point;
            // there is no "set position" endpoint that does it alone.
            // Unlike the fire-and-forget report a live session makes,
            // this one has to actually land before the record is
            // marked synced, or a server blip mid-loop drops the
            // resume point for good.
            if positionTicks > 0 {
                try await client.reportPlaybackStoppedOrThrow(
                    PlaybackReport(
                        itemId: itemId,
                        mediaSourceId: nil,
                        playSessionId: nil,
                        positionSeconds: Double(positionTicks) / 10_000_000,
                        isPaused: true,
                        isTranscode: false
                    )
                )
            }
        }
    }

    /// One sitting with a downloaded file, as the server hears about it.
    ///
    /// The beat used to go through `send`, which says where a record got to
    /// with a stopped report — the right call for a sitting that is over, and
    /// the wrong one every ten seconds of a sitting that isn't. Each was a
    /// whole play as far as webhooks and Playback Reporting could tell, so one
    /// episode from the device's own copy was logged as dozens, and no start
    /// was ever sent. A sitting is reported the way a stream is instead: a
    /// start the first time the server can hear it, progress after that, and
    /// one stop at the end, all under an id of its own. A sitting the server
    /// never heard start is left to `sync`, which says it in one stopped
    /// report once the server is back.
    @MainActor
    final class Session {
        let itemId: String
        let playSessionId = UUID().uuidString
        /// Who was signed in when it began. The reports below go under whoever
        /// is signed in now, so a sitting outlasting its account stops sending.
        let accountKey = JellyfinClient.shared.session?.accountKey
        /// Whether the server has been sent this sitting's start.
        fileprivate(set) var started = false

        init(itemId: String) {
            self.itemId = itemId
        }

        fileprivate func report(for record: DownloadRecord, paused: Bool) -> PlaybackReport {
            PlaybackReport(
                itemId: itemId,
                mediaSourceId: nil,
                playSessionId: playSessionId,
                positionSeconds: Double(record.positionTicks) / 10_000_000,
                isPaused: paused,
                isTranscode: false
            )
        }
    }

    @MainActor private static var pushing = false

    /// The sitting that is playing, sent while it plays — see
    /// `PlayerModel.maybeReport`. Unlike `sync` this never probes for the
    /// server: it runs every few seconds, so it goes only when the server is
    /// believed to be there, one at a time, and a failure is left for the
    /// next beat or for the sync that follows the connection coming back.
    @MainActor
    static func push(_ session: Session, paused: Bool) async {
        let client = JellyfinClient.shared
        guard !pushing, client.isSignedIn, !client.isOffline,
              client.session?.accountKey == session.accountKey,
              let record = DownloadManager.shared.record(for: session.itemId),
              !record.progressSynced else { return }
        pushing = true
        defer { pushing = false }
        do {
            // Un-watched here: said first, as in `send`.
            if record.unplayedPending {
                try await client.markPlayed(record.itemId, played: false)
            }
            let report = session.report(for: record, paused: paused)
            if session.started {
                try await client.reportPlaybackProgressOrThrow(report)
            } else {
                try await client.reportPlaybackStartOrThrow(report)
                session.started = true
            }
        } catch {
            return
        }
        // A watched flag is left unsynced: the server applies its own
        // threshold to the position it was sent, which need not be this
        // one, and `end` leaves the flag to `sync` to say in so many words.
        guard !record.played else { return }
        DownloadManager.shared.markSynced(record.itemId, revision: record.progressRevision)
    }

    /// Close a sitting: its one stopped report, if the server heard it start,
    /// and then whatever is still owed — a watched flag, or the whole sitting
    /// when the server never heard it — through `sync`. The record is noted
    /// with its final position before this is called.
    @MainActor
    static func end(_ session: Session) async {
        // A beat still on its way decides whether there is a start to close.
        for _ in 0..<100 where pushing {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let client = JellyfinClient.shared
        if session.started, client.isSignedIn,
           client.session?.accountKey == session.accountKey,
           let record = DownloadManager.shared.record(for: session.itemId) {
            let stopped = (try? await client.reportPlaybackStoppedOrThrow(
                session.report(for: record, paused: true)
            )) != nil
            if stopped, !record.played, !record.unplayedPending {
                DownloadManager.shared.markSynced(record.itemId, revision: record.progressRevision)
            }
        }
        await sync()
    }

    /// Bring local records back in step with the server, so an episode watched
    /// on another device shows its tick here too.
    @MainActor
    static func refreshFromServer() async {
        let client = JellyfinClient.shared
        let ids = DownloadManager.shared.records
            .filter { $0.progressSynced && DownloadManager.shared.belongsToCurrentAccount($0) }
            .map(\.itemId)
        guard !ids.isEmpty, client.isSignedIn, !client.isOffline else { return }
        guard let items = try? await client.itemsByIds(ids) else { return }
        for item in items {
            let data = item.userData
            DownloadManager.shared.applyServerState(
                itemId: item.Id,
                positionTicks: data.positionTicks,
                played: data.played
            )
        }
    }
}

#endif
