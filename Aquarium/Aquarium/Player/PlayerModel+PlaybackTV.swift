//  Starting, reopening and recovering streams on the Apple TV, where the
//  engine is libmpv. Lifted from the old `TVPlayerModel` with mpv's own calls
//  moved behind the engine: a `load` is an `EngineLoadRequest`, `ao-reload` is
//  `rebuildAudio`, `video-sync` is `setDisplayRefreshRate`.

#if os(tvOS)

import AVFoundation
import Foundation
import OSLog
import UIKit

extension PlayerModel {
    // MARK: - Starting playback

    func play(item: BaseItem, options: StreamOptions = .init(), meta: StartMeta = .init()) async {
        MusicPlayer.shared.yield()
        guard let engine = makeEngine() else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }
        let sameItem = self.item?.Id == item.Id

        var opts = options
        if opts.maxBitrate == nil, !opts.bitrateIsChosen, !opts.live, prefs.defaultBitrate != nil,
           !meta.inherited {
            opts.maxBitrate = prefs.defaultBitrate
        }
        if !opts.live, let source = item.MediaSources?.first, !source.streams.isEmpty,
           !sameItem || (opts.audioStreamIndex == nil && opts.subtitleStreamIndex == nil) {
            let wanted = preferredStreams(in: source, seriesId: item.SeriesId)
            opts.audioStreamIndex = wanted.audio
            opts.subtitleStreamIndex = wanted.subtitle
        }

        let startSeconds = startSeconds(for: item, options: opts)

        let previous = source
        let keptDuration = duration
        resetStreamState()
        // The same title reopened for a track or a quality plays on until the
        // new file is in, with the engine's reports ignored meanwhile.
        if sameItem, !opts.live {
            position = startSeconds
            duration = keptDuration
        }
        if !sameItem { fullItem = nil }
        if !meta.reopening { liveReopens = 0 }
        if !meta.recovering { escalated = false }
        self.item = item
        self.options = opts
        self.externalStream = nil
        self.isExternal = false
        self.isLive = opts.live
        self.autoplayCancelled = false
        self.title = Self.displayTitle(item)
        self.subtitle = item.isEpisode ? (item.SeriesName ?? "") : Format.itemSubtitle(item)
        self.artworkURL = Artwork.url(item, type: "Primary", width: 600)
        self.currentBitrate = opts.maxBitrate
        self.wantedTracks = (opts.audioStreamIndex, opts.subtitleStreamIndex)
        self.isActive = true
        self.isOpening = true
        self.isBuffering = true
        generation &+= 1
        let mine = generation
        watchOpening(mine)
        awaitingLoad = true
        if !sameItem {
            engine.stop()
            pictureIsStale = true
        }

        do {
            let src = try await client.resolvePlayback(
                itemId: item.Id, maxBitrate: opts.maxBitrate,
                forceTranscode: opts.forceTranscode || opts.maxBitrate != nil,
                live: opts.live, startTicks: Int64(startSeconds * 10_000_000),
                audioStreamIndex: opts.audioStreamIndex, subtitleStreamIndex: opts.subtitleStreamIndex)
            guard generation == mine else { await release(src); return }
            source = src
            isTranscoding = src.isTranscode
            Self.log.info("opening \(item.Id, privacy: .public): \(src.isTranscode ? "transcode" : "original", privacy: .public), container \(src.mediaSource.Container ?? "none", privacy: .public)")
            engine.rate = speed
            if let video = src.mediaSource.streams.first(where: { $0.type == "Video" }),
               let rate = video.RealFrameRate ?? video.AverageFrameRate {
                displayRequested = true
                await DisplayMatch.request(
                    rate: rate, codec: video.Codec,
                    size: CGSize(width: video.Width ?? 0, height: video.Height ?? 0))
                guard generation == mine else { await release(src); return }
            }
            engine.setDisplayRefreshRate(DisplayMatch.matchedRate)
            engine.audioDelay = audioDelay
            awaitingLoad = false
            currentStreamURL = src.url
            engine.load(EngineLoadRequest(
                url: src.url, headers: client.authHeaders(for: src.url),
                startAt: opts.live ? 0 : startSeconds, live: opts.live))
            if let previous {
                if previous.isTranscode, previous.playSessionId != src.playSessionId {
                    await client.stopTranscode(playSessionId: previous.playSessionId)
                }
                if let stale = previous.mediaSource.LiveStreamId, !stale.isEmpty,
                   stale != src.mediaSource.LiveStreamId {
                    await client.closeLiveStream(id: stale)
                }
            }
            await loadExtras(for: item)
            guard generation == mine else { return }
            await client.reportPlaybackStart(report(paused: false))
        } catch {
            guard generation == mine else { return }
            awaitingLoad = false
            Self.log.error("start failed \(item.Id, privacy: .public): \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            isBuffering = false
            isOpening = false
        }
    }

