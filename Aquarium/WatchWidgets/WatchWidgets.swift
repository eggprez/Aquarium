//  The Smart Stack card: what is playing, or the book most recently left,
//  with how far in it is. Tapping it opens the app and resumes.
//
//  Drawn from the snapshot the app writes into the app group
//  (Shared/WatchWidgetSnapshot.swift); nothing here talks to a server.

import SwiftUI
import WidgetKit

@main
struct AquariumWatchWidgets: WidgetBundle {
    var body: some Widget {
        ListeningWidget()
    }
}

struct ListeningEntry: TimelineEntry {
    var date: Date
    var snapshot: ListeningSnapshot?
}

struct ListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListeningEntry {
        ListeningEntry(date: .now, snapshot: ListeningSnapshot(
            itemId: "", title: "The Long Way Home", subtitle: "Chapter 12", isAudiobook: true,
            isPlaying: false, position: 3_800, duration: 30_000
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (ListeningEntry) -> Void) {
        completion(ListeningEntry(date: .now, snapshot: context.isPreview ? placeholder(in: context).snapshot : ListeningSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningEntry>) -> Void) {
        completion(Timeline(entries: [ListeningEntry(date: .now, snapshot: ListeningSnapshot.read())], policy: .never))
    }
}

struct ListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "scottai.FellyJin.watch.listening", provider: ListeningProvider()) { entry in
            ListeningWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Aquarium")
        .description("What you're listening to, ready to pick up.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct ListeningWidgetView: View {
    let entry: ListeningEntry
    @Environment(\.widgetFamily) private var family

    private static let accent = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            default: inline
            }
        }
        .widgetURL(URL(string: entry.snapshot.map { "aquarium://play/\($0.itemId)" } ?? "aquarium://resume"))
    }

    private var symbol: String {
        guard let s = entry.snapshot else { return "waveform" }
        if s.isPlaying { return "waveform" }
        return s.isAudiobook ? "book.fill" : "music.note"
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Self.accent.gradient)
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                if let s = entry.snapshot {
                    Text(s.title).font(.headline).lineLimit(1)
                    Text(s.isPlaying ? "Playing · \(s.subtitle)" : s.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let f = s.fraction {
                        ProgressView(value: f).tint(Self.accent).scaleEffect(x: 1, y: 0.7, anchor: .center)
                    }
                } else {
                    Text("Aquarium").font(.headline)
                    Text("Nothing playing").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var circular: some View {
        ZStack {
            if let f = entry.snapshot?.fraction {
                Gauge(value: f) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(Self.accent)
            } else {
                AccessoryWidgetBackground()
            }
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
        }
    }

    private var corner: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .widgetLabel {
                if let s = entry.snapshot, let f = s.fraction {
                    Gauge(value: f) { Text(s.title) }.tint(Self.accent)
                } else {
                    Text(entry.snapshot?.title ?? "Aquarium")
                }
            }
    }

    private var inline: some View {
        if let s = entry.snapshot {
            Label(s.title, systemImage: symbol)
        } else {
            Label("Aquarium", systemImage: "waveform")
        }
    }
}
