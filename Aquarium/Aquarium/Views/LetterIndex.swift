//  The A–Z strip down the edge of a list sorted by name.
//
//  A touch on it, or a drag along it, jumps the list to the first name at
//  or after that letter, the way Contacts does. The lists it sits on are
//  paged from the server, so a letter past what has been loaded is asked
//  for as a count — how many names sort before it — and the pages up to
//  that point are fetched in one request before the jump. "#" is the top:
//  numbers and symbols sort before any letter.
//
//  iPhone and iPad only. The Mac has a keyboard, and the television a
//  directional pad that would have to cross the strip to reach the grid.

import SwiftUI

#if os(iOS)

struct LetterIndexBar: View {
    static let letters: [String] = ["#"] + (0..<26).map { String(Character(UnicodeScalar(65 + $0)!)) }

    /// How much of the trailing edge the strip takes: its column and the
    /// margin after it.
    static let width: CGFloat = 26

    /// The shortest row every letter is still legible in.
    static let readableRow: CGFloat = 11.5

    /// Called with each letter the finger lands on.
    var onSelect: (String) -> Void

    @Environment(\.bottomChromeTop) private var chromeTop
    @State private var current: String?
    @State private var dragging = false
    /// Where the overlay's own frame ends, in global points.
    @State private var foot: CGFloat?

    /// How far past its frame the strip reaches: down to where the bars
    /// along the bottom begin, where the shell says (`bottomChromeTop`).
    /// The scroll view's safe area ended well above the bars on a page
    /// with the offline strip up — the strip sat squashed in the top of
    /// the list with a dead stretch under it.
    private var reach: CGFloat {
        guard let chromeTop, let foot else { return 0 }
        return max(0, (chromeTop - foot).rounded())
    }

    var body: some View {
        Color.clear
            .frame(width: Self.width - 2)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { foot = $0 }
            .overlay(alignment: .top) {
                strip.padding(.bottom, -reach)
            }
            .padding(.trailing, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Index")
            .accessibilityHint("Drag to jump to a letter")
    }

    private var strip: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let count = CGFloat(Self.letters.count)
            let rowHeight = min(16, max(7, (height - 24) / count))
            // Where the page is short — a mini player, the offline strip
            // and the tab bar stacked under it — the letters shrank until
            // they could not be read. Below a readable row every other
            // letter is drawn, with a dot for the one between, as the
            // Contacts index does; all twenty-seven still take the finger.
            let abridged = rowHeight < Self.readableRow
            let fontSize = abridged ? 10.5 : min(11, max(9, rowHeight - 2.5))
            let stripHeight = rowHeight * count + 8
            let top = max(0, (height - stripHeight) / 2)
            VStack(spacing: 0) {
                ForEach(Array(Self.letters.enumerated()), id: \.offset) { index, letter in
                    Group {
                        if abridged, !index.isMultiple(of: 2) {
                            Circle().frame(width: 3, height: 3)
                        } else {
                            Text(letter)
                                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                                .fixedSize()
                        }
                    }
                    .frame(width: 16, height: rowHeight)
                }
            }
            .padding(.vertical, 4)
            .foregroundStyle(Theme.accent)
            .background(
                Capsule().fill(Theme.raised.opacity(dragging ? 0.95 : 0))
            )
            .frame(maxWidth: .infinity)
            .offset(y: top)
            .overlay(alignment: .topLeading) {
                if dragging, let current, let i = Self.letters.firstIndex(of: current) {
                    bubble(current)
                        .offset(x: -52, y: top + 4 + rowHeight * (CGFloat(i) + 0.5) - 22)
                }
            }
            .frame(height: height, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        dragging = true
                        let row = Int(((value.location.y - top - 4) / rowHeight).rounded(.down))
                        let letter = Self.letters[min(Self.letters.count - 1, max(0, row))]
                        guard letter != current else { return }
                        current = letter
                        onSelect(letter)
                    }
                    .onEnded { _ in
                        dragging = false
                        current = nil
                    }
            )
            .sensoryFeedback(.selection, trigger: current)
        }
    }

    private func bubble(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.text)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Theme.raised))
            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .transition(.opacity)
    }
}

/// Where a letter lands in a list of names.
enum LetterIndex {
    /// Fewer than this and the list fits a flick: no strip.
    static let minimumCount = 20

    /// The name the server sorts an item by, lowercased as the server
    /// compares it. A song's title, not its `SortName`: the server prefixes
    /// that with the disc and track numbers, and songs are listed by title
    /// (see `JellyfinClient.sortBy`).
    static func key(_ item: BaseItem) -> String {
        if item.kind == "Audio" { return (item.Name ?? "").lowercased() }
        return (item.SortName ?? item.Name ?? "").lowercased()
    }

    /// Whether a name sorts at or after `letter`. "#" is before everything.
    static func isAtOrAfter(_ key: String, _ letter: String) -> Bool {
        guard letter != "#" else { return true }
        return key.compare(letter.lowercased(), options: [.diacriticInsensitive]) != .orderedAscending
    }

    /// The first of `items` at or after `letter`, by `key`.
    static func first(in items: [BaseItem], atOrAfter letter: String, key: (BaseItem) -> String = key) -> BaseItem? {
        guard letter != "#" else { return items.first }
        return items.first { isAtOrAfter(key($0), letter) }
    }
}

extension View {
    /// The strip, down the trailing edge of a scroll view, while `shown` —
    /// and the scroll view's content moved in to clear it.
    ///
    /// The strip is wider than the page's gutter, so laid over the content
    /// as it was it covered the last column's trailing edge, titles and all,
    /// and took the taps meant for those posters as touches on a letter.
    /// The margin is only what the gutter doesn't already give, plus a few
    /// points of air, so the content gives up as little as it can.
    @ViewBuilder
    func letterIndex(shown: Bool, onSelect: @escaping (String) -> Void) -> some View {
        contentMargins(.trailing, shown ? LetterIndexBar.width + 4 - Metrics.gutter : 0, for: .scrollContent)
            .overlay(alignment: .trailing) {
                if shown { LetterIndexBar(onSelect: onSelect) }
            }
    }
}

#endif
