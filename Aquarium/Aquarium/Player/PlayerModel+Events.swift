//  The Jellyfin reactions to engine events. `PlayerModel.handle` turns the
//  engine's one event stream into these, which is where the player's own
//  behaviour — Up Next, prefetch, adaptive quality, the lock-screen clock,
//  reaching the end, a stream failing — actually lives. Split from the core so
//  that file stays the state and the plumbing.

import Foundation
import OSLog

extension PlayerModel {
    /// Everything a position tick drives beyond the clock itself.
    func onPositionTick(_ seconds: Double) {
        #if !os(tvOS)
        if isActive { PlaybackHandoff.shared.update(position: position) }
        #endif

        // The Up Next card appears over the closing stretch rather than at the
        // very end — by the time the file runs out the decision is already made.
        if upNext == nil, upNextLocalId == nil, !upNextChecked, duration > 0, duration - seconds < 90 {
            upNextChecked = true
            Task { await refreshUpNext() }
        }

        // The next title's stream, ahead of time.
        if !prefetchAttempted, prefetched == nil, !isLocal, !isLive, !isExternal,
           prefs.autoplayNext, !autoplayCancelled, duration > 0, duration - seconds < Self.prefetchLead,
           let next = queue.first ?? upNext {
            prefetchAttempted = true
            Task { await prefetchNext(next) }
        }

        // Adaptive quality, and the lock-screen clock's anchor.
        adaptive.sample(
            position: seconds, buffered: buffered, paused: isPaused,
            buffering: isBuffering, droppedFrames: droppedFrames
        )
        maybeAdapt()
        refreshNowPlayingAnchor()
    }

    func onFrameRate(_ rate: Double) {
        #if os(iOS)
        // A ProMotion panel is asked to run at the film's rate while mpv
        // draws it; AVPlayer's layer arranges that for itself.
        if let mpv = engine as? MPVEngine { mpv.hintContentFrameRate(rate > 0 ? rate : nil) }
        #endif
        #if os(tvOS)
        guard rate > 0 else { return }
        engine?.audioDelay = audioDelay
        // A stream the server couldn't say the rate of is matched once mpv has
        // read it; it is already playing, so the switch lands over the picture.
        guard !displayRequested else { return }
        displayRequested = true
        let size = videoSize
        Task {
            let switched = await DisplayMatch.request(rate: rate, codec: nil, size: size)
            if switched { await engine?.rebuildAudio() }
            engine?.setDisplayRefreshRate(DisplayMatch.matchedRate)
            engine?.audioDelay = audioDelay
        }
        #endif
    }

    func onVariantChanged(_ bitsPerSecond: Double) {
        let up = lastVariantBitrate.map { bitsPerSecond > $0 } ?? true
        lastVariantBitrate = bitsPerSecond
        showBitrateNotice(BitrateNotice(
            isUp: up,
            headline: String(format: "%.1f Mbps", bitsPerSecond / 1_000_000),
            detail: up ? "Network improved" : "Network slowed"
        ))
    }

