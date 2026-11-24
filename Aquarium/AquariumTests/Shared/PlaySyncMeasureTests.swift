//  Measuring the Apple TV's sound against its picture with the phone's camera
//  and microphone (Settings › Audio › Measure, `Player/SyncMeasure`). The
//  camera page itself needs a camera and a television (MANUAL.md); the sums
//  under it know nothing of AVFoundation, and are fed made-up frames and
//  samples here: a 1 kHz beep in silence, a white frame in a dark room.
//
//  `SyncCode`'s text is covered by `TVSyncCodeTests`.

import Foundation
import XCTest
@testable import Aquarium

// MARK: - Pairs, the median and the advice

final class PlaySyncMeasurementTests: XCTestCase {
    private func flash(_ onset: Double, bands: [SyncFlash.Band] = []) -> SyncFlash {
        SyncFlash(onset: onset, bands: bands, frames: 1, strength: 100)
    }

    private func beep(_ onset: Double) -> SyncBeep {
        SyncBeep(onset: onset, amplitude: 0.5, held: 0.042)
    }

    func testMedianOfOddAndEvenCounts() {
        XCTAssertEqual(SyncMeasurement.median([1, 2, 3]), 2)
        XCTAssertEqual(SyncMeasurement.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(SyncMeasurement.median([7]), 7)
    }

    func testWeightedMedianLeansToTheHeavyValue() {
        XCTAssertEqual(SyncMeasurement.weightedMedian([(slope: 1, weight: 1), (slope: 2, weight: 1), (slope: 10, weight: 5)]), 10)
        XCTAssertEqual(SyncMeasurement.weightedMedian([(slope: 3, weight: 1), (slope: 1, weight: 1)]), 1,
                       "sorted first; the lower of two equal weights")
    }

    func testThreePairsGiveTheMedianAndASpread() throws {
        let m = SyncMeasurement()
        for t in [10.0, 12.0, 14.0] { m.add(flash(t)) }
        for t in [10.04, 12.05, 14.03] { m.add(beep(t)) }
        let result = try XCTUnwrap(m.result())
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.residual, 0.04, accuracy: 1e-9, "the sound came 40 ms late")
        // Deviations from 0.04 are 0, 0.01, 0.01: their median is 0.01.
        XCTAssertEqual(result.spread, 1.4826 * 0.01, accuracy: 1e-9)
        XCTAssertNil(result.readoutPerBand, "no bands, no readout slope")
    }

    func testFewerThanThreePairsIsNoAnswer() {
        let m = SyncMeasurement()
        for t in [10.0, 12.0] { m.add(flash(t)) }
        for t in [10.04, 12.05] { m.add(beep(t)) }
        XCTAssertEqual(m.pairs().count, 2)
        XCTAssertNil(m.result())
    }

    func testABeepOutOfReachIsNotPaired() {
        let m = SyncMeasurement()
        m.add(flash(10))
        m.add(beep(11))
        XCTAssertTrue(m.pairs().isEmpty, "a second away is the next beat's, not this flash's")
        m.reach = 1.5
        XCTAssertEqual(m.pairs().count, 1)
    }

    func testTheNearestBeepIsTakenAndEachBeepOnce() {
        let m = SyncMeasurement()
        m.add(flash(10))
        m.add(beep(10.5))
        m.add(beep(10.1))
        XCTAssertEqual(m.pairs().map(\.beep), [10.1])

        let once = SyncMeasurement()
        once.add(flash(10))
        once.add(flash(10.1))
        once.add(beep(10.05))
        let pairs = once.pairs()
        XCTAssertEqual(pairs.count, 1, "one beep cannot answer two flashes")
        XCTAssertEqual(pairs.first?.flash, 10)
    }

    func testAPairsResidualIsBeepLessFlash() {
        XCTAssertEqual(SyncPair(flash: 2, beep: 2.25).residual, 0.25)
        XCTAssertEqual(SyncPair(flash: 2, beep: 1.5).residual, -0.5, "negative when the sound came first")
    }

    func testAFlashWithNoBandsIsTimedByTheWholeFrame() {
        let m = SyncMeasurement()
        XCTAssertEqual(m.onset(of: flash(3.5), readoutPerBand: nil), 3.5)
        XCTAssertEqual(m.onset(of: flash(3.5), readoutPerBand: 0.002), 3.5)
    }

    func testBandsAreAveragedByWeightAndTheReadoutSlopeTakenOff() {
        let m = SyncMeasurement()
        let bands = [
            SyncFlash.Band(index: 0, onset: 10.000, weight: 1),
            SyncFlash.Band(index: 1, onset: 10.002, weight: 1),
            SyncFlash.Band(index: 2, onset: 10.004, weight: 3),
        ]
        let f = flash(9, bands: bands)
        XCTAssertEqual(m.onset(of: f, readoutPerBand: nil), 10.0028, accuracy: 1e-9)
        XCTAssertEqual(m.onset(of: f, readoutPerBand: 0.002), 10.0, accuracy: 1e-9,
                       "each band read 2 ms after the one above: all began at the first row's moment")
    }

