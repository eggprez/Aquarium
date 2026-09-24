//  Settings.
//
//  Every setting is a name, a control, and a sentence saying what the setting
//  actually does — the sentence being the part that stops a settings page from
//  being a list of words you have to guess at. Carried over from the Linux
//  build, minus the options that only meant something to an mpv process.
//
//  This file is the page on a Mac, where each sentence sits in a row of its
//  own under the control it describes, and the page on a phone and an iPad,
//  which is shaped like the television's instead: short, with the sentences
//  behind an (i) and the rarely-touched groups on pages of their own. A
//  television draws the same settings and the same sentences differently — see
//  `TVSettingsView.swift`. What all of them share is at the bottom of this file.

import SwiftUI

/// A setting's name and the sentence that explains it, written once and read by
/// both versions of the page.
struct SettingNote: Identifiable {
    /// The control this is about. Nil for a remark that belongs to the section
    /// rather than to any one row.
    var name: String?
    let text: String

    var id: String { text }

    /// The first sentence: what the Mac shows under a control, with the rest
    /// of `text` on hover.
    var summary: String {
        var first = text
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, stop in
            if let sub { first = sub.trimmingCharacters(in: .whitespaces) }
            stop = true
        }
        return first
    }
}

#if os(macOS)
/// The tabs of the Settings window, in the order they appear.
enum MacSettingsPane: String, CaseIterable, Identifiable {
    case general, account, playback, subtitles, liveTV, downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .account: "Account"
        case .playback: "Playback"
        case .subtitles: "Subtitles"
        case .liveTV: "Live TV"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: "person.crop.circle"
        case .playback: "play.rectangle"
        case .subtitles: "captions.bubble"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle"
        }
    }
}

/// The Settings window (⌘,): one tab per group, the way Mac apps lay out their
/// preferences, rather than one long page in the sidebar.
struct MacSettingsWindow: View {
    @AppStorage("settingsPane") private var pane: MacSettingsPane = .general

