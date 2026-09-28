//  The library, kept on this device.
//
//  With "Keep a copy of my library" on, every film, show, season and episode
//  the account can see is written to disk once, and from then on the app only
//  asks the server what has changed. Library grids, a show's seasons and a
//  season's episodes are answered from the copy — at once, and with the server
//  unreachable — and posters, logos and episode stills are saved alongside it
//  so a grid never has to wait on a picture it has shown before.
//
//  What "what has changed" costs, because Jellyfin has no feed of it:
//
//  - `MinDateLastSaved` asks for the items whose metadata was saved since the
//    last sync, with every field. That is the expensive half, and it is only
//    ever the handful that changed.
//  - Watched state and favourites are not metadata. Saving them does not move
//    an item's DateLastSaved, so no date filter finds them — and deletions
//    leave nothing behind to ask for at all. Both come from one light sweep per
//    library: every id with its user data and nothing else, a few hundred bytes
//    an item. Anything the sweep lists that the copy doesn't have (added while
//    the filter missed it, or moved from another library) is fetched in full
//    by id; anything the copy has that the sweep doesn't list is gone.
//
//  The cursor is kept in the server's clock, not this device's — see
//  `JellyfinClient.serverNow` — and wound back two minutes, so a device whose
//  clock disagrees with the server's, or a save that lands while a sync is
//  running, is fetched twice rather than missed.

import Foundation
import Observation

@MainActor
@Observable
final class LibraryIndex {
    static let shared = LibraryIndex()

    /// Where a full or partial sync has got to, for Settings to show.
    struct SyncProgress: Equatable {
        var library: String
        var done: Int
        var total: Int
    }

    /// A copy for the signed-in account is in memory and can answer.
    private(set) var isReady = false
    private(set) var syncProgress: SyncProgress?
    /// Posters, logos and stills still to save, while that is running.
    private(set) var artworkProgress: (done: Int, total: Int)?
    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    private(set) var itemCount = 0
    private(set) var artworkBytes: Int64 = 0
    /// Home as the server last drew it, for the moment Home opens and for when
    /// the server can't be asked. See `homeCopy()`.
    private(set) var hasHomeCopy = false
    @ObservationIgnored private var home: HomeCopy?

    var isSyncing: Bool { syncTask != nil }

    @ObservationIgnored private var items: [String: BaseItem] = [:]
    /// Every indexed item under each library, by id.
    @ObservationIgnored private var members: [String: [String]] = [:]
    @ObservationIgnored private var views: [BaseItem] = []
    @ObservationIgnored private var cursor: Date?
    @ObservationIgnored private var owner: String?

    /// Children in the order the server would list them, as ids — looked up
    /// through `items` on the way out, so a watched flag patched into `items`
    /// is never left behind in a stale copy here.
    @ObservationIgnored private var seasonsBySeries: [String: [String]] = [:]
    @ObservationIgnored private var episodesBySeason: [String: [String]] = [:]
    @ObservationIgnored private var episodesBySeries: [String: [String]] = [:]
    /// Sorted and filtered library pages, by query, so paging through a grid
    /// sorts it once rather than once a page.
    @ObservationIgnored private var queryCache: [String: [String]] = [:]

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSyncStarted = Date.distantPast

    private init() {}

    // MARK: - Where it lives

