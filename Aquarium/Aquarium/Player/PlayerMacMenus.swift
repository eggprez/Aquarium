//  What the Mac player offers from its menus, written once.
//
//  On a Mac the standing playback choices — quality, the file's audio and
//  subtitle tracks, the audio offset, the sleep timer, fill — belong in three
//  places at once: the Playback menu in the menu bar, where they gain key
//  equivalents and can be found without knowing where to look; a right-click
//  on the picture, which is where a Mac user asks "what can I do with this";
//  and AVKit's own action button in its floating controls, when it draws one.
//  The first two are SwiftUI menus and share `PlayerMenuItems`; the third is
//  an `NSMenu`, built by `PlayerActionMenu` from the same model each time it
//  opens. Nothing here is a second copy of a decision — every item calls the
//  same `PlayerModel` method the iOS pills and the tvOS panel call.
//
//  `PlayerMacState` is the little that a menu bar command needs to reach and
//  a view owns: the window, so Full Screen and Picture in Picture can act on
//  it; whether the stream inspector and the delay popover are up; and whether
//  the pointer has moved lately, which is what fades the app's own row of
//  controls in step with AVKit's.

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - State the menus and the window share

@MainActor @Observable
final class PlayerMacState {
    static let shared = PlayerMacState()

    /// The player's window, registered by `PlayerWindow` once it has one.
    /// Weak: the window is AppKit's, and goes away when the scene does.
    @ObservationIgnored weak var window: NSWindow?

    /// Playback ▸ Stream Info (⌘I): the inspector beside the picture.
    var showsStreamInfo = false

    /// Playback ▸ Audio Sync ▸ Adjust Audio Delay…: the popover with the
    /// stepper, over the picture it is being set for.
    var showsAudioDelay = false

    /// Whether the app's own row over the picture is showing. Follows the
    /// pointer: on when it moves, off again a couple of seconds after it
    /// stops, which is the clock AVKit's floating controls keep too.
    private(set) var controlsVisible = true

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity: ContinuousClock.Instant?

    /// The last subtitle track that was on, so the C key can bring the same
    /// one back rather than always the first in the list.
    @ObservationIgnored private var lastSubtitle: TrackOption.ID?

    /// How long the row stays after the pointer stops moving.
    private static let idle: Duration = .milliseconds(2500)

    // MARK: Pointer

    /// The pointer moved over the picture: show the row and restart the clock.
    func noteActivity() {
        if !controlsVisible { controlsVisible = true }
        // The pointer reports dozens of moves a second; the clock only
        // needs restarting a few times a second to be right.
        let now = ContinuousClock.now
        if let lastActivity, hideTask != nil, now - lastActivity < .milliseconds(200) { return }
        lastActivity = now
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idle)
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    /// The pointer left the picture: the row goes with it.
    func pointerLeft() {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = false
    }

    // MARK: Window

