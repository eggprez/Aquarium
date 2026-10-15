//  What Siri and Shortcuts can ask of whatever is playing: a sleep timer,
//  stop after this episode, the speed, skipping an intro or to the next
//  episode, pausing, a language, and the queue.
//
//  Each works on whichever player is active — the video player or the music
//  player — and says so when neither is. None opens the app: these are the
//  things said to a phone on the nightstand or a remote on the sofa, and
//  the player is already up. The Control Centre buttons and the Live
//  Activity's buttons come through here too (Shared/WidgetTypes.swift,
//  Shared/LiveActivityTypes.swift), so a press and a request do the same.

import AppIntents
import Foundation

// MARK: - Which player

/// The one place that knows which of the two players is the one meant.
@MainActor
enum PlayerActions {
    private static var video: PlayerModel { .shared }
    private static var music: MusicPlayer { .shared }

    /// The video player when it has something up, else the music player
    /// when it does. The video player first: a film is the thing on screen.
    enum Active { case video, music }

    static var active: Active? {
        if video.isActive { return .video }
        if music.isActive, music.current != nil { return .music }
        return nil
    }

    static var isPlaying: Bool {
        switch active {
        case .video: !video.isPaused
        case .music: music.isPlaying
        case nil: false
        }
    }

    static func togglePlayPause() -> Bool {
        switch active {
        case .video: video.togglePlayPause()
        case .music: music.togglePlayPause()
        case nil: return false
        }
        return true
    }

    static func pause() {
        if video.isActive { video.pause() }
        if music.isActive { music.pause() }
    }

    static func setSleepTimer(minutes: Int) -> Bool {
        switch active {
        case .video: video.setSleepTimer(minutes: minutes)
        case .music: music.setSleepTimer(minutes: minutes)
        case nil: return false
        }
        return true
    }

    static func cancelSleepTimer() {
        video.cancelSleepTimer()
        music.cancelSleepTimer()
    }

    static var sleepMinutesRemaining: Int? {
        video.sleepMinutesRemaining ?? music.sleepDeadline.map {
            max(0, Int(($0.timeIntervalSinceNow / 60).rounded()))
        }
    }

    static func setSpeed(_ speed: Double) -> Bool {
        switch active {
        case .video: video.speed = speed
        case .music: music.speed = speed
        case nil: return false
        }
        return true
    }

    /// What the intro or credits button would read right now, or nil when
    /// there is nothing to skip.
    static var skipLabel: String? {
        guard video.isActive, let segment = video.activeSegment else { return nil }
        return segment.isOutro ? "Skip credits" : "Skip intro"
    }

    static func skipSegment() -> Bool {
        guard video.isActive, video.activeSegment != nil else { return false }
        video.skipSegment()
        return true
    }

    /// The next episode where there is one, else the next song.
    static func next() async -> Bool {
        switch active {
        case .video:
            #if os(tvOS)
            guard video.upNext != nil else { return false }
            #else
            guard video.upNext != nil || video.upNextLocalId != nil || !video.queue.isEmpty else { return false }
            #endif
            await video.playNextNow()
            return true
        case .music:
            guard music.hasNext else { return false }
            music.skipNext()
            return true
        case nil:
            return false
        }
    }

    static func stopAfterThis(_ stop: Bool) -> Bool {
        guard video.isActive else { return false }
        if stop { video.cancelAutoplay() } else { video.resumeAutoplay() }
        return true
    }

    /// Make a language the preferred one for audio, and switch to it now when
    /// the file has such a track — the same as choosing it in the player's
    /// menu.
    static func applyAudioLanguage(_ code: String) -> String {
        Preferences.shared.audioLanguage = code
        guard video.isActive else { return "Saved for everything played after." }
        guard let option = video.audioOptions.first(where: { Languages.matches(preference: code, tag: $0.language) }) else {
            return "Saved, but this file has no such track."
        }
        if option.id != video.selectedAudioOption { video.selectAudio(option) }
        return "Switched."
    }

