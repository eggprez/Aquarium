//  The Apple TV player screen: mpv's picture, and the app's own controls over
//  it. Presented full screen by `RootView` and the title screen whenever
//  `PlayerModel.isActive`.

#if os(tvOS)

import SwiftUI

struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoHost(view: player.videoView)
                .ignoresSafeArea()

            if player.isBuffering, player.errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if let message = player.errorMessage {
                ErrorCard(message: message)
            }
        }
        .onPlayPauseCommand { player.togglePlayPause() }
        .onMoveCommand { direction in
            switch direction {
            case .left: player.seek(by: -10)
            case .right: player.seek(by: 10)
            default: break
            }
        }
        .onExitCommand { player.stop(reason: "menu") }
    }
}

/// Puts the model's video view on screen. The view outlives the screen — mpv
/// was created against its layer — so it is moved into each new container
/// rather than made anew.
private struct VideoHost: UIViewRepresentable {
    let view: MPVVideoView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds
            container.addSubview(view)
        }
    }
}

private struct ErrorCard: View {
    @Environment(PlayerModel.self) private var player
    let message: String

    var body: some View {
        VStack(spacing: 28) {
            Text("Couldn't play this")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textBody)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            HStack(spacing: 30) {
                if player.canRetry {
                    Button("Try again") { Task { await player.retry() } }
                }
                Button("Close") { player.stop(reason: "error card") }
            }
        }
        .padding(60)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .focusSection()
    }
}

#endif
