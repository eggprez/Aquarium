//  What this account has shown it likes, learned from what it does.
//
//  Two kinds of evidence. Listening: a song heard to the end counts for it,
//  its artist and its genres; a song skipped in the first seconds counts
//  against them, and one skipped halfway counts against it less. And thumbs:
//  a thumbs-down takes a song out of every station for good and weighs
//  heavily against its artist; a thumbs-up does the opposite and keeps the
//  song to hand so a related station can reach for it.
//
//  Listening fades — a half-life of weeks — so this month's taste outweighs
//  last year's. Thumbs don't fade. Thumbs are also sent to the server as the
//  item's Likes rating, which is what carries them to other devices; the rest
//  stays on this one.
//
//  `StationSession` is the same idea for one station while it plays: stronger,
//  immediate, and forgotten when the station ends. That is what makes a
//  station change course after two skips rather than after two weeks.

import Foundation
import Observation
import os

/// What a listener did with one song.
enum ListenReaction: Sendable {
    case finished, heardMost, skippedMid, skippedEarly, thumbUp, thumbDown, removed
}

@MainActor
@Observable
final class MusicTaste {
    static let shared = MusicTaste()

    struct Mark: Codable, Sendable {
        var score = 0.0
        var at = Date.distantPast
        /// 1 up, -1 down, nil neither.
        var thumb: Int?
        var skips = 0
        var finishes = 0
        var lastFinished: Date?
        var lastSkipped: Date?
        /// A thumb the server hasn't been told about yet.
        var thumbUnsent: Bool?
    }

    struct Lean: Codable, Sendable {
        var score = 0.0
        var at = Date.distantPast
    }

    private struct Saved: Codable {
        var songs: [String: Mark] = [:]
        var artists: [String: Lean] = [:]
        var genres: [String: Lean] = [:]
        var dayparts: [[String: Lean]] = []
        var liked: [String: BaseItem] = [:]
    }

    private(set) var songs: [String: Mark] = [:]
    private(set) var artists: [String: Lean] = [:]
    private(set) var genres: [String: Lean] = [:]
    /// Morning, afternoon, evening, late night: the artists (`id:`/`name:`)
    /// and genres (`g:`) heard to the end at that time of day.
    private(set) var dayparts: [[String: Lean]] = Array(repeating: [:], count: 4)
    /// Songs given a thumbs-up, whole, so a station can offer them again.
    private(set) var liked: [String: BaseItem] = [:]
    private(set) var revision = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let songHalfLife = 45.0
    private static let leanHalfLife = 90.0

    private nonisolated static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // the pre-Aquarium name, kept so what is already on disk is found
            .appendingPathComponent("FellyJin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MusicTaste.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let now = Date()
        // What has faded to nothing, and was never thumbed, is let go.
        songs = saved.songs.filter { _, m in
            m.thumb != nil || abs(Self.decayed(m.score, m.at, Self.songHalfLife, now)) > 0.05
                || now.timeIntervalSince(m.at) < 180 * 86400
        }
        artists = saved.artists
        genres = saved.genres
        if saved.dayparts.count == 4 { dayparts = saved.dayparts }
        liked = saved.liked
    }

    // MARK: Reading

