//  What is playing, and the controls for it. A book gets fifteen back and
//  thirty forward, a speed and its chapters; a song gets previous and next.
//  The Digital Crown is the volume, as in Apple's own players: the page
//  doesn't scroll, and a `WKInterfaceVolumeControl` holds the crown whenever
//  the page is in front. The output route is the system's Now Playing view,
//  a tap away.
//
//  A page on the root stack, pushed when something starts and backed out of
//  like any other. No top-bar items: on a pushed page they pop it.

import SwiftUI
import WatchKit

struct NowPlayingScreen: View {
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchNavigator.self) private var nav
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSystem = false
    @State private var showsChapters = false
    /// Bumped whenever the crown should come back to the volume: on
    /// appearing, on returning to the app, and when a sheet goes away.
    @State private var crownClaim = 0

    private var isBook: Bool { player.current?.isAudiobook == true }

    var body: some View {
        Group {
            if let item = player.current {
                content(item)
            } else {
                idle
            }
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsSystem, onDismiss: claimCrown) { NowPlayingView() }
        .sheet(isPresented: $showsChapters, onDismiss: claimCrown) { chapters }
        .onAppear(perform: claimCrown)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { claimCrown() }
        }
        .onDisappear { nav.playerLeft() }
    }

    private func claimCrown() { crownClaim &+= 1 }

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 34))
                .foregroundStyle(WatchTheme.accent)
            Text("Nothing playing").font(.footnote).foregroundStyle(WatchTheme.dim)
            Button { Task { await WatchActions.resumeBook() } } label: {
                Label("Resume Audiobook", systemImage: "book")
            }
            .font(.footnote)
        }
        .padding()
    }

    /// Not a scroll view: one would want the crown too.
    private func content(_ item: BaseItem) -> some View {
        playing(item)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private func playing(_ item: BaseItem) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Artwork(item: item, size: 46, corner: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2)
                    Text(subtitle(item)).font(.caption2).foregroundStyle(WatchTheme.dim).lineLimit(2)
                }
                Spacer(minLength: 0)
                // Beside the crown, which is what turns it.
                CrownVolume(claim: crownClaim)
                    .frame(width: 26, height: 26)
                    .accessibilityLabel("Volume")
            }

            VStack(spacing: 2) {
                ProgressView(value: player.duration > 0 ? min(1, player.position / player.duration) : 0)
                    .tint(WatchTheme.accent)
                HStack {
                    Text(Format.clock(player.position))
                    Spacer()
                    if player.duration > 0 { Text("-" + Format.clock(max(0, player.duration - player.position))) }
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(WatchTheme.dim)
            }

            if let error = player.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }

            HStack(spacing: 14) {
                Button {
                    if isBook { player.seek(by: -15) } else { player.skipPrevious() }
                } label: {
                    Image(systemName: isBook ? "gobackward.15" : "backward.fill")
                }
                .buttonStyle(.plain)
                .font(.title3)

                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Circle().fill(WatchTheme.accent.gradient)
                        if player.isBuffering && !player.isPlaying {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                Button {
                    if isBook { player.seek(by: 30) } else { player.skipNext() }
                } label: {
                    Image(systemName: isBook ? "goforward.30" : "forward.fill")
                }
                .buttonStyle(.plain)
                .font(.title3)
                .disabled(!isBook && !player.hasNext)
            }

            HStack(spacing: 8) {
                Button { showsSystem = true } label: {
                    Image(systemName: "airplayaudio").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Output")
                if isBook {
                    Button { player.stepSpeed(1) } label: {
                        Text(speedLabel).font(.caption2.weight(.semibold).monospacedDigit())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .simultaneousGesture(LongPressGesture().onEnded { _ in player.speed = 1 })
                    if !player.chapters.isEmpty {
                        Button { showsChapters = true } label: {
                            Image(systemName: "list.bullet").font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("Chapters")
                    }
                }
            }

            if !isBook {
                let notes = [
                    player.upNextCount > 0 ? "\(player.upNextCount) up next" : nil,
                    player.isLocal ? "On watch" : nil,
                ].compactMap { $0 }
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.dim)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var speedLabel: String {
        let s = player.speed
        return s == s.rounded() ? "\(Int(s))×" : String(format: "%.2g×", s)
    }

    private func subtitle(_ item: BaseItem) -> String {
        if item.isAudiobook, let chapter = player.currentChapter?.Name, !chapter.isEmpty { return chapter }
        var parts: [String] = []
        if !item.artistLine.isEmpty { parts.append(item.artistLine) }
        if let album = item.Album, !album.isEmpty, !item.isAudiobook { parts.append(album) }
        if parts.isEmpty, let title = player.queueTitle { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    private var chapters: some View {
        List {
            ForEach(Array(player.chapters.enumerated()), id: \.offset) { i, chapter in
                Button {
                    player.seek(to: chapter.startSeconds)
                    showsChapters = false
                } label: {
                    HStack {
                        Text(chapter.Name?.isEmpty == false ? chapter.Name! : "Chapter \(i + 1)")
                            .font(.footnote)
                            .foregroundStyle(player.currentChapter == chapter ? WatchTheme.link : .primary)
                            .lineLimit(2)
                        Spacer()
                        Text(Format.clock(chapter.startSeconds)).font(.caption2.monospacedDigit()).foregroundStyle(WatchTheme.dim)
                    }
                }
            }
        }
    }
}

/// The system's volume control for this watch's own output, holding the
/// crown. A new `claim` hands the crown back to it; SwiftUI takes the crown
/// for a sheet and doesn't return it on its own.
private struct CrownVolume: WKInterfaceObjectRepresentable {
    var claim: Int

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        control.setTintColor(UIColor(WatchTheme.accent))
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        guard context.coordinator.claim != claim else { return }
        context.coordinator.claim = claim
        // After this pass, so the control is in the window when it asks.
        DispatchQueue.main.async { control.focus() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var claim = -1 }
}
