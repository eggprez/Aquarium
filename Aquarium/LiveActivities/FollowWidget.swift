//  The Follow tile: one film or show, its poster, and where you are in it.
//
//  Configurable — press and hold, Edit Widget — from the candidates the app
//  writes into the app group (Shared/FollowTypes.swift). With nothing
//  chosen it shows whatever is next: the first thing part-watched, else the
//  first episode up next. A tap opens the title's page, or the episode's.
//  Nothing here talks to a server; the poster is a file the app put beside
//  the snapshot.

import AppIntents
import SwiftUI
import WidgetKit

struct FollowEntry: TimelineEntry {
    var date: Date
    var entry: FollowSnapshot.Entry?
    var artwork: UIImage?
    /// Nothing written yet, as opposed to a title that has gone.
    var isEmpty: Bool
}

struct FollowProvider: AppIntentTimelineProvider {
    private static let sample = FollowSnapshot.Entry(
        id: "", title: "The Long Way Home", subtitle: "S02E03 · The Harbour", fraction: 0.35,
        linkId: "", isSeries: true, hasArtwork: false
    )

    func placeholder(in context: Context) -> FollowEntry {
        FollowEntry(date: .now, entry: Self.sample, isEmpty: false)
    }

    func snapshot(for configuration: FollowTitleIntent, in context: Context) async -> FollowEntry {
        context.isPreview ? placeholder(in: context) : Self.current(configuration)
    }

    func timeline(for configuration: FollowTitleIntent, in context: Context) async -> Timeline<FollowEntry> {
        Timeline(entries: [Self.current(configuration)], policy: .never)
    }

    private static func current(_ configuration: FollowTitleIntent) -> FollowEntry {
        let snapshot = FollowSnapshot.read()
        let entries = snapshot?.entries ?? []
        let chosen: FollowSnapshot.Entry? = {
            if let id = configuration.title?.id { return entries.first { $0.id == id } }
            return entries.first
        }()
        var artwork: UIImage?
        if let chosen, chosen.hasArtwork, let file = FollowSnapshot.artworkFile(for: chosen.id),
           let data = try? Data(contentsOf: file) {
            artwork = UIImage(data: data)
        }
        return FollowEntry(date: .now, entry: chosen, artwork: artwork, isEmpty: snapshot == nil)
    }
}

struct FollowWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: FollowSnapshot.widgetKind, intent: FollowTitleIntent.self, provider: FollowProvider()) { entry in
            FollowCard(entry: entry)
                .containerBackground(for: .widget) { ActivityPalette.background }
                .widgetURL(entry.entry.flatMap { URL(string: "aquarium://item/\($0.linkId)") })
        }
        .configurationDisplayName("Follow a Title")
        .description("A film or show you're in the middle of, and where you are in it.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct FollowCard: View {
    let entry: FollowEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let item = entry.entry {
                switch family {
                case .accessoryRectangular: rectangular(item)
                case .systemMedium: medium(item)
                default: small(item)
                }
            } else {
                empty
            }
        }
        .foregroundStyle(.white)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "tv")
                .font(.title2)
                .foregroundStyle(ActivityPalette.accentText)
            Text(entry.isEmpty ? "Nothing to follow yet" : "That title has gone")
                .font(.headline)
            Text(entry.isEmpty ? "Open Aquarium to load your library." : "Edit the widget to pick another.")
                .font(.caption)
                .foregroundStyle(ActivityPalette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func small(_ item: FollowSnapshot.Entry) -> some View {
        ZStack(alignment: .bottomLeading) {
            poster(cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            LinearGradient(
                colors: [.clear, ActivityPalette.background.opacity(0.92)],
                startPoint: .center, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(ActivityPalette.dim)
                    .lineLimit(1)
                if let fraction = item.fraction { bar(fraction) }
            }
            .padding(12)
        }
        .ignoresSafeArea()
    }

    private func medium(_ item: FollowSnapshot.Entry) -> some View {
        HStack(spacing: 14) {
            poster(cornerRadius: 10)
                .frame(width: 76, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.isSeries ? "Up Next" : "Continue Watching")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ActivityPalette.accentText)
                    .textCase(.uppercase)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ActivityPalette.dim)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let fraction = item.fraction { bar(fraction) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rectangular(_ item: FollowSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.caption)
                .lineLimit(1)
            if let fraction = item.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func poster(cornerRadius: CGFloat) -> some View {
        if let image = entry.artwork {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                ActivityPalette.accent.opacity(0.3)
                Image(systemName: entry.entry?.isSeries == true ? "tv" : "film")
                    .font(.largeTitle)
                    .foregroundStyle(ActivityPalette.accentText)
            }
        }
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(ActivityPalette.accent).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}
