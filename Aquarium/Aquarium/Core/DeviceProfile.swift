//  What this client can actually open, told to the server so it knows when to
//  step in.
//
//  This is the one part of the port that could not be copied across. The Linux
//  build declares mpv's capabilities, which is very nearly "everything": MKV,
//  HEVC, DTS, TrueHD, PGS subtitles, all direct. AVFoundation opens a much
//  narrower set — no Matroska at all, no DTS, no TrueHD — so the profile below
//  is deliberately honest about that, and everything outside it is handed to
//  Jellyfin to remux or transcode.
//
//  Worth knowing: an MKV whose video and audio codecs are on this list is
//  *remuxed*, not re-encoded. The server rewraps the same bitstream into HLS,
//  which costs it almost nothing and costs the picture nothing at all. Only a
//  codec AVFoundation genuinely can't decode — DTS, TrueHD, VP9, AV1 on older
//  hardware — makes the server do real work.

import Foundation

struct DeviceProfile: Encodable, Sendable {
    var Name: String
    var MaxStreamingBitrate: Int
    var MaxStaticBitrate: Int
    var MusicStreamingTranscodingBitrate: Int
    var DirectPlayProfiles: [DirectPlayProfile]
    var TranscodingProfiles: [TranscodingProfile]
    var CodecProfiles: [CodecProfile]
    var SubtitleProfiles: [SubtitleProfile]

    /// How many segments the server must have written before it hands over a
    /// playlist.
    ///
    /// Two is what this asked for, and two is the encoder's own edge: the
    /// player starts the instant the minimum exists and then spends the rest of
    /// the stream a segment and a half behind an ffmpeg that is racing real
    /// time. It survives a file, where the encoder is ahead of the playhead
    /// within seconds and stays there. It does not survive a live channel,
    /// where the encoder never gets ahead at all — every wobble in the source
    /// arrives at the player as a stall.
    ///
    /// Four costs a couple of seconds of start-up on everything and gives a
    /// live encode room to be late without the picture stopping.
    static let minSegments = 4

