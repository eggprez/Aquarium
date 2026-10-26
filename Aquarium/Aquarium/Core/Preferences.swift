//  Everything Settings can change, and the saved session it hangs off.
//
//  The Linux build keeps this in ~/.config/fellyjin/config.json. Here it is
//  UserDefaults, with the same key names wherever the setting still means
//  something on Apple platforms — the ones that were about driving an mpv
//  process (binary path, hwdec, audio device names) have no counterpart and are
//  gone rather than left as dead controls.

import Foundation
import Observation

/// Which stream quality a session is pinned to. `nil` maxBitrate is direct play.
struct QualityChoice: Hashable, Sendable, Identifiable {
    var label: String
    /// The same rung in the handful of characters a button on top of the picture
    /// has room for.
    var short: String
    var maxBitrate: Int?
    /// The picture size this rung's bitrate is meant to carry.
    ///
    /// Not decoration, and not something the server works out for itself.
    /// `MaxStreamingBitrate` caps the bits and nothing else, so a rung that
    /// named a resolution without sending one was asking for the source at its
    /// full size and a fraction of its bitrate — 1080p at 1.5 Mbps, which looks
    /// far worse than the 480p the label promised. `DeviceProfile.build` turns
    /// these into the profile conditions that actually make the server scale.
    var maxWidth: Int?
    var maxHeight: Int?
    var id: String { label }
}

enum Quality {
    /// The rungs, highest first — the order adaptive quality steps through.
    ///
    /// The bitrate is the whole stream, audio included, because that is what
    /// `MaxStreamingBitrate` caps; the video target underneath each one is the
    /// ceiling less about 0.8 Mbps for surround. They are set for a medium-high
    /// H.264 encode of 24–30fps live action on server hardware (QSV/NVENC/
    /// VAAPI), which needs roughly a quarter more bits than x264 would for the
    /// same picture. Grain wants more than this and animation less; 50/60fps
    /// wants about 1.4×, which is what the second 1080p rung is there for.
    ///
    /// One ladder rather than two even though HEVC needs ~60% of these numbers:
    /// an HEVC source that stays HEVC through the transcode (see
    /// `DeviceProfile.remuxableVideo`) simply lands well under its ceiling, and
    /// a ceiling nobody reaches costs nothing.
    static let choices: [QualityChoice] = [
        .init(label: "Direct Play (original)", short: "Original", maxBitrate: nil),
        .init(label: "36 Mbps · 4K", short: "4K", maxBitrate: 36_000_000,
              maxWidth: 3840, maxHeight: 2160),
        .init(label: "20 Mbps · 1440p", short: "1440p", maxBitrate: 20_000_000,
              maxWidth: 2560, maxHeight: 1440),
        .init(label: "16 Mbps · 1080p", short: "1080p·16", maxBitrate: 16_000_000,
              maxWidth: 1920, maxHeight: 1080),
        .init(label: "10 Mbps · 1080p", short: "1080p·10", maxBitrate: 10_000_000,
              maxWidth: 1920, maxHeight: 1080),
        .init(label: "5 Mbps · 720p", short: "720p", maxBitrate: 5_000_000,
              maxWidth: 1280, maxHeight: 720),
        .init(label: "2.5 Mbps · 480p", short: "480p", maxBitrate: 2_500_000,
              maxWidth: 854, maxHeight: 480),
    ]

    static func label(for bitrate: Int?) -> String {
        choices.first { $0.maxBitrate == bitrate }?.label ?? "Custom"
    }

    static func shortLabel(for bitrate: Int?) -> String {
        choices.first { $0.maxBitrate == bitrate }?.short ?? "Custom"
    }

    /// Where a bitrate sits on the ladder: 0 is direct play, and a higher
    /// index is a smaller stream. A bitrate that isn't a rung is read as the
    /// rung `snapped` would make of it.
    static func rungIndex(_ bitrate: Int?) -> Int {
        let rung = snapped(bitrate)
        return choices.firstIndex { $0.maxBitrate == rung } ?? 0
    }

    /// What the error card's "Try a smaller stream" asks for: the 720p rung,
    /// or the rung below whatever was already playing at or under it. It
    /// used to ask for a flat 4 Mbps, which is no rung: the quality pill read
    /// "Custom" and the size cap resolved to 480p.
    static func smallerStream(than bitrate: Int?) -> Int? {
        let floor = choices.firstIndex { $0.maxBitrate == 5_000_000 } ?? choices.count - 1
        let index = max(floor, rungIndex(bitrate) + 1)
        return choices[min(index, choices.count - 1)].maxBitrate
    }

    /// A stored bitrate moved onto the current ladder.
    ///
    /// The rungs are not the ones earlier builds wrote, and a saved default of
    /// 4 Mbps — 720p on the old ladder — matches nothing here: the Settings
    /// picker draws a blank row for a tag that isn't in its list, and the
    /// bitrate quietly stops meaning a resolution. Snapping up to the smallest
    /// rung that contains it keeps the resolution the person chose (4 Mbps was
    /// 720p and becomes the 5 Mbps 720p rung) at the cost of a little more
    /// bandwidth, which is the trade this ladder was rebuilt to make anyway.
    /// Direct play stays direct play.
    static func snapped(_ bitrate: Int?) -> Int? {
        guard let bitrate else { return nil }
        if choices.contains(where: { $0.maxBitrate == bitrate }) { return bitrate }
        let rungs = choices.compactMap(\.maxBitrate)
        return rungs.filter { $0 >= bitrate }.min() ?? rungs.max()
    }

    /// The size cap that belongs with a bitrate ceiling.
    ///
    /// A bitrate that isn't one of ours — a rung from an older build still in
    /// UserDefaults, a value synced from a device on a different version — gets
    /// the cap of the largest rung that fits inside it rather than no cap at
    /// all. No cap at all is the fault this field exists to stop, so an
    /// unrecognised number must not be the one case that reintroduces it.
    static func cap(for bitrate: Int?) -> (width: Int, height: Int)? {
        guard let bitrate else { return nil }
        let sized = choices.filter { $0.maxWidth != nil && $0.maxHeight != nil }
        let match = sized.first { $0.maxBitrate == bitrate }
            ?? sized.filter { ($0.maxBitrate ?? .max) <= bitrate }.first
            ?? sized.last
        guard let match, let w = match.maxWidth, let h = match.maxHeight else { return nil }
        return (w, h)
    }
}

struct DownloadQuality: Hashable, Sendable, Identifiable {
    var label: String
    var original: Bool = false
    var videoBitrate: Int?
    var maxWidth: Int?
    /// Sent alongside the width. A width cap on its own does nothing to a
    /// portrait or anamorphic source, which then downloads at full size.
    var maxHeight: Int?
    var id: String { label }

    /// The label without its "(transcoded)", for a menu that has no width to
    /// spare. `label` itself can't lose it: it is what gets written into a
    /// download's meta.json — see `DownloadQualities.named`. In a list headed
    /// by "Original", every other rung being a transcode goes without saying.
    var menuLabel: String {
        original ? "Original" : label.replacingOccurrences(of: " (transcoded)", with: "")
    }
}

enum DownloadQualities {
    /// The same ladder as `Quality.choices`, less the audio: this bitrate is
    /// sent as `VideoBitrate` and the 192 kbps stereo AAC alongside it is
    /// separate. A download is always H.264 — see `JellyfinClient.downloadURL`
    /// — so unlike the streaming rungs there is no HEVC case to leave headroom
    /// for, and these are simply the video targets.
    static let all: [DownloadQuality] = [
        .init(label: "Original quality", original: true),
        .init(label: "4K · 34 Mbps (transcoded)", videoBitrate: 34_000_000, maxWidth: 3840, maxHeight: 2160),
        .init(label: "1440p · 18 Mbps (transcoded)", videoBitrate: 18_000_000, maxWidth: 2560, maxHeight: 1440),
        .init(label: "1080p · 9 Mbps (transcoded)", videoBitrate: 9_000_000, maxWidth: 1920, maxHeight: 1080),
        .init(label: "720p · 4.5 Mbps (transcoded)", videoBitrate: 4_500_000, maxWidth: 1280, maxHeight: 720),
        .init(label: "480p · 2 Mbps (transcoded)", videoBitrate: 2_000_000, maxWidth: 854, maxHeight: 480),
    ]

