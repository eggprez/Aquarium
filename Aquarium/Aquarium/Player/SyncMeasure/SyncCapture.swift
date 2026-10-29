//  The phone's camera and microphone, run for one audio sync measurement.
//
//  One capture session carries both, so every frame and every audio buffer
//  is stamped on the same clock; the detectors in `SyncDetector.swift` do
//  the timing and this file does the camera.
//
//  The camera is set up for timing rather than for a picture. The format
//  with the highest frame rate is chosen — 240 fps on any recent iPhone —
//  because a frame is the coarsest the flash can be placed to before the
//  partial-frame reading refines it. The shutter is then locked open for
//  the whole frame: the reading rests on how much of a frame's exposure the
//  flash covered, which only means something when exposures touch end to
//  end with no gap between. Auto exposure is let settle first, so the ISO
//  that goes with the long shutter is the one the room wants, then the
//  brightest part of the picture is checked against the top of the range
//  and the ISO brought down until the television's white isn't clipped —
//  a clipped flash can't be half bright. Focus and white balance are locked
//  as well so nothing drifts under the baseline.
//
//  Frames and audio are handed to a worker on a serial queue; the QR code
//  is looked for on another, since Vision takes longer than a frame.

#if os(iOS)

import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Observation
import os
@preconcurrency import Vision

@MainActor
@Observable
final class SyncCapture {
    enum Phase: Equatable {
        case idle
        /// No permission, or no camera.
        case unavailable(String)
        case starting
        /// Letting the exposure settle, then locking it.
        case settling
        /// Running: timing flashes against beeps, and looking for the code
        /// on screen until it is read.
        case measuring
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What the television said, once read — or what was typed in.
    private(set) var code: SyncCode?
    private(set) var result: SyncResult?
    private(set) var flashes = 0
    private(set) var beeps = 0
    private(set) var pairs = 0
    private(set) var droppedFrames = 0
    /// How the camera was set, for the details.
    private(set) var camera = ""
    /// The microphone's own lag, in seconds, as the audio session reports it.
    private(set) var microphoneLatency = 0.0
    /// When measuring began, for the UI's sense of how long it has been
    /// looking for the code.
    private(set) var measuringSince: Date?

    /// How many flash–beep pairs to stop at.
    var targetPairs = 8
    /// How long to try for before stopping with what there is.
    var timeLimit: TimeInterval = 45

