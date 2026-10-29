//  The chrome's own menus, on an iPhone, an iPad and a Mac: the cards that
//  drop from the Audio, Subtitles, Quality and Up Next pills and from the
//  "…" button. Not the system's menus — those took the app's palette badly,
//  and the controls under them kept their clock and faded away mid-choice.
//  These are drawn by the transport over the picture, in the same glass and
//  rows as the panel, placed beside the control that opened them, held
//  open until a choice is made, the card's close is tapped, or the picture
//  is tapped (`PlayerChrome.tapPicture`). `PlayerChromeState.menu` says
//  which is open; `showsControls` keeps the controls up while one is.
//
//  A control reports where it is through `chromeMenuAnchor`, and
//  `ChromeMenuLayer`, laid over the whole transport, puts the open card
//  above a pill or under the "…" button — clamped to the picture, and no
//  taller than the room there is, scrolling inside when it needs more.

import SwiftUI

// MARK: - Where the controls are

/// The bounds of each control a card can hang off, keyed by its menu.
struct ChromeMenuAnchors: PreferenceKey {
    static let defaultValue: [PlayerChromeState.ChromeMenu: Anchor<CGRect>] = [:]

    static func reduce(value: inout [PlayerChromeState.ChromeMenu: Anchor<CGRect>],
                       nextValue: () -> [PlayerChromeState.ChromeMenu: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Says this control is the one `menu`'s card hangs off.
    func chromeMenuAnchor(_ menu: PlayerChromeState.ChromeMenu) -> some View {
        anchorPreference(key: ChromeMenuAnchors.self, value: .bounds) { [menu: $0] }
    }
}

// MARK: - The layer

/// The open card, beside its control: above a pill, left edges aligned;
/// under the "…" button, right edges aligned.
struct ChromeMenuLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var chrome: PlayerChromeState
    let anchors: [PlayerChromeState.ChromeMenu: Anchor<CGRect>]
    let compact: Bool
    /// A touch on a card: keeps the controls' clock honest once it closes.
    let onInteract: () -> Void
    /// Opens a page of the panel from a card — Channels, from "…".
    let openPanel: (PlayerTab) -> Void

    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            if let menu = chrome.menu, let anchor = anchors[menu] {
                let rect = geo[anchor]
                let width = min(compact ? 300 : 340, geo.size.width - Self.margin * 2)
                if menu == .more {
                    let x = max(Self.margin, min(rect.maxX - width, geo.size.width - width - Self.margin))
                    let room = geo.size.height - rect.maxY - Self.gap - Self.margin
                    VStack(spacing: 0) {
                        card(menu, maxHeight: room)
                        Spacer(minLength: 0)
                    }
                    .frame(width: width, height: max(0, room), alignment: .top)
                    .offset(x: x, y: rect.maxY + Self.gap)
                    .transition(transition(anchor: .topTrailing))
                    .id(menu)
                } else {
                    let x = max(Self.margin, min(rect.minX, geo.size.width - width - Self.margin))
                    let room = rect.minY - Self.gap - Self.margin
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        card(menu, maxHeight: room)
                    }
                    .frame(width: width, height: max(0, room), alignment: .bottom)
                    .offset(x: x, y: Self.margin)
                    .transition(transition(anchor: .bottomLeading))
                    .id(menu)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: chrome.menu)
    }

    private func transition(anchor: UnitPoint) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.96, anchor: anchor).combined(with: .opacity)
    }

    private func close() { chrome.menu = nil }

    @ViewBuilder
    private func card(_ menu: PlayerChromeState.ChromeMenu, maxHeight: CGFloat) -> some View {
        switch menu {
        case .audio:
            PlayerMenuCard(title: "Audio", symbol: "speaker.wave.2", maxHeight: maxHeight, close: close) {
                AudioMenu(onInteract: onInteract, close: close)
            }
        case .subtitles:
            PlayerMenuCard(title: "Subtitles", symbol: "captions.bubble", maxHeight: maxHeight, close: close) {
                SubtitlesMenu(onInteract: onInteract, close: close)
            }
        case .quality:
            PlayerMenuCard(title: "Quality", symbol: "slider.horizontal.3", maxHeight: maxHeight, close: close) {
                QualityMenu(onInteract: onInteract, close: close)
            }
        case .upNext:
            PlayerMenuCard(title: "Up Next", symbol: "text.line.first.and.arrowtriangle.forward",
                           maxHeight: maxHeight, close: close) {
                UpNextMenu(onInteract: onInteract, close: close)
            }
        case .more:
            PlayerMenuCard(title: "More", symbol: "ellipsis.circle", maxHeight: maxHeight, close: close) {
                MoreMenu(onInteract: onInteract, close: close, openPanel: openPanel)
            }
        }
    }
}

// MARK: - The card

