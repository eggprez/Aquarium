//  The audio delay, set over the picture it is being set for.
//
//  A sync test in Settings — a ball dropping onto a line with a beep — was the
//  first answer, and it calibrated the wrong thing. A room's lag is not one
//  number: a soundbar takes longer over a Dolby bitstream than over PCM, a
//  television adds a different amount at 24 Hz than at 60, and the only test
//  that measures what a film actually needs is the film. So the controls come
//  here, in a strip along the bottom of the player with the picture left
//  playing above it: nudge the sound, watch a line of dialogue, nudge again.
//
//  Every press moves the number on screen at once and the stream a moment
//  after. On a direct play the offset is a composition and changing it reopens
//  the stream at its position — a second or two each time — so a run of
//  presses is settled first and then built once, rather than five reopens for
//  five presses. On anything HLS (a transcode, a channel) the picture is held
//  back instead and the swap is instant, but the same short wait costs nothing
//  there. What is settled on is written to `Preferences.audioDelay` as it goes
//  and applied to everything played on this Apple TV from then on. See
//  `PlayerModel.setAudioDelay`.

#if os(tvOS)

import SwiftUI

struct AudioDelayOverlay: View {
    let player: PlayerModel
    let dismiss: () -> Void

    /// The number on screen. Ahead of the model by the settle time below, and
    /// the thing every button moves.
    @State private var milliseconds: Int
    @State private var commit: Task<Void, Never>?
    @FocusState private var focused: Control?

    private enum Control: Hashable { case earlier50, earlier10, later10, later50, reset, done }

    /// Ten milliseconds is a fraction of a frame, and the fine step; fifty is
    /// the coarse one for a room that is a long way out.
    private static let fineStep = 10
    private static let coarseStep = 50
    /// The same reach as the menu presets. Beyond half a second the held
    /// picture's frame queue fills, and nothing in a room needs more.
    private static let reach = 500

    /// How long after the last press the stream is rebuilt.
    private static let settle: Duration = .milliseconds(350)

    init(player: PlayerModel, dismiss: @escaping () -> Void) {
        self.player = player
        self.dismiss = dismiss
        _milliseconds = State(initialValue: player.audioDelayMilliseconds)
    }

    /// Whether the sound can be moved *later* on this stream — only a file
    /// can, by composition; an HLS stream has its picture held instead, which
    /// only goes one way.
    private var offersLater: Bool { player.canDelayAudioLater }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            strip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Whatever has been pressed and not yet built goes now: a Menu press
        // is "I'm done", and the value on screen is the one to keep.
        .onExitCommand { close() }
        // The keyboard-less half of the remote. Left and right are already
        // taken by focus moving between the buttons; the play/pause key is
        // free, and pausing is a reasonable thing to want while judging a
        // line of dialogue.
        .onPlayPauseCommand { player.togglePlayPause() }
        .onDisappear { commit?.cancel() }
    }

    // MARK: - The strip

    private var strip: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("Audio delay")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
            }

            HStack(spacing: 24) {
                nudge(-Self.coarseStep, control: .earlier50)
                nudge(-Self.fineStep, control: .earlier10)

                Text(PlayerModel.audioDelayName(milliseconds))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .frame(minWidth: 560)
                    // The number is what the eye is on; the buttons either
                    // side of it move, the number must not.
                    .fixedSize()

                nudge(Self.fineStep, control: .later10)
                nudge(Self.coarseStep, control: .later50)

                Spacer(minLength: 0)

                Button("In step") { set(0) }
                    .focused($focused, equals: .reset)
                    .disabled(milliseconds == 0)
                Button("Done") { close() }
                    .focused($focused, equals: .done)
            }

            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 90)
        .padding(.top, 60)
        .padding(.bottom, 70)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { scrim }
        // One focus group, with the remote landing on the fine "earlier"
        // step: a soundbar's lag is the reason this exists, and earlier is
        // the way a soundbar's lag is corrected.
        .focusSection()
        .defaultFocus($focused, .earlier10, priority: .userInitiated)
    }

    /// Solid enough to read against a snow scene, and gone by its top edge so
    /// the picture is what is above it rather than a line ruled across it.
    /// The same reasoning as the info ribbon's, upside down.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.82), location: 0.3),
                .init(color: .black.opacity(0.92), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    /// "−50", "+10": what the button does to the number beside it, not to the
    /// picture. The sign is the sign of the delay, positive being later.
    private func nudge(_ delta: Int, control: Control) -> some View {
        Button {
            set(milliseconds + delta)
        } label: {
            Text(delta > 0 ? "+\(delta)" : "−\(-delta)")
                .monospacedDigit()
                .frame(minWidth: 80)
        }
        .focused($focused, equals: control)
        .disabled(!canReach(milliseconds + delta))
    }

    // MARK: - What it says

    private var status: String {
        if !player.canDelayAudio { return "Once the stream has opened" }
        if player.isBuffering { return "Reopening at the new offset…" }
        return "Saved for everything you play here"
    }

    private var notes: [String] {
        var out: [String] = []
        if !offersLater {
            out.append("The sound can only be moved earlier on this stream. Later needs a file the server can send untouched; here the picture is held back instead, and it only goes one way.")
        }
        let matched = player.frameRateMatchMilliseconds
        if matched != 0 {
            out.append("Plus \(PlayerModel.audioDelayShortName(matched)) for Match Frame Rate — the television switched mode for this video. That amount is set in Settings → Audio output.")
        }
        return out
    }

    // MARK: - Moving it

    private func canReach(_ value: Int) -> Bool {
        guard player.canDelayAudio else { return false }
        guard abs(value) <= Self.reach else { return false }
        return value <= 0 || offersLater
    }

    private func set(_ value: Int) {
        let clamped = min(max(value, -Self.reach), offersLater ? Self.reach : 0)
        guard clamped != milliseconds else { return }
        milliseconds = clamped
        commit?.cancel()
        commit = Task {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            player.setAudioDelay(milliseconds: clamped)
        }
    }

    private func close() {
        commit?.cancel()
        commit = nil
        if milliseconds != player.audioDelayMilliseconds {
            player.setAudioDelay(milliseconds: milliseconds)
        }
        dismiss()
    }
}

