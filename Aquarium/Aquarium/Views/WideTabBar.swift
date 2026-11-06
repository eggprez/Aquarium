#if os(iOS)
import SwiftUI

/// The tab bar, drawn by the app when it holds two tabs or fewer.
///
/// From iOS 26 the system's bar is a capsule as wide as its tabs, and nothing
/// widens it: neither `itemPositioning` nor `itemWidth` reaches the floating
/// bar. Offline the tabs are Downloads and More, and the bar shrank to a
/// lozenge in the middle of the screen. This one keeps the width, height and
/// place of the bar as it is with every tab in it, and splits it between the
/// tabs there are.
///
/// On a foldable the system's bar is not along the bottom at all: it stands
/// in the status column down the trailing edge, icons only, resting on the
/// home indicator's margin. Handed that column's width (`inColumn`) this bar
/// takes the same shape and place, so that going offline does not move the
/// tabs from the side of the screen to the foot of it.
@available(iOS 26.0, *)
struct WideTabBar: View {
    @Environment(AppModel.self) private var app

    let sections: [AppSection]
    /// Whether the bar stands in a foldable's trailing column.
    var inColumn = false

    /// A trailing inset this deep is a foldable's status column (84), not
    /// a landscape phone's rounded corner and camera (up to 62).
    static let columnMinimum: CGFloat = 72

    /// The column's bar, measured against the system's on the Duo: 48
    /// points across, 50 a tab, 24 in from the edge, 2 above the home
    /// indicator's margin.
    private static let columnBarWidth: CGFloat = 48
    private static let columnTabHeight: CGFloat = 50
    private static let columnEdgeGap: CGFloat = 24

    var body: some View {
        if inColumn {
            VStack(spacing: 2) {
                ForEach(sections) { section in
                    tab(section, labelled: false)
                        .frame(width: Self.columnBarWidth - 8, height: Self.columnTabHeight)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .glassEffect(.regular.interactive(), in: Capsule())
            // Centred on where the system's stands: 24 points in from the
            // edge, whatever the column's exact width.
            .padding(.trailing, Self.columnEdgeGap)
            .padding(.bottom, 2)
        } else {
            HStack(spacing: 4) {
                ForEach(sections) { section in
                    tab(section, labelled: true)
                }
            }
            .padding(4)
            .frame(height: 62)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, 21)
            // Resting on the home indicator's margin rather than reaching into it
            // as the system's does: drawn down there, the lower edge of the bar
            // took no taps.
        }
    }

    private func tab(_ section: AppSection, labelled: Bool) -> some View {
        let selected = app.shownSelection == section
        return Button {
            // The tab already showing goes back to its top, as the system's
            // bar does.
            if selected {
                app.path(for: section).wrappedValue = NavigationPath()
            } else {
                app.shownSelectionBinding.wrappedValue = section
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: section.symbol)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 28)
                if labelled {
                    Text(section.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    if labelled {
                        Capsule().fill(Theme.text.opacity(0.08))
                    } else {
                        Circle().fill(Theme.text.opacity(0.08))
                    }
                }
            }
            .contentShape(labelled ? AnyShape(Capsule()) : AnyShape(Circle()))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
