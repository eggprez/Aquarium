//  What is on the watch, what is arriving, and the room left — the page
//  that answers "what is taking the space" and lets a thing go. Everything
//  is shown as what was asked for: a playlist, an album or a book is one
//  row, arriving or arrived, never its songs one by one. The songs and
//  books on their way are listed one by one on the queue's own page.

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

    /// Everything still arriving, stopped: each group the way its own
    /// Cancel would, so a playlist asked for by hand that has nothing here
    /// yet goes with its songs.
    func cancelAll() {
        for group in groups() where progress(of: group.itemIds).arriving > 0 { cancel(group) }
    }

    /// The queue as its page shows it, one row per song or book: what is
    /// moving now, furthest along first, then what is waiting, in the order
    /// it will start — asked-for things before the phone's plan, oldest ask
    /// first, the way the pump takes them.
    func queue() -> (moving: [WatchRecord], waiting: [WatchRecord]) {
        var moving: [(record: WatchRecord, fraction: Double)] = []
        var waiting: [WatchRecord] = []
        for r in inFlight {
            if r.status == .downloading, let f = fraction(r.itemId) { moving.append((r, f)) } else { waiting.append(r) }
        }
        moving.sort { $0.fraction > $1.fraction }
        waiting.sort { a, b in
            let aStarting = isStarting(a.itemId), bStarting = isStarting(b.itemId)
            if aStarting != bStarting { return aStarting }
            if a.automatic != b.automatic { return !a.automatic }
            return a.createdAt < b.createdAt
        }
        return (moving.map(\.record), waiting)
    }

    /// The name of the playlist a song is here for, if it is here for one.
    func playlistName(for record: WatchRecord) -> String? {
        playlists.first { record.reasons.contains("playlist:\($0.id)") }?.name
    }
}

struct OnWatchView: View {
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player
    @State private var confirmAll = false

    /// The groups sorted into the page's shelves, each with its progress.
    private struct Shelves {
        var groups: [WatchDownloads.Group] = []
        var progress: [String: WatchDownloads.Progress] = [:]
        var failed: [WatchDownloads.Group] = []
        var here: [WatchDownloads.Group] = []
        func p(_ g: WatchDownloads.Group) -> WatchDownloads.Progress { progress[g.id + g.kind.rawValue] ?? .init() }
    }

    private var shelves: Shelves {
        var s = Shelves(groups: downloads.groups())
        for g in s.groups { s.progress[g.id + g.kind.rawValue] = downloads.progress(of: g.itemIds) }
        s.failed = s.groups.filter { s.p($0).arriving == 0 && s.p($0).failed > 0 }
        // Arriving groups stay on their shelf, with how far they have got;
        // the songs and books themselves are on the queue's page.
        s.here = s.groups.filter { s.p($0).arriving > 0 || (s.p($0).failed == 0 && s.p($0).done > 0) }
        return s
    }