    var body: some View {
        TabView(selection: $pane) {
            ForEach(MacSettingsPane.allCases) { pane in
                SettingsView(pane: pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }
        .frame(width: 620, height: 560)
    }
}
#endif

#if os(macOS)
struct SettingsView: View {
    /// Which tab of the Settings window this is; nil draws every group, for
    /// anywhere the whole page is still wanted.
    var pane: MacSettingsPane? = nil

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(Preferences.self) private var prefs
    @Environment(PlayerModel.self) private var player

    @State private var isSigningOut = false
    @State private var confirmSignOut = false

    private typealias Copy = SettingsCopy

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            if shows(.account) {
                serverSection
                if client.session != nil {
                    AccountsSection()
                    QuickConnectApproveSection()
                }
            }

            if shows(.general) {
            Section("Appearance") {
                Picker(Copy.theme.name ?? "", selection: $prefs.theme) {
                    ForEach(ThemePref.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .note(Copy.theme)
            }

            }

            if shows(.playback) {
            Section("Playback") {
                Toggle(Copy.adaptiveQuality.name ?? "", isOn: $prefs.adaptiveQuality)
                    .note(Copy.adaptiveQuality)

                Picker(Copy.defaultQuality.name ?? "", selection: Self.bitrateBinding) {
                    ForEach(Quality.choices) { Text($0.label).tag($0.maxBitrate) }
                }
                .note(Copy.defaultQuality)

                Toggle("Resume where I left off", isOn: $prefs.resumePlayback)

                Toggle(Copy.autoplayNext.name ?? "", isOn: $prefs.autoplayNext)
                    .note(Copy.autoplayNext)

                Toggle(Copy.downmix.name ?? "", isOn: $prefs.stereoDownmix)
                    .note(Copy.downmix)

                Picker(Copy.audioDelay.name ?? "", selection: Self.audioDelayBinding) {
                    ForEach(Self.audioDelayChoices, id: \.self) { milliseconds in
                        Text(PlayerModel.audioDelayName(milliseconds)).tag(milliseconds)
                    }
                }
                .note(Copy.audioDelay)
            }

            }

            if shows(.subtitles) {
            Section("Languages") {
                Picker(Copy.audioLanguage.name ?? "", selection: $prefs.audioLanguage) {
                    Text("Whatever the file lists first").tag("")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .note(Copy.audioLanguage)

                Picker(Copy.subtitleLanguage.name ?? "", selection: $prefs.subtitleLanguage) {
                    Text("Only when the file turns them on").tag("")
                    Text("Never — no subtitles").tag("off")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .note(Copy.subtitleLanguage)

                Toggle(Copy.forcedOnly.name ?? "", isOn: $prefs.forcedSubtitlesOnly)
                    .note(Copy.forcedOnly, Copy.trackMemory)
            }

            Section("Subtitle appearance") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(prefs.subtitleSize))%")
                            .foregroundStyle(Theme.textDim)
                            .monospacedDigit()
                    }
                    Slider(value: $prefs.subtitleSize, in: 60...180, step: 5)
                        .onChange(of: prefs.subtitleSize) { _, _ in player.refreshSubtitleStyling() }
                }
                Picker(Copy.subtitleBackground.name ?? "", selection: $prefs.subtitleBackground) {
                    ForEach(SubtitleBackground.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: prefs.subtitleBackground) { _, _ in player.refreshSubtitleStyling() }
                .note(Copy.subtitleBackground)
            }

            }

            if shows(.liveTV) {
            Section("Live TV source") {
                Picker(Copy.liveTVSource.name ?? "", selection: $prefs.liveTVSource) {
                    ForEach(LiveTVSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .note(Copy.liveTVSource)

                if prefs.liveTVSource == .custom {
                    TextField("M3U playlist URL", text: $prefs.iptvPlaylistURL)
                        .textFieldStyle(.plain)
                        .note(Copy.iptvPlaylist)
                    TextField("XMLTV guide URL (optional)", text: $prefs.iptvGuideURL)
                        .textFieldStyle(.plain)
                        .note(Copy.iptvGuide)
                    TextField(Preferences.defaultIPTVUserAgent, text: $prefs.iptvUserAgent)
                        .textFieldStyle(.plain)
                        .note(Copy.iptvUserAgent)

                    Picker(Copy.iptvRefresh.name ?? "", selection: $prefs.iptvRefreshMinutes) {
                        ForEach(Self.iptvRefreshChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    }
                    .note(Copy.iptvRefresh)

                    // What the playlist and guide actually produced, last time
                    // they were read. A channel column full of empty tiles has
                    // two very different causes — the artwork wouldn't load, or
                    // the playlist never named any — and they are not tellable
                    // apart by looking at the guide. This tells them apart.
                    if let summary = LiveTVStore.shared.summary {
                        Text(Self.playlistSummary(summary))
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ArtworkProbeRow()
                }

                Button("Refresh channel list & guide now") {
                    prefs.liveTVRefreshToken += 1
                    app.toast("Refreshing Live TV…", tone: .info)
                }
            }

            }

            #if os(iOS)
            if app.hasAudio {
                Section("Music and audiobooks") {
                    Toggle(Copy.losslessOnCellular.name ?? "", isOn: $prefs.losslessOnCellular)
                        .note(Copy.losslessOnCellular)
                    Toggle(Copy.musicAutoplay.name ?? "", isOn: $prefs.musicAutoplay)
                        .note(Copy.musicAutoplay)
                    Toggle(Copy.normalizeVolume.name ?? "", isOn: $prefs.normalizeVolume)
                        .note(Copy.normalizeVolume)
                }
            }
            #endif

            if shows(.playback) {
            Section("Picture") {
                Picker(Copy.framing.name ?? "", selection: $prefs.fillScreen) {
                    Text("Fit — show the whole frame").tag(false)
                    Text("Fill — crop to the screen").tag(true)
                }
                .note(Copy.framing, Copy.pictureControls)
            }

            }

            if shows(.downloads) {
            Section("Downloads") {
                Picker("Default quality", selection: $prefs.downloadQuality) {
                    ForEach(DownloadQualities.all) { Text($0.label).tag($0.label) }
                }
                Stepper("Parallel downloads: \(prefs.downloadConcurrency)",
                        value: $prefs.downloadConcurrency,
                        in: 1...Preferences.maxDownloadConcurrency)
                    .note(Copy.concurrency)
                Toggle(Copy.wifiOnly.name ?? "", isOn: $prefs.downloadsWiFiOnly)
                    .note(Copy.wifiOnly)
                LabeledContent("Kept in") {
                    Button("Show in Finder") { DownloadManager.revealInFinder() }
                        .help(DownloadManager.root.path)
                }
            }

            }

            if shows(.general) {
            Section("Library copy") {
                Toggle(Copy.libraryCopy.name ?? "", isOn: $prefs.keepsLibraryCopy)
                    .onChange(of: prefs.keepsLibraryCopy) { _, on in LibraryIndex.shared.setEnabled(on) }
                    .note(Copy.libraryCopy)
                if prefs.keepsLibraryCopy {
                    let index = LibraryIndex.shared
                    LabeledContent("Status") {
                        Text(LibraryCopyText.status(index))
                            .foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Saved") {
                        Text(LibraryCopyText.contents(index))
                            .foregroundStyle(Theme.textDim)
                    }
                    Button(Copy.syncNow.name ?? "") {
                        Task { await LibraryIndex.shared.sync(force: true) }
                    }
                    .disabled(index.isSyncing)
                    .note(Copy.syncNow)
                    Button(Copy.deleteCopy.name ?? "", role: .destructive) {
                        LibraryIndex.shared.wipe()
                    }
                    .note(Copy.deleteCopy)
                }
            }

            Section("This iCloud account") {
                Toggle(Copy.cloudSync.name ?? "", isOn: cloudSyncBinding)
                    .disabled(!prefs.cloudIsAvailable)
                    .note(Copy.cloudSync)
                if !prefs.cloudIsAvailable {
                    Text(Copy.cloudUnavailable.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }

            Section("About") {
                LabeledContent("Aquarium", value: "\(Bundle.appVersion) (\(Bundle.appBuild))")
                LabeledContent("Playback engine", value: "AVFoundation")
                    .note(Copy.about)
            }
            }

        }
        .formStyle(.grouped)
        .screenTitle(pane?.title ?? "Settings")
        .paletteBar()
        .confirmationDialog("Sign out of \(client.session?.server ?? "this server")?",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    isSigningOut = true
                    await app.signOut()
                    isSigningOut = false
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func shows(_ group: MacSettingsPane) -> Bool {
        pane == nil || pane == group
    }

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            if let session = client.session {
                LabeledContent("Signed in as", value: session.userName)
                LabeledContent("Server") {
                    Text(session.server)
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                }
                LabeledContent("Connection") {
                    StatusPill(text: session.secure ? "HTTPS" : "HTTP", tone: session.secure ? .ok : .warn)
                }
                .note(Copy.connection(secure: session.secure))

                LabeledContent("Server identity") {
                    StatusPill(
                        text: session.serverId != nil ? "Pinned" : "Unpinned",
                        tone: session.serverId != nil ? .ok : .warn
                    )
                }
                .note(Copy.identity(pinned: session.serverId != nil))

                LabeledContent("Access token") {
                    StatusPill(text: "Keychain", tone: .ok)
                }
                .note(Copy.accessToken)

                LabeledContent("Status") {
                    StatusPill(
                        text: client.isOffline ? "Offline" : "Connected",
                        tone: client.isOffline ? .warn : .ok
                    )
                }

                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    if isSigningOut {
                        HStack { ProgressView().controlSize(.small); Text("Signing out…") }
                    } else {
                        Text("Sign out")
                    }
                }
                .disabled(isSigningOut)
            } else {
                Text("Not connected").foregroundStyle(Theme.textDim)
            }
        }
    }
}

#endif

#if os(iOS)
private typealias Copy = SettingsCopy

/// The page on a phone and an iPad: short, the way the television's is.
///
/// What people change — quality, resume, autoplay, the theme — is on the first
/// page with nothing but the control to look at; the sentence about a setting
/// is behind the (i) beside its name, read when asked for rather than laid out
/// under every row at once. The groups nobody touches twice — the server's
/// details, the audio and subtitle plumbing, a Live TV source, the library
/// copy, About — are a row each that opens a page of its own, where the
/// sentences sit under the controls the way the Mac's page still has them.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(Preferences.self) private var prefs
    /// Read again on the way back from the picker; nothing announces a change.
    @State private var iconTitle = AppIconChoice.current.title

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                NavigationLink {
                    ServerSettingsPage()
                } label: {
                    LabeledContent("Server", value: serverSummary)
                }
                NavigationLink {
                    TabBarSettingsView()
                } label: {
                    LabeledContent("Tab Bar", value: prefs.tabBarOrder.isEmpty ? "Default" : "Custom")
                }
            }

            Section("Appearance") {
                Picker(selection: $prefs.theme) {
                    ForEach(ThemePref.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel(Copy.theme)
                }
                if UIApplication.shared.supportsAlternateIcons {
                    NavigationLink {
                        AppIconSettingsView()
                    } label: {
                        LabeledContent("App Icon", value: iconTitle)
                    }
                }
            }

            Section("Playback") {
                Picker(selection: Self.bitrateBinding) {
                    ForEach(Quality.choices) { Text($0.label).tag($0.maxBitrate) }
                } label: {
                    SettingLabel(Copy.defaultQuality)
                }
                Toggle(isOn: $prefs.adaptiveQuality) { SettingLabel(Copy.adaptiveQuality) }
                Toggle(isOn: $prefs.resumePlayback) { SettingLabel(Copy.resume) }
                Toggle(isOn: $prefs.autoplayNext) { SettingLabel(Copy.autoplayNext) }
                Picker(selection: $prefs.fillScreen) {
                    Text("Fit — show the whole frame").tag(false)
                    Text("Fill — crop to the screen").tag(true)
                } label: {
                    SettingLabel(Copy.framing, Copy.pictureControls)
                }
                NavigationLink {
                    AudioSubtitleSettingsPage()
                } label: {
                    LabeledContent("Audio & Subtitles", value: audioSummary)
                }
            }

            Section("Live TV") {
                NavigationLink {
                    LiveTVSettingsPage()
                } label: {
                    LabeledContent("Source", value: prefs.liveTVSource == .custom ? "Custom playlist" : "Jellyfin")
                }
            }

            if app.hasAudio {
                Section("Music and audiobooks") {
                    Toggle(isOn: $prefs.losslessOnCellular) { SettingLabel(Copy.losslessOnCellular) }
                    Toggle(isOn: $prefs.musicAutoplay) { SettingLabel(Copy.musicAutoplay) }
                    Toggle(isOn: $prefs.normalizeVolume) { SettingLabel(Copy.normalizeVolume) }
                    NavigationLink {
                        StationSettingsPage()
                    } label: {
                        LabeledContent("Stations", value: prefs.musicLearns ? "Learning" : "Thumbs only")
                    }
                }
            }

            Section("Downloads") {
                Picker("Default quality", selection: $prefs.downloadQuality) {
                    ForEach(DownloadQualities.all) { Text($0.label).tag($0.label) }
                }
                Stepper(value: $prefs.downloadConcurrency, in: 1...Preferences.maxDownloadConcurrency) {
                    HStack {
                        SettingLabel(Copy.concurrency)
                        Spacer()
                        Text("\(prefs.downloadConcurrency)")
                            .foregroundStyle(Theme.textDim)
                            .monospacedDigit()
                    }
                }
                Toggle(isOn: $prefs.downloadsWiFiOnly) { SettingLabel(Copy.wifiOnly) }
                LabeledContent("Kept in") {
                    Text(DownloadManager.root.path)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                }
            }

            Section("General") {
                Toggle(isOn: cloudSyncBinding) { SettingLabel(Copy.cloudSync) }
                    .disabled(!prefs.cloudIsAvailable)
                if !prefs.cloudIsAvailable {
                    Text(Copy.cloudUnavailable.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                NavigationLink {
                    LibraryCopySettingsPage()
                } label: {
                    LabeledContent("Library copy", value: prefs.keepsLibraryCopy ? "On" : "Off")
                }
                NavigationLink {
                    AboutSettingsPage()
                } label: {
                    LabeledContent("About", value: Bundle.appVersion)
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Settings")
        .paletteBar()
        .onAppear { iconTitle = AppIconChoice.current.title }
    }

    private var serverSummary: String {
        guard let session = client.session else { return "Not connected" }
        return "\(session.userName) · \(client.isOffline ? "Offline" : "Connected")"
    }

    /// What is set beyond the defaults, or nothing: the languages, a downmix,
    /// a delay.
    private var audioSummary: String {
        var parts: [String] = []
        if let name = Languages.all.first(where: { $0.code == prefs.audioLanguage })?.name { parts.append(name) }
        if prefs.subtitleLanguage == "off" { parts.append("No subtitles") }
        if prefs.stereoDownmix { parts.append("Stereo") }
        if prefs.audioDelay != 0 {
            parts.append(PlayerModel.audioDelayShortName(Int((prefs.audioDelay * 1000).rounded())))
        }
        return parts.joined(separator: " · ")
    }
}

/// A setting's name and, beside it, the (i) that says what the setting does.
private struct SettingLabel: View {
    let notes: [SettingNote]
    @State private var isExplaining = false

    init(_ notes: SettingNote...) { self.notes = notes }

    var body: some View {
        HStack(spacing: 6) {
            Text(notes.first?.name ?? "")
            Button {
                isExplaining = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("What \(notes.first?.name ?? "this setting") does")
            .popover(isPresented: $isExplaining, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { note in
                        Text(note.text)
                            .font(.callout)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(width: 320, alignment: .leading)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

// MARK: - The pages

private struct ServerSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var isSigningOut = false
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            // First, above the facts about the connection: who is signed in
            // is what this page is opened to change.
            if client.session != nil { AccountsSection() }
            Section {
                if let session = client.session {
                    LabeledContent("Signed in as", value: session.userName)
                        .note(Copy.signedInAs)
                    LabeledContent("Server") {
                        Text(session.server)
                            .foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Connection") {
                        StatusPill(text: session.secure ? "HTTPS" : "HTTP", tone: session.secure ? .ok : .warn)
                    }
                    .note(Copy.connection(secure: session.secure))
                    LabeledContent("Server identity") {
                        StatusPill(
                            text: session.serverId != nil ? "Pinned" : "Unpinned",
                            tone: session.serverId != nil ? .ok : .warn
                        )
                    }
                    .note(Copy.identity(pinned: session.serverId != nil))
                    LabeledContent("Access token") {
                        StatusPill(text: "Keychain", tone: .ok)
                    }
                    .note(Copy.accessToken)
                    LabeledContent("Status") {
                        StatusPill(
                            text: client.isOffline ? "Offline" : "Connected",
                            tone: client.isOffline ? .warn : .ok
                        )
                    }
                    .note(Copy.status)
                } else {
                    Text("Not connected").foregroundStyle(Theme.textDim)
                }
            }

            if client.session != nil {
                QuickConnectApproveSection()
                Section {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        if isSigningOut {
                            HStack { ProgressView().controlSize(.small); Text("Signing out…") }
                        } else {
                            Text("Sign out")
                        }
                    }
                    .disabled(isSigningOut)
                    .note(Copy.signOut)
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Server")
        .paletteBar()
        .confirmationDialog("Sign out of \(client.session?.server ?? "this server")?",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    isSigningOut = true
                    await app.signOut()
                    isSigningOut = false
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct AudioSubtitleSettingsPage: View {
    @Environment(Preferences.self) private var prefs
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Audio") {
                Picker(Copy.audioLanguage.name ?? "", selection: $prefs.audioLanguage) {
                    Text("Whatever the file lists first").tag("")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .note(Copy.audioLanguage)

                Toggle(Copy.downmix.name ?? "", isOn: $prefs.stereoDownmix)
                    .note(Copy.downmix)

                Picker(Copy.audioDelay.name ?? "", selection: SettingsView.audioDelayBinding) {
                    ForEach(SettingsView.audioDelayChoices, id: \.self) { milliseconds in
                        Text(PlayerModel.audioDelayName(milliseconds)).tag(milliseconds)
                    }
                }
                .note(Copy.audioDelay)
            }

            Section("Subtitles") {
                Picker(Copy.subtitleLanguage.name ?? "", selection: $prefs.subtitleLanguage) {
                    Text("Only when the file turns them on").tag("")
                    Text("Never — no subtitles").tag("off")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .note(Copy.subtitleLanguage)

                Toggle(Copy.forcedOnly.name ?? "", isOn: $prefs.forcedSubtitlesOnly)
                    .note(Copy.forcedOnly, Copy.trackMemory)
            }

            Section("Subtitle appearance") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(prefs.subtitleSize))%")
                            .foregroundStyle(Theme.textDim)
                            .monospacedDigit()
                    }
                    Slider(value: $prefs.subtitleSize, in: 60...180, step: 5)
                        .onChange(of: prefs.subtitleSize) { _, _ in player.refreshSubtitleStyling() }
                }
                .note(Copy.subtitleSize)
                Picker(Copy.subtitleBackground.name ?? "", selection: $prefs.subtitleBackground) {
                    ForEach(SubtitleBackground.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: prefs.subtitleBackground) { _, _ in player.refreshSubtitleStyling() }
                .note(Copy.subtitleBackground)
            }
        }
        .formStyle(.grouped)
        .screenTitle("Audio & Subtitles")
        .paletteBar()
    }
}

private struct LiveTVSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Source") {
                Picker(Copy.liveTVSource.name ?? "", selection: $prefs.liveTVSource) {
                    ForEach(LiveTVSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .note(Copy.liveTVSource)
            }

            if prefs.liveTVSource == .custom {
                Section("Playlist") {
                    TextField("M3U playlist URL", text: $prefs.iptvPlaylistURL)
                        .textFieldStyle(.plain)
                        .note(Copy.iptvPlaylist)
                    TextField("XMLTV guide URL (optional)", text: $prefs.iptvGuideURL)
                        .textFieldStyle(.plain)
                        .note(Copy.iptvGuide)
                    TextField(Preferences.defaultIPTVUserAgent, text: $prefs.iptvUserAgent)
                        .textFieldStyle(.plain)
                        .note(Copy.iptvUserAgent)

                    Picker(Copy.iptvRefresh.name ?? "", selection: $prefs.iptvRefreshMinutes) {
                        ForEach(SettingsView.iptvRefreshChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    }
                    .note(Copy.iptvRefresh)

                    // What the playlist and guide actually produced, last time
                    // they were read — see the Mac's page for why.
                    if let summary = LiveTVStore.shared.summary {
                        Text(SettingsView.playlistSummary(summary))
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ArtworkProbeRow()
                }
            }

            Section {
                Button("Refresh channel list & guide now") {
                    prefs.liveTVRefreshToken += 1
                    app.toast("Refreshing Live TV…", tone: .info)
                }
                .note(Copy.refreshNow)
            }
        }
        .formStyle(.grouped)
        .screenTitle("Live TV")
        .paletteBar()
    }
}

private struct LibraryCopySettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        let index = LibraryIndex.shared
        Form {
            Section {
                Toggle(Copy.libraryCopy.name ?? "", isOn: $prefs.keepsLibraryCopy)
                    .onChange(of: prefs.keepsLibraryCopy) { _, on in LibraryIndex.shared.setEnabled(on) }
                    .note(Copy.libraryCopy)
            }
            if prefs.keepsLibraryCopy {
                Section {
                    LabeledContent("Status") {
                        Text(LibraryCopyText.status(index))
                            .foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.trailing)
                    }
                    .note(Copy.libraryCopyStatus)
                    LabeledContent("Saved") {
                        Text(LibraryCopyText.contents(index))
                            .foregroundStyle(Theme.textDim)
                    }
                    .note(Copy.libraryCopyContents)
                }
                Section {
                    Button(Copy.syncNow.name ?? "") {
                        Task { await LibraryIndex.shared.sync(force: true) }
                    }
                    .disabled(index.isSyncing)
                    .note(Copy.syncNow)
                    Button(Copy.deleteCopy.name ?? "", role: .destructive) {
                        LibraryIndex.shared.wipe()
                    }
                    .note(Copy.deleteCopy)
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Library copy")
        .paletteBar()
    }
}

private struct AboutSettingsPage: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Aquarium", value: "\(Bundle.appVersion) (\(Bundle.appBuild))")
                LabeledContent("Playback engine", value: "AVFoundation")
                    .note(Copy.playbackEngine)
            }
            Section {
                Text(Copy.about.text)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .screenTitle("About")
        .paletteBar()
    }
}
#endif

#if !os(tvOS)
/// Everyone signed in on this device: tap to become them, swipe (or press
/// and hold, or right-click) to sign one out of it.
struct AccountsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        Section {
            ForEach(client.accounts, id: \.accountKey) { account in
                let isCurrent = account.accountKey == client.session?.accountKey
                Button {
                    Task { await app.switchAccount(to: account) }
                } label: {
                    AccountRow(account: account, isCurrent: isCurrent)
                }
                .buttonStyle(.plain)
                .disabled(app.switchingTo != nil)
                .contextMenu {
                    if !isCurrent {
                        Button("Sign Out of This Device", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task { await app.remove(account) }
                        }
                    }
                }
                #if os(iOS)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isCurrent {
                        Button("Sign Out", role: .destructive) {
                            Task { await app.remove(account) }
                        }
                    }
                }
                #endif
            }
            Button {
                app.isAddingAccount = true
            } label: {
                Label("Add Account…", systemImage: "person.badge.plus")
            }
            .note(SettingsCopy.addAccount)
        } header: {
            Text("Accounts")
        } footer: {
            if client.accounts.count > 1 {
                Text("Tap an account to switch to it.")
            }
        }
    }
}

private extension View {
    /// Attaches the sentences that say what this setting does, as rows of their
    /// own directly under it.
    func note(_ notes: SettingNote...) -> some View {
        Group {
            #if os(macOS)
            // One sentence under the control, the rest on hover. The full
            // paragraphs under every row made the window a wall of grey text
            // and pushed the controls themselves apart.
            self.help(notes.map(\.text).joined(separator: "\n\n"))
            ForEach(notes) { note in
                Text(note.summary)
                    .help(note.text)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #else
            // In the cell with the control it describes, not a row of its
            // own. As separate rows, a control and its sentence sat either
            // side of a divider with a full row's padding between them, and
            // read as two unrelated settings rather than one and its
            // explanation.
            VStack(alignment: .leading, spacing: 6) {
                self
                ForEach(notes) { note in
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #endif
        }
    }
}

/// "Why is the channel column empty?", answered on the device that is asking.
///
/// The causes are not distinguishable from the guide — a playlist that names no
/// artwork, a host that refuses this device, an address that resolves nowhere
/// and a picture in a format nothing here decodes all look like the same grey
/// tile. This fetches a handful of them and prints what actually came back, so
/// the next step is a fact rather than a guess.
private struct ArtworkProbeRow: View {
    @State private var results: [ArtworkProbe.Result] = []
    @State private var isRunning = false
    @State private var hasRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await run() }
            } label: {
                HStack(spacing: 8) {
                    Text(hasRun ? "Check channel artwork again" : "Check channel artwork")
                    if isRunning { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isRunning)

            if hasRun, results.isEmpty {
                Text(SettingsView.noChannelsYet)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }

            ForEach(results) { ArtworkProbeResultView(result: $0) }
        }
    }

    private func run() async {
        isRunning = true
        defer {
            isRunning = false
            hasRun = true
        }
        results = await ArtworkProbe.run(channels: LiveTVStore.shared.channels)
    }
}
#endif

// MARK: - Shared by both pages

/// One channel's line in the artwork check's report.
struct ArtworkProbeResultView: View {
    let result: ArtworkProbe.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(result.ok ? Theme.ok : Theme.warn)
                Text(result.channel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
            }
            if let address = result.address {
                Text(address)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(result.outcome)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsView {
    /// The delay in the menu's units. Stored in seconds like the player reads
    /// it; chosen in milliseconds like the player names it.
    static var audioDelayBinding: Binding<Int> {
        Binding(
            get: { Int((Preferences.shared.audioDelay * 1000).rounded()) },
            set: { Preferences.shared.audioDelay = Double($0) / 1000 }
        )
    }

    /// The presets, plus whatever is set if it isn't one of them — the value
    /// was nudged ten milliseconds at a time from inside the player, and a
    /// picker showing none of its rows ticked reads as a setting that broke.
    static var audioDelayChoices: [Int] {
        var values = PlayerModel.audioDelays
        let current = audioDelayBinding.wrappedValue
        if !values.contains(current) { values.append(current); values.sort() }
        return values
    }

    static var bitrateBinding: Binding<Int?> {
        Binding(
            get: { Preferences.shared.defaultBitrate },
            set: { Preferences.shared.defaultBitrate = $0 }
        )
    }

    static func playlistSummary(_ summary: LiveTVStore.Summary) -> String {
        var lines = ["\(summary.channels) channel\(summary.channels == 1 ? "" : "s")"]
        if summary.withLogos == 0 {
            lines.append("no channel artwork — the playlist carries no tvg-logo and the guide no <icon>, so the column shows each channel's lettering instead")
        } else if summary.withLogos < summary.channels {
            lines.append("\(summary.withLogos) with artwork")
        } else {
            lines.append("all with artwork")
        }
        lines.append("\(summary.programmes) programme\(summary.programmes == 1 ? "" : "s") in the guide")
        return lines.joined(separator: " · ")
    }

    static let noChannelsYet = "No channels loaded yet — open Live TV first, or use Refresh above."

    static let iptvRefreshChoices: [(minutes: Int, label: String)] = [
        (0, "Off"),
        (15, "15 minutes"),
        (30, "30 minutes"),
        (60, "1 hour"),
        (180, "3 hours"),
        (360, "6 hours"),
        (720, "12 hours"),
        (1440, "24 hours"),
    ]
}

/// What the library copy is doing and holding, in the words both Settings
/// pages show.
@MainActor
enum LibraryCopyText {
    static func status(_ index: LibraryIndex) -> String {
        if let p = index.syncProgress {
            return p.total > 0
                ? "Reading \(p.library): \(p.done.formatted()) of \(p.total.formatted())"
                : "Reading \(p.library)…"
        }
        if let a = index.artworkProgress {
            return "Saving artwork: \(a.done.formatted()) of \(a.total.formatted())"
        }
        if let error = index.lastError { return "Last sync failed: \(error)" }
        if let synced = index.lastSynced {
            return "Synced " + relative.localizedString(for: synced, relativeTo: Date())
        }
        return "Not synced yet"
    }

    /// Built once; the line above is redrawn on every step of a sync.
    private static let relative = RelativeDateTimeFormatter()

    static func contents(_ index: LibraryIndex) -> String {
        let size = ByteCountFormatter.string(fromByteCount: index.artworkBytes, countStyle: .file)
        return "\(index.itemCount.formatted()) items · \(size) of artwork"
    }
}

extension Bundle {
    static var appVersion: String {
        main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var appBuild: String {
        main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

/// Every sentence on the page, in one place, because both versions of the page
/// read them.
enum SettingsCopy {
    static func connection(secure: Bool) -> SettingNote {
        SettingNote(name: "Connection", text: secure
            ? "Encrypted. Your password and access token are never sent in the clear."
            : "Unencrypted. Anything on the network path can read your access token and what you watch. Put Jellyfin behind HTTPS if it's reachable from outside your home network.")
    }
    static func identity(pinned: Bool) -> SettingNote {
        SettingNote(name: "Server identity", text: pinned
            ? "Pinned. If this address ever answers as a different Jellyfin server, Aquarium stops instead of signing in to it."
            : "Not pinned yet — it will be recorded the next time this server answers.")
    }
    static let losslessOnCellular = SettingNote(
        name: "Lossless on cellular",
        text: "Off, a lossless file (FLAC, ALAC) is sent as 256 kbps AAC when you're on cellular data. Wi-Fi always gets the original."
    )
    static let musicAutoplay = SettingNote(
        name: "Keep playing at the end",
        text: "When the queue runs out, carry on with songs like the last one, built by the server."
    )
    static let musicLearns = SettingNote(
        name: "Learn from listening",
        text: "Stations play more of what you hear to the end and less of what you skip, and change course while they play. Off, only your thumbs steer them."
    )
    static let musicRomanize = SettingNote(
        name: "Romanize artist names",
        text: "Name stations after an artist in Latin letters when the server has a romanized name or the script has a reliable transliteration. Japanese names written in kanji are left as they are."
    )
    static let normalizeVolume = SettingNote(
        name: "Sound check",
        text: "Level tracks against each other using the loudness the server measured, so a quiet album isn't followed by a loud one."
    )
    static let accessToken = SettingNote(
        name: "Access token",
        text: "Stored in the system keychain. Never written to a settings file, and never sent in a URL."
    )
    static let signedInAs = SettingNote(
        name: "Signed in as",
        text: "The Jellyfin account this device is using. What you watch, resume and favourite here is recorded against it."
    )
    static let server = SettingNote(
        name: "Server",
        text: "The address Aquarium talks to."
    )
    static let status = SettingNote(
        name: "Status",
        text: "Whether the server answered the last time Aquarium asked. Offline means the address didn't reply — the server is down, or this device can't reach it from where it is."
    )
    static let accounts = SettingNote(
        name: "Accounts",
        text: "Everyone signed in on this device. Switching is instant and needs no password: each account keeps its own token in the keychain, and what you watch is recorded against whichever one is in use. Downloads stay on the device and are shared between them."
    )
    static let addAccount = SettingNote(
        name: "Add account",
        text: "Sign in to another user on this server, or to a different server, without signing this one out."
    )
    static let signOut = SettingNote(
        name: "Sign out",
        text: "Forgets this account on this device. If your settings are shared through iCloud, it signs you out on your other devices too."
    )
    static let theme = SettingNote(
        name: "Theme",
        text: "Match system follows the device's light/dark setting. The player is always dark, wherever this is set."
    )
    static let adaptiveQuality = SettingNote(
        name: "Adapt quality automatically",
        text: "Drops to a smaller stream when playback keeps stalling or the device can't decode fast enough, and climbs back after the connection has been steady for a while. It never goes above the quality you picked, and never touches downloaded files or Live TV."
    )
    static let defaultQuality = SettingNote(
        name: "Default quality",
        text: "What a stream opens at before you change it. Direct Play sends the original file when this device can open it, and asks the server to remux or transcode when it can't."
    )
    static let resume = SettingNote(
        name: "Resume where I left off",
        text: "Opens something you have already started at the point you stopped, instead of from the beginning."
    )
    static let autoplayNext = SettingNote(
        name: "Play the next episode automatically",
        text: "The Up Next card appears over the closing stretch of an episode either way — turning this off just means it won't start on its own."
    )
    static let downmix = SettingNote(
        name: "Downmix surround to stereo",
        text: "Asks the server for two channels instead of six. Worth turning on if you listen on headphones or a laptop and find dialogue in 5.1 material too quiet — the centre channel it lives on gets mixed in properly rather than dropped."
    )
    static let soundbar = SettingNote(
        name: "Decode audio on this Apple TV",
        text: "For a soundbar or receiver whose sound runs behind the picture. Dolby tracks are normally handed to it undecoded and it takes its own time over them; with this on, the server sends AAC instead, the Apple TV decodes it, and plain multichannel PCM goes down the HDMI cable. Surround is kept, Atmos is not. Takes effect on the next thing you play."
    )
    static let audioDelay = SettingNote(
        name: "Audio delay",
        text: "How far the sound is moved against the picture — the lag a television or soundbar adds, which is the same for everything watched through it. " + audioDelayPlayerHint + "Whatever is settled on is saved here and applied to everything you play. The sound can be moved earlier on any stream; moving it later needs a file the server can send untouched."
    )
    static let frameRateMatch = SettingNote(
        name: "Match Frame Rate offset",
        text: "Extra sound delay for when Match Content → Match Frame Rate switches your television out of 60 Hz for a video. Many televisions show the picture later at 24 Hz than at 60, and tvOS can tell the app that matching is on but not how much later. Pick a value here; while a film the display switched for is playing, the audio delay controls in the player say how much is being added. Added on top of the audio delay, and only to videos the display switches for."
    )
    static let audioLanguage = SettingNote(
        name: "Audio",
        text: "Preferred spoken language. The first track matching it is chosen when a file has more than one."
    )
    static let subtitleLanguage = SettingNote(
        name: "Subtitles",
        text: "“Never” is the setting to pick if you don't use subtitles: it stops them being switched on by a file that ships with them enabled, which no other option here can do."
    )
    static let forcedOnly = SettingNote(
        name: "Forced subtitles only",
        text: "When the audio is already in your preferred language, show only the forced track — the one that translates signs and the occasional line of foreign dialogue — instead of subtitling the whole thing."
    )
    static let trackMemory = SettingNote(
        text: "Changing a track during an episode is remembered for that series on its own, and the next episode opens the same way."
    )
    static let subtitleSize = SettingNote(
        name: "Size",
        text: "How large subtitles are drawn, against the size the track asks for."
    )
    static let subtitleBackground = SettingNote(
        name: "Background",
        text: "An outline disappears into a bright scene now and then. A solid strip behind the text always stays readable, at the cost of covering a band of the picture. Applies to the subtitle tracks the server sends with a stream; anything burnt into the picture is fixed."
    )
    static let liveTVSource = SettingNote(
        name: "Source",
        text: "Jellyfin is what the tuner and guide data configured on the server provide. Custom playlist bypasses Jellyfin's own Live TV entirely — channels come from an M3U playlist below and tune by playing their stream URL directly, whether or not this server has Live TV set up at all."
    )
    static let iptvPlaylist = SettingNote(
        name: "M3U playlist URL",
        text: "Standard extended M3U — tvg-id, tvg-name, tvg-logo and tvg-chno on each #EXTINF line, if the playlist has them, decide the channel's number and logo."
    )
    static let iptvGuide = SettingNote(
        name: "XMLTV guide URL",
        text: "The schedule for the playlist above, matched to each channel by tvg-id. A channel plays fine without one — the guide just shows no programme information for it."
    )
    static let iptvUserAgent = SettingNote(
        name: "User agent",
        text: "The client string sent when fetching a channel from the playlist. Some stream servers serve different content depending on it. Left empty, a widely supported default is sent. Change it only if the playlist's documentation asks for a specific value."
    )
    static let iptvRefresh = SettingNote(
        name: "Guide refresh",
        text: "How often the playlist and guide are re-downloaded while Live TV is open, for an XMLTV feed that regenerates on its own schedule upstream. Doesn't apply to the Jellyfin source, which always asks the server fresh."
    )
    static let artworkProbe = SettingNote(
        name: "Check channel artwork",
        text: "Fetches a few channel logos and reports what came back — for when the channel column shows lettering or empty tiles instead of logos, and it isn't clear whether the playlist never named any or they wouldn't load."
    )
    static let refreshNow = SettingNote(
        name: "Refresh channel list & guide now",
        text: "Downloads the channels and the guide again straight away, instead of waiting for the next scheduled refresh."
    )
    static let framing = SettingNote(
        name: "Framing",
        text: "Fill is how you put a 2.35:1 film on a 16:9 screen without watching it between black bars. It does cut the edges of the frame off. Also reachable from the player itself, so it can be judged against what's on screen."
    )
    static let pictureControls = SettingNote(
        text: "There are no brightness, contrast or colour controls: Apple's video player has no way to adjust the picture of a stream."
    )
    static let concurrency = SettingNote(
        name: "Parallel downloads",
        text: "How many transfers run at once. One at a time is kindest to a server that has to transcode each of them."
    )
    static let wifiOnly = SettingNote(
        name: "Only download on Wi-Fi",
        text: "Takes effect for transfers started after it changes."
    )
    static let cloudSync = SettingNote(
        name: "Share settings across my devices",
        text: "Your server, your sign-in and everything on this screen follow you to your other Apple TVs, iPhones, iPads and Macs through iCloud. Signing out anywhere signs out everywhere. Volume, the audio delay and this device's identity to the server stay where they are — those describe the room, not the account."
    )
    static let libraryCopy: SettingNote = {
        var text = "Saves the details of every film, show, season and episode on this device, with their posters, logos and episode stills. After the first sync, opening the app only fetches what changed: library pages open straight away, and can still be browsed when the server can't be reached. Backdrops are saved as you come across them. Turning this off deletes the copy."
        #if os(tvOS)
        text += " Apple TV may clear the copy when it runs short of storage; it is rebuilt at the next sync."
        #endif
        return SettingNote(name: "Keep a copy of my library", text: text)
    }()
    static let libraryCopyStatus = SettingNote(
        name: "Status",
        text: "What the copy is doing. The first sync reads the whole library and then saves its artwork, which can take a while on a large one; after that a sync only reads what changed."
    )
    static let libraryCopyContents = SettingNote(
        name: "Saved",
        text: "How many films, shows, seasons and episodes the copy holds, and the space its artwork takes on this device."
    )
    static let syncNow = SettingNote(
        name: "Sync now",
        text: "Asks the server what has changed since the last sync. This also happens by itself when the app opens, when it comes back to the front, and after you finish watching something."
    )
    static let deleteCopy = SettingNote(
        name: "Delete the copy",
        text: "Removes the saved details and artwork from this device. With the setting still on, the next sync downloads everything again."
    )
    /// The player's own audio-sync controls exist only on Apple TV; elsewhere
    /// the footer pointed at a panel that isn't there.
    private static var audioDelayPlayerHint: String {
        #if os(tvOS)
        "Easier to set from inside the player: Audio sync in the player's settings puts the controls over whatever is playing, so the sound can be nudged while watching a line of dialogue. "
        #else
        ""
        #endif
    }

    static let cloudUnavailable = SettingNote(
        text: "Not signed in to iCloud on this device, or this build isn't set up for it."
    )
    static let about = SettingNote(
        text: "Built with AI: this app was written with AI assistance (Anthropic's Claude), directed and tested by one developer, and is shared as-is. A lightweight Jellyfin client — the Apple build of the same app that ships for Linux; the two share their behaviour but not their code."
    )
    static let playbackEngine = SettingNote(
        name: "Playback engine",
        text: "Apple's AVFoundation, the same media framework the system's own players are built on — so what plays directly, and what the server is asked to convert, follows what this device supports."
    )
}

#if os(iOS)
/// What stations learn, and a way to make them forget it.
struct StationSettingsPage: View {
    @Environment(Preferences.self) private var prefs
    @State private var confirmForget = false

    var body: some View {
        @Bindable var prefs = prefs
        let taste = MusicTaste.shared
        Form {
            Section {
                Toggle(SettingsCopy.musicLearns.name ?? "", isOn: $prefs.musicLearns)
                    .note(SettingsCopy.musicLearns)
                Toggle(SettingsCopy.musicRomanize.name ?? "", isOn: $prefs.musicRomanizeNames)
                    .note(SettingsCopy.musicRomanize)
            }
            Section {
                LabeledContent("Thumbs up", value: "\(taste.thumbsUpCount)")
                LabeledContent("Thumbs down", value: "\(taste.thumbsDownCount)")
            } footer: {
                Text("Thumbs are saved to your server as each song's rating, so other devices and the web client see them too. A song with a thumbs down never plays in a station; tap the thumb again on Now Playing to take it back.")
            }
            Section {
                Button("Forget What Stations Have Learned", role: .destructive) { confirmForget = true }
            } footer: {
                Text("Clears what finished and skipped songs have taught stations on this device. Thumbs are kept.")
            }
        }
        .navigationTitle("Stations")
        .confirmationDialog("Forget listening history for stations?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { MusicTaste.shared.forgetListening() }
        }
    }
}
#endif

extension SettingsView {
    /// Off whenever iCloud can't be used, whatever was chosen before. A
    /// disabled switch still drawn *on* read as a feature that was working.
    fileprivate var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { Preferences.shared.syncsAcrossDevices && Preferences.shared.cloudIsAvailable },
            set: { Preferences.shared.syncsAcrossDevices = $0 }
        )
    }
}
