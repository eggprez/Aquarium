//  The panel: a row of tabs, and under it the choices for the tab that is
//  open. Info · Channels · Audio · Subtitles · Quality · Speed · Sync ·
//  Picture. A sheet with medium and large detents on a phone, a popover off
//  the pill that opened it on an iPad or a Mac, and on the Apple TV the card
//  that comes down from the top of the picture on a swipe down: wide and
//  shallow, its tabs focusable, its rows cards in a row that scrolls
//  sideways, so as much of the picture as possible stays in view — most of
//  all on Sync and Picture, where the picture is what's being judged.
//
//  A row the engine cannot honour says why rather than vanishing: the quality
//  rungs under a download, the audio offset on a transcode, the picture
//  sliders on AVPlayer — the last two with a button that hands the title to
//  the mpv engine at the same position. The one thing a stream has nothing
//  of (a film has no channels) is left out of the tabs.
//
//  Focus, on a television: focusing a tab opens it, the way the system's own
//  tab bars work; moving down reaches its choices. Up, a swipe up or Menu
//  from a choice goes back to the tab it belongs to — never to whichever tab
//  happens to be above it — and from the tabs, Menu or a swipe up puts the
//  panel away (see `PlayerRemoteDriver` for the swipe). Every card is lifted
//  and painted from the app's palette (`PlayerFocusStyle`).

import SwiftUI

struct PlayerPanel: View {
    @Environment(PlayerModel.self) private var player
    @Binding var tab: PlayerTab
    let schedule: ChannelSchedule
    let artwork: InfoArtwork
    /// Puts the panel away, where the panel is the thing that decides: Menu
    /// from the row of tabs on a television.
    var close: (() -> Void)? = nil
    /// Told whether focus is on the row of tabs, for the swipe up that
    /// closes the panel from there on a television.
    var tabsFocused: ((Bool) -> Void)? = nil

    var body: some View {
        Group {
            #if os(tvOS)
            television
            #else
            stacked
            #endif
        }
        .foregroundStyle(Theme.text)
        // A tab the stream has nothing to show in — Channels after a channel
        // became a film — falls back to Info.
        .onChange(of: player.panelTabs, initial: true) { _, tabs in
            if !tabs.contains(tab) { tab = .info }
        }
    }

    // MARK: - A phone, an iPad, a Mac

    private var stacked: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(Theme.border)
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(player.panelTabs) { item in
                        Button {
                            tab = item
                        } label: {
                            PanelTabLabel(title: item.title, isCurrent: item == tab)
                        }
                        .buttonStyle(PlayerFocusStyle())
                        .id(item)
                        .accessibilityAddTraits(item == tab ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: tab, initial: true) { _, tab in
                withAnimation { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel tabs")
    }

    // MARK: - A television

    #if os(tvOS)
    private var television: some View {
        TelevisionPanelBody(tab: $tab, close: close, tabsFocused: tabsFocused) {
            content
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .playerGlass(cornerRadius: PlayerMetrics.panelCorner)
        // A row longer than the panel scrolls inside it rather than running
        // off its edge.
        .clipShape(RoundedRectangle(cornerRadius: PlayerMetrics.panelCorner, style: .continuous))
        .padding(.horizontal, PlayerMetrics.panelGutter)
        .padding(.top, PlayerMetrics.panelTop)
    }
    #endif

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .info: InfoTab(schedule: schedule, artwork: artwork)
        case .channels: ChannelsTab()
        case .audio: AudioTab()
        case .subtitles: SubtitlesTab()
        case .quality: QualityTab()
        case .speed: SpeedTab()
        case .sync: SyncTab()
        case .picture: PictureTab()
        }
    }
}

/// A tab along the top of the panel: text, with the accent capsule behind
/// the open one — or, on a television, behind the focused one and an accent
/// underline under the open one.
private struct PanelTabLabel: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let isCurrent: Bool

    var body: some View {
        let tv = PlayerMetrics.television
        let lit = tv ? isFocused : isCurrent
        Text(title)
            .font(tv ? .headline : .subheadline.weight(.semibold))
            .foregroundStyle(lit ? .white : isCurrent ? Theme.text : Theme.textDim)
            .padding(.horizontal, tv ? 22 : 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(lit ? Theme.accent : .clear))
            .overlay(alignment: .bottom) {
                if tv, isCurrent, !isFocused {
                    Capsule().fill(Theme.accent).frame(height: 4).padding(.horizontal, 22).offset(y: 4)
                }
            }
            .contentShape(Capsule())
    }
}

#if os(tvOS)
/// The television's panel: its row of tabs, driven by the focus engine, and
/// under it the open tab's cards. Menu from a card goes back up to its tab,
/// and from the tabs puts the panel away.
private struct TelevisionPanelBody<Content: View>: View {
    @Environment(PlayerModel.self) private var player
    @Binding var tab: PlayerTab
    let close: (() -> Void)?
    let tabsFocused: ((Bool) -> Void)?
    @ViewBuilder let content: () -> Content

