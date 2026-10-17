//  The moment overlays and the badges: things drawn over the picture that
//  come and go with their moment rather than with the controls. Skip intro /
//  Skip credits, the Up Next card, the bitrate notice, the loading card, the
//  error card, the banner for a stream with no picture, the ripple a
//  double-tap leaves, the 2× badge and the edge-drag level.
//
//  Shared by the iPhone, iPad and Mac chrome. The Mac keeps its Title Case
//  and tighter corners here, by `#if`; nothing else differs.

#if !os(tvOS)

import SwiftUI

// MARK: - Styling

extension View {
    /// What the overlays sit on: the black wash the phone's and the
    /// television's controls use.
    func overlayBackdrop<S: InsettableShape>(_ shape: S, opacity: Double) -> some View {
        background(.black.opacity(opacity), in: shape)
    }

    /// The overlays read as part of the dark HUD whatever the app's theme.
    func playerOverlayScheme() -> some View {
        environment(\.colorScheme, .dark)
    }

    /// Return and Escape, on the platforms with a keyboard to press them on.
    @ViewBuilder
    func playerDefaultAction() -> some View {
        #if os(macOS)
        keyboardShortcut(.defaultAction)
        #else
        self
        #endif
    }

    @ViewBuilder
    func playerCancelAction() -> some View {
        #if os(macOS)
        keyboardShortcut(.cancelAction)
        #else
        self
        #endif
    }
}

// MARK: - Loading

/// One line, out of the middle of the screen, while a stream is opening at a
/// position: the wait can run to tens of seconds while a transcode catches
/// up to the offset.
struct PlayerLoadingCard: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            Text(player.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let bitrate = player.currentBitrate {
                Text(Quality.shortLabel(for: bitrate))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlayBackdrop(Capsule(), opacity: 0.6)
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .playerOverlayScheme()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Error

struct PlayerErrorCard: View {
    @Environment(PlayerModel.self) private var player
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.warn)
            Text("This didn't play")
                .font(.headline)
                .foregroundStyle(.white)
            // What the stream turned out to contain, when it could be read,
            // in place of AVFoundation's own message — see `StreamDiagnosis`.
            Text(player.noVideoDetail ?? message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                if player.canRetry {
                    Button(PlayerOverlayText.label(mac: "Try Again", elsewhere: "Try again")) {
                        Task { await player.retry() }
                    }
                    .appButtonStyle(prominent: true)
                    .playerDefaultAction()
                }
                // Only for a stream the server is choosing a bitrate for.
                if player.item != nil {
                    Button(PlayerOverlayText.label(mac: "Try a Smaller Stream", elsewhere: "Try a smaller stream")) {
                        Task { await player.switchQuality(to: Quality.smallerStream(than: player.currentBitrate)) }
                    }
                    .appButtonStyle(prominent: !player.canRetry)
                }
                Button("Close") { player.stop(reason: "error card closed") }
                    .appButtonStyle()
                    .playerCancelAction()
            }
        }
        .padding(28)
        // Fully opaque, unlike the other cards: it sits where the play glyph
        // is, and at a lesser opacity the glyph showed through as a ghost.
        .overlayBackdrop(RoundedRectangle(cornerRadius: PlayerOverlayText.corner, style: .continuous), opacity: 1)
        .playerOverlayScheme()
        #if os(macOS)
        .focusedValue(\.playerKeysYielded, true)
        #endif
    }
}

// MARK: - No picture

/// At the top of the picture rather than centre stage: nothing has failed,
/// the stream is playing, there is just no picture in it to show.
struct PlayerNoVideoBanner: View {
    @Environment(PlayerModel.self) private var player
    @Binding var dismissed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("No picture in this stream")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(player.noVideoDetail ?? "Its video is in a format this device can't decode. H.264 plays from anything; H.265 only from fMP4 segments, never from MPEG-TS; MPEG-2 not at all. Changing the container alone won't help — set the server sending this channel to transcode video to H.264.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                dismissed = true
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlayBackdrop(RoundedRectangle(cornerRadius: PlayerOverlayText.corner, style: .continuous), opacity: 0.6)
        .padding(.horizontal, 16)
        .playerOverlayScheme()
    }
}