    func testTheReadoutSlopeNeedsTwoFlashesWithThreeBands() {
        func banded(_ start: Double) -> SyncFlash {
            flash(start, bands: (0..<4).map { SyncFlash.Band(index: $0, onset: start + 0.002 * Double($0), weight: 1) })
        }
        let m = SyncMeasurement()
        m.add(banded(10))
        XCTAssertNil(m.readoutPerBand(), "one flash is not enough to trust")
        m.add(flash(11, bands: [SyncFlash.Band(index: 0, onset: 11, weight: 1), SyncFlash.Band(index: 1, onset: 11.5, weight: 1)]))
        XCTAssertNil(m.readoutPerBand(), "a flash that lit two bands has no slope to give")
        m.add(banded(12))
        XCTAssertEqual(try XCTUnwrap(m.readoutPerBand()), 0.002, accuracy: 1e-9)
    }

    func testPairsUseTheFirstRowsMomentOnceThereIsASlope() throws {
        let m = SyncMeasurement()
        for start in [10.0, 12.0, 14.0] {
            m.add(flash(start + 1, bands: (0..<4).map {
                SyncFlash.Band(index: $0, onset: start + 0.002 * Double($0), weight: 1)
            }))
            m.add(beep(start + 0.02))
        }
        let result = try XCTUnwrap(m.result())
        XCTAssertEqual(try XCTUnwrap(result.readoutPerBand), 0.002, accuracy: 1e-9)
        XCTAssertEqual(result.residual, 0.02, accuracy: 1e-9, "against the bands' start, not the whole-frame guess a second later")
        XCTAssertEqual(result.spread, 0, accuracy: 1e-9)
    }

    // MARK: What to set

    func testAdviceTakesHowLateTheSoundWasOffTheDelayInForce() {
        let advice = SyncAdvice(code: SyncCode(fps: 60, delayMilliseconds: 100), late: 0.03)
        XCTAssertEqual(advice.storedMilliseconds, 70)
        XCTAssertEqual(advice.tabMilliseconds, -70, "the Sync tab shows the stored delay negated")
        XCTAssertEqual(advice.tabNowMilliseconds, -100)
    }

    func testTheTabsNumberIsRoundedToFives() {
        let advice = SyncAdvice(code: SyncCode(fps: 24, delayMilliseconds: 0), late: 0.033)
        XCTAssertEqual(advice.storedMilliseconds, -33)
        XCTAssertEqual(advice.tabMilliseconds, 35)
        let early = SyncAdvice(code: SyncCode(fps: 24, delayMilliseconds: 0), late: -0.012)
        XCTAssertEqual(early.storedMilliseconds, 12)
        XCTAssertEqual(early.tabMilliseconds, -10)
    }

    func testTabTextSaysInStepOrASignedNumber() {
        XCTAssertEqual(SyncAdvice.tabText(0), "In step")
        XCTAssertEqual(SyncAdvice.tabText(35), "+35 ms")
        XCTAssertEqual(SyncAdvice.tabText(-70), "\u{2212}70 ms", "a real minus sign, not a hyphen")
    }
}

// MARK: - The beep and the flash, from made-up signals

