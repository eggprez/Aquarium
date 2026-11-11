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
    /// The frame the chrome was laid out in while the status bar was up —
    /// see `framed`.
    @State private var heldFrame: HeldFrame?
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
            #if !os(tvOS)
            // A download's subtitle file, where the engine can't take one.
            if !player.pictureIsStale {
                SubtitleFileOverlay()
                    .ignoresSafeArea()
            }
            #endif
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
                let live = geo.safeAreaInsets
                let screen = CGSize(width: geo.size.width + live.leading + live.trailing,
                                    height: geo.size.height + live.top + live.bottom)
                // A Duo's clock column and strip are safe area, and they
                // change as the status bar goes. The bar is gone in a blink
                // while the chrome takes a quarter second to fade, so the
                // title row's buttons slid across the gap before they went.
                // While the bar is hidden the chrome keeps the frame it had
                // with the bar up — unless the screen has changed, or been
                // turned: the two landscapes are the same size with the
                // camera and the clock column on opposite sides, and a
                // frame held across that turn kept the first side's
                // clearance, which shoved the title row's buttons in from
                // an edge nothing was on.
                let orientation = Self.interfaceOrientation
                let held = statusBarHidden
                    ? heldFrame.flatMap { $0.screen == screen && $0.orientation == orientation ? $0 : nil } : nil
                let insets = held?.insets ?? live
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
                // `PlayerSideClearance`. The inside screen held sideways
                // does the same with its clock column: only the pill at its
                // head is in the way, so the timeline runs to the edge under
                // it while the title row and the pills keep the column.
                // The camera's clearance is read live: the lens is where it
                // is whether or not the bar shows. Only the insets are held.
                let clearance: PlayerSideClearance? = pose == .front
                    ? PlayerSideClearance(geo, column: insets, titleRowFoot: top + PlayerSideClearance.titleRowDepth,
                                          pillRowHead: insets.top + geo.size.height - PlayerSideClearance.pillRowDepth)
                    : FoldState.shared.innerSideways ? PlayerSideClearance(keeping: insets) : nil
                let frame = HeldFrame(screen: screen, orientation: orientation, insets: insets)
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
                .onChange(of: frame, initial: true) { _, frame in
                    if !statusBarHidden { heldFrame = frame }
                }
            }
        } else {
            stage
        }
        #else
        stage
        #endif
    }

    #if os(iOS)
    private var statusBarHidden: Bool { !chrome.controlsVisible && !player.isPaused }

    private struct HeldFrame: Equatable {
        var screen: CGSize
        var orientation: UIInterfaceOrientation
        var insets: EdgeInsets
    }

    /// Which way the screen is turned, from the scene that is up.
    private static var interfaceOrientation: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.effectiveGeometry.interfaceOrientation ?? .unknown
    }
    #endif

    var body: some View {
        framed
        // Dark whatever the app's theme: the chrome is drawn over a picture,
        // and on a Mac the popovers take the window's appearance.
        .preferredColorScheme(.dark)
        .modifier(PlayerScreenLifecycle())
        #if os(iOS)
        // The status bar comes and goes with the controls, as in Apple's
        // player; the home indicator dims on its own over a full-screen video.
        .statusBarHidden(statusBarHidden)
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
/// button or the pills stop at it while the timeline runs past. Only the
/// lens counts, and only a lens in the column; when the system reports
/// none the camera is taken to be where it always is in that column.
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

    /// The title row and the pills keep the safe area's sides; only the
    /// timeline spans them.
    init(keeping insets: EdgeInsets) {
        titleLeading = insets.leading
        titleTrailing = insets.trailing
        pillsLeading = insets.leading
        pillsTrailing = insets.trailing
    }

    #if os(iOS)
    /// The lens with its margins, as the system reports it: 37 points.
    /// Anything much bigger is the Dynamic Island's room around it, not
    /// the camera.
    static let lensReach: CGFloat = 60
    /// Where the lens sits when the system says nothing: measured on the
    /// simulator, 17.67 points in from the column's inner edge and 29.33
    /// from the end of the screen it is nearest, 37 square.
    private static let lensInset: CGFloat = 17.67
    private static let lensEndGap: CGFloat = 29.33
    private static let lensSize: CGFloat = 37
    /// A side of safe area at least this wide is the clock column.
    private static let columnMinimum: CGFloat = 40

    /// `column` is the safe area the chrome is laid out to — held while the
    /// status bar is hidden, since the column goes with the bar.
    init(_ geo: GeometryProxy, column: EdgeInsets, titleRowFoot: CGFloat, pillRowHead: CGFloat) {
        // The reader is the safe area's rectangle and the regions come back
        // in its space, out past its edges; shifted here to the screen's.
        let live = geo.safeAreaInsets
        let width = geo.size.width + live.leading + live.trailing
        let height = geo.size.height + live.top + live.bottom
        let screen = CGRect(x: 0, y: 0, width: width, height: height)
        let onTrailing = column.trailing >= Self.columnMinimum
        let onLeading = !onTrailing && column.leading >= Self.columnMinimum
        // Only the lens itself, and only inside the column. The system
        // reports the camera twice — the lens, and the 84-point block at
        // the head of the column the Dynamic Island grows into — and on
        // the device the block can stand at the head of the column with
        // the lens at its foot, holding nothing: clearing it shoved the
        // title row's buttons in from an edge nothing was on. And the
        // regions can come back a turn late, the lens still where it was
        // before the phone turned, on a side with no column at all.
        var lenses: [CGRect] = []
        #if DEBUG
        // `-AquariumNoLens YES` plays the device that reports no regions.
        let reported = !UserDefaults.standard.bool(forKey: "AquariumNoLens")
        #else
        let reported = true
        #endif
        if reported, #available(iOS 27.1, *) {
            lenses = geo.reservedRegions(kind: .occlusion).filter(\.isActive)
                .map { $0.frame.offsetBy(dx: live.leading, dy: live.top) }
                .filter { region in
                    guard screen.intersects(region), max(region.width, region.height) <= Self.lensReach else { return false }
                    if onTrailing { return region.minX >= width - column.trailing - 1 }
                    if onLeading { return region.maxX <= column.leading + 1 }
                    return true
                }
        }
        // Nothing to go by. With a column the camera is still where it
        // always is — at the column's head, or at its foot when the
        // column is trailing and the screen is wide — so the rows stop
        // there rather than a whole column short. Without one the rows
        // keep the safe area's sides, as they did before, so neither can
        // land on the camera; the timeline still runs edge to edge.
        if lenses.isEmpty, onTrailing || onLeading {
            let x = onTrailing ? width - column.trailing + Self.lensInset : column.leading - Self.lensInset - Self.lensSize
            let atFoot = onTrailing && width > height
            let y = atFoot ? height - Self.lensEndGap - Self.lensSize : Self.lensEndGap
            lenses = [CGRect(x: x, y: y, width: Self.lensSize, height: Self.lensSize)]
        }
        guard !lenses.isEmpty else {
            titleLeading = column.leading
            titleTrailing = column.trailing
            pillsLeading = column.leading
            pillsTrailing = column.trailing
            return
        }
        for lens in lenses {
            let leading = lens.midX < width / 2
            let reach = leading ? lens.maxX : width - lens.minX
            if lens.minY < titleRowFoot {
                if leading { titleLeading = max(titleLeading, reach) } else { titleTrailing = max(titleTrailing, reach) }
            }
            if lens.maxY > pillRowHead {
                if leading { pillsLeading = max(pillsLeading, reach) } else { pillsTrailing = max(pillsTrailing, reach) }
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
