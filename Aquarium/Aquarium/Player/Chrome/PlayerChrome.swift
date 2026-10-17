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
    var panel: PlayerTab?
    /// Which pill the panel hangs off, where it is a popover.
    var panelAnchor: PanelAnchor = .audio
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

    enum PanelAnchor: Hashable { case audio, speed, quality, more }

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
        guard context.mayHide, scrub == nil, !panelOpen, context.hideAfter > 0 else { return }
        let after = context.hideAfter
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled, let self, self.scrub == nil, !self.panelOpen else { return }
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
    #if os(macOS)
    /// The picture's size: a Mac window runs from 480×270 to a full display,
    /// and the small metrics are for the small end of that.
    @State private var size: CGSize = .zero
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
        clockSaysVisible || player.isPaused || chrome.scrub != nil || chrome.panelOpen
            || player.errorMessage != nil || voiceOver
    }

    /// A touch or a click on a control: keeps the controls up a while longer.
    private func interact() {
        #if os(macOS)
        mac.noteActivity()
        #endif
        chrome.show(hideContext)
    }

    /// A tap on the picture: a finger toggles the controls; a click on a Mac
    /// only counts as the pointer moving, since the pointer is what hides
    /// them.
    private func tapPicture() {
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
                                onInteract: interact, onDismiss: onDismiss)
                    .transition(.opacity)
            }

            momentOverlays

            if chrome.skipTotal != 0 {
                SkipBadge(seconds: chrome.skipTotal, compact: compact)
                    .frame(maxWidth: .infinity, alignment: chrome.skipTotal > 0 ? .trailing : .leading)
                    .padding(.horizontal, PlayerMetrics.skipBadgeInset(compact: compact))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
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
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.25), value: chrome.skipTotal)
        .animation(.easeOut(duration: 0.2), value: chrome.holdingDoubleSpeed)
        .animation(.easeOut(duration: 0.2), value: chrome.edgeLevel)
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
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, now in size = now }
        })
        // The pointer: moving over the picture brings the controls up and
        // starts the clock; leaving the window takes them away.
        .onContinuousHover { phase in
            switch phase {
            case .active: mac.noteActivity()
            case .ended: mac.pointerLeft()
            }
        }
        // Playback ▸ … ▸ Show … Panel, and the Sync tab from Adjust Audio
        // Delay: a menu command has no pill to hang the popover off, so the
        // request comes through `PlayerMacState` and the tab's own pill is
        // used, or the "…" button for the tabs with none.
        .onChange(of: mac.panelRequest) { _, request in
            guard let request else { return }
            mac.panelRequest = nil
            chrome.panelAnchor = PlayerChromeState.PanelAnchor.anchor(for: request)
            chrome.panel = request
        }
        .onChange(of: mac.togglePanelRequest) { _, _ in
            if chrome.panelOpen { chrome.panel = nil } else {
                chrome.panelAnchor = .more
                chrome.panel = .info
            }
        }
        .onAppear { mac.pictureInPicture = pictureInPicture }
        #endif
        .onChange(of: player.isPaused) { _, _ in chrome.scheduleHide(hideContext) }
        .onChange(of: chrome.panel) { _, open in
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

        if PlayerMetrics.television {
            // No centre cluster to carry the spinner: it sits in the middle of
            // the picture on its own, as the Apple TV player always drew it.
            if player.isBuffering || player.isOpening, player.errorMessage == nil, chrome.scrub == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(34)
                    .playerGlass(cornerRadius: 30)
                    .allowsHitTesting(false)
            }
        } else if player.isBuffering, player.position < 1 || player.isOpening, player.errorMessage == nil {
            PlayerLoadingCard()
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, compact ? 64 : 88)
                .allowsHitTesting(false)
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
    /// The pill a tab's popover hangs off: its own where it has one, the "…"
    /// button for the rest.
    static func anchor(for tab: PlayerTab) -> Self {
        switch tab {
        case .audio, .subtitles: .audio
        case .speed: .speed
        case .quality: .quality
        case .info, .channels, .sync, .picture: .more
        }
    }
}

// MARK: - The panel's presentation

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
                    .presentationBackground(.ultraThinMaterial)
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
