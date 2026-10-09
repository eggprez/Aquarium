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

    /// Called with each letter the finger lands on.
    var onSelect: (String) -> Void

    @State private var current: String?
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(Self.letters.count)
            let rowHeight = min(16, max(8.5, (geo.size.height - 24) / count))
            let fontSize = min(11, max(6.5, rowHeight - 2.5))
            let stripHeight = rowHeight * count + 8
            let top = max(0, (geo.size.height - stripHeight) / 2)
            VStack(spacing: 0) {
                ForEach(Self.letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
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
        .frame(width: 24)
        .padding(.trailing, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Index")
        .accessibilityHint("Drag to jump to a letter")
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
    /// compares it.
    static func key(_ item: BaseItem) -> String {
        (item.SortName ?? item.Name ?? "").lowercased()
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
    /// The strip, down the trailing edge of a scroll view, while `shown`.
    @ViewBuilder
    func letterIndex(shown: Bool, onSelect: @escaping (String) -> Void) -> some View {
        overlay(alignment: .trailing) {
            if shown { LetterIndexBar(onSelect: onSelect) }
        }
    }
}

#endif
