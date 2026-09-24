//  Lyrics, in the Now Playing screen.
//
//  Where the server has an LRC file or an embedded sync, the line being sung
//  is lit and the page keeps it in view; where it has plain text, the words
//  simply scroll. Tapping a timed line goes there.

import SwiftUI

#if os(iOS)

/// Fetches and remembers the words for whatever is playing, so switching the
/// panel on and off doesn't ask twice.
@MainActor
@Observable
final class LyricsStore {
    static let shared = LyricsStore()

    private(set) var itemId: String?
    private(set) var lyrics: LyricsResponse?
    private(set) var isLoading = false
    private var cache: [String: LyricsResponse?] = [:]

    private init() {}

    func load(for item: BaseItem) async {
        if itemId == item.Id, lyrics != nil || !isLoading { return }
        itemId = item.Id
        if let known = cache[item.Id] {
            lyrics = known
            isLoading = false
            return
        }
        lyrics = nil
        isLoading = true
        // Only the load still wanted clears the spinner; a superseded one
        // finishing late must not hide the current one's.
        defer { if itemId == item.Id { isLoading = false } }
        // A downloaded song's words are kept beside it, so they are there
        // with no server — and are read from there first, which is quicker
        // than asking even when there is one.
        var found = OfflineLyrics.load(item.Id)
        if found == nil, !JellyfinClient.shared.isOffline {
            found = (try? await JellyfinClient.shared.lyrics(itemId: item.Id)) ?? nil
            if let found { OfflineLyrics.keep(found, for: item.Id) }
        }
        guard itemId == item.Id else { return }
        cache[item.Id] = found
        lyrics = found
    }
}

struct LyricsView: View {
    @Environment(MusicPlayer.self) private var music
    @State private var store = LyricsStore.shared
    /// The line lit at the moment; scrolling is driven by it changing.
    @State private var currentLine: Int64?
    /// A finger on the page holds the auto-scroll off for a moment, so a
    /// reader who scrolled up to see a verse isn't yanked back on the next
    /// beat.
    @State private var userScrolledAt: Date?

    var body: some View {
        Group {
            if let song = music.current {
                content(for: song)
                    .task(id: song.Id) { await store.load(for: song) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for song: BaseItem) -> some View {
        if store.isLoading, store.lyrics == nil {
            ProgressView().tint(.white)
        } else if let lyrics = store.lyrics, !lyrics.lines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(lyrics.lines) { line in
                            let lit = lyrics.isSynced && line.id == currentLine
                            Text(line.Text?.isEmpty == false ? line.Text! : "…")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(lit ? .white : .white.opacity(lyrics.isSynced ? 0.4 : 0.85))
                                .scaleEffect(lit ? 1.0 : 0.96, anchor: .leading)
                                .animation(.easeOut(duration: 0.25), value: lit)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .id(line.id)
                                .onTapGesture {
                                    if let at = line.startSeconds {
                                        music.seek(to: at)
                                        if !music.isPlaying { music.resume() }
                                    }
                                }
                        }
                        Color.clear.frame(height: 200)
                    }
                    .padding(.top, 8)
                }
                .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
                .onChange(of: music.position) { _, position in
                    guard lyrics.isSynced else { return }
                    let line = lyrics.lines.last { ($0.startSeconds ?? 0) <= position + 0.15 }?.id
                    guard line != currentLine else { return }
                    currentLine = line
                    if let line, userScrolledAt.map({ Date().timeIntervalSince($0) > 4 }) ?? true {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.3))
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.quote").font(.title).foregroundStyle(.white.opacity(0.4))
                Text("No lyrics for this song")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Text("Jellyfin reads .lrc files beside the track and lyrics embedded in its tags.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 24)
        }
    }
}

#endif
