//  What every platform's player chrome is built from: the dark glass, the
//  time format, Jellyfin's trickplay thumbnails, a channel's schedule, the
//  Info tab's artwork and the badge that counts a run of skips. Lifted from
//  the Apple TV player (`TV/TVPlayerParts.swift`), which keeps only its
//  focus-driven cards.

import ImageIO
import SwiftUI

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

// MARK: - Time

enum PlayerTime {
    /// `1:02:03`, `2:03`, or `0:07`.
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The same, spoken: "1 hour, 2 minutes and 3 seconds", for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unknown" }
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        if s > 0 || parts.isEmpty { parts.append("\(s) second\(s == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
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
            // ImageIO rather than UIImage, so the store is the same object on
            // a Mac.
            if let data,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
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
    private(set) var image: PlatformImage?

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

/// How far a run of skips has gone: "+30 s", "−1:20", beside the edge of the
/// picture it went towards. Full size on a television; `compact` is the
/// phone's.
struct SkipBadge: View {
    let seconds: Int
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 14) {
            if seconds < 0 { Image(systemName: "backward.fill") }
            Text(label)
                .contentTransition(.numericText(value: Double(seconds)))
            if seconds > 0 { Image(systemName: "forward.fill") }
        }
        .font((compact ? Font.headline : .title2).weight(.bold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 18 : 34)
        .padding(.vertical, compact ? 10 : 20)
        .playerGlass(cornerRadius: compact ? 22 : 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(seconds < 0 ? "Skipped back \(PlayerTime.spoken(Double(-seconds)))" : "Skipped forward \(PlayerTime.spoken(Double(seconds)))")
    }

    private var label: String {
        let size = abs(seconds)
        let sign = seconds < 0 ? "−" : "+"
        return size < 60 ? "\(sign)\(size) s" : "\(sign)\(size / 60):" + String(format: "%02d", size % 60)
    }
}
