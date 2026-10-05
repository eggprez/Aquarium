//  What is playing: the bar above the tab bar, and the screen it opens.
//
//  The bar is the one piece of the music player that is on every screen of
//  the app, so it is small and says three things — the cover, the song, and
//  whether it is playing — with Play/Pause and Next under a thumb. The screen
//  behind it is the whole instrument: where the music is coming from across
//  the top, the cover big, a scrubber, one row of transport with shuffle and
//  repeat at its ends and Play in the accent at its middle, volume, and a
//  foot of lyrics, AirPlay, the sleep timer and the queue. The queue is a
//  card that comes up over all of it, leaving the top in view, and goes back
//  down with a swipe — the player under it doesn't move.

import AVKit
import MediaPlayer
import SwiftUI

#if os(iOS)

// MARK: - Mini player

/// The line along the bottom of the mini player.
///
/// Its own view so that it is the only thing reading the position, which
/// changes twice a second: read in the bar's body, it redrew the whole bar —
/// the material, the artwork, the shadows — on every screen of the app for as
/// long as anything played. Scaled rather than measured, which draws the
/// same line without a geometry pass.
private struct MiniPlayerProgress: View {
    @Environment(MusicPlayer.self) private var music

    var body: some View {
        if music.duration > 0 {
            Rectangle().fill(Theme.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .scaleEffect(x: min(1, max(0, music.position / music.duration)), y: 1, anchor: .leading)
        }
    }
}

struct MiniPlayerBar: View {
    @Environment(MusicPlayer.self) private var music
    @State private var presenter = NowPlayingPresentation.shared

    var body: some View {
        if music.isActive, let song = music.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    MusicArtwork(item: song, width: 200, radius: 6, placeholderSymbol: song.isAudiobook ? "book" : "music.note")
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(Theme.text)
                        Text(secondLine(song))
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: 8)
                    Button { music.togglePlayPause() } label: {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.title2)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                    Button {
                        if song.isAudiobook { music.seek(by: 30) } else { music.skipNext() }
                    } label: {
                        Image(systemName: song.isAudiobook ? "goforward.30" : "forward.end.fill")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .disabled(!song.isAudiobook && !music.hasNext)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .background(Theme.raised.opacity(0.85))
                .overlay(alignment: .bottom) { MiniPlayerProgress() }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border.opacity(0.7), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .contentShape(Rectangle())
                .onTapGesture { presenter.isPresented = true }
                .gesture(
                    DragGesture(minimumDistance: 20).onEnded { value in
                        if value.translation.height < -30 { presenter.isPresented = true }
                    }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: music.isActive)
        }
    }

