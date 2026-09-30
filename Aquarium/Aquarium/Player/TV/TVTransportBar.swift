//  The bar along the bottom of the picture: what is playing, the timeline, and
//  the times either side of it. While scrubbing, a thumbnail of where the
//  scrubber has got to rides above it.

#if os(tvOS)

import SwiftUI

struct TVTransportBar: View {
    @Environment(PlayerModel.self) private var player
    let trickplay: TrickplayStore
    let schedule: ChannelSchedule
    /// Where the scrubber is, while scrubbing.
    let scrub: Double?
    /// Where Menu would take the playhead back to, after a scrub.
    var returnPoint: Double?
    /// With the panel down, only the timeline: the panel covers where the
    /// title goes, and says everything it would.
    var timelineOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !timelineOnly { heading }
            if player.isLive {
                LiveTimeline(programme: schedule.now)
            } else {
                Timeline(scrub: scrub, returnPoint: returnPoint, trickplay: trickplay)
                    .frame(height: 12)
                times
            }
            if !timelineOnly { hint }
        }
        .padding(.horizontal, 90)
        .padding(.top, 180)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.45),
                    .init(color: .black.opacity(0.85), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - What is playing

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if player.isLive {
                    Text("LIVE")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.danger))
                        .foregroundStyle(.white)
                }
                if let kicker, !kicker.isEmpty {
                    Text(kicker)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.link)
                }
                if player.isPaused {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textBody)
                }
            }
            Text(mainTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    /// The line above the title: the show and the episode, or the channel.
    private var kicker: String? {
        if player.isLive {
            if let channel = player.currentChannel {
                return [channel.ChannelNumber, channel.title].compactMap { $0 }.joined(separator: " · ")
            }
            return player.subtitle
        }
        if let item = player.item, item.isEpisode {
            return [item.SeriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        }
        return player.item?.ProductionYear.map(String.init)
    }

    private var mainTitle: String {
        if player.isLive { return schedule.now?.title ?? player.title }
        return player.item?.title ?? player.title
    }

    private var times: some View {
        HStack {
            Text(PlayerTime.format(scrub ?? player.position))
            Spacer()
            Text("−" + PlayerTime.format(max(0, player.duration - (scrub ?? player.position))))
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
    }

    private var hint: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.down")
            Text(scrub != nil
                 ? "Click to jump here · Menu to go back"
                 : returnPoint.map { "Menu to go back to \(PlayerTime.format($0))" }
                 ?? (player.isLive
                    ? "Swipe down for Info, Audio, Subtitles and Channels · Click up or down to change channel"
                    : "Swipe down for Info, Audio, Subtitles, Quality, Speed and Sync"))
        }
        .font(.caption)
        .foregroundStyle(Theme.textDim)
    }
}

// MARK: - The timeline

private struct Timeline: View {
    @Environment(PlayerModel.self) private var player
    let scrub: Double?
    let returnPoint: Double?
    let trickplay: TrickplayStore

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.32))
                    .frame(width: width * fraction(player.buffered))
                // Intro and credits, marked where they are.
                ForEach(player.segments) { segment in
                    Rectangle()
                        .fill(Theme.link.opacity(0.35))
                        .frame(width: max(2, width * (fraction(segment.end) - fraction(segment.start))))
                        .offset(x: width * fraction(segment.start))
                }
                Capsule().fill(Theme.accent)
                    .frame(width: max(12, width * fraction(player.position)))
            }
            .frame(height: geo.size.height)
            // Over the bar rather than in it, so the knob and the thumbnail
            // above it don't make the bar itself any taller.
            // Where the playhead was before the last jump: Menu goes back there.
            .overlay(alignment: .leading) {
                if let returnPoint, scrub == nil {
                    Capsule()
                        .fill(.white.opacity(0.8))
                        .frame(width: 4, height: 30)
                        .offset(x: width * fraction(returnPoint) - 2)
                }
            }
            .overlay(alignment: .leading) {
                if let scrub {
                    ScrubKnob().offset(x: width * fraction(scrub) - ScrubKnob.size / 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let scrub {
                    ScrubPreview(seconds: scrub, trickplay: trickplay)
                        .offset(
                            x: min(max(width * fraction(scrub) - ScrubPreview.width / 2, 0),
                                   max(0, width - ScrubPreview.width)),
                            y: -(geo.size.height + 30)
                        )
                }
            }
        }
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / player.duration, 0), 1))
    }
}

/// The scrubber's knob, centred on the bar.
private struct ScrubKnob: View {
    static let size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: Self.size, height: Self.size)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 5))
            .shadow(color: .black.opacity(0.4), radius: 8)
    }
}

/// Above the knob: the thumbnail of that moment, and its time. It follows the
/// knob but stops at either end of the bar rather than leaving the screen.
private struct ScrubPreview: View {
    static let width: CGFloat = 400
    let seconds: Double
    let trickplay: TrickplayStore

    private var thumbWidth: CGFloat { Self.width }

    var body: some View {
        VStack(spacing: 10) {
            thumbnail
            Text(PlayerTime.format(seconds))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.accent))
        }
        .frame(width: Self.width)
    }

    private var thumbHeight: CGFloat {
        guard let info = trickplay.info, info.width > 0 else { return 0 }
        return thumbWidth * CGFloat(info.height) / CGFloat(info.width)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if trickplay.info != nil {
            Group {
                if let image = trickplay.thumbnail(at: seconds) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.6)
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        }
    }
}

/// A channel's timeline: how far through the programme on now.
private struct LiveTimeline: View {
    let programme: BaseItem?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * progress(at: context.date))
                    }
                }
                .frame(height: 12)
                HStack {
                    Text(programme?.programStart.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                    Spacer()
                    if let end = programme?.programEnd {
                        let minutes = max(0, Int(end.timeIntervalSince(context.date) / 60))
                        Text("\(minutes) min left · ends \(end.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
            }
            .opacity(programme == nil ? 0.4 : 1)
        }
    }

    private func progress(at date: Date) -> CGFloat {
        guard let start = programme?.programStart, let end = programme?.programEnd, end > start else { return 1 }
        return CGFloat(min(max(date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1))
    }
}

#endif
