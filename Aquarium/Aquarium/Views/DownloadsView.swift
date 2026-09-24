//  Downloads: what's on this device, what's transferring, what's waiting, and
//  what failed. Everything here works with no server at all.
//
//  What is already downloaded is presented the way the rest of the app presents
//  a library — a grid of posters, one per show and one per film — rather than as
//  a list of every episode title. A show opens into its own page, which is where
//  its seasons, its episodes and the delete controls for both live.

import SwiftUI

#if !os(tvOS)

struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    @State private var downloads = DownloadManager.shared
    @State private var isSyncing = false
    @State private var pendingDeletion: DownloadDeletion?

    #if os(iOS)
    /// Download All Music, in its two steps: the library being read, and then
    /// what was found, waiting on a yes.
    @State private var musicSweep: (found: Int, total: Int)?
    @State private var allMusicPlan: AllMusicPlan?

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    /// How many rows of a list that can run to thousands are drawn.
    private static let listPreview = 25

    // All from one pass over the records, kept until they change — see
    // `DownloadManager.tally`.
    private var running: [DownloadRecord] { downloads.tally.running }
    private var failed: [DownloadRecord] { downloads.tally.failed }
    private var completeCount: Int { downloads.tally.completeCount }

    private var series: [DownloadSeries] { DownloadGroups.current().series }
    private var films: [DownloadRecord] { DownloadGroups.current().films }

    /// The volume's free space, asked of the file system when the page opens
    /// and when a download finishes or goes — not on every redraw, which is
    /// what reading it in `body` did.
    @State private var freeSpace: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summary

                if !running.isEmpty {
                    section("Downloading") {
                        ForEach(running) { record in
                            TransferRow(record: record) {
                                downloads.cancel(record.itemId)
                            }
                        }
                    }
                }

                if !downloads.queue.isEmpty {
                    section("Up next · \(downloads.queue.count.formatted())") {
                        // The head of the queue, not the queue. A music
                        // library is thousands of entries, this stack is not a
                        // lazy one, and every song that finished rebuilt a row
                        // for each of them — the whole app ran at the speed
                        // of that.
                        ForEach(downloads.queue.prefix(Self.listPreview)) { entry in
                            HStack {
                                Image(systemName: entry.isRetry ? "arrow.clockwise" : "clock")
                                    .foregroundStyle(Theme.textDim)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).lineLimit(1).foregroundStyle(Theme.text)
                                    Text(entry.quality).font(.caption).foregroundStyle(Theme.textDim)
                                    // Why the app put it back here itself — a
                                    // dropped connection, a stall — and how long
                                    // it is waiting before asking again.
                                    if let reason = entry.reason {
                                        Text(reason).font(.caption).foregroundStyle(Theme.warn)
                                    }
                                }
                                Spacer()
                                Button("Remove") { downloads.cancelQueued(entry.itemId) }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                        if downloads.queue.count > Self.listPreview {
                            Text("and \((downloads.queue.count - Self.listPreview).formatted()) more waiting")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        HStack(spacing: 18) {
                            // The same pause the download Live Activity has a
                            // button for; this is where one set from the Lock
                            // Screen is found and lifted.
                            Button(downloads.isPaused ? "Resume downloads" : "Pause downloads") {
                                downloads.setPaused(!downloads.isPaused)
                            }
                            .foregroundStyle(Theme.link)
                            Button("Clear the queue") {
                                let n = downloads.clearQueue()
                                app.toast("Removed \(n) item\(n == 1 ? "" : "s") from the queue", tone: .ok)
                            }
                            .foregroundStyle(Theme.danger)
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                    }
                }

                if !failed.isEmpty {
                    section("Failed · \(failed.count.formatted())") {
                        ForEach(failed.prefix(Self.listPreview)) { record in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.title).lineLimit(1).foregroundStyle(Theme.text)
                                    Text(record.errorMessage ?? "Transfer stopped")
                                        .font(.caption)
                                        .foregroundStyle(Theme.danger)
                                }
                                Spacer()
                                Button("Retry") { downloads.retry(record.itemId) }
                                    .buttonStyle(.bordered)
                                Button {
                                    downloads.delete(record.itemId)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.danger)
                            }
                        }
                        if failed.count > Self.listPreview {
                            Text("and \((failed.count - Self.listPreview).formatted()) more")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        if failed.count > 1 {
                            HStack(spacing: 10) {
                                Button("Retry all \(failed.count)") {
                                    let n = downloads.retryAllFailed()
                                    app.toast("Queued \(n) retr\(n == 1 ? "y" : "ies")", tone: .ok)
                                }
                                .buttonStyle(.bordered)
                                Button("Clear failed", role: .destructive) {
                                    let ids = failed.map(\.itemId)
                                    let n = downloads.delete(ids)
                                    app.toast("Removed \(n) failed download\(n == 1 ? "" : "s")", tone: .ok)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if completeCount == 0, running.isEmpty, downloads.queue.isEmpty, failed.isEmpty {
                    EmptyState(
                        symbol: "arrow.down.circle",
                        title: "Nothing downloaded",
                        message: "Anything you download from a detail page is kept on this device and plays without a server — including when you're offline."
                    )
                }

                #if os(iOS)
                audioDoors
                #endif

                // Grouped once rather than once per reference: every read walks
                // and sorts the whole record set.
                let shows = series
                let movies = films

                if !shows.isEmpty {
                    grid(movies.isEmpty ? "On this device" : "Shows") {
                        ForEach(shows) { show in
                            seriesCard(show)
                        }
                    }
                }

                if !movies.isEmpty {
                    grid(shows.isEmpty ? "On this device" : "Films") {
                        ForEach(movies) { film in
                            filmCard(film)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Downloads")
        .paletteBar()
        .downloadDeletionDialog($pendingDeletion) { ids in
            let n = downloads.delete(ids)
            app.toast("Deleted \(n) download\(n == 1 ? "" : "s")", tone: .ok)
        }
        #if os(iOS)
        .alert(
            allMusicPlan?.title ?? "",
            isPresented: Binding(get: { allMusicPlan != nil }, set: { if !$0 { allMusicPlan = nil } }),
            presenting: allMusicPlan
        ) { plan in
            if plan.fits {
                Button("Download \(plan.fresh.count.formatted()) song\(plan.fresh.count == 1 ? "" : "s")") {
                    Task { await MusicDownloads.download(plan.fresh) }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { plan in
            Text(plan.message)
        }
        #endif
        .task {
            await OfflineProgress.refreshFromServer()
        }
        .task(id: completeCount) {
            freeSpace = await Task.detached(priority: .utility) { DownloadManager.freeSpace() }.value
        }
    }

    // MARK: - Tiles

    private func seriesCard(_ show: DownloadSeries) -> some View {
        Button {
            app.push(.downloadedSeries(show.id))
        } label: {
            DownloadPosterCard(
                title: show.title,
                subtitle: show.subtitle,
                posterURL: show.posterURL,
                width: PosterGrid.cardWidth(wide: false, compact: isCompact),
                unwatched: show.unwatched
            )
        }
        .buttonStyle(PosterButtonStyle())
        .contextMenu {
            Button { app.push(.downloadedSeries(show.id)) } label: {
                Label("Open", systemImage: "chevron.right")
            }
            if let start = show.resumePoint {
                Button { player.playLocal(start) } label: {
                    Label("Play", systemImage: "play.fill")
                }
            }
            if show.records.count > 1 {
                Button { player.startShuffle(show.records) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }
            Button(role: .destructive) { pendingDeletion = .series(show) } label: {
                Label("Delete this show", systemImage: "trash")
            }
        }
    }

    private func filmCard(_ film: DownloadRecord) -> some View {
        Button {
            player.playLocal(film)
        } label: {
            DownloadPosterCard(
                title: film.title,
                subtitle: film.quality,
                posterURL: film.artURL ?? film.seriesArtURL,
                width: PosterGrid.cardWidth(wide: false, compact: isCompact),
                progress: film.watchedFraction,
                watched: film.played
            )
        }
        .buttonStyle(PosterButtonStyle())
        .contextMenu {
            Button { player.playLocal(film) } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                downloads.setPlayed(film.itemId, played: !film.played)
            } label: {
                Label(
                    film.played ? "Mark unwatched" : "Mark watched",
                    systemImage: film.played ? "arrow.uturn.backward.circle" : "checkmark.circle"
                )
            }
            Button(role: .destructive) { downloads.delete(film.itemId) } label: {
                Label("Delete download", systemImage: "trash")
            }
        }
    }

    // MARK: - Music and audiobooks

    #if os(iOS)
    /// The way into the downloaded songs and audiobooks.
    ///
    /// They are counted in "items on this device" above and drawn nowhere
    /// below — the grids are shows and films — so a phone with nothing but
    /// music on it opened this page to a total and an empty screen. A door
    /// each rather than a tile per record: a music library is thousands of
    /// them, and the pages behind these already sort it into artists, albums
    /// and playlists.
    @ViewBuilder
    private var audioDoors: some View {
        let songs = downloads.tally.songs
        let books = downloads.tally.books
        if songs > 0 || books > 0 {
            VStack(spacing: 10) {
                if songs > 0 {
                    audioDoor(
                        "Music", symbol: "music.note",
                        detail: "\(songs.formatted()) song\(songs == 1 ? "" : "s")",
                        route: .downloaded
                    )
                }
                if books > 0 {
                    audioDoor(
                        "Audiobooks", symbol: "book",
                        detail: "\(books.formatted()) audiobook\(books == 1 ? "" : "s")",
                        route: .downloadedBooks
                    )
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    private func audioDoor(_ title: String, symbol: String, detail: String, route: MusicRoute) -> some View {
        Button {
            app.push(.music(route))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    Text(detail).font(.caption).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Chrome

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(completeCount.formatted()) item\(completeCount == 1 ? "" : "s") on this device")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                    Text(Format.bytes(downloads.totalBytesOnDisk)
                        + (freeSpace.map { " · \(Format.bytes($0)) free" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                if downloads.pendingSyncCount > 0 {
                    Button {
                        Task {
                            isSyncing = true
                            let result = await OfflineProgress.sync()
                            isSyncing = false
                            app.toast(
                                result.synced > 0
                                    ? "Synced \(result.synced) item\(result.synced == 1 ? "" : "s") to Jellyfin"
                                    : "Couldn't reach the server to sync",
                                tone: result.failed > 0 ? .error : .ok
                            )
                        }
                    } label: {
                        if isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Sync \(downloads.pendingSyncCount)", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSyncing || client.isOffline)
                }
                #if os(macOS)
                Button {
                    DownloadManager.revealInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Show the downloads folder in Finder")
                #endif
                manageMenu
            }

            #if os(iOS)
            if let sweep = musicSweep {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(sweep.total > 0
                        ? "Reading your music library… \(sweep.found.formatted()) of \(sweep.total.formatted())"
                        : "Reading your music library…")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }
            #endif

            @Bindable var prefs = prefs
            HStack {
                Text("Parallel downloads")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                Picker("", selection: $prefs.downloadConcurrency) {
                    ForEach(1...Preferences.maxDownloadConcurrency, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
        }
        .padding(Metrics.gutter)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Metrics.gutter)
    }

    /// Clearing space is the one thing this screen exists for that had nowhere
    /// to be done from: everything used to be one row and one trash can at a
    /// time.
    @ViewBuilder
    private var manageMenu: some View {
        // Films and episodes only — see `DownloadManager.Tally.watched`.
        let watched = downloads.tally.watched
        Menu {
            #if os(iOS)
            if offersAllMusic {
                Button {
                    Task { await planAllMusic() }
                } label: {
                    Label("Download All Music", systemImage: "music.note.list")
                }
                .disabled(musicSweep != nil)
                Divider()
            }
            #endif
            if !watched.isEmpty {
                Button {
                    pendingDeletion = DownloadDeletion(
                        title: "Delete everything you've watched?",
                        message: "\(watched.count) item\(watched.count == 1 ? "" : "s") · \(Format.bytes(bytes(of: watched)))",
                        confirmLabel: "Delete \(watched.count) download\(watched.count == 1 ? "" : "s")",
                        ids: watched.map(\.itemId)
                    )
                } label: {
                    Label("Delete watched · \(watched.count)", systemImage: "checkmark.circle")
                }
            }
            if !downloads.records.isEmpty {
                Button(role: .destructive) {
                    let all = downloads.records
                    pendingDeletion = DownloadDeletion(
                        title: "Delete every download?",
                        message: "\(all.count) item\(all.count == 1 ? "" : "s") · \(Format.bytes(downloads.totalBytesOnDisk)) will be removed from this device, and anything still queued is cancelled.",
                        confirmLabel: "Delete everything",
                        ids: all.map(\.itemId),
                        clearsQueue: true
                    )
                } label: {
                    Label("Delete all downloads", systemImage: "trash")
                }
            }
        } label: {
            Label("Manage downloads", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        #if os(macOS)
        .help("Manage downloads")
        #endif
        .disabled(downloads.records.isEmpty && !offersAllMusic)
    }

    /// Whether there is a music library to download, and a server to download
    /// it from.
    private var offersAllMusic: Bool {
        #if os(iOS)
        app.hasMusic && !client.showsOffline
        #else
        false
        #endif
    }

    #if os(iOS)
    /// Read the whole music library, take out what is already here or on its
    /// way, and put the rest — counted and weighed — in front of the person
    /// before anything is queued. A music library can be bigger than a phone.
    private func planAllMusic() async {
        musicSweep = (0, 0)
        defer { musicSweep = nil }
        let songs: [BaseItem]
        do {
            songs = try await MusicDownloads.everySong { musicSweep = ($0, $1) }
        } catch is CancellationError {
            return
        } catch {
            return app.toast("Couldn't read the music library: \(error.localizedDescription)", tone: .error)
        }
        guard !songs.isEmpty else { return app.toast("There's no music on this server", tone: .info) }
        let fresh = songs.filter {
            downloads.record(for: $0.Id)?.status != .complete && !downloads.isQueuedOrRunning($0.Id)
        }
        guard !fresh.isEmpty else {
            return app.toast("All \(songs.count.formatted()) songs are already on this device or on their way", tone: .ok)
        }
        let original = DownloadQualities.all.first { $0.original } ?? DownloadQualities.all[0]
        allMusicPlan = AllMusicPlan(
            fresh: fresh,
            alreadyHere: songs.count - fresh.count,
            verdict: DownloadManager.checkSpace(for: fresh, quality: original)
        )
    }
    #endif

    private func bytes(of records: [DownloadRecord]) -> Int64 {
        records.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
            content()
        }
        .padding(.horizontal, Metrics.gutter)
    }

    @ViewBuilder
    private func grid(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Metrics.gutter)
            LazyVGrid(
                columns: PosterGrid.columns(wide: false, compact: isCompact),
                spacing: Metrics.gridRowSpacing
            ) {
                content()
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }
}

// MARK: - Download All Music

/// What a sweep of the music library found, as the confirmation words it.
struct AllMusicPlan {
    /// The songs not on this device and not already queued.
    var fresh: [BaseItem]
    var alreadyHere: Int
    var verdict: DownloadManager.SpaceVerdict?

    var fits: Bool { verdict?.fits ?? true }

    var title: String { fits ? "Download all music?" : "Not enough space" }

    var message: String {
        let count = "\(fresh.count.formatted()) song\(fresh.count == 1 ? "" : "s")"
        let skipped = alreadyHere > 0 ? " \(alreadyHere.formatted()) more are already here or queued." : ""
        guard let verdict else {
            return "\(count) will be queued.\(skipped) Songs added to the server later aren't included — run this again to pick them up."
        }
        if verdict.fits {
            return "\(count), about \(Format.bytes(verdict.needed)). There is \(Format.bytes(verdict.free)) free on this device.\(skipped) Songs added to the server later aren't included — run this again to pick them up."
        }
        return "\(count) would need about \(Format.bytes(verdict.needed)), and there is \(Format.bytes(verdict.free)) free on this device. Albums and playlists can be downloaded one at a time from their menus."
    }
}

// MARK: - Deleting more than one thing at a time

/// A delete that takes more than one file with it, held until it's confirmed.
struct DownloadDeletion: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var ids: [String]
    /// "Delete all" also drops what hasn't started yet.
    var clearsQueue: Bool = false

    static func series(_ show: DownloadSeries) -> DownloadDeletion {
        DownloadDeletion(
            title: "Delete \(show.title)?",
            message: "\(show.subtitle) · \(Format.bytes(show.bytes))",
            confirmLabel: "Delete \(show.records.count) episode\(show.records.count == 1 ? "" : "s")",
            ids: show.records.map(\.itemId)
        )
    }

    static func season(_ season: DownloadSeason, show: String) -> DownloadDeletion {
        let n = season.records.count
        return DownloadDeletion(
            title: "Delete \(season.title) of \(show)?",
            message: "\(n) episode\(n == 1 ? "" : "s") · \(Format.bytes(season.bytes))",
            confirmLabel: "Delete \(n) episode\(n == 1 ? "" : "s")",
            ids: season.records.map(\.itemId)
        )
    }
}

extension View {
    /// The one confirmation both Downloads screens put in front of a bulk
    /// delete. Deleting a season is not undoable and not cheap to redo.
    func downloadDeletionDialog(
        _ pending: Binding<DownloadDeletion?>,
        onConfirm: @escaping ([String]) -> Void
    ) -> some View {
        confirmationDialog(
            pending.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { deletion in
            Button(deletion.confirmLabel, role: .destructive) {
                if deletion.clearsQueue { DownloadManager.shared.clearQueue() }
                onConfirm(deletion.ids)
                pending.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: { deletion in
            Text(deletion.message)
        }
    }
}

// MARK: - Tiles

/// A downloaded show or film as a tile — the same shape, size and chrome as the
/// poster cards on Home and in the libraries, built from a record rather than
/// from an item so it draws with no server.
struct DownloadPosterCard: View {
    var title: String
    var subtitle: String
    var posterURL: String?
    var width: CGFloat?
    /// How far into a film you are. Shows carry a count instead.
    var progress: Double?
    var unwatched: Int?
    var watched: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
                .cardChrome()
                .overlay(alignment: .topTrailing) { badge }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let picture = ZStack(alignment: .bottom) {
            RemoteImage(url: posterURL.flatMap(URL.init(string:)))

            if let progress, progress > 0.01 {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.45))
                    Rectangle().fill(Theme.accent)
                        .scaleEffect(x: min(1, max(0, progress)), y: 1, anchor: .leading)
                }
                .frame(height: 3)
            }
        }

        if let width {
            picture.frame(width: width, height: width * 1.5)
        } else {
            picture
                .frame(maxWidth: .infinity)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
        }
    }

    @ViewBuilder
    private var badge: some View {
        Group {
            if let unwatched, unwatched > 0 {
                Text("\(unwatched)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.accentStrong, in: Capsule())
                    .foregroundStyle(.white)
            } else if watched || unwatched == 0 {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .padding(5)
                    .background(Theme.accentStrong, in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(6)
    }
}

// MARK: - Rows

/// The bar for a transfer whose length nobody knows — which is every transcode,
/// since the server can't say how big a file is until it has finished making it.
///
/// Not `ProgressView()` under a linear style: with no value to draw it renders
/// an empty track, and an empty track on this background is a black rectangle
/// sitting there looking like a transfer stuck at nothing. This says the one
/// true thing instead — something is happening, and how far along is not known.
struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelling = false

    private static let height: CGFloat = 4
    private static let segment: CGFloat = 0.32

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let run = width * Self.segment
            Capsule()
                .fill(Theme.accent.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: run)
                        // Reduced motion gets a still bar rather than a still
                        // *empty* bar: the point is that work is in progress,
                        // and that has to survive the animation being off.
                        .offset(x: reduceMotion ? (width - run) / 2 : (travelling ? width : -run))
                }
                .clipShape(Capsule())
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                        travelling = true
                    }
                }
        }
        .frame(height: Self.height)
        .accessibilityLabel("Downloading")
    }
}

struct TransferRow: View {
    /// As the list has it. What is drawn is `live`: the byte counts change
    /// twice a second and only this row reads them, so only this row redraws
    /// for them — see `DownloadManager.liveProgress`.
    let listed: DownloadRecord
    var onCancel: () -> Void

    init(record: DownloadRecord, onCancel: @escaping () -> Void) {
        listed = record
        self.onCancel = onCancel
    }

    private var record: DownloadRecord { DownloadManager.shared.live(listed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.title).lineLimit(1).foregroundStyle(Theme.text)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            if let fraction = record.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            } else {
                IndeterminateBar()
            }
            HStack {
                Text(record.quality).font(.caption).foregroundStyle(Theme.textDim)
                Spacer()
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textDim)
                    // Digits roll rather than snap as the bytes climb.
                    .contentTransition(.numericText())
                    .animation(.default, value: progressText)
            }
            // Why the same episode is downloading a second time. Without this
            // the transfer restarts from nothing for no stated reason, which
            // reads as a fault in the app rather than as the app working
            // around one in what it was sent.
            if record.verifyFailures > 0 {
                Label(
                    "The first copy arrived incomplete — fetching it again",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(Theme.warn)
            }
        }
    }

    private var progressText: String {
        let received = Format.bytes(record.receivedBytes)
        guard let total = record.progressTotal else { return received }
        // The tilde is the whole disclosure: past that point the bar is full and
        // the bytes are still climbing, and this is what says why.
        let denominator = (total.estimated ? "~" : "") + Format.bytes(total.bytes)
        guard let fraction = record.fraction else { return "\(received) / \(denominator)" }
        return "\(Int(fraction * 100))% · \(received) / \(denominator)"
    }
}

struct DownloadedRow: View {
    let record: DownloadRecord
    /// False under a series-and-season heading, which has already said which
    /// show and which season this is.
    var showsContext: Bool = true
    /// The show's poster, for an episode whose own thumbnail the server never
    /// had — better than an empty rectangle, and only ever a last resort.
    var fallbackPosterURL: String?
    var onPlay: () -> Void
    var onDelete: () -> Void
    var onToggleWatched: () -> Void

    /// "The Bear S01E03 · System" everywhere the row stands alone; "3. System"
    /// under a heading that already carries the rest.
    private var displayTitle: String {
        guard !showsContext, record.isEpisode else { return record.title }
        let number = record.episode.map { "\($0). " } ?? ""
        return number + record.name
    }

    /// An episode is a 16:9 still of that episode; a film is its portrait
    /// poster. Drawing an episode as a poster meant borrowing the show's, and
    /// then every row of a season was the same picture.
    @ViewBuilder
    private var thumbnail: some View {
        let fallback = (record.seasonArtURL ?? fallbackPosterURL ?? record.seriesArtURL)
            .flatMap(URL.init(string:))
        let picture = RemoteImage(
            url: record.artURL.flatMap(URL.init(string:)),
            fallbackURL: fallback
        )
        if record.isEpisode {
            picture.frame(width: 104, height: 59).cardChrome(radius: 6)
        } else {
            picture.frame(width: 52, height: 78).cardChrome(radius: 6)
        }
    }

    var body: some View {
        // The row proper and its menu are siblings rather than one inside the
        // other: a Menu nested in a Button's label never gets the tap, which is
        // why these actions had only ever been reachable by holding the row
        // down. The play button keeps all the flexible width, so the menu sits
        // hard against the trailing edge either way.
        HStack(spacing: 4) {
            playButton
            Menu {
                rowActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Options for \(displayTitle)")
        }
    }

    private var playButton: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .lineLimit(2)
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 8) {
                        Text(record.quality).font(.caption).foregroundStyle(Theme.textDim)
                        if record.played {
                            Label("Watched", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        } else if record.positionTicks > 0, record.runTimeTicks > 0 {
                            Text("\(Format.clock(Double(record.positionTicks) / 10_000_000)) in")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        if !record.progressSynced {
                            StatusPill(text: "To sync", tone: .warn)
                        }
                    }
                }

                Spacer(minLength: 8)
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowActions }
    }

    @ViewBuilder
    private var rowActions: some View {
        Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
        Button {
            onToggleWatched()
        } label: {
            Label(
                record.played ? "Mark unwatched" : "Mark watched",
                systemImage: record.played ? "arrow.uturn.backward.circle" : "checkmark.circle"
            )
        }
        Button(role: .destructive, action: onDelete) {
            Label("Delete this episode", systemImage: "trash")
        }
    }
}

#endif
