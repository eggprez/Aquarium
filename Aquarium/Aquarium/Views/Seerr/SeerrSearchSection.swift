//  Search, carried on past the library: what Seerr knows by the same name
//  that isn't here yet.
//
//  Drawn under the library's own results, and under "No matches" when the
//  library has none, which is the case it exists for: a search that finds
//  nothing now ends in a title that can be asked for.

import SwiftUI

struct SeerrSearchSection: View {
    let term: String

    @State private var results: [SeerrResult] = []
    /// The term `results` answers.
    @State private var answered = ""

    private var seerr: SeerrClient { .shared }
    private var query: String { term.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        // The clear layer is what the search hangs from: a view that draws
        // nothing is never mounted, and its task never runs (see `RemoteImage`).
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if seerr.isConnected, answered == query {
                RequestShelf(
                    title: "Not in Your Library",
                    subtitle: "Open one to request it.",
                    results: results,
                    key: "search"
                )
            }
        }
        .task(id: query + "|\(seerr.isConnected)|\(seerr.requestsChanged)") { await search() }
    }

    private func search() async {
        let query = query
        guard seerr.isConnected, query.count >= 2 else {
            results = []
            answered = query
            return
        }
        // Longer than the library's own debounce: this one leaves the house.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        guard let page = try? await seerr.search(query), !Task.isCancelled else { return }
        results = (page.results ?? []).filter(\.isRequestable)
        answered = query
    }
}
