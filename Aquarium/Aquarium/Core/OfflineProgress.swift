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
        let pending = DownloadManager.shared.unsyncedRecords
        guard !pending.isEmpty else { return Result(synced: 0, failed: 0) }
        guard await client.checkOnline() else {
            return Result(synced: 0, failed: pending.count)
        }

        var synced = 0
        var failed = 0
        for record in pending {
            do {
                try await send(record, with: client)
                // Against what was sent: newer progress noted during the
                // await leaves the record unsynced.
                DownloadManager.shared.markSynced(record.itemId, revision: record.progressRevision)
                synced += 1
            } catch {
                failed += 1
            }
        }
        return Result(synced: synced, failed: failed)
    }

    /// One record's state, said to the server. Throws unless all of it landed.
    @MainActor
    private static func send(_ record: DownloadRecord, with client: JellyfinClient) async throws {
        if record.played {
            try await client.markPlayed(record.itemId, played: true)
        } else {
            // Un-watched here: said first, since the server keeps its
            // tick through a stopped report and the next refresh would
            // otherwise put it straight back.
            if record.unplayedPending {
                try await client.markPlayed(record.itemId, played: false)
            }
            // A stopped report is how Jellyfin records a resume point;
            // there is no "set position" endpoint that does it alone.
            // Unlike the fire-and-forget report a live session makes,
            // this one has to actually land before the record is
            // marked synced, or a server blip mid-loop drops the
            // resume point for good.
            if record.positionTicks > 0 {
                try await client.reportPlaybackStoppedOrThrow(
                    PlaybackReport(
                        itemId: record.itemId,
                        mediaSourceId: nil,
                        playSessionId: nil,
                        positionSeconds: Double(record.positionTicks) / 10_000_000,
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
            .filter { $0.progressSynced }
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
