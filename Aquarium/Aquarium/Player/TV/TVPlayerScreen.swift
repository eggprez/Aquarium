//  The Apple TV player screen: mpv's picture, and the app's own controls over
//  it. Presented full screen by `RootView` and the title screen whenever
//  `PlayerModel.isActive`.
//
//  The remote works the way it does in Apple's own apps:
//
//  - click the centre to pause or play, and to bring up the bar;
//  - click the left or right edge to go back or forward ten seconds;
//  - swipe left or right to scrub, with a thumbnail of where you'll land,
//    then click to jump there or press Menu to go back. Paused, a short
//    swipe starts it; playing, only a long, flat one does, so a swipe meant
//    for something else doesn't. After a jump, Menu returns to where the
//    playhead was, for as long as the bar is up;
//  - each click left or right shows how far it has gone, run together;
//  - swipe down for the panel (Info, Audio, Subtitles, Quality, Speed, Sync);
//    Menu, or a swipe up from its tabs, puts it away again;
//  - on a channel, click the top or bottom edge to change channel;
//  - Menu steps back: the panel away, out of a scrub, then the bar away,
//    then out.
//
//  While the bar is up with nothing else open, `RemoteInput` holds focus and
//  reads the remote itself — see there for why. A panel or the error card
//  takes focus from it, and SwiftUI's focus engine drives those as usual.

#if os(tvOS)

import SwiftUI

struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player

    @State private var controlsVisible = true
    @State private var panel: PlayerTab?
    /// Whether focus is on the panel's tabs, and whether it was when the
    /// finger now on the remote went down.
    @State private var panelTabsFocused = false
    @State private var swipeBeganOnTabs = false
    /// Where the scrubber is, while scrubbing.
    @State private var scrub: Double?
    /// Where the scrubber was when the current swipe began.
    @State private var scrubAnchor: Double = 0
    /// How far the current swipe had gone when the scrub began: the scrub
    /// moves from there, not from where the finger went down.
    @State private var scrubStartX: Double = 0
    /// Where the playhead was when the scrub began.
    @State private var scrubOrigin: Double = 0
    /// Where the playhead was before the last scrub jumped it: Menu goes back
    /// there while the bar is up.
    @State private var returnPoint: Double?
    /// The clicks left or right in the current run, in seconds, and the task
    /// that clears the count once they stop.
    @State private var skipTotal = 0
    @State private var skipTask: Task<Void, Never>?
    @State private var panning = false
    @State private var hideTask: Task<Void, Never>?
    @State private var trickplay = TrickplayStore()
    @State private var schedule = ChannelSchedule()
    @State private var artwork = InfoArtwork()

    /// How long the bar stays after the last touch, while playing.
    private static let hideAfter: Duration = .seconds(5)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoHost(view: player.videoView)
                .ignoresSafeArea()
            // The last title's final frame, still on the view: covered until
            // this one's first frame replaces it.
            if player.pictureIsStale {
                Color.black.ignoresSafeArea()
            }

            RemoteInput(isEnabled: remoteInCharge, panelOpen: panel != nil, onEvent: handle)
                .ignoresSafeArea()

            if showsBar {
                VStack {
                    Spacer()
                    TVTransportBar(trickplay: trickplay, schedule: schedule, scrub: scrub,
                                   returnPoint: returnPoint, timelineOnly: panel != nil)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if player.errorMessage == nil, panel == nil, scrub == nil {
                cues
            }

            if skipTotal != 0 {
                SkipBadge(seconds: skipTotal)
                    .frame(maxWidth: .infinity, alignment: skipTotal > 0 ? .trailing : .leading)
                    .padding(.horizontal, 160)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            if panel != nil {
                VStack {
                    TVPlayerPanel(tab: $panel, tabsFocused: $panelTabsFocused, schedule: schedule, artwork: artwork)
                    Spacer()
                }
                // Past tvOS's overscan margins, the way the system's own
                // player panels go: the panel's insides keep their distance
                // from the edge, the glass needn't.
                .ignoresSafeArea()
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if (player.isBuffering || player.isOpening), player.errorMessage == nil, scrub == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(34)
                    .playerGlass(cornerRadius: 30)
            }

            if let message = player.errorMessage {
                ErrorCard(message: message)
            }
        }
        .animation(.easeOut(duration: 0.25), value: showsBar)
        .animation(.easeOut(duration: 0.3), value: panel)
        .animation(.spring(duration: 0.25), value: skipTotal)
        .onPlayPauseCommand { player.togglePlayPause() }
        .onChange(of: player.trickplay, initial: true) { _, info in trickplay.reset(info) }
        .task(id: player.currentChannel?.Id) { await schedule.load(for: player.currentChannel) }
        .task(id: InfoArtwork.url(for: player)) { await artwork.load(InfoArtwork.url(for: player)) }
        .onChange(of: player.isPaused) { _, _ in scheduleHide() }
        .onChange(of: showsBar, initial: true) { _, raised in
            player.raiseSubtitles(raised)
            if !raised { returnPoint = nil }
        }
        .onChange(of: panel) { _, open in
            if open == nil { scheduleHide() } else { hideTask?.cancel() }
        }
        .onChange(of: player.item?.Id) { _, _ in
            scrub = nil
            returnPoint = nil
            showControls()
        }
        .onAppear { showControls() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: RemoteDebugHook.openTab)) {
            panel = $0.object as? PlayerTab
        }
        #endif
    }

    /// The remote goes to `RemoteInput` unless something focusable needs it.
    private var remoteInCharge: Bool {
        panel == nil && player.errorMessage == nil
    }

    private var showsBar: Bool {
        (controlsVisible || scrub != nil || player.isPaused || panel != nil) && player.errorMessage == nil
    }

    // MARK: - Skip and Up Next

    /// The prompts that answer a click while nothing else is up: skip the
    /// intro or the credits, or start the next episode.
    @ViewBuilder
    private var cues: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if player.shouldShowUpNext, let next = player.upNext {
                    UpNextCard(next: next, secondsLeft: player.secondsRemaining)
                } else if let segment = player.activeSegment {
                    CuePill(title: segment.isOutro ? "Skip Credits" : "Skip Intro")
                }
            }
        }
        .padding(.horizontal, 90)
        .padding(.bottom, showsBar ? 330 : 90)
        .animation(.easeOut(duration: 0.25), value: showsBar)
        .transition(.opacity)
    }

    // MARK: - The remote

    private func handle(_ event: RemoteEvent) {
        switch event {
        case .touchDown:
            showControls()

        case .select:
            if let scrub {
                commit(scrub)
            } else if player.shouldShowUpNext {
                Task { await player.playNextNow() }
            } else if player.activeSegment != nil {
                player.skipSegment()
            } else {
                player.togglePlayPause()
                showControls()
            }

        case .playPause:
            if let scrub {
                commit(scrub)
                player.resume()
            } else {
                player.togglePlayPause()
                showControls()
            }

        case .menu:
            if panel != nil {
                panel = nil
            } else if player.errorMessage != nil {
                player.stop(reason: "error card")
            } else if scrub != nil {
                scrub = nil
                showControls()
            } else if let point = returnPoint {
                // Undo the jump: back to where the playhead was before it.
                returnPoint = nil
                player.seek(to: point)
                showControls()
            } else if player.shouldShowUpNext {
                player.cancelAutoplay()
            } else if controlsVisible, !player.isPaused {
                hideControls()
            } else {
                player.stop(reason: "menu")
            }

        case .arrow(let direction):
            arrow(direction)

        case .panelTouchDown:
            swipeBeganOnTabs = panelTabsFocused

        case .panelSwipeUp:
            // From the tabs only: from the choices below them, a swipe up is
            // the focus engine's, back to the tabs.
            if panel != nil, swipeBeganOnTabs { panel = nil }

        case .panChanged(let translation, _):
            if !panning {
                panning = true
                scrubAnchor = scrub ?? player.position
                scrubStartX = 0
            }
            showControls()
            if scrub == nil {
                // Paused, a short swipe that is mostly sideways. Playing, a
                // long one that is plainly sideways: a finger resting on the
                // remote, or a swipe down that drifts, shouldn't move the film.
                let x = abs(translation.x), y = abs(translation.y)
                let starts = player.isPaused
                    ? x > 24 && x > y
                    : x > Self.playingScrubDistance && x > y * 2.5
                guard starts, canScrub else { return }
                scrub = player.position
                scrubAnchor = player.position
                scrubOrigin = player.position
                scrubStartX = Double(translation.x)
            }
            scrub = clamp(scrubAnchor + (Double(translation.x) - scrubStartX) * secondsPerPoint)

        case .panEnded(let translation, _):
            panning = false
            guard scrub == nil else {
                // The scrubber stays where the swipe left it, waiting for a
                // click; another swipe carries on from there.
                scrubAnchor = scrub ?? player.position
                return
            }
            let vertical = abs(translation.y) > abs(translation.x) * 1.3
            if vertical, translation.y > 60 {
                panel = openingTab
            } else if vertical, translation.y < -60 {
                hideControls()
            }
        }
    }

    private func arrow(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            let delta: Double = direction == .left ? -10 : 10
            if let scrub {
                self.scrub = clamp(scrub + delta)
                scrubAnchor = self.scrub ?? scrubAnchor
            } else if canScrub {
                player.seek(by: delta)
                countSkip(Int(delta))
            }
            showControls()
        case .up:
            if player.isLive { player.switchChannel(by: 1) }
            showControls()
        case .down:
            if player.isLive {
                player.switchChannel(by: -1)
                showControls()
            } else {
                panel = openingTab
            }
        @unknown default:
            break
        }
    }

    /// The tab a swipe or press down opens on. The sync test's picture says
    /// a swipe down adjusts the sync, so there it is Sync rather than Info.
    private var openingTab: PlayerTab { player.isSyncTest ? .sync : .info }

    private var canScrub: Bool { !player.isLive && player.duration > 0 && !player.isOpening }

    /// A full swipe across the touch surface moves a quarter of the item,
    /// never less than ninety seconds.
    private var secondsPerPoint: Double { max(player.duration / 4, 90) / 1000 }

    private func clamp(_ seconds: Double) -> Double {
        min(max(0, seconds), max(0, player.duration - 1))
    }

    private func commit(_ seconds: Double) {
        if abs(seconds - scrubOrigin) > 1 { returnPoint = scrubOrigin }
        player.seek(to: seconds)
        scrub = nil
        showControls()
    }

    /// How far a swipe must go, in the remote's points (about a thousand
    /// across), to start a scrub while playing.
    private static let playingScrubDistance: CGFloat = 170

    /// Add a click to the run on screen: clicks the same way add up, a click
    /// the other way starts again, and the count goes a moment after the
    /// last.
    private func countSkip(_ seconds: Int) {
        skipTotal = (skipTotal == 0 || (skipTotal > 0) == (seconds > 0)) ? skipTotal + seconds : seconds
        skipTask?.cancel()
        skipTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            skipTotal = 0
        }
    }

    // MARK: - The bar coming and going

    private func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    private func hideControls() {
        hideTask?.cancel()
        controlsVisible = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !player.isPaused, panel == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: Self.hideAfter)
            guard !Task.isCancelled, scrub == nil, panel == nil, !player.isPaused else { return }
            controlsVisible = false
        }
    }
}