    @FocusState private var focusedTab: PlayerTab?
    /// Whether focus has reached the row of tabs since the panel opened —
    /// see the retry in `body`.
    @State private var tabWasFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tabs
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                // While focus is on the row of tabs, a tab's choices can say
                // which of them Down should land on — see `panelEntryOnly`.
                .environment(\.panelTabsHaveFocus, focusedTab != nil)
        }
        .onChange(of: focusedTab) { was, focused in
            // Belt to the braces in `tabs`: should focus reach another tab
            // from a choice anyway, back to the one it belongs to.
            if was == nil, let focused, focused != tab {
                focusedTab = tab
                return
            }
            if let focused {
                tab = focused
                tabWasFocused = true
            }
            tabsFocused?(focused != nil)
        }
        // The tab opened from outside the row — a stream that lost its
        // Channels, the debug hook — while focus is on another tab: focus
        // follows, so the lit tab and the open one are the same thing.
        .onChange(of: tab) { _, now in
            if let focused = focusedTab, focused != now { focusedTab = now }
        }
        .defaultFocus($focusedTab, tab)
        // Claimed on appearing, and again a moment later if nothing has it:
        // the first claim can land while `RemoteInput` still holds focus and
        // be refused, which leaves focus nowhere — and Menu, with nothing
        // focused to take it, closing the player instead of the panel. Only
        // until a tab has had it once: after that, nothing focused on the
        // row means a press down into the choices, which a retry would undo.
        .onAppear { focusedTab = tab }
        .task {
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(100))
                if focusedTab != nil || tabWasFocused { return }
                focusedTab = tab
            }
        }
        .onDisappear { tabsFocused?(false) }
        // Menu: from a choice, back up to its tab; from the tabs, away.
        .onExitCommand {
            if focusedTab == nil {
                focusedTab = tab
            } else {
                close?()
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(player.panelTabs) { item in
                Button { tab = item } label: {
                    PanelTabLabel(title: item.title, isCurrent: item == tab)
                }
                .buttonStyle(PlayerFocusStyle())
                .focused($focusedTab, equals: item)
                // From the choices, Up can only reach the open tab: the
                // others can't take focus until it is on the row. Left to
                // the focus engine, Up takes the nearest tab above, which
                // lights up for a moment even when put right.
                .disabled(focusedTab == nil && item != tab)
                .accessibilityAddTraits(item == tab ? [.isSelected] : [])
            }
        }
        // The full width of the panel, so that Up finds the tabs from a
        // choice at the far right too, where no tab is directly above.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}
#endif

// MARK: - Rows

/// Whether focus is on the television panel's row of tabs. Read by a tab
/// whose choices are laid out in columns, where the focus engine would take
/// Down to whichever control is nearest the tab rather than the first: while
/// this is true every control but the first is kept from taking focus, so
/// Down can only land there. Off a television it is never true.
private struct PanelTabsHaveFocusKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var panelTabsHaveFocus: Bool {
        get { self[PanelTabsHaveFocusKey.self] }
        set { self[PanelTabsHaveFocusKey.self] = newValue }
    }
}

private extension View {
    /// Kept from taking focus while the tabs have it, unless this is the
    /// control Down should land on.
    func panelEntryOnly(_ isEntry: Bool) -> some View {
        modifier(PanelEntryOnly(isEntry: isEntry))
    }
}

private struct PanelEntryOnly: ViewModifier {
    @Environment(\.panelTabsHaveFocus) private var tabsHaveFocus
    let isEntry: Bool

    func body(content: Content) -> some View {
        content.disabled(tabsHaveFocus && !isEntry)
    }
}

/// The width a card in a row takes on a television; nil shares the row with
/// the other cards in it.
private struct PanelCardWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = 460
}

private extension EnvironmentValues {
    var panelCardWidth: CGFloat? {
        get { self[PanelCardWidthKey.self] }
        set { self[PanelCardWidthKey.self] = newValue }
    }
}

/// The rows of a tab: a column on a phone, an iPad or a Mac; on a television
/// a row of cards that scrolls sideways, or (`fills`) one that shares the
/// panel's width between them — every quality rung at once, every speed.
struct PanelRows<Content: View>: View {
    var fills = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if PlayerMetrics.television {
            if fills {
                HStack(spacing: 20) { content() }
                    .padding(.vertical, 10)
                    .environment(\.panelCardWidth, nil)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) { content() }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                }
                .scrollClipDisabled()
                // As tall as its cards: a sideways scroll view otherwise
                // takes all the height it is offered, and the panel with it.
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }
}

/// One choice in a tab: a title, an optional line under it, a tick when it is
/// the current one. A row that cannot be chosen keeps its place and says why.
/// On a television it is a card: the accent behind it while it has focus, a
/// tick in the accent when it is the current choice, lifted by
/// `PlayerFocusStyle`.
struct PanelRow<Leading: View>: View {
    let title: String
    var detail: String? = nil
    var isSelected = false
    var disabledReason: String? = nil
    /// A television card's width; nil shares the row. Ignored elsewhere.
    var width: CGFloat? = nil
    /// A television card's height; nil is as tall as the text needs.
    var height: CGFloat? = nil
    /// The title in the middle of the card, for short labels — `+5`,
    /// `Reset`, `1.5×` — that look adrift at its leading edge.
    var centered = false
    let action: () -> Void
    /// A channel's logo: above the title on a television, beside it
    /// elsewhere.
    @ViewBuilder var leading: () -> Leading

