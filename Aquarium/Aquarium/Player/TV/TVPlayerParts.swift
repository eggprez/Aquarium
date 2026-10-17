//  The focus-driven pieces the Apple TV player's controls are built from:
//  choice cards and the tab labels, purple where focus is. What they share
//  with the other platforms' chrome — the glass, the time format, trickplay,
//  a channel's schedule, the Info tab's artwork and the skip badge — is in
//  `Player/Chrome/PlayerParts.swift`.

#if os(tvOS)

import SwiftUI
import UIKit

// MARK: - The look

/// A focusable card in a panel row: purple when focused, a purple tick when
/// it is the current choice.
struct ChoiceCard<Leading: View>: View {
    let title: String
    var detail: String?
    var isSelected = false
    /// Nil shares the row's width with the other cards in it.
    var width: CGFloat? = 340
    /// Nil is as tall as the text needs; a row of choices that must match
    /// gives them all the same one.
    var height: CGFloat?
    /// The title in the middle of the card, for short labels — `+5`,
    /// `Reset`, `1.5×` — that look adrift at its leading edge.
    var centered = false
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        Button(action: action) {
            ChoiceCardLabel(title: title, detail: detail, isSelected: isSelected, width: width, height: height,
                            centered: centered, leading: leading)
        }
        .buttonStyle(PlayerCardStyle())
    }
}

extension ChoiceCard where Leading == EmptyView {
    init(title: String, detail: String? = nil, isSelected: Bool = false, width: CGFloat? = 340,
         height: CGFloat? = nil, centered: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, isSelected: isSelected, width: width, height: height,
                  centered: centered, action: action) { EmptyView() }
    }
}

private struct ChoiceCardLabel<Leading: View>: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let detail: String?
    let isSelected: Bool
    let width: CGFloat?
    let height: CGFloat?
    let centered: Bool
    @ViewBuilder var leading: () -> Leading

    /// Where the tick goes: in the corner when the card is too narrow to
    /// spare the title the room, or when the title is centred and a tick
    /// beside it would push it off the middle.
    private var tickInCorner: Bool { width == nil || centered }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            leading()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if centered { Spacer(minLength: 0) }
                // Only a card sharing its row's width shrinks its title to
                // fit. One of its own width — a long track name, with the
                // tick beside it — takes a third line instead: shrunk, the
                // chosen track read smaller than the ones beside it and was
                // cut off all the same.
                Text(title)
                    .font(.headline)
                    .lineLimit(width == nil ? 2 : 3)
                    .minimumScaleFactor(width == nil ? 0.75 : 1)
                    .multilineTextAlignment(centered ? .center : .leading)
                Spacer(minLength: 0)
                if isSelected, !tickInCorner { checkmark }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFocused ? .white.opacity(0.85) : Theme.textDim)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(isFocused ? .white : Theme.text)
        .padding(.horizontal, centered ? 12 : 24)
        .padding(.vertical, 10)
        .frame(width: width, alignment: centered ? .center : .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: centered ? .center : .leading)
        .frame(minHeight: height ?? 72)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected && !isFocused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 2)
        )
        // A card sharing a row is too narrow to give the title's width to
        // the tick, so there it sits in the corner instead.
        .overlay(alignment: .topTrailing) {
            if isSelected, tickInCorner { checkmark.padding(12) }
        }
        .shadow(color: isFocused ? Theme.accent.opacity(0.45) : .clear, radius: 18, y: 8)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.headline.weight(.bold))
            .foregroundStyle(isFocused ? .white : Theme.link)
    }
}

/// The lift a focused card gets, without the system's own white platter.
struct PlayerCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerCardBody(configuration: configuration)
    }

    private struct PlayerCardBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : isFocused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// A tab along the top of the panel: text, with a purple capsule behind the
/// one that is focused and a purple underline under the one that is open.
struct PanelTabLabel: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let isCurrent: Bool

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(isFocused ? .white : isCurrent ? Theme.text : Theme.textDim)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(Capsule().fill(isFocused ? Theme.accent : .clear))
            .overlay(alignment: .bottom) {
                if isCurrent && !isFocused {
                    Capsule().fill(Theme.accent).frame(height: 4).padding(.horizontal, 22).offset(y: 4)
                }
            }
    }
}

#endif
