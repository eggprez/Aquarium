//  The controls over the picture, as one view: the scrims, the transport, the
//  panel, the moment overlays, and the state that says which of them are up.
//
//  `PlayerChromeState` is the screen's: whether the controls are showing and
//  when they go, which panel tab is open and which pill it hangs off, where a
//  scrub has got to, how far a run of skips has gone, whether a finger is
//  holding 2×. The transport, the timeline, the gesture layer and the panel
//  all read and write it rather than talking to each other.
//
//  Shared by iPhone, iPad and (from phase 3) the Mac window. Nothing here is
//  about fingers or pointers — that is `PlayerGestureLayer` — and the numbers
//  that differ by platform are `PlayerMetrics`.

#if !os(tvOS)

import SwiftUI

@MainActor @Observable
final class PlayerChromeState {
    var controlsVisible = true
    /// The open panel tab; nil is closed.
    var panel: PlayerTab?
    /// Which pill the panel hangs off, where it is a popover.
    var panelAnchor: PanelAnchor = .audio
    /// Where the scrubber is, while a finger is on the timeline.
    var scrub: Double?
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
    #if !os(macOS)
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

    /// A phone, or an iPad narrowed to one: the sheet rather than the
    /// popover, the smaller glyphs. A Mac window is never compact.
    private var compact: Bool {
        #if os(macOS)
        false
        #else
        sizeClass == .compact
        #endif
    }

    private var hideContext: PlayerChromeState.HideContext {
        .init(isPaused: player.isPaused, voiceOver: voiceOver,
              hideAfter: prefs.hideControlsAfter, hasError: player.errorMessage != nil)
    }

    /// The controls are up when they are showing, or while anything that
    /// needs them is: a pause, a scrub, the panel, an error.
    private var showsControls: Bool {
        chrome.controlsVisible || player.isPaused || chrome.scrub != nil || chrome.panelOpen
            || player.errorMessage != nil || voiceOver
    }

    var body: some View {
        ZStack {
            PlayerGestureLayer(chrome: chrome, compact: compact, onTap: { chrome.toggle(hideContext) },
                               onSkip: skip)

            // The scrims and the transport come and go together.
            if showsControls {
                PlayerTransport(chrome: chrome, trickplay: trickplay, schedule: schedule, artwork: artwork,
                                pictureInPicture: pictureInPicture, compact: compact,
                                onInteract: { chrome.show(hideContext) }, onDismiss: onDismiss)
                    .transition(.opacity)
            }

            momentOverlays

            if chrome.skipTotal != 0 {
                SkipBadge(seconds: chrome.skipTotal, compact: compact)
                    .frame(maxWidth: .infinity, alignment: chrome.skipTotal > 0 ? .trailing : .leading)
                    .padding(.horizontal, compact ? 36 : 72)
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
        .animation(.spring(duration: 0.25), value: chrome.skipTotal)
        .animation(.easeOut(duration: 0.2), value: chrome.holdingDoubleSpeed)
        .animation(.easeOut(duration: 0.2), value: chrome.edgeLevel)
        .panelPresentation(chrome: chrome, compact: compact, schedule: schedule, artwork: artwork)
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .medium), trigger: skips)
        .sensoryFeedback(.impact(weight: .light), trigger: chrome.skipTotal) { _, now in now != 0 }
        .sensoryFeedback(trigger: player.currentBitrate) { was, _ in was == nil ? nil : .selection }
        #endif
        .onChange(of: player.isPaused) { _, _ in chrome.scheduleHide(hideContext) }
        .onChange(of: chrome.panel) { _, open in
            if open == nil { chrome.show(hideContext) } else { chrome.holdControls() }
        }
        .onChange(of: chrome.scrub) { _, scrub in if scrub == nil { chrome.scheduleHide(hideContext) } }
        .onChange(of: showsControls, initial: true) { _, raised in player.raiseSubtitles(raised) }
        .onChange(of: player.item?.Id) { _, _ in
            chrome.resetForNewStream()
            dismissedNoVideoNotice = false
            chrome.show(hideContext)
        }
        .onChange(of: player.trickplay, initial: true) { _, info in trickplay.reset(info) }
        .task(id: player.currentChannel?.Id) { await schedule.load(for: player.currentChannel) }
        .task(id: InfoArtwork.url(for: player)) { await artwork.load(InfoArtwork.url(for: player)) }
        .onAppear { chrome.show(hideContext) }
    }

    // MARK: - Moments

    /// The prompts you act on once and the cards that say what is happening:
    /// they come and go with their moment, not with the controls. Skip intro
    /// and Up Next sit above the bottom band when it is up and at the foot of
    /// the picture when it isn't.
    @ViewBuilder
    private var momentOverlays: some View {
        let edge = PlayerMetrics.edge(compact: compact)

        if player.isBuffering, player.position < 1 || player.isOpening, player.errorMessage == nil {
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

        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            if player.shouldShowUpNext, let next = player.upNextTitle, player.errorMessage == nil {
                PlayerUpNextCard(title: next, compact: compact)
            }
            if player.activeSegment != nil, player.errorMessage == nil {
                PlayerSkipSegmentButton(isOutro: player.activeSegment?.isOutro == true) {
                    skips += 1
                    player.skipSegment()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, edge)
        .padding(.bottom, showsControls ? (player.isLive ? 110 : 148) : 24)
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
        chrome.show(hideContext)
    }
}

// MARK: - The panel's presentation

private extension View {
    /// A sheet with medium and large detents on a phone; a popover hung off
    /// the pill that opened it on an iPad or a Mac.
    @ViewBuilder
    func panelPresentation(chrome: PlayerChromeState, compact: Bool, schedule: ChannelSchedule,
                           artwork: InfoArtwork) -> some View {
        if compact {
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
    }
}

#endif