    /// The rung a stored label names.
    ///
    /// Three passes, and the order matters. An exact match first. Then the
    /// resolution the label leads with, which is what carries a queued or
    /// resumable download across a version where the bitrates moved — the
    /// labels are written into meta.json, and "1080p · 10 Mbps (transcoded)"
    /// from an older build has to keep meaning 1080p rather than becoming
    /// whatever the fallback is. Only then the smallest transcode, chosen over
    /// the first entry because the first entry is *Original quality*: a label
    /// nothing recognises used to turn a 480p request into a full-size download
    /// of the source file.
    static func named(_ label: String) -> DownloadQuality {
        if let exact = all.first(where: { $0.label == label }) { return exact }
        let leading = label.prefix { $0 != " " }.lowercased()
        if !leading.isEmpty,
           let byResolution = all.first(where: { $0.label.prefix { $0 != " " }.lowercased() == leading }) {
            return byResolution
        }
        return all[all.count - 1]
    }
}

/// Where the Live TV tab gets its channels — Jellyfin's own tuner, or a
/// custom M3U playlist and XMLTV guide that never touch the server at all.
/// See LiveTVView.
enum LiveTVSource: String, CaseIterable, Sendable {
    case jellyfin, custom

    var label: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .custom: "Custom playlist (M3U + XMLTV)"
        }
    }
}

enum ThemePref: String, CaseIterable, Sendable {
    case auto, light, dark

