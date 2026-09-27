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
                relaySection
                storageSection
                syncSection
                diagnosticsSection
            }
        }
        .screenTitle("Apple Watch")
        .task {
            await playlists.ensureLoaded()
            link.requestInventory()
            link.reloadWatchLogs()
        }
    }

    // MARK: Mirror

    private var mirrorSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { prefs.watchKeepsBooks },
                set: { on in prefs.watchKeepsBooks = on; link.sendContext() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audiobooks in progress")
                    Text("Every book you're part-way through, sent as you start it")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
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
            Text("A playlist is on when it is on the watch, whether it was picked here or downloaded on the watch. Playlists on the watch follow the server: songs added there are downloaded, and songs taken out are removed from the watch. Turning a playlist off removes it from the watch. Books you're part-way through are sent as you start them; turning that off leaves those already sent.")
        }
    }

    private func binding(for playlistId: String) -> Binding<Bool> {
        Binding(
            get: { link.keepsOnWatch(playlistId) },
            set: { on in link.setKeepsOnWatch(playlistId, on) }
        )
    }

    // MARK: Fetching for the watch

    @ViewBuilder
    private var relaySection: some View {
        if !link.relayItems.isEmpty {
            Section {
                ForEach(relayRows) { item in
                    RelayItemRow(item: item)
                }
                if link.relayItems.contains(where: { $0.stage == .failed }) {
                    Button("Clear Failed") { link.clearFinishedRelayItems() }
                }
            } header: {
                Text("Fetching for the watch")
            } footer: {
                Text("What the watch asked this phone for: downloaded from the server here, a few at a time, then sent to the watch. Each leaves the list once it is on the watch. Downloads and sends carry on in the background.")
            }
        }
    }

    /// Moving first, furthest along at the top; then waiting, in the order
    /// they'll start; then what failed.
    private var relayRows: [RelayItem] {
        func along(_ r: RelayItem) -> Double { 0.5 * (r.downloadFraction ?? 0) + 0.5 * (r.transferFraction ?? 0) }
        let queue = Dictionary(link.fetchQueue.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let moving = link.relayItems.filter { $0.stage == .downloading || $0.stage == .sending }.sorted { along($0) > along($1) }
        let waiting = link.relayItems.filter { $0.stage == .waiting }
            .sorted { (queue[$0.id] ?? .max, $0.askedAt ?? .distantPast) < (queue[$1.id] ?? .max, $1.askedAt ?? .distantPast) }
        let failed = link.relayItems.filter { $0.stage == .failed }.sorted { $0.updatedAt > $1.updatedAt }
        return moving + waiting + failed
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

    // MARK: Diagnostics

    @State private var exportingPhone = false

    private var diagnosticsSection: some View {
        Section {
            Button {
                link.requestWatchLogs()
            } label: {
                Label("Fetch Log from Watch", systemImage: "applewatch.radiowaves.left.and.right")
            }
            if let at = link.logsRequestedAt, !link.watchLogs.contains(where: { logDate($0) > at }) {
                Text("Asked \(at.formatted(.relative(presentation: .named))). The watch sends it in the background; it can take a minute, longer when the watch is away.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
            Button {
                exportingPhone = true
                Task { _ = await link.exportPhoneLog(); exportingPhone = false }
            } label: {
                if exportingPhone { ProgressView() } else { Label("Save This iPhone's Log", systemImage: "iphone") }
            }
            .disabled(exportingPhone)
            ForEach(link.watchLogs, id: \.self) { url in
                ShareLink(item: url) {
                    HStack {
                        Image(systemName: url.lastPathComponent.hasPrefix("AquariumPhone") ? "iphone" : "applewatch")
                            .foregroundStyle(Theme.textDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent.hasPrefix("AquariumPhone") ? "iPhone log" : "Watch log")
                            Text("\(logDate(url).formatted(date: .abbreviated, time: .shortened)) · \(Format.bytes(logSize(url)))")
                                .font(.caption).foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accent)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { link.deleteWatchLog(url) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The watch keeps a log of what it does: sign-in, downloads, playback, and anything the system reported, with the memory it had left. Fetch it here or send it from the watch under Settings → Send Log to iPhone, then share the file from this list.")
        }
    }

    private func logDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private func logSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
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

/// One item on its way to the watch: the download, then the send, each
/// with its bar and a check when done.
private struct RelayItemRow: View {
    let item: RelayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title ?? "Looking it up…")
                .lineLimit(1)
                .foregroundStyle(item.title == nil ? Theme.textDim : Theme.text)
            step("Download to this phone", symbol: "arrow.down.circle",
                 fraction: item.downloadFraction, active: item.stage == .downloading)
            step("Send to the watch", symbol: "applewatch",
                 fraction: item.transferFraction, active: item.stage == .sending)
            switch item.stage {
            case .waiting:
                Text("Waiting its turn").font(.caption).foregroundStyle(Theme.textDim)
            case .failed:
                Label(item.failure ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func step(_ label: String, symbol: String, fraction: Double?, active: Bool) -> some View {
        let done = (fraction ?? 0) >= 1
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(active || done ? Theme.accent : Theme.textDim)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label).font(.caption)
                    Spacer()
                    if !done, let fraction {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                    }
                }
                if active, fraction == nil {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: min(1, fraction ?? 0))
                        .tint(done ? Theme.ok : Theme.accent)
                }
            }
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.ok : Theme.textDim.opacity(0.5))
                .accessibilityLabel(done ? "done" : "not done")
        }
    }
}

#endif
