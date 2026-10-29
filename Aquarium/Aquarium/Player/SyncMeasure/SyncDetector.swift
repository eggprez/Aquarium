//  Timing a beep against a flash, from a camera and a microphone.
//
//  The Apple TV's sync clips flash on one frame and start a beep on the same
//  frame (`Tools/SyncTestClip/make-sync-test.swift`). Pointed at the
//  television, an iPhone records both — every camera frame and every audio
//  buffer stamped on the one clock a capture session runs — and the gap
//  between the flash reaching the lens and the beep reaching the microphone
//  is how far out the room's sound is, before anyone's ear gets a say.
//
//  Three parts, each knowing nothing of AVFoundation so the same code runs
//  in the app and in `Tools/SyncMeasure/measure-sync.swift` on a recording:
//
//  `SyncFlashDetector` is handed each frame's luma plane. It keeps a slow
//  baseline of the picture and watches for a short, large brightening
//  against it. A camera frame is a time window, not an instant, and the
//  flash usually begins partway through one: how much of that frame's
//  exposure the flash covered — the partial frame's brightness against a
//  fully-lit one — says how far into the window it began. The sensor reads
//  its rows one after another too (a rolling shutter), so the picture is cut
//  into horizontal bands and timed band by band, and the moment the flash
//  began at the first row is read off across the bands. `SyncMeasurement`
//  does that last step, since the readout rate is one number for the whole
//  recording.
//
//  `SyncBeepDetector` is handed the microphone samples. A Goertzel filter at
//  the beep's 1 kHz, two milliseconds at a time, draws the tone's envelope;
//  a beep is a step in it that holds, and its start is where the envelope
//  crosses half height, less half the clip's two-millisecond ramp.
//
//  `SyncMeasurement` pairs flashes with beeps, fits the readout slope, and
//  reduces the pairs to a median and a spread.
//
//  `SyncCode` is the text in the code the Apple TV draws over a sync clip —
//  the rate on test and the delay in force — read by the phone from the same
//  picture, so the two apps never need to talk.

import Accelerate
import Foundation

// MARK: - The code on screen

/// What the Apple TV draws in the corner of a sync clip, for the phone to
/// read: which rate's delay this is and the delay the clip is playing with,
/// in the stored sign — positive for sound later, as `Preferences.audioDelay`
/// and mpv have it. The Sync tab shows the negation; see `SyncAdvice`.
struct SyncCode: Equatable, Sendable {
    static let version = 1

    let fps: Int
    let delayMilliseconds: Int

    init(fps: Int, delayMilliseconds: Int) {
        self.fps = fps
        self.delayMilliseconds = delayMilliseconds
    }

    var payload: String { "AQSYNC:\(Self.version):\(fps):\(delayMilliseconds)" }

    init?(payload: String) {
        let parts = payload.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 4, parts[0] == "AQSYNC", Int(parts[1]) == Self.version,
              let fps = Int(parts[2]), let delay = Int(parts[3]), fps > 0, abs(delay) <= 5000 else { return nil }
        self.fps = fps
        self.delayMilliseconds = delay
    }
}

// MARK: - Flash

/// One flash: when it began, in the capture clock's seconds.
struct SyncFlash: Sendable {
    struct Band: Sendable {
        /// Which horizontal band of the sensor, 0 at the top of the buffer.
        let index: Int
        /// When the flash began, as this band alone saw it.
        let onset: Double
        /// How bright the flash was in this band at full exposure; the weight
        /// a band's reading gets.
        let weight: Float
    }

    /// The start, taken from the whole frame: what stands in for the band
    /// reading when there is no readout slope to apply.
    let onset: Double
    let bands: [Band]
    /// How many camera frames the flash was seen in.
    let frames: Int
    /// The brightening at its peak, in mean linear-light units over the
    /// sampled picture; for the diagnostics.
    let strength: Float
}

