//  The half of a half-folded player that is not the picture.
//
//  A foldable part-open on a table is a laptop: the picture stands up on the
//  top half and the bottom half is flat, under the hands. AVKit keeps its own
//  controls on the picture — the scrubber, Picture in Picture, AirPlay, the
//  speed menu — and this is what the flat half holds: the prompts that come
//  and go (Skip intro, Up Next), what is playing, this app's own Quality and
//  Extras pills moved down out of AVKit's bar, the chapters, what is queued,
//  and the rest of the season.
//
//  See `PlayerScreen.framed` for how the two halves are laid out around the
//  fold (`FoldSplit`), and `TransportBarExtras.install` for how the pills
//  get here.

#if os(iOS)
import SwiftUI
import UIKit

struct PlayerFoldPanel: View {
    @Environment(PlayerModel.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Binding var skips: Int

    @State private var episodes: [BaseItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PlayerPrompts(skips: $skips, width: 360)
                header
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
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task(id: seasonKey) { await loadSeason() }
    }

    // MARK: - What is playing

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let line = episodeLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // The pills, pinned here by `TransportBarExtras` while this is
            // on screen.
            ExtrasHost()
                .frame(width: 170, height: 40)
        }
    }

    private var episodeLine: String? {
        guard let item = player.infoItem, item.isEpisode else { return nil }
        var parts: [String] = []
        if let series = item.SeriesName { parts.append(series) }
        if let season = item.ParentIndexNumber, let episode = item.IndexNumber {
            parts.append("S\(season) · E\(episode)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
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
            ForEach(player.queue) { item in
                Button {
                    Task { await player.playQueued(item.Id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .foregroundStyle(.white.opacity(0.7))
                        Text(item.Name ?? "")
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

/// A plain view for `TransportBarExtras` to pin its row into. Hands itself to
/// the player model on the way in and takes itself back on the way out; the
/// generation bump is what makes the player screen notice either.
private struct ExtrasHost: UIViewRepresentable {
    @Environment(PlayerModel.self) private var player

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let player = self.player
        player.extrasHost = { [weak view] in view }
        // Not during this update: a change published mid-update is the
        // warning SwiftUI prints, and the screen redraws a moment later anyway.
        Task { @MainActor in player.extrasHostGeneration += 1 }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        let player = PlayerModel.shared
        guard player.extrasHost?() === uiView else { return }
        player.extrasHost = nil
        Task { @MainActor in player.extrasHostGeneration += 1 }
    }
}
#endif
