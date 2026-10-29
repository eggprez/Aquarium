//  A season's episodes on the Mac: a list, with everything a list has.
//
//  The phone and the television draw the rows by hand in a lazy stack — see
//  `EpisodeRow` — because a finger wants a tall row with a still it can hit,
//  and the remote moves a selector that the row itself has to hold. A pointer
//  wants what Finder gives it: rows that alternate, a selection that ↑ and ↓
//  move and ⇧-click extends, a double-click or Return that plays, a context
//  menu that acts on whatever is selected, and a Play control that appears
//  under the pointer rather than sitting on every row.

#if os(macOS)
import SwiftUI

/// The rows, the selection and the menu. Sits inside the detail page's own
/// scroll view, so it does no scrolling itself and is exactly as tall as its
/// rows — a list that scrolled inside a page that scrolls would be two
/// scrollers fighting over one wheel.
struct MacEpisodeList: View {
    let episodes: [BaseItem]
    @Binding var selection: Set<String>
    var onPlay: (BaseItem) -> Void
    var onOpen: (BaseItem) -> Void
    /// The context menu's "Mark as Watched" for a selection: the ids, and
    /// what to mark them.
    var onMarkWatched: (Set<String>, Bool) -> Void

    /// A row's height including its insets, which is what the frame below is
    /// counted in. Compact — a still the height of two lines of text — because
    /// a season is twenty rows and a page is one screen.
    static let rowHeight: CGFloat = 64
    /// The inset list's own margin above the first row and below the last.
    private static let listPadding: CGFloat = 8

    /// How tall the rows came out, as the list itself measures them — see
    /// `MeasuresListContent`.
    @State private var measuredHeight: CGFloat?

    /// The rows' height, worked out from `rowHeight` until the list has said,
    /// and never less than that. Counted alone, a row the system drew taller —
    /// a larger text size, a list style with more air between rows — cut the
    /// last episode off at the bottom of a frame that has no scrolling to
    /// reach it with.
    private var height: CGFloat {
        let counted = CGFloat(episodes.count) * Self.rowHeight + Self.listPadding * 2
        return max(counted, measuredHeight ?? 0)
    }

    /// One row's share of `height`, for the anchors below.
    private var rowPitch: CGFloat {
        guard !episodes.isEmpty else { return Self.rowHeight }
        return (height - Self.listPadding * 2) / CGFloat(episodes.count)
    }

    /// What the page scrolls to when the selection moves onto a row — see
    /// `ItemDetailView.scroll`.
    static func anchor(for episodeId: String) -> String { "episode-row-\(episodeId)" }

    var body: some View {
        List(episodes, selection: $selection) { episode in
            MacEpisodeRow(episode: episode) { onPlay(episode) }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .scrollDisabled(true)
        .modifier(MeasuresListContent(height: $measuredHeight))
        .frame(height: height)
        // An empty band per row, laid over the list in the page's own scroll
        // view. The rows are the list's, which a `ScrollViewReader` outside it
        // can't reach; these are the page's, so it can bring one into view as
        // the arrow keys move the selection down past the window's edge.
        .background(alignment: .top) {
            VStack(spacing: 0) {
                ForEach(episodes) { episode in
                    Color.clear
                        .frame(height: rowPitch)
                        .id(Self.anchor(for: episode.Id))
                }
            }
            .padding(.top, Self.listPadding)
            .accessibilityHidden(true)
        }
        // Right-click on the rows, or double-click and Return on them: the
        // menu for the selection, and the one thing a row is for.
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            // The earliest of the selection, in the season's order. `ids` is
            // a set, and its `first` was whichever the hash put there: Return
            // on episodes 3 to 5 played any one of them.
            guard let episode = episodes.first(where: { ids.contains($0.Id) }) else { return }
            onPlay(episode)
        }
        .onChange(of: episodes.map(\.Id)) { _, ids in
            // The season reloaded: nothing selected that isn't there.
            let present = Set(ids)
            if !selection.isSubset(of: present) { selection = selection.intersection(present) }
            // And measured again: a list never reports itself shorter than
            // the frame it is in, so a season that lost a row would keep its
            // old height otherwise.
            measuredHeight = nil
        }
        .accessibilityLabel("Episodes")
    }

    /// One row held: its own menu, which already has Play, Get Info and the
    /// rest. Several: the two things that make sense for a set.
    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first, let episode = episodes.first(where: { $0.Id == id }) {
            ItemMenu(item: episode, allowsOpen: true)
        } else if !ids.isEmpty {
            let chosen = episodes.filter { ids.contains($0.Id) }
            // Offered both ways when the set is mixed; only the way that
            // changes something when it isn't.
            if chosen.contains(where: { !$0.userData.played }) {
                Button {
                    onMarkWatched(ids, true)
                } label: {
                    Label("Mark as Watched", systemImage: "checkmark.circle")
                }
            }
            if chosen.contains(where: { $0.userData.played }) {
                Button {
                    onMarkWatched(ids, false)
                } label: {
                    Label("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle")
                }
            }
        }
    }
}

/// The height of the list's rows as the list lays them out, from its own
/// scroll geometry. macOS 15 and later; on 14 the list keeps the counted
/// height.
private struct MeasuresListContent: ViewModifier {
    @Binding var height: CGFloat?

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, new in
                guard new > 0, abs((height ?? 0) - new) > 0.5 else { return }
                height = new
            }
        } else {
            content
        }
    }
}

/// One episode: still, number and name, runtime and a line of the overview,
/// and Play under the pointer. Selection is the list's, so nothing here is
/// painted in the app's own colours — a selected row's text has to invert
/// with the row, and only the system's styles do that.
struct MacEpisodeRow: View {
    let episode: BaseItem
    var onPlay: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            still
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let number = episode.IndexNumber {
                        Text("\(number).")
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.title)
                        .fontWeight(.medium)
                    if episode.userData.played {
                        MacWatchedMark()
                            .font(.caption)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 6) {
                    let runtime = Format.ticks(episode.RunTimeTicks)
                    if !runtime.isEmpty {
                        Text(runtime)
                    }
                    if let overview = episode.Overview, !overview.isEmpty {
                        if !runtime.isEmpty { Text("·") }
                        Text(overview)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Under the pointer only: twenty play glyphs in a column are
            // noise, and the row itself plays on a double-click anyway.
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .help("Play")
            .accessibilityLabel("Play \(episode.title)")
        }
        .frame(height: 56)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // The whole overview, for the line that only shows its start.
        .help(episode.Overview ?? "")
        .accessibilityElement(children: .combine)
    }

    private var still: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(
                url: Artwork.url(episode, type: "Primary", width: 300),
                blurHash: Artwork.hash(episode)
            )
            .frame(width: 100, height: 56)
            if let progress = episode.progressFraction {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.45))
                    Rectangle().fill(Color.accentColor)
                        .scaleEffect(x: min(1, max(0, progress)), y: 1, anchor: .leading)
                }
                .frame(height: 3)
            }
        }
        .frame(width: 100, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}
#endif
