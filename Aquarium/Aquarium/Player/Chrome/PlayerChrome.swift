//  The controls over the picture, as one view: the scrims, the transport, the
//  panel, the moment overlays, and the state that says which of them are up.
//
//  `PlayerChromeState` is the screen's: whether the controls are showing and
//  when they go, which panel tab is open and which pill it hangs off, where a
//  scrub has got to, how far a run of skips has gone, whether a finger is
//  holding 2×. The transport, the timeline, the gesture layer and the panel
//  all read and write it rather than talking to each other.
//
//  Shared by iPhone, iPad, the Mac window and the Apple TV. Nothing here is
//  about fingers, pointers or the remote — that is `PlayerGestureLayer`, on a
//  Mac `PlayerPointer`, on a television `PlayerRemoteDriver` — and the
//  numbers that differ by platform are `PlayerMetrics`. The one thing a
//  pointer changes about the chrome itself is who keeps the clock on the
//  controls: a finger's tap or a remote's click starts `PlayerChromeState`'s,
//  a pointer's movement starts `PlayerMacState`'s, and `showsControls` reads
//  whichever the platform has. The panel is a sheet on a phone, a popover
//  off its pill on an iPad or a Mac, and on a television a card that comes
//  down from the top of the picture.

import SwiftUI

@MainActor @Observable
final class PlayerChromeState {
    var controlsVisible = true
    /// The pointer is on the title row, the centre cluster or the bottom
    /// band — which keeps the controls up on a Mac and the scroll wheel
    /// theirs. Set by the transport's hover; never true under a finger.
    var pointerOnControls = false
    /// The open panel tab; nil is closed.
    var panel: PlayerTab? {
        didSet { if panel != nil { menu = nil } }
    }
    /// The open menu card — Audio, Subtitles, Quality, Up Next off their
    /// pills, "…" off its button — drawn by the transport over the picture;
    /// nil is closed. Not the system's menus: these are the chrome's own, so
    /// they hold the controls up while they are open and go on a tap of the
    /// picture. See `PlayerMenuCard`.
    var menu: ChromeMenu?
    /// Which pill the panel hangs off, where it is a popover: the Info
    /// pill, or the "…" button for the pages opened from its menu.
    var panelAnchor: PanelAnchor = .info
    /// Where the scrubber is, while a finger is on the timeline — or, on a
    /// television, where a swipe has left it, waiting for a click.
    var scrub: Double?
    /// Where the playhead was before the last scrub jumped it: Menu goes back
    /// there while the controls are up. The remote's; nothing else sets it.
    var returnPoint: Double?
    /// Whether focus is on the panel's row of tabs, for the swipe up that
    /// closes the panel from there. The television panel writes it.
    var panelTabsFocused = false
    /// The skips in the current run, in seconds, signed.
    var skipTotal = 0
    /// The ripple a double-tap leaves; nil once it has faded.
    var ripple: SkipRipple?
    /// A finger is holding the picture for 2×.
    var holdingDoubleSpeed = false
    /// An edge drag in progress, and the level it has reached.
    var edgeLevel: EdgeLevel?
    /// The right-hand time under the timeline: the whole length rather than
    /// what is left. Starts from Settings and flips on a tap.
    var showsTotalTime: Bool

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var skipTask: Task<Void, Never>?
    @ObservationIgnored private var rippleTask: Task<Void, Never>?
    @ObservationIgnored private var edgeTask: Task<Void, Never>?
    /// The speed to go back to when the hold ends.
    @ObservationIgnored var speedBeforeHold: Double = 1

    enum PanelAnchor: Hashable { case info, more }

    enum ChromeMenu: Hashable {
        case audio, subtitles, quality, upNext, more
    }

    struct SkipRipple: Identifiable, Equatable {
        let id = UUID()
        var forward: Bool
    }

    struct EdgeLevel: Equatable {
        enum Kind { case brightness, volume }
        var kind: Kind
        /// 0...1
        var level: Double
    }

    init(showsTotalTime: Bool) {
        self.showsTotalTime = showsTotalTime
    }

    var panelOpen: Bool { panel != nil }
    var menuOpen: Bool { menu != nil }

    // MARK: Showing and hiding

    /// Bring the controls up and start the clock on them.
    func show(_ context: HideContext) {
        controlsVisible = true
        scheduleHide(context)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = false
    }