    @Environment(\.panelCardWidth) private var rowWidth

    var body: some View {
        Button(action: action) {
            if PlayerMetrics.television {
                PanelCardLabel(title: title, detail: detail, isSelected: isSelected, disabledReason: disabledReason,
                               width: width ?? rowWidth, height: height, centered: centered, leading: leading)
            } else {
                PanelRowLabel(title: title, detail: detail, isSelected: isSelected, disabledReason: disabledReason,
                              leading: leading)
            }
        }
        .buttonStyle(PlayerFocusStyle())
        .disabled(disabledReason != nil)
        .opacity(disabledReason != nil ? 0.75 : 1)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(disabledReason ?? "")
    }
}

extension PanelRow where Leading == EmptyView {
    init(title: String, detail: String? = nil, isSelected: Bool = false, disabledReason: String? = nil,
         width: CGFloat? = nil, height: CGFloat? = nil, centered: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, isSelected: isSelected, disabledReason: disabledReason,
                  width: width, height: height, centered: centered, action: action) { EmptyView() }
    }
}

private struct PanelRowLabel<Leading: View>: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let detail: String?
    let isSelected: Bool
    let disabledReason: String?
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(isFocused ? .white : Theme.text)
                    .multilineTextAlignment(.leading)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isFocused ? .white.opacity(0.85) : Theme.textDim)
                        .multilineTextAlignment(.leading)
                }
                if let disabledReason {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isFocused ? .white : Theme.link)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.playerFill(focused: isFocused, rest: isSelected ? Theme.accentSoft : Color.white.opacity(0.06)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The television's card. Lifted from the Apple TV player's `ChoiceCard`.
private struct PanelCardLabel<Leading: View>: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let detail: String?
    let isSelected: Bool
    let disabledReason: String?
    let width: CGFloat?
    let height: CGFloat?
    let centered: Bool
    @ViewBuilder var leading: () -> Leading

    /// Where the tick goes: in the corner when the card is too narrow to
    /// spare the title the room, or when the title is centred and a tick
    /// beside it would push it off the middle.
    private var tickInCorner: Bool { width == nil || centered }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            leading()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if centered { Spacer(minLength: 0) }
                // Only a card sharing its row's width shrinks its title to
                // fit. One of its own width — a long track name, with the
                // tick beside it — takes a third line instead: shrunk, the
                // chosen track read smaller than the ones beside it and was
                // cut off all the same.
                Text(title)
                    .font(.headline)
                    .lineLimit(width == nil ? 2 : 3)
                    .minimumScaleFactor(width == nil ? 0.75 : 1)
                    .multilineTextAlignment(centered ? .center : .leading)
                Spacer(minLength: 0)
                if isSelected, !tickInCorner { checkmark }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFocused ? .white.opacity(0.85) : Theme.textDim)
                    .lineLimit(2)
            }
            if let disabledReason, !disabledReason.isEmpty {
                Text(disabledReason)
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(isFocused ? .white : Theme.text)
        .padding(.horizontal, centered ? 12 : 24)
        .padding(.vertical, 10)
        .frame(width: width, alignment: centered ? .center : .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: centered ? .center : .leading)
        .frame(minHeight: height ?? 72)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.playerFill(focused: isFocused, rest: Color.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected && !isFocused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 2)
        )
        // A card sharing a row is too narrow to give the title's width to
        // the tick, so there it sits in the corner instead.
        .overlay(alignment: .topTrailing) {
            if isSelected, tickInCorner { checkmark.padding(12) }
        }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.headline.weight(.bold))
            .foregroundStyle(isFocused ? .white : Theme.link)
    }
}

/// A short button in a row of them: a sync step, a picture step, a sleep
/// timer's minutes. A small card on a television, a square elsewhere.
struct PanelStepButton: View {
    let title: String
    var width: CGFloat? = nil
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        if PlayerMetrics.television {
            PanelRow(title: title, width: width ?? 130, height: 64, centered: true, action: action)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1)
        } else {
            Button(action: action) {
                PanelStepLabel(title: title)
            }
            .buttonStyle(PlayerFocusStyle())
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.4 : 1)
        }
    }
}

private struct PanelStepLabel: View {
    @Environment(\.isFocused) private var isFocused
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(isFocused ? .white : Theme.text)
            .frame(minWidth: 44)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.playerFill(focused: isFocused, rest: Color.white.opacity(0.06))))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A heading between groups of rows.
private struct PanelHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.heavy))
            .foregroundStyle(Theme.link)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A sentence that stands in for rows the stream has none of, or explains
/// why a whole tab is quiet.
private struct PanelNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }
}

/// A value from a range: a slider where there is a finger or a pointer to
/// drag one; on a television, which has no slider a remote can drive, a
/// step down and a step up either side of the value and a bar showing where
/// in the range it is.
private struct PanelSlider: View {
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var enabled = true
    /// On a television, the control Down lands on from the row of tabs —
    /// see `panelEntryOnly`.
    var isEntry = false
    let format: (Double) -> String