// MARK: - Pieces

/// Puts the model's video view on screen. The view outlives the screen — mpv
/// was created against its layer — so it is moved into each new container
/// rather than made anew.
private struct VideoHost: UIViewRepresentable {
    let view: MPVVideoView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

/// Skip Intro / Skip Credits: drawn focused, because a click is what it
/// answers to.
private struct CuePill: View {
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "forward.end.fill")
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 34)
        .padding(.vertical, 20)
        .background(Capsule().fill(Theme.accent))
        .shadow(color: Theme.accent.opacity(0.5), radius: 20, y: 8)
    }
}

/// The next episode, counting down to itself.
private struct UpNextCard: View {
    let next: BaseItem
    let secondsLeft: Double

    var body: some View {
        HStack(spacing: 26) {
            RemoteImage(url: Artwork.still(for: next, width: 480))
                .frame(width: 280, height: 158)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("UP NEXT IN \(Int(secondsLeft.rounded(.up)))")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.link)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                if let label = next.episodeLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Text("Click to play now · Menu to stop here")
                    .font(.caption)
                    .foregroundStyle(Theme.textBody)
                    .padding(.top, 4)
            }
            .frame(width: 420, alignment: .leading)
        }
        .padding(26)
        .playerGlass(cornerRadius: 30)
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 3)
        )
    }
}

private struct ErrorCard: View {
    @Environment(PlayerModel.self) private var player
    let message: String

    private enum Choice { case retry, close }
    /// Taken on appearing: focus was with `RemoteInput`, which lets go of it
    /// when the card comes up but can't say where it should go.
    @FocusState private var focused: Choice?

    var body: some View {
        VStack(spacing: 28) {
            Text("Couldn't play this")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textBody)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            HStack(spacing: 30) {
                if player.canRetry {
                    ChoiceCard(title: "Try again", width: 240) { Task { await player.retry() } }
                        .focused($focused, equals: .retry)
                }
                ChoiceCard(title: "Close", width: 240) { player.stop(reason: "error card") }
                    .focused($focused, equals: .close)
            }
        }
        .padding(60)
        .playerGlass(cornerRadius: 40)
        .focusSection()
        .onAppear { focused = player.canRetry ? .retry : .close }
        .onExitCommand { player.stop(reason: "error card") }
    }
}

#endif
