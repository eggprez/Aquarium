//  The panel that comes down from the top of the picture on a swipe down: a
//  row of tabs, and under it the choices for the tab that is open. Focusing a
//  tab opens it, the way the system's own tab bars work; moving down reaches
//  its choices. Up, a swipe up or Menu from a choice goes back to the tab it
//  belongs to — never to whichever tab happens to be above it — and from the
//  tabs, Menu or a swipe up puts the panel away (see `PlayerScreen` for the
//  swipe).

#if os(tvOS)

import SwiftUI

enum PlayerTab: String, Hashable, CaseIterable, Identifiable {
    case info, channels, audio, subtitles, quality, speed, sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .channels: "Channels"
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        case .quality: "Quality"
        case .speed: "Speed"
        case .sync: "Sync"
        }
    }
}

struct TVPlayerPanel: View {
    @Environment(PlayerModel.self) private var player
    @Binding var tab: PlayerTab?
    /// Whether focus is on the row of tabs, for the swipe up that closes the
    /// panel from there.
    @Binding var tabsFocused: Bool
    let schedule: ChannelSchedule
    let artwork: InfoArtwork

    @FocusState private var focusedTab: PlayerTab?

    /// The tabs this stream has something to show in.
    private var tabs: [PlayerTab] {
        var out: [PlayerTab] = [.info]
        if player.isLive, player.channelLineup.count > 1 { out.append(.channels) }
        out.append(.audio)
        out.append(.subtitles)
        if !player.isExternal, !player.isLive { out.append(.quality) }
        if !player.isLive { out.append(.speed) }
        out.append(.sync)
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(tabs) { item in
                    Button { tab = item } label: {
                        PanelTabLabel(title: item.title, isCurrent: item == tab)
                    }
                    .buttonStyle(PlayerCardStyle())
                    .focused($focusedTab, equals: item)
                    // From the choices, Up can only reach the open tab: the
                    // others can't take focus until it is on the row. Left
                    // to the focus engine, Up takes the nearest tab above,
                    // which lights up for a moment even when put right.
                    .disabled(focusedTab == nil && item != (tab ?? .info))
                }
            }
            // The full width of the panel, so that Up finds the tabs from a
            // choice at the far right too, where no tab is directly above.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
        // Wide and shallow: across the top of the picture rather than down
        // into it, so as much of it as possible stays in view — most of all
        // on Sync, where the picture is what's being judged.
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .playerGlass(cornerRadius: 28)
        // A row longer than the panel scrolls inside it rather than running
        // off its edge.
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .onChange(of: focusedTab) { was, focused in
            // Belt to the braces above: should focus reach another tab from
            // a choice anyway, back to the one it belongs to.
            if was == nil, let focused, let tab, focused != tab {
                focusedTab = tab
                return
            }
            if let focused { tab = focused }
            tabsFocused = focused != nil
        }
        .defaultFocus($focusedTab, tab ?? .info)
        // Claimed on appearing, and again a moment later if nothing has it:
        // the first claim can land while `RemoteInput` still holds focus and
        // be refused, which leaves focus nowhere — and Menu, with nothing
        // focused to take it, closing the player instead of the panel.
        .onAppear { focusedTab = tab }
        .task {
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(100))
                if focusedTab != nil { return }
                focusedTab = tab ?? .info
            }
        }
        // Menu: from a choice, back up to its tab; from the tabs, away.
        .onExitCommand {
            if focusedTab == nil, let tab {
                focusedTab = tab
            } else {
                tab = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab ?? .info {
        case .info: InfoTab(schedule: schedule, artwork: artwork)
        case .channels: ChannelsTab()
        case .audio: AudioTab()
        case .subtitles: SubtitlesTab()
        case .quality: QualityTab()
        case .speed: SpeedTab()
        case .sync: SyncTab()
        }
    }
}

// MARK: - Rows

