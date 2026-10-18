//  What the Mac player offers from its menus, written once.
//
//  On a Mac the standing playback choices — quality, the file's audio and
//  subtitle tracks, speed, the audio offset, the sleep timer, fill — belong in
//  two places at once: the Playback menu in the menu bar, where they gain key
//  equivalents and can be found without knowing where to look, and a
//  right-click on the picture, which is where a Mac user asks "what can I do
//  with this". Both are SwiftUI menus and share `PlayerMenuItems`. Nothing
//  here is a second copy of a decision — every item calls the same
//  `PlayerModel` method the chrome's menus call.
//
//  `PlayerMacState` is the little that a menu bar command needs to reach and
//  a view owns: the window, so Full Screen can act on it; the Picture in
//  Picture controller, so the menu can start it; whether the stream inspector
//  is up; whether the panel has been asked for; and whether the pointer has
//  moved lately, which is the clock the chrome's controls keep on a Mac (see
//  `PlayerChrome`).

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - State the menus and the window share

@MainActor @Observable
final class PlayerMacState {
    static let shared = PlayerMacState()

    /// The player's window, registered by `PlayerWindow` once it has one.
    /// Weak: the window is AppKit's, and goes away when the scene does.
    @ObservationIgnored weak var window: NSWindow? {
        didSet { watchFullScreen() }
    }

    /// Whether the window is full screen, kept current from AppKit's
    /// notifications so the chrome and the menus can read it without asking
    /// the window on every redraw.
    private(set) var isFullScreen = false

    /// The Picture in Picture controller over the picture, registered by the
    /// chrome while the player screen is up; the Playback menu toggles it.
    @ObservationIgnored weak var pictureInPicture: PictureInPicture?

    /// Playback ▸ Stream Info (⌘I): the inspector beside the picture.
    var showsStreamInfo = false

    /// Bumped by Playback ▸ Show Panel: the panel opens on Info, or closes
    /// if it is open.
    var togglePanelRequest = 0

    /// Whether the controls over the picture are showing. Follows the
    /// pointer: on when it moves, off again once it has rested for the
    /// Settings interval. The chrome keeps them up regardless while the
    /// stream is paused, a panel is open or the pointer is on them — see
    /// `PlayerChrome.showsControls`.
    private(set) var controlsVisible = true

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity: ContinuousClock.Instant?
    @ObservationIgnored private var fullScreenObservers: [any NSObjectProtocol] = []

    /// The last subtitle track that was on, so the C key can bring the same
    /// one back rather than always the first in the list.
    @ObservationIgnored private var lastSubtitle: TrackOption.ID?

    // MARK: Pointer

    /// The pointer moved over the picture: show the controls and restart the
    /// clock.
    func noteActivity() {
        if !controlsVisible { controlsVisible = true }
        // The pointer reports dozens of moves a second; the clock only
        // needs restarting a few times a second to be right.
        let now = ContinuousClock.now
        if let lastActivity, hideTask != nil, now - lastActivity < .milliseconds(200) { return }
        lastActivity = now
        hideTask?.cancel()
        // Settings ▸ Video ▸ Hide controls after, the same row a phone reads.
        let idle = Preferences.shared.hideControlsAfter
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(idle))
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    /// The pointer left the window: the controls go with it.
    func pointerLeft() {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = false
    }

    // MARK: Window

    /// The player's window, never another: with no player window to hand this
    /// used to fall back to the key window, and Full Screen on the menu put the
    /// main window into full screen instead. Nothing while Picture in Picture
    /// has the window put away, either — toggling it brought the window back
    /// as an empty black screen with the picture still floating elsewhere.
    func toggleFullScreen() {
        guard let window, !isHiddenForPictureInPicture else { return }
        window.toggleFullScreen(nil)
    }

    /// The player's window is put away while Picture in Picture shows the
    /// picture — ordered out, not closed and not minimised (see
    /// `PictureInPicture`). Bringing it forward then shows nothing but black;
    /// the floating picture's own button is the way back.
    var isHiddenForPictureInPicture: Bool {
        guard let window else { return false }
        return !window.isVisible && !window.isMiniaturized
    }

