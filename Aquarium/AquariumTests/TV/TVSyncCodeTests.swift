//  The sync clip's code (`SyncCode`, drawn by Player/TV/SyncCodeOverlay.swift),
//  the per-rate delays it stands for (`PlayerModel.DelayRate`,
//  `Preferences.audioDelay(forRate:)`), and the clips the Apple TV build ships.

#if os(tvOS)
import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import Aquarium

@MainActor
final class TVSyncCodeTests: TVUnitTestCase {
    // MARK: The payload

    func testPayloadNamesVersionRateAndDelay() {
        XCTAssertEqual(SyncCode(fps: 24, delayMilliseconds: 0).payload, "AQSYNC:1:24:0")
        XCTAssertEqual(SyncCode(fps: 60, delayMilliseconds: -45).payload, "AQSYNC:1:60:-45")
        XCTAssertEqual(SyncCode(fps: 25, delayMilliseconds: 120).payload, "AQSYNC:1:25:120")
    }

    func testPayloadRoundTrips() {
        for fps in [24, 25, 30, 50, 60, 48, 120] {
            for delay in [-5000, -50, -5, 0, 5, 50, 5000] {
                let code = SyncCode(fps: fps, delayMilliseconds: delay)
                XCTAssertEqual(SyncCode(payload: code.payload), code)
            }
        }
        XCTAssertEqual(SyncCode(payload: "  AQSYNC:1:24:15\n"), SyncCode(fps: 24, delayMilliseconds: 15), "whitespace around a read")
    }

    func testOtherTextIsNotACode() {
        for text in ["", "AQSYNC", "AQSYNC:1:24", "AQSYNC:2:24:0", "XQSYNC:1:24:0", "AQSYNC:1:0:0",
                     "AQSYNC:1:-24:0", "AQSYNC:1:24:5001", "AQSYNC:1:24:-5001", "AQSYNC:1:24:0:extra",
                     "AQSYNC:1:twentyfour:0", "https://example.com"] {
            XCTAssertNil(SyncCode(payload: text), text)
        }
    }

    /// The code drawn the way the overlay draws it, read back the way a
    /// camera would: what the iPhone's Measure screen depends on.
    func testDrawnCodeReadsBack() throws {
        let payload = SyncCode(fps: 24, delayMilliseconds: -35).payload
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        let small = try XCTUnwrap(filter.outputImage)
        let scale = (300 / small.extent.width).rounded(.down)
        XCTAssertGreaterThanOrEqual(scale, 1, "a whole number of pixels per module")
        let image = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let read = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(read, [payload])
    }

    // MARK: Rates

    func testPresetsAreTheFiveClipRates() {
        XCTAssertEqual(PlayerModel.DelayRate.presets.map(\.fps), [24, 25, 30, 50, 60])
        XCTAssertTrue(PlayerModel.DelayRate(fps: 24).isPreset)
        XCTAssertFalse(PlayerModel.DelayRate(fps: 48).isPreset)
        XCTAssertEqual(PlayerModel.DelayRate(fps: 30).name, "30 fps")
        XCTAssertEqual(PlayerModel.DelayRate(fps: 25).resource, "SyncTest-25")
    }

    func testFilmAndNTSCRatesRoundToTheirPreset() {
        XCTAssertEqual(PlayerModel.DelayRate(frameRate: 23.976).fps, 24)
        XCTAssertEqual(PlayerModel.DelayRate(frameRate: 29.97).fps, 30)
        XCTAssertEqual(PlayerModel.DelayRate(frameRate: 59.94).fps, 60)
        XCTAssertEqual(PlayerModel.DelayRate(frameRate: 50).fps, 50)
        XCTAssertEqual(PlayerModel.DelayRate(frameRate: nil).fps, 60, "unknown rate: the 60 fps delay")
        XCTAssertEqual(PlayerModel.DelayRate(frameRate: 0).fps, 60)
        XCTAssertEqual(PlayerModel.DelayRate(fps: 24).clipRate, 24000.0 / 1001, accuracy: 1e-9)
        XCTAssertEqual(PlayerModel.DelayRate(fps: 30).clipRate, 30000.0 / 1001, accuracy: 1e-9)
        XCTAssertEqual(PlayerModel.DelayRate(fps: 25).clipRate, 25)
        XCTAssertLessThan(PlayerModel.DelayRate(fps: 24), PlayerModel.DelayRate(fps: 25))
    }

    func testEveryPresetClipShipsWithTheTVBuild() {
        for rate in PlayerModel.DelayRate.presets {
            XCTAssertNotNil(Bundle.main.url(forResource: rate.resource, withExtension: "mov"), "\(rate.resource).mov missing")
        }
    }

    // MARK: A delay per rate (the Apple TV's)

    func testDelaysAreKeptPerRateWithSixtyAsTheMainOne() {
        let prefs = Preferences.shared
        let saved = (prefs.audioDelay, prefs.audioDelaysByRate)
        defer { prefs.audioDelay = saved.0; prefs.audioDelaysByRate = saved.1 }
        prefs.audioDelay = 0
        prefs.audioDelaysByRate = [:]

        prefs.setAudioDelay(0.040, forRate: 24)
        prefs.setAudioDelay(-0.020, forRate: 60)
        prefs.setAudioDelay(0.015, forRate: 48)
        XCTAssertEqual(prefs.audioDelay(forRate: 24), 0.040, accuracy: 1e-9)
        XCTAssertEqual(prefs.audioDelay(forRate: 60), -0.020, accuracy: 1e-9)
        XCTAssertEqual(prefs.audioDelay, -0.020, accuracy: 1e-9, "60 fps is the main delay")
        XCTAssertEqual(prefs.audioDelay(forRate: 48), 0.015, accuracy: 1e-9, "a rate learned from a video")
        XCTAssertEqual(prefs.audioDelay(forRate: 25), 0, "nothing measured is in step")
        XCTAssertNil(prefs.audioDelaysByRate["60"], "60 lives in audioDelay, not the table")

        prefs.setAudioDelay(0.0001, forRate: 24)
        XCTAssertNil(prefs.audioDelaysByRate["24"], "in step is forgotten, not kept as zero")
    }

    func testDelaysStayOnThisDevice() {
        // A room's soundbar lag: not synced (`audio_delay` and
        // `audio_delays_by_rate` are plain defaults).
        let prefs = Preferences.shared
        let saved = prefs.audioDelaysByRate
        defer { prefs.audioDelaysByRate = saved }
        prefs.setAudioDelay(0.030, forRate: 25)
        XCTAssertEqual((UserDefaults.standard.dictionary(forKey: "audio_delays_by_rate") as? [String: Double])?["25"] ?? 0,
                       0.030, accuracy: 1e-9)
    }
}
#endif
