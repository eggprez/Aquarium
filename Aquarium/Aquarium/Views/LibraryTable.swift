//  A library as a list: the Mac's other way of looking at a collection, beside
//  the poster grid. Sortable by clicking a column heading, the way Finder and
//  Music sort theirs, and opened by double-click or Return.
//
//  Sorting stays the server's job. The table's comparators are translated into
//  the library's own sort option (and a direction), and the page asks again, so
//  a sorted list of a few thousand films is sorted as a whole and not just the
//  pages that happen to have loaded.
//
//  The selection is the page's, not the table's: the poster grid shares it, so
//  what was selected in one view is still selected in the other, and the
//  toolbar can act on it whichever is showing.

#if os(macOS)
import SwiftUI

struct LibraryTable: View {
    let items: [BaseItem]
    @Binding var sort: LibraryView.SortOption
    /// Whether the column's direction is the opposite of the sort's natural
    /// one — ascending for a name, descending for a rating.
    @Binding var reversed: Bool
    @Binding var selection: Set<BaseItem.ID>
    let onOpen: (BaseItem) -> Void
    let onReachEnd: () -> Void

    var body: some View {
        Table(items, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Title", value: \.tableTitle) { item in
                HStack(spacing: 10) {
                    RemoteImage(url: Artwork.poster(for: item, width: 80))
                        .frame(width: 26, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(item.title)
                        .lineLimit(1)
                        // A narrow column cuts a long title short; the
                        // tooltip has the whole of it, and the show an
                        // episode belongs to.
                        .help(item.SeriesName.map { "\(item.title) — \($0)" } ?? item.title)
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
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Runtime", value: \.tableRuntime) { item in
                Text(Format.ticks(item.RunTimeTicks))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 110)

            TableColumn("Rated") { item in
                Text(item.OfficialRating ?? "")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(item.OfficialRating ?? "")
            }
            .width(min: 50, ideal: 64, max: 90)

            TableColumn("Score", value: \.tableScore) { item in
                Text(item.CommunityRating.map { String(format: "%.1f", $0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Watched") { item in
                if item.userData.played {
                    MacWatchedMark()
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
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: BaseItem.ID.self) { ids in
            if ids.count > 1 {
                // Several rows: what can be done to all of them at once.
                // The single-item menu would act on whichever came first,
                // which is not what a right-click on a selection means.
                LibrarySelectionMenu(items: items, selection: ids)
            } else if let item = items.first(where: { ids.contains($0.Id) }) {
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

/// The watched checkmark in a row: the accent colour, except on a selected
/// row in the key window, whose highlight is the accent colour too and hid it.
/// There it goes white with the row's text. The row's grey columns are
/// `.secondary` for the same reason — a fixed grey stayed grey on the blue.
struct MacWatchedMark: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            .accessibilityLabel("Watched")
    }
}
#endif