/// A row of cards that scrolls sideways.
private struct CardRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) { content() }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
        }
        .scrollClipDisabled()
        // As tall as its cards: a sideways scroll view otherwise takes all
        // the height it is offered, and the panel with it.
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Info

private struct InfoTab: View {
    @Environment(PlayerModel.self) private var player
    let schedule: ChannelSchedule
    let artwork: InfoArtwork

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            if let url = InfoArtwork.url(for: player) {
                poster(url)
                    .frame(width: player.isLive ? 150 : 104, height: player.isLive ? 96 : 156)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                if player.isLive { live } else { onDemand }
                Text(player.streamSummary.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 4)
    }

    /// The one fetched beforehand when there is one — see `InfoArtwork` — and
    /// fetched now only if the panel beat it.
    @ViewBuilder
    private func poster(_ url: URL) -> some View {
        let mode: ContentMode = player.isLive ? .fit : .fill
        if artwork.url == url, let image = artwork.image {
            Color.clear.overlay {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: mode)
            }
            .clipped()
        } else {
            RemoteImage(url: url, contentMode: mode)
        }
    }

    @ViewBuilder
    private var onDemand: some View {
        let item = player.infoItem
        Text(item?.title ?? player.title)
            .font(.title3.weight(.bold))
        if let facts = facts(item), !facts.isEmpty {
            Text(facts)
                .font(.callout)
                .foregroundStyle(Theme.textBody)
                .lineLimit(1)
        }
        if let overview = item?.Overview, !overview.isEmpty {
            Text(overview)
                .font(.callout)
                .foregroundStyle(Theme.textBody)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var live: some View {
        if let now = schedule.now {
            Text(now.title)
                .font(.title3.weight(.bold))
            if let start = now.programStart, let end = now.programEnd {
                Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(Theme.textBody)
            }
            if let overview = now.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(2)
            }
        } else {
            Text(player.title)
                .font(.title3.weight(.bold))
        }
        if !schedule.upcoming.isEmpty {
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
        }
    }

    /// What the Info tab can change: whether the next episode starts by
    /// itself, for this episode.
    @ViewBuilder
    private var actions: some View {
        if !player.isLive, player.item?.isEpisode == true {
            let on = !player.autoplayCancelled
            ChoiceCard(title: on ? "Autoplay: On" : "Autoplay: Off", isSelected: on, width: 340) {
                on ? player.cancelAutoplay() : player.resumeAutoplay()
            }
        }
    }

    private func facts(_ item: BaseItem?) -> String? {
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
        CardRow {
            ForEach(player.channelLineup, id: \.Id) { channel in
                ChoiceCard(
                    title: channel.title,
                    detail: channel.ChannelNumber.map { "Channel \($0)" },
                    isSelected: channel.Id == current,
                    width: 300
                ) {
                    player.playChannel(channel)
                } leading: {
                    RemoteImage(url: Artwork.channelLogo(channel, width: 240), contentMode: .fit)
                        .frame(width: 252, height: 90)
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

    var body: some View {
        let options = player.audioOptions
        let selected = player.selectedAudioOption
        if options.isEmpty {
            Text("No audio tracks yet")
                .foregroundStyle(Theme.textDim)
                .frame(minHeight: 150)
        } else {
            CardRow {
                ForEach(options) { option in
                    ChoiceCard(
                        title: option.label,
                        detail: option.needsNewStream ? "Reopens the stream" : nil,
                        isSelected: option.id == selected,
                        width: 460
                    ) {
                        player.selectAudio(option)
                    }
                }
            }
        }
    }
}

private struct SubtitlesTab: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let options = player.subtitleOptions
        let selected = player.selectedSubtitleOption
        CardRow {
            ChoiceCard(title: "Off", isSelected: selected == nil, width: 200) {
                player.selectSubtitles(nil)
            }
            ForEach(options) { option in
                ChoiceCard(
                    title: option.label,
                    detail: option.isForced ? "Forced" : nil,
                    isSelected: option.id == selected,
                    width: 460
                ) {
                    player.selectSubtitles(option)
                }
            }
        }
    }
}

// MARK: - Quality

/// Every rung at once, each card the same size, across the panel.
private struct QualityTab: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Quality.choices) { choice in
                ChoiceCard(
                    title: title(choice),
                    isSelected: player.currentBitrate == choice.maxBitrate,
                    width: nil,
                    height: 96
                ) {
                    guard player.currentBitrate != choice.maxBitrate else { return }
                    Task { await player.switchQuality(to: choice.maxBitrate) }
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// "4K" over "36 Mbps": seven cards to a row leaves no room for the two
    /// side by side.
    private func title(_ choice: QualityChoice) -> String {
        guard choice.maxBitrate != nil else { return "Original" }
        return choice.label.components(separatedBy: " · ").reversed().joined(separator: "\n")
    }
}

// MARK: - Speed

private struct SpeedTab: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 20) {
            ForEach(PlayerModel.speeds, id: \.self) { rate in
                ChoiceCard(
                    title: PlayerModel.speedName(rate),
                    isSelected: abs(player.speed - rate) < 0.001,
                    width: nil,
                    height: 64,
                    centered: true
                ) {
                    player.speed = rate
                }
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Sync

/// The sound against the picture, moved while the picture plays above: five
/// milliseconds a step, fifty for a room that is a long way out, either way,
/// on everything. mpv moves it the moment it is pressed. Which of the two
/// offsets it moves follows the display: the standard one, or the Match
/// Frame Rate one while the television has been switched for this video —
/// see `PlayerModel.usesMatchedDelay`.
///
/// Signed the way a receiver's lip-sync control is: minus holds the sound
/// back, plus brings it forward. That is the opposite of the stored value
/// (`Preferences.audioDelay`, positive for later, as mpv and the other
/// devices read it), so the tab shows and steps its negation.
private struct SyncTab: View {
    @Environment(PlayerModel.self) private var player

    /// One slim row: the picture being judged is everything under it.
    var body: some View {
        let current = player.audioDelayMilliseconds
        let shown = -current
        HStack(spacing: 20) {
            step(-50)
            step(-5)
            VStack(spacing: 2) {
                Text(shown == 0 ? "In step" : "\(shown > 0 ? "+" : "−")\(abs(shown)) ms")
                    .font(.title3.weight(.bold).monospacedDigit())
                Text(caption(current))
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 380)
            step(5)
            step(50)
            Spacer(minLength: 0)
            ChoiceCard(title: "Reset", width: 180, height: 64, centered: true) {
                player.setAudioDelay(milliseconds: 0)
            }
        }
        .padding(.vertical, 10)
    }

    /// Which way the sound is moved, and which of the two offsets this is:
    /// the one for the display as the Home screen has it, or the one for
    /// the mode the television was switched to for this video.
    private func caption(_ current: Int) -> String {
        let direction = current == 0 ? "Sound and picture together"
            : current < 0 ? "Sound earlier" : "Sound later"
        let mode: String
        if player.usesMatchedDelay, let rate = DisplayMatch.requested {
            mode = "Match Frame Rate · \(PlayerModel.frameRateName(rate.rounded(), unit: "Hz"))"
        } else if player.syncTest == .matched {
            // The clip asked for 24 Hz and wasn't given it: Match Frame
            // Rate is off on the Apple TV, so there is no matched mode to
            // set an offset for, and this test is setting the other one.
            mode = "Match Frame Rate is off · standard frame rate"
        } else {
            mode = "Standard frame rate"
        }
        return "\(direction) · \(mode)"
    }

    /// `delta` as the tab signs it: negative holds the sound back.
    private func step(_ delta: Int) -> some View {
        let current = player.audioDelayMilliseconds
        let target = current - delta
        return ChoiceCard(title: delta > 0 ? "+\(delta)" : "−\(-delta)", width: 130, height: 64, centered: true) {
            player.nudgeAudioDelay(by: -delta)
        }
        .disabled(abs(target) > PlayerModel.audioDelayReach)
    }
}

#endif
