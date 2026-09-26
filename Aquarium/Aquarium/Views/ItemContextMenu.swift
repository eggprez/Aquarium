//  Press and hold: what a card, a row or a poster can do without being opened
//  first.
//
//  Every screen in this app is made of the same few containers — `MediaShelf`,
//  `MediaGrid`, `EpisodeRow`, the guide's channel column — so the menu is
//  written once here and those containers carry it. That is the whole reason it
//  is a modifier rather than a block of buttons copied into five files: "mark
//  watched" should be in the same place with the same wording whether you found
//  the episode on Home, in a library, in search or in the season it belongs to.
//
//  The gesture is the platform's own. A finger holds a tile down; the Siri
//  Remote holds the select button on whatever the selector is on. Neither needs
//  anything drawn for it, which is why these actions are additive: nothing here
//  is the only way to reach anything.

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Change notice

/// Something about an item on the server has changed — watched, favourite, a
/// download queued — so the screens showing it can ask again.
///
/// The menu can be opened from anywhere, and what it changes is almost never
/// held by the view it was opened from: marking an episode watched from Home
/// changes Continue Watching, Next Up, the library grid behind it and the
/// season page two taps away. None of those own the item, and none of them can
/// be handed a corrected copy. So the fact of the change is broadcast and each
/// screen decides for itself whether it is worth a reload — the same shape as
/// `reloadWhenPlaybackEnds`, and for the same reason.
@MainActor
@Observable
final class ItemMutations {
    static let shared = ItemMutations()

    /// Bumped on every change. Nothing reads what changed: a screen that cares
    /// reloads whole, because the alternative is every screen keeping a map of
    /// which of its rows came from which request.
    private(set) var revision = 0

    func changed() { revision &+= 1 }

    private init() {}
}

/// Reloads a page when something changes — at once if the page is on
/// screen, otherwise the next time it is.
///
/// A navigation stack keeps every page under the top one alive, and a tab
/// keeps its pages when another tab is showing. So one "mark watched" used to
/// reload the episode, the season under it, the series under that, the
/// library grid and Home all at once: a dozen requests for pages nobody could
/// see, each of which reloads again when it is next shown anyway. Now a page
/// that is out of sight notes the change and reloads once, when it comes back.
private struct ReloadWhenItemsChange: ViewModifier {
    let reload: () async -> Void

    @State private var isVisible = false
    @State private var changedWhileHidden = false

    func body(content: Content) -> some View {
        content
            .onChange(of: ItemMutations.shared.revision) { _, _ in
                if isVisible {
                    Task { await reload() }
                } else {
                    changedWhileHidden = true
                }
            }
            .onAppear {
                isVisible = true
                guard changedWhileHidden else { return }
                changedWhileHidden = false
                Task { await reload() }
            }
            .onDisappear { isVisible = false }
    }
}

extension View {
    /// Ask the server again once a press-and-hold menu changes something.
    func reloadWhenItemsChange(_ reload: @escaping () async -> Void) -> some View {
        modifier(ReloadWhenItemsChange(reload: reload))
    }

    /// The press-and-hold menu for one item from the server.
    ///
    /// `allowsOpen` is off where the thing being held *is* the page's own way
    /// in — a poster whose tap already opens the title page doesn't need a
    /// menu entry saying so.
    func itemContextMenu(_ item: BaseItem, allowsOpen: Bool = false) -> some View {
        contextMenu { ItemMenu(item: item, allowsOpen: allowsOpen) }
    }
}

// MARK: - The menu

/// The actions themselves. Ordered as they are read rather than as they were
/// written: start it, find it, change what the server thinks of it, put it on
/// the device. Anything an item can't do simply isn't there — an entry that is
/// present and does nothing is worse than one that is missing.
struct ItemMenu: View {
    let item: BaseItem
    var allowsOpen: Bool = false

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// A channel is a stream and nothing else: no progress, no watched state,
    /// nothing to download. It gets the one action that means anything.
    private var isChannel: Bool { item.kind == "TvChannel" }

    /// Whether this item is media rather than a shelf of it.
    private var isPlayableItself: Bool { !item.isFolderLike && !isChannel }

    var body: some View {
        if isChannel {
            channelActions
        } else {
            playActions
            placeActions
            stateActions
            #if !os(tvOS)
            downloadActions
            #endif
        }
    }

    @ViewBuilder
    private var channelActions: some View {
        Button { playChannel() } label: {
            Label("Watch", systemImage: "play.fill")
        }
        // A playlist channel has no item on the server behind it, so there is
        // nothing to star. See `IPTVSource`.
        if item.ExternalStreamURL == nil { favoriteButton }
    }

    // MARK: Playing

