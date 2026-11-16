//  Cards and shelves for titles that come from Seerr rather than the library.
//
//  They look like the library's own (`PosterCard`, `MediaShelf`) on purpose:
//  a title that isn't here yet is still a title. What differs is where the
//  picture comes from (TMDB, by way of `SeerrClient.imageURL`) and the badge
//  that says how far a request has got.

import SwiftUI

/// One title from Seerr: poster, name, year, and a badge once it has been
/// asked for.
struct RequestPosterCard: View {
    let result: SeerrResult
    var width: CGFloat? = Metrics.posterWidth

    private var seerr: SeerrClient { .shared }
    private var standing: SeerrStanding { SeerrStanding(media: result.mediaInfo) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardTextSpacing) {
            RequestPoster(path: result.posterPath, title: result.displayTitle)
                .frame(width: width)
                .cardChrome()
                .overlay(alignment: .topLeading) {
                    if let badge = standing.badge {
                        StandingBadge(text: badge, symbol: standing.symbol)
                            .padding(6)
                            .accessibilityIdentifier(TestID.Requests.cardBadge(result.id))
                    }
                }
                .artworkFocus()
            VStack(alignment: .leading, spacing: 1) {
                Text(result.displayTitle)
                    .font(titleFont.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(subtitleFont)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        [result.year, result.kind == .tv ? "Show" : "Film"].compactMap { $0 }.joined(separator: " · ")
    }

    private var titleFont: Font {
        #if os(macOS)
        .callout
        #else
        .subheadline
        #endif
    }

    private var subtitleFont: Font {
        #if os(macOS)
        .subheadline
        #else
        .caption
        #endif
    }
}

/// A TMDB poster in a 2:3 slot, or the title's name on a plain card when
/// there is no picture.
struct RequestPoster: View {
    let path: String?
    let title: String

    var body: some View {
        RemoteImage(url: SeerrClient.shared.imageURL(path, size: .poster))
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if path == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.title2)
                        Text(title)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(8)
                }
            }
    }
}

/// "Requested", "On its way": a dark capsule that reads over any poster.
struct StandingBadge: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(badgeFont.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
    }

    private var badgeFont: Font {
        #if os(tvOS)
        .caption2
        #else
        .caption2
        #endif
    }
}

/// A horizontal shelf of Seerr titles. Draws nothing when it has none, the
/// way `MediaShelf` does.
struct RequestShelf: View {
    let title: String
    var subtitle: String?
    let results: [SeerrResult]
    /// The row's key for UI tests.
    let key: String

    @Environment(AppModel.self) private var app

    var body: some View {
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(TestID.Common.shelfTitle("requests-\(key)"))
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                        ForEach(results) { result in
                            Button {
                                app.open(result)
                            } label: {
                                RequestPosterCard(result: result)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PosterButtonStyle())
                            .accessibilityIdentifier(TestID.Requests.card(result.id))
                            .accessibilityLabel(result.displayTitle)
                            #if os(macOS)
                            .help(result.displayTitle)
                            #endif
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.shelfCardPadding)
                }
                .focusRegion()
            }
            .testAnchor(TestID.Requests.shelf(key))
        }
    }

    private var titleFont: Font {
        #if os(iOS)
        return Metrics.phoneLayout ? .headline : .title2.weight(.bold)
        #elseif os(macOS)
        return .title2.weight(.bold)
        #else
        return .title3.weight(.semibold)
        #endif
    }
}

extension AppModel {
    /// Open a title Seerr named: the library's own page when it is already
    /// here, its request page when it isn't.
    func open(_ result: SeerrResult) {
        guard let kind = result.kind else { return }
        if result.availability == .available, let id = result.mediaInfo?.libraryItemId {
            push(.item(id))
        } else {
            push(.request(kind: kind, tmdbId: result.tmdbId))
        }
    }
}