    var label: String {
        switch self {
        case .auto: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// How subtitles are drawn over the picture. Mapped onto `AVTextStyleRule`s,
/// which is the one subtitle-styling hook AVPlayer actually honours (it applies
/// to the WebVTT tracks HLS carries — which is every transcoded stream).
enum SubtitleBackground: String, CaseIterable, Sendable {
    case outline, shadow, box

    var label: String {
        switch self {
        case .outline: "Outline"
        case .shadow: "Drop shadow"
        case .box: "Solid strip"
        }
    }
}

/// Languages offered for the audio and subtitle defaults. Several languages
/// have two ISO codes in circulation (French is both `fre` and `fra`) and files
/// in the wild use either, so both are listed and either matches.
enum Languages {
    static let all: [(code: String, name: String)] = [
        ("eng", "English"), ("spa", "Spanish"), ("fre,fra", "French"),
        ("ger,deu", "German"), ("ita", "Italian"), ("por", "Portuguese"),
        ("dut,nld", "Dutch"), ("swe", "Swedish"), ("nor", "Norwegian"),
        ("dan", "Danish"), ("fin", "Finnish"), ("pol", "Polish"),
        ("cze,ces", "Czech"), ("hun", "Hungarian"), ("gre,ell", "Greek"),
        ("rus", "Russian"), ("ukr", "Ukrainian"), ("tur", "Turkish"),
        ("ara", "Arabic"), ("heb", "Hebrew"), ("hin", "Hindi"),
        ("jpn", "Japanese"), ("kor", "Korean"), ("chi,zho", "Chinese"),
        ("tha", "Thai"), ("vie", "Vietnamese"),
    ]

    /// What `Preferences.audioLanguage` can be, each with its name: the
    /// file's own order first, then the languages.
    static let audioChoices: [(code: String, name: String)] =
        [("", "Whatever the file lists first")] + all
    /// What `Preferences.subtitleLanguage` can be: the file's own choice,
    /// never, forced only, then the languages.
    static let subtitleChoices: [(code: String, name: String)] =
        [("", "Only when the file turns them on"), ("off", "Never — no subtitles"),
         (TrackPreference.forcedOnly, "Forced only — signs and foreign lines")] + all

    /// A readable name for a track's language tag, for the times a file names
    /// its tracks by code and nothing else. Anything not on the list above
    /// keeps the code it came with — a wrong name is worse than a bare `nor`.
    static func name(for tag: String) -> String {
        let code = tag.lowercased()
        let match = all.first { entry in
            entry.code.split(separator: ",").contains { code == $0 || code.hasPrefix($0) }
        }
        return match?.name ?? tag.uppercased()
    }

    /// Does a track's language tag satisfy a preference like "fre,fra"?
    static func matches(preference: String, tag: String?) -> Bool {
        guard !preference.isEmpty, let tag = tag?.lowercased(), !tag.isEmpty else { return false }
        return preference.lowercased()
            .split(separator: ",")
            // `tag.hasPrefix($0)` covers a preference code that is the tag or
            // a prefix of it; the last clause is only for a genuinely
            // two-letter ISO 639-1 tag ("en", "fr") against a three-letter
            // preference code. Matching on just the preference's own first
            // two letters, regardless of the tag's length, is what let "pol"
            // satisfy a "por" track — both start "po".
            .contains { tag.hasPrefix($0) || (tag.count <= 2 && $0.hasPrefix(tag)) }
    }
}

// MARK: - Saved session

/// The signed-in server and user. Mirrors `Session` in api.ts; the token is not
/// part of it — that lives in the keychain and only `JellyfinClient` reads it.
struct SavedSession: Codable, Hashable, Sendable {
    var server: String
    var userId: String
    var userName: String
    var deviceId: String
    /// The server's own id, recorded at sign-in. Re-checked before the client
    /// authenticates, so a changed address can't quietly redirect the token.
    var serverId: String?

    var secure: Bool { server.hasPrefix("https://") }

    /// What makes two saved sessions the same account: the server and the
    /// user on it. The rest — a display name, the server's id — can change
    /// under an account without it becoming a different one.
    var accountKey: String { "\(server)|\(userId)" }

    /// The server's address without the scheme, for a line under a name.
    var serverLabel: String {
        server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

// MARK: - Preferences

@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // ---- Session ----

    var session: SavedSession? {
        didSet {
            if let session, let data = try? JSONEncoder().encode(session) {
                defaults.set(data, forKey: "session")
            } else if session == nil {
                defaults.removeObject(forKey: "session")
            }
            if let session { remember(session) }
            publishSessionToCloud()
            #if os(iOS)
            // The watch signs in with whatever this phone is signed in to.
            Task { @MainActor in WatchLink.shared.sendContext() }
            #endif
        }
    }

    /// Every account this device is signed in to: the one in `session`, and
    /// the others it can switch to without a password, because their tokens
    /// are still in the keychain (which has always kept one per server and
    /// user — see `Keychain`). Signing out of an account, or the server
    /// refusing its token, takes it off the list.
    ///
    /// Kept on this device and not sent to iCloud. What travels is the one
    /// account in use (`session.shared`), and a household's other boxes each
    /// decide for themselves who else is signed in on them.
    private(set) var accounts: [SavedSession] = []

    private func remember(_ account: SavedSession) {
        var list = accounts
        if let i = list.firstIndex(where: { $0.accountKey == account.accountKey }) {
            guard list[i] != account else { return }
            list[i] = account
        } else {
            list.append(account)
        }
        accounts = list
        persistAccounts()
    }

    func forgetAccount(_ account: SavedSession) {
        accounts.removeAll { $0.accountKey == account.accountKey }
        persistAccounts()
        #if os(tvOS)
        Keychain.Household.accounts.removeAll { $0.accountKey == account.accountKey }
        #endif
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: "accounts") }
        #if os(tvOS)
        shareWithHousehold()
        #endif
    }

    #if os(tvOS)
    /// Accounts signed in under this Apple TV's *other* users, which this one
    /// can take up without a password — see `Keychain.Household`. This list is
    /// one Apple TV user's; that one is the box's.
    var householdAccounts: [SavedSession] {
        Keychain.Household.accounts.filter { other in
            !accounts.contains { $0.accountKey == other.accountKey }
        }
    }

    /// Tell the rest of the household who is signed in here. Also run at
    /// launch, which is what carries over the accounts of a build from before
    /// the Apple TV's users were told apart: their tokens are in this user's
    /// keychain only until they are copied across.
    private func shareWithHousehold() {
        var shared = Keychain.Household.accounts
        var changed = false
        for account in accounts {
            if let i = shared.firstIndex(where: { $0.accountKey == account.accountKey }) {
                if shared[i] != account { shared[i] = account; changed = true }
            } else {
                shared.append(account)
                changed = true
            }
            Keychain.shareToken(server: account.server, userId: account.userId)
        }
        if changed { Keychain.Household.accounts = shared }
    }
    #endif

    /// Stable per-install id Jellyfin uses to recognise this device across
    /// sign-ins. Generated once and kept; a new one each launch would fill the
    /// server's device list with ghosts.
    private(set) var deviceId: String

    // ---- Appearance ----

    var theme: ThemePref {
        didSet { write(theme.rawValue, forKey: "theme") }
    }

    // ---- Playback ----

    /// The player's quality is Auto: it may drop to a smaller stream by
    /// itself when one keeps stalling, and climb back. On unless a rung is
    /// picked in the player, as on Linux. See `PlayerModel.QualitySelection`.
    var adaptiveQuality: Bool {
        didSet { write(adaptiveQuality, forKey: "adaptive") }
    }

    /// Ease the stream off when the device itself is the limit: a phone that
    /// has run hot, or one in Low Power Mode. See `AdaptiveQuality.notePower`.
    var powerAwareQuality: Bool {
        didSet { write(powerAwareQuality, forKey: "power_aware_quality") }
    }

    /// Start the next episode when one finishes.
    var autoplayNext: Bool {
        didSet { write(autoplayNext, forKey: "autoplay_next") }
    }

    /// Leave Home's Continue Watching row out, keeping Next Up: the next
    /// episode of each show, without a row of stills from the ones you are
    /// partway through.
    var hidesContinueWatching: Bool {
        didSet { write(hidesContinueWatching, forKey: "home_hide_continue_watching") }
    }

    /// Have the server forget the position of episodes left partway through
    /// that Next Up has since moved well past — see `HomeRows.abandoned` —
    /// each time Home loads. Off by default: it writes to the account's watch
    /// state, so it is asked for.
    var clearsAbandonedEpisodes: Bool {
        didSet { write(clearsAbandonedEpisodes, forKey: "home_clear_abandoned") }
    }

    /// Shows taken out of Next Up by hand — see `ItemMenu`'s "Remove from
    /// Next Up". Jellyfin has no way to hide a show from Next Up without
    /// marking something watched, so the list is this app's, and it travels
    /// with the account's other preferences.
    ///
    /// Keyed by account and series (see `nextUpHiddenKey`), the value being
    /// the episode the row was showing when the show was removed. A show
    /// stays hidden while that is still the episode Next Up has for it, and
    /// comes back by itself once something later has been watched — the
    /// same moment the row would have changed anyway. Nothing to forget, no
    /// list to manage.
    var nextUpHidden: [String: String] {
        didSet { write(nextUpHidden, forKey: "next_up_hidden") }
    }

    private func nextUpHiddenKey(seriesId: String) -> String? {
        guard let session else { return nil }
        return session.accountKey + "|" + seriesId
    }

    /// Hide a show from Next Up while `episodeId` is the episode its card
    /// stands for.
    func hideFromNextUp(seriesId: String, episodeId: String) {
        guard let key = nextUpHiddenKey(seriesId: seriesId) else { return }
        nextUpHidden[key] = episodeId
    }

    /// The episode this account removed the show at, if it ever did. The
    /// caller compares it with what the row would show now — see
    /// `HomeRows.visible`.
    func nextUpHiddenEpisode(seriesId: String) -> String? {
        guard let key = nextUpHiddenKey(seriesId: seriesId) else { return nil }
        return nextUpHidden[key]
    }

    /// The rung picked in the player, for the next stream to open at while
    /// the quality isn't Auto (`openingBitrate`). `nil` is direct play. This device's
    /// own, not synced: what a stream can carry depends on the network and
    /// the screen it is on, and an Apple TV on Ethernet and a phone on
    /// cellular want different answers.
    var defaultBitrate: Int? {
        didSet {
            if let defaultBitrate {
                defaults.set(defaultBitrate, forKey: "default_bitrate")
            } else {
                defaults.removeObject(forKey: "default_bitrate")
            }
        }
    }

    /// What a new stream opens at. Auto opens at the best there is and
    /// leaves the rest to `AdaptiveQuality`; a rung picked in the player
    /// opens there. The Apple TV keeps its Settings row, which is read as
    /// it always was.
    var openingBitrate: Int? {
        #if os(tvOS)
        defaultBitrate
        #else
        adaptiveQuality ? nil : defaultBitrate
        #endif
    }

    /// Fold surround down to stereo. Unlike on Linux this is asked of the
    /// server (MaxAudioChannels in the device profile), because AVPlayer has no
    /// downmix of its own.
    var stereoDownmix: Bool {
        didSet { write(stereoDownmix, forKey: "stereo_downmix") }
    }

    /// Have this device decode the sound rather than pass a Dolby bitstream
    /// through to whatever is on the other end of the HDMI cable.
    ///
    /// Soundbar mode, in effect. An Apple TV left to itself hands AC-3 and
    /// E-AC-3 to the television or soundbar undecoded, and a soundbar takes
    /// its own time decoding them — a lag tvOS can only correct for if the
    /// set reports it honestly, which many don't. Asking the server for AAC
    /// instead means AVPlayer decodes here and sends PCM down the cable, which
    /// is what the apps that stay in sync on the same soundbar are doing.
    /// Surround is kept; only the bitstream is given up. Like `audioDelay`,
    /// this is a fact about the room, so it does not travel between devices.
    var decodeAudioLocally: Bool {
        didSet { defaults.set(decodeAudioLocally, forKey: "decode_audio_locally") }
    }

    /// Keep the whole library — its details, posters, logos and stills — on
    /// this device, and sync only what changed. A fact about this device's
    /// storage rather than about the account, so it does not travel. See
    /// `LibraryIndex`.
    var keepsLibraryCopy: Bool {
        didSet { defaults.set(keepsLibraryCopy, forKey: "library_copy") }
    }

    /// Resume where you left off instead of starting from the top.
    var resumePlayback: Bool {
        didSet { write(resumePlayback, forKey: "resume_playback") }
    }

    var volume: Double {
        didSet { defaults.set(volume, forKey: "volume") }
    }

    /// How far the sound is shifted against the picture, in seconds; positive
    /// means it plays later.
    ///
    /// Kept here rather than on the player because of what it usually is: the
    /// lag a soundbar or a receiver adds, which is a property of the room and
    /// the same for everything watched in it. A file that is simply muxed wrong
    /// wants the opposite — an offset that dies with the stream — but that is
    /// the rarer case, and the cost of getting it wrong is one menu entry
    /// rather than an offset silently reappearing next time. Only ever applied
    /// where it can be: see `PlayerModel.canDelayAudio`.
    ///
    /// On an Apple TV this is the 60 fps delay — shows, sport and Live TV —
    /// and the one for a video whose rate isn't known; every other rate has
    /// its own, in `audioDelaysByRate`.
    var audioDelay: Double {
        // Not shared between devices, for the reason above: it is the lag of
        // the room's own soundbar, and two Apple TVs are two rooms.
        didSet { defaults.set(audioDelay, forKey: "audio_delay") }
    }

    /// The Apple TV's offsets for every other frame rate, in seconds and
    /// positive for later, keyed by the rate rounded to a whole number:
    /// "24" for a 23.976 or 24 fps film, "30" for 29.97, "48", "120". Read
    /// and written through `audioDelay(forRate:)`, which folds the 60 fps
    /// one into `audioDelay`.
    ///
    /// A delay a rate because a television does different work on each:
    /// with Match Frame Rate on it switches modes for a film and runs a
    /// different motion mode there, and either way its frame-rate
    /// conversion is a different job at 24 than at 60. The picture comes
    /// out later by an amount that is nothing to do with the soundbar, so
    /// each is measured on its own — the preset rates over the sync clips
    /// in Settings → Audio, any other rate over a video at it, from the
    /// Sync tab — and kept. Not shared between devices: another room is
    /// another television.
    var audioDelaysByRate: [String: Double] {
        didSet { defaults.set(audioDelaysByRate, forKey: "audio_delays_by_rate") }
    }

    /// The offset for a video at `fps` frames a second, rounded. Nothing
    /// measured yet is in step.
    func audioDelay(forRate fps: Int) -> Double {
        fps == 60 ? audioDelay : audioDelaysByRate[String(fps)] ?? 0
    }

    /// Set the offset for a rate. In step is forgotten rather than kept as
    /// zero, so a rate only stays in the list while it has a delay.
    func setAudioDelay(_ seconds: Double, forRate fps: Int) {
        if fps == 60 {
            audioDelay = seconds
        } else if abs(seconds) < 0.0005 {
            audioDelaysByRate.removeValue(forKey: String(fps))
        } else {
            audioDelaysByRate[String(fps)] = seconds
        }
    }

    // ---- Languages ----

    var audioLanguage: String {
        didSet { write(audioLanguage, forKey: "audio_lang") }
    }
    /// "" = only when the file turns them on, "off" = never, else a language tag.
    var subtitleLanguage: String {
        didSet { write(subtitleLanguage, forKey: "sub_lang") }
    }
    var forcedSubtitlesOnly: Bool {
        didSet { write(forcedSubtitlesOnly, forKey: "subs_forced_only") }
    }

    // ---- Subtitle appearance ----

    /// Relative to the default size, as a percentage (100 = as delivered).
    var subtitleSize: Double {
        didSet { write(subtitleSize, forKey: "sub_font_size") }
    }
    var subtitleBackground: SubtitleBackground {
        didSet { write(subtitleBackground.rawValue, forKey: "sub_bg") }
    }

    // ---- Picture ----

    /// Crop the picture to fill the screen instead of letterboxing it — the
    /// answer to a 2.35:1 film in a 16:9 frame.
    ///
    /// The Linux build offered a zoom slider plus brightness, contrast,
    /// saturation and gamma, all of which it pushed straight into mpv.
    /// AVFoundation exposes none of that for a stream: `videoGravity` is the
    /// whole of the picture control it has. Rather than keep four sliders that
    /// would do nothing, this is what's left, and it genuinely works.
    var fillScreen: Bool {
        didSet { write(fillScreen, forKey: "fill_screen") }
    }

    /// Brightness, contrast, saturation and gamma, each -100…100 with 0 as
    /// the file's own. The mpv engine's; setting any of them on an iPhone,
    /// iPad or Mac is one of the things that switches the engine to it for
    /// the title (see `EnginePolicy`).
    var pictureBrightness: Double {
        didSet { write(pictureBrightness, forKey: "picture_brightness") }
    }
    var pictureContrast: Double {
        didSet { write(pictureContrast, forKey: "picture_contrast") }
    }
    var pictureSaturation: Double {
        didSet { write(pictureSaturation, forKey: "picture_saturation") }
    }
    var pictureGamma: Double {
        didSet { write(pictureGamma, forKey: "picture_gamma") }
    }
    /// Zoom into the picture by this factor; 1 is none. mpv's too.
    var pictureZoom: Double {
        didSet { write(pictureZoom, forKey: "picture_zoom") }
    }
    /// Stretch or crop the picture to this width:height; 0 is the file's own.
    var aspectOverride: Double {
        didSet { write(aspectOverride, forKey: "picture_aspect") }
    }

    var picture: PictureAdjustment {
        get {
            PictureAdjustment(brightness: pictureBrightness, contrast: pictureContrast,
                              saturation: pictureSaturation, gamma: pictureGamma)
        }
        set {
            if pictureBrightness != newValue.brightness { pictureBrightness = newValue.brightness }
            if pictureContrast != newValue.contrast { pictureContrast = newValue.contrast }
            if pictureSaturation != newValue.saturation { pictureSaturation = newValue.saturation }
            if pictureGamma != newValue.gamma { pictureGamma = newValue.gamma }
        }
    }

    /// Whether any picture adjustment, zoom or aspect override is in force.
    var pictureIsAdjusted: Bool {
        !picture.isNeutral || abs(pictureZoom - 1) > 0.001 || aspectOverride > 0
    }

    /// Everything back to the file's own picture.
    func resetPicture() {
        picture = .neutral
        pictureZoom = 1
        aspectOverride = 0
    }

    /// The aspect overrides on offer, as width:height with 0 for none.
    static let aspectChoices: [(label: String, ratio: Double)] = [
        ("File's own", 0), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1.85:1", 1.85), ("2.35:1", 2.35), ("2.39:1", 2.39),
    ]

    /// Night mode: dynamic range compression on the sound, so quiet dialogue
    /// comes up and loud passages come down for a room where the volume has
    /// to stay low. The mpv engine's (`dynaudnorm`); Apple's engine leaves
    /// the sound as it is. Not synced: like the volume, it describes the
    /// room rather than the account.
    var nightMode: Bool {
        didSet { write(nightMode, forKey: "player_night_mode") }
    }

    // ---- The engine ----

    /// Which engine plays video on an iPhone, iPad or Mac: Apple's, mpv, or
    /// whichever the file and the controls in use call for. The Apple TV
    /// always plays through mpv.
    var playbackEngine: EnginePolicy.Preference {
        didSet { write(playbackEngine.rawValue, forKey: "player_engine") }
    }

    /// Whether the mpv engine draws cheaply: always, never, or when the
    /// device is on a battery, in Low Power Mode or running hot.
    var batterySaver: EnginePolicy.BatterySaver {
        didSet { write(batterySaver.rawValue, forKey: "player_battery_saver") }
    }

    // ---- The player's controls ----

    /// How far the skip buttons and a double-tap on the picture jump, in
    /// seconds: 10, 15 or 30.
    var skipInterval: Int {
        didSet { write(skipInterval, forKey: "player_skip_interval") }
    }

    /// A vertical drag on the left edge of the picture for brightness and on
    /// the right for volume. Off unless asked for: on some devices the drags
    /// fight the system's own edge gestures.
    var edgeGestures: Bool {
        didSet { write(edgeGestures, forKey: "player_edge_gestures") }
    }

    /// Holding a finger on the picture plays at 2× until it lifts.
    var holdForDoubleSpeed: Bool {
        didSet { write(holdForDoubleSpeed, forKey: "player_hold_2x") }
    }

    /// Seconds the controls stay up after the last touch while playing. They
    /// never hide while paused or with a panel open.
    var hideControlsAfter: Double {
        didSet { write(hideControlsAfter, forKey: "player_hide_after") }
    }

    /// What the right-hand time under the timeline shows: the time left, or
    /// the whole length. Tapping it in the player flips this.
    var showsRemainingTime: Bool {
        didSet { write(showsRemainingTime, forKey: "player_show_remaining") }
    }

    static let skipIntervals = [10, 15, 30]
    static let hideControlsChoices: [Double] = [2, 4, 6, 10]

    /// Until it is set: 2 s on a Mac, where a pointer brings the controls
    /// back with a nudge and QuickTime and the TV app hide theirs about as
    /// fast; 4 s where a finger or a remote has to find them again.
    static let defaultHideControlsAfter: Double = {
        #if os(macOS)
        2
        #else
        4
        #endif
    }()

    /// The ranges the picture values are kept to, whatever a defaults file
    /// or another device sends.
    static func pictureValue(_ v: Double) -> Double { v.isFinite ? min(max(v.rounded(), -100), 100) : 0 }
    static func zoomValue(_ v: Double) -> Double { v.isFinite && v > 0 ? min(max(v, 1), 2) : 1 }
    static func aspectValue(_ v: Double) -> Double { v.isFinite && v > 0 ? min(max(v, 0.5), 4) : 0 }

    // ---- Live TV source ----

    var liveTVSource: LiveTVSource {
        didSet { write(liveTVSource.rawValue, forKey: "livetv_source") }
    }
    var iptvPlaylistURL: String {
        didSet { write(iptvPlaylistURL, forKey: "iptv_playlist_url") }
    }
    var iptvGuideURL: String {
        didSet { write(iptvGuideURL, forKey: "iptv_guide_url") }
    }
    /// The User-Agent sent when fetching a channel from a custom playlist.
    ///
    /// Some stream servers vary what they serve — bitrate, container, or a
    /// redirect target — by the client string they see, and AVFoundation's own
    /// `AppleCoreMedia/1.0.0…` is not always one they have a rule for. A
    /// stream that plays in one player and stalls in another, byte-identical
    /// either way, is usually this.
    ///
    /// Empty means the default below rather than no header at all: sending
    /// nothing is what leaves AVFoundation to send its own.
    var iptvUserAgent: String {
        didSet { write(iptvUserAgent, forKey: "iptv_user_agent") }
    }

    /// What an empty setting sends: the client string of a widely deployed
    /// open-source player, which most stream servers have a working rule for.
    static let defaultIPTVUserAgent = "VLC/3.0.20 LibVLC/3.0.20"

    /// The header that is actually sent — whatever is set, or the default.
    var iptvUserAgentHeader: String {
        let trimmed = iptvUserAgent.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultIPTVUserAgent : trimmed
    }
    /// How often the custom playlist and guide are re-downloaded while Live TV
    /// is open. 0 means never — only a manual refresh or a changed URL loads
    /// them again. Meaningless for the Jellyfin source, which always asks the
    /// server fresh.
    var iptvRefreshMinutes: Int {
        didSet { write(iptvRefreshMinutes, forKey: "iptv_refresh_minutes") }
    }
    /// Bumped by Settings' "Refresh now" to force the guide to reload without
    /// waiting on `iptvRefreshMinutes` — a signal for `LiveTVView` to catch,
    /// not a setting, so it isn't persisted to `UserDefaults` like the rest of
    /// this file.
    var liveTVRefreshToken = 0

    // ---- Downloads ----

    var downloadQuality: String {
        didSet { write(downloadQuality, forKey: "download_quality") }
    }
    var downloadConcurrency: Int {
        didSet { write(downloadConcurrency, forKey: "download_concurrency") }
    }
    /// Never more than one transcoded download running, whatever Parallel
    /// downloads is set to. A server encoding several at once shares its
    /// encoder between them, and each finishes later than it would have in
    /// turn. This device's, like the parallel count: not in `CloudSync`.
    var transcodesOneAtATime: Bool {
        didSet { write(transcodesOneAtATime, forKey: "downloads_one_transcode") }
    }
    /// Only queue transfers while on Wi-Fi.
    var downloadsWiFiOnly: Bool {
        didSet { write(downloadsWiFiOnly, forKey: "downloads_wifi_only") }
    }

    static let maxDownloadConcurrency = 6

    // ---- Music ----

    /// Send lossless files as they are over cellular. Off, a FLAC over a
    /// phone plan is asked for as 256 kbps AAC instead.
    var losslessOnCellular: Bool {
        didSet { write(losslessOnCellular, forKey: "music_lossless_cellular") }
    }
    /// When the queue runs out, keep going with songs like the last one.
    var musicAutoplay: Bool {
        didSet { write(musicAutoplay, forKey: "music_autoplay") }
    }
    /// Show artist names in Latin letters where a fair transliteration exists.
    var musicRomanizeNames: Bool {
        didSet { write(musicRomanizeNames, forKey: "music_romanize") }
    }
    /// What stations favour, as points spent across the dials of `MixPoints`.
    var mixPoints: MixPoints {
        didSet { write(mixPoints.stored, forKey: "music_mix_points") }
    }
    /// Level tracks against each other using the gain the server measured.
    var normalizeVolume: Bool {
        didSet { write(normalizeVolume, forKey: "music_normalize") }
    }
    /// The repeat mode the music player was last left in.
    var musicRepeat: String {
        didSet { defaults.set(musicRepeat, forKey: "music_repeat") }
    }
    /// The speed audiobooks open at.
    var audiobookSpeed: Double {
        // Unchanged is not written: this one travels, so each write is an
        // iCloud one too.
        didSet { if audiobookSpeed != oldValue { write(audiobookSpeed, forKey: "audiobook_speed") } }
    }
    /// The rule-based playlists, as one JSON document — see `SmartPlaylist`.
    /// Stored as data because the key-value store takes data and the rules
    /// are a nested structure.
    var smartPlaylists: [SmartPlaylist] {
        get { Self.decodeSmartPlaylists(defaults.data(forKey: "smart_playlists")) }
        set {
            let data = try? JSONEncoder().encode(newValue)
            write(data, forKey: "smart_playlists")
        }
    }

    private static func decodeSmartPlaylists(_ data: Data?) -> [SmartPlaylist] {
        guard let data else { return [] }
        if let all = try? JSONDecoder().decode([SmartPlaylist].self, from: data) { return all }
        // Rule by rule, so one a newer build wrote can't take the rest with it.
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return array.compactMap { rule in
            guard let one = try? JSONSerialization.data(withJSONObject: rule) else { return nil }
            return try? JSONDecoder().decode(SmartPlaylist.self, from: one)
        }
    }

    // ---- Misc ----

    /// Route the app reopens into, so a cold start lands where you left off.
    var lastRoute: String {
        didSet { defaults.set(lastRoute, forKey: "last_route") }
    }

    var recentSearches: [String] {
        didSet { defaults.set(recentSearches, forKey: "recent_searches") }
    }

    /// The order the user chose for the phone's tab bar (and the iPad's
    /// sidebar) — `AppSection.id` strings, `.home` omitted since it is always
    /// pinned first. Empty means nobody has customized it yet, and the shell
    /// keeps computing the order itself — see `AppModel.primaryTabs`.
    var tabBarOrder: [String] {
        didSet { write(tabBarOrder, forKey: "tab_bar_order") }
    }

    /// The playlists the Apple Watch keeps a copy of — see `WatchLink`. This
    /// phone's, not the account's: the watch is paired with one phone.
    var watchPlaylistIds: [String] {
        didSet { defaults.set(watchPlaylistIds, forKey: "watch_playlists") }
    }

    /// Send the audiobooks this account is part-way through to the watch
    /// without being asked. Off unless chosen: a download the wearer did not
    /// ask for is a mystery on a small screen.
    var watchKeepsBooks: Bool {
        didSet { defaults.set(watchKeepsBooks, forKey: "watch_keeps_books") }
    }

    /// Settings › Appearance › Layout on a foldable: hold the app in one of
    /// its poses rather than following the hinge. A fact about this device —
    /// no other has the hinge — so it does not travel. See `DevicePose`.
    var layoutOverride: LayoutOverride {
        didSet { defaults.set(layoutOverride.rawValue, forKey: "layout_override") }
    }

    // ---- iCloud ----

    /// Whether this device joins the shared settings.
    ///
    /// Deliberately *not* one of the shared settings itself: a switch that
    /// synced would be a switch one room could use to turn the feature off in
    /// every other room.
    var syncsAcrossDevices: Bool {
        didSet {
            defaults.set(syncsAcrossDevices, forKey: "cloud_sync")
            guard syncsAcrossDevices != oldValue else { return }
            // The token follows the switch — into iCloud Keychain, or into a
            // copy of this device's own — and is never dropped on the way.
            if let session { Keychain.relocate(server: session.server, userId: session.userId) }
            if syncsAcrossDevices {
                publishEverythingToCloud()
            }
        }
    }

    /// Whether iCloud is there to sync with at all — what Settings says when
    /// the switch would do nothing.
    var cloudIsAvailable: Bool { CloudSync.isAvailable }

    /// Set while a value that arrived from another device is being applied, so
    /// the `didSet` it triggers writes it to this device's defaults without
    /// sending it straight back where it came from.
    @ObservationIgnored
    private var isAdoptingRemote = false

    private init() {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: "device_id"), !existing.isEmpty {
            deviceId = existing
        } else {
            let fresh = UUID().uuidString
            d.set(fresh, forKey: "device_id")
            deviceId = fresh
        }
        let savedSession = d.data(forKey: "session").flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }
        session = savedSession
        var savedAccounts = d.data(forKey: "accounts").flatMap { try? JSONDecoder().decode([SavedSession].self, from: $0) } ?? []
        // A build from before there was a list: the one account is the list.
        if let savedSession, !savedAccounts.contains(where: { $0.accountKey == savedSession.accountKey }) {
            savedAccounts.append(savedSession)
            if let data = try? JSONEncoder().encode(savedAccounts) { d.set(data, forKey: "accounts") }
        }
        accounts = savedAccounts
        theme = ThemePref(rawValue: d.string(forKey: "theme") ?? "") ?? .auto
        adaptiveQuality = d.object(forKey: "adaptive") == nil ? true : d.bool(forKey: "adaptive")
        powerAwareQuality = d.object(forKey: "power_aware_quality") == nil ? true : d.bool(forKey: "power_aware_quality")
        autoplayNext = d.object(forKey: "autoplay_next") == nil ? true : d.bool(forKey: "autoplay_next")
        hidesContinueWatching = d.bool(forKey: "home_hide_continue_watching")
        clearsAbandonedEpisodes = d.bool(forKey: "home_clear_abandoned")
        nextUpHidden = (d.dictionary(forKey: "next_up_hidden") as? [String: String]) ?? [:]
        defaultBitrate = Quality.snapped(d.object(forKey: "default_bitrate") as? Int)
        stereoDownmix = d.bool(forKey: "stereo_downmix")
        decodeAudioLocally = d.bool(forKey: "decode_audio_locally")
        keepsLibraryCopy = d.bool(forKey: "library_copy")
        resumePlayback = d.object(forKey: "resume_playback") == nil ? true : d.bool(forKey: "resume_playback")
        volume = d.object(forKey: "volume") == nil ? 1.0 : d.double(forKey: "volume")
        audioDelay = d.double(forKey: "audio_delay")
        var byRate = (d.dictionary(forKey: "audio_delays_by_rate") as? [String: Double]) ?? [:]
        // The 24 fps delay was the "matched" delay before the player chose
        // by frame rate rather than by display mode: the same measurement,
        // so it carries over.
        if byRate["24"] == nil,
           let old = d.object(forKey: "audio_delay_24") as? Double ?? d.object(forKey: "matched_audio_delay") as? Double,
           old != 0 {
            byRate["24"] = old
        }
        audioDelaysByRate = byRate
        d.removeObject(forKey: "audio_delay_24")
        d.removeObject(forKey: "matched_audio_delay")
        // The offset this replaced was added to the other rather than used
        // instead of it, so it doesn't carry over.
        d.removeObject(forKey: "frame_rate_match_delay")
        audioLanguage = d.string(forKey: "audio_lang") ?? ""
        subtitleLanguage = d.string(forKey: "sub_lang") ?? ""
        forcedSubtitlesOnly = d.bool(forKey: "subs_forced_only")
        subtitleSize = d.object(forKey: "sub_font_size") == nil ? 100 : d.double(forKey: "sub_font_size")
        subtitleBackground = SubtitleBackground(rawValue: d.string(forKey: "sub_bg") ?? "") ?? .outline
        fillScreen = d.bool(forKey: "fill_screen")
        pictureBrightness = Self.pictureValue(d.double(forKey: "picture_brightness"))
        pictureContrast = Self.pictureValue(d.double(forKey: "picture_contrast"))
        pictureSaturation = Self.pictureValue(d.double(forKey: "picture_saturation"))
        pictureGamma = Self.pictureValue(d.double(forKey: "picture_gamma"))
        pictureZoom = Self.zoomValue(d.object(forKey: "picture_zoom") == nil ? 1 : d.double(forKey: "picture_zoom"))
        aspectOverride = Self.aspectValue(d.double(forKey: "picture_aspect"))
        nightMode = d.bool(forKey: "player_night_mode")
        playbackEngine = EnginePolicy.Preference(rawValue: d.string(forKey: "player_engine") ?? "") ?? .automatic
        batterySaver = EnginePolicy.BatterySaver(rawValue: d.string(forKey: "player_battery_saver") ?? "") ?? .automatic
        skipInterval = Self.skipIntervals.contains(d.integer(forKey: "player_skip_interval")) ? d.integer(forKey: "player_skip_interval") : 10
        edgeGestures = d.bool(forKey: "player_edge_gestures")
        holdForDoubleSpeed = d.object(forKey: "player_hold_2x") == nil ? true : d.bool(forKey: "player_hold_2x")
        hideControlsAfter = Self.hideControlsChoices.contains(d.double(forKey: "player_hide_after")) ? d.double(forKey: "player_hide_after") : Self.defaultHideControlsAfter
        showsRemainingTime = d.object(forKey: "player_show_remaining") == nil ? true : d.bool(forKey: "player_show_remaining")
        liveTVSource = LiveTVSource(rawValue: d.string(forKey: "livetv_source") ?? "") ?? .jellyfin
        iptvPlaylistURL = d.string(forKey: "iptv_playlist_url") ?? ""
        iptvGuideURL = d.string(forKey: "iptv_guide_url") ?? ""
        iptvUserAgent = d.string(forKey: "iptv_user_agent") ?? ""
        iptvRefreshMinutes = d.object(forKey: "iptv_refresh_minutes") == nil ? 180 : d.integer(forKey: "iptv_refresh_minutes")
        downloadQuality = d.string(forKey: "download_quality") ?? DownloadQualities.all[0].label
        let c = d.integer(forKey: "download_concurrency")
        downloadConcurrency = (1...Preferences.maxDownloadConcurrency).contains(c) ? c : 1
        downloadsWiFiOnly = d.bool(forKey: "downloads_wifi_only")
        transcodesOneAtATime = d.bool(forKey: "downloads_one_transcode")
        lastRoute = d.string(forKey: "last_route") ?? ""
        recentSearches = d.stringArray(forKey: "recent_searches") ?? []
        tabBarOrder = d.stringArray(forKey: "tab_bar_order") ?? []
        layoutOverride = d.string(forKey: "layout_override").flatMap(LayoutOverride.init(rawValue:)) ?? .automatic
        watchPlaylistIds = d.stringArray(forKey: "watch_playlists") ?? []
        watchKeepsBooks = d.bool(forKey: "watch_keeps_books")
        syncsAcrossDevices = d.object(forKey: "cloud_sync") == nil ? true : d.bool(forKey: "cloud_sync")
        losslessOnCellular = d.bool(forKey: "music_lossless_cellular")
        musicAutoplay = d.object(forKey: "music_autoplay") == nil ? true : d.bool(forKey: "music_autoplay")
        normalizeVolume = d.bool(forKey: "music_normalize")
        // Stations once had a switch for learning across weeks. They learn
        // only while they play now, and the switch went with that.
        d.removeObject(forKey: "music_learns")
        musicRomanizeNames = d.object(forKey: "music_romanize") == nil ? true : d.bool(forKey: "music_romanize")
        mixPoints = MixPoints(stored: d.dictionary(forKey: "music_mix_points")) ?? .balanced
        musicRepeat = d.string(forKey: "music_repeat") ?? "off"
        let bookSpeed = d.double(forKey: "audiobook_speed")
        audiobookSpeed = bookSpeed > 0 ? bookSpeed : 1

        observeCloud()
        adoptCloudChanges()
        #if os(iOS)
        pinSettingsNotOfferedHere()
        #endif
        #if os(tvOS)
        shareWithHousehold()
        #endif
    }

