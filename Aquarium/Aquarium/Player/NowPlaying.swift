//  The lock screen, Control Centre, CarPlay, the Touch Bar, a paired remote and
//  the media keys on a Mac keyboard — all one API, and the counterpart to
//  mpris.rs on Linux.

import AVFoundation
import Foundation
import MediaPlayer

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    private weak var model: PlayerModel?
    private var wired = false
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?

    private init() {}

    /// Whether a remote command is the music player's to answer.
    ///
    /// The two players take turns — starting one stops the other — so at any
    /// moment at most one of them is up, and this says which. The video
    /// player wins a tie it should never be in.
    private var music: MusicPlayer { .shared }
    private var musicHasTheStage: Bool {
        music.isActive && !(model?.isActive ?? false)
    }

    /// Previous and next mean different things to the two players, and the
    /// lock screen shows only the buttons that are enabled: a film gets a
    /// "next episode" and no "previous", a song gets both.
    func refreshCommandAvailability() {
        let centre = MPRemoteCommandCenter.shared()
        let onStage = musicHasTheStage
        centre.previousTrackCommand.isEnabled = onStage
        #if os(tvOS)
        let videoHasNext = model?.upNext != nil
        #else
        let videoHasNext = model?.upNext != nil || model?.upNextLocalId != nil || model?.isShuffling == true
        #endif
        centre.nextTrackCommand.isEnabled = onStage || videoHasNext
        centre.skipForwardCommand.isEnabled = !onStage || music.current?.isAudiobook == true
        centre.skipBackwardCommand.isEnabled = !onStage || music.current?.isAudiobook == true
        centre.changeShuffleModeCommand.isEnabled = onStage
        centre.changeRepeatModeCommand.isEnabled = onStage
        // Thumbs, for a song: what a watch, a car or a pair of headphones
        // with the controls for it shows.
        let song = onStage ? music.current.flatMap { $0.isSong ? $0 : nil } : nil
        let thumb = song.flatMap { MusicTaste.shared.thumb(for: $0) }
        centre.likeCommand.isEnabled = song != nil
        centre.dislikeCommand.isEnabled = song != nil
        centre.likeCommand.isActive = thumb == 1
        centre.dislikeCommand.isActive = thumb == -1
        if onStage {
            centre.changeShuffleModeCommand.currentShuffleType = music.isShuffled ? .items : .off
            centre.changeRepeatModeCommand.currentRepeatType = {
                switch music.repeatMode {
                case .off: .off
                case .all: .all
                case .one: .one
                }
            }()
        }
    }

    func attach(to model: PlayerModel) {
        self.model = model
        guard !wired else { return }
        wired = true

        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            if self.musicHasTheStage { self.music.resume(); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.resume()
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            if self.musicHasTheStage { self.music.pause(); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.pause()
            return .success
        }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            if self.musicHasTheStage { self.music.togglePlayPause(); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.togglePlayPause()
            return .success
        }
        centre.stopCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            if self.musicHasTheStage { self.music.stop(); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.stop()
            return .success
        }

        // ±30 s, the same jumps the app's own buttons make and the same ones
        // the Linux player bar offered.
        centre.skipForwardCommand.preferredIntervals = [30]
        centre.skipBackwardCommand.preferredIntervals = [30]
        centre.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .noSuchContent }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            if self.musicHasTheStage { self.music.seek(by: interval); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.seek(by: interval)
            return .success
        }
        centre.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .noSuchContent }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            if self.musicHasTheStage { self.music.seek(by: -interval); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.seek(by: -interval)
            return .success
        }

        centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .noSuchContent }
            if self.musicHasTheStage { self.music.seek(to: event.positionTime); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.seek(to: event.positionTime)
            return .success
        }

        // The shell's "next track" button means the next episode here, which is
        // exactly what it meant over MPRIS — and the next song when it is the
        // music player on the lock screen.
        centre.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            if self.musicHasTheStage { self.music.skipNext(); return .success }
            guard let model = self.model else { return .noSuchContent }
            Task { await model.playNextNow() }
            return .success
        }
        centre.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.musicHasTheStage else { return .noSuchContent }
            self.music.skipPrevious()
            return .success
        }
        centre.likeCommand.localizedTitle = "Thumbs Up"
        centre.likeCommand.localizedShortTitle = "Like"
        centre.dislikeCommand.localizedTitle = "Thumbs Down"
        centre.dislikeCommand.localizedShortTitle = "Dislike"
        centre.likeCommand.addTarget { [weak self] event in
            guard let self, self.musicHasTheStage, let event = event as? MPFeedbackCommandEvent else { return .noSuchContent }
            self.music.setThumb(event.isNegative ? nil : 1)
            self.refreshCommandAvailability()
            return .success
        }
        centre.dislikeCommand.addTarget { [weak self] event in
            guard let self, self.musicHasTheStage, let event = event as? MPFeedbackCommandEvent else { return .noSuchContent }
            self.music.setThumb(event.isNegative ? nil : -1)
            self.refreshCommandAvailability()
            return .success
        }
        centre.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self, self.musicHasTheStage,
                  let event = event as? MPChangeShuffleModeCommandEvent else { return .noSuchContent }
            if (event.shuffleType == .off) == self.music.isShuffled { self.music.toggleShuffle() }
            return .success
        }
        centre.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self, self.musicHasTheStage,
                  let event = event as? MPChangeRepeatModeCommandEvent else { return .noSuchContent }
            switch event.repeatType {
            case .off: self.music.repeatMode = .off
            case .one: self.music.repeatMode = .one
            case .all: self.music.repeatMode = .all
            @unknown default: break
            }
            return .success
        }

        centre.changePlaybackRateCommand.supportedPlaybackRates =
            PlayerModel.speeds.map { NSNumber(value: $0) }
        centre.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackRateCommandEvent
            else { return .noSuchContent }
            if self.musicHasTheStage { self.music.speed = Double(event.playbackRate); return .success }
            guard let model = self.model else { return .noSuchContent }
            model.speed = Double(event.playbackRate)
            return .success
        }
    }

    /// Push the whole card: title, show, duration, artwork.
    func update(from model: PlayerModel) {
        refreshCommandAvailability()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: model.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.position,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPaused ? 0.0 : model.speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: model.speed,
            MPNowPlayingInfoPropertyIsLiveStream: model.isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if !model.subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = model.subtitle
            info[MPMediaItemPropertyAlbumTitle] = model.subtitle
        }
        if model.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = model.duration
        }
        // The picture already on the card is kept only while it is still this
        // item's; a new item with no artwork, or one whose artwork won't load,
        // must not go on showing the last one's.
        let artworkChanged = model.artworkURL != artworkURL
        if !artworkChanged,
           let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = model.isPaused ? .paused : .playing

        if artworkChanged {
            artworkURL = model.artworkURL
            loadArtwork(model.artworkURL)
        }
    }

    /// Cheap per-tick update — the position only.
    func updateElapsed(_ position: Double, rate: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            if let model { update(from: model) }
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if let model, model.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = model.duration
            info[MPMediaItemPropertyTitle] = model.title
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // The Mac reads the state from here rather than from the rate, and set
        // only in `update(from:)` it said "playing" through every pause.
        MPNowPlayingInfoCenter.default().playbackState = rate == 0 ? .paused : .playing
    }

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task {
            guard let image = await ImageLoader.shared.load(url), !Task.isCancelled,
                  artworkURL == url else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func clear() {
        artworkTask?.cancel()
        artworkURL = nil
        // The video player coming down while a song is already up — which is
        // the order things happen in when a song *replaces* a film — must not
        // wipe the song's card.
        guard !music.isActive else {
            refreshCommandAvailability()
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
