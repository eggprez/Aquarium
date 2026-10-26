//  The player screen, on every platform.
//
//  The picture is the engine's layer in a plain view (`VideoSurface`) and
//  everything over it is this app's own: `PlayerChrome` draws the scrims, the
//  title, the centre cluster, the timeline with trickplay, the pills and the
//  panel, and the moment overlays — Skip intro, Up Next, the bitrate notice,
//  the error card. On an iPhone or iPad it used to be `AVPlayerViewController`,
//  whose transport could not be changed; on a Mac `AVPlayerView` with its
//  floating panel; on the Apple TV a bar, a panel and a set of cards of its
//  own under `Player/TV/`. All of that is gone. See `PLAYER-OVERHAUL-PLAN.md`,
//  phases 2, 3 and 5.
//
//  What differs by platform is input and the frame around the picture: a
//  finger taps the chrome up and the status bar follows it on a phone; a
//  pointer brings it up by moving and the window carries the title, full
//  screen and the right-click menu on a Mac (`PlayerPointer`, `PlayerWindow`,
//  `PlayerMacMenus`); the Siri Remote is read by `PlayerRemoteDriver`
//  (`TV/TVPlayerScreen.swift`) on a television, which also draws the code in
//  the corner of a sync clip.
//
//  A foldable half-folded — part-open, flat on a table like a laptop — is
//  split at the crease: the picture and the half of the chrome that belongs
//  over it above the fold, and below it `PlayerFoldPanel` with the timeline,
//  the pills, the prompts and what is playing. See `framed`.

import Observation
import OSLog
import SwiftUI

