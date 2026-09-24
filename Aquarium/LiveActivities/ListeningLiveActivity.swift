//  What is being listened to: a sleep timer's countdown, an audiobook's place
//  in its chapter, or both at once.
//
//  Everything that moves here moves by itself. The countdown is a
//  `Text(timerInterval:)` and the chapter bar a `ProgressView(timerInterval:)`,
//  both of which the system animates from two dates without asking anyone —
//  the app says something only when those dates change: a seek, a pause, a
//  new chapter, a different speed.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct ListeningLiveActivity: Widget {
    typealias State = ListeningActivityAttributes.ContentState

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningActivityAttributes.self) { context in
            ActivityLayout {
                ListeningSmall(state: context.state, isStale: context.isStale)
            } full: {
                ListeningLockScreen(state: context.state, isStale: context.isStale)
            }
            .widgetURL(Self.link(context.state))
        } dynamicIsland: { context in
            let state = context.state
            // Stale means the app stopped speaking while something was
            // playing; its dates have run out, and would say 0:00.
            let clocks = !context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.title2)
                        .foregroundStyle(ActivityPalette.accentText)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if clocks, let deadline = state.sleepDeadline {
                        SleepCountdown(deadline: deadline)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: 76, alignment: .trailing)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let subtitle = state.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(ActivityPalette.dim).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        if let chapter = state.chapter { ChapterProgress(chapter: chapter, clocks: clocks) }
                        if clocks, state.sleepDeadline != nil { SleepButtons() }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(ActivityPalette.accentText)
            } compactTrailing: {
                if clocks, let deadline = state.sleepDeadline {
                    SleepCountdown(deadline: deadline)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: 48)
                } else if let chapter = state.chapter {
                    ChapterRing(chapter: chapter, clocks: clocks)
                }
            } minimal: {
                if !clocks || state.sleepDeadline == nil, let chapter = state.chapter {
                    ChapterRing(chapter: chapter, clocks: clocks)
                } else {
                    Image(systemName: state.symbol).foregroundStyle(ActivityPalette.accentText)
                }
            }
            .keylineTint(ActivityPalette.accent)
            .widgetURL(Self.link(state))
        }
        .withSmallCard()
    }

    /// A film's player is already in front when the app opens; there is
    /// nowhere further to send a tap.
    private static func link(_ state: State) -> URL? {
        state.isVideo ? nil : URL(string: "aquarium://nowplaying")
    }
}

extension ListeningActivityAttributes.ContentState {
    var symbol: String {
        if sleepDeadline != nil { return "moon.zzz.fill" }
        return chapter != nil ? "book.fill" : "music.note"
    }
}

// MARK: - Lock Screen