/// Finds the sync clip's flash in a stream of camera frames.
///
/// Frames are sampled on a coarse grid — every few pixels — and converted
/// to linear light, so a half-exposed flash reads as half as bright, which a
/// gamma-encoded luma would not. A slow per-pixel baseline follows the
/// picture; the mean of what rises above it, less a margin for sensor noise,
/// is the frame's energy, kept per horizontal band. A flash is a run of
/// frames with energy, no longer than `maxEventSeconds`; anything longer is
/// the room's light changing or the phone moving, and is thrown away.
final class SyncFlashDetector {
    let frameDuration: Double
    /// How long each row is exposed, in seconds. The fraction of a flash a
    /// partly-lit frame caught is read against this. The app sets it to the
    /// frame duration, which is what it locks the camera to; a recording
    /// with a shorter shutter gets a bigger, unavoidable error.
    var exposure: Double
    /// How long the television shows the flash — one of its frames, so
    /// 1/60 s for the 60 fps clip — when known from the code on screen.
    /// With it, how bright a band is at full exposure needn't be seen: it
    /// is the band's brightness summed over the flash, scaled by exposure
    /// over flash length. That holds even when no frame caught the whole
    /// flash, which at 60 fps against a 60 fps clip none does.
    var flashDuration: Double?
    let bands: Int

    /// Sensor noise to ignore, in linear-light units of 0–255.
    var margin: Float = 10
    /// How fast the baseline follows the picture, per frame.
    var baselineRate: Float = 0.02
    var maxEventSeconds = 0.2

    private let sampledWidth: Int
    private let sampledHeight: Int
    private let strideX: Int
    private let strideY: Int
    private let count: Int
    private let lut: [Float]

    private var encoded: [Float]
    private var current: [Float]
    private var baseline: [Float]
    private var diff: [Float]
    private var positive: [Float]

    private var framesSeen = 0
    private var ready = false
    /// Mean energy of a quiet frame, followed slowly: the threshold scales
    /// with it so a noisy, high-ISO picture doesn't trigger on its own.
    private var noise: Float = 0
    private var lastQuiet: Frame?
    private var event: [Frame] = []

    private struct Frame {
        let time: Double
        let total: Float
        let bands: [Float]
    }

    /// `fullRange` for a luma plane coded 0–255 rather than 16–235.
    init(width: Int, height: Int, frameDuration: Double, exposure: Double? = nil, fullRange: Bool = false, bands: Int = 8) {
        self.frameDuration = frameDuration
        self.exposure = exposure ?? frameDuration
        self.bands = bands
        strideX = max(1, width / 480)
        strideY = max(1, height / 270)
        sampledWidth = width / strideX
        sampledHeight = height / strideY
        count = sampledWidth * sampledHeight
        encoded = [Float](repeating: 0, count: count)
        current = encoded
        baseline = encoded
        diff = encoded
        positive = encoded
        // Luma to linear light, 0–255 either end, through the camera's
        // roughly 2.2 curve.
        lut = (0..<256).map { code in
            let black: Float = fullRange ? 0 : 16
            let white: Float = fullRange ? 255 : 235
            let unit = min(max((Float(code) - black) / (white - black), 0), 1)
            return 255 * powf(unit, 2.2)
        }
    }

    var warmSeconds: Double { 0.5 }

    /// Feeds one frame's luma plane, `bytesPerRow` apart row to row, taken at
    /// `time` seconds on the capture clock. Returns a flash once one has
    /// ended, so a flash is reported a few frames after it was seen.
    func process(luma: UnsafePointer<UInt8>, bytesPerRow: Int, time: Double) -> SyncFlash? {
        framesSeen += 1
        for row in 0..<sampledHeight {
            vDSP_vfltu8(luma + row * strideY * bytesPerRow, strideX, &encoded[row * sampledWidth], 1, vDSP_Length(sampledWidth))
        }
        vDSP_vindex(lut, encoded, 1, &current, 1, vDSP_Length(count))

        guard ready else {
            baseline = current
            ready = true
            return nil
        }

        // diff = current − baseline; positive = max(diff − margin, 0).
        vDSP_vsub(baseline, 1, current, 1, &diff, 1, vDSP_Length(count))
        var floor = margin
        vDSP_vthr(diff, 1, &floor, &positive, 1, vDSP_Length(count))
        var negative = -margin
        vDSP_vsadd(positive, 1, &negative, &positive, 1, vDSP_Length(count))

        var energies = [Float](repeating: 0, count: bands)
        var total: Float = 0
        for band in 0..<bands {
            let from = band * sampledHeight / bands
            let to = (band + 1) * sampledHeight / bands
            guard to > from else { continue }
            var sum: Float = 0
            positive.withUnsafeBufferPointer { buffer in
                vDSP_sve(buffer.baseAddress! + from * sampledWidth, 1, &sum, vDSP_Length((to - from) * sampledWidth))
            }
            energies[band] = sum / Float((to - from) * sampledWidth)
            total += sum
        }
        total /= Float(count)
        let frame = Frame(time: time, total: total, bands: energies)

        let warming = Double(framesSeen) * frameDuration < warmSeconds
        let threshold = max(0.4, 8 * noise)

        if event.isEmpty {
            if !warming, total > threshold {
                if let lastQuiet { event.append(lastQuiet) }
                event.append(frame)
                return nil
            }
            // Quiet: follow the picture, and remember what quiet looks like.
            var rate = warming ? max(baselineRate, 0.2) : baselineRate
            vDSP_vsma(diff, 1, &rate, baseline, 1, &baseline, 1, vDSP_Length(count))
            noise += (warming ? 0.1 : 0.01) * (total - noise)
            lastQuiet = frame
            return nil
        }

        // In a flash.
        if total > threshold / 2 {
            event.append(frame)
            if Double(event.count) * frameDuration > maxEventSeconds {
                // Not a flash: the scene changed. Start the baseline again
                // from here so the next real flash isn't lost to the gap.
                event.removeAll()
                baseline = current
                lastQuiet = nil
            }
            return nil
        }
        let frames = event
        event.removeAll()
        lastQuiet = frame
        return finish(frames)
    }

