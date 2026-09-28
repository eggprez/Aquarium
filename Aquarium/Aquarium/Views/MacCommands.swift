//  The Mac's menu bar, beyond Playback (see `PlaybackCommands`): the About
//  panel, the sidebar's sections on ⌘1…⌘9, a View menu for the thumbnails
//  and a refresh, a Go menu, and an Item menu for the title in front of you.
//  Everything a pointer can reach should be reachable from the keyboard and
//  findable in the menus — that is what a Mac app is expected to offer, and it
//  is the part an iPad port never has.

#if os(macOS)
import AppKit
import SwiftUI

/// Requests the menus make of views that aren't theirs to reach — counters a
/// view watches, because a menu command has no handle on the view it means.
@MainActor @Observable
final class MacCommandRequests {
    static let shared = MacCommandRequests()
    /// Bumped by Go ▸ Search (⌘F): the search field takes focus.
    var focusSearch = 0
    /// Bumped by View ▸ Refresh (⌘R), and by the app coming back to the front
    /// after a while away (see `MacAppDelegate`): the page in front asks the
    /// server again.
    var refresh = 0
    /// Bumped by Go ▸ Earlier / Later / Now (⌘← / ⌘→ / ⌘T) while Live TV is
    /// showing: the guide scrolls a page back or forward in time, or to now.
    var guideEarlier = 0
    var guideLater = 0
    var guideNow = 0
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
    @FocusedValue(\.playerWindowFocused) private var inPlayer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Handed to `MacMainWindow` so that what isn't a view — the Dock's
        // reopen, the app delegate — can open windows too.
        let _ = MacMainWindow.remember(openWindow)

        // The main window, from the Window menu, as Music has Window ▸ Music.
        // With New Window gone (below) and a title, Settings or the player
        // still open, nothing else brought it back once it was closed: the
        // Dock only reopens an app with no windows showing, and the Go and
        // View commands changed the sections of a window that wasn't there.
        CommandGroup(before: .windowList) {
            Button("Aquarium") { MacMainWindow.show() }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Divider()
        }

        // The About panel, with the version and the playback engine that
        // Settings ▸ General also lists — the standard panel rather than a
        // window of our own, because that is where a Mac user looks for it.
        CommandGroup(replacing: .appInfo) {
            Button("About Aquarium") { showAboutPanel() }
        }

        // One main window. The navigation, the player and the app model are
        // single instances, so a second window would only mirror the first.
        CommandGroup(replacing: .newItem) {}