/// Glass, a heading with its glyph and a close, and the rows under it: as
/// tall as the rows need, up to the room it was given, scrolling past that.
struct PlayerMenuCard<Content: View>: View {
    let title: String
    let symbol: String
    let maxHeight: CGFloat
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat?

    private var headerHeight: CGFloat { 44 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.link)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: headerHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.onChange(of: geo.size.height, initial: true) { _, now in contentHeight = now }
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: max(0, min(contentHeight ?? maxHeight, maxHeight - headerHeight)))
        }
        .playerGlass(cornerRadius: 20)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .playerChromeScheme()
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A short choice in a row of them — a speed, a sleep timer's minutes —
/// lit in the accent while it is the one in force.
private struct MenuChip: View {
    let title: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(isOn ? Theme.accent : Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PlayerPillStyle())
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Audio and subtitles

/// The file's audio tracks, the one playing ticked. A track the stream
/// doesn't carry says it will reopen the stream. See `PlayerModel.audioOptions`.
private struct AudioMenu: View {
    @Environment(PlayerModel.self) private var player
    let onInteract: () -> Void
    let close: () -> Void

    var body: some View {
        let options = player.audioOptions
        let selected = player.selectedAudioOption
        if options.isEmpty {
            PanelNote(text: player.isOpening ? "The stream is still opening." : "This stream lists no audio tracks.")
        } else {
            ForEach(options) { option in
                PanelRow(title: option.label,
                         detail: option.needsNewStream ? "Reopens the stream with this track" : nil,
                         isSelected: option.id == selected) {
                    onInteract()
                    player.selectAudio(option)
                    close()
                }
            }
        }
    }
}

private struct SubtitlesMenu: View {
    @Environment(PlayerModel.self) private var player
    let onInteract: () -> Void
    let close: () -> Void

    var body: some View {
        let options = player.subtitleOptions
        let selected = player.selectedSubtitleOption
        PanelRow(title: "Off", isSelected: selected == nil) {
            onInteract()
            player.selectSubtitles(nil)
            close()
        }
        ForEach(options) { option in
            PanelRow(title: option.label,
                     // Many forced tracks are named so already.
                     detail: [option.isForced && !option.label.localizedCaseInsensitiveContains("forced") ? "Forced" : nil,
                              option.needsNewStream ? "Drawn by the server · reopens the stream" : nil]
                        .compactMap { $0 }.joined(separator: " · "),
                     isSelected: option.id == selected) {
                onInteract()
                player.selectSubtitles(option)
                close()
            }
        }
        if options.isEmpty {
            PanelNote(text: "This stream has no subtitle tracks.")
        }
    }
}

// MARK: - Quality

/// Every rung, the one playing ticked and saying whether it is a transcode.
/// Only offered for a stream the server is choosing a bitrate for.
private struct QualityMenu: View {
    @Environment(PlayerModel.self) private var player
    let onInteract: () -> Void
    let close: () -> Void

    var body: some View {
        let selection = player.qualitySelection
        let auto = selection == .auto
        let streamable = player.offersQuality || player.isLocal

        if let reason = player.qualityUnavailableReason, !player.isLocal {
            PanelNote(text: reason)
        }
        // Auto first, then the rows in the order Auto tries them: the
        // download, Direct, and the transcodes from the largest down.
        PanelRow(title: "Auto",
                 detail: auto ? "Playing now · \(playingNow)" : "Downloaded, then Direct, then smaller streams",
                 isSelected: auto) {
            pick(.auto)
        }
        #if !os(tvOS)
        if let download = player.downloadedCopy {
            PanelRow(title: download.quality.isEmpty ? "Downloaded" : "Downloaded · \(download.quality)",
                     detail: player.isLocal ? (auto ? "Playing now" : "Playing now · from this device") : "From this device",
                     isSelected: !auto && player.isLocal) {
                pick(.downloaded)
            }
        }
        #endif
        ForEach(Quality.choices) { choice in
            let playing = !player.isLocal && player.currentBitrate == choice.maxBitrate
            PanelRow(title: choice.maxBitrate == nil ? "Direct (original)" : choice.label,
                     detail: playing ? (player.isTranscoding ? "Playing now · transcoding" : "Playing now")
                        : choice.maxBitrate == nil ? "The file as it is, no transcode" : nil,
                     isSelected: !auto && playing,
                     disabledReason: streamable ? nil : "Not for this stream") {
                pick(.stream(choice.maxBitrate))
            }
        }
        PanelNote(text: "Auto plays the downloaded copy if there is one, then Direct — the original file, no transcode — and steps down through the streams below it when the connection struggles, climbing back once it is steady. Picking a quality keeps it there.")
    }

    /// What Auto has landed on, in the pill's words.
    private var playingNow: String {
        player.isLocal ? "Downloaded" : player.currentBitrate == nil ? "Direct" : Quality.shortLabel(for: player.currentBitrate)
    }