    private func watchFullScreen() {
        let center = NotificationCenter.default
        fullScreenObservers.forEach { center.removeObserver($0) }
        fullScreenObservers = []
        guard let window else {
            isFullScreen = false
            return
        }
        isFullScreen = window.styleMask.contains(.fullScreen)
        for (name, value) in [(NSWindow.didEnterFullScreenNotification, true),
                              (NSWindow.didExitFullScreenNotification, false)] {
            fullScreenObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = value }
            })
        }
    }

    // MARK: Picture in Picture

    /// Picture in Picture, or on mpv the hand-over to AVPlayer that gets it.
    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        let player = PlayerModel.shared
        if !pictureInPicture.isActive, player.canHandOverForPictureInPicture {
            player.handOverForPictureInPicture(pictureInPicture)
            return
        }
        pictureInPicture.toggle()
    }

    /// Whether the Picture in Picture item has anything to do.
    var canPictureInPicture: Bool {
        guard let pictureInPicture else { return false }
        return pictureInPicture.isPossible || pictureInPicture.isActive
            || PlayerModel.shared.canHandOverForPictureInPicture
    }

    // MARK: Keys

    /// ↑ / ↓: five percent a press, the same step as the keyboard's own
    /// volume keys take. Unmutes on the way up, because a press on ↑ while
    /// muted means "I want to hear this".
    func stepVolume(_ player: PlayerModel, by delta: Double) {
        player.volume = min(max(player.volume + delta, 0), 1)
        if delta > 0, player.isMuted { player.isMuted = false }
    }

    /// C: subtitles off if any are on, otherwise the track that was on last —
    /// or, the first time, the first track that isn't a forced one.
    func cycleSubtitles(_ player: PlayerModel) {
        if let current = player.selectedSubtitleOption {
            lastSubtitle = current
            player.selectSubtitles(nil)
            return
        }
        let options = player.subtitleOptions
        guard !options.isEmpty else { return }
        let next = options.first { $0.id == lastSubtitle }
            ?? options.first { !$0.isForced }
            ?? options[0]
        player.selectSubtitles(next)
    }
}

// MARK: - The shared SwiftUI menu content

/// Quality, Audio, Subtitles, Speed, Up Next, Sleep and Fill Screen, as
/// submenus with real check marks. Placed in the Playback
/// menu and in the picture's context menu alike.
///
/// `shortcut` is asked for each key equivalent rather than the keys being
/// written in, because the Playback menu binds ⌥[ and the like only while
/// the player window is in front (a menu's key equivalents beat every text
/// field in the app otherwise — see `PlaybackCommands`), while a context menu
/// shows them for reference and never binds them.
struct PlayerMenuItems: View {
    let player: PlayerModel
    var shortcut: (KeyEquivalent, EventModifiers) -> KeyboardShortcut? = { KeyboardShortcut($0, modifiers: $1) }

    private var state: PlayerMacState { PlayerMacState.shared }

