//  Music with no server: what is known about the songs on this device, and
//  the smart features rebuilt on top of that.
//
//  Everything clever in the Music tab is the server's doing — it builds the
//  Instant Mix, it knows what was played most, it answers a smart playlist's
//  rule. With the server gone, the only music there is to play is what was
//  downloaded, and a `DownloadRecord` knows a song's name, album and artist
//  and nothing else: no genres, no play count, no star. That is enough to
//  list it and not enough to choose from it.
//
//  So two things live here. `OfflineMusicIndex` keeps the missing facts for
//  every downloaded song in one small file, filled in while there is a server
//  to ask and kept current by what is played on this device. `OfflineMusic`
//  answers the questions the server would have — a mix like this, the most
//  played, this rule, this search — from the downloads and those facts.
//
//  The facts are a sidecar rather than new fields on `DownloadRecord` on
//  purpose: a record is written once per song into its own meta.json, and a
//  refresh of three thousand play counts should be one file, not three
//  thousand.

import Foundation
import os
import Observation

#if !os(tvOS)

// MARK: - Facts

/// What a downloaded song's record doesn't say.
struct SongFacts: Codable, Hashable, Sendable {
    var genres: [String] = []
    var artists: [NameGuidPair] = []
    var albumArtists: [NameGuidPair] = []
    var favorite = false
    var playCount = 0
    var lastPlayed: Date?
    /// When the song was added to the library, as opposed to this device.
    var dateCreated: Date?
    var hasLyrics = false
    /// A star given or taken with no server in reach, still to be sent.
    var pendingFavorite: Bool?
    /// Nil until the server has been asked about this song at least once.
    var refreshedAt: Date?

    init() {}

    /// Key by key, for the reason `DownloadRecord` does it: the synthesised
    /// decoder throws on a missing key, and one field added later would
    /// empty the index written by the version before.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        artists = try c.decodeIfPresent([NameGuidPair].self, forKey: .artists) ?? []
        albumArtists = try c.decodeIfPresent([NameGuidPair].self, forKey: .albumArtists) ?? []
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        dateCreated = try c.decodeIfPresent(Date.self, forKey: .dateCreated)
        hasLyrics = try c.decodeIfPresent(Bool.self, forKey: .hasLyrics) ?? false
        pendingFavorite = try c.decodeIfPresent(Bool.self, forKey: .pendingFavorite)
        refreshedAt = try c.decodeIfPresent(Date.self, forKey: .refreshedAt)
    }
}

/// One of the server's playlists, as it stood when last asked: its name and
/// the songs in it, in order. Offline it lists whichever of those are here.
struct SavedPlaylist: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var itemIds: [String]
}

/// The facts for every downloaded song, and the account's playlists, on disk
/// as one file.
@MainActor
@Observable
final class OfflineMusicIndex {
    static let shared = OfflineMusicIndex()