    /// Keep the controls up with no clock on them: a panel is open.
    func holdControls() {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = true
    }

    func toggle(_ context: HideContext) {
        if controlsVisible && context.mayHide { hide() } else { show(context) }
    }

    /// Hide after the Settings interval, unless something says to stay: a
    /// pause, an open panel, a scrub in progress, or VoiceOver, whose user is
    /// finding the controls by touch.
    func scheduleHide(_ context: HideContext) {
        hideTask?.cancel()
        hideTask = nil
        guard context.mayHide, scrub == nil, !panelOpen, !menuOpen, context.hideAfter > 0 else { return }
        let after = context.hideAfter
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled, let self, self.scrub == nil, !self.panelOpen, !self.menuOpen else { return }
            self.controlsVisible = false
        }
    }

    /// What `scheduleHide` has to know, read by the view that calls it.
    struct HideContext {
        var isPaused: Bool
        var voiceOver: Bool
        var hideAfter: Double
        var hasError: Bool

        var mayHide: Bool { !isPaused && !voiceOver && !hasError }
    }

    // MARK: Skips

    /// Add a skip to the run on screen: skips the same way add up, one the
    /// other way starts again, and the count goes a moment after the last.
    /// Lifted from the Apple TV player's `countSkip`.
    func countSkip(_ seconds: Int) {
        skipTotal = (skipTotal == 0 || (skipTotal > 0) == (seconds > 0)) ? skipTotal + seconds : seconds
        skipTask?.cancel()
        skipTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.skipTotal = 0
        }
    }

    func rippleOnce(forward: Bool) {
        ripple = SkipRipple(forward: forward)
        rippleTask?.cancel()
        rippleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            self?.ripple = nil
        }
    }

    // MARK: Edge drags

    func showEdgeLevel(_ level: EdgeLevel) {
        edgeLevel = level
        edgeTask?.cancel()
        edgeTask = nil
    }

    func fadeEdgeLevel() {
        edgeTask?.cancel()
        edgeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.edgeLevel = nil
        }
    }

    /// Everything that belongs to one stream.
    func resetForNewStream() {
        scrub = nil
        returnPoint = nil
        skipTotal = 0
        ripple = nil
        holdingDoubleSpeed = false
        edgeLevel = nil
        panel = nil
        menu = nil
    }
}

// MARK: - The chrome