    #if os(iOS)
    /// The settings an iPhone or an iPad has no row for, in the app's
    /// Settings or in the player, and so keeps at their defaults: the layout
    /// follows the hinge, the player's own behaviour is the default one, and
    /// subtitles are drawn the one way. Another device's choices for them
    /// arrive through iCloud and are set back here, locally only, so a Mac
    /// or an Apple TV keeps what it was set to — see `publishEverythingToCloud`.
    static let keysNotOfferedHere: Set<String> = [
        "home_clear_abandoned", "power_aware_quality", "stereo_downmix",
        "subs_forced_only", "sub_font_size", "sub_bg",
        "picture_brightness", "picture_contrast", "picture_saturation", "picture_gamma",
        "picture_zoom", "picture_aspect", "player_night_mode",
        "player_engine", "player_battery_saver", "player_skip_interval",
        "player_hide_after", "player_hold_2x", "player_edge_gestures",
    ]

    private func pinSettingsNotOfferedHere() {
        let wasAdopting = isAdoptingRemote
        isAdoptingRemote = true
        defer { isAdoptingRemote = wasAdopting }
        if layoutOverride != .automatic { layoutOverride = .automatic }
        if clearsAbandonedEpisodes { clearsAbandonedEpisodes = false }
        if !powerAwareQuality { powerAwareQuality = true }
        if stereoDownmix { stereoDownmix = false }
        if forcedSubtitlesOnly { forcedSubtitlesOnly = false }
        if subtitleSize != 100 { subtitleSize = 100 }
        if subtitleBackground != .outline { subtitleBackground = .outline }
        if pictureIsAdjusted { resetPicture() }
        if nightMode { nightMode = false }
        if playbackEngine != .automatic { playbackEngine = .automatic }
        if batterySaver != .automatic { batterySaver = .automatic }
        if skipInterval != 10 { skipInterval = 10 }
        if hideControlsAfter != Self.defaultHideControlsAfter { hideControlsAfter = Self.defaultHideControlsAfter }
        if !holdForDoubleSpeed { holdForDoubleSpeed = true }
        if edgeGestures { edgeGestures = false }
    }
    #endif

