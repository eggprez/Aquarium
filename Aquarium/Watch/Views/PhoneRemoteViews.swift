//  The watch as a remote for the phone.
//
//  The top of the library is a switch between two sources. "Watch" is the
//  app as it was: the server and what is kept on the wrist. "iPhone" is the
//  phone's player seen from here — what it is playing, and the controls
//  for it — and nothing else, the way a podcast app's watch remote works.
//  The state comes over the link (see `WatchLink.phonePlayback`) and the
//  buttons go back the same way; the crown is the phone's volume.

import AVFoundation
import SwiftUI
import WatchKit

enum WatchSource: String, CaseIterable {
    case watch, phone

    var label: String {
        switch self {
        case .watch: "Watch"
        case .phone: "iPhone"
        }
    }

    var symbol: String {
        switch self {
        case .watch: "applewatch"
        case .phone: "iphone"
        }
    }
}

/// Which source the library shows. Remembered across launches.
@MainActor
@Observable
final class WatchMode {
    static let shared = WatchMode()

    var source: WatchSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "watch_source")
            if source == .phone { WatchLink.shared.requestPlayback() }
        }
    }

    private init() {
        source = UserDefaults.standard.string(forKey: "watch_source").flatMap(WatchSource.init) ?? .watch
    }
}

// MARK: - The switch

/// Two capsules, one lit: the row at the top of the library.
struct SourceSwitch: View {
    @Environment(WatchMode.self) private var mode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WatchSource.allCases, id: \.self) { source in
                Button {
                    guard mode.source != source else { return }
                    withAnimation(.easeOut(duration: 0.15)) { mode.source = source }
                } label: {
                    Label(source.label, systemImage: source.symbol)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(
                            Capsule().fill(mode.source == source ? WatchTheme.accent.opacity(0.9) : Color.white.opacity(0.08))
                        )
                        .foregroundStyle(mode.source == source ? .white : WatchTheme.dim)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode.source == source ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

// MARK: - The row

/// The phone's player in one line, for the top of the library: tapping it
/// opens the remote.
struct PhoneNowPlayingRow: View {
    let state: PhonePlaybackState
    @Environment(WatchLink.self) private var link

    var body: some View {
        HStack(spacing: 8) {
            PhoneArtwork(itemId: state.itemId, isAudiobook: state.isAudiobook, isVideo: state.isVideo, size: 34, corner: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.isPlaying ? "Playing on iPhone" : "Paused on iPhone")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchTheme.link)
                Text(state.title).font(.footnote).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.footnote)
                .foregroundStyle(WatchTheme.link)
                .symbolEffect(.variableColor.iterative, isActive: state.isPlaying)
        }
    }
}

