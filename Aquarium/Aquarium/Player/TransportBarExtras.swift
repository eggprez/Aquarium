//  Aquarium's standing controls, planted inside AVKit's own.
//
//  Quality is the control people reach for most in a Jellyfin client, and until
//  now it floated over the picture on a layer of its own: a row that had to be
//  told when AVKit's bar came and went, kept clear of every corner AVKit might
//  use, and still read as something bolted on.
//
//  There is no API for this on iOS — `transportBarCustomMenuItems` and
//  `contextualActions` are tvOS only, and iOS 26's custom media selection
//  schemes describe how a *stream* was authored, not choices an app invents. So
//  the pills are added to AVKit's controls as ordinary subviews: find the group
//  holding the full-screen toggle and AirPlay, and hang ours off its trailing
//  edge with constraints. Nothing private is called — this reads a class name,
//  then uses `addSubview`, `NSLayoutConstraint` and `alpha` like any other view.
//
//  What that buys, beyond looking right: the pills are inside the view AVKit
//  hides and shows, so they come and go with the bar for free, with no second
//  copy of AVKit's idle clock to drift out of step.
//
//  Where AVKit's controls can't be found — an iOS whose player is built out of
//  differently named parts — the same row is hung over the bottom corner of the
//  picture instead, above the transport bar, and told to fade with whichever
//  view AVKit is fading. A control that looks bolted on is a far better failure
//  than one that isn't there.
//
//  Both placements are this file's business, and that is the point: when the
//  fallback was a second row drawn by `PlayerScreen`, whether it appeared came
//  down to a flag being reported across a SwiftUI representable — and a player
//  showing its quality menu twice, once in the bar and once floating over the
//  corner, is what that arrangement cost. There is one row now, in one place or
//  the other, and no flag for it to disagree with.

#if os(iOS)

import AVKit
import UIKit

@MainActor
final class TransportBarExtras {
    /// Switch to a rung. The bitrate is nil for direct play.
    var onQuality: (Int?) -> Void = { _ in }
    /// Sleep timer, in minutes, or nil to cancel one.
    var onSleepTimer: (Int?) -> Void = { _ in }
    var onToggleAutoplay: () -> Void = {}
    var onToggleFill: () -> Void = {}
    /// Flush both renderers and start them together again.
    var onResync: () -> Void = {}
    /// Ask the server to encode this stream without copying either bitstream.
    var onReencodeForSync: () -> Void = {}
    /// Shift the sound against the picture, in milliseconds.
    var onAudioDelay: (Int) -> Void = { _ in }
    /// Play another of the file's audio tracks, by `TrackOption.id`.
    var onAudio: (Int) -> Void = { _ in }
    /// Show one of the file's subtitle tracks, by `TrackOption.id`; nil for
    /// none.
    var onSubtitles: (Int?) -> Void = { _ in }

    private let quality = UIButton(type: .system)
    private let extras = UIButton(type: .system)
    private let row = UIStackView()
    /// The glass each button sits in. Hiding a button would leave its capsule
    /// standing there empty, so it's these that come and go.
    private var qualityPill = UIVisualEffectView()
    private var extrasPill = UIVisualEffectView()

    /// Where the row ended up. There is only ever one of it, in one of these
    /// two places.
    private enum Placement { case none, bar, corner }
    private var placement: Placement = .none

    /// The two ways the row can sit in the bar, built together when the row
    /// is put there and swapped by `relayout`.
    private var besideConstraints: [NSLayoutConstraint] = []
    private var belowConstraints: [NSLayoutConstraint] = []

    /// The view the row follows: the group it sits beside when it is in the bar,
    /// and AVKit's whole controls view when it is over the corner instead.
    /// Whatever it is, our row is shown exactly when it is.
    private weak var anchor: UIView?
    private var observations: [NSKeyValueObservation] = []
    private var scans = 0

    /// How long to keep looking for AVKit's own controls before settling for the
    /// corner: twelve quarter-seconds, which is far longer than the bar has ever
    /// taken to lay itself out.
    private static let maxScans = 12