    /// Reads the start of the flash off a run of frames: the first frame with
    /// a share of the full brightness caught that share of the way through
    /// its exposure.
    private func finish(_ frames: [Frame]) -> SyncFlash? {
        guard frames.count >= 2 else { return nil }
        let peak = frames.map(\.total).max() ?? 0
        guard peak > 0, let whole = onsetOf(frames.map(\.total), times: frames.map(\.time)) else { return nil }

        var bandOnsets: [SyncFlash.Band] = []
        let plateaus = (0..<bands).map { band in frames.map { $0.bands[band] }.max() ?? 0 }
        let brightest = plateaus.max() ?? 0
        for band in 0..<bands where plateaus[band] >= 0.2 * brightest && plateaus[band] >= 0.3 {
            if let when = onsetOf(frames.map { $0.bands[band] }, times: frames.map(\.time)) {
                bandOnsets.append(SyncFlash.Band(index: band, onset: when, weight: plateaus[band]))
            }
        }
        return SyncFlash(onset: whole, bands: bandOnsets, frames: frames.count - 1, strength: peak)
    }

    private func onsetOf(_ series: [Float], times: [Double]) -> Double? {
        guard let brightest = series.max(), brightest > 0 else { return nil }
        var plateau = brightest
        if let flashDuration, flashDuration > 0 {
            let summed = series.reduce(0, +) * Float(exposure / flashDuration)
            plateau = max(plateau, summed)
        }
        guard let first = series.firstIndex(where: { $0 >= 0.08 * brightest }) else { return nil }
        let fraction = Double(min(series[first] / plateau, 1))
        return times[first] + (1 - fraction) * exposure
    }
}

// MARK: - Beep

/// One beep: when the tone began, in the capture clock's seconds.
struct SyncBeep: Sendable {
    let onset: Double
    /// The tone's amplitude at full height, 0–1 of full scale.
    let amplitude: Float
    /// How long the tone held above half height: the clip's beep is 42 ms.
    let held: Double
}

/// Finds the sync clip's 1 kHz beep in a stream of microphone samples.
final class SyncBeepDetector {
    let sampleRate: Double
    let frequency: Double
    /// The clip's fade-in: the envelope reaches half height half way through
    /// it.
    let ramp: Double

    private let hop: Int
    private let window: Int
    private let coefficient: Float
    private var pending: [Float] = []
    private var pendingTime: Double?
    private var samplesIn = 0

    private struct Reading {
        let center: Double
        let amplitude: Float
    }
    private var envelope: [Reading] = []
    private var floor: Float = 0.001
    private var windowsSeen = 0
    /// The centre time of the window that tripped the threshold, while the
    /// rest of the beep is waited for. A time, not an index: the envelope
    /// is trimmed from the front as it goes.
    private var armed: Double?
    private var quietUntil: Double = -.infinity

    init(sampleRate: Double, frequency: Double = 1000, ramp: Double = 0.002) {
        self.sampleRate = sampleRate
        self.frequency = frequency
        self.ramp = ramp
        hop = max(8, Int((sampleRate / 1000).rounded()))
        window = 2 * hop
        coefficient = 2 * cosf(Float(2 * Double.pi * frequency / sampleRate))
    }