struct PlayerScreen: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var app

    @State private var chrome = PlayerChromeState(showsTotalTime: !Preferences.shared.showsRemainingTime)
    @State private var trickplay = TrickplayStore()
    @State private var schedule = ChannelSchedule()
    @State private var artwork = InfoArtwork()
    @State private var pictureInPicture = PictureInPicture()
    #if os(iOS)
    @Environment(\.devicePose) private var pose
    #endif

    /// How far down a foldable's front screen the status bar still takes
    /// touches, though the safe area says nothing is there — see `framed`.
    private static var frontStatusStrip: CGFloat { FoldState.frontStatusStrip }

    /// Half-folded: the transport is split at the crease.
    private var foldsBelow: Bool {
        #if os(iOS)
        pose == .halfFolded
        #else
        false
        #endif
    }

    /// The picture and everything drawn over it.
    private var stage: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(pictureInPicture: pictureInPicture)
                .ignoresSafeArea()
            // The last title's final frame, still on the layer: covered until
            // this one's first frame replaces it.
            if player.pictureIsStale {
                Color.black.ignoresSafeArea()
            }
            #if os(tvOS)
            // The code the iPhone app reads during a sync clip: which rate
            // this is and the delay in force. See `SyncCodeOverlay`.
            if player.isSyncTest, player.errorMessage == nil {
                SyncCodeOverlay()
            }
            #endif
            PlayerChrome(chrome: chrome, trickplay: trickplay, schedule: schedule, artwork: artwork,
                         pictureInPicture: pictureInPicture, belowFold: foldsBelow) {
                player.stop(reason: "player dismissed")
            }
        }
    }

    /// The stage — or, on a foldable half-folded, the stage above the fold
    /// and `PlayerFoldPanel` below it. The stage is the first child of the
    /// same stack either way, so the surface and its layer are never remade
    /// by the fold: `FoldSplit` only changes the frame.
    ///
    /// The split is measured against the whole screen, so the container
    /// ignores the safe area — which left the chrome inside it with none:
    /// the title row sat under the status bar on the front screen, where
    /// its taps went to the status bar, and half-folded it rose off the top
    /// of the screen once the status-strip rise lifted it further. So the
    /// window's insets are read out here and given back by hand. The
    /// picture's half keeps the top and the sides, and the bottom only
    /// while it is the whole screen; the flat half below the crease keeps
    /// the bottom, for the home indicator. The picture and the scrims still
    /// ignore them and fill the screen.
    @ViewBuilder
    private var framed: some View {
        #if os(iOS)
        if FoldState.shared.isFoldable {
            GeometryReader { geo in
                let insets = geo.safeAreaInsets
                // The front screen reports no top inset — its clock is in
                // the column down the trailing edge — yet the top 24 points
                // still belong to the status bar's touch strip: measured on
                // the simulator, a tap on the "…" button 22 points down
                // dies and one 26 points down lands. The title row's
                // buttons were centred in that strip, which is why they
                // rarely worked. So the chrome keeps at least the strip
                // clear on the front screen.
                let top = pose == .front ? max(insets.top, Self.frontStatusStrip) : insets.top
                // The front screen's side column (camera, then clock) comes
                // back as a whole side of safe area, which held the progress
                // bar and the title row's buttons 84 points short of that
                // edge. Apple's guidance for an immersive screen that does
                // not scroll is the full width, clear of the camera and the
                // status bar, so there the chrome drops the sides and steps
                // around the camera row by row instead — see
                // `PlayerSideClearance`.
                let clearance = pose == .front
                    ? PlayerSideClearance(geo, titleRowFoot: top + PlayerSideClearance.titleRowDepth,
                                          pillRowHead: insets.top + geo.size.height - PlayerSideClearance.pillRowDepth)
                    : nil
                FoldSplit(split: foldsBelow, crease: .black) {
                    stage
                        .safeAreaPadding(EdgeInsets(top: top, leading: clearance == nil ? insets.leading : 0,
                                                    bottom: foldsBelow ? 0 : insets.bottom,
                                                    trailing: clearance == nil ? insets.trailing : 0))
                        .environment(\.playerSideClearance, clearance)
                        .onChange(of: clearance, initial: true) { _, clearance in
                            guard let clearance else { return }
                            var regions = ""
                            if #available(iOS 27.1, *) {
                                regions = geo.reservedRegions(kind: .occlusion).map { "\($0.frame) active \($0.isActive)" }
                                    .joined(separator: "; ")
                            }
                            FoldState.log.debug("player sides \(String(describing: clearance)) in \(geo.size.width, format: .fixed(precision: 0))×\(geo.size.height, format: .fixed(precision: 0)), insets \(String(describing: insets)); occlusion \(regions)")
                        }
                } lower: {
                    PlayerFoldPanel(chrome: chrome, trickplay: trickplay, schedule: schedule, artwork: artwork)
                        .safeAreaPadding(.bottom, insets.bottom)
                }
                .background(Color.black)
                .ignoresSafeArea()
            }
        } else {
            stage
        }
        #else
        stage
        #endif
    }

    var body: some View {
        framed
        // Dark whatever the app's theme: the chrome is drawn over a picture,
        // and on a Mac the popovers take the window's appearance.
        .preferredColorScheme(.dark)
        .modifier(PlayerScreenLifecycle())
        #if os(iOS)
        // The status bar comes and goes with the controls, as in Apple's
        // player; the home indicator dims on its own over a full-screen video.
        .statusBarHidden(!chrome.controlsVisible && !player.isPaused)
        .persistentSystemOverlays(.hidden)
        // The shell is portrait on a phone; a film is the reason the phone gets
        // turned, so the player follows the phone either way up. See
        // `OrientationLock`.
        .allowsLandscape()
        #endif
        #if os(macOS)
        // The scroll wheel: volume, and a sideways scrub.
        .background(PlayerPointerAdapter(player: player, chrome: chrome))
        // The picture's right-click menu: the transport and every setting the
        // Playback menu has, in the place a Mac user asks for them.
        .contextMenu { PlayerContextMenu(player: player) }
        #endif
    }
}

// MARK: - The front screen's camera