    private func secondLine(_ song: BaseItem) -> String {
        if song.isAudiobook, let chapter = music.currentChapter?.Name, !chapter.isEmpty { return chapter }
        let artist = song.artistLine
        return artist.isEmpty ? (song.Album ?? "") : artist
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @Environment(MusicPlayer.self) private var music
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var scrubbing: Double?

    /// What sits where the cover normally is.
    private enum Panel { case art, lyrics }
    private var panel: Panel { showLyrics ? .lyrics : .art }

    var body: some View {
        ZStack {
            background
            if let song = music.current {
                VStack(spacing: 0) {
                    topBar(song)
                        .padding(.bottom, 8)
                    switch panel {
                    case .lyrics:
                        LyricsView()
                            .transition(.opacity)
                    case .art:
                        Spacer(minLength: 12)
                        artwork(song)
                        Spacer(minLength: 16)
                    }
                    titleBlock(song)
                        .padding(.top, panel == .art ? 0 : 6)
                    scrubber
                        .padding(.top, 14)
                    transport(song)
                        .padding(.top, 10)
                    volume
                        .padding(.top, 16)
                    bottomBar(song)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .animation(.easeInOut(duration: 0.25), value: showLyrics)
                // The player is still there under the card, just out of reach.
                .accessibilityHidden(showQueue)
            }
            if showQueue {
                // The strip of player left showing: a tap on it puts the card
                // away, as a tap above a sheet does.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { setQueue(false) }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                QueueCard { setQueue(false) }
                    .padding(.top, Self.queueCardTop)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        // Dragging the card down is the card's, not the whole screen's.
        .interactiveDismissDisabled(showQueue)
        .preferredColorScheme(.dark)
        .modifier(SongInfoHost(overNowPlaying: true))
    }

    /// Where the queue card's top edge sits: just under the top bar, so where
    /// this is playing from stays in view above it.
    private static let queueCardTop: CGFloat = 62

    private func setQueue(_ shown: Bool) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { showQueue = shown }
    }

    /// The cover, blurred to nothing and darkened: the colour of the record
    /// as the colour of the room.
    private var background: some View {
        ZStack {
            Theme.background
            if let song = music.current {
                RemoteImage(url: MusicArt.url(song, width: 200), blurHash: MusicArt.hash(song))
                    .blur(radius: 60)
                    .scaleEffect(1.4)
                    .opacity(0.55)
            }
            // Down into the app's own near-black rather than plain black, so
            // the foot of the screen is the same room as every other page.
            LinearGradient(
                colors: [.black.opacity(0.2), Color(hex: 0x0E0E14).opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    /// Where this is playing from, with the way out at one end and the menu
    /// at the other.
    private func topBar(_ song: BaseItem) -> some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            VStack(spacing: 1) {
                Text(song.isAudiobook ? "Listening to" : "Playing from")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.55))
                Text(music.queueTitle ?? song.Album ?? "Your Library")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            Menu {
                MusicItemMenu(item: song)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
        }
    }

    private func artwork(_ song: BaseItem) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            MusicArtwork(item: song, width: 1000, radius: 12, placeholderSymbol: song.isAudiobook ? "book" : "music.note")
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                // Paused, the cover fades back a little rather than moving.
                .saturation(music.isPlaying ? 1 : 0.55)
                .opacity(music.isPlaying ? 1 : 0.8)
                .animation(.easeInOut(duration: 0.3), value: music.isPlaying)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func titleBlock(_ song: BaseItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                // Two lines before it truncates. The three buttons beside it
                // take nearly half the row, and on one line most titles with
                // more than three words in them ended in an ellipsis — "I Hate
                // Myself fo…" — on every phone, the largest included. The
                // artwork above gives up the height; it is sized to what is
                // left.
                Text(song.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                Button {
                    goToArtist(song)
                } label: {
                    Text(subtitle(song))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .disabled(song.isAudiobook)
            }
            Spacer()
            if music.canThumb {
                thumbButton(value: -1)
                thumbButton(value: 1)
            }
            Button {
                Task { await toggleFavorite(song) }
            } label: {
                Image(systemName: song.userData.isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(song.userData.isFavorite ? Theme.accent : .white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Advice to the station playing, and only there: down skips the song
    /// and steers away from it, up steers towards it. Both are forgotten when
    /// the station ends. Tapped again, either is taken back.
    private func thumbButton(value: Int) -> some View {
        let on = music.thumb == value
        let symbol = value > 0 ? "hand.thumbsup" : "hand.thumbsdown"
        return Button {
            music.setThumb(on ? nil : value)
            guard !on else { return }
            app.toast(value > 0 ? "More like this" : "Less like this", tone: .ok)
        } label: {
            Image(systemName: on ? symbol + ".fill" : symbol)
                .font(.title3)
                .foregroundStyle(on ? Theme.accent : .white.opacity(0.8))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value > 0 ? "Thumbs Up" : "Thumbs Down")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var sleepOptions: some View {
        if music.sleepDeadline != nil {
            Section(sleepLabel) {
                Button("Turn off", role: .destructive) { music.cancelSleepTimer() }
            }
        }
        ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
            Button("\(minutes) minutes") { music.setSleepTimer(minutes: minutes) }
        }
    }

    private var sleepLabel: String {
        guard let deadline = music.sleepDeadline else { return "Sleep Timer" }
        let minutes = max(1, Int(deadline.timeIntervalSinceNow / 60))
        return "Sleep in \(minutes) min"
    }

    private var speedMenu: some View {
        Menu {
            ForEach(MusicPlayer.speeds, id: \.self) { rate in
                Button {
                    music.speed = rate
                } label: {
                    if abs(music.speed - rate) < 0.001 {
                        Label(PlayerModel.speedName(rate), systemImage: "checkmark")
                    } else {
                        Text(PlayerModel.speedName(rate))
                    }
                }
            }
        } label: {
            Text(abs(music.speed - 1) < 0.001 ? "1×" : PlayerModel.speedName(music.speed))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(abs(music.speed - 1) < 0.001 ? .white.opacity(0.7) : Theme.link)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Speed")
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? music.position },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(1, music.duration),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        music.seek(to: target)
                        scrubbing = nil
                    }
                }
            )
            .tint(.white.opacity(0.9))
            HStack {
                Text(Format.clock(scrubbing ?? music.position))
                Spacer()
                if let chapter = music.currentChapter?.Name, music.current?.isAudiobook == true {
                    Text(chapter).lineLimit(1)
                    Spacer()
                }
                Text("-" + Format.clock(max(0, music.duration - (scrubbing ?? music.position))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func transport(_ song: BaseItem) -> some View {
        HStack(spacing: 0) {
            // A book has no order to shuffle; its speed goes where shuffle is.
            if song.isAudiobook {
                speedMenu
            } else {
                toggle("shuffle", isOn: music.isShuffled, label: "Shuffle") { music.toggleShuffle() }
            }
            Spacer(minLength: 0)
            Button {
                // The glyph says fifteen seconds, so it is fifteen seconds;
                // chapters are skipped from the foot of the screen.
                if song.isAudiobook { music.seek(by: -15) } else { music.skipPrevious() }
            } label: {
                Image(systemName: song.isAudiobook ? "gobackward.15" : "backward.end.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 60, height: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button { music.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Theme.accentStrong)
                    if music.isBuffering, !music.isPlaying {
                        ProgressView().tint(.white).scaleEffect(1.2)
                    } else {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.system(size: 30, weight: .bold))
                    }
                }
                .frame(width: 74, height: 74)
                .shadow(color: Theme.accentStrong.opacity(0.45), radius: 16, y: 6)
                .contentShape(Circle())
            }
            .buttonStyle(PosterButtonStyle())
            .foregroundStyle(.white)
            .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
            Spacer(minLength: 0)
            Button {
                if song.isAudiobook { music.seek(by: 30) } else { music.skipNext() }
            } label: {
                Image(systemName: song.isAudiobook ? "goforward.30" : "forward.end.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 60, height: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(!song.isAudiobook && !music.hasNext)
            .opacity(!song.isAudiobook && !music.hasNext ? 0.4 : 1)
            Spacer(minLength: 0)
            toggle(
                music.repeatMode == .one ? "repeat.1" : "repeat",
                isOn: music.repeatMode != .off, label: "Repeat"
            ) { music.repeatMode = music.repeatMode.next }
        }
    }

    /// One of the small switches around the transport and along the foot:
    /// lit in the accent, on a faint pill, while it is on.
    private func toggle(_ symbol: String, isOn: Bool, dimmed: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Theme.link : .white.opacity(dimmed ? 0.35 : 0.7))
                .frame(width: 44, height: 40)
                .background(isOn ? .white.opacity(0.14) : .clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption)
            SystemVolumeSlider()
                .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    private func bottomBar(_ song: BaseItem) -> some View {
        // A book has no lyrics and no queue behind it; with chapters, the two
        // ends of the foot step through them instead.
        let stepsChapters = song.isAudiobook && !music.chapters.isEmpty
        return HStack {
            if stepsChapters {
                toggle("backward.end", isOn: false, label: "Previous Chapter") { music.skipChapter(-1) }
            } else {
                toggle("text.quote", isOn: showLyrics, dimmed: song.HasLyrics == false, label: "Lyrics") {
                    withAnimation { showLyrics.toggle() }
                }
                .disabled(song.isAudiobook)
                .opacity(song.isAudiobook ? 0.3 : 1)
            }
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 40)
            Spacer()
            Menu {
                sleepOptions
            } label: {
                Image(systemName: music.sleepDeadline != nil ? "moon.zzz.fill" : "moon.zzz")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(music.sleepDeadline != nil ? Theme.link : .white.opacity(0.7))
                    .frame(width: 44, height: 40)
                    .background(music.sleepDeadline != nil ? .white.opacity(0.14) : .clear, in: Capsule())
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(sleepLabel)
            Spacer()
            if stepsChapters {
                toggle("forward.end", isOn: false, label: "Next Chapter") { music.skipChapter(1) }
            } else {
                toggle("list.bullet", isOn: showQueue, label: "Queue") { setQueue(!showQueue) }
            }
        }
    }

    private func subtitle(_ song: BaseItem) -> String {
        if song.isAudiobook { return song.AlbumArtist ?? song.artistLine }
        let artist = song.artistLine
        // The album is left out when the top of the screen already says it.
        if let album = song.Album, !album.isEmpty, !artist.isEmpty, album != music.queueTitle {
            return "\(artist) — \(album)"
        }
        return artist.isEmpty ? (song.Album ?? "") : artist
    }

    private func goToArtist(_ song: BaseItem) {
        guard let id = (song.ArtistItems?.first ?? song.AlbumArtists?.first)?.Id else { return }
        dismiss()
        app.show(.music)
        app.push(.music(.artist(id)))
    }

    private func toggleFavorite(_ song: BaseItem) async {
        let next = !song.userData.isFavorite
        do {
            // Kept on this device and sent later when there is no server.
            _ = try await MusicFavorites.set(song, favorite: next)
            music.markFavorite(song.Id, next)
            ItemMutations.shared.changed()
        } catch {
            app.toast("Couldn't update favorites", tone: .error)
        }
    }
}

// MARK: - Queue

/// Up Next as a card over the player. It follows a finger dragged down on
/// its top — the grabber and the heading, not the list, whose rows drag to
/// reorder — and goes away past a third of the way or on a flick.
private struct QueueCard: View {
    var close: () -> Void
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)
                        .accessibilityLabel("Close Up Next")
                        .accessibilityAddTraits(.isButton)
                    QueueHeader()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                .contentShape(Rectangle())
                .gesture(grip(height: geo.size.height))
                QueueList()
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                let shape = UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                shape.fill(Color(hex: 0x16161E).opacity(0.94))
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(.white.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 20, y: -4)
                    .ignoresSafeArea(edges: .bottom)
            }
            .offset(y: drag)
        }
        .accessibilityAction(.escape, close)
    }

    private func grip(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                // Up past where it rests, it gives a little and no more.
                let y = value.translation.height
                drag = y > 0 ? y : y / 6
            }
            .onEnded { value in
                if value.translation.height > height / 3 || value.predictedEndTranslation.height > height / 2 {
                    close()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                }
            }
    }
}

/// What Up Next is playing from, and the way to empty it.
private struct QueueHeader: View {
    @Environment(MusicPlayer.self) private var music

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up Next")
                    .font(.headline)
                    .foregroundStyle(.white)
                if let title = music.queueTitle {
                    Text("From \(title)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if music.station != nil, !music.isShuffled {
                    Label("Changes with what you play, skip and rate", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Theme.link)
                }
            }
            Spacer()
            if music.hasUpNext {
                Button("Clear") { music.clearUpNext() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .buttonStyle(.plain)
            }
        }
    }
}

/// The songs still to come: tap one to go to it, drag to reorder, swipe
/// to take one out.
private struct QueueList: View {
    @Environment(MusicPlayer.self) private var music

    var body: some View {
        if !music.hasUpNext {
            VStack(spacing: 6) {
                Image(systemName: "music.note.list").font(.title).foregroundStyle(.white.opacity(0.4))
                Text(music.repeatMode == .all ? "The queue starts over from the top." : "Nothing queued after this.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(music.upNext) { entry in
                    HStack(spacing: 12) {
                        MusicArtwork(item: entry.item, width: 160, radius: 5)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.title).font(.subheadline).lineLimit(1).foregroundStyle(.white)
                            Text(entry.item.artistLine).font(.caption).lineLimit(1).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { music.skip(to: entry) }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.1))
                    // Room on the left for the delete control the list
                    // shows while it is editable: at zero it sits against
                    // the cover.
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 0))
                }
                .onDelete { offsets in
                    // One copy of the list, taken before anything is
                    // removed — not a fresh copy per row deleted.
                    let listed = music.upNext
                    for i in offsets.sorted(by: >) where listed.indices.contains(i) {
                        music.remove(listed[i])
                    }
                }
                .onMove { from, to in music.moveUpNext(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
    }
}

// MARK: - System controls

/// The system's own volume slider, which is the only one that moves the
/// device's volume. Drawn without its route button — that is the AirPlay
/// button in the row below.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsVolumeSlider = true
        view.tintColor = UIColor.white.withAlphaComponent(0.85)
        return view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.7)
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

#endif
