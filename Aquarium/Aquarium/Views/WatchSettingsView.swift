//  Settings → Apple Watch: what the watch holds, taken off from here; the
//  playlists kept on it; and whether the phone and the watch are talking.

#if os(iOS)

import SwiftUI

struct WatchSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(Preferences.self) private var prefs
    @State private var link = WatchLink.shared
    @State private var playlists = PlaylistStore.shared
    @State private var confirmAll = false

    var body: some View {
        Form {
            Section {
                if !link.isPaired {
                    Label("No Apple Watch is paired with this iPhone.", systemImage: "applewatch.slash")
                        .foregroundStyle(Theme.textDim)
                } else if !link.isWatchAppInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Aquarium isn't on the watch yet", systemImage: "applewatch")
                        Text("Install it from the Watch app on this iPhone, under Available Apps.")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                } else {
                    LabeledContent("Watch", value: link.isReachable ? "In reach" : "Away")
                    LabeledContent("Signed in on watch", value: link.watchSignedIn ? "Yes" : "Not yet")
                    if let at = link.lastContextSentAt {
                        LabeledContent("Sign-in sent", value: at.formatted(.relative(presentation: .named)))
                    }
                    Button("Send Sign-In Again") { link.sendContext(now: true) }
                        .disabled(client.session == nil)
                }
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("The watch signs in with this phone's account, browses and plays from the server on its own, and tells the phone what it listened to — the phone passes that to the server. When the phone is out of reach and the watch has a network, the watch tells the server itself.")
            }

            if link.isAvailable {
                mirrorSection
                storageSection
                syncSection
            }
        }
        .screenTitle("Apple Watch")
        .task {
            await playlists.ensureLoaded()
            link.requestInventory()
        }
    }

    // MARK: Mirror

    private var mirrorSection: some View {
        Section {
            Text("Audiobooks you're part-way through are sent to the watch automatically.")
                .font(.callout)
                .foregroundStyle(Theme.textDim)
            if playlists.playlists.isEmpty {
                Text(playlists.isLoading ? "Loading playlists…" : "No playlists on this server.")
                    .foregroundStyle(Theme.textDim)
            }
            ForEach(playlists.playlists) { list in
                Toggle(isOn: binding(for: list.Id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.title)
                        if let n = list.ChildCount {
                            Text("\(n) song\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.textDim)
                        }
                    }
                }
            }
        } header: {
            Text("Kept on the watch")
        } footer: {
            Text("A playlist picked here is downloaded to the watch over Wi‑Fi and kept up to date as it changes. Turning one off leaves what is already on the watch; remove it below.")
        }
    }

    private func binding(for playlistId: String) -> Binding<Bool> {
        Binding(
            get: { prefs.watchPlaylistIds.contains(playlistId) },
            set: { on in
                var ids = prefs.watchPlaylistIds
                if on { if !ids.contains(playlistId) { ids.append(playlistId) } } else { ids.removeAll { $0 == playlistId } }
                prefs.watchPlaylistIds = ids
                link.sendContext()
            }
        )
    }

    // MARK: Storage

    @ViewBuilder
    private var storageSection: some View {
        Section {
            if let inventory = link.inventory {
                LabeledContent("On the watch") {
                    Text("\(inventory.itemCount) item\(inventory.itemCount == 1 ? "" : "s") · \(Format.bytes(inventory.totalBytes))")
                }
                if let free = inventory.freeBytes {
                    LabeledContent("Free on the watch", value: Format.bytes(free))
                }
                if inventory.inFlight > 0 {
                    LabeledContent("Downloading", value: "\(inventory.inFlight)")
                }
                if let fetching = link.fetching {
                    HStack {
                        Text("Fetching for the watch")
                        Spacer()
                        if let f = link.fetchFraction {
                            ProgressView(value: f).frame(width: 80)
                        } else {
                            ProgressView()
                        }
                    }
                    .accessibilityLabel("Fetching \(fetching) for the watch")
                }
                if !link.transferring.isEmpty {
                    LabeledContent("Sending to the watch", value: "\(link.transferring.count)")
                }
                if !link.fetchQueue.isEmpty {
                    LabeledContent("Waiting to fetch", value: "\(link.fetchQueue.count)")
                }
                ForEach(inventory.groups) { group in
                    HStack(spacing: 12) {
                        Image(systemName: group.kind.symbol)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title).lineLimit(1)
                            Text(groupDetail(group)).font(.caption).foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        Text(Format.bytes(group.bytes)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            link.deleteFromWatch(group)
                            app.toast("Removing \(group.title) from the watch", tone: .ok)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                if inventory.truncated {
                    Text("The list is longer than the watch could send; the totals count everything.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
                if !inventory.groups.isEmpty {
                    Button("Remove Everything from the Watch", role: .destructive) { confirmAll = true }
                }
            } else {
                HStack {
                    Text("Waiting for the watch to say what it holds…").foregroundStyle(Theme.textDim)
                    Spacer()
                    ProgressView()
                }
            }
        } header: {
            Text("Storage on the watch")
        } footer: {
            if let at = link.inventoryAt {
                Text("As of \(at.formatted(.relative(presentation: .named))). Swipe a row to remove it from the watch. The phone fetches what the watch asks for and hands it across, so downloads reach the watch over Bluetooth; they are AAC at 128 kbps.")
            }
        }
        .confirmationDialog("Remove everything from the watch?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Remove Everything", role: .destructive) {
                link.deleteEverythingOnWatch()
                app.toast("Removing everything from the watch", tone: .ok)
            }
        } message: {
            Text("Every audiobook, playlist and album on the watch will be deleted. Nothing on this phone or the server is touched.")
        }
    }

    private func groupDetail(_ group: WatchStorageGroup) -> String {
        var parts: [String] = [group.kind.label]
        if let sub = group.subtitle, !sub.isEmpty, group.kind != .playlist { parts.append(sub) }
        if group.kind != .book {
            parts.append(group.complete == group.count ? "\(group.count) song\(group.count == 1 ? "" : "s")" : "\(group.complete) of \(group.count) songs")
        } else if group.complete < group.count {
            parts.append("arriving")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Sync

    private var syncSection: some View {
        Section {
            LabeledContent("Waiting for the server", value: "\(link.pendingEvents.count)")
            if let at = link.lastForwardedAt {
                LabeledContent("Last passed on", value: at.formatted(.relative(presentation: .named)))
            }
            Button("Pass On Now") { link.forward() }
                .disabled(link.pendingEvents.isEmpty || client.isOffline)
        } header: {
            Text("Listening from the watch")
        } footer: {
            Text("Where a book was left and which songs were heard, as the watch reported them. Passed to the server as soon as it can be reached.")
        }
    }
}

#endif
