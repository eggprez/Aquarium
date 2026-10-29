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
@available(iOS 26.0, *)
struct WideTabBar: View {
    @Environment(AppModel.self) private var app

    let sections: [AppSection]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sections) { section in
                tab(section)
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

    private func tab(_ section: AppSection) -> some View {
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
                Text(section.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected { Capsule().fill(Theme.text.opacity(0.08)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
