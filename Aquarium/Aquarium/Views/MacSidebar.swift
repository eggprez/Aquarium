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
                .tag(section)
                .contextMenu { menu(for: section) }
        }
    }

    /// A row's menu: the section in a window of its own, and a fresh answer
    /// from the server, where either makes sense. Home, Live TV and Downloads
    /// have no second window — Home publishes to the Dock and assumes it is
    /// the one in front, the guide's menu commands go to the main window's
    /// guide, and Downloads is the device's queue.
    @ViewBuilder
    private func menu(for section: AppSection) -> some View {
        if let route = windowRoute(for: section) {
            Button("Open in New Window") { openWindow(id: RouteWindow.id, value: route) }
        }
        switch section {
        case .library, .libraries, .favorites, .home:
            Button(section == .home ? "Refresh" : "Refresh Library") {
                app.selection = section
                MacCommandRequests.shared.refresh += 1
                // The saved library copy is what the library pages read first,
                // so it is brought up to date along with the page.
                Task { await LibraryIndex.shared.sync(force: true) }
            }
        case .liveTV:
            Button("Refresh Guide") {
                app.selection = section
                MacCommandRequests.shared.refresh += 1
                Task { await LiveTVStore.shared.refresh() }
            }
        default:
            EmptyView()
        }
    }

    private func windowRoute(for section: AppSection) -> Route? {
        switch section {
        case .library(let id, let name, let type): .library(id: id, name: name, collectionType: type)
        case .favorites, .libraries: .section(section)
        default: nil
        }
    }

    /// Transfers still to finish, on Downloads — the count the Dock icon shows
    /// too. Zero draws no badge.
    private func badge(for section: AppSection) -> Int {
        guard section == .downloads else { return 0 }
        return DownloadManager.shared.records.lazy
            .filter { $0.status == .queued || $0.status == .downloading }
            .count
    }
}

/// A heading and the rows under it.
struct MacSidebarGroup: Identifiable {
    let title: String?
    let sections: [AppSection]
    var id: String { title ?? "top" }

    /// Home on its own at the top (Search is the field above the rows, not a
    /// row); then the libraries and what is kept from them; then Live TV; then
    /// what is on this Mac.
    static func grouped(_ sections: [AppSection]) -> [MacSidebarGroup] {
        var top: [AppSection] = []
        var library: [AppSection] = []
        var live: [AppSection] = []
        var device: [AppSection] = []
        for section in sections {
            switch section {
            case .home, .search: top.append(section)
            case .liveTV: live.append(section)
            case .downloads: device.append(section)
            case .settings, .more: break
            default: library.append(section)
            }
        }
        return [
            MacSidebarGroup(title: nil, sections: top),
            MacSidebarGroup(title: "Library", sections: library),
            MacSidebarGroup(title: "Live", sections: live),
            MacSidebarGroup(title: "This Mac", sections: device),
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
        // The same count as the sidebar's badge on Downloads, on the Dock icon,
        // so a queue left running can be watched from anywhere.
        .onChange(of: transfersLeft, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .confirmationDialog(
            "Sign out of \(client.session?.server ?? "this server")?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var transfersLeft: Int {
        DownloadManager.shared.records.lazy
            .filter { $0.status == .queued || $0.status == .downloading }
            .count
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
        }
        .padding(8)
        // A quaternary fill rather than a painted card: on the sidebar's
        // material the strip stays vibrant, and reads as part of the sidebar
        // rather than as a widget set on it.
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { openWindow(id: PlayerWindow.id) }
        .help("Show the Player")
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
                    }
                }
            }
            Button("Add Account…") { app.isAddingAccount = true }
            Divider()
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Sign Out…") { confirmSignOut = true }
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
    }

    private func host(_ server: String) -> String {
        URL(string: server)?.host() ?? server
    }
}
#endif
