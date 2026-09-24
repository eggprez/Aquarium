//  Playlists: the server's own, and the smart ones this app keeps.
//
//  A Jellyfin playlist is a list the server holds — made, renamed, added to,
//  reordered and deleted through its API, and shared with every other client.
//  A smart playlist is a *rule* — "rock, added this year, most played first,
//  fifty songs" — that the server has no notion of. It is kept here, travels
//  between this account's devices over iCloud with the rest of the settings,
//  and is answered afresh from the library every time it is opened. One can
//  be frozen into a real playlist at any moment, which is how it reaches the
//  web client and the television.

import Foundation
import os
import Observation

// MARK: - The server's playlists, cached

/// The account's audio playlists, kept in memory so the "Add to Playlist"
/// menu can open without a round trip, and refreshed whenever one changes.
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore()

    private(set) var playlists: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private var loaded = false
    /// Something changed that only the server can redraw — a playlist's cover
    /// is made from its songs — so the next caller that wants the list asks
    /// for it again. See `add` and `remove`.
    private var isStale = false

    private init() {}

    /// Ask once; after that only `refresh`, or a change marking the list
    /// stale, asks again.
    func ensureLoaded() async {
        guard !loaded || isStale, !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await JellyfinClient.shared.audioPlaylists()
            lastError = nil
            loaded = true
            isStale = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reset() {
        playlists = []
        loaded = false
    }

    // MARK: Changes

    /// Every change goes through here so the cached list, the pages showing
    /// it and the mutation notice all move together.
    ///
    /// Only creating one asks for the whole list again, since the new
    /// playlist is something only the server can describe. The rest are
    /// applied to the list in hand: each used to be a second round trip for
    /// the entire list, on top of the change itself.
    func create(name: String, itemIds: [String]) async throws -> String {
        let id = try await JellyfinClient.shared.createPlaylist(name: name, itemIds: itemIds)
        await refresh()
        ItemMutations.shared.changed()
        return id
    }

    func rename(_ playlistId: String, to name: String) async throws {
        try await JellyfinClient.shared.renamePlaylist(playlistId, to: name)
        if let i = playlists.firstIndex(where: { $0.Id == playlistId }) { playlists[i].Name = name }
        ItemMutations.shared.changed()
    }

    func delete(_ playlistId: String) async throws {
        try await JellyfinClient.shared.deletePlaylist(playlistId)
        playlists.removeAll { $0.Id == playlistId }
        ItemMutations.shared.changed()
    }

    func add(_ itemIds: [String], to playlistId: String) async throws {
        try await JellyfinClient.shared.addToPlaylist(playlistId, itemIds: itemIds)
        adjustCount(of: playlistId, by: itemIds.count)
        ItemMutations.shared.changed()
    }

    func remove(entryIds: [String], from playlistId: String) async throws {
        try await JellyfinClient.shared.removeFromPlaylist(playlistId, entryIds: entryIds)
        adjustCount(of: playlistId, by: -entryIds.count)
        ItemMutations.shared.changed()
    }

    /// The song count, which the list shows, kept right straight away; the
    /// cover the server builds from the songs waits for the next look.
    private func adjustCount(of playlistId: String, by delta: Int) {
        if let i = playlists.firstIndex(where: { $0.Id == playlistId }) {
            if let count = playlists[i].ChildCount { playlists[i].ChildCount = max(0, count + delta) }
            if let count = playlists[i].RecursiveItemCount { playlists[i].RecursiveItemCount = max(0, count + delta) }
        }
        isStale = true
    }

    func move(entryId: String, in playlistId: String, to index: Int) async throws {
        try await JellyfinClient.shared.movePlaylistEntry(playlistId, entryId: entryId, to: index)
        ItemMutations.shared.changed()
    }
}

// MARK: - Smart playlists

