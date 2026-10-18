//  Starting, reopening and recovering streams, on every platform and either
//  engine. Lifted from the old AVPlayer `PlayerModel` with the AVFoundation
//  mechanics moved behind the engine — where it used to install an
//  `AVPlayerItem` and hang observers off it, it now builds an
//  `EngineLoadRequest` and lets the engine do that and report back — and with
//  what the old Apple TV model did on top folded in: the display asked to
//  match the film's frame rate before the file opens, the opening and seek
//  watchdogs that restart a stalled audio output, the sync clips, and the
//  black cover over the last title's final frame while the next one opens.
//  What differs by engine is asked of `capabilities`; what differs by
//  platform is the display, which only the Apple TV can switch.

import Foundation
import OSLog
import QuartzCore

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
        live: Bool = false, loop: Bool = false, hints: [EngineTrackHint] = [], prepared: (any PreparedStream)? = nil
    ) {
        currentStreamURL = url
        lastVariantBitrate = nil
        engine?.audioDelay = appliedAudioDelay
        #if os(tvOS)
        engine?.setDisplayRefreshRate(DisplayMatch.matchedRate)
        #endif
        var request = EngineLoadRequest(url: url, headers: headers, startAt: startAt, paused: paused, live: live)
        request.loop = loop
        request.hints = hints
        request.prepared = prepared
        awaitingLoad = false
        engine?.load(request)
        // Every stream begins the way it was asked for. The engine only
        // reports a change of its pause flag, and mpv's doesn't change when
        // a file replaces one that was playing — while the model's did, when
        // the outgoing stream was quiesced.
        isPaused = paused
        isOpening = true
        if live { armLiveWatchdog() }
        watchOpening(generation)
    }

    /// The last title's final frame is still on the layer: covered until
    /// this one's first frame, and the engine told to stop rather than left
    /// playing it (with its sound) while the server builds the replacement.
    /// Only for a different title — the same one reopened for a track or a
    /// quality plays on until the new file is in — and only on an engine
    /// that would otherwise play on; AVPlayer is quiesced with its last
    /// frame left under the loading card, as it always was.
    private func coverOutgoingPicture(forNewTitle newTitle: Bool) {
        guard newTitle, engine?.capabilities.contains(.playsOnWhileReloading) == true else { return }
        engine?.stop()
        pictureIsStale = true
    }

    /// Ask the television to switch to the film's frame rate before the file
    /// opens: a switch blanks the set for a second or two, better spent
    /// before the first frame than over it. Nothing off the Apple TV.
    private func matchDisplay(to source: MediaSource?) async {
        #if os(tvOS)
        guard let video = source?.streams.first(where: { $0.type == "Video" }),
              let rate = video.RealFrameRate ?? video.AverageFrameRate else { return }
        displayRequested = true
        await DisplayMatch.request(
            rate: rate, codec: video.Codec,
            size: CGSize(width: video.Width ?? 0, height: video.Height ?? 0))
        #endif
    }

    // MARK: - Starting playback

    func play(item: BaseItem, options: StreamOptions = .init(), meta: StartMeta = .init()) async {
        #if !os(tvOS)
        // A copy on this device is played in preference to the server.
        if let record = downloadToPlay(for: item, options: options, meta: meta) {
            let start: Double = {
                if let explicit = options.startSeconds { return explicit.isFinite ? max(0, explicit) : 0 }
                return options.resume && prefs.resumePlayback ? record.resumeSeconds : 0
            }()
            playLocal(record, startAt: start)
            return
        }
        #endif

        // An engine the viewer asked for was asked for on the title before.
        if self.item?.Id != item.Id {
            engineOverride = nil
            returnsToMPV = false
        }

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

        // Which engine, before the server is asked: the device profile is the
        // engine's. A change of engine is a plain reopen — the old picture
        // cannot be left up while the other engine's stream is built.
        let kind = chooseEngine(for: item, options: opts)
        let sameEngine = engine?.kind == kind

        // Whether there is a picture on screen right now, of this very title,
        // worth leaving there while its replacement is built.
        let streamIsPlaying = sameEngine && isActive && !isOpening && !isBuffering
            && errorMessage == nil && !isLocal && !isExternal && !isLive
            && engine?.transport == .playing
            && self.item?.Id == item.Id && !options.live

        guard let engine = makeEngine(kind) else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }

        MusicPlayer.shared.yield()
        shuffleSeries = nil
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel()
        bitrateNotice = nil

        let startSeconds = startSeconds(for: item, options: opts)

        let canHandOver = streamIsPlaying
            && startSeconds > 1 && duration > 0
            && startSeconds + Self.handoverLead < duration - 30

        if !canHandOver {
            quiesceOutgoingStream()
            coverOutgoingPicture(forNewTitle: self.item?.Id != item.Id)
            // Whatever the engine says between now and the load is about the
            // file before, and would be taken for the new one's first frame.
            awaitingLoad = true
        }

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
        self.upcoming = []
        self.upNextChecked = false
        self.upNextSettled = false
        self.prefetchAttempted = false
        self.title = Self.displayTitle(item)
        self.subtitle = item.isEpisode ? (item.SeriesName ?? "") : Format.itemSubtitle(item)
        self.artworkURL = Artwork.url(item, type: "Primary", width: 600)
        self.currentBitrate = opts.maxBitrate
        self.isActive = true
        #if !os(tvOS)
        if opts.live {
            PlaybackHandoff.shared.end()
        } else {
            PlaybackHandoff.shared.begin(item: item, position: startSeconds)
        }
        #endif
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
        #if !os(tvOS)
        SharePlayCoordinator.shared.playerStarted(item)
        #endif

        do {
            let src: PlaybackSource
            var prepared: (any PreparedStream)?
            if let ready = takePrefetched(for: item, options: opts, startTicks: requestedTicks, inherited: meta.inherited, engine: kind) {
                src = ready.source
                prepared = ready.prepared
            } else {
                src = try await client.resolvePlayback(
                    itemId: item.Id, maxBitrate: opts.maxBitrate,
                    forceTranscode: opts.forceTranscode || opts.forceFullEncode || opts.maxBitrate != nil,
                    live: opts.live, startTicks: requestedTicks, fullEncode: opts.forceFullEncode,
                    audioStreamIndex: opts.audioStreamIndex, subtitleStreamIndex: opts.subtitleStreamIndex,
                    engine: kind
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
            if !canHandOver {
                await matchDisplay(to: src.mediaSource)
                guard generation == mine else {
                    prepared?.cancel()
                    await release(src)
                    return
                }
            }
            self.isBuffering = true
            self.source = src
            self.isTranscoding = src.isTranscode
            Self.log.info("opening \(item.Id, privacy: .public) on \(kind.title, privacy: .public): \(src.isTranscode ? "transcode" : "original", privacy: .public), container \(src.mediaSource.Container ?? "none", privacy: .public)")

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
            awaitingLoad = false
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

    #if !os(tvOS)
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

    func playLocal(_ record: DownloadRecord, keepShuffle: Bool = false, startAt: Double? = nil, paused: Bool = false) {
        guard let url = DownloadManager.shared.mediaURL(for: record) else {
            DownloadManager.shared.markMissing(record.itemId)
            AppModel.shared.toast(
                "That download isn't on this device any more — it's in Downloads under Failed, with a Retry on it",
                tone: .error)
            return
        }
        if localRecordId != record.itemId {
            engineOverride = nil
            returnsToMPV = false
        }
        let kind = chooseEngine(forLocal: record)
        guard makeEngine(kind) != nil else { return }
        Self.log.info("opening download \(record.itemId, privacy: .public) on \(kind.title, privacy: .public): \(record.fileName, privacy: .public)")
        MusicPlayer.shared.yield()
        quiesceOutgoingStream()
        coverOutgoingPicture(forNewTitle: localRecordId != record.itemId)
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
        upcoming = []
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
        engineLoad(url: url, startAt: startAt ?? record.resumeSeconds, headers: [:], paused: paused)
        if paused { isPaused = true }
        Task { await refreshLocalUpNext(after: record) }
    }

    func endLocalSession() {
        guard let session = localSession else { return }
        localSession = nil
        Task { await OfflineProgress.end(session) }
    }
    #else
    func endLocalSession() {}
    #endif

    // MARK: - IPTV channels

    func playExternal(
        title: String, subtitle: String, artworkURL: URL?, streamURL: URL,
        channel: BaseItem? = nil, reopening: Bool = false, startAt: Double = 0, paused: Bool = false
    ) {
        if externalChannel?.streamURL != streamURL {
            engineOverride = nil
            returnsToMPV = false
        }
        let kind = chooseEngine(forExternal: streamURL)
        guard makeEngine(kind) != nil else { return }
        Self.log.info("opening external stream on \(kind.title, privacy: .public): \(streamURL.lastPathComponent, privacy: .public)")
        MusicPlayer.shared.yield()
        quiesceOutgoingStream()
        coverOutgoingPicture(forNewTitle: externalChannel?.streamURL != streamURL)
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
        upcoming = []
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
            engineLoad(url: known, startAt: startAt, headers: Self.externalHeaders(), paused: paused, live: true)
            if paused { isPaused = true }
            return
        }
        // A file by its extension — the debug URL, a playlist entry that is a
        // file — is opened as it is: the resolver walks HLS redirects, and
        // mpv reads anything it is handed.
        if kind == .mpv {
            engineLoad(url: streamURL, startAt: startAt, headers: Self.externalHeaders(), paused: paused, live: true)
            if paused { isPaused = true }
            return
        }
        externalResolve = Task { [weak self] in
            let resolved = await StreamResolver.resolve(streamURL)
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.externalResolve = nil
            guard !resolved.isBareTransportStream else {
                // A transport stream on its own is the one thing a channel
                // can be that Apple's engine never opens — it reads MPEG-TS
                // inside an HLS playlist and nowhere else — so it is the one
                // live stream that needs mpv, and goes there: the policy's
                // rule for a `.ts` address, applied to an address that only
                // turned out to be one when read. Everything else live stays
                // on Apple's engine. The card is for a build or a setting
                // with no mpv to go to.
                if self.canSwitchEngine(to: .mpv) {
                    Self.log.notice("\(streamURL.lastPathComponent, privacy: .public) is a raw MPEG-TS stream; reopening on mpv")
                    self.engineOverride = .mpv
                    self.playExternal(title: title, subtitle: subtitle, artworkURL: artworkURL, streamURL: streamURL,
                                      channel: channel, reopening: true, startAt: startAt, paused: paused)
                    return
                }
                self.isBuffering = false
                self.errorMessage = "This channel is being sent as a raw MPEG-TS stream, which Apple's engine can't open \u{2014} it reads transport-stream segments inside an HLS playlist, but never a transport stream on its own. Set Settings → Video → Playback engine to Automatic, which plays such a channel through mpv, or set this channel's stream mode to HLS on the server sending it."
                return
            }
            self.externalChannel?.resolvedURL = resolved.url
            self.engineLoad(url: resolved.url, startAt: startAt, headers: Self.externalHeaders(), paused: paused, live: true)
            if paused { self.isPaused = true }
        }
    }

    static func externalHeaders() -> [String: String] {
        ["User-Agent": Preferences.shared.iptvUserAgentHeader]
    }

    // MARK: - The sync test

    /// One of the sync tests from Settings → Audio: a clip in the app, looped,
    /// opened the way a video is. The clip's rate picks the delay the Sync tab
    /// over it sets. The clips ship with the Apple TV build; elsewhere this
    /// only logs that they are missing.
    func playSyncTest(_ test: DelayRate) async {
        guard let url = Bundle.main.url(forResource: test.resource, withExtension: "mov") else {
            Self.log.error("\(test.resource, privacy: .public).mov is missing from the bundle")
            return
        }
        guard let engine = makeEngine(.mpv) else {
            errorMessage = "The player couldn't start."
            isActive = true
            return
        }
        MusicPlayer.shared.yield()
        quiesceOutgoingStream()
        releaseOutgoingServerStream()
        endLocalSession()
        shuffleSeries = nil
        engine.stop()
        pictureIsStale = true
        errorMessage = nil
        noVideoTrack = false
        noVideoDetail = nil
        bitrateNoticeDismissal?.cancel(); bitrateNotice = nil
        item = nil
        fullItem = nil
        source = nil
        options = StreamOptions()
        externalChannel = nil
        resetLiveRecovery()
        isLocal = false
        localRecordId = nil
        isExternal = true
        isLive = false
        isTranscoding = false
        syncTest = test
        autoplayCancelled = true
        tracksApplied = false
        wantedTracks = (nil, nil)
        setSelectedAudioTrack(nil)
        setSelectedSubtitleTrack(nil)
        pendingTrackChoice = nil
        transcodingForSubtitle = false
        upcoming = []
        setUpNextLocalId(nil)
        upNextChecked = true
        upNextSettled = true
        title = "Audio Sync · \(test.name) delay"
        subtitle = "The beep should land on the flash"
        artworkURL = nil
        currentBitrate = nil
        setChapters([])
        segments = []
        trickplay = nil
        speed = 1
        isActive = true
        isBuffering = true
        generation &+= 1
        let mine = generation
        awaitingLoad = true
        #if os(tvOS)
        displayRequested = true
        await DisplayMatch.request(rate: test.clipRate, codec: "h264", size: CGSize(width: 1920, height: 1080))
        guard generation == mine else { return }
        #endif
        await awaitSurface()
        guard generation == mine else { return }
        // Read before the load: `audioDelay` follows the clip's rate.
        engineLoad(url: url, startAt: 0, headers: [:], loop: true)
    }

    /// mpv wants a drawable before its first file: the player screen is
    /// presented by `isActive`, and the layer is in it a frame or two later.
    private func awaitSurface() async {
        #if canImport(Libmpv)
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while (mpvLayer.superlayer == nil || mpvLayer.bounds.width < 2 || mpvLayer.bounds.height < 2),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
        #endif
    }

    // MARK: - Opening and seek watchdogs

    /// The television renegotiating HDMI for a frame-rate switch can leave the
    /// engine's audio output stalled with the file read and waiting: an
    /// opening or a seek that shows no frame with seconds of data in hand
    /// gets the output restarted once, on an engine that offers it
    /// (`.restartsAudioOutput`). Past `openingPatience` with still no frame,
    /// the stream is given up on.
    private static let openingPatience: Duration = .seconds(45)
    private static let recoveryPoint: Duration = .seconds(15)
    private static let seekPatience: Duration = .seconds(8)

    func watchOpening(_ mine: Int) {
        guard engine?.capabilities.contains(.restartsAudioOutput) == true else { return }
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
            if self.isLive { self.reopenCurrentLive(); return }
            self.generation &+= 1
            self.engine?.stop()
            self.errorMessage = "This is taking too long to start. The server may be struggling to prepare it."
            self.isBuffering = false
            self.isOpening = false
        }
    }

    func watchSeek(to target: Double) {
        seekWatch?.cancel(); seekWatch = nil
        guard engine?.capabilities.contains(.restartsAudioOutput) == true else { return }
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