    /// The label's column and the value's, in points at the default type
    /// size; wider as the type grows so neither clips at the
    /// accessibility sizes.
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 88
    @ScaledMetric(relativeTo: .subheadline) private var valueWidth: CGFloat = 52

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 12) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .frame(width: 230, alignment: .leading)
            PanelStepButton(title: "−", width: 84, isDisabled: !enabled || value <= range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            .panelEntryOnly(isEntry)
            .accessibilityLabel("Decrease \(name)")
            VStack(spacing: 6) {
                Text(format(value))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.text)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
            .frame(width: 150)
            PanelStepButton(title: "+", width: 84, isDisabled: !enabled || value >= range.upperBound) {
                value = min(range.upperBound, value + step)
            }
            .panelEntryOnly(false)
            .accessibilityLabel("Increase \(name)")
        }
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(format(value))
        #else
        HStack(spacing: 12) {
            Text(name)
                .font(.subheadline)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .tint(Theme.accent)
                .disabled(!enabled)
                .accessibilityLabel(name)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textDim)
                .frame(width: valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .opacity(enabled ? 1 : 0.5)
        #endif
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }
}

// MARK: - Info

private struct InfoTab: View {
    @Environment(PlayerModel.self) private var player
    let schedule: ChannelSchedule
    let artwork: InfoArtwork

    var body: some View {
        if PlayerMetrics.television { wide } else { tall }
    }

