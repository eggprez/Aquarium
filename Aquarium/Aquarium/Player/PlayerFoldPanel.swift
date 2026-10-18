//  The half of a half-folded player that is not the picture.
//
//  A foldable part-open on a table is a laptop: the picture stands up on the
//  top half with the chrome over it — the transport, the pills and their
//  cards — and the bottom half is flat, under the hands. This is what the
//  flat half holds: the Info page the Info pill would open as a sheet, the
//  chapters, what is queued, and the rest of the season.
//
//  See `PlayerScreen.framed` for how the two halves are laid out around the
//  fold (`FoldSplit`).

#if os(iOS)
import SwiftUI

struct PlayerFoldPanel: View {
    @Environment(PlayerModel.self) private var player
    @Environment(JellyfinClient.self) private var client
    let schedule: ChannelSchedule
    let artwork: InfoArtwork

    @State private var episodes: [BaseItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The same page the Info pill opens, laid flat.
                PlayerPanel(tab: .constant(.info), schedule: schedule, artwork: artwork)
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                if !player.chapters.isEmpty {
                    chapters
                }
                if !player.queue.isEmpty {
                    queue
                }
                if !episodes.isEmpty {
                    season
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color.black)
        .playerChromeScheme()
        .task(id: seasonKey) { await loadSeason() }
    }

    // MARK: - Chapters

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters")
                .font(.headline)
                .foregroundStyle(.white)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(player.chapters) { chapter in
                        let current = chapter.id == currentChapter?.id
                        Button {
                            player.seek(to: chapter.start)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(Format.clock(chapter.start))
                                    .font(.caption)
                                    .opacity(0.7)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(current ? Theme.accentStrong : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The last chapter that has started.
    private var currentChapter: Chapter? {
        player.chapters.last { $0.start <= player.position }
    }

    // MARK: - Queue

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.white)
            ForEach(player.queue, id: \.Id) { item in
                Button {
                    Task { await player.playQueued(item.Id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .foregroundStyle(.white.opacity(0.7))
                        Text(PlayerModel.displayTitle(item))
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
        VStack(alignment: .leading, spacing: 10) {
            Text(player.infoItem?.SeasonName ?? "Episodes")
                .font(.headline)
                .foregroundStyle(.white)
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