/// One rule-based playlist. Every field is optional: an empty rule is "every
/// song", and each field that is set narrows it.
struct SmartPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "New Smart Playlist"
    /// Any of these genres, by name.
    var genres: [String] = []
    /// Any of these artists.
    var artists: [NameGuidPair] = []
    var yearFrom: Int? = nil
    var yearTo: Int? = nil
    /// Only songs added to the library in the last so many days.
    var addedWithinDays: Int? = nil
    var favoritesOnly = false
    var played: PlayedFilter = .any
    /// At least this many plays, counted by the server.
    var minPlayCount: Int? = nil
    var sort: MusicSort = .random
    var limit: Int = 100

    enum PlayedFilter: String, Codable, CaseIterable, Sendable {
        case any, played, unplayed
        var label: String {
            switch self {
            case .any: "Any"
            case .played: "Played before"
            case .unplayed: "Never played"
            }
        }
    }

    /// A sentence describing the rule, for the row it is listed on.
    var summary: String {
        var parts: [String] = []
        if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        if !artists.isEmpty { parts.append(artists.compactMap(\.Name).joined(separator: ", ")) }
        switch (yearFrom, yearTo) {
        case let (from?, to?): parts.append("\(min(from, to))–\(max(from, to))")
        case let (from?, nil): parts.append("from \(from)")
        case let (nil, to?): parts.append("up to \(to)")
        default: break
        }
        if let days = addedWithinDays { parts.append("added in the last \(days) day\(days == 1 ? "" : "s")") }
        if favoritesOnly { parts.append("favourites") }
        if played != .any { parts.append(played.label.lowercased()) }
        if let n = minPlayCount, n > 0 { parts.append("played \(n)+ times") }
        let rule = parts.isEmpty ? "Every song" : parts.joined(separator: " · ")
        return "\(rule) · \(sort.label.lowercased()) · \(limit)"
    }

    /// The songs this rule picks out right now.
    ///
    /// The server answers what it can filter — genre, artist, year, favourite,
    /// played — and the rest is settled here: "added within" and a play-count
    /// floor are not things `/Items` can be asked. So those songs are walked
    /// in the order of the thing being filtered on — newest first, most played
    /// first — until they fall past the line, and only then put in the rule's
    /// own order. A fixed first page in the rule's order missed any match
    /// that happened to sort after it.
    @MainActor
    func resolve(client: JellyfinClient? = nil) async throws -> [BaseItem] {
        let client = client ?? .shared
        let cutoff = addedWithinDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let floor = minPlayCount.flatMap { $0 > 0 ? $0 : nil }
        var q = JellyfinClient.MusicQuery(types: "Audio", sort: sort, limit: limit)
        q.genres = genres
        q.artistIds = artists.compactMap(\.Id)
        if let a = yearFrom ?? yearTo, let b = yearTo ?? yearFrom {
            let from = min(a, b), to = max(a, b)
            if to - from <= 150 {
                q.years = Array(from...to)
            }
        }
        q.favorites = favoritesOnly
        switch played {
        case .any: q.played = nil
        case .played: q.played = true
        case .unplayed: q.played = false
        }
        guard cutoff != nil || floor != nil else { return try await client.music(q).items }

        func added(_ s: BaseItem) -> Date { Format.parseDate(s.DateCreated) ?? .distantPast }
        func plays(_ s: BaseItem) -> Int { s.userData.PlayCount ?? 0 }
        func heard(_ s: BaseItem) -> Date { Format.parseDate(s.userData.LastPlayedDate) ?? .distantPast }

        q.sort = cutoff != nil ? .recentlyAdded : .mostPlayed
        q.descending = true
        q.limit = 500
        var songs: [BaseItem] = []
        pages: while true {
            let page = try await client.music(q).items
            for song in page {
                // Past the line on the key being walked: nothing after it can match.
                if let cutoff, added(song) < cutoff { break pages }
                if cutoff == nil, let floor, plays(song) < floor { break pages }
                if let floor, plays(song) < floor { continue }
                songs.append(song)
            }
            q.startIndex += page.count
            // A short page is the end; the cap is for a library that never says so.
            if page.count < q.limit || q.startIndex >= 50_000 { break }
        }

        func byName(_ a: BaseItem, _ b: BaseItem) -> Bool {
            (a.SortName ?? a.title).localizedStandardCompare(b.SortName ?? b.title) == .orderedAscending
        }
        switch sort {
        case .name: songs.sort(by: byName)
        case .artist:
            songs.sort {
                let a = $0.AlbumArtist ?? "", b = $1.AlbumArtist ?? ""
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return byName($0, $1)
            }
        case .recentlyAdded: songs.sort { added($0) > added($1) }
        case .year: songs.sort { ($0.ProductionYear ?? 0) > ($1.ProductionYear ?? 0) }
        case .recentlyPlayed: songs.sort { heard($0) > heard($1) }
        case .mostPlayed: songs.sort { plays($0) > plays($1) }
        case .random: songs.shuffle()
        }
        return Array(songs.prefix(limit))
    }
}

