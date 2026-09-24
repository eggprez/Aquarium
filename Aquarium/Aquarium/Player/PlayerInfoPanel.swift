//  The ribbon you pull down from the top of the picture: everything about what
//  is on screen.
//
//  This is the app's own overlay, and it did not start that way. The first
//  version went through `AVPlayerViewController.customInfoViewControllers`,
//  which is the supported door into the system's own info panel — and on
//  tvOS 26 that panel is not at the top any more. It comes up from the bottom,
//  as a row of tabs above the transport bar, which is a different thing from
//  the band of information the Apple TV app slides down over the picture. So
//  the content stayed and the container changed: it is drawn here, at the top,
//  over the video.
//
//  Being ours rather than the system's costs the tab bar, and that is why
//  nothing in here is focusable and everything is on screen at once — a
//  overlay on tvOS cannot take focus off the transport bar without fighting
//  it for the remote, which is the same reason `PlayerScreen`'s iOS overlay is
//  walled off from tvOS. So the two halves sit one above the other instead:
//  what you are watching — the title, the cast, the description, and on a
//  channel the programme that is on and the ones after it — and what is
//  actually arriving, the file the server holds against the bytes coming down
//  the wire, which on this app's usual diet of IPTV channels and transcodes is
//  the interesting half.
//
//  It is opened by a down-swipe on the remote and by an item in the transport
//  bar's own menu, because a gesture layered over AVKit's is a gesture that
//  may not land — see `PlayerScreen.Coordinator`. It is readable over any
//  picture because it carries its own scrim rather than relying on one.
//
//  Everything it shows is fetched before it is asked for. The first version
//  loaded the item's detail and the channel's schedule when the ribbon
//  appeared, and the ribbon came down in two stages because of it: the title
//  and a blank slid in, then the overview, the cast and the artwork landed a
//  few hundred milliseconds later and the band grew under them, unanimated.
//  `PlayerInfoStore` is owned by the player screen and starts loading when
//  the stream does, so by the time anyone swipes the band is whole, and it
//  comes down once, at its full size, as one piece.

#if os(tvOS)

import AVKit
import SwiftUI

// MARK: - What the ribbon shows

/// The channel's schedule and the artwork, fetched as the stream starts rather
/// than as the ribbon opens. The item's detail is the player's: see
/// `item(for:)`.
///
/// Owned by `PlayerScreen`, which restarts `load` whenever the thing playing
/// changes, so the ribbon only ever draws from memory. The artwork is here as
/// a decoded image rather than a URL for the same reason: a `RemoteImage`
/// loads on its first appearance and fades in when it has, which is a second
/// thing arriving after the band has.
@MainActor @Observable
final class PlayerInfoStore {
    /// What this channel is showing, and what it shows after that.
    private(set) var schedule: [BaseItem] = []
    /// The poster or the channel's wordmark, decoded and ready to draw.
    private(set) var artwork: PlatformImage?

    /// The whole item, when what playback was handed was a list row.
    ///
    /// An episode started from a shelf on Home arrives with a name, an id and
    /// little else: no overview, no cast, no media streams. The player asks for
    /// the full item itself as it starts one (see `PlayerModel.loadExtras`),
    /// and `infoItem` is that item once it lands. This store used to make the
    /// same request again, at the same moment, with the same test.
    func item(for player: PlayerModel) -> BaseItem? { player.infoItem }

    func load(for player: PlayerModel) async {
        schedule = []
        artwork = nil
        guard let base = player.infoItem else { return }
        if player.isLive {
            await loadSchedule(for: base, player: player)
        }
        await loadArtwork(for: player)
        guard player.isLive else { return }
        // An evening on one channel outlives the window fetched above, and the
        // programme on it changes without anything about playback moving. The
        // custom source answers this from memory; Jellyfin's is one small
        // request every twenty minutes, and only while a channel is on screen.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1200))
            guard !Task.isCancelled else { return }
            await loadSchedule(for: base, player: player)
        }
    }

    private func loadSchedule(for channel: BaseItem, player: PlayerModel) async {
        let start = Date().addingTimeInterval(-6 * 3600)
        let end = Date().addingTimeInterval(6 * 3600)
        var fetched: [BaseItem] = []
        // The same two roads the guide takes: a custom playlist's schedule came
        // down with the playlist and is filtered in memory, a Jellyfin channel
        // has a server to ask. See `TVGuideView.loadPrograms`.
        if let provider = LiveTVStore.shared.programsProvider {
            fetched = (try? await provider([channel.Id], start, end)) ?? []
        } else if Preferences.shared.session != nil {
            fetched = (try? await JellyfinClient.shared.programs(
                channelIds: [channel.Id], start: start, end: end
            )) ?? []
        }
        guard player.infoItem?.Id == channel.Id else { return }
        schedule = fetched.sorted {
            ($0.programStart ?? .distantPast) < ($1.programStart ?? .distantPast)
        }
    }

    /// The same address `PlayerInfoPanel.artwork` draws, fetched through the
    /// shared cache so a poster the library page already holds costs nothing.
    private func loadArtwork(for player: PlayerModel) async {
        let id = player.infoItem?.Id
        guard let url = Self.artworkURL(for: player, item: item(for: player)) else { return }
        let image = await ImageLoader.shared.load(url)
        guard player.infoItem?.Id == id else { return }
        artwork = image
    }

    static func artworkURL(for player: PlayerModel, item: BaseItem?) -> URL? {
        if player.isLive {
            return item.map { Artwork.channelLogo($0, width: 400) } ?? player.artworkURL
        }
        return item.map { Artwork.poster(for: $0, width: 400) } ?? player.artworkURL
    }
}

