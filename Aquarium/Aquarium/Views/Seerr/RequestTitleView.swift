//  A title that isn't in the library: what it is, and the button that asks
//  for it.
//
//  The page a Seerr card opens. It says where the title stands (not here,
//  asked for, on its way, here), offers the one thing that can be done about
//  it, and for a show lists the seasons so some of them can be asked for
//  without the rest.

import SwiftUI

struct RequestTitleView: View {
    let kind: SeerrMediaKind
    let tmdbId: Int

    @Environment(AppModel.self) private var app

    @State private var title: SeerrTitle?
    @State private var quota: SeerrQuota?
    @State private var error: String?
    @State private var isLoading = true
    /// The seasons ticked for the request. Starts as every season that can
    /// still be asked for.
    @State private var chosenSeasons = Set<Int>()
    @State private var wants4K = false
    @State private var isSending = false
    @State private var confirmCancel = false

    private var seerr: SeerrClient { .shared }
    private var key: String { "\(kind.rawValue)-\(tmdbId)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let title {
                    header(title)
                    actions(title)
                    if let overview = title.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Metrics.gutter)
                    }
                    if kind == .tv { seasons(title) }
                    cast(title)
                } else if let error {
                    ErrorState(error: error) { Task { await load() } }
                        .testAnchor(TestID.Requests.titleError)
                } else {
                    SkeletonGrid(count: 3)
                        .testAnchor(TestID.Requests.titleLoading)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusOnArrival()
        .screenTitle(title?.displayTitle ?? "")
        .paletteBar()
        #if !os(macOS)
        .background(Theme.background)
        #endif
        .task(id: key) { await load() }
        .testAnchor(TestID.Requests.titleRoot)
        .testAnchor(TestID.Requests.titlePage(key))
        .confirmationDialog("Cancel this request?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Request", role: .destructive) { Task { await cancelMine() } }
                .accessibilityIdentifier(TestID.Requests.titleCancelConfirm)
            Button("Keep It", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var posterWidth: CGFloat {
        #if os(tvOS)
        260
        #elseif os(macOS)
        180
        #else
        Metrics.phoneLayout ? 118 : 180
        #endif
    }

    @ViewBuilder
    private func header(_ title: SeerrTitle) -> some View {
        HStack(alignment: .top, spacing: 18) {
            RequestPoster(path: title.posterPath, title: title.displayTitle)
                .frame(width: posterWidth)
                .cardChrome()
            VStack(alignment: .leading, spacing: 8) {
                Text(title.displayTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(TestID.Requests.titleName)
                Text(facts(title))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let tagline = title.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.subheadline.italic())
                        .foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let standing = SeerrStanding(media: title.mediaInfo)
                Label(standing.label, systemImage: standing.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(standing == .available ? Theme.ok : Theme.text)
                    .padding(.top, 4)
                    .accessibilityIdentifier(TestID.Requests.titleStanding)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private func facts(_ title: SeerrTitle) -> String {
        var parts: [String] = []
        if let year = title.year { parts.append(year) }
        parts.append(kind == .movie ? "Film" : "Show")
        if kind == .movie, let minutes = title.runtime, minutes > 0 {
            parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        }
        if kind == .tv {
            let count = title.realSeasons.count
            if count > 0 { parts.append("\(count) season\(count == 1 ? "" : "s")") }
        }
        let genres = (title.genres ?? []).compactMap(\.name).prefix(3)
        if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - What can be done

    private var rights: SeerrPermissions { seerr.connection?.rights ?? [] }

    /// This account's own request for the title that is still waiting, which
    /// is the one Seerr lets it take back.
    private func myPendingRequest(_ title: SeerrTitle) -> SeerrRequest? {
        guard let me = seerr.connection?.userId else { return nil }
        return title.mediaInfo?.requests?.first { $0.requestedBy?.id == me && $0.requestStatus == .pending }
    }

    private func offers4K(_ title: SeerrTitle) -> Bool {
        let enabled = kind == .movie ? seerr.connection?.settings?.movie4kEnabled : seerr.connection?.settings?.series4kEnabled
        return enabled == true && rights.canRequest4K(kind)
    }

    /// Whether there is anything left to ask for.
    private func canAsk(_ title: SeerrTitle) -> Bool {
        switch kind {
        case .movie: SeerrStanding(media: title.mediaInfo) == .requestable
        case .tv: !title.requestableSeasons.isEmpty
        }
    }

    private var outOfQuota: Bool {
        guard let allowance = quota?.allowance(for: kind) else { return false }
        return allowance.restricted == true
    }

    @ViewBuilder
    private func actions(_ title: SeerrTitle) -> some View {
        // The page opens before Seerr answers, so when the buttons arrive the
        // focus engine has already placed focus and found nothing: opened
        // from a shelf on a title page, an Apple TV sat with nothing focused
        // and the remote did nothing. The first button drawn takes focus
        // when it appears (`focusOnArrival` on the page).
        let inLibrary = title.mediaInfo?.libraryItemId != nil
            && [.available, .partiallyAvailable].contains(title.mediaInfo?.availability ?? .unknown)
        let asks = canAsk(title) && rights.canRequest(kind)
        VStack(alignment: .leading, spacing: 12) {
            if let libraryId = title.mediaInfo?.libraryItemId,
               [.available, .partiallyAvailable].contains(title.mediaInfo?.availability ?? .unknown) {
                Button {
                    app.push(.item(libraryId))
                } label: {
                    Label("Open in Library", systemImage: "play.rectangle")
                }
                .appButtonStyle(prominent: !canAsk(title))
                .accessibilityIdentifier(TestID.Requests.titleOpenInLibrary)
                .arrivalFocusCard(isFirst: true)
            }
            if canAsk(title) {
                if !rights.canRequest(kind) {
                    Text("This account can't request \(kind.noun)s. Ask whoever runs the server.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .accessibilityIdentifier(TestID.Requests.titleNotAllowed)
                } else {
                    if offers4K(title) {
                        Toggle("Ask for the 4K version", isOn: $wants4K)
                            #if !os(tvOS)
                            .toggleStyle(.switch)
                            #endif
                            .frame(maxWidth: 420)
                            .accessibilityIdentifier(TestID.Requests.title4K)
                    }
                    Button {
                        Task { await send(title) }
                    } label: {
                        HStack(spacing: 8) {
                            if isSending { ProgressView().controlSize(.small) }
                            Label(requestLabel(title), systemImage: "plus")
                        }
                    }
                    .appButtonStyle(prominent: true)
                    .disabled(isSending || outOfQuota || (kind == .tv && chosenSeasons.isEmpty))
                    .accessibilityIdentifier(TestID.Requests.titleRequest)
                    .arrivalFocusCard(isFirst: !inLibrary)
                    if let summary = quota?.allowance(for: kind)?.summary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(outOfQuota ? Theme.warn : Theme.textDim)
                            .accessibilityIdentifier(TestID.Requests.titleQuota)
                    }
                }
            }
            if myPendingRequest(title) != nil {
                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label("Cancel Request", systemImage: "xmark")
                }
                .appButtonStyle()
                .disabled(isSending)
                .accessibilityIdentifier(TestID.Requests.titleCancel)
                .arrivalFocusCard(isFirst: !inLibrary && !asks)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private func requestLabel(_ title: SeerrTitle) -> String {
        guard kind == .tv else { return "Request" }
        let open = title.requestableSeasons.count
        let chosen = chosenSeasons.count
        if chosen == open, open == title.realSeasons.count { return "Request All Seasons" }
        return "Request \(chosen) Season\(chosen == 1 ? "" : "s")"
    }

    // MARK: - Seasons

    /// Whether seasons can be ticked one at a time: Seerr's administrator can
    /// turn that off, and then a show is asked for whole.
    private var picksSeasons: Bool { seerr.connection?.settings?.partialRequestsEnabled != false }

    @ViewBuilder
    private func seasons(_ title: SeerrTitle) -> some View {
        let all = title.realSeasons
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Seasons")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 4)
                ForEach(all) { season in
                    let standing = title.standing(ofSeason: season.seasonNumber)
                    let open = standing == .requestable
                    Button {
                        guard open, picksSeasons else { return }
                        if chosenSeasons.contains(season.seasonNumber) {
                            chosenSeasons.remove(season.seasonNumber)
                        } else {
                            chosenSeasons.insert(season.seasonNumber)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: open
                                ? (chosenSeasons.contains(season.seasonNumber) ? "checkmark.circle.fill" : "circle")
                                : standing.symbol)
                                .foregroundStyle(open ? Theme.accent : Theme.textDim)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(season.name ?? "Season \(season.seasonNumber)")
                                    .foregroundStyle(Theme.text)
                                Text(seasonLine(season, standing: standing))
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textDim)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, Metrics.gutter)
                        .contentShape(Rectangle())
                    }
                    .rowButtonStyle()
                    .disabled(!open || !picksSeasons || !rights.canRequest(.tv))
                    .accessibilityIdentifier(TestID.Requests.titleSeason(season.seasonNumber))
                    .accessibilityValue(open ? (chosenSeasons.contains(season.seasonNumber) ? "selected" : "not selected") : standing.label)
                }
            }
            .focusRegion()
        }
    }

    private func seasonLine(_ season: SeerrSeason, standing: SeerrStanding) -> String {
        var parts: [String] = []
        if let count = season.episodeCount, count > 0 { parts.append("\(count) episode\(count == 1 ? "" : "s")") }
        if let year = SeerrDates.year(season.airDate) { parts.append(year) }
        if standing != .requestable { parts.append(standing.label) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func cast(_ title: SeerrTitle) -> some View {
        let names = (title.credits?.cast ?? []).compactMap(\.name).prefix(8)
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cast")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(names.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    // MARK: - Loading and sending

    private func load(fresh: Bool = false) async {
        if title == nil { isLoading = true }
        defer { isLoading = false }
        do {
            // Always asked again on the way in: the page exists to say where
            // the title stands now, not where it stood when a list was drawn.
            let found = try await seerr.title(kind, tmdbId: tmdbId, fresh: true)
            guard !Task.isCancelled else { return }
            title = found
            error = nil
            chosenSeasons = Set(found.requestableSeasons.map(\.seasonNumber))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if title == nil { self.error = error.localizedDescription }
        }
        quota = try? await seerr.quota()
        await seerr.refreshAccount()
    }

    private func send(_ title: SeerrTitle) async {
        isSending = true
        defer { isSending = false }
        do {
            let made = try await seerr.request(
                kind, tmdbId: tmdbId,
                seasons: kind == .tv ? chosenSeasons.sorted() : nil,
                is4K: wants4K
            )
            let approved = made.requestStatus == .approved
            app.toast(
                approved ? "Requested \(title.displayTitle). It's on its way."
                    : "Requested \(title.displayTitle). It's waiting for approval.",
                tone: .ok
            )
            await load()
        } catch is CancellationError {
        } catch {
            app.toast(error.localizedDescription, tone: .error)
            await load()
        }
    }

    private func cancelMine() async {
        guard let title, let mine = myPendingRequest(title) else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await seerr.cancel(mine)
            app.toast("Request cancelled")
            await load()
        } catch is CancellationError {
        } catch {
            app.toast(error.localizedDescription, tone: .error)
        }
    }
}
