//  What Surprise Me remembers between sessions: the mood, and only as a
//  place to start.
//
//  A Surprise Mix learns from what is played out and what is skipped, and
//  forgets it all when it ends (see `StationSession`). This is the one thing
//  kept: for each time of day — night, morning, afternoon, evening — in the
//  car or not, which genres the sessions there have leaned toward and away
//  from. The next session in the same slot opens with a light nudge that way
//  (`StationSession.priorLean`), worth a fraction of the shuffle's luck to
//  begin with and next to nothing after the first handful of songs. It never
//  widens the pool, and it never outweighs what the listener does now.
//
//  Genres only. An artist remembered would come back as that artist, every
//  time; a genre comes back as anything in it.
//
//  Moved a little after every reaction rather than written once at the end,
//  because a session has no clean end — it is replaced, paused for good, or
//  the app is gone — and each step is small enough that one session moves
//  the memory about halfway toward itself. Kept per account, in defaults.

import Foundation
#if canImport(CarPlay)
import CarPlay
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum MoodMemory {
    /// How far one reaction moves the memory toward the session's leanings.
    private static let step = 0.07
    /// The most genres kept for one slot.
    private static let kept = 16

    private typealias Slots = [String: [String: Double]]

    // MARK: - Where and when

    private enum Part: String { case night, morning, afternoon, evening }

    private static var part: Part {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: .morning
        case 12..<17: .afternoon
        case 17..<22: .evening
        default: .night
        }
    }

    private static var inCar: Bool {
        #if canImport(CarPlay) && os(iOS)
        UIApplication.shared.connectedScenes.contains { $0.session.role == .carTemplateApplication }
        #else
        false
        #endif
    }

    private static func slot(_ part: Part, car: Bool) -> String { "\(part.rawValue).\(car ? "car" : "elsewhere")" }

    // MARK: - Reading and writing

    private static var key: String? {
        JellyfinClient.shared.session.map { "surprise.mood.\($0.accountKey)" }
    }

    private static func load() -> Slots {
        guard let key, let data = UserDefaults.standard.data(forKey: key),
              let slots = try? JSONDecoder().decode(Slots.self, from: data) else { return [:] }
        return slots
    }

    private static func save(_ slots: Slots) {
        guard let key, let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The nudge for a session starting now: this time of day in this
    /// place, or failing that this time of day anywhere. Nothing from other
    /// times of day — the evening's mood is no guide to the morning's.
    static func prior() -> [String: Double] {
        let slots = load()
        let now = part
        return slots[slot(now, car: inCar)] ?? slots[slot(now, car: !inCar)] ?? [:]
    }

    /// A Surprise Mix reacted to a song: move this slot's memory a step
    /// toward what the session leans toward now.
    static func record(_ session: StationSession) {
        guard key != nil else { return }
        // The session's leanings on the same -1...1 scale `prior` is read
        // on: a genre played out several times reads close to 1, one skipped
        // a few times close to -1.
        var now: [String: Double] = [:]
        for (genre, points) in session.genres where abs(points) > 0.01 {
            now[genre] = tanh(points / 2)
        }
        var slots = load()
        let here = slot(part, car: inCar)
        var memory = slots[here] ?? [:]
        for genre in Set(memory.keys).union(now.keys) {
            memory[genre] = (memory[genre] ?? 0) * (1 - step) + (now[genre] ?? 0) * step
        }
        let strongest = memory.filter { abs($0.value) >= 0.03 }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(kept)
        slots[here] = Dictionary(uniqueKeysWithValues: strongest.map { ($0.key, $0.value) })
        save(slots)
    }

    /// The genres a session started from, strongest first, for the
    /// "what's leading" card.
    static func describe(_ prior: [String: Double], limit: Int = 3) -> [String] {
        prior.filter { $0.value > 0.05 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { MusicNames.genreName($0.key) }
    }
}
