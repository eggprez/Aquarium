//  The front screen of a foldable stood up on its edges like a tent.
//
//  Set down that way the phone is a small television on a table, too far off
//  to browse on: what it is for is being left to play. So while nothing is
//  playing this is the whole app — the things worth one tap, as big cards
//  across a landscape screen, and the music that is on — and the moment
//  something starts, the player covers it. Browsing is a button away for the
//  person who did want the app; see `RootView.tentBrowsing`.
//
//  The pose itself is worked out in `DevicePose`; this is only what the tent
//  shows.

#if os(iOS)
import SwiftUI

struct TentIdleView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player
    @Environment(MusicPlayer.self) private var music

    /// Continue Watching, then Next Up, as Home has them. Seeded from Home's
    /// last page so the shelf is there on the first frame, then refreshed.
    @State private var items: [BaseItem] = TentIdleView.seed()
    @State private var loaded = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    topRow
                    if music.isActive, let song = music.current {
                        nowPlaying(song)
                    }
                    if items.isEmpty {
                        empty
                    } else {
                        MediaShelf(title: "Continue Watching", items: items, wide: true, menuOpensDetails: true) { item in
                            Task { await player.play(item: item) }
                        }
                    }
                }
                .padding(.vertical, 22)
            }
            .scrollIndicators(.hidden)
        }
        .task { await load() }
        // Opened from the music card: Now Playing, over this.
        .nowPlayingSheet()
    }

    // MARK: - Pieces

    private var topRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Aquarium")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                app.tentBrowsing = true
            } label: {
                Label("Browse", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private func nowPlaying(_ song: BaseItem) -> some View {
        HStack(spacing: 18) {
            MusicArtwork(item: song, width: 400, radius: 10, placeholderSymbol: song.isAudiobook ? "book" : "music.note")
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(song.artistLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 22) {
                Button { music.togglePlayPause() } label: {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                }
                .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
                Button { music.skipNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 26, weight: .semibold))
                }
                .accessibilityLabel("Next")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
        }
        .padding(16)
        .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { NowPlayingPresentation.shared.isPresented = true }
        .padding(.horizontal, Metrics.gutter)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: loaded ? "play.rectangle" : "hourglass")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textDim)
            Text(loaded ? "Nothing to continue" : "Loading…")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
            if loaded {
                Button("Browse the library") { app.tentBrowsing = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStrong)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    // MARK: - Data

    private static func seed() -> [BaseItem] {
        guard let memo = HomeMemo.current else { return [] }
        return Self.merge(resume: memo.resume, nextUp: memo.nextUp)
    }

    /// Continue Watching first, then whatever Next Up adds.
    private static func merge(resume: [BaseItem], nextUp: [BaseItem]) -> [BaseItem] {
        var seen = Set(resume.map(\.Id))
        var out = resume
        for item in nextUp where !seen.contains(item.Id) {
            seen.insert(item.Id)
            out.append(item)
        }
        return out
    }

    private func load() async {
        guard client.isSignedIn else { loaded = true; return }
        async let resume = client.resume()
        async let nextUp = client.nextUp()
        let fresh = Self.merge(resume: (try? await resume) ?? [], nextUp: (try? await nextUp) ?? [])
        guard !Task.isCancelled else { return }
        if !fresh.isEmpty || items.isEmpty { items = fresh }
        loaded = true
    }
}
#endif