    nonisolated static func decayed(_ score: Double, _ at: Date, _ halfLife: Double, _ now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(at) / 86400)
        return score * pow(0.5, days / halfLife)
    }

    /// The thumb on a song: this device's, or failing that the server's.
    func thumb(for song: BaseItem) -> Int? {
        if let t = songs[song.Id]?.thumb { return t }
        switch song.UserData?.Likes {
        case true?: return 1
        case false?: return -1
        default: return nil
        }
    }

    /// How much this account wants to hear a song now, roughly -12…+12, and
    /// whether it has asked never to.
    func lean(for song: BaseItem, now: Date = Date()) -> (score: Double, blocked: Bool) {
        let thumb = thumb(for: song)
        if thumb == -1 { return (0, true) }
        var s = 0.0
        if let m = songs[song.Id] {
            s += 3 * tanh(Self.decayed(m.score, m.at, Self.songHalfLife, now) / 2)
            // Skipped every time it has come up, and never heard out.
            if m.skips >= 3, m.finishes == 0 { s -= 3 }
            if let t = m.lastFinished {
                let hours = now.timeIntervalSince(t) / 3600
                s -= hours < 2 ? 3 : hours < 12 ? 1.5 : hours < 72 ? 0.5 : 0
            }
            if let t = m.lastSkipped, now.timeIntervalSince(t) < 86400 { s -= 1.5 }
        }
        if thumb == 1 { s += 3 }
        s += 2.5 * tanh(artistLean(for: song, now: now) / 2)
        let keys = MusicKeys.genres(of: song)
        if !keys.isEmpty {
            let g = keys.reduce(0.0) { $0 + genreLean($1, now: now) } / Double(keys.count)
            s += 1.2 * tanh(g / 2)
        }
        return (s, false)
    }

    /// The strongest feeling about any of the song's artists, either way.
    func artistLean(for song: BaseItem, now: Date = Date()) -> Double {
        MusicKeys.artists(of: song).reduce(0.0) { best, key in
            guard let l = artists[key] else { return best }
            let v = Self.decayed(l.score, l.at, Self.leanHalfLife, now)
            return abs(v) > abs(best) ? v : best
        }
    }

    func genreLean(_ key: String, now: Date = Date()) -> Double {
        guard let l = genres[key] else { return 0 }
        return Self.decayed(l.score, l.at, Self.leanHalfLife, now)
    }

    /// Artists this account leans towards most, by id, strongest first.
    func topArtistIds(limit: Int = 12) -> [String] {
        let now = Date()
        return artists
            .compactMap { key, l -> (String, Double)? in
                guard key.hasPrefix("id:") else { return nil }
                let v = Self.decayed(l.score, l.at, Self.leanHalfLife, now)
                return v > 0.5 ? (String(key.dropFirst(3)), v) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    nonisolated static func daypart(_ date: Date = Date()) -> Int {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: 0
        case 11..<17: 1
        case 17..<22: 2
        default: 3
        }
    }

    nonisolated static let daypartNames = ["Morning", "Afternoon", "Evening", "Late Night"]

    /// What gets heard out at this time of day: artist ids and genre keys,
    /// strongest first — nil until there are enough listens to say.
    func daypartFavourites(_ part: Int = daypart()) -> (artistIds: [String], genres: [String])? {
        let now = Date()
        let values = dayparts[part].map { ($0.key, Self.decayed($0.value.score, $0.value.at, 30, now)) }
        guard values.reduce(0, { $0 + $1.1 }) >= 5 else { return nil }
        let sorted = values.sorted { $0.1 > $1.1 }
        let ids = sorted.filter { $0.0.hasPrefix("id:") }.prefix(8).map { String($0.0.dropFirst(3)) }
        let genres = sorted.filter { $0.0.hasPrefix("g:") }.prefix(4).map { String($0.0.dropFirst(2)) }
        return (ids, genres)
    }

    // MARK: Learning

    /// A song left the player. `heard` is seconds actually played, seeks not
    /// counted. Returns what it amounted to, for the station playing it.
    @discardableResult
    func noteListen(_ song: BaseItem, heard: Double, duration: Double, finished: Bool, skipped: Bool) -> ListenReaction? {
        guard song.isSong else { return nil }
        let f = duration > 0 ? min(1, heard / duration) : 0
        let reaction: ListenReaction?
        if finished || f >= 0.9 {
            reaction = .finished
        } else if skipped {
            reaction = heard < 30 || f < 0.25 ? .skippedEarly : f < 0.6 ? .skippedMid : .heardMost
        } else {
            // Stopped, or something else was put on: only counts for it.
            reaction = f >= 0.5 ? .heardMost : nil
        }
        guard let reaction, Preferences.shared.musicLearns else { return reaction }
        let now = Date()
        let w: (song: Double, artist: Double, genre: Double) = switch reaction {
        case .finished: (1, 0.4, 0.15)
        case .heardMost: (0.4, 0.15, 0.05)
        case .skippedMid: (-0.5, -0.12, -0.04)
        case .skippedEarly: (-1.2, -0.35, -0.1)
        default: (0, 0, 0)
        }
        var m = songs[song.Id] ?? Mark()
        m.score = Self.decayed(m.score, m.at, Self.songHalfLife, now) + w.song
        m.at = now
        switch reaction {
        case .finished, .heardMost:
            m.finishes += 1
            m.lastFinished = now
        case .skippedEarly, .skippedMid:
            m.skips += 1
            m.lastSkipped = now
        default: break
        }
        songs[song.Id] = m
        nudge(song, artist: w.artist, genre: w.genre, now: now)
        if reaction == .finished || reaction == .heardMost {
            let part = Self.daypart(now)
            let weight = reaction == .finished ? 1.0 : 0.5
            for key in [MusicKeys.lead(of: song)] + MusicKeys.genres(of: song).map({ "g:\($0)" }) {
                let l = dayparts[part][key] ?? Lean()
                dayparts[part][key] = Lean(score: Self.decayed(l.score, l.at, 30, now) + weight, at: now)
            }
        }
        changed()
        return reaction
    }

    /// Thumbs up (1), down (-1), or neither (nil). Sent to the server as the
    /// song's Likes rating; kept and retried when there is no server.
    func setThumb(_ song: BaseItem, _ value: Int?) {
        let now = Date()
        var m = songs[song.Id] ?? Mark()
        let old = m.thumb ?? thumb(for: song)
        guard old != value else { return }
        // Take back what the old thumb said about the artist, then say the new.
        let delta = Double(value ?? 0) - Double(old ?? 0)
        nudge(song, artist: 1.0 * delta, genre: 0.3 * delta, now: now)
        m.thumb = value
        m.at = max(m.at, now)
        m.thumbUnsent = true
        songs[song.Id] = m
        if value == 1 {
            var kept = song
            kept.UserData = nil
            liked[song.Id] = kept
            if liked.count > 500, let other = liked.keys.first(where: { $0 != song.Id }) { liked[other] = nil }
        } else {
            liked[song.Id] = nil
        }
        changed()
        Task { await send(song.Id) }
    }

    /// Thumbs given with no server, sent now.
    func flushThumbs() async {
        for id in songs.filter({ $0.value.thumbUnsent == true }).map(\.key).prefix(50) {
            await send(id)
        }
    }

    private func send(_ id: String) async {
        guard let m = songs[id], m.thumbUnsent == true else { return }
        let client = JellyfinClient.shared
        guard client.isSignedIn, !client.isOffline else { return }
        do {
            try await client.setLikes(id, likes: m.thumb.map { $0 > 0 })
            // Unless it changed again while that was in flight.
            if songs[id]?.thumb == m.thumb { songs[id]?.thumbUnsent = nil }
            changed()
        } catch {
            MusicPlayer.log.error("couldn't send a thumb for \(id, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Everything listening taught, gone; thumbs kept.
    func forgetListening() {
        songs = songs.compactMapValues { m in
            guard let t = m.thumb else { return nil }
            var kept = Mark()
            kept.thumb = t
            kept.at = m.at
            kept.thumbUnsent = m.thumbUnsent
            return kept
        }
        artists = [:]
        genres = [:]
        dayparts = Array(repeating: [:], count: 4)
        let now = Date()
        for (id, m) in songs {
            guard let t = m.thumb, let song = liked[id] else { continue }
            nudge(song, artist: 1.0 * Double(t), genre: 0.3 * Double(t), now: now)
        }
        changed()
    }

    var thumbsDownCount: Int { songs.values.filter { $0.thumb == -1 }.count }
    var thumbsUpCount: Int { songs.values.filter { $0.thumb == 1 }.count }

    private func nudge(_ song: BaseItem, artist: Double, genre: Double, now: Date) {
        if artist != 0 {
            for key in MusicKeys.artists(of: song) {
                let l = artists[key] ?? Lean()
                artists[key] = Lean(score: Self.decayed(l.score, l.at, Self.leanHalfLife, now) + artist, at: now)
            }
        }
        if genre != 0 {
            for key in MusicKeys.genres(of: song) {
                let l = genres[key] ?? Lean()
                genres[key] = Lean(score: Self.decayed(l.score, l.at, Self.leanHalfLife, now) + genre, at: now)
            }
        }
    }

    private func changed() {
        revision &+= 1
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let saved = Saved(songs: songs, artists: artists, genres: genres, dayparts: dayparts, liked: liked)
            guard let data = try? JSONEncoder().encode(saved) else { return }
            let file = Self.file
            await Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }.value
        }
    }
}

// MARK: - One station, while it plays

/// What has happened in the station playing now. Stronger than `MusicTaste`
/// and short-lived: each reaction fades the ones before it a little, so the
/// last few songs steer hardest.
struct StationSession: Sendable {
    private(set) var artists: [String: Double] = [:]
    private(set) var genres: [String: Double] = [:]
    /// Skipped, removed or turned down while this station played: not again.
    private(set) var passed = Set<String>()

    mutating func note(_ song: BaseItem, _ reaction: ListenReaction) {
        let w: (artist: Double, genre: Double) = switch reaction {
        // One thumbs-down is mostly about the song; two or three in a row
        // are about the artist. A skip says less than either.
        case .finished: (1, 0.5)
        case .heardMost: (0.4, 0.2)
        case .skippedMid: (-0.5, -0.2)
        case .skippedEarly: (-1, -0.4)
        case .thumbUp: (2, 0.8)
        case .thumbDown: (-1.5, -0.5)
        case .removed: (-0.6, -0.25)
        }
        for k in artists.keys { artists[k]! *= 0.9 }
        for k in genres.keys { genres[k]! *= 0.9 }
        for key in MusicKeys.artists(of: song) { artists[key, default: 0] += w.artist }
        for key in MusicKeys.genres(of: song) { genres[key, default: 0] += w.genre }
        if [.skippedEarly, .skippedMid, .thumbDown, .removed].contains(reaction) { passed.insert(song.Id) }
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
}
