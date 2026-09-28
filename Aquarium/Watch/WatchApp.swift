//  Aquarium on the wrist: audiobooks and music from the Jellyfin server the
//  phone is signed in to, kept on the watch for when the phone is at home.
//
//  The phone hands over the sign-in through WatchConnectivity (see
//  `WatchLink`), so there is nothing to type here; from then on the watch
//  talks to the server itself when it has a network, and tells the phone
//  what it has listened to when the phone is near.

import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct AquariumWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var client = JellyfinClient.shared
    @State private var downloads = WatchDownloads.shared
    @State private var player = WatchPlayer.shared
    @State private var link = WatchLink.shared
    @State private var sync = WatchSyncQueue.shared
    @State private var navigator = WatchNavigator()

    init() {
        WatchLog.launched()
        WatchLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .environment(downloads)
                .environment(player)
                .environment(link)
                .environment(sync)
                .environment(navigator)
                .tint(WatchTheme.accent)
                .onOpenURL { WatchActions.handle($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                WatchLog.foregrounded()
                link.requestContext()
                Task {
                    await client.checkOnline()
                    downloads.pump()
                    downloads.mirror()
                    await sync.flush()
                    await WatchActions.refreshBookPositions()
                }
            case .background:
                WatchLog.backgrounded()
                player.checkpoint()
                player.writeSnapshot()
                downloads.handOffToPhone()
                WatchDelegate.scheduleRefresh()
            default:
                break
            }
        }
    }
}

/// What WatchKit still has to answer for: the background session's events,
/// and the refresh the app asks for so queued listening reaches the server
/// even when nobody has raised their wrist.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let urlTask as WKURLSessionRefreshBackgroundTask:
                // Rejoining the session is enough: its delegate delivers what
                // was missed, and the "finished events" call ends the task.
                MainActor.assumeIsolated {
                    WatchDownloads.shared.handleBackgroundEvents {
                        urlTask.setTaskCompletedWithSnapshot(false)
                    }
                }
            case let link as WKWatchConnectivityRefreshBackgroundTask:
                // Held while the session still has things to hand over —
                // the pieces of a book from the phone — so the app isn't
                // put back to sleep before they reach it.
                Task { @MainActor in
                    for _ in 0..<20 where WCSession.default.activationState != .activated || WCSession.default.hasContentPending {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    link.setTaskCompletedWithSnapshot(false)
                }
            case let refresh as WKApplicationRefreshBackgroundTask:
                Task { @MainActor in
                    await WatchSyncQueue.shared.flush()
                    await WatchActions.refreshBookPositions()
                    WatchDownloads.shared.pump()
                    WatchDownloads.shared.mirror()
                    Self.scheduleRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// Ask to be woken in a while, when there is something to do then.
    @MainActor
    static func scheduleRefresh() {
        let hasWork = !WatchSyncQueue.shared.pending.isEmpty || !WatchDownloads.shared.inFlight.isEmpty
        // Playlists on the watch follow the server's: a wake now and then
        // picks up songs added or taken out there with nobody looking.
        let hasPlaylists = !WatchDownloads.shared.playlists.isEmpty
        guard hasWork || hasPlaylists else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(hasWork ? 30 * 60 : 2 * 60 * 60), userInfo: nil
        ) { _ in }
    }
}

/// Things asked of the app from outside a screen: a link, a Siri request, a
/// widget tap.
@MainActor
enum WatchActions {
    static func handle(_ url: URL) {
        guard url.scheme == "aquarium" else { return }
        switch url.host {
        case "resume":
            Task { await resumeBook() }
        case "play":
            let id = url.pathComponents.first { $0 != "/" } ?? ""
            guard !id.isEmpty else { return }
            Task { await play(itemId: id) }
        default:
            break
        }
    }

