//  The player's own window, on a Mac.
//
//  Everywhere else the player covers the screen it was opened from. A Mac has
//  room for both, and people expect to keep browsing while something plays, to
//  resize the picture, put it on another display or full screen, or float it in
//  Picture in Picture — the way QuickTime and the TV app behave. So on macOS the
//  player is a window of its own, opened when something starts playing and
//  closed when it stops. It used to be a sheet on the main window, sized to
//  nothing in particular, which AppKit laid out at about 470×150 points with no
//  way to make it bigger and nothing on it to close it.
//
//  Closing the window stops playback: `PlayerScreen`'s `onDisappear` already
//  does that for any screen that goes away while a stream is running.

#if os(macOS)
import AppKit
import SwiftUI

struct PlayerWindow: View {
    static let id = "player"

    @Environment(PlayerModel.self) private var player
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if player.isActive {
                PlayerScreen()
            } else {
                Color.black
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        .background(WindowReader(window: $window))
        .navigationTitle(player.isActive ? player.title : "Player")
        // Space, [ and ] belong to the player while this window is in front,
        // and to whatever is being typed into anywhere else — see
        // `PlaybackCommands`.
        .focusedSceneValue(\.playerWindowFocused, true)
        .onExitCommand { leave() }
        .onAppear {
            // Brought back by window restoration at launch, with nothing to play.
            if !player.isActive { dismissWindow(id: Self.id) }
        }
        .onChange(of: player.isActive) { _, active in
            if !active { dismissWindow(id: Self.id) }
        }
        .onChange(of: window) { _, window in
            window?.backgroundColor = .black
            fit(to: player.pictureSize)
        }
        .onChange(of: player.pictureSize) { _, size in fit(to: size) }
    }

    /// Escape: out of full screen if it is in it, otherwise done watching.
    private func leave() {
        if let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            player.stop(reason: "player window escape")
        }
    }

    /// Gives the window the picture's shape, so there are no bars inside it and
    /// resizing keeps it that way. The width stays where it is and the height
    /// follows, unless that would run off the screen, in which case both shrink.
    private func fit(to size: CGSize) {
        guard let window, size.width > 0, size.height > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        window.contentAspectRatio = size

        let content = window.contentRect(forFrameRect: window.frame)
        var width = content.width
        var height = width * size.height / size.width
        if let visible = window.screen?.visibleFrame {
            let chrome = window.frame.height - content.height
            let maxHeight = visible.height - chrome
            if height > maxHeight {
                height = maxHeight
                width = height * size.width / size.height
            }
        }
        guard abs(height - content.height) > 1 || abs(width - content.width) > 1 else { return }
        // Pinned at the top edge, where the title bar is, so the window grows
        // or shrinks downwards rather than jumping.
        let resized = NSRect(
            x: content.minX,
            y: content.maxY - height,
            width: width,
            height: height
        )
        window.setFrame(window.frameRect(forContentRect: resized), display: true, animate: true)
    }
}

/// Hands the hosting `NSWindow` to SwiftUI once the view is in one.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window !== window {
            DispatchQueue.main.async { window = view.window }
        }
    }
}

// MARK: - Menu commands

private struct PlayerWindowFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    /// Set by the player window while it is the key window.
    var playerWindowFocused: Bool? {
        get { self[PlayerWindowFocusedKey.self] }
        set { self[PlayerWindowFocusedKey.self] = newValue }
    }
}

/// The Playback menu.
///
/// The keys with no modifier — Space, [ and ] — are only bound while the player
/// window is in front. A menu's key equivalents are looked at before the view
/// that has focus, so bound everywhere they took the space bar from every text
/// field in the app: typing "star wars" into Search paused the film instead.
/// Skipping and stopping carry ⌘, the TV app's keys for them, and work from any
/// window while something is playing.
struct PlaybackCommands: Commands {
    let player: PlayerModel
    @FocusedValue(\.playerWindowFocused) private var inPlayer

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") { player.togglePlayPause() }
                .keyboardShortcut(bare(.space))
                .disabled(!player.isActive)
            Button("Back 10 Seconds") { player.seek(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.isActive)
            Button("Forward 10 Seconds") { player.seek(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.isActive)
            Divider()
            Button("Slower") { player.stepSpeed(-1) }
                .keyboardShortcut(bare("["))
                .disabled(!player.isActive)
            Button("Faster") { player.stepSpeed(1) }
                .keyboardShortcut(bare("]"))
                .disabled(!player.isActive)
            Divider()
            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!player.isActive)
        }
    }

    private func bare(_ key: KeyEquivalent) -> KeyboardShortcut? {
        inPlayer == true ? KeyboardShortcut(key, modifiers: []) : nil
    }
}
#endif
