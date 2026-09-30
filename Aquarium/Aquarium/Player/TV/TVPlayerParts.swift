//  The pieces the Apple TV player's controls are built from: the look (dark
//  glass, Aquarium purple where focus is), the thumbnails shown while
//  scrubbing, and a live channel's schedule.

#if os(tvOS)

import SwiftUI
import UIKit

// MARK: - The look

extension View {
    /// Dark glass: the system material with the app's own dark laid over it,
    /// so it reads the same over a snow scene as over a night one.
    func playerGlass(cornerRadius: CGFloat = 32) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.background.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

/// A focusable card in a panel row: purple when focused, a purple tick when
/// it is the current choice.
struct ChoiceCard<Leading: View>: View {
    let title: String
    var detail: String?
    var isSelected = false
    /// Nil shares the row's width with the other cards in it.
    var width: CGFloat? = 340
    /// Nil is as tall as the text needs; a row of choices that must match
    /// gives them all the same one.
    var height: CGFloat?
    /// The title in the middle of the card, for short labels — `+5`,
    /// `Reset`, `1.5×` — that look adrift at its leading edge.
    var centered = false
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        Button(action: action) {
            ChoiceCardLabel(title: title, detail: detail, isSelected: isSelected, width: width, height: height,
                            centered: centered, leading: leading)
        }
        .buttonStyle(PlayerCardStyle())
    }
}

extension ChoiceCard where Leading == EmptyView {
    init(title: String, detail: String? = nil, isSelected: Bool = false, width: CGFloat? = 340,
         height: CGFloat? = nil, centered: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, isSelected: isSelected, width: width, height: height,
                  centered: centered, action: action) { EmptyView() }
    }
}

private struct ChoiceCardLabel<Leading: View>: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let detail: String?
    let isSelected: Bool
    let width: CGFloat?
    let height: CGFloat?
    let centered: Bool
    @ViewBuilder var leading: () -> Leading

    /// Where the tick goes: in the corner when the card is too narrow to
    /// spare the title the room, or when the title is centred and a tick
    /// beside it would push it off the middle.
    private var tickInCorner: Bool { width == nil || centered }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            leading()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if centered { Spacer(minLength: 0) }
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(centered ? .center : .leading)
                Spacer(minLength: 0)
                if isSelected, !tickInCorner { checkmark }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFocused ? .white.opacity(0.85) : Theme.textDim)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(isFocused ? .white : Theme.text)
        .padding(.horizontal, centered ? 12 : 24)
        .padding(.vertical, 10)
        .frame(width: width, alignment: centered ? .center : .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: centered ? .center : .leading)
        .frame(minHeight: height ?? 72)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected && !isFocused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 2)
        )
        // A card sharing a row is too narrow to give the title's width to
        // the tick, so there it sits in the corner instead.
        .overlay(alignment: .topTrailing) {
            if isSelected, tickInCorner { checkmark.padding(12) }
        }
        .shadow(color: isFocused ? Theme.accent.opacity(0.45) : .clear, radius: 18, y: 8)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.headline.weight(.bold))
            .foregroundStyle(isFocused ? .white : Theme.link)
    }
}

/// The lift a focused card gets, without the system's own white platter.
struct PlayerCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerCardBody(configuration: configuration)
    }

    private struct PlayerCardBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : isFocused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// A tab along the top of the panel: text, with a purple capsule behind the
/// one that is focused and a purple underline under the one that is open.
struct PanelTabLabel: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let isCurrent: Bool

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(isFocused ? .white : isCurrent ? Theme.text : Theme.textDim)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(Capsule().fill(isFocused ? Theme.accent : .clear))
            .overlay(alignment: .bottom) {
                if isCurrent && !isFocused {
                    Capsule().fill(Theme.accent).frame(height: 4).padding(.horizontal, 22).offset(y: 4)
                }
            }
    }
}

// MARK: - Time

enum PlayerTime {
    /// `1:02:03`, `2:03`, or `0:07`.
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Scrub thumbnails

/// Jellyfin's trickplay thumbnails: sheets of small pictures, one every few
/// seconds, fetched a sheet at a time as the scrubber reaches them.
@MainActor @Observable
final class TrickplayStore {
    private(set) var info: TrickplayInfo?
    private var sheets: [Int: CGImage] = [:]
    @ObservationIgnored private var loading: Set<Int> = []

    func reset(_ info: TrickplayInfo?) {
        guard info != self.info else { return }
        self.info = info
        sheets = [:]
        loading = []
    }