    @ViewBuilder
    private var playActions: some View {
        if isPlayableItself {
            Button {
                Task { await player.play(item: item) }
            } label: {
                Label(item.progressFraction != nil ? "Resume" : "Play", systemImage: "play.fill")
            }
            .macShortcut(.return, modifiers: .command)
            // Only where there is something to go back past. On anything not
            // started this is the button above it under a second name.
            if item.progressFraction != nil {
                Button {
                    Task { await player.play(item: item, options: StreamOptions(resume: false)) }
                } label: {
                    Label("Play from Beginning", systemImage: "gobackward")
                }
            }
        } else if item.isSeries || item.isSeason {
            // A show has no media of its own; what it means by "play" is the
            // episode you are up to, which only the server can name. Resolved
            // when the button is pressed rather than when the menu is built —
            // a menu that costs a request per card to *open* is not worth
            // having.
            Button {
                Task { await playNext() }
            } label: {
                Label("Play Next Episode", systemImage: "play.fill")
            }
            .macShortcut(.return, modifiers: .command)
        }
    }

    /// Where the next episode comes from, in the order the answer gets less
    /// specific: what the server has queued for the show, else the first
    /// episode nobody has watched, else the opener.
    private func playNext() async {
        let seriesId = item.isSeries ? item.Id : (item.SeriesId ?? item.ParentId)
        guard let seriesId else { return }
        if item.isSeries, let next = try? await client.seriesNextUp(seriesId: seriesId) {
            await player.play(item: next)
            return
        }
        let seasonId = item.isSeason ? item.Id : nil
        let episodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? []
        guard let target = episodes.first(where: { !$0.userData.played }) ?? episodes.first else {
            app.toast("Nothing to play here yet", tone: .error)
            return
        }
        await player.play(item: target)
    }

    private func playChannel() {
        if let raw = item.ExternalStreamURL, let url = URL(string: raw) {
            player.playExternal(
                title: item.title,
                subtitle: item.CurrentProgram?.Name ?? "",
                artworkURL: Artwork.channelLogo(item, width: 600),
                streamURL: url,
                channel: item
            )
        } else {
            Task { await player.play(item: item, options: StreamOptions(resume: false, live: true)) }
        }
    }

    // MARK: Getting there

