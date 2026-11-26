//  Delete from Server: taking a film, a show, a season or an episode off the
//  server itself, from the press-and-hold menu.
//
//  There are two ways and they are not the same thing:
//
//  - Jellyfin deletes the files and the library entry. Nothing else hears of
//    it: if Radarr or Sonarr is looking after the title it will usually fetch
//    it again.
//  - Seerr removes the title from Radarr (a film) or Sonarr (a show), which
//    deletes the files there, and then drops the requests for it and its own
//    record, so the title can be asked for again later. Whole titles only:
//    Seerr has no notion of removing one season or one episode.
//
//  Each is offered only when it can be done. Jellyfin's by the server's own
//  word on the item (`BaseItem.CanDelete`); Seerr's when the account may
//  manage requests, Seerr has a Radarr or Sonarr server for that kind of
//  title, and its record says the title is on one (`SeerrClient.removal`).
//  With neither there is no menu entry, or, where that was only found out on
//  pressing it, a line saying so.
//
//  A copy downloaded to this device is left alone: it is the person's own,
//  and still plays.

import SwiftUI

/// What "Delete from Server" can do for one title, worked out when the menu
/// entry is pressed.
struct ServerDeleteChoice: Identifiable, Hashable, Sendable {
    var item: BaseItem
    /// The server will let this account delete the item.
    var jellyfin: Bool
    /// Seerr can remove it from Radarr or Sonarr, and how.
    var seerr: SeerrRemoval?

    var id: String { item.Id }
    var isEmpty: Bool { !jellyfin && seerr == nil }
}

@MainActor
enum ServerDeleting {
    /// The kinds this is for. Music, collections, playlists and channels have
    /// their own pages and their own rules.
    nonisolated static func covers(_ item: BaseItem) -> Bool {
        ["Movie", "Series", "Season", "Episode"].contains(item.kind)
    }

    /// Whether the menu shows the entry at all, from what is already in hand.
    static func mightDelete(_ item: BaseItem, seerr: SeerrClient) -> Bool {
        guard covers(item), item.ExternalStreamURL == nil else { return false }
        return item.CanDelete == true || seerr.mightRemove(item)
    }

    /// What the dialog is headed with: an episode or a season is named with
    /// its show, since "Delete Episode 3?" could be anything.
    nonisolated static func name(of item: BaseItem) -> String {
        if item.isEpisode || item.isSeason, let show = item.SeriesName, !show.isEmpty {
            if item.isEpisode, let label = item.episodeLabel { return "\(show) \(label)" }
            return "\(show), \(item.title)"
        }
        return item.title
    }

    nonisolated static func jellyfinLabel(for item: BaseItem) -> String {
        item.isFolderLike ? "Delete Files from Jellyfin" : "Delete File from Jellyfin"
    }

    nonisolated static func seerrLabel(for removal: SeerrRemoval) -> String {
        "Remove from \(removal.service) with Seerr"
    }

    /// The small print under the question: what each way on offer does.
    nonisolated static func message(for choice: ServerDeleteChoice) -> String {
        var lines: [String] = []
        if choice.jellyfin {
            switch choice.item.kind {
            case "Series": lines.append("Jellyfin deletes every episode's file from the server.")
            case "Season": lines.append("Jellyfin deletes the file of every episode in this season from the server.")
            default: lines.append("Jellyfin deletes the file from the server.")
            }
        }
        if let removal = choice.seerr {
            lines.append("Seerr removes it from \(removal.service), which deletes its files, and clears its requests.")
        }
        lines.append("This can't be undone. Copies downloaded to your devices are kept.")
        return lines.joined(separator: " ")
    }

