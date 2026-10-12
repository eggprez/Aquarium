//  Runs the iPhone app's sync detector on a Mac, against a recording or a
//  simulated camera — the same `SyncDetector.swift` the app compiles:
//
//      swiftc -O Tools/SyncMeasure/main.swift \
//          Aquarium/Player/SyncMeasure/SyncDetector.swift -o /tmp/measure-sync
//
//  (`main.swift` because a file compiled alongside another may only run
//  top-level code under that name.)
//
//      /tmp/measure-sync recording.mov [--exposure 0.004167] [--shift-audio-ms 0] [--tv-fps 60]
//          Times every flash against every beep in a movie with a sound track —
//          a phone recording of the television, or one of the sync clips
//          themselves, where the answer should be 0. `--exposure` is the
//          shutter the recording was made with, in seconds; the frame
//          duration when not given. `--shift-audio-ms` moves the sound's
//          timestamps, to check that a known offset comes back. `--tv-fps`
//          is the clip's rate, which the app reads from the code on screen.
//
//      /tmp/measure-sync --simulate [--fps 240] [--tv-fps 60] [--offset-ms 37]
//                                   [--readout 0.8] [--noise 3] [--no-flash-length]
//          Makes up a rolling-shutter camera at `fps` filming a television at
//          `tv-fps` whose beep lands `offset-ms` after its flash, with the
//          sensor taking `readout` of a frame to read its rows and `noise`
//          codes of luma noise, and checks the detector finds the offset.
//          `--no-flash-length` withholds the clip's frame length from the
//          detector, as when the code on screen couldn't be read.
//
//  Both print every pair and the median, spread and fitted readout.

import AVFoundation
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...i + 1)
    return value
}
func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

func report(_ measurement: SyncMeasurement, expected: Double?) {
    print("flashes \(measurement.flashes.count), beeps \(measurement.beeps.count)")
    for flash in measurement.flashes {
        let bands = flash.bands.map { "\($0.index):\(String(format: "%.2f", ($0.onset - flash.onset) * 1000))" }.joined(separator: " ")
        print(String(format: "  flash %9.4f s  %d frames  strength %.1f  bands[%@]", flash.onset, flash.frames, flash.strength, bands))
    }
    for beep in measurement.beeps {
        print(String(format: "  beep  %9.4f s  amplitude %.4f  held %.0f ms", beep.onset, beep.amplitude, beep.held * 1000))
    }
    guard let result = measurement.result() else {
        print("fewer than three pairs — nothing to report")
        exit(2)
    }
    for pair in result.pairs {
        print(String(format: "  pair  flash %9.4f  beep %9.4f  residual %+.2f ms", pair.flash, pair.beep, pair.residual * 1000))
    }
    let readout = result.readoutPerBand.map { String(format: "%.3f ms per band", $0 * 1000) } ?? "not fitted"
    print(String(format: "median %+.2f ms, spread ±%.2f ms over %d pairs, readout %@",
                 result.residual * 1000, result.spread * 1000, result.count, readout))
    if let expected {
        let error = result.residual * 1000 - expected
        print(String(format: "expected %+.2f ms, error %+.2f ms", expected, error))
        if abs(error) > 2 { exit(3) }
    }
}

// MARK: - Simulation

