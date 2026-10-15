//  A title in a window of its own, on a Mac — "Open in New Window" from any
//  poster's menu — and, the same way, a library or a section from the
//  sidebar's row menu.
//
//  The window has its own navigation: a season, an episode or a cast member
//  opened from it opens in it, and its Back goes back through its own pages.
//  The pages themselves are the same ones the main window shows, and they all
//  open things through `AppModel.push` and `navigate(to:)`; those send the
//  route here whenever this window is the main one (see
//  `AppModel.keyNavigator`) — the window being worked in, which is the one
//  that was clicked.
//
//  Windows are keyed by what they opened on, so asking for the same one again
//  brings its window forward rather than opening a second copy, and the
//  system reopens them at launch the way it reopens a document.

#if os(macOS)
import AppKit
import SwiftUI

/// One title window's pages: its own path, and the routes that path holds so a
/// link up to a page already behind can go back to it rather than pushing a
/// second copy — the same bookkeeping `AppModel` keeps for each tab.
@MainActor @Observable
final class ItemWindowNavigator {
    var path = NavigationPath()
    private(set) var routes: [Route] = []

    func push(_ route: Route) {
        path.append(route)
        routes.append(route)
    }

    func navigate(to route: Route) {
        if let index = routes.lastIndex(of: route) {
            let drop = routes.count - index - 1
            if drop > 0, path.count >= drop {
                path.removeLast(drop)
                routes = Array(routes.prefix(index + 1))
            }
            return
        }
        push(route)
    }

    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
        routes = Array(routes.prefix(path.count))
    }

    /// For the stack's own binding: a Back button shortens the path without
    /// coming through here, so the routes follow its length.
    var pathBinding: Binding<NavigationPath> {
        Binding(
            get: { self.path },
            set: { new in
                self.path = new
                if new.count < self.routes.count { self.routes = Array(self.routes.prefix(new.count)) }
            }
        )
    }
}

private struct RouteWindowNavigatorKey: EnvironmentKey {
    static let defaultValue: ItemWindowNavigator? = nil
}

extension EnvironmentValues {
    /// The pages of the title or library window a view is in; nil in the main
    /// window. See `AppModel.isWorkingWindow`.
    var routeWindowNavigator: ItemWindowNavigator? {
        get { self[RouteWindowNavigatorKey.self] }
        set { self[RouteWindowNavigatorKey.self] = newValue }
    }
}

extension AppModel {
    /// Whether the window with these pages — nil for the main window — is the
    /// one being worked in: the window a click opens into (see
    /// `keyNavigator`), which is also the one an alert, a toast and View ▸
    /// Refresh are for. Every window shares one model, so each of those used
    /// to happen in all of them at once: a toast in every window, Escape in
    /// any of them dismissing it everywhere, an error from a title window
    /// shown on the main one, and ⌘R reloading every page that was open.
    func isWorkingWindow(_ navigator: ItemWindowNavigator?) -> Bool {
        keyNavigator === navigator
    }
}

/// A title, by id. The window group the poster menus open into; kept keyed
/// by the id so those callers don't change.
struct ItemWindow: View {
    static let id = "item"

    let itemId: String?

    var body: some View {
        RouteWindow(route: itemId.map { Route.item($0) })
    }
}

/// Any route in a window of its own — a library, Favorites, a search. The
/// sidebar's "Open in New Window" opens these; see `MacSidebarRows`.
struct RouteWindow: View {
    static let id = "route"

    let route: Route?

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var navigator = ItemWindowNavigator()
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if let route, client.isSignedIn {
                NavigationStack(path: navigator.pathBinding) {
                    RouteDestination(route: route)
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
            } else {
                EmptyState(symbol: "film", title: "Nothing to Show", message: "This window's page isn't available.")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        // No painted background: the window's own, so the toolbar's material
        // and the page's hero read as one surface.
        .overlay(alignment: .bottom) { ToastOverlay() }
        .background(WindowReader(window: $window))
        // Whose pages a click opens into — see `AppModel.keyNavigator`. The
        // main window rather than the key one: an app in the background has no
        // key window at all, but it still has the window you were last
        // working in, and that is where the next click lands. Given up only
        // when some other window takes over.
        .onChange(of: window) { _, window in
            if window?.isMainWindow == true { app.keyNavigator = navigator }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { note in
            guard let window, let other = note.object as? NSWindow else { return }
            if other === window {
                app.keyNavigator = navigator
            } else {
                release()
            }
        }
        .onDisappear { release() }
        // A window belongs to the account it was opened under.
        .onChange(of: client.session?.accountKey) { _, _ in dismissWindow() }
        // What goes wrong on this window's pages is said on this window — a
        // favourite that didn't stick, a library that wouldn't load — rather
        // than on the main window behind it. Which window that is follows
        // `keyNavigator`, the same as where a click opens: see
        // `isWorkingWindow`. `RootView` and the app delegate stand down while
        // this window has it.
        .alert(
            app.pendingAlert?.title ?? "",
            isPresented: Binding(
                get: { app.pendingAlert != nil && app.isWorkingWindow(navigator) },
                set: { if !$0 { app.pendingAlert = nil } }
            ),
            presenting: app.pendingAlert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        // Outermost, so the toasts' overlay and every page know which window
        // they are in.
        .environment(\.routeWindowNavigator, navigator)
    }

    private func release() {
        if app.keyNavigator === navigator { app.keyNavigator = nil }
    }
}
#endif