// MARK: - The ribbon

/// The whole band: what is playing above, what is arriving below, on a scrim
/// of its own.
struct PlayerInfoRibbon: View {
    let player: PlayerModel
    let info: PlayerInfoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PlayerInfoPanel(player: player, info: info)
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
            PlayerStreamPanel(player: player)
        }
        .padding(.horizontal, 70)
        .padding(.top, 40)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(alignment: .top) { scrim }
        // One piece. The band is inserted with a move transition, and without
        // this each column inside it settles into place on a path of its own
        // — the geometry of the children animates against the parent's, and a
        // band that is meant to slide down as a slab arrives in parts. This
        // resolves the layout inside first and moves the result as a whole.
        .geometryGroup()
    }

    /// Near-solid where the words are and gone by the bottom edge, so the band
    /// ends in the picture rather than on a line ruled across it.
    ///
    /// Black rather than a material: a material over a bright frame is still a
    /// bright frame, and this has to be legible over a snow scene as well as
    /// over a night exterior.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.94), location: 0),
                .init(color: .black.opacity(0.94), location: 0.72),
                .init(color: .black.opacity(0.78), location: 0.88),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Info

struct PlayerInfoPanel: View {
    let player: PlayerModel
    /// Loaded before this is on screen — see `PlayerInfoStore`.
    let info: PlayerInfoStore

    private var item: BaseItem? { info.item(for: player) }
    private var schedule: [BaseItem] { info.schedule }