    /// The thumbnail nearest `seconds`, if its sheet has arrived. Asks for the
    /// sheet if it hasn't, and for the one after it, which is where a scrub is
    /// usually heading.
    func thumbnail(at seconds: Double) -> CGImage? {
        guard let info, info.interval > 0, info.width > 0, info.height > 0 else { return nil }
        let perSheet = max(1, info.tileWidth * info.tileHeight)
        var index = Int(max(0, seconds) * 1000) / info.interval
        if info.thumbnailCount > 0 { index = min(index, info.thumbnailCount - 1) }
        let sheet = index / perSheet
        let cell = index % perSheet
        load(sheet)
        load(sheet + 1)
        guard let image = sheets[sheet] else { return nil }
        let x = (cell % info.tileWidth) * info.width
        let y = (cell / info.tileWidth) * info.height
        return image.cropping(to: CGRect(x: x, y: y, width: info.width, height: info.height))
    }

    private func load(_ sheet: Int) {
        guard let info, sheets[sheet] == nil, !loading.contains(sheet) else { return }
        if info.thumbnailCount > 0 {
            let perSheet = max(1, info.tileWidth * info.tileHeight)
            guard sheet * perSheet < info.thumbnailCount else { return }
        }
        loading.insert(sheet)
        Task {
            let data = try? await JellyfinClient.shared.trickplayTile(info, tileIndex: sheet)
            guard self.info == info else { return }
            loading.remove(sheet)
            if let data, let image = UIImage(data: data)?.cgImage {
                sheets[sheet] = image
            }
        }
    }
}

// MARK: - The Info tab's artwork

/// The poster (or a channel's logo) for the Info tab, fetched while the
/// stream opens rather than when the panel does. Fetched then, it arrives
/// part-way down the panel's slide and fades in on its own, a beat apart from
/// the card it sits in; decoded beforehand, it is drawn with the card from the
/// first frame.
@MainActor @Observable
final class InfoArtwork {
    private(set) var url: URL?
    private(set) var image: UIImage?

    static func url(for player: PlayerModel) -> URL? {
        guard let item = player.infoItem else { return nil }
        return player.isLive ? Artwork.channelLogo(item, width: 400) : Artwork.poster(for: item, width: 400)
    }

    func load(_ url: URL?) async {
        guard url != self.url else { return }
        self.url = url
        image = nil
        guard let url else { return }
        let loaded = await ImageLoader.shared.load(url)
        guard self.url == url else { return }
        image = loaded
    }
}

// MARK: - A channel's schedule

/// What a channel is showing and what comes after, for the Info tab and the
/// live timeline. The same two roads the guide takes: a custom playlist's
/// schedule came down with the playlist, a Jellyfin channel has a server to
/// ask. Refreshed every twenty minutes while the channel is on.
@MainActor @Observable
final class ChannelSchedule {
    private(set) var programmes: [BaseItem] = []
    @ObservationIgnored private var channelId: String?

    func load(for channel: BaseItem?) async {
        guard let channel else {
            programmes = []
            channelId = nil
            return
        }
        if channel.Id != channelId { programmes = [] }
        channelId = channel.Id
        while !Task.isCancelled {
            await fetch(channel)
            try? await Task.sleep(for: .seconds(1200))
        }
    }

    /// The programme on now, and the ones after it.
    var now: BaseItem? {
        let date = Date()
        return programmes.first { ($0.programStart ?? .distantFuture) <= date && date < ($0.programEnd ?? .distantPast) }
    }

    var upcoming: [BaseItem] {
        let date = Date()
        return programmes.filter { ($0.programStart ?? .distantPast) > date }
    }

    private func fetch(_ channel: BaseItem) async {
        let start = Date().addingTimeInterval(-6 * 3600)
        let end = Date().addingTimeInterval(8 * 3600)
        var fetched: [BaseItem] = []
        if let provider = LiveTVStore.shared.programsProvider {
            fetched = (try? await provider([channel.Id], start, end)) ?? []
        } else if Preferences.shared.session != nil {
            fetched = (try? await JellyfinClient.shared.programs(channelIds: [channel.Id], start: start, end: end)) ?? []
        }
        guard channelId == channel.Id else { return }
        programmes = fetched.sorted { ($0.programStart ?? .distantPast) < ($1.programStart ?? .distantPast) }
    }
}

// MARK: - Skip badge

/// How far a run of clicks left or right has gone: "+30 s", "−1:20", beside
/// the edge of the picture it went towards.
struct SkipBadge: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 14) {
            if seconds < 0 { Image(systemName: "backward.fill") }
            Text(label)
                .contentTransition(.numericText(value: Double(seconds)))
            if seconds > 0 { Image(systemName: "forward.fill") }
        }
        .font(.title2.weight(.bold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 34)
        .padding(.vertical, 20)
        .playerGlass(cornerRadius: 40)
    }

    private var label: String {
        let size = abs(seconds)
        let sign = seconds < 0 ? "−" : "+"
        return size < 60 ? "\(sign)\(size) s" : "\(sign)\(size / 60):" + String(format: "%02d", size % 60)
    }
}

#endif
