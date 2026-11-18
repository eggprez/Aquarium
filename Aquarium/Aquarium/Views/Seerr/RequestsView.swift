//  The Seerr page: one carousel of what this account has asked for and how
//  far each request has got, then rows of things worth asking for, Trending
//  first, and a line crediting Seerr and TMDB at the foot.
//
//  Every row stands as a placeholder until its answer lands. They are asked
//  for at once, beside the requests, so the rows below no longer appear one
//  by one, unannounced, after the carousel.

import SwiftUI

struct RequestsView: View {
    @Environment(AppModel.self) private var app

    @State private var mine: [SeerrRequest] = []
    /// What each request is a request *for*. Seerr's list names titles only by
    /// TMDB id, so each row's name and poster are looked up (and remembered
    /// by the client).
    @State private var names: [Int: SeerrTitle] = [:]
    @State private var rows: [SeerrClient.BrowseRow: [SeerrResult]] = [:]
    /// Rows Seerr couldn't give: drawn as nothing rather than waiting forever.
    @State private var failedRows: Set<SeerrClient.BrowseRow> = []
    @State private var isLoading = true
    @State private var error: String?

    private var seerr: SeerrClient { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                #if os(tvOS)
                PageHeading(title: Self.title)
                #endif
                if !seerr.isConnected {
                    EmptyState(
                        symbol: "plus.rectangle.on.rectangle",
                        title: seerr.needsReconnect ? "Reconnect to Seerr" : "Requests aren't set up",
                        message: seerr.needsReconnect
                            ? "The connection to Seerr has run out. Reconnect in Settings, under Account."
                            : "Connect a Seerr server in Settings, under Account, to ask for films and shows."
                    )
                    .testAnchor(TestID.Requests.notConnected)
                } else {
                    if seerr.postersOff { postersOffNotice }
                    yours
                    ForEach(SeerrClient.BrowseRow.allCases) { row in
                        if let results = rows[row] {
                            RequestShelf(title: row.title, results: results, key: row.rawValue)
                        } else if !failedRows.contains(row) {
                            SkeletonShelf()
                                .testAnchor(TestID.Requests.shelfLoading(row.rawValue))
                        }
                    }
                    SeerrCredit()
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusOnArrival()
        .screenTitle(Self.title)
        .paletteBar()
        // Asked again whenever a request is made or withdrawn anywhere.
        .task(id: seerr.requestsChanged) { await load() }
        #if os(iOS)
        .refreshable { await load() }
        #endif
        .testAnchor(TestID.Requests.root)
    }

    // MARK: - Your requests

    /// What this account has asked for, as one carousel of posters, each
    /// with where its request stands.
    @ViewBuilder
    private var yours: some View {
        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
            Text("Your Requests")
                .font(headingFont)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Metrics.gutter)
            if isLoading, mine.isEmpty {
                SkeletonShelf(heading: false)
            } else if let error, mine.isEmpty {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, Metrics.gutter)
                    .accessibilityIdentifier(TestID.Requests.mineError)
            } else if mine.isEmpty {
                Text("Nothing requested yet. Search for a film or a show, or pick one below.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, Metrics.gutter)
                    .accessibilityIdentifier(TestID.Requests.mineEmpty)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                        ForEach(mine) { request in
                            Button {
                                open(request)
                            } label: {
                                RequestCard(request: request, title: names[request.id])
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PosterButtonStyle())
                            .accessibilityIdentifier(TestID.Requests.row(request.id))
                            #if os(macOS)
                            .help(names[request.id]?.displayTitle ?? "")
                            #endif
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.shelfCardPadding)
                }
                .focusRegion()
            }
        }
        .testAnchor(TestID.Requests.mine)
    }

    /// Seerr's Cache Images is off, so every poster on this page is blank.
    private var postersOffNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(SeerrCopy.postersOffTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(SeerrCopy.postersOff)
                    .font(.footnote)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, Metrics.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(TestID.Requests.postersOff)
    }

    private var headingFont: Font {
        #if os(iOS)
        return Metrics.phoneLayout ? .headline : .title2.weight(.bold)
        #elseif os(macOS)
        return .title2.weight(.bold)
        #else
        return .title3.weight(.semibold)
        #endif
    }

    private func open(_ request: SeerrRequest) {
        guard let kind = request.kind, let tmdbId = request.media?.tmdbId else { return }
        if SeerrStanding(request: request) == .available, let id = request.media?.libraryItemId {
            app.push(.item(id))
        } else {
            app.push(.request(kind: kind, tmdbId: tmdbId))
        }
    }

    // MARK: - Loading

    /// The page's name: the server it shows, named as its makers name it.
    static let title = "Seerr"

    private func load() async {
        guard seerr.isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        // The rows don't wait on the requests: both are asked for at once.
        async let browsed: Void = loadRows()
        // Picks up Cache Images being turned on (or off) since the last look.
        await seerr.refreshAccount()
        do {
            let page = try await seerr.myRequests()
            guard !Task.isCancelled else { return }
            mine = page.results ?? []
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        await loadNames()
        await browsed
    }

    /// Each request's name and poster, all asked for together.
    private func loadNames() async {
        let wanted = mine.compactMap { request -> (Int, SeerrMediaKind, Int)? in
            guard names[request.id] == nil, let kind = request.kind, let tmdbId = request.media?.tmdbId else { return nil }
            return (request.id, kind, tmdbId)
        }
        await withTaskGroup(of: (Int, SeerrTitle?).self) { group in
            for (id, kind, tmdbId) in wanted {
                group.addTask { (id, try? await SeerrClient.shared.title(kind, tmdbId: tmdbId)) }
            }
            for await (id, title) in group where !Task.isCancelled {
                if let title { names[id] = title }
            }
        }
    }

    /// The rows not yet here (or that failed last time), all asked for
    /// together; each replaces its placeholder as it lands.
    private func loadRows() async {
        let wanted = SeerrClient.BrowseRow.allCases.filter { rows[$0] == nil }
        failedRows.subtract(wanted)
        await withTaskGroup(of: (SeerrClient.BrowseRow, SeerrPage?).self) { group in
            for row in wanted {
                group.addTask { (row, try? await SeerrClient.shared.browse(row)) }
            }
            for await (row, page) in group {
                if let page {
                    rows[row] = (page.results ?? []).filter { $0.kind != nil }
                } else if !Task.isCancelled {
                    failedRows.insert(row)
                }
            }
        }
    }
}