private struct ListeningLockScreen: View {
    let state: ListeningActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: state.symbol)
                    .font(.title2)
                    .foregroundStyle(ActivityPalette.accentText)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1)
                    if let subtitle = state.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(ActivityPalette.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !isStale, let deadline = state.sleepDeadline {
                    VStack(alignment: .trailing, spacing: 0) {
                        SleepCountdown(deadline: deadline)
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: 96, alignment: .trailing)
                        Text("until sleep").font(.caption2).foregroundStyle(ActivityPalette.dim)
                    }
                } else if !state.isPlaying || isStale {
                    Text("Paused").font(.subheadline.weight(.semibold)).foregroundStyle(ActivityPalette.dim)
                }
            }
            // A book left paused for a quarter of an hour keeps its name on
            // the Lock Screen and gives the rest of the space back. So does
            // one whose app stopped speaking mid-chapter: its dates have run
            // out, and the countdown would sit at 0:00.
            if !isStale {
                if let chapter = state.chapter { ChapterProgress(chapter: chapter) }
                if state.sleepDeadline != nil { SleepButtons() }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

// MARK: - Apple Watch and CarPlay

/// The small card: one thing, large. A glance at a wrist or a dashboard has
/// time for the title and a single number, so there are no buttons — the
/// car is no place for them, and the watch's Now Playing already has them.
private struct ListeningSmall: View {
    let state: ListeningActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: state.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(ActivityPalette.accentText)
                Text(state.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isStale, let deadline = state.sleepDeadline {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SleepCountdown(deadline: deadline, alignment: .leading)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .frame(maxWidth: 110, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("to sleep")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ActivityPalette.smallDim)
                        .lineLimit(1)
                }
            } else if !isStale, let chapter = state.chapter {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ChapterLeft(chapter: chapter)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text(state.isPlaying ? chapter.shortPlace : "Paused")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ActivityPalette.smallDim)
                        .lineLimit(1)
                }
            } else if !state.isPlaying || isStale {
                Text("Paused")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(ActivityPalette.smallDim)
            } else if let subtitle = state.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ActivityPalette.smallDim)
                    .lineLimit(1)
            }
            if !isStale, let chapter = state.chapter {
                ChapterBar(chapter: chapter)
                    .tint(state.isPlaying ? ActivityPalette.accentText : ActivityPalette.smallDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Time left in the chapter: counting while the book plays, standing still
/// while it doesn't.
private struct ChapterLeft: View {
    let chapter: ListeningActivityAttributes.Chapter

    var body: some View {
        if let span = chapter.span {
            Text(timerInterval: span, countsDown: true)
                .monospacedDigit()
                .frame(maxWidth: 100, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(ListeningActivityAttributes.Chapter.clock(chapter.remaining))
                .monospacedDigit()
        }
    }
}

private struct ChapterBar: View {
    let chapter: ListeningActivityAttributes.Chapter

    var body: some View {
        Group {
            if let span = chapter.span {
                ProgressView(timerInterval: span, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else {
                ProgressView(value: chapter.fraction)
            }
        }
        .progressViewStyle(.linear)
    }
}

extension ListeningActivityAttributes.Chapter {
    /// "4:07", "1:02:09" — how `Text(timerInterval:)` draws the same span.
    static func clock(_ seconds: TimeInterval) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(max(0, seconds).rounded()).formatted(.time(pattern: pattern))
    }

    /// "ch. 4 of 31", or "left" for a book that is one piece.
    var shortPlace: String {
        count > 1 ? "ch. \(number) of \(count)" : "left"
    }
}

// MARK: - Pieces

/// Counts down to the deadline on its own. The interval's start is a day
/// back only because the API wants an interval; what is drawn is the time
/// from now to its end.
private struct SleepCountdown: View {
    let deadline: Date
    var alignment: TextAlignment = .trailing

    var body: some View {
        Text(timerInterval: deadline.addingTimeInterval(-86_400)...deadline, countsDown: true)
            .monospacedDigit()
            .multilineTextAlignment(alignment)
            .foregroundStyle(.white)
    }
}

private struct SleepButtons: View {
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ExtendSleepTimerIntent(minutes: 15)) {
                ActivityPill(title: "15 min", systemImage: "plus", prominent: true)
            }
            Button(intent: CancelSleepTimerIntent()) {
                ActivityPill(title: "Turn off", systemImage: "xmark")
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ChapterProgress: View {
    let chapter: ListeningActivityAttributes.Chapter
    var clocks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    if clocks, let span = chapter.span {
                        Text(timerInterval: span, countsDown: true)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 64, alignment: .trailing)
                    } else {
                        Text(Self.left(chapter.remaining))
                    }
                }
                .font(.caption)
                .foregroundStyle(ActivityPalette.dim)
            }
            Group {
                if clocks, let span = chapter.span {
                    ProgressView(timerInterval: span, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                } else {
                    ProgressView(value: chapter.fraction)
                }
            }
            .progressViewStyle(.linear)
            .tint(ActivityPalette.accent)
        }
    }

    /// "Chapter 4 of 31 · The Letter", or just the name when the book is one
    /// piece and the count would say nothing.
    private var heading: String {
        guard chapter.count > 1 else { return chapter.name }
        let place = "Chapter \(chapter.number) of \(chapter.count)"
        // A chapter called "Chapter 4" doesn't need saying twice.
        if chapter.name.isEmpty || chapter.name.localizedCaseInsensitiveContains("chapter \(chapter.number)") {
            return place
        }
        return "\(place) · \(chapter.name)"
    }

    /// The same clock the running countdown shows, standing still — "1 min
    /// left" was said of a chapter with fifteen seconds to go.
    private static func left(_ seconds: TimeInterval) -> String {
        "\(ListeningActivityAttributes.Chapter.clock(seconds)) left"
    }
}

/// The chapter as a ring, for the corner of the Dynamic Island.
private struct ChapterRing: View {
    let chapter: ListeningActivityAttributes.Chapter
    var clocks = true

    var body: some View {
        Group {
            if clocks, let span = chapter.span {
                ProgressView(timerInterval: span, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else {
                ProgressView(value: chapter.fraction)
            }
        }
        .progressViewStyle(.circular)
        .tint(ActivityPalette.accent)
        .frame(width: 22, height: 22)
    }
}
