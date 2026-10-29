//  The rest of the Jellyfin side: what is fetched alongside a stream, Up Next
//  and autoplay, the queue and the download shuffle, the sleep timer, progress
//  reports, the bitrate notice, the next stream ahead of time, and the
//  resync and re-encode repairs.

import Foundation
import OSLog

extension PlayerModel {
    // MARK: - Per-item extras

    func loadExtras(for item: BaseItem) async {
        segments = []
        trickplay = nil
        setChapters([])
        fullItem = nil
        let itemId = item.Id
        let needsDetail = item.Overview?.isEmpty != false
            || item.People?.isEmpty != false
            || item.MediaSources?.isEmpty != false
        async let segmentsTask = client.mediaSegments(itemId: itemId)
        async let detailTask = needsDetail ? try? client.item(itemId) : nil
        let loadedSegments = (try? await segmentsTask) ?? []
        let loadedDetail = await detailTask ?? nil
        guard self.item?.Id == itemId else { return }
        segments = loadedSegments
        trickplay = JellyfinClient.trickplayInfo(for: loadedDetail ?? item)
        fullItem = loadedDetail
        await refreshUpNext()
    }

    // MARK: - Up Next and autoplay

    func cancelAutoplay() { autoplayCancelled = true }
    func resumeAutoplay() { autoplayCancelled = false }

    func upNextIsDue() -> Bool {
        guard !autoplayCancelled, prefs.autoplayNext, duration > 0 else { return false }
        let hasNext = upNext != nil || upNextLocalId != nil || !queue.isEmpty
        return hasNext && secondsRemaining <= 25 && secondsRemaining > 0
    }

    var upNextTitle: String? {
        if let queued = queue.first { return Self.displayTitle(queued) }
        if let upNext { return Self.displayTitle(upNext) }
        #if !os(tvOS)
        if let upNextLocalId, let record = DownloadManager.shared.record(for: upNextLocalId) {
            return record.title
        }
        #endif
        return nil
    }

    func refreshUpNext() async {
        guard let item, item.isEpisode, let seriesId = item.SeriesId else { return }
        let found = await lookUpNextEpisodes(after: item.Id, seasonId: item.SeasonId, seriesId: seriesId)
        guard self.item?.Id == item.Id else { return }
        if found.settled {
            upNextChecked = true
            upNextSettled = true
        }
        if !found.list.isEmpty { upcoming = found.list }
    }

    /// The episodes after this one — the rest of its season, then the next
    /// season's from its first, up to `upNextLimit` — and whether every
    /// request needed to decide them was answered: an empty list with
    /// `settled` is a series that has ended. `located` says the episode was
    /// found in its season at all — a download's record can carry a season
    /// the server has since renumbered, and an empty list is no ending then.
    private func lookUpNextEpisodes(
        after itemId: String, seasonId: String?, seriesId: String
    ) async -> (list: [BaseItem], settled: Bool, located: Bool) {
        let limit = Self.upNextLimit
        guard let episodes = try? await client.episodes(seriesId: seriesId, seasonId: seasonId) else {
            return ([], false, false)
        }
        var list: [BaseItem] = []
        let index = episodes.firstIndex(where: { $0.Id == itemId })
        if let i = index {
            list = Array(episodes.dropFirst(i + 1).prefix(limit))
        }
        let located = index != nil
        if list.count >= limit { return (list, true, located) }
        guard let seasons = try? await client.seasons(seriesId: seriesId) else { return (list, false, located) }
        guard let si = seasons.firstIndex(where: { $0.Id == seasonId }) else { return (list, true, located) }
        // Season by season until the list is full or the series runs out.
        for season in seasons.dropFirst(si + 1) {
            guard let more = try? await client.episodes(seriesId: seriesId, seasonId: season.Id) else {
                return (list, false, located)
            }
            list.append(contentsOf: more.prefix(limit - list.count))
            if list.count >= limit { break }
        }
        return (list, true, located)
    }