final class PlaySyncDetectorTests: XCTestCase {
    /// `seconds` of microphone at `rate`: silence, with a 1 kHz tone of
    /// `amplitude` from each of `starts` for `length` seconds, faded in over
    /// two milliseconds as the sync clip's is.
    private func microphone(seconds: Double, rate: Double, beepsAt starts: [Double],
                            length: Double = 0.042, amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            for start in starts where t >= start && t < start + length {
                let ramp = min(1, (t - start) / 0.002)
                samples[i] = amplitude * Float(ramp) * Float(sin(2 * Double.pi * 1000 * t))
            }
        }
        return samples
    }

    /// Fed in buffers of 1024, as a capture session hands them over, the
    /// first sample taken at `clock`.
    private func beeps(in samples: [Float], rate: Double, clock: Double = 0) -> [SyncBeep] {
        let detector = SyncBeepDetector(sampleRate: rate)
        var found: [SyncBeep] = []
        var at = 0
        while at < samples.count {
            let end = min(samples.count, at + 1024)
            samples[at..<end].withUnsafeBufferPointer { buffer in
                found += detector.process(buffer, time: clock + Double(at) / rate)
            }
            at = end
        }
        return found
    }

    func testABeepIsTimedToItsStart() throws {
        let found = beeps(in: microphone(seconds: 1.5, rate: 48_000, beepsAt: [0.7]), rate: 48_000, clock: 10)
        XCTAssertEqual(found.count, 1)
        let beep = try XCTUnwrap(found.first)
        XCTAssertEqual(beep.onset, 10.7, accuracy: 0.001, "within a millisecond, on the capture clock")
        XCTAssertEqual(beep.amplitude, 0.5, accuracy: 0.05)
        XCTAssertEqual(beep.held, 0.042, accuracy: 0.004, "the clip's beep is 42 ms long")
    }

    func testAnotherSampleRateReadsTheSame() throws {
        let found = beeps(in: microphone(seconds: 1.5, rate: 44_100, beepsAt: [0.8]), rate: 44_100)
        XCTAssertEqual(try XCTUnwrap(found.first).onset, 0.8, accuracy: 0.001)
    }

    func testTwoBeatsAreTwoBeeps() {
        let found = beeps(in: microphone(seconds: 4, rate: 48_000, beepsAt: [0.6, 2.6], amplitude: 0.3), rate: 48_000)
        XCTAssertEqual(found.count, 2)
        guard found.count == 2 else { return }
        XCTAssertEqual(found[0].onset, 0.6, accuracy: 0.001)
        XCTAssertEqual(found[1].onset, 2.6, accuracy: 0.001)
    }

    func testSilenceAndAClickAreNotBeeps() {
        XCTAssertTrue(beeps(in: microphone(seconds: 1.5, rate: 48_000, beepsAt: []), rate: 48_000).isEmpty)
        let click = microphone(seconds: 1.5, rate: 48_000, beepsAt: [0.8], length: 0.005)
        XCTAssertTrue(beeps(in: click, rate: 48_000).isEmpty, "five milliseconds of tone does not hold long enough")
    }

    func testNothingIsHeardWhileTheNoiseFloorIsStillBeingLearned() {
        let early = microphone(seconds: 1.5, rate: 48_000, beepsAt: [0.1])
        XCTAssertTrue(beeps(in: early, rate: 48_000).isEmpty, "the first 300 ms are for the room's own noise")
    }

    // MARK: Flash

    /// Two seconds of a dark picture at 60 frames a second, 480×270 video
    /// range luma. From `frame` the screen is white for `litFrames` frames;
    /// the first of them is lit for `share` of its exposure (the flash
    /// began partway through it), so it reads `share` as bright in linear
    /// light.
    private func flashes(startingAt frame: Int, share: Double = 1, litFrames: Int = 1, white: UInt8 = 235) -> [SyncFlash] {
        let width = 480, height = 270, fps = 60.0
        let detector = SyncFlashDetector(width: width, height: height, frameDuration: 1 / fps)
        // The code whose linear light is `share` of white's.
        let whiteUnit = (Double(white) - 16) / 219
        let partial = UInt8((16 + whiteUnit * pow(share, 1 / 2.2) * 219).rounded())
        var found: [SyncFlash] = []
        for f in 0..<120 {
            var value: UInt8 = 16
            if f == frame { value = partial }
            else if f > frame && f <= frame + litFrames { value = white }
            let luma = [UInt8](repeating: value, count: width * height)
            let flash = luma.withUnsafeBufferPointer { buffer in
                detector.process(luma: buffer.baseAddress!, bytesPerRow: width, time: Double(f) / fps)
            }
            if let flash { found.append(flash) }
        }
        return found
    }

    func testAFlashFromTheStartOfAFrameIsTimedToThatFrame() throws {
        let found = flashes(startingAt: 60)
        XCTAssertEqual(found.count, 1)
        let flash = try XCTUnwrap(found.first)
        XCTAssertEqual(flash.onset * 60, 60, accuracy: 0.05, "in frames")
        XCTAssertEqual(flash.frames, 2)
        XCTAssertEqual(flash.bands.count, 8, "the whole picture lit: every band saw it")
        XCTAssertEqual(flash.strength, 245, accuracy: 1, "white, less the ten kept back for sensor noise")
    }

    func testAHalfLitFirstFrameMeansTheFlashBeganHalfWayThroughIt() throws {
        let half = try XCTUnwrap(flashes(startingAt: 60, share: 0.5).first)
        XCTAssertEqual(half.onset * 60, 60.5, accuracy: 0.05)
        let quarter = try XCTUnwrap(flashes(startingAt: 60, share: 0.25).first)
        XCTAssertEqual(quarter.onset * 60, 60.75, accuracy: 0.05, "a quarter lit: it began three quarters of the way in")
    }

    func testALightLeftOnIsTheRoomNotAFlash() {
        XCTAssertTrue(flashes(startingAt: 60, litFrames: 50).isEmpty, "longer than a fifth of a second is the scene changing")
    }

    func testNoFlashWhileWarmingUpOrFromAFaintFlicker() {
        XCTAssertTrue(flashes(startingAt: 10).isEmpty, "the first half second sets the baseline")
        XCTAssertTrue(flashes(startingAt: 60, white: 20).isEmpty, "four codes above black is under the noise margin")
    }
}
