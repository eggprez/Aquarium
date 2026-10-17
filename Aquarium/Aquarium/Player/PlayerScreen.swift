//  The player screen on iPhone, iPad and Mac.
//
//  On an iPhone or iPad the picture is an `AVPlayerLayer` in a plain view
//  (`VideoSurface`) and everything over it is this app's own: `PlayerChrome`
//  draws the scrims, the title row with AirPlay and Picture in Picture, the
//  centre cluster, the timeline with trickplay, the pills and the panel, and
//  the moment overlays — Skip intro, Up Next, the bitrate notice, the error
//  card. It used to be `AVPlayerViewController`, whose transport could not be
//  changed, with this app's controls planted inside AVKit's view tree by
//  `TransportBarExtras`; both are gone. See `PLAYER-OVERHAUL-PLAN.md`, phase 2.
//
//  macOS still plays through `AVPlayerView` with its floating panel, plus a
//  row of this app's buttons over the picture that fades with the pointer;
//  phase 3 moves the window onto the shared chrome. What the two share is the
//  overlays (`Chrome/PlayerOverlays.swift`) and the stop this screen owes when
//  it goes away.

// The Apple TV has its own PlayerScreen, on mpv — see TV/TVPlayerScreen.swift.
#if !os(tvOS)
import AVKit
import Observation
import OSLog
import SwiftUI

struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app

    #if os(iOS)
    @State private var chrome = PlayerChromeState(showsTotalTime: !Preferences.shared.showsRemainingTime)
    @State private var trickplay = TrickplayStore()
    @State private var schedule = ChannelSchedule()
    @State private var artwork = InfoArtwork()
    @State private var pictureInPicture = PictureInPicture()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(pictureInPicture: pictureInPicture)
                .ignoresSafeArea()
            PlayerChrome(chrome: chrome, trickplay: trickplay, schedule: schedule, artwork: artwork,
                         pictureInPicture: pictureInPicture) {
                player.stop(reason: "player dismissed")
            }
        }
        // The status bar comes and goes with the controls, as in Apple's
        // player; the home indicator dims on its own over a full-screen video.
        .statusBarHidden(!chrome.controlsVisible && !player.isPaused)
        .persistentSystemOverlays(.hidden)
        // Dark whatever the app's theme: the chrome is drawn over a picture.
        .preferredColorScheme(.dark)
        .modifier(PlayerScreenLifecycle())
        // The shell is portrait on a phone; a film is the reason the phone gets
        // turned. See `OrientationLock`.
        .allowsLandscape()
    }
    #endif

    #if os(macOS)
    /// Acknowledged once and not shown again for this stream — audio keeps
    /// playing regardless, so this is an explanation, not a fault to keep
    /// nagging about.
    @State private var dismissedNoVideoNotice = false
    /// Bumped by Skip intro / Skip credits, so the segment going away by being
    /// skipped is told apart from its being played through.
    @State private var skips = 0
    /// The picture's size, for keeping the overlays clear of AVKit's floating
    /// panel by an amount that grows with the window rather than a phone's
    /// constant.
    @State private var surfaceSize: CGSize = .zero
    /// The pointer is on the app's own row, which keeps it from fading.
    @State private var hoveringRow = false
    private var mac: PlayerMacState { PlayerMacState.shared }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface()
                .ignoresSafeArea()

            // While a stream is opening at a position there is nothing on
            // screen but the first frame, and the wait can run to tens of
            // seconds while a transcode catches up. Say so.
            if player.isBuffering, player.position < 1 || player.isOpening {
                PlayerLoadingCard()
                    .allowsHitTesting(false)
            }

            if let error = player.errorMessage {
                // Centred: AVKit's panel is along the bottom of a Mac window
                // and the card is above it. Raised over everything else so its
                // buttons never hit-test to AVKit underneath.
                PlayerErrorCard(message: error)
                    .zIndex(2)
            } else if player.noVideoTrack, !dismissedNoVideoNotice {
                VStack {
                    PlayerNoVideoBanner(dismissed: $dismissedNoVideoNotice)
                        .padding(.top, 16)
                    Spacer()
                }
            }

            overlay

            VStack {
                PlayerBitrateBadge()
                    .padding(.top, 12)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
        // The picture's right-click menu: the transport and every setting the
        // Playback menu has, in the place a Mac user asks for them.
        .contextMenu { PlayerContextMenu(player: player) }
        // The app's own row fades with the pointer, on the same clock as
        // AVKit's floating panel: back on a move, gone a couple of seconds
        // after the last one, and gone at once when the pointer leaves.
        .onContinuousHover { phase in
            switch phase {
            case .active: mac.noteActivity()
            case .ended: mac.pointerLeft()
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SurfaceSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(SurfaceSizeKey.self) { surfaceSize = $0 }
        .modifier(PlayerScreenLifecycle())
    }

    // MARK: - Overlay (macOS)

    /// What is drawn over the picture: the prompts you act on once — Skip
    /// intro, Up Next — at the leading edge of the band just above the
    /// floating panel, and the app's own row of standing controls at the
    /// trailing edge, which fades with the pointer.
    @ViewBuilder
    private var overlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()

            if player.shouldShowUpNext, let next = player.upNextTitle {
                PlayerUpNextCard(title: next)
            }
            if player.activeSegment != nil {
                PlayerSkipSegmentButton(isOutro: player.activeSegment?.isOutro == true) {
                    skips += 1
                    player.skipSegment()
                }
            }

            // Quality keeps a button of its own showing the rung it is on: it is
            // the one people reach for. The row comes and goes with the pointer,
            // like AVKit's panel under it — see `PlayerMacState.noteActivity` —
            // and stays while the pointer is on it or the delay popover hangs
            // off it.
            let rowVisible = mac.controlsVisible || hoveringRow || mac.showsAudioDelay
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if !player.isLocal, !player.isLive {
                    qualityButton
                }
                extrasMenu
            }
            .onHover { hoveringRow = $0 }
            .opacity(rowVisible ? 1 : 0)
            .allowsHitTesting(rowVisible)
            .animation(.easeOut(duration: 0.25), value: rowVisible)
            // Playback ▸ Audio Sync ▸ Adjust Audio Delay… — see
            // `AudioDelayPopover`.
            .popover(isPresented: Binding(
                get: { mac.showsAudioDelay },
                set: { mac.showsAudioDelay = $0 }
            ), arrowEdge: .top) {
                AudioDelayPopover(player: player)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        // Clear of the floating panel: about 64 points tall and a little way
        // up from the edge. A constant either overflows the smallest window
        // or floats mid-picture in a big one, so it scales with the height.
        .padding(.bottom, min(max(surfaceSize.height * 0.15, 96), 128))
        .animation(.easeOut(duration: 0.2), value: player.activeSegment)
        .animation(.easeOut(duration: 0.2), value: player.shouldShowUpNext)
        .playerOverlayScheme()
    }

    /// Quality, as its own control beside the system's. The label carries the
    /// rung so the button answers the question without being opened.
    private var qualityButton: some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { player.currentBitrate },
                set: { bitrate in Task { await player.switchQuality(to: bitrate) } }
            )) {
                ForEach(Quality.choices) { choice in
                    Text(choice.label).tag(choice.maxBitrate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.footnote.weight(.semibold))
                Text(Quality.shortLabel(for: player.currentBitrate))
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.white)
        .fixedSize()
        .help("Stream Quality")
        .accessibilityLabel("Stream quality")
    }

    /// The same items as Playback in the menu bar and the picture's context
    /// menu — one list, written once. See `PlayerMenuItems`.
    private var extrasMenu: some View {
        Menu {
            PlayerMenuItems(player: player)
            Divider()
            Toggle("Stream Info", isOn: Binding(
                get: { mac.showsStreamInfo },
                set: { mac.showsStreamInfo = $0 }
            ))
        } label: {
            // A gear rather than an ellipsis: AVKit draws an ellipsis of its
            // own in the floating panel.
            Image(systemName: "gearshape")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.white)
        .fixedSize()
        .help("Playback Options")
        .accessibilityLabel("More playback options")
    }
    #endif
}

// MARK: - The stop the screen owes

/// The screen going away has to stop playback too, or a stream keeps running
/// (and keeps a transcode alive) behind the UI: the cover's own binding covers
/// every dismissal SwiftUI knows about, and this covers the rest — signing
/// out, the shell being rebuilt under it.
///
/// A moment later rather than now. `onDisappear` also fires for a view that
/// is about to come straight back — SwiftUI rebuilding the hierarchy,
/// something presented full-screen over it and removed again — and stopping
/// on the spot for one of those is a channel that opened, went black, and
/// dropped back to the guide with nothing wrong. If the screen is back within
/// the moment, `onAppear` calls this off. And it stops only the stream it
/// saw: a channel picked from the guide inside that moment is a new
/// generation, and this must not be the thing that tears it down.
private struct PlayerScreenLifecycle: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @State private var pendingStop: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { pendingStop?.cancel(); pendingStop = nil }
            .onDisappear {
                guard player.isActive else { return }
                let generation = player.streamGeneration
                pendingStop?.cancel()
                pendingStop = Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    player.stop(reason: "player screen disappeared", ifStill: generation)
                }
            }
    }
}

