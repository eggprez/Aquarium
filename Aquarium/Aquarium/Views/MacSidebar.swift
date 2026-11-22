//  The Mac's sidebar: its rows, grouped under headings the way Finder, Music
//  and the TV app group theirs, and the footer under them — what is playing,
//  and who is signed in.

#if os(macOS)
import AppKit
import SwiftUI

/// The sidebar's rows, in the order `AppModel.sections` gives them, gathered
/// under headings. Tags are the sections themselves, so the list's selection
/// binding works exactly as it does for a flat list.
struct MacSidebarRows: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    /// Pairs each click with the selection change it caused, if any — see
    /// `reselected` and `SidebarClickRule`.
    static var clicks = SidebarClickRule()

    /// Called by the list's selection binding (see
    /// `RootView.sidebarSelection`) when the selection moves to another row.
    static func selectionMoved(to section: AppSection) {
        clicks.selectionMoved(to: section.id, at: Date())
    }

    var body: some View {
        ForEach(MacSidebarGroup.grouped(app.sections)) { group in
            if let title = group.title {
                Section(title) { rows(group.sections) }
            } else {
                rows(group.sections)
            }
        }
    }

    private func rows(_ sections: [AppSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.symbol)
                .badge(badge(for: section))
                // The whole name, for a library whose name the sidebar's
                // width cuts short.
                .help(section.title)
                .accessibilityIdentifier(TestID.Sidebar.row(section.id))
                .tag(section)
                .contextMenu { menu(for: section) }
                .simultaneousGesture(TapGesture().onEnded { reselected(section) })
        }
    }

    /// A click on the row already selected: back to the top of that section,
    /// as Music and Finder do. The list's selection binding isn't told about a
    /// click that doesn't change it, so the row hears it itself. The click
    /// that moved the selection here is not a second click — that one keeps
    /// the section's pages where they were left.
    ///
    /// Which click moved the selection is told by pairing, not by order or
    /// by how long the press took. The rule used to assume the list's
    /// selection arrives first; on macOS 27 the tap does (checked
    /// 2026-11-13), which left the selection waiting for a tap that had
    /// already come, and it swallowed the real re-click after it. See
    /// `SidebarClickRule`.
    private func reselected(_ section: AppSection) {
        let reclick = Self.clicks.tapped(section.id, isShown: app.shownSelection == section, at: Date())
        guard reclick, app.shownSelection == section else { return }
        app.showAtTop(section)
    }

    /// A row's menu: the section in a window of its own, and a fresh answer
    /// from the server, where either makes sense. Home, Live TV and Downloads
    /// have no second window — Home publishes to the Dock and assumes it is
    /// the one in front, the guide's menu commands go to the main window's
    /// guide, and Downloads is the device's queue.
    @ViewBuilder
    private func menu(for section: AppSection) -> some View {
        if let route = Self.windowRoute(for: section) {
            Button("Open in New Window") { openWindow(id: RouteWindow.id, value: route) }
                .accessibilityIdentifier(TestID.Sidebar.rowOpenInNewWindow(section.id))
        }
        switch section {
        case .library, .libraries, .favorites, .collections, .home:
            Button(section == .home ? "Refresh" : "Refresh Library") {
                app.selection = section
                MacCommandRequests.shared.refresh += 1
                // The saved library copy is what the library pages read first,
                // so it is brought up to date along with the page.
                Task { await LibraryIndex.shared.sync(force: true) }
            }
            .accessibilityIdentifier(TestID.Sidebar.rowRefresh(section.id))
        case .liveTV:
            Button("Refresh Guide") {
                app.selection = section
                MacCommandRequests.shared.refresh += 1
                Task { await LiveTVStore.shared.refresh() }
            }
            .accessibilityIdentifier(TestID.Sidebar.rowRefresh(section.id))
        default:
            EmptyView()
        }
    }

    /// Static for the unit tests.
    static func windowRoute(for section: AppSection) -> Route? {
        switch section {
        case .library(let id, let name, let type): .library(id: id, name: name, collectionType: type)
        case .favorites, .libraries, .collections: .section(section)
        default: nil
        }
    }

    /// Transfers still to finish, on Downloads — the count the Dock icon shows
    /// too. Zero draws no badge.
    private func badge(for section: AppSection) -> Int {
        Self.badge(for: section, transfersToFinish: DownloadManager.shared.transfersToFinish)
    }

    /// Static for the unit tests.
    static func badge(for section: AppSection, transfersToFinish: Int) -> Int {
        guard section == .downloads else { return 0 }
        return transfersToFinish
    }
}

/// Tells a click on the selected sidebar row (a re-click: back to the top)
/// from the click that selected it, whichever of the two events of that click
/// — the list's selection change and the row's tap — arrives first.
///
/// - Selection first: it is left waiting, and the tap on the same row that
///   follows ends that click.
/// - Tap first (the row isn't the shown one yet): the tap is left waiting,
///   and the selection change to that row that follows is its own click's.
///
/// Either half waits only a few seconds, so a selection moved with the arrow
/// keys, which no tap ends, doesn't swallow a real re-click made long after.
struct SidebarClickRule {
    static let pairing: TimeInterval = 10

    private var selectionAwaitingTap: (id: String, at: Date)?
    private var tapAwaitingSelection: (id: String, at: Date)?

    /// The list's selection moved to `id`.
    mutating func selectionMoved(to id: String, at now: Date) {
        if let tap = tapAwaitingSelection, tap.id == id, now.timeIntervalSince(tap.at) < Self.pairing {
            // The tap of this same click came first.
            tapAwaitingSelection = nil
            selectionAwaitingTap = nil
        } else {
            tapAwaitingSelection = nil
            selectionAwaitingTap = (id, now)
        }
    }

