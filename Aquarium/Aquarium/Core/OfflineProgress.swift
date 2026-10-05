//  Watching a downloaded file records position and watched state locally; this
//  pushes it back to Jellyfin whenever the server is reachable. A port of
//  progress.rs.
//
//  Resume points go back as a playback-stopped report (the same call a live
//  session makes when you close the player), and watched flags go to the
//  played-items endpoint. Runs automatically at app start, on coming back to
//  the app, every few seconds during local playback and after it, and
//  manually from the Downloads view.

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

    @MainActor private static var pushing = false

    /// The record that is playing, sent while it plays — see
    /// `PlayerModel.maybeReport`. Unlike `sync` this never probes for the
    /// server: it runs every few seconds, so it goes only when the server is
    /// believed to be there, one at a time, and a failure is left for the
    /// next beat or for the sync that follows the connection coming back.
    @MainActor
    static func push(_ itemId: String) async {
        let client = JellyfinClient.shared
        guard !pushing, client.isSignedIn, !client.isOffline,
              let record = DownloadManager.shared.record(for: itemId), !record.progressSynced else { return }
        pushing = true
        defer { pushing = false }
        guard (try? await send(record, with: client)) != nil else { return }
        DownloadManager.shared.markSynced(record.itemId, revision: record.progressRevision)
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