    /// The menu entry was pressed: find out which ways are open, then ask.
    /// The item a grid holds has no TMDB id, so it is asked for whole first
    /// when Seerr might have a part in this.
    static func ask(_ item: BaseItem, client: JellyfinClient, seerr: SeerrClient, app: AppModel) async {
        var full = item
        var removal: SeerrRemoval?
        if seerr.mightRemove(item) {
            if item.tmdbId == nil, let fetched = try? await client.item(item.Id) { full = fetched }
            removal = await seerr.removal(for: full)
        }
        let choice = ServerDeleteChoice(item: full, jellyfin: (full.CanDelete ?? item.CanDelete) == true, seerr: removal)
        guard !choice.isEmpty else {
            app.toast("\(name(of: item)) can't be deleted from here: Seerr has no \(SeerrClient.removalKind(of: item) == .movie ? "Radarr" : "Sonarr") entry for it", tone: .error)
            return
        }
        app.deletingFromServer = choice
    }

    static func deleteFromJellyfin(_ item: BaseItem, client: JellyfinClient, app: AppModel) async {
        let name = name(of: item)
        do {
            try await client.deleteItem(item.Id)
            finished(item, app: app)
            app.toast("Deleted \(name) from the server", tone: .ok)
        } catch APIError.server(let status, _) where status == 401 || status == 403 {
            app.toast("This account isn't allowed to delete \(name)", tone: .error)
        } catch APIError.server(let status, _) where status == 404 {
            // Already gone, which is what was asked for.
            finished(item, app: app)
            app.toast("\(name) was already gone from the server", tone: .ok)
        } catch {
            app.toast("Couldn't delete \(name)", tone: .error)
        }
    }

    static func removeWithSeerr(_ choice: ServerDeleteChoice, seerr: SeerrClient, app: AppModel) async {
        guard let removal = choice.seerr else { return }
        let name = name(of: choice.item)
        do {
            try await seerr.remove(removal)
            // Jellyfin drops the title when it next looks at its folders;
            // until then the page would open onto files that are gone.
            LibraryIndex.shared.forget(choice.item.Id)
            finished(choice.item, app: app)
            app.toast("Removed \(name) from \(removal.service). Jellyfin drops it at its next library scan.", tone: .ok)
        } catch {
            let why = (error as? SeerrError)?.errorDescription ?? "Seerr couldn't be reached."
            app.toast("Couldn't remove \(name): \(why)", tone: .error)
        }
    }

    private static func finished(_ item: BaseItem, app: AppModel) {
        app.noteDeletedFromServer(item.Id)
        ItemMutations.shared.changed()
    }
}

/// The question "Delete from Server" asks: which way. Both are red; neither
/// can be taken back. Shown by whichever window or screen is in front, as
/// `NextUpChoiceDialog` is.
struct ServerDeleteDialog: ViewModifier {
    var isMine: Bool

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    func body(content: Content) -> some View {
        content.confirmationDialog(
            app.deletingFromServer.map { "Delete \(ServerDeleting.name(of: $0.item))?" } ?? "",
            isPresented: Binding(
                get: { app.deletingFromServer != nil && isMine },
                set: { if !$0 { app.deletingFromServer = nil } }
            ),
            titleVisibility: .visible,
            presenting: app.deletingFromServer
        ) { choice in
            if choice.jellyfin {
                Button(ServerDeleting.jellyfinLabel(for: choice.item), role: .destructive) {
                    app.deletingFromServer = nil
                    Task { await ServerDeleting.deleteFromJellyfin(choice.item, client: client, app: app) }
                }
                .accessibilityIdentifier(TestID.Shell.serverDeleteJellyfin)
            }
            if let removal = choice.seerr {
                Button(ServerDeleting.seerrLabel(for: removal), role: .destructive) {
                    app.deletingFromServer = nil
                    Task { await ServerDeleting.removeWithSeerr(choice, seerr: SeerrClient.shared, app: app) }
                }
                .accessibilityIdentifier(TestID.Shell.serverDeleteSeerr)
            }
            Button("Cancel", role: .cancel) { app.deletingFromServer = nil }
                .accessibilityIdentifier(TestID.Shell.serverDeleteCancel)
        } message: { choice in
            Text(ServerDeleting.message(for: choice))
        }
    }
}

extension View {
    func serverDeleteDialog(isMine: Bool) -> some View {
        modifier(ServerDeleteDialog(isMine: isMine))
    }
}