    nonisolated let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "aquarium.sync-capture")
    private var worker: Worker?
    private var run: Task<Void, Never>?

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "sync")

    var isRunning: Bool {
        switch phase {
        case .starting, .settling, .measuring: true
        default: false
        }
    }

    /// The rate and delay typed in by hand, for when the code can't be
    /// read; applied at once so the flash length is known from here on.
    func useManualCode(_ manual: SyncCode) {
        code = manual
        let worker = worker
        queue.async { worker?.set(code: manual) }
        if pairs >= targetPairs { finish() }
    }

    func start() {
        guard !isRunning else { return }
        result = nil
        code = nil
        flashes = 0
        beeps = 0
        pairs = 0
        droppedFrames = 0
        measuringSince = nil
        phase = .starting
        run = Task { await self.perform() }
    }

    func stop() {
        run?.cancel()
        run = nil
        let session = session
        let worker = worker
        queue.async {
            worker?.detecting = false
            if session.isRunning { session.stopRunning() }
            Self.restoreCamera(session)
        }
        if isRunning { phase = .idle }
    }

    // MARK: - The run

    private func perform() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            phase = .unavailable("Aquarium needs the camera to see the flash. Allow it in Settings → Apps → Aquarium.")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            phase = .unavailable("Aquarium needs the microphone to hear the beep. Allow it in Settings → Apps → Aquarium.")
            return
        }
        guard !Task.isCancelled else { return }
        let queue = queue
        let session = session
        let worker = Worker(queue: queue) { [weak self] event in
            Task { @MainActor in self?.take(event) }
        }
        self.worker = worker

        let setup: Result<Setup, SetupError> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.configure(session, worker: worker, queue: queue)) }
        }
        let device: AVCaptureDevice
        let frameDuration: Double
        switch setup {
        case .failure(let error):
            phase = .unavailable(error.message)
            return
        case .success(let made):
            device = made.device
            frameDuration = made.frameDuration
        }
        guard !Task.isCancelled else { return }

        phase = .settling
        // Let auto exposure, focus and white balance find the room.
        try? await Task.sleep(for: .seconds(1.0))
        guard !Task.isCancelled else { return }
        var exposure = Self.lockExposure(device, frameDuration: frameDuration)
        for _ in 0..<3 {
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            let brightest = await brightestLevel(worker)
            if brightest >= 248 {
                exposure = Self.adjustExposure(device, by: 0.6, frameDuration: frameDuration)
            } else if brightest < 140 {
                exposure = Self.adjustExposure(device, by: 1.6, frameDuration: frameDuration)
            } else {
                break
            }
        }
        Self.lockFocus(device)
        microphoneLatency = AVAudioSession.sharedInstance().inputLatency
        camera = Self.describe(device, frameDuration: frameDuration)
        Self.log.info("camera \(self.camera, privacy: .public), microphone latency \(self.microphoneLatency * 1000, format: .fixed(precision: 1)) ms")

        queue.async { worker.begin(frameDuration: frameDuration, exposure: exposure) }
        phase = .measuring
        measuringSince = .now

        try? await Task.sleep(for: .seconds(timeLimit))
        guard !Task.isCancelled else { return }
        finish()
    }

    private func take(_ event: Worker.Event) {
        switch event {
        case .flash: flashes += 1
        case .beep: beeps += 1
        case .pairs(let count):
            pairs = count
            if count >= targetPairs, code != nil { finish() }
        case .code(let found):
            if code == nil { code = found }
        case .dropped(let count): droppedFrames = count
        }
    }

    private func finish() {
        guard phase == .measuring, let worker else { return }
        run?.cancel()
        run = nil
        let session = session
        queue.async {
            worker.detecting = false
            let result = worker.measurement.result()
            session.stopRunning()
            Self.restoreCamera(session)
            Task { @MainActor in
                self.result = result
                if result != nil {
                    self.phase = .done
                } else {
                    self.phase = .failed(self.flashes == 0
                        ? "No flash was seen. Keep the whole television in the picture, and make sure a sync clip is playing."
                        : self.beeps == 0
                        ? "No beep was heard. Turn the sound up, or bring the phone nearer."
                        : "Only \(self.pairs) beat\(self.pairs == 1 ? "" : "s") lined up. Hold the phone still and try again.")
                }
            }
        }
    }

    private func brightestLevel(_ worker: Worker) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: worker.brightest) }
        }
    }

    // MARK: - The camera

    private struct Setup {
        let device: AVCaptureDevice
        let frameDuration: Double
    }

    private struct SetupError: Error {
        let message: String
    }

    /// Builds the session — the back camera at its fastest frame rate, the
    /// microphone, both outputs on the worker — and starts it. On the
    /// capture queue.
    private nonisolated static func configure(_ session: AVCaptureSession, worker: Worker, queue: DispatchQueue) -> Result<Setup, SetupError> {
        session.beginConfiguration()
        let made = build(session, worker: worker, queue: queue)
        session.commitConfiguration()
        if case .success = made {
            session.startRunning()
        }
        return made
    }

    private nonisolated static func build(_ session: AVCaptureSession, worker: Worker, queue: DispatchQueue) -> Result<Setup, SetupError> {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            return .failure(SetupError(message: "This device has no camera to measure with."))
        }
        guard let format = fastestFormat(of: device) else {
            return .failure(SetupError(message: "The camera has no format the measurement can use."))
        }
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let frameDuration = 1 / fps

        session.sessionPreset = .inputPriority
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        do {
            let cameraInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(cameraInput) else { return .failure(SetupError(message: "The camera couldn't be opened.")) }
            session.addInput(cameraInput)
            if let microphone = AVCaptureDevice.default(for: .audio) {
                let audioInput = try AVCaptureDeviceInput(device: microphone)
                if session.canAddInput(audioInput) { session.addInput(audioInput) }
            }
        } catch {
            return .failure(SetupError(message: "The camera couldn't be opened: \(error.localizedDescription)"))
        }

        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        // Every frame matters: a late one is still a timed one.
        video.alwaysDiscardsLateVideoFrames = false
        video.setSampleBufferDelegate(worker, queue: queue)
        guard session.canAddOutput(video) else { return .failure(SetupError(message: "The camera couldn't be read.")) }
        session.addOutput(video)
        if let connection = video.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        let audio = AVCaptureAudioDataOutput()
        audio.setSampleBufferDelegate(worker, queue: queue)
        if session.canAddOutput(audio) { session.addOutput(audio) }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // Televisions are the bright thing in the room: start a stop
            // under what the meter would pick.
            device.setExposureTargetBias(max(device.minExposureTargetBias, -1), completionHandler: nil)
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
        } catch {
            return .failure(SetupError(message: "The camera couldn't be set up: \(error.localizedDescription)"))
        }
        return .success(Setup(device: device, frameDuration: frameDuration))
    }

    /// The format with the highest frame rate that delivers the luma plane
    /// the detector reads; among those, the largest up to 1080p — a bigger
    /// picture only costs time.
    private nonisolated static func fastestFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter { format in
            let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                && dims.width <= 1920 && dims.height <= 1080
        }
        func rate(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        func pixels(_ f: AVCaptureDevice.Format) -> Int32 {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        return usable.max { a, b in
            rate(a) != rate(b) ? rate(a) < rate(b) : pixels(a) < pixels(b)
        }
    }

    /// Locks the shutter open for the whole frame at the ISO that keeps the
    /// exposure auto settled on. Returns the exposure in force, seconds.
    private nonisolated static func lockExposure(_ device: AVCaptureDevice, frameDuration: Double) -> Double {
        guard device.isExposureModeSupported(.custom) else { return device.exposureDuration.seconds }
        let format = device.activeFormat
        let wanted = min(frameDuration, format.maxExposureDuration.seconds)
        let duration = max(wanted, format.minExposureDuration.seconds)
        let had = device.exposureDuration.seconds
        let iso = min(max(device.iso * Float(had / duration), format.minISO), format.maxISO)
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            log.error("exposure lock: \(error.localizedDescription, privacy: .public)")
        }
        return duration
    }

    /// Scales the ISO by `factor`, and the shutter instead once the ISO is
    /// at the end of its range. Returns the exposure in force.
    private nonisolated static func adjustExposure(_ device: AVCaptureDevice, by factor: Float, frameDuration: Double) -> Double {
        guard device.isExposureModeSupported(.custom) else { return device.exposureDuration.seconds }
        let format = device.activeFormat
        var iso = device.iso * factor
        var duration = device.exposureDuration.seconds
        if iso < format.minISO {
            duration *= Double(iso / format.minISO)
            iso = format.minISO
        } else if iso > format.maxISO {
            iso = format.maxISO
        }
        duration = min(max(duration, format.minExposureDuration.seconds), min(frameDuration, format.maxExposureDuration.seconds))
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            log.error("exposure adjust: \(error.localizedDescription, privacy: .public)")
        }
        return duration
    }

    private nonisolated static func lockFocus(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()
        } catch {
            log.error("focus lock: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hands the camera back to its automatic modes once the session has
    /// stopped, so nothing else that opens it inherits a locked shutter.
    private nonisolated static func restoreCamera(_ session: AVCaptureSession) {
        for input in session.inputs {
            guard let input = input as? AVCaptureDeviceInput, input.device.hasMediaType(.video) else { continue }
            let device = input.device
            guard (try? device.lockForConfiguration()) != nil else { continue }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(0, completionHandler: nil)
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
        }
    }

    private nonisolated static func describe(_ device: AVCaptureDevice, frameDuration: Double) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return String(format: "%.0f fps · %d×%d · %.2f ms shutter · ISO %.0f",
                      1 / frameDuration, dims.width, dims.height, device.exposureDuration.seconds * 1000, device.iso)
    }

    // MARK: - The worker

    /// Takes every frame and every audio buffer on the capture queue. Its
    /// state is only ever touched there, which is what `@unchecked` stands
    /// for: the owner reaches it through `queue.async` and nowhere else.
    final class Worker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
        enum Event {
            case flash
            case beep
            case pairs(Int)
            case code(SyncCode)
            case dropped(Int)
        }

        let measurement = SyncMeasurement()
        /// Whether flashes and beeps are being timed yet: not until the
        /// exposure is locked.
        var detecting = false
        /// The brightest luma seen lately, 0–255: the 99.9th percentile of
        /// the last sampled frame, for the exposure check.
        private(set) var brightest = 0

        private let queue: DispatchQueue
        private let onEvent: (Event) -> Void
        private var flashDetector: SyncFlashDetector?
        private var beepDetector: SyncBeepDetector?
        private var frameDuration = 1.0 / 30
        private var exposure = 1.0 / 30
        private var code: SyncCode?
        private var frames = 0
        private var dropped = 0
        private var scanning = false
        private var lastScan = -1.0
        private let scanQueue = DispatchQueue(label: "aquarium.sync-scan", qos: .userInitiated)
        private var histogram = [vImagePixelCount](repeating: 0, count: 256)
        private var mono: [Float] = []

        init(queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
            self.queue = queue
            self.onEvent = onEvent
        }

        func begin(frameDuration: Double, exposure: Double) {
            self.frameDuration = frameDuration
            self.exposure = exposure
            flashDetector = nil
            detecting = true
        }

        func set(code: SyncCode) {
            self.code = code
            flashDetector?.flashDuration = Self.flashDuration(for: code)
        }

        /// One television frame: the NTSC rate for 24 and 30, as the clips
        /// are.
        private static func flashDuration(for code: SyncCode) -> Double {
            switch code.fps {
            case 24: 1001.0 / 24000
            case 30: 1001.0 / 30000
            default: 1 / Double(code.fps)
            }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if output is AVCaptureVideoDataOutput {
                video(sampleBuffer)
            } else {
                audio(sampleBuffer)
            }
        }

        func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard output is AVCaptureVideoDataOutput, detecting else { return }
            dropped += 1
            onEvent(.dropped(dropped))
        }

        private func video(_ sample: CMSampleBuffer) {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            frames += 1

            if code == nil, !scanning, time - lastScan > 0.4 {
                scan(pixels, at: time)
            }

            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
            let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)

            if !detecting || frames % 10 == 0 {
                measureBrightest(base, width: width, height: height, bytesPerRow: bytesPerRow)
            }
            guard detecting else { return }

            if flashDetector == nil {
                let fullRange = CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                let detector = SyncFlashDetector(width: width, height: height, frameDuration: frameDuration,
                                                 exposure: exposure, fullRange: fullRange)
                detector.flashDuration = code.map(Self.flashDuration(for:))
                flashDetector = detector
            }
            if let flash = flashDetector!.process(luma: base.assumingMemoryBound(to: UInt8.self), bytesPerRow: bytesPerRow, time: time) {
                measurement.add(flash)
                onEvent(.flash)
                onEvent(.pairs(measurement.pairs().count))
            }
        }

        private func measureBrightest(_ base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
            var buffer = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
            histogram.withUnsafeMutableBufferPointer { bins in
                _ = vImageHistogramCalculation_Planar8(&buffer, bins.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
            let total = histogram.reduce(0, +)
            var run: vImagePixelCount = 0
            let cut = total / 1000
            var level = 255
            while level > 0 {
                run += histogram[level]
                if run > cut { break }
                level -= 1
            }
            brightest = level
        }

        /// Looks for the code on another queue — Vision takes longer than a
        /// frame — and comes back to this one with what it found.
        private func scan(_ pixels: CVPixelBuffer, at time: Double) {
            scanning = true
            lastScan = time
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            // The buffer is read on the scan queue and only read: the camera
            // hands out a fresh one per frame.
            nonisolated(unsafe) let frame = pixels
            scanQueue.async { [weak self] in
                let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
                try? handler.perform([request])
                let found = (request.results ?? []).compactMap(\.payloadStringValue).compactMap(SyncCode.init(payload:)).first
                guard let self else { return }
                self.queue.async {
                    self.scanning = false
                    if let found, self.code == nil {
                        self.set(code: found)
                        self.onEvent(.code(found))
                    }
                }
            }
        }

        private func audio(_ sample: CMSampleBuffer) {
            guard detecting,
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
            if beepDetector == nil || beepDetector!.sampleRate != asbd.mSampleRate {
                beepDetector = SyncBeepDetector(sampleRate: asbd.mSampleRate)
            }
            var needed = 0
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed, bufferListOut: nil,
                                                                    bufferListSize: 0, blockBufferAllocator: nil,
                                                                    blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
            guard needed > 0 else { return }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            let list = raw.assumingMemoryBound(to: AudioBufferList.self)
            var block: CMBlockBuffer?
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list,
                                                                          bufferListSize: needed, blockBufferAllocator: nil,
                                                                          blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let first = buffers.first, let data = first.mData else { return }
            let channels = Int(asbd.mChannelsPerFrame)
            let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let bytesPerSample = Int(asbd.mBitsPerChannel) / 8
            guard bytesPerSample > 0 else { return }
            // One channel is enough: the beep is the same in all of them.
            let step = interleaved ? channels : 1
            let frames = Int(first.mDataByteSize) / bytesPerSample / step
            guard frames > 0 else { return }
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }

            if isFloat, bytesPerSample == 4 {
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { mono[i] = floats[i * step] }
            } else if !isFloat, bytesPerSample == 2 {
                let ints = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<frames { mono[i] = Float(ints[i * step]) / 32768 }
            } else if !isFloat, bytesPerSample == 4 {
                let ints = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<frames { mono[i] = Float(ints[i * step]) / 2_147_483_648 }
            } else {
                return
            }

            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let found = mono.withUnsafeBufferPointer { all in
                beepDetector!.process(UnsafeBufferPointer(rebasing: all[0..<frames]), time: time)
            }
            for beep in found {
                measurement.add(beep)
                onEvent(.beep)
            }
            if !found.isEmpty {
                onEvent(.pairs(measurement.pairs().count))
            }
        }
    }
}

#endif
