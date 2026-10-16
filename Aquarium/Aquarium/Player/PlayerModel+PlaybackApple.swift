//  Starting, reopening and recovering streams on iPhone, iPad and Mac, where
//  the engine is AVPlayer. Lifted from the old AVPlayer `PlayerModel` with the
//  AVFoundation mechanics moved behind the engine: where it used to install an
//  `AVPlayerItem` and hang observers off it, it now builds an
//  `EngineLoadRequest` and lets `AVEngine` do that and report back.

#if !os(tvOS)

import Foundation
import OSLog

extension PlayerModel {
    /// How far ahead of the playhead a replacement stream is opened, and how
    /// long the whole hand-over may take.
    static let handoverLead: Double = 12
    /// How close to the end the next title's stream is asked for.
    static let prefetchLead: Double = 90
    static let streamRecoveryLimit = 2
    static let streamRecoverySettled: TimeInterval = 90

    private func streamHints(for source: MediaSource?) -> [EngineTrackHint] {
        guard let source else { return [] }
        return source.streams.compactMap { stream in
            guard let index = stream.Index, let type = stream.type else { return nil }
            let kind: EngineTrack.Kind
            switch type {
            case "Audio": kind = .audio
            case "Subtitle": kind = .subtitle
            default: return nil
            }
            return EngineTrackHint(
                fileIndex: index, kind: kind, title: stream.DisplayTitle, language: stream.Language,
                isForced: stream.isForced, isExternal: stream.IsExternal ?? false, isImage: stream.isImageSubtitle
            )
        }
    }

    private func engineLoad(
        url: URL, startAt: Double, headers: [String: String], paused: Bool = false,
        live: Bool = false, hints: [EngineTrackHint] = [], prepared: (any PreparedStream)? = nil
    ) {
        currentStreamURL = url
        lastVariantBitrate = nil
        engine?.audioDelay = appliedAudioDelay
        var request = EngineLoadRequest(url: url, headers: headers, startAt: startAt, paused: paused, live: live)
        request.hints = hints
        request.prepared = prepared
        engine?.load(request)
        isOpening = startAt > 1
        if live { armLiveWatchdog() }
    }

    // MARK: - Starting playback

    func play(item: BaseItem, options: StreamOptions = .init(), meta: StartMeta = .init()) async {
        // A copy on this device is played in preference to the server.
        if let record = downloadToPlay(for: item, options: options, meta: meta) {
            let start: Double = {
                if let explicit = options.startSeconds { return explicit.isFinite ? max(0, explicit) : 0 }
                return options.resume && prefs.resumePlayback ? record.resumeSeconds : 0
            }()
            playLocal(record, startAt: start)
            return
        }
        guard let engine = makeEngine() else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }

        // Whether there is a picture on screen right now, of this very title,
        // worth leaving there while its replacement is built.
        let streamIsPlaying = isActive && !isOpening && !isBuffering
            && errorMessage == nil && !isLocal && !isExternal && !isLive
            && engine.transport == .playing
            && self.item?.Id == item.Id && !options.live

        MusicPlayer.shared.yield()
        shuffleSeries = nil
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel()
        bitrateNotice = nil

        var opts = options
        if opts.maxBitrate == nil, !opts.bitrateIsChosen, !opts.live, prefs.defaultBitrate != nil,
           !meta.inherited {
            opts.maxBitrate = prefs.defaultBitrate
        }
        let requestedBitrate = opts.maxBitrate
        if !opts.live, let cap = powerCapBitrate, Quality.rungIndex(opts.maxBitrate) < Quality.rungIndex(cap) {
            opts.maxBitrate = cap
        }

        if !opts.live, let source = item.MediaSources?.first, !source.streams.isEmpty,
           self.item?.Id != item.Id || (opts.audioStreamIndex == nil && opts.subtitleStreamIndex == nil) {
            let wanted = preferredStreams(in: source, seriesId: item.SeriesId)
            opts.audioStreamIndex = wanted.audio
            opts.subtitleStreamIndex = wanted.subtitle
        }

        let startSeconds = startSeconds(for: item, options: opts)

        let canHandOver = streamIsPlaying
            && startSeconds > 1 && duration > 0
            && startSeconds + Self.handoverLead < duration - 30

        if !canHandOver { quiesceOutgoingStream() }

        if self.item?.SeriesId != item.SeriesId { episodeQueue = nil }

