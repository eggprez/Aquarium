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

    private var state: PlayerMacState { PlayerMacState.shared }

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
        // Playback ▸ Stream Info (⌘I): what is actually arriving, beside the
        // picture rather than over it — see `StreamInfoInspector`.
        .inspector(isPresented: streamInfoBinding) {
            StreamInfoInspector(player: player)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
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
            if !active {
                state.showsAudioDelay = false
                dismissWindow(id: Self.id)
            }
        }
        .onChange(of: window) { _, window in
            window?.backgroundColor = .black
            // Full Screen (F) and Picture in Picture act on the window from
            // the menu bar and from AVKit's delegate, neither of which has a
            // view to ask — see `PlayerMacState`.
            state.window = window
            fit(to: player.pictureSize)
        }
        .onChange(of: player.pictureSize) { _, size in fit(to: size) }
        // The inspector adds a column beside the picture, and a window held
        // to the picture's shape can't fit both: the ratio is let go while it
        // is open and put back when it closes.
        .onChange(of: state.showsStreamInfo) { _, shown in
            if shown {
                window?.contentAspectRatio = .zero
            } else {
                fit(to: player.pictureSize)
            }
        }
    }

    private var streamInfoBinding: Binding<Bool> {
        Binding(get: { state.showsStreamInfo }, set: { state.showsStreamInfo = $0 })
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
              !window.styleMask.contains(.fullScreen),
              !state.showsStreamInfo else { return }
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
/// The keys with no modifier — Space, [ and ], the arrows, M, F, S and C — are
/// only bound while the player window is in front. A menu's key equivalents
/// are looked at before the view that has focus, so bound everywhere they took
/// the space bar from every text field in the app: typing "star wars" into
/// Search paused the film instead. The same goes for ⌥[ and ⌥], which type
/// quotation marks on a US keyboard. So do ⌘← and ⌘→, the TV app's keys for
/// skipping: bound everywhere they moved a film instead of the cursor to the
/// start of a line in a text field, and took Go ▸ Earlier and Later from the
/// guide, which uses the same two keys. Stopping carries ⌘ and works from any
/// window while something is playing.
///
/// The settings — Quality, Audio, Subtitles, Audio Sync, Audio Delay, Sleep,
/// Fill Screen — are `PlayerMenuItems`, shared with the picture's context menu
/// and with AVKit's action button.
struct PlaybackCommands: Commands {
    let player: PlayerModel
    @FocusedValue(\.playerWindowFocused) private var inPlayer

    private var state: PlayerMacState { PlayerMacState.shared }

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") { player.togglePlayPause() }
                .keyboardShortcut(bare(.space))
                .disabled(!player.isActive)
            Button("Back 10 Seconds") { player.seek(by: -10) }
                .keyboardShortcut(gated(.leftArrow, .command))
                .disabled(!player.isActive)
            Button("Forward 10 Seconds") { player.seek(by: 10) }
                .keyboardShortcut(gated(.rightArrow, .command))
                .disabled(!player.isActive)
            Button(player.activeSegment?.isOutro == true ? "Skip Credits" : "Skip Intro") {
                player.skipSegment()
            }
            .keyboardShortcut(bare("s"))
            .disabled(player.activeSegment == nil)
            Divider()
            Button("Slower") { player.stepSpeed(-1) }
                .keyboardShortcut(bare("["))
                .disabled(!player.isActive || player.isLive)
            Button("Faster") { player.stepSpeed(1) }
                .keyboardShortcut(bare("]"))
                .disabled(!player.isActive || player.isLive)
            Divider()
            Button("Volume Up") { state.stepVolume(player, by: 0.05) }
                .keyboardShortcut(bare(.upArrow))
                .disabled(!player.isActive)
            Button("Volume Down") { state.stepVolume(player, by: -0.05) }
                .keyboardShortcut(bare(.downArrow))
                .disabled(!player.isActive)
            Toggle("Mute", isOn: Binding(get: { player.isMuted }, set: { player.isMuted = $0 }))
                .keyboardShortcut(bare("m"))
                .disabled(!player.isActive)
            Divider()
            PlayerMenuItems(player: player, shortcut: gated)
            Divider()
            Toggle("Stream Info", isOn: Binding(
                get: { state.showsStreamInfo },
                set: { state.showsStreamInfo = $0 }
            ))
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!player.isActive)
            Button("Full Screen") { state.toggleFullScreen() }
                .keyboardShortcut(bare("f"))
                .disabled(!player.isActive)
            Divider()
            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!player.isActive)
        }
    }

    private func bare(_ key: KeyEquivalent) -> KeyboardShortcut? {
        gated(key, [])
    }

    /// Any key equivalent, bound only while the player window is in front.
    private func gated(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        inPlayer == true ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }
}
#endif
