//  The transport over the picture: the scrims top and bottom, the title row
//  with dismiss, AirPlay, Picture in Picture and the "…" menu, the centre
//  cluster, and along the bottom the timeline, the times and the row of pills
//  that open the panel.
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
        } else {
            handheld
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
                    .pointerHover { hoverTitle = $0 }
                Spacer(minLength: 0)
                bottom
                    .pointerHover { hoverBottom = $0 }
            }
            .padding(.horizontal, edge)
            // The cluster steps aside while a finger is on the timeline, so
            // the thumbnail has the middle of the picture to itself.
            if chrome.scrub == nil, player.errorMessage == nil {
                centreCluster
                    .pointerHover { hoverCluster = $0 }
            }
        }
        .onChange(of: hoverTitle || hoverCluster || hoverBottom, initial: true) { _, on in
            chrome.pointerOnControls = on
        }
        .onDisappear { chrome.pointerOnControls = false }
    }

    // MARK: - Scrims

    /// Two gradients, never a full dim: the picture stays the thing on screen.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: compact ? 130 : 160)
            Spacer(minLength: 0)
            LinearGradient(stops: PlayerMetrics.scrimStops, startPoint: .top, endPoint: .bottom)
                .frame(height: compact ? 210 : 250)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            #if !os(macOS)
            PlayerGlyphButton(symbol: "chevron.down", label: "Close the player", size: 18, action: onDismiss)
            #endif

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

            moreMenu
                .panelPopover(isPresented: popover(for: .more), arrowEdge: .top) { panelPopover }
        }
        .padding(.top, compact ? 2 : 8)
        // Clear of the window's close, minimise and zoom buttons, which sit
        // over the picture in a window with no title bar.
        .padding(.leading, PlayerMetrics.titleLeadingInset(fullScreen: PlayerMetrics.isFullScreen))
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(PlayerMetrics.television ? .caption.weight(.heavy) : .caption2.weight(.heavy))
            .padding(.horizontal, PlayerMetrics.television ? 12 : 7)
            .padding(.vertical, PlayerMetrics.television ? 4 : 3)
            .background(Capsule().fill(Theme.danger))
            .foregroundStyle(.white)
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

    /// The rare things: Stream Info, Watch Together, the sync tools, the
    /// sleep timer and "stop after this episode".
    private var moreMenu: some View {
        Menu {
            Button {
                open(.info, anchor: .more)
            } label: {
                Label("Stream Info", systemImage: "info.circle")
            }
            #if !os(tvOS)
            if let item = player.item, !player.isLocal, !player.isLive,
               player.engine?.capabilities.contains(.sharePlay) == true || player.canSwitchEngine(to: .apple) {
                let shareplay = SharePlayCoordinator.shared
                if shareplay.isActive {
                    Button {
                        shareplay.leave()
                    } label: {
                        Label("Leave SharePlay", systemImage: "shareplay.slash")
                    }
                } else {
                    // On mpv the stream is handed to AVPlayer first, whose
                    // player the session coordinates.
                    Button {
                        Task {
                            await player.prepareForSharePlay()
                            await shareplay.share(item)
                        }
                    } label: {
                        Label("Watch Together", systemImage: "shareplay")
                    }
                }
            }
            #endif
            Button {
                open(.sync, anchor: .more)
            } label: {
                Label("Audio Sync", systemImage: "waveform.path.ecg")
            }
            Divider()
            Menu {
                if let left = player.sleepMinutesRemaining {
                    Button("Cancel sleep timer (\(left) min left)") { player.cancelSleepTimer() }
                } else {
                    ForEach([15, 30, 60, 90], id: \.self) { minutes in
                        Button("Stop in \(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                    }
                }
            } label: {
                Label(player.sleepMinutesRemaining.map { "Sleep timer · \($0) min" } ?? "Sleep timer",
                      systemImage: "moon")
            }
            if !player.isLive {
                Button {
                    if player.autoplayCancelled { player.resumeAutoplay() } else { player.cancelAutoplay() }
                } label: {
                    Label(player.autoplayCancelled ? "Keep playing after this" : "Stop after this episode",
                          systemImage: player.autoplayCancelled ? "play.circle" : "stop.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .tint(.white)
        .accessibilityLabel("More")
    }

    // MARK: - Centre cluster

    private var centreCluster: some View {
        let skip = prefs.skipInterval
        return HStack(spacing: PlayerMetrics.clusterSpacing(compact: compact)) {
            if !player.isLive {
                PlayerGlyphButton(
                    symbol: "gobackward.\(skip)", label: "Back \(skip) seconds",
                    size: PlayerMetrics.skipGlyph(compact: compact), weight: .medium, padding: 12
                ) {
                    onInteract()
                    player.seek(by: -Double(skip))
                    chrome.countSkip(-skip)
                }
                .disabled(player.isOpening)
            }

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

            if !player.isLive {
                PlayerGlyphButton(
                    symbol: "goforward.\(skip)", label: "Forward \(skip) seconds",
                    size: PlayerMetrics.skipGlyph(compact: compact), weight: .medium, padding: 12
                ) {
                    onInteract()
                    player.seek(by: Double(skip))
                    chrome.countSkip(skip)
                }
                .disabled(player.isOpening)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
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
            pills
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

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(symbol: "captions.bubble", title: "Audio & Subtitles", label: "Audio and subtitles",
                     tab: .audio, anchor: .audio)
                if !player.isLive {
                    pill(symbol: "gauge.with.dots.needle.67percent",
                         title: player.speed == 1 ? "Speed" : PlayerModel.speedName(player.speed),
                         label: "Speed, \(PlayerModel.speedName(player.speed))",
                         tab: .speed, anchor: .speed)
                }
                if player.offersQuality {
                    pill(symbol: "slider.horizontal.3", title: Quality.shortLabel(for: player.currentBitrate),
                         label: "Quality, \(Quality.label(for: player.currentBitrate))",
                         tab: .quality, anchor: .quality)
                }
                if !player.isLive, player.upNextCount > 0 {
                    upNextPill
                }
                Button {
                    onInteract()
                    prefs.fillScreen.toggle()
                    player.applyFraming()
                } label: {
                    PlayerPill(isOn: prefs.fillScreen) {
                        Image(systemName: prefs.fillScreen
                              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        Text("Fill")
                    }
                }
                .buttonStyle(PlayerPillStyle())
                .accessibilityLabel("Fill the screen")
                .accessibilityValue(prefs.fillScreen ? "On" : "Off")
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func pill(symbol: String, title: String, label: String, tab: PlayerTab,
                      anchor: PlayerChromeState.PanelAnchor) -> some View {
        Button {
            open(tab, anchor: anchor)
        } label: {
            PlayerPill(isOn: chrome.panelAnchor == anchor && chrome.panelOpen) {
                Image(systemName: symbol)
                Text(title)
            }
        }
        .buttonStyle(PlayerPillStyle())
        .accessibilityLabel(label)
        .accessibilityHint("Opens the \(tab.title) panel")
        .panelPopover(isPresented: popover(for: anchor), arrowEdge: .bottom) { panelPopover }
    }

    /// What is queued by hand, then the next the series offers. A row plays
    /// its title now.
    private var upNextPill: some View {
        Menu {
            ForEach(player.queue, id: \.Id) { entry in
                Button(PlayerModel.displayTitle(entry)) { Task { await player.playQueued(entry.Id) } }
            }
            if player.queue.isEmpty, let next = player.upNextTitle {
                Button {
                    Task { await player.playNextNow() }
                } label: {
                    Label("Play now · \(next)", systemImage: "forward.fill")
                }
            }
            if !player.queue.isEmpty {
                Divider()
                Button("Clear up next", role: .destructive) { player.clearQueue() }
            }
        } label: {
            PlayerPill {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                Text(player.queue.isEmpty ? "Up Next" : "Up Next · \(player.queue.count)")
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(PlayerPillStyle())
        .accessibilityLabel("Up next, \(player.upNextCount) waiting")
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
            .frame(minWidth: 400, idealWidth: 440, maxWidth: 520, minHeight: 360, idealHeight: 460, maxHeight: 560)
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