        if self.item?.Id != item.Id {
            setSelectedAudioTrack(nil)
            setSelectedSubtitleTrack(nil)
            pendingTrackChoice = nil
            transcodingForSubtitle = meta.carriesSubtitleTranscode && opts.forceTranscode
        }

        let outgoingReport = source != nil && !isLocal && !isExternal ? report(paused: true) : nil

        self.item = item
        self.options = opts
        self.isLocal = false
        self.isExternal = false
        self.externalChannel = nil
        if !meta.reopening { resetLiveRecovery() }
        endLocalSession()
        self.localRecordId = nil
        self.isLive = opts.live
        self.autoplayCancelled = false
        self.tracksApplied = false
        self.wantedTracks = (opts.audioStreamIndex, opts.subtitleStreamIndex)
        self.upNext = nil
        self.upNextChecked = false
        self.upNextSettled = false
        self.prefetchAttempted = false
        self.title = Self.displayTitle(item)
        self.subtitle = item.isEpisode ? (item.SeriesName ?? "") : Format.itemSubtitle(item)
        self.artworkURL = Artwork.url(item, type: "Primary", width: 600)
        self.currentBitrate = opts.maxBitrate
        self.isActive = true
        if opts.live {
            PlaybackHandoff.shared.end()
        } else {
            PlaybackHandoff.shared.begin(item: item, position: startSeconds)
        }
        self.isBuffering = !canHandOver
        if !meta.recovering && !meta.reopening {
            streamRecoveries = 0
            lastRecoveryAt = nil
        }
        generation &+= 1
        let mine = generation
        resolvingGeneration = mine

        let handoverTarget = startSeconds + Self.handoverLead
        let requestedStart = canHandOver ? handoverTarget : startSeconds
        let requestedTicks = Int64(requestedStart * 10_000_000)
        SharePlayCoordinator.shared.playerStarted(item)

        do {
            let src: PlaybackSource
            var prepared: (any PreparedStream)?
            if let ready = takePrefetched(for: item, options: opts, startTicks: requestedTicks, inherited: meta.inherited) {
                src = ready.source
                prepared = ready.prepared
            } else {
                src = try await client.resolvePlayback(
                    itemId: item.Id, maxBitrate: opts.maxBitrate,
                    forceTranscode: opts.forceTranscode || opts.forceFullEncode || opts.maxBitrate != nil,
                    live: opts.live, startTicks: requestedTicks, fullEncode: opts.forceFullEncode,
                    audioStreamIndex: opts.audioStreamIndex, subtitleStreamIndex: opts.subtitleStreamIndex
                )
            }
            guard generation == mine else {
                prepared?.cancel()
                await release(src)
                return
            }
            resolvingGeneration = nil
            let previous = self.source
            let hints = streamHints(for: src.mediaSource)

            if canHandOver, src.isTranscode {
                awaitingLoad = false
                engine.audioDelay = appliedAudioDelay
                var request = EngineLoadRequest(
                    url: src.url, headers: client.authHeaders(for: src.url), startAt: handoverTarget)
                request.hints = hints
                if await engine.handOver(to: request, at: handoverTarget) {
                    currentStreamURL = src.url
                    self.source = src
                    self.isTranscoding = src.isTranscode
                    lastVariantBitrate = nil
                    setAudioDelayApplied(false)
                    if let previous, previous.isTranscode, previous.playSessionId != src.playSessionId {
                        await client.stopTranscode(playSessionId: previous.playSessionId)
                    }
                    await loadExtras(for: item)
                    guard generation == mine else { return }
                    await client.reportPlaybackStart(report(paused: false))
                    adaptive.begin(inherited: meta.inherited, ceiling: requestedBitrate, powerCap: powerCapBitrate)
                    return
                }
            }
            guard generation == mine else {
                prepared?.cancel()
                await release(src)
                return
            }
            self.isBuffering = true
            self.source = src
            self.isTranscoding = src.isTranscode
            Self.log.info("opening \(item.Id, privacy: .public): \(src.isTranscode ? "transcode" : "original", privacy: .public), container \(src.mediaSource.Container ?? "none", privacy: .public)")

            let resumeAt = canHandOver ? max(startSeconds, position) : startSeconds
            engineLoad(
                url: src.url, startAt: opts.live ? 0 : resumeAt,
                headers: client.authHeaders(for: src.url), live: opts.live, hints: hints, prepared: prepared)

            if let previous, previous.isTranscode, previous.playSessionId != src.playSessionId {
                await client.stopTranscode(playSessionId: previous.playSessionId)
            }
            if let stale = previous?.mediaSource.LiveStreamId, !stale.isEmpty,
               stale != src.mediaSource.LiveStreamId {
                await client.closeLiveStream(id: stale)
            }
            await loadExtras(for: item)
            guard generation == mine else { return }
            await client.reportPlaybackStart(report(paused: false))
            adaptive.begin(inherited: meta.inherited, ceiling: requestedBitrate, powerCap: powerCapBitrate)
        } catch {
            guard generation == mine else { return }
            resolvingGeneration = nil
            if canHandOver { quiesceOutgoingStream() }
            if !canHandOver, let stale = source {
                source = nil
                isTranscoding = false
                Task {
                    if let outgoingReport { await client.reportPlaybackStopped(outgoingReport) }
                    await release(stale)
                }
            }
            NowPlaying.shared.clear()
            pendingTrackChoice = nil
            Self.log.error(
                "start failed \(item.Id, privacy: .public) live=\(opts.live) reopening=\(meta.reopening): \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            isBuffering = false
            isOpening = false
        }
    }

