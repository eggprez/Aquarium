//  Stations that listen back.
//
//  A station is built from a seed — a song, an album, an artist, a genre, or
//  one of the stations about this account rather than any one thing
//  (Rediscover, Deep Cuts). Building it gathers a large pool of candidates
//  from several places at once: the server's Instant Mix of the seed, the
//  Instant Mix of its artist, songs by the artists the server calls similar,
//  and every spelling of its genre. `StationRanker` then picks and orders
//  from the pool.
//
//  The pool is kept for as long as the station plays. Each song finished or
//  skipped feeds `StationSession`, and the music player re-deals what is
//  still to come from the same pool (see `MusicPlayer.restation`).
//
//  Nothing outlives the station but one thing: Surprise Me remembers, by
//  time of day and by car or not, which genres its sessions leaned toward
//  (`MoodMemory`), and starts the next one with a light nudge that way. The
//  nudge fades within a few songs; everything else is the seed, the
//  server's own record of the account — favourites, play counts — and the
//  points the listener has spent on what stations favour (`MixPoints`).

import Foundation
import Observation
import os

@MainActor
@Observable
final class LiveStation {
    let title: String
    let seed: BaseItem
    let profile: MixProfile
    /// Built from downloads only — no server was asked.
    let isLocal: Bool
    @ObservationIgnored private(set) var pool: [String: BaseItem] = [:]
    /// Watched, so the "what's leading" card redraws as it moves.
    var session: StationSession
    /// Songs the pool has already been widened from.
    @ObservationIgnored fileprivate var widenedFrom = Set<String>()
    /// Each song's luck, 0..<1, drawn once: the Surprise dial says how much
    /// it counts, and a re-deal moves only what the listener gave it cause to.
    @ObservationIgnored private var luck: [String: Double] = [:]

    init(title: String, seed: BaseItem, profile: MixProfile, isLocal: Bool, pool: [BaseItem]) {
        self.title = title
        self.seed = seed
        self.profile = profile
        self.isLocal = isLocal
        // A Surprise Mix drifts faster — a forty-minute session is a dozen
        // songs, and the mood at the end of it is not the one at the start —
        // and opens with the genres this time of day has leaned toward.
        if profile.isSurprise {
            session = StationSession(decay: 0.85, prior: MoodMemory.prior())
        } else {
            session = StationSession()
        }
        add(pool)
    }

    func add(_ songs: [BaseItem]) {
        for song in songs where song.isSong && pool[song.Id] == nil { pool[song.Id] = song }
    }

    /// What should play next, `count` of it, after `history`.
    func upcoming(count: Int, after history: [BaseItem], exclude: Set<String> = []) -> [BaseItem] {
        let skip = exclude.union(history.map(\.Id)).union(session.passed)
        for id in pool.keys where luck[id] == nil { luck[id] = Double.random(in: 0..<1) }
        let scored = StationRanker.score(
            Array(pool.values), profile: profile, session: session, exclude: skip, luck: luck
        )
        return StationRanker.sequence(scored, count: count, profile: profile, after: history)
    }

    /// How many songs in the pool could still be offered.
    func remaining(excluding: Set<String>) -> Int {
        pool.keys.filter { !excluding.contains($0) && !session.passed.contains($0) }.count
    }
}

// MARK: - Seeds that aren't one thing

enum SpecialStation: String, CaseIterable {
    case rediscover, deepCuts
    /// Surprise Me. Not a tile: the button on the Discover pages starts it.
    case surprise

    static let prefix = "fj-station:"

