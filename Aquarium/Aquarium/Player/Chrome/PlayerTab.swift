//  The tabs of the player's panel, on every platform. The Apple TV's swipe-down
//  panel and the iPhone's sheet show the same set; which of them a stream
//  offers is each panel's decision (a channel has no Quality, a film no
//  Channels).

import Foundation

enum PlayerTab: String, Hashable, CaseIterable, Identifiable {
    case info, channels, audio, subtitles, quality, speed, sync
    /// Brightness, contrast, saturation, gamma, zoom and aspect: the mpv
    /// engine's, over the live picture.
    case picture

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
        case .picture: "Picture"
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
        case .picture: "camera.filters"
        }
    }
}