    // MARK: - Downloads

    private func downloadToPlay(for item: BaseItem, options: StreamOptions, meta: StartMeta) -> DownloadRecord? {
        guard !options.live, !meta.recovering, !meta.reopening else { return nil }
        if isActive, !isLocal, self.item?.Id == item.Id { return nil }
        let askedForAStream = options.maxBitrate != nil || options.bitrateIsChosen
            || options.forceTranscode || options.forceFullEncode
        if askedForAStream, !meta.inherited { return nil }
        guard let record = DownloadManager.shared.record(for: item.Id), !record.isAudio,
              DownloadManager.shared.mediaURL(for: record) != nil else { return nil }
        return record
    }

    func playLocal(_ record: DownloadRecord, keepShuffle: Bool = false, startAt: Double? = nil) {
        guard let url = DownloadManager.shared.mediaURL(for: record) else {
            DownloadManager.shared.markMissing(record.itemId)
            AppModel.shared.toast(
                "That download isn't on this device any more — it's in Downloads under Failed, with a Retry on it",
                tone: .error)
            return
        }
        guard makeEngine() != nil else { return }
        MusicPlayer.shared.yield()
        quiesceOutgoingStream()
        generation &+= 1
        externalResolve?.cancel(); externalResolve = nil
        externalChannel = nil
        resetLiveRecovery()
        releaseOutgoingServerStream()
        endLocalSession()
        localSession = OfflineProgress.Session(itemId: record.itemId)
        if !keepShuffle { shuffleSeries = nil }
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel(); bitrateNotice = nil
        item = nil
        source = nil
        options = .init()
        isLocal = true
        isExternal = false
        isLive = false
        isTranscoding = false
        localRecordId = record.itemId
        autoplayCancelled = false
        tracksApplied = false
        wantedTracks = (nil, nil)
        setSelectedAudioTrack(nil)
        setSelectedSubtitleTrack(nil)
        pendingTrackChoice = nil
        transcodingForSubtitle = false
        upNext = nil
        setUpNextLocalId(nil)
        upNextChecked = false
        upNextSettled = false
        title = record.title
        subtitle = record.series ?? ""
        artworkURL = (record.seriesArtURL ?? record.artURL).flatMap(URL.init(string:))
        currentBitrate = nil
        setChapters([])
        segments = []
        trickplay = nil
        fullItem = nil
        isActive = true
        isBuffering = true
        engineLoad(url: url, startAt: startAt ?? record.resumeSeconds, headers: [:])
        Task { await refreshLocalUpNext(after: record) }
    }

    func endLocalSession() {
        guard let session = localSession else { return }
        localSession = nil
        Task { await OfflineProgress.end(session) }
    }

    // MARK: - IPTV channels

