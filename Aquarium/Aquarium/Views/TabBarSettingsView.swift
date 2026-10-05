//  Settings → Tab Bar: the phone's bar, in an order of your own.
//
//  One list, because that is what the thing is: an order. The first three
//  after Home get the places in the bar, the rest are what More lists, and
//  dragging a row across that line is how something gets in or out. There is
//  no second list to move things between and no switch per row, so the bar
//  can never be left with a gap in it or with six things asked of five places.

import SwiftUI

#if os(iOS)
struct TabBarSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let order = app.tabOrder
        let slots = AppModel.slotsAfterHome
        List {
            Section {
                Label(AppSection.home.title, systemImage: AppSection.home.symbol)
                    .foregroundStyle(Theme.textDim)
            } header: {
                Text("Always first")
            }

            Section {
                ForEach(Array(order.enumerated()), id: \.element.id) { index, section in
                    HStack {
                        Label(section.title, systemImage: section.symbol)
                            .foregroundStyle(index < slots ? Theme.text : Theme.textDim)
                        Spacer()
                        Text(index < slots ? "Tab bar" : "More")
                            .font(.caption)
                            .foregroundStyle(index < slots ? Theme.accent : Theme.textDim)
                    }
                }
                .onMove { from, to in
                    var next = order
                    next.move(fromOffsets: from, toOffset: to)
                    prefs.tabBarOrder = next.map(\.id)
                }
            } header: {
                Text("Then, in this order")
            } footer: {
                Text(AppModel.usesSidebar
                    ? "Drag to reorder. On an iPad this is the order of the sidebar; on an iPhone the first \(slots) are in the tab bar and the rest are listed under More."
                    : "Drag to reorder. The first \(slots) are in the tab bar; everything after them is listed under More. Search stays reachable either way — from More when it isn't in the bar. The tab bar changes when you leave this page.")
            }
        }
        .environment(\.editMode, .constant(.active))
        // The phone's bar is rebuilt whenever its tabs change, which would
        // take this page down with it mid-drag; it waits until the page is
        // left instead. An iPad's sidebar follows along live.
        .onAppear { if !AppModel.usesSidebar { app.holdTabBar() } }
        .onDisappear { app.releaseTabBar() }
        .screenTitle("Tab Bar")
        .paletteBar()
        .toolbar {
            if !prefs.tabBarOrder.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") { prefs.tabBarOrder = [] }
                }
            }
        }
    }
}
#endif