// MARK: - Up Next and skips

struct PlayerUpNextCard: View {
    @Environment(PlayerModel.self) private var player
    let title: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.isStartingNext
                 ? "Starting…"
                 : "Up next · in \(Int(player.secondsRemaining.rounded()))s")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button(PlayerOverlayText.label(mac: "Play Now", elsewhere: "Play now")) { Task { await player.playNextNow() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStrong)
                    .controlSize(.small)
                    .playerDefaultAction()
                Button(PlayerOverlayText.label(mac: "Not Now", elsewhere: "Not now")) { player.cancelAutoplay() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .playerCancelAction()
            }
        }
        .padding(14)
        .frame(maxWidth: compact ? 260 : 320, alignment: .leading)
        .overlayBackdrop(RoundedRectangle(cornerRadius: PlayerOverlayText.corner, style: .continuous), opacity: 0.65)
        .playerOverlayScheme()
    }
}

struct PlayerSkipSegmentButton: View {
    let isOutro: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                PlayerOverlayText.label(mac: isOutro ? "Skip Credits" : "Skip Intro",
                                        elsewhere: isOutro ? "Skip credits" : "Skip intro"),
                systemImage: "forward.end.fill"
            )
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlayBackdrop(Capsule(), opacity: 0.6)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(isOutro ? "Skip the credits (S)" : "Skip the intro (S)")
        .playerOverlayScheme()
    }
}

// MARK: - Bitrate

/// The stream changing bitrate on its own, said where it can't be missed and
/// gone again in a few seconds. Never takes a touch: something to read.
struct PlayerBitrateBadge: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if let notice = player.bitrateNotice, player.isActive {
                BitrateBadge(notice: notice)
                    .id(notice.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.3), value: player.bitrateNotice?.id)
    }
}

struct BitrateBadge: View {
    let notice: PlayerModel.BitrateNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isUp ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(notice.isUp ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.isUp ? "Quality up · \(notice.headline)" : "Quality down · \(notice.headline)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlayBackdrop(Capsule(), opacity: 0.62)
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .playerOverlayScheme()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gesture feedback

/// The ripple a double-tap leaves on the half of the picture it skipped
/// towards: a disc that grows and fades, the TV app's.
struct SkipRippleView: View {
    let forward: Bool
    @State private var grown = false

    var body: some View {
        GeometryReader { geo in
            Circle()
                .fill(.white.opacity(grown ? 0 : 0.22))
                .frame(width: geo.size.height * 1.4, height: geo.size.height * 1.4)
                .scaleEffect(grown ? 1 : 0.5)
                .position(x: forward ? geo.size.width + geo.size.height * 0.2 : -geo.size.height * 0.2,
                          y: geo.size.height / 2)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.5)) { grown = true }
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// "2×" while a finger holds the picture.
struct HoldSpeedBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "forward.fill")
            Text("2×")
                .monospacedDigit()
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .playerMaterial(Capsule())
        .accessibilityLabel("Playing at double speed")
    }
}

/// The brightness or volume an edge drag has reached: a glyph over a short
/// vertical bar, by the edge being dragged.
struct EdgeLevelIndicator: View {
    let level: PlayerChromeState.EdgeLevel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white)
                        .frame(height: geo.size.height * level.level)
                }
            }
            .frame(width: 5, height: 110)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .playerMaterial(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.kind == .brightness ? "Brightness" : "Volume")
        .accessibilityValue("\(Int((level.level * 100).rounded())) percent")
    }

    private var symbol: String {
        switch level.kind {
        case .brightness: level.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume: level.level == 0 ? "speaker.slash.fill" : level.level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        }
    }
}

// MARK: - Shared text and corners

enum PlayerOverlayText {
    /// Buttons are Title Case on a Mac and stay as they were elsewhere.
    static func label(mac: String, elsewhere: String) -> String {
        #if os(macOS)
        mac
        #else
        elsewhere
        #endif
    }

    /// Mac corners are tighter than a phone's cards.
    static var corner: CGFloat {
        #if os(macOS)
        10
        #else
        12
        #endif
    }
}

#endif