    // MARK: - iCloud

    /// Write a setting to this device, and to the shared dictionary when it is
    /// one of the settings that travels. See `CloudSync.syncedKeys`.
    private func write(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        guard syncsAcrossDevices, !isAdoptingRemote else { return }
        CloudSync.set(value, forKey: key)
    }

    private func observeCloud() {
        NotificationCenter.default.addObserver(
            forName: CloudSync.changed, object: nil, queue: .main
        ) { _ in
            // No capture: the singleton is reached by name, so this closure is
            // sendable and there is nothing here for a retain cycle to hold.
            Preferences.shared.adoptCloudChanges()
        }
    }

    /// What this device sends when it joins, or when the switch is turned back
    /// on: everything it currently has, so an Apple TV set up first is the one
    /// the second one copies rather than the other way round.
    private func publishEverythingToCloud() {
        guard CloudSync.isAvailable else { return }
        // What this device has no row for is only its default, not a choice
        // to hand to the others.
        func publish(_ value: Any?, forKey key: String) {
            #if os(iOS)
            guard !Self.keysNotOfferedHere.contains(key) else { return }
            #endif
            CloudSync.set(value, forKey: key)
        }
        publish(theme.rawValue, forKey: "theme")
        publish(adaptiveQuality, forKey: "adaptive")
        publish(powerAwareQuality, forKey: "power_aware_quality")
        publish(autoplayNext, forKey: "autoplay_next")
        publish(hidesContinueWatching, forKey: "home_hide_continue_watching")
        publish(clearsAbandonedEpisodes, forKey: "home_clear_abandoned")
        publish(nextUpHidden, forKey: "next_up_hidden")
        publish(stereoDownmix, forKey: "stereo_downmix")
        publish(resumePlayback, forKey: "resume_playback")
        publish(audioLanguage, forKey: "audio_lang")
        publish(subtitleLanguage, forKey: "sub_lang")
        publish(forcedSubtitlesOnly, forKey: "subs_forced_only")
        publish(subtitleSize, forKey: "sub_font_size")
        publish(subtitleBackground.rawValue, forKey: "sub_bg")
        publish(losslessOnCellular, forKey: "music_lossless_cellular")
        publish(musicAutoplay, forKey: "music_autoplay")
        publish(normalizeVolume, forKey: "music_normalize")
        publish(musicRomanizeNames, forKey: "music_romanize")
        publish(mixPoints.stored, forKey: "music_mix_points")
        publish(audiobookSpeed, forKey: "audiobook_speed")
        publish(defaults.data(forKey: "smart_playlists"), forKey: "smart_playlists")
        publish(fillScreen, forKey: "fill_screen")
        publish(pictureBrightness, forKey: "picture_brightness")
        publish(pictureContrast, forKey: "picture_contrast")
        publish(pictureSaturation, forKey: "picture_saturation")
        publish(pictureGamma, forKey: "picture_gamma")
        publish(pictureZoom, forKey: "picture_zoom")
        publish(aspectOverride, forKey: "picture_aspect")
        publish(playbackEngine.rawValue, forKey: "player_engine")
        publish(batterySaver.rawValue, forKey: "player_battery_saver")
        publish(skipInterval, forKey: "player_skip_interval")
        publish(edgeGestures, forKey: "player_edge_gestures")
        publish(holdForDoubleSpeed, forKey: "player_hold_2x")
        publish(hideControlsAfter, forKey: "player_hide_after")
        publish(showsRemainingTime, forKey: "player_show_remaining")
        publish(liveTVSource.rawValue, forKey: "livetv_source")
        publish(iptvPlaylistURL, forKey: "iptv_playlist_url")
        publish(iptvGuideURL, forKey: "iptv_guide_url")
        publish(iptvUserAgent, forKey: "iptv_user_agent")
        publish(iptvRefreshMinutes, forKey: "iptv_refresh_minutes")
        publish(downloadQuality, forKey: "download_quality")
        publish(downloadsWiFiOnly, forKey: "downloads_wifi_only")
        publish(tabBarOrder, forKey: "tab_bar_order")
        publishSessionToCloud()
        CloudSync.flush()
    }

