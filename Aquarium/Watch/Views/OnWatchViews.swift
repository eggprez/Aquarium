//  What is on the watch, what is arriving, and the room left — the page
//  that answers "what is taking the space" and lets a thing go. Everything
//  is shown as what was asked for: a playlist, an album or a book is one
//  row, arriving or arrived, never its songs one by one.

import SwiftUI

extension WatchDownloads {
    /// A book, a playlist, an album or the loose songs, with the records
    /// that make it up. A song in a kept playlist is the playlist's, not its
    /// album's, so nothing is counted twice.
    struct Group: Identifiable {
        var kind: WatchStorageGroup.Kind
        var id: String
        var title: String
        var subtitle: String?
        var itemIds: [String]
        /// The page a tap opens.
        var route: WatchRoute?
        /// The item that stands for it in a row's artwork.
        var item: BaseItem
    }

    func groups() -> [Group] {
        var out: [Group] = []
        for book in records where book.isAudiobook {
            let item = book.asItem
            out.append(Group(kind: .book, id: book.itemId, title: book.name, subtitle: book.artist,
                             itemIds: [book.itemId], route: .book(item), item: item))
        }
        var claimed = Set<String>()
        for list in playlists {
            claimed.formUnion(list.itemIds)
            let item = list.asItem
            out.append(Group(kind: .playlist, id: list.id, title: list.name, subtitle: "\(list.itemIds.count) songs",
                             itemIds: list.itemIds, route: .collection(item), item: item))
        }
        var byAlbum: [String: [WatchRecord]] = [:]
        var loose: [WatchRecord] = []
        for song in records where !song.isAudiobook && !claimed.contains(song.itemId) {
            if let albumId = song.albumId, !albumId.isEmpty { byAlbum[albumId, default: []].append(song) } else { loose.append(song) }
        }
        for (albumId, songs) in byAlbum {
            let sorted = songs.map(\.asItem).sortedByTrack()
            let album = sorted.albumsInOrder().first ?? sorted[0]
            out.append(Group(kind: .album, id: albumId, title: songs[0].album ?? "Album", subtitle: songs[0].artist,
                             itemIds: sorted.map(\.Id), route: .collection(album), item: album))
        }
        if !loose.isEmpty {
            var item = BaseItem()
            item.Id = "songs"
            item.Name = "Songs"
            item.type = "Audio"
            out.append(Group(kind: .songs, id: "songs", title: "Songs", subtitle: "\(loose.count) song\(loose.count == 1 ? "" : "s")",
                             itemIds: loose.map(\.itemId), route: .songs, item: item))
        }
        out.sort { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return out
    }

    func remove(_ group: Group) {
        switch group.kind {
        case .book: deleteBook(group.id)
        case .album: deleteAlbum(group.id)
        case .playlist: deletePlaylist(group.id)
        case .songs: deleteLooseSongs()
        }
    }

    func cancel(_ group: Group) {
        for id in group.itemIds where isQueuedOrRunning(id) { cancel(id) }
        if group.kind == .playlist, playlists.first(where: { $0.id == group.id })?.automatic == false,
           !group.itemIds.contains(where: { isComplete($0) }) {
            deletePlaylist(group.id)
        }
    }

    func retry(_ group: Group) {
        for id in group.itemIds { retry(id) }
    }
}

struct OnWatchView: View {
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchLink.self) private var link
    @State private var confirmAll = false

    /// The groups sorted into the page's shelves, each with its progress.
    private struct Shelves {
        var groups: [WatchDownloads.Group] = []
        var progress: [String: WatchDownloads.Progress] = [:]
        var arriving: [WatchDownloads.Group] = []
        var failed: [WatchDownloads.Group] = []
        var here: [WatchDownloads.Group] = []
        func p(_ g: WatchDownloads.Group) -> WatchDownloads.Progress { progress[g.id + g.kind.rawValue] ?? .init() }
    }

    private var shelves: Shelves {
        var s = Shelves(groups: downloads.groups())
        for g in s.groups { s.progress[g.id + g.kind.rawValue] = downloads.progress(of: g.itemIds) }
        s.arriving = s.groups.filter { s.p($0).arriving > 0 }
        s.failed = s.groups.filter { s.p($0).arriving == 0 && s.p($0).failed > 0 }
        s.here = s.groups.filter { s.p($0).arriving == 0 && s.p($0).failed == 0 && s.p($0).done > 0 }
        return s
    }

