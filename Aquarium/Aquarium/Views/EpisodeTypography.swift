//  One way of setting the three names an episode goes by, so that a glance
//  says which is which wherever they turn up together:
//
//  - the show's name, semibold, in the page's strongest text colour;
//  - what the episode is called, regular weight, a step quieter;
//  - which episode it is — "Season 2: Episode 4" — in small capitals with
//    figures of one width, quietest of the three. It is a label, and it is
//    set like one.
//
//  A card on Home, the hero, a title page's "Up next" line, the player's
//  title and its Info page, the Up Next card and list, a download's row: all
//  of them come here rather than choosing a weight of their own. The sizes
//  stay each screen's business — a television's heading is not a phone's
//  caption — which is why every helper takes the font it is to be set in.
//
//  Plain strings are not this file's concern: Spotlight, Siri, CarPlay, a
//  Quick Action and a menu's sentence have no typography to give.

import SwiftUI

/// Which of an episode's names a piece of text is.
enum TitleRole {
    /// The show. A film's title is the same kind of name and is set the same.
    case show
    /// What the episode is called.
    case episode
    /// Which episode it is: `BaseItem.episodeLabel`.
    case label
}

/// What the words sit on.
enum TitleTone {
    /// The page: the theme's own text colours, light or dark.
    case page
    /// A picture, or the player's dark glass: white, at three strengths.
    case picture
    /// A row with the television's focus on it: white, barely stepped, so
    /// nothing fades into the accent behind it.
    case focused
}

extension TitleRole {
    func color(_ tone: TitleTone) -> Color {
        switch (tone, self) {
        case (.page, .show): Theme.text
        case (.page, .episode): Theme.textBody
        case (.page, .label): Theme.textDim
        case (.picture, .show): .white
        case (.picture, .episode): .white.opacity(0.92)
        case (.picture, .label): .white.opacity(0.72)
        case (.focused, .show), (.focused, .episode): .white
        case (.focused, .label): .white.opacity(0.85)
        }
    }
}

extension Font {
    /// This font, as `role` is set. The size and the design are the caller's;
    /// the weight and the figures are the role's.
    func titleRole(_ role: TitleRole) -> Font {
        switch role {
        case .show: weight(.semibold)
        case .episode: weight(.regular)
        case .label: weight(.medium).lowercaseSmallCaps().monospacedDigit()
        }
    }
}

extension Text {
    /// Set as `role`, in `font`'s size.
    func titleRole(_ role: TitleRole, font: Font, tone: TitleTone = .page) -> Text {
        self.font(font.titleRole(role)).foregroundStyle(role.color(tone))
    }
}

/// The names on one line — "Firefly · Season 1: Episode 3 · Bushwhacked", or
/// any two of them — each in its own role, with a quiet dot between.
enum EpisodeLine {
    /// `lead` goes in front, set like the dots: "Up next", "Carry on with".
    static func text(
        lead: String? = nil, show: String? = nil, label: String? = nil, episode: String? = nil,
        font: Font, tone: TitleTone = .page
    ) -> Text {
        let quiet = TitleRole.label.color(tone)
        var parts: [Text] = []
        if let lead, !lead.isEmpty { parts.append(Text(lead).font(font).foregroundStyle(quiet)) }
        if let show, !show.isEmpty { parts.append(Text(show).titleRole(.show, font: font, tone: tone)) }
        if let label, !label.isEmpty { parts.append(Text(label).titleRole(.label, font: font, tone: tone)) }
        if let episode, !episode.isEmpty { parts.append(Text(episode).titleRole(.episode, font: font, tone: tone)) }
        let dot = Text(" · ").font(font).foregroundStyle(quiet)
        guard var line = parts.first else { return Text(verbatim: "") }
        for part in parts.dropFirst() {
            line = Text("\(line)\(dot)\(part)")
        }
        return line
    }

    /// The same, read off an episode. Pass false for whatever the screen has
    /// already said somewhere else.
    static func text(
        for item: BaseItem, lead: String? = nil, show: Bool = true, label: Bool = true, episode: Bool = true,
        font: Font, tone: TitleTone = .page
    ) -> Text {
        text(lead: lead,
             show: show ? item.SeriesName : nil,
             label: label ? item.episodeLabel : nil,
             episode: episode ? item.title : nil,
             font: font, tone: tone)
    }

    /// The same again for a row that sets its own title — the player's Up
    /// Next list — which knows its font and whether it has the focus, and so
    /// asks for the line once it does. Nil for anything but an episode, whose
    /// plain title needs no setting apart.
    static func row(_ item: BaseItem, show: Bool = true) -> ((Font, TitleTone) -> Text)? {
        guard item.isEpisode else { return nil }
        return { font, tone in text(for: item, show: show, font: font, tone: tone) }
    }
}