    func playExternal(
        title: String, subtitle: String, artworkURL: URL?, streamURL: URL,
        channel: BaseItem? = nil, reopening: Bool = false
    ) {
        guard makeEngine() != nil else { return }
        MusicPlayer.shared.yield()
        quiesceOutgoingStream()
        releaseOutgoingServerStream()
        endLocalSession()
        shuffleSeries = nil
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel(); bitrateNotice = nil
        item = nil
        source = nil
        options = StreamOptions(live: true)
        let carriedResolution = reopening && externalChannel?.streamURL == streamURL
            ? externalChannel?.resolvedURL : nil
        externalChannel = ExternalChannel(
            title: title, subtitle: subtitle, artworkURL: artworkURL, streamURL: streamURL,
            item: channel, resolvedURL: carriedResolution)
        if !reopening { resetLiveRecovery() }
        isLocal = false
        localRecordId = nil
        isLive = true
        isExternal = true
        autoplayCancelled = true
        tracksApplied = false
        wantedTracks = (nil, nil)
        setSelectedAudioTrack(nil)
        setSelectedSubtitleTrack(nil)
        pendingTrackChoice = nil
        transcodingForSubtitle = false
        upNext = nil
        setUpNextLocalId(nil)
        upNextChecked = true
        upNextSettled = true
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        currentBitrate = nil
        setChapters([])
        segments = []
        trickplay = nil
        fullItem = nil
        isActive = true
        isBuffering = true
        generation &+= 1
        let mine = generation
        externalResolve?.cancel(); externalResolve = nil
        if let known = carriedResolution {
            engineLoad(url: known, startAt: 0, headers: Self.externalHeaders(), live: true)
            return
        }
        externalResolve = Task { [weak self] in
            let resolved = await StreamResolver.resolve(streamURL)
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.externalResolve = nil
            guard !resolved.isBareTransportStream else {
                self.isBuffering = false
                self.errorMessage = "This channel is being sent as a raw MPEG-TS stream, which Apple's player can't open \u{2014} it reads transport-stream segments inside an HLS playlist, but never a transport stream on its own. Set this channel's stream mode to HLS on the server sending it."
                return
            }
            self.externalChannel?.resolvedURL = resolved.url
            self.engineLoad(url: resolved.url, startAt: 0, headers: Self.externalHeaders(), live: true)
        }
    }

    static func externalHeaders() -> [String: String] {
        ["User-Agent": Preferences.shared.iptvUserAgentHeader]
    }

    // MARK: - Quiescing

    func quiesceOutgoingStream() {
        engine?.quiesce()
        isPaused = true
        isOpening = false
    }

    func releaseOutgoingServerStream() {
        dropPrefetched()
        guard let outgoing = source else { return }
        let closing = report(paused: true)
        source = nil
        Task {
            await client.reportPlaybackStopped(closing)
            await release(outgoing)
        }
    }

    // MARK: - Quality

    func switchQuality(to bitrate: Int?, meta: StartMeta = .init()) async {
        guard let item, !isLocal else { return }
        var opts = options
        opts.maxBitrate = bitrate
        opts.bitrateIsChosen = true
        opts.forceTranscode = false
        opts.forceFullEncode = false
        opts.startSeconds = isLive ? nil : position
        await play(item: item, options: opts, meta: meta)
    }

    func maybeAdapt() {
        guard prefs.adaptiveQuality, !isLocal, !isExternal, isActive else { return }
        guard let decision = adaptive.decide(currentBitrate: currentBitrate) else { return }
        guard decision.bitrate != currentBitrate else {
            AppModel.shared.toast(decision.message, tone: .error)
            return
        }
        showBitrateNotice(BitrateNotice(
            isUp: !decision.isDrop,
            headline: decision.bitrate == nil ? "Original quality" : Quality.label(for: decision.bitrate),
            detail: decision.reason))
        Task { await switchQuality(to: decision.bitrate, meta: StartMeta(inherited: true, quiet: true)) }
    }

    // MARK: - Recovery