    var body: some View {
        let shelves = shelves
        let groups = shelves.groups
        let arriving = shelves.arriving
        let failed = shelves.failed
        let here = shelves.here
        let p = shelves.p

        List {
            if !arriving.isEmpty {
                Section("Downloading") {
                    ForEach(arriving) { group in
                        GroupLink(group: group) {
                            ArrivingRow(group: group, progress: p(group), waiting: waitingNote(group))
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.cancel(group) } label: { Label("Cancel", systemImage: "xmark") }
                        }
                    }
                }
            }

            if !failed.isEmpty {
                Section("Didn't Arrive") {
                    ForEach(failed) { group in
                        GroupLink(group: group) {
                            GroupRow(group: group, note: failedNote(group, p(group)), noteColor: .orange)
                        }
                        .swipeActions {
                            Button { downloads.retry(group) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(WatchTheme.accent)
                            Button(role: .destructive) { downloads.remove(group) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    Button("Retry All") { downloads.retryAllFailed() }
                }
            }

            ForEach([WatchStorageGroup.Kind.book, .playlist, .album, .songs], id: \.rawValue) { kind in
                let rows = here.filter { $0.kind == kind }
                if !rows.isEmpty {
                    Section(kind == .book ? "Audiobooks" : (kind == .playlist ? "Playlists" : (kind == .album ? "Albums" : "Songs"))) {
                        ForEach(rows) { group in
                            GroupLink(group: group) {
                                GroupRow(group: group, note: hereNote(group, p(group)), noteColor: WatchTheme.dim)
                            }
                            .swipeActions {
                                Button(role: .destructive) { downloads.remove(group) } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                    }
                }
            }

            if groups.isEmpty {
                StatusRow(empty: "Nothing on the watch yet. Open a book, an album or a playlist and choose Download to Watch.")
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

    /// Why nothing is moving yet, when it isn't.
    private func waitingNote(_ group: WatchDownloads.Group) -> String? {
        let members = group.itemIds.compactMap { downloads.record(for: $0) }
        guard !members.contains(where: { $0.status == .downloading && downloads.fraction($0.itemId) != nil }) else { return nil }
        if members.contains(where: { $0.status == .downloading && $0.relayAskedAt != nil }) {
            return link.isPhoneReachable ? "From iPhone…" : "Waiting for iPhone"
        }
        if members.contains(where: { $0.status == .downloading }) { return "Starting…" }
        if members.contains(where: { $0.status == .queued && $0.automatic }), !downloads.isOnWiFi, !link.hasCompanion { return "Waiting for Wi‑Fi" }
        // Part-way through, with another group's song on the wire.
        let done = members.filter { $0.status == .complete }.count
        return done > 0 ? "\(done) of \(group.itemIds.count)" : "Waiting"
    }

    private func failedNote(_ group: WatchDownloads.Group, _ p: WatchDownloads.Progress) -> String {
        if p.total == 1, let message = downloads.record(for: group.itemIds[0])?.errorMessage { return message }
        return p.total == 1 ? "Didn't arrive" : "\(p.failed) of \(p.total) didn't arrive"
    }

    private func hereNote(_ group: WatchDownloads.Group, _ p: WatchDownloads.Progress) -> String? {
        switch group.kind {
        case .book:
            return group.subtitle
        case .playlist:
            return p.done == p.total ? "\(p.total) songs" : "\(p.done) of \(p.total) songs"
        case .album:
            return [group.subtitle, "\(p.done) song\(p.done == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
        case .songs:
            return group.subtitle
        }
    }
}

/// A row that opens the group's page when it has one.
private struct GroupLink<Label: View>: View {
    let group: WatchDownloads.Group
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let route = group.route {
            NavigationLink(value: route) { label() }
        } else {
            label()
        }
    }
}

/// Artwork, name, and a line under it.
private struct GroupRow: View {
    let group: WatchDownloads.Group
    var note: String?
    var noteColor: Color = WatchTheme.dim
    @Environment(WatchDownloads.self) private var downloads

    var body: some View {
        HStack(spacing: 8) {
            if group.kind == .songs {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(WatchTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Artwork(item: group.item, size: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.footnote.weight(.medium)).lineLimit(2)
                if let note { Text(note).font(.caption2).foregroundStyle(noteColor).lineLimit(1) }
                if group.kind == .book, let f = downloads.record(for: group.id)?.progressFraction {
                    ProgressBar(fraction: f)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A group on its way: what it is, and how far along.
private struct ArrivingRow: View {
    let group: WatchDownloads.Group
    let progress: WatchDownloads.Progress
    var waiting: String?

    var body: some View {
        HStack(spacing: 8) {
            Artwork(item: group.item, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title).font(.footnote.weight(.medium)).lineLimit(1)
                HStack {
                    Text(group.kind.label).font(.caption2).foregroundStyle(WatchTheme.dim)
                    Spacer()
                    Text(waiting ?? (progress.total > 1 ? "\(progress.done) of \(progress.total) · \(progress.percent)%" : "\(progress.percent)%"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WatchTheme.dim)
                        .lineLimit(1)
                }
                ProgressBar(fraction: progress.fraction)
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
                     ? "Nothing is sent by itself. Downloads happen only when you ask for them here. To keep the audiobooks you're listening to, or chosen playlists, on the watch automatically, open Aquarium on your iPhone under Settings → Apple Watch."
                     : "\(plan.bookIds.count) audiobook\(plan.bookIds.count == 1 ? "" : "s") and \(plan.playlistIds.count) playlist\(plan.playlistIds.count == 1 ? "" : "s") kept in step from the iPhone's settings. The iPhone fetches them and hands them across; over Wi‑Fi the watch can fetch for itself.")
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.dim)
                if let note = downloads.mirrorNote { Text(note).font(.caption2) }
            }

            Section("Storage") {
                StorageLine()
                NavigationLink("Manage", value: WatchRoute.onWatch)
            }

            Section {
                Button {
                    Task { await link.sendLogs() }
                } label: {
                    if link.logsSending { ProgressView() } else { Label("Send Log to iPhone", systemImage: "doc.text") }
                }
                .disabled(link.logsSending)
                if let at = link.logsSentAt {
                    Text("Sent \(at.formatted(.relative(presentation: .named))). Find it in Aquarium on your iPhone under Settings → Apple Watch.")
                        .font(.caption2).foregroundStyle(WatchTheme.dim)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("What the watch has been doing, for when something goes wrong.")
                    .font(.caption2)
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
