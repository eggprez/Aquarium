//  The pages of the player's panel. The Apple TV's swipe-down panel shows
//  them as a row of tabs; on an iPhone, an iPad or a Mac each is a page of
//  its own, opened by its own button, and the tracks, speed, quality and sync
//  are cards or not offered, never pages. Which of them a stream offers is
//  `PlayerModel.panelTabs` (a channel has no Quality, a film no Channels).

import Foundation

enum PlayerTab: String, Hashable, CaseIterable, Identifiable {
    case info, channels, audio, subtitles, quality, speed, sync
    /// SharePlay and SyncPlay, on the Apple TV, whose panel is where its
    /// choices live. Elsewhere they are rows in the "…" card.
    case together

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .channels: "Channels"
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        case .quality: "Quality"
        case .speed: "Speed"
        case .sync: "Sync"
        case .together: "Watch Together"
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .channels: "tv"
        case .audio: "speaker.wave.2"
        case .subtitles: "captions.bubble"
        case .quality: "slider.horizontal.3"
        case .speed: "gauge.with.dots.needle.67percent"
        case .sync: "waveform.path.ecg"
        case .together: "person.2"
        }
    }
}
