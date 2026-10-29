//  The phone's end of the watch's remote.
//
//  In its "iPhone" mode the watch shows what this phone is playing and
//  drives it. This keeps the watch told — a `PhonePlaybackState` whenever
//  something worth knowing changes, while the watch app is in reach — and
//  does what the watch asks of the player. Only the music player and the
//  video player are watched; nothing here starts playback.
//
//  Position isn't sent every second. The state carries where the player was
//  and when, and the watch adds the time since; a seek, a pause or a track
//  change is what earns a message, with one every so often while playing
//  to keep the two clocks honest. See Shared/WatchSyncTypes.swift.

#if os(iOS)

import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
final class WatchRemote {
    static let shared = WatchRemote()

    /// The last state sent, less its cover and clock: what a change is
    /// measured against.
    private var lastSent: PhonePlaybackState?
    /// Whether the last state went to a watch that was in reach. A watch
    /// coming back into reach gets a fresh one whether or not anything moved.
    private var lastReachable = false
    /// The item whose cover the watch has been sent.
    private var artworkSentFor: String?
    private var artwork: (itemId: String, data: Data)?
    private var artworkTask: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var volumeWatcher: NSKeyValueObservation?
    private var started = false

    /// How far the drawn clock may drift from the player's before a state
    /// goes just to correct it.
    private static let positionSlack: TimeInterval = 2
    private static let settle: TimeInterval = 0.3
    private static let heartbeatEvery: TimeInterval = 20

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        volumeWatcher = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.changed() }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatEvery))
                guard let self else { return }
                if WatchLink.shared.isReachable, self.snapshot()?.isPlaying == true { self.send(force: true) }
            }
        }
        watch()
        watchClock()
    }

    /// Re-armed on every change: `withObservationTracking` fires once.
    ///
    /// What is playing and the clock are watched apart. The clock moves twice
    /// a second, and read under the same observation as everything else —
    /// `snapshot()` reads it — every tick restarted the settle below and built
    /// a whole state, Up Next copied out of the queue included, to find
    /// nothing worth sending. A tick now costs a comparison with the clock the
    /// watch is already drawing; see `clockMoved`.
    private func watch() {
        withObservationTracking {
            observeState()
            _ = WatchLink.shared.isReachable
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.changed()
                self?.watch()
            }
        }
    }

    /// Everything `snapshot()` reads except the clock and what follows from
    /// it, for `watch` to observe.
    private func observeState() {
        let music = MusicPlayer.shared
        _ = music.isActive
        if let item = music.current {
            _ = item
            _ = music.queueTitle
            _ = music.isPlaying
            _ = music.duration
            _ = music.speed
            _ = music.hasNext
            _ = music.upNextCount
            _ = music.chapters
            return
        }
        let video = PlayerModel.shared
        _ = video.isActive
        _ = video.item?.Id
        _ = video.title
        _ = video.subtitle
        _ = video.isPaused
        _ = video.duration
        _ = video.speed
    }

    private func watchClock() {
        withObservationTracking {
            _ = MusicPlayer.shared.position
            _ = PlayerModel.shared.position
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.clockMoved()
                self?.watchClock()
            }
        }
    }

    /// A tick. Worth a state only when the clock the watch is drawing from
    /// the last one has drifted — a seek on the phone — or when the clock has
    /// carried the book into another chapter, or past the point where
    /// Previous restarts the track instead of going back.
    private func clockMoved() {
        guard settling == nil, WatchLink.shared.isReachable, let last = lastSent else { return }
        let music = MusicPlayer.shared
        let position: Double
        if music.isActive, music.current != nil {
            position = music.position
            if music.currentChapter?.Name != last.chapter || music.hasPrevious != last.hasPrevious {
                return changed()
            }
        } else {
            position = PlayerModel.shared.position
        }
        let expected = last.isPlaying
            ? last.position + Date().timeIntervalSince(last.at) * last.speed
            : last.position
        if abs(expected - position) > Self.positionSlack { changed() }
    }

    /// Something moved. Sent once things have been still for a moment: play
    /// is several changes in half a second.
    private func changed() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settle))
            guard let self, !Task.isCancelled else { return }
            self.settling = nil
            self.send()
        }
    }

    // MARK: - What is playing

    /// The player as it stands, without the cover.
    func snapshot() -> PhonePlaybackState? {
        let volume = Double(AVAudioSession.sharedInstance().outputVolume)
        let music = MusicPlayer.shared
        if music.isActive, let item = music.current {
            var parts: [String] = []
            if !item.artistLine.isEmpty { parts.append(item.artistLine) }
            if !item.isAudiobook, let album = item.Album, !album.isEmpty { parts.append(album) }
            if parts.isEmpty, let title = music.queueTitle { parts.append(title) }
            return PhonePlaybackState(
                itemId: item.Id,
                title: (item.isAudiobook ? item.Album : nil) ?? item.Name ?? "",
                subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
                isAudiobook: item.isAudiobook,
                isPlaying: music.isPlaying,
                position: music.position,
                duration: music.duration,
                speed: music.speed,
                hasNext: music.hasNext,
                hasPrevious: music.hasPrevious,
                upNextCount: music.upNextCount,
                chapter: music.currentChapter?.Name,
                volume: volume
            )
        }
        let video = PlayerModel.shared
        if video.isActive, let item = video.item {
            return PhonePlaybackState(
                itemId: item.Id,
                title: video.title,
                subtitle: video.subtitle.isEmpty ? nil : video.subtitle,
                isVideo: true,
                isPlaying: !video.isPaused,
                position: video.position,
                duration: video.duration,
                speed: video.speed,
                volume: volume
            )
        }
        return nil
    }

    /// The state with its cover, for the watch's own ask. Waits a moment for
    /// a cover not yet fetched, and goes without it rather than hold the
    /// reply past the watch's patience.
    func state(withArtwork: Bool) async -> PhonePlaybackState? {
        guard var state = snapshot() else { return nil }
        guard withArtwork else { return state }
        if artwork?.itemId != state.itemId {
            artworkTask?.cancel()
            artworkTask = nil
            let itemId = state.itemId
            let load = Task { await self.loadArtwork(itemId: itemId) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await load.value }
                group.addTask { try? await Task.sleep(for: .seconds(4)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        if let artwork, artwork.itemId == state.itemId {
            state.artwork = artwork.data
            artworkSentFor = state.itemId
        }
        return state
    }

    // MARK: - Telling the watch

    /// Send the state if it says something the last one didn't — or
    /// whatever it says, when `force`.
    func send(force: Bool = false) {
        let reachable = WatchLink.shared.isReachable
        defer { lastReachable = reachable }
        guard reachable else { return }
        let state = snapshot()
        let fresh = force || !lastReachable || Self.differs(state, from: lastSent)
        guard fresh else { return }
        guard var state else {
            lastSent = nil
            WatchLink.shared.sendLive(.phonePlayback(nil))
            return
        }
        if artworkSentFor != state.itemId {
            if let artwork, artwork.itemId == state.itemId {
                state.artwork = artwork.data
                artworkSentFor = state.itemId
            } else {
                fetchArtwork(for: state.itemId)
            }
        }
        lastSent = state.withoutArtwork
        WatchLink.shared.sendLive(.phonePlayback(state))
    }

    private static func differs(_ now: PhonePlaybackState?, from last: PhonePlaybackState?) -> Bool {
        guard let now, let last else { return (now == nil) != (last == nil) }
        var a = now.withoutArtwork, b = last
        a.position = 0; b.position = 0
        a.volume = nil; b.volume = nil
        if a != b { return true }
        if let v = now.volume, let w = last.volume, abs(v - w) > 0.01 { return true }
        if (now.volume == nil) != (last.volume == nil) { return true }
        // The clock the watch is drawing from the last state, against the
        // player's own.
        let expected = last.isPlaying
            ? last.position + Date().timeIntervalSince(last.at) * last.speed
            : last.position
        return abs(expected - now.position) > positionSlack
    }

    // MARK: - The cover

    private func fetchArtwork(for itemId: String) {
        guard artworkTask == nil || artwork?.itemId != itemId else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            await self.loadArtwork(itemId: itemId)
            guard !Task.isCancelled else { return }
            self.artworkTask = nil
            // The cover arrived after the state went: send it along now.
            if self.artwork?.itemId == itemId, self.artworkSentFor != itemId { self.send(force: true) }
        }
    }

    /// A small JPEG of the item's cover, kept for the next send.
    private func loadArtwork(itemId: String) async {
        if artwork?.itemId == itemId { return }
        guard let url = artworkURL(for: itemId), let image = await ImageLoader.shared.load(url) else { return }
        let side: CGFloat = 128
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let scale = max(side / max(1, image.size.width), side / max(1, image.size.height))
            let w = image.size.width * scale, h = image.size.height * scale
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let data = small.jpegData(compressionQuality: 0.6), !Task.isCancelled else { return }
        artwork = (itemId, data)
    }

    private func artworkURL(for itemId: String) -> URL? {
        let music = MusicPlayer.shared
        if music.isActive, let item = music.current, item.Id == itemId { return MusicArt.url(item, width: 200) }
        let video = PlayerModel.shared
        if video.isActive, let item = video.item, item.Id == itemId { return Artwork.url(item, width: 200) }
        return nil
    }

    // MARK: - What the watch asks

    func handle(_ command: RemoteCommand) {
        let music = MusicPlayer.shared
        if music.isActive {
            switch command {
            case .play: music.resume()
            case .pause: music.pause()
            case .togglePlayPause: music.togglePlayPause()
            case .next: music.skipNext()
            case .previous: music.skipPrevious()
            case .seekTo(let seconds): music.seek(to: seconds)
            case .seekBy(let delta): music.seek(by: delta)
            case .setSpeed(let speed): music.speed = speed
            }
        } else {
            let video = PlayerModel.shared
            guard video.isActive else { return }
            switch command {
            case .play: video.resume()
            case .pause: video.pause()
            case .togglePlayPause: video.togglePlayPause()
            case .next, .previous: break
            case .seekTo(let seconds): video.seek(to: seconds)
            case .seekBy(let delta): video.seek(by: delta)
            case .setSpeed(let speed): video.speed = speed
            }
        }
        changed()
    }
}

#endif
