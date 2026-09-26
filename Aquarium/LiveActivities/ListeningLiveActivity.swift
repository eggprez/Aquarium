//  What is being listened to, and when the sleep timer will stop it.
//
//  Everything that moves here moves by itself. The countdown is a
//  `Text(timerInterval:)`, which the system animates from a date without
//  asking anyone — the app says something only when that date changes, or
//  when playback pauses or resumes.
//
//  An audiobook's place in its chapter used to be drawn here as well. It was
//  taken out: the bar had to be re-anchored by the app after every stall,
//  seek, speed change and pause, and it never stayed honest for long.

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
            // playing; the deadline has passed, and would say 0:00.
            let clocks = !context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: State.symbol)
                        .font(.title2)
                        .foregroundStyle(ActivityPalette.accentText)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if clocks {
                        SleepCountdown(deadline: state.sleepDeadline)
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
                    if clocks {
                        SleepButtons().padding(.top, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: State.symbol).foregroundStyle(ActivityPalette.accentText)
            } compactTrailing: {
                if clocks {
                    SleepCountdown(deadline: state.sleepDeadline)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: 48)
                }
            } minimal: {
                Image(systemName: State.symbol).foregroundStyle(ActivityPalette.accentText)
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
    static let symbol = "moon.zzz.fill"
}

// MARK: - Lock Screen

private struct ListeningLockScreen: View {
    let state: ListeningActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: ListeningActivityAttributes.ContentState.symbol)
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
                if !isStale {
                    VStack(alignment: .trailing, spacing: 0) {
                        SleepCountdown(deadline: state.sleepDeadline)
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: 96, alignment: .trailing)
                        Text("until sleep").font(.caption2).foregroundStyle(ActivityPalette.dim)
                    }
                } else {
                    Text("Paused").font(.subheadline.weight(.semibold)).foregroundStyle(ActivityPalette.dim)
                }
            }
            // Something left paused for a quarter of an hour keeps its name on
            // the Lock Screen and gives the rest of the space back. So does
            // one whose app stopped speaking: its deadline has passed, and
            // the countdown would sit at 0:00.
            if !isStale {
                SleepButtons()
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
                Image(systemName: ListeningActivityAttributes.ContentState.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(ActivityPalette.accentText)
                Text(state.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isStale {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SleepCountdown(deadline: state.sleepDeadline, alignment: .leading)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .frame(maxWidth: 110, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("to sleep")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ActivityPalette.smallDim)
                        .lineLimit(1)
                }
            } else {
                Text("Paused")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(ActivityPalette.smallDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