        // The View menu's own entries, ahead of the system's Show Sidebar and
        // Enter Full Screen: the thumbnail size, then the sidebar's sections
        // on ⌘1…⌘9 — Finder's and Music's convention — then Refresh.
        CommandGroup(before: .sidebar) {
            // ⌘=, the key under "+": bound to "+" itself it needed Shift as
            // well, so the ⌘= that every other Mac app zooms in with did
            // nothing.
            Button("Bigger") { MacViewOptions.shared.bigger() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!MacViewOptions.shared.canGrow)
            Button("Smaller") { MacViewOptions.shared.smaller() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!MacViewOptions.shared.canShrink)
            Button("Actual Size") { MacViewOptions.shared.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(MacViewOptions.shared.isActualSize)
            Divider()
            // Numbered down the sidebar as it is drawn — regrouped under its
            // headings — not in `app.sections` order, which an iPhone's tab
            // order (synced through iCloud) can shuffle: with Live TV put
            // first there, ⌘2 opened Live TV while the sidebar's second row
            // was a library.
            ForEach(Array(sidebarOrder.prefix(9).enumerated()), id: \.element.id) { index, section in
                Button(section.title) { app.showAtTop(section) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Refresh") { MacCommandRequests.shared.refresh += 1 }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canGoBack)
            Divider()
            Button("Home") { show(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Search") { focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            if app.sections.contains(.liveTV) {
                Button("Live TV") { show(.liveTV) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            Button("Downloads") { show(.downloads) }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Button("Show Downloads in Finder") { showDownloadsInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            // The guide's own navigation, live only while it is in front:
            // a page back or forward in time, and back to now.
            Divider()
            Button("Earlier") { MacCommandRequests.shared.guideEarlier += 1 }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!isGuideShowing)
            Button("Later") { MacCommandRequests.shared.guideLater += 1 }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!isGuideShowing)
            Button("Now") { MacCommandRequests.shared.guideNow += 1 }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!isGuideShowing)
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

    /// The sections in the order the sidebar's rows show them.
    private var sidebarOrder: [AppSection] {
        MacSidebarGroup.grouped(app.sections).flatMap(\.sections).filter { $0 != .search }
    }

    /// Straight to a section, at its top. Selecting it alone left whatever
    /// had been opened in it on screen: from a season you had reached
    /// through Home, Go ▸ Home and ⌘1 did nothing at all, because Home was
    /// already the section and the season was its page.
    private func show(_ section: AppSection) {
        guard app.sections.contains(section) else { return }
        app.showAtTop(section)
    }

    /// Live TV in front of you, with nothing pushed over it: the only time
    /// Earlier, Later and Now mean anything.
    ///
    /// Not with the player in front either: there ⌘← and ⌘→ skip through the
    /// film (see `PlaybackCommands`), and the guide behind it is not what
    /// they're for.
    private var isGuideShowing: Bool {
        inPlayer != true
            && app.keyNavigator == nil
            && app.shownSelection == .liveTV
            && app.path(for: .liveTV).wrappedValue.isEmpty
    }

    /// ⌘F: the cursor into the sidebar's search field. `searchFocused`, which
    /// puts it there, is macOS 15; on 14 the menu shows the Search section
    /// instead, so the command still leads somewhere.
    private func focusSearch() {
        if #available(macOS 15.0, *) {
            MacCommandRequests.shared.focusSearch += 1
        } else {
            app.show(.search)
        }
    }

    /// The folder the downloads are kept in, selected in Finder. Application
    /// Support rather than ~/Downloads: the files are the app's, named by id,
    /// and are no use opened from anywhere but here — but a person is
    /// entitled to see how much of their disk they take.
    private func showDownloadsInFinder() {
        let folder = DownloadManager.root
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// The standard About panel, with what Settings ▸ General says under
    /// "About": the version and build, the playback engine, and the note
    /// about how the app was made.
    private func showAboutPanel() {
        let credits = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        credits.append(NSAttributedString(string: "Playback engine: AVFoundation\n", attributes: attributes))
        credits.append(NSAttributedString(
            string: "A lightweight Jellyfin client — the Apple build of the same app that ships for Linux. Written with AI assistance (Anthropic’s Claude), directed and tested by one developer, and shared as-is.",
            attributes: attributes.merging([.foregroundColor: NSColor.secondaryLabelColor]) { _, new in new }
        ))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Aquarium",
            .applicationVersion: Bundle.appVersion,
            .version: Bundle.appBuild,
            .credits: credits,
        ])
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

/// Puts the cursor in the sidebar's search field when Go ▸ Search asks.
/// `searchFocused` is macOS 15; on 14 the menu shows Search instead (see
/// `MacCommands.focusSearch`). Applied to the view that carries
/// `.searchable` — the shell's split view.
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
                // Not `initial`: the field taking focus at launch would put
                // the cursor there ahead of whatever Home wants it on.
                .onChange(of: MacCommandRequests.shared.focusSearch) { _, _ in
                    focused = true
                }
        }
    }
}
#endif

#if os(macOS)
/// The one main window: finding it, bringing it forward, and opening it again
/// once it has been closed. SwiftUI's `openWindow` exists only in views and
/// commands, so `MacCommands` hands it over here for the parts of the app that
/// are neither — the Dock's reopen and the app delegate's watchers.
@MainActor
enum MacMainWindow {
    static let id = "main"

    private static var openWindow: OpenWindowAction?

    static func remember(_ action: OpenWindowAction) {
        openWindow = action
    }

    /// The main window, if one is open — minimised counts, closed doesn't.
    /// SwiftUI names a group's windows after its id ("main-AppWindow-1").
    static var window: NSWindow? {
        NSApp.windows.first { window in
            guard window.identifier?.rawValue.hasPrefix("\(id)-") == true else { return false }
            return window.isVisible || window.isMiniaturized
        }
    }

    /// In front, opened again first if it had been closed.
    static func show() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            openWindow?(id: id)
        }
    }

    /// Any window by scene id, for callers with no `openWindow` of their own.
    static func open(id: String) {
        openWindow?(id: id)
    }
}
#endif