    /// A tap on row `id`; `isShown` is whether that row is the one shown as
    /// the tap arrives. True when it is a re-click.
    mutating func tapped(_ id: String, isShown: Bool, at now: Date) -> Bool {
        defer { selectionAwaitingTap = nil }
        guard isShown else {
            // The selection change of this click hasn't arrived yet.
            tapAwaitingSelection = (id, now)
            return false
        }
        tapAwaitingSelection = nil
        if let selection = selectionAwaitingTap, selection.id == id,
           now.timeIntervalSince(selection.at) < Self.pairing {
            return false
        }
        return true
    }
}

/// A heading and the rows under it.
struct MacSidebarGroup: Identifiable {
    let title: String?
    let sections: [AppSection]
    var id: String { title ?? "top" }

    /// The iPad's groups (see `PadSidebarGroup`): Home on its own at the top
    /// (Search is the field above the rows, not a row); the libraries, Music
    /// and Audiobooks among them; Live TV; then what is yours — favourites
    /// and what is on this Mac.
    static func grouped(_ sections: [AppSection]) -> [MacSidebarGroup] {
        var top: [AppSection] = []
        var libraries: [AppSection] = []
        var live: [AppSection] = []
        var you: [AppSection] = []
        for section in sections {
            switch section {
            case .home, .search: top.append(section)
            case .liveTV: live.append(section)
            case .favorites, .requests, .downloads: you.append(section)
            case .settings, .more: break
            default: libraries.append(section)
            }
        }
        return [
            MacSidebarGroup(title: nil, sections: top),
            MacSidebarGroup(title: "Libraries", sections: libraries),
            MacSidebarGroup(title: "Live", sections: live),
            MacSidebarGroup(title: "You", sections: you),
        ].filter { !$0.sections.isEmpty }
    }
}

/// Under the rows: a strip for whatever is playing, then the signed-in account
/// with the sync status beneath its name. The account is a menu — switch,
/// add another, open Settings, sign out — where the Mac keeps those things,
/// rather than a trip to a settings page.
struct MacSidebarFooter<Status: View>: View {
    let status: Status

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player
    @Environment(\.openWindow) private var openWindow
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if player.isActive {
                nowPlaying
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            account
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .animation(.easeOut(duration: 0.2), value: player.isActive)
        .confirmationDialog(
            client.session?.signOutQuestion ?? "Sign out?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                .accessibilityIdentifier(TestID.Shell.signOutConfirm)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(TestID.Shell.signOutCancel)
        }
    }

    // MARK: Now playing

    /// What the player window is showing, for when it is behind this one or
    /// in Picture in Picture: its title, play/pause, and a way back to it.
    private var nowPlaying: some View {
        HStack(spacing: 8) {
            artwork
                .frame(width: 44, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Now Playing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(player.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .help(player.title)
                    .accessibilityIdentifier(TestID.Sidebar.nowPlayingTitle)
            }
            Spacer(minLength: 4)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(player.isPaused ? "Play" : "Pause")
            .accessibilityIdentifier(TestID.Sidebar.nowPlayingPlayPause)
        }
        .padding(8)
        // A quaternary fill rather than a painted card: on the sidebar's
        // material the strip stays vibrant, and reads as part of the sidebar
        // rather than as a widget set on it.
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            // Not while Picture in Picture has the window put away: it came
            // back as a black window beside the floating picture.
            guard !PlayerMacState.shared.isHiddenForPictureInPicture else { return }
            openWindow(id: PlayerWindow.id)
        }
        .help("Show the Player")
        .testAnchor(TestID.Sidebar.nowPlaying)
    }

    @ViewBuilder
    private var artwork: some View {
        if let item = player.item {
            RemoteImage(url: Artwork.still(for: item, width: 120))
        } else {
            ZStack {
                Color.accentColor.opacity(0.25)
                Image(systemName: "play.rectangle.fill").foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: Account

    private var account: some View {
        Menu {
            if client.accounts.count > 1 {
                Section("Switch Account") {
                    ForEach(client.accounts, id: \.accountKey) { saved in
                        let isCurrent = saved.accountKey == client.session?.accountKey
                        Button {
                            Task { await app.switchAccount(to: saved) }
                        } label: {
                            if isCurrent {
                                Label("\(saved.userName) — \(host(saved.server))", systemImage: "checkmark")
                            } else {
                                Text("\(saved.userName) — \(host(saved.server))")
                            }
                        }
                        .disabled(isCurrent || app.switchingTo != nil)
                        .accessibilityIdentifier(TestID.Sidebar.accountMenuSwitch(saved.accountKey))
                    }
                }
            }
            Button("Add Account…") { app.isAddingAccount = true }
                .accessibilityIdentifier(TestID.Sidebar.accountMenuAdd)
            Divider()
            SettingsLink { Text("Settings…") }
                .accessibilityIdentifier(TestID.Sidebar.accountMenuSettings)
            Divider()
            Button("Sign Out…") { confirmSignOut = true }
                .accessibilityIdentifier(TestID.Sidebar.accountMenuSignOut)
        } label: {
            HStack(spacing: 8) {
                if let session = client.session {
                    AccountAvatar(account: session, size: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(client.session?.userName ?? "Not signed in")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    status
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        // `.button` + `.plain`: the one menu style on a Mac that draws a label
        // made of more than a title and an icon. Borderless reduced this row
        // to the avatar's initial.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Account, Settings and Sign Out")
        .accessibilityIdentifier(TestID.Sidebar.accountMenu)
    }

    private func host(_ server: String) -> String {
        URL(string: server)?.host() ?? server
    }
}
#endif
