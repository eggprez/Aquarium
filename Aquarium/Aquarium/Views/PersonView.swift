//  Someone from a cast list: who they are, and what of theirs is here.
//
//  A name used to search for itself, which found the person's films only by
//  way of whatever else the word matched — "Ford" is a director, an actor and
//  a film about a car company. The server already knows which titles a person
//  is credited on, by id, so the page asks it that instead.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PersonView: View {
    let personId: String
    let name: String

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var person: BaseItem?
    @State private var films: [BaseItem] = []
    @State private var shows: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var showsWholeBio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if isLoading, films.isEmpty, shows.isEmpty {
                    SkeletonGrid(count: 6)
                } else if let error, films.isEmpty, shows.isEmpty {
                    ErrorState(error: error) { Task { await load() } }
                } else if films.isEmpty, shows.isEmpty {
                    EmptyState(
                        symbol: "person.crop.rectangle.stack",
                        title: "Nothing else of theirs here",
                        message: "No other film or show in your libraries credits \(displayName)."
                    )
                } else {
                    #if os(macOS)
                    // A grid under each heading: a filmography is a list to
                    // scan and select from, and a Mac window is wide enough
                    // to show it whole rather than a row at a time. The grid
                    // brings the Mac's own selection, arrows and menu with it.
                    filmographyGrid(title: films.count == 1 ? "Film" : "Films", items: films)
                    filmographyGrid(title: shows.count == 1 ? "Show" : "Shows", items: shows)
                    #else
                    // Shelves, not one grid: "was in these films" and "was in
                    // these shows" are two answers, and a television can walk
                    // a shelf without a page of tiles between it and the top.
                    MediaShelf(title: films.count == 1 ? "Film" : "Films", items: films) { app.push(.item($0.Id)) }
                    MediaShelf(title: shows.count == 1 ? "Show" : "Shows", items: shows) { app.push(.item($0.Id)) }
                    #endif
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .screenTitle(displayName)
        .paletteBar()
        .task(id: personId) { await load() }
        #if os(macOS)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isLoading {
                    // Still asking, without a skeleton over what is already
                    // shown: the credits arrive before the biography does.
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    openWindow(id: RouteWindow.id, value: Route.person(id: personId, name: displayName))
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
                .help("Open in New Window")
            }
        }
        #endif
    }

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow

    @ViewBuilder
    private func filmographyGrid(title: String, items: [BaseItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Metrics.gutter)
                MediaGrid(items: items) { app.push(.item($0.Id)) }
            }
        }
    }
    #endif

    private var displayName: String { person?.Name ?? (name.isEmpty ? "Person" : name) }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.gutter) {
            // Plenty of people in a cast list have no picture on the server;
            // an empty dark slab said "still loading" for ever.
            ZStack {
                #if os(macOS)
                // The system's fill for a well with nothing in it, at the
                // Mac's corner radius, which is smaller than a phone's.
                Rectangle().fill(.quaternary)
                Image(systemName: "person.fill")
                    .font(.system(size: portraitSize.width * 0.4))
                    .foregroundStyle(.tertiary)
                #else
                Theme.raised
                Image(systemName: "person.fill")
                    .font(.system(size: portraitSize.width * 0.4))
                    .foregroundStyle(Theme.textDim.opacity(0.5))
                #endif
                RemoteImage(url: portraitURL, placeholderFill: Self.clear)
            }
            .frame(width: portraitSize.width, height: portraitSize.height)
            .clipShape(RoundedRectangle(cornerRadius: portraitRadius, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                #if os(tvOS)
                // No navigation bar to carry it on a television.
                Text(displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.text)
                #endif
                if let facts, !facts.isEmpty {
                    Text(facts)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .macSelectable()
                }
                if let bio = person?.Overview, !bio.isEmpty {
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(Theme.textBody)
                        .lineLimit(showsWholeBio ? nil : bioLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .macSelectable()
                    // A button rather than a tap on the text: a television can
                    // only scroll to what can take focus, and a biography that
                    // runs off the screen would otherwise be out of reach.
                    if bio.count > 320 {
                        Button(showsWholeBio ? "Show Less" : "Read More") {
                            withAnimation(.easeOut(duration: 0.2)) { showsWholeBio.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                        #if os(tvOS)
                        .appButtonStyle()
                        #elseif os(macOS)
                        // A link, which is what a "Read More" is: words that
                        // do something, in the colour the system gives them.
                        .buttonStyle(.link)
                        .help(showsWholeBio ? "Show Less" : "Read More")
                        #else
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        #endif
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.gutter)
        .focusRegion()
    }

    private static let clear = LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom)

    private var portraitSize: CGSize {
        #if os(tvOS)
        CGSize(width: 220, height: 330)
        #else
        CGSize(width: 110, height: 165)
        #endif
    }

    private var portraitRadius: CGFloat {
        #if os(macOS)
        8
        #else
        12
        #endif
    }

    private var bioLines: Int {
        #if os(tvOS)
        5
        #else
        6
        #endif
    }

    private var portraitURL: URL? {
        guard let tag = person?.ImageTags?["Primary"] ?? person?.PrimaryImageTag else { return nil }
        return Artwork.person(Person(Id: personId, PrimaryImageTag: tag), width: 440)
    }

    /// "Born 12 March 1960 · Dublin, Ireland", as far as the server knows.
    private var facts: String? {
        guard let person else { return nil }
        var parts: [String] = []
        // The server files a birthday as midnight UTC. Read in local time
        // that is the evening before, anywhere west of Greenwich.
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        if let born = Format.parseDate(person.PremiereDate) {
            if let died = Format.parseDate(person.EndDate) {
                parts.append("\(born.formatted(style)) – \(died.formatted(style))")
            } else {
                parts.append("Born \(born.formatted(style))")
            }
        }
        if let place = person.ProductionLocations?.first(where: { !$0.isEmpty }) { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        async let who = try? client.item(personId)
        do {
            let credits = try await client.items(withPerson: personId)
            guard !Task.isCancelled else { return }
            films = credits.filter { $0.kind == "Movie" }
            shows = credits.filter { $0.kind == "Series" }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if let found = await who, !Task.isCancelled { person = found }
    }
}

// MARK: - Trailers

/// Which trailer a title has, and how one that lives on the web gets opened.
enum Trailers {
    static func has(_ item: BaseItem) -> Bool {
        guard item.kind == "Movie" || item.kind == "Series" else { return false }
        return (item.LocalTrailerCount ?? 0) > 0 || remote(item) != nil
    }

    /// The first remote trailer with an address that can actually be opened.
    static func remote(_ item: BaseItem) -> URL? {
        for trailer in item.RemoteTrailers ?? [] {
            guard let raw = trailer.Url, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
            else { continue }
            return url
        }
        return nil
    }

    /// The video id in a YouTube address, which is what nearly every remote
    /// trailer is.
    static func youTubeID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty || id == "/" ? nil : id
        }
        guard host.hasSuffix("youtube.com") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "v" }?.value
    }

    /// Hand a trailer's address to the system. False when nothing took it.
    ///
    /// A phone or a Mac opens it in the YouTube app or the browser. A
    /// television has no browser, so the only door is the YouTube app's own
    /// link — and whether that app is installed is only known by trying.
    @MainActor
    static func open(_ url: URL) async -> Bool {
        #if os(tvOS)
        guard let id = youTubeID(url), let link = URL(string: "youtube://watch/\(id)") else { return false }
        return await UIApplication.shared.open(link)
        #elseif os(iOS)
        return await UIApplication.shared.open(url)
        #else
        return NSWorkspace.shared.open(url)
        #endif
    }
}