    func toggleFullScreen() {
        (window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
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

    /// The reach of the audio offset, either way: the same half second the
    /// menu presets and the tvOS strip stop at. A stream whose picture is
    /// held back rather than composed can only go earlier — see
    /// `PlayerModel.canDelayAudioLater`.
    nonisolated static let delayReach = 500

    /// ⌥[ / ⌥]: ten milliseconds, a fraction of a frame.
    func nudgeAudioDelay(_ player: PlayerModel, by delta: Int) {
        guard player.canDelayAudio else { return }
        let upper = player.canDelayAudioLater ? Self.delayReach : 0
        let target = min(max(player.audioDelayMilliseconds + delta, -Self.delayReach), upper)
        guard target != player.audioDelayMilliseconds else { return }
        player.setAudioDelay(milliseconds: target)
    }

    /// ⌥0.
    func resetAudioDelay(_ player: PlayerModel) {
        guard player.audioDelayMilliseconds != 0 else { return }
        player.setAudioDelay(milliseconds: 0)
    }
}

// MARK: - The shared SwiftUI menu content

/// Quality, Audio, Subtitles, Audio Sync, Audio Delay, Sleep and Fill Screen,
/// as submenus with real check marks. Placed in the Playback menu and in the
/// picture's context menu alike.
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
        if !player.isLocal, !player.isLive {
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

        // The file's own tracks, from what the server says it contains —
        // AVKit's menu only knows the one a transcode carried. See
        // `PlayerModel.audioOptions`. One track is not a choice.
        let audio = player.audioOptions
        if audio.count > 1 {
            Menu("Audio") {
                Picker("Audio", selection: audioBinding) {
                    ForEach(audio) { option in
                        Text(trackTitle(option)).tag(option.id as TrackOption.ID?)
                    }
                }
                .pickerStyle(.inline)
            }
        }

        let subtitles = player.subtitleOptions
        if !subtitles.isEmpty {
            Menu("Subtitles") {
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
            }
        }

        // The repairs, ahead of the two settings under them: sleep and fill
        // are preferences set when nothing is wrong, and this is the group
        // opened when something is.
        Menu("Audio Sync") {
            Button("Resync Audio") { player.resyncAudio() }
                .disabled(!player.canResync)
            Button("Re-encode This Stream") { Task { await player.reencodeForSync() } }
                .disabled(!player.canReencodeForSync)
            Divider()
            Button("Adjust Audio Delay…") { state.showsAudioDelay = true }
                .disabled(!player.isActive)
        }

        Menu("Audio Delay") {
            Button("Sound 10 ms Earlier") { state.nudgeAudioDelay(player, by: -10) }
                .keyboardShortcut(shortcut("[", .option))
                .disabled(!player.canDelayAudio)
            Button("Sound 10 ms Later") { state.nudgeAudioDelay(player, by: 10) }
                .keyboardShortcut(shortcut("]", .option))
                .disabled(!player.canDelayAudio || !player.canDelayAudioLater)
            Button("In Step") { state.resetAudioDelay(player) }
                .keyboardShortcut(shortcut("0", .option))
                .disabled(!player.canDelayAudio || player.audioDelayMilliseconds == 0)
            Divider()
            if player.canDelayAudio {
                Picker("Audio Delay", selection: delayBinding) {
                    // A value from the stepper can be any multiple of ten;
                    // one that isn't a preset is shown ticked at the top
                    // rather than leaving the menu with nothing on.
                    let current = player.audioDelayMilliseconds
                    if !PlayerModel.audioDelays.contains(current) {
                        Text(PlayerModel.audioDelayName(current)).tag(current)
                    }
                    ForEach(delayPresets, id: \.self) { milliseconds in
                        Text(PlayerModel.audioDelayName(milliseconds)).tag(milliseconds)
                    }
                }
                .pickerStyle(.inline)
            } else {
                // Offered greyed out with a reason rather than dropped:
                // somebody looking for this and finding nothing concludes
                // the app has lost it.
                Text(player.isActive && player.isOpening ? "Once the Stream Has Opened" : "Only on a Direct-Played File")
                if player.audioDelayMilliseconds != 0 {
                    Text("Set to \(PlayerModel.audioDelayShortName(player.audioDelayMilliseconds)) — not applied here")
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
            set: { Preferences.shared.fillScreen = $0 }
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

    /// Only the half of the ladder this stream can take.
    private var delayPresets: [Int] {
        player.canDelayAudioLater ? PlayerModel.audioDelays : PlayerModel.audioDelays.filter { $0 <= 0 }
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

    private var delayBinding: Binding<Int> {
        Binding(
            get: { player.audioDelayMilliseconds },
            set: { player.setAudioDelay(milliseconds: $0) }
        )
    }
}

/// The picture's right-click menu: the transport, then everything above.
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
        Button(isFullScreen ? "Exit Full Screen" : "Enter Full Screen") { state.toggleFullScreen() }
            .keyboardShortcut("f", modifiers: [])
    }

    private var isFullScreen: Bool {
        state.window?.styleMask.contains(.fullScreen) == true
    }
}

// MARK: - AVKit's action button

/// The `NSMenu` behind `AVPlayerView.actionPopUpButtonMenu`, rebuilt from the
/// model each time it opens so a sleep timer set from the menu bar is not
/// still offered here.
///
/// The button itself is AVKit's to draw or not: it belongs to the inline and
/// floating control styles, and nothing in this app decides whether it
/// appears. The menu is kept ready either way — the same menu is what a
/// right-click pops when the SwiftUI context menu can't reach the picture.
@MainActor
final class PlayerActionMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Playback")
    weak var player: PlayerModel?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }

    private func rebuild() {
        menu.removeAllItems()
        guard let player else { return }
        let state = PlayerMacState.shared

        menu.addItem(item(player.isPaused ? "Play" : "Pause") { player.togglePlayPause() })
        if let segment = player.activeSegment {
            menu.addItem(item(segment.isOutro ? "Skip Credits" : "Skip Intro", key: "s") { player.skipSegment() })
        }
        menu.addItem(.separator())

        if !player.isLocal, !player.isLive {
            let quality = NSMenu(title: "Quality")
            for choice in Quality.choices {
                let row = item(choice.label) { Task { await player.switchQuality(to: choice.maxBitrate) } }
                row.state = choice.maxBitrate == player.currentBitrate ? .on : .off
                quality.addItem(row)
            }
            menu.addItem(submenu("Quality", quality))
        }

        let audio = player.audioOptions
        if audio.count > 1 {
            let tracks = NSMenu(title: "Audio")
            for option in audio {
                let row = item(Self.trackTitle(option)) { player.selectAudio(option) }
                row.state = option.id == player.selectedAudioOption ? .on : .off
                tracks.addItem(row)
            }
            menu.addItem(submenu("Audio", tracks))
        }

        let subtitles = player.subtitleOptions
        if !subtitles.isEmpty {
            let tracks = NSMenu(title: "Subtitles")
            let off = item("Off") { player.selectSubtitles(nil) }
            off.state = player.selectedSubtitleOption == nil ? .on : .off
            tracks.addItem(off)
            tracks.addItem(.separator())
            for option in subtitles {
                let row = item(Self.trackTitle(option)) { player.selectSubtitles(option) }
                row.state = option.id == player.selectedSubtitleOption ? .on : .off
                tracks.addItem(row)
            }
            menu.addItem(submenu("Subtitles", tracks))
        }

        let sync = NSMenu(title: "Audio Sync")
        let resync = item("Resync Audio") { player.resyncAudio() }
        resync.isEnabled = player.canResync
        sync.addItem(resync)
        let reencode = item("Re-encode This Stream") { Task { await player.reencodeForSync() } }
        reencode.isEnabled = player.canReencodeForSync
        sync.addItem(reencode)
        sync.addItem(.separator())
        sync.addItem(item("Adjust Audio Delay…") { state.showsAudioDelay = true })
        menu.addItem(submenu("Audio Sync", sync))

        let delay = NSMenu(title: "Audio Delay")
        let earlier = item("Sound 10 ms Earlier", key: "[", modifiers: .option) {
            state.nudgeAudioDelay(player, by: -10)
        }
        earlier.isEnabled = player.canDelayAudio
        delay.addItem(earlier)
        let later = item("Sound 10 ms Later", key: "]", modifiers: .option) {
            state.nudgeAudioDelay(player, by: 10)
        }
        later.isEnabled = player.canDelayAudio && player.canDelayAudioLater
        delay.addItem(later)
        let reset = item("In Step", key: "0", modifiers: .option) { state.resetAudioDelay(player) }
        reset.isEnabled = player.canDelayAudio && player.audioDelayMilliseconds != 0
        delay.addItem(reset)
        delay.addItem(.separator())
        if player.canDelayAudio {
            let current = player.audioDelayMilliseconds
            let presets = player.canDelayAudioLater
                ? PlayerModel.audioDelays
                : PlayerModel.audioDelays.filter { $0 <= 0 }
            if !presets.contains(current) {
                let row = item(PlayerModel.audioDelayName(current)) {}
                row.state = .on
                delay.addItem(row)
            }
            for milliseconds in presets {
                let row = item(PlayerModel.audioDelayName(milliseconds)) {
                    player.setAudioDelay(milliseconds: milliseconds)
                }
                row.state = milliseconds == current ? .on : .off
                delay.addItem(row)
            }
        } else {
            let why = item(player.isActive && player.isOpening ? "Once the Stream Has Opened" : "Only on a Direct-Played File") {}
            why.isEnabled = false
            delay.addItem(why)
        }
        menu.addItem(submenu("Audio Delay", delay))

        let sleep = NSMenu(title: "Sleep")
        if let left = player.sleepMinutesRemaining {
            sleep.addItem(item("Cancel Sleep Timer (\(left) min left)") { player.cancelSleepTimer() })
        } else {
            for minutes in [15, 30, 60, 90] {
                sleep.addItem(item("Stop in \(minutes) Minutes") { player.setSleepTimer(minutes: minutes) })
            }
        }
        if !player.isLive {
            sleep.addItem(.separator())
            let after = item("Stop After This Episode") {
                if player.autoplayCancelled { player.resumeAutoplay() } else { player.cancelAutoplay() }
            }
            after.state = player.autoplayCancelled ? .on : .off
            sleep.addItem(after)
        }
        menu.addItem(submenu("Sleep", sleep))

        let fill = item("Fill Screen") { Preferences.shared.fillScreen.toggle() }
        fill.state = Preferences.shared.fillScreen ? .on : .off
        menu.addItem(fill)

        menu.addItem(.separator())
        let info = item("Stream Info", key: "i", modifiers: .command) { state.showsStreamInfo.toggle() }
        info.state = state.showsStreamInfo ? .on : .off
        menu.addItem(info)
    }

    private static func trackTitle(_ option: TrackOption) -> String {
        var title = option.isForced ? "\(option.label) (Forced)" : option.label
        if option.needsNewStream { title += " (reopens the stream)" }
        return title
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func item(
        _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [],
        run: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, run: run)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

/// An `NSMenuItem` that runs a closure, so a menu built from the model needs
/// no selector table.
private final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        MainActor.assumeIsolated { run() }
    }
}
#endif
