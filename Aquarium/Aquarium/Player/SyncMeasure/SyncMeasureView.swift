//  Settings → Audio → Measure Apple TV sync.
//
//  Point the phone at a television playing one of the Apple TV's sync clips
//  and it says what to set the Sync tab to. The camera and microphone are
//  `SyncCapture`'s; the timing is `SyncDetector.swift`'s; this is the page:
//  a live picture with what is happening written over it, the one number
//  that matters when it is done, and the readings behind it for anyone
//  wondering whether to believe it.

#if os(iOS)

import AVFoundation
import SwiftUI

struct SyncMeasureView: View {
    @State private var capture = SyncCapture()
    /// From the phone to the television's speaker, in metres: sound takes
    /// 2.9 ms a metre, which would otherwise read as the room being late.
    @AppStorage("sync_measure_distance") private var distance = 2.5
    @State private var manualFps = 24
    @State private var manualTab = 0
    @State private var showsManual = false

    private static let speedOfSound = 343.0

    var body: some View {
        Form {
            Section {
                preview
                    .listRowInsets(EdgeInsets())
            }
            if let result = capture.result, let code = capture.code {
                resultSection(result, code: code)
            } else if capture.result != nil {
                Section {
                    Text("The beats were timed, but the phone never read the code on the screen, so it doesn't know which rate this is or what the Apple TV has set. Fill those in below and the answer appears.")
                        .font(.callout)
                    manualFields
                }
            }
            if case .failed(let message) = capture.phase {
                Section { Text(message).font(.callout) }
            }
            if case .unavailable(let message) = capture.phase {
                Section { Text(message).font(.callout) }
            }
            Section {
                Stepper(value: $distance, in: 0...15, step: 0.25) {
                    LabeledContent("Distance to the speaker", value: Measurement(value: distance, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0...1)))))
                }
                .disabled(capture.isRunning)
                Button(capture.isRunning ? "Stop" : "Measure") {
                    if capture.isRunning { capture.stop() } else { capture.start() }
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text("On the Apple TV, open Settings → Audio and press the frame rate to measure. Turn the sound up, hold the phone so the whole television is in the picture, and keep it still until the number comes up — about twenty seconds.")
            }
            if showsManual || (capture.phase == .measuring && lookingTooLong && capture.code == nil) {
                Section {
                    manualFields
                } header: {
                    Text("Can't read the code?")
                } footer: {
                    Text("The Apple TV draws a square code in the corner of the clip. If the phone can't make it out, say which rate is playing and what the Sync tab reads on the television now, and the measurement carries on.")
                }
            }
            if capture.result != nil || capture.isRunning {
                detailsSection
            }
        }
        .navigationTitle("Measure Apple TV sync")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { capture.stop() }
        .onChange(of: capture.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
    }

    private var lookingTooLong: Bool {
        guard let since = capture.measuringSince else { return false }
        return Date.now.timeIntervalSince(since) > 8
    }

    // MARK: - The picture

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            SyncPreview(session: capture.session)
                .aspectRatio(4 / 3, contentMode: .fit)
                .background(Color.black)
            if !status.isEmpty {
                Text(status)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var status: String {
        switch capture.phase {
        case .idle: ""
        case .unavailable: "Camera unavailable"
        case .starting: "Starting the camera…"
        case .settling: "Setting the exposure…"
        case .measuring:
            if let code = capture.code {
                "\(code.fps) fps · \(capture.pairs) of \(capture.targetPairs) beats"
            } else {
                "Looking for the code on screen… \(capture.pairs) beat\(capture.pairs == 1 ? "" : "s")"
            }
        case .done: "Done"
        case .failed: "Stopped"
        }
    }

    // MARK: - The answer

    private func resultSection(_ result: SyncResult, code: SyncCode) -> some View {
        let advice = SyncAdvice(code: code, late: late(result))
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set \(code.fps) fps to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(SyncAdvice.tabText(advice.tabMilliseconds))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text(advice.tabMilliseconds == advice.tabNowMilliseconds
                     ? "That is what the Sync tab reads now: the room is in step."
                     : "The Sync tab reads \(SyncAdvice.tabText(advice.tabNowMilliseconds)) now. Swipe down on the clip and press \(advice.tabMilliseconds > advice.tabNowMilliseconds ? "+" : "−") until it reads this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            if result.spread > 0.005 {
                Label("The beats disagreed by ±\(Self.ms(result.spread)). Hold the phone still, keep the television filling the picture, and measure again.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        } header: {
            Text("Result")
        } footer: {
            Text("The sound reached the phone \(Self.signedMs(late(result))) \(late(result) >= 0 ? "after" : "before") the flash, over \(result.count) beats. Plus brings the sound forward, as on the Sync tab.")
        }
    }

    /// How late the sound really was: what the phone heard, less the time
    /// it took to cross the room and the microphone's own lag.
    private func late(_ result: SyncResult) -> Double {
        result.residual - distance / Self.speedOfSound - capture.microphoneLatency
    }

    private var manualFields: some View {
        Group {
            Picker("Rate playing", selection: $manualFps) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            Stepper(value: $manualTab, in: -1000...1000, step: 5) {
                LabeledContent("Sync tab reads", value: SyncAdvice.tabText(manualTab))
            }
            Button("Use these") {
                capture.useManualCode(SyncCode(fps: manualFps, delayMilliseconds: -manualTab))
                showsManual = false
            }
        }
    }

    // MARK: - Behind the number

    private var detailsSection: some View {
        Section("Readings") {
            if let code = capture.code {
                LabeledContent("Code on screen", value: "\(code.fps) fps, Sync tab \(SyncAdvice.tabText(-code.delayMilliseconds))")
            }
            LabeledContent("Flashes seen", value: "\(capture.flashes)")
            LabeledContent("Beeps heard", value: "\(capture.beeps)")
            if !capture.camera.isEmpty {
                LabeledContent("Camera", value: capture.camera)
            }
            LabeledContent("Microphone lag", value: Self.ms(capture.microphoneLatency))
            LabeledContent("Sound travel", value: Self.ms(distance / Self.speedOfSound))
            if capture.droppedFrames > 0 {
                LabeledContent("Frames dropped", value: "\(capture.droppedFrames)")
            }
            if let result = capture.result {
                LabeledContent("Median", value: Self.signedMs(result.residual))
                LabeledContent("Spread", value: "±\(Self.ms(result.spread))")
                if let readout = result.readoutPerBand {
                    LabeledContent("Sensor readout", value: "\(Self.ms(abs(readout) * 8)) a frame")
                }
                ForEach(Array(result.pairs.enumerated()), id: \.offset) { index, pair in
                    LabeledContent("Beat \(index + 1)", value: Self.signedMs(pair.residual))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private static func signedMs(_ seconds: Double) -> String {
        String(format: "%@%.1f ms", seconds < 0 ? "−" : "+", abs(seconds) * 1000)
    }
}

/// The camera's picture, turned the way the phone is held.
private struct SyncPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = previewLayer.connection,
                  let orientation = window?.windowScene?.interfaceOrientation else { return }
            let angle: CGFloat = switch orientation {
            case .landscapeLeft: 180
            case .landscapeRight: 0
            case .portraitUpsideDown: 270
            default: 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }
}

#endif