    init?(seed: BaseItem) {
        guard seed.Id.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: String(seed.Id.dropFirst(Self.prefix.count)))
    }

    var title: String {
        switch self {
        case .rediscover: "Rediscover"
        case .deepCuts: "Deep Cuts"
        case .surprise: "Surprise Mix"
        }
    }

    var subtitle: String {
        switch self {
        case .rediscover: "Favourites you haven't played lately"
        case .deepCuts: "Songs you haven't heard by artists you love"
        case .surprise: "A shuffle of what you play, learning as it goes"
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

    /// Which of these to offer as tiles. Both are read from the server's
    /// record of the account, so both are always worth a try. Surprise Me
    /// has a button of its own.
    @MainActor
    static func available() -> [SpecialStation] { [.rediscover, .deepCuts] }
}

// MARK: - Genres, every spelling of them

/// The server's genres grouped by `MusicNames.genreKey`, so "Rock" and
/// "Rockmusik" are asked for together. Read once and kept for an hour.
@MainActor
enum GenreCatalog {
    private static var byKey: [String: [NameGuidPair]] = [:]
    private static var readAt: Date?
    /// Key → a Latin spelling the library has for it, for naming a station
    /// after a tag in another script. Readable from anywhere, since names
    /// are made wherever a list is.
    private nonisolated static let latin = OSAllocatedUnfairLock(initialState: [String: String]())

    static func genres(forKey key: String) async -> [NameGuidPair] {
        await prime()
        return byKey[key] ?? []
    }

    /// Read the server's genres if they haven't been in the last hour.
    static func prime() async {
        guard readAt == nil || Date().timeIntervalSince(readAt!) > 3600 else { return }
        guard let all = try? await JellyfinClient.shared.musicGenres(limit: 2000).items else { return }
        byKey = Dictionary(grouping: all.map { NameGuidPair(Id: $0.Id, Name: $0.Name) }) {
            MusicNames.genreKey($0.Name ?? "")
        }
        readAt = Date()
        var spellings: [String: String] = [:]
        for (key, pairs) in byKey {
            if let name = pairs.compactMap(\.Name).first(where: { MusicNames.isLatin($0) && !$0.isEmpty }) { spellings[key] = name }
        }
        let found = spellings
        latin.withLock { $0 = found }
    }

    nonisolated static func latinSpelling(forKey key: String) -> String? {
        latin.withLock { $0[key] }
    }
}

// MARK: - Building

@MainActor
enum StationBuilder {
    static let genrePrefix = "fj-genre:"

    /// A station from `seed`: the server's when there is a server, this
    /// device's downloads when there isn't or the server has nothing — or
    /// the downloads whatever the server could do, when `localOnly`, which
    /// is what the Downloaded page asks for.
    static func build(from seed: BaseItem, title: String, localOnly: Bool = false) async -> LiveStation? {
        let station: LiveStation?
        #if !os(tvOS)
        station = localOnly ? local(from: seed, title: title) : await remoteOrLocal(from: seed, title: title)
        #else
        station = await remoteOrLocal(from: seed, title: title)
        #endif
        if let station { TagCoverage.record(station.pool.values) }
        return station
    }

    private static func remoteOrLocal(from seed: BaseItem, title: String) async -> LiveStation? {
        let client = JellyfinClient.shared
        #if !os(tvOS)
        if client.isOffline || seed.Id.hasPrefix("local-") {
            return local(from: seed, title: title)
        }
        #endif
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
            let pool = (await songs) + (await mix)
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
        var pool = mix + (await ofArtist) + (await similar)
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
        switch special {
        case .rediscover:
            let favs: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 200)
                q.favorites = true
                return q
            }()
            async let starred = fetch(favs)
            async let top = try? client.mostPlayedSongs(limit: 150)
            let all = (await starred) + (await top ?? [])
            return (all.filter(isForgotten), MixProfile(open: true))
        case .deepCuts:
            // The artists starred on the server, then the ones its play
            // counts say are heard most.
            async let starred = try? client.albumArtists(limit: 10, favorites: true).items
            async let top = try? client.mostPlayedSongs(limit: 60)
            var ids = (await starred ?? []).map(\.Id)
            for song in await top ?? [] {
                guard ids.count < 10 else { break }
                if let id = (song.AlbumArtists?.first ?? song.ArtistItems?.first)?.Id, !ids.contains(id) { ids.append(id) }
            }
            guard !ids.isEmpty else { return ([], MixProfile(open: true)) }
            var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 250)
            q.artistIds = ids
            q.played = false
            return (await fetch(q), MixProfile(open: true))
        case .surprise:
            // A shuffle of what this account plays: what it has starred and
            // played, more by the same artists, and a few songs from
            // anywhere, so there is something to be surprised by.
            let favs: JellyfinClient.MusicQuery = {
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 150)
                q.favorites = true
                return q
            }()
            async let starred = fetch(favs)
            async let top = try? client.mostPlayedSongs(limit: 100)
            async let recent = try? client.recentlyPlayedSongs(limit: 60)
            async let anywhere = fetch(JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 50))
            let known = (await starred) + (await top ?? []) + (await recent ?? [])
            var artistIds: [String] = []
            for song in known.shuffled() {
                guard artistIds.count < 25 else { break }
                if let id = (song.AlbumArtists?.first ?? song.ArtistItems?.first)?.Id, !artistIds.contains(id) { artistIds.append(id) }
            }
            var byArtists: [BaseItem] = []
            if !artistIds.isEmpty {
                var q = JellyfinClient.MusicQuery(types: "Audio", sort: .random, limit: 250)
                q.artistIds = artistIds
                byArtists = await fetch(q)
            }
            return (known + byArtists + (await anywhere), MixProfile(open: true, surprise: true))
        }
    }

    /// A favourite not heard in six weeks, by the server's record.
    private static func isForgotten(_ song: BaseItem) -> Bool {
        let cutoff = Date().addingTimeInterval(-42 * 86400)
        if let last = Format.parseDate(song.UserData?.LastPlayedDate), last > cutoff { return false }
        return true
    }

    // MARK: Widening

    /// Pull in more like `song` — when a Surprise Mix has found a direction
    /// (see `StationSession.supports`), or when the pool runs low. Once per
    /// song. False when the pool is no bigger for it.
    @discardableResult
    static func widen(_ station: LiveStation, from song: BaseItem) async -> Bool {
        guard !station.widenedFrom.contains(song.Id) else { return false }
        station.widenedFrom.insert(song.Id)
        let client = JellyfinClient.shared
        #if !os(tvOS)
        guard !station.isLocal, !client.isOffline else { return false }
        #endif
        let artistId = (song.AlbumArtists?.first ?? song.ArtistItems?.first)?.Id
        async let mix = try? client.instantMix(from: song.Id, limit: 60)
        async let similar = similarArtistSongs(artistId)
        let before = station.pool.count
        station.add((await mix ?? []) + (await similar))
        return station.pool.count > before
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
                // As the server's: what is starred, and what is played most.
                let top = songs.filter { ($0.userData.PlayCount ?? 0) > 0 }
                    .sorted { ($0.userData.PlayCount ?? 0) > ($1.userData.PlayCount ?? 0) }
                    .prefix(150)
                let wanted = Set(top.map(\.Id))
                pool = songs.filter { ($0.userData.isFavorite || wanted.contains($0.Id)) && isForgotten($0) }
                profile = MixProfile(open: true)
            case .deepCuts:
                // The artists of what is starred and what is played most.
                let played = songs.filter { ($0.userData.PlayCount ?? 0) > 0 }
                    .sorted { ($0.userData.PlayCount ?? 0) > ($1.userData.PlayCount ?? 0) }
                let top = (songs.filter(\.userData.isFavorite) + played.prefix(40))
                    .reduce(into: Set<String>()) { $0.formUnion(MusicKeys.artists(of: $1)) }
                pool = songs.filter { !top.isDisjoint(with: MusicKeys.artists(of: $0)) && ($0.userData.PlayCount ?? 0) == 0 }
                profile = MixProfile(open: true)
            case .surprise:
                // Everything on the device: the shuffle is the point, and
                // the downloads are already what this listener keeps.
                profile = MixProfile(open: true, surprise: true)
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

// MARK: - What the tags leave out

/// How many of the songs recent stations chose from had no artist, genre or
/// year. A song missing a tag scores nothing on the dial that reads it, so
/// the more of them there are, the less that dial's points can do — and the
/// page where points are spent says so (see `note(for:)`). Counted from the
/// pools the server answered with; nothing is fetched for it.
struct TagCoverage: Sendable {
    var songs = 0
    var noArtist = 0
    var noGenre = 0
    var noYear = 0

    private static let key = "music_tag_coverage"
    /// How many stations back "recent" goes.
    private static let depth = 5

    /// The last few stations' pools, added together.
    static var recent: TagCoverage {
        var out = TagCoverage()
        for counts in stored where counts.count == 4 {
            out.songs += counts[0]
            out.noArtist += counts[1]
            out.noGenre += counts[2]
            out.noYear += counts[3]
        }
        return out
    }

    static func record(_ pool: some Collection<BaseItem>) {
        guard !pool.isEmpty else { return }
        let counts = [
            pool.count,
            pool.count { MusicKeys.artists(of: $0).isEmpty },
            pool.count { MusicKeys.genres(of: $0).isEmpty },
            pool.count { $0.ProductionYear == nil },
        ]
        UserDefaults.standard.set(Array((stored + [counts]).suffix(depth)), forKey: key)
    }

    private static var stored: [[Int]] { UserDefaults.standard.array(forKey: key) as? [[Int]] ?? [] }

    /// A sentence for the dial's row when enough songs lack what it reads to
    /// be worth saying. Nil for a dial that reads no tag, and before any
    /// station has played.
    func note(for dial: MixPoints.Dial) -> String? {
        let (missing, tag): (Int, String)
        switch dial {
        case .artist: (missing, tag) = (noArtist, "artist")
        case .genre: (missing, tag) = (noGenre, "genre")
        case .era: (missing, tag) = (noYear, "year")
        case .favorites, .mostPlayed, .discovery, .surprise: return nil
        }
        guard songs > 0 else { return nil }
        let percent = Int((100 * Double(missing) / Double(songs)).rounded())
        guard percent >= 5 else { return nil }
        return "\(percent)% of the songs your recent stations chose from have no \(tag) tag, so these points have less to work with."
    }
}

// MARK: - One station, while it plays

/// What a listener did with one song.
enum ListenReaction: Sendable {
    case finished, heardMost, skippedMid, skippedEarly, removed

    /// How a song leaving the player reads. `heard` is seconds actually
    /// played, seeks not counted. Nil when it says nothing either way.
    init?(heard: Double, duration: Double, finished: Bool, skipped: Bool) {
        let f = duration > 0 ? min(1, heard / duration) : 0
        if finished || f >= 0.9 {
            self = .finished
        } else if skipped {
            self = heard < 30 || f < 0.25 ? .skippedEarly : f < 0.6 ? .skippedMid : .heardMost
        } else if f >= 0.5 {
            // Stopped, or something else was put on: only counts for it.
            self = .heardMost
        } else {
            return nil
        }
    }
}

/// What has happened in the station playing now — everything a station goes
/// on beyond its seed. Each reaction fades the ones before it a little, so
/// the last few songs steer hardest, and the whole of it is forgotten when
/// the station ends. That is what makes a station change course after two
/// skips. A Surprise Mix also opens with `prior`, a few genres remembered
/// from earlier sessions at this time of day, which fades out as soon as
/// there are reactions of this session's own to go on.
struct StationSession: Sendable {
    private(set) var artists: [String: Double] = [:]
    private(set) var genres: [String: Double] = [:]
    /// Skipped or removed while this station played: not again.
    private(set) var passed = Set<String>()
    /// How many reactions this station has had: how far a Surprise Mix has
    /// come from being a shuffle.
    private(set) var reactions = 0
    /// How much of what came before each reaction keeps.
    let decay: Double
    /// Genre keys to -1...1: the opening nudge, from `MoodMemory`.
    let prior: [String: Double]

    init(decay: Double = 0.9, prior: [String: Double] = [:]) {
        self.decay = decay
        self.prior = prior
    }
    /// How each artist is spelled, by the keys `MusicKeys.artists` gives it
    /// — an id, a lowercased name — so `artistLeanings` can say who.
    private(set) var artistNames: [String: String] = [:]

    /// One name and what it has earned, for the player's "what's leading"
    /// card.
    struct Leaning: Identifiable, Equatable, Sendable {
        let name: String
        let points: Double
        var id: String { name }
    }

    /// The artists this station has come to lean toward or away from,
    /// most points first. An artist is reached by more than one key — its
    /// id and its name move together — so each is listed once, under the
    /// best spelling kept for it.
    var artistLeanings: [Leaning] {
        var points: [String: Double] = [:]
        var spelled: [String: String] = [:]
        for (key, value) in artists {
            guard let name = artistNames[key] ?? (key.hasPrefix("name:") ? String(key.dropFirst(5)) : nil),
                  !name.isEmpty else { continue }
            let k = name.lowercased()
            if spelled[k] == nil || spelled[k] == k { spelled[k] = name }
            if abs(value) > abs(points[k] ?? 0) { points[k] = value }
        }
        return points.map { Leaning(name: spelled[$0.key] ?? $0.key, points: $0.value) }
            .sorted { $0.points == $1.points ? $0.name < $1.name : $0.points > $1.points }
    }

    /// The genres, the same way, by their keys: the caller names them.
    var genreLeanings: [Leaning] {
        genres.map { Leaning(name: $0.key, points: $0.value) }
            .sorted { $0.points == $1.points ? $0.name < $1.name : $0.points > $1.points }
    }

    mutating func note(_ song: BaseItem, _ reaction: ListenReaction) {
        reactions += 1
        for k in artists.keys { artists[k]! *= decay }
        for k in genres.keys { genres[k]! *= decay }
        shift(song, by: Self.weight(reaction))
        if [.skippedEarly, .skippedMid, .removed].contains(reaction) { passed.insert(song.Id) }
    }

    /// How far a Surprise Mix's own reactions count yet, 0...1.
    ///
    /// The first song finished used to steer the next twenty-five as hard as
    /// any later one: a song nobody chose, let play because nobody minded,
    /// tilted the deal toward itself before there was anything else to go
    /// on. Now the session's leanings come in gradually — about a fifth after
    /// one reaction, half after three, nine-tenths by the tenth — which, at
    /// a dozen songs to a forty-minute session, is a shuffle for the first
    /// few and a mix by the middle.
    var ramp: Double { 1 - exp(-Double(reactions) / 4) }

    /// What a Surprise Mix makes of the session so far, for one song: its
    /// leanings let in by `ramp`, and the remembered mood, fading.
    ///
    /// Leaning away comes in faster than leaning toward. A skip is the one
    /// signal that is never passive, and someone who skips a lot is saying
    /// most of what they have to say that way.
    func surpriseLean(for song: BaseItem) -> Double {
        let own = lean(for: song)
        let share = own >= 0 ? ramp : ramp.squareRoot()
        return own * share + priorLean(for: song)
    }

    /// The remembered mood's say over one song: up to a point and a half
    /// either way to begin with — a nudge against a shuffle's five points of
    /// luck — and a third of that after three reactions, next to nothing
    /// after nine.
    func priorLean(for song: BaseItem) -> Double {
        guard !prior.isEmpty else { return 0 }
        let keys = MusicKeys.genres(of: song)
        guard !keys.isEmpty else { return 0 }
        let mood = keys.reduce(0.0) { $0 + (prior[$1] ?? 0) } / Double(keys.count)
        return 1.5 * mood * exp(-Double(reactions) / 3)
    }

    /// Whether a Surprise Mix has heard enough in this song's direction to
    /// go looking for more of it: two songs by its artist played out, or two
    /// in its genre, and never in the first few songs. Before this, every
    /// song finished pulled sixty like it into the pool — the first one
    /// included, which is how a session ended up being about whatever
    /// happened to play first.
    func supports(_ song: BaseItem) -> Bool {
        guard reactions >= 3 else { return false }
        let artist = MusicKeys.artists(of: song).map { artists[$0] ?? 0 }.max() ?? 0
        let genre = MusicKeys.genres(of: song).map { genres[$0] ?? 0 }.max() ?? 0
        return artist >= 1.5 || genre >= 0.9
    }

    func lean(for song: BaseItem) -> Double {
        let a = MusicKeys.artists(of: song).reduce(0.0) { best, key in
            let v = artists[key] ?? 0
            return abs(v) > abs(best) ? v : best
        }
        let keys = MusicKeys.genres(of: song)
        let g = keys.isEmpty ? 0 : keys.reduce(0.0) { $0 + (genres[$1] ?? 0) } / Double(keys.count)
        return 3 * tanh(a / 2) + 2 * tanh(g / 2)
    }

    private static func weight(_ reaction: ListenReaction) -> (artist: Double, genre: Double) {
        switch reaction {
        // One skip is mostly about the song; two or three by the same
        // artist are about the artist.
        case .finished: (1, 0.5)
        case .heardMost: (0.4, 0.2)
        case .skippedMid: (-0.5, -0.2)
        case .skippedEarly: (-1, -0.4)
        case .removed: (-0.6, -0.25)
        }
    }

    private mutating func shift(_ song: BaseItem, by w: (artist: Double, genre: Double)) {
        for key in MusicKeys.artists(of: song) { artists[key, default: 0] += w.artist }
        for key in MusicKeys.genres(of: song) { genres[key, default: 0] += w.genre }
        for pair in (song.ArtistItems ?? []) + (song.AlbumArtists ?? []) {
            guard let name = pair.Name, !name.isEmpty else { continue }
            for key in MusicKeys.artist(id: pair.Id, name: name) { artistNames[key] = name }
        }
        for name in (song.Artists ?? []) + [song.AlbumArtist].compactMap({ $0 }) where !name.isEmpty {
            artistNames["name:\(name.lowercased())"] = name
        }
    }

    /// Stations once learned from every song for weeks and kept every
    /// reaction for good, in a file of their own. They learn only while they
    /// play now, so what that file kept is let go.
    nonisolated static func forgetOldTaste() {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FellyJin", isDirectory: true)
            .appendingPathComponent("MusicTaste.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