    /// Across the top of the picture: the poster, the words, what can be
    /// changed, and the stream in a line.
    private var wide: some View {
        let rows = PlayerStreamRows(player: player)
        let _ = player.position
        return HStack(alignment: .center, spacing: 32) {
            if let url = InfoArtwork.url(for: player) {
                poster(url)
                    .frame(width: player.isLive ? 150 : 104, height: player.isLive ? 96 : 156)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                if player.isLive { live } else { onDemand }
                Text(Self.summary(rows))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 4)
    }

    /// What the stream is, in a line: delivery, size, rate, engine, display.
    private static func summary(_ rows: PlayerStreamRows) -> String {
        var parts: [String] = []
        for row in rows.stream where ["Delivery", "Arriving at", "Variant"].contains(row.label) {
            parts.append(row.value)
        }
        for row in rows.now where ["Engine", "Display"].contains(row.label) {
            parts.append(row.label == "Display" ? "Display \(row.value)" : row.value)
        }
        return parts.joined(separator: " · ")
    }

    /// What the Info tab can change, on a television: whether the next
    /// episode starts by itself, and the sleep timer.
    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !player.isLive, player.item?.isEpisode == true {
                let on = !player.autoplayCancelled
                PanelRow(title: on ? "Autoplay: On" : "Autoplay: Off", isSelected: on, width: 340) {
                    on ? player.cancelAutoplay() : player.resumeAutoplay()
                }
            }
            if let left = player.sleepMinutesRemaining {
                PanelRow(title: "Sleep: \(left) min left", detail: "Click to cancel", isSelected: true, width: 340) {
                    player.cancelSleepTimer()
                }
            } else {
                HStack(spacing: 10) {
                    Text("Sleep")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.link)
                    ForEach([15, 30, 60, 90], id: \.self) { minutes in
                        PanelRow(title: "\(minutes)m", width: 130, height: 64, centered: true) {
                            player.setSleepTimer(minutes: minutes)
                        }
                        .accessibilityLabel("Stop in \(minutes) minutes")
                    }
                }
            }
        }
    }

    private var tall: some View {
        let rows = PlayerStreamRows(player: player)
        // Read here so the stream figures, which nothing writes, redraw on the
        // player's clock.
        let _ = player.position
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                if let url = InfoArtwork.url(for: player) {
                    poster(url)
                        .frame(width: player.isLive ? 110 : 84, height: player.isLive ? 70 : 126)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if player.isLive { live } else { onDemand }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !player.isLive, player.item?.isEpisode == true {
                PanelHeading(text: "After this")
                PanelRow(title: player.autoplayCancelled ? "Stop after this episode" : "Play the next episode automatically",
                         detail: player.upNextTitle.map { "Next: \($0)" },
                         isSelected: !player.autoplayCancelled) {
                    player.autoplayCancelled ? player.resumeAutoplay() : player.cancelAutoplay()
                }
            }

            PanelHeading(text: "Sleep timer")
            sleepTimer

            let stream = rows.stream
            if !stream.isEmpty {
                PanelHeading(text: "Coming down")
                facts(stream)
            }
            let file = rows.file
            if !file.isEmpty {
                PanelHeading(text: "On the server")
                facts(file)
            }
            let now = rows.now
            if !now.isEmpty {
                PanelHeading(text: "Playing")
                facts(now)
            }
        }
    }

    /// The one fetched beforehand when there is one — see `InfoArtwork` — and
    /// fetched now only if the panel beat it.
    @ViewBuilder
    private func poster(_ url: URL) -> some View {
        let mode: ContentMode = player.isLive ? .fit : .fill
        if artwork.url == url, let image = artwork.image {
            Color.clear.overlay {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
                #else
                Image(nsImage: image).resizable().aspectRatio(contentMode: mode)
                #endif
            }
            .clipped()
        } else {
            RemoteImage(url: url, contentMode: mode)
        }
    }

    @ViewBuilder
    private var onDemand: some View {
        let item = player.infoItem
        let tv = PlayerMetrics.television
        Text(item?.title ?? player.title)
            .font(tv ? .title3.weight(.bold) : .headline)
        if let facts = Self.facts(item), !facts.isEmpty {
            Text(facts)
                .font(tv ? .callout : .subheadline)
                .foregroundStyle(Theme.textBody)
                .lineLimit(tv ? 1 : nil)
        }
        if let overview = item?.Overview, !overview.isEmpty {
            Text(overview)
                .font(tv ? .callout : .subheadline)
                .foregroundStyle(Theme.textBody)
                .lineLimit(tv ? 2 : 4)
        }
    }

    @ViewBuilder
    private var live: some View {
        let tv = PlayerMetrics.television
        if let now = schedule.now {
            Text(now.title)
                .font(tv ? .title3.weight(.bold) : .headline)
            if let start = now.programStart, let end = now.programEnd {
                Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                    .font(tv ? .callout : .subheadline)
                    .foregroundStyle(Theme.textBody)
            }
            if let overview = now.Overview, !overview.isEmpty {
                Text(overview)
                    .font(tv ? .callout : .subheadline)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(tv ? 2 : 3)
            }
        } else {
            Text(player.title)
                .font(tv ? .title3.weight(.bold) : .headline)
        }
        if !schedule.upcoming.isEmpty {
            if tv {
                HStack(spacing: 30) {
                    Text("COMING UP")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.link)
                    ForEach(schedule.upcoming.prefix(3), id: \.Id) { programme in
                        Text("\(programme.programStart?.formatted(date: .omitted, time: .shortened) ?? "") \(programme.title)")
                            .font(.caption)
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("COMING UP")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.link)
                        .padding(.top, 4)
                    ForEach(schedule.upcoming.prefix(3), id: \.Id) { programme in
                        Text("\(programme.programStart?.formatted(date: .omitted, time: .shortened) ?? "") \(programme.title)")
                            .font(.caption)
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sleepTimer: some View {
        if let left = player.sleepMinutesRemaining {
            PanelRow(title: "Stopping in \(left) min", detail: "Tap to cancel the sleep timer", isSelected: true) {
                player.cancelSleepTimer()
            }
        } else {
            HStack(spacing: 8) {
                ForEach([15, 30, 60, 90], id: \.self) { minutes in
                    PanelStepButton(title: "\(minutes) min") {
                        player.setSleepTimer(minutes: minutes)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Stop in \(minutes) minutes")
                }
            }
        }
    }

    private func facts(_ rows: [PlayerStreamRows.Row]) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .foregroundStyle(Theme.textDim)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .multilineTextAlignment(.trailing)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    static func facts(_ item: BaseItem?) -> String? {
        guard let item else { return nil }
        var parts: [String] = []
        if item.isEpisode, let label = item.episodeLabel {
            parts.append([item.SeriesName, label].compactMap { $0 }.joined(separator: " · "))
        } else if let year = item.ProductionYear {
            parts.append(String(year))
        }
        if let ticks = item.RunTimeTicks, ticks > 0 {
            let minutes = Int(Double(ticks) / 600_000_000)
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        if let rating = item.OfficialRating { parts.append(rating) }
        if let score = item.CommunityRating { parts.append("★ " + score.formatted(.number.precision(.fractionLength(1)))) }
        if let genres = item.Genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Channels

private struct ChannelsTab: View {
    @Environment(PlayerModel.self) private var player
    @FocusState private var focused: String?

    var body: some View {
        let current = player.currentChannel?.Id
        let tv = PlayerMetrics.television
        PanelRows {
            ForEach(player.channelLineup, id: \.Id) { channel in
                PanelRow(
                    title: channel.title,
                    detail: channel.ChannelNumber.map { "Channel \($0)" },
                    isSelected: channel.Id == current,
                    width: 300
                ) {
                    player.playChannel(channel)
                } leading: {
                    RemoteImage(url: Artwork.channelLogo(channel, width: tv ? 240 : 160), contentMode: .fit)
                        .frame(width: tv ? 252 : 56, height: tv ? 90 : 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .focused($focused, equals: channel.Id)
            }
        }
        .defaultFocus($focused, current)
    }
}

// MARK: - Audio and subtitles

private struct AudioTab: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        let options = player.audioOptions
        let selected = player.selectedAudioOption
        VStack(alignment: .leading, spacing: 6) {
            if options.isEmpty {
                PanelNote(text: player.isOpening ? "The stream is still opening." : "This stream lists no audio tracks.")
            } else {
                PanelRows {
                    ForEach(options) { option in
                        PanelRow(title: option.label,
                                 detail: option.needsNewStream ? "Reopens the stream with this track" : nil,
                                 isSelected: option.id == selected) {
                            player.selectAudio(option)
                        }
                    }
                }
            }

            #if !os(tvOS)
            // A menu picker, which a television has no control for; its
            // language rows are in Settings.
            PanelHeading(text: "Preferred language")
            Picker(selection: $prefs.audioLanguage) {
                ForEach(Languages.audioChoices, id: \.code) { Text($0.name).tag($0.code) }
            } label: {
                Text("Preferred audio language")
            }
            .pickerStyle(.menu)
            .tint(Theme.link)
            // A language chosen here is kept for everything played after, and
            // this title switches to it now when it has such a track.
            .onChange(of: prefs.audioLanguage) { _, code in
                guard let option = player.audioOptions.first(where: { Languages.matches(preference: code, tag: $0.language) }),
                      option.id != player.selectedAudioOption else { return }
                player.selectAudio(option)
            }
            #endif
        }
    }
}

private struct SubtitlesTab: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        let options = player.subtitleOptions
        let selected = player.selectedSubtitleOption
        VStack(alignment: .leading, spacing: 6) {
            PanelRows {
                PanelRow(title: "Off", isSelected: selected == nil, width: 200) {
                    player.selectSubtitles(nil)
                }
                ForEach(options) { option in
                    PanelRow(title: option.label,
                             detail: [option.isForced ? "Forced" : nil,
                                      option.needsNewStream ? "Drawn by the server · reopens the stream" : nil]
                                .compactMap { $0 }.joined(separator: " · "),
                             isSelected: option.id == selected) {
                        player.selectSubtitles(option)
                    }
                }
            }
            if options.isEmpty {
                PanelNote(text: "This stream has no subtitle tracks.")
            }

            #if !os(tvOS)
            PanelHeading(text: "Preferred language")
            Picker(selection: $prefs.subtitleLanguage) {
                ForEach(Languages.subtitleChoices, id: \.code) { Text($0.name).tag($0.code) }
            } label: {
                Text("Preferred subtitle language")
            }
            .pickerStyle(.menu)
            .tint(Theme.link)
            .onChange(of: prefs.subtitleLanguage) { _, code in
                if code == "off" {
                    if player.selectedSubtitleOption != nil { player.selectSubtitles(nil) }
                    return
                }
                let matching = player.subtitleOptions.filter { Languages.matches(preference: code, tag: $0.language) }
                guard let option = matching.first(where: { !$0.isForced }) ?? matching.first,
                      option.id != player.selectedSubtitleOption else { return }
                player.selectSubtitles(option)
            }
            #endif
        }
    }
}

// MARK: - Quality

/// Every rung: a column of rows, or on a television every card at once
/// across the panel, each the same size.
private struct QualityTab: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = player.qualityUnavailableReason {
                PanelNote(text: reason)
            }
            PanelRows(fills: true) {
                ForEach(Quality.choices) { choice in
                    let current = player.currentBitrate == choice.maxBitrate
                    PanelRow(title: Self.title(choice),
                             detail: PlayerMetrics.television ? nil
                                : current && player.isTranscoding ? "Playing now · transcoding" : current ? "Playing now" : nil,
                             isSelected: current,
                             disabledReason: player.qualityUnavailableReason == nil ? nil : "Not for this stream",
                             height: PlayerMetrics.television ? 96 : nil) {
                        guard !current else { return }
                        Task { await player.switchQuality(to: choice.maxBitrate) }
                    }
                }
            }
            if prefs.adaptiveQuality, player.offersQuality, !PlayerMetrics.television {
                PanelNote(text: "The stream steps down on its own when the connection struggles, and back up once it is steady. Settings → Video turns that off.")
            }
        }
    }

    /// "4K" over "36 Mbps" on a television: seven cards to a row leaves no
    /// room for the two side by side.
    private static func title(_ choice: QualityChoice) -> String {
        guard PlayerMetrics.television, choice.maxBitrate != nil else {
            return choice.maxBitrate == nil && PlayerMetrics.television ? "Original" : choice.label
        }
        return choice.label.components(separatedBy: " · ").reversed().joined(separator: "\n")
    }
}

// MARK: - Speed

private struct SpeedTab: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if player.isLive {
                PanelNote(text: "A live channel plays at its own pace.")
            }
            PanelRows(fills: true) {
                ForEach(PlayerModel.speeds, id: \.self) { rate in
                    PanelRow(title: PlayerModel.speedName(rate),
                             isSelected: abs(player.speed - rate) < 0.001,
                             disabledReason: player.isLive ? "Not on a live channel" : nil,
                             height: PlayerMetrics.television ? 64 : nil,
                             centered: PlayerMetrics.television) {
                        player.speed = rate
                    }
                }
            }
        }
    }
}