    static func applySubtitleLanguage(_ code: String) -> String {
        Preferences.shared.subtitleLanguage = code
        guard video.isActive else { return "Saved for everything played after." }
        if code == "off" {
            if video.selectedSubtitleOption != nil { video.selectSubtitles(nil) }
            return "Subtitles off."
        }
        let matching = video.subtitleOptions.filter { Languages.matches(preference: code, tag: $0.language) }
        guard let option = matching.first(where: { !$0.isForced }) ?? matching.first else {
            return "Saved, but this file has no such subtitles."
        }
        if option.id != video.selectedSubtitleOption { video.selectSubtitles(option) }
        return "Switched."
    }
}

// MARK: - Sleep timer

struct SetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Stops whatever is playing after a number of minutes.")

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 720))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Stop playing in \(\.$minutes) minutes")
    }

    init() {}
    init(minutes: Int) { self.minutes = minutes }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PlayerActions.setSleepTimer(minutes: minutes) else { throw PlaybackError.nothingPlaying }
        return .result(dialog: "Stopping in \(minutes) minutes.")
    }
}

struct CancelSleepTimerAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Sleep Timer"
    static let description = IntentDescription("Cancels a running sleep timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PlayerActions.sleepMinutesRemaining != nil else {
            return .result(dialog: "There's no sleep timer running.")
        }
        PlayerActions.cancelSleepTimer()
        return .result(dialog: "Sleep timer off.")
    }
}

struct StopAfterEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop After This Episode"
    static let description = IntentDescription("Lets the episode finish and doesn't start the next one. Turn it off to keep the episodes coming again.")

    @Parameter(title: "Stop", default: true)
    var stop: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$stop, .equalTo, true) {
            Summary("Stop after this episode")
        } otherwise: {
            Summary("Keep playing after this episode")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PlayerActions.stopAfterThis(stop) else { throw PlaybackError.nothingPlaying }
        return .result(dialog: stop ? "Stopping after this one." : "The next episode will follow.")
    }
}

// MARK: - Speed

enum PlaybackRate: String, AppEnum {
    case x0_75 = "0.75"
    case x1 = "1"
    case x1_25 = "1.25"
    case x1_5 = "1.5"
    case x1_75 = "1.75"
    case x2 = "2"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Speed")
    static let caseDisplayRepresentations: [PlaybackRate: DisplayRepresentation] = [
        .x0_75: "0.75×", .x1: "Normal", .x1_25: "1.25×", .x1_5: "1.5×", .x1_75: "1.75×", .x2: "2×",
    ]

    var value: Double { Double(rawValue) ?? 1 }
}

struct SetPlaybackSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let description = IntentDescription("Plays what's on faster or slower — an audiobook at 1.5×, a film back to normal.")

    @Parameter(title: "Speed", default: .x1)
    var speed: PlaybackRate

    static var parameterSummary: some ParameterSummary {
        Summary("Play at \(\.$speed)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PlayerActions.setSpeed(speed.value) else { throw PlaybackError.nothingPlaying }
        return .result(dialog: speed == .x1 ? "Back to normal speed." : "Playing at \(speed.rawValue)×.")
    }
}

// MARK: - Skipping

struct SkipSegmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Intro or Credits"
    static let description = IntentDescription("Jumps past the intro or the credits when the server has marked one.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PlayerActions.active == .video else { throw PlaybackError.nothingPlaying }
        guard PlayerActions.skipSegment() else {
            return .result(dialog: "There's no intro or credits to skip right now.")
        }
        return .result(dialog: "Skipped.")
    }
}

struct NextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Episode"
    static let description = IntentDescription("Starts the next episode now — or the next song, when music is playing.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PlayerActions.active != nil else { throw PlaybackError.nothingPlaying }
        guard await PlayerActions.next() else {
            return .result(dialog: "There's nothing queued after this.")
        }
        return .result(dialog: "Playing the next one.")
    }
}

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Pauses what's playing, or starts it again.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PlayerActions.togglePlayPause() else { throw PlaybackError.nothingPlaying }
        return .result(dialog: PlayerActions.isPlaying ? "Playing." : "Paused.")
    }
}

