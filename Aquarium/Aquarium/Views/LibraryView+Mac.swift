//  What a library page needs on the Mac and nowhere else: filters that are
//  remembered per library, a search field that narrows the library rather
//  than the whole server, and actions that act on a selection of many.
//
//  Kept out of `LibraryView` so the page reads as one flow on every platform
//  and the Mac's extras are all in one place.

#if os(macOS)
import SwiftUI

// MARK: - Filters remembered per library

/// The controls a library page was left on: sort, direction, the two toggles
/// and the genre. A Mac window's filters are part of the window's state, and
/// the sidebar keeps one page and hands it library after library — so without
/// this, moving from Films to Shows and back would forget that Films was
/// sorted by rating, unwatched only.
///
/// Keyed by the library's id in the defaults, so each library keeps its own.
/// The search term is deliberately not here: a filter you typed is one you
/// meant for now, not for next week.
struct LibraryFilters: Codable, Equatable {
    var sort: LibraryView.SortOption = .name
    var reversed = false
    var unwatchedOnly = false
    var favouritesOnly = false
    var genre: String?

    private static func key(_ parentId: String) -> String { "libraryFilters.\(parentId)" }

    static func load(for parentId: String) -> LibraryFilters {
        guard let data = UserDefaults.standard.data(forKey: key(parentId)),
              let saved = try? JSONDecoder().decode(LibraryFilters.self, from: data)
        else { return LibraryFilters() }
        return saved
    }

    func save(for parentId: String) {
        // The defaults are the absence of a record, so a library put back the
        // way it started leaves nothing behind.
        if self == LibraryFilters() {
            UserDefaults.standard.removeObject(forKey: Self.key(parentId))
        } else if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(parentId))
        }
    }
}

// MARK: - Searching within one library

extension JellyfinClient {
    /// The fields a list row draws — `listFields` in the client proper, which
    /// is private to it. Kept in step by hand; a field missing here shows up
    /// as a blank cell in the table, not as a failure.
    private static let librarySearchFields =
        "PrimaryImageAspectRatio,Overview,Genres,UserData,SeriesPrimaryImage,ChildCount,RecursiveItemCount,ProductionYear,RunTimeTicks,OfficialRating,CommunityRating,ParentId"

    /// `libraryItems`, narrowed to titles matching `term`. The server's own
    /// search inside a parent, so a filtered list of a few thousand films is
    /// filtered as a whole and paged, sorted and filtered like the unfiltered
    /// one. With no term it is the ordinary call, local copy and all.
    func libraryItems(parentId: String, query: LibraryQuery, searchTerm: String) async throws -> ItemsResponse {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return try await libraryItems(parentId: parentId, query: query) }
        guard let s = prefs.session else { throw APIError.notConfigured }
        var q = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "searchTerm", value: term),
            URLQueryItem(name: "SortBy", value: query.sortBy),
            URLQueryItem(name: "SortOrder", value: query.sortOrder),
            URLQueryItem(name: "Fields", value: Self.librarySearchFields),
            URLQueryItem(name: "StartIndex", value: String(query.startIndex)),
            URLQueryItem(name: "Limit", value: String(query.limit)),
        ]
        if let t = query.includeTypes {
            q.append(.init(name: "IncludeItemTypes", value: t))
        } else {
            q.append(.init(name: "ExcludeItemTypes", value: Self.nonVideoTypes))
        }
        if query.unwatched { q.append(.init(name: "Filters", value: "IsUnplayed")) }
        if query.favorites { q.append(.init(name: "IsFavorite", value: "true")) }
        if let g = query.genre { q.append(.init(name: "Genres", value: g)) }
        return try await get(ItemsResponse.self, "/Users/\(s.userId)/Items?\(Self.encode(q))")
    }
}

// MARK: - Acting on a selection