    private(set) var facts: [String: SongFacts] = [:]
    private(set) var playlists: [SavedPlaylist] = []
    /// Bumped on every change, for pages that want to redraw from it.
    private(set) var revision = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// When everything was last read back in full. Kept across launches: a
    /// full read is a request per fifty songs, and a launch is not a reason.
    @ObservationIgnored private var lastRefresh: Date? {
        get { UserDefaults.standard.object(forKey: "music_index_refreshed") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "music_index_refreshed") }
    }

    private nonisolated static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // the pre-Aquarium name, kept so what is already on disk is found
            .appendingPathComponent("FellyJin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MusicIndex.json")
    }

    private struct Saved: Codable, Sendable {
        var facts: [String: SongFacts]?
        var playlists: [SavedPlaylist]?
    }

    /// The file being read, until it has been. Read off the main actor: the
    /// index is first touched at launch, and for a few thousand songs with
    /// their genres and artists it is a decode worth not waiting on.
    @ObservationIgnored private var loading: Task<Saved?, Never>?
    /// Changes asked for before the file was in, applied on top of it once it
    /// is. Applied to an empty index instead, a play counted in that moment
    /// would start from nought and the next save would write that over the
    /// real count.
    @ObservationIgnored private var waitingChanges: [@MainActor () -> Void] = []

    private init() {
        let file = Self.file
        loading = Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Saved.self, from: data)
        }
        Task { await self.ensureLoaded() }
    }

    /// Waits for the file, and applies it and anything that queued behind it.
    func ensureLoaded() async {
        guard let loading else { return }
        let saved = await loading.value
        // Another caller got here first.
        guard self.loading != nil else { return }
        self.loading = nil
        if let saved {
            facts = saved.facts ?? [:]
            playlists = saved.playlists ?? []
        }
        let queued = waitingChanges
        waitingChanges = []
        for change in queued { change() }
        revision += 1
    }

    /// Runs `change` now, or once the file is in.
    private func whenLoaded(_ change: @escaping @MainActor () -> Void) {
        if loading == nil {
            change()
        } else {
            waitingChanges.append(change)
        }
    }

    // MARK: Writing

    /// Take what the server says about these songs. Counts only ever go up
    /// here: a play made on this device with no server to tell is one the
    /// server never counted, and its lower number would erase it.
    func note(_ items: [BaseItem]) {
        whenLoaded { [self] in apply(items) }
    }

    private func apply(_ items: [BaseItem]) {
        var changed = false
        for item in items where item.isSong {
            var f = facts[item.Id] ?? SongFacts()
            let before = f
            if let genres = item.Genres ?? item.GenreItems?.compactMap(\.Name), !genres.isEmpty { f.genres = genres }
            if let artists = item.ArtistItems, !artists.isEmpty { f.artists = artists }
            if let albumArtists = item.AlbumArtists, !albumArtists.isEmpty { f.albumArtists = albumArtists }
            if let data = item.UserData {
                if f.pendingFavorite == nil { f.favorite = data.isFavorite }
                f.playCount = max(f.playCount, data.PlayCount ?? 0)
                if let played = Format.parseDate(data.LastPlayedDate), played > (f.lastPlayed ?? .distantPast) {
                    f.lastPlayed = played
                }
            }
            if let added = Format.parseDate(item.DateCreated) { f.dateCreated = added }
            if let lyrics = item.HasLyrics { f.hasLyrics = lyrics }
            // Compared before the stamp below is set, or every refresh would
            // read as a change — `refreshedAt` always differs — and touch the
            // file and the revision for nothing. `facts` still takes the new
            // stamp either way, so a song already known isn't asked about again
            // this session even when nothing else about it moved.
            let contentChanged = f != before
            f.refreshedAt = Date()
            facts[item.Id] = f
            if contentChanged { changed = true }
        }
        if changed { touch() }
    }

    /// A song finished playing on this device. Only songs that are kept here
    /// are counted; the rest are the server's to remember.
    func notePlayed(_ itemId: String) {
        guard DownloadManager.shared.record(for: itemId) != nil else { return }
        let when = Date()
        whenLoaded { [self] in
            var f = facts[itemId] ?? SongFacts()
            f.playCount += 1
            f.lastPlayed = when
            facts[itemId] = f
            touch()
        }
    }

    func setFavorite(_ itemId: String, _ favorite: Bool, pending: Bool) {
        whenLoaded { [self] in
            var f = facts[itemId] ?? SongFacts()
            f.favorite = favorite
            f.pendingFavorite = pending ? favorite : nil
            facts[itemId] = f
            touch()
        }
    }

    private func touch() {
        revision += 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let snapshot = Saved(facts: self.facts, playlists: self.playlists)
            let file = Self.file
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
            }.value
        }
    }

    // MARK: Refreshing

    private var downloadedSongIds: [String] {
        DownloadManager.shared.records
            .filter { $0.type == "Audio" && $0.status == .complete }
            .map(\.itemId)
    }

    private var downloadedBookIds: [String] {
        DownloadManager.shared.records
            .filter { $0.type == "AudioBook" && $0.status == .complete }
            .map(\.itemId)
    }

    /// Bring the facts up to date while there is a server to ask: send the
    /// stars that were waiting, then read back genres, counts and stars for
    /// everything downloaded, and keep the words of any song that has them.
    ///
    /// Asked for at launch, on the way back online and after a download
    /// lands. It does the full read a few times a day at most; in between it
    /// only asks about songs it has never asked about.
    func refresh(force: Bool = false) async {
        await ensureLoaded()
        if let running = refreshTask { return await running.value }
        let task = Task { await runRefresh(force: force) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func runRefresh(force: Bool) async {
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.isOffline else { return }

        for (id, f) in facts {
            guard let wanted = f.pendingFavorite else { continue }
            if (try? await client.setFavorite(id, favorite: wanted)) != nil {
                facts[id]?.pendingFavorite = nil
                touch()
            }
        }

        let ids = downloadedSongIds
        let kept = Set(ids)
        let stale = facts.keys.filter { !kept.contains($0) && facts[$0]?.pendingFavorite == nil }
        if !stale.isEmpty {
            for id in stale { facts[id] = nil }
            touch()
        }

        // A book's page is its chapters and its blurb, neither of which a
        // download record carries: the whole item is kept beside the file.
        for id in downloadedBookIds where !OfflineBooks.isKept(id) {
            guard !Task.isCancelled, !client.isOffline else { break }
            if let full = try? await client.musicItem(id) { OfflineBooks.keep(full) }
        }

        let due = force || lastRefresh.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        let wanted = due ? ids : ids.filter { facts[$0]?.refreshedAt == nil }
        if !wanted.isEmpty {
            guard let items = try? await client.songs(ids: wanted) else { return }
            note(items)
        }

        if due {
            lastRefresh = Date()
            // The playlists, and which songs are in each. Only the ones with
            // something downloaded in them are any use offline, but which
            // those are changes with every download, so all are kept.
            if let lists = try? await client.audioPlaylists() {
                var saved: [SavedPlaylist] = []
                for list in lists {
                    guard let entries = try? await client.playlistItems(playlistId: list.Id) else { continue }
                    saved.append(SavedPlaylist(id: list.Id, name: list.title, itemIds: entries.map(\.Id)))
                }
                if saved != playlists {
                    playlists = saved
                    touch()
                }
            }
        }

        // The words, for downloaded songs that have them and haven't had them
        // kept yet. One request each, once.
        for id in ids where facts[id]?.hasLyrics == true && !OfflineLyrics.isKept(id) {
            guard !Task.isCancelled, !client.isOffline else { break }
            if let found = try? await client.lyrics(itemId: id) { OfflineLyrics.keep(found, for: id) }
        }
    }
}

// MARK: - Lyrics on disk

/// A downloaded song's words, kept in its download folder so they go when it
/// does.
enum OfflineLyrics {
    private static func file(_ itemId: String) -> URL {
        DownloadManager.folderPath(for: itemId).appendingPathComponent("lyrics.json")
    }

    static func isKept(_ itemId: String) -> Bool {
        FileManager.default.fileExists(atPath: file(itemId).path)
    }

    /// Only for songs that are on this device: the folder is the download's.
    static func keep(_ lyrics: LyricsResponse, for itemId: String) {
        let folder = DownloadManager.folderPath(for: itemId)
        guard FileManager.default.fileExists(atPath: folder.path), !lyrics.lines.isEmpty,
              let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: file(itemId), options: .atomic)
    }

    static func load(_ itemId: String) -> LyricsResponse? {
        guard let data = try? Data(contentsOf: file(itemId)) else { return nil }
        return try? JSONDecoder().decode(LyricsResponse.self, from: data)
    }
}