extension SmartPlaylist {
    private enum CodingKeys: String, CodingKey {
        case id, name, genres, artists, yearFrom, yearTo, addedWithinDays
        case favoritesOnly, played, minPlayCount, sort, limit
    }

    /// Forgiving on purpose: a rule written by an older or newer build — a
    /// field missing, a sort this one doesn't know — still reads, with the
    /// default in the gap. A throw here used to empty the whole list, and the
    /// next save pushed that emptiness to every device.
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(UUID.self, forKey: .id) { id = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .name) { name = v }
        if let v = try? c.decodeIfPresent([String].self, forKey: .genres) { genres = v }
        if let v = try? c.decodeIfPresent([NameGuidPair].self, forKey: .artists) { artists = v }
        yearFrom = (try? c.decodeIfPresent(Int.self, forKey: .yearFrom)) ?? nil
        yearTo = (try? c.decodeIfPresent(Int.self, forKey: .yearTo)) ?? nil
        addedWithinDays = (try? c.decodeIfPresent(Int.self, forKey: .addedWithinDays)) ?? nil
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .favoritesOnly) { favoritesOnly = v }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .played), let v = PlayedFilter(rawValue: raw) {
            played = v
        }
        minPlayCount = (try? c.decodeIfPresent(Int.self, forKey: .minPlayCount)) ?? nil
        if let raw = try? c.decodeIfPresent(String.self, forKey: .sort), let v = MusicSort(rawValue: raw) {
            sort = v
        }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .limit), v > 0 { limit = v }
    }

    /// One rule that couldn't be read at all is left out, not the list.
    fileprivate struct Lenient: Decodable {
        let value: SmartPlaylist?
        init(from decoder: any Decoder) throws { value = try? SmartPlaylist(from: decoder) }
    }
}

/// Where the smart playlists live: one JSON blob in the settings, so they
/// travel with them. See `Preferences.smartPlaylists`.
@MainActor
@Observable
final class SmartPlaylistStore {
    static let shared = SmartPlaylistStore()

    private(set) var playlists: [SmartPlaylist]
    /// What is stored held rules that couldn't be read. Saving over it
    /// with nothing would wipe them on every device, so that one save isn't made.
    private var storedUnreadable = false

    /// `Preferences.smartPlaylists`' key, read here rule by rule rather than
    /// as one array that a single bad rule empties.
    private static let key = "smart_playlists"

    private init() {
        let stored = Self.read()
        playlists = stored.rules
        storedUnreadable = stored.unreadable
    }

    /// Another device changed them — see `Preferences.adoptCloudChanges`.
    func reload() {
        let stored = Self.read()
        playlists = stored.rules
        storedUnreadable = stored.unreadable
    }

    private static func read() -> (rules: [SmartPlaylist], unreadable: Bool) {
        guard let data = UserDefaults.standard.data(forKey: key), !data.isEmpty else { return ([], false) }
        guard let rows = try? JSONDecoder().decode([SmartPlaylist.Lenient].self, from: data) else {
            MusicPlayer.log.error("smart playlists: stored list unreadable")
            return ([], true)
        }
        let rules = rows.compactMap(\.value)
        if rules.count < rows.count {
            MusicPlayer.log.error("smart playlists: skipped \(rows.count - rules.count) unreadable")
        }
        return (rules, rules.count < rows.count)
    }

    func upsert(_ playlist: SmartPlaylist) {
        if let i = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[i] = playlist
        } else {
            playlists.append(playlist)
        }
        persist()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        persist()
    }

    func playlist(_ id: UUID) -> SmartPlaylist? {
        playlists.first { $0.id == id }
    }

    private func persist() {
        if storedUnreadable, playlists.isEmpty { return }
        Preferences.shared.smartPlaylists = playlists
        storedUnreadable = false
    }
}
