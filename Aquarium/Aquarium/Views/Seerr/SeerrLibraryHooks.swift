//  What a library page gains from Seerr: the seasons of a show that aren't
//  here, the films of a collection that aren't, the rest of what someone made,
//  and titles like this one that could be asked for.
//
//  Each is drawn from what `SeerrClient.warm(for:)` found, and draws nothing
//  at all until there is something to say, so a page looks exactly as it did
//  for anyone without Seerr.

import SwiftUI

/// Under a show or a collection in `ItemDetailView`.
struct SeerrItemHooks: View {
    let item: BaseItem

    @Environment(AppModel.self) private var app
    private var seerr: SeerrClient { .shared }

    var body: some View {
        if seerr.isConnected, let tmdbId = item.tmdbId {
            if item.kind == "Series", let title = seerr.knownTitle(.tv, tmdbId: tmdbId) {
                let missing = title.requestableSeasons
                if !missing.isEmpty { moreSeasons(missing, tmdbId: tmdbId) }
            } else if item.kind == "BoxSet", let collection = seerr.knownCollection(tmdbId: tmdbId) {
                RequestShelf(
                    title: "Missing From This Collection",
                    subtitle: "Open one to request it.",
                    results: (collection.parts ?? []).filter(\.isRequestable),
                    key: "collection"
                )
            }
        }
    }

    private func moreSeasons(_ missing: [SeerrSeason], tmdbId: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(missing.count == 1 ? "1 more season exists" : "\(missing.count) more seasons exist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(Self.list(missing) + (missing.count == 1 ? " isn't" : " aren't") + " in your library.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Request…") { app.push(.request(kind: .tv, tmdbId: tmdbId)) }
                .appButtonStyle()
                .accessibilityIdentifier(TestID.Requests.detailSeasonsButton)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 4)
        // The button sits at the far trailing edge, out of line with the
        // seasons above it, and on an Apple TV a press down from a season
        // found nothing straight below and went nowhere. As a region the
        // whole band is the target, so Down lands on the button.
        .focusRegion()
        .testAnchor(TestID.Requests.detailSeasons)
    }

    /// "Season 3", "Seasons 3 and 4", "Seasons 3, 4 and 5".
    static func list(_ seasons: [SeerrSeason]) -> String {
        let numbers = seasons.map { String($0.seasonNumber) }
        switch numbers.count {
        case 0: return ""
        case 1: return "Season \(numbers[0])"
        default: return "Seasons " + numbers.dropLast().joined(separator: ", ") + " and " + numbers[numbers.count - 1]
        }
    }
}

/// Under More Like This on a film's, a show's, a season's or an episode's
/// page: what Seerr would suggest beside it that isn't here yet. A season
/// and an episode are answered with their show's suggestions.
struct SeerrLikeThisHook: View {
    let item: BaseItem

    private var seerr: SeerrClient { .shared }

    var body: some View {
        if seerr.isConnected, let found = seerr.knownLikeThis(for: item) {
            RequestShelf(
                title: "Like This, Not in Your Library",
                subtitle: "Open one to request it.",
                results: Array(found.filter(\.isRequestable).prefix(20)),
                key: "likeThis"
            )
        }
    }
}

/// Under someone's films and shows in `PersonView`.
struct SeerrPersonHook: View {
    let person: BaseItem?

    private var seerr: SeerrClient { .shared }

    var body: some View {
        if seerr.isConnected, let tmdbId = person?.tmdbId, let credits = seerr.knownCredits(personTmdbId: tmdbId) {
            RequestShelf(
                title: "Not in Your Library",
                subtitle: "Open one to request it.",
                results: Array(credits.filter(\.isRequestable).prefix(30)),
                key: "person"
            )
        }
    }
}
