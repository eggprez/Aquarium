//  Adaptive quality: move the stream down a rung when the connection or the
//  device stops keeping up, and back up when it recovers.
//
//  A direct port of adaptive.ts. The signals it watches are different — mpv
//  reported cache stalls and dropped frames over an IPC socket, AVFoundation
//  reports them through `AVPlayerItemAccessLog` and the buffer-empty flag — but
//  the policy is the same one, thresholds included.
//
//  It only ever reacts to what has already gone wrong: no probing, no
//  prediction. Two rules move it down (repeated stalls, or one long one; and
//  frames being dropped, which buffering can't fix), one rule moves it back up
//  (a long clean stretch with a healthy read-ahead), and a rung that failed on
//  the way up is never tried again for the rest of the session.

import AVFoundation
import Foundation

@MainActor
final class AdaptiveQuality {
    struct Decision: Sendable {
        var bitrate: Int?
        var message: String
        var isDrop: Bool
        /// The cause in a few words, for the badge that announces a move.
        var reason: String
    }

    /// Quality.choices runs best-first: index 0 is direct play, the last entry
    /// is the smallest stream on offer. "Down" is therefore a higher index.
    private var lowest: Int { Quality.choices.count - 1 }

    /// Stalls this close together mean the stream, not a blip.
    private let stallWindow: TimeInterval = 60
    private let stallsToDrop = 2
    /// One stall this long is damning on its own — nobody waits it out twice.
    private let longStall: TimeInterval = 8
    /// Every stream buffers as it opens; that isn't evidence of anything.
    private let startupGrace: TimeInterval = 15
    /// After a switch of our own, say nothing until the new stream has settled.
    private let switchCooldown: TimeInterval = 45
    /// A rung the user picked by hand is left alone for this long.
    ///
    /// Switching quality makes the server open a fresh transcode and seek it to
    /// the current position, and the first stretch of one is rough however good
    /// the connection is. Judged on that, a deliberate move up the ladder was
    /// condemned almost immediately and walked back down — which is not
    /// adapting to the connection, it is overruling the person watching.
    private let manualGrace: TimeInterval = 90
    /// A seek empties the buffer, so the stall that follows is our own doing.
    private let seekGrace: TimeInterval = 12
    /// Position running this far ahead of the clock between two samples is a
    /// jump. Measured against elapsed time rather than as a bare delta: a
    /// stalled stream stands still while the clock moves, and that must not read
    /// as a seek — it's the very thing being watched for.
    private let seekJump: Double = 5
    /// Dropped frames are counted per window rather than in total: a handful
    /// over an hour is normal, the same number in twenty seconds is a slideshow.
    private let dropWindow: TimeInterval = 20
    private let dropsToDrop = 120
    /// Read-ahead that counts as comfortable, in seconds of video.
    private let healthyRunway: Double = 12
    /// How long it has to stay comfortable before trying a better rung.
    private let upshiftAfter: TimeInterval = 5 * 60
    /// A stall this soon after moving up means the rung is out of reach.
    private let upshiftProbation: TimeInterval = 90

    /// Best rung the policy may climb back to — the one the user actually asked
    /// for, lowered permanently when a climb turns out to be beyond the line.
    private var ceiling = 0
    /// The rung the device itself can afford right now, as an index into the
    /// ladder — see `notePower`. Nil when it can afford any of them.
    private var powerCap: Int?
    private var streamStartedAt = Date.distantPast
    private var lastSwitchAt = Date.distantPast
    /// While this is in the future, the rung playing was chosen by hand and the
    /// policy keeps out of it.
    private var manualUntil = Date.distantPast
    private var lastSeekAt = Date.distantPast
    private var lastUpshiftAt: Date?
    private var lastPosition: Double = 0
    private var lastSampleAt: Date?
    private var stallTimes: [Date] = []
    private var stallSince: Date?
    private var healthySince: Date?
    private var dropSample: (at: Date, frames: Int)?
    /// Said "this is as low as it goes" once for this stream.
    private var floorNoted = false
    private var pendingDecision: Decision?

    private var isPaused = false
    private var isBuffering = false

    // MARK: - Lifecycle

    /// A new stream started. `inherited` marks one whose bitrate carried over
    /// from the last rather than being chosen; only our own switches earn the
    /// cooldown, because a user who just picked a quality shouldn't wait 45
    /// seconds for the policy to start watching it.
    func begin(inherited: Bool, ceiling requested: Int?) {
        let index = rungIndex(requested)
        resetStream()
        streamStartedAt = Date()
        lastSwitchAt = inherited ? streamStartedAt : .distantPast
        // A rung nobody chose is watched from the off; one that was chosen gets
        // long enough to prove itself first.
        manualUntil = inherited ? .distantPast : streamStartedAt.addingTimeInterval(manualGrace)
        // Picking a quality by hand is the user redrawing the line the policy
        // climbs back to. Anything inherited keeps the line where it was, but
        // can't leave it below what's actually playing.
        ceiling = inherited ? min(ceiling, index) : index
    }

    func reset() {
        resetStream()
        ceiling = 0
        lastUpshiftAt = nil
        manualUntil = .distantPast
    }