// MARK: - Audiobooks on disk

/// A downloaded audiobook's full item — chapters, blurb, author — kept in its
/// download folder. The record beside it has the one thing that changes: how
/// far in the listener is.
enum OfflineBooks {
    private static func file(_ itemId: String) -> URL {
        DownloadManager.folderPath(for: itemId).appendingPathComponent("item.json")
    }

    static func isKept(_ itemId: String) -> Bool {
        FileManager.default.fileExists(atPath: file(itemId).path)
    }

    static func keep(_ book: BaseItem) {
        guard book.isAudiobook else { return }
        var slim = book
        slim.MediaSources = nil
        slim.UserData = nil
        let folder = DownloadManager.folderPath(for: book.Id)
        // The folder is made when the transfer starts, which may be after
        // this is called for a book that was only just queued.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(slim) { try? data.write(to: file(book.Id), options: .atomic) }
        revision.withLock { $0 &+= 1 }
    }

    /// Bumped whenever a book's saved item is written, so the list built from
    /// them knows to read them again. See `OfflineMusic.books`.
    static let revision = OSAllocatedUnfairLock(initialState: 0)

    static func saved(_ itemId: String) -> BaseItem? {
        guard let data = try? Data(contentsOf: file(itemId)) else { return nil }
        return try? JSONDecoder().decode(BaseItem.self, from: data)
    }
}