struct PlayerChrome: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @Bindable var chrome: PlayerChromeState
    let trickplay: TrickplayStore
    let schedule: ChannelSchedule
    let artwork: InfoArtwork
    /// Picture in Picture, where the surface offers it.
    var pictureInPicture: PictureInPicture?
    let onDismiss: () -> Void

    /// Bumped by Skip intro / Skip credits, purely so the haptic has something
    /// to fire on.
    @State private var skips = 0
    /// Acknowledged once and not shown again for this stream.
    @State private var dismissedNoVideoNotice = false
    /// The chrome's size: on a Mac the window runs from 480×270 to a full
    /// display and the small metrics are for the small end of that. Held
    /// upright, a phone or an iPad keeps the title at the top of the screen
    /// and the timeline and pills at the bottom, as Apple's player does,
    /// whatever black bars the picture leaves between them.
    @State private var size: CGSize = .zero
    #if os(macOS)
    private var mac: PlayerMacState { PlayerMacState.shared }
    #endif

    /// A phone, or an iPad narrowed to one: the sheet rather than the
    /// popover, the smaller glyphs. A Mac window takes the smaller glyphs
    /// while it is narrow and never the sheet. A television is never compact.
    private var compact: Bool {
        #if os(macOS)
        size.width > 0 && size.width < PlayerMetrics.narrowWindow
        #elseif os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var usesSheet: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// The popover panel's width, where the panel is one: about three
    /// quarters of the picture, never narrower than its two columns need
    /// nor wider than reads well. The popover clamps itself to the screen.
    private var panelWidth: CGFloat {
        guard size.width > 0 else { return 640 }
        return min(max(size.width * 0.74, 560), 900)
    }

    /// On a Mac the clock is the pointer's (`PlayerMacState`), so the
    /// chrome's own never runs: `hideAfter` 0 is "no clock".
    private var hideContext: PlayerChromeState.HideContext {
        #if os(macOS)
        let after = 0.0
        #else
        let after = prefs.hideControlsAfter
        #endif
        return .init(isPaused: player.isPaused, voiceOver: voiceOver,
                     hideAfter: after, hasError: player.errorMessage != nil)
    }

    /// Whether the clock says the controls are up: a finger's on iOS, the
    /// pointer's on a Mac, where the pointer resting on the controls keeps
    /// them too.
    private var clockSaysVisible: Bool {
        #if os(macOS)
        mac.controlsVisible || chrome.pointerOnControls
        #else
        chrome.controlsVisible
        #endif
    }

    /// The controls are up when they are showing, or while anything that
    /// needs them is: a pause, a scrub, the panel, an error.
    private var showsControls: Bool {
        clockSaysVisible || player.isPaused || chrome.scrub != nil || chrome.panelOpen || chrome.menuOpen
            || player.errorMessage != nil || voiceOver
    }

    /// A touch or a click on a control: keeps the controls up a while longer.
    private func interact() {
        #if os(macOS)
        mac.noteActivity()
        #endif
        chrome.show(hideContext)
    }

    /// A tap on the picture: with a menu card open it puts the card away
    /// and nothing else; otherwise a finger toggles the controls, and a
    /// click on a Mac only counts as the pointer moving, since the pointer
    /// is what hides them.
    private func tapPicture() {
        if chrome.menuOpen {
            chrome.menu = nil
            return
        }
        #if os(macOS)
        mac.noteActivity()
        #else
        chrome.toggle(hideContext)
        #endif
    }

    var body: some View {
        ZStack {
            #if !os(tvOS)
            PlayerGestureLayer(chrome: chrome, compact: compact, onTap: tapPicture, onSkip: skip)
            #endif

            // The scrims and the transport come and go together. With the
            // television's panel down, the band keeps only its timeline: the
            // panel covers where the title goes, and says everything it would.
            if showsControls {
                PlayerTransport(chrome: chrome, trickplay: trickplay, schedule: schedule, artwork: artwork,
                                pictureInPicture: pictureInPicture, compact: compact, usesSheet: usesSheet,
                                timelineOnly: PlayerMetrics.television && chrome.panelOpen,
                                panelWidth: panelWidth,
                                onInteract: interact, onDismiss: onDismiss)
                    .transition(.opacity)
            }

            momentOverlays

            // Pops up as it is and goes the same way: no scale, no fade, no
            // spring on the number.
            if chrome.skipTotal != 0 {
                SkipBadge(seconds: chrome.skipTotal, compact: compact)
                    .frame(maxWidth: .infinity, alignment: chrome.skipTotal > 0 ? .trailing : .leading)
                    .padding(.horizontal, PlayerMetrics.skipBadgeInset(compact: compact))
                    .transition(.identity)
                    .allowsHitTesting(false)
            }

            if let ripple = chrome.ripple, !reduceMotion {
                SkipRippleView(forward: ripple.forward)
                    .id(ripple.id)
                    .allowsHitTesting(false)
            }

            if chrome.holdingDoubleSpeed {
                HoldSpeedBadge()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, compact ? 64 : 88)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let level = chrome.edgeLevel {
                EdgeLevelIndicator(level: level)
                    .frame(maxWidth: .infinity, alignment: level.kind == .brightness ? .leading : .trailing)
                    .padding(.horizontal, 28)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .playerChromeScheme()
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: showsControls)
        .animation(nil, value: chrome.skipTotal)
        .animation(.easeOut(duration: 0.2), value: chrome.holdingDoubleSpeed)
        .animation(.easeOut(duration: 0.2), value: chrome.edgeLevel)
        .background(GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size, initial: true) { _, now in size = now }
        })
        .panelPresentation(chrome: chrome, usesSheet: usesSheet, schedule: schedule, artwork: artwork,
                           reduceMotion: reduceMotion)
        #if os(tvOS)
        // The Siri Remote: clicks, edge clicks, swipes and Menu, read by
        // `RemoteInput` while nothing focusable is up.
        .modifier(PlayerRemoteDriver(chrome: chrome, onInteract: interact, onHide: { chrome.hide() }))
        #endif
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .medium), trigger: skips)
        .sensoryFeedback(.impact(weight: .light), trigger: chrome.skipTotal) { _, now in now != 0 }
        .sensoryFeedback(trigger: player.currentBitrate) { was, _ in was == nil ? nil : .selection }
        #endif
        #if os(macOS)
        // The pointer: moving over the picture brings the controls up and
        // starts the clock; leaving the window takes them away.
        .onContinuousHover { phase in
            switch phase {
            case .active: mac.noteActivity()
            case .ended: mac.pointerLeft()
            }
        }
        // Playback ▸ Show Panel: a menu command has no pill under the
        // pointer, so the request comes through `PlayerMacState` and the
        // popover hangs off the Info pill.
        .onChange(of: mac.togglePanelRequest) { _, _ in
            if chrome.panelOpen { chrome.panel = nil } else {
                chrome.panelAnchor = .info
                chrome.panel = .info
            }
        }
        .onAppear { mac.pictureInPicture = pictureInPicture }
        #endif
        .onChange(of: player.isPaused) { _, _ in chrome.scheduleHide(hideContext) }
        .onChange(of: chrome.panel) { _, open in
            if open == nil { interact() } else { chrome.holdControls() }
        }
        .onChange(of: chrome.menu) { _, open in
            if open == nil { interact() } else { chrome.holdControls() }
        }
        .onChange(of: chrome.scrub) { _, scrub in if scrub == nil { chrome.scheduleHide(hideContext) } }
        .onChange(of: showsControls, initial: true) { _, raised in
            player.raiseSubtitles(raised)
            // A jump can be undone for as long as the controls are up.
            if !raised { chrome.returnPoint = nil }
        }
        .onChange(of: player.item?.Id) { _, _ in
            chrome.resetForNewStream()
            dismissedNoVideoNotice = false
            interact()
        }
        .onChange(of: player.trickplay, initial: true) { _, info in trickplay.reset(info) }
        .task(id: player.currentChannel?.Id) { await schedule.load(for: player.currentChannel) }
        .task(id: InfoArtwork.url(for: player)) { await artwork.load(InfoArtwork.url(for: player)) }
        // The controls start up with their clock running on both platforms:
        // on a Mac that is the pointer's clock, before the pointer has moved.
        .onAppear {
            interact()
            #if DEBUG
            // `-AquariumPlayPanel <tab>` opens the panel on that tab once the
            // stream is up, for a screenshot with nobody at the keyboard —
            // the companion of `-AquariumPlayURL`.
            if let name = UserDefaults.standard.string(forKey: "AquariumPlayPanel"), let tab = PlayerTab(rawValue: name) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    chrome.panelAnchor = PlayerChromeState.PanelAnchor.anchor(for: tab)
                    chrome.panel = tab
                }
            }
            #if os(iOS)
            // `-AquariumPlayLandscape YES` turns a phone sideways once the
            // player is up: a simulator has no other way to be turned from
            // the command line.
            if UserDefaults.standard.bool(forKey: "AquariumPlayLandscape") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                    scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
            }
            #endif
            // `-AquariumPlayMenu audio|subtitles|quality|upnext|more` opens
            // that card once the stream has opened, for the same reason.
            if let name = UserDefaults.standard.string(forKey: "AquariumPlayMenu") {
                let menu: PlayerChromeState.ChromeMenu? = switch name.lowercased() {
                case "audio": .audio
                case "subtitles": .subtitles
                case "quality": .quality
                case "upnext": .upNext
                case "more": .more
                default: nil
                }
                if let menu {
                    Task { @MainActor in
                        for _ in 0..<60 {
                            try? await Task.sleep(for: .seconds(1))
                            if player.isActive, !player.isOpening { break }
                        }
                        try? await Task.sleep(for: .seconds(1))
                        chrome.menu = menu
                    }
                }
            }
            #endif
        }
    }

    // MARK: - Moments

    /// The prompts you act on once and the cards that say what is happening:
    /// they come and go with their moment, not with the controls. Skip intro
    /// and Up Next sit above the bottom band when it is up and at the foot of
    /// the picture when it isn't.
    /// On a television the prompts step aside for the panel and for a scrub
    /// waiting on its click, since a click is what they answer to.
    private var promptsMayShow: Bool {
        !(PlayerMetrics.television && (chrome.panelOpen || chrome.scrub != nil))
    }

    @ViewBuilder
    private var momentOverlays: some View {
        let edge = PlayerMetrics.edge(compact: compact)

        // On a television there is no centre cluster to carry the spinner,
        // so it sits in the middle of the picture on its own, as the Apple
        // TV player always drew it. Elsewhere the cluster's play button is
        // the spinner while the stream opens, and the title row already
        // says what is opening.
        if PlayerMetrics.television {
            if player.isBuffering || player.isOpening, player.errorMessage == nil, chrome.scrub == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(34)
                    .playerGlass(cornerRadius: 30)
                    .allowsHitTesting(false)
            }
        }

        if let error = player.errorMessage {
            PlayerErrorCard(message: error)
                .zIndex(2)
        } else if player.noVideoTrack, !dismissedNoVideoNotice {
            PlayerNoVideoBanner(dismissed: $dismissedNoVideoNotice)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, showsControls ? 60 : 16)
        }

        VStack(alignment: PlayerMetrics.television ? .trailing : .leading, spacing: 12) {
            Spacer()
            if player.shouldShowUpNext, let next = player.upNextTitle, player.errorMessage == nil, promptsMayShow {
                PlayerUpNextCard(title: next, next: player.upNextItem, compact: compact)
            } else if player.activeSegment != nil, player.errorMessage == nil, promptsMayShow {
                PlayerSkipSegmentButton(isOutro: player.activeSegment?.isOutro == true) {
                    skips += 1
                    player.skipSegment()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: PlayerMetrics.television ? .trailing : .leading)
        .padding(.horizontal, edge)
        .padding(.bottom, PlayerMetrics.overlayLift(controlsUp: showsControls, live: player.isLive))
        .animation(.easeOut(duration: 0.2), value: player.activeSegment)
        .animation(.easeOut(duration: 0.2), value: player.shouldShowUpNext)
        .animation(.easeOut(duration: 0.25), value: showsControls)

        PlayerBitrateBadge()
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, showsControls ? 60 : 12)
            .allowsHitTesting(false)
    }

    // MARK: - Skips

    private func skip(forward: Bool) {
        guard !player.isLive, player.duration > 0, !player.isOpening else { return }
        let delta = forward ? prefs.skipInterval : -prefs.skipInterval
        player.seek(by: Double(delta))
        chrome.countSkip(delta)
        chrome.rippleOnce(forward: forward)
        interact()
    }
}

