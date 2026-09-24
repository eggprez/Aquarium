//  Everything the player can be told, behind one button.
//
//  This started as a single `UIMenu` in the transport bar with Quality, Speed,
//  Subtitles and the rest nested inside it, and that cannot work: AVKit's
//  header says so outright — "Only UIMenu and UIAction instance types are
//  supported. Nested UIMenus are not supported. Unsupported types will be
//  ignored." The transport bar is exactly one level deep. Every element handed
//  to `transportBarCustomMenuItems` is a *button*, and a `UIMenu` among them
//  buys a flat list of actions and nothing more.
//
//  So a settings button with sections under it is not something that API can
//  express. What it can express is one `UIAction` — one button — and what that
//  button does is up to this app. It opens this: a panel of the app's own, over
//  the picture, with the categories down the left and the choices for the
//  focused one on the right. Which is the shape a television wants anyway. A
//  remote is good at a list and bad at a menu that keeps pushing another menu
//  in front of it, and this way the quality rungs and the subtitle tracks are
//  one press apart rather than three.
//
//  Focus picks the category rather than a press: moving down the left column
//  changes what is on the right, the way the Apple TV app's own panels behave.
//  Choosing anything on the right closes the panel — every one of these is a
//  decision that shows on screen, and staying open to admire the tick is not
//  worth a second press to get back to the film.

#if os(tvOS)

import SwiftUI

struct PlayerSettingsPanel: View {
    let player: PlayerModel
    let dismiss: () -> Void
    /// Close this and open the audio delay controls over the picture — see
    /// `AudioDelayOverlay`. The one choice here that leads somewhere rather
    /// than deciding something.
    let adjustDelay: () -> Void

    @State private var category: Category = .quality
    @FocusState private var focusedCategory: Category?
    @FocusState private var focusedOption: String?

