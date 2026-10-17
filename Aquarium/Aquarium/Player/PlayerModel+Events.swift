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
        if isLocal, let localRecordId {
            // A download keeps the same beat a stream does; its own cadence is
            // handled in `maybeReport`.
            _ = localRecordId
        }
        #endif

        // The Up Next card appears over the closing stretch rather than at the
        // very end — by the time the file runs out the decision is already made.
        let hasLocalNext: Bool = {
            #if os(tvOS)
            false
            #else
            upNextLocalId != nil
            #endif
        }()
        if upNext == nil, !hasLocalNext, !upNextChecked, duration > 0, duration - seconds < 90 {
            upNextChecked = true
            Task { await refreshUpNext() }
        }

        #if !os(tvOS)
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
        #endif
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
        #if !os(tvOS)
        let up = lastVariantBitrate.map { bitsPerSecond > $0 } ?? true
        lastVariantBitrate = bitsPerSecond
        showBitrateNotice(BitrateNotice(
            isUp: up,
            headline: String(format: "%.1f Mbps", bitsPerSecond / 1_000_000),
            detail: up ? "Network improved" : "Network slowed"
        ))
        #endif
    }

    func onAudioDelayApplied(_ delay: Double, refused: Bool) {
        #if !os(tvOS)
        setAudioDelayApplied(delay != 0 && !refused)
        if refused {
            AppModel.shared.toast("This file's sound can't be shifted — playing it in step", tone: .error)
        }
        #endif
    }

    func onNoPicture() {
        #if !os(tvOS)
        noVideoTrack = true
        // A server item playing sound with no picture is a video codec this
        // device can't decode, and there is something to be done about it: the
        // server can send a version that plays. Asked for silently.
        if escalateToTranscode() { return }
        diagnoseExternalStream()
        #endif
    }

    func handleStreamFailure(_ failure: EngineFailure) {
        // A live stream that dies while playing is the live reopener's — it
        // has its own budget and re-resolves the address from the playlist.
        if failure.duringPlayback, isLive, isActive, errorMessage == nil {
            #if !os(tvOS)
            if isReopeningLive { return }
            #endif
            Self.log.notice("live stream failed mid-play: \(failure.message ?? "no error", privacy: .public); reopening")
            isBuffering = true
            reopenCurrentLive()
            return
        }
        Self.log.error(
            "stream failure live=\(self.isLive) external=\(self.isExternal) duringPlayback=\(failure.duringPlayback): \(failure.message ?? "no error", privacy: .public)")
        #if !os(tvOS)
        // A session that went bad rather than unplayable media — ask again.
        if failure.isSessionLoss, recoverFromStreamFailure() { return }
        // Not a session fault — the stream itself. If the server sent the
        // original file, it has another way to send it.
        if escalateToTranscode() { return }
        errorMessage = failure.message ?? "This stream couldn't be played"
        diagnoseExternalStream()
        isBuffering = false
        isOpening = false
        #else
        if isLive { reopenCurrentLive(); return }
        // The original wouldn't play: once, ask the server for a transcode.
        if !escalated, let item, !isTranscoding {
            escalated = true
            var opts = options
            opts.forceTranscode = true
            opts.startSeconds = position > 1 ? position : nil
            Task { await play(item: item, options: opts, meta: StartMeta(inherited: true, recovering: true)) }
            return
        }
        errorMessage = "This stream couldn't be played (\(failure.message ?? "unknown error"))."
        isBuffering = false
        isOpening = false
        #endif
    }

    /// Reopen whatever live stream is playing, by whichever path the platform
    /// recovers one.
    func reopenCurrentLive() {
        #if !os(tvOS)
        Task { await reopenStalledLive() }
        #else
        reopenLive()
        #endif
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
