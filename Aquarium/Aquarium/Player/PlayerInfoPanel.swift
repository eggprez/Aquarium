//  The stream facts the Mac's inspector and the player's Info tab list: the
//  file the server holds, what is actually coming down the wire, and where
//  playback is. See `StreamInfoInspector` and `PlayerPanel`.

import Foundation

/// What is actually arriving, as rows of label and value: the file the server
/// holds, the stream this device is being sent, and where playback has got
/// to. The tvOS ribbon lays them out in three columns and the Mac inspector
/// in a `Form`; the numbers are the same, read here once.
///
/// None of the numbers below `streamFacts` is a property anything writes, so
/// observation has nothing to notice about them — they are read out of the
/// player item each time a body that uses these runs, and the panels redraw
/// on `player.position`, which moves every half second.
@MainActor
struct PlayerStreamRows {
    let player: PlayerModel

    typealias Row = (label: String, value: String)

    private var item: BaseItem? { player.infoItem }
    private var source: MediaSource? { item?.MediaSources?.first }

    // MARK: The file

    /// Empty for a channel and for a download: neither has a Jellyfin media
    /// source behind it, and a column of blanks says less than no column.
    var file: [Row] {
        guard let source else { return [] }
        let video = source.streams.first { $0.type == "Video" }
        let audio = source.streams.first { $0.type == "Audio" }
        let subtitles = source.streams.filter { $0.type == "Subtitle" }
        var rows: [Row] = []
        if let container = source.Container, !container.isEmpty {
            rows.append(("Container", container.uppercased()))
        }
        if let size = source.Size, size > 0 { rows.append(("Size", Format.bytes(size))) }
        if let video {
            var parts: [String] = []
            if let codec = video.Codec, !codec.isEmpty { parts.append(codec.uppercased()) }
            if let profile = video.Profile, !profile.isEmpty { parts.append(profile) }
            if let depth = video.BitDepth, depth > 0 { parts.append("\(depth)-bit") }
            if !parts.isEmpty { rows.append(("Video", parts.joined(separator: " · "))) }
            if let width = video.Width, let height = video.Height, width > 0, height > 0 {
                let name = Format.resolutionLabel(video).map { " (\($0))" } ?? ""
                rows.append(("Frame", "\(width)×\(height)\(name)"))
            }
            if let rate = video.RealFrameRate ?? video.AverageFrameRate, rate > 0 {
                rows.append(("Frame rate", PlayerModel.frameRateName(rate)))
            }
            // `HDR10`, `HLG`, `DOVI`; the coarse `HDR` when that is all the
            // server read; nothing for plain SDR.
            if let range = video.VideoRangeType ?? video.VideoRange, !range.isEmpty, range.uppercased() != "SDR" {
                rows.append(("Range", range))
            }
            if let bitrate = video.BitRate, bitrate > 0 {
                rows.append(("Video rate", Self.mbps(Double(bitrate))))
            }
        }
        if let audio {
            var parts: [String] = []
            if let codec = audio.Codec, !codec.isEmpty { parts.append(codec.uppercased()) }
            if let channels = Format.channelLabel(audio) { parts.append(channels) }
            if let language = audio.Language, !language.isEmpty { parts.append(language.uppercased()) }
            if !parts.isEmpty { rows.append(("Audio", parts.joined(separator: " · "))) }
        }
        if !subtitles.isEmpty {
            rows.append(("Subtitles", "\(subtitles.count) track\(subtitles.count == 1 ? "" : "s")"))
        }
        return rows
    }

    // MARK: The stream

    var stream: [Row] {
        let facts = player.streamFacts
        var rows: [Row] = []
        rows.append(("Delivery", delivery))
        if let resolution = facts.resolution { rows.append(("Arriving at", resolution)) }
        if let indicated = facts.indicatedBitrate {
            rows.append(("Variant", Self.mbps(indicated)))
        }
        if let observed = facts.observedBitrate {
            rows.append(("Throughput", Self.mbps(observed)))
        }
        if let stalls = facts.stalls { rows.append(("Stalls", String(stalls))) }
        if let dropped = facts.droppedFrames, dropped > 0 {
            rows.append(("Dropped", String(dropped)))
        }
        if let host = facts.host, !host.isEmpty { rows.append(("From", host)) }
        // The one line worth more than all the others when it is there: what
        // the stream turned out to contain, when the picture never came. See
        // `StreamDiagnosis`.
        if player.noVideoTrack { rows.append(("Picture", "None in this stream")) }
        return rows
    }

    private var delivery: String {
        if player.isLocal { return "Playing from this device" }
        if player.isExternal { return "Straight from the playlist" }
        if player.isTranscoding {
            return "Transcoding · " + Quality.shortLabel(for: player.currentBitrate)
        }
        return "Direct play"
    }

    // MARK: Where playback is

    var now: [Row] {
        var rows: [Row] = []
        if let engine = player.engineKind {
            var value = engine.title
            if let decoder = player.decoder, engine == .mpv {
                value += decoder == "no" ? " · software decoding" : " · hardware decoding (\(decoder))"
            }
            rows.append(("Engine", value))
        }
        #if os(tvOS)
        if let matched = DisplayMatch.matchedRate {
            rows.append(("Display", PlayerModel.frameRateName(matched, unit: "Hz")))
        }
        #endif
        if player.isLive {
            rows.append(("Position", "Live"))
        } else if player.duration > 0 {
            rows.append(("Position", "\(Format.clock(player.position)) / \(Format.clock(player.duration))"))
            rows.append(("Left", Format.ticks(Int64(max(0, player.duration - player.position) * 10_000_000))))
        }
        let ahead = player.buffered - player.position
        if ahead.isFinite, ahead > 0 {
            rows.append(("Buffered", "\(Int(ahead.rounded()))s ahead"))
        }
        if player.speed != 1 { rows.append(("Speed", PlayerModel.speedName(player.speed))) }
        // Only once it has been moved off zero: on a stream that is in sync
        // this is a row saying nothing, and it is the one row here that says
        // something about a setting rather than about the file.
        if player.appliedAudioDelayMilliseconds != 0 {
            let ms = player.appliedAudioDelayMilliseconds
            rows.append(("Audio delay", "\(ms > 0 ? "+" : "")\(ms) ms"))
        }
        if let id = player.selectedAudioTrack, let track = player.audioTracks.first(where: { $0.id == id }) {
            rows.append(("Audio track", track.label))
        }
        if let id = player.selectedSubtitleTrack, let track = player.subtitleTracks.first(where: { $0.id == id }) {
            rows.append(("Subtitles", track.label))
        } else if !player.subtitleTracks.isEmpty {
            rows.append(("Subtitles", "Off"))
        }
        if let chapter = player.chapterName(at: player.position) {
            rows.append(("Chapter", chapter))
        }
        if let minutes = player.sleepMinutesRemaining {
            rows.append(("Sleep timer", "\(minutes) min left"))
        }
        if player.autoplayCancelled, !player.isLive {
            rows.append(("After this", "Stop"))
        }
        return rows
    }

    static func mbps(_ bitsPerSecond: Double) -> String {
        let mbps = bitsPerSecond / 1_000_000
        return mbps >= 10
            ? String(format: "%.0f Mbps", mbps)
            : String(format: "%.1f Mbps", mbps)
    }
}