#if os(macOS)
/// The picture's size, read off the surface for the overlay's clearance.
private struct SurfaceSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
#endif

// MARK: - Overlay styling, per platform

extension View {
    /// What the overlays sit on. On a Mac, a material in the dark scheme, so
    /// they match AVKit's floating panel; elsewhere the black wash the
    /// phone's and the television's controls use.
    func overlayBackdrop<S: InsettableShape>(_ shape: S, opacity: Double) -> some View {
        #if os(macOS)
        background(.regularMaterial, in: shape)
        #else
        background(.black.opacity(opacity), in: shape)
        #endif
    }

    /// The overlays read as part of the dark HUD whatever the app's theme.
    @ViewBuilder
    func playerOverlayScheme() -> some View {
        #if os(macOS)
        environment(\.colorScheme, .dark)
        #else
        self
        #endif
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

// MARK: - The AVKit surface (macOS)

#if os(macOS)
struct VideoSurface: NSViewRepresentable {
    @Environment(PlayerModel.self) private var player

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = (player.engine as? AVEngine)?.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        // Off by default on AppKit's player view, unlike UIKit's controller.
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
        // Speed belongs to AVKit's own control, on the Mac as on the phone.
        view.speeds = PlayerModel.speeds.map {
            AVPlaybackSpeed(rate: Float($0), localizedName: PlayerModel.speedName($0))
        }
        // Pinch to look closer at the picture, which AVKit leaves off unless
        // asked for; Live Text over a paused frame is on by default and is
        // said so here rather than left to the default.
        view.allowsMagnification = true
        view.allowsVideoFrameAnalysis = true
        // Picture in Picture takes the window away and brings it back — see
        // the delegate methods below.
        view.pictureInPictureDelegate = context.coordinator
        context.coordinator.attach(view, player: player)
        context.coordinator.applyLiveChrome(for: player, to: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.videoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
        context.coordinator.attach(view, player: player)
        context.coordinator.applyLiveChrome(for: player, to: view)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The AppKit half: what AVKit calls back about, and the events a Mac
    /// player answers that SwiftUI has no modifier for.
    @MainActor
    final class Coordinator: NSObject, AVPlayerViewPictureInPictureDelegate {
        private weak var view: AVPlayerView?
        private weak var player: PlayerModel?

        /// AVKit's action button, when its control style draws one, opens
        /// the same menu the Playback menu and the right-click carry. See
        /// `PlayerActionMenu`.
        private let actionMenu = PlayerActionMenu()

        private var monitor: Any?

        /// What `applyLiveChrome` last set, so the control style is only
        /// assigned when the answer changes: assigning it rebuilds AVKit's
        /// controls, and a channel plays for hours through an unbounded
        /// number of SwiftUI updates.
        private var lastLive: Bool?

        /// Seconds of sideways scroll not yet turned into a seek — see
        /// `scroll`.
        private var pendingSeek: Double = 0

        /// Whether the window was put away for Picture in Picture and owes a
        /// return.
        private var hiddenForPiP = false

        func attach(_ view: AVPlayerView, player: PlayerModel) {
            self.view = view
            self.player = player
            actionMenu.player = player
            if view.actionPopUpButtonMenu !== actionMenu.menu {
                view.actionPopUpButtonMenu = actionMenu.menu
            }
            guard monitor == nil else { return }
            // A local monitor rather than an NSView subclass under the
            // player view: AVKit's view takes the events first, and what it
            // does not use — scrolls, a double-click on the picture, the
            // pointer moving — still passes through here on the way.
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .mouseMoved, .leftMouseUp]
            ) { [weak self] event in
                // AppKit calls a local monitor on the main thread. The result
                // goes out through a local because NSEvent isn't Sendable and
                // `assumeIsolated` won't return one.
                nonisolated(unsafe) var result: NSEvent? = event
                MainActor.assumeIsolated { result = self?.handle(event) ?? event }
                return result
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// What a live channel gets of the controls: the minimal style,
        /// which is play/pause and nothing to scrub. A channel has no
        /// timeline, and AVKit's floating panel on a Mac draws one
        /// regardless — there is no `requiresLinearPlayback` here to take
        /// only the scrubber away. Volume, tracks and the rest are on the
        /// keyboard, the scroll wheel and the menus.
        func applyLiveChrome(for player: PlayerModel, to view: AVPlayerView) {
            let isLive = player.isLive
            guard lastLive != isLive else { return }
            lastLive = isLive
            view.controlsStyle = isLive ? .minimal : .floating
        }

        // MARK: Events

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }
            switch event.type {
            case .mouseMoved:
                PlayerMacState.shared.noteActivity()
                return event
            case .scrollWheel:
                guard let player, player.isActive else { return event }
                return scroll(event, player: player)
            case .leftMouseUp:
                // Double-click on the picture — not on the panel's buttons —
                // is full screen, as in QuickTime Player.
                guard event.clickCount == 2, !isOverControl(event, in: view) else { return event }
                window.toggleFullScreen(nil)
                return event
            default:
                return event
            }
        }

        /// Whether the click landed on a control rather than the picture:
        /// one of AVKit's — any control, or anything inside a view AVKit
        /// names as its controls — or anything of this screen's layered over
        /// the picture.
        ///
        /// The hit test starts at the window, not at the player view. Skip
        /// Intro, Up Next's Play Now and Not Now, the quality and gear buttons
        /// and the error card's Try Again are SwiftUI, siblings of the picture
        /// in `PlayerScreen`'s stack and drawn by the hosting view above it;
        /// asked from the player view down, a test never sees them, and a
        /// quick double-click on one went to full screen as well as pressing
        /// it. Asked from the top, anything that takes the click before the
        /// picture does comes back as something other than the player view or
        /// one of its own, and that is not the picture. What those overlays
        /// leave to the picture — the loading card, the bitrate badge, the row
        /// while it is hidden — is marked not to take hits, so double-clicking through
        /// it still works.
        private func isOverControl(_ event: NSEvent, in view: AVPlayerView) -> Bool {
            guard let content = view.window?.contentView else { return false }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var hit = content.hitTest(point)
            guard let first = hit, first === view || first.isDescendant(of: view) else { return true }
            while let current = hit, current !== view {
                if current is NSControl { return true }
                if String(describing: type(of: current)).localizedCaseInsensitiveContains("control") { return true }
                hit = current.superview
            }
            return false
        }

        /// Vertical scroll is volume and two fingers sideways is a scrub, the
        /// way IINA and mpv behave. Either physical direction is read the
        /// way the trackpad is set — fingers up is louder, fingers right is
        /// forward — and momentum is ignored so a flick does not run on.
        private func scroll(_ event: NSEvent, player: PlayerModel) -> NSEvent? {
            guard event.momentumPhase == [] else { return nil }
            if event.phase == .ended || event.phase == .cancelled {
                flushSeek(player)
                return nil
            }
            let inverted = event.isDirectionInvertedFromDevice
            let precise = event.hasPreciseScrollingDeltas
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if abs(dx) > abs(dy) {
                guard !player.isLive else { return nil }
                let forward = inverted ? dx : -dx
                // A tenth of a second a point, five seconds a wheel notch:
                // a hand's width of trackpad is about twenty seconds.
                pendingSeek += forward * (precise ? 0.1 : 5)
                // Settled in whole seconds as the gesture runs, rather than
                // one seek per event, which the player would have to queue.
                if abs(pendingSeek) >= 2 || event.phase == [] { flushSeek(player) }
                return nil
            }
            if dy != 0 {
                let up = inverted ? -dy : dy
                PlayerMacState.shared.stepVolume(player, by: up * (precise ? 0.004 : 0.05))
            }
            return nil
        }

        private func flushSeek(_ player: PlayerModel) {
            guard abs(pendingSeek) >= 0.5 else { return }
            let delta = pendingSeek
            pendingSeek = 0
            player.seek(by: delta)
        }

        // MARK: Picture in Picture

        /// Never: the window is this app's to put away, and putting it away
        /// through AVKit would take the player with it.
        nonisolated func playerViewShouldAutomaticallyDismissAtPicture(
            inPictureStart playerView: AVPlayerView
        ) -> Bool {
            false
        }

        /// The picture is in its own floating window now; the player window
        /// behind it would be a black rectangle, so it goes away until the
        /// picture comes back. A full-screen window is left where it is —
        /// there is no hiding one gracefully.
        nonisolated func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
            MainActor.assumeIsolated {
                guard let window = playerView.window, !window.styleMask.contains(.fullScreen) else { return }
                hiddenForPiP = true
                window.orderOut(nil)
            }
        }

        /// The button in the floating window that means "back to the app".
        nonisolated func playerView(
            _ playerView: AVPlayerView,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            MainActor.assumeIsolated {
                restoreWindow(playerView)
                completionHandler(true)
            }
        }

        /// Picture in Picture ended some other way — its close button, or the
        /// stream ending. A window still hidden with a stream still playing
        /// is a player nobody can reach, so it comes back here too.
        nonisolated func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
            MainActor.assumeIsolated { restoreWindow(playerView) }
        }

        private func restoreWindow(_ playerView: AVPlayerView) {
            guard hiddenForPiP else { return }
            hiddenForPiP = false
            guard let window = playerView.window ?? PlayerMacState.shared.window,
                  player?.isActive == true else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif

#endif