    /// What the pills show and what their menus offer.
    struct State {
        var bitrate: Int?
        var offersQuality = false
        /// Minutes left on a running sleep timer; nil when there is none.
        var sleepMinutesRemaining: Int?
        var autoplayCancelled = false
        var fillScreen = false
        var canResync = false
        var canReencodeForSync = false
        var canDelayAudio = false
        var audioDelayMilliseconds = 0
        /// Every audio and subtitle track the *file* has, and which of each is
        /// on — see `PlayerModel.audioOptions` for why that is more than the
        /// stream carries.
        var audio: [Track] = []
        var subtitles: [Track] = []
        /// Whether no subtitle is showing.
        var subtitlesOff = true

        struct Track {
            var id: Int
            var title: String
            /// Choosing it means asking the server for the stream again.
            var needsNewStream: Bool
            var isOn: Bool
        }
    }

    /// Asked for the state rather than told it, because the menus are built at
    /// the moment they open — long after the last time anything thought to push
    /// an update. A sleep timer set from somewhere else would otherwise leave
    /// this menu still offering to start one.
    var state: () -> State = { State() }

    init() {
        build()
    }

    // MARK: - Installing

    /// Put the pills into AVKit's controls, retrying while they don't exist yet,
    /// and settle for the bottom corner of the picture if they never turn up.
    ///
    /// Safe to call on every SwiftUI update: it returns immediately once the row
    /// is in a window, and picks the controls back up if AVKit has rebuilt them
    /// — which it does on rotation, and on the way back from Picture in Picture.
    func install(into root: UIView) {
        // In the bar, the group we hang off going away is AVKit having rebuilt
        // its controls, and the row has to be put back. Over the corner there is
        // nothing to be torn out from under us: the row is in the player's own
        // view, and being in a window is the whole of the question.
        let attached = row.window != nil && (placement == .corner || anchor?.window != nil)
        guard !attached else { return }

        if let group = Self.firstView(under: root, named: "DisplayModeControls"),
           let parent = group.superview {
            scans = 0
            placement = .bar
            row.removeFromSuperview()
            parent.addSubview(row)
            // Beside the group, on its line: the ordinary arrangement.
            besideConstraints = [
                row.leadingAnchor.constraint(equalTo: group.trailingAnchor, constant: 8),
                row.centerYAnchor.constraint(equalTo: group.centerYAnchor),
                row.heightAnchor.constraint(equalTo: group.heightAnchor),
            ]
            // Under it, on a line of its own. The group's frame is a few
            // points wider than the glass it draws, so the row is inset to
            // line its first capsule up with the close button's.
            belowConstraints = [
                row.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 4),
                row.topAnchor.constraint(equalTo: group.bottomAnchor, constant: 12),
                row.heightAnchor.constraint(equalTo: group.heightAnchor),
            ]
            relayout()
            follow(group)
            return
        }