/// Where this page's titles come from. Seerr is the server answering; its
/// films, shows and posters are TMDB's, whose terms ask for this line.
struct SeerrCredit: View {
    var body: some View {
        Text(SeerrCopy.credit)
            .font(.caption)
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .accessibilityIdentifier(TestID.Requests.credit)
    }
}

/// One request in the carousel: its poster with where it stands on it, its
/// name, and what was asked for.
private struct RequestCard: View {
    let request: SeerrRequest
    let title: SeerrTitle?
    var width: CGFloat? = Metrics.posterWidth

    private var standing: SeerrStanding { SeerrStanding(request: request) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardTextSpacing) {
            RequestPoster(path: title?.posterPath, title: title?.displayTitle ?? "")
                .frame(width: width)
                .cardChrome()
                .overlay(alignment: .topLeading) {
                    if let badge = standing.badge {
                        StandingBadge(text: badge, symbol: standing.symbol)
                            .padding(6)
                    }
                }
                .artworkFocus()
            VStack(alignment: .leading, spacing: 1) {
                Text(title?.displayTitle ?? " ")
                    .font(titleFont.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(subtitleFont)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textDim)
                Text(standing.label)
                    .font(subtitleFont.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(tone)
                    .accessibilityIdentifier(TestID.Requests.rowStatus(request.id))
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var tone: Color {
        switch standing {
        case .available: Theme.ok
        case .declined, .failed: Theme.warn
        default: Theme.textBody
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let year = title?.year { parts.append(year) }
        parts.append(request.kind == .tv ? "Show" : "Film")
        if request.kind == .tv {
            let numbers = (request.seasons ?? []).compactMap(\.seasonNumber).sorted()
            if !numbers.isEmpty {
                parts.append(numbers.map { "S\($0)" }.joined(separator: ", "))
            }
        }
        if request.is4k == true { parts.append("4K") }
        return parts.joined(separator: " · ")
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