    /// The levels around this one. An episode found on Home is an episode with
    /// no context at all — which show, which season, what came before it — and
    /// these are the two questions a card like that provokes.
    @ViewBuilder
    private var placeActions: some View {
        if allowsOpen {
            Button {
                app.push(.item(item.Id))
            } label: {
                Label(detailsLabel, systemImage: "info.circle")
            }
        }
        #if os(macOS)
        // Its own window, with its own Back — see `ItemWindow`.
        Button {
            openWindow(id: ItemWindow.id, value: item.Id)
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        .keyboardShortcut("o", modifiers: [.command, .option])
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.title, forType: .string)
        } label: {
            Label("Copy Title", systemImage: "doc.on.doc")
        }
        #endif
        if item.isEpisode {
            if let seriesId = item.SeriesId, !seriesId.isEmpty {
                Button {
                    app.navigate(to: .item(seriesId))
                } label: {
                    #if os(macOS)
                    // A Mac menu has no subtitle line; the show's name is what
                    // the title bar of the page it opens will say.
                    Label("Go to Show", systemImage: "tv")
                    #else
                    // The name goes underneath as the menu's subtitle, which
                    // truncates; in the title it wrapped, and "Go to Abbott
                    // Elementary" on two lines made one row twice the height of
                    // its neighbours.
                    Text("Go to Show")
                    if let name = item.SeriesName, !name.isEmpty { Text(name) }
                    Image(systemName: "tv")
                    #endif
                }
            }
            if let seasonId = item.SeasonId, !seasonId.isEmpty {
                Button {
                    app.navigate(to: .item(seasonId))
                } label: {
                    Label(seasonLabel, systemImage: "rectangle.stack")
                }
            }
        }
    }

    /// "Get Info" is what a Mac calls the page about a thing; a phone calls
    /// it the details.
    private var detailsLabel: String {
        #if os(macOS)
        "Get Info"
        #else
        item.isEpisode ? "Episode Details" : "Details"
        #endif
    }

    /// Season zero is where Jellyfin files specials, which is never what
    /// "Season 0" means to anyone reading it.
    private var seasonLabel: String {
        if let name = item.SeasonName, !name.isEmpty { return "Go to \(name)" }
        guard let number = item.ParentIndexNumber else { return "Go to Season" }
        return number == 0 ? "Go to Specials" : "Go to Season \(number)"
    }

    // MARK: What the server thinks

    @ViewBuilder
    private var stateActions: some View {
        favoriteButton

        Button {
            Task { await toggleWatched() }
        } label: {
            Label(watchedLabel, systemImage: item.userData.played ? "arrow.uturn.backward.circle" : "checkmark.circle")
        }
        .macShortcut("u", modifiers: [.command, .shift])
    }

    /// A show or a season is marked whole, and saying so is the difference
    /// between a useful shortcut and an alarming one.
    private var watchedLabel: String {
        if item.userData.played { return item.isFolderLike ? "Mark All as Unwatched" : "Mark as Unwatched" }
        return item.isFolderLike ? "Mark All as Watched" : "Mark as Watched"
    }

    private var favoriteButton: some View {
        Button {
            Task { await toggleFavorite() }
        } label: {
            Label(
                item.userData.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: item.userData.isFavorite ? "star.slash" : "star"
            )
        }
        .macShortcut("d", modifiers: .command)
    }

    private func toggleFavorite() async {
        let next = !item.userData.isFavorite
        do {
            try await client.setFavorite(item.Id, favorite: next)
            ItemMutations.shared.changed()
        } catch {
            app.toast("Couldn't update favorites", tone: .error)
        }
    }

    private func toggleWatched() async {
        let next = !item.userData.played
        do {
            try await client.markPlayed(item.Id, played: next)
            ItemMutations.shared.changed()
        } catch {
            app.toast("Couldn't update watched state", tone: .error)
        }
    }

    // MARK: Onto the device

    #if !os(tvOS)
    /// Downloads, for the one item being held — a whole series or a whole
    /// season is a decision with a size attached, and that belongs on the page
    /// where the size can be shown. See `ItemDetailView.downloadMenu`.
    @ViewBuilder
    private var downloadActions: some View {
        if isPlayableItself {
            let existing = DownloadManager.shared.record(for: item.Id)
            if existing?.status == .complete {
                #if os(macOS)
                if let existing, let url = DownloadManager.shared.mediaURL(for: existing) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                #endif
                Button(role: .destructive) {
                    DownloadManager.shared.delete(item.Id)
                    app.toast("Download deleted", tone: .ok)
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            } else if DownloadManager.shared.isQueuedOrRunning(item.Id) {
                Button {
                    app.show(.downloads)
                } label: {
                    Label("Show Download Progress", systemImage: "arrow.down.circle.dotted")
                }
            } else {
                Menu {
                    #if os(macOS)
                    // A Mac menu is as wide as its widest row, so the full
                    // labels fit. A picker rather than buttons: the rungs are
                    // one choice among alternatives, which is what a picker
                    // says, and inline it draws as plain rows. Nothing is
                    // ticked because nothing is chosen yet.
                    Picker("Download", selection: Binding<DownloadQuality?>(
                        get: { nil },
                        set: { if let quality = $0 { download(quality) } }
                    )) {
                        ForEach(DownloadQualities.all) { quality in
                            Text(quality.label).tag(Optional(quality))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    #else
                    // The short labels: a press-and-hold menu is a fixed,
                    // narrow width, and "1080p · 9 Mbps (transcoded)" wrapped
                    // every row onto two lines — six rows became twelve, taller
                    // than a small phone has room for under the row being held.
                    ForEach(DownloadQualities.all) { quality in
                        Button(quality.menuLabel) { download(quality) }
                    }
                    #endif
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    /// The same disk-space gate the detail page applies, reporting rather than
    /// asking: a context menu is dismissed by the press that chose the item, so
    /// there is nothing left on screen to put a dialog on top of. What it can
    /// do is refuse for a stated reason and name a rung that would fit.
    private func download(_ quality: DownloadQuality) {
        Task { await queueDownload(quality) }
    }

    private func queueDownload(_ quality: DownloadQuality) async {
        // Grids and shelves leave the media sources out of what they ask for
        // (see `JellyfinClient.listFields`), and a download needs them: which
        // file the server holds decides whether it can come down as it is, and
        // what it weighs. Without them a request for the original would be
        // quietly turned into a transcode. So the item is asked for whole first.
        var item = self.item
        if !item.isAudio, item.MediaSources?.isEmpty != false {
            guard let full = try? await client.item(item.Id) else {
                app.toast("Couldn't reach the server to start that download", tone: .error)
                return
            }
            item = full
        }
        if let verdict = DownloadManager.checkSpace(for: [item], quality: quality), !verdict.fits {
            let alternative = verdict.alternatives.first.map { " Try \($0.label)." } ?? ""
            let message = "Needs about \(Format.bytes(verdict.needed)) and there is \(Format.bytes(verdict.free)) free."
                + alternative
            #if os(macOS)
            app.presentAlert(title: "Not Enough Disk Space", message: message)
            #else
            app.toast(message, tone: .error)
            #endif
            return
        }
        DownloadManager.shared.enqueue(item: item, quality: quality)
        // The rung the download will actually use, which is the original file
        // when the encode would have been the larger of the two. Saying "1080p ·
        // 9 Mbps" here and then showing "Original quality" on the Downloads
        // screen a second later reads as a bug.
        let queued = JellyfinClient.effectiveQuality(item: item, quality: quality)
        app.toast("Queued \(item.title) · \(queued.label)", tone: .ok)
    }
    #endif
}

// MARK: - Key equivalents

extension View {
    /// The shortcut the Item menu gives this action, so the context menu shows
    /// the same key beside the same words. Mac only: a phone's menu has no
    /// column for it, and the shortcut would be live on an iPad keyboard
    /// while the menu was open, which is not what the Item menu promises.
    @ViewBuilder
    func macShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        #if os(macOS)
        keyboardShortcut(key, modifiers: modifiers)
        #else
        self
        #endif
    }
}
