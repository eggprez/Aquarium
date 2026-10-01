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

    /// May the player drop to a smaller stream by itself when one keeps
    /// stalling? On unless turned off, as on Linux.
    var adaptiveQuality: Bool {
        didSet { write(adaptiveQuality, forKey: "adaptive") }
    }

    /// Start the next episode when one finishes.
    var autoplayNext: Bool {
        didSet { write(autoplayNext, forKey: "autoplay_next") }
    }

    /// Default quality for a new stream. `nil` is direct play. This device's
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
    var audioDelay: Double {
        // Not shared between devices, for the reason above: it is the lag of
        // the room's own soundbar, and two Apple TVs are two rooms.
        didSet { defaults.set(audioDelay, forKey: "audio_delay") }
    }

    /// A second offset, in seconds, added to `audioDelay` when the Apple TV
    /// switches the television out of its usual 60 Hz for a video — Match
    /// Content → Match Frame Rate.
    ///
    /// Separate because a television does different work at 24 Hz than at
    /// 60: frame-rate conversion, a different motion mode, a different game
    /// or low-latency setting. The picture comes out later by an amount that
    /// is nothing to do with the soundbar, and tvOS reports only that
    /// matching is switched on, never what it costs. Set by hand in Settings.
    /// Not shared between devices: another room is another television.
    var frameRateMatchDelay: Double {
        didSet { defaults.set(frameRateMatchDelay, forKey: "frame_rate_match_delay") }
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
        autoplayNext = d.object(forKey: "autoplay_next") == nil ? true : d.bool(forKey: "autoplay_next")
        defaultBitrate = Quality.snapped(d.object(forKey: "default_bitrate") as? Int)
        stereoDownmix = d.bool(forKey: "stereo_downmix")
        decodeAudioLocally = d.bool(forKey: "decode_audio_locally")
        keepsLibraryCopy = d.bool(forKey: "library_copy")
        resumePlayback = d.object(forKey: "resume_playback") == nil ? true : d.bool(forKey: "resume_playback")
        volume = d.object(forKey: "volume") == nil ? 1.0 : d.double(forKey: "volume")
        audioDelay = d.double(forKey: "audio_delay")
        frameRateMatchDelay = d.double(forKey: "frame_rate_match_delay")
        audioLanguage = d.string(forKey: "audio_lang") ?? ""
        subtitleLanguage = d.string(forKey: "sub_lang") ?? ""
        forcedSubtitlesOnly = d.bool(forKey: "subs_forced_only")
        subtitleSize = d.object(forKey: "sub_font_size") == nil ? 100 : d.double(forKey: "sub_font_size")
        subtitleBackground = SubtitleBackground(rawValue: d.string(forKey: "sub_bg") ?? "") ?? .outline
        fillScreen = d.bool(forKey: "fill_screen")
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
        musicRepeat = d.string(forKey: "music_repeat") ?? "off"
        let bookSpeed = d.double(forKey: "audiobook_speed")
        audiobookSpeed = bookSpeed > 0 ? bookSpeed : 1

        observeCloud()
        adoptCloudChanges()
        #if os(tvOS)
        shareWithHousehold()
        #endif
    }

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
        CloudSync.set(theme.rawValue, forKey: "theme")
        CloudSync.set(adaptiveQuality, forKey: "adaptive")
        CloudSync.set(autoplayNext, forKey: "autoplay_next")
        CloudSync.set(stereoDownmix, forKey: "stereo_downmix")
        CloudSync.set(resumePlayback, forKey: "resume_playback")
        CloudSync.set(audioLanguage, forKey: "audio_lang")
        CloudSync.set(subtitleLanguage, forKey: "sub_lang")
        CloudSync.set(forcedSubtitlesOnly, forKey: "subs_forced_only")
        CloudSync.set(subtitleSize, forKey: "sub_font_size")
        CloudSync.set(subtitleBackground.rawValue, forKey: "sub_bg")
        CloudSync.set(losslessOnCellular, forKey: "music_lossless_cellular")
        CloudSync.set(musicAutoplay, forKey: "music_autoplay")
        CloudSync.set(normalizeVolume, forKey: "music_normalize")
        CloudSync.set(musicRomanizeNames, forKey: "music_romanize")
        CloudSync.set(audiobookSpeed, forKey: "audiobook_speed")
        CloudSync.set(defaults.data(forKey: "smart_playlists"), forKey: "smart_playlists")
        CloudSync.set(fillScreen, forKey: "fill_screen")
        CloudSync.set(liveTVSource.rawValue, forKey: "livetv_source")
        CloudSync.set(iptvPlaylistURL, forKey: "iptv_playlist_url")
        CloudSync.set(iptvGuideURL, forKey: "iptv_guide_url")
        CloudSync.set(iptvUserAgent, forKey: "iptv_user_agent")
        CloudSync.set(iptvRefreshMinutes, forKey: "iptv_refresh_minutes")
        CloudSync.set(downloadQuality, forKey: "download_quality")
        CloudSync.set(downloadsWiFiOnly, forKey: "downloads_wifi_only")
        CloudSync.set(tabBarOrder, forKey: "tab_bar_order")
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
        if let v = CloudSync.object(forKey: "autoplay_next") as? Bool, v != autoplayNext { autoplayNext = v }
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
        if let v = (CloudSync.object(forKey: "audiobook_speed") as? NSNumber)?.doubleValue, v > 0,
           abs(v - audiobookSpeed) > 0.01 { audiobookSpeed = v }
        if let data = CloudSync.data(forKey: "smart_playlists"), data != defaults.data(forKey: "smart_playlists") {
            defaults.set(data, forKey: "smart_playlists")
            Task { @MainActor in SmartPlaylistStore.shared.reload() }
        }
        if let v = CloudSync.object(forKey: "tab_bar_order") as? [String], v != tabBarOrder {
            tabBarOrder = v
        }
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
