//  Live TV: a time-table guide for the channels. Channels play through
//  PlaybackInfo with AutoOpenLiveStream, exactly as on Linux — unless
//  Settings points Live TV at a custom M3U playlist instead, in which case a
//  channel plays its own stream URL directly and Jellyfin never hears about
//  it. See IPTVSource and PlayerModel.playExternal.
//
//  The channels themselves live in `LiveTVStore` rather than in this view, so
//  the work of producing them can start when the app opens instead of when the
//  tab is tapped. This screen only draws what is there.

import SwiftUI

struct LiveTVView: View {
    @Environment(Preferences.self) private var prefs

    private var store: LiveTVStore { LiveTVStore.shared }

    #if os(macOS)
    @State private var filter = ""
    /// How many times Refresh has been asked for. Handed to the guide so
    /// that it fetches its programmes again even when the channel list comes
    /// back with the same ids — see `TVGuideView.reloadToken`.
    @State private var refreshCount = 0
    #endif

    private var channels: [BaseItem] { store.channels }

    /// The channels the guide is given. Everything on iOS and tvOS; on a Mac,
    /// whatever the navigation bar's search field has narrowed them to.
    private var shown: [BaseItem] {
        #if os(macOS)
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return channels }
        return channels.filter {
            $0.title.lowercased().contains(term)
                || ($0.ChannelNumber ?? "").contains(term)
                || ($0.CurrentProgram?.Name ?? "").lowercased().contains(term)
        }
        #else
        return channels
        #endif
    }

    var body: some View {
        #if os(tvOS)
        core
        #elseif os(iOS)
        // No navigation bar: this screen draws its own heading, for the same
        // reason Home and a detail page do. A large title collapses as its
        // scroll view moves — the bar reads the guide's height, the guide is
        // laid out against the bar, and at some screen sizes those two chase
        // each other until the main thread is spinning inside AttributeGraph
        // under `UIHostingView.layoutSubviews` and the system kills the app.
        // (It reproduced on a 17 Pro Max and not on a 17 Pro, which is what a
        // feedback loop that depends on exact sizes looks like from outside.)
        // A bar the page draws for itself is the height it is from the first
        // frame, so it can be as large as the screen deserves without any of
        // that.
        core.toolbar(.hidden, for: .navigationBar)
        #else
        // The Mac's furniture is the window's: the filter in the toolbar's
        // search field, Refresh beside it, and the day and the line-up in the
        // subtitle under the title. The guide's own controls — earlier, now,
        // later, the date — are added to the same toolbar by `TVGuideView`.
        core
            .searchable(text: $filter, placement: .toolbar, prompt: "Filter Channels")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Fetch the channels and guide again (⌘R)")
                    .disabled(store.isLoading)
                }
            }
            // View ▸ Refresh, ⌘R. A counter from the menu rather than a
            // shortcut on the button, so the key is bound in one place.
            .onChange(of: MacCommandRequests.shared.refresh) { _, _ in refresh() }
        #endif
    }

    #if os(macOS)
    /// Fetch the line-up again, then tell the guide to ask for its programmes
    /// again too: a Jellyfin refresh brings back the same channel ids, which
    /// the guide would otherwise take as nothing having changed.
    private func refresh() {
        Task {
            await store.refresh()
            refreshCount += 1
        }
    }

    /// What the subtitle says after the day: how many channels, of how many
    /// when the filter is narrowing them, and where they come from.
    private var sourceSummary: String {
        let source = prefs.liveTVSource == .custom ? "Custom playlist" : "Jellyfin"
        let count: String
        if shown.count == channels.count {
            count = "\(channels.count) channel\(channels.count == 1 ? "" : "s")"
        } else {
            count = "\(shown.count) of \(channels.count) channels"
        }
        return "\(count) · \(source)"
    }
    #endif

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The screen's name, at the size a large title would have been.
    ///
    /// It shrinks back to an ordinary bar when the phone is turned sideways.
    /// The guide is the one page in this app that is wider than it is tall and
    /// the one page a phone may be rotated for (see `allowsLandscape`), and in
    /// landscape a phone has about four hundred points of height to give it —
    /// a heading taking a fifth of that would be the screen's own furniture
    /// crowding out the thing the screen is for.
    private var header: some View {
        let roomy = verticalSizeClass != .compact
        return AppTopBar(height: Metrics.topBar + (roomy ? 26 : 0)) {
            Text("Live TV")
                .font(roomy ? .largeTitle.weight(.bold) : .headline)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
    }
    #endif

    private var core: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
            // Stacked above the guide rather than fitted into it with
            // `safeAreaInset`, which is what Home and a detail page use.
            //
            // Those two put a plain `ScrollView` under the bar. This screen's
            // scroll view has a pinned section header and a second, horizontal
            // scroll view inside every row, and an inset over that arrangement
            // reopens the feedback loop the inline title was introduced to
            // close: the inset changes the scroll view's safe area, the scroll
            // view's own safe-area update changes the inset, and the main
            // thread spins inside `HostingScrollView._updateSafeAreaInsets`
            // until the watchdog kills the app. A sibling in a stack takes its
            // height from its own content and nothing else, so there is no
            // second party to the negotiation.
            header
            #endif
            // No filter field on a television, and none on a phone or an iPad
            // either. It was the first thing the tvOS selector met coming down
            // off the tab strip and it opened the on-screen keyboard on the way
            // past; on iOS it cost a row of the one screen in the app that is
            // short of vertical room, sitting beside window arrows that did
            // nothing scrolling the guide sideways doesn't. The channel column
            // is scrolled rather than filtered on both. A Mac keeps its
            // `.searchable` field, which costs the guide no height at all.
            content
        }
        .screenTitle("Live TV")
        .paletteBar()
        // Keyed rather than bare `.task {}`: a tab's view stays alive when you
        // switch away from it (see `reloadWhenPlaybackEnds`), so changing the
        // source or its URLs in Settings — or tapping "Refresh now" there —
        // has to be what reloads this.
        .task(id: reloadKey) { await store.ensureLoaded(key: reloadKey) }
        .task(id: autoRefreshKey) { await autoRefresh() }
        .reloadWhenPlaybackEnds { await store.refreshAfterPlayback() }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading, channels.isEmpty {
            ScrollView { SkeletonList(count: 7).padding(.top, 8) }
        } else if let error = store.error, channels.isEmpty {
            ErrorState(error: error) { Task { await store.refresh() } }
        } else if channels.isEmpty {
            EmptyState(
                symbol: "antenna.radiowaves.left.and.right",
                title: "No channels",
                message: emptyChannelsMessage
            )
        } else {
            // Not nested in a ScrollView of its own: the guide's vertical
            // scroll region has to be the one giving the page its scroll, or
            // the time ruler pinned above it has nothing to stay fixed
            // against — see TVGuideView.
            #if os(macOS)
            TVGuideView(
                channels: shown,
                programsProvider: store.programsProvider,
                noMatches: shown.isEmpty ? filter : nil,
                sourceSummary: sourceSummary,
                reloadToken: refreshCount
            )
            #else
            TVGuideView(
                channels: shown,
                programsProvider: store.programsProvider
            )
            #endif
        }
    }

    private var emptyChannelsMessage: String {
        if prefs.liveTVSource == .custom {
            return "No channels loaded from the playlist — check the M3U address in Settings."
        }
        return "This server has a Live TV library but no channels are available — check that a tuner and guide data are configured in Jellyfin."
    }

    private var reloadKey: String { LiveTVStore.key }

    /// Keyed on the interval rather than folded into `reloadKey`: changing
    /// *how often* to refresh shouldn't itself trigger an immediate reload
    /// the way changing the source or URLs does, only restart this wait with
    /// the new duration.
    private var autoRefreshKey: String {
        "\(prefs.liveTVSource.rawValue)|\(prefs.iptvRefreshMinutes)"
    }

    /// Re-downloads the custom playlist and guide on a timer — the Jellyfin
    /// path already asks the server fresh on every load, so there's nothing
    /// here for it to do. `.task(id:)` cancels and restarts this the moment
    /// the source or interval changes, which is what makes turning it off
    /// (or picking a new interval) take effect immediately rather than after
    /// whatever wait was already in progress.
    private func autoRefresh() async {
        guard prefs.liveTVSource == .custom, prefs.iptvRefreshMinutes > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double(prefs.iptvRefreshMinutes) * 60))
            guard !Task.isCancelled else { return }
            await store.refresh()
        }
    }
}
