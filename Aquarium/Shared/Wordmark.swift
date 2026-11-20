//  Wordmark.swift
//  Aquarium
//
//  The app's name as it is drawn wherever the app names itself: "aquarium"
//  in lowercase SF Rounded heavy, with the dot on the i swapped for one of
//  the bubbles that rise past the icon. It replaced "Aqua·rium", the split
//  carried over from FellyJin, where the two halves were two real words.
//
//  Shared by the app (every platform), the watch app and the watch widgets,
//  so the mark is the same everywhere. The Linux build draws the same thing
//  in CSS (`.wordmark` in Linux/src/styles.css), and the tvOS Top Shelf image
//  in `Tools/IconGenerator` (`drawWordmark`).

import SwiftUI

struct Wordmark: View {
    /// The text style or size to set it in. The bubble scales with it, so a
    /// Dynamic Type change moves both together.
    var font: Font = .title3
    /// The letters' colour. Nil keeps whatever the surroundings set.
    var color: Color? = nil

    /// The brand purple, fixed rather than the accent colour, so the bubble
    /// is the same on the watch, in a widget and in the app.
    static let bubbleColor = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)

    /// Where the bubble sits, as fractions of the line box the dotless i is
    /// set in (SF's line is about 1.2 em, its baseline about 0.8 of the way
    /// down): a bubble about a third of an em across, centred just above
    /// where the i's dot would be.
    static let bubbleDiameter: CGFloat = 0.27
    static let bubbleCentreY: CGFloat = 0.215

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "aquar")
            Text(verbatim: "\u{0131}")
                .overlay {
                    GeometryReader { g in
                        let d = g.size.height * Self.bubbleDiameter
                        WordmarkBubble()
                            .frame(width: d, height: d)
                            .position(x: g.size.width / 2, y: g.size.height * Self.bubbleCentreY)
                    }
                }
            Text(verbatim: "um")
        }
        .font(font)
        .fontWeight(.heavy)
        .fontDesign(.rounded)
        .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
        .lineLimit(1)
        .fixedSize()
        // Read and found as one word, "Aquarium": the dotless i and the
        // split runs are drawing, not spelling.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Aquarium"))
    }
}

/// The bubble standing in for the dot: a purple ring, a faint purple fill and
/// a highlight top-left, like the bubbles in the icon.
struct WordmarkBubble: View {
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(Wordmark.bubbleColor.opacity(0.18))
                Circle().strokeBorder(Wordmark.bubbleColor, lineWidth: max(1, d * 0.17))
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: d * 0.3, height: d * 0.3)
                    .offset(x: -d * 0.16, y: -d * 0.16)
            }
            .frame(width: d, height: d)
        }
        .accessibilityHidden(true)
    }
}