/// How far the title row and the pill row keep in from each side where
/// the chrome spans the whole width: a foldable's front screen, whose side
/// column the safe area reports as one solid side though only its top holds
/// anything — the camera, then the clock. Apple's guidance for a full-screen
/// interface that doesn't scroll is the full width as long as nothing runs
/// into the camera or the status bar, and the camera comes back as an
/// occlusion region (`ReservedRegion`). So each row clears only the regions
/// level with it, from the edge they sit on: upright the title row's
/// buttons stop at the camera and the band runs edge to edge; sideways the
/// camera is at the head of one side or the foot of the other, and the back
/// button or the pills stop at it while the timeline runs past.
///
/// Measured in the full screen's coordinates, the space `PlayerScreen.framed`
/// reads. Each value is the region's reach in from its edge, margins and
/// all; the rows already sit `PlayerMetrics.edge` in.
struct PlayerSideClearance: Equatable {
    var titleLeading: CGFloat = 0
    var titleTrailing: CGFloat = 0
    var pillsLeading: CGFloat = 0
    var pillsTrailing: CGFloat = 0

    /// The title row's foot below the top inset: its 8-point drop and its
    /// 40-point buttons, and some air.
    static let titleRowDepth: CGFloat = 56
    /// The pill row's head above the bottom inset: its 40 points, the
    /// band's 12 under it, and some air.
    static let pillRowDepth: CGFloat = 64

    #if os(iOS)
    init(_ geo: GeometryProxy, titleRowFoot: CGFloat, pillRowHead: CGFloat) {
        // The reader is the safe area's rectangle and the regions come back
        // in its space, out past its edges; shifted here to the screen's.
        let insets = geo.safeAreaInsets
        var regions: [CGRect] = []
        if #available(iOS 27.1, *) {
            regions = geo.reservedRegions(kind: .occlusion).filter(\.isActive)
                .map { $0.frame.offsetBy(dx: insets.leading, dy: insets.top) }
        }
        // No regions to go by: the title row and the pills keep the safe
        // area's sides, as they did before, so neither can land on the
        // camera; the timeline still runs edge to edge.
        guard !regions.isEmpty else {
            titleLeading = insets.leading
            titleTrailing = insets.trailing
            pillsLeading = insets.leading
            pillsTrailing = insets.trailing
            return
        }
        // The camera comes back twice: its lens, 37 points with margins,
        // inside an 84-point square at the head of the column that the
        // Dynamic Island grows into. Only the lens is in the way of a row
        // across the top, so a region holding another is left out and the
        // buttons stop at the camera itself.
        let innermost = regions.filter { outer in
            !regions.contains { $0 != outer && outer.contains($0) }
        }
        let width = geo.size.width + insets.leading + insets.trailing
        for region in innermost {
            let onLeading = region.midX < width / 2
            let reach = onLeading ? region.maxX : width - region.minX
            if region.minY < titleRowFoot {
                if onLeading { titleLeading = max(titleLeading, reach) } else { titleTrailing = max(titleTrailing, reach) }
            }
            if region.maxY > pillRowHead {
                if onLeading { pillsLeading = max(pillsLeading, reach) } else { pillsTrailing = max(pillsTrailing, reach) }
            }
        }
    }
    #endif
}

extension EnvironmentValues {
    /// Set where the chrome spans the full width; nil where the safe area's
    /// sides hold. See `PlayerSideClearance`.
    @Entry var playerSideClearance: PlayerSideClearance? = nil
}

// MARK: - The stop the screen owes

/// The screen going away has to stop playback too, or a stream keeps running
/// (and keeps a transcode alive) behind the UI: the cover's own binding covers
/// every dismissal SwiftUI knows about, and this covers the rest — signing
/// out, the shell being rebuilt under it.
///
/// A moment later rather than now. `onDisappear` also fires for a view that
/// is about to come straight back — SwiftUI rebuilding the hierarchy,
/// something presented full-screen over it and removed again — and stopping
/// on the spot for one of those is a channel that opened, went black, and
/// dropped back to the guide with nothing wrong. If the screen is back within
/// the moment, `onAppear` calls this off. And it stops only the stream it
/// saw: a channel picked from the guide inside that moment is a new
/// generation, and this must not be the thing that tears it down.
private struct PlayerScreenLifecycle: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @State private var pendingStop: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { pendingStop?.cancel(); pendingStop = nil }
            .onDisappear {
                guard player.isActive else { return }
                let generation = player.streamGeneration
                pendingStop?.cancel()
                pendingStop = Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    player.stop(reason: "player screen disappeared", ifStill: generation)
                }
            }
    }
}