    /// Play one of the titles the Up Next list offers now, from wherever
    /// this one is: a jump, so this episode isn't marked finished.
    func playUpcoming(_ next: BaseItem) async {
        guard !isStartingNext else { return }
        isStartingNext = true
        defer { isStartingNext = false }
        var opts = options
        opts.startSeconds = nil
        opts.resume = true
        // From a download there are no stream options to carry over, so the
        // next one opens as a fresh start would, under the opening bitrate.
        // Inherited, it skipped that cap and opened at full rate on cellular.
        await play(item: next, options: opts, meta: StartMeta(
            inherited: !isLocal, quiet: true,
            carriesSubtitleTranscode: transcodingForSubtitle && opts.forceTranscode))
    }

    func playNextNow() async {
        guard !isStartingNext else { return }
        isStartingNext = true
        defer { isStartingNext = false }
        _ = await advanceToNext()
    }

    /// Returns true when something next was found and started.
    func advanceToNext() async -> Bool {
        if !queue.isEmpty {
            #if !os(tvOS)
            if isLocal, let current = localRecordId { await reportLocalFinished(current) }
            #endif
            await reportFinishedBeforeNext()
            var q = queue
            let next = q.removeFirst()
            setQueue(q)
            var opts = options
            opts.startSeconds = nil
            opts.resume = true
            await play(item: next, options: opts, meta: StartMeta(
                inherited: true, quiet: true,
                carriesSubtitleTranscode: transcodingForSubtitle && opts.forceTranscode))
            return true
        }
        #if !os(tvOS)
        if isLocal, let current = localRecordId {
            if isShuffling {
                guard let next = nextShuffled(after: current) else { return false }
                await reportLocalFinished(current)
                playLocal(next, keepShuffle: true)
                return true
            }
            // Online, the server's next episode wins over the next one that
            // happens to be downloaded: with E1 and E3 on the device, E1 is
            // followed by E2 streamed, not by E3. Playing it as a server item
            // still opens the local copy when there is a complete one.
            if upcoming.isEmpty, !upNextSettled, !JellyfinClient.shared.isOffline,
               let record = DownloadManager.shared.record(for: current), let seriesId = record.seriesId {
                let found = await lookUpNextEpisodes(after: current, seasonId: record.seasonId, seriesId: seriesId)
                guard isLocal, localRecordId == current else { return true }
                if !found.list.isEmpty {
                    upcoming = found.list
                } else if found.settled, found.located {
                    upNextSettled = true
                }
            }
            if let next = upNext {
                await reportLocalFinished(current)
                // Not inherited, for the reason given in `playUpcoming`.
                await play(item: next, options: .init(), meta: StartMeta(inherited: false, quiet: true))
                return true
            }
            // Offline, or the server couldn't be asked: the next download
            // whose file is really there. One that has gone would only toast
            // and leave the player on the episode that ended, so it is passed
            // over rather than committed to.
            if !upNextSettled, let record = nextPlayableDownload(after: current) {
                await reportLocalFinished(current)
                playLocal(record, keepShuffle: true)
                return true
            }
            return false
        }
        #endif
        var candidate = upNext
        if candidate == nil, !upNextSettled, let item, item.isEpisode, let seriesId = item.SeriesId {
            candidate = await lookUpNextEpisodes(after: item.Id, seasonId: item.SeasonId, seriesId: seriesId).list.first
        }
        guard let next = candidate else { return false }
        await reportFinishedBeforeNext()
        var opts = options
        opts.startSeconds = nil
        opts.resume = true
        // From a download there are no stream options to carry over, so the
        // next one opens as a fresh start would, under the opening bitrate.
        // Inherited, it skipped that cap and opened at full rate on cellular.
        await play(item: next, options: opts, meta: StartMeta(
            inherited: !isLocal, quiet: true,
            carriesSubtitleTranscode: transcodingForSubtitle && opts.forceTranscode))
        return true
    }