    // MARK: - The device

    /// The rungs a device in this state is held to. Decoding and drawing a
    /// 4K stream is what heats a phone up, and the thermal manager answers by
    /// throttling the clocks — which is when frames start being dropped. The
    /// policy already catches that, a minute late and after the slideshow.
    /// Easing off at the warning instead keeps the picture smooth and the
    /// phone cooler, and the usual climb brings it back once things settle.
    ///
    /// Low Power Mode is the person asking for the battery to last; a 1080p
    /// stream at a third of the bits is a fair reading of that.
    static func powerRung(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> Int? {
        var cap: Int?
        if lowPower { cap = 10_000_000 }
        switch thermal {
        case .serious: cap = min(cap ?? .max, 10_000_000)
        case .critical: cap = min(cap ?? .max, 5_000_000)
        default: break
        }
        return cap
    }

    /// The device's state changed. True when the stream playing is now above
    /// what it can afford and `decide` has a step down ready — a change the
    /// caller is expected to act on at once rather than at the next tick.
    func notePower(thermal: ProcessInfo.ThermalState, lowPower: Bool, currentBitrate: Int?) -> Bool {
        let cap = Self.powerRung(thermal: thermal, lowPower: lowPower).flatMap(rungIndex)
        powerCap = cap
        guard let cap, rungIndex(currentBitrate) < cap else { return false }
        powerReason = lowPower && thermal != .serious && thermal != .critical ? .lowPower : .heat
        wantPowerDrop = true
        return true
    }

    private enum PowerReason { case heat, lowPower }
    private var powerReason: PowerReason = .heat
    private var wantPowerDrop = false

    /// The stream is finally playing. The opening hold — fetching the playlist,
    /// waiting for a transcode to reach the position it was seeked to — can run
    /// to tens of seconds, and none of it says anything about whether this rung
    /// can be sustained, so the startup grace is measured from here.
    func noteOpened() {
        streamStartedAt = Date()
        stallTimes = []
        stallSince = nil
        dropSample = nil
        wantDown = false
        wantUp = false
    }

    /// Everything that belongs to one stream rather than to the session.
    private func resetStream() {
        stallTimes = []
        stallSince = nil
        healthySince = nil
        dropSample = nil
        lastPosition = 0
        lastSampleAt = nil
        lastSeekAt = .distantPast
        floorNoted = false
        pendingDecision = nil
    }

    /// A bitrate that isn't one of ours — a rung from an older build, one
    /// synced from a device on another version — is read as the rung that
    /// `Quality.snapped` would turn it into. Read as direct play, as it was, a
    /// "step down" from 7 Mbps asked for 36.
    private func rungIndex(_ bitrate: Int?) -> Int {
        let rung = Quality.snapped(bitrate)
        return Quality.choices.firstIndex { $0.maxBitrate == rung } ?? 0
    }

    /// True while anything recent would make a stall someone else's fault.
    private var settling: Bool {
        let now = Date()
        return now < manualUntil
            || now.timeIntervalSince(streamStartedAt) < startupGrace
            || now.timeIntervalSince(lastSwitchAt) < switchCooldown
            || now.timeIntervalSince(lastSeekAt) < seekGrace
    }

    // MARK: - Signals

    /// The player stopped the picture to refill its buffer.
    func noteStall() {
        guard !settling else { return }
        let now = Date()
        stallTimes = stallTimes.filter { now.timeIntervalSince($0) < stallWindow }
        stallTimes.append(now)
        if stallTimes.count >= stallsToDrop {
            stallTimes = []
            queueStepDown(reason: .stall)
        }
    }

    func noteSeek() {
        lastSeekAt = Date()
    }

    /// A stall counted by `noteStall` is still going, `seconds` into it. Called
    /// by the player on a timer of its own: a stalled stream's clock stops, and
    /// `sample` stops with it, so the long-stall rule there could never fire
    /// for the stall that needed it most. Returns whether a step down is now
    /// queued for `decide`.
    func noteStillStalled(for seconds: TimeInterval) -> Bool {
        guard seconds >= longStall, !settling else { return false }
        stallSince = nil
        stallTimes = []
        queueStepDown(reason: .stall)
        return true
    }

    /// One sample of the player's state, taken on every time-observer tick.
    /// `paused` is the player's own intent: the timebase's rate is zero for a
    /// stall as much as for a pause, and read from there no stall was ever
    /// long.
    func sample(item: AVPlayerItem, position: Double, buffered: Double, paused: Bool) {
        let now = Date()
        isPaused = paused
        isBuffering = item.isPlaybackBufferEmpty || !item.isPlaybackLikelyToKeepUp

        // Seeks, spotted rather than reported: forward, the picture outruns the
        // clock; backward, it goes somewhere no amount of waiting takes it.
        // Everything in between — paused, stalled, playing — is not a seek.
        if let last = lastSampleAt {
            let elapsed = now.timeIntervalSince(last)
            let moved = position - lastPosition
            if moved - elapsed > seekJump || moved < -1 { lastSeekAt = now }
        }
        lastPosition = position
        lastSampleAt = now

        // A single stall that never ends counts on its own — waiting for a
        // second one means waiting for this one to finish, and it may not.
        if isBuffering, !isPaused {
            if stallSince == nil {
                stallSince = now
            } else if let since = stallSince, now.timeIntervalSince(since) >= longStall, !settling {
                stallSince = nil
                stallTimes = []
                queueStepDown(reason: .stall)
            }
        } else {
            stallSince = nil
        }

        // Frames given up on. Sampled as a rate: this is the device failing to
        // decode what it's been sent, which a smaller stream fixes and a bigger
        // buffer does not.
        //
        // The log is read only when a sample is due. `accessLog()` hands back
        // a fresh copy of every event since the stream opened, and it was
        // being taken twice a second — a copy that grows for the length of a
        // film — to be looked at once every twenty seconds.
        let dropSampleDue = dropSample.map { now.timeIntervalSince($0.at) >= dropWindow } ?? true
        if dropSampleDue, !isPaused, let event = item.accessLog()?.events.last {
            let frames = event.numberOfDroppedVideoFrames
            if frames >= 0 {
                if dropSample == nil {
                    dropSample = (now, frames)
                } else if let sample = dropSample, now.timeIntervalSince(sample.at) >= dropWindow {
                    let delta = frames - sample.frames
                    dropSample = (now, frames)
                    if delta >= dropsToDrop, !settling { queueStepDown(reason: .drops) }
                }
            }
        }

        // Health, for the climb back. Paused doesn't count: a buffer that fills
        // while nothing is playing says nothing about whether it can be kept
        // full.
        let runway = buffered - position
        let healthy = !isPaused && !isBuffering && runway >= healthyRunway
        guard healthy else {
            healthySince = nil
            return
        }
        if healthySince == nil { healthySince = now }
        if let since = healthySince, now.timeIntervalSince(since) >= upshiftAfter, !settling {
            healthySince = nil
            queueStepUp()
        }
    }

    // MARK: - Decisions

    private enum DropReason { case stall, drops }

    private var lastReasonWasDrop = false
    private var wantDown = false
    private var wantUp = false

    private func queueStepDown(reason: DropReason) {
        wantDown = true
        wantUp = false
        lastReasonWasDrop = reason == .drops
    }

    private func queueStepUp() {
        wantUp = true
        wantDown = false
    }

    /// The move the policy wants to make, or nil. Returns at most one decision
    /// per event, and starts the cooldown as it hands it over — the caller is
    /// expected to act on it.
    func decide(currentBitrate: Int?) -> Decision? {
        let index = rungIndex(currentBitrate)

        // The device's own limit comes first and waits for nothing — not the
        // startup grace, not a rung picked by hand. A phone at its thermal
        // limit is going to drop frames whatever anyone chose.
        if wantPowerDrop {
            wantPowerDrop = false
            if let cap = powerCap, index < cap {
                lastSwitchAt = Date()
                lastUpshiftAt = nil
                let label = Quality.choices[cap].label
                return Decision(
                    bitrate: Quality.choices[cap].maxBitrate,
                    message: powerReason == .heat
                        ? "This device is running hot — easing to \(label)"
                        : "Low Power Mode — easing to \(label)",
                    isDrop: true,
                    reason: powerReason == .heat ? "Device running hot" : "Low Power Mode"
                )
            }
        }

        if wantDown {
            wantDown = false
            guard !settling else { return nil }
            guard index < lowest else {
                // Nothing left to give. Say so once — a picture that keeps
                // stopping with no explanation reads as a broken app rather
                // than a struggling network.
                guard !floorNoted else { return nil }
                floorNoted = true
                return Decision(
                    bitrate: currentBitrate,
                    message: "Still struggling at \(Quality.choices[index].label) — the network or the server is the limit",
                    isDrop: true,
                    reason: "Lowest quality"
                )
            }
            let next = index + 1
            // A stall straight after climbing means that rung is beyond this
            // connection. Pin the ceiling here so the policy doesn't spend the
            // evening rediscovering it every five minutes.
            if let up = lastUpshiftAt, Date().timeIntervalSince(up) < upshiftProbation {
                ceiling = next
            }
            lastUpshiftAt = nil
            lastSwitchAt = Date()
            let label = Quality.choices[next].label
            return Decision(
                bitrate: Quality.choices[next].maxBitrate,
                message: lastReasonWasDrop
                    ? "Playback can't keep up — switching to \(label)"
                    : "Buffering — switching to \(label)",
                isDrop: true,
                reason: lastReasonWasDrop ? "Playback couldn't keep up" : "Connection slowed"
            )
        }

        if wantUp {
            wantUp = false
            let next = index - 1
            guard next >= ceiling, next >= (powerCap ?? 0), next >= 0, !settling else { return nil }
            lastUpshiftAt = Date()
            lastSwitchAt = Date()
            return Decision(
                bitrate: Quality.choices[next].maxBitrate,
                message: "Connection looks steady — back to \(Quality.choices[next].label)",
                isDrop: false,
                reason: "Connection improved"
            )
        }

        return nil
    }
}
