//  Renders the Apple TV's audio sync test clip.
//
//      swift Tools/SyncTestClip/make-sync-test.swift Aquarium/Player/TV/SyncTest.mov
//
//  A ruler of milliseconds, −300 to +300, with a line sweeping across it in
//  real time: the line crosses 0 on the frame the beep starts on, so where the
//  line is when the beep is heard is how far out the sound is. Four dots count
//  in to each beat, and a bar and a disc flash on the beat frame alone.
//
//  23.976 fps, the rate films are, so the television switches to the mode the
//  library plays in and the test measures that mode's lag. The beat is always
//  on a frame boundary (2002 samples a frame at 48 kHz), so picture and sound
//  agree to the sample. The audio is ALAC, not AAC: AAC's encoder priming
//  would move the beep ~21 ms against the picture in any player that ignored
//  the edit list, and a sync test can't carry an error of its own.
//
//  After writing, the clip is read back and every beep's first sample checked
//  against its beat frame's time.

import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let width = 1920, height = 1080
let timescale: CMTimeScale = 24000
let frameTicks: Int64 = 1001            // 23.976 fps
let framesPerCycle = 48                 // a beat every 2.002 s
let beatFrame = 24                      // mid-cycle, away from the loop point
let cycles = 15                         // ~30 s, then mpv loops it
let totalFrames = framesPerCycle * cycles
let sampleRate = 48000
let samplesPerFrame = 2002              // 48000 × 1001 / 24000
let beepHz = 1000.0

guard CommandLine.arguments.count == 2 else {
    print("usage: make-sync-test.swift <output.mov>")
    exit(1)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outURL)

// MARK: - Drawing

let blue = CGColor(srgbRed: 0.20, green: 0.45, blue: 0.74, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let dim = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)

let rulerLeft = 200.0, rulerRight = 1720.0
let rulerY = 560.0                      // from the top
let centreX = (rulerLeft + rulerRight) / 2
let pxPerMs = (rulerRight - rulerLeft) / 600

/// CoreGraphics counts up from the bottom; everything here is laid out from
/// the top, like the screen.
func y(_ top: Double) -> Double { Double(height) - top }

func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    return base
}

func text(_ ctx: CGContext, _ string: String, size: CGFloat, bold: Bool = false,
          colour: CGColor = white, x: Double, top: Double, align: Double = 0.5) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: x - bounds.width * align, y: y(top) - Double(size) * 0.75)
    CTLineDraw(line, ctx)
}

func draw(frame n: Int, into ctx: CGContext) {
    let f = n % framesPerCycle
    let fromBeat = f - beatFrame
    let ms = Double(fromBeat) * Double(frameTicks) / Double(timescale) * 1000

    ctx.setFillColor(blue)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    text(ctx, "Audio Sync", size: 96, bold: true, x: Double(width) / 2, top: 110)
    text(ctx, "SOUND EARLY · PRESS −", size: 34, bold: true, x: rulerLeft, top: 400, align: 0)
    text(ctx, "SOUND LATE · PRESS +", size: 34, bold: true, x: rulerRight, top: 400, align: 1)
    text(ctx, "−", size: 64, bold: true, x: centreX - 70, top: 382)
    text(ctx, "0", size: 64, bold: true, x: centreX, top: 382)
    text(ctx, "+", size: 64, bold: true, x: centreX + 70, top: 382)

    // The ruler: a tick every 10 ms, longer every 50, labelled every 100.
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: rulerLeft, y: y(rulerY) - 2, width: rulerRight - rulerLeft, height: 4))
    for tick in stride(from: -300, through: 300, by: 10) {
        let x = centreX + Double(tick) * pxPerMs
        let long = tick % 50 == 0
        let h = tick == 0 ? 90.0 : long ? 50.0 : 26.0
        ctx.fill(CGRect(x: x - (long ? 2 : 1.5), y: y(rulerY) - h / 2, width: long ? 4 : 3, height: h))
        if tick % 100 == 0 {
            let label = tick == 0 ? "0 ms" : tick < 0 ? "−\(-tick)" : "+\(tick)"
            text(ctx, label, size: 30, colour: dim, x: x, top: rulerY + 56)
        }
    }

    // The line, where it is against the beat — only while within the ruler.
    if abs(ms) <= 300.5 {
        let x = centreX + ms * pxPerMs
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: x - 5, y: y(rulerY) - 70, width: 10, height: 140))
    }

    // Four dots counting in, filled a quarter-second apart, cleared on the beat.
    let dotTop = 800.0
    for k in 0..<4 {
        let rect = CGRect(x: 250 + Double(k) * 110 - 36, y: y(dotTop) - 36, width: 72, height: 72)
        let filled = f < beatFrame && f >= k * 6
        ctx.setStrokeColor(white)
        ctx.setLineWidth(10)
        if filled {
            ctx.setFillColor(white)
            ctx.fillEllipse(in: rect)
        } else {
            ctx.strokeEllipse(in: rect.insetBy(dx: 5, dy: 5))
        }
    }

    // The beat: bar and disc flash for exactly one frame.
    let onBeat = fromBeat == 0
    ctx.setFillColor(white)
    let barHeight = onBeat ? 240.0 : 36.0
    ctx.fill(CGRect(x: centreX - 22, y: y(dotTop) - barHeight / 2, width: 44, height: barHeight))
    let disc = CGRect(x: 1560 - 110, y: y(dotTop) - 110, width: 220, height: 220)
    if onBeat {
        ctx.fillEllipse(in: disc)
    } else {
        ctx.setStrokeColor(dim)
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: disc.insetBy(dx: 4, dy: 4))
    }

    text(ctx, "The beep should land on the flash. Heard before it: press −. After it: press +.",
         size: 34, colour: dim, x: Double(width) / 2, top: 985)
}