    /// The signed-in server and user, minus this device's own id.
    ///
    /// The device id is what Jellyfin recognises a client by: shared between
    /// two Apple TVs they would be one session on the server's dashboard, and
    /// stopping playback on one would stop it on the other. Each box keeps its
    /// own and takes only the account.
    private func publishSessionToCloud() {
        guard syncsAcrossDevices, !isAdoptingRemote, CloudSync.isAvailable else { return }
        guard let session, let data = try? JSONEncoder().encode(SharedSession(session)) else {
            CloudSync.set(nil, forKey: CloudSync.sessionKey)
            return
        }
        CloudSync.set(data, forKey: CloudSync.sessionKey)
    }

    /// The account as it travels: no device id, and no token — the token goes
    /// through iCloud Keychain, which is built for it. See `Keychain`.
    private struct SharedSession: Codable {
        var server: String
        var userId: String
        var userName: String
        var serverId: String?

        init(_ s: SavedSession) {
            server = s.server
            userId = s.userId
            userName = s.userName
            serverId = s.serverId
        }
    }

    /// Take whatever the shared dictionary currently holds.
    ///
    /// Runs at launch and whenever another device writes. Every assignment goes
    /// through the ordinary property, so the value lands in this device's
    /// defaults too — `isAdoptingRemote` is only there to stop it bouncing
    /// straight back out.
    func adoptCloudChanges() {
        guard syncsAcrossDevices, CloudSync.isAvailable else { return }
        isAdoptingRemote = true
        defer { isAdoptingRemote = false }

        if let v = CloudSync.object(forKey: "theme") as? String,
           let t = ThemePref(rawValue: v), t != theme { theme = t }
        if let v = CloudSync.object(forKey: "adaptive") as? Bool, v != adaptiveQuality { adaptiveQuality = v }
        if let v = CloudSync.object(forKey: "power_aware_quality") as? Bool, v != powerAwareQuality { powerAwareQuality = v }
        if let v = CloudSync.object(forKey: "autoplay_next") as? Bool, v != autoplayNext { autoplayNext = v }
        if let v = CloudSync.object(forKey: "home_hide_continue_watching") as? Bool, v != hidesContinueWatching { hidesContinueWatching = v }
        if let v = CloudSync.object(forKey: "home_clear_abandoned") as? Bool, v != clearsAbandonedEpisodes { clearsAbandonedEpisodes = v }
        if let v = CloudSync.object(forKey: "next_up_hidden") as? [String: String], v != nextUpHidden { nextUpHidden = v }
        if let v = CloudSync.object(forKey: "stereo_downmix") as? Bool, v != stereoDownmix { stereoDownmix = v }
        if let v = CloudSync.object(forKey: "resume_playback") as? Bool, v != resumePlayback { resumePlayback = v }
        if let v = CloudSync.object(forKey: "audio_lang") as? String, v != audioLanguage { audioLanguage = v }
        if let v = CloudSync.object(forKey: "sub_lang") as? String, v != subtitleLanguage { subtitleLanguage = v }
        if let v = CloudSync.object(forKey: "subs_forced_only") as? Bool, v != forcedSubtitlesOnly {
            forcedSubtitlesOnly = v
        }
        if let v = (CloudSync.object(forKey: "sub_font_size") as? NSNumber)?.doubleValue,
           abs(v - subtitleSize) > 0.5 { subtitleSize = v }
        if let v = CloudSync.object(forKey: "sub_bg") as? String,
           let b = SubtitleBackground(rawValue: v), b != subtitleBackground { subtitleBackground = b }
        if let v = CloudSync.object(forKey: "fill_screen") as? Bool, v != fillScreen { fillScreen = v }
        if let v = (CloudSync.object(forKey: "picture_brightness") as? NSNumber)?.doubleValue,
           Self.pictureValue(v) != pictureBrightness { pictureBrightness = Self.pictureValue(v) }
        if let v = (CloudSync.object(forKey: "picture_contrast") as? NSNumber)?.doubleValue,
           Self.pictureValue(v) != pictureContrast { pictureContrast = Self.pictureValue(v) }
        if let v = (CloudSync.object(forKey: "picture_saturation") as? NSNumber)?.doubleValue,
           Self.pictureValue(v) != pictureSaturation { pictureSaturation = Self.pictureValue(v) }
        if let v = (CloudSync.object(forKey: "picture_gamma") as? NSNumber)?.doubleValue,
           Self.pictureValue(v) != pictureGamma { pictureGamma = Self.pictureValue(v) }
        if let v = (CloudSync.object(forKey: "picture_zoom") as? NSNumber)?.doubleValue,
           abs(Self.zoomValue(v) - pictureZoom) > 0.001 { pictureZoom = Self.zoomValue(v) }
        if let v = (CloudSync.object(forKey: "picture_aspect") as? NSNumber)?.doubleValue,
           abs(Self.aspectValue(v) - aspectOverride) > 0.001 { aspectOverride = Self.aspectValue(v) }
        if let v = CloudSync.object(forKey: "player_engine") as? String,
           let e = EnginePolicy.Preference(rawValue: v), e != playbackEngine { playbackEngine = e }
        if let v = CloudSync.object(forKey: "player_battery_saver") as? String,
           let b = EnginePolicy.BatterySaver(rawValue: v), b != batterySaver { batterySaver = b }
        if let v = (CloudSync.object(forKey: "player_skip_interval") as? NSNumber)?.intValue,
           Self.skipIntervals.contains(v), v != skipInterval { skipInterval = v }
        if let v = CloudSync.object(forKey: "player_edge_gestures") as? Bool, v != edgeGestures { edgeGestures = v }
        if let v = CloudSync.object(forKey: "player_hold_2x") as? Bool, v != holdForDoubleSpeed { holdForDoubleSpeed = v }
        if let v = (CloudSync.object(forKey: "player_hide_after") as? NSNumber)?.doubleValue,
           Self.hideControlsChoices.contains(v), v != hideControlsAfter { hideControlsAfter = v }
        if let v = CloudSync.object(forKey: "player_show_remaining") as? Bool, v != showsRemainingTime { showsRemainingTime = v }
        if let v = CloudSync.object(forKey: "livetv_source") as? String,
           let s = LiveTVSource(rawValue: v), s != liveTVSource { liveTVSource = s }
        if let v = CloudSync.object(forKey: "iptv_playlist_url") as? String, v != iptvPlaylistURL {
            iptvPlaylistURL = v
        }
        if let v = CloudSync.object(forKey: "iptv_guide_url") as? String, v != iptvGuideURL { iptvGuideURL = v }
        if let v = CloudSync.object(forKey: "iptv_user_agent") as? String, v != iptvUserAgent {
            iptvUserAgent = v
        }
        if let v = (CloudSync.object(forKey: "iptv_refresh_minutes") as? NSNumber)?.intValue,
           v != iptvRefreshMinutes { iptvRefreshMinutes = v }
        if let v = CloudSync.object(forKey: "download_quality") as? String, v != downloadQuality {
            downloadQuality = v
        }
        if let v = CloudSync.object(forKey: "downloads_wifi_only") as? Bool, v != downloadsWiFiOnly {
            downloadsWiFiOnly = v
        }
        if let v = CloudSync.object(forKey: "music_lossless_cellular") as? Bool, v != losslessOnCellular {
            losslessOnCellular = v
        }
        if let v = CloudSync.object(forKey: "music_autoplay") as? Bool, v != musicAutoplay { musicAutoplay = v }
        if let v = CloudSync.object(forKey: "music_normalize") as? Bool, v != normalizeVolume { normalizeVolume = v }
        if let v = CloudSync.object(forKey: "music_romanize") as? Bool, v != musicRomanizeNames { musicRomanizeNames = v }
        if let v = MixPoints(stored: CloudSync.object(forKey: "music_mix_points")), v != mixPoints { mixPoints = v }
        if let v = (CloudSync.object(forKey: "audiobook_speed") as? NSNumber)?.doubleValue, v > 0,
           abs(v - audiobookSpeed) > 0.01 { audiobookSpeed = v }
        if let data = CloudSync.data(forKey: "smart_playlists"), data != defaults.data(forKey: "smart_playlists") {
            defaults.set(data, forKey: "smart_playlists")
            Task { @MainActor in SmartPlaylistStore.shared.reload() }
        }
        if let v = CloudSync.object(forKey: "tab_bar_order") as? [String], v != tabBarOrder {
            tabBarOrder = v
        }
        #if os(iOS)
        pinSettingsNotOfferedHere()
        #endif
        adoptCloudSession()
    }

