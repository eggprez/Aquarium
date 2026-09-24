//  A title in a window of its own, on a Mac — "Open in New Window" from any
//  poster's menu.
//
//  The window has its own navigation: a season, an episode or a cast member
//  opened from it opens in it, and its Back goes back through its own pages.
//  The pages themselves are the same ones the main window shows, and they all
//  open things through `AppModel.push` and `navigate(to:)`; those send the
//  route here whenever this window is the main one (see
//  `AppModel.keyNavigator`) — the window being worked in, which is the one
//  that was clicked.
//
//  Windows are keyed by the title they opened on, so asking for the same one
//  again brings its window forward rather than opening a second copy, and the
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

struct ItemWindow: View {
    static let id = "item"

    let itemId: String?

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var navigator = ItemWindowNavigator()
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if let itemId, client.isSignedIn {
                NavigationStack(path: navigator.pathBinding) {
                    RouteDestination(route: .item(itemId))
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
            } else {
                EmptyState(symbol: "film", title: "Nothing to show", message: "This window's title isn't available.")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Theme.background)
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
        // A title window belongs to the account it was opened under.
        .onChange(of: client.session?.accountKey) { _, _ in dismissWindow() }
    }

    private func release() {
        if app.keyNavigator === navigator { app.keyNavigator = nil }
    }
}
#endif