    var body: some View {
        let shelves = shelves
        let groups = shelves.groups
        let failed = shelves.failed
        let here = shelves.here
        let p = shelves.p

        List {
            if !downloads.inFlight.isEmpty {
                Section {
                    NavigationLink(value: WatchRoute.downloadQueue) { DownloadingRow() }
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
                                if p(group).done == 0 {
                                    Button(role: .destructive) { downloads.cancel(group) } label: { Label("Cancel", systemImage: "xmark") }
                                } else {
                                    Button(role: .destructive) { downloads.remove(group) } label: { Label("Remove", systemImage: "trash") }
                                }
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

    private func failedNote(_ group: WatchDownloads.Group, _ p: WatchDownloads.Progress) -> String {
        if p.total == 1, let message = downloads.record(for: group.itemIds[0])?.errorMessage { return message }
        return p.total == 1 ? "Didn't arrive" : "\(p.failed) of \(p.total) didn't arrive"
    }

    private func hereNote(_ group: WatchDownloads.Group, _ p: WatchDownloads.Progress) -> String? {
        if p.arriving > 0 {
            return group.kind == .book ? "Downloading · \(p.percent)%" : "\(p.done) of \(p.total) · downloading"
        }
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

// MARK: - The queue

/// Every song and book on its way, one row each: what is moving at the
/// top, furthest along first, and what is waiting below in the order it
/// will start. A row leaves by itself once its file is on the watch.
struct DownloadQueueView: View {
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchLink.self) private var link
    @State private var confirmCancel = false

    /// Rows drawn for the waiting; a genre's worth of songs is thousands.
    private static let shownWaiting = 60

    var body: some View {
        let (moving, waiting) = downloads.queue()
        List {
            if moving.isEmpty && waiting.isEmpty {
                StatusRow(empty: "Nothing is downloading. Everything asked for is on the watch.")
            }
            if !moving.isEmpty {
                Section("Downloading") {
                    ForEach(moving) { record in
                        QueueRow(record: record, fraction: downloads.fraction(record.itemId), note: nil)
                            .swipeActions { cancelButton(record) }
                    }
                }
            }
            if !waiting.isEmpty {
                Section("Waiting") {
                    ForEach(waiting.prefix(Self.shownWaiting)) { record in
                        QueueRow(record: record, fraction: nil, note: waitingNote(record))
                            .swipeActions { cancelButton(record) }
                    }
                    if waiting.count > Self.shownWaiting {
                        Text("and \(waiting.count - Self.shownWaiting) more")
                            .font(.caption2).foregroundStyle(WatchTheme.dim)
                    }
                }
            }
            if !moving.isEmpty || !waiting.isEmpty {
                Section {
                    Button(role: .destructive) { confirmCancel = true } label: {
                        Label("Cancel All", systemImage: "xmark.circle")
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Cancel every download?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel \(moving.count + waiting.count)", role: .destructive) { downloads.cancelAll() }
        } message: {
            Text("What is already on the watch stays.")
        }
    }

    private func cancelButton(_ record: WatchRecord) -> some View {
        Button(role: .destructive) { downloads.cancel(record.itemId) } label: { Label("Cancel", systemImage: "xmark") }
    }

    /// Why a row isn't moving yet.
    private func waitingNote(_ record: WatchRecord) -> String {
        if downloads.isStarting(record.itemId) { return "Starting…" }
        if record.status == .downloading, record.relayAskedAt != nil {
            return link.isPhoneReachable ? "Queued on iPhone" : "Waiting for iPhone"
        }
        if record.automatic, !downloads.isOnWiFi, !link.hasCompanion { return "Waiting for Wi‑Fi" }
        return "Waiting"
    }
}

/// One song or book in the queue: what it is, what it came with, and how
/// far along it is.
private struct QueueRow: View {
    let record: WatchRecord
    let fraction: Double?
    let note: String?
    @Environment(WatchDownloads.self) private var downloads

    var body: some View {
        HStack(spacing: 8) {
            Artwork(item: record.asItem, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.footnote.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(from).font(.caption2).foregroundStyle(WatchTheme.dim).lineLimit(1)
                    Spacer(minLength: 2)
                    if let fraction {
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.caption2.monospacedDigit()).foregroundStyle(WatchTheme.dim)
                    }
                }
                if let fraction {
                    ProgressBar(fraction: fraction)
                } else if let note {
                    Text(note).font(.caption2).foregroundStyle(WatchTheme.dim).lineLimit(1)
                }
            }
        }
    }

    /// The playlist, the album or the book's author.
    private var from: String {
        if record.isAudiobook { return record.artist ?? "Audiobook" }
        return downloads.playlistName(for: record) ?? record.album ?? record.artist ?? "Song"
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

/// Four short sections and no paragraphs: who is signed in and whether
/// anything is in reach, what is on the watch, what is waiting to be sent,
/// and the log. What the iPhone keeps in step is one row with a count; the
/// choosing happens on the iPhone, and the footer says so.
struct WatchSettingsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchLink.self) private var link
    @Environment(WatchSyncQueue.self) private var sync
    @State private var syncing = false

    var body: some View {
        List {
            Section {
                if let account = client.account {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.userName.isEmpty ? "Unnamed user" : account.userName)
                            .lineLimit(1)
                        Text(account.server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                            .font(.caption2)
                            .foregroundStyle(WatchTheme.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Server", value: client.isOffline ? "Out of reach" : "Connected")
                } else {
                    Text("Not signed in. Open Aquarium on your iPhone.")
                        .foregroundStyle(WatchTheme.dim)
                }
                LabeledContent("iPhone", value: link.isPhoneReachable ? "In reach" : "Away")
            } header: {
                Text("Account")
            }
            .font(.footnote)

            Section {
                StorageLine()
                NavigationLink("Manage", value: WatchRoute.onWatch)
                LabeledContent("From iPhone", value: keptSummary)
                    .font(.footnote)
                if let note = downloads.mirrorNote {
                    Text(note).font(.caption2).foregroundStyle(WatchTheme.dim)
                }
            } header: {
                Text("On This Watch")
            } footer: {
                Text("Choose what the iPhone keeps here in Aquarium on iPhone, under Settings → Apple Watch. Downloads are AAC at 128 kbps, about \(Format.bytes(JellyfinClient.estimatedBytes(for: hourItem))) an hour.")
                    .font(.caption2)
            }

            Section {
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
                        downloads.mirror(force: true)
                        await WatchActions.refreshBookPositions()
                        syncing = false
                    }
                } label: {
                    if syncing { ProgressView() } else { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(syncing)
            } header: {
                Text("Sync")
            }

            Section {
                Button {
                    Task { await link.sendLogs() }
                } label: {
                    if link.logsSending { ProgressView() } else { Label("Send Log to iPhone", systemImage: "doc.text") }
                }
                .disabled(link.logsSending)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(link.logsSentAt.map { "Sent \($0.formatted(.relative(presentation: .named))). Find it on the iPhone under Settings → Apple Watch." }
                     ?? "What the watch has been doing, for when something goes wrong.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Settings")
    }

    /// What the iPhone's settings keep on this watch: "2 books · 3 lists".
    private var keptSummary: String {
        let books = downloads.plan.bookIds.count
        let lists = downloads.plannedPlaylistIds.count
        var parts: [String] = []
        if books > 0 { parts.append("\(books) book\(books == 1 ? "" : "s")") }
        if lists > 0 { parts.append("\(lists) list\(lists == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " · ")
    }

    private var hourItem: BaseItem {
        var item = BaseItem()
        item.RunTimeTicks = 3600 * 10_000_000
        return item
    }
}