    /// Adopt an account signed in on another device — but only where there is
    /// nothing signed in here.
    ///
    /// A second Apple TV set up from scratch picks the server, the user and
    /// (through iCloud Keychain) the token, and never sees the sign-in screen.
    /// One already signed in is left exactly as it is: replacing a session
    /// somebody deliberately chose, because another box in the house was
    /// pointed somewhere else, is not synchronising, it is overruling.
    private func adoptCloudSession() {
        guard session == nil,
              let data = CloudSync.data(forKey: CloudSync.sessionKey),
              let shared = try? JSONDecoder().decode(SharedSession.self, from: data),
              !shared.server.isEmpty, !shared.userId.isEmpty
        else { return }
        // Without the token there is nothing to sign in *with*, and a session
        // with no credential behind it is a shell that fails its first request
        // and drops you at the sign-in screen anyway. iCloud Keychain is
        // usually a little behind the key-value store, so this simply waits and
        // is asked again on the next change.
        guard Keychain.token(server: shared.server, userId: shared.userId) != nil else { return }
        session = SavedSession(
            server: shared.server,
            userId: shared.userId,
            userName: shared.userName,
            deviceId: deviceId,
            serverId: shared.serverId
        )
    }

    // ---- Per-series track memory ----
    //
    // The language settings above decide what a *new* show opens with. This is
    // the other half: when you override them for one series — the dub is bad,
    // this one needs subtitles — the next episode opens the same way.

    struct TrackChoice: Codable, Sendable {
        var audio: String?
        /// A language tag, or "off" for none.
        var sub: String?
    }

    func trackChoice(seriesId: String) -> TrackChoice? {
        guard let data = defaults.data(forKey: "tracks.\(seriesId)") else { return nil }
        return try? JSONDecoder().decode(TrackChoice.self, from: data)
    }

    func setTrackChoice(_ choice: TrackChoice, seriesId: String) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: "tracks.\(seriesId)")
    }

    // ---- Recent searches ----

    func rememberSearch(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        recentSearches = Array(list.prefix(8))
    }

    func clearRecentSearches() { recentSearches = [] }
}