// MARK: - The library on this device

/// The questions the Music tab asks the server, answered from downloads.
@MainActor
enum OfflineMusic {
    /// Every downloaded song, as an item that carries what the index knows:
    /// its genres, its artists by id, its star and its play count. Rows, menus
    /// and the mix below all read those the way they would a server item's.
    ///
    /// Built once per change rather than on every access. The Discover page
    /// alone read it six times per load — each a pass over every download,
    /// an item built per song and its artwork looked for on disk — and loaded
    /// again every time a song finished. Both sources are still read on a
    /// cache hit, so a view asking is told when either changes.
    static var songs: [BaseItem] {
        let downloads = DownloadManager.shared
        let index = OfflineMusicIndex.shared
        let records = downloads.records
        let facts = index.facts
        let key = SongsKey(records: downloads.recordsRevision, facts: index.revision)
        if let builtSongs, builtSongs.key == key { return builtSongs.songs }
        let songs = records
            .filter { $0.type == "Audio" && $0.status == .complete }
            .map { item($0, facts: facts[$0.itemId]) }
        builtSongs = (key, songs)
        return songs
    }

    private struct SongsKey: Equatable {
        var records: Int
        var facts: Int
    }

    private static var builtSongs: (key: SongsKey, songs: [BaseItem])?

    static var hasSongs: Bool {
        DownloadManager.shared.records.contains { $0.type == "Audio" && $0.status == .complete }
    }

    private static func item(_ record: DownloadRecord, facts: SongFacts?) -> BaseItem {
        var item = record.asItem
        guard let facts else { return item }
        if !facts.genres.isEmpty { item.Genres = facts.genres }
        if !facts.artists.isEmpty {
            item.ArtistItems = facts.artists
            item.Artists = facts.artists.compactMap(\.Name)
        }
        if !facts.albumArtists.isEmpty { item.AlbumArtists = facts.albumArtists }
        var data = item.UserData ?? UserData()
        data.IsFavorite = facts.favorite
        data.PlayCount = facts.playCount
        data.Played = facts.playCount > 0 || record.played
        item.UserData = data
        item.HasLyrics = facts.hasLyrics
        return item
    }

    private static func facts(_ song: BaseItem) -> SongFacts { OfflineMusicIndex.shared.facts[song.Id] ?? SongFacts() }

    // MARK: Shelves