    /// Application Support where the platform has one that is kept. tvOS gives
    /// an app nothing but its caches folder, which the system may empty when
    /// the Apple TV runs short of space; the copy is then simply rebuilt at the
    /// next sync.
    nonisolated static var directory: URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appending(path: "LibraryCopy", directoryHint: .isDirectory)
    }

    nonisolated private static var snapshotURL: URL {
        directory.appending(path: "index.lzfse")
    }

    /// Where a sync that changed nothing records how far it got — see
    /// `saveCursor`.
    nonisolated private static var cursorURL: URL {
        directory.appending(path: "SyncCursor")
    }

    nonisolated private static var homeURL: URL {
        directory.appending(path: "home.lzfse")
    }

    private var isEnabled: Bool { Preferences.shared.keepsLibraryCopy }

    /// Whose library this is. A copy made for one account on one server is
    /// never shown to another.
    private var currentOwner: String? {
        guard let s = JellyfinClient.shared.session else { return nil }
        return "\(s.server)|\(s.userId)"
    }

    // MARK: - Turning it on and off

    func setEnabled(_ enabled: Bool) {
        Task { await ImageLoader.shared.setDiskEnabled(enabled) }
        if enabled {
            Task { await sync(force: true) }
        } else {
            wipe()
        }
    }

    /// Forget the copy: in memory and on disk. Called when the setting goes
    /// off, and on sign-out, so a different account never inherits it.
    func wipe() {
        #if os(iOS) || os(macOS)
        SpotlightIndexer.shared.wipe()
        #endif
        loadTask?.cancel()
        syncTask?.cancel()
        artworkTask?.cancel()
        saveTask?.cancel()
        loadTask = nil
        syncTask = nil
        artworkTask = nil
        saveTask = nil
        items = [:]
        members = [:]
        views = []
        home = nil
        hasHomeCopy = false
        cursor = nil
        owner = nil
        isReady = false
        syncProgress = nil
        artworkProgress = nil
        lastSynced = nil
        lastError = nil
        itemCount = 0
        artworkBytes = 0
        rebuildDerived()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: LibraryIndex.directory)
            await ImageLoader.shared.forgetDisk()
        }
    }

    // MARK: - Loading

    /// Read the saved copy, once per launch. Cheap to call again.
    func prepare() async {
        guard isEnabled, let owner = currentOwner else { return }
        await ImageLoader.shared.setDiskEnabled(true)
        if isReady, self.owner == owner { return }
        if let loadTask { return await loadTask.value }
        let task = Task {
            // The table by id and the season and episode orderings are built
            // here too, beside the decode, rather than on the main actor once
            // it lands: every item hashed into a dictionary and every show's
            // episodes sorted, before Home could draw.
            let (loaded, savedHome) = await Task.detached(priority: .userInitiated) {
                var snapshot = LibraryIndex.readSnapshot()
                // A sync that found nothing new moved the cursor on without
                // rewriting the snapshot; the newer of the two wins.
                if let progress = LibraryIndex.read(SyncCursor.self, from: LibraryIndex.cursorURL),
                   progress.owner == snapshot?.owner,
                   (progress.syncedAt ?? .distantPast) > (snapshot?.syncedAt ?? .distantPast) {
                    snapshot?.cursor = progress.cursor
                    snapshot?.syncedAt = progress.syncedAt
                }
                let loaded = snapshot.map { snapshot in
                    let table = Dictionary(snapshot.items.map { ($0.Id, $0) }, uniquingKeysWith: { _, new in new })
                    return (snapshot, table, LibraryIndex.derive(table))
                }
                return (loaded, LibraryIndex.read(HomeCopy.self, from: LibraryIndex.homeURL))
            }.value
            guard !Task.isCancelled, isEnabled, currentOwner == owner else { return }
            if case let (snapshot, table, derived)? = loaded, snapshot.version == Snapshot.currentVersion,
               snapshot.owner == owner, !isReady {
                apply(snapshot, items: table, derived: derived)
            }
            if home == nil, let savedHome, savedHome.owner == owner {
                home = savedHome
                hasHomeCopy = true
            }
            artworkBytes = await ImageLoader.shared.diskUsage()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func apply(_ snapshot: Snapshot, items table: [String: BaseItem], derived: Derived) {
        items = table
        members = snapshot.members
        views = snapshot.views
        cursor = snapshot.cursor
        owner = snapshot.owner
        lastSynced = snapshot.syncedAt
        itemCount = items.count
        isReady = snapshot.cursor != nil
        install(derived)
    }

    nonisolated private static func readSnapshot() -> Snapshot? {
        read(Snapshot.self, from: snapshotURL)
    }

    nonisolated private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Syncing

    /// Bring the copy up to date: everything the first time, the difference
    /// after that, then any artwork not yet saved.
    ///
    /// `force` skips the minimum gap, which exists because the app becomes
    /// active far more often than a library changes.
    func sync(force: Bool = false, minimumGap: TimeInterval = 60) async {
        guard isEnabled, let owner = currentOwner else { return }
        if let syncTask { return await syncTask.value }
        guard force || Date().timeIntervalSince(lastSyncStarted) >= minimumGap else { return }
        await prepare()
        guard isEnabled, currentOwner == owner else { return }
        lastSyncStarted = Date()
        let task = Task { await runSync(owner: owner) }
        syncTask = task
        await task.value
        syncTask = nil
        startArtwork()
    }

    private static let types = "Movie,Series,Season,Episode,Video,BoxSet"
    private static let heavyPage = 300
    private static let lightPage = 2000

    private func runSync(owner: String) async {
        let client = JellyfinClient.shared
        guard let userId = client.session?.userId else { return }
        lastError = nil
        let startedAt = client.serverNow
        let since = isReady && self.owner == owner ? cursor : nil

        do {
            let fetchedViews = try await client.views()
            let libraries = fetchedViews.filter(Self.isIndexable)

            var items = since == nil ? [:] : self.items
            var members = since == nil ? [:] : self.members
            var changed = since == nil

            for library in libraries {
                try Task.checkCancellation()
                let name = library.Name ?? "Library"
                syncProgress = SyncProgress(library: name, done: 0, total: 0)
                let librarySince = members[library.Id] == nil ? nil : since
                changed = try await syncLibrary(
                    library, name: name, userId: userId, since: librarySince,
                    items: &items, members: &members
                ) || changed
            }

            let libraryIds = Set(libraries.map(\.Id))
            for gone in members.keys where !libraryIds.contains(gone) {
                members[gone] = nil
                changed = true
            }
            if changed {
                let kept = Set(members.values.joined())
                items = items.filter { kept.contains($0.key) }
            }

            // Worked out before anything is assigned, so the table and its
            // orderings change in the same moment rather than a query landing
            // between the two.
            var derived: Derived?
            if changed {
                derived = await Task.detached(priority: .utility) { [items] in LibraryIndex.derive(items) }.value
            }
            try Task.checkCancellation()
            guard isEnabled, currentOwner == owner else { return }
            let previous = self.items
            let previousViews = self.views
            // A favourite or watched flag set here while this sync was still
            // fetching touched `self.items` directly, not this function's own
            // snapshot of it — replacing `self.items` wholesale would revert
            // that tap the moment the sync completes. The live copy's word on
            // those ids wins over what this sync built.
            for id in locallyPatchedIds where items[id] != nil {
                if let live = previous[id] { items[id]?.UserData = live.UserData }
            }
            locallyPatchedIds.removeAll()
            self.items = items
            self.members = members
            self.views = fetchedViews
            self.owner = owner
            cursor = startedAt.addingTimeInterval(-120)
            lastSynced = Date()
            itemCount = items.count
            isReady = true
            if let derived {
                install(derived)
                ItemMutations.shared.changed()
                #if os(iOS) || os(macOS)
                // The system's search follows the copy: what changed goes in
                // again, what is gone comes out. On a first sync that is
                // everything.
                SpotlightIndexer.shared.update(
                    changed: items.values.filter { previous[$0.Id] != $0 },
                    removed: previous.keys.filter { items[$0] == nil }
                )
                #endif
            }
            // The whole library encoded, compressed and written only when some
            // of it changed. The common sync — every return to the app — finds
            // nothing new, and all that moved is the cursor, which goes in a
            // file of its own. A change still waiting on `scheduleSave` is
            // written with everything else, as it was.
            if changed || hasUnsavedChanges || fetchedViews != previousViews {
                await save()
            } else {
                await saveCursor()
            }
        } catch is CancellationError {
            // Turned off, or signed out, part-way through.
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        syncProgress = nil
    }

    /// One library. Returns whether anything in the copy changed.
    private func syncLibrary(
        _ library: BaseItem, name: String, userId: String, since: Date?,
        items: inout [String: BaseItem], members: inout [String: [String]]
    ) async throws -> Bool {
        var changed = false
        let base: [URLQueryItem] = [
            .init(name: "ParentId", value: library.Id),
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: Self.types),
        ]

        // 1. Everything, or everything saved since the last sync, in full.
        var heavy = base + [
            .init(name: "Fields", value: JellyfinClient.indexFields),
        ] + Self.stableOrder
        if let since {
            heavy.append(.init(name: "MinDateLastSaved", value: Self.iso.string(from: since)))
        }
        let full = try await pages(heavy, userId: userId, pageSize: Self.heavyPage) { done, total in
            self.syncProgress = SyncProgress(library: name, done: done, total: total)
        }
        var parentsToRefresh = Set<String>()
        for item in full {
            if items[item.Id] != item { changed = true }
            items[item.Id] = item
            // A new or changed episode changes its season's and show's counts,
            // and saving it does not re-save them.
            if since != nil {
                if let s = item.SeasonId { parentsToRefresh.insert(s) }
                if let s = item.SeriesId { parentsToRefresh.insert(s) }
            }
        }

        // 2. What exists, and its watched state — see the note at the top.
        let light = try await pages(base + [
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "true"),
        ] + Self.stableOrder, userId: userId, pageSize: Self.lightPage) { _, _ in }

        var ids: [String] = []
        ids.reserveCapacity(light.count)
        var missing: [String] = []
        for entry in light where !entry.Id.isEmpty {
            ids.append(entry.Id)
            guard var known = items[entry.Id] else {
                missing.append(entry.Id)
                continue
            }
            if known.UserData != entry.UserData {
                known.UserData = entry.UserData
                items[entry.Id] = known
                changed = true
            }
        }
        if Set(members[library.Id] ?? []) != Set(ids) { changed = true }
        members[library.Id] = ids

        // 3. Anything listed and not held, and the parents of what changed.
        let wanted = Array(Set(missing).union(parentsToRefresh.subtracting(missing)))
        if !wanted.isEmpty {
            for fetched in try await byIds(wanted, userId: userId) {
                items[fetched.Id] = fetched
                changed = true
            }
        }
        return changed
    }

    /// An order that holds still between pages. Paged by `StartIndex` with no
    /// sort (or by name alone), the server is free to order each page's query
    /// differently, and an item that moves across a page boundary is either
    /// listed twice or not at all — and one not listed is one the sweep reads
    /// as deleted. `SortBy` takes no `Id`; `DateCreated` is to the tick, which
    /// breaks the ties a shared name leaves.
    private static let stableOrder: [URLQueryItem] = [
        .init(name: "SortBy", value: "SortName,DateCreated"),
        .init(name: "SortOrder", value: "Ascending"),
    ]

    /// Every page of a query.
    private func pages(
        _ query: [URLQueryItem], userId: String, pageSize: Int,
        progress: (Int, Int) -> Void
    ) async throws -> [BaseItem] {
        var out: [BaseItem] = []
        var total = Int.max
        while out.count < total {
            try Task.checkCancellation()
            let q = query + [
                .init(name: "StartIndex", value: String(out.count)),
                .init(name: "Limit", value: String(pageSize)),
                .init(name: "EnableTotalRecordCount", value: "true"),
            ]
            let page = try await fetch("/Users/\(userId)/Items?\(JellyfinClient.encode(q))")
            out += page.items
            total = page.TotalRecordCount ?? out.count
            progress(out.count, total)
            if page.items.isEmpty { break }
        }
        return out
    }

    private func byIds(_ ids: [String], userId: String) async throws -> [BaseItem] {
        var out: [BaseItem] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let chunk = ids[start..<min(start + 100, ids.count)].joined(separator: ",")
            let q: [URLQueryItem] = [
                .init(name: "Ids", value: chunk),
                .init(name: "Fields", value: JellyfinClient.indexFields),
            ]
            out += try await fetch("/Users/\(userId)/Items?\(JellyfinClient.encode(q))").items
        }
        return out
    }

    /// A request that is allowed to be slow and says nothing about whether the
    /// server is up — a sync running in the background must not put the whole
    /// app into its offline screen because one large page took a while — with
    /// the JSON decoded off the main thread.
    private func fetch(_ path: String) async throws -> ItemsResponse {
        let data = try await JellyfinClient.shared.request(path, countsForOffline: false, patient: true)
        return try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(ItemsResponse.self, from: data)
        }.value
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Libraries whose contents this client shows. Music and the like are out
    /// of scope everywhere else, so they are here too; Live TV is not a
    /// library of items at all.
    static func isIndexable(_ view: BaseItem) -> Bool {
        let excluded = ["boxsets", "playlists", "music", "audiobooks", "books", "podcasts", "livetv"]
        guard let type = view.CollectionType else { return true }
        return !excluded.contains(type)
    }

    // MARK: - Saving

    private func save() async {
        guard let owner else { return }
        hasUnsavedChanges = false
        let snapshot = Snapshot(
            version: Snapshot.currentVersion, owner: owner, cursor: cursor, syncedAt: lastSynced,
            views: views, members: members, items: Array(items.values)
        )
        await Task.detached(priority: .utility) {
            LibraryIndex.write(snapshot)
        }.value
    }

    /// A watched flag or a favourite changed here: saved a moment later, so a
    /// run of them is written once.
    /// Set between a change here and the delayed save that writes it.
    @ObservationIgnored private var hasUnsavedChanges = false
    /// Ids `patchUserData` has touched since the last sync folded them in. A
    /// sync in flight builds its result from a snapshot taken before such a
    /// change, so committing it wholesale would silently undo the tap — see
    /// `runSync`'s merge just before it assigns `items`.
    @ObservationIgnored private var locallyPatchedIds: Set<String> = []

    private func saveCursor() async {
        guard let owner else { return }
        let progress = SyncCursor(owner: owner, cursor: cursor, syncedAt: lastSynced)
        await Task.detached(priority: .utility) {
            LibraryIndex.write(progress, to: LibraryIndex.cursorURL)
        }.value
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    nonisolated private static func write(_ snapshot: Snapshot) {
        write(snapshot, to: snapshotURL)
    }

    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value),
              let packed = try? (data as NSData).compressed(using: .lzfse) as Data
        else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if !os(tvOS)
        // A copy of the server's own data, rebuilt from it at will: no reason
        // to spend the user's iCloud backup on it.
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        #endif
        try? packed.write(to: url, options: .atomic)
    }

    // MARK: - Artwork

    /// Save every poster, logo and episode still that isn't on disk yet.
    /// Backdrops are left to be saved as they are seen: they are the large
    /// ones, and most are never looked at.
    private func startArtwork() {
        guard isEnabled, isReady, artworkTask == nil else { return }
        let urls = artworkURLs()
        artworkTask = Task {
            await saveArtwork(urls)
            artworkTask = nil
            artworkProgress = nil
        }
    }

    private func artworkURLs() -> [URL] {
        let poster = Int(Metrics.posterWidth * 2)
        let still = Int(Metrics.stillWidth * 2)
        var out: [URL] = []
        out.reserveCapacity(items.count + items.count / 4)
        for item in items.values {
            switch item.kind {
            case "Episode":
                if let url = Artwork.ownPrimary(item, width: still) { out.append(url) }
            case "Movie", "Series":
                if let url = Artwork.url(item, type: "Primary", width: poster) { out.append(url) }
                if let url = Artwork.logo(item, width: 700) { out.append(url) }
            default:
                if let url = Artwork.url(item, type: "Primary", width: poster) { out.append(url) }
            }
        }
        return out
    }

    private func saveArtwork(_ urls: [URL]) async {
        let loader = ImageLoader.shared
        let needed = await loader.missingOnDisk(urls)
        guard !needed.isEmpty else {
            artworkBytes = await loader.diskUsage()
            return
        }
        artworkProgress = (0, needed.count)
        var done = 0
        await withTaskGroup(of: Void.self) { group in
            var pending = needed.makeIterator()
            var running = 0
            while true {
                while running < 4, let url = pending.next() {
                    // A film being streamed has a better use for the network.
                    while PlayerModel.shared.isActive, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                    }
                    guard !Task.isCancelled else { break }
                    group.addTask { _ = await loader.saveToDisk(url) }
                    running += 1
                }
                guard running > 0, await group.next() != nil else { break }
                running -= 1
                done += 1
                artworkProgress = (done, needed.count)
                if done % 50 == 0 { artworkBytes = await loader.diskUsage() }
            }
        }
        artworkBytes = await loader.diskUsage()
    }

    // MARK: - Home

    /// What Home last showed, brought up to date with the copy's watched
    /// state: something finished since is no longer in Continue Watching, and
    /// something further along says so. Nil until Home has loaded once from
    /// the server with the copy on.
    func homeCopy() -> HomeCopy? {
        guard isReady, var copy = home else { return nil }
        // Which of the two is newer isn't recorded, so the copy only wins where
        // it has something to say: finished, or further along. A copy that
        // simply holds no position for an item hasn't heard less than Home did
        // — it was never told — and must not take a film out of Continue
        // Watching for that.
        func finished(_ item: BaseItem) -> Bool { items[item.Id]?.userData.played == true }
        func current(_ item: BaseItem) -> BaseItem {
            guard let known = items[item.Id],
                  known.userData.played || known.userData.positionTicks > 0
            else { return item }
            var updated = item
            updated.UserData = known.UserData
            return updated
        }
        copy.resume = copy.resume.filter { !finished($0) }.map(current)
        copy.nextUp = copy.nextUp.filter { !finished($0) }.map(current)
        copy.latest = copy.latest.map { .init(library: $0.library, items: $0.items.map(current)) }
        copy.hero = copy.hero.map(current)
        return copy
    }

    /// Home as the server just drew it.
    func keepHome(sections: [HomeSection], resume: [BaseItem], nextUp: [BaseItem],
                  latest: [(library: BaseItem, items: [BaseItem])], hero: [BaseItem]) {
        guard isEnabled, isReady, let owner else { return }
        let copy = HomeCopy(
            owner: owner, sections: sections.map(\.rawValue), resume: resume, nextUp: nextUp,
            latest: latest.map { .init(library: $0.library, items: $0.items) }, hero: hero
        )
        home = copy
        hasHomeCopy = true
        Task.detached(priority: .utility) {
            LibraryIndex.write(copy, to: LibraryIndex.homeURL)
        }
    }

    /// Films and shows at random for the media bar, drawn from the copy
    /// rather than asked of the server — only those with a backdrop, as there.
    func spotlight(limit: Int) -> [BaseItem]? {
        guard isReady else { return nil }
        let candidates = items.values.filter {
            ($0.kind == "Movie" || $0.kind == "Series") && $0.BackdropImageTags?.isEmpty == false
        }
        guard !candidates.isEmpty else { return nil }
        return Array(candidates.shuffled().prefix(limit))
    }

    // MARK: - Answering

    /// The libraries, for when the server can't be asked.
    var savedViews: [BaseItem]? { isReady && !views.isEmpty ? views : nil }

    func item(_ id: String) -> BaseItem? {
        isReady ? items[id] : nil
    }

    /// Titles matching a few typed words, for Siri. A title that starts with
    /// the words comes before one that merely contains them, and films and
    /// shows before episodes, so "play heat" is the film and not an episode
    /// called Heat Wave. Nil when there is no copy to ask.
    func search(_ term: String, limit: Int) -> [BaseItem]? {
        guard isReady else { return nil }
        let needle = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        func rank(_ item: BaseItem) -> Int? {
            guard let name = item.Name?.lowercased() else { return nil }
            let kindWeight = item.isEpisode ? 3 : 0
            if name == needle { return 0 + kindWeight }
            if name.hasPrefix(needle) { return 1 + kindWeight }
            if name.contains(needle) { return 2 + kindWeight }
            if item.isEpisode, let series = item.SeriesName?.lowercased(), series.contains(needle) { return 6 }
            return nil
        }
        let kinds: Set<String> = ["Movie", "Series", "Episode"]
        var ranked: [(item: BaseItem, rank: Int)] = []
        for item in items.values where kinds.contains(item.kind) {
            if let rank = rank(item) { ranked.append((item, rank)) }
        }
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return (a.item.Name ?? "") < (b.item.Name ?? "")
        }
        return ranked.prefix(limit).map(\.item)
    }

    func seasons(seriesId: String) -> [BaseItem]? {
        guard isReady, let ids = seasonsBySeries[seriesId], !ids.isEmpty else { return nil }
        return ids.compactMap { items[$0] }
    }

    func episodes(seriesId: String, seasonId: String?) -> [BaseItem]? {
        guard isReady else { return nil }
        let ids = seasonId.map { episodesBySeason[$0] } ?? episodesBySeries[seriesId]
        guard let ids, !ids.isEmpty else { return nil }
        return ids.compactMap { items[$0] }
    }

    /// One page of a library grid, sorted and filtered here the way the server
    /// would. Nil where the copy can't say — not synced yet, a folder that isn't
    /// a library, or a mixed library that the server lists by folder, which
    /// is only answered here when the server can't be.
    func libraryItems(parentId: String, query: JellyfinClient.LibraryQuery) -> ItemsResponse? {
        guard isReady, let ids = members[parentId] else { return nil }
        let types: Set<String>
        if let include = query.includeTypes {
            types = Set(include.split(separator: ",").map(String.init))
        } else {
            guard JellyfinClient.shared.isOffline else { return nil }
            types = ["Movie", "Series", "Video"]
        }
        let key = [
            parentId, types.sorted().joined(separator: ","), query.sortBy, query.sortOrder,
            String(query.unwatched), String(query.favorites), query.genre ?? "",
        ].joined(separator: "|")

        let list: [String]
        if let cached = queryCache[key] {
            list = cached
        } else {
            var matches = ids.compactMap { items[$0] }.filter { types.contains($0.kind) }
            if query.unwatched {
                matches = matches.filter {
                    $0.isSeries ? ($0.userData.UnplayedItemCount ?? 1) > 0 : !$0.userData.played
                }
            }
            if query.favorites { matches = matches.filter { $0.userData.isFavorite } }
            if let genre = query.genre { matches = matches.filter { $0.Genres?.contains(genre) == true } }
            list = Self.sorted(matches, by: query.sortBy, order: query.sortOrder).map(\.Id)
            queryCache[key] = list
        }
        return page(list, startIndex: query.startIndex, limit: query.limit)
    }

    /// Everything starred, across every library.
    func favorites(startIndex: Int, limit: Int, includeTypes: String, sortBy: String, sortOrder: String) -> ItemsResponse? {
        guard isReady else { return nil }
        let types = Set(includeTypes.split(separator: ",").map(String.init))
        let key = ["favourites", types.sorted().joined(separator: ","), sortBy, sortOrder].joined(separator: "|")
        let list: [String]
        if let cached = queryCache[key] {
            list = cached
        } else {
            let matches = items.values.filter { types.contains($0.kind) && $0.userData.isFavorite }
            list = Self.sorted(matches, by: sortBy, order: sortOrder).map(\.Id)
            queryCache[key] = list
        }
        return page(list, startIndex: startIndex, limit: limit)
    }

    private func page(_ ids: [String], startIndex: Int, limit: Int) -> ItemsResponse {
        let start = min(max(startIndex, 0), ids.count)
        let end = min(start + max(limit, 0), ids.count)
        return ItemsResponse(Items: ids[start..<end].compactMap { items[$0] }, TotalRecordCount: ids.count)
    }

    /// A watched flag or favourite changed from this device: into the copy at
    /// once, so a grid redrawn a moment later agrees with the page that
    /// changed it, without waiting for the next sync to hear it back.
    func patchUserData(_ id: String, _ change: (inout UserData) -> Void) {
        guard isReady, var item = items[id] else { return }
        var data = item.userData
        change(&data)
        item.UserData = data
        items[id] = item
        locallyPatchedIds.insert(id)
        queryCache = [:]
        scheduleSave()
    }

    // MARK: - Order

    private func rebuildDerived() {
        install(Self.derive(items))
    }

    /// The orderings a series page reads, which the item table alone doesn't
    /// give without a sort.
    struct Derived: Sendable {
        var seasonsBySeries: [String: [String]]
        var episodesBySeason: [String: [String]]
        var episodesBySeries: [String: [String]]
    }

    private func install(_ derived: Derived) {
        queryCache = [:]
        seasonsBySeries = derived.seasonsBySeries
        episodesBySeason = derived.episodesBySeason
        episodesBySeries = derived.episodesBySeries
    }

    /// Pure, so it can run beside a decode or a sync rather than on the main
    /// actor.
    nonisolated static func derive(_ items: [String: BaseItem]) -> Derived {
        var seasons: [String: [BaseItem]] = [:]
        var bySeason: [String: [BaseItem]] = [:]
        var bySeries: [String: [BaseItem]] = [:]
        for item in items.values {
            switch item.kind {
            case "Season":
                if let series = item.SeriesId ?? item.ParentId { seasons[series, default: []].append(item) }
            case "Episode":
                if let season = item.SeasonId { bySeason[season, default: []].append(item) }
                if let series = item.SeriesId { bySeries[series, default: []].append(item) }
            default:
                break
            }
        }
        return Derived(
            seasonsBySeries: seasons.mapValues { $0.sorted(by: seasonOrder).map(\.Id) },
            episodesBySeason: bySeason.mapValues { $0.sorted(by: episodeOrder).map(\.Id) },
            episodesBySeries: bySeries.mapValues { $0.sorted(by: episodeOrder).map(\.Id) }
        )
    }

    private nonisolated static func seasonOrder(_ a: BaseItem, _ b: BaseItem) -> Bool {
        let x = a.IndexNumber ?? Int.max, y = b.IndexNumber ?? Int.max
        return x != y ? x < y : nameOrder(a, b)
    }

    private nonisolated static func episodeOrder(_ a: BaseItem, _ b: BaseItem) -> Bool {
        let sa = a.ParentIndexNumber ?? Int.max, sb = b.ParentIndexNumber ?? Int.max
        if sa != sb { return sa < sb }
        let ea = a.IndexNumber ?? Int.max, eb = b.IndexNumber ?? Int.max
        return ea != eb ? ea < eb : nameOrder(a, b)
    }

    private nonisolated static func nameOrder(_ a: BaseItem, _ b: BaseItem) -> Bool {
        let x = a.SortName ?? a.Name ?? "", y = b.SortName ?? b.Name ?? ""
        return x.compare(y, options: [.caseInsensitive, .numeric, .diacriticInsensitive]) == .orderedAscending
    }

    /// The server's sort fields, as far as a grid uses them.
    private static func sorted(_ list: [BaseItem], by field: String, order: String) -> [BaseItem] {
        if field == "Random" { return list.shuffled() }
        let descending = order == "Descending"
        func value(_ item: BaseItem) -> Double? {
            switch field {
            case "DateCreated": Format.parseDate(item.DateCreated)?.timeIntervalSince1970
            case "PremiereDate": Format.parseDate(item.PremiereDate)?.timeIntervalSince1970
            case "CommunityRating": item.CommunityRating
            case "Runtime": item.RunTimeTicks.map(Double.init)
            default: nil
            }
        }
        guard field != "SortName" else {
            let byName = list.sorted(by: nameOrder)
            return descending ? byName.reversed() : byName
        }
        let keyed = list.map { ($0, value($0)) }
        return keyed.sorted { a, b in
            // Missing values go last whichever way the list runs, as they do
            // on the server.
            switch (a.1, b.1) {
            case let (x?, y?) where x != y: return descending ? x > y : x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return nameOrder(a.0, b.0)
            }
        }.map(\.0)
    }
}

/// Home's rows as they were last drawn. See `LibraryIndex.homeCopy()`.
struct HomeCopy: Codable, Sendable {
    struct LatestRow: Codable, Sendable {
        var library: BaseItem
        var items: [BaseItem]
    }

    var owner: String
    var sections: [String]
    var resume: [BaseItem]
    var nextUp: [BaseItem]
    var latest: [LatestRow]
    var hero: [BaseItem]
}

/// The copy as it is written to disk.
/// How far the last sync got, for a sync that changed nothing.
private struct SyncCursor: Codable, Sendable {
    var owner: String
    var cursor: Date?
    var syncedAt: Date?
}

private struct Snapshot: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var owner: String
    var cursor: Date?
    var syncedAt: Date?
    var views: [BaseItem]
    var members: [String: [String]]
    var items: [BaseItem]
}
