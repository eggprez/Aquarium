//  The Requests section: what this account has asked for and how far each
//  request has got, then rows of things worth asking for.

import SwiftUI

struct RequestsView: View {
    @Environment(AppModel.self) private var app

    @State private var mine: [SeerrRequest] = []
    /// What each request is a request *for*. Seerr's list names titles only by
    /// TMDB id, so each row's name and poster are looked up (and remembered
    /// by the client).
    @State private var names: [Int: SeerrTitle] = [:]
    @State private var rows: [SeerrClient.BrowseRow: [SeerrResult]] = [:]
    @State private var isLoading = true
    @State private var error: String?

    private var seerr: SeerrClient { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                #if os(tvOS)
                PageHeading(title: "Requests")
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
                    yours
                    ForEach(SeerrClient.BrowseRow.allCases) { row in
                        RequestShelf(title: row.title, results: rows[row] ?? [], key: row.rawValue)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusOnArrival()
        .screenTitle("Requests")
        .paletteBar()
        // Asked again whenever a request is made or withdrawn anywhere.
        .task(id: seerr.requestsChanged) { await load() }
        #if os(iOS)
        .refreshable { await load() }
        #endif
        .testAnchor(TestID.Requests.root)
    }

    // MARK: - Your requests

    @ViewBuilder
    private var yours: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Requests")
                .font(headingFont)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 4)
            if isLoading, mine.isEmpty {
                SkeletonList(count: 3)
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
                ForEach(mine) { request in
                    Button {
                        open(request)
                    } label: {
                        RequestRow(request: request, title: names[request.id])
                            .padding(.vertical, 6)
                            .padding(.horizontal, Metrics.gutter)
                            .contentShape(Rectangle())
                    }
                    .rowButtonStyle()
                    .accessibilityIdentifier(TestID.Requests.row(request.id))
                }
            }
        }
        .focusRegion()
        .testAnchor(TestID.Requests.mine)
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

    private func load() async {
        guard seerr.isConnected else { return }
        isLoading = true
        defer { isLoading = false }
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
        for request in mine where names[request.id] == nil {
            guard let kind = request.kind, let tmdbId = request.media?.tmdbId else { continue }
            if let title = try? await seerr.title(kind, tmdbId: tmdbId) { names[request.id] = title }
            if Task.isCancelled { return }
        }
        for row in SeerrClient.BrowseRow.allCases where rows[row] == nil {
            if let page = try? await seerr.browse(row) {
                rows[row] = (page.results ?? []).filter { $0.kind != nil }
            }
            if Task.isCancelled { return }
        }
    }
}

/// One request: its poster, what it is, and where it stands.
private struct RequestRow: View {
    let request: SeerrRequest
    let title: SeerrTitle?

    private var standing: SeerrStanding { SeerrStanding(request: request) }

    private var thumb: CGFloat {
        #if os(tvOS)
        90
        #else
        52
        #endif
    }

    var body: some View {
        HStack(spacing: 14) {
            RequestPoster(path: title?.posterPath, title: "")
                .frame(width: thumb)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title?.displayTitle ?? " ")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Label(standing.label, systemImage: standing.symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tone)
                    .accessibilityIdentifier(TestID.Requests.rowStatus(request.id))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .hiddenOnTV()
        }
    }

    private var tone: Color {
        switch standing {
        case .available: Theme.ok
        case .declined, .failed: Theme.warn
        default: Theme.textBody
        }
    }

    private var detail: String {
        var parts: [String] = [request.kind == .tv ? "Show" : "Film"]
        if let year = title?.year { parts.append(year) }
        if request.kind == .tv {
            let numbers = (request.seasons ?? []).compactMap(\.seasonNumber).sorted()
            if !numbers.isEmpty {
                parts.append("Season\(numbers.count == 1 ? "" : "s") " + numbers.map(String.init).joined(separator: ", "))
            }
        }
        if request.is4k == true { parts.append("4K") }
        return parts.joined(separator: " · ")
    }
}
