//  The Now Playing card, and the Control Centre buttons.
//
//  The card — on the Home Screen, the Lock Screen and StandBy — is what is
//  playing or was last playing, with its cover and how far in it is. The
//  bar moves by itself: the snapshot carries the playhead and the moment it
//  was read, and the timeline draws a minute's worth of entries ahead.
//  Drawn from the snapshot the app writes into the app group
//  (Shared/WidgetTypes.swift); nothing here talks to a server.
//
//  The buttons are the three things most worth a press without opening
//  the app: continue watching, shuffle the music, resume the book.

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - The card

struct NowPlayingEntry: TimelineEntry {
    var date: Date
    var snapshot: NowPlayingSnapshot?
    var artwork: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
    private static let sample = NowPlayingSnapshot(
        itemId: "", title: "The Long Way Home", subtitle: "Chapter 12 · Ada Lane", isVideo: false,
        isPlaying: true, position: 3_800, duration: 30_000, hasArtwork: false
    )

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(Self.current(at: .now))
        }
    }

    /// While something is playing, an entry a minute for the next half hour
    /// so the bar keeps moving between the app's own updates; otherwise the
    /// one entry, until the app says something changed.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Date()
        let first = Self.current(at: now)
        guard let snapshot = first.snapshot, snapshot.isPlaying, snapshot.duration > 0 else {
            completion(Timeline(entries: [first], policy: .never))
            return
        }
        var entries = [first]
        let remaining = max(0, snapshot.duration - snapshot.position(at: now))
        let minutes = min(30, Int(remaining / 60) + 1)
        for minute in 1...max(1, minutes) {
            let at = now.addingTimeInterval(Double(minute) * 60)
            entries.append(NowPlayingEntry(date: at, snapshot: snapshot, artwork: first.artwork))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private static func current(at date: Date) -> NowPlayingEntry {
        let snapshot = NowPlayingSnapshot.read()
        var artwork: UIImage?
        if snapshot?.hasArtwork == true, let file = NowPlayingSnapshot.artworkFile,
           let data = try? Data(contentsOf: file) {
            artwork = UIImage(data: data)
        }
        return NowPlayingEntry(date: date, snapshot: snapshot, artwork: artwork)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingSnapshot.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingCard(entry: entry)
                .containerBackground(for: .widget) { ActivityPalette.background }
                .widgetURL(entry.snapshot?.link ?? URL(string: "aquarium://nowplaying"))
        }
        .configurationDisplayName("Now Playing")
        .description("What you're watching or listening to, ready to pick up.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct NowPlayingCard: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryRectangular: rectangular(snapshot)
                case .systemMedium: medium(snapshot)
                default: small(snapshot)
                }
            } else {
                empty
            }
        }
        .foregroundStyle(.white)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "play.circle")
                .font(.title2)
                .foregroundStyle(ActivityPalette.accentText)
            Text("Nothing playing")
                .font(.headline)
            Text("Open Aquarium to start something.")
                .font(.caption)
                .foregroundStyle(ActivityPalette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func small(_ snapshot: NowPlayingSnapshot) -> some View {
        ZStack(alignment: .bottomLeading) {
            artwork(cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            LinearGradient(
                colors: [.clear, ActivityPalette.background.opacity(0.9)],
                startPoint: .center, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: snapshot.isPlaying ? "play.fill" : "pause.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ActivityPalette.accentText)
                    bar(snapshot)
                }
            }
            .padding(12)
        }
        .ignoresSafeArea()
    }

    private func medium(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 14) {
            artwork(cornerRadius: 10)
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.isPlaying ? "Now Playing" : "Paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ActivityPalette.accentText)
                    .textCase(.uppercase)
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(2)
                if !snapshot.subtitle.isEmpty {
                    Text(snapshot.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(ActivityPalette.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                bar(snapshot)
                HStack {
                    Text(Self.clock(snapshot.position(at: entry.date)))
                    Spacer()
                    if snapshot.duration > 0 {
                        Text("−" + Self.clock(max(0, snapshot.duration - snapshot.position(at: entry.date))))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(ActivityPalette.dim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rectangular(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: snapshot.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption2.weight(.bold))
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            if !snapshot.subtitle.isEmpty {
                Text(snapshot.subtitle)
                    .font(.caption)
                    .lineLimit(1)
            }
            if let fraction = snapshot.fraction(at: entry.date) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func artwork(cornerRadius: CGFloat) -> some View {
        if let image = entry.artwork {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                ActivityPalette.accent.opacity(0.3)
                Image(systemName: entry.snapshot?.isVideo == true ? "film" : "music.note")
                    .font(.largeTitle)
                    .foregroundStyle(ActivityPalette.accentText)
            }
        }
    }

    private func bar(_ snapshot: NowPlayingSnapshot) -> some View {
        GeometryReader { proxy in
            let fraction = snapshot.fraction(at: entry.date) ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(ActivityPalette.accent).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Control Centre

@available(iOS 18.0, *)
struct ResumeWatchingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "scottai.FellyJin.control.resume") {
            ControlWidgetButton(action: ResumeWatchingControlIntent()) {
                Label("Continue Watching", systemImage: "play.tv.fill")
            }
        }
        .displayName("Continue Watching")
        .description("Picks up the film or episode you were in the middle of.")
    }
}

@available(iOS 18.0, *)
struct ShuffleMusicControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "scottai.FellyJin.control.shuffle") {
            ControlWidgetButton(action: ShuffleMusicControlIntent()) {
                Label("Shuffle Music", systemImage: "shuffle")
            }
        }
        .displayName("Shuffle Music")
        .description("Shuffles your whole music library.")
    }
}

@available(iOS 18.0, *)
struct ResumeAudiobookControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "scottai.FellyJin.control.audiobook") {
            ControlWidgetButton(action: ResumeAudiobookControlIntent()) {
                Label("Resume Audiobook", systemImage: "book.fill")
            }
        }
        .displayName("Resume Audiobook")
        .description("Picks up the audiobook you were listening to.")
    }
}