// MARK: - Sound

/// The whole track, stereo Int16: a 1 kHz beep one frame long on every beat,
/// with 2 ms ramps so it clicks on neither edge. The ramp-in starts on the
/// beat's first sample.
func beepSamples() -> [Int16] {
    var out = [Int16](repeating: 0, count: totalFrames * samplesPerFrame * 2)
    let ramp = sampleRate / 500
    for cycle in 0..<cycles {
        let start = (cycle * framesPerCycle + beatFrame) * samplesPerFrame
        for i in 0..<samplesPerFrame {
            let envelope = min(1, Double(min(i, samplesPerFrame - 1 - i)) / Double(ramp))
            let value = sin(2 * .pi * beepHz * Double(i) / Double(sampleRate)) * envelope * 0.5
            let sample = Int16(value * Double(Int16.max))
            out[(start + i) * 2] = sample
            out[(start + i) * 2 + 1] = sample
        }
    }
    return out
}

// MARK: - Writing

let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)

let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 1_500_000,
        AVVideoMaxKeyFrameIntervalKey: framesPerCycle,
        AVVideoExpectedSourceFrameRateKey: 24,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoAllowFrameReorderingKey: false,
    ],
])
videoInput.expectsMediaDataInRealTime = false
// QuickTime's default of 600 can't hold 1001/24000 s: every frame time would
// be rounded, up to 0.8 ms either way.
videoInput.mediaTimeScale = timescale
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])

var layout = AudioChannelLayout()
layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatAppleLossless,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitDepthHintKey: 16,
    AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
])
audioInput.expectsMediaDataInRealTime = false

writer.add(videoInput)
writer.add(audioInput)
guard writer.startWriting() else { fatalError("start: \(writer.error!)") }
writer.startSession(atSourceTime: .zero)

let queue = DispatchQueue(label: "write")
let group = DispatchGroup()

group.enter()
var nextFrame = 0
videoInput.requestMediaDataWhenReady(on: queue) {
    while videoInput.isReadyForMoreMediaData {
        guard nextFrame < totalFrames else {
            videoInput.markAsFinished()
            group.leave()
            return
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        draw(frame: nextFrame, into: ctx)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let time = CMTime(value: Int64(nextFrame) * frameTicks, timescale: timescale)
        adaptor.append(pixels, withPresentationTime: time)
        nextFrame += 1
    }
}

let samples = beepSamples()
var asbd = AudioStreamBasicDescription(
    mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
    mBitsPerChannel: 16, mReserved: 0
)
var pcmFormat: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                               magicCookieSize: 0, magicCookie: nil, extensions: nil,
                               formatDescriptionOut: &pcmFormat)

group.enter()
let chunk = 4800
var nextSample = 0
let totalSamples = samples.count / 2
audioInput.requestMediaDataWhenReady(on: queue) {
    while audioInput.isReadyForMoreMediaData {
        guard nextSample < totalSamples else {
            audioInput.markAsFinished()
            group.leave()
            return
        }
        let count = min(chunk, totalSamples - nextSample)
        let bytes = count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + nextSample * 4, blockBuffer: block!,
                                              offsetIntoDestination: 0, dataLength: bytes)
        }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: pcmFormat!, sampleCount: count,
            presentationTimeStamp: CMTime(value: Int64(nextSample), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        audioInput.append(sampleBuffer!)
        nextSample += count
    }
}

group.wait()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("write: \(String(describing: writer.error))") }

// MARK: - Checking

/// Read the sound back as a player would, and find where each beep begins.
let asset = AVURLAsset(url: outURL)
let reader = try AVAssetReader(asset: asset)
let track = asset.tracks(withMediaType: .audio)[0]
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
])
reader.add(output)
reader.startReading()
var decoded: [Int16] = []
while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
    let length = CMBlockBufferGetDataLength(block)
    var chunk = [Int16](repeating: 0, count: length / 2)
    chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
    decoded += chunk
}
var worst = 0
var found = 0
var i = 0
while i < decoded.count / 2 {
    if decoded[i * 2] != 0 || decoded[i * 2 + 1] != 0 {
        // The ramp's first sample is 0 by construction, so the beep starts
        // one sample before the first one that isn't.
        let start = i - 1
        let expected = (found * framesPerCycle + beatFrame) * samplesPerFrame
        worst = max(worst, abs(start - expected))
        found += 1
        i = start + samplesPerFrame + 1
    } else {
        i += 1
    }
}
let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
print("wrote \(outURL.lastPathComponent): \(totalFrames) frames, \(found)/\(cycles) beeps, worst offset \(worst) samples, \(size / 1024) KB")
if found != cycles || worst > 1 { exit(2) }