// MARK: - Sync

/// The sound against the picture, moved while the picture plays behind:
/// five milliseconds a step, fifty for a room that is a long way out. Signed
/// the way a receiver's lip-sync control is — minus holds the sound back,
/// plus brings it forward — which is the opposite of the stored value
/// (`Preferences.audioDelay`, positive for later), so the tab shows and steps
/// its negation. Lifted from the Apple TV's tab; on AVPlayer a change rebuilds
/// the stream, so a run of taps is settled first and applied once. On the
/// Apple TV the offset moved is the one for the frame rate of what is
/// playing — `PlayerModel.audioDelayScope` says which.
private struct SyncTab: View {
    @Environment(PlayerModel.self) private var player

    /// The number on screen, ahead of the model while taps settle.
    @State private var pending: Int?
    @State private var commit: Task<Void, Never>?

    private static let settle: Duration = .milliseconds(350)

    private var reach: Int { player.audioDelayReach }

    var body: some View {
        let current = pending ?? player.audioDelayMilliseconds
        let shown = -current
        let reason = player.audioDelayUnavailableReason
        let tv = PlayerMetrics.television
        VStack(alignment: .leading, spacing: 10) {
            if let reason {
                PanelNote(text: reason)
            }
            HStack(spacing: tv ? 20 : 8) {
                step(-50, current: current, reason: reason)
                step(-5, current: current, reason: reason)
                VStack(spacing: 2) {
                    Text(shown == 0 ? "In step" : "\(shown > 0 ? "+" : "−")\(abs(shown)) ms")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(shown)))
                    Text(caption(current))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: tv ? 380 : .infinity)
                .accessibilityElement(children: .combine)
                step(5, current: current, reason: reason)
                step(50, current: current, reason: reason)
                if tv {
                    Spacer(minLength: 0)
                    reset(current: current, reason: reason)
                }
            }
            .animation(.easeOut(duration: 0.15), value: shown)

