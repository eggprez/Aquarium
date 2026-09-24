//  The Mac's menu bar, beyond Playback (see `PlaybackCommands`): the sidebar's
//  sections on ⌘1…⌘9, a Go menu, and an Item menu for the title in front of you.
//  Everything a pointer can reach should be reachable from the keyboard and
//  findable in the menus — that is what a Mac app is expected to offer, and it
//  is the part an iPad port never has.

#if os(macOS)
import SwiftUI

/// Requests the menus make of views that aren't theirs to reach — counters a
/// view watches, because a menu command has no handle on the view it means.
@MainActor @Observable
final class MacCommandRequests {
    static let shared = MacCommandRequests()
    /// Bumped by Go ▸ Search (⌘F): the search field takes focus.
    var focusSearch = 0
}

/// What the Item menu can do to the title on screen, published by the title
/// page while it is in front — see `ItemDetailView`.
struct ItemMenuActions {
    var title: String
    var canPlay: Bool
    var playLabel: String
    var isFavorite: Bool
    /// Nil for a series, which is marked watched a season at a time.
    var isWatched: Bool?
    var play: () -> Void
    var toggleFavorite: () -> Void
    var toggleWatched: () -> Void
    var openInNewWindow: () -> Void
}

private struct ItemMenuActionsKey: FocusedValueKey {
    typealias Value = ItemMenuActions
}

extension FocusedValues {
    var itemMenuActions: ItemMenuActions? {
        get { self[ItemMenuActionsKey.self] }
        set { self[ItemMenuActionsKey.self] = newValue }
    }
}

struct MacCommands: Commands {
    let app: AppModel
    @FocusedValue(\.itemMenuActions) private var item

    var body: some Commands {
        // One main window. The navigation, the player and the app model are
        // single instances, so a second window would only mirror the first.
        CommandGroup(replacing: .newItem) {}

        // The sidebar's sections, in its order, on ⌘1…⌘9 — Finder's and
        // Music's convention.
        CommandGroup(before: .sidebar) {
            ForEach(Array(app.sections.prefix(9).enumerated()), id: \.element.id) { index, section in
                Button(section.title) { app.selection = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canGoBack)
            Divider()
            Button("Home") { show(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Search") {
                show(.search)
                MacCommandRequests.shared.focusSearch += 1
            }
            .keyboardShortcut("f", modifiers: .command)
            if app.sections.contains(.liveTV) {
                Button("Live TV") { show(.liveTV) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            Button("Downloads") { show(.downloads) }
                .keyboardShortcut("j", modifiers: [.command, .option])
        }

        CommandMenu("Item") {
            Button(item?.playLabel ?? "Play") { item?.play() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(item?.canPlay != true)
            Divider()
            Button(item?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                item?.toggleFavorite()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(item == nil)
            Button(item?.isWatched == true ? "Mark as Unwatched" : "Mark as Watched") {
                item?.toggleWatched()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(item?.isWatched == nil)
            Divider()
            Button("Open in New Window") { item?.openInNewWindow() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(item == nil)
        }
    }

    /// Straight to a section, at its top.
    private func show(_ section: AppSection) {
        guard app.sections.contains(section) else { return }
        app.selection = section
    }

    /// A title window in front goes back through its own pages.
    private var canGoBack: Bool {
        if let window = app.keyNavigator { return !window.path.isEmpty }
        return !app.path(for: app.shownSelection).wrappedValue.isEmpty
    }

    private func goBack() {
        if let window = app.keyNavigator {
            window.goBack()
            return
        }
        let path = app.path(for: app.shownSelection)
        guard !path.wrappedValue.isEmpty else { return }
        var shorter = path.wrappedValue
        shorter.removeLast()
        path.wrappedValue = shorter
    }
}

/// Puts the cursor in the search field when Go ▸ Search asks. `searchFocused`
/// is macOS 15; on 14 the menu still brings Search to the front.
struct FocusSearchOnRequest: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            Focused(content: content)
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private struct Focused<C: View>: View {
        let content: C
        @FocusState private var focused: Bool

        var body: some View {
            content
                .searchFocused($focused)
                .onChange(of: MacCommandRequests.shared.focusSearch, initial: true) { _, _ in
                    focused = true
                }
        }
    }
}
#endif