extension PlayerChromeState.PanelAnchor {
    /// The pill a page's popover hangs off: the Info pill for Info, the "…"
    /// button for the pages opened from its menu.
    static func anchor(for tab: PlayerTab) -> Self {
        tab == .info ? .info : .more
    }
}

// MARK: - The panel's presentation

/// The sheet's material, solid under Reduce Transparency as the chrome's
/// pills are.
private struct PanelSheetBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.presentationBackground(Theme.raised)
        } else {
            content.presentationBackground(.ultraThinMaterial)
        }
    }
}

private extension View {
    /// A sheet with medium and large detents on a phone; a popover hung off
    /// the pill that opened it on an iPad or a Mac; on a television a card
    /// down from the top of the picture, placed against the screen's edges
    /// rather than the safe area's so its glass stays inside the overscan
    /// margin — see `PlayerPanel`.
    @ViewBuilder
    func panelPresentation(chrome: PlayerChromeState, usesSheet: Bool, schedule: ChannelSchedule,
                           artwork: InfoArtwork, reduceMotion: Bool) -> some View {
        #if os(tvOS)
        self.overlay(alignment: .top) {
            if chrome.panelOpen {
                PlayerPanel(tab: Binding(get: { chrome.panel ?? .info }, set: { chrome.panel = $0 }),
                            schedule: schedule, artwork: artwork, close: { chrome.panel = nil },
                            tabsFocused: { chrome.panelTabsFocused = $0 })
                    .ignoresSafeArea()
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.3), value: chrome.panelOpen)
        #else
        if usesSheet {
            self.sheet(isPresented: Binding(
                get: { chrome.panel != nil },
                set: { if !$0 { chrome.panel = nil } }
            )) {
                PlayerPanel(tab: Binding(get: { chrome.panel ?? .info }, set: { chrome.panel = $0 }),
                            schedule: schedule, artwork: artwork)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .modifier(PanelSheetBackground())
                    // The sheet is its own presentation and takes the app's
                    // theme unless told; the player is dark.
                    .preferredColorScheme(.dark)
                    .playerChromeScheme()
            }
        } else {
            // The popover is attached by the pill row — see `PlayerTransport`.
            self
        }
        #endif
    }
}