    /// The book most recently left, from where it was left. The server's
    /// list when it can be asked, the watch's own when it can't.
    @discardableResult
    static func resumeBook() async -> Bool {
        let player = WatchPlayer.shared
        if let current = player.current, current.isAudiobook, !player.isPlaying {
            player.resume()
            return true
        }
        let downloads = WatchDownloads.shared
        let client = JellyfinClient.shared
        if client.isSignedIn, !client.isOffline,
           let book = (try? await client.resumeAudio(limit: 10))?.first(where: \.isAudiobook) {
            player.play([book], title: book.title)
            return true
        }
        if let book = downloads.booksInProgress.first ?? downloads.books.first {
            player.play([book.asItem], title: book.name)
            return true
        }
        return false
    }

    static func play(itemId: String) async {
        let downloads = WatchDownloads.shared
        if let record = downloads.record(for: itemId), record.status == .complete {
            WatchPlayer.shared.play([record.asItem], title: record.name)
            return
        }
        guard let item = try? await JellyfinClient.shared.item(itemId) else { return }
        if item.isAlbum {
            let songs = (try? await JellyfinClient.shared.albumTracks(albumId: item.Id)) ?? []
            WatchPlayer.shared.play(songs, title: item.title)
        } else if item.isPlaylist {
            let songs = (try? await JellyfinClient.shared.playlistItems(playlistId: item.Id)) ?? []
            WatchPlayer.shared.play(songs, title: item.title)
        } else {
            WatchPlayer.shared.play([item], title: item.title)
        }
    }

    /// The songs of a thing, from the server or from the watch.
    static func songs(of item: BaseItem) async -> [BaseItem] {
        let client = JellyfinClient.shared
        let downloads = WatchDownloads.shared
        if item.isSong || item.isAudiobook { return [item] }
        if item.isAlbum {
            let local = downloads.albumTracks(albumId: item.Id)
            if client.isOffline || !client.isSignedIn { return local }
            return (try? await client.albumTracks(albumId: item.Id)) ?? local
        }
        if item.isPlaylist {
            let local = downloads.playlists.first { $0.id == item.Id }.map(downloads.playlistSongs) ?? []
            if client.isOffline || !client.isSignedIn { return local }
            return (try? await client.playlistItems(playlistId: item.Id)) ?? local
        }
        if item.isArtist {
            let local = downloads.songs.map(\.asItem).filter { $0.artistLine == item.title }
            if client.isOffline || !client.isSignedIn { return local }
            return (try? await client.songs(artistId: item.Id)) ?? local
        }
        if item.isMusicGenre {
            return client.isOffline ? [] : (try? await client.songs(genreId: item.Id)) ?? []
        }
        return []
    }

    /// Books on the watch — these, or all of them — brought in step with
    /// the server when it can be asked and the watch has nothing newer to
    /// say. What the server sent, for a caller that wants its word too;
    /// nothing when it couldn't be asked, or took longer than `timeout`.
    @discardableResult
    static func refreshBookPositions(ids only: [String]? = nil, timeout: Duration? = nil) async -> [BaseItem] {
        let client = JellyfinClient.shared
        let downloads = WatchDownloads.shared
        guard client.isSignedIn, !client.isOffline else { return [] }
        let ids = only ?? downloads.books.map(\.itemId)
        guard !ids.isEmpty else { return [] }
        let fetched: [BaseItem]?
        if let timeout {
            fetched = await withTaskGroup(of: [BaseItem]?.self) { group in
                group.addTask { try? await JellyfinClient.shared.items(ids: ids) }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } else {
            fetched = try? await client.items(ids: ids)
        }
        guard let items = fetched else { return [] }
        for item in items where item.isAudiobook {
            downloads.applyServerState(
                itemId: item.Id, positionTicks: item.userData.positionTicks, played: item.userData.played,
                lastPlayed: BookProgress.date(fromServer: item.userData.LastPlayedDate)
            )
        }
        WatchPlayer.shared.writeSnapshot()
        return items
    }
}