/// What the phone has sent of the cover, or a glyph for the kind of thing.
struct PhoneArtwork: View {
    let itemId: String
    var isAudiobook = false
    var isVideo = false
    var size: CGFloat = 40
    var corner: CGFloat = 6
    @Environment(WatchLink.self) private var link

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x3B2A6B), Color(hex: 0x1B2A5B)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let art = link.phoneArtwork, art.itemId == itemId {
                Image(uiImage: art.image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isVideo ? "film" : (isAudiobook ? "book.fill" : "music.note"))
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// The row when the phone has nothing on, or can't be reached.
struct PhoneIdleRow: View {
    @Environment(WatchLink.self) private var link

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(link.isPhoneReachable ? "Nothing playing on iPhone" : "iPhone out of reach", systemImage: link.isPhoneReachable ? "iphone" : "iphone.slash")
                .font(.footnote.weight(.semibold))
            Text(link.isPhoneReachable
                 ? "Start something in Aquarium on your iPhone and it shows here."
                 : "Bring the watch near your iPhone to control what it plays.")
                .font(.caption2)
                .foregroundStyle(WatchTheme.dim)
            if let error = link.remoteError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            Button {
                link.requestPlayback()
            } label: {
                HStack {
                    if link.remoteBusy { ProgressView().controlSize(.mini) }
                    Text("Check Again")
                }
                .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(link.remoteBusy)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - The remote

/// The phone's player, drawn here. Laid out like the watch's own `NowPlayingScreen`
/// so the two feel like one app; the differences are that every button is a
/// message, the clock runs on from the last state the phone sent, and the
/// crown turns the phone's volume.
struct PhonePlayerScreen: View {
    @Environment(WatchLink.self) private var link
    @Environment(\.scenePhase) private var scenePhase
    @State private var crownClaim = 0

    var body: some View {
        Group {
            if let state = link.phonePlayback {
                content(state)
            } else {
                idle
            }
        }
        .navigationTitle("iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            crownClaim &+= 1
            link.requestPlayback()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                crownClaim &+= 1
                link.requestPlayback()
            }
        }
    }

    private var idle: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: link.isPhoneReachable ? "iphone" : "iphone.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(WatchTheme.accent)
                PhoneIdleRow()
            }
            .padding()
        }
    }

    private func content(_ state: PhonePlaybackState) -> some View {
        ViewThatFits(in: .vertical) {
            playing(state, compact: false)
            playing(state, compact: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            ZStack {
                CompanionCrownVolume(claim: crownClaim)
                    .frame(width: 2, height: 2)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                PhoneVolumePopup(level: state.volume)
            }
        }
    }

    private func playing(_ state: PhonePlaybackState, compact: Bool) -> some View {
        let lines = compact ? 1 : 2
        let side: CGFloat = compact ? 44 : 52
        let main: CGFloat = compact ? 50 : 58
        let glyph: CGFloat = compact ? 22 : 26
        let isBook = state.isAudiobook
        let skips = isBook || state.isVideo
        return VStack(spacing: compact ? 4 : 6) {
            HStack(alignment: .top, spacing: 8) {
                PhoneArtwork(itemId: state.itemId, isAudiobook: state.isAudiobook, isVideo: state.isVideo, size: compact ? 38 : 46, corner: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.footnote.weight(.semibold)).lineLimit(lines)
                    Text(subtitle(state)).font(.caption2).foregroundStyle(WatchTheme.dim).lineLimit(lines)
                }
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = state.position(now: context.date)
                VStack(spacing: 2) {
                    ProgressView(value: state.duration > 0 ? min(1, position / state.duration) : 0)
                        .tint(WatchTheme.accent)
                    HStack {
                        Text(Format.clock(position))
                        Spacer()
                        if state.duration > 0 { Text("-" + Format.clock(max(0, state.duration - position))) }
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(WatchTheme.dim)
                }
            }

            if let error = link.remoteError {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }

            HStack(spacing: 4) {
                Button {
                    link.remote(skips ? .seekBy(isBook ? -15 : -10) : .previous)
                } label: {
                    Image(systemName: skips ? (isBook ? "gobackward.15" : "gobackward.10") : "backward.fill")
                        .frame(maxWidth: .infinity, minHeight: side)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: glyph, weight: .semibold))
                .disabled(!skips && !state.hasPrevious)

                Button { link.remote(.togglePlayPause) } label: {
                    ZStack {
                        Circle().fill(WatchTheme.accent.gradient)
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: glyph, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: main, height: main)
                }
                .buttonStyle(.plain)

                Button {
                    link.remote(skips ? .seekBy(30) : .next)
                } label: {
                    Image(systemName: skips ? "goforward.30" : "forward.fill")
                        .frame(maxWidth: .infinity, minHeight: side)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: glyph, weight: .semibold))
                .disabled(!skips && !state.hasNext)
            }

            if isBook {
                HStack(spacing: 8) {
                    Button { link.remote(.setSpeed(Self.nextSpeed(after: state.speed))) } label: {
                        Text(speedLabel(state.speed)).font(.caption2.weight(.semibold).monospacedDigit())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .simultaneousGesture(LongPressGesture().onEnded { _ in link.remote(.setSpeed(1)) })
                }
            }

            if !isBook {
                let notes = [
                    state.upNextCount > 0 ? "\(state.upNextCount) up next" : nil,
                    "On iPhone",
                ].compactMap { $0 }
                Text(notes.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.dim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private static func nextSpeed(after speed: Double) -> Double {
        let speeds = WatchPlayer.speeds
        guard let i = speeds.firstIndex(where: { abs($0 - speed) < 0.01 }) else { return 1 }
        return speeds[(i + 1) % speeds.count]
    }

    private func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%.2g×", s)
    }

    private func subtitle(_ state: PhonePlaybackState) -> String {
        if state.isAudiobook, let chapter = state.chapter, !chapter.isEmpty { return chapter }
        return state.subtitle ?? ""
    }
}

/// The level bar beside the crown, shown while the phone's volume moves.
/// The phone reports its volume in every state; a change shows it.
private struct PhoneVolumePopup: View {
    var level: Double?
    @State private var shown = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .semibold))
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(WatchTheme.accent)
                        .frame(height: max(6, geo.size.height * CGFloat(level ?? 0)))
                }
            }
            .frame(width: 6, height: 64)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .background(Capsule().fill(Color(white: 0.16)))
        .shadow(color: .black.opacity(0.6), radius: 4)
        .opacity(shown ? 1 : 0)
        .offset(x: shown ? 0 : 8)
        .animation(.easeOut(duration: 0.2), value: shown)
        .animation(.easeOut(duration: 0.12), value: level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: level) { old, new in
            guard old != nil, new != nil else { return }
            shown = true
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                shown = false
            }
        }
        .onDisappear { hideTask?.cancel() }
    }
}

/// The system's volume control for the paired phone, holding the crown.
/// Hidden, like the watch's own in `NowPlayingScreen`: the popup above is
/// what the eye gets.
private struct CompanionCrownVolume: WKInterfaceObjectRepresentable {
    var claim: Int

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .companion)
        control.setTintColor(UIColor(WatchTheme.accent))
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        guard context.coordinator.claim != claim else { return }
        context.coordinator.claim = claim
        DispatchQueue.main.async { control.focus() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var claim = -1 }
}