            if !tv { reset(current: current, reason: reason) }

            if reason != nil, player.canDelayAudioBySwitching {
                EngineSwitchRow(reason: "audio delay")
            }

            if player.canResync || player.canReencodeForSync {
                if !tv { PanelHeading(text: "Repairs") }
                PanelRows {
                    if player.canResync {
                        PanelRow(title: "Resync audio",
                                 detail: "Flushes picture and sound and starts them together again. A visible hiccup, so it is never done unasked.") {
                            player.resyncAudio()
                        }
                    }
                    if player.canReencodeForSync {
                        PanelRow(title: "Re-encode for sync",
                                 detail: "Asks the server to encode picture and sound together rather than copying either through — for a transcode that drifts.") {
                            Task { await player.reencodeForSync() }
                        }
                    }
                }
            }
            if !player.isLive, !tv {
                PanelNote(text: "Saved for everything you play on this device.")
            }
        }
        .onChange(of: player.audioDelayMilliseconds) { _, _ in
            // The model caught up, or something else moved it: the number on
            // screen follows, and a tap still settling is dropped.
            commit?.cancel()
            commit = nil
            pending = nil
        }
        .onDisappear { flush() }
    }

    /// Which way the sound is moved and, where there is one offset per frame
    /// rate, which one this is.
    private func caption(_ current: Int) -> String {
        let direction = current == 0 ? "Picture and sound together" : current < 0 ? "Sound earlier" : "Sound later"
        guard let scope = player.audioDelayScope else { return direction }
        return [current == 0 ? "Together" : direction, scope].joined(separator: " · ")
    }

    /// `delta` as the tab signs it: negative holds the sound back.
    private func step(_ delta: Int, current: Int, reason: String?) -> some View {
        let target = current - delta
        return PanelStepButton(title: delta > 0 ? "+\(delta)" : "−\(-delta)",
                               isDisabled: reason != nil || abs(target) > reach) {
            set(target)
        }
        .accessibilityLabel(delta > 0 ? "Sound \(delta) milliseconds earlier" : "Sound \(-delta) milliseconds later")
    }

    private func reset(current: Int, reason: String?) -> some View {
        PanelRow(title: "Reset",
                 detail: PlayerMetrics.television ? nil : "Put the sound back in step with the picture",
                 disabledReason: reason == nil || current == 0 ? nil : "Not on this stream",
                 width: 180, height: PlayerMetrics.television ? 64 : nil, centered: PlayerMetrics.television) {
            set(0)
        }
    }

    private func set(_ value: Int) {
        let clamped = min(max(value, -reach), reach)
        pending = clamped
        commit?.cancel()
        commit = Task {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            player.setAudioDelay(milliseconds: clamped)
            pending = nil
        }
    }

    private func flush() {
        commit?.cancel()
        commit = nil
        guard let pending, pending != player.audioDelayMilliseconds else { return }
        player.setAudioDelay(milliseconds: pending)
        self.pending = nil
    }
}

// MARK: - Picture

