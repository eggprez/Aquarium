//  A library as a list: the Mac's other way of looking at a collection, beside
//  the poster grid. Sortable by clicking a column heading, the way Finder and
//  Music sort theirs, and opened by double-click or Return.
//
//  Sorting stays the server's job. The table's comparators are translated into
//  the library's own sort option (and a direction), and the page asks again, so
//  a sorted list of a few thousand films is sorted as a whole and not just the
//  pages that happen to have loaded.

#if os(macOS)
import SwiftUI

struct LibraryTable: View {
    let items: [BaseItem]
    @Binding var sort: LibraryView.SortOption
    /// Whether the column's direction is the opposite of the sort's natural
    /// one — ascending for a name, descending for a rating.
    @Binding var reversed: Bool
    let onOpen: (BaseItem) -> Void
    let onReachEnd: () -> Void

    @State private var selection = Set<BaseItem.ID>()

    var body: some View {
        Table(items, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Title", value: \.tableTitle) { item in
                HStack(spacing: 10) {
                    RemoteImage(url: Artwork.poster(for: item, width: 80))
                        .frame(width: 26, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(item.title)
                        .lineLimit(1)
                    if item.userData.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.warn)
                            .help("Favorite")
                    }
                }
                .onAppear {
                    if item.Id == items.last?.Id { onReachEnd() }
                }
            }
            .width(min: 220, ideal: 340)

            TableColumn("Year", value: \.tableYear) { item in
                Text(item.ProductionYear.map(String.init) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Runtime", value: \.tableRuntime) { item in
                Text(Format.ticks(item.RunTimeTicks))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
            }
            .width(min: 60, ideal: 80, max: 110)

            TableColumn("Rated") { item in
                Text(item.OfficialRating ?? "")
                    .foregroundStyle(Theme.textDim)
            }
            .width(min: 50, ideal: 64, max: 90)

            TableColumn("Score", value: \.tableScore) { item in
                Text(item.CommunityRating.map { String(format: "%.1f", $0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Watched") { item in
                if item.userData.played {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .help("Watched")
                } else if let progress = item.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 40)
                        .help("\(Int(progress * 100))% watched")
                }
            }
            .width(min: 56, ideal: 64, max: 80)
        }
        .contextMenu(forSelectionType: BaseItem.ID.self) { ids in
            if let item = items.first(where: { ids.contains($0.Id) }) {
                ItemMenu(item: item, allowsOpen: true)
            }
        } primaryAction: { ids in
            if let item = items.first(where: { ids.contains($0.Id) }) { onOpen(item) }
        }
    }

    /// The table's idea of its sort, drawn from the page's and written back to
    /// it. Sorts with no column — recently added, random — show no arrow.
    private var sortOrder: Binding<[KeyPathComparator<BaseItem>]> {
        Binding(
            get: {
                let natural: SortOrder = sort.order == "Ascending" ? .forward : .reverse
                let order: SortOrder = reversed ? (natural == .forward ? .reverse : .forward) : natural
                switch sort {
                case .name: return [KeyPathComparator(\.tableTitle, order: order)]
                case .releaseDate: return [KeyPathComparator(\.tableYear, order: order)]
                case .runtime: return [KeyPathComparator(\.tableRuntime, order: order)]
                case .rating: return [KeyPathComparator(\.tableScore, order: order)]
                case .dateAdded, .random: return []
                }
            },
            set: { comparators in
                guard let first = comparators.first else { return }
                let path: PartialKeyPath<BaseItem> = first.keyPath
                let chosen: LibraryView.SortOption =
                    if path == \BaseItem.tableYear { .releaseDate }
                    else if path == \BaseItem.tableRuntime { .runtime }
                    else if path == \BaseItem.tableScore { .rating }
                    else { .name }
                let natural: SortOrder = chosen.order == "Ascending" ? .forward : .reverse
                sort = chosen
                reversed = first.order != natural
            }
        )
    }
}

/// Non-optional stand-ins for the fields the table sorts by; a comparator
/// needs a `Comparable` value, and the server leaves any of these out.
extension BaseItem {
    var tableTitle: String { SortName ?? title }
    var tableYear: Int { ProductionYear ?? 0 }
    var tableRuntime: Int64 { RunTimeTicks ?? 0 }
    var tableScore: Double { CommunityRating ?? 0 }
}
#endif
