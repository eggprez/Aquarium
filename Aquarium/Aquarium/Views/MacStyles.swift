//  What a pointer gets that a finger and a remote don't: hover fills, the
//  selection ring, the paging chevrons on a shelf. Everything here is a no-op
//  on iOS and tvOS, so the screens can use it without a platform check.

import SwiftUI

extension View {
    /// The fill a system list row draws when the pointer rests on it — the
    /// label colour at a few percent, in a rounded rect a little larger than
    /// the content. For any row or tile that is clickable and would otherwise
    /// give no sign of it. Nothing at all where there is no pointer.
    @ViewBuilder
    func macHover(cornerRadius: CGFloat = 8, inset: CGFloat = 0) -> some View {
        #if os(macOS)
        modifier(MacHoverFill(cornerRadius: cornerRadius, inset: inset))
        #else
        self
        #endif
    }

    /// The Mac's whole-tile hover and selection treatment for a poster, a
    /// still, a library tile: a faint fill and an accent ring under the
    /// pointer, a stronger ring when the tile is selected. See `PosterHover`.
    @ViewBuilder
    func macTileState(isSelected: Bool = false, radius: CGFloat = Theme.cornerRadius) -> some View {
        #if os(macOS)
        modifier(PosterHover(radius: radius, isSelected: isSelected))
        #else
        self
        #endif
    }
}

#if os(macOS)
struct MacHoverFill: ViewModifier {
    var cornerRadius: CGFloat
    var inset: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.hover)
                    .padding(-inset)
                    .opacity(isHovering ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// The pointer resting on a tile, and the tile being the one selected.
///
/// The whole tile, text included, rather than the artwork alone: a Mac tile
/// is a thing you select, and the selection has to enclose the name as well
/// as the picture or the name reads as belonging to the tile above. The ring
/// is the accent colour — a white stroke, which is what this was, is invisible
/// on a light window — and it sits a few points outside the artwork rather
/// than on its edge, so it is a ring around the tile and not a border on the
/// poster. There is no scale: a lift grew past the shelf's bounds and was cut
/// off top and bottom, and a tile that changes size under the pointer moves
/// the text around it.
struct PosterHover: ViewModifier {
    var radius: CGFloat = Theme.cornerRadius
    var isSelected: Bool = false
    /// How far outside the content the ring and the fill sit.
    var inset: CGFloat = 5
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius + inset, style: .continuous)
                    .fill(fill)
                    .padding(-inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius + inset, style: .continuous)
                    .strokeBorder(ring, lineWidth: isSelected ? 2 : 1)
                    .padding(-inset)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if isSelected { return Theme.accentSoft }
        return isHovering ? Theme.hover : .clear
    }

    private var ring: Color {
        if isSelected { return Color.accentColor }
        return isHovering ? Color.accentColor.opacity(0.45) : .clear
    }
}

/// A ‹ or › over the edge of a shelf: a circle of material with a chevron in
/// it, the way the TV app pages a row. Shown only while the pointer is over
/// the shelf, which is the caller's business.
struct ShelfPagingButton: View {
    enum Direction { case back, forward }
    var direction: Direction
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(direction == .back ? "Previous" : "Next")
        .accessibilityLabel(direction == .back ? "Previous" : "Next")
    }
}

/// How many cards of at least `minimum` points fit across `available` points
/// with `spacing` between them, and how wide each is when they share the
/// remainder — so a shelf ends on a whole card rather than half of one.
enum ShelfLayout {
    static func fit(available: CGFloat, minimum: CGFloat, spacing: CGFloat) -> (count: Int, width: CGFloat) {
        guard available > minimum else { return (1, max(minimum, available)) }
        let count = max(1, Int(((available + spacing) / (minimum + spacing)).rounded(.down)))
        let width = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (count, width.rounded(.down))
    }
}
#endif
