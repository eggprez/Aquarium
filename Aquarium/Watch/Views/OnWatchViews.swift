//  What is on the watch, what is arriving, and the room left — the page
//  that answers "what is taking the space" and lets a thing go.

import SwiftUI

struct OnWatchView: View {
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player
    @State private var confirmAll = false

    var body: some View {
        List {
            let arriving = downloads.inFlight
            if !arriving.isEmpty {
                Section("Downloading") {
                    ForEach(arriving) { record in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name).font(.footnote).lineLimit(1)
                                if record.status == .downloading, let f = downloads.fraction(record.itemId) {
                                    ProgressView(value: f).tint(WatchTheme.accent).scaleEffect(x: 1, y: 0.6, anchor: .center)
                                } else {
                                    Text(record.status == .queued ? (record.automatic && !downloads.isOnWiFi ? "Waiting for Wi‑Fi" : "Waiting") : "Starting…")
                                        .font(.caption2).foregroundStyle(WatchTheme.dim)
                                }
                            }
                            Spacer()
                            DownloadMark(itemId: record.itemId)
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.cancel(record.itemId) } label: { Label("Cancel", systemImage: "xmark") }
                        }
                    }
                }
            }

            let failed = downloads.failed
            if !failed.isEmpty {
                Section("Didn't Arrive") {
                    ForEach(failed) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name).font(.footnote).lineLimit(1)
                            Text(record.errorMessage ?? "Failed").font(.caption2).foregroundStyle(.orange)
                        }
                        .swipeActions {
                            Button { downloads.retry(record.itemId) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(WatchTheme.accent)
                            Button(role: .destructive) { downloads.delete(record.itemId) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    Button("Retry All") { downloads.retryAllFailed() }
                }
            }

            let books = downloads.books
            if !books.isEmpty {
                Section("Audiobooks") {
                    ForEach(books) { record in
                        let item = record.asItem
                        NavigationLink { BookDetail(item: item) } label: {
                            BookRow(item: item, progress: record.progressFraction)
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.deleteBook(record.itemId) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }

            if !downloads.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(downloads.playlists) { list in
                        let item = list.asItem
                        let here = downloads.playlistSongs(list).count
                        NavigationLink { CollectionDetail(item: item) } label: {
                            CollectionRow(item: item, subtitle: here == list.itemIds.count ? "\(here) songs" : "\(here) of \(list.itemIds.count) songs")
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.deletePlaylist(list.id) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }

            let albums = downloads.albums
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        NavigationLink { CollectionDetail(item: album) } label: {
                            CollectionRow(item: album, subtitle: "\(downloads.albumTracks(albumId: album.Id).count) songs")
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.deleteAlbum(album.Id) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }

            if downloads.complete.isEmpty, arriving.isEmpty, failed.isEmpty {
                StatusRow(empty: "Nothing on the watch yet. Open an album, a playlist or a book and choose Download to Watch — or pick playlists for the watch in Aquarium on your iPhone.")
            }

            Section {
                StorageLine()
                if !downloads.records.isEmpty {
                    Button(role: .destructive) { confirmAll = true } label: {
                        Label("Remove Everything", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("On Watch")
        .confirmationDialog("Remove everything from the watch?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Remove \(downloads.complete.count) items", role: .destructive) {
                player.stop()
                downloads.deleteEverything()
            }
        }
    }
}

struct StorageLine: View {
    @Environment(WatchDownloads.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let used = downloads.totalBytes
            let free = WatchDownloads.freeBytes()
            HStack {
                Text("Aquarium").font(.caption2)
                Spacer()
                Text(Format.bytes(used)).font(.caption2.monospacedDigit())
            }
            if let free {
                HStack {
                    Text("Free on watch").font(.caption2).foregroundStyle(WatchTheme.dim)
                    Spacer()
                    Text(Format.bytes(free)).font(.caption2.monospacedDigit()).foregroundStyle(WatchTheme.dim)
                }
                // Drawn by hand: the system bar's track reads as a full bar
                // on a watch's black, which at 0 B looked like a full watch.
                GeometryReader { geo in
                    let fraction = used + free > 0 ? Double(used) / Double(used + free) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(WatchTheme.accent)
                            .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

// MARK: - Settings

struct WatchSettingsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchLink.self) private var link
    @Environment(WatchSyncQueue.self) private var sync
    @State private var syncing = false

    var body: some View {
        List {
            Section("Account") {
                if let account = client.account {
                    LabeledContent("Signed in as", value: account.userName)
                    LabeledContent("Server", value: account.server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                    LabeledContent("Server", value: client.isOffline ? "Out of reach" : "Connected")
                } else {
                    Text("Not signed in. Open Aquarium on your iPhone.").font(.footnote).foregroundStyle(WatchTheme.dim)
                }
                LabeledContent("iPhone", value: link.isPhoneReachable ? "In reach" : "Away")
            }
            .font(.footnote)

            Section("Sync") {
                LabeledContent("Waiting to send", value: "\(sync.pending.count)").font(.footnote)
                if let at = sync.lastFlushedAt {
                    LabeledContent("Last sent", value: at.formatted(.relative(presentation: .named)) + (sync.lastRoute.map { " via \($0)" } ?? ""))
                        .font(.footnote)
                }
                Button {
                    syncing = true
                    Task {
                        await client.checkOnline()
                        await sync.flush()
                        downloads.mirror()
                        await WatchActions.refreshBookPositions()
                        syncing = false
                    }
                } label: {
                    if syncing { ProgressView() } else { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                }
            }

            Section("From iPhone") {
                let plan = downloads.plan
                Text(plan.playlistIds.isEmpty && plan.bookIds.isEmpty
                     ? "Audiobooks you start on the phone are kept here automatically. Pick playlists for the watch in Aquarium on your iPhone under Settings → Apple Watch."
                     : "\(plan.bookIds.count) audiobook\(plan.bookIds.count == 1 ? "" : "s") and \(plan.playlistIds.count) playlist\(plan.playlistIds.count == 1 ? "" : "s") kept in step. They arrive over Wi‑Fi.")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.dim)
                if let note = downloads.mirrorNote { Text(note).font(.caption2) }
            }

            Section("Storage") {
                StorageLine()
                NavigationLink("Manage") { OnWatchView() }
            }

            Section {
                Text("Downloads are AAC at 128 kbps. About \(Format.bytes(JellyfinClient.estimatedBytes(for: hourItem))) an hour.")
                    .font(.caption2).foregroundStyle(WatchTheme.dim)
            }
        }
        .navigationTitle("Settings")
    }

    private var hourItem: BaseItem {
        var item = BaseItem()
        item.RunTimeTicks = 3600 * 10_000_000
        return item
    }
}