    /// Feeds mono samples, −1…1, the first taken at `time` on the capture
    /// clock. Buffers are taken as contiguous; a gap of more than two
    /// milliseconds against the running clock restarts it.
    func process(_ samples: UnsafeBufferPointer<Float>, time: Double) -> [SyncBeep] {
        if let pendingTime {
            let expected = pendingTime + Double(pending.count) / sampleRate
            if abs(expected - time) > 0.002 {
                pending.removeAll()
                self.pendingTime = time
                armed = nil
            }
        } else {
            pendingTime = time
        }
        pending.append(contentsOf: samples)

        var found: [SyncBeep] = []
        var offset = 0
        while offset + window <= pending.count {
            let amplitude = pending.withUnsafeBufferPointer { buffer -> Float in
                var s1: Float = 0, s2: Float = 0
                for i in offset..<offset + window {
                    let s0 = buffer[i] + coefficient * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                let power = max(s1 * s1 + s2 * s2 - coefficient * s1 * s2, 0)
                return 2 * sqrtf(power) / Float(window)
            }
            let center = pendingTime! + (Double(offset) + Double(window) / 2) / sampleRate
            if let beep = take(Reading(center: center, amplitude: amplitude)) {
                found.append(beep)
            }
            offset += hop
        }
        pending.removeFirst(offset)
        pendingTime! += Double(offset) / sampleRate
        return found
    }

    private var hopSeconds: Double { Double(hop) / sampleRate }

    private func take(_ reading: Reading) -> SyncBeep? {
        envelope.append(reading)
        if envelope.count > 400 { envelope.removeFirst(envelope.count - 400) }
        windowsSeen += 1

        if let trigger = armed {
            // Wait for 60 ms past the trigger, then judge the whole shape.
            guard reading.center - trigger >= 0.06 else { return nil }
            armed = nil
            guard let start = envelope.firstIndex(where: { $0.center >= trigger }) else { return nil }
            let upto = min(envelope.count - 1, start + Int(0.05 / hopSeconds))
            let span = envelope[max(0, start - 3)...upto]
            guard let peak = span.max(by: { $0.amplitude < $1.amplitude }) else { return nil }
            let half = peak.amplitude / 2
            let held = Double(span.filter { $0.amplitude >= half }.count) * hopSeconds
            guard held >= 0.02 else { return nil }
            // Back from the peak to the half-height crossing.
            guard let peakIndex = envelope.firstIndex(where: { $0.center == peak.center }) else { return nil }
            var i = peakIndex
            while i > 0, envelope[i - 1].amplitude >= half { i -= 1 }
            guard i > 0 else { return nil }
            let below = envelope[i - 1], above = envelope[i]
            let rise: Float = max(above.amplitude - below.amplitude, 1e-9)
            let fraction = Double((half - below.amplitude) / rise)
            let crossing = below.center + fraction * (above.center - below.center)
            let onset = crossing - ramp / 2
            quietUntil = onset + 0.15
            return SyncBeep(onset: onset, amplitude: peak.amplitude, held: held)
        }

        let warming = windowsSeen < 300
        if reading.center < quietUntil {
            return nil
        }
        if !warming, reading.amplitude > max(6 * floor, 3e-4) {
            armed = reading.center
            return nil
        }
        floor += (warming ? 0.02 : 0.002) * (reading.amplitude - floor)
        floor = max(floor, 1e-5)
        return nil
    }
}

// MARK: - Putting them together

/// A flash and the beep that went with it.
struct SyncPair: Sendable {
    let flash: Double
    let beep: Double
    /// Beep less flash, in seconds: positive when the sound came late.
    var residual: Double { beep - flash }
}

struct SyncResult: Sendable {
    /// The median of the pairs' residuals, in seconds, positive for sound
    /// late, as the camera and microphone saw it — before distance and the
    /// microphone's own lag are allowed for.
    let residual: Double
    /// Half the pairs lie within this of the median: 1.4826 × the median
    /// absolute deviation, a standard deviation that ignores outliers.
    let spread: Double
    let pairs: [SyncPair]
    /// The sensor's readout time per band, in seconds, as fitted; nil when
    /// there wasn't enough to fit one and the whole-frame onsets were used.
    let readoutPerBand: Double?

    var count: Int { pairs.count }
}

/// Collects flashes and beeps and reduces them to one answer.
final class SyncMeasurement {
    private(set) var flashes: [SyncFlash] = []
    private(set) var beeps: [SyncBeep] = []

    /// How far apart a flash and its beep may be: the beats are two seconds
    /// apart, so a beep is never nearer another beat's flash than this.
    var reach = 0.9

    func add(_ flash: SyncFlash) { flashes.append(flash) }
    func add(_ beep: SyncBeep) { beeps.append(beep) }

