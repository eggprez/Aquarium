//  Which of a file's tracks to ask the server for, from the file's own list.
//
//  `PlayerModel` settles the tracks before it asks for a stream, so a transcode
//  — which carries exactly one audio track and only the subtitles asked for —
//  arrives carrying the right ones. Pure, so it can be tested: what was chosen
//  for this series last time wins over Settings, and Settings over the file's
//  own defaults.

import Foundation

enum TrackPreference {
    /// The language settings, read off `Preferences` by the caller.
    struct Settings: Sendable, Hashable {
        /// A language tag, or "" for the file's own choice.
        var audioLanguage = ""
        /// "" = only when the file turns them on, "off" = never, else a tag.
        var subtitleLanguage = ""
        var forcedSubtitlesOnly = false
    }

    /// The tracks to ask for, as the server numbers them — what to request so
    /// the stream arrives carrying them.
    ///
    /// Only where it would make a difference. A track that is the file's own
    /// default is left unnamed: the server sends it anyway, the stream is the
    /// one it would have been, and a direct play stays a direct play. Naming a
    /// subtitle is what turns a direct play into a stream the server builds
    /// (see `DeviceProfile.requestedSubtitleProfiles`), which is the price of
    /// the words being there when the picture is.
    ///
    /// `nil` leaves a choice to the server; `-1` for the subtitle is Jellyfin's
    /// spelling of none.
    static func preferredStreams(
        in source: MediaSource, saved: Preferences.TrackChoice?, settings: Settings
    ) -> (audio: Int?, subtitle: Int?) {
        let audioStreams = source.audioStreams
        let subtitleStreams = source.subtitleStreams

        // The track the server sends when nothing is asked for.
        let defaultAudio = audioStreams.first { $0.Index == source.DefaultAudioStreamIndex }
            ?? audioStreams.first { $0.IsDefault ?? false }
            ?? audioStreams.first

        var audio: MediaStream?
        for want in [saved?.audio, settings.audioLanguage] {
            guard let want, !want.isEmpty else { continue }
            if let match = audioStreams.first(where: { Languages.matches(preference: want, tag: $0.Language) }) {
                audio = match
                break
            }
        }
        let audioIndex = audio?.Index == defaultAudio?.Index ? nil : audio?.Index

        // With the sound already in the preferred language, "forced only"
        // means the track that translates signs and the odd foreign line, or
        // nothing.
        let audioMatches = Languages.matches(
            preference: settings.audioLanguage, tag: (audio ?? defaultAudio)?.Language
        )
        var subtitle: Int?
        for (want, fromSettings) in [(saved?.sub, false), (settings.subtitleLanguage, true)] {
            guard let want, !want.isEmpty else { continue }
            if want == "off" {
                // Only worth saying when the file has something to turn on.
                subtitle = subtitleStreams.isEmpty ? nil : -1
                break
            }
            let candidates = subtitleStreams.filter { Languages.matches(preference: want, tag: $0.Language) }
            if fromSettings, settings.forcedSubtitlesOnly, audioMatches {
                subtitle = candidates.first(where: \.isForced)?.Index ?? (subtitleStreams.isEmpty ? nil : -1)
                break
            }
            if let pick = candidates.first(where: { !$0.isForced }) ?? candidates.first {
                subtitle = pick.Index
                break
            }
            // A saved language the file doesn't have falls through to
            // Settings, as it does once the stream is open.
        }
        if let subtitle, subtitle >= 0, subtitle == source.DefaultSubtitleStreamIndex {
            // Already what the server would send.
            return (audioIndex, nil)
        }
        return (audioIndex, subtitle)
    }
}