    static func recentlyPlayed(limit: Int = 40) -> [BaseItem] {
        songs.filter { facts($0).lastPlayed != nil }
            .sorted { (facts($0).lastPlayed ?? .distantPast) > (facts($1).lastPlayed ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    static func mostPlayed(limit: Int = 40) -> [BaseItem] {
        songs.filter { facts($0).playCount > 0 }
            .sorted { facts($0).playCount > facts($1).playCount }
            .prefix(limit).map { $0 }
    }

    static func favorites() -> [BaseItem] {
        songs.filter { facts($0).favorite }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Albums in the order they arrived on this device, newest first.
    static func recentlyDownloadedAlbums(limit: Int = 20) -> [BaseItem] {
        let index = OfflineMusicIndex.shared.facts
        return DownloadManager.shared.records
            .filter { $0.type == "Audio" && $0.status == .complete }
            .sorted { $0.createdAt > $1.createdAt }
            .map { item($0, facts: index[$0.itemId]) }
            .localAlbums().prefix(limit).map { $0 }
    }

    static func albumTracks(albumId: String) -> [BaseItem] {
        songs.filter { $0.AlbumId == albumId }.sortedByTrack()
    }

    static func songs(byArtist artist: BaseItem) -> [BaseItem] {
        let keys = artistKeys(id: artist.Id, name: artist.Name)
        return songs.filter { !artistKeys(of: $0).isDisjoint(with: keys) }
    }

    static func songs(inGenre name: String) -> [BaseItem] {
        let wanted = name.lowercased()
        return songs.filter { ($0.Genres ?? []).contains { $0.lowercased() == wanted } }
    }

    static var genres: [String] {
        Array(Set(songs.flatMap { $0.Genres ?? [] })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Everything an item stands for, as downloaded songs — what a menu's
    /// Play, Shuffle and Play Next fall back to with no server.
    static func songs(for item: BaseItem) -> [BaseItem] {
        if item.isSong { return songs.filter { $0.Id == item.Id } }
        if item.isAlbum { return albumTracks(albumId: item.Id) }
        if item.isArtist { return songs(byArtist: item) }
        if item.isMusicGenre { return songs(inGenre: item.title) }
        if item.isPlaylist { return playlistSongs(item.Id) }
        if item.isAudiobook { return book(item.Id).map { [$0] } ?? [] }
        return []
    }

    // MARK: Playlists

    /// The server's playlists that have something on this device in them.
    static var playlists: [(list: SavedPlaylist, songs: [BaseItem])] {
        let byId = Dictionary(songs.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
        return OfflineMusicIndex.shared.playlists.compactMap { list in
            let here = list.itemIds.compactMap { byId[$0] }
            return here.isEmpty ? nil : (list, here)
        }
    }

    static func playlistSongs(_ playlistId: String) -> [BaseItem] {
        playlists.first { $0.list.id == playlistId }?.songs ?? []
    }

    /// A saved playlist as a row or a tile can draw it, under the cover of its
    /// first song.
    static func playlistItem(_ list: SavedPlaylist, songs: [BaseItem]) -> BaseItem {
        var item = BaseItem()
        item.Id = list.id
        item.Name = list.name
        item.type = "Playlist"
        item.MediaType = "Audio"
        item.ChildCount = songs.count
        item.ExternalLogoURL = songs.first?.ExternalLogoURL
        return item
    }

    // MARK: Audiobooks

    /// Every downloaded audiobook: the saved item where there is one, with
    /// this device's cover and this device's place in it.
    ///
    /// Built once per change. Each book is its saved item read off disk and
    /// decoded, and the audiobook pages read this list several times per
    /// redraw — the authors, the search, the shelves — and once per keystroke
    /// while searching. The records are still read on a cache hit, so a view
    /// asking is told when they change.
    static var books: [BaseItem] {
        let downloads = DownloadManager.shared
        let records = downloads.records
        let key = [downloads.recordsRevision, OfflineBooks.revision.withLock { $0 }]
        if let builtBooks, builtBooks.key == key { return builtBooks.books }
        let books = records
            .filter { $0.type == "AudioBook" && $0.status == .complete }
            .map(book)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        builtBooks = (key, books)
        return books
    }

    private static var builtBooks: (key: [Int], books: [BaseItem])?

    static func book(_ itemId: String) -> BaseItem? {
        guard let record = DownloadManager.shared.record(for: itemId), record.status == .complete,
              record.type == "AudioBook" else { return nil }
        return book(record)
    }

    private static func book(_ record: DownloadRecord) -> BaseItem {
        let plain = record.asItem
        guard var full = OfflineBooks.saved(record.itemId) else { return plain }
        full.UserData = plain.UserData
        full.ExternalLogoURL = plain.ExternalLogoURL
        if full.RunTimeTicks == nil { full.RunTimeTicks = plain.RunTimeTicks }
        return full
    }

    static var booksInProgress: [BaseItem] { books.filter { $0.progressFraction != nil } }

    static func books(byAuthor name: String) -> [BaseItem] {
        let wanted = name.lowercased()
        return books.filter { book in
            ([book.AlbumArtist] + (book.Artists ?? []).map(Optional.some) + (book.AlbumArtists ?? []).map(\.Name))
                .contains { $0?.lowercased() == wanted }
        }
    }

    static var authors: [String] {
        Array(Set(books.compactMap { $0.AlbumArtist ?? $0.Artists?.first }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func searchBooks(_ term: String) -> [BaseItem] {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.AlbumArtist ?? $0.artistLine).localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: Search

    static func search(_ term: String, limit: Int = 24) -> JellyfinClient.MusicSearchResults {
        let needle = term.trimmingCharacters(in: .whitespaces)
        var out = JellyfinClient.MusicSearchResults()
        guard !needle.isEmpty else { return out }
        func hit(_ text: String?) -> Bool { text?.localizedCaseInsensitiveContains(needle) ?? false }
        let all = songs
        out.songs = Array(all.filter { hit($0.Name) }.prefix(limit))
        out.albums = Array(all.filter { hit($0.Album) }.localAlbums().prefix(limit))
        out.artists = Array(all.localArtists().filter { hit($0.Name) }.prefix(limit))
        out.playlists = playlists.filter { hit($0.list.name) }.map { playlistItem($0.list, songs: $0.songs) }
        return out
    }

    // MARK: Smart playlists

    /// A rule, answered from what is on this device. The same reading of each
    /// field as `SmartPlaylist.resolve`, which asks the server.
    static func resolve(_ rule: SmartPlaylist) -> [BaseItem] {
        let index = OfflineMusicIndex.shared.facts
        let created = Dictionary(
            DownloadManager.shared.records.map { ($0.itemId, $0.createdAt) }, uniquingKeysWith: { a, _ in a }
        )
        func added(_ song: BaseItem) -> Date { index[song.Id]?.dateCreated ?? created[song.Id] ?? .distantPast }

        let wantedGenres = Set(rule.genres.map { $0.lowercased() })
        let wantedArtists = rule.artists.reduce(into: Set<String>()) { $0.formUnion(artistKeys(id: $1.Id, name: $1.Name)) }
        let cutoff = rule.addedWithinDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        // Either way round, as the server path reads it.
        let yearA = rule.yearFrom ?? rule.yearTo, yearB = rule.yearTo ?? rule.yearFrom
        let from = yearA.flatMap { a in yearB.map { min(a, $0) } }
        let to = yearA.flatMap { a in yearB.map { max(a, $0) } }

        var out = songs.filter { song in
            let f = index[song.Id] ?? SongFacts()
            if !wantedGenres.isEmpty, wantedGenres.isDisjoint(with: f.genres.map { $0.lowercased() }) { return false }
            if !wantedArtists.isEmpty, wantedArtists.isDisjoint(with: artistKeys(of: song)) { return false }
            if let from, let to, from <= to {
                guard let year = song.ProductionYear, (from...to).contains(year) else { return false }
            }
            if let cutoff, added(song) < cutoff { return false }
            if rule.favoritesOnly, !f.favorite { return false }
            switch rule.played {
            case .any: break
            case .played: if !song.userData.played { return false }
            case .unplayed: if song.userData.played { return false }
            }
            if let floor = rule.minPlayCount, floor > 0, f.playCount < floor { return false }
            return true
        }

        func byName(_ a: BaseItem, _ b: BaseItem) -> Bool { a.title.localizedStandardCompare(b.title) == .orderedAscending }
        switch rule.sort {
        case .name: out.sort(by: byName)
        case .artist:
            out.sort {
                let a = ($0.AlbumArtist ?? "", $0.Album ?? ""), b = ($1.AlbumArtist ?? "", $1.Album ?? "")
                if a != b { return a < b }
                return ($0.ParentIndexNumber ?? 1, $0.IndexNumber ?? 0) < ($1.ParentIndexNumber ?? 1, $1.IndexNumber ?? 0)
            }
        case .recentlyAdded: out.sort { added($0) > added($1) }
        case .year: out.sort { ($0.ProductionYear ?? 0) > ($1.ProductionYear ?? 0) }
        case .recentlyPlayed: out.sort { (index[$0.Id]?.lastPlayed ?? .distantPast) > (index[$1.Id]?.lastPlayed ?? .distantPast) }
        case .mostPlayed: out.sort { (index[$0.Id]?.playCount ?? 0) > (index[$1.Id]?.playCount ?? 0) }
        case .random: out.shuffle()
        }
        return Array(out.prefix(rule.limit))
    }

    // MARK: - Instant Mix

    /// A station from one thing, built from downloads — the same ranking the
    /// server's stations get (see `StationRanker`), over what is here.
    static func mix(from seed: BaseItem, limit: Int = 100) -> [BaseItem] {
        guard let station = StationBuilder.local(from: seed, title: seed.title) else { return [] }
        var out: [BaseItem] = []
        if seed.isSong, let first = station.pool[seed.Id] { out.append(first) }
        return out + station.upcoming(count: limit - out.count, after: out)
    }

    // MARK: Artists, by id or by name

    /// The index knows artists by id; a record downloaded before there was an
    /// index knows a name. Both spellings, so either finds the other.
    static func artistKeys(id: String?, name: String?) -> Set<String> { MusicKeys.artist(id: id, name: name) }

    static func artistKeys(of song: BaseItem) -> Set<String> { MusicKeys.artists(of: song) }
}

extension Array where Element == BaseItem {
    /// `albumsInOrder`, for downloaded songs: the same shelf of covers, each
    /// carrying the cover file of the song it was made from.
    func localAlbums() -> [BaseItem] {
        let art = Dictionary(compactMap { s in s.AlbumId.map { ($0, s.ExternalLogoURL) } }, uniquingKeysWith: { a, _ in a })
        return albumsInOrder().map {
            var album = $0
            album.ExternalLogoURL = art[album.Id] ?? nil
            if album.AlbumArtist == nil, let song = first(where: { $0.AlbumId == album.Id }) {
                album.AlbumArtist = song.AlbumArtist
                album.Artists = song.AlbumArtist.map { [$0] }
            }
            return album
        }
    }

    /// The artists of these songs, one entry each, most songs first.
    func localArtists() -> [BaseItem] {
        var order: [String] = []
        var found: [String: (item: BaseItem, count: Int)] = [:]
        for song in self {
            let pair = song.AlbumArtists?.first ?? song.ArtistItems?.first
            guard let name = pair?.Name ?? song.AlbumArtist, !name.isEmpty else { continue }
            let key = name.lowercased()
            if found[key] == nil {
                var artist = BaseItem()
                artist.Id = pair?.Id ?? "local-artist:\(key)"
                artist.Name = name
                artist.type = "MusicArtist"
                artist.ExternalLogoURL = song.ExternalLogoURL
                found[key] = (artist, 0)
                order.append(key)
            }
            found[key]?.count += 1
        }
        return order.compactMap { found[$0] }.sorted { $0.count > $1.count }.map(\.item)
    }
}

#endif

// MARK: - One door for every mix

/// Where every station is started: Listen Now, Surprise Me, Start Station,
/// CarPlay, the end of a queue. Built by `StationBuilder`, from the server
/// when there is one and from downloads when there isn't.
@MainActor
enum MusicMixes {
    struct Started {
        var started: Bool
        /// Built on this device, from downloads only.
        var isLocal: Bool
    }

    @discardableResult
    static func startStation(from seed: BaseItem, title: String) async -> Started {
        guard let station = await StationBuilder.build(from: seed, title: title) else {
            return Started(started: false, isLocal: JellyfinClient.shared.isOffline)
        }
        var first: [BaseItem] = []
        if seed.isSong { first = [station.pool[seed.Id] ?? seed] }
        let songs = first + station.upcoming(count: MusicPlayer.stationDepth, after: first)
        guard !songs.isEmpty else { return Started(started: false, isLocal: station.isLocal) }
        MusicPlayer.shared.playStation(station, songs: songs)
        return Started(started: true, isLocal: station.isLocal)
    }
}