    private func pick(_ selection: PlayerModel.QualitySelection) {
        onInteract()
        close()
        Task { await player.chooseQuality(selection) }
    }
}

// MARK: - Up Next

/// What is queued by hand, else the next few episodes the series has left
/// (`PlayerModel.upNextLimit`) with their stills, or for a download the
/// episodes after it on this device. A row plays its title now.
private struct UpNextMenu: View {
    @Environment(PlayerModel.self) private var player
    let onInteract: () -> Void
    let close: () -> Void

    var body: some View {
        if !player.queue.isEmpty {
            ForEach(player.queue, id: \.Id) { entry in
                PanelRow(title: PlayerModel.displayTitle(entry)) {
                    onInteract()
                    close()
                    Task { await player.playQueued(entry.Id) }
                } leading: {
                    still(entry)
                }
            }
            PanelRow(title: "Clear up next", detail: "Forget what was queued by hand") {
                onInteract()
                player.clearQueue()
                close()
            }
        } else {
            ForEach(player.upNextList, id: \.Id) { entry in
                PanelRow(title: PlayerModel.upNextRowTitle(entry),
                         detail: entry.title == PlayerModel.upNextRowTitle(entry) ? nil : entry.SeriesName) {
                    onInteract()
                    close()
                    Task { await player.playUpcoming(entry) }
                } leading: {
                    still(entry)
                }
            }
            #if !os(tvOS)
            ForEach(player.upNextLocal, id: \.itemId) { record in
                PanelRow(title: record.title, detail: "On this device") {
                    onInteract()
                    close()
                    player.playLocal(record, keepShuffle: true)
                }
            }
            #endif
        }
    }

    /// The episode's still, where the server has one.
    @ViewBuilder
    private func still(_ item: BaseItem) -> some View {
        if let url = Artwork.still(for: item, width: 240) {
            RemoteImage(url: url)
                .frame(width: 72, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - More

/// The rest: the speed, the sleep timer, what happens after this episode,
/// the channel lineup, Watch Together.
private struct MoreMenu: View {
    @Environment(PlayerModel.self) private var player
    let onInteract: () -> Void
    let close: () -> Void
    let openPanel: (PlayerTab) -> Void

    private let chipColumns = [GridItem(.adaptive(minimum: 58), spacing: 6)]

    var body: some View {
        if !player.isLive {
            PanelHeading(text: "Speed")
            LazyVGrid(columns: chipColumns, spacing: 6) {
                ForEach(PlayerModel.speeds, id: \.self) { rate in
                    MenuChip(title: PlayerModel.speedName(rate), isOn: abs(player.speed - rate) < 0.001) {
                        onInteract()
                        player.speed = rate
                    }
                    .accessibilityLabel("Speed \(PlayerModel.speedName(rate))")
                }
            }
        }

        PanelHeading(text: "Sleep timer")
        if let left = player.sleepMinutesRemaining {
            PanelRow(title: "Stopping in \(left) min", detail: "Tap to cancel the sleep timer", isSelected: true) {
                onInteract()
                player.cancelSleepTimer()
            }
        } else {
            HStack(spacing: 6) {
                ForEach([15, 30, 60, 90], id: \.self) { minutes in
                    MenuChip(title: "\(minutes) min") {
                        onInteract()
                        player.setSleepTimer(minutes: minutes)
                        close()
                    }
                    .accessibilityLabel("Stop in \(minutes) minutes")
                }
            }
        }

        if !player.isLive {
            PanelHeading(text: "After this")
            PanelRow(title: "Stop after this episode",
                     detail: player.autoplayCancelled ? "Nothing plays after this one"
                        : player.upNextTitle.map { "Otherwise next: \($0)" },
                     isSelected: player.autoplayCancelled) {
                onInteract()
                if player.autoplayCancelled { player.resumeAutoplay() } else { player.cancelAutoplay() }
            }
        }

        if player.isLive, player.channelLineup.count > 1 {
            PanelHeading(text: "Channels")
            PanelRow(title: "Change channel", detail: "\(player.channelLineup.count) channels") {
                onInteract()
                close()
                openPanel(.channels)
            }
        }

        #if !os(tvOS)
        if let item = player.item, !player.isLocal, !player.isLive,
           player.engine?.capabilities.contains(.sharePlay) == true || player.canSwitchEngine(to: .apple) {
            let shareplay = SharePlayCoordinator.shared
            PanelHeading(text: "Watch Together")
            if shareplay.isActive {
                PanelRow(title: "Leave SharePlay", isSelected: true) {
                    onInteract()
                    shareplay.leave()
                    close()
                }
            } else {
                // On mpv the stream is handed to AVPlayer first, whose player
                // the session coordinates.
                PanelRow(title: "Watch Together with SharePlay",
                         detail: "The same picture on everyone's screen, over FaceTime") {
                    onInteract()
                    close()
                    Task {
                        await player.prepareForSharePlay()
                        await shareplay.share(item)
                    }
                }
            }
        }
        #endif
    }
}
