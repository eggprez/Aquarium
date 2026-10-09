//  The Live Activities extension — iPhone and iPad only — which is also
//  where the Now Playing widget and the Control Centre buttons live.
//
//  Two activities. Each is drawn three ways: the Lock Screen,
//  the Dynamic Island, and — from iOS 18 — the small card that Apple Watch's
//  Smart Stack and (iOS 26) the CarPlay dashboard show. That last one gets
//  its own layout rather than the island's compact corners, which is what the
//  system borrows when an activity offers nothing better. What each one draws is decided entirely by
//  the state the app hands over (Shared/LiveActivityTypes.swift); nothing in
//  here talks to the server, reads a file, or knows what a Jellyfin is.

import SwiftUI
import WidgetKit

@main
struct AquariumLiveActivities: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
        DownloadsLiveActivity()
        // The Now Playing card, and — from iOS 18 — the Control Centre
        // buttons. See NowPlayingWidget.swift.
        NowPlayingWidget()
        if #available(iOS 18.0, *) {
            ResumeWatchingControl()
            ShuffleMusicControl()
            ResumeAudiobookControl()
        }
    }
}

/// The app's colours, restated: the extension doesn't link Theme, and an
/// activity is always drawn on the system's dark material whatever the app's
/// own theme is set to.
enum ActivityPalette {
    /// `Theme.accent`.
    static let accent = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)
    /// `Theme.link` in the dark theme — the accent, light enough to be text.
    static let accentText = Color(red: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255)
    static let background = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x14 / 255)
    static let dim = Color.white.opacity(0.62)
    /// The small card's ground: opaque, a touch lighter than the Lock
    /// Screen's so it still reads as a card on the watch's black.
    static let smallBackground = Color(red: 0x17 / 255, green: 0x15 / 255, blue: 0x22 / 255)
    /// Secondary text on the small card — seen at arm's length or across a
    /// car, so brighter than `dim`.
    static let smallDim = Color.white.opacity(0.78)
}

/// The Lock Screen layout, or the small card for Apple Watch and CarPlay.
///
/// The small card is drawn on an opaque background of our own and always in
/// the dark: CarPlay can put an activity on a light dashboard, where the Lock
/// Screen's translucent tint turned grey and white text on it went to mush.
struct ActivityLayout<Small: View, Full: View>: View {
    @ViewBuilder var small: Small
    @ViewBuilder var full: Full

    var body: some View {
        if #available(iOS 18.0, *) {
            FamilyReader(small: small, full: full)
        } else {
            full.lockScreenChrome()
        }
    }

    @available(iOS 18.0, *)
    private struct FamilyReader: View {
        @Environment(\.activityFamily) private var family
        let small: Small
        let full: Full

        var body: some View {
            if family == .small {
                small
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(.white)
                    .activityBackgroundTint(ActivityPalette.smallBackground)
                    .activitySystemActionForegroundColor(.white)
            } else {
                full.lockScreenChrome()
            }
        }
    }
}

private extension View {
    func lockScreenChrome() -> some View {
        activityBackgroundTint(ActivityPalette.background.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
    }
}

extension WidgetConfiguration {
    /// Offers the small card to the Smart Stack and CarPlay.
    func withSmallCard() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}

/// The pill a button on an activity is drawn as.
struct ActivityPill: View {
    let title: String
    let systemImage: String
    var prominent = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : ActivityPalette.accentText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                prominent ? ActivityPalette.accent : ActivityPalette.accent.opacity(0.22),
                in: Capsule()
            )
    }
}