    enum Category: String, Identifiable, CaseIterable {
        case quality, speed, subtitles, audio, sync, playback

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quality: "Quality"
            case .speed: "Speed"
            case .subtitles: "Subtitles"
            case .audio: "Audio track"
            case .sync: "Audio sync"
            case .playback: "Playback"
            }
        }

        var symbol: String {
            switch self {
            case .quality: "slider.horizontal.3"
            case .speed: "speedometer"
            case .subtitles: "captions.bubble"
            case .audio: "waveform.circle"
            case .sync: "waveform"
            case .playback: "rectangle.arrowtriangle.2.outward"
            }
        }
    }

    /// Only the categories this stream has anything to say about. A downloaded
    /// file has no rungs and a channel with one soundtrack has no track list,
    /// and an empty pane is worse than an absent one.
    private var categories: [Category] {
        Category.allCases.filter { category in
            switch category {
            case .quality: !player.isLocal && !player.isLive
            case .subtitles: !player.subtitleOptions.isEmpty
            case .audio: player.audioOptions.count > 1
            // A channel plays at the speed it is broadcast.
            case .speed: !player.isLive
            case .sync, .playback: true
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            categoryColumn
            optionColumn
        }
        .background(scrim)
        .onAppear {
            if !categories.contains(category) { category = categories.first ?? .speed }
        }
        // Focus is what chooses the category, so the right-hand pane follows
        // the left column as it is moved through rather than waiting for a
        // press that would cost one on the way in and another on the way out.
        .onChange(of: focusedCategory) { _, new in
            if let new { category = new }
        }
        // Menu puts the panel away. Nothing else would: this is a hosting
        // controller presented over AVKit's, and a press that isn't taken
        // here goes on to the player, which answers it by leaving the film.
        .onExitCommand { dismiss() }
    }

    /// Near-solid rather than a material. A material over a bright frame is
    /// still a bright frame, and this has to be readable over a snow scene as
    /// well as over a night exterior — the same reasoning as the info ribbon's.
    private var scrim: some View {
        Color.black.opacity(0.92).ignoresSafeArea()
    }

    // MARK: - Left

    /// A `List` and the buttons' own style, with nothing painted on top.
    ///
    /// This column used to draw its own highlight: a tinted capsule behind the
    /// chosen category, and the label's colour flipped to black by hand when it
    /// held focus. That is two highlights for one cursor, and neither of them
    /// is tvOS's — the system's focus treatment lifts the row, scales it and
    /// inverts its contents on its own, so painting a second one underneath got
    /// a tinted row *and* a white one, and a hand-inverted label that went black
    /// on a background that hadn't turned white yet. It read as a bug because it
    /// looked like one. Standard focus is one highlight, drawn by the system, in
    /// the place the remote is pointing.
    private var categoryColumn: some View {
        List(categories) { item in
            Button {
                category = item
            } label: {
                Label(item.title, systemImage: item.symbol)
            }
            .focused($focusedCategory, equals: item)
        }
        .listStyle(.plain)
        .frame(width: 520)
    }

    // MARK: - Right

    /// Which category these belong to is said here rather than by tinting a row
    /// in the other column: with the focus over this side, the left-hand list
    /// has no highlight on it at all, and a heading is a plainer answer to
    /// "what am I looking at" than a second kind of highlight would be.
    private var optionColumn: some View {
        List {
            Section {
                ForEach(options(for: category)) { option in
                    row(option)
                }
            } header: {
                Text(category.title)
            }
        }
        .listStyle(.plain)
        .frame(maxWidth: .infinity)
        // Coming across from the categories, land on the ticked row rather
        // than the top one — the quality rung in use, the track that is on —
        // so the remote starts where it almost always wants to be.
        .focusSection()
        .defaultFocus(
            $focusedOption,
            options(for: category).first { $0.isOn && $0.run != nil }?.id,
            priority: .userInitiated
        )
    }

    @ViewBuilder
    private func row(_ option: Option) -> some View {
        if let run = option.run {
            Button {
                run()
                if option.closesPanel { dismiss() }
            } label: {
                rowLabel(option)
            }
            .focused($focusedOption, equals: option.id)
        } else {
            // A line with nothing behind it — the explanation for a control
            // that can't be used here. Not a button, so the remote passes over
            // it rather than stopping on something that answers no press.
            rowLabel(option)
                .foregroundStyle(Theme.textDim)
                .focusable(false)
        }
    }

    /// No colours of its own. Everything in here inherits from the row, which
    /// is what lets the system invert the whole thing — tick, title and note
    /// together — when it takes focus.
    private func rowLabel(_ option: Option) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "checkmark")
                .opacity(option.isOn ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                if let detail = option.detail {
                    Text(detail).font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - What each category offers

    private struct Option: Identifiable {
        var id: String
        var title: String
        var detail: String?
        var isOn: Bool
        /// Off for the one row that opens something of its own and closes
        /// this panel on the way — a second dismissal after it would land on
        /// a controller that is already going.
        var closesPanel = true
        /// `nil` for a line that only explains something.
        var run: (() -> Void)?
    }

    private func options(for category: Category) -> [Option] {
        switch category {
        case .quality: qualityOptions
        case .speed: speedOptions
        case .subtitles: subtitleRows
        case .audio: audioRows
        case .sync: syncOptions
        case .playback: playbackOptions
        }
    }

    private var qualityOptions: [Option] {
        Quality.choices.map { choice in
            Option(
                id: "q\(choice.maxBitrate ?? 0)",
                title: choice.label,
                isOn: choice.maxBitrate == player.currentBitrate
            ) {
                Task { await player.switchQuality(to: choice.maxBitrate) }
            }
        }
    }

    private var speedOptions: [Option] {
        PlayerModel.speeds.map { rate in
            Option(
                id: "s\(rate)",
                title: PlayerModel.speedName(rate),
                isOn: abs(rate - player.speed) < 0.001
            ) {
                player.speed = rate
            }
        }
    }

    /// The file's subtitles, not the stream's — see `PlayerModel.subtitleOptions`.
    private var subtitleRows: [Option] {
        let selected = player.selectedSubtitleOption
        var rows = [Option(id: "off", title: "Off", isOn: selected == nil) {
            player.selectSubtitles(nil)
        }]
        rows += player.subtitleOptions.map { option in
            Option(
                id: "sub\(option.id)",
                title: option.label,
                // Said rather than hidden. A track the stream doesn't carry is
                // still the right one to pick — it costs the couple of seconds
                // the server needs to build a stream with it in.
                detail: option.needsNewStream ? "Reopens the stream" : nil,
                isOn: option.id == selected
            ) {
                player.selectSubtitles(option)
            }
        }
        return rows
    }

    private var audioRows: [Option] {
        let selected = player.selectedAudioOption
        return player.audioOptions.map { option in
            Option(
                id: "aud\(option.id)",
                title: option.label,
                detail: option.needsNewStream ? "Reopens the stream" : nil,
                isOn: option.id == selected
            ) {
                player.selectAudio(option)
            }
        }
    }

    /// The one repair a viewer can make from the sofa. It matters more here
    /// than on a phone: a television is where the audio route actually goes
    /// away mid-film — the set sleeps, the receiver renegotiates HDMI — and
    /// where the sound comes back on a clock of its own.
    private var syncOptions: [Option] {
        var rows: [Option] = []
        if player.canResync {
            rows.append(Option(id: "resync", title: "Resync audio", isOn: false) {
                player.resyncAudio()
            })
        }
        if player.canReencodeForSync {
            rows.append(Option(
                id: "reencode",
                title: "Re-encode this stream",
                detail: "For a transcode that arrived out of step",
                isOn: false
            ) {
                Task { await player.reencodeForSync() }
            })
        }
        // The offset itself is not chosen from a list here any more. It is
        // set over the picture — the controls sit along the bottom of the
        // player and the film goes on playing above them — because the only
        // test of an audio delay that means anything is the thing being
        // watched. See `AudioDelayOverlay`.
        if player.canDelayAudio {
            let current = player.audioDelayMilliseconds
            rows.append(Option(
                id: "adjust",
                title: "Adjust audio delay",
                detail: current == 0
                    ? "In step · nudge the sound over the picture"
                    : "\(PlayerModel.audioDelayName(current)) · nudge it over the picture",
                isOn: current != 0,
                closesPanel: false
            ) {
                adjustDelay()
            })
        } else {
            // Offered whether or not it can be used: a control that vanishes
            // reads as one that broke. On a television the only stream that
            // can't take an offset is one still opening; the second line
            // appears when an offset is set and says it isn't on yet.
            rows.append(Option(
                id: "nodelay",
                title: "Adjust audio delay",
                detail: "Once the stream has opened",
                isOn: false
            ))
            if player.audioDelayMilliseconds != 0 {
                rows.append(Option(
                    id: "nodelayset",
                    title: PlayerModel.audioDelayName(player.audioDelayMilliseconds),
                    detail: "Set, and applied as it opens",
                    isOn: false
                ))
            }
        }
        // The frame-rate offset is added on top of whatever is set, and said
        // so here: otherwise "In step" is shown while the sound is plainly
        // being moved.
        let matched = player.frameRateMatchMilliseconds
        if matched != 0 {
            rows.append(Option(
                id: "framerate",
                title: "Plus \(PlayerModel.audioDelayShortName(matched)) for Match Frame Rate",
                detail: "The TV switched mode for this video — change it in Settings → Audio output",
                isOn: false
            ))
        }
        return rows
    }

    /// No sleep timer here. tvOS has one of its own, in Settings, and it stops
    /// the box rather than just this app; a second one is a worse version of a
    /// control the viewer already has. What is left is the thing tvOS can't do
    /// — stopping at the end of *this episode* rather than at a time.
    private var playbackOptions: [Option] {
        var rows: [Option] = []
        // A channel has no "this episode" to stop after.
        if !player.isLive {
            rows.append(Option(
                id: "autoplay",
                title: player.autoplayCancelled ? "Keep playing after this" : "Stop after this episode",
                isOn: player.autoplayCancelled
            ) {
                if player.autoplayCancelled { player.resumeAutoplay() } else { player.cancelAutoplay() }
            })
        }
        rows.append(Option(
            id: "fill",
            title: "Fill the screen",
            detail: "Crop to the edges instead of letterboxing",
            isOn: Preferences.shared.fillScreen
        ) {
            Preferences.shared.fillScreen.toggle()
        })
        return rows
    }
}

#endif
