//  Downloads on a Mac: the queue as a list with sections, what is on this
//  machine as a grid of posters, and a downloaded show as a list of its
//  episodes under season headers — the shapes Finder, Mail and Safari's
//  downloads use, with their manners: click selects, double-click opens, the
//  Delete key removes, the context menu acts on the selection, and the
//  toolbar holds the actions the phone keeps in a card at the top of the page.
//
//  The records, the grouping, the confirmation and the poster tile are the
//  ones the phone uses (see `DownloadsView`); only the page around them is
//  different.

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - The Downloads page

struct MacDownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player
    @Environment(\.openWindow) private var openWindow

    @State private var downloads = DownloadManager.shared
    @State private var isSyncing = false
    @State private var pendingDeletion: DownloadDeletion?
    @State private var confirmingClearQueue = false

    /// The queue's rows — transfers, what is waiting, what failed — by item
    /// id. The list's own selection.
    @State private var rowSelection: Set<String> = []
    /// The poster tiles: a show by the key `DownloadGroups` gave it, a film by
    /// its item id. Kept apart from the rows because the two are different
    /// kinds of thing and the Delete key means different things for each.
    @State private var tileSelection: Set<String> = []
    /// The tile last clicked, for Return.
    @State private var tileAnchor: String?
    @FocusState private var focusedGrid: GridKind?

    /// The volume's free space, asked of the file system when the page opens
    /// and when a download finishes or goes — not on every redraw.
    @State private var freeSpace: Int64?

    private enum GridKind: Hashable { case shows, films }

    // All from one pass over the records, kept until they change — see
    // `DownloadManager.tally`.
    private var running: [DownloadRecord] { downloads.tally.running }
    private var failed: [DownloadRecord] { downloads.tally.failed }
    private var completeCount: Int { downloads.tally.completeCount }

    private var isEmpty: Bool {
        completeCount == 0 && running.isEmpty && downloads.queue.isEmpty && failed.isEmpty
    }

    /// Whether the list has any rows above the grids. The alternating stripes
    /// are for those; a page that is only posters is better plain.
    private var hasQueueRows: Bool {
        !running.isEmpty || !downloads.queue.isEmpty || !failed.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                EmptyState(
                    symbol: "arrow.down.circle",
                    title: "No Downloads",
                    message: "Anything you download from a title's page is kept on this Mac and plays without a server — including when you're offline."
                )
            } else {
                list
            }
        }
        .navigationTitle("Downloads")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .downloadDeletionDialog($pendingDeletion) { ids in
            // No toast: the tiles go, which is the confirmation.
            downloads.delete(ids)
            tileSelection = []
        }
        .alert("Clear the Queue?", isPresented: $confirmingClearQueue) {
            Button("Clear Queue", role: .destructive) { downloads.clearQueue() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = downloads.queue.count
            Text("\(n.formatted()) waiting download\(n == 1 ? "" : "s") will be removed. Nothing already on this Mac is affected.")
        }
        .task {
            await OfflineProgress.refreshFromServer()
        }
        .task(id: completeCount) {
            freeSpace = await Task.detached(priority: .utility) { DownloadManager.freeSpace() }.value
        }
        // View ▸ Refresh: send what is waiting and ask the server what it knows.
        .onChange(of: MacCommandRequests.shared.refresh) { _, _ in
            Task { await sync() }
        }
    }

    /// "42 items · 120 GB · 310 GB free", where the phone has a card.
    private var subtitle: String {
        var parts = ["\(completeCount.formatted()) item\(completeCount == 1 ? "" : "s")"]
        if downloads.totalBytesOnDisk > 0 { parts.append(Format.bytes(downloads.totalBytesOnDisk)) }
        if let freeSpace { parts.append("\(Format.bytes(freeSpace)) free") }
        if downloads.isPaused { parts.append("Paused") }
        return parts.joined(separator: " · ")
    }

    // MARK: List

    private var list: some View {
        // Grouped once rather than once per reference: every read walks and
        // sorts the whole record set.
        let groups = DownloadGroups.current()
        let shows = groups.series
        let films = groups.films

        return List(selection: $rowSelection) {
            if !running.isEmpty {
                Section("Downloading") {
                    ForEach(running) { record in
                        MacTransferRow(record: record) { downloads.cancel(record.itemId) }
                    }
                }
            }

            if !downloads.queue.isEmpty {
                // The whole queue: a list is lazy, so a music library's worth
                // of rows costs what is on screen, and no "and 900 more".
                Section("Up Next · \(downloads.queue.count.formatted())") {
                    ForEach(downloads.queue) { entry in
                        MacQueueRow(entry: entry) { downloads.cancelQueued(entry.itemId) }
                    }
                }
            }

            if !failed.isEmpty {
                Section("Failed · \(failed.count.formatted())") {
                    ForEach(failed) { record in
                        MacFailedRow(record: record) {
                            downloads.retry(record.itemId)
                        } onDelete: {
                            downloads.delete(record.itemId)
                        }
                    }
                }
            }

            if !shows.isEmpty {
                gridSection(films.isEmpty ? "On This Device" : "Shows", kind: .shows) {
                    ForEach(shows) { show in seriesTile(show) }
                }
            }

            if !films.isEmpty {
                gridSection(shows.isEmpty ? "On This Device" : "Films", kind: .films) {
                    ForEach(films) { film in filmTile(film) }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(hasQueueRows ? .enabled : .disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            rowMenu(ids)
        }
        .onDeleteCommand {
            if rowSelection.isEmpty {
                deleteTiles(tileSelection)
            } else {
                removeRows(rowSelection)
            }
        }
        // One selection at a time, the way one Finder window has one.
        .onChange(of: rowSelection) { _, rows in
            if !rows.isEmpty { tileSelection = [] }
        }
    }

    /// A grid of posters as one row of the list: no stripe, no separator,
    /// and not selectable as a row — the tiles carry their own selection.
    private func gridSection(
        _ title: String,
        kind: GridKind,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Section(title) {
            LazyVGrid(columns: PosterGrid.columns(wide: false, compact: false), spacing: Metrics.gridRowSpacing) {
                content()
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
            .focusable()
            .focusEffectDisabled()
            .focused($focusedGrid, equals: kind)
            .onDeleteCommand { deleteTiles(tileSelection) }
            .onKeyPress(.return) { openAnchorTile() }
        }
    }

    // MARK: Tiles

    /// A show. Not a button: the click selects, the double-click opens — the
    /// same reading `MediaGrid` gives a library tile.
    private func seriesTile(_ show: DownloadSeries) -> some View {
        DownloadPosterCard(
            title: show.title,
            subtitle: show.subtitle,
            posterURL: show.posterURL,
            width: nil,
            unwatched: show.unwatched
        )
        .contentShape(Rectangle())
        .macTileState(isSelected: tileSelection.contains(show.id))
        .onTapGesture { clickTile(show.id, in: .shows) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { app.push(.downloadedSeries(show.id)) })
        .contextMenu { seriesMenu(show) }
        .help(show.title)
        .accessibilityAddTraits(tileSelection.contains(show.id) ? .isSelected : [])
    }

    private func filmTile(_ film: DownloadRecord) -> some View {
        DownloadPosterCard(
            title: film.title,
            subtitle: film.quality,
            posterURL: film.artURL ?? film.seriesArtURL,
            width: nil,
            progress: film.watchedFraction,
            watched: film.played
        )
        .contentShape(Rectangle())
        .macTileState(isSelected: tileSelection.contains(film.itemId))
        .onTapGesture { clickTile(film.itemId, in: .films) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { player.playLocal(film) })
        .contextMenu { filmMenu(film) }
        .help(film.title)
        .accessibilityAddTraits(tileSelection.contains(film.itemId) ? .isSelected : [])
    }

    @ViewBuilder
    private func seriesMenu(_ show: DownloadSeries) -> some View {
        let targets = tilesToActOn(show.id)
        Button { app.push(.downloadedSeries(show.id)) } label: {
            Label("Open", systemImage: "chevron.right")
        }
        if let start = show.resumePoint {
            Button { player.playLocal(start) } label: {
                Label(show.unwatched > 0 ? "Play Next" : "Play", systemImage: "play.fill")
            }
        }
        if show.records.count > 1 {
            Button { player.startShuffle(show.records) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
        }
        Divider()
        Button {
            openWindow(id: RouteWindow.id, value: Route.downloadedSeries(show.id))
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        Button { downloads.reveal(itemIds: records(inTiles: targets).map(\.itemId)) } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) { deleteTiles(targets) } label: {
            Label(targets.count > 1 ? "Delete \(targets.count) Items…" : "Delete Show…", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func filmMenu(_ film: DownloadRecord) -> some View {
        let targets = tilesToActOn(film.itemId)
        Button { player.playLocal(film) } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button {
            downloads.setPlayed(film.itemId, played: !film.played)
        } label: {
            Label(
                film.played ? "Mark Unwatched" : "Mark Watched",
                systemImage: film.played ? "arrow.uturn.backward.circle" : "checkmark.circle"
            )
        }
        Divider()
        Button {
            openWindow(id: ItemWindow.id, value: film.itemId)
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        Button { downloads.reveal(itemIds: records(inTiles: targets).map(\.itemId)) } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) { deleteTiles(targets) } label: {
            Label(targets.count > 1 ? "Delete \(targets.count) Items…" : "Delete…", systemImage: "trash")
        }
    }

    /// The click, read with whatever keys were down: ⌘ toggles the tile, a
    /// plain click is the new selection. Rows and tiles never share one.
    private func clickTile(_ id: String, in kind: GridKind) {
        focusedGrid = kind
        rowSelection = []
        if NSEvent.modifierFlags.contains(.command) {
            if tileSelection.contains(id) { tileSelection.remove(id) } else { tileSelection.insert(id) }
        } else {
            tileSelection = [id]
        }
        tileAnchor = id
    }

    /// A menu opened on a selected tile acts on the whole selection; opened
    /// on any other tile, on that tile alone.
    private func tilesToActOn(_ id: String) -> Set<String> {
        tileSelection.contains(id) ? tileSelection : [id]
    }

    /// Return: the show or film last clicked, if it is still selected.
    private func openAnchorTile() -> KeyPress.Result {
        guard let id = tileAnchor, tileSelection.contains(id) else { return .ignored }
        let groups = DownloadGroups.current()
        if let show = groups.series.first(where: { $0.id == id }) {
            app.push(.downloadedSeries(show.id))
            return .handled
        }
        if let film = groups.films.first(where: { $0.itemId == id }) {
            player.playLocal(film)
            return .handled
        }
        return .ignored
    }

    /// Every record behind a set of tiles — a show's episodes, a film.
    private func records(inTiles ids: Set<String>) -> [DownloadRecord] {
        let groups = DownloadGroups.current()
        var out: [DownloadRecord] = []
        for show in groups.series where ids.contains(show.id) { out += show.records }
        out += groups.films.filter { ids.contains($0.itemId) }
        return out
    }

    /// Delete key on tiles, and the tiles' menus: always confirmed, because
    /// what goes is on disk and not cheap to fetch again.
    private func deleteTiles(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let groups = DownloadGroups.current()
        let shows = groups.series.filter { ids.contains($0.id) }
        let films = groups.films.filter { ids.contains($0.itemId) }
        if shows.count == 1, films.isEmpty {
            pendingDeletion = .series(shows[0])
            return
        }
        if films.count == 1, shows.isEmpty {
            let film = films[0]
            pendingDeletion = DownloadDeletion(
                title: "Delete “\(film.title)”?",
                message: "\(film.quality) · \(Format.bytes(max(film.receivedBytes, film.totalBytes)))",
                confirmLabel: "Delete",
                ids: [film.itemId]
            )
            return
        }
        let records = shows.flatMap(\.records) + films
        let bytes = records.reduce(Int64(0)) { $0 + max($1.receivedBytes, $1.totalBytes) }
        pendingDeletion = DownloadDeletion(
            title: "Delete \(ids.count) items?",
            message: "\(records.count) file\(records.count == 1 ? "" : "s") · \(Format.bytes(bytes))",
            confirmLabel: "Delete \(ids.count) Items",
            ids: records.map(\.itemId)
        )
    }

    // MARK: Rows

    /// The queue's context menu, on the selection or on the row clicked.
    /// What is offered follows what the rows are: a transfer is stopped, a
    /// waiting entry removed, a failure retried or deleted.
    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        let active = running.filter { ids.contains($0.itemId) }
        let waiting = downloads.queue.filter { ids.contains($0.itemId) }
        let broken = failed.filter { ids.contains($0.itemId) }

        if !active.isEmpty {
            Button {
                for record in active { downloads.cancel(record.itemId) }
            } label: {
                Label(active.count > 1 ? "Stop Downloads" : "Stop Download", systemImage: "xmark.circle")
            }
        }
        if !waiting.isEmpty {
            Button {
                for entry in waiting { downloads.cancelQueued(entry.itemId) }
            } label: {
                Label("Remove from Queue", systemImage: "xmark.circle")
            }
        }
        if !broken.isEmpty {
            Button {
                for record in broken { downloads.retry(record.itemId) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                downloads.delete(broken.map(\.itemId))
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        if ids.count == 1, let id = ids.first {
            Divider()
            // What is on disk so far: a transfer's partial file, a failure's
            // folder. A waiting entry has nothing there yet.
            if downloads.record(for: id) != nil {
                Button { downloads.reveal(itemIds: [id]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            Button {
                openWindow(id: ItemWindow.id, value: id)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
    }

    /// The Delete key on rows. Nothing finished is touched, so nothing is
    /// asked: a transfer stops, a waiting entry leaves, a failure is dropped.
    private func removeRows(_ ids: Set<String>) {
        for record in running where ids.contains(record.itemId) { downloads.cancel(record.itemId) }
        for entry in downloads.queue where ids.contains(entry.itemId) { downloads.cancelQueued(entry.itemId) }
        let broken = failed.filter { ids.contains($0.itemId) }.map(\.itemId)
        if !broken.isEmpty { downloads.delete(broken) }
        rowSelection = []
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // The same pause the download Live Activity has a button for on
            // a phone.
            Button {
                downloads.setPaused(!downloads.isPaused)
            } label: {
                Label(
                    downloads.isPaused ? "Resume Downloads" : "Pause Downloads",
                    systemImage: downloads.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .help(downloads.isPaused ? "Resume Downloads" : "Pause Downloads")
            .disabled(!downloads.isPaused && running.isEmpty && downloads.queue.isEmpty)

            Button {
                Task { await sync() }
            } label: {
                if isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sync Progress", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .help(syncHelp)
            .disabled(isSyncing || client.isOffline)

            Button {
                DownloadManager.revealInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show Downloads in Finder")

            manageMenu
        }
    }

    private var syncHelp: String {
        let n = downloads.pendingSyncCount
        guard n > 0 else { return "Sync Watched Progress with Jellyfin" }
        return "Sync Watched Progress with Jellyfin · \(n.formatted()) item\(n == 1 ? "" : "s") waiting"
    }

    /// Clearing space is the one thing this page exists for that had nowhere
    /// to be done from: everything used to be one row and one trash can at a
    /// time.
    private var manageMenu: some View {
        // Films and episodes only — see `DownloadManager.Tally.watched`.
        let watched = downloads.tally.watched
        return Menu {
            Button("Retry All Failed") { downloads.retryAllFailed() }
                .disabled(failed.isEmpty)
            Button("Clear Queue…") { confirmingClearQueue = true }
                .disabled(downloads.queue.isEmpty)
            Divider()
            Button("Delete Watched Downloads…") {
                pendingDeletion = DownloadDeletion(
                    title: "Delete everything you've watched?",
                    message: "\(watched.count) item\(watched.count == 1 ? "" : "s") · \(Format.bytes(bytes(of: watched)))",
                    confirmLabel: "Delete \(watched.count) Download\(watched.count == 1 ? "" : "s")",
                    ids: watched.map(\.itemId)
                )
            }
            .disabled(watched.isEmpty)
            Button("Delete All Downloads…", role: .destructive) {
                let all = downloads.records
                pendingDeletion = DownloadDeletion(
                    title: "Delete every download?",
                    message: "\(all.count) item\(all.count == 1 ? "" : "s") · \(Format.bytes(downloads.totalBytesOnDisk)) will be removed from this Mac, and anything still queued is cancelled.",
                    confirmLabel: "Delete Everything",
                    ids: all.map(\.itemId),
                    clearsQueue: true
                )
            }
            .disabled(downloads.records.isEmpty)
        } label: {
            Label("Manage", systemImage: "ellipsis.circle")
        }
        .help("Manage Downloads")
    }

    /// Send what is waiting, then ask the server what it knows. Success shows
    /// in the toolbar tooltip's count going to nothing; only a failure is
    /// said, as an alert.
    private func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let result = await OfflineProgress.sync()
        await OfflineProgress.refreshFromServer()
        if result.failed > 0 {
            app.presentAlert(
                title: "Couldn't Sync",
                message: "The watched progress of \(result.failed) item\(result.failed == 1 ? "" : "s") couldn't be sent to Jellyfin. Check the connection and try again."
            )
        }
    }

    private func bytes(of records: [DownloadRecord]) -> Int64 {
        records.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) }
    }
}

// MARK: - Queue rows

/// A transfer in flight: name, a native bar, the bytes, and a stop button.
struct MacTransferRow: View {
    /// As the list has it. What is drawn is `live`: the byte counts change
    /// twice a second and only this row reads them, so only this row redraws
    /// for them — see `DownloadManager.liveProgress`.
    let listed: DownloadRecord
    var onStop: () -> Void

    init(record: DownloadRecord, onStop: @escaping () -> Void) {
        listed = record
        self.onStop = onStop
    }

    private var record: DownloadRecord { DownloadManager.shared.live(listed) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).lineLimit(1)
                // A transcode has no length until the server has finished
                // making it; the system's indeterminate bar says so.
                Group {
                    if let fraction = record.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .controlSize(.small)
                HStack {
                    Text(record.quality)
                    Spacer()
                    Text(progressText)
                        .monospacedDigit()
                        // Digits roll rather than snap as the bytes climb.
                        .contentTransition(.numericText())
                        .animation(.default, value: progressText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Why the same episode is downloading a second time. Without
                // this the transfer restarts from nothing for no stated
                // reason, which reads as a fault in the app rather than as
                // the app working around one in what it was sent.
                if record.verifyFailures > 0 {
                    Label("The first copy arrived incomplete — fetching it again", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Button(action: onStop) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stop Download")
            .accessibilityLabel("Stop downloading \(record.title)")
        }
        .padding(.vertical, 3)
        .macHover(cornerRadius: 6, inset: 4)
    }

    private var progressText: String {
        let received = Format.bytes(record.receivedBytes)
        guard let total = record.progressTotal else { return received }
        // The tilde is the whole disclosure: past that point the bar is full
        // and the bytes are still climbing, and this is what says why.
        let denominator = (total.estimated ? "~" : "") + Format.bytes(total.bytes)
        guard let fraction = record.fraction else { return "\(received) / \(denominator)" }
        return "\(Int(fraction * 100))% · \(received) / \(denominator)"
    }
}

/// Something waiting its turn.
struct MacQueueRow: View {
    let entry: QueuedDownload
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isRetry ? "arrow.clockwise" : "clock")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.quality)
                    // Why the app put it back here itself — a dropped
                    // connection, a stall — and how long it is waiting before
                    // asking again.
                    if let reason = entry.reason {
                        Text("·")
                        Text(reason).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from Queue")
            .accessibilityLabel("Remove \(entry.title) from the queue")
        }
        .padding(.vertical, 2)
        .macHover(cornerRadius: 6, inset: 4)
    }
}

/// A transfer that stopped on an error, with the way to try it again.
struct MacFailedRow: View {
    let record: DownloadRecord
    var onRetry: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(record.errorMessage ?? "Transfer stopped")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(record.errorMessage ?? "Transfer stopped")
            }
            Spacer(minLength: 8)
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Retry")
            .accessibilityLabel("Retry \(record.title)")
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete")
            .accessibilityLabel("Delete \(record.title)")
        }
        .padding(.vertical, 2)
        .macHover(cornerRadius: 6, inset: 4)
    }
}

// MARK: - One downloaded show

/// A show's episodes as a list under season headers. The title is the
/// window's; the counts and the size are its subtitle; the actions are in the
/// toolbar — nothing is said twice.
struct MacDownloadedSeriesView: View {
    /// The key `DownloadGroups` gave the show, not necessarily a server id.
    let seriesKey: String

    @Environment(AppModel.self) private var app
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var downloads = DownloadManager.shared
    @State private var pendingDeletion: DownloadDeletion?
    @State private var selection: Set<String> = []

    private var show: DownloadSeries? {
        DownloadGroups.series(id: seriesKey)
    }

    var body: some View {
        Group {
            if let show {
                list(show)
            } else {
                EmptyState(
                    symbol: "trash",
                    title: "Nothing Left Here",
                    message: "Every episode of this show has been deleted from this Mac."
                )
            }
        }
        .navigationTitle(show?.title ?? "Downloads")
        .navigationSubtitle(subtitle)
        .toolbar {
            if let show { toolbar(show) }
        }
        .downloadDeletionDialog($pendingDeletion) { ids in
            downloads.delete(ids)
            selection = []
            // The last episode taking the page with it is better than leaving
            // an empty screen the back button is the only way out of.
            if show == nil { dismiss() }
        }
    }

    /// "2 seasons · 14 episodes · 9.8 GB · 3 unwatched".
    private var subtitle: String {
        guard let show else { return "" }
        var parts = [show.subtitle, Format.bytes(show.bytes)]
        if show.unwatched > 0 { parts.append("\(show.unwatched) unwatched") }
        return parts.joined(separator: " · ")
    }

    private func list(_ show: DownloadSeries) -> some View {
        List(selection: $selection) {
            ForEach(show.seasons) { season in
                Section {
                    ForEach(season.records) { record in
                        DownloadedRow(record: record, showsContext: false, fallbackPosterURL: show.posterURL) {
                            player.playLocal(record)
                        } onDelete: {
                            confirmDelete([record.itemId], in: show)
                        } onToggleWatched: {
                            downloads.setPlayed(record.itemId, played: !record.played)
                        }
                    }
                } header: {
                    HStack {
                        Text(season.title)
                        Spacer()
                        Text("\(season.records.count) episode\(season.records.count == 1 ? "" : "s") · \(Format.bytes(season.bytes))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { ids in
            episodeMenu(ids, in: show)
        } primaryAction: { ids in
            // Double-click: the first of what was clicked, in the show's order.
            if let record = show.records.first(where: { ids.contains($0.itemId) }) {
                player.playLocal(record)
            }
        }
        .onDeleteCommand { confirmDelete(selection, in: show) }
    }

    @ViewBuilder
    private func episodeMenu(_ ids: Set<String>, in show: DownloadSeries) -> some View {
        let records = show.records.filter { ids.contains($0.itemId) }
        if records.count == 1, let record = records.first {
            Button { player.playLocal(record) } label: {
                Label("Play", systemImage: "play.fill")
            }
        }
        if !records.isEmpty {
            // One verb for the lot: watched if any is not, unwatched once all are.
            let allPlayed = records.allSatisfy(\.played)
            Button {
                for record in records { downloads.setPlayed(record.itemId, played: !allPlayed) }
            } label: {
                Label(
                    allPlayed ? "Mark Unwatched" : "Mark Watched",
                    systemImage: allPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle"
                )
            }
            Divider()
            if records.count == 1, let record = records.first {
                Button { openWindow(id: ItemWindow.id, value: record.itemId) } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
            Button { downloads.reveal(itemIds: records.map(\.itemId)) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { confirmDelete(ids, in: show) } label: {
                Label(records.count > 1 ? "Delete \(records.count) Episodes…" : "Delete Episode…", systemImage: "trash")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ show: DownloadSeries) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let start = show.resumePoint {
                Button { player.playLocal(start) } label: {
                    Label(show.unwatched > 0 ? "Play Next" : "Play", systemImage: "play.fill")
                }
                .help(show.unwatched > 0 ? "Play the Next Unwatched Episode" : "Play from the Start")
            }
            if show.records.count > 1 {
                Button { player.startShuffle(show.records) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .help("Shuffle Every Episode")
            }
            Button { downloads.reveal(itemIds: show.records.map(\.itemId)) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show the Episodes in Finder")
            Menu {
                ForEach(show.seasons) { season in
                    Button("Delete \(season.title)…") {
                        pendingDeletion = .season(season, show: show.title)
                    }
                }
                let watched = show.records.filter(\.played)
                Button("Delete Watched Episodes…") {
                    pendingDeletion = DownloadDeletion(
                        title: "Delete the watched episodes of \(show.title)?",
                        message: "\(watched.count) episode\(watched.count == 1 ? "" : "s") · \(Format.bytes(watched.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) }))",
                        confirmLabel: "Delete \(watched.count) Episode\(watched.count == 1 ? "" : "s")",
                        ids: watched.map(\.itemId)
                    )
                }
                .disabled(watched.isEmpty)
                Divider()
                Button("Delete Show…", role: .destructive) {
                    pendingDeletion = .series(show)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete Episodes, a Season or the Show")
        }
    }

    /// The Delete key and the menus: a whole season or the show go through
    /// their own wording; anything else is counted.
    private func confirmDelete(_ ids: Set<String>, in show: DownloadSeries) {
        let records = show.records.filter { ids.contains($0.itemId) }
        guard !records.isEmpty else { return }
        if records.count == show.records.count {
            pendingDeletion = .series(show)
            return
        }
        if let season = show.seasons.first(where: { Set($0.records.map(\.itemId)) == Set(records.map(\.itemId)) }) {
            pendingDeletion = .season(season, show: show.title)
            return
        }
        let n = records.count
        pendingDeletion = DownloadDeletion(
            title: n == 1 ? "Delete “\(records[0].name)”?" : "Delete \(n) episodes of \(show.title)?",
            message: "\(Format.bytes(records.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) })) will be removed from this Mac.",
            confirmLabel: n == 1 ? "Delete" : "Delete \(n) Episodes",
            ids: records.map(\.itemId)
        )
    }
}

// MARK: - Finder

extension DownloadManager {
    /// Selects the downloaded files in Finder — the media file where the
    /// transfer finished, the item's folder where it is still coming or
    /// failed, and the downloads folder itself when nothing of the sort is
    /// on disk yet.
    @MainActor
    func reveal(itemIds: [String]) {
        let fm = FileManager.default
        let urls = itemIds.compactMap { id -> URL? in
            if let record = record(for: id), let media = mediaURL(for: record) { return media }
            let folder = Self.folder(for: id)
            return fm.fileExists(atPath: folder.path) ? folder : nil
        }
        guard !urls.isEmpty else { return Self.revealInFinder() }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

#endif
