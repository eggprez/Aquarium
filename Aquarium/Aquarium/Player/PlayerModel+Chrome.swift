//  What the shared chrome asks of the model on iPhone, iPad and Mac, where
//  the Apple TV player already had an answer: the channel being watched and
//  the lineup around it, which tabs a stream has something to show in, and
//  the chapter marks for the timeline. The Apple TV's versions are in
//  `PlayerModel+PlaybackTV.swift`; phase 5 of the overhaul folds the two.

#if !os(tvOS)

import Foundation

extension PlayerModel {
    // MARK: - Live

    var currentChannel: BaseItem? {
        guard isLive else { return nil }
        return externalChannel?.item ?? item
    }

    var channelLineup: [BaseItem] { LiveTVStore.shared.channels }

    func switchChannel(by offset: Int) {
        let lineup = channelLineup
        guard let current = currentChannel, !lineup.isEmpty,
              let index = lineup.firstIndex(where: { $0.Id == current.Id }) else { return }
        let next = lineup[((index + offset) % lineup.count + lineup.count) % lineup.count]
        playChannel(next)
    }

    func playChannel(_ channel: BaseItem) {
        guard channel.Id != currentChannel?.Id else { return }
        if let raw = channel.ExternalStreamURL, let url = URL(string: raw) {
            playExternal(
                title: channel.title,
                subtitle: channel.ChannelNumber.map { "Channel \($0)" } ?? "",
                artworkURL: Artwork.channelLogo(channel, width: 600),
                streamURL: url, channel: channel)
        } else {
            Task { await play(item: channel, options: StreamOptions(resume: false, live: true)) }
        }
    }

    // MARK: - What the chrome may offer

    /// Whether the quality rungs mean anything for this stream: only a
    /// Jellyfin item being streamed, not a download or a playlist channel.
    var offersQuality: Bool { item != nil && !isLocal && !isExternal && !isLive }

    /// Why the quality rungs are not offered, when they aren't.
    var qualityUnavailableReason: String? {
        if isLocal { return "This is a download: it plays the file as it was saved." }
        if isExternal { return "This channel comes straight from its playlist; the server isn't encoding it." }
        if isLive { return "A live channel plays as the tuner sends it." }
        return nil
    }

    /// Where the chapters start, for the timeline's ticks.
    var chapterStarts: [Double] { chapters.map(\.start) }

    /// The tabs this stream has something to show in.
    var panelTabs: [PlayerTab] {
        var out: [PlayerTab] = [.info]
        if isLive, channelLineup.count > 1 { out.append(.channels) }
        out.append(.audio)
        out.append(.subtitles)
        if !isExternal, !isLive, !isLocal { out.append(.quality) }
        if !isLive { out.append(.speed) }
        out.append(.sync)
        out.append(.picture)
        return out
    }

    /// Why the sound cannot be moved against the picture on this stream,
    /// or nil when it can.
    var audioDelayUnavailableReason: String? {
        if !isActive || isOpening { return "Once the stream has opened." }
        if streamCarriesDelay { return nil }
        let fix = canDelayAudioBySwitching
            ? " The mpv engine moves the sound on any stream — switch for this title?"
            : ""
        if isExternal { return "This channel comes straight from its playlist as a live stream, and the sound of a live stream can't be shifted on Apple's engine." + fix }
        if isLive { return "A live channel's sound can't be shifted on Apple's engine." + fix }
        return "Apple's engine can only shift the sound of a file the server sends untouched. This stream is being transcoded, so the picture and sound arrive already mixed." + fix
    }

    /// Why the picture controls are not live on this stream, or nil when
    /// they are. The row under it offers the switch.
    var pictureUnavailableReason: String? {
        if engine?.capabilities.contains(.pictureAdjust) == true { return nil }
        if !isActive || isOpening { return "Once the stream has opened." }
        if canSwitchEngine(to: .mpv) { return "Picture controls need the mpv engine — switch for this title?" }
        return "Picture controls need the mpv engine. " + (engineSwitchUnavailableReason(to: .mpv) ?? "")
    }

    /// How many titles wait behind this one: the hand-made queue, or the one
    /// Up Next the series offers.
    var upNextCount: Int {
        if !queue.isEmpty { return queue.count }
        return upNext != nil || upNextLocalId != nil ? 1 : 0
    }
}

#endif
