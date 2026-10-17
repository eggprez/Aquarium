//  The timeline: the played portion in the accent, what is buffered in white
//  at 30 %, intro and credits marked where they are, a tick at every chapter,
//  and a trickplay thumbnail riding above the thumb while a finger scrubs.
//
//  A drag along the bar scrubs. Pulling the finger away from the bar slows
//  the scrub — the Music app's fine scrub — so the last few seconds can be
//  found without a hand's width of travel meaning a minute. A tap on the bar
//  jumps there. VoiceOver gets the bar as an adjustable element that moves
//  by the Settings skip interval.

#if !os(tvOS)

import SwiftUI

struct PlayerTimeline: View {
    @Environment(PlayerModel.self) private var player
    @Environment(Preferences.self) private var prefs

    @Bindable var chrome: PlayerChromeState
    let trickplay: TrickplayStore
    let compact: Bool
    let onInteract: () -> Void

    /// Where the finger last was along the bar, for the delta the next move
    /// adds.
    @State private var lastX: CGFloat = 0

    /// The whole band the finger can land in; the bar sits in its middle.
    private static let hitHeight: CGFloat = 44

    private var canScrub: Bool { !player.isLive && player.duration > 0 && !player.isOpening }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let scrubbing = chrome.scrub != nil
            let barHeight = scrubbing ? PlayerMetrics.barHeightScrubbing : PlayerMetrics.barHeight
            let thumb = scrubbing ? PlayerMetrics.thumbSizeScrubbing : PlayerMetrics.thumbSize
            let shown = chrome.scrub ?? player.position

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                    .frame(height: barHeight)
                Capsule().fill(.white.opacity(0.3))
                    .frame(width: width * fraction(player.buffered), height: barHeight)
                ForEach(player.segments) { segment in
                    Rectangle()
                        .fill(Theme.link.opacity(0.35))
                        .frame(width: max(2, width * (fraction(segment.end) - fraction(segment.start))), height: barHeight)
                        .offset(x: width * fraction(segment.start))
                }
                Capsule().fill(Theme.accent)
                    .frame(width: max(barHeight, width * fraction(shown)), height: barHeight)
                ForEach(Array(player.chapterStarts.enumerated()), id: \.offset) { _, start in
                    if start > 0 {
                        Rectangle()
                            .fill(.white.opacity(0.75))
                            .frame(width: 1.5, height: barHeight + 4)
                            .offset(x: width * fraction(start) - 0.75)
                    }
                }
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                    .offset(x: min(max(width * fraction(shown) - thumb / 2, 0), max(0, width - thumb)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(drag(width: width, height: geo.size.height))
            .overlay(alignment: .bottomLeading) {
                if let scrub = chrome.scrub {
                    let previewWidth = PlayerMetrics.previewWidth(compact: compact)
                    ScrubPreview(seconds: scrub, chapter: player.chapterName(at: scrub), trickplay: trickplay,
                                 width: previewWidth)
                        .offset(
                            x: min(max(width * fraction(scrub) - previewWidth / 2, 0), max(0, width - previewWidth)),
                            y: -(geo.size.height / 2 + 18)
                        )
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: scrubbing)
        }
        .frame(height: Self.hitHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(PlayerTime.spoken(player.position)) of \(PlayerTime.spoken(player.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.seek(by: Double(prefs.skipInterval))
            case .decrement: player.seek(by: -Double(prefs.skipInterval))
            @unknown default: break
            }
        }
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / player.duration, 0), 1))
    }

    /// A drag from anywhere in the band: the first touch puts the scrubber
    /// under the finger, and every move after adds its distance along the
    /// bar, scaled down the further the finger is from it.
    private func drag(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard canScrub, width > 0 else { return }
                onInteract()
                if chrome.scrub == nil {
                    chrome.scrub = Double(min(max(value.location.x / width, 0), 1)) * player.duration
                    lastX = value.location.x
                    return
                }
                // Dead zone of thirty points around the bar, then slower by
                // half every fifty points further: a hand's width away is a
                // quarter speed.
                let away = max(0, abs(value.location.y - height / 2) - 30)
                let factor = 1 / (1 + Double(away) / 50)
                let dx = value.location.x - lastX
                lastX = value.location.x
                let delta = Double(dx / width) * player.duration * factor
                chrome.scrub = min(max(0, (chrome.scrub ?? 0) + delta), max(0, player.duration - 1))
            }
            .onEnded { _ in
                guard let target = chrome.scrub else { return }
                player.seek(to: target)
                chrome.scrub = nil
            }
    }
}

// MARK: - The thumbnail above the thumb

/// The thumbnail of that moment, its time, and the chapter it is in. It
/// follows the thumb but stops at either end of the bar rather than leaving
/// the screen.
private struct ScrubPreview: View {
    let seconds: Double
    let chapter: String?
    let trickplay: TrickplayStore
    let width: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            HStack(spacing: 6) {
                Text(PlayerTime.format(seconds))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                if let chapter, !chapter.isEmpty {
                    Text(chapter)
                        .font(.footnote)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.accent))
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }

    private var height: CGFloat {
        guard let info = trickplay.info, info.width > 0 else { return 0 }
        return width * CGFloat(info.height) / CGFloat(info.width)
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
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        }
    }
}

// MARK: - A channel's timeline

/// How far through the programme on now, and when it ends.
struct LivePlayerTimeline: View {
    let programme: BaseItem?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * progress(at: context.date))
                    }
                }
                .frame(height: PlayerMetrics.barHeight)
                HStack {
                    Text(programme?.programStart.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                    Spacer()
                    if let end = programme?.programEnd {
                        let minutes = max(0, Int(end.timeIntervalSince(context.date) / 60))
                        Text("\(minutes) min left · ends \(end.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
            }
            .opacity(programme == nil ? 0.4 : 1)
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 8)
    }

    private func progress(at date: Date) -> CGFloat {
        guard let start = programme?.programStart, let end = programme?.programEnd, end > start else { return 1 }
        return CGFloat(min(max(date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1))
    }
}

#endif