if flag("--simulate") {
    let fps = Double(option("--fps") ?? "240")!
    let tvFps = Double(option("--tv-fps") ?? "60")!
    let offset = Double(option("--offset-ms") ?? "37")! / 1000
    let readoutShare = Double(option("--readout") ?? "0.8")!
    let noise = Double(option("--noise") ?? "3")!

    let width = 480, height = 270
    let frameDuration = 1 / fps
    let exposure = frameDuration
    let readout = readoutShare * frameDuration
    let seconds = 24.0
    var flashes: [Double] = []
    for j in 0..<10 {
        let jitter = Double(j % 3) * 0.0013
        flashes.append(1.3 + 2.0 * Double(j) + jitter)
    }
    let flashLength = 1 / tvFps

    let tvRows = 68..<203, tvCols = 60..<420
    let edgeLeft = 60..<90, edgeRight = 390..<420
    let discRows = 120..<150, discCols = 300..<330

    func lit(row: Int, col: Int) -> Bool {
        guard tvRows.contains(row), tvCols.contains(col) else { return false }
        return edgeLeft.contains(col) || edgeRight.contains(col) || (discRows.contains(row) && discCols.contains(col))
    }

    var generator = SystemRandomNumberGenerator()
    func gaussian() -> Double {
        let u1 = Double.random(in: 1e-9..<1, using: &generator), u2 = Double.random(in: 0..<1, using: &generator)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    let detector = SyncFlashDetector(width: width, height: height, frameDuration: frameDuration, exposure: exposure)
    if !flag("--no-flash-length") { detector.flashDuration = flashLength }
    let measurement = SyncMeasurement()
    var buffer = [UInt8](repeating: 0, count: width * height)
    var frame = 0
    while Double(frame) * frameDuration < seconds {
        let t = Double(frame) * frameDuration
        for row in 0..<height {
            let open = t + Double(row) / Double(height) * readout
            let close = open + exposure
            // How much of this row's exposure a flash covered, 0–1.
            var share = 0.0
            for f in flashes {
                let overlap = min(close, f + flashLength) - max(open, f)
                if overlap > 0 { share += overlap / exposure }
            }
            for col in 0..<width {
                let inTV = tvRows.contains(row) && tvCols.contains(col)
                var light = inTV ? 40.0 : 10.0
                if lit(row: row, col: col) { light += (255 - 40) * share }
                let code = 16 + 219 * pow(light / 255, 1 / 2.2) + gaussian() * noise
                buffer[row * width + col] = UInt8(min(max(code, 0), 255))
            }
        }
        if let flash = buffer.withUnsafeBufferPointer({ detector.process(luma: $0.baseAddress!, bytesPerRow: width, time: t) }) {
            measurement.add(flash)
        }
        frame += 1
    }

    let sampleRate = 48000.0
    let beeper = SyncBeepDetector(sampleRate: sampleRate)
    let total = Int(seconds * sampleRate)
    var audio = [Float](repeating: 0, count: total)
    for i in 0..<total { audio[i] = Float(gaussian() * 0.002) }
    for f in flashes {
        let start = Int((f + offset) * sampleRate)
        for i in 0..<2002 where start + i < total {
            let envelope = min(1, Double(min(i, 2001 - i)) / 96)
            audio[start + i] += Float(sin(2 * .pi * 1000 * Double(i) / sampleRate) * envelope * 0.1)
        }
    }
    var at = 0
    while at < total {
        let n = min(1024, total - at)
        audio.withUnsafeBufferPointer { all in
            let slice = UnsafeBufferPointer(rebasing: all[at..<at + n])
            for beep in beeper.process(slice, time: Double(at) / sampleRate) { measurement.add(beep) }
        }
        at += n
    }
    print(String(format: "simulated %.0f fps camera, %.3f of a frame to read, %.0f fps television, beep %+.1f ms after the flash; true readout %.3f ms per band",
                 fps, readoutShare, tvFps, offset * 1000, readout / 8 * 1000))
    report(measurement, expected: offset * 1000)
    exit(0)
}

// MARK: - A recording

guard let path = arguments.first else {
    print("usage: measure-sync <recording.mov> | --simulate   (see the top of the file)")
    exit(1)
}
let exposureOption = option("--exposure").flatMap(Double.init)
let tvFpsOption = option("--tv-fps").flatMap(Double.init)
let shift = Double(option("--shift-audio-ms") ?? "0")! / 1000

let asset = AVURLAsset(url: URL(fileURLWithPath: path))
guard let video = asset.tracks(withMediaType: .video).first, let audioTrack = asset.tracks(withMediaType: .audio).first else {
    print("needs a movie with a video and an audio track")
    exit(1)
}
let measurement = SyncMeasurement()

// Video.
do {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    let frameDuration = video.minFrameDuration.seconds > 0 ? video.minFrameDuration.seconds : 1 / Double(video.nominalFrameRate)
    var detector: SyncFlashDetector?
    var frames = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        if detector == nil {
            detector = SyncFlashDetector(width: width, height: height, frameDuration: frameDuration, exposure: exposureOption)
            detector!.flashDuration = tvFpsOption.map { 1 / $0 }
            print(String(format: "video %dx%d at %.3f fps, exposure taken as %.3f ms", width, height, 1 / frameDuration, (exposureOption ?? frameDuration) * 1000))
        }
        let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        if let flash = detector!.process(luma: base, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), time: time) {
            measurement.add(flash)
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        frames += 1
    }
    print("\(frames) frames read")
}

// Audio.
do {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()
    var detector: SyncBeepDetector?
    var mono: [Float] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let channels = Int(asbd.mChannelsPerFrame)
        if detector == nil {
            detector = SyncBeepDetector(sampleRate: asbd.mSampleRate)
            print(String(format: "audio %.0f Hz, %d channel(s)", asbd.mSampleRate, channels))
        }
        let length = CMBlockBufferGetDataLength(block)
        var interleaved = [Float](repeating: 0, count: length / 4)
        interleaved.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        let frames = interleaved.count / channels
        mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += interleaved[i * channels + c] }
            mono[i] = sum / Float(channels)
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds + shift
        mono.withUnsafeBufferPointer { for beep in detector!.process($0, time: time) { measurement.add(beep) } }
    }
}

report(measurement, expected: shift == 0 ? nil : shift * 1000)
