//  The half of a half-folded player that is not the picture.
//
//  A foldable part-open on a table is a laptop: the picture stands up on the
//  top half and the bottom half is flat, under the hands. The chrome's half
//  over the picture keeps the scrims, the title row and the centre cluster
//  (`PlayerTransport.Part.aboveFold`), and this is what the flat half holds:
//  the prompts that come and go (Skip intro, Up Next), what is playing, the
//  chapters, what is queued and the rest of the season, scrolling; and along
//  the foot, where the hands are, the transport's bottom band — the timeline,
//  the times and the pills (`PlayerTransport.Part.belowFold`). The band has
//  no clock on it: a surface under the hands stays put.
//
//  The pills are the same pills, dropping the same cards (`PlayerMenus`),
//  placed here so they can rise over the panel rather than off the foot of
//  the screen. See `PlayerScreen.framed` for how the two halves are laid
//  out around the fold (`FoldSplit`).

#if os(iOS)
import SwiftUI

struct PlayerFoldPanel: View {
    @Environment(PlayerModel.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.horizontalSizeClass) private var sizeClass

    let chrome: PlayerChromeState
    let trickplay: TrickplayStore
    let schedule: ChannelSchedule
    let artwork: InfoArtwork

    @State private var episodes: [BaseItem] = []
    /// Bumped by Skip intro / Skip credits, for the haptic.
    @State private var skips = 0
    @State private var width: CGFloat = 0

    /// The phone's glyphs and insets unless the display is wide: the inside
    /// screen is, and a developer holding the pose on a plain phone isn't.
    private var compact: Bool { sizeClass == .compact }
    private var usesSheet: Bool { sizeClass == .compact }
    private var panelWidth: CGFloat {
        guard width > 0 else { return 640 }
        return min(max(width * 0.74, 560), 900)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    prompts
                    header
                    if !player.chapters.isEmpty {
                        chapters
                    }
                    if !player.isLive, player.upNextCount > 0 {
                        upNext
                    }
                    if !episodes.isEmpty {
                        season
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // The list meets the transport band in a fade rather than a cut:
            // at rest a heading used to sit sliced in half on the line.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                }
            }

            PlayerTransport(chrome: chrome, trickplay: trickplay, schedule: schedule, artwork: artwork,
                            compact: compact, usesSheet: usesSheet, panelWidth: panelWidth, part: .belowFold,
                            onInteract: {}, onDismiss: {})
                .padding(.bottom, 8)
        }
        .background(Color.black)
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width, initial: true) { _, now in width = now }
        })
        // The open card, above the pill that dropped it — placed over the
        // whole half, so it has the panel's height to rise into.
        .overlayPreferenceValue(ChromeMenuAnchors.self) { anchors in
            ChromeMenuLayer(chrome: chrome, anchors: anchors, compact: compact, onInteract: {},
                            openPanel: { tab in
                                chrome.panelAnchor = .more
                                chrome.panel = tab
                            })
        }
        .playerChromeScheme()
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .medium), trigger: skips)
        .task(id: seasonKey) { await loadSeason() }
    }

    // MARK: - Prompts

    /// Skip intro and Up Next, moved down here from over the picture.
    @ViewBuilder
    private var prompts: some View {
        if player.shouldShowUpNext, let next = player.upNextTitle, player.errorMessage == nil {
            PlayerUpNextCard(title: next, next: player.upNextItem, compact: compact)
        } else if player.activeSegment != nil, player.errorMessage == nil {
            PlayerSkipSegmentButton(isOutro: player.activeSegment?.isOutro == true) {
                skips += 1
                player.skipSegment()
            }
        }
    }

    // MARK: - What is playing

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if let url = InfoArtwork.url(for: player) {
                poster(url)
                    .frame(width: player.isLive ? 84 : 52, height: player.isLive ? 54 : 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(mainTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let kicker, !kicker.isEmpty {
                    Text(kicker)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                if let chapter = player.chapterName(at: player.position) {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(Theme.link)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func poster(_ url: URL) -> some View {
        if artwork.url == url, let image = artwork.image {
            Color.clear.overlay {
                Image(uiImage: image).resizable().aspectRatio(contentMode: player.isLive ? .fit : .fill)
            }
            .clipped()
        } else {
            RemoteImage(url: url)
        }
    }

    private var mainTitle: String {
        if player.isLive { return schedule.now?.title ?? player.title }
        return player.item?.title ?? player.title
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

    // MARK: - Chapters

    /// A row of pills, the one playing lit; a tap jumps to it.
    private var chapters: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading(text: "Chapters")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(player.chapters) { chapter in
                        let current = chapter.id == currentChapter?.id
                        Button {
                            player.seek(to: chapter.start)
                        } label: {
                            PlayerPill(isOn: current) {
                                Text(chapter.title)
                                Text(PlayerTime.format(chapter.start))
                                    .font(.caption.monospacedDigit())
                                    .opacity(0.7)
                            }
                        }
                        .buttonStyle(PlayerPillStyle())
                        .accessibilityLabel("\(chapter.title), \(PlayerTime.spoken(chapter.start))")
                        .accessibilityAddTraits(current ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    /// The last chapter that has started.
    private var currentChapter: Chapter? {
        player.chapters.last { $0.start <= player.position }
    }

    // MARK: - Up Next

    /// What is queued by hand, else the next few episodes the series has
    /// left, as the Up Next card lists them. A row plays its title now.
    private var upNext: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading(text: "Up Next")
            if !player.queue.isEmpty {
                ForEach(player.queue, id: \.Id) { entry in
                    PanelRow(title: PlayerModel.displayTitle(entry)) {
                        Task { await player.playQueued(entry.Id) }
                    } leading: {
                        still(entry)
                    }
                }
            } else {
                ForEach(player.upNextList, id: \.Id) { entry in
                    PanelRow(title: PlayerModel.upNextRowTitle(entry),
                             detail: entry.title == PlayerModel.upNextRowTitle(entry) ? nil : entry.SeriesName) {
                        Task { await player.playUpcoming(entry) }
                    } leading: {
                        still(entry)
                    }
                }
                ForEach(player.upNextLocal, id: \.itemId) { record in
                    PanelRow(title: record.title, detail: "On this device") {
                        player.playLocal(record, keepShuffle: true)
                    }
                }
            }
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

    // MARK: - The season

    /// The season the episode belongs to, or nothing: a film has no list.
    private var seasonKey: String? {
        guard let item = player.infoItem, item.isEpisode, let series = item.SeriesId else { return nil }
        return series + "/" + (item.SeasonId ?? "")
    }

    private func loadSeason() async {
        guard let item = player.infoItem, item.isEpisode, let series = item.SeriesId else {
            episodes = []
            return
        }
        let list = (try? await client.episodes(seriesId: series, seasonId: item.SeasonId)) ?? []
        guard !Task.isCancelled else { return }
        episodes = list
    }

    private var season: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading(text: player.infoItem?.SeasonName ?? "Episodes")
            ForEach(episodes) { episode in
                // Both actions play: there is no page to open from inside the
                // player, and the row is the way to the next episode.
                EpisodeRow(episode: episode, isHighlighted: episode.Id == player.infoItem?.Id) {
                    Task { await player.play(item: episode) }
                } onOpen: {
                    Task { await player.play(item: episode) }
                }
            }
        }
    }
}
#endif
