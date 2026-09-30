//  The audio delay, set over the picture it is being set for: on a Mac, a
//  popover with a stepper, from Playback ▸ Audio Sync. The Apple TV sets it
//  from the player's Sync tab.
//
//  Every click moves the number on screen at once and the stream a moment
//  after. On a direct play the offset is a composition and changing it reopens
//  the stream at its position — a second or two each time — so a run of
//  clicks is settled first and then built once. What is settled on is written
//  to `Preferences.audioDelay` and applied to everything played on this Mac.
//  See `PlayerModel.setAudioDelay`.

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
    /// Whether the number on screen is one chosen here and not yet handed to
    /// the model. Only then does putting the popover away write it: a number
    /// that merely followed the model — ⌥[ pressed with this open, a preset
    /// picked from the Playback menu — has nothing of this popover's to save,
    /// and writing it back would undo whatever moved it.
    @State private var edited = false

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
        // The offset has other routes than this popover — ⌥[ and ⌥], which
        // its own tooltip names, the menu presets, the picture's context
        // menu — and any of them can be used with it open. The number here
        // follows, and a click still waiting on its settle is dropped rather
        // than left to land on top of the newer choice. The model catching up
        // with a click of this popover's own arrives here too, and is already
        // the number on screen, so it changes nothing.
        .onChange(of: player.audioDelayMilliseconds) { _, current in
            guard current != milliseconds else { return }
            commit?.cancel()
            commit = nil
            milliseconds = current
            edited = false
        }
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
        edited = true
        commit?.cancel()
        commit = Task {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            edited = false
            player.setAudioDelay(milliseconds: clamped)
        }
    }

    /// Only a number chosen here is written. One that came from elsewhere
    /// while this was open is the model's already, and the copy taken when
    /// the popover opened is not a choice anyone made.
    private func flush() {
        commit?.cancel()
        commit = nil
        guard edited else { return }
        edited = false
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