    struct DirectPlayProfile: Encodable, Sendable {
        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec
            case type = "Type"
        }
        var Container: String
        var type: String
        var VideoCodec: String?
        var AudioCodec: String?
    }

    struct TranscodingProfile: Encodable, Sendable {
        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec, Context, MaxAudioChannels
            case MinSegments, BreakOnNonKeyFrames, EnableSubtitlesInManifest
            case type = "Type"
            case transportProtocol = "Protocol"
        }
        var Container: String
        var type: String
        var transportProtocol: String
        var VideoCodec: String?
        var AudioCodec: String
        var Context: String
        var MaxAudioChannels: String
        var MinSegments: Int?
        /// Left `false` in every profile below, and it needs to stay that way.
        ///
        /// True lets the server cut a segment wherever it likes rather than
        /// only at a keyframe, and a segment starting mid-GOP has no complete
        /// picture to show for its opening frames — so the audio for those
        /// frames plays against video carried over from the segment before.
        /// That is the ordinary way a Jellyfin transcode ends up out of sync,
        /// and from inside the app it looks like a decoding fault rather than a
        /// stream that was built wrong. The Linux build reached the same
        /// setting from the other end: mpv answers a mid-GOP segment by staying
        /// black after a seek while the sound plays on.
        var BreakOnNonKeyFrames: Bool?
        var EnableSubtitlesInManifest: Bool?
    }

    struct CodecProfile: Encodable, Sendable {
        enum CodingKeys: String, CodingKey {
            case Codec, Conditions
            case type = "Type"
        }
        var type: String
        var Codec: String?
        var Conditions: [ProfileCondition]
    }

    struct ProfileCondition: Encodable, Sendable {
        var Condition: String
        var Property: String
        var Value: String
        var IsRequired: Bool
    }

    struct SubtitleProfile: Encodable, Sendable {
        var Format: String
        var Method: String
    }

    /// Audio AVFoundation decodes without help. AC-3 and E-AC-3 are included:
    /// they decode on every current Apple platform and pass through to a
    /// receiver over HDMI on Apple TV, which is exactly where 5.1 matters.
    ///
    /// DTS and TrueHD are still absent and are not an oversight: no Apple
    /// platform decodes either, and tvOS will not pass them through over HDMI
    /// the way it does AC-3 — a track in one of those has to be re-encoded by
    /// the server or there is no sound.
    ///
    /// Vorbis and MP2 are deliberately absent too. Both turn up in the wild and
    /// neither has an AVFoundation decoder, so naming them would buy a direct
    /// play that arrives with no sound at all — worse than the server spending a
    /// moment re-encoding the track.
    private static let directAudio =
        "aac,mp3,ac3,eac3,alac,flac,opus,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be"

    /// Containers AVFoundation opens over HTTP. The ISO base-media family and
    /// QuickTime, which between them is every MP4 a scanner will ever produce;
    /// `3gp`/`3g2` are the same box structure under different brands and cost
    /// nothing to name.
    private static let directContainers = "mp4,m4v,mov,3gp,3g2"

    /// Video codecs AVFoundation decodes out of one of those.
    ///
    /// `dvhe`/`dvh1` are Dolby Vision, which every Apple TV 4K plays natively
    /// and which some servers report as a codec of its own rather than as HEVC
    /// with a profile. Naming both spellings costs nothing and is the
    /// difference between a DV film direct-playing and being ground down to
    /// H.264 SDR by ffmpeg.
    private static let directVideo = "h264,hevc,dvhe,dvh1,hvc1,avc1,mpeg4,mjpeg"

    /// Codecs that survive a remux into HLS without being re-encoded.
    private static let remuxableVideo = "h264,hevc"

    // What the lists above mean for a *file*, which is a narrower question than
    // what they mean for a stream. A download is opened later, from disk, with
    // no server left to fall back on: if AVFoundation can't read it there is no
    // second chance, so the answer has to be certain rather than hopeful.

    /// Containers AVFoundation opens from disk. Matroska is absent for the same
    /// reason it is absent above — it genuinely cannot be opened.
    private static let fileContainers: Set<String> = ["mp4", "m4v", "mov"]

    private static let fileVideoCodecs: Set<String> = ["h264", "hevc", "mpeg4", "mjpeg"]

    /// Narrower than `directAudio`: Opus, FLAC and raw PCM decode happily out of
    /// a stream but are not things AVFoundation reads out of an MP4.
    private static let fileAudioCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac"]

    /// Whether this source, saved to disk byte for byte as the server holds it,
    /// would play. Downloads ask before offering to keep the original: an MKV
    /// transfers perfectly, sits in the list looking finished, and then fails to
    /// open — which is worse than spending the server's time rewrapping it.
    static func canPlayAsFile(_ source: MediaSource?) -> Bool {
        // Split, as in `canDirectPlay`: a container reported as the whole
        // ffmpeg family (`mov,mp4,m4a,3gp,3g2,mj2`) is still an MP4.
        guard let source,
              containerNames(source.Container).contains(where: fileContainers.contains)
        else { return false }
        // A video file with no video stream the server will admit to is not
        // something to gamble a gigabyte on.
        guard let video = source.streams.first(where: { $0.type == "Video" })?.Codec?.lowercased(),
              fileVideoCodecs.contains(video)
        else { return false }
        // Audio is allowed to be absent — silent films exist — but not to be
        // something that won't decode.
        if let audio = source.streams.first(where: { $0.type == "Audio" })?.Codec?.lowercased(),
           !fileAudioCodecs.contains(audio) {
            return false
        }
        return true
    }

    /// Whether the original picture can come down rewrapped rather than
    /// re-encoded: H.264 or HEVC, which the download's fMP4 segments carry as
    /// they are. What `JellyfinClient.downloadURL` asks for when the original is
    /// wanted and `canPlayAsFile` says no.
    static func canRemuxForDownload(_ source: MediaSource?) -> Bool {
        guard let codec = source?.streams.first(where: { $0.type == "Video" })?.Codec?.lowercased() else { return false }
        return codec == "h264" || codec == "hevc"
    }

    /// A container as the server reports it, one name per entry.
    private static func containerNames(_ container: String?) -> [String] {
        (container ?? "").lowercased()
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
    }

    /// The extension to save a downloaded file under. Not the container as
    /// reported: that can be a family of names, and `film.mov,mp4,m4a` is not
    /// a file AVFoundation will open. The MP4 name is preferred when it is
    /// among them, `m4a` for sound alone.
    static func fileExtension(forContainer container: String?, audio: Bool) -> String {
        let names = containerNames(container)
        let preferred = audio ? ["m4a", "mp4"] : ["mp4", "m4v", "mov"]
        if let hit = preferred.first(where: names.contains) { return hit }
        // The container is the server's word and this becomes part of a file
        // name, so it has to look like an extension: a few letters and digits,
        // and nothing that means anything to a path.
        let plain = names.first { name in
            (1...8).contains(name.utf8.count) && name.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
        }
        return plain ?? (audio ? "m4a" : "mp4")
    }

    // MARK: - Second-guessing the server

    /// Whether a source the server has offered as *direct play* is one
    /// AVFoundation will actually open.
    ///
    /// The profile above is meant to make this question unnecessary: the server
    /// is told exactly what this client reads and is supposed to hand back a
    /// transcode for anything else. In practice it does not always. Jellyfin
    /// applies `CodecProfile` conditions only where ffprobe filled in the
    /// property they test — a source whose `Profile` or `BitDepth` came back
    /// empty passes every condition by default — an older server ignores some of
    /// them outright, and a `Container` reported as the ffmpeg demuxer's whole
    /// family (`mov,mp4,m4a,3gp,3g2,mj2`) matches a direct-play entry it should
    /// not. Every one of those ends the same way: the app is handed the original
    /// file, opens it, and gets a black screen or a failure, having asked the
    /// server for the one thing it can't use.
    ///
    /// So the answer is checked here as well, against the same lists the profile
    /// is built from. Disagreement is not an error — it means ask again with
    /// direct play switched off, which is what `JellyfinClient.resolvePlayback`
    /// does with it.
    ///
    /// Deliberately conservative in one direction only: unknown is treated as
    /// *playable*. A source the server didn't describe is left alone rather than
    /// transcoded on suspicion, because the cost of a wrong "no" is real work on
    /// somebody's server for every file it misjudges, while the cost of a wrong
    /// "yes" is the failure path this already had — which now escalates to a
    /// transcode anyway. See `PlayerModel.escalateToTranscode`.
    static func canDirectPlay(_ source: MediaSource) -> Bool {
        if let container = source.Container?.lowercased(), !container.isEmpty {
            // Split, because ffprobe names a family rather than a file: the
            // question is whether *any* of the names it gave is one we read.
            let names = container.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            guard names.contains(where: { directContainerSet.contains($0) }) else { return false }
        }

        if let video = source.streams.first(where: { $0.type == "Video" }) {
            if let codec = video.Codec?.lowercased(), !codec.isEmpty {
                guard directVideoSet.contains(codec) else { return false }
                // 10-bit H.264 has no hardware decoder on any Apple device and
                // crawls in software; HEVC above ten bits has none at all.
                let ceiling = (codec == "h264" || codec == "avc1") ? 8 : 10
                if let depth = video.BitDepth, depth > ceiling { return false }
                // The bit depth is the honest test, but it is also the field
                // most often missing. `High 10` and `Main 12` say the same thing
                // in words, and a server that dropped one usually kept the other.
                if let profile = video.Profile?.lowercased(),
                   profile.contains("10") || profile.contains("12") {
                    if codec == "h264" || codec == "avc1" { return false }
                    if profile.contains("12") { return false }
                }
            }
        }

        // Audio is allowed to be absent — silent films exist — but a track this
        // device can't decode means a direct play that arrives without sound,
        // which is not a direct play anyone wanted. DTS and TrueHD are the two
        // that turn up constantly in a library of remuxes.
        for audio in source.streams where audio.type == "Audio" {
            guard let codec = audio.Codec?.lowercased(), !codec.isEmpty else { continue }
            if !directAudioSet.contains(codec) { return false }
            // Only the first audio track decides. A remux carrying a DTS-HD
            // commentary alongside a perfectly playable AC-3 main track should
            // still direct-play; the track menu simply won't offer the one that
            // doesn't decode.
            break
        }

        return true
    }

    private static let directContainerSet = Set(directContainers.split(separator: ",").map(String.init))
    private static let directVideoSet = Set(directVideo.split(separator: ",").map(String.init))
    private static let directAudioSet = Set(directAudio.split(separator: ",").map(String.init))

    // MARK: - Music

    /// Containers AVFoundation opens as a plain audio file, over HTTP or from
    /// disk. Ogg — and so Vorbis and Opus in it — is absent because it cannot
    /// be opened at all; WMA, APE, WavPack and DSD likewise. Those are the
    /// files the server re-encodes to AAC for this client.
    private static let musicContainers = "mp3,aac,m4a,m4b,flac,alac,wav,aiff,aif,caf"
    private static let musicContainerSet = Set(musicContainers.split(separator: ",").map(String.init))

    /// What can be inside one of those and still decode.
    private static let musicCodecs = "mp3,aac,alac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be,pcm_s24be"
    private static let musicCodecSet = Set(musicCodecs.split(separator: ",").map(String.init))

    /// What the server is told before it hands over a song.
    ///
    /// `maxBitrate` is the cellular cap: with one set, anything above it —
    /// which in practice means every lossless file — comes back as an AAC
    /// transcode instead, at `transcodeBitrate`. Without one the ceiling is
    /// high enough that nothing is refused on size and only a format this
    /// device can't read is re-encoded.
    ///
    /// The transcode is HLS in fragmented MP4 rather than a progressive MP3:
    /// a progressive transcode cannot be seeked — the bytes for a position
    /// the encoder hasn't reached do not exist yet — and a scrubber that
    /// works on some songs and not others is worse than one that never works.
    static func buildMusic(maxBitrate: Int?, transcodeBitrate: Int = 256_000) -> DeviceProfile {
        DeviceProfile(
            Name: "Aquarium Music (AVFoundation)",
            MaxStreamingBitrate: maxBitrate ?? 200_000_000,
            MaxStaticBitrate: 200_000_000,
            MusicStreamingTranscodingBitrate: transcodeBitrate,
            DirectPlayProfiles: [
                .init(Container: musicContainers, type: "Audio", VideoCodec: nil, AudioCodec: musicCodecs),
            ],
            TranscodingProfiles: [
                .init(
                    Container: "mp4", type: "Audio", transportProtocol: "hls",
                    VideoCodec: nil, AudioCodec: "aac",
                    Context: "Streaming", MaxAudioChannels: "2",
                    MinSegments: 1, BreakOnNonKeyFrames: nil, EnableSubtitlesInManifest: nil
                ),
                .init(
                    Container: "ts", type: "Audio", transportProtocol: "hls",
                    VideoCodec: nil, AudioCodec: "aac",
                    Context: "Streaming", MaxAudioChannels: "2",
                    MinSegments: 1, BreakOnNonKeyFrames: nil, EnableSubtitlesInManifest: nil
                ),
                .init(
                    Container: "mp3", type: "Audio", transportProtocol: "http",
                    VideoCodec: nil, AudioCodec: "mp3",
                    Context: "Streaming", MaxAudioChannels: "2",
                    MinSegments: nil, BreakOnNonKeyFrames: nil, EnableSubtitlesInManifest: nil
                ),
            ],
            CodecProfiles: [],
            SubtitleProfiles: []
        )
    }

    /// `canDirectPlay` for a song: the same second-guessing of the server,
    /// against the audio lists rather than the video ones.
    static func canDirectPlayAudio(_ source: MediaSource) -> Bool {
        if let container = source.Container?.lowercased(), !container.isEmpty {
            let names = container.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            guard names.contains(where: { musicContainerSet.contains($0) }) else { return false }
        }
        if let audio = source.audioStreams.first, let codec = audio.Codec?.lowercased(), !codec.isEmpty {
            guard musicCodecSet.contains(codec) else { return false }
        }
        return true
    }

    /// Whether a song, downloaded byte for byte, would open from disk. The
    /// same lists as above: a file AVFoundation streams it also reads.
    static func canPlayAudioAsFile(_ source: MediaSource?) -> Bool {
        guard let source else { return false }
        return canDirectPlayAudio(source) && !(source.Container ?? "").isEmpty
    }

    /// The codec to ask for when rewrapping this source into MP4. Naming the
    /// codec it already uses is what lets the server copy the bitstream across
    /// instead of re-encoding it; anything else has to become H.264.
    static func remuxVideoCodec(for source: MediaSource?) -> String {
        let codec = source?.streams.first { $0.type == "Video" }?.Codec?.lowercased() ?? ""
        return codec == "hevc" ? "hevc" : "h264"
    }

    /// Audio that is decoded here rather than passed through: `directAudio`
    /// less the two Dolby bitstreams. Named separately so the two lists can be
    /// read against each other — everything else AVFoundation decodes on its
    /// own anyway, and only AC-3 and E-AC-3 are ever handed to the receiver
    /// undecoded.
    private static let decodedAudio =
        "aac,mp3,alac,flac,opus,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be"

    /// The Apple TV's profile, now that it plays through mpv rather than
    /// AVFoundation.
    ///
    /// Nearly everything above is about what AVFoundation can't open, and none
    /// of it applies: mpv reads Matroska, DTS, TrueHD, PGS and the rest straight
    /// from the file. So the original is asked for untouched — the least work
    /// for the server, and no transcode to put the sound out of step with the
    /// picture — unless a lower quality was chosen or the connection can't
    /// carry the file, which is what `forceTranscode` and `maxBitrate` say.
    /// Subtitles stay in the file (`Embed`) and mpv draws them; a sidecar the
    /// server offers as `External` is added to the player by URL.
    ///
    /// The same shape as the Linux client's profile, which plays through the
    /// same library.
    static func buildMPV(forceTranscode: Bool, maxBitrate: Int?, stereoOnly: Bool) -> DeviceProfile {
        let channels = stereoOnly ? "2" : "8"
        let sizeConditions: [ProfileCondition] = {
            guard let cap = Quality.cap(for: maxBitrate) else { return [] }
            return [
                .init(Condition: "LessThanEqual", Property: "Width",
                      Value: String(cap.width), IsRequired: false),
                .init(Condition: "LessThanEqual", Property: "Height",
                      Value: String(cap.height), IsRequired: false),
            ]
        }()
        let subtitles: [SubtitleProfile] =
            ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "sub", "pgssub", "dvdsub", "dvbsub"]
                .map { SubtitleProfile(Format: $0, Method: "Embed") }
            + ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]
                .map { SubtitleProfile(Format: $0, Method: "External") }
        return DeviceProfile(
            Name: "Aquarium (mpv)",
            MaxStreamingBitrate: maxBitrate ?? 200_000_000,
            MaxStaticBitrate: 200_000_000,
            MusicStreamingTranscodingBitrate: 384_000,
            DirectPlayProfiles: forceTranscode ? [] : [
                .init(Container: "mp4,m4v,mkv,webm,mov,avi,wmv,asf,ts,m2ts,mpegts,flv,ogv,mpg,mpeg,3gp",
                      type: "Video", VideoCodec: nil, AudioCodec: nil),
                .init(Container: "mp3,aac,m4a,m4b,flac,alac,wav,aiff,aif,caf,opus,ogg", type: "Audio",
                      VideoCodec: nil, AudioCodec: nil),
            ],
            TranscodingProfiles: [
                // Keyframe-aligned segments for the reason on
                // `BreakOnNonKeyFrames`: mpv answers a mid-GOP segment by
                // staying black after a seek while the sound plays on.
                .init(
                    Container: "mp4", type: "Video", transportProtocol: "hls",
                    VideoCodec: "hevc,h264",
                    AudioCodec: stereoOnly ? "aac" : "aac,ac3,eac3",
                    Context: "Streaming", MaxAudioChannels: channels,
                    MinSegments: minSegments, BreakOnNonKeyFrames: false,
                    EnableSubtitlesInManifest: false
                ),
                .init(
                    Container: "ts", type: "Video", transportProtocol: "hls",
                    VideoCodec: "h264",
                    AudioCodec: stereoOnly ? "aac" : "aac,ac3",
                    Context: "Streaming", MaxAudioChannels: channels,
                    MinSegments: minSegments, BreakOnNonKeyFrames: false,
                    EnableSubtitlesInManifest: false
                ),
                .init(
                    Container: "mp3", type: "Audio", transportProtocol: "http",
                    VideoCodec: nil, AudioCodec: "mp3",
                    Context: "Streaming", MaxAudioChannels: "2",
                    MinSegments: nil, BreakOnNonKeyFrames: nil,
                    EnableSubtitlesInManifest: nil
                ),
            ],
            // Only the size a chosen quality asks for. What the Apple TV can
            // decode is no longer the server's question: mpv decodes in
            // hardware what VideoToolbox takes and in software the rest.
            CodecProfiles: sizeConditions.isEmpty ? [] : [
                .init(type: "Video", Codec: "h264", Conditions: sizeConditions),
                .init(type: "Video", Codec: "hevc", Conditions: sizeConditions),
            ],
            SubtitleProfiles: subtitles
        )
    }

    static func build(
        forceTranscode: Bool, maxBitrate: Int?, stereoOnly: Bool,
        decodeAudioLocally: Bool = false,
        subtitlesInManifest: Bool = false
    ) -> DeviceProfile {
        let ceiling = maxBitrate ?? 200_000_000
        // Soundbar mode (`Preferences.decodeAudioLocally`): no Dolby bitstream
        // anywhere in the profile, so a file carrying one is re-encoded to AAC
        // by the server — audio only, the picture is still copied through —
        // and AVPlayer decodes it here and sends PCM over HDMI instead of
        // leaving the soundbar to decode and add its own lag. Six channels
        // rather than eight in that mode: 5.1 PCM is what every receiver
        // takes, and a 7.1 track re-encoded to AAC for a soundbar that will
        // fold it anyway is work for nothing.
        let directAudio = decodeAudioLocally ? decodedAudio : directAudio
        let transcodeAudio = stereoOnly || decodeAudioLocally ? "aac" : "aac,ac3,eac3"
        let tsTranscodeAudio = stereoOnly || decodeAudioLocally ? "aac" : "aac,ac3"
        // Jellyfin reads this as a hard cap on the *stream*, so a direct play of
        // a 40 Mbps remux would be refused if it were pinned to the rung the
        // user picked. Only a forced transcode gets the tight ceiling.
        //
        // Eight channels rather than six where the user hasn't asked for a
        // downmix. An Apple TV passes 7.1 E-AC-3 straight out over HDMI, and
        // saying "6" made the server re-encode a 7.1 track down to 5.1 for no
        // reason at all — real work, on every stream with one, to lose two
        // channels the receiver on the other end was ready to play.
        let channels = stereoOnly ? "2" : (decodeAudioLocally ? "6" : "8")

        // The picture size that goes with the rung, as conditions on the output
        // codec. This is the only way to ask Jellyfin for a resolution:
        // `MaxStreamingBitrate` caps bits alone, and a server given nothing but
        // a small ceiling encodes the source at its original size and spends the
        // bitrate badly — a 480p rung that arrives as smeared 1080p. Jellyfin's
        // `StreamBuilder` reads Width and Height off the codec profile for the
        // codec it is about to encode to and turns them into MaxWidth/MaxHeight
        // on the transcode, which is what the browser client does too.
        //
        // Both conditions, not just width: a width cap does nothing to a
        // portrait or heavily letterboxed source, which then encodes at full
        // height. Same trap as the download URL builder.
        //
        // `IsRequired: false` because these are a preference about scale, not a
        // statement about what can be decoded. Required conditions are also
        // consulted when the server decides whether a file could be played
        // untouched, and a 4K file is perfectly playable — it just isn't what
        // this rung asked for.
        let sizeConditions: [ProfileCondition] = {
            guard let cap = Quality.cap(for: maxBitrate) else { return [] }
            return [
                .init(Condition: "LessThanEqual", Property: "Width",
                      Value: String(cap.width), IsRequired: false),
                .init(Condition: "LessThanEqual", Property: "Height",
                      Value: String(cap.height), IsRequired: false),
            ]
        }()

        return DeviceProfile(
            Name: "Aquarium (AVFoundation)",
            MaxStreamingBitrate: ceiling,
            MaxStaticBitrate: 200_000_000,
            MusicStreamingTranscodingBitrate: 384_000,
            DirectPlayProfiles: forceTranscode ? [] : [
                // The containers AVFoundation opens. MKV is absent because it
                // genuinely cannot be opened, not as a policy choice — and an
                // MKV whose codecs are on these lists is remuxed rather than
                // re-encoded anyway, which costs the picture nothing.
                .init(Container: directContainers, type: "Video",
                      VideoCodec: directVideo, AudioCodec: directAudio),
                .init(Container: "mp3,aac,m4a,m4b,flac,alac,wav,aiff,aif,caf,opus", type: "Audio",
                      VideoCodec: nil, AudioCodec: nil),
            ],
            TranscodingProfiles: [
                // Both video profiles leave `BreakOnNonKeyFrames` off. It is
                // the one field here that decides whether a transcode arrives
                // in sync at all — see the property for what turning it on
                // costs.
                //
                // fMP4 HLS first: it is the only way HEVC reaches AVPlayer, and
                // an HEVC source stays HEVC instead of being ground down to
                // H.264 for no reason.
                .init(
                    Container: "mp4", type: "Video", transportProtocol: "hls",
                    VideoCodec: remuxableVideo,
                    AudioCodec: transcodeAudio,
                    Context: "Streaming", MaxAudioChannels: channels,
                    MinSegments: minSegments, BreakOnNonKeyFrames: false,
                    EnableSubtitlesInManifest: true
                ),
                // MPEG-TS HLS as the fallback for older servers that don't
                // offer fMP4 segments.
                .init(
                    Container: "ts", type: "Video", transportProtocol: "hls",
                    VideoCodec: "h264",
                    AudioCodec: tsTranscodeAudio,
                    Context: "Streaming", MaxAudioChannels: channels,
                    MinSegments: minSegments, BreakOnNonKeyFrames: false,
                    EnableSubtitlesInManifest: true
                ),
                .init(
                    Container: "mp3", type: "Audio", transportProtocol: "http",
                    VideoCodec: nil, AudioCodec: "mp3",
                    Context: "Streaming", MaxAudioChannels: "2",
                    MinSegments: nil, BreakOnNonKeyFrames: nil,
                    EnableSubtitlesInManifest: nil
                ),
            ],
            CodecProfiles: [
                // 10-bit H.264 is not decodable in hardware on any Apple device
                // and stutters badly in software; asking the server to handle it
                // is much better than watching it fail. `high 10` is left out of
                // the profile list for exactly that reason, and the bit-depth
                // condition says the same thing a second way.
                .init(type: "Video", Codec: "h264", Conditions: [
                    .init(Condition: "EqualsAny", Property: "VideoProfile",
                          Value: "high|main|baseline|constrained baseline|constrained high",
                          IsRequired: false),
                    .init(Condition: "LessThanEqual", Property: "VideoBitDepth", Value: "8", IsRequired: false),
                    .init(Condition: "LessThanEqual", Property: "VideoLevel", Value: "52", IsRequired: false),
                ] + sizeConditions),
                // HEVC by bit depth alone.
                //
                // There was an `EqualsAny VideoProfile main|main 10` here, and
                // it was quietly the most expensive line in this file. Dolby
                // Vision is HEVC with a profile idc ffprobe does not have a name
                // for, so Jellyfin reports it as `Unknown` — which matches
                // neither `main` nor `main 10`, so every DV title on the server
                // failed the condition and was transcoded: a full re-encode of a
                // 4K film, on a box that would have played the original
                // untouched. HDR10 and HLG go the same way on servers that
                // report their profile as `Main 10 HDR`.
                //
                // Bit depth is the condition that actually separates what this
                // hardware decodes from what it doesn't: Main and Main 10 are 8
                // and 10 bits, and the profiles Apple silicon genuinely cannot
                // take — Main 12, and the Range Extensions — are all above ten.
                //
                // `IsAnamorphic` has gone from both entries as well. It is in
                // Jellyfin's browser profiles because some `<video>` decoders
                // ignore a non-square pixel aspect ratio; AVFoundation honours
                // the `pasp` box, so a DVD rip here plays at the shape it was
                // authored in rather than being re-encoded to square pixels.
                .init(type: "Video", Codec: "hevc", Conditions: [
                    .init(Condition: "LessThanEqual", Property: "VideoBitDepth", Value: "10", IsRequired: false),
                ] + sizeConditions),
            ],
            SubtitleProfiles: subtitlesInManifest ? requestedSubtitleProfiles : subtitleProfiles
        )
    }

    /// Text subtitles ride the HLS manifest as WebVTT, which is what makes them
    /// selectable in AVPlayer's own track menu and stylable through
    /// `AVTextStyleRule`. Image-based subtitles (PGS, VOBSUB) have no such path
    /// and are burnt into the picture by the server, which is the only way they
    /// can be shown at all.
    ///
    /// The methods here decide far more than how a subtitle arrives: Jellyfin
    /// will only direct-play a source whose *selected* subtitle can be delivered
    /// without building a new stream, and the server selects one on its own from
    /// the file's defaults whenever the request doesn't. So a list that offers
    /// only `Hls` and `Encode` for the text formats turns every file with a
    /// default subtitle track into a transcode — which is what happened when
    /// SubRip was moved off `External` here, and it took the audio delay with it,
    /// that being a thing only a direct-played file can carry.
    ///
    /// `External` is kept for that reason even though this client cannot open a
    /// standalone `.srt` — AVFoundation has no side door for one. Declaring it
    /// costs nothing, because a subtitle nobody asked for was never going to be
    /// shown anyway, and it keeps the direct play. Asking for a subtitle is what
    /// changes the answer — see `requestedSubtitleProfiles`.
    private static let subtitleProfiles: [SubtitleProfile] = [
        .init(Format: "vtt", Method: "Hls"),
        .init(Format: "webvtt", Method: "Hls"),
        .init(Format: "srt", Method: "External"),
        .init(Format: "subrip", Method: "External"),
        .init(Format: "ass", Method: "Encode"),
        .init(Format: "ssa", Method: "Encode"),
        .init(Format: "pgssub", Method: "Encode"),
        .init(Format: "dvdsub", Method: "Encode"),
        .init(Format: "dvbsub", Method: "Encode"),
    ]

    /// The same list for a stream somebody has actually chosen a subtitle on.
    ///
    /// Here `External` is the wrong answer rather than the harmless one: the
    /// viewer has asked to see this track, and a URL to fetch it from is a thing
    /// this client can do nothing with. So the text formats are all `Hls`, which
    /// converts them to WebVTT and puts them in the manifest where AVPlayer can
    /// select them — and which, being a delivery only an HLS output can make,
    /// is also what stops the server offering the untouched file back.
    ///
    /// Two lists rather than one because the cost is real and only worth paying
    /// when it buys something. Sent on every request, this turns each file whose
    /// *default* subtitle happens to be a `.srt` into a remux — and takes the
    /// audio delay with it, that being a thing only a direct play can carry.
    private static let requestedSubtitleProfiles: [SubtitleProfile] = subtitleProfiles.map {
        ["srt", "subrip", "vtt", "webvtt", "mov_text", "ass", "ssa"].contains($0.Format)
            && $0.Method == "External"
            ? SubtitleProfile(Format: $0.Format, Method: "Hls")
            : $0
    }
}

// MARK: - Playback reporting

/// One progress report to `/Sessions/Playing*`. The same shape serves start,
/// progress and stopped, which is how Jellyfin's own clients do it.
struct PlaybackReport: Encodable, Sendable {
    var ItemId: String
    var MediaSourceId: String?
    var PlaySessionId: String?
    var PositionTicks: Int64
    var IsPaused: Bool
    var IsMuted: Bool
    var PlayMethod: String
    var RepeatMode: String = "RepeatNone"
    var PlaybackRate: Double?
    var VolumeLevel: Int?
    var CanSeek: Bool = true
    var AudioStreamIndex: Int?
    var SubtitleStreamIndex: Int?

    init(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionSeconds: Double,
        isPaused: Bool,
        isTranscode: Bool,
        rate: Double = 1,
        volume: Double = 1
    ) {
        ItemId = itemId
        MediaSourceId = mediaSourceId
        PlaySessionId = playSessionId
        PositionTicks = Int64(max(0, positionSeconds) * 10_000_000)
        IsPaused = isPaused
        IsMuted = volume <= 0
        PlayMethod = isTranscode ? "Transcode" : "DirectStream"
        PlaybackRate = rate
        VolumeLevel = Int((volume * 100).rounded())
    }
}