    var body: some View {
        // Only for a stream the server is choosing a bitrate for: a download
        // has no rungs and a channel plays as broadcast.
        if player.offersQuality {
            Menu("Quality") {
                Picker("Quality", selection: qualityBinding) {
                    ForEach(Quality.choices) { choice in
                        Text(choice.label).tag(choice.maxBitrate)
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(!player.isActive)
        }

        // The file's own tracks, from what the server says it contains. See
        // `PlayerModel.audioOptions`.
        let audio = player.audioOptions
        Menu("Audio") {
            if audio.isEmpty {
                Text(player.isActive && player.isOpening ? "Once the Stream Has Opened" : "No Audio Tracks Listed")
            } else {
                Picker("Audio", selection: audioBinding) {
                    ForEach(audio) { option in
                        Text(trackTitle(option)).tag(option.id as TrackOption.ID?)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        .disabled(!player.isActive)

        let subtitles = player.subtitleOptions
        Menu("Subtitles") {
            if !subtitles.isEmpty {
                Picker("Subtitles", selection: subtitleBinding) {
                    Text("Off").tag(nil as TrackOption.ID?)
                    Divider()
                    ForEach(subtitles) { option in
                        Text(trackTitle(option)).tag(option.id as TrackOption.ID?)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Toggle Subtitles") { state.cycleSubtitles(player) }
                    .keyboardShortcut(shortcut("c", []))
            } else {
                Text("No Subtitle Tracks")
            }
        }
        .disabled(!player.isActive)

        if !player.isLive {
            Menu("Speed") {
                Picker("Speed", selection: speedBinding) {
                    ForEach(PlayerModel.speeds, id: \.self) { rate in
                        Text(PlayerModel.speedName(rate)).tag(rate)
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(!player.isActive)
        }

        // What was queued by hand — see `PlayerModel.queueNext` — else the
        // next few episodes the series has left. A row plays its title now;
        // for the queue, the rows above it go.
        Menu("Up Next") {
            if !player.queue.isEmpty {
                ForEach(player.queue, id: \.Id) { queued in
                    Button(PlayerModel.displayTitle(queued)) { Task { await player.playQueued(queued.Id) } }
                }
                Divider()
                Button("Clear Up Next") { player.clearQueue() }
            } else if !player.upNextList.isEmpty {
                ForEach(player.upNextList, id: \.Id) { next in
                    Button(PlayerModel.upNextRowTitle(next)) { Task { await player.playUpcoming(next) } }
                }
            } else if !player.upNextLocal.isEmpty {
                ForEach(player.upNextLocal, id: \.itemId) { record in
                    Button(record.title) { player.playLocal(record, keepShuffle: true) }
                }
            } else {
                Text("Nothing Queued")
            }
        }

        // The same film on everyone's screen — see Core/SharePlay.swift.
        if SharePlayCoordinator.shared.isActive {
            Button("Leave SharePlay") { SharePlayCoordinator.shared.leave() }
        } else if let item = player.item, !player.isLocal, !player.isLive,
                  player.engine?.capabilities.contains(.sharePlay) == true || player.canSwitchEngine(to: .apple) {
            // On mpv the stream is handed to AVPlayer first, whose player
            // the session coordinates.
            Button("Watch Together with SharePlay") {
                Task {
                    await player.prepareForSharePlay()
                    await SharePlayCoordinator.shared.share(item)
                }
            }
        }

        Menu("Sleep") {
            if let left = player.sleepMinutesRemaining {
                Button("Cancel Sleep Timer (\(left) min left)") { player.cancelSleepTimer() }
            } else {
                ForEach([15, 30, 60, 90], id: \.self) { minutes in
                    Button("Stop in \(minutes) Minutes") { player.setSleepTimer(minutes: minutes) }
                }
            }
            if !player.isLive {
                Divider()
                Toggle("Stop After This Episode", isOn: Binding(
                    get: { player.autoplayCancelled },
                    set: { if $0 { player.cancelAutoplay() } else { player.resumeAutoplay() } }
                ))
            }
        }
        .disabled(!player.isActive)

        Toggle("Fill Screen", isOn: Binding(
            get: { Preferences.shared.fillScreen },
            set: { Preferences.shared.fillScreen = $0; player.applyFraming() }
        ))
    }

    /// "English · 5.1 (reopens the stream)": said in the row rather than
    /// hidden. A track the stream doesn't carry is still the right one to
    /// pick — it costs the couple of seconds the server needs to build a
    /// stream with it in.
    private func trackTitle(_ option: TrackOption) -> String {
        var title = option.isForced ? "\(option.label) (Forced)" : option.label
        if option.needsNewStream { title += " (reopens the stream)" }
        return title
    }

    private var qualityBinding: Binding<Int?> {
        Binding(
            get: { player.currentBitrate },
            set: { bitrate in Task { await player.switchQuality(to: bitrate) } }
        )
    }

    private var audioBinding: Binding<TrackOption.ID?> {
        Binding(
            get: { player.selectedAudioOption },
            set: { id in
                guard let option = player.audioOptions.first(where: { $0.id == id }) else { return }
                player.selectAudio(option)
            }
        )
    }

    private var subtitleBinding: Binding<TrackOption.ID?> {
        Binding(
            get: { player.selectedSubtitleOption },
            set: { id in player.selectSubtitles(player.subtitleOptions.first { $0.id == id }) }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { PlayerModel.speeds.first { abs($0 - player.speed) < 0.001 } ?? 1 },
            set: { player.speed = $0 }
        )
    }
}

/// The picture's right-click menu: the transport, then everything above,
/// then the window.
struct PlayerContextMenu: View {
    let player: PlayerModel

    private var state: PlayerMacState { PlayerMacState.shared }

    var body: some View {
        Button(player.isPaused ? "Play" : "Pause") { player.togglePlayPause() }
        if let segment = player.activeSegment {
            Button(segment.isOutro ? "Skip Credits" : "Skip Intro") { player.skipSegment() }
                .keyboardShortcut("s", modifiers: [])
        }
        if player.shouldShowUpNext, player.upNextTitle != nil {
            Button("Play Next Now") { Task { await player.playNextNow() } }
        }
        Divider()
        // Shown for reference: a context menu's key equivalents are not
        // bound, the Playback menu's are.
        PlayerMenuItems(player: player)
        Divider()
        Toggle("Stream Info", isOn: Binding(
            get: { state.showsStreamInfo },
            set: { state.showsStreamInfo = $0 }
        ))
        .keyboardShortcut("i", modifiers: .command)
        if let pip = state.pictureInPicture, state.canPictureInPicture {
            Button(pip.isActive ? "Leave Picture in Picture" : "Picture in Picture") { state.togglePictureInPicture() }
                .keyboardShortcut("p", modifiers: [])
        }
        Button(state.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") { state.toggleFullScreen() }
            .keyboardShortcut("f", modifiers: [])
    }
}
#endif
