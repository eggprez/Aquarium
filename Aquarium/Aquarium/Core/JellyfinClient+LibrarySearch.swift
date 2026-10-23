//  A library page's search: the server's own search inside one parent, for
//  the Mac's toolbar field and the iPad's filter header. A phone has no
//  field; a television no keyboard.

import Foundation

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
        return try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))")
    }
}