    /// The readout slope: each band reads later than the one above it by a
    /// constant, so a band's onset is early by its index times that
    /// constant. One number for the sensor, so it is fitted across every
    /// flash that lit three or more bands and the median taken.
    func readoutPerBand() -> Double? {
        var slopes: [(slope: Double, weight: Double)] = []
        for flash in flashes where flash.bands.count >= 3 {
            let xs = flash.bands.map { Double($0.index) }
            let ys = flash.bands.map(\.onset)
            let ws = flash.bands.map { Double($0.weight) }
            guard Set(xs).count >= 3 else { continue }
            let w = ws.reduce(0, +)
            let mx = zip(xs, ws).map(*).reduce(0, +) / w
            let my = zip(ys, ws).map(*).reduce(0, +) / w
            var sxx = 0.0, sxy = 0.0
            for i in xs.indices {
                sxx += ws[i] * (xs[i] - mx) * (xs[i] - mx)
                sxy += ws[i] * (xs[i] - mx) * (ys[i] - my)
            }
            guard sxx > 0 else { continue }
            slopes.append((sxy / sxx, w))
        }
        guard slopes.count >= 2 else { return nil }
        return Self.weightedMedian(slopes)
    }

    /// When a flash began at the sensor's first row.
    func onset(of flash: SyncFlash, readoutPerBand slope: Double?) -> Double {
        guard let slope, !flash.bands.isEmpty else {
            guard !flash.bands.isEmpty else { return flash.onset }
            let w = flash.bands.map { Double($0.weight) }.reduce(0, +)
            return flash.bands.map { $0.onset * Double($0.weight) }.reduce(0, +) / w
        }
        let w = flash.bands.map { Double($0.weight) }.reduce(0, +)
        return flash.bands.map { ($0.onset - slope * Double($0.index)) * Double($0.weight) }.reduce(0, +) / w
    }

    /// Every flash matched with the nearest beep within `reach`, each used
    /// once.
    func pairs() -> [SyncPair] {
        let slope = readoutPerBand()
        var taken = Set<Int>()
        var out: [SyncPair] = []
        for flash in flashes {
            let at = onset(of: flash, readoutPerBand: slope)
            var best: (index: Int, distance: Double)?
            for (i, beep) in beeps.enumerated() where !taken.contains(i) {
                let d = abs(beep.onset - at)
                if d <= reach, best == nil || d < best!.distance { best = (i, d) }
            }
            guard let best else { continue }
            taken.insert(best.index)
            out.append(SyncPair(flash: at, beep: beeps[best.index].onset))
        }
        return out
    }

    /// Nil until there are three pairs to agree.
    func result() -> SyncResult? {
        let pairs = pairs()
        guard pairs.count >= 3 else { return nil }
        let residuals = pairs.map(\.residual).sorted()
        let median = Self.median(residuals)
        let deviations = residuals.map { abs($0 - median) }.sorted()
        return SyncResult(residual: median, spread: 1.4826 * Self.median(deviations), pairs: pairs,
                          readoutPerBand: readoutPerBand())
    }

    static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    static func weightedMedian(_ values: [(slope: Double, weight: Double)]) -> Double {
        let sorted = values.sorted { $0.slope < $1.slope }
        let half = sorted.map(\.weight).reduce(0, +) / 2
        var run = 0.0
        for value in sorted {
            run += value.weight
            if run >= half { return value.slope }
        }
        return sorted.last!.slope
    }
}

// MARK: - What to set

/// The number to put in, from what was measured and the code on screen.
struct SyncAdvice: Equatable, Sendable {
    let code: SyncCode
    /// Beep less flash at the phone, in seconds, after distance and the
    /// microphone's lag are taken off: how late the sound really is.
    let late: Double

    /// The delay the Apple TV should store, in milliseconds, stored sign:
    /// the one in force less how late the sound was.
    var storedMilliseconds: Int { code.delayMilliseconds - Int((late * 1000).rounded()) }

    /// What the Sync tab should read: the tab shows the negation of the
    /// stored delay (plus brings the sound forward), and steps by fives.
    var tabMilliseconds: Int { Int((Double(-storedMilliseconds) / 5).rounded()) * 5 }

    /// The tab's reading now, for "from … to …".
    var tabNowMilliseconds: Int { -code.delayMilliseconds }

    static func tabText(_ milliseconds: Int) -> String {
        milliseconds == 0 ? "In step" : "\(milliseconds > 0 ? "+" : "−")\(abs(milliseconds)) ms"
    }
}
