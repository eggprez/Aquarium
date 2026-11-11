//  A download's subtitle file, drawn over the picture by the app.
//
//  Everywhere else subtitles are the engine's: tracks of the stream on
//  AVPlayer, anything at all on mpv. This is for the one case neither covers,
//  a subtitle file beside a download playing on AVPlayer — see
//  `PlayerModel.loadSidecar`. It follows the same two settings the engines
//  do, size and background, and lifts clear of the transport bar with them.
//
//  It is the app's drawing and not the player's, so it does not follow the
//  picture into Picture in Picture or onto an AirPlay screen.

#if !os(tvOS)
import SwiftUI

struct SubtitleFileOverlay: View {
    @Environment(PlayerModel.self) private var player
    private var prefs: Preferences { .shared }

    var body: some View {
        if player.overlaidSidecar != nil {
            GeometryReader { geo in
                // Ten times a second: a line arrives within a frame or two of
                // its time, and nothing is drawn afresh unless the words change.
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    lines(player.overlaidSubtitleText(), in: geo.size)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Where the picture is inside the screen: fitted, with bars where its
    /// shape isn't the screen's.
    private func picture(in screen: CGSize) -> CGRect {
        let size = player.pictureSize
        guard size.width > 0, size.height > 0, screen.width > 0, screen.height > 0, !prefs.fillScreen else {
            return CGRect(origin: .zero, size: screen)
        }
        let scale = min(screen.width / size.width, screen.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (screen.width - fitted.width) / 2, y: (screen.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }

    @ViewBuilder
    private func lines(_ text: String?, in screen: CGSize) -> some View {
        let frame = picture(in: screen)
        let scale = max(0.5, min(2.0, prefs.subtitleSize / 100))
        // About what AVPlayer draws its own at: a twentieth of the picture's
        // height, and never too small to read on a phone held upright.
        let size = max(15, min(frame.height * 0.055, 44)) * scale
        // Inside the picture's foot, or above the transport bar while it is up.
        let foot = screen.height - frame.maxY + frame.height * 0.05
        let lift = player.subtitlesRaised ? max(foot, min(screen.height * 0.3, 150)) : foot
        VStack {
            Spacer(minLength: 0)
            if let text {
                styled(Text(text).font(.system(size: size, weight: .semibold)))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .frame(maxWidth: min(frame.width * 0.9, screen.width - 32))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, lift)
        .animation(.easeOut(duration: 0.2), value: player.subtitlesRaised)
    }

    @ViewBuilder
    private func styled(_ text: Text) -> some View {
        switch prefs.subtitleBackground {
        case .outline:
            text
                .shadow(color: .black, radius: 0, x: 1, y: 1)
                .shadow(color: .black, radius: 0, x: -1, y: -1)
                .shadow(color: .black, radius: 0, x: 1, y: -1)
                .shadow(color: .black, radius: 0, x: -1, y: 1)
                .shadow(color: .black.opacity(0.6), radius: 2)
        case .shadow:
            text.shadow(color: .black.opacity(0.9), radius: 2, x: 1.5, y: 1.5)
        case .box:
            text
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}
#endif