#endif

#if os(macOS)

import SwiftUI

/// The same control on a Mac: a popover over the picture with a stepper and
/// the number, opened from Playback ▸ Audio Sync ▸ Adjust Audio Delay… and
/// from the picture's context menu. Ten milliseconds a click, the presets'
/// half-second reach, and the same short settle before the stream is
/// rebuilt — see the note at the top of this file. ⌥[ and ⌥] do the same
/// from the keyboard without opening this; see `PlaybackCommands`.
struct AudioDelayPopover: View {
    let player: PlayerModel

    @Environment(\.dismiss) private var dismiss

    /// The number on screen. Ahead of the model by the settle time, and the
    /// thing the stepper moves.
    @State private var milliseconds: Int
    @State private var commit: Task<Void, Never>?

    private static let fineStep = 10
    private static let coarseStep = 50
    private static let reach = PlayerMacState.delayReach
    private static let settle: Duration = .milliseconds(350)

    init(player: PlayerModel) {
        self.player = player
        _milliseconds = State(initialValue: player.audioDelayMilliseconds)
    }

    /// Whether the sound can be moved *later* on this stream — only a file
    /// can, by composition; an HLS stream has its picture held instead, which
    /// only goes one way.
    private var offersLater: Bool { player.canDelayAudioLater }

    private var range: ClosedRange<Int> { -Self.reach...(offersLater ? Self.reach : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Delay")
                    .font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(PlayerModel.audioDelayName(milliseconds))
                    .monospacedDigit()
                    .frame(minWidth: 150, alignment: .leading)
                Spacer(minLength: 0)
                Stepper(
                    "Audio delay",
                    value: Binding(get: { milliseconds }, set: { set($0) }),
                    in: range,
                    step: Self.fineStep
                )
                .labelsHidden()
                .disabled(!player.canDelayAudio)
                .help("10 ms a step (⌥[ and ⌥])")
            }

            HStack(spacing: 8) {
                nudge(-Self.coarseStep)
                nudge(Self.coarseStep)
                Spacer(minLength: 0)
                Button("In Step") { set(0) }
                    .disabled(milliseconds == 0 || !player.canDelayAudio)
                    .help("Put the sound back in step with the picture (⌥0)")
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)

            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
        // Whatever has been clicked and not yet built goes when the popover
        // is put away, however it is put away.
        .onDisappear { flush() }
    }

    /// "−50", "+50": what the button does to the number beside it. The sign
    /// is the sign of the delay, positive being later.
    private func nudge(_ delta: Int) -> some View {
        Button(delta > 0 ? "+\(delta)" : "−\(-delta)") { set(milliseconds + delta) }
            .monospacedDigit()
            .disabled(!canReach(milliseconds + delta))
            .help(delta > 0 ? "Sound \(delta) ms later" : "Sound \(-delta) ms earlier")
    }

    private var status: String {
        if !player.canDelayAudio {
            return player.isActive && player.isOpening
                ? "Once the stream has opened"
                : "Only on a direct-played file"
        }
        if player.isBuffering { return "Reopening at the new offset…" }
        return "Saved for everything you play on this Mac"
    }

    private var notes: [String] {
        var out: [String] = []
        if player.canDelayAudio, !offersLater {
            out.append("The sound can only be moved earlier on this stream. Later needs a file the server can send untouched.")
        }
        return out
    }

    private func canReach(_ value: Int) -> Bool {
        player.canDelayAudio && range.contains(value)
    }

    private func set(_ value: Int) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard clamped != milliseconds else { return }
        milliseconds = clamped
        commit?.cancel()
        commit = Task {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            player.setAudioDelay(milliseconds: clamped)
        }
    }

    private func flush() {
        commit?.cancel()
        commit = nil
        if milliseconds != player.audioDelayMilliseconds {
            player.setAudioDelay(milliseconds: milliseconds)
        }
    }

    private func close() {
        flush()
        dismiss()
    }
}

#endif
