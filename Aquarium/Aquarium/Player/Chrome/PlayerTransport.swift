//  The transport over the picture: the scrims top and bottom, the title row
//  with dismiss, AirPlay, Picture in Picture and the "…" menu, the centre
//  cluster, and along the bottom the timeline, the times and the row of
//  pills. Each pill is its own thing: Info opens the panel on the episode
//  and the stream facts; Audio, Subtitles, Quality and Up Next each drop a
//  card of the chrome's own (`PlayerMenus`); Fill is a switch. The "…"
//  button drops the More card — speed, the sleep timer, what happens after
//  this episode, the channels, Watch Together. Nothing on an iPhone, an
//  iPad or a Mac opens a panel with a row of tabs; that is the television's.
//
//  Apple's grammar in this app's palette. Nothing here knows how it was
//  touched: taps on the picture, double-taps and pinches are
//  `PlayerGestureLayer`'s, and this view's buttons are ordinary SwiftUI
//  buttons that work from a finger, a pointer or VoiceOver alike.
//
//  On a television the same transport is one band along the bottom of the
//  picture — the heading above the timeline, the times under it, and a line
//  saying what the remote does — inside the 90-point gutters: the remote's
//  clicks are the cluster and the swipe-down panel is the pill row, so neither
//  is drawn. The band keeps only its timeline while the panel is down.

import AVKit
import SwiftUI

