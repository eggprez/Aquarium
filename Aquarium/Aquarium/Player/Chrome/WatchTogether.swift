//  Watch Together, on screen: the rows that start and leave SharePlay and
//  SyncPlay, and the question SyncPlay asks ("which group?").
//
//  The rows are the same on every device and sit where each keeps its
//  choices: first in the "…" card on an iPhone, an iPad or a Mac, and under
//  a Watch Together tab in the Apple TV's panel. One of the two at a time —
//  with SharePlay on, SyncPlay's rows step aside, and the other way round —
//  since two things each moving everyone's playhead would fight.
//
//  SyncPlay can also be joined with nothing playing, from Settings: the
//  question is the same one (`SyncPlayPrompt`), hung on the root of the app
//  as well as on the player.

import SwiftUI

extension PlayerModel {
    /// Whether SharePlay or SyncPlay has everyone on one clock.
    var isWatchingTogether: Bool {
        SharePlayCoordinator.shared.isActive || SyncPlayCoordinator.shared.isActive
    }

    /// Whether the player has anything to say under Watch Together.
    var offersWatchTogether: Bool {
        isWatchingTogether || canWatchTogether || canSyncPlay
    }
}

/// The rows. A column in a card, or cards in the television's panel — see
/// `PanelRows`, which the caller wraps them in.
struct WatchTogetherRows: View {
    @Environment(PlayerModel.self) private var player
    let onInteract: () -> Void
    let close: () -> Void

    var body: some View {
        let shareplay = SharePlayCoordinator.shared
        let syncplay = SyncPlayCoordinator.shared

        if shareplay.isActive {
            if !shareplay.progressChoices.isEmpty {
                PanelRow(title: "Start From Someone’s Progress…",
                         detail: "Everyone jumps to the spot you pick") {
                    onInteract()
                    close()
                    shareplay.askAgain()
                }
                .accessibilityIdentifier(TestID.Player.sharePlayProgressAsk)
            }
            PanelRow(title: "Leave SharePlay", isSelected: true) {
                onInteract()
                shareplay.leave()
                close()
            }
            .accessibilityIdentifier(TestID.Player.sharePlayLeave)
            PanelRow(title: "End SharePlay for Everyone") {
                onInteract()
                shareplay.endForEveryone()
                close()
            }
            .accessibilityIdentifier(TestID.Player.sharePlayEnd)
        } else if player.canWatchTogether, !syncplay.isActive {
            // On mpv the stream is handed to AVPlayer first, whose player the
            // session coordinates; a download is left for the server's stream.
            PanelRow(title: "Watch Together with SharePlay",
                     detail: "The same picture on everyone’s screen, over FaceTime") {
                onInteract()
                close()
                Task {
                    guard await player.streamForGroup(), let item = player.item else { return }
                    await player.prepareForSharePlay()
                    await shareplay.share(item)
                }
            }
            .accessibilityIdentifier(TestID.Player.sharePlayStart)
        }

        if let group = syncplay.group {
            PanelRow(title: "Leave SyncPlay", detail: group.summary, isSelected: true) {
                onInteract()
                close()
                Task { await syncplay.leave() }
            }
            .accessibilityIdentifier(TestID.Player.syncPlayLeave)
        } else if player.canSyncPlay, !shareplay.isActive {
            PanelRow(title: "Watch Together with SyncPlay",
                     detail: "With people on your Jellyfin server. No call needed") {
                onInteract()
                close()
                Task { await syncplay.choose() }
            }
            .accessibilityIdentifier(TestID.Player.syncPlayStart)
        }
    }
}

/// "Which group?" — the server's groups to join, a new one to start, and the
/// way out of the one this device is in. Asked from the player's Watch
/// Together rows and from Settings; `whilePlaying` says which of the two this
/// copy answers for, so the question is only ever put once.
struct SyncPlayPrompt: ViewModifier {
    @Environment(PlayerModel.self) private var player
    let whilePlaying: Bool

    func body(content: Content) -> some View {
        let syncplay = SyncPlayCoordinator.shared
        let asking = Binding(
            get: { syncplay.picker != nil && player.isActive == whilePlaying },
            set: { if !$0 { syncplay.picker = nil } })
        content.alert("SyncPlay", isPresented: asking, presenting: syncplay.picker) { groups in
            ForEach(groups.filter { $0.GroupId != syncplay.group?.GroupId }) { group in
                Button("Join \(group.summary)") { Task { await syncplay.join(group) } }
                    .accessibilityIdentifier(TestID.Player.syncPlayGroup(group.GroupName))
            }
            Button("Start a New Group") { Task { await syncplay.create() } }
                .accessibilityIdentifier(TestID.Player.syncPlayNew)
            if let current = syncplay.group {
                Button("Leave \u{201C}\(current.GroupName)\u{201D}", role: .destructive) { Task { await syncplay.leave() } }
                    .accessibilityIdentifier(TestID.Player.syncPlayLeave)
            }
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(TestID.Player.syncPlayCancel)
        } message: { groups in
            Text(SyncPlayCopy.question(groups: groups.count, playing: whilePlaying))
        }
    }
}

enum SyncPlayCopy {
    /// What Settings says under its SyncPlay row, and the Apple TV beside it.
    static let about = "Watch with other people signed in to your Jellyfin server. Everyone’s picture pauses, plays and jumps together, with no FaceTime call. Join a group here, or start one from the player’s Watch Together."

    static func question(groups: Int, playing: Bool) -> String {
        let what = playing
            ? "A new group starts with what you’re watching."
            : "Whatever you play next is put on for the group."
        return groups == 0
            ? "Nobody on your server has a group going. \(what)"
            : "Join a group to watch what it’s watching. \(what)"
    }

    /// The Settings row's value: the group, or nothing.
    @MainActor static var status: String {
        SyncPlayCoordinator.shared.group?.GroupName ?? "Off"
    }
}