/// The actions that make sense for several items at once — watched state and
/// favorites — as menu items, for a toolbar menu over the grid and for the
/// table's context menu. The server has no bulk call for either, so each item
/// is asked for in turn; the page reloads once at the end through
/// `ItemMutations`, the way a single change does.
///
/// What is offered follows the selection: "Mark as Watched" only while
/// something selected is unwatched, "Add to Favorites" only while something
/// isn't one, so a menu over an all-watched selection doesn't offer to watch
/// it again.
struct LibrarySelectionMenu: View {
    /// Every item on the page; the selection is looked up in it.
    let items: [BaseItem]
    let selection: Set<String>

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    private var selected: [BaseItem] { items.filter { selection.contains($0.Id) } }

    var body: some View {
        let chosen = selected
        let anyUnwatched = chosen.contains { !$0.userData.played }
        let anyWatched = chosen.contains { $0.userData.played }
        let anyNotFavorite = chosen.contains { !$0.userData.isFavorite }
        let anyFavorite = chosen.contains { $0.userData.isFavorite }

        if anyUnwatched {
            Button {
                Task { await mark(chosen.filter { !$0.userData.played }, played: true) }
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
        }
        if anyWatched {
            Button {
                Task { await mark(chosen.filter { $0.userData.played }, played: false) }
            } label: {
                Label("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle")
            }
        }
        if anyNotFavorite {
            Button {
                Task { await favorite(chosen.filter { !$0.userData.isFavorite }, favorite: true) }
            } label: {
                Label("Add to Favorites", systemImage: "star")
            }
        }
        if anyFavorite {
            Button {
                Task { await favorite(chosen.filter { $0.userData.isFavorite }, favorite: false) }
            } label: {
                Label("Remove from Favorites", systemImage: "star.slash")
            }
        }
    }

    private func mark(_ items: [BaseItem], played: Bool) async {
        var failed = 0
        for item in items {
            do { try await client.markPlayed(item.Id, played: played) } catch { failed += 1 }
        }
        ItemMutations.shared.changed()
        if failed > 0 {
            app.presentAlert(
                title: played ? "Couldn't Mark as Watched" : "Couldn't Mark as Unwatched",
                message: "\(failed) of \(items.count) item\(items.count == 1 ? "" : "s") couldn't be updated."
            )
        }
    }

    private func favorite(_ items: [BaseItem], favorite: Bool) async {
        var failed = 0
        for item in items {
            do { try await client.setFavorite(item.Id, favorite: favorite) } catch { failed += 1 }
        }
        ItemMutations.shared.changed()
        if failed > 0 {
            app.presentAlert(
                title: favorite ? "Couldn't Add to Favorites" : "Couldn't Remove from Favorites",
                message: "\(failed) of \(items.count) item\(items.count == 1 ? "" : "s") couldn't be updated."
            )
        }
    }
}

/// The toolbar's handle on the selection: a menu of `LibrarySelectionMenu`,
/// titled with how many are selected. Nothing at all with nothing selected
/// — a disabled menu would be a control with no meaning yet.
struct LibrarySelectionToolbarMenu: View {
    let items: [BaseItem]
    let selection: Set<String>

    var body: some View {
        Menu {
            LibrarySelectionMenu(items: items, selection: selection)
        } label: {
            Label("\(selection.count) Selected", systemImage: "checkmark.circle")
        }
        .help("Act on the \(selection.count) selected item\(selection.count == 1 ? "" : "s")")
    }
}

// MARK: - Nothing matched

/// The system's "No Results" page, for a search or a set of filters that left
/// nothing, with the way out on it. `ContentUnavailableView.search` draws the
/// same thing but has nowhere for a button.
struct LibraryNoResults: View {
    var searchTerm: String
    var hasFilters: Bool
    var clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "magnifyingglass")
        } description: {
            Text(description)
        } actions: {
            Button(hasFilters ? "Clear Filters" : "Clear Search", action: clear)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var title: String {
        searchTerm.isEmpty ? "No Results" : "No Results for “\(searchTerm)”"
    }

    private var description: String {
        switch (searchTerm.isEmpty, hasFilters) {
        case (false, true): "Nothing in this library matches the search and the filters."
        case (false, false): "Check the spelling or try a different search."
        default: "Nothing in this library matches the filters."
        }
    }
}
#endif
