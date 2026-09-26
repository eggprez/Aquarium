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

    var body: some View {
        List(episodes, selection: $selection) { episode in
            MacEpisodeRow(episode: episode) { onPlay(episode) }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .scrollDisabled(true)
        .frame(height: CGFloat(episodes.count) * Self.rowHeight + 16)
        // Right-click on the rows, or double-click and Return on them: the
        // menu for the selection, and the one thing a row is for.
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            guard let id = ids.first, let episode = episodes.first(where: { $0.Id == id }) else { return }
            onPlay(episode)
        }
        .onChange(of: episodes.map(\.Id)) { _, ids in
            // The season reloaded: nothing selected that isn't there.
            let present = Set(ids)
            if !selection.isSubset(of: present) { selection = selection.intersection(present) }
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
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Watched")
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