/// Brightness, contrast, saturation and gamma, a zoom and an aspect
/// override, applied to the live picture: the mpv engine's. On AVPlayer every
/// row says so and the row under them hands the title over. The values are
/// the Settings ones, so what is set here holds for everything played after,
/// and Reset puts the file's own picture back. On a television the sliders
/// are steppers in two columns and the aspect ratios a row of cards, so the
/// picture being judged stays mostly in view.
private struct PictureTab: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        let reason = player.pictureUnavailableReason
        let live = reason == nil
        VStack(alignment: .leading, spacing: 10) {
            if let reason {
                PanelNote(text: reason)
                if player.canSwitchEngine(to: .mpv) {
                    EngineSwitchRow(reason: "picture controls")
                }
            }

            if PlayerMetrics.television {
                // Down from the row of tabs lands on Brightness's "−", the
                // first control, whichever tab it comes from: the others
                // are kept from taking focus until it is in the columns.
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 10) {
                        adjustment("Brightness", value: $prefs.pictureBrightness, enabled: live, isEntry: true)
                        adjustment("Contrast", value: $prefs.pictureContrast, enabled: live)
                        adjustment("Saturation", value: $prefs.pictureSaturation, enabled: live)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        adjustment("Gamma", value: $prefs.pictureGamma, enabled: live)
                        zoom(enabled: live)
                        HStack(spacing: 20) {
                            reset.panelEntryOnly(false)
                            nightMode.panelEntryOnly(false)
                        }
                    }
                }
            } else {
                PanelHeading(text: "Picture")
                adjustment("Brightness", value: $prefs.pictureBrightness, enabled: live)
                adjustment("Contrast", value: $prefs.pictureContrast, enabled: live)
                adjustment("Saturation", value: $prefs.pictureSaturation, enabled: live)
                adjustment("Gamma", value: $prefs.pictureGamma, enabled: live)
                PanelHeading(text: "Zoom")
                zoom(enabled: live)
            }

            if !PlayerMetrics.television { PanelHeading(text: "Aspect ratio") }
            PanelRows(fills: PlayerMetrics.television) {
                ForEach(Preferences.aspectChoices, id: \.ratio) { choice in
                    PanelRow(title: choice.label,
                             isSelected: abs(prefs.aspectOverride - choice.ratio) < 0.001,
                             disabledReason: live ? nil : "Needs the mpv engine",
                             height: PlayerMetrics.television ? 64 : nil,
                             centered: PlayerMetrics.television) {
                        prefs.aspectOverride = choice.ratio
                        player.applyFraming()
                    }
                }
            }
            .panelEntryOnly(false)

            if !PlayerMetrics.television {
                reset
                PanelHeading(text: "Sound")
                nightMode
                if live {
                    PanelNote(text: "Saved for everything you play on this device.")
                }
            }
        }
    }

    /// One of the four adjustments: -100…100, 0 being the file's own.
    private func adjustment(_ name: String, value: Binding<Double>, enabled: Bool, isEntry: Bool = false) -> some View {
        PanelSlider(name: name, value: value, range: -100...100, step: PlayerMetrics.television ? 5 : 1,
                    enabled: enabled, isEntry: isEntry) { "\(Int($0))" }
            .onChange(of: value.wrappedValue) { _, _ in player.applyPicture() }
    }

    /// Dynamic range compression on the sound: the engine's existing knob,
    /// with a reason in place of the switch where the engine has none.
    private var nightMode: some View {
        let tv = PlayerMetrics.television
        let reason = player.nightModeUnavailableReason
        // Ticked only while it is in force: a setting left on against an
        // engine that refused it is not a night mode.
        return PanelRow(title: tv ? (prefs.nightMode && reason == nil ? "Night mode: On" : "Night mode: Off") : "Night mode",
                        detail: tv ? nil : "Quiet dialogue up, loud passages down, for a room where the volume has to stay low",
                        isSelected: prefs.nightMode && reason == nil,
                        disabledReason: reason,
                        width: 460, height: tv ? 64 : nil, centered: tv) {
            prefs.nightMode.toggle()
            player.applyNightMode()
        }
        .accessibilityValue(prefs.nightMode ? "On" : "Off")
    }

    private func zoom(enabled: Bool) -> some View {
        @Bindable var prefs = prefs
        return PanelSlider(name: "Zoom", value: $prefs.pictureZoom, range: 1...2,
                           step: PlayerMetrics.television ? 0.1 : 0.05, enabled: enabled) {
            "\($0.formatted(.number.precision(.fractionLength(2))))×"
        }
        .onChange(of: prefs.pictureZoom) { _, _ in player.applyFraming() }
    }

    private var reset: some View {
        let tv = PlayerMetrics.television
        return PanelRow(title: tv ? "Reset picture" : "Reset",
                        detail: tv ? nil : "The file's own picture: no adjustment, no zoom, its own shape",
                        disabledReason: prefs.pictureIsAdjusted ? nil : tv ? "" : "Nothing is adjusted",
                        width: 460, height: tv ? 64 : nil, centered: tv) {
            prefs.resetPicture()
            player.applyPicture()
            player.applyFraming()
        }
    }
}

/// The row that hands the title to the mpv engine at the same position, for
/// a tab whose controls are mpv's.
private struct EngineSwitchRow: View {
    @Environment(PlayerModel.self) private var player
    let reason: String

    var body: some View {
        PanelRow(title: "Switch to the mpv engine for this title",
                 detail: "Reopens where it is now. Apple's engine comes back for the next title, or for Picture in Picture and AirPlay.") {
            Task { await player.switchEngine(to: .mpv, reason: reason) }
        }
    }
}
