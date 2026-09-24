//  The player screen.
//
//  The video and its transport come from AVPlayerViewController, which is worth
//  far more than a hand-built bar would be: it brings Picture in Picture,
//  AirPlay, the system scrubber with its own frame previews, the subtitle and
//  audio menus, and every gesture and remote behaviour people already know.
//
//  Layered on top of it is the part that is Aquarium's rather than the system's
//  — Skip intro, the Up Next card, the quality rungs and the episode queue (and,
//  everywhere but tvOS, a sleep timer). On tvOS those go into the transport
//  bar's own menu and
//  contextual actions, because a floating overlay can't be reached with a
//  remote while the system controls have focus. There they are one button:
//  everything that is a setting hangs off a single gear, and the two things
//  that are one press — Skip intro, Play next — are contextual actions instead.
//  A row of five buttons beside AVKit's own is not a transport bar anybody can
//  read from a sofa. On iOS the standing controls go
//  into AVKit's controls too, as subviews beside its own pills — see
//  `TransportBarExtras`, which owns them outright, including where they go when
//  AVKit's bar can't be found. Nothing of ours is drawn over the picture there
//  but the prompts you act on once, Skip intro and Up Next.
//
//  macOS is the exception: AppKit's floating controls are a panel that follows
//  the pointer, with no band to put anything in, so the quality and extras
//  buttons stay in this app's own row there.

import AVKit
import Observation
import OSLog
import SwiftUI

struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app

    #if !os(tvOS)
    /// Bumped by Skip intro / Skip credits, purely so the haptic has something
    /// to fire on — the segment going away isn't it, since it also goes away by
    /// being played through.
    @State private var skips = 0
    #endif

    /// Acknowledged once and not shown again for this stream — audio keeps
    /// playing regardless, so this is an explanation, not a fault to keep
    /// nagging about.
    @State private var dismissedNoVideoNotice = false

    /// The stop this screen owes when it goes away, held back a moment so a
    /// disappearance that turns out to be a flicker can call it off — see
    /// `onDisappear` below.
    @State private var pendingStop: Task<Void, Never>?

    #if os(tvOS)
    /// Whether the metadata ribbon is pulled down. Owned here and handed to the
    /// coordinator, which is where the remote's swipes and the transport bar's
    /// menu arrive — see `PlayerInfoRibbon`.
    @State private var showsRibbon = false
    /// What the ribbon shows, fetched as the stream starts so the band comes
    /// down whole — see `PlayerInfoStore`.
    @State private var info = PlayerInfoStore()
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(tvOS)
            VideoSurface(showsRibbon: $showsRibbon)
                .ignoresSafeArea()
            #else
            VideoSurface()
                .ignoresSafeArea()
            #endif

            // While a stream is opening at a position — a resume, or the switch
            // to another quality — there is nothing on screen but the first
            // frame, and the wait can run to tens of seconds while a transcode
            // catches up to the offset. Say what is happening rather than
            // leaving a still picture that reads as a player that has died.
            //
            // Not on tvOS. AVPlayerViewController draws its own loading spinner
            // there, in the middle of the screen, and this card landed on top of
            // it — two things spinning at once, one of them the system's.
            #if !os(tvOS)
            if player.isBuffering, player.position < 1 || player.isOpening {
                loadingCard
            }
            #endif

            if let error = player.errorMessage {
                errorCard(error)
            } else if player.noVideoTrack, !dismissedNoVideoNotice {
                VStack {
                    noVideoBanner
                    Spacer()
                }
            }

            #if !os(tvOS)
            overlay
            #endif

            bitrateBadge

            #if os(tvOS)
            // The band that moves is the ribbon and nothing else.
            //
            // The whole `VStack` — ribbon *plus* the `Spacer` under it — used
            // to be what carried the transition, and a stack holding a spacer
            // is as tall as the screen. `.move(edge: .top)` moves a view by its
            // own height, so what was being animated was a screen-height slab:
            // coming down, the ribbon was already in place while the animation
            // still had most of its journey to run, and going up it left the
            // screen in the first fraction of it and read as a snap. Kept
            // outside the condition, the stack is only there to hold the ribbon
            // against the top edge, and the thing that comes and goes is the
            // ribbon at its own size.
            VStack(spacing: 0) {
                if showsRibbon {
                    PlayerInfoRibbon(player: player, info: info)
                        .transition(.move(edge: .top))
                }
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            #endif
        }
        #if os(tvOS)
        .animation(.easeOut(duration: 0.28), value: showsRibbon)
        // Restarted for each thing that plays, and cancelled with the screen.
        .task(id: player.infoItem?.Id ?? player.title) { await info.load(for: player) }
        // A stream ending or being closed takes the ribbon with it; otherwise
        // it is still down over the next thing that starts.
        .onChange(of: player.title) { _, _ in showsRibbon = false }
        // No `onExitCommand` here, deliberately. There used to be one, to put
        // the ribbon away on Menu; but SwiftUI takes the press for that
        // command before AVKit's responder chain sees it, and AVKit is what
        // puts the transport bar away on the first press — so with the bar up,
        // Menu did nothing to the bar and closed the player instead. Left
        // alone, the press reaches AVKit: it hides the bar if the bar is up,
        // and otherwise asks the coordinator whether it may dismiss, which is
        // where the ribbon and the close are handled. See
        // `playerViewControllerShouldDismiss` and `PlayerModel.handleExit`.
        #endif
        #if !os(tvOS)
        // Skipping a segment and changing rung are the two things that happen
        // here with nothing under the finger to acknowledge them: the picture
        // jumps somewhere else, or it carries on looking identical.
        .sensoryFeedback(.impact(weight: .medium), trigger: skips)
        .sensoryFeedback(trigger: player.currentBitrate) { was, _ in
            was == nil ? nil : .selection
        }
        #endif
        .onAppear { pendingStop?.cancel(); pendingStop = nil }
        .onDisappear {
            // The screen going away has to stop playback too, or a stream keeps
            // running (and keeps a transcode alive) behind the UI: the cover's
            // own binding covers every dismissal SwiftUI knows about, and this
            // covers the rest — signing out, the shell being rebuilt under it.
            //
            // A moment later rather than now. `onDisappear` also fires for a
            // view that is about to come straight back — SwiftUI rebuilding the
            // hierarchy, something presented full-screen over it and removed
            // again — and stopping on the spot for one of those is a channel
            // that opened, went black, and dropped back to the guide with
            // nothing wrong. If the screen is back within the moment, `onAppear`
            // calls this off. And it stops only the stream it saw: a channel
            // picked from the guide inside that moment is a new generation,
            // and this must not be the thing that tears it down.
            guard player.isActive else { return }
            let generation = player.streamGeneration
            pendingStop?.cancel()
            pendingStop = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                player.stop(reason: "player screen disappeared", ifStill: generation)
            }
        }
        // The shell is portrait on a phone; a film is the reason the phone gets
        // turned. See `OrientationLock`.
        .allowsLandscape()
    }

    /// The stream changing bitrate on its own, said where it can't be missed
    /// and gone again in a few seconds. Top right on a television, clear of the
    /// transport bar at the bottom and of the info ribbon, which it steps aside
    /// for; top centre elsewhere, between AVKit's corner buttons. Never takes a
    /// touch or focus — it is something to read, not something to press.
    private var bitrateBadge: some View {
        VStack {
            HStack {
                #if !os(tvOS)
                Spacer(minLength: 0)
                #endif
                Spacer(minLength: 0)
                if let notice = player.bitrateNotice, player.isActive, !ribbonIsDown {
                    BitrateBadge(notice: notice)
                        .id(notice.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                #if !os(tvOS)
                Spacer(minLength: 0)
                #endif
            }
            Spacer(minLength: 0)
        }
        #if os(tvOS)
        .padding(.top, 40)
        .padding(.trailing, 60)
        #else
        .padding(.top, 12)
        #endif
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: player.bitrateNotice?.id)
    }

    private var ribbonIsDown: Bool {
        #if os(tvOS)
        showsRibbon
        #else
        false
        #endif
    }

    #if !os(tvOS)
    /// One line, and out of the middle of the screen.
    ///
    /// It used to be a card in the dead centre — spinner over title over
    /// quality — which is exactly where AVKit puts play/pause and the two skip
    /// buttons. Touch the screen while a stream was still opening and the title
    /// ran straight across all three, with this spinner sitting on the pause
    /// glyph. Raised clear of them and flattened to a capsule, it shares the
    /// screen with the controls instead of colliding with them; the offset
    /// leaves it under the top row of buttons on the shortest phone sideways.
    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            Text(player.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let bitrate = player.currentBitrate {
                Text(Quality.shortLabel(for: bitrate))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .offset(y: -92)
        .allowsHitTesting(false)
    }
    #endif

    private func errorCard(_ error: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.warn)
            Text("This didn't play")
                .font(.headline)
                .foregroundStyle(.white)
            // What the stream turned out to contain, when it could be read,
            // in place of AVFoundation's own message — which for an
            // undecodable codec says only that the operation could not be
            // completed. See `StreamDiagnosis`.
            Text(player.noVideoDetail ?? error)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                // Offered first, and on a live channel it is the only one of
                // these that does anything: a stream that died is a session on
                // the far end that has to be asked for again, and it is what
                // the two failures an IPTV channel actually produces — an item
                // that failed outright, and one the stall watchdog gave up on
                // — both want.
                if player.canRetry {
                    Button("Try again") {
                        Task { await player.retry() }
                    }
                    .appButtonStyle(prominent: true)
                }
                // Only for a stream the server is choosing a bitrate for.
                // `switchQuality` needs a Jellyfin item; on a channel that came
                // from a playlist there is nothing to switch, and this was a
                // button that quietly did nothing at all.
                if player.item != nil {
                    Button("Try a smaller stream") {
                        Task { await player.switchQuality(to: 4_000_000) }
                    }
                    .appButtonStyle(prominent: !player.canRetry)
                }
                Button("Close") { player.stop(reason: "error card closed") }
                    .appButtonStyle()
            }
        }
        .padding(28)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        #if !os(tvOS)
        // AVKit's own transport chrome (the top icon row, the bottom
        // scrubber/transport bar) lives in a native view AVKit manages
        // itself — this app never re-toggles `showsPlaybackControls` to
        // avoid AVKit tearing its controls down and rebuilding them hidden
        // (see the note on that property). So instead of fighting that
        // native layer for touches, the card sits away from both of AVKit's
        // bands — clear of the top icon row and well clear of the bottom
        // transport bar — and is explicitly raised above everything else in
        // this ZStack, so "Try a smaller stream" and "Close" can never end
        // up hit-testing to whatever AVKit has underneath them.
        .zIndex(2)
        .padding(.bottom, 120)
        .frame(maxHeight: .infinity, alignment: .center)
        #endif
        #if os(tvOS)
        // A focus group of its own, so the remote lands on these buttons
        // rather than on the player view underneath, which is focusable and
        // covers the whole screen.
        .focusSection()
        #endif
    }

    /// Sits at the top of the picture rather than centre stage like
    /// `errorCard`: nothing has actually failed, the stream is playing, there
    /// is just no picture in it to show.
    private var noVideoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("No picture in this stream")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                // Naming the likely cause rather than stopping at "not
                // supported", because this one is fixable and not here: Apple's
                // players decode H.265 in HLS only when the segments are fMP4,
                // never inside MPEG-TS, and won't touch MPEG-2 video at all. A
                // re-streamer left on its defaults is the usual way to end up
                // sending exactly that. The container is called out separately
                // because changing it is the obvious thing to try and the one
                // that changes nothing on its own — the codec is what decides.
                // The stream itself is asked what it contains, and when it
                // answers, its answer is what goes here — see
                // `StreamDiagnosis`. The sentence below is the fallback for a
                // stream that couldn't be read, and stays deliberately general
                // because at that point nothing specific is actually known.
                Text(player.noVideoDetail ?? "Its video is in a format this device can't decode. H.264 plays from anything; H.265 only from fMP4 segments, never from MPEG-TS; MPEG-2 not at all. Changing the container alone won't help — set the server sending this channel to transcode video to H.264.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                dismissedNoVideoNotice = true
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Overlay (iOS, iPadOS, macOS)

    #if !os(tvOS)
    @ViewBuilder
    private var overlay: some View {
        // What is drawn over the picture is the prompts you act on once — Skip
        // intro, Up Next. They sit at the leading edge of the band just above
        // the system transport bar, and come and go with the moment they belong
        // to rather than with the controls.
        //
        // The standing controls — quality, and the extras menu — are not here on
        // iOS any more, in any circumstance. `TransportBarExtras` puts them
        // inside AVKit's own controls, and puts them somewhere sensible itself
        // when it can't; a second copy drawn here is how the player came to show
        // two quality menus at once, one in the bar and one floating over the
        // bottom corner. macOS keeps the row, because AppKit's floating controls
        // are a panel with nothing to hang a button off.
        VStack(alignment: .leading, spacing: 12) {
            Spacer()

            if player.shouldShowUpNext, let next = player.upNextTitle {
                upNextCard(next)
            }
            if player.activeSegment != nil {
                Button {
                    skips += 1
                    player.skipSegment()
                } label: {
                    Label(
                        player.activeSegment?.isOutro == true ? "Skip credits" : "Skip intro",
                        systemImage: "forward.end.fill"
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            #if os(macOS)
            // Quality keeps a button of its own showing the rung it is on: it is
            // the one people reach for, and it was two taps deep in an anonymous
            // "…" before.
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if !player.isLocal, !player.isLive {
                    qualityButton
                }
                extrasMenu
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        // Clear of the system transport bar.
        .padding(.bottom, 110)
        .animation(.easeOut(duration: 0.2), value: player.activeSegment)
        .animation(.easeOut(duration: 0.2), value: player.shouldShowUpNext)
    }

    private func upNextCard(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.isStartingNext
                 ? "Starting…"
                 : "Up next · in \(Int(player.secondsRemaining.rounded()))s")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button("Play now") { Task { await player.playNextNow() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStrong)
                    .controlSize(.small)
                Button("Not now") { player.cancelAutoplay() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    #if os(macOS)
    /// Quality, as its own control beside the system's. The label carries the
    /// rung so the button answers the question without being opened.
    private var qualityButton: some View {
        Menu {
            ForEach(Quality.choices) { choice in
                Button {
                    Task { await player.switchQuality(to: choice.maxBitrate) }
                } label: {
                    Label(
                        choice.label,
                        systemImage: choice.maxBitrate == player.currentBitrate ? "checkmark" : ""
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.footnote.weight(.semibold))
                Text(Quality.shortLabel(for: player.currentBitrate))
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.4), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Stream quality")
    }

    /// Submenus rather than one flat list: spelled out in full this is more than
    /// a dozen rows, and a popup that tall covers the picture and reaches the
    /// system's own controls no matter which corner it is anchored to.
    ///
    /// Speed isn't among them: it is handed to AVKit through `speeds`, so it
    /// appears in the system's own speed control on iOS and macOS alike.
    private var extrasMenu: some View {
        Menu {
            Menu {
                if let left = player.sleepMinutesRemaining {
                    Button("Cancel sleep timer (\(left) min left)") { player.cancelSleepTimer() }
                } else {
                    ForEach([15, 30, 60, 90], id: \.self) { minutes in
                        Button("Stop in \(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                    }
                }
                Button(player.autoplayCancelled ? "Keep playing after this" : "Stop after this episode") {
                    if player.autoplayCancelled { player.resumeAutoplay() } else { player.cancelAutoplay() }
                }
            } label: {
                Label("Sleep", systemImage: "moon")
            }

            Button {
                Preferences.shared.fillScreen.toggle()
            } label: {
                Label(
                    Preferences.shared.fillScreen ? "Fit to screen" : "Fill the screen",
                    systemImage: "rectangle.arrowtriangle.2.outward"
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                // Sized to match the quality capsule beside it rather than to
                // the glyph, so the two sit as one pair of controls.
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.4), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More playback options")
    }
    #endif
    #endif
}

// MARK: - The AVKit surface

#if os(macOS)
struct VideoSurface: NSViewRepresentable {
    @Environment(PlayerModel.self) private var player

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
        // Speed belongs to AVKit's own control, on the Mac as on the phone.
        view.speeds = PlayerModel.speeds.map {
            AVPlaybackSpeed(rate: Float($0), localizedName: PlayerModel.speedName($0))
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.videoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
    }
}
#else
struct VideoSurface: UIViewControllerRepresentable {
    @Environment(PlayerModel.self) private var player

    #if os(tvOS)
    /// Written by the remote's swipes and by the transport bar's own menu, both
    /// of which arrive in the coordinator rather than in SwiftUI.
    @Binding var showsRibbon: Bool
    #endif

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player.player
        controller.videoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        #if os(iOS)
        // Speed is the one extra with an API of its own: handed over, it appears
        // in AVKit's speed control rather than in a menu of this app's, and
        // reports what was chosen back through the player's `defaultRate`.
        // tvOS keeps its own entry, which the remote can reach from the
        // transport bar menu alongside everything else.
        controller.speeds = PlayerModel.speeds.map {
            AVPlaybackSpeed(rate: Float($0), localizedName: PlayerModel.speedName($0))
        }
        // Set once here and never assigned again. Assigning it tears AVKit's
        // controls down and builds them back *hidden*, waiting for a tap that
        // has already happened — so driving the bar from this property meant
        // that after the first idle timeout it never came back, and this app's
        // own buttons were the only thing left on screen. AVKit shows and hides
        // its bar; the coordinator below watches it and reports.
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = false
        context.coordinator.bindExtras(to: player)
        context.coordinator.installExtras()
        #else
        controller.showsPlaybackControls = true
        // On a television the extras have to live where the remote can reach
        // them: inside the transport bar's own menu, and as the contextual
        // actions that appear when the picture is swiped down.
        context.coordinator.player = player
        context.coordinator.ribbon = $showsRibbon
        context.coordinator.installSettingsButton(player: player)
        context.coordinator.rebuildContextualActions(player: player)
        context.coordinator.installRibbonGestures(on: controller)
        context.coordinator.installMenuHandling(on: controller)
        // Where a held-back picture is drawn — see `DelayedVideoRenderer`.
        // The overlay sits between the video layer and AVKit's controls, so
        // the transport bar and the ribbon go on top of it as they do the
        // ordinary picture.
        player.heldPictureHost = { [weak controller] in controller?.contentOverlayView }
        context.coordinator.hostHeldPicture(player: player)
        #endif
        context.coordinator.applyLiveChrome(for: player, to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.videoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
        #if os(iOS)
        // Both no-op once bound and installed; they pick the controls back up if
        // AVKit has rebuilt them (rotation, Picture in Picture coming back).
        context.coordinator.bindExtras(to: player)
        context.coordinator.installExtras()
        #endif
        #if os(tvOS)
        context.coordinator.player = player
        context.coordinator.ribbon = $showsRibbon
        context.coordinator.installSettingsButton(player: player)
        context.coordinator.rebuildContextualActions(player: player)
        context.coordinator.hostHeldPicture(player: player)
        #endif
        context.coordinator.applyLiveChrome(for: player, to: controller)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        weak var controller: AVPlayerViewController?
        private var lastSignature = ""

        /// What `applyLiveChrome` last set, so the property below is only
        /// ever assigned when the answer changes. Assigning it makes AVKit
        /// rebuild its controls — the same hazard the note on
        /// `showsPlaybackControls` describes — and a channel plays for hours
        /// through an unbounded number of SwiftUI updates.
        private var lastLive: Bool?

        /// What a live channel gets of the transport bar.
        ///
        /// On a television, all of it. AVKit's own bar is where the LIVE
        /// badge is drawn, where the remote reaches this app's Settings
        /// button, and where scrubbing back through a channel's buffer happens
        /// when the stream offers one; taking it away for live — which this
        /// used to do, on the grounds that there was nothing to scrub — left a
        /// channel as a bare picture with no badge and no way to change
        /// anything. What changes for live there is who answers the Menu
        /// button; see `refreshMenuOwnership`.
        ///
        /// Everywhere else the bar stays too — it is where AirPlay, the volume
        /// and this app's own pills live — but it is put into linear playback,
        /// which removes the scrubber and the skip buttons and leaves the rest.
        func applyLiveChrome(for player: PlayerModel, to controller: AVPlayerViewController) {
            #if os(tvOS)
            refreshMenuOwnership(player: player)
            #else
            let isLive = player.isLive
            guard lastLive != isLive else { return }
            lastLive = isLive
            controller.requiresLinearPlayback = isLive
            #endif
        }

        #if os(iOS)
        /// This app's own standing controls, living inside AVKit's.
        private let extras = TransportBarExtras()
        private var hasBoundExtras = false

        /// Point the pills at the model. Done once; the closures below outlive
        /// the SwiftUI updates that hand them over.
        func bindExtras(to player: PlayerModel) {
            guard !hasBoundExtras else { return }
            hasBoundExtras = true
            extras.state = {
                MainActor.assumeIsolated {
                    TransportBarExtras.State(
                        bitrate: player.currentBitrate,
                        offersQuality: !player.isLocal && !player.isLive,
                        sleepMinutesRemaining: player.sleepMinutesRemaining,
                        autoplayCancelled: player.autoplayCancelled,
                        fillScreen: Preferences.shared.fillScreen,
                        canResync: player.canResync,
                        canReencodeForSync: player.canReencodeForSync,
                        canDelayAudio: player.canDelayAudio,
                        audioDelayMilliseconds: player.audioDelayMilliseconds
                    )
                }
            }
            extras.onQuality = { bitrate in
                Task { @MainActor in await player.switchQuality(to: bitrate) }
            }
            extras.onSleepTimer = { minutes in
                if let minutes { player.setSleepTimer(minutes: minutes) } else { player.cancelSleepTimer() }
            }
            extras.onToggleAutoplay = {
                if player.autoplayCancelled { player.resumeAutoplay() } else { player.cancelAutoplay() }
            }
            extras.onToggleFill = { Preferences.shared.fillScreen.toggle() }
            extras.onResync = {
                Task { @MainActor in player.resyncAudio() }
            }
            extras.onReencodeForSync = {
                Task { @MainActor in await player.reencodeForSync() }
            }
            extras.onAudioDelay = { milliseconds in
                Task { @MainActor in player.setAudioDelay(milliseconds: milliseconds) }
            }
        }

        /// Put the pills into AVKit's controls and refresh what they say. Both
        /// halves are cheap and idempotent, so this runs on every update: the
        /// install no-ops once it has taken, and re-takes if AVKit has rebuilt
        /// its controls underneath us.
        func installExtras() {
            guard let root = controller?.view else { return }
            extras.install(into: root)
            extras.refresh()
        }
        #endif

        #if os(tvOS)
        /// Where the ribbon's open/closed state lives — `PlayerScreen` owns it,
        /// this writes to it. See `PlayerInfoRibbon`.
        var ribbon: Binding<Bool>?
        private var installedRibbonGestures = false

        /// A down-swipe pulls the ribbon down and an up-swipe puts it back.
        ///
        /// Layered over AVKit's own recognisers rather than in place of them:
        /// this asks for simultaneous recognition, so the transport bar goes on
        /// answering the remote exactly as it did. That also means the swipe is
        /// shared rather than owned — if AVKit claims it outright in some state,
        /// the gesture stops arriving here and nothing says so. Which is why the
        /// Menu button carries the same command; see `PlayerScreen`'s
        /// `onExitCommand`.
        func installRibbonGestures(on controller: AVPlayerViewController) {
            guard !installedRibbonGestures else { return }
            installedRibbonGestures = true
            let directions: [(UISwipeGestureRecognizer.Direction, Selector)] = [
                (.down, #selector(pullRibbonDown)),
                (.up, #selector(pushRibbonUp)),
            ]
            for (direction, action) in directions {
                let swipe = UISwipeGestureRecognizer(target: self, action: action)
                swipe.direction = direction
                swipe.delegate = self
                controller.view.addGestureRecognizer(swipe)
            }
        }

        @objc private func pullRibbonDown() { ribbon?.wrappedValue = true }
        @objc private func pushRibbonUp() { ribbon?.wrappedValue = false }

        /// The model, for the two things below that AVKit calls into rather
        /// than SwiftUI: the Menu press and the request to dismiss.
        weak var player: PlayerModel?
        private var menuPress: UITapGestureRecognizer?

        /// Take the Menu button when AVKit's own handling of it is wrong.
        ///
        /// A recogniser on the player's view sees the press before AVKit's
        /// responder chain does, which is the documented way to keep an
        /// `AVPlayerViewController` from dismissing itself on Menu. Enabled
        /// only where that matters — see `applyLiveChrome` — so a film keeps
        /// AVKit's ordinary two-press behaviour, hide the bar and then leave.
        /// What it does with the press is what `onExitCommand` does: put the
        /// ribbon away if it is down, otherwise close the player — through the
        /// same arbiter, so a press arriving by both doors is acted on once.
        func installMenuHandling(on controller: AVPlayerViewController) {
            guard menuPress == nil else { return }
            let press = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
            press.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            press.delegate = self
            press.isEnabled = false
            controller.view.addGestureRecognizer(press)
            menuPress = press
        }

        @objc private func menuPressed() {
            PlayerModel.log.notice("Menu press taken by the player view's recogniser")
            player?.handleExit(hidingRibbon: hideRibbon)
        }

        /// Whether AVKit's transport bar is up, as reported by the delegate
        /// callback below. AVKit's own Menu handling is two presses — the
        /// first puts the bar away, the second closes the player — and the
        /// first half is right for every stream.
        private var transportBarVisible = false

        /// Give the Menu button to this app where AVKit's answer would be
        /// wrong, and leave it with AVKit where it wouldn't.
        ///
        /// Over the error card the press is always ours, whichever kind of
        /// stream is behind it. On a live channel it is ours only while the
        /// bar is hidden: AVKit's answer to that press is to close the player
        /// itself, which `playerViewControllerShouldDismiss` may have to
        /// refuse mid-recovery, and a refusal with nobody else listening is a
        /// Menu button that does nothing. While the bar is up, AVKit takes the
        /// press and hides it, as on a film. Cheap and unguarded — enabling a
        /// recogniser rebuilds nothing — so it runs on every update and from
        /// the bar's own transitions.
        func refreshMenuOwnership(player: PlayerModel) {
            menuPress?.isEnabled = player.errorMessage != nil || (player.isLive && !transportBarVisible)
        }

        @objc(playerViewController:willTransitionToVisibilityOfTransportBar:withAnimationCoordinator:)
        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with coordinator: any AVPlayerViewControllerAnimationCoordinator
        ) {
            MainActor.assumeIsolated {
                PlayerModel.log.notice("transport bar visible=\(visible)")
                transportBarVisible = visible
                player?.transportBarVisible = visible
                if let player { refreshMenuOwnership(player: player) }
            }
        }

        private func hideRibbon() -> Bool {
            guard ribbon?.wrappedValue == true else { return false }
            ribbon?.wrappedValue = false
            return true
        }

        /// AVKit wants to close the player. Sometimes.
        ///
        /// It asks this for its own reasons as well as for a Menu press: on
        /// tvOS an `AVPlayerViewController` dismisses itself when its item
        /// plays to the end, fails, or is taken away — and as a child of the
        /// cover, its dismissal is the cover's. For a live channel those are
        /// precisely the moments the model is mid-recovery, and letting AVKit
        /// through was the channel "loading and then backing out". The model
        /// says which moments those are; see `PlayerModel.systemMayDismiss`.
        ///
        /// A request in a steady state is the Menu button, with the bar
        /// already hidden — AVKit only asks once there is no bar to put away.
        /// It is handled as that press, through the same arbiter as the other
        /// doors, and the dismissal itself is always refused: closing the
        /// player is `stop`'s, which takes the cover down through its binding
        /// and writes why to the log, rather than AVKit's.
        nonisolated func playerViewControllerShouldDismiss(
            _ playerViewController: AVPlayerViewController
        ) -> Bool {
            MainActor.assumeIsolated {
                guard let player else { return true }
                let allowed = player.systemMayDismiss
                PlayerModel.log.notice(
                    "AVKit asked to dismiss: allowed=\(allowed) live=\(player.isLive) item=\(player.player.currentItem == nil ? "none" : "present", privacy: .public)")
                if allowed { player.handleExit(hidingRibbon: hideRibbon) }
                return false
            }
        }

        nonisolated func playerViewControllerWillBeginDismissalTransition(
            _ playerViewController: AVPlayerViewController
        ) {
            PlayerModel.log.notice("AVKit is dismissing the player view controller")
        }

        /// Keep the held picture's view in the overlay and shaped like the
        /// player's own. The model puts the view there itself when it makes
        /// the renderer; this is for the two cases it can't cover — a renderer
        /// made before the controller existed, and the fill-screen setting
        /// changing while one is on screen. Cheap and idempotent, like the
        /// rest of what runs on every update.
        func hostHeldPicture(player: PlayerModel) {
            guard let renderer = player.heldPicture, let host = controller?.contentOverlayView else { return }
            if renderer.view.superview !== host {
                renderer.view.frame = host.bounds
                host.addSubview(renderer.view)
            }
            let gravity: AVLayerVideoGravity = Preferences.shared.fillScreen ? .resizeAspectFill : .resizeAspect
            if renderer.view.displayLayer.videoGravity != gravity {
                renderer.view.displayLayer.videoGravity = gravity
            }
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// The one button, put in once.
        ///
        /// `transportBarCustomMenuItems` is one level deep — AVKit's header
        /// says nested menus are unsupported and ignored — so a gear with
        /// Quality and Speed and the rest *inside* it is not a thing this API
        /// can be asked for. One `UIAction` is a button, and the button opens a
        /// panel of the app's own. See `PlayerSettingsPanel`.
        func installSettingsButton(player: PlayerModel) {
            guard !installedSettingsButton, let controller else { return }
            installedSettingsButton = true
            controller.transportBarCustomMenuItems = [
                UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                    Task { @MainActor in self?.presentSettings(player: player) }
                }
            ]
        }

        private var installedSettingsButton = false

        private func presentSettings(player: PlayerModel) {
            guard let controller, controller.presentedViewController == nil else { return }
            let panel = PlayerSettingsPanel(
                player: player,
                dismiss: { [weak controller] in
                    controller?.dismiss(animated: true)
                },
                adjustDelay: { [weak self, weak controller] in
                    // The panel goes first and the strip comes up in its
                    // place once it has gone: two presentations from one
                    // controller at once is the second one refused.
                    controller?.dismiss(animated: true) {
                        Task { @MainActor in self?.presentAudioDelay(player: player) }
                    }
                }
            )
            present(panel)
        }

        /// The audio delay controls, along the bottom of the picture. See
        /// `AudioDelayOverlay`.
        private func presentAudioDelay(player: PlayerModel) {
            guard let controller, controller.presentedViewController == nil else { return }
            present(AudioDelayOverlay(player: player) { [weak controller] in
                controller?.dismiss(animated: true)
            })
        }

        /// Over, not instead of: the picture goes on playing behind whatever
        /// this puts up, which is the whole reason to draw a panel of the
        /// app's own rather than let AVKit take the screen for a menu.
        private func present(_ panel: some View) {
            guard let controller else { return }
            let host = UIHostingController(rootView: panel)
            host.modalPresentationStyle = .overFullScreen
            host.view.backgroundColor = .clear
            controller.present(host, animated: true)
        }

        /// Skip intro and Play next are one press, so they belong in the
        /// contextual strip rather than behind the settings button. Rebuilt
        /// only when something they show has actually changed.
        func rebuildContextualActions(player: PlayerModel) {
            let signature = [
                String(player.activeSegment?.start ?? -1),
                player.upNextTitle ?? "",
                String(player.shouldShowUpNext),
            ].joined(separator: "|")
            guard signature != lastSignature, let controller else { return }
            lastSignature = signature

            var contextual: [UIAction] = []
            if let segment = player.activeSegment {
                contextual.append(UIAction(
                    title: segment.isOutro ? "Skip credits" : "Skip intro",
                    image: UIImage(systemName: "forward.end.fill")
                ) { _ in
                    Task { @MainActor in player.skipSegment() }
                })
            }
            if player.shouldShowUpNext, let next = player.upNextTitle {
                contextual.append(UIAction(
                    title: "Play next · \(next)",
                    image: UIImage(systemName: "forward.fill")
                ) { _ in
                    Task { @MainActor in await player.playNextNow() }
                })
                contextual.append(UIAction(title: "Stop after this episode") { _ in
                    Task { @MainActor in player.cancelAutoplay() }
                })
            }
            controller.contextualActions = contextual
        }
        #endif

        #if os(iOS)
        /// Picture in Picture puts the video in a floating window; the app must
        /// not tear the player down behind it.
        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
        #endif
    }
}
#endif


/// See `PlayerScreen.bitrateBadge`.
struct BitrateBadge: View {
    let notice: PlayerModel.BitrateNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isUp ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(notice.isUp ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.isUp ? "Quality up · \(notice.headline)" : "Quality down · \(notice.headline)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }
}