    /// The engine waiting on the network, told to adaptive quality: the
    /// stall counted as it starts, and timed while it lasts. Both were lost
    /// when the engines moved behind `PlaybackEngine`, and nothing else can
    /// do the timing — a stalled stream's clock stops, and the position
    /// ticks `AdaptiveQuality.sample` rides on stop with it.
    func noteBuffering(_ waiting: Bool) {
        guard waiting else { endStall(); return }
        // The opening hold, a pause, or a stall already counted: none of
        // them is a new one.
        guard !stallCounted, !isOpening, !isPaused, adaptsQuality, isActive, !isLocal, !isExternal else { return }
        stallCounted = true
        adaptive.noteStall()
        maybeAdapt()
        let mine = generation
        stallWatch?.cancel()
        stallWatch = Task { [weak self] in
            var stalledFor: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isActive, self.stallCounted,
                      self.generation == mine else { return }
                // Paused by the viewer, the wait isn't the network's.
                if self.isPaused || self.isOpening { continue }
                stalledFor += 1
                if self.adaptive.noteStillStalled(for: stalledFor) {
                    self.maybeAdapt()
                    return
                }
            }
        }
    }

    /// Two things the engine never reports, watched for on a clock of this
    /// model's own while Auto is choosing the quality.
    ///
    /// A picture that has stopped with the engine still saying "playing":
    /// AVPlayer does this on a stream far bigger than the line — no stall
    /// flag, no time ticks, so neither `noteBuffering` nor `sample` ever
    /// hears of it, and it sat frozen for a minute and a half. Counted here
    /// as the long stall it is.
    ///
    /// And a stream Auto stepped down to that won't open: see
    /// `AdaptiveQuality.noteSlowOpening`.
    func watchProgress() {
        progressWatch?.cancel()
        progressWatch = nil
        let afterAutoDrop = openingAfterAutoDrop
        openingAfterAutoDrop = false
        guard adaptsQuality, isActive, !isLocal, !isExternal, !isLive else { return }
        let mine = generation
        progressWatch = Task { [weak self] in
            var openingFor: TimeInterval = 0
            var frozenFor: TimeInterval = 0
            var last: Double = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.isActive, self.generation == mine,
                      self.errorMessage == nil else { return }
                guard self.adaptsQuality else { continue }
                if self.isOpening {
                    frozenFor = 0
                    guard afterAutoDrop else { continue }
                    openingFor += 2
                    if self.adaptive.noteSlowOpening(for: openingFor) {
                        Self.log.notice("no picture \(Int(openingFor)) s after stepping down; stepping down again")
                        self.maybeAdapt()
                        return
                    }
                    continue
                }
                let shouldBeMoving = !self.isPaused && !self.isBuffering && !self.stallCounted
                    && self.duration > 0 && self.duration - self.position > 2
                if shouldBeMoving, abs(self.position - last) < 0.05 { frozenFor += 2 } else { frozenFor = 0 }
                last = self.position
                if frozenFor >= 8, self.adaptive.noteStillStalled(for: frozenFor) {
                    Self.log.notice("picture stopped for \(Int(frozenFor)) s with nothing reported; counted as a stall")
                    self.maybeAdapt()
                    return
                }
            }
        }
    }

    func endStall() {
        stallCounted = false
        stallWatch?.cancel()
        stallWatch = nil
    }

    func onAudioDelayApplied(_ delay: Double, refused: Bool) {
        setAudioDelayApplied(delay != 0 && !refused)
        if refused {
            AppModel.shared.toast("This file's sound can't be shifted — playing it in step", tone: .error)
        }
    }

    func onNoPicture() {
        noVideoTrack = true
        // A server item playing sound with no picture is a video codec this
        // device can't decode, and there is something to be done about it: the
        // server can send a version that plays. Asked for silently.
        if escalateToTranscode() { return }
        diagnoseExternalStream()
    }

    func handleStreamFailure(_ failure: EngineFailure) {
        // A live stream that dies while playing is the live reopener's — it
        // has its own budget and re-resolves the address from the playlist.
        if failure.duringPlayback, isLive, isActive, errorMessage == nil {
            if isReopeningLive { return }
            Self.log.notice("live stream failed mid-play: \(failure.message ?? "no error", privacy: .public); reopening")
            isBuffering = true
            reopenCurrentLive()
            return
        }
        Self.log.error(
            "stream failure live=\(self.isLive) external=\(self.isExternal) duringPlayback=\(failure.duringPlayback): \(failure.message ?? "no error", privacy: .public)")
        // The last segment of a server encode, listed and never made.
        if recoverFromMissingTail(failure) { return }
        // A session that went bad rather than unplayable media — ask again.
        if failure.isSessionLoss, recoverFromStreamFailure() { return }
        // A title that was playing a moment ago, reopened at its position,
        // failing within seconds of the reopen: not a file that won't play.
        // The server starts one encode for the playlist and replaces it with
        // another at the position asked for, and now and then the player is
        // still reading the first when it is deleted (seen as -19602, on
        // about one quality change in four on a 15 Mbps file). Asked again,
        // it plays. Within the same budget as any other recovery.
        if failure.duringPlayback, !isLocal, !isExternal, isTranscoding,
           let reopened = sameTitleReopenedAt, Date().timeIntervalSince(reopened) < 10,
           recoverFromStreamFailure() {
            Self.log.notice("failed \(Date().timeIntervalSince(reopened), format: .fixed(precision: 1)) s after a reopen; asking again")
            return
        }
        // Not a session fault — the stream itself. If the server sent the
        // original file, it has another way to send it.
        if escalateToTranscode() { return }
        errorMessage = failure.message ?? "This stream couldn't be played"
        diagnoseExternalStream()
        isBuffering = false
        isOpening = false
    }

    /// Reopen whatever live stream is playing.
    func reopenCurrentLive() {
        Task { await reopenStalledLive() }
    }

    func handleReachedEnd() {
        // A live stream has no end to reach. Getting this for one means the
        // playlist stopped — reopen it rather than drop back to the guide.
        if isLive, isActive {
            Self.log.notice("live stream reported its end; reopening")
            reopenCurrentLive()
            return
        }
        position = duration
        Task {
            guard !autoplayCancelled, prefs.autoplayNext else {
                await finish(userRequested: false)
                return
            }
            guard !autoplayInFlight else { return }
            autoplayInFlight = true
            let started = await advanceToNext()
            autoplayInFlight = false
            if !started { await finish(userRequested: false) }
        }
    }
}
