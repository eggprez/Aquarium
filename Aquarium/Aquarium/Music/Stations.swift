//  Stations that listen back.
//
//  A station is built from a seed — a song, an album, an artist, a genre, or
//  one of the stations about this account rather than any one thing
//  (Rediscover, Deep Cuts, the time-of-day mix). Building it gathers a large
//  pool of candidates from several places at once: the server's Instant Mix
//  of the seed, the Instant Mix of its artist, songs by the artists the
//  server calls similar, every spelling of its genre, and the songs this
//  account gave a thumbs-up. `StationRanker` then picks and orders from the
//  pool.
//
//  The pool is kept for as long as the station plays. Each song finished,
//  skipped or thumbed feeds `StationSession`, and the music player re-deals
//  what is still to come from the same pool (see `MusicPlayer.restation`).
//  A thumbs-up also widens the pool towards the song it was given to.

import Foundation

@MainActor
final class LiveStation {
    let title: String
    let seed: BaseItem
    let profile: MixProfile
    /// Built from downloads only — no server was asked.
    let isLocal: Bool
    private(set) var pool: [String: BaseItem] = [:]
    var session = StationSession()
    /// Songs the pool has already been widened from.
    fileprivate var widenedFrom = Set<String>()

    init(title: String, seed: BaseItem, profile: MixProfile, isLocal: Bool, pool: [BaseItem]) {
        self.title = title
        self.seed = seed
        self.profile = profile
        self.isLocal = isLocal
        add(pool)
    }

    func add(_ songs: [BaseItem]) {
        for song in songs where song.isSong && pool[song.Id] == nil { pool[song.Id] = song }
    }

    /// What should play next, `count` of it, after `history`.
    func upcoming(count: Int, after history: [BaseItem], exclude: Set<String> = []) -> [BaseItem] {
        let skip = exclude.union(history.map(\.Id)).union(session.passed)
        let scored = StationRanker.score(Array(pool.values), profile: profile, session: session, exclude: skip)
        return StationRanker.sequence(scored, count: count, profile: profile, after: history)
    }

    /// How many songs in the pool could still be offered.
    func remaining(excluding: Set<String>) -> Int {
        pool.keys.filter { !excluding.contains($0) && !session.passed.contains($0) }.count
    }
}

// MARK: - Seeds that aren't one thing

enum SpecialStation: String, CaseIterable {
    case rediscover, deepCuts, timeOfDay

    static let prefix = "fj-station:"

    init?(seed: BaseItem) {
        guard seed.Id.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: String(seed.Id.dropFirst(Self.prefix.count)))
    }

    var title: String {
        switch self {
        case .rediscover: "Rediscover"
        case .deepCuts: "Deep Cuts"
        case .timeOfDay: "\(MusicTaste.daypartNames[MusicTaste.daypart()]) Mix"
        }
    }

    var subtitle: String {
        switch self {
        case .rediscover: "Favourites you haven't played lately"
        case .deepCuts: "Songs you haven't heard by artists you love"
        case .timeOfDay: "What you play at this time of day"
        }
    }

    /// A seed for this station, wearing `cover`'s artwork.
    @MainActor
    func seed(cover: BaseItem?) -> BaseItem {
        var seed = BaseItem()
        seed.Id = Self.prefix + rawValue
        seed.Name = title
        if let cover {
            seed.AlbumId = cover.AlbumId
            seed.AlbumPrimaryImageTag = cover.AlbumPrimaryImageTag
            seed.ImageBlurHashes = cover.ImageBlurHashes
            seed.ExternalLogoURL = cover.ExternalLogoURL
        }
        return seed
    }

    /// Which of these have something to offer yet.
    @MainActor
    static func available() -> [SpecialStation] {
        var out: [SpecialStation] = [.rediscover]
        if !MusicTaste.shared.topArtistIds(limit: 1).isEmpty { out.append(.deepCuts) }
        if MusicTaste.shared.daypartFavourites() != nil { out.append(.timeOfDay) }
        return out
    }
}

// MARK: - Genres, every spelling of them

/// The server's genres grouped by `MusicNames.genreKey`, so "Rock" and
/// "Rockmusik" are asked for together. Read once and kept for an hour.
@MainActor
enum GenreCatalog {
    private static var byKey: [String: [NameGuidPair]] = [:]
    private static var readAt: Date?

    static func genres(forKey key: String) async -> [NameGuidPair] {
        if readAt == nil || Date().timeIntervalSince(readAt!) > 3600 {
            if let all = try? await JellyfinClient.shared.musicGenres(limit: 2000).items {
                byKey = Dictionary(grouping: all.map { NameGuidPair(Id: $0.Id, Name: $0.Name) }) {
                    MusicNames.genreKey($0.Name ?? "")
                }
                readAt = Date()
            }
        }
        return byKey[key] ?? []
    }
}

// MARK: - Building