    func recoverFromStreamFailure() -> Bool {
        guard let item, isActive, !isLive, !isLocal else { return false }
        guard streamRecoveries < Self.streamRecoveryLimit else { return false }
        streamRecoveries += 1
        lastRecoveryAt = Date()
        let resume = isOpening ? position : position
        isOpening = false
        isBuffering = true
        var opts = options
        opts.startSeconds = max(0, resume)
        Task { await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true, recovering: true)) }
        return true
    }

    @discardableResult
    func escalateToTranscode() -> Bool {
        guard let item, isActive, !isLocal, !isExternal, !isLive else { return false }
        guard let source, !source.isTranscode else { return false }
        guard !options.forceTranscode else { return false }
        let streams = source.mediaSource.streams
        if !streams.isEmpty, !streams.contains(where: { $0.type == "Video" }) { return false }
        let resume = position
        isOpening = false
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        isBuffering = true
        var opts = options
        opts.forceTranscode = true
        opts.startSeconds = max(0, resume)
        Task { await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true, recovering: true)) }
        return true
    }

    func canReencodeForSyncValue() -> Bool {
        isActive && isTranscoding && !isLocal && !isExternal && item != nil
    }

    func reencodeForSync() async {
        guard canReencodeForSyncValue(), let item else { return }
        var opts = options
        opts.forceTranscode = true
        opts.forceFullEncode = true
        opts.startSeconds = isLive ? nil : position
        AppModel.shared.toast("Asking the server to re-encode this stream…")
        await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true))
    }

    func diagnoseExternalStream() {
        guard isExternal, noVideoDetail == nil, noVideoTrack || errorMessage != nil,
              let url = currentStreamURL else { return }
        diagnosis?.cancel()
        diagnosis = Task { [weak self] in
            let finding = await StreamDiagnosis.inspect(hlsURL: url)
            guard !Task.isCancelled, let self, let finding, self.isExternal, self.currentStreamURL == url else { return }
            self.noVideoDetail = finding.message
            if finding.videoWillNotPlay { self.noVideoTrack = true }
        }
    }

    // MARK: - Live stall recovery

    static let liveStallLimit: TimeInterval = 28
    static let liveOpenLimit: TimeInterval = 60
    static let liveReopenLimit = 3
    static let liveRecoveryWindow: TimeInterval = 60
    static let liveEdgeGrace: TimeInterval = 10

    func armLiveWatchdog() {
        liveWatchdog?.cancel()
        isReopeningLive = false
        guard isLive, isActive else { liveWatchdog = nil; return }
        lastAdvance = (Date(), -1)
        jumpedForThisStall = false
        liveWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.checkLiveProgress() else { return }
            }
        }
    }

    private func checkLiveProgress() -> Bool {
        guard isActive, isLive, errorMessage == nil else { return false }
        guard engine?.transport != .paused, !isOpening else {
            lastAdvance = (Date(), lastAdvance?.position ?? -1)
            return true
        }
        let now = engine?.clock ?? -1
        guard let last = lastAdvance else {
            lastAdvance = (Date(), now)
            return true
        }
        if now > last.position + 0.25 {
            lastAdvance = (Date(), now)
            jumpedForThisStall = false
            if liveReconnects > 0, Date().timeIntervalSince(lastReopenAt) > Self.liveRecoveryWindow {
                liveReconnects = 0
            }
            return true
        }
        let limit: TimeInterval = jumpedForThisStall
            ? Self.liveEdgeGrace
            : (last.position <= 0 ? Self.liveOpenLimit : Self.liveStallLimit)
        guard Date().timeIntervalSince(last.at) >= limit else { return true }
        isBuffering = true
        if !jumpedForThisStall, engine?.jumpToLiveEdge(margin: 4) == true {
            jumpedForThisStall = true
            lastAdvance = (Date(), last.position)
            return true
        }
        Task { await self.reopenStalledLive() }
        return false
    }

    func reopenStalledLive() async {
        guard isActive, isLive, errorMessage == nil, !isReopeningLive else { return }
        isReopeningLive = true
        liveWatchdog?.cancel(); liveWatchdog = nil
        liveReconnects += 1
        lastReopenAt = Date()
        Self.log.notice("reopening live stream, attempt \(self.liveReconnects) of \(Self.liveReopenLimit)")
        guard liveReconnects <= Self.liveReopenLimit else {
            isReopeningLive = false
            isBuffering = false
            errorMessage = "This channel stopped sending data. Reopening it "
                + "\(Self.liveReopenLimit) times didn't bring it back — the server "
                + "sending the channel is the thing that has stopped."
            return
        }
        isBuffering = true
        engine?.stop()
        let mine = generation
        if let held = source {
            source = nil
            await release(held)
        }
        try? await Task.sleep(for: .seconds(0.6 * Double(liveReconnects)))
        guard generation == mine else { return }
        guard isActive, isLive, isReopeningLive else { isReopeningLive = false; return }
        if let channel = externalChannel {
            playExternal(
                title: channel.title, subtitle: channel.subtitle, artworkURL: channel.artworkURL,
                streamURL: channel.streamURL, channel: channel.item, reopening: true)
        } else if let item {
            await play(item: item, options: options, meta: StartMeta(reopening: true))
        }
    }

    func resetLiveRecovery() {
        liveWatchdog?.cancel(); liveWatchdog = nil
        isReopeningLive = false
        lastAdvance = nil
        liveReconnects = 0
        lastReopenAt = .distantPast
        jumpedForThisStall = false
        jumpedToEdgeAt = .distantPast
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
}

#endif
