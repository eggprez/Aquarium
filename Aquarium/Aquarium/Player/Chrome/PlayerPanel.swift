//  The panel: a row of tabs, and under it the choices for the tab that is
//  open. Info · Channels · Audio · Subtitles · Quality · Speed · Sync ·
//  Picture. A sheet with medium and large detents on a phone, a popover off
//  the pill that opened it on an iPad or a Mac; the Apple TV's swipe-down
//  panel (`TV/TVPlayerPanel.swift`) shows its own tabs in focus-driven cards
//  until phase 5 brings it here.
//
//  A row the engine cannot honour says why rather than vanishing: the quality
//  rungs under a download, the audio offset on a transcode, the picture
//  sliders on AVPlayer — the last two with a button that hands the title to
//  the mpv engine at the same position. The one thing a stream has nothing
//  of (a film has no channels) is left out of the tabs.

#if !os(tvOS)

import SwiftUI

struct PlayerPanel: View {
    @Environment(PlayerModel.self) private var player
    @Binding var tab: PlayerTab
    let schedule: ChannelSchedule
    let artwork: InfoArtwork

    var body: some View {
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
        .foregroundStyle(Theme.text)
        // A tab the stream has nothing to show in — Channels after a channel
        // became a film — falls back to Info.
        .onChange(of: player.panelTabs, initial: true) { _, tabs in
            if !tabs.contains(tab) { tab = .info }
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
                            Label(item.title, systemImage: item.symbol)
                                .labelStyle(.titleOnly)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(item == tab ? .white : Theme.textDim)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(item == tab ? Theme.accent : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
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

// MARK: - Rows

/// One choice in a tab: a title, an optional line under it, a tick when it is
/// the current one. A row that cannot be chosen keeps its place and says why.
struct PanelRow: View {
    let title: String
    var detail: String? = nil
    var isSelected = false
    var disabledReason: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
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
                        .foregroundStyle(Theme.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .opacity(disabledReason != nil ? 0.75 : 1)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(disabledReason ?? "")
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

// MARK: - Info

private struct InfoTab: View {
    @Environment(PlayerModel.self) private var player
    let schedule: ChannelSchedule
    let artwork: InfoArtwork

    var body: some View {
        let rows = PlayerStreamRows(player: player)
        // Read here so the stream figures, which nothing writes, redraw on the
        // player's clock.
        let _ = player.position
        VStack(alignment: .leading, spacing: 10) {
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
        Text(item?.title ?? player.title)
            .font(.headline)
        if let facts = Self.facts(item), !facts.isEmpty {
            Text(facts)
                .font(.subheadline)
                .foregroundStyle(Theme.textBody)
        }
        if let overview = item?.Overview, !overview.isEmpty {
            Text(overview)
                .font(.subheadline)
                .foregroundStyle(Theme.textBody)
                .lineLimit(4)
        }
    }

    @ViewBuilder
    private var live: some View {
        if let now = schedule.now {
            Text(now.title)
                .font(.headline)
            if let start = now.programStart, let end = now.programEnd {
                Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textBody)
            }
            if let overview = now.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(3)
            }
        } else {
            Text(player.title)
                .font(.headline)
        }
        if !schedule.upcoming.isEmpty {
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

    @ViewBuilder
    private var sleepTimer: some View {
        if let left = player.sleepMinutesRemaining {
            PanelRow(title: "Stopping in \(left) min", detail: "Tap to cancel the sleep timer", isSelected: true) {
                player.cancelSleepTimer()
            }
        } else {
            HStack(spacing: 8) {
                ForEach([15, 30, 60, 90], id: \.self) { minutes in
                    Button {
                        player.setSleepTimer(minutes: minutes)
                    } label: {
                        Text("\(minutes) min")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
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

    var body: some View {
        let current = player.currentChannel?.Id
        VStack(spacing: 6) {
            ForEach(player.channelLineup, id: \.Id) { channel in
                Button {
                    player.playChannel(channel)
                } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: Artwork.channelLogo(channel, width: 160), contentMode: .fit)
                            .frame(width: 56, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.title)
                                .font(.body)
                                .foregroundStyle(Theme.text)
                            if let number = channel.ChannelNumber {
                                Text("Channel \(number)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                        Spacer(minLength: 0)
                        if channel.Id == current {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.link)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(channel.Id == current ? Theme.accentSoft : Color.white.opacity(0.06))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(channel.Id == current ? [.isSelected] : [])
            }
        }
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
                ForEach(options) { option in
                    PanelRow(title: option.label,
                             detail: option.needsNewStream ? "Reopens the stream with this track" : nil,
                             isSelected: option.id == selected) {
                        player.selectAudio(option)
                    }
                }
            }

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
            PanelRow(title: "Off", isSelected: selected == nil) {
                player.selectSubtitles(nil)
            }
            if options.isEmpty {
                PanelNote(text: "This stream has no subtitle tracks.")
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
        }
    }
}

// MARK: - Quality

private struct QualityTab: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = player.qualityUnavailableReason {
                PanelNote(text: reason)
            }
            ForEach(Quality.choices) { choice in
                let current = player.currentBitrate == choice.maxBitrate
                PanelRow(title: choice.label,
                         detail: current && player.isTranscoding ? "Playing now · transcoding" : current ? "Playing now" : nil,
                         isSelected: current,
                         disabledReason: player.qualityUnavailableReason == nil ? nil : "Not for this stream") {
                    guard !current else { return }
                    Task { await player.switchQuality(to: choice.maxBitrate) }
                }
            }
            if prefs.adaptiveQuality, player.offersQuality {
                PanelNote(text: "The stream steps down on its own when the connection struggles, and back up once it is steady. Settings → Video turns that off.")
            }
        }
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
            ForEach(PlayerModel.speeds, id: \.self) { rate in
                PanelRow(title: PlayerModel.speedName(rate),
                         isSelected: abs(player.speed - rate) < 0.001,
                         disabledReason: player.isLive ? "Not on a live channel" : nil) {
                    player.speed = rate
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
/// the stream, so a run of taps is settled first and applied once.
private struct SyncTab: View {
    @Environment(PlayerModel.self) private var player

    /// The number on screen, ahead of the model while taps settle.
    @State private var pending: Int?
    @State private var commit: Task<Void, Never>?

    private static let settle: Duration = .milliseconds(350)

    private var reach: Int {
        player.engine?.capabilities.contains(.audioDelayOnAnyStream) == true ? PlayerModel.audioDelayReach : 500
    }

    var body: some View {
        let current = pending ?? player.audioDelayMilliseconds
        let shown = -current
        let reason = player.audioDelayUnavailableReason
        VStack(alignment: .leading, spacing: 10) {
            if let reason {
                PanelNote(text: reason)
            }
            HStack(spacing: 8) {
                step(-50, current: current, reason: reason)
                step(-5, current: current, reason: reason)
                VStack(spacing: 2) {
                    Text(shown == 0 ? "In step" : "\(shown > 0 ? "+" : "−")\(abs(shown)) ms")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(shown)))
                    Text(current == 0 ? "Picture and sound together"
                         : current < 0 ? "Sound earlier" : "Sound later")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                step(5, current: current, reason: reason)
                step(50, current: current, reason: reason)
            }
            .animation(.easeOut(duration: 0.15), value: shown)

            PanelRow(title: "Reset", detail: "Put the sound back in step with the picture",
                     disabledReason: reason == nil || current == 0 ? nil : "Not on this stream") {
                set(0)
            }

            if reason != nil, player.canDelayAudioBySwitching {
                EngineSwitchRow(reason: "audio delay")
            }

            if player.canResync || player.canReencodeForSync {
                PanelHeading(text: "Repairs")
            }
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
            if !player.isLive {
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

    /// `delta` as the tab signs it: negative holds the sound back.
    private func step(_ delta: Int, current: Int, reason: String?) -> some View {
        let target = current - delta
        return Button {
            set(target)
        } label: {
            Text(delta > 0 ? "+\(delta)" : "−\(-delta)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(minWidth: 44)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(reason != nil || abs(target) > reach)
        .opacity(reason != nil || abs(target) > reach ? 0.4 : 1)
        .accessibilityLabel(delta > 0 ? "Sound \(delta) milliseconds earlier" : "Sound \(-delta) milliseconds later")
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
/// and Reset puts the file's own picture back.
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

            PanelHeading(text: "Picture")
            slider("Brightness", value: $prefs.pictureBrightness, enabled: live)
            slider("Contrast", value: $prefs.pictureContrast, enabled: live)
            slider("Saturation", value: $prefs.pictureSaturation, enabled: live)
            slider("Gamma", value: $prefs.pictureGamma, enabled: live)

            PanelHeading(text: "Zoom")
            HStack(spacing: 12) {
                Text("Zoom")
                    .font(.subheadline)
                    .frame(width: 88, alignment: .leading)
                Slider(value: $prefs.pictureZoom, in: 1...2, step: 0.05)
                    .tint(Theme.accent)
                    .disabled(!live)
                    .accessibilityLabel("Zoom")
                    .accessibilityValue("\(Int((prefs.pictureZoom * 100).rounded()))%")
                Text("\(prefs.pictureZoom.formatted(.number.precision(.fractionLength(2))))×")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 52, alignment: .trailing)
            }
            .opacity(live ? 1 : 0.5)
            .onChange(of: prefs.pictureZoom) { _, _ in player.applyFraming() }

            PanelHeading(text: "Aspect ratio")
            ForEach(Preferences.aspectChoices, id: \.ratio) { choice in
                PanelRow(title: choice.label,
                         isSelected: abs(prefs.aspectOverride - choice.ratio) < 0.001,
                         disabledReason: live ? nil : "Needs the mpv engine") {
                    prefs.aspectOverride = choice.ratio
                    player.applyFraming()
                }
            }

            PanelRow(title: "Reset", detail: "The file's own picture: no adjustment, no zoom, its own shape",
                     disabledReason: prefs.pictureIsAdjusted ? nil : "Nothing is adjusted") {
                prefs.resetPicture()
                player.applyPicture()
                player.applyFraming()
            }

            if live {
                PanelNote(text: "Saved for everything you play on this device.")
            }
        }
    }

    /// One of the four adjustments: -100…100, 0 being the file's own.
    private func slider(_ name: String, value: Binding<Double>, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.subheadline)
                .frame(width: 88, alignment: .leading)
            Slider(value: value, in: -100...100, step: 1)
                .tint(Theme.accent)
                .disabled(!enabled)
                .accessibilityLabel(name)
                .accessibilityValue("\(Int(value.wrappedValue))")
            Text("\(Int(value.wrappedValue))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textDim)
                .frame(width: 52, alignment: .trailing)
        }
        .opacity(enabled ? 1 : 0.5)
        .onChange(of: value.wrappedValue) { _, _ in player.applyPicture() }
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

#endif