    func playExternal(
        title: String, subtitle: String, artworkURL: URL?, streamURL: URL,
        channel: BaseItem? = nil, reopening: Bool = false
    ) {
        MusicPlayer.shared.yield()
        guard let engine = makeEngine() else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }
        let previous = source
        resetStreamState()
        if !reopening { liveReopens = 0 }
        if channel?.Id != item?.Id || channel == nil { pictureIsStale = true }
        item = channel
        fullItem = nil
        source = nil
        options = StreamOptions(live: true)
        externalStream = (streamURL, channel)
        isExternal = true
        isLive = true
        autoplayCancelled = true
        upNextSettled = true
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        currentBitrate = nil
        wantedTracks = (nil, nil)
        isActive = true
        isOpening = true
        isBuffering = true
        generation &+= 1
        watchOpening(generation)
        currentStreamURL = streamURL
        engine.audioDelay = audioDelay
        engine.rate = 1
        awaitingLoad = false
        engine.load(EngineLoadRequest(
            url: streamURL, headers: ["User-Agent": prefs.iptvUserAgentHeader], live: true))
        if let previous { Task { await release(previous) } }
    }

    /// One of the sync tests from Settings → Audio: a clip in the app, looped,
    /// opened the way a video is. The clip's rate picks the delay the Sync tab
    /// over it sets.
    func playSyncTest(_ test: DelayRate) async {
        guard let url = Bundle.main.url(forResource: test.resource, withExtension: "mov") else {
            Self.log.error("\(test.resource, privacy: .public).mov is missing from the bundle")
            return
        }
        MusicPlayer.shared.yield()
        guard let engine = makeEngine() else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }
        let previous = source
        resetStreamState()
        pictureIsStale = true
        item = nil
        fullItem = nil
        source = nil
        options = StreamOptions()
        externalStream = nil
        isExternal = true
        syncTest = test
        isLive = false
        autoplayCancelled = true
        upNextSettled = true
        title = "Audio Sync · \(test.name) delay"
        subtitle = "The beep should land on the flash"
        artworkURL = nil
        currentBitrate = nil
        wantedTracks = (nil, nil)
        speed = 1
        isActive = true
        isOpening = true
        isBuffering = true
        generation &+= 1
        let mine = generation
        watchOpening(mine)
        awaitingLoad = true
        engine.stop()
        displayRequested = true
        await DisplayMatch.request(rate: test.clipRate, codec: "h264", size: CGSize(width: 1920, height: 1080))
        guard generation == mine else { return }
        await awaitSurface()
        guard generation == mine else { return }
        engine.setDisplayRefreshRate(DisplayMatch.matchedRate)
        engine.audioDelay = audioDelay
        awaitingLoad = false
        engine.load(EngineLoadRequest(url: url, startAt: 0, loop: true))
        if let previous { Task { await release(previous) } }
    }

    private func awaitSurface() async {
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while (videoView.window == nil || videoView.bounds.width < 2 || videoView.bounds.height < 2),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // MARK: - Opening and seek watchdogs

    private static let openingPatience: Duration = .seconds(45)
    private static let recoveryPoint: Duration = .seconds(15)
    private static let seekPatience: Duration = .seconds(8)

    func watchOpening(_ mine: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.recoveryPoint)
            if let self, self.generation == mine, self.isActive, self.isOpening, self.errorMessage == nil,
               self.buffered - self.position > 3 {
                Self.log.notice("stalled with \(self.buffered - self.position, format: .fixed(precision: 1))s buffered; restarting audio output")
                self.reactivateAudioSession()
                await self.engine?.rebuildAudio()
                self.engine?.seek(to: self.position)
            }
            try? await Task.sleep(for: Self.openingPatience - Self.recoveryPoint)
            guard let self, self.generation == mine, self.isActive, self.isOpening,
                  self.errorMessage == nil else { return }
            Self.log.error("no first frame after \(Self.openingPatience, privacy: .public): \(self.title, privacy: .public)")
            if self.isLive { self.reopenLive(); return }
            self.generation &+= 1
            self.engine?.stop()
            self.errorMessage = "This is taking too long to start. The server may be struggling to prepare it."
            self.isBuffering = false
            self.isOpening = false
        }
    }

    func watchSeek(to target: Double) {
        seekWatch?.cancel()
        let mine = generation
        seekWatch = Task { [weak self] in
            try? await Task.sleep(for: Self.seekPatience)
            guard !Task.isCancelled, let self, self.generation == mine, self.isActive,
                  !self.isOpening, self.errorMessage == nil, self.buffered - target > 3 else { return }
            self.seekWatch = nil
            Self.log.notice("seek to \(target, format: .fixed(precision: 1)) stalled with \(self.buffered - target, format: .fixed(precision: 1))s buffered; restarting audio output")
            self.reactivateAudioSession()
            await self.engine?.rebuildAudio()
            self.engine?.seek(to: target)
        }
    }

    // MARK: - Live

    var currentChannel: BaseItem? {
        guard isLive else { return nil }
        return externalStream?.channel ?? item
    }

    var channelLineup: [BaseItem] { LiveTVStore.shared.channels }

    func switchChannel(by offset: Int) {
        let lineup = channelLineup
        guard let current = currentChannel, !lineup.isEmpty,
              let index = lineup.firstIndex(where: { $0.Id == current.Id }) else { return }
        let next = lineup[((index + offset) % lineup.count + lineup.count) % lineup.count]
        playChannel(next)
    }

    func playChannel(_ channel: BaseItem) {
        guard channel.Id != currentChannel?.Id else { return }
        if let raw = channel.ExternalStreamURL, let url = URL(string: raw) {
            playExternal(
                title: channel.title,
                subtitle: channel.ChannelNumber.map { "Channel \($0)" } ?? "",
                artworkURL: Artwork.channelLogo(channel, width: 600),
                streamURL: url, channel: channel)
        } else {
            Task { await play(item: channel, options: StreamOptions(resume: false, live: true)) }
        }
    }

    func reopenLive() {
        if Date().timeIntervalSince(liveReopensSince) > 60 {
            liveReopens = 0
            liveReopensSince = Date()
        }
        liveReopens += 1
        guard liveReopens <= 3 else {
            errorMessage = "The channel stopped and didn't come back."
            isBuffering = false
            return
        }
        Self.log.notice("reopening live stream (\(self.liveReopens))")
        if let external = externalStream {
            playExternal(title: title, subtitle: subtitle, artworkURL: artworkURL,
                         streamURL: external.url, channel: external.channel, reopening: true)
        } else if let item {
            Task { await play(item: item, options: options, meta: StartMeta(reopening: true)) }
        }
    }

    func resetLiveRecovery() {
        liveReopens = 0
        liveReopensSince = .distantPast
    }

    // MARK: - Quality

    func switchQuality(to bitrate: Int?, meta: StartMeta = .init()) async {
        guard let item, !isExternal, !isLive || bitrate != currentBitrate else { return }
        var opts = options
        opts.maxBitrate = bitrate
        opts.bitrateIsChosen = true
        opts.forceTranscode = false
        opts.startSeconds = isLive ? nil : position
        await play(item: item, options: opts, meta: meta.inherited ? meta : StartMeta(inherited: true))
    }

    // MARK: - Resume point

    func startSeconds(for item: BaseItem, options opts: StreamOptions) -> Double {
        if let explicit = opts.startSeconds { return explicit.isFinite ? min(max(0, explicit), 30 * 86_400) : 0 }
        guard opts.resume, prefs.resumePlayback else { return 0 }
        let ticks = item.userData.positionTicks
        guard ticks > 0, let total = item.RunTimeTicks, total > 0 else { return 0 }
        let f = Double(ticks) / Double(total)
        return f > 0.92 ? 0 : Double(ticks) / 10_000_000
    }

    // MARK: - What is playing, in a line

    var streamSummary: [String] {
        var parts: [String] = []
        parts.append(isExternal ? "Direct stream" : isTranscoding ? "Transcoding" : "Direct play")
        let streams = source?.mediaSource
        if let container = streams?.Container?.split(separator: ",").first {
            parts.append(container.uppercased())
        }
        if let video = streams?.streams.first(where: { $0.type == "Video" }) {
            var picture = [String]()
            if let height = video.Height ?? (videoSize.height > 0 ? Int(videoSize.height) : nil) {
                picture.append(height >= 2000 ? "4K" : "\(height)p")
            }
            if let codec = video.Codec { picture.append(codec.uppercased()) }
            if let rate = video.RealFrameRate ?? video.AverageFrameRate ?? frameRate, rate > 0 {
                picture.append(Self.frameRateName(rate))
            }
            if let range = video.VideoRange, range != "SDR" { picture.append(range) }
            if !picture.isEmpty { parts.append(picture.joined(separator: " ")) }
        } else if videoSize.height > 0 {
            var picture = ["\(Int(videoSize.height))p"]
            if let frameRate { picture.append(Self.frameRateName(frameRate)) }
            parts.append(picture.joined(separator: " "))
        }
        if isActive {
            let latency = AVAudioSession.sharedInstance().outputLatency
            if latency > 0 { parts.append("Audio latency \(Int((latency * 1000).rounded())) ms") }
        }
        if let matched = DisplayMatch.matchedRate {
            parts.append("Display \(Self.frameRateName(matched, unit: "Hz"))")
        }
        if let audio = tracks.first(where: { $0.kind == .audio && $0.isSelected }) {
            var sound = [audio.codec?.uppercased() ?? "Audio"]
            if let channels = audio.channels {
                sound.append(channels == 8 ? "7.1" : channels == 6 ? "5.1" : channels == 2 ? "Stereo" : "\(channels) ch")
            }
            parts.append(sound.joined(separator: " "))
        }
        if let decoder {
            parts.append(decoder == "no" ? "Software decoding" : "Hardware decoding")
        }
        return parts
    }
}

#endif