        // AVKit builds its controls lazily, so a miss this early only means "not
        // yet" — look again once it has laid itself out.
        guard scans >= Self.maxScans else {
            scans += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak root] in
                guard let self, let root else { return }
                self.install(into: root)
            }
            return
        }

        // Nothing to sit beside, so the row goes where it used to live before it
        // moved into the bar: clear of the transport controls, at the trailing
        // edge, above the safe area.
        placement = .corner
        besideConstraints = []
        belowConstraints = []
        row.removeFromSuperview()
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            root.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: 84),
        ])
        follow(Self.firstView(under: root, named: "Controls"))
    }

    func stop() {
        observations.removeAll()
        row.removeFromSuperview()
        anchor = nil
        placement = .none
    }

    /// Beside the group or under it, by the room there is.
    ///
    /// A phone held upright is the one shape where the band across the top is
    /// already full: the close button and AirPlay at one end, the mute button
    /// at the other, and something under two hundred points between them —
    /// into which two pills and their gaps went, and read as one crowd with
    /// nothing to separate this app's controls from the system's. So there the
    /// row drops to a line of its own under the close button and AirPlay,
    /// where there is nothing but black: the picture is letterboxed well
    /// below. A phone on its side and any iPad have most of the band empty,
    /// and the row stays in it beside the group as before.
    ///
    /// Upright-phone is compact width with regular height. Called when the
    /// row is put in the bar and again whenever those traits change; AVKit
    /// also rebuilds its controls on rotation, which puts the row back
    /// through `install` and lands here anyway.
    private func relayout() {
        guard placement == .bar, !besideConstraints.isEmpty else { return }
        let traits = row.traitCollection
        let stacked = traits.horizontalSizeClass == .compact && traits.verticalSizeClass == .regular
        NSLayoutConstraint.deactivate(stacked ? besideConstraints : belowConstraints)
        NSLayoutConstraint.activate(stacked ? belowConstraints : besideConstraints)
    }

    /// Show the row exactly when the view it belongs to is shown.
    ///
    /// AVKit fades the pieces of its bar individually and hides the whole
    /// controls view around them. Sitting inside that view covers the hiding;
    /// this covers the fade, so ours dims on the same curve rather than standing
    /// at full strength until the moment everything vanishes. Over the corner it
    /// is doing both jobs — the row is outside anything AVKit touches there, and
    /// this is the only thing taking it away with the bar.
    ///
    /// Nothing found to follow leaves the row up, which is the harmless way to
    /// be wrong: a control that overstays can still be used, and one that is
    /// hidden for good cannot.
    private func follow(_ view: UIView?) {
        anchor = view
        observations.removeAll()
        guard let view else {
            row.alpha = 1
            row.isHidden = false
            return
        }
        observations = [
            view.observe(\.alpha, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.row.alpha = view.alpha }
            },
            view.observe(\.isHidden, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.row.isHidden = view.isHidden }
            },
        ]
    }

    /// AVKit's own naming is the only handle on these views, and this reads a
    /// class name rather than calling anything private.
    ///
    /// `DisplayModeControls` is the group holding the full-screen toggle and
    /// AirPlay. It sits at the leading end of the band across the top of the
    /// picture, and the rest of that band is empty in both orientations — the
    /// one place in AVKit's layout with room for another control that doesn't
    /// land on the scrubber, the volume slider, or the buttons at either end of
    /// the transport bar. `Controls` is the view around all of it, which on iOS
    /// 26 is `AVMobileGlassControlsView`: what AVKit hides and unhides as the
    /// bar goes and comes.
    private static func firstView(under root: UIView, named fragment: String) -> UIView? {
        var queue = root.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if String(describing: type(of: view)).contains(fragment) {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - State

    /// Refresh what the pills say. Only the labels need this — the menus ask for
    /// themselves when they open.
    ///
    /// Called from `updateUIViewController`, which runs whenever the player
    /// screen redraws — so it returns straight away when nothing it shows has
    /// changed, rather than building an attributed title and a button
    /// configuration each time.
    func refresh() {
        let state = state()
        let label = Quality.shortLabel(for: state.bitrate)
        guard label != shownLabel || state.offersQuality != shownOffersQuality else { return }
        shownLabel = label
        shownOffersQuality = state.offersQuality
        qualityPill.isHidden = !state.offersQuality
        quality.configuration?.attributedTitle = Self.title(label)
    }

    /// What the pill was last set to.
    private var shownLabel: String?
    private var shownOffersQuality: Bool?

    // MARK: - Building

    private func build() {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .fill
        row.registerForTraitChanges(
            [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]
        ) { [weak self] (_: UIStackView, _) in
            self?.relayout()
        }

        quality.configuration = Self.pill(symbol: "slider.horizontal.3", title: "Auto")
        shownLabel = nil
        shownOffersQuality = nil
        quality.accessibilityLabel = "Stream quality"
        quality.showsMenuAsPrimaryAction = true
        quality.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.qualityItems() ?? [])
            }
        ])

        // Not an ellipsis. AVKit draws one of its own on this same bar — the
        // circular "more" button at the trailing end — and two identical glyphs
        // a few points apart, opening entirely different menus, is a coin toss
        // every time. A gear is the nearest thing to "this app's own settings
        // for what is playing", and it is distinct from both AVKit's ellipsis
        // and the sliders on the quality pill beside it.
        extras.configuration = Self.pill(symbol: "gearshape", title: nil)
        extras.accessibilityLabel = "More playback options"
        extras.showsMenuAsPrimaryAction = true
        extras.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.extrasItems() ?? [])
            }
        ])

        qualityPill = Self.capsule(around: quality)
        extrasPill = Self.capsule(around: extras)
        row.addArrangedSubview(qualityPill)
        row.addArrangedSubview(extrasPill)
    }

    /// The pill's backing, which is what makes it read as one of AVKit's rather
    /// than a button sitting near them.
    ///
    /// The glass has to be a view of its own rather than a button background:
    /// `UIGlassEffect` takes its shape from the view it fills, and a background
    /// configuration gives it a rectangle to fill and a foreground drawn through
    /// it, which comes out square-cornered and washed out. Filling a visual
    /// effect view shaped as a capsule, with the button in its content view, is
    /// the arrangement the effect is built for.
    private static func capsule(around button: UIButton) -> UIVisualEffectView {
        let backing: UIVisualEffectView
        if #available(iOS 26.0, *) {
            backing = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            backing.cornerConfiguration = .capsule()
        } else {
            // Before Liquid Glass, AVKit's own controls were dark translucent
            // capsules, and this is that: rounded by `CapsuleEffectView`, which
            // has to measure itself because there is no capsule corner to ask
            // for until iOS 26.
            backing = CapsuleEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        backing.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: backing.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: backing.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: backing.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: backing.contentView.bottomAnchor),
        ])
        return backing
    }

    /// Sized to sit beside AVKit's own pills rather than on top of them: the
    /// same band, the same weight of glyph, and a label only where there is
    /// something to say.
    private static func pill(symbol: String, title: String?) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        config.baseForegroundColor = .white
        config.contentInsets = .init(top: 6, leading: 14, bottom: 6, trailing: 14)
        if let title {
            config.attributedTitle = Self.title(title)
            config.imagePadding = 6
        }
        return config
    }

    private static func title(_ text: String) -> AttributedString {
        AttributedString(
            text,
            attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
            ])
        )
    }

    // MARK: - Menus

    private func qualityItems() -> [UIMenuElement] {
        let bitrate = state().bitrate
        return Quality.choices.map { choice in
            UIAction(
                title: choice.label,
                state: choice.maxBitrate == bitrate ? .on : .off
            ) { [weak self] _ in
                self?.onQuality(choice.maxBitrate)
            }
        }
    }

    /// The offsets, or a couple of lines saying why there are none.
    ///
    /// Shown either way rather than dropped when it can't be used. Somebody
    /// looking for this control and finding nothing concludes the app has lost
    /// it; finding it greyed out with a reason is the answer they came for.
    ///
    /// The second line only appears when an offset is actually set, and it is
    /// the one that matters now the setting is kept: an offset chosen weeks ago
    /// on a direct play, silently not applied to tonight's transcode, is
    /// otherwise a difference with nothing on screen to explain it.
    private func audioDelayMenu(_ state: State) -> UIMenu {
        let image = UIImage(systemName: "arrow.left.arrow.right")
        guard state.canDelayAudio else {
            var children: [UIMenuElement] = [
                UIAction(title: "Only on a direct-played file", attributes: .disabled) { _ in }
            ]
            if state.audioDelayMilliseconds != 0 {
                children.append(UIAction(
                    title: "Set to \(PlayerModel.audioDelayShortName(state.audioDelayMilliseconds))"
                        + " — not applied here",
                    attributes: .disabled
                ) { _ in })
            }
            return UIMenu(title: "Audio delay", image: image, children: children)
        }
        var children: [UIMenuElement] = []
        // A value from the sync test in Settings can be any multiple of ten;
        // one that isn't a preset is shown ticked at the top rather than
        // leaving the menu with nothing on.
        let current = state.audioDelayMilliseconds
        if !PlayerModel.audioDelays.contains(current) {
            children.append(UIAction(title: PlayerModel.audioDelayName(current), state: .on) { _ in })
        }
        children += PlayerModel.audioDelays.map { milliseconds in
            UIAction(
                title: PlayerModel.audioDelayName(milliseconds),
                state: milliseconds == current ? .on : .off
            ) { [weak self] _ in
                self?.onAudioDelay(milliseconds)
            }
        }
        return UIMenu(title: "Audio delay", image: image, children: children)
    }

    /// The file's audio tracks, each one, with the one playing ticked.
    ///
    /// Beside AVKit's own audio-and-subtitles menu rather than instead of it,
    /// because that one lists what the *stream* carries — which on a
    /// transcode is a single soundtrack for a film with four, and no subtitles
    /// at all for one with six. These list what the server says the file has,
    /// and choosing a track the stream doesn't carry asks for the stream again
    /// with that track in it — which the row says, so the moment of black is
    /// not a surprise. See `PlayerModel.audioOptions`.
    private func audioMenu(_ state: State) -> UIMenu? {
        // One track is not a choice.
        guard state.audio.count > 1 else { return nil }
        return UIMenu(
            title: "Audio", image: UIImage(systemName: "speaker.wave.2"),
            children: state.audio.map { track in
                UIAction(
                    title: track.title,
                    subtitle: track.needsNewStream ? "Reopens the stream" : nil,
                    state: track.isOn ? .on : .off
                ) { [weak self] _ in
                    self?.onAudio(track.id)
                }
            }
        )
    }

    /// Off, then the file's subtitle tracks. Absent when the file has none.
    private func subtitlesMenu(_ state: State) -> UIMenu? {
        guard !state.subtitles.isEmpty else { return nil }
        var children: [UIMenuElement] = [
            UIAction(title: "Off", state: state.subtitlesOff ? .on : .off) { [weak self] _ in
                self?.onSubtitles(nil)
            }
        ]
        children += state.subtitles.map { track in
            UIAction(
                title: track.title,
                subtitle: track.needsNewStream ? "Reopens the stream" : nil,
                state: track.isOn ? .on : .off
            ) { [weak self] _ in
                self?.onSubtitles(track.id)
            }
        }
        return UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: children)
    }

    private func extrasItems() -> [UIMenuElement] {
        let state = state()

        // First in the menu, ahead of the two settings under it, because this
        // is the entry somebody opens the menu *looking* for: sleep and fill
        // are preferences you set when nothing is wrong, and this is the one
        // you go hunting for when something is.
        var sync: [UIMenuElement] = []
        if state.canResync {
            sync.append(UIAction(
                title: "Resync audio",
                image: UIImage(systemName: "arrow.triangle.2.circlepath")
            ) { [weak self] _ in
                self?.onResync()
            })
        }
        if state.canReencodeForSync {
            sync.append(UIAction(
                title: "Re-encode this stream",
                image: UIImage(systemName: "server.rack")
            ) { [weak self] _ in
                self?.onReencodeForSync()
            })
        }
        sync.append(audioDelayMenu(state))

        var sleep: [UIAction] = []
        if let left = state.sleepMinutesRemaining {
            sleep.append(UIAction(title: "Cancel sleep timer (\(left) min left)") { [weak self] _ in
                self?.onSleepTimer(nil)
            })
        } else {
            for minutes in [15, 30, 60, 90] {
                sleep.append(UIAction(title: "Stop in \(minutes) minutes") { [weak self] _ in
                    self?.onSleepTimer(minutes)
                })
            }
        }
        sleep.append(UIAction(
            title: state.autoplayCancelled ? "Keep playing after this" : "Stop after this episode"
        ) { [weak self] _ in
            self?.onToggleAutoplay()
        })

        var items: [UIMenuElement] = []
        // Tracks first: the thing people open this menu for most often, and
        // the one AVKit's own menu answers wrongly on a transcode.
        if let audio = audioMenu(state) { items.append(audio) }
        if let subtitles = subtitlesMenu(state) { items.append(subtitles) }
        if !sync.isEmpty {
            items.append(UIMenu(
                title: "Audio sync", image: UIImage(systemName: "waveform"), children: sync
            ))
        }
        items.append(UIMenu(title: "Sleep", image: UIImage(systemName: "moon"), children: sleep))
        items.append(UIAction(
            title: state.fillScreen ? "Fit to screen" : "Fill the screen",
            image: UIImage(systemName: "rectangle.arrowtriangle.2.outward")
        ) { [weak self] _ in
            self?.onToggleFill()
        })
        return items
    }
}

/// A blurred capsule, for the iOS versions with no capsule corner to ask for.
private final class CapsuleEffectView: UIVisualEffectView {
    override func layoutSubviews() {
        super.layoutSubviews()
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = bounds.height / 2
    }
}

#endif
