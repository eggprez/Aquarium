//  A download batch: how many have landed, what is arriving, and a pause.
//
//  The one activity here that can't animate itself — a transfer ends when it
//  ends, not at a date anyone knows — so it shows what the app last said. The
//  app says something as each item lands, which it is woken for even while
//  suspended; between those it may be saying nothing, and once the state has
//  gone stale the view stops quoting a percentage it can no longer vouch for.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct DownloadsLiveActivity: Widget {
    private static let link = URL(string: "aquarium://downloads")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadsActivityAttributes.self) { context in
            ActivityLayout {
                DownloadsSmall(state: context.state, isStale: context.isStale)
            } full: {
                DownloadsLockScreen(state: context.state, isStale: context.isStale)
            }
            .widgetURL(Self.link)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.title2)
                        .foregroundStyle(state.tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .running, !context.isStale {
                        Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(state.headline).font(.subheadline.weight(.semibold)).lineLimit(1).monospacedDigit()
                        if let detail = state.detail(isStale: context.isStale) {
                            Text(detail).font(.caption).foregroundStyle(ActivityPalette.dim).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.phase != .finished {
                        VStack(alignment: .leading, spacing: 8) {
                            if state.phase == .running, !context.isStale, state.currentTitle != nil {
                                CurrentItemBar(state: state)
                            }
                            QueueLine(state: state)
                            HStack(spacing: 12) {
                                OverallBar(fraction: state.fraction, remaining: state.remaining)
                                PauseButton(paused: state.phase == .paused)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            } compactTrailing: {
                if state.phase == .finished {
                    Text("\(state.done)").font(.caption.weight(.semibold)).monospacedDigit()
                } else {
                    DownloadRing(fraction: state.fraction, count: state.remaining)
                }
            } minimal: {
                if state.phase == .finished {
                    Image(systemName: state.symbol).foregroundStyle(state.tint)
                } else {
                    DownloadRing(fraction: state.fraction, count: state.remaining)
                }
            }
            .keylineTint(ActivityPalette.accent)
            .widgetURL(Self.link)
        }
        .withSmallCard()
    }
}

extension DownloadsActivityAttributes.ContentState {
    var symbol: String {
        switch phase {
        case .running: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .finished: failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch phase {
        case .running, .paused: ActivityPalette.accentText
        case .finished: failed > 0 ? .orange : .green
        }
    }

    var headline: String {
        switch phase {
        case .running:
            // The one arriving is the next after those that have landed.
            total > 1 ? "Downloading \(min(done + failed + 1, total).formatted()) of \(total.formatted())" : "Downloading"
        case .paused:
            "Downloads paused"
        case .finished:
            "Downloaded \(done.formatted()) item\(done == 1 ? "" : "s")"
        }
    }

    func detail(isStale: Bool) -> String? {
        switch phase {
        case .running:
            if isStale { return "Carrying on in the background" }
            return currentTitle
        case .paused:
            return "\(remaining.formatted()) item\(remaining == 1 ? "" : "s") waiting"
        case .finished:
            return failed > 0 ? "\(failed.formatted()) didn't finish — open Downloads to retry" : nil
        }
    }
}

private struct DownloadsLockScreen: View {
    let state: DownloadsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: state.symbol)
                    .font(.title2)
                    .foregroundStyle(state.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.headline).font(.headline).lineLimit(1).monospacedDigit()
                    if let detail = state.detail(isStale: isStale) {
                        Text(detail).font(.subheadline).foregroundStyle(ActivityPalette.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if state.phase == .running, !isStale {
                    Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if state.phase != .finished {
                if state.phase == .running, !isStale, state.currentTitle != nil {
                    CurrentItemBar(state: state)
                        .padding(.leading, 42)
                }
                QueueLine(state: state)
                    .padding(.leading, 42)
                HStack(spacing: 12) {
                    OverallBar(fraction: state.fraction, remaining: state.remaining)
                    PauseButton(paused: state.phase == .paused)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// The small card for Apple Watch and CarPlay: the batch's percentage, large,
/// and how far through the count it is. No button — see `ListeningSmall`.
private struct DownloadsSmall: View {
    let state: DownloadsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: state.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(state.tint)
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(big)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let small {
                    Text(small)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ActivityPalette.smallDim)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if state.phase != .finished {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.linear)
                    .tint(state.phase == .paused ? ActivityPalette.smallDim : ActivityPalette.accentText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var label: String {
        switch state.phase {
        case .running: "Downloading"
        case .paused: "Paused"
        case .finished: state.failed > 0 ? "Downloads done" : "Downloaded"
        }
    }

    /// The one number: a percentage while it runs, the count once it's over.
    private var big: String {
        switch state.phase {
        case .running where !isStale, .paused:
            state.fraction.formatted(.percent.precision(.fractionLength(0)))
        case .running:
            "\(state.done.formatted()) of \(state.total.formatted())"
        case .finished:
            "\(state.done.formatted()) item\(state.done == 1 ? "" : "s")"
        }
    }

    private var small: String? {
        switch state.phase {
        case .running where !isStale, .paused:
            state.total > 1 ? "\(state.done.formatted()) of \(state.total.formatted())" : nil
        case .running:
            nil
        case .finished:
            state.failed > 0 ? "\(state.failed.formatted()) failed" : nil
        }
    }
}

/// The arriving item's own bar, and roughly how long it has left. Drawn from
/// the span when there is one, so it keeps filling while the app sleeps;
/// from the last reading when there isn't; a sliver that says "working on it"
/// when neither exists yet.
private struct CurrentItemBar: View {
    let state: DownloadsActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let start = state.currentStart, let end = state.currentEnd, end > start {
                    ProgressView(timerInterval: start...end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(value: state.currentFraction ?? 0)
                }
            }
            .progressViewStyle(.linear)
            .tint(.white)
            if let end = state.currentEnd, end > Date() {
                Text(timerInterval: Date()...end, countsDown: true)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(ActivityPalette.dim)
                    .frame(width: 52, alignment: .trailing)
            } else if let fraction = state.currentFraction {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(ActivityPalette.dim)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// "Next: …" — the count lives on the overall bar, where a long title
/// can't push it off the end.
private struct QueueLine: View {
    let state: DownloadsActivityAttributes.ContentState

    var body: some View {
        if let next = state.nextTitle, state.phase == .running {
            (Text("Next: ").foregroundStyle(ActivityPalette.dim) + Text(next))
                .font(.caption)
                .lineLimit(1)
        }
    }
}

/// The whole batch, labelled so it isn't mistaken for the item bar above it.
private struct OverallBar: View {
    let fraction: Double
    let remaining: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("All downloads · \(remaining.formatted()) remaining")
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(ActivityPalette.dim)
            ProgressView(value: fraction).tint(ActivityPalette.accent)
        }
    }
}

private struct PauseButton: View {
    let paused: Bool

    var body: some View {
        Button(intent: SetDownloadsPausedIntent(paused: !paused)) {
            ActivityPill(
                title: paused ? "Resume" : "Pause",
                systemImage: paused ? "play.fill" : "pause.fill",
                prominent: paused
            )
        }
        .buttonStyle(.plain)
    }
}

/// The batch as a ring, with how many are left inside it.
private struct DownloadRing: View {
    let fraction: Double
    let count: Int

    var body: some View {
        ProgressView(value: fraction)
            .progressViewStyle(.circular)
            .tint(ActivityPalette.accent)
            .frame(width: 22, height: 22)
            .overlay {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: count > 99 ? 7 : 9, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
            }
    }
}