struct PlayerTransport: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs
    @Environment(\.playerSideClearance) private var sides

    @Bindable var chrome: PlayerChromeState
    let trickplay: TrickplayStore
    let schedule: ChannelSchedule
    let artwork: InfoArtwork
    var pictureInPicture: PictureInPicture?
    /// The smaller glyphs and insets: a phone, or a narrow Mac window.
    let compact: Bool
    /// The panel is a sheet of the chrome's rather than a popover off a pill
    /// here: a phone.
    var usesSheet = false
    /// Only the timeline and the times: the television's panel is down over
    /// where the heading goes.
    var timelineOnly = false
    /// How wide the panel is where it is a popover (an iPad, a Mac): most
    /// of the picture, so the Info page has room for its two columns. The
    /// chrome works it out from its size.
    var panelWidth: CGFloat = 640
    /// How much of the transport this is. The whole of it, usually. On a
    /// foldable half-folded the transport is split at the crease: the half
    /// over the picture keeps the scrims, the title row and the centre
    /// cluster, and the half below the fold is the bottom band alone — the
    /// timeline, the times and the pills — drawn by `PlayerFoldPanel`, where
    /// the hands are.
    var part: Part = .whole

    /// `foldControls` is the centre cluster on its own, stacked for the
    /// flat half's trailing column: play/pause over the two skips.
    enum Part { case whole, aboveFold, belowFold, foldControls }

    /// A touch on any control: keeps the controls up a while longer.
    let onInteract: () -> Void
    let onDismiss: () -> Void

    /// Where the pointer is, by region; together they are
    /// `PlayerChromeState.pointerOnControls`. Never set by a finger.
    @State private var hoverTitle = false
    @State private var hoverCluster = false
    @State private var hoverBottom = false

    private var edge: CGFloat { PlayerMetrics.edge(compact: compact) }

    var body: some View {
        if PlayerMetrics.television {
            band
        } else if part == .belowFold {
            foldBand
        } else if part == .foldControls {
            foldControls
        } else {
            handheld
        }
    }

    // MARK: - Below the fold

    /// The bottom band on its own, for the half of a half-folded phone that
    /// lies flat: no scrims, no cluster, no title row. The menu cards its
    /// pills drop are placed by whoever lays this out — see
    /// `PlayerFoldPanel` — so they can rise over the panel above the band.
    private var foldBand: some View {
        bottom
            .padding(.horizontal, edge)
    }

    /// Play/pause, and the two skips under it, for the flat half's trailing
    /// column — where a thumb resting on the table finds them. Always
    /// drawn: the controls over the picture come and go, these stay put.
    private var foldControls: some View {
        VStack(spacing: 10) {
            playPauseButton
            if !player.isLive {
                HStack(spacing: 18) {
                    skipButton(forward: false)
                    skipButton(forward: true)
                }
            }
        }
    }

    // MARK: - The television's band

    private var band: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Faded rather than removed while scrubbing: the thumbnail and its
            // time ride up over where the title is, and were drawn across
            // it. Kept in the layout so the band doesn't jump down.
            if !timelineOnly {
                heading
                    .opacity(chrome.scrub == nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: chrome.scrub == nil)
            }
            if player.isLive {
                LivePlayerTimeline(programme: schedule.now)
            } else {
                PlayerTimeline(chrome: chrome, trickplay: trickplay, compact: compact, onInteract: onInteract)
                times
            }
            if !timelineOnly, let remoteHint {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.down")
                    Text(remoteHint)
                }
                .font(.caption)
                .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, edge)
        .padding(.top, PlayerMetrics.bandTop)
        .padding(.bottom, PlayerMetrics.bandBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(stops: PlayerMetrics.scrimStops, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
    }

    /// Above the band's timeline: the show, the title, and that it is paused.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if player.isLive { liveBadge }
                if let kicker, !kicker.isEmpty {
                    Text(kicker)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.link)
                }
                if player.isPaused {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textBody)
                }
            }
            Text(mainTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// What the remote does from here, in a line. The remote's alone.
    private var remoteHint: String? {
        #if os(tvOS)
        if chrome.scrub != nil { return "Click to jump here · Menu to go back" }
        if let point = chrome.returnPoint { return "Menu to go back to \(PlayerTime.format(point))" }
        return player.isLive
            ? "Swipe down for Info, Audio, Subtitles and Channels · Click up or down to change channel"
            : "Swipe down for Info, Audio, Subtitles, Quality, Speed, Sync and Picture"
        #else
        return nil
        #endif
    }

    // MARK: - iPhone, iPad and Mac

    private var handheld: some View {
        ZStack {
            scrims
            VStack(spacing: 0) {
                titleRow
                    .padding(.leading, beyondEdge(sides?.titleLeading))
                    .padding(.trailing, beyondEdge(sides?.titleTrailing))
                    .pointerHover { hoverTitle = $0 }
                Spacer(minLength: 0)
                if part == .whole {
                    bottom
                        .pointerHover { hoverBottom = $0 }
                }
            }
            .padding(.horizontal, edge)
            // The cluster steps aside while a finger is on the timeline, so
            // the thumbnail has the middle of the picture to itself. Half-
            // folded it lives below the fold, in `PlayerFoldPanel`.
            if chrome.scrub == nil, player.errorMessage == nil, part == .whole {
                centreCluster
                    .pointerHover { hoverCluster = $0 }
            }
        }
        // The open menu card, beside the control that opened it.
        .overlayPreferenceValue(ChromeMenuAnchors.self) { anchors in
            ChromeMenuLayer(chrome: chrome, anchors: anchors, compact: compact, onInteract: onInteract,
                            openPanel: { open($0, anchor: .more) })
        }
        .onChange(of: hoverTitle || hoverCluster || hoverBottom, initial: true) { _, on in
            chrome.pointerOnControls = on
        }
        .onDisappear { chrome.pointerOnControls = false }
    }

    /// What a row keeps clear beyond the edge inset it already has: the
    /// camera's reach on the front screen (`PlayerSideClearance`), or
    /// nothing.
    private func beyondEdge(_ reach: CGFloat?) -> CGFloat {
        max(0, (reach ?? 0) - edge)
    }

    // MARK: - Scrims

    /// Two gradients, never a full dim: the picture stays the thing on screen.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: compact ? 130 : 160)
            Spacer(minLength: 0)
            // The bottom scrim is the band's; above a fold there is no band.
            if part == .whole {
                LinearGradient(stops: PlayerMetrics.scrimStops, startPoint: .top, endPoint: .bottom)
                    .frame(height: compact ? 210 : 250)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            // Back to wherever the film was opened from, the way every other
            // page in the app is left. A Mac window has its own close button
            // over the picture; in full screen, where that is gone, it gets
            // this one.
            if showsBackButton {
                PlayerGlyphButton(symbol: "chevron.backward", label: "Back", size: 20, action: onDismiss)
                    .accessibilityHint("Closes the player")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if player.isLive { liveBadge }
                    Text(mainTitle)
                        .font(compact ? .headline : .title3.weight(.semibold))
                        .lineLimit(1)
                }
                if let kicker, !kicker.isEmpty {
                    Text(kicker)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            // AirPlay and Picture in Picture are AVPlayer's. On mpv the
            // buttons stay, and hand the stream to AVPlayer: the picker as it
            // opens, the picture as soon as the new layer plays.
            if player.engine?.capabilities.contains(.airPlay) == true || player.canSwitchEngine(to: .apple) {
                PlayerAirPlayButton()
                    .frame(width: 40, height: 40)
                    .accessibilityLabel("AirPlay")
            }

            if let pip = pictureInPicture, pip.isPossible || pip.isActive || player.canHandOverForPictureInPicture {
                PlayerGlyphButton(
                    symbol: pip.isActive ? "pip.exit" : "pip.enter",
                    label: pip.isActive ? "Leave Picture in Picture" : "Picture in Picture",
                    size: 18
                ) {
                    onInteract()
                    if !pip.isActive, player.canHandOverForPictureInPicture {
                        player.handOverForPictureInPicture(pip)
                    } else {
                        pip.toggle()
                    }
                }
            }

            moreButton
                .panelPopover(isPresented: popover(for: .more), arrowEdge: .top) { panelPopover }
        }
        .padding(.top, titleRowTop)
        // Clear of the window's close, minimise and zoom buttons, which sit
        // over the picture in a window with no title bar.
        .padding(.leading, PlayerMetrics.titleLeadingInset(fullScreen: PlayerMetrics.isFullScreen))
        .padding(.trailing, titleRowTrailing)
    }

    /// The row's buttons are 40 points tall.
    private static let titleRowHalf: CGFloat = 20

    /// Where the row sits. On a foldable's inside screen it goes next to the
    /// system's clock: held upright, up onto the status strip and onto the
    /// pill's line (`FoldState.statusStrip`); held sideways, down to the
    /// line the time reads on in the trailing column. Elsewhere, under the
    /// status bar as Apple's player has it.
    private var titleRowTop: CGFloat {
        #if os(iOS)
        if let strip = FoldState.shared.statusStrip {
            return FoldState.statusPillLine - Self.titleRowHalf - strip
        }
        if FoldState.shared.innerSideways {
            return FoldState.columnClockLine - Self.titleRowHalf
        }
        #endif
        return compact ? 2 : 8
    }

    /// What the row keeps clear on the trailing side beyond the chrome's
    /// edge inset. On the strip: the pill, and a little air before it.
    /// Sideways: 8 points of air past the column, which `PlayerSideClearance`
    /// already keeps clear — the buttons go right up to it rather than
    /// stopping a full inset short. Nothing
    /// elsewhere; a 92-point clearance here once pushed the buttons nearly
    /// 180 points in and squeezed the title to nothing on the front screen.
    private var titleRowTrailing: CGFloat {
        #if os(iOS)
        if FoldState.shared.statusStrip != nil {
            return max(0, FoldState.statusPillReach + 10 - edge)
        }
        if FoldState.shared.innerSideways {
            return 8
        }
        #endif
        return 0
    }

    private var showsBackButton: Bool {
        #if os(macOS)
        PlayerMetrics.isFullScreen
        #else
        true
        #endif
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(PlayerMetrics.television ? .caption.weight(.heavy) : .caption2.weight(.heavy))
            .padding(.horizontal, PlayerMetrics.television ? 12 : 7)
            .padding(.vertical, PlayerMetrics.television ? 4 : 3)
            .background(Capsule().fill(Theme.danger))
            .foregroundStyle(.white)
            // Never wrapped: squeezed, the badge once ran its letters down
            // the screen rather than give the title the width.
            .fixedSize()
            .accessibilityLabel("Live")
    }

    /// The line under the title: the show and the episode, or the channel.
    private var kicker: String? {
        if player.isLive {
            if let channel = player.currentChannel {
                return [channel.ChannelNumber, channel.title].compactMap { $0 }.joined(separator: " · ")
            }
            return player.subtitle
        }
        if let item = player.item, item.isEpisode {
            return [item.SeriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        }
        return player.item?.ProductionYear.map(String.init)
    }

    private var mainTitle: String {
        if player.isLive { return schedule.now?.title ?? player.title }
        return player.item?.title ?? player.title
    }

    /// The "…" button: the More card — speed, the sleep timer, what happens
    /// after this episode, the channels, Watch Together. See `PlayerMenus`.
    private var moreButton: some View {
        PlayerGlyphButton(symbol: "ellipsis", label: "More", size: 18, isOn: chrome.menu == .more) {
            toggleMenu(.more)
        }
        .chromeMenuAnchor(.more)
    }

    // MARK: - Centre cluster

    private var centreCluster: some View {
        HStack(spacing: PlayerMetrics.clusterSpacing(compact: compact)) {
            if !player.isLive {
                skipButton(forward: false)
            }
            playPauseButton
            if !player.isLive {
                skipButton(forward: true)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
    }

    private func skipButton(forward: Bool) -> some View {
        let skip = prefs.skipInterval
        return PlayerGlyphButton(
            symbol: forward ? "goforward.\(skip)" : "gobackward.\(skip)",
            label: forward ? "Forward \(skip) seconds" : "Back \(skip) seconds",
            size: PlayerMetrics.skipGlyph(compact: compact), weight: .medium, padding: 12
        ) {
            onInteract()
            player.seek(by: Double(forward ? skip : -skip))
            chrome.countSkip(forward ? skip : -skip)
        }
        .disabled(player.isOpening)
    }

    private var playPauseButton: some View {
        Button {
            onInteract()
            player.togglePlayPause()
        } label: {
            ZStack {
                if player.isBuffering {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: PlayerMetrics.centreGlyph(compact: compact), weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: PlayerMetrics.centreGlyph(compact: compact) + 32,
                   height: PlayerMetrics.centreGlyph(compact: compact) + 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isBuffering ? "Loading" : player.isPaused ? "Play" : "Pause")
    }

    // MARK: - Bottom

    private var bottom: some View {
        VStack(spacing: compact ? 6 : 10) {
            if player.isLive {
                LivePlayerTimeline(programme: schedule.now)
            } else {
                PlayerTimeline(chrome: chrome, trickplay: trickplay, compact: compact, onInteract: onInteract)
                times
            }
            // Only the pills stand level with the front screen's camera
            // when it is at the foot of the screen; the timeline runs past.
            pills
                .padding(.leading, beyondEdge(sides?.pillsLeading))
                .padding(.trailing, beyondEdge(sides?.pillsTrailing))
        }
        .padding(.bottom, compact ? 4 : 12)
    }

    private var times: some View {
        let shown = chrome.scrub ?? player.position
        let remaining = max(0, player.duration - shown)
        return HStack {
            Text(PlayerTime.format(shown))
                .accessibilityLabel("Elapsed \(PlayerTime.spoken(shown))")
            Spacer()
            Button {
                onInteract()
                chrome.showsTotalTime.toggle()
                prefs.showsRemainingTime = !chrome.showsTotalTime
            } label: {
                Text(chrome.showsTotalTime ? PlayerTime.format(player.duration) : "−" + PlayerTime.format(remaining))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chrome.showsTotalTime
                ? "Total length \(PlayerTime.spoken(player.duration))"
                : "Remaining \(PlayerTime.spoken(remaining))")
            .accessibilityHint("Switches between time remaining and total length")
        }
        .font(PlayerMetrics.television ? .callout.monospacedDigit() : .caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 2)
    }

    // MARK: - Pills

    /// Info opens the panel; Audio, Subtitles, Quality and Up Next drop
    /// their cards; Fill is a switch.
    ///
    /// A phone held upright, the smallest of them especially, has no room
    /// for six pills with their words: the row used to scroll, with Fill
    /// cut off at the edge. So the pills draw in closer first, then the
    /// words go before anything is cut — from the pills whose glyph says it
    /// all, then from the two that carry a state (the quality in force, how
    /// many are queued) — and the row only scrolls if even the glyphs can't
    /// fit.
    private var pills: some View {
        ViewThatFits(in: .horizontal) {
            pillRow(.all)
            pillRow(.all, tight: true)
            pillRow(.stateOnly, tight: true)
            pillRow(.none, tight: true)
            ScrollView(.horizontal, showsIndicators: false) { pillRow(.none, tight: true) }
                .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which pills keep their words.
    private enum PillWords { case all, stateOnly, none }

    private func pillRow(_ words: PillWords, tight: Bool = false) -> some View {
        let plain = words == .all
        let state = words != .none
        return HStack(spacing: tight ? 6 : 8) {
            pill(symbol: PlayerTab.info.symbol, title: plain ? "Info" : nil,
                 label: player.isLive ? "Channel info" : "Episode info",
                 tab: .info, anchor: .info)
            menuPill(.audio, symbol: "speaker.wave.2", title: plain ? "Audio" : nil, label: "Audio tracks")
            menuPill(.subtitles, symbol: "captions.bubble", title: plain ? "Subtitles" : nil, label: "Subtitles")
            if player.offersQualityChoice {
                menuPill(.quality, symbol: "slider.horizontal.3",
                         title: state ? qualityTitle : nil, label: "Quality, \(qualitySpoken)")
            }
            if !player.isLive, player.upNextCount > 0 {
                menuPill(.upNext, symbol: "text.line.first.and.arrowtriangle.forward",
                         title: !state ? nil : player.queue.isEmpty ? "Up Next" : "Up Next · \(player.queue.count)",
                         label: "Up next, \(player.upNextCount) waiting")
            }
            Button {
                onInteract()
                prefs.fillScreen.toggle()
                player.applyFraming()
            } label: {
                PlayerPill(isOn: prefs.fillScreen) {
                    Image(systemName: prefs.fillScreen
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    if plain { Text("Fill") }
                }
            }
            .buttonStyle(PlayerPillStyle())
            .accessibilityLabel("Fill the screen")
            .accessibilityValue(prefs.fillScreen ? "On" : "Off")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .fixedSize(horizontal: true, vertical: false)
        .environment(\.playerPillsTight, tight)
    }

    /// Auto, a download, or the rung held — in the handful of characters a
    /// pill has.
    private var qualityTitle: String {
        switch player.qualitySelection {
        case .auto: "Auto"
        case .downloaded: "Downloaded"
        case .stream(let bitrate): bitrate == nil ? "Direct" : Quality.shortLabel(for: bitrate)
        }
    }

    private var qualitySpoken: String {
        switch player.qualitySelection {
        case .auto: player.isLocal ? "Auto, playing the download" : "Auto, playing \(Quality.label(for: player.currentBitrate))"
        case .downloaded: "Downloaded copy"
        case .stream(let bitrate): Quality.label(for: bitrate)
        }
    }

    private func pill(symbol: String, title: String?, label: String, tab: PlayerTab,
                      anchor: PlayerChromeState.PanelAnchor) -> some View {
        Button {
            open(tab, anchor: anchor)
        } label: {
            PlayerPill(isOn: chrome.panelAnchor == anchor && chrome.panelOpen) {
                Image(systemName: symbol)
                if let title { Text(title) }
            }
        }
        .buttonStyle(PlayerPillStyle())
        .accessibilityLabel(label)
        .accessibilityHint("Opens the \(tab.title) panel")
        .panelPopover(isPresented: popover(for: anchor), arrowEdge: .bottom) { panelPopover }
    }

    /// A pill whose card drops from it; lit while the card is up.
    private func menuPill(_ menu: PlayerChromeState.ChromeMenu, symbol: String, title: String?, label: String) -> some View {
        Button {
            toggleMenu(menu)
        } label: {
            PlayerPill(isOn: chrome.menu == menu) {
                Image(systemName: symbol)
                if let title { Text(title) }
            }
        }
        .buttonStyle(PlayerPillStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(chrome.menu == menu ? [.isSelected] : [])
        .chromeMenuAnchor(menu)
    }

    /// Open `menu`'s card, or put it away if it is the one up. The card
    /// holds the controls while it is open — see `PlayerChrome`.
    private func toggleMenu(_ menu: PlayerChromeState.ChromeMenu) {
        onInteract()
        chrome.menu = chrome.menu == menu ? nil : menu
    }

    // MARK: - The panel

    private func open(_ tab: PlayerTab, anchor: PlayerChromeState.PanelAnchor) {
        onInteract()
        chrome.panelAnchor = anchor
        chrome.panel = tab
    }

    /// A popover hung off the pill that opened it, where the panel is a
    /// popover (an iPad or a Mac). On a phone the panel is a sheet, attached
    /// by `PlayerChrome`, and these bindings stay false.
    private func popover(for anchor: PlayerChromeState.PanelAnchor) -> Binding<Bool> {
        Binding(
            get: { !usesSheet && chrome.panelOpen && chrome.panelAnchor == anchor },
            set: { if !$0 { chrome.panel = nil } }
        )
    }

    private var panelPopover: some View {
        PlayerPanel(tab: Binding(get: { chrome.panel ?? .info }, set: { chrome.panel = $0 }),
                    schedule: schedule, artwork: artwork)
            .frame(minWidth: panelWidth, idealWidth: panelWidth, maxWidth: panelWidth, minHeight: 360, idealHeight: 520, maxHeight: 640)
            .playerChromeScheme()
    }
}

private extension View {
    /// Where the pointer is, on the platforms that have one.
    @ViewBuilder
    func pointerHover(_ perform: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        onHover(perform: perform)
        #endif
    }

    /// The panel as a popover off a pill, where the platform has popovers;
    /// a television's panel is the chrome's overlay and this is nothing.
    @ViewBuilder
    func panelPopover<Panel: View>(isPresented: Binding<Bool>, arrowEdge: Edge,
                                   @ViewBuilder content: @escaping () -> Panel) -> some View {
        #if os(tvOS)
        self
        #else
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            content().presentationCompactAdaptation(.sheet)
        }
        #endif
    }
}

// MARK: - AirPlay

/// The system's route picker: the only way to offer AirPlay. As it opens,
/// a stream on mpv is handed to AVPlayer, which is the engine that can send
/// video to the television about to be chosen.
#if canImport(UIKit)
struct PlayerAirPlayButton: UIViewRepresentable {
    @Environment(PlayerModel.self) private var player

    func makeCoordinator() -> PlayerAirPlayDelegate { PlayerAirPlayDelegate() }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.link)
        view.prioritizesVideoDevices = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#elseif os(macOS)
struct PlayerAirPlayButton: NSViewRepresentable {
    @Environment(PlayerModel.self) private var player

    func makeCoordinator() -> PlayerAirPlayDelegate { PlayerAirPlayDelegate() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player.appleEngine.player
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player.appleEngine.player
    }
}
#endif

final class PlayerAirPlayDelegate: NSObject, AVRoutePickerViewDelegate {
    nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        Task { @MainActor in PlayerModel.shared.handOverForAirPlay() }
    }
}