    var body: some View {
        // Three columns, not one tall stack. The panel is a band across the top
        // of the screen — a couple of thousand points wide and a few hundred
        // deep — so everything that isn't the description goes beside it rather
        // than under it. Stacked, the cast and the studio fell off the bottom.
        HStack(alignment: .top, spacing: 44) {
            artwork
            VStack(alignment: .leading, spacing: 10) {
                if player.isLive {
                    liveText
                } else {
                    onDemandText
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 16) {
                if player.isLive {
                    comingUp
                } else {
                    credits
                }
            }
            .frame(width: 460, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Artwork

    /// The decoded picture from the store when it has one, so the artwork is
    /// there on the ribbon's first frame; the loading view only for the
    /// ribbon opened before the fetch has finished.
    @ViewBuilder
    private var artwork: some View {
        if player.isLive {
            // A channel's picture is a wordmark on a transparent background,
            // which cropped to a poster shape is a corner of a letter.
            Group {
                if let image = info.artwork {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RemoteImage(
                        url: PlayerInfoStore.artworkURL(for: player, item: item),
                        contentMode: .fit
                    )
                }
            }
            .frame(width: 200, height: 120)
        } else {
            Group {
                if let image = info.artwork {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 300)
                        .clipped()
                } else {
                    RemoteImage(
                        url: PlayerInfoStore.artworkURL(for: player, item: item),
                        blurHash: item.flatMap { Artwork.hash($0) },
                        contentMode: .fill
                    )
                }
            }
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: A film or an episode

    @ViewBuilder
    private var onDemandText: some View {
        let item = item

        if let series = item?.SeriesName, !series.isEmpty {
            eyebrow(series)
        } else if let year = item?.ProductionYear {
            eyebrow(String(year))
        }

        Text(item?.title ?? player.title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(2)

        if let label = item?.episodeLabel {
            Text(label)
                .font(.headline)
                .foregroundStyle(Theme.textBody)
        }

        if let facts = factsLine(item), !facts.isEmpty {
            Text(facts)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }

        if let tagline = item?.Taglines?.first, !tagline.isEmpty {
            Text(tagline)
                .font(.caption.italic())
                .foregroundStyle(Theme.textDim)
        }

        if let overview = item?.Overview, !overview.isEmpty {
            Text(overview)
                .font(.subheadline)
                .foregroundStyle(Theme.textBody)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let genres = item?.Genres, !genres.isEmpty {
            Text(genres.prefix(5).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
    }

    /// Who made it, in the column beside the description.
    @ViewBuilder
    private var credits: some View {
        let cast = castNames(item)
        if !cast.isEmpty {
            stacked("Cast", cast)
        }
        let crew = crewNames(item)
        if !crew.isEmpty {
            stacked("Crew", crew)
        }
        if let studios = item?.Studios?.compactMap(\.Name).filter({ !$0.isEmpty }), !studios.isEmpty {
            stacked("Studio", Array(studios.prefix(2)))
        }
    }

    // MARK: A channel

    /// On a channel the headline is the programme, not the channel — the
    /// channel is the address you got there by, and it goes above it in the
    /// same place a series name does.
    ///
    /// Redrawn on a clock of its own rather than on the player's: what is on
    /// changes at the top of the hour whether or not anything about playback
    /// has moved, and the bar under it has to creep.
    private var liveText: some View {
        // The contents go in a stack of this view's own, explicitly leading.
        // A `TimelineView` hands its content to an implicit stack that centres
        // it, and the alignment of the column outside does not reach in — which
        // left the programme name, its airtime and its description all centred
        // in the middle of the panel.
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let airing = self.airing(at: context.date)
            let now = airing.now

            VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.danger, in: Capsule())
                eyebrow(channelLine)
            }

            Text(now?.title ?? item?.title ?? player.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)

            if let episode = now?.EpisodeTitle, !episode.isEmpty {
                Text(episode)
                    .font(.headline)
                    .foregroundStyle(Theme.textBody)
            }

            if let now, let start = now.programStart, let end = now.programEnd {
                airtime(start: start, end: end, at: context.date)
            }

            if let overview = now?.Overview ?? item?.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The only thing to say about a channel with no guide behind it —
            // an M3U playlist with no XMLTV, which is most of them.
            if airing.now == nil, airing.next == nil {
                Text("No guide data for this channel.")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The rest of the evening on this channel, in the column beside the
    /// programme that is on. On its own clock like the block beside it, since
    /// what is "next" changes on the hour and not on anything playback does.
    private var comingUp: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let later = schedule.filter { ($0.programStart ?? .distantPast) > context.date }
            VStack(alignment: .leading, spacing: 6) {
                if !later.isEmpty {
                    Text("COMING UP")
                        .font(.caption2.weight(.semibold))
                        .kerning(1.2)
                        .foregroundStyle(Theme.textDim)
                        .padding(.bottom, 2)
                    ForEach(Array(later.prefix(4).enumerated()), id: \.offset) { _, programme in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            // Wide enough for a twelve-hour clock: "12:00 PM"
                            // in a hundred points wraps onto a second line and
                            // takes the row's whole height with it.
                            Text(Format.programWindow(start: programme.programStart, end: nil) ?? "")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                                .frame(width: 140, alignment: .leading)
                            Text(programme.title)
                                .font(.caption)
                                .foregroundStyle(Theme.textBody)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Channel 12 · BBC One", with whichever halves exist.
    private var channelLine: String {
        var parts: [String] = []
        let name = item?.ChannelName ?? item?.title ?? player.title
        // Not where the name already carries it — plenty of playlists name a
        // channel after its number, and "Channel 102 · Channel 102" is what
        // that came out as.
        if let number = item?.ChannelNumber, !number.isEmpty, !name.contains(number) {
            parts.append("Channel \(number)")
        }
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// The window a programme airs in, how far through it is, and how much of
    /// it is left.
    private func airtime(start: Date, end: Date, at now: Date) -> some View {
        let total = end.timeIntervalSince(start)
        let done = total > 0 ? min(max(now.timeIntervalSince(start) / total, 0), 1) : 0
        let left = max(0, end.timeIntervalSince(now))
        let window = Format.programWindow(start: start, end: end) ?? ""

        return HStack(spacing: 14) {
            Text(window)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textDim)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(4, geo.size.width * done))
                }
            }
            .frame(width: 220, height: 5)
            Text("\(Int((left / 60).rounded())) min left")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: Pieces

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(1.2)
            .foregroundStyle(Theme.textDim)
            .lineLimit(1)
    }

    /// A heading with its lines under it — the shape the narrow column wants,
    /// where a label and its value side by side would leave the value a third
    /// of a line to fit in.
    private func stacked(_ label: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(Theme.textDim)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.caption)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
            }
        }
    }

    private func factsLine(_ item: BaseItem?) -> String? {
        guard let item else { return nil }
        var parts: [String] = []
        if let year = item.ProductionYear { parts.append(String(year)) }
        let runtime = Format.ticks(item.RunTimeTicks)
        if !runtime.isEmpty { parts.append(runtime) }
        if let rating = item.OfficialRating, !rating.isEmpty { parts.append(rating) }
        if let community = item.CommunityRating {
            parts.append("★ " + String(format: "%.1f", community))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Pedro Pascal as Joel" — the role is the half that answers the question
    /// people actually ask a cast list.
    private func castNames(_ item: BaseItem?) -> [String] {
        Array(
            (item?.People ?? [])
                .filter { ($0.type ?? "Actor") == "Actor" }
                .compactMap { person -> String? in
                    guard let name = person.Name, !name.isEmpty else { return nil }
                    guard let role = person.Role, !role.isEmpty else { return name }
                    return "\(name) as \(role)"
                }
                .prefix(4)
        )
    }

    private func crewNames(_ item: BaseItem?) -> [String] {
        let people = item?.People ?? []
        func names(_ job: String) -> [String] {
            people.filter { $0.type == job }.compactMap(\.Name).filter { !$0.isEmpty }
        }
        var out: [String] = []
        let directors = names("Director").prefix(2)
        if !directors.isEmpty { out.append("Directed by " + directors.joined(separator: ", ")) }
        let writers = names("Writer").prefix(2)
        if !writers.isEmpty { out.append("Written by " + writers.joined(separator: ", ")) }
        return out
    }

    // MARK: Loading

    /// What is on now and what is next, out of whatever schedule was found.
    private func airing(at now: Date) -> (now: BaseItem?, next: BaseItem?) {
        let list = schedule.isEmpty ? [currentProgramme].compactMap { $0 } : schedule
        let current = list.first {
            guard let start = $0.programStart, let end = $0.programEnd else { return false }
            return start <= now && now < end
        }
        let next = list.first { ($0.programStart ?? .distantPast) > now }
        return (current, next)
    }

    /// What a Jellyfin channel already carries about itself, for the moment
    /// before the guide has been asked — and for good, where there is no guide
    /// to ask.
    private var currentProgramme: BaseItem? {
        guard let program = item?.CurrentProgram else { return nil }
        var out = BaseItem()
        out.Id = program.Id ?? UUID().uuidString
        out.Name = program.Name
        out.Overview = program.Overview
        out.StartDate = program.StartDate
        out.EndDate = program.EndDate
        out.EpisodeTitle = program.EpisodeTitle
        return out
    }
}

// MARK: - Stream

/// What is actually arriving, in three columns: the file the server holds, the
/// stream this device is being sent, and where playback has got to.
///
/// Redraws on `player.position`, which moves every half second. That is the
/// only clock this tab has: none of the numbers below `streamFacts` is a
/// property anything writes, so observation has nothing to notice about them —
/// they are read out of the player item each time the body runs.
struct PlayerStreamPanel: View {
    let player: PlayerModel

    private var item: BaseItem? { player.infoItem }
    private var source: MediaSource? { item?.MediaSources?.first }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            if !fileRows.isEmpty {
                column("On the server", fileRows)
            }
            column("Coming down", streamRows)
            column("Right now", nowRows)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func column(_ heading: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading.uppercased())
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    Text(row.1)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: The file

    /// Empty for a channel and for a download: neither has a Jellyfin media
    /// source behind it, and a column of blanks says less than no column.
    private var fileRows: [(String, String)] {
        guard let source else { return [] }
        let video = source.streams.first { $0.type == "Video" }
        let audio = source.streams.first { $0.type == "Audio" }
        let subtitles = source.streams.filter { $0.type == "Subtitle" }
        var rows: [(String, String)] = []
        if let container = source.Container, !container.isEmpty {
            rows.append(("Container", container.uppercased()))
        }
        if let size = source.Size, size > 0 { rows.append(("Size", Format.bytes(size))) }
        if let video {
            var parts: [String] = []
            if let codec = video.Codec, !codec.isEmpty { parts.append(codec.uppercased()) }
            if let profile = video.Profile, !profile.isEmpty { parts.append(profile) }
            if let depth = video.BitDepth, depth > 0 { parts.append("\(depth)-bit") }
            if !parts.isEmpty { rows.append(("Video", parts.joined(separator: " · "))) }
            if let width = video.Width, let height = video.Height, width > 0, height > 0 {
                let name = Format.resolutionLabel(video).map { " (\($0))" } ?? ""
                rows.append(("Frame", "\(width)×\(height)\(name)"))
            }
            if let bitrate = video.BitRate, bitrate > 0 {
                rows.append(("Video rate", Self.mbps(Double(bitrate))))
            }
        }
        if let audio {
            var parts: [String] = []
            if let codec = audio.Codec, !codec.isEmpty { parts.append(codec.uppercased()) }
            if let channels = Format.channelLabel(audio) { parts.append(channels) }
            if let language = audio.Language, !language.isEmpty { parts.append(language.uppercased()) }
            if !parts.isEmpty { rows.append(("Audio", parts.joined(separator: " · "))) }
        }
        if !subtitles.isEmpty {
            rows.append(("Subtitles", "\(subtitles.count) track\(subtitles.count == 1 ? "" : "s")"))
        }
        return rows
    }

    // MARK: The stream

    private var streamRows: [(String, String)] {
        let facts = player.streamFacts
        var rows: [(String, String)] = []
        rows.append(("Delivery", delivery))
        if let resolution = facts.resolution { rows.append(("Arriving at", resolution)) }
        if let indicated = facts.indicatedBitrate {
            rows.append(("Variant", Self.mbps(indicated)))
        }
        if let observed = facts.observedBitrate {
            rows.append(("Throughput", Self.mbps(observed)))
        }
        if let stalls = facts.stalls { rows.append(("Stalls", String(stalls))) }
        if let dropped = facts.droppedFrames, dropped > 0 {
            rows.append(("Dropped", String(dropped)))
        }
        if let host = facts.host, !host.isEmpty { rows.append(("From", host)) }
        // The one line worth more than all the others when it is there: what
        // the stream turned out to contain, when the picture never came. See
        // `StreamDiagnosis`.
        if player.noVideoTrack { rows.append(("Picture", "None in this stream")) }
        return rows
    }

    private var delivery: String {
        if player.isLocal { return "Playing from this device" }
        if player.isExternal { return "Straight from the playlist" }
        if player.isTranscoding {
            return "Transcoding · " + Quality.shortLabel(for: player.currentBitrate)
        }
        return "Direct play"
    }

    // MARK: Where playback is

    private var nowRows: [(String, String)] {
        var rows: [(String, String)] = []
        if player.isLive {
            rows.append(("Position", "Live"))
        } else if player.duration > 0 {
            rows.append(("Position", "\(Format.clock(player.position)) / \(Format.clock(player.duration))"))
            rows.append(("Left", Format.ticks(Int64(max(0, player.duration - player.position) * 10_000_000))))
        }
        let ahead = player.buffered - player.position
        if ahead.isFinite, ahead > 0 {
            rows.append(("Buffered", "\(Int(ahead.rounded()))s ahead"))
        }
        if player.speed != 1 { rows.append(("Speed", PlayerModel.speedName(player.speed))) }
        // Only once it has been moved off zero: on a stream that is in sync
        // this is a row saying nothing, and it is the one row here that says
        // something about a setting rather than about the file.
        if player.appliedAudioDelayMilliseconds != 0 {
            let ms = player.appliedAudioDelayMilliseconds
            var value = "\(ms > 0 ? "+" : "")\(ms) ms"
            let matched = player.frameRateMatchMilliseconds
            if matched != 0 { value += " (\(matched > 0 ? "+" : "")\(matched) for frame rate)" }
            #if os(tvOS)
            // Which way it is being made matters to someone checking the
            // picture: a held picture is one that can be a frame late.
            if player.heldPicture != nil { value += " · picture held back" }
            #endif
            rows.append(("Audio delay", value))
        }
        if let index = player.selectedAudioTrack, index < player.audioTracks.count {
            rows.append(("Audio track", player.audioTracks[index].label))
        }
        if let index = player.selectedSubtitleTrack, index < player.subtitleTracks.count {
            rows.append(("Subtitles", player.subtitleTracks[index].label))
        } else if !player.subtitleTracks.isEmpty {
            rows.append(("Subtitles", "Off"))
        }
        if let chapter = player.chapterName(at: player.position) {
            rows.append(("Chapter", chapter))
        }
        if let minutes = player.sleepMinutesRemaining {
            rows.append(("Sleep timer", "\(minutes) min left"))
        }
        if player.autoplayCancelled, !player.isLive {
            rows.append(("After this", "Stop"))
        }
        return rows
    }

    private static func mbps(_ bitsPerSecond: Double) -> String {
        let mbps = bitsPerSecond / 1_000_000
        return mbps >= 10
            ? String(format: "%.0f Mbps", mbps)
            : String(format: "%.1f Mbps", mbps)
    }
}

#endif