    /// The episode that ended is reported finished before the next starts,
    /// so the server marks it played rather than left at its last tick.
    /// Lifted from the Apple TV model.
    private func reportFinishedBeforeNext() async {
        guard item != nil, !isExternal, !isLocal, source != nil, duration > 0 else { return }
        await client.reportPlaybackStopped(report(paused: true, position: duration))
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let seconds = Double(max(1, minutes)) * 60
        let deadline = Date().addingTimeInterval(seconds)
        sleepDeadline = deadline
        Self.log.notice("sleep timer set: \(minutes) min")
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.sleepTimerElapsed(deadline)
        }
    }

    func cancelSleepTimer() {
        if sleepDeadline != nil { Self.log.notice("sleep timer cancelled") }
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
    }

    var sleepMinutesRemaining: Int? {
        guard let sleepDeadline else { return nil }
        return max(1, Int((sleepDeadline.timeIntervalSinceNow / 60).rounded(.up)))
    }

    func checkSleepDeadline() {
        guard let sleepDeadline, Date() >= sleepDeadline else { return }
        Task { await sleepTimerElapsed(sleepDeadline) }
    }

    private func sleepTimerElapsed(_ deadline: Date) async {
        guard sleepDeadline == deadline else { return }
        sleepDeadline = nil
        // Dropped rather than cancelled: cancelling this task from inside it
        // would cancel the requests `finish` awaits.
        sleepTask = nil
        cancelAutoplay()
        Self.log.notice("sleep timer elapsed; closing the player")
        await finish(userRequested: true, reason: "sleep timer")
    }

    // MARK: - Progress reporting

    /// Ten seconds, the cadence every first-class Jellyfin client uses.
    static let reportInterval: TimeInterval = 10

    func maybeReport() {
        #if !os(tvOS)
        if isActive, let localRecordId {
            guard Date().timeIntervalSince(lastReportAt) >= Self.reportInterval else { return }
            lastReportAt = Date()
            DownloadManager.shared.noteProgress(itemId: localRecordId, positionSeconds: position)
            if let localSession {
                let paused = isPaused
                Task { await OfflineProgress.push(localSession, paused: paused) }
            }
            return
        }
        #endif
        guard !isLocal else { return }
        guard isActive, !isExternal, !isOpening,
              Date().timeIntervalSince(lastReportAt) >= Self.reportInterval else { return }
        lastReportAt = Date()
        Task { await client.reportPlaybackProgress(report(paused: isPaused)) }
    }

    func reportNow() async {
        guard isActive, !isExternal else { return }
        #if !os(tvOS)
        if let localRecordId {
            DownloadManager.shared.noteProgress(itemId: localRecordId, positionSeconds: position)
            if let localSession { await OfflineProgress.push(localSession, paused: isPaused) }
            return
        }
        #endif
        lastReportAt = Date()
        await client.reportPlaybackProgress(report(paused: isPaused))
    }

    func report(paused: Bool, position override: Double? = nil) -> PlaybackReport {
        let itemId = item?.Id ?? localRecordId ?? ""
        let volumeLevel = isMuted ? 0 : volume
        var report = PlaybackReport(
            itemId: itemId,
            mediaSourceId: source?.mediaSourceId,
            playSessionId: source?.playSessionId,
            positionSeconds: override ?? position,
            isPaused: paused,
            isTranscode: isTranscoding,
            rate: speed,
            volume: volumeLevel)
        report.AudioStreamIndex = options.audioStreamIndex
        report.SubtitleStreamIndex = options.subtitleStreamIndex
        return report
    }

    /// Tell Now Playing about a pause or a resume straight away.
    func postNowPlayingRate() {
        guard isActive else { return }
        let rate = isPaused ? 0 : speed
        nowPlayingAnchor = (position, rate, Date(), duration)
        NowPlaying.shared.updateElapsed(position, rate: rate)
    }

    /// Now Playing runs its own clock forward; it is only re-anchored when
    /// that clock would otherwise be wrong.
    func refreshNowPlayingAnchor() {
        let rate = isPaused ? 0 : speed
        let now = Date()
        let isStale: Bool = {
            guard let anchor = nowPlayingAnchor else { return true }
            if anchor.rate != rate { return true }
            let expected = anchor.position + anchor.rate * now.timeIntervalSince(anchor.at)
            if abs(expected - position) > 1.5 { return true }
            return abs(anchor.duration - duration) > 5
        }()
        if isStale {
            nowPlayingAnchor = (position, rate, now, duration)
            NowPlaying.shared.updateElapsed(position, rate: rate)
        }
    }

    // MARK: - Bitrate notice

    func showBitrateNotice(_ notice: BitrateNotice) {
        Self.log.notice("bitrate \(notice.isUp ? "up" : "down", privacy: .public): \(notice.headline, privacy: .public) (\(notice.detail, privacy: .public))")
        setBitrateNotice(notice)
        bitrateNoticeDismissal?.cancel()
        bitrateNoticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.bitrateNotice?.id == notice.id else { return }
            self?.setBitrateNotice(nil)
        }
    }

    // MARK: - The queue

    func queueNext(_ items: [BaseItem]) {
        let fresh = items.filter { !$0.isFolderLike }
        guard !fresh.isEmpty else { return }
        var q = queue
        q.removeAll { queued in fresh.contains { $0.Id == queued.Id } }
        q.insert(contentsOf: fresh, at: 0)
        setQueue(q)
        startQueueIfIdle()
    }

    func queueLater(_ items: [BaseItem]) {
        let fresh = items.filter { !$0.isFolderLike }
        guard !fresh.isEmpty else { return }
        var q = queue
        q.removeAll { queued in fresh.contains { $0.Id == queued.Id } }
        q.append(contentsOf: fresh)
        setQueue(q)
        startQueueIfIdle()
    }

    func removeFromQueue(_ id: String) {
        var q = queue
        q.removeAll { $0.Id == id }
        setQueue(q)
    }

    func clearQueue() { setQueue([]) }

    func playQueued(_ id: String) async {
        guard let i = queue.firstIndex(where: { $0.Id == id }) else { return }
        var q = queue
        let next = q[i]
        q.removeFirst(i + 1)
        setQueue(q)
        await play(item: next)
    }

    private func startQueueIfIdle() {
        guard !isActive, !queue.isEmpty else { return }
        var q = queue
        let first = q.removeFirst()
        setQueue(q)
        Task { await play(item: first) }
    }

    // MARK: - The next stream, ahead of time

    func prefetchNext(_ next: BaseItem) async {
        guard prefetched == nil, let current = item else { return }
        let mine = generation
        var opts = options
        opts.startSeconds = nil
        opts.resume = true
        #if !os(tvOS)
        if DownloadManager.shared.record(for: next.Id).map({ !$0.isAudio && DownloadManager.shared.mediaURL(for: $0) != nil }) == true,
           !(opts.maxBitrate != nil || opts.bitrateIsChosen || opts.forceTranscode || opts.forceFullEncode) {
            return
        }
        #endif
        if let source = next.MediaSources?.first, !source.streams.isEmpty {
            let wanted = preferredStreams(in: source, seriesId: next.SeriesId)
            opts.audioStreamIndex = wanted.audio
            opts.subtitleStreamIndex = wanted.subtitle
        }
        let startTicks = Int64(startSeconds(for: next, options: opts) * 10_000_000)
        let forced = opts.forceTranscode || opts.forceFullEncode || opts.maxBitrate != nil
        // The next title may call for the other engine (a PGS track where
        // this one had none); the stream is asked for with that engine's
        // profile, and only taken if it is still the engine wanted.
        let kind = chooseEngine(for: next, options: opts)
        guard let src = try? await client.resolvePlayback(
            itemId: next.Id, maxBitrate: opts.maxBitrate, forceTranscode: forced, live: false,
            startTicks: startTicks, fullEncode: opts.forceFullEncode,
            audioStreamIndex: opts.audioStreamIndex, subtitleStreamIndex: opts.subtitleStreamIndex,
            engine: kind
        ) else { return }
        guard generation == mine, item?.Id == current.Id, prefetched == nil, isActive else {
            await release(src)
            return
        }
        let prepared = kind == engine?.kind ? engine?.prepare(url: src.url, headers: client.authHeaders(for: src.url)) : nil
        prefetched = PrefetchedNext(
            itemId: next.Id, source: src, prepared: prepared,
            maxBitrate: opts.maxBitrate, forceTranscode: forced,
            audioStreamIndex: opts.audioStreamIndex, subtitleStreamIndex: opts.subtitleStreamIndex,
            startTicks: startTicks, engine: kind)
        Self.log.info("prefetched next \(next.Id, privacy: .public) transcode=\(src.isTranscode) engine=\(kind.title, privacy: .public)")
    }

    func takePrefetched(
        for item: BaseItem, options opts: StreamOptions, startTicks: Int64, inherited: Bool,
        engine kind: PlaybackEngineKind
    ) -> PrefetchedNext? {
        guard let ready = prefetched else { return nil }
        prefetched = nil
        let forced = opts.forceTranscode || opts.forceFullEncode || opts.maxBitrate != nil
        guard inherited, !opts.live, ready.itemId == item.Id, ready.engine == kind,
              ready.maxBitrate == opts.maxBitrate, ready.forceTranscode == forced,
              ready.audioStreamIndex == opts.audioStreamIndex,
              ready.subtitleStreamIndex == opts.subtitleStreamIndex,
              ready.startTicks == startTicks
        else {
            ready.prepared?.cancel()
            Task { await release(ready.source) }
            return nil
        }
        return ready
    }

    func dropPrefetched() {
        guard let ready = prefetched else { return }
        prefetched = nil
        ready.prepared?.cancel()
        Task { await release(ready.source) }
    }

    // MARK: - Downloads: shuffle and local Up Next

    var isShuffling: Bool { shuffleSeries != nil }

    #if !os(tvOS)
    func refreshLocalUpNext(after record: DownloadRecord) async {
        guard record.isEpisode else { return }
        setUpNextLocalId(nextPlayableDownload(after: record.itemId)?.itemId)
        // With the server reachable, Up Next is the series' real next episode
        // rather than the next one on the device, so a gap in the downloads
        // isn't skipped and a lone download doesn't end the binge. Until it
        // answers, or if it can't, the downloads' own order stands.
        guard !isShuffling, !JellyfinClient.shared.isOffline, let seriesId = record.seriesId else { return }
        let found = await lookUpNextEpisodes(after: record.itemId, seasonId: record.seasonId, seriesId: seriesId)
        guard isLocal, localRecordId == record.itemId else { return }
        if !found.list.isEmpty {
            upcoming = found.list
            setUpNextLocalId(nil)
        } else if found.settled, found.located {
            // The series has ended on the server; a download sorted after
            // this one is a special, not the next episode.
            upNextChecked = true
            upNextSettled = true
            setUpNextLocalId(nil)
        }
    }

    /// The download after this one in its series whose file is on the device.
    private func nextPlayableDownload(after itemId: String) -> DownloadRecord? {
        guard let record = DownloadManager.shared.record(for: itemId), record.isEpisode else { return nil }
        let siblings = DownloadManager.shared.episodes(ofSeries: record.seriesId, seriesName: record.series)
        guard let i = siblings.firstIndex(where: { $0.itemId == itemId }) else { return nil }
        return siblings.dropFirst(i + 1).first { DownloadManager.shared.mediaURL(for: $0) != nil }
    }

    /// Shuffle over these downloads only — a season's, when that is what was
    /// asked for — rather than everything of the series on the device.
    func startShuffle(_ records: [DownloadRecord]) {
        let pool = records.filter { DownloadManager.shared.mediaURL(for: $0) != nil }
        guard let first = pool.randomElement() else {
            AppModel.shared.toast("Nothing to shuffle — no playable downloads", tone: .error)
            return
        }
        shuffleSeries = DownloadShuffleState(
            seriesId: first.seriesId, seriesName: first.series, seen: [first.itemId],
            pool: Set(pool.map(\.itemId)))
        playLocal(first, keepShuffle: true)
    }

    private func nextShuffled(after current: String) -> DownloadRecord? {
        guard var state = shuffleSeries else { return nil }
        let pool = DownloadManager.shared.episodes(ofSeries: state.seriesId, seriesName: state.seriesName)
            .filter { state.pool?.contains($0.itemId) ?? true }
            .filter { DownloadManager.shared.mediaURL(for: $0) != nil }
        guard !pool.isEmpty else { return nil }
        var choices = pool.filter { !state.seen.contains($0.itemId) }
        if choices.isEmpty {
            state.seen.removeAll()
            choices = pool.filter { $0.itemId != current }
            if choices.isEmpty { return nil }
        }
        guard let next = choices.randomElement() else { return nil }
        state.seen.insert(next.itemId)
        shuffleSeries = state
        return next
    }

    private func reportLocalFinished(_ itemId: String) async {
        DownloadManager.shared.noteProgress(itemId: itemId, positionSeconds: duration, played: true)
        if localSession?.itemId == itemId {
            endLocalSession()
        } else {
            Task { await OfflineProgress.sync() }
        }
    }
    #endif

    // MARK: - Putting the sound back on the picture's clock

    /// How far behind the playhead a resync seeks to: unambiguously a seek,
    /// short enough to read as a hiccup.
    static let resyncNudge: Double = 0.5

    var canResync: Bool { isActive && !isOpening && currentStreamURL != nil }

    /// Flush the picture and the sound and start them again together: the
    /// audio mix is rebuilt first, then an exact seek primes both renderers
    /// from a single keyframe.
    func resyncAudio() {
        guard canResync, !isResyncing, let engine else { return }
        isResyncing = true
        AppModel.shared.toast("Resyncing the audio…")
        let mine = generation
        Task {
            defer { isResyncing = false }
            await engine.rebuildAudio()
            guard isActive, generation == mine else { return }
            engine.seek(to: max(0, position - Self.resyncNudge))
        }
    }

    var canReencodeForSync: Bool { canReencodeForSyncValue() }

    // MARK: - What the stream turned out to be

    struct StreamFacts: Sendable {
        var width: Int?
        var height: Int?
        var indicatedBitrate: Double?
        var observedBitrate: Double?
        var stalls: Int?
        var droppedFrames: Int?
        var host: String?

        var resolution: String? {
            guard let width, let height else { return nil }
            return "\(width)×\(height)"
        }
    }

    var streamFacts: StreamFacts {
        let facts = engine?.streamFacts ?? EngineStreamFacts()
        return StreamFacts(
            width: facts.width, height: facts.height,
            indicatedBitrate: facts.indicatedBitrate, observedBitrate: facts.observedBitrate,
            stalls: facts.stalls, droppedFrames: facts.droppedFrames, host: currentStreamURL?.host)
    }

    #if DEBUG
    /// Launched with `-AquariumPlayURL <url>` (and, optionally,
    /// `-AquariumPlayTitle <title>`), play that URL straight away: how the
    /// player is looked at on a simulator that is signed in to no server.
    /// Played as a title rather than a channel, so the timeline and the
    /// on-demand controls are what is drawn. Debug builds only.
    func playDebugStreamIfAsked() {
        guard let string = UserDefaults.standard.string(forKey: "AquariumPlayURL"),
              let url = URL(string: string) else { return }
        let title = UserDefaults.standard.string(forKey: "AquariumPlayTitle") ?? url.lastPathComponent
        playExternal(title: title, subtitle: url.host ?? "", artworkURL: nil, streamURL: url)
        isLive = false
        options.live = false
        autoplayCancelled = false
        // `-AquariumPlayPaused YES` pauses once the stream has opened, which
        // keeps the controls on screen for a screenshot.
        if UserDefaults.standard.bool(forKey: "AquariumPlayPaused") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.pause()
            }
        }
    }
    #endif
}