// MARK: - Languages

/// A language the player can be asked for, by the code `Preferences` keeps.
struct LanguageEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Language")
    static let defaultQuery = LanguageQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let off = LanguageEntity(id: "off", name: "Off")
    static let auto = LanguageEntity(id: "", name: "Whatever the file lists first")

    static var all: [LanguageEntity] {
        [auto, off] + Languages.all.map { LanguageEntity(id: $0.code, name: $0.name) }
    }
}

struct LanguageQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LanguageEntity] {
        LanguageEntity.all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [LanguageEntity] {
        let term = string.lowercased()
        return LanguageEntity.all.filter { $0.name.lowercased().hasPrefix(term) || $0.id.contains(term) }
    }

    func suggestedEntities() async throws -> [LanguageEntity] {
        LanguageEntity.all
    }
}

struct SetAudioLanguageIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Audio Language"
    static let description = IntentDescription("Makes a language the preferred one for audio, and switches to it now when the file has that track.")

    @Parameter(title: "Language")
    var language: LanguageEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch the audio to \(\.$language)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard language.id != "off" else { return .result(dialog: "The audio can't be turned off.") }
        let outcome = PlayerActions.applyAudioLanguage(language.id)
        return .result(dialog: "\(outcome)")
    }
}

struct SetSubtitleLanguageIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Subtitle Language"
    static let description = IntentDescription("Makes a language the preferred one for subtitles — or turns them off — and switches now when the file has that track.")

    @Parameter(title: "Language")
    var language: LanguageEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch the subtitles to \(\.$language)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = PlayerActions.applySubtitleLanguage(language.id)
        return .result(dialog: "\(outcome)")
    }
}

// MARK: - The queue

#if !os(tvOS)
enum QueuePosition: String, AppEnum {
    case next, later

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Position")
    static let caseDisplayRepresentations: [QueuePosition: DisplayRepresentation] = [
        .next: "Next", .later: "Later",
    ]
}

struct AddToQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Up Next"
    static let description = IntentDescription("Queues a film, an episode, or a show's unwatched episodes to play after what's on. With nothing playing, it starts now.")

    @Parameter(title: "Title")
    var item: MediaItemEntity

    @Parameter(title: "Position", default: .later)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$item) \(\.$position)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        let items = try await LibraryActions.playable(item)
        guard !items.isEmpty else { return .result(value: [], dialog: "There's nothing to queue in \(item.title).") }
        let player = PlayerModel.shared
        if position == .next { player.queueNext(items) } else { player.queueLater(items) }
        let what = items.count == 1 ? items[0].title : "\(items.count) episodes of \(item.title)"
        return .result(value: items.map(MediaItemEntity.init), dialog: "Queued \(what).")
    }
}

struct GetUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Up Next"
    static let description = IntentDescription("What's queued to play after this: the titles added by hand, then the episode the show would offer.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        let player = PlayerModel.shared
        var items = player.queue
        if let next = player.upNext, !items.contains(where: { $0.Id == next.Id }) { items.append(next) }
        let entities = items.map(MediaItemEntity.init)
        if entities.isEmpty { return .result(value: [], dialog: "Nothing is queued.") }
        let names = entities.prefix(3).map(\.title).joined(separator: ", ")
        let more = entities.count > 3 ? " and \(entities.count - 3) more" : ""
        return .result(value: entities, dialog: "Up next: \(names)\(more).")
    }
}

struct ClearQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Up Next"
    static let description = IntentDescription("Drops everything queued by hand. The show's own next episode still follows.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = PlayerModel.shared.queue.count
        PlayerModel.shared.clearQueue()
        return .result(dialog: count == 0 ? "Nothing was queued." : "Cleared \(count) from up next.")
    }
}
#endif