@MainActor
enum StationBuilder {
    static let genrePrefix = "fj-genre:"

    /// A station from `seed`: the server's when there is a server, this
    /// device's downloads when there isn't or the server has nothing.
    static func build(from seed: BaseItem, title: String) async -> LiveStation? {
        let client = JellyfinClient.shared
        #if !os(tvOS)
        if client.isOffline || seed.Id.hasPrefix("local-") {
            return local(from: seed, title: title)
        }
        #endif
        Task { await MusicTaste.shared.flushThumbs() }
        if let station = await remote(from: seed, title: title), !station.pool.isEmpty {
            return station
        }
        #if !os(tvOS)
        return local(from: seed, title: title)
        #else
        return nil
        #endif
    }

    private static func remote(from seed: BaseItem, title: String) async -> LiveStation? {
        let liked = Array(MusicTaste.shared.liked.values)

        if let special = SpecialStation(seed: seed) {
            let (pool, profile) = await specialPool(special)
            return LiveStation(title: title, seed: seed, profile: profile, isLocal: false, pool: pool)
        }

        if seed.isMusicGenre {
            let key = MusicNames.genreKey(seed.title)
            let catalogued = await GenreCatalog.genres(forKey: key).compactMap(\.Id)
            let ids = catalogued.isEmpty && !seed.Id.hasPrefix(genrePrefix) && !seed.Id.isEmpty
                ? [seed.Id] : catalogued
            let byGenre: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 250)
                if ids.isEmpty { q.genres = [seed.title] } else { q.genreIds = ids }
                return q
            }()
            let first = ids.first
            async let songs = fetch(byGenre)
            async let mix = mixOf(first, limit: 100)
            let pool = (await songs) + (await mix) + liked
            return LiveStation(title: title, seed: seed, profile: MixProfile(seed: seed), isLocal: false, pool: pool)
        }

        // A song, an album, an artist, a playlist: the server's mix of it,
        // its artist's mix, and the artists the server calls similar.
        let artistId: String? = seed.isArtist ? seed.Id : (seed.AlbumArtists?.first ?? seed.ArtistItems?.first)?.Id
        async let own = mixOf(seed.Id, limit: 150)
        async let ofArtist = mixOf(seed.isArtist ? nil : artistId, limit: 80)
        async let similar = similarArtistSongs(artistId)
        async let members = seedMembers(seed)
        let mix = await own
        var pool = mix + (await ofArtist) + (await similar) + liked
        var profile = MixProfile(seed: seed, members: await members)
        // A playlist says nothing about itself: what the server mixed from it
        // is the best account of what it sounds like.
        if profile.artists.isEmpty, profile.genres.isEmpty {
            profile = MixProfile(seed: seed, members: Array(mix.prefix(30)))
        }
        // The server's mix matches genres as spelled, so "Rock" never finds
        // "Rockmusik" or "Рок". Ask for the seed's main genres by every
        // spelling the library has.
        var genreIds: [String] = []
        for key in profile.genres.sorted(by: { $0.value > $1.value }).prefix(2).map(\.key) {
            genreIds += await GenreCatalog.genres(forKey: key).compactMap(\.Id)
        }
        if !genreIds.isEmpty {
            var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 120)
            q.genreIds = genreIds
            pool += await fetch(q)
        }
        return LiveStation(title: title, seed: seed, profile: profile, isLocal: false, pool: pool)
    }

    private static func mixOf(_ id: String?, limit: Int) async -> [BaseItem] {
        guard let id else { return [] }
        return (try? await JellyfinClient.shared.instantMix(from: id, limit: limit)) ?? []
    }

    private static func fetch(_ q: JellyfinClient.MusicQuery) async -> [BaseItem] {
        (try? await JellyfinClient.shared.music(q).items) ?? []
    }

    /// Songs by the artists the server finds most like this one.
    private static func similarArtistSongs(_ artistId: String?) async -> [BaseItem] {
        guard let artistId else { return [] }
        let client = JellyfinClient.shared
        guard let similar = try? await client.similarArtists(to: artistId, limit: 8), !similar.isEmpty else { return [] }
        var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 100)
        q.artistIds = similar.map(\.Id)
        return await fetch(q)
    }

    /// An album's tracks or some of an artist's songs: what the seed's genres
    /// and years are read from.
    private static func seedMembers(_ seed: BaseItem) async -> [BaseItem] {
        guard seed.isAlbum || seed.isArtist else { return [] }
        var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 40)
        if seed.isAlbum { q.parentId = seed.Id } else { q.artistIds = [seed.Id] }
        return await fetch(q)
    }

    private static func specialPool(_ special: SpecialStation) async -> ([BaseItem], MixProfile) {
        let client = JellyfinClient.shared
        let taste = MusicTaste.shared
        switch special {
        case .rediscover:
            let favs: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 200)
                q.favorites = true
                return q
            }()
            async let starred = fetch(favs)
            async let top = try? client.mostPlayedSongs(limit: 150)
            let all = (await starred) + (await top ?? []) + Array(taste.liked.values)
            return (all.filter(isForgotten), MixProfile(open: true))
        case .deepCuts:
            var ids = taste.topArtistIds(limit: 10)
            if ids.count < 5, let favourites = try? await client.albumArtists(limit: 10, favorites: true).items {
                ids += favourites.map(\.Id).filter { !ids.contains($0) }
            }
            guard !ids.isEmpty else { return ([], MixProfile(open: true)) }
            var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 250)
            q.artistIds = ids
            q.played = false
            return (await fetch(q), MixProfile(open: true))
        case .timeOfDay:
            guard let fav = taste.daypartFavourites() else { return ([], MixProfile(open: true)) }
            var found: [String] = []
            for key in fav.genres { found += await GenreCatalog.genres(forKey: key).compactMap(\.Id) }
            let genreIds = found
            let byArtist: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 150)
                q.artistIds = fav.artistIds
                return q
            }()
            let byGenre: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 150)
                q.genreIds = genreIds
                return q
            }()
            async let a = fav.artistIds.isEmpty ? [] : fetch(byArtist)
            async let g = genreIds.isEmpty ? [] : fetch(byGenre)
            let pool = (await a) + (await g)
            return (pool, MixProfile(artistIds: fav.artistIds, genreKeys: fav.genres))
        }
    }

    /// A favourite not heard in six weeks, by the server's record or this
    /// device's.
    private static func isForgotten(_ song: BaseItem) -> Bool {
        let cutoff = Date().addingTimeInterval(-42 * 86400)
        if let last = Format.parseDate(song.UserData?.LastPlayedDate), last > cutoff { return false }
        if let last = MusicTaste.shared.songs[song.Id]?.lastFinished, last > cutoff { return false }
        return true
    }

    // MARK: Widening

    /// Pull in more like `song` — after a thumbs-up, or when the pool runs
    /// low. Once per song.
    static func widen(_ station: LiveStation, from song: BaseItem) async {
        guard !station.widenedFrom.contains(song.Id) else { return }
        station.widenedFrom.insert(song.Id)
        let client = JellyfinClient.shared
        #if !os(tvOS)
        guard !station.isLocal, !client.isOffline else { return }
        #endif
        let artistId = (song.AlbumArtists?.first ?? song.ArtistItems?.first)?.Id
        async let mix = try? client.instantMix(from: song.Id, limit: 60)
        async let similar = similarArtistSongs(artistId)
        station.add((await mix ?? []) + (await similar))
    }

    // MARK: On this device

    #if !os(tvOS)
    static func local(from seed: BaseItem, title: String) -> LiveStation? {
        let songs = OfflineMusic.songs
        guard !songs.isEmpty else { return nil }
        let profile: MixProfile
        var pool = songs
        if let special = SpecialStation(seed: seed) {
            switch special {
            case .rediscover:
                pool = songs.filter { ($0.userData.isFavorite || MusicTaste.shared.thumb(for: $0) == 1) && isForgotten($0) }
                profile = MixProfile(open: true)
            case .deepCuts:
                let top = Set(MusicTaste.shared.topArtistIds(limit: 10).map { "id:\($0)" })
                pool = songs.filter { !top.isDisjoint(with: MusicKeys.artists(of: $0)) && ($0.userData.PlayCount ?? 0) == 0 }
                profile = MixProfile(open: true)
            case .timeOfDay:
                guard let fav = MusicTaste.shared.daypartFavourites() else { return nil }
                profile = MixProfile(artistIds: fav.artistIds, genreKeys: fav.genres)
            }
        } else if seed.isArtist {
            let keys = MusicKeys.artist(id: seed.Id, name: seed.Name)
            profile = MixProfile(seed: seed, members: songs.filter { !keys.isDisjoint(with: MusicKeys.artists(of: $0)) })
        } else if seed.isAlbum {
            profile = MixProfile(seed: seed, members: songs.filter { $0.AlbumId == seed.Id })
        } else if seed.isSong {
            // What the device knows about the song beats what the seed says.
            profile = MixProfile(seed: songs.first { $0.Id == seed.Id } ?? seed)
        } else {
            profile = MixProfile(seed: seed)
        }
        return LiveStation(title: title, seed: seed, profile: profile, isLocal: true, pool: pool)
    }
    #endif
}

extension MixProfile {
    /// A station about some artists and some genres, rather than one seed.
    init(artistIds: [String], genreKeys: [String]) {
        self.init(open: false)
        for id in artistIds { artists.formUnion(MusicKeys.artist(id: id, name: nil)) }
        for key in genreKeys {
            genres[key, default: 0] += 1
            for word in Self.words(key) { words[word, default: 0] += 1 }
        }
    }
}
