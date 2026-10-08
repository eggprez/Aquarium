//  Settings → Apple Watch: what the watch holds, taken off from here; the
//  playlists kept on it; and whether the phone and the watch are talking.
//
//  A hub, shaped like the rest of Settings: the watch's state in a card at
//  the top, then a row for each of the things that change — what is kept on
//  it, what is on it, what is on its way — each a page of its own, and the
//  listening it reports back as a short section inline. The log machinery,
//  wanted once in a long while, is a page under Support.

#if os(iOS)

import SwiftUI

struct WatchSettingsView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var link = WatchLink.shared
    @State private var playlists = PlaylistStore.shared

    var body: some View {
        Form {
            Section {
                statusCard
            } footer: {
                if link.isAvailable {
                    Text("The watch signs in with this phone's account, browses and plays from the server on its own, and tells the phone what it listened to.")
                }
            }

            if link.isAvailable {
                Section {
                    NavigationLink {
                        WatchKeptPage()
                            .clearsBottomChrome()
                    } label: {
                        LabeledContent("Kept on the watch", value: keptSummary)
                    }
                    NavigationLink {
                        WatchStoragePage()
                            .clearsBottomChrome()
                    } label: {
                        LabeledContent("Storage on the watch", value: storageSummary)
                    }
                    if !link.relayItems.isEmpty {
                        NavigationLink {
                            WatchTransfersPage()
                                .clearsBottomChrome()
                        } label: {
                            LabeledContent("Transfers", value: transfersSummary)
                        }
                    }
                } header: {
                    Text("Content")
                } footer: {
                    Text("Playlists on the watch follow the server. The phone fetches what the watch asks for and hands it across over Bluetooth.")
                }

                Section {
                    LabeledContent("Waiting for the server", value: "\(link.pendingEvents.count)")
                    if let at = link.lastForwardedAt {
                        LabeledContent("Last passed on", value: at.formatted(.relative(presentation: .named)))
                    }
                    Button("Pass On Now") { link.forward() }
                        .disabled(link.pendingEvents.isEmpty || client.isOffline)
                } header: {
                    Text("Listening history")
                } footer: {
                    Text("Where a book was left and which songs were heard, as the watch reported them. Passed to the server as soon as it can be reached.")
                }

                Section {
                    NavigationLink {
                        WatchDiagnosticsPage()
                            .clearsBottomChrome()
                    } label: {
                        LabeledContent("Diagnostics", value: link.watchLogs.isEmpty ? "" : "\(link.watchLogs.count) log\(link.watchLogs.count == 1 ? "" : "s")")
                    }
                    Button("Send Sign-In Again") { link.sendContext(now: true) }
                        .disabled(client.session == nil)
                } header: {
                    Text("Support")
                } footer: {
                    if let at = link.lastContextSentAt {
                        Text("Sign-in last sent \(at.formatted(.relative(presentation: .named))).")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await playlists.ensureLoaded()
            link.requestInventory()
            link.reloadWatchLogs()
        }
    }

    // MARK: The card

    @ViewBuilder
    private var statusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: link.isPaired ? "applewatch" : "applewatch.slash")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(SettingsPage.watch.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(cardTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(cardDetail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if link.isAvailable {
                StatusPill(text: link.isReachable ? "In reach" : "Away", tone: link.isReachable ? .ok : .neutral)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var cardTitle: String {
        guard link.isPaired else { return "No Apple Watch" }
        guard link.isWatchAppInstalled else { return "Aquarium isn't on the watch" }
        return "Apple Watch"
    }

    private var cardDetail: String {
        guard link.isPaired else { return "None is paired with this iPhone." }
        guard link.isWatchAppInstalled else { return "Install it from the Watch app on this iPhone, under Available Apps." }
        var parts = [link.watchSignedIn ? "Signed in" : "Not signed in yet"]
        if let inventory = link.inventory {
            parts.append(inventory.itemCount == 0 ? "nothing on it" : "\(inventory.itemCount) item\(inventory.itemCount == 1 ? "" : "s") on it")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: The values

    private var keptSummary: String {
        var parts: [String] = []
        if Preferences.shared.watchKeepsBooks { parts.append("Books") }
        let lists = playlists.playlists.filter { link.keepsOnWatch($0.Id) }.count
        if lists > 0 { parts.append("\(lists) playlist\(lists == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " · ")
    }

    private var storageSummary: String {
        guard let inventory = link.inventory else { return "" }
        var parts = [Format.bytes(inventory.totalBytes)]
        if let free = inventory.freeBytes { parts.append("\(Format.bytes(free)) free") }
        return parts.joined(separator: " · ")
    }

    private var transfersSummary: String {
        let moving = link.relayItems.filter { $0.stage == .downloading || $0.stage == .sending }.count
        let failed = link.relayItems.filter { $0.stage == .failed }.count
        if moving > 0 { return "\(moving) in progress" }
        if failed > 0 { return "\(failed) failed" }
        return "\(link.relayItems.count) waiting"
    }
}

// MARK: - Kept on the watch

private struct WatchKeptPage: View {
    @Environment(Preferences.self) private var prefs
    @State private var link = WatchLink.shared
    @State private var playlists = PlaylistStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { prefs.watchKeepsBooks },
                    set: { on in prefs.watchKeepsBooks = on; link.sendContext() }
                )) {
                    Text("Audiobooks in progress")
                }
            } footer: {
                Text("Every book you're part-way through, sent as you start it. Turning this off leaves those already sent.")
            }

            Section {
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
                Text("Playlists")
            } footer: {
                Text("A playlist is on when it is on the watch, whether it was picked here or downloaded on the watch. Playlists on the watch follow the server: songs added there are downloaded, and songs taken out are removed from the watch. Turning a playlist off removes it from the watch.")
            }
        }
        .formStyle(.grouped)
        .screenTitle("Kept on the Watch")
        .paletteBar()
        .task { await playlists.ensureLoaded() }
    }

    private func binding(for playlistId: String) -> Binding<Bool> {
        Binding(
            get: { link.keepsOnWatch(playlistId) },
            set: { on in link.setKeepsOnWatch(playlistId, on) }
        )
    }
}

// MARK: - Storage on the watch

private struct WatchStoragePage: View {
    @Environment(AppModel.self) private var app
    @State private var link = WatchLink.shared
    @State private var confirmAll = false

    var body: some View {
        Form {
            if let inventory = link.inventory {
                Section {
                    LabeledContent("On the watch") {
                        Text("\(inventory.itemCount) item\(inventory.itemCount == 1 ? "" : "s") · \(Format.bytes(inventory.totalBytes))")
                    }
                    if let free = inventory.freeBytes {
                        LabeledContent("Free on the watch", value: Format.bytes(free))
                    }
                    if inventory.inFlight > 0 {
                        LabeledContent("Downloading", value: "\(inventory.inFlight)")
                    }
                } footer: {
                    if let at = link.inventoryAt {
                        Text("As of \(at.formatted(.relative(presentation: .named))). Downloads reach the watch over Bluetooth as AAC at 128 kbps.")
                    }
                }

                if !inventory.groups.isEmpty {
                    Section {
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
                    } header: {
                        Text("What is on it")
                    } footer: {
                        Text(inventory.truncated
                             ? "Swipe a row to remove it from the watch. The list is longer than the watch could send; the totals count everything."
                             : "Swipe a row to remove it from the watch.")
                    }

                    Section {
                        Button("Remove Everything from the Watch", role: .destructive) { confirmAll = true }
                    }
                }
            } else {
                Section {
                    HStack {
                        Text("Waiting for the watch to say what it holds…").foregroundStyle(Theme.textDim)
                        Spacer()
                        ProgressView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Storage on the Watch")
        .paletteBar()
        .task { link.requestInventory() }
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
}

// MARK: - Transfers

private struct WatchTransfersPage: View {
    @State private var link = WatchLink.shared

    var body: some View {
        Form {
            Section {
                if link.relayItems.isEmpty {
                    Text("Nothing is on its way to the watch.")
                        .foregroundStyle(Theme.textDim)
                }
                ForEach(relayRows) { item in
                    RelayItemRow(item: item)
                }
                if link.relayItems.contains(where: { $0.stage == .failed }) {
                    Button("Clear Failed") { link.clearFinishedRelayItems() }
                }
            } footer: {
                Text("What the watch asked this phone for: downloaded from the server here, a few at a time, then sent to the watch. Each leaves the list once it is on the watch. Downloads and sends carry on in the background.")
            }
        }
        .formStyle(.grouped)
        .screenTitle("Transfers")
        .paletteBar()
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
}

// MARK: - Diagnostics

private struct WatchDiagnosticsPage: View {
    @State private var link = WatchLink.shared
    @State private var exportingPhone = false

    var body: some View {
        Form {
            Section {
                Button {
                    link.requestWatchLogs()
                } label: {
                    Label("Fetch Log from Watch", systemImage: "applewatch.radiowaves.left.and.right")
                }
                Button {
                    exportingPhone = true
                    Task { _ = await link.exportPhoneLog(); exportingPhone = false }
                } label: {
                    if exportingPhone { ProgressView() } else { Label("Save This iPhone's Log", systemImage: "iphone") }
                }
                .disabled(exportingPhone)
            } footer: {
                if let at = link.logsRequestedAt, !link.watchLogs.contains(where: { logDate($0) > at }) {
                    Text("Asked \(at.formatted(.relative(presentation: .named))). The watch sends it in the background; it can take a minute, longer when the watch is away.")
                } else {
                    Text("The watch keeps a log of what it does: sign-in, downloads, playback, and anything the system reported, with the memory it had left. Fetch it here or send it from the watch under Settings → Send Log to iPhone.")
                }
            }

            if !link.watchLogs.isEmpty {
                Section {
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
                    Text("Logs")
                } footer: {
                    Text("Tap a log to share it. Swipe to delete it.")
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Diagnostics")
        .paletteBar()
        .task { link.reloadWatchLogs() }
    }

    private func logDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private func logSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
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
