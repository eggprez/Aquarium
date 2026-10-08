//  Settings.
//
//  Every setting is a name, a control, and a sentence saying what the setting
//  actually does — the sentence being the part that stops a settings page from
//  being a list of words you have to guess at. Carried over from the Linux
//  build, minus the options that only meant something to an mpv process.
//
//  This file is the Settings window on a Mac — a tab per group, each row a
//  control with its sentence as the second line of its label and the rest of
//  the paragraph as a tooltip — and the page on a phone and an iPad, which is
//  shaped like the television's instead: short, with the sentences behind an
//  (i) and the rarely-touched groups on pages of their own. A television draws
//  the same settings and the same sentences differently — see
//  `TVSettingsView.swift`. What all of them share is at the bottom of this file.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
/// The tabs of the Settings window, in the order they appear: the shared map
/// (`SettingsPage`), with Appearance and iCloud folded into General, and
/// Downloads and Library copy sharing Storage — which is what the two are both
/// about: what this Mac keeps on disk.
enum MacSettingsPane: String, CaseIterable, Identifiable {
    case general, account, video, audio, subtitles, music, liveTV, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .account: SettingsPage.account.title
        case .video: SettingsPage.video.title
        case .audio: SettingsPage.audio.title
        case .subtitles: SettingsPage.subtitles.title
        case .music: SettingsPage.music.title
        case .liveTV: SettingsPage.liveTV.title
        case .storage: "Storage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: SettingsPage.account.symbol
        case .video: SettingsPage.video.symbol
        case .audio: SettingsPage.audio.symbol
        case .subtitles: SettingsPage.subtitles.symbol
        case .music: SettingsPage.music.symbol
        case .liveTV: SettingsPage.liveTV.symbol
        case .storage: "internaldrive"
        }
    }
}

/// The Settings window (⌘,): one tab per group, the way Mac apps lay out their
/// preferences, rather than one long page in the sidebar.
struct MacSettingsWindow: View {
    @AppStorage("settingsPane") private var pane: MacSettingsPane = .general
    @Environment(AppModel.self) private var app

    /// Music only where the server has any: a tab of settings for a library
    /// that isn't there would be a puzzle.
    private var panes: [MacSettingsPane] {
        MacSettingsPane.allCases.filter { $0 != .music || app.hasAudio }
    }

    var body: some View {
        TabView(selection: $pane) {
            ForEach(panes) { pane in
                SettingsView(pane: pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }
        // The width is fixed; each pane takes the height its rows need, and
        // the window follows the tab — General is a handful of rows, Account
        // a table and a form, and neither should be sized for the other.
        .frame(width: 620)
        .onAppear { if !panes.contains(pane) { pane = .general } }
    }
}

/// A control's label: its name, on one line. The sentence about the control
/// is the footer of the section it sits in (`MacSettingFooter`) and the row's
/// tooltip (`note`), so a row is a row and not a paragraph.
struct MacSettingLabel: View {
    var title: String

    init(_ note: SettingNote, _ more: SettingNote..., title: String? = nil) {
        self.title = title ?? note.name ?? ""
    }

    init(title: String, summary: String = "") {
        self.title = title
    }

    var body: some View {
        Text(title)
    }
}

/// Under a section: the first sentence about each control in it, as one
/// short paragraph. The whole of each note is on hover over its row.
struct MacSettingFooter: View {
    let notes: [SettingNote]

    init(_ notes: SettingNote...) { self.notes = notes }
    init(notes: [SettingNote]) { self.notes = notes }

    var body: some View {
        Text(notes.map(\.summary).joined(separator: " "))
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
    @State private var confirmDeleteCopy = false

    private typealias Copy = SettingsCopy

    var body: some View {
        Form {
            if shows(.general) {
                appearanceSection
                cloudSection
            }

            if shows(.account) {
                serverSection
                if client.session != nil {
                    AccountsSection()
                    QuickConnectApproveSection()
                }
            }

            if shows(.video) {
                qualitySection
                pictureSection
                playingSection
            }

            if shows(.audio) {
                audioLanguageSection
                audioOutputSection
            }

            if shows(.subtitles) {
                subtitleLanguageSection
                subtitleAppearanceSection
            }

            if shows(.music), app.hasAudio {
                musicSection
                stationsSection
                StationMixSection()
            }

            if shows(.liveTV) {
                liveTVSections
            }

            if shows(.storage) {
                downloadsSection
                libraryCopySection
            }
        }
        .formStyle(.grouped)
        // As a tab, exactly as tall as its rows, so the window can fit the
        // pane; as the whole page, free to scroll.
        .fixedSize(horizontal: false, vertical: pane != nil)
        .screenTitle(pane?.title ?? "Settings")
        .paletteBar()
        .confirmationDialog("Sign out of \(client.session?.server ?? "this server")?",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task {
                    isSigningOut = true
                    await app.signOut()
                    isSigningOut = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Copy.signOut.text)
        }
        .confirmationDialog("Delete the saved copy of your library?",
                            isPresented: $confirmDeleteCopy, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { LibraryIndex.shared.wipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Copy.deleteCopy.text)
        }
    }

    private func shows(_ group: MacSettingsPane) -> Bool {
        pane == nil || pane == group
    }

    // MARK: - General

    private var appearanceSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker(selection: $prefs.theme) {
                Text("System").tag(ThemePref.auto)
                Text("Light").tag(ThemePref.light)
                Text("Dark").tag(ThemePref.dark)
            } label: {
                MacSettingLabel(Copy.theme)
            }
            .pickerStyle(.segmented)
            .note(Copy.theme)
        } header: {
            Text("Appearance")
        } footer: {
            MacSettingFooter(Copy.theme)
        }
    }

    private var cloudSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Toggle(isOn: Self.cloudSyncBinding) { MacSettingLabel(Copy.cloudSync) }
                .disabled(!prefs.cloudIsAvailable)
                .note(Copy.cloudSync)
        } header: {
            Text("iCloud")
        } footer: {
            if prefs.cloudIsAvailable {
                MacSettingFooter(Copy.cloudSync)
            } else {
                Text(Copy.cloudUnavailable.text)
            }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            if let session = client.session {
                LabeledContent {
                    Text(session.userName)
                } label: {
                    MacSettingLabel(Copy.signedInAs)
                }
                .note(Copy.signedInAs)
                LabeledContent("Server") {
                    Text(session.server)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent {
                    Label(session.secure ? "Encrypted" : "Unencrypted",
                          systemImage: session.secure ? "lock.fill" : "lock.open")
                        .foregroundStyle(session.secure ? Color.green : Color.orange)
                } label: {
                    MacSettingLabel(Copy.connection(secure: session.secure))
                }
                .note(Copy.connection(secure: session.secure))

                LabeledContent {
                    Label(session.serverId != nil ? "Pinned" : "Not Pinned",
                          systemImage: session.serverId != nil ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(session.serverId != nil ? Color.green : Color.orange)
                } label: {
                    MacSettingLabel(Copy.identity(pinned: session.serverId != nil))
                }
                .note(Copy.identity(pinned: session.serverId != nil))

                LabeledContent {
                    Label("Keychain", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                } label: {
                    MacSettingLabel(Copy.accessToken)
                }
                .note(Copy.accessToken)

                LabeledContent {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(client.isOffline ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(client.isOffline ? "Offline" : "Connected")
                    }
                } label: {
                    MacSettingLabel(Copy.status)
                }
                .note(Copy.status)

                LabeledContent {
                    HStack(spacing: 8) {
                        if isSigningOut { ProgressView().controlSize(.small) }
                        Button("Sign Out…") { confirmSignOut = true }
                            .disabled(isSigningOut)
                    }
                } label: {
                    MacSettingLabel(Copy.signOut, title: "Sign Out")
                }
                .note(Copy.signOut)
            } else {
                Text("Not connected").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Video

    private var qualitySection: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker(selection: Self.bitrateBinding) {
                ForEach(Quality.choices) { Text($0.label).tag($0.maxBitrate) }
            } label: {
                MacSettingLabel(Copy.defaultQuality)
            }
            .note(Copy.defaultQuality)

            Toggle(isOn: $prefs.adaptiveQuality) { MacSettingLabel(Copy.adaptiveQuality) }
                .note(Copy.adaptiveQuality)
        } header: {
            Text("Quality")
        } footer: {
            MacSettingFooter(Copy.defaultQuality, Copy.adaptiveQuality)
        }
    }

    private var pictureSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker(selection: $prefs.fillScreen) {
                Text("Fit — show the whole frame").tag(false)
                Text("Fill — crop to the screen").tag(true)
            } label: {
                MacSettingLabel(Copy.framing, Copy.pictureControls)
            }
            .pickerStyle(.radioGroup)
            .note(Copy.framing, Copy.pictureControls)
        } header: {
            Text("Picture")
        } footer: {
            MacSettingFooter(Copy.framing, Copy.pictureControls)
        }
    }

    private var playingSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Toggle(isOn: $prefs.resumePlayback) { MacSettingLabel(Copy.resume) }
                .note(Copy.resume)

            Toggle(isOn: $prefs.autoplayNext) { MacSettingLabel(Copy.autoplayNext) }
                .note(Copy.autoplayNext)
        } header: {
            Text("Playing")
        } footer: {
            MacSettingFooter(Copy.resume, Copy.autoplayNext)
        }
    }

    // MARK: - Audio

    private var audioLanguageSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker(selection: $prefs.audioLanguage) {
                Text("Whatever the file lists first").tag("")
                ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
            } label: {
                MacSettingLabel(Copy.audioLanguage, title: "Language")
            }
            .note(Copy.audioLanguage)
        } header: {
            Text("Language")
        } footer: {
            MacSettingFooter(Copy.audioLanguage)
        }
    }

    private var audioOutputSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Toggle(isOn: $prefs.stereoDownmix) { MacSettingLabel(Copy.downmix) }
                .note(Copy.downmix)

            Picker(selection: Self.audioDelayBinding) {
                ForEach(Self.audioDelayChoices, id: \.self) { milliseconds in
                    Text(PlayerModel.audioDelayName(milliseconds)).tag(milliseconds)
                }
            } label: {
                MacSettingLabel(Copy.audioDelay)
            }
            .note(Copy.audioDelay)
        } header: {
            Text("Output")
        } footer: {
            MacSettingFooter(Copy.downmix, Copy.audioDelay)
        }
    }

    // MARK: - Subtitles

    private var subtitleLanguageSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker(selection: $prefs.subtitleLanguage) {
                Text("Only when the file turns them on").tag("")
                Text("Never — no subtitles").tag("off")
                ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
            } label: {
                MacSettingLabel(Copy.subtitleLanguage, title: "Language")
            }
            .note(Copy.subtitleLanguage)

            Toggle(isOn: $prefs.forcedSubtitlesOnly) { MacSettingLabel(Copy.forcedOnly, Copy.trackMemory) }
                .note(Copy.forcedOnly, Copy.trackMemory)
        } header: {
            Text("Language")
        } footer: {
            MacSettingFooter(Copy.subtitleLanguage, Copy.forcedOnly, Copy.trackMemory)
        }
    }

    private var subtitleAppearanceSection: some View {
        @Bindable var prefs = prefs
        return Section {
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: $prefs.subtitleSize, in: 60...180, step: 5) {
                        Text("Size")
                    } minimumValueLabel: {
                        Text("A").font(.caption2)
                    } maximumValueLabel: {
                        Text("A").font(.title3)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Text("\(Int(prefs.subtitleSize))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } label: {
                MacSettingLabel(Copy.subtitleSize)
            }
            .onChange(of: prefs.subtitleSize) { _, _ in player.refreshSubtitleStyling() }
            .note(Copy.subtitleSize)

            Picker(selection: $prefs.subtitleBackground) {
                ForEach(SubtitleBackground.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                MacSettingLabel(Copy.subtitleBackground)
            }
            .onChange(of: prefs.subtitleBackground) { _, _ in player.refreshSubtitleStyling() }
            .note(Copy.subtitleBackground)
        } header: {
            Text("Appearance")
        } footer: {
            MacSettingFooter(Copy.subtitleSize, Copy.subtitleBackground)
        }
    }

    // MARK: - Music

    /// The phone's music settings less the one about cellular data, which a
    /// Mac has no say in.
    private var musicSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Toggle(isOn: $prefs.musicAutoplay) { MacSettingLabel(Copy.musicAutoplay) }
                .note(Copy.musicAutoplay)
            Toggle(isOn: $prefs.normalizeVolume) { MacSettingLabel(Copy.normalizeVolume) }
                .note(Copy.normalizeVolume)
        } header: {
            Text("Playing")
        } footer: {
            MacSettingFooter(Copy.musicAutoplay, Copy.normalizeVolume)
        }
    }

    /// Stations learn only while they play — thumbs included — so there is
    /// nothing kept here to count or forget.
    private var stationsSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Toggle(isOn: $prefs.musicRomanizeNames) { MacSettingLabel(Copy.musicRomanize) }
                .note(Copy.musicRomanize)
        } header: {
            Text("Stations")
        } footer: {
            MacSettingFooter(Copy.musicRomanize)
        }
    }

    // MARK: - Live TV

    @ViewBuilder
    private var liveTVSections: some View {
        @Bindable var prefs = prefs
        Section {
            Picker(selection: $prefs.liveTVSource) {
                ForEach(LiveTVSource.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                MacSettingLabel(Copy.liveTVSource)
            }
            .note(Copy.liveTVSource)
        } header: {
            Text("Source")
        } footer: {
            MacSettingFooter(Copy.liveTVSource)
        }

        if prefs.liveTVSource == .custom {
            Section {
                LabeledContent {
                    TextField("M3U playlist URL", text: $prefs.iptvPlaylistURL, prompt: Text("https://example.com/playlist.m3u"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(minWidth: 240)
                } label: {
                    MacSettingLabel(Copy.iptvPlaylist, title: "Playlist")
                }
                .note(Copy.iptvPlaylist)
                LabeledContent {
                    TextField("XMLTV guide URL", text: $prefs.iptvGuideURL, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(minWidth: 240)
                } label: {
                    MacSettingLabel(Copy.iptvGuide, title: "Guide")
                }
                .note(Copy.iptvGuide)
                LabeledContent {
                    TextField("User agent", text: $prefs.iptvUserAgent, prompt: Text(Preferences.defaultIPTVUserAgent))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(minWidth: 240)
                } label: {
                    MacSettingLabel(Copy.iptvUserAgent)
                }
                .note(Copy.iptvUserAgent)

                Picker(selection: $prefs.iptvRefreshMinutes) {
                    ForEach(Self.iptvRefreshChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                } label: {
                    MacSettingLabel(Copy.iptvRefresh)
                }
                .note(Copy.iptvRefresh)

                ArtworkProbeRow()
            } header: {
                Text("Playlist")
            } footer: {
                // What the playlist and guide actually produced, last time
                // they were read. A channel column full of empty tiles has
                // two very different causes — the artwork wouldn't load, or
                // the playlist never named any — and they are not tellable
                // apart by looking at the guide. This tells them apart.
                if let summary = LiveTVStore.shared.summary {
                    Text("Last read: " + Self.playlistSummary(summary))
                } else {
                    MacSettingFooter(Copy.iptvPlaylist, Copy.iptvGuide)
                }
            }
        }

        Section {
            LabeledContent {
                Button("Refresh Now") {
                    prefs.liveTVRefreshToken += 1
                    app.toast("Refreshing Live TV…", tone: .info)
                }
            } label: {
                MacSettingLabel(Copy.refreshNow, title: "Channel List & Guide")
            }
            .note(Copy.refreshNow)
        } footer: {
            MacSettingFooter(Copy.refreshNow)
        }
    }

    // MARK: - Storage

    private var downloadsSection: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker("Default Quality", selection: $prefs.downloadQuality) {
                ForEach(DownloadQualities.all) { Text($0.label).tag($0.label) }
            }
            LabeledContent {
                Stepper(value: $prefs.downloadConcurrency, in: 1...Preferences.maxDownloadConcurrency) {
                    Text("\(prefs.downloadConcurrency)")
                        .monospacedDigit()
                        .frame(minWidth: 16, alignment: .trailing)
                }
            } label: {
                MacSettingLabel(Copy.concurrency)
            }
            .note(Copy.concurrency)
            Toggle(isOn: $prefs.downloadsWiFiOnly) { MacSettingLabel(Copy.wifiOnly) }
                .note(Copy.wifiOnly)
            LabeledContent {
                Button("Show in Finder") { DownloadManager.revealInFinder() }
                    .help(DownloadManager.root.path)
            } label: {
                Text("Kept In")
            }
        } header: {
            Text("Downloads")
        } footer: {
            MacSettingFooter(Copy.concurrency, Copy.wifiOnly)
        }
    }

    private var libraryCopySection: some View {
        @Bindable var prefs = prefs
        return Section {
            Toggle(isOn: $prefs.keepsLibraryCopy) { MacSettingLabel(Copy.libraryCopy) }
                .onChange(of: prefs.keepsLibraryCopy) { _, on in LibraryIndex.shared.setEnabled(on) }
                .note(Copy.libraryCopy)
            if prefs.keepsLibraryCopy {
                let index = LibraryIndex.shared
                LabeledContent {
                    Text(LibraryCopyText.status(index))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    MacSettingLabel(Copy.libraryCopyStatus)
                }
                .note(Copy.libraryCopyStatus)
                LabeledContent {
                    Text(LibraryCopyText.contents(index))
                        .foregroundStyle(.secondary)
                } label: {
                    MacSettingLabel(Copy.libraryCopyContents)
                }
                .note(Copy.libraryCopyContents)
                LabeledContent {
                    HStack(spacing: 8) {
                        if index.isSyncing { ProgressView().controlSize(.small) }
                        Button("Sync Now") {
                            Task { await LibraryIndex.shared.sync(force: true) }
                        }
                        .disabled(index.isSyncing)
                    }
                } label: {
                    MacSettingLabel(Copy.syncNow, title: "Sync")
                }
                .note(Copy.syncNow)
                LabeledContent {
                    Button("Delete the Copy…") { confirmDeleteCopy = true }
                } label: {
                    MacSettingLabel(Copy.deleteCopy, title: "Saved Copy")
                }
                .note(Copy.deleteCopy)
            }
        } header: {
            Text("Library Copy")
        } footer: {
            MacSettingFooter(Copy.libraryCopy)
        }
    }
}

#endif

#if os(iOS)
private typealias Copy = SettingsCopy

/// The page on a phone and an iPad: a table of contents.
///
/// Every row on the first page is a page — an icon, a name, and where the
/// page stands in grey — and nothing on it is a control, so nothing on it
/// needs a sentence. The controls are one level down, four to eight to a
/// page, grouped in short sections with the sentence about each group as its
/// footer, which is how the system's own Settings reads. The one exception
/// is iCloud sync, a switch, because a switch is the clearest way to show it.
///
/// On an iPad with the room, the list is the left column and the chosen page
/// the right (`SettingsSplitPage`), the way iPadOS Settings works; narrower,
/// it is the phone's page.
struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if AppModel.usesSidebar && sizeClass == .regular {
            SettingsSplitPage()
        } else {
            SettingsListPage()
        }
    }
}

/// The first page as one list, every row opening its page.
private struct SettingsListPage: View {
    var body: some View {
        Form {
            SettingsMapRows()
        }
        .formStyle(.grouped)
        .screenTitle("Settings")
        .paletteBar()
    }
}

/// The first page beside the page it opens, for an iPad in a regular width.
///
/// Not a `NavigationSplitView`: this already sits in the detail column of the
/// app's own, and one inside another is not a thing SwiftUI does. A list with
/// a selection and the page beside it is the same shape without the
/// machinery. Pages a page opens — Station mix, the app icon, the sidebar's
/// order — push onto the stack this view is in, as they would on a phone.
private struct SettingsSplitPage: View {
    @State private var page: SettingsPage = .video

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { Optional(page) }, set: { if let new = $0 { page = new } })) {
                SettingsMapRows(selectable: true)
            }
            .listStyle(.insetGrouped)
            .frame(width: 320)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(page.note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 4)
                SettingsPageView(page: page)
            }
            .frame(maxWidth: .infinity)
            .id(page)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .screenTitle("Settings")
        .paletteBar()
    }
}

/// The rows of the first page, in their groups. `selectable` makes each a
/// tagged row for a list with a selection; otherwise each is a link.
private struct SettingsMapRows: View {
    var selectable = false

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Section {
            row(.account) { SettingsAccountCard() }
        }

        Section {
            row(.appearance, value: prefs.theme.label)
        }

        Section("Playing") {
            row(.video, value: SettingsSummary.video(prefs))
            row(.audio, value: SettingsSummary.audio(prefs))
            row(.subtitles, value: SettingsSummary.subtitles(prefs))
            if app.hasAudio {
                row(.music)
            }
            row(.liveTV, value: SettingsSummary.liveTV(prefs))
        }

        Section("Storage") {
            row(.downloads, value: SettingsSummary.downloads(prefs))
            row(.libraryCopy, value: SettingsSummary.libraryCopy(prefs))
            if UIDevice.current.userInterfaceIdiom == .phone {
                row(.watch, value: Self.watchSummary)
            }
        }

        Section {
            Toggle(isOn: SettingsView.cloudSyncBinding) {
                HStack(spacing: 12) {
                    SettingsTile(page: .about, symbol: "icloud.fill", tint: Color(hex: 0x0EA5E9))
                    Text("Sync settings with iCloud")
                        .foregroundStyle(Theme.text)
                }
            }
            .disabled(!prefs.cloudIsAvailable)
            row(.about, value: Bundle.appVersion)
        } header: {
            Text("General")
        } footer: {
            Text(prefs.cloudIsAvailable ? Copy.cloudSync.summary : Copy.cloudUnavailable.text)
        }
    }

    /// A page's row: a link to it, or a selectable row standing for it.
    @ViewBuilder
    private func row(_ page: SettingsPage, value: String? = nil) -> some View {
        row(page) { SettingsRow(page: page, value: value) }
    }

    @ViewBuilder
    private func row<Label: View>(_ page: SettingsPage, @ViewBuilder label: () -> Label) -> some View {
        if selectable {
            label().tag(page)
        } else {
            NavigationLink {
                SettingsPageView(page: page)
                    .settingsPushed(page)
            } label: {
                label()
            }
        }
    }

    private static var watchSummary: String {
        let link = WatchLink.shared
        guard link.isPaired else { return "Not paired" }
        guard link.isWatchAppInstalled else { return "Not installed" }
        guard let inventory = link.inventory else { return "Installed" }
        return inventory.itemCount == 0 ? "Nothing on it" : "\(inventory.itemCount) item\(inventory.itemCount == 1 ? "" : "s") · \(Format.bytes(inventory.totalBytes))"
    }
}

/// The page a first-page row opens.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .account: AccountSettingsPage()
        case .appearance: AppearanceSettingsPage()
        case .video: VideoSettingsPage()
        case .audio: AudioSettingsPage()
        case .subtitles: SubtitlesSettingsPage()
        case .music: MusicSettingsPage()
        case .liveTV: LiveTVSettingsPage()
        case .downloads: DownloadsSettingsPage()
        case .libraryCopy: LibraryCopySettingsPage()
        case .watch: WatchSettingsView()
        case .about: AboutSettingsPage()
        }
    }
}

extension View {
    /// What a settings page wears when it is pushed onto the stack rather than
    /// shown beside the list: its title in the bar, the bar in the app's
    /// colour, and room at the foot for the mini player.
    func settingsPushed(_ page: SettingsPage) -> some View {
        self
            .screenTitle(page.title)
            .paletteBar()
            .clearsBottomChrome()
    }
}

/// A first-page row: the page's tile, its name, and where it stands.
///
/// The name has the room and the value gives way: a long value is cut short
/// rather than pushing the name into the tile or wrapping it under the value.
struct SettingsRow: View {
    let page: SettingsPage
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            SettingsTile(page: page)
            Text(page.title)
                .foregroundStyle(Theme.text)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if let value, !value.isEmpty {
                Text(value)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A page's symbol on a rounded square of its colour, the way the system's
/// Settings marks its rows.
struct SettingsTile: View {
    let page: SettingsPage
    var symbol: String?
    var tint: Color?
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: symbol ?? page.symbol)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint ?? page.tint, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The first row: who is signed in, where, and whether the server answered.
struct SettingsAccountCard: View {
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        HStack(spacing: 14) {
            if let session = client.session {
                AccountAvatar(account: session, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.userName.isEmpty ? "Unnamed user" : session.userName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(session.serverLabel)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                StatusPill(text: client.isOffline ? "Offline" : "Connected", tone: client.isOffline ? .warn : .ok)
            } else {
                SettingsTile(page: .account, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not connected")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text("No Jellyfin server is signed in.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 8)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Under a section: the sentences about the controls in it, a paragraph each.
private struct SettingsFooter: View {
    let notes: [SettingNote]

    init(_ notes: SettingNote...) { self.notes = notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notes) { note in
                Text(note.text)
            }
        }
    }
}

// MARK: - The pages

private struct AccountSettingsPage: View {
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
            } header: {
                Text("Server")
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
                } footer: {
                    SettingsFooter(Copy.signOut)
                }
            }
        }
        .formStyle(.grouped)
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

private struct AppearanceSettingsPage: View {
    @Environment(Preferences.self) private var prefs
    /// Read again on the way back from the picker; nothing announces a change.
    @State private var iconTitle = AppIconChoice.current.title

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker(Copy.theme.name ?? "", selection: $prefs.theme) {
                    ForEach(ThemePref.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                SettingsFooter(Copy.theme)
            }

            Section {
                if UIApplication.shared.supportsAlternateIcons {
                    NavigationLink {
                        AppIconSettingsView()
                            .clearsBottomChrome()
                    } label: {
                        LabeledContent("App Icon", value: iconTitle)
                    }
                }
                NavigationLink {
                    TabBarSettingsView()
                        .clearsBottomChrome()
                } label: {
                    LabeledContent(AppModel.usesSidebar ? "Sidebar" : "Tab Bar",
                                   value: prefs.tabBarOrder.isEmpty ? "Default" : "Custom")
                }
            } footer: {
                Text(AppModel.usesSidebar
                     ? "The order of the sections in the sidebar."
                     : "Which sections have a place in the tab bar, and in what order. The rest are listed under More.")
            }
        }
        .formStyle(.grouped)
        .onAppear { iconTitle = AppIconChoice.current.title }
    }
}

private struct VideoSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker(Copy.defaultQuality.name ?? "", selection: SettingsView.bitrateBinding) {
                    ForEach(Quality.choices) { Text($0.label).tag($0.maxBitrate) }
                }
                Toggle(Copy.adaptiveQuality.name ?? "", isOn: $prefs.adaptiveQuality)
            } header: {
                Text("Quality")
            } footer: {
                SettingsFooter(Copy.defaultQuality, Copy.adaptiveQuality)
            }

            Section {
                // The segments beside the name: a segmented picker on its own
                // in a form row drops its label, and "Fit | Fill" with nothing
                // to say what they are of is a puzzle.
                HStack {
                    Text(Copy.framing.name ?? "")
                    Spacer(minLength: 16)
                    Picker(Copy.framing.name ?? "", selection: $prefs.fillScreen) {
                        Text("Fit").tag(false)
                        Text("Fill").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Picture")
            } footer: {
                SettingsFooter(Copy.framing, Copy.pictureControls)
            }

            Section {
                Toggle(Copy.resume.name ?? "", isOn: $prefs.resumePlayback)
                Toggle(Copy.autoplayNext.name ?? "", isOn: $prefs.autoplayNext)
            } header: {
                Text("Playing")
            } footer: {
                SettingsFooter(Copy.resume, Copy.autoplayNext)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker("Language", selection: $prefs.audioLanguage) {
                    Text("File's choice").tag("")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: {
                Text("Language")
            } footer: {
                SettingsFooter(Copy.audioLanguage)
            }

            Section {
                Toggle(Copy.downmix.name ?? "", isOn: $prefs.stereoDownmix)
                Picker(Copy.audioDelay.name ?? "", selection: SettingsView.audioDelayBinding) {
                    ForEach(SettingsView.audioDelayChoices, id: \.self) { milliseconds in
                        Text(PlayerModel.audioDelayName(milliseconds)).tag(milliseconds)
                    }
                }
            } header: {
                Text("Output")
            } footer: {
                SettingsFooter(Copy.downmix, Copy.audioDelay)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SubtitlesSettingsPage: View {
    @Environment(Preferences.self) private var prefs
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker("Language", selection: $prefs.subtitleLanguage) {
                    Text("File's choice").tag("")
                    Text("Never").tag("off")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                Toggle(Copy.forcedOnly.name ?? "", isOn: $prefs.forcedSubtitlesOnly)
            } header: {
                Text("Language")
            } footer: {
                SettingsFooter(Copy.subtitleLanguage, Copy.forcedOnly, Copy.trackMemory)
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text(Copy.subtitleSize.name ?? "")
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
            } header: {
                Text("Appearance")
            } footer: {
                SettingsFooter(Copy.subtitleSize, Copy.subtitleBackground)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MusicSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Toggle(Copy.musicAutoplay.name ?? "", isOn: $prefs.musicAutoplay)
                Toggle(Copy.normalizeVolume.name ?? "", isOn: $prefs.normalizeVolume)
            } header: {
                Text("Playing")
            } footer: {
                SettingsFooter(Copy.musicAutoplay, Copy.normalizeVolume)
            }

            Section {
                Toggle(Copy.losslessOnCellular.name ?? "", isOn: $prefs.losslessOnCellular)
            } header: {
                Text("Streaming")
            } footer: {
                SettingsFooter(Copy.losslessOnCellular)
            }

            Section {
                Toggle(Copy.musicRomanize.name ?? "", isOn: $prefs.musicRomanizeNames)
                NavigationLink {
                    StationMixSettingsPage()
                        .clearsBottomChrome()
                } label: {
                    LabeledContent(Copy.stationMix.name ?? "", value: prefs.mixPoints.presetName)
                }
            } header: {
                Text("Stations")
            } footer: {
                SettingsFooter(Copy.musicRomanize, Copy.stationMix)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LiveTVSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker(Copy.liveTVSource.name ?? "", selection: $prefs.liveTVSource) {
                    ForEach(LiveTVSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Source")
            } footer: {
                SettingsFooter(Copy.liveTVSource)
            }

            if prefs.liveTVSource == .custom {
                Section {
                    NavigationLink {
                        CustomPlaylistSettingsPage()
                            .clearsBottomChrome()
                    } label: {
                        LabeledContent("Custom playlist", value: Self.host(of: prefs.iptvPlaylistURL) ?? "Not set")
                    }
                } footer: {
                    // What the playlist and guide actually produced, last time
                    // they were read — see the Mac's page for why.
                    if let summary = LiveTVStore.shared.summary {
                        Text("Last read: " + SettingsView.playlistSummary(summary) + ".")
                    } else {
                        Text("The playlist and guide addresses, how often they are re-read, and a check on the channel artwork.")
                    }
                }
            }

            Section {
                Button(Copy.refreshNow.name ?? "") {
                    prefs.liveTVRefreshToken += 1
                    app.toast("Refreshing Live TV…", tone: .info)
                }
            } footer: {
                SettingsFooter(Copy.refreshNow)
            }
        }
        .formStyle(.grouped)
    }

    /// The server a URL names, for a row with no room for the whole address.
    private static func host(of url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)?.host ?? trimmed
    }
}

private struct CustomPlaylistSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                TextField("https://example.com/playlist.m3u", text: $prefs.iptvPlaylistURL)
                    .textFieldStyle(.plain)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(Copy.iptvPlaylist.name ?? "")
            } footer: {
                SettingsFooter(Copy.iptvPlaylist)
            }

            Section {
                TextField("Optional", text: $prefs.iptvGuideURL)
                    .textFieldStyle(.plain)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(Copy.iptvGuide.name ?? "")
            } footer: {
                SettingsFooter(Copy.iptvGuide)
            }

            Section {
                TextField(Preferences.defaultIPTVUserAgent, text: $prefs.iptvUserAgent)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker(Copy.iptvRefresh.name ?? "", selection: $prefs.iptvRefreshMinutes) {
                    ForEach(SettingsView.iptvRefreshChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
            } header: {
                Text("Fetching")
            } footer: {
                SettingsFooter(Copy.iptvUserAgent, Copy.iptvRefresh)
            }

            Section {
                ArtworkProbeRow()
            } header: {
                Text("Channel artwork")
            } footer: {
                SettingsFooter(Copy.artworkProbe)
            }
        }
        .formStyle(.grouped)
        .screenTitle("Custom playlist")
        .paletteBar()
    }
}

private struct DownloadsSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker("Default quality", selection: $prefs.downloadQuality) {
                    ForEach(DownloadQualities.all) { Text($0.label).tag($0.label) }
                }
            } header: {
                Text("Quality")
            } footer: {
                Text("What a download is asked for. Original keeps the file as it is on the server; the rest are transcoded to fit.")
            }

            Section {
                Stepper(value: $prefs.downloadConcurrency, in: 1...Preferences.maxDownloadConcurrency) {
                    HStack {
                        Text(Copy.concurrency.name ?? "")
                        Spacer()
                        Text("\(prefs.downloadConcurrency)")
                            .foregroundStyle(Theme.textDim)
                            .monospacedDigit()
                    }
                }
                Toggle(Copy.wifiOnly.name ?? "", isOn: $prefs.downloadsWiFiOnly)
            } header: {
                Text("Transfers")
            } footer: {
                SettingsFooter(Copy.concurrency, Copy.wifiOnly)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LibraryCopySettingsPage: View {
    @Environment(Preferences.self) private var prefs
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var prefs = prefs
        let index = LibraryIndex.shared
        Form {
            Section {
                Toggle(Copy.libraryCopy.name ?? "", isOn: $prefs.keepsLibraryCopy)
                    .onChange(of: prefs.keepsLibraryCopy) { _, on in LibraryIndex.shared.setEnabled(on) }
            } footer: {
                SettingsFooter(Copy.libraryCopy)
            }
            if prefs.keepsLibraryCopy {
                Section {
                    LabeledContent("Status") {
                        Text(LibraryCopyText.status(index))
                            .foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Saved") {
                        Text(LibraryCopyText.contents(index))
                            .foregroundStyle(Theme.textDim)
                    }
                } footer: {
                    SettingsFooter(Copy.libraryCopyStatus)
                }
                Section {
                    Button(Copy.syncNow.name ?? "") {
                        Task { await LibraryIndex.shared.sync(force: true) }
                    }
                    .disabled(index.isSyncing)
                    Button(Copy.deleteCopy.name ?? "", role: .destructive) {
                        confirmDelete = true
                    }
                } footer: {
                    SettingsFooter(Copy.syncNow, Copy.deleteCopy)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the saved copy of your library?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { LibraryIndex.shared.wipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Copy.deleteCopy.text)
        }
    }
}

private struct StationMixSettingsPage: View {
    var body: some View {
        Form {
            StationMixSection()
        }
        .formStyle(.grouped)
        .screenTitle(Copy.stationMix.name ?? "")
        .paletteBar()
    }
}

private struct AboutSettingsPage: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Aquarium", value: "\(Bundle.appVersion) (\(Bundle.appBuild))")
                LabeledContent("Playback engine", value: "AVFoundation")
            } footer: {
                SettingsFooter(Copy.playbackEngine)
            }
            Section {
                Text(Copy.about.text)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
#endif

#if !os(tvOS)
/// Everyone signed in on this device: tap to become them, swipe (or press
/// and hold, or right-click) to sign one out of it.
///
/// On a Mac, the Users & Groups pattern instead: a table with + and − under
/// it, a Switch button for the selected row, and a double-click that does the
/// same.
struct AccountsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    #if os(macOS)
    @State private var selected: String?
    @State private var removing: SavedSession?

    private var selectedAccount: SavedSession? {
        client.accounts.first { $0.accountKey == selected }
    }

    private func isCurrent(_ account: SavedSession) -> Bool {
        account.accountKey == client.session?.accountKey
    }

    private func switchTo(_ account: SavedSession) {
        guard !isCurrent(account) else { return }
        Task { await app.switchAccount(to: account) }
    }

    var body: some View {
        Section {
            List(client.accounts, id: \.accountKey, selection: $selected) { account in
                HStack(spacing: 10) {
                    AccountAvatar(account: account, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.userName.isEmpty ? "Unnamed user" : account.userName)
                        Text(account.serverLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if isCurrent(account) {
                        Text("Signed In")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if app.switchingTo?.accountKey == account.accountKey {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            .frame(height: CGFloat(min(max(client.accounts.count, 1), 5)) * 40 + 2)
            .contextMenu(forSelectionType: String.self) { keys in
                if let account = client.accounts.first(where: { keys.contains($0.accountKey) }) {
                    Button("Switch to \(account.userName)") { switchTo(account) }
                        .disabled(isCurrent(account) || app.switchingTo != nil)
                    Button("Sign Out of This Mac…", role: .destructive) { removing = account }
                        .disabled(isCurrent(account))
                }
            } primaryAction: { keys in
                if let account = client.accounts.first(where: { keys.contains($0.accountKey) }) { switchTo(account) }
            }
            HStack(spacing: 0) {
                Button {
                    app.isAddingAccount = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 14, height: 14)
                }
                .help("Add Account… — " + SettingsCopy.addAccount.text)
                .accessibilityLabel("Add Account")
                Button {
                    if let account = selectedAccount { removing = account }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 14, height: 14)
                }
                .disabled(selectedAccount == nil || selectedAccount.map(isCurrent) == true)
                .help("Sign Out of This Mac — forgets the selected account here, without touching the one in use.")
                .accessibilityLabel("Remove Account")
                Spacer()
                Button("Switch") {
                    if let account = selectedAccount { switchTo(account) }
                }
                .disabled(selectedAccount == nil || selectedAccount.map(isCurrent) == true || app.switchingTo != nil)
                .help("Sign in as the selected account. Switching is instant and needs no password.")
            }
            .controlSize(.small)
            .confirmationDialog("Sign \(removing?.userName ?? "this account") out of this Mac?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { account in
                Button("Sign Out", role: .destructive) { Task { await app.remove(account) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The account's token is removed from this Mac's keychain. Signing in again asks for the password.")
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text(client.accounts.count > 1
                 ? "Select an account and click Switch, or double-click it. " + SettingsCopy.accounts.summary
                 : SettingsCopy.accounts.summary)
        }
    }
    #else
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
    #endif
}

/// The points stations are weighed by: a preset, then a stepper a dial. A
/// dial can only go as high as the budget has points left, so spending on one
/// is taking from another.
struct StationMixSection: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let points = prefs.mixPoints
        let coverage = TagCoverage.recent
        Section {
            Picker(selection: preset) {
                ForEach(MixPoints.presets, id: \.name) { Text($0.name).tag($0.name) }
                if points.presetName == MixPoints.customName {
                    Text(MixPoints.customName).tag(MixPoints.customName)
                }
            } label: {
                #if os(macOS)
                MacSettingLabel(SettingsCopy.mixPreset)
                #else
                Text(SettingsCopy.mixPreset.name ?? "")
                #endif
            }
            .note(SettingsCopy.mixPreset)

            ForEach(MixPoints.Dial.allCases) { dial in
                let note = SettingsCopy.mixDial(dial)
                VStack(alignment: .leading, spacing: 6) {
                    #if os(macOS)
                    LabeledContent {
                        Stepper(value: binding(dial), in: 0...(points[dial] + points.remaining)) {
                            Text("\(points[dial])")
                                .monospacedDigit()
                                .frame(minWidth: 16, alignment: .trailing)
                        }
                    } label: {
                        MacSettingLabel(note)
                    }
                    #else
                    Stepper(value: binding(dial), in: 0...(points[dial] + points.remaining)) {
                        HStack {
                            Text(note.name ?? "")
                            Spacer()
                            Text("\(points[dial])")
                                .foregroundStyle(Theme.textDim)
                                .monospacedDigit()
                        }
                    }
                    #endif
                    if let warning = coverage.note(for: dial) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .note(note)
            }
        } header: {
            Text(SettingsCopy.stationMix.name ?? "")
        } footer: {
            Text("\(SettingsCopy.mixPointsLeft(points)) \(SettingsCopy.stationMix.text)")
        }
    }

    private var preset: Binding<String> {
        Binding(
            get: { prefs.mixPoints.presetName },
            set: { name in
                if let preset = MixPoints.presets.first(where: { $0.name == name }) { prefs.mixPoints = preset.points }
            }
        )
    }

    private func binding(_ dial: MixPoints.Dial) -> Binding<Int> {
        Binding(get: { prefs.mixPoints[dial] }, set: { prefs.mixPoints[dial] = $0 })
    }
}

private extension View {
    /// Attaches the sentences that say what this setting does, as rows of their
    /// own directly under it.
    func note(_ notes: SettingNote...) -> some View {
        Group {
            #if os(macOS)
            // The first sentence is the second line of the control's own
            // label (`MacSettingLabel`); the whole paragraph is here, on
            // hover. Sentences in rows of their own read as settings of
            // their own, and the full paragraphs under every row made the
            // window a wall of grey text.
            self.help(notes.map(\.text).joined(separator: "\n\n"))
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
        #if os(macOS)
        LabeledContent {
            HStack(spacing: 8) {
                if isRunning { ProgressView().controlSize(.small) }
                Button(hasRun ? "Check Again" : "Check Now") {
                    Task { await run() }
                }
                .disabled(isRunning)
            }
        } label: {
            MacSettingLabel(SettingsCopy.artworkProbe, title: "Channel Artwork")
        }
        .note(SettingsCopy.artworkProbe)

        if hasRun, results.isEmpty {
            Text(SettingsView.noChannelsYet)
                .foregroundStyle(.secondary)
        }

        ForEach(results) { ArtworkProbeResultView(result: $0) }
        #else
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
        #endif
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
    static let musicRomanize = SettingNote(
        name: "Romanize artist names",
        text: "Name stations after an artist in Latin letters when the server has a romanized name or the script has a reliable transliteration. Japanese names written in kanji are left as they are."
    )
    static let stationMix = SettingNote(
        name: "Station mix",
        text: "\(MixPoints.budget) points to spend on what stations favour. Every station uses them, autoplay and downloads included, and they follow your iCloud account. Rediscover and Deep Cuts have nothing to be like, so the first three do nothing there."
    )
    static let mixPreset = SettingNote(
        name: "Preset",
        text: "Balanced is how stations have always chosen. Familiar leans on what you star and play most. Discovery leans on what you have never played."
    )
    static func mixDial(_ dial: MixPoints.Dial) -> SettingNote {
        switch dial {
        case .artist: SettingNote(name: "Same artist", text: "More songs by the artist the station started from. A genre station has no artist to keep to.")
        case .genre: SettingNote(name: "Genre", text: "Keeps closer to the genre the station started from.")
        case .era: SettingNote(name: "Era", text: "Keeps closer to the years the station started from. Artist and genre stations have no era to keep to.")
        case .favorites: SettingNote(name: "Favourites", text: "Songs you have starred come up more.")
        case .mostPlayed: SettingNote(name: "Most played", text: "Songs you play a lot come up more.")
        case .discovery: SettingNote(name: "Discovery", text: "Songs you have never played come up more. Deep Cuts plays nothing else, so these points do nothing there.")
        case .surprise: SettingNote(name: "Surprise", text: "A less predictable order.")
        }
    }
    static func mixPointsLeft(_ points: MixPoints) -> String {
        "\(points.remaining) of \(MixPoints.budget) points left to spend."
    }
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
    static let matchedAudioDelay = SettingNote(
        name: "Audio delay at 24 Hz",
        text: "The offset used instead when Match Content → Match Frame Rate switches your television out of 60 Hz for a video — a film, mostly. Many televisions show the picture later at 24 Hz than at 60, and tvOS can tell the app that matching is on but not how much later, so this is measured on its own with the Match Frame Rate sync test. Until it has been, films get the standard delay. The player's Sync tab moves this one while a video the display switched for is playing."
    )
    static let syncTestStandard = SettingNote(
        name: "Sync test · standard frame rate",
        text: "Plays a short looping clip at 60 fps, which leaves the television in the mode the Home screen runs in — what shows and most Live TV play in. A line sweeps across a ruler and a beep plays as it crosses 0. Swipe down for the Sync tab: if the beep comes before the flash, press −; after it, press +. What is settled on becomes the audio delay."
    )
    static let syncTestMatched = SettingNote(
        name: "Sync test · Match Frame Rate",
        text: "The same clip at 23.976 fps, the rate films are, so with Match Content → Match Frame Rate on the television switches to the mode your films play in and the test measures that mode's lag. What is settled on becomes the audio delay at 24 Hz, and is used for every video the display switches for. With Match Frame Rate off there is no switch, and the test sets the standard delay instead."
    )
    static let audioLanguage = SettingNote(
        name: "Audio",
        text: "Preferred spoken language. When a file has more than one soundtrack, every video opens with the first track in this language — asked of the server before the stream starts, so it holds on a transcode as well as a file played untouched."
    )
    static let subtitleLanguage = SettingNote(
        name: "Subtitles",
        text: "Which subtitles a video opens with, when the file has them in this language. “Never” is the setting to pick if you don't use subtitles: it stops them being switched on by a file that ships with them enabled, which no other option here can do."
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
        "Set from inside the player: the Sync tab puts the controls over whatever is playing, so the sound can be nudged while watching a line of dialogue, or over the sync test's clip. Used while the television is in its usual 60 Hz mode; a video the display is switched for gets the delay at 24 Hz instead. "
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
    /// What the About panel says — on a Mac the app menu's About item, now
    /// that the General tab no longer carries it. The version first, then the
    /// engine, then the paragraph.
    static var aboutLines: [String] {
        ["Aquarium \(Bundle.appVersion) (\(Bundle.appBuild))", "Playback engine: AVFoundation", about.text]
    }
    static let playbackEngine = SettingNote(
        name: "Playback engine",
        text: "Apple's AVFoundation, the same media framework the system's own players are built on — so what plays directly, and what the server is asked to convert, follows what this device supports."
    )
}

extension SettingsView {
    /// Off whenever iCloud can't be used, whatever was chosen before. A
    /// disabled switch still drawn *on* read as a feature that was working.
    static var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { Preferences.shared.syncsAcrossDevices && Preferences.shared.cloudIsAvailable },
            set: { Preferences.shared.syncsAcrossDevices = $0 }
        )
    }
}

// MARK: - The map

/// The pages of Settings: the same ones, in the same order, on every platform,
/// so a setting is on the same page wherever it is looked for and a sentence
/// written about it once is true everywhere.
///
/// A phone and an iPad list them as rows that open pages; a Mac makes tabs of
/// them (with Appearance and iCloud folded into General, and Downloads and
/// Library copy sharing Storage); an Apple TV lists them as rows with the
/// panel describing each. The tile colour and symbol travel with the page.
enum SettingsPage: String, CaseIterable, Identifiable {
    case account, appearance, video, audio, subtitles, music, liveTV, downloads, libraryCopy, watch, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "Account"
        case .appearance: "Appearance"
        case .video: "Video"
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        case .music: "Music"
        case .liveTV: "Live TV"
        case .downloads: "Downloads"
        case .libraryCopy: "Library copy"
        case .watch: "Apple Watch"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .appearance: "circle.lefthalf.filled"
        case .video: "play.rectangle.fill"
        case .audio: "speaker.wave.2.fill"
        case .subtitles: "captions.bubble.fill"
        case .music: "music.note"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle.fill"
        case .libraryCopy: "externaldrive.fill"
        case .watch: "applewatch"
        case .about: "info.circle.fill"
        }
    }

    /// The colour behind the symbol: one per page, kept apart from each other
    /// and from the app's accent, so a glance down the list finds the row.
    var tint: Color {
        switch self {
        case .account: Color(hex: 0x3478F6)
        case .appearance: Color(hex: 0xA550A7)
        case .video: Color(hex: 0xE5484D)
        case .audio: Color(hex: 0xF0742A)
        case .subtitles: Color(hex: 0x2A9D8F)
        case .music: Color(hex: 0xEC4899)
        case .liveTV: Color(hex: 0x34A853)
        case .downloads: Color(hex: 0x5B5BD6)
        case .libraryCopy: Color(hex: 0x8E8E93)
        case .watch: Color(hex: 0x3A3A3C)
        case .about: Color(hex: 0x8E8E93)
        }
    }

    /// What the page is about, in a line: the Apple TV's panel while the
    /// selector rests on the row, and the heading beside an iPad's list.
    var note: String {
        switch self {
        case .account: "Who is signed in and where, how the connection is secured, the other accounts on this device, and signing out."
        case .appearance: "Light or dark, the icon on the Home Screen, and the order of the tabs."
        case .video: "The quality a stream opens at, whether it adapts, how a wide picture is framed, and what happens at the end of an episode."
        case .audio: "The spoken language a video opens with, downmixing surround for a stereo setup, and the delay that keeps sound and picture together."
        case .subtitles: "Which subtitles a video opens with, whether only the forced track shows, and how large they are drawn and on what."
        case .music: "Keeping the music going, levelling quiet albums against loud ones, lossless over cellular, and how stations choose."
        case .liveTV: "Where channels and the guide come from — Jellyfin's own Live TV, or an M3U playlist and XMLTV guide of your own."
        case .downloads: "The quality a download is asked for, how many run at once, and whether they wait for Wi‑Fi."
        case .libraryCopy: "Keep the whole library, with its posters, on this device, so it opens straight away and only syncs what changed."
        case .watch: "Audiobooks and music on the watch, what is on its way there, and what it reports back."
        case .about: "The version of Aquarium on this device, and how it was made."
        }
    }
}

/// The grey value on a first-page row: the one or two things most worth
/// knowing about the page without opening it. A page left at its defaults says
/// as little as it can.
@MainActor
enum SettingsSummary {
    static func account(_ client: JellyfinClient) -> String {
        guard let session = client.session else { return "Not connected" }
        return "\(session.userName) · \(client.isOffline ? "Offline" : "Connected")"
    }

    static func video(_ prefs: Preferences) -> String {
        var parts = [Quality.shortLabel(for: prefs.defaultBitrate)]
        if prefs.fillScreen { parts.append("Fill") }
        return parts.joined(separator: " · ")
    }

    static func audio(_ prefs: Preferences) -> String {
        var parts = [language(prefs.audioLanguage, none: "File's choice")]
        if prefs.stereoDownmix {
            parts.append("Stereo")
        } else if prefs.audioDelay != 0 {
            parts.append(PlayerModel.audioDelayShortName(Int((prefs.audioDelay * 1000).rounded())))
        }
        return parts.joined(separator: " · ")
    }

    static func subtitles(_ prefs: Preferences) -> String {
        var parts = [prefs.subtitleLanguage == "off" ? "Never" : language(prefs.subtitleLanguage, none: "File's choice")]
        if prefs.forcedSubtitlesOnly { parts.append("Forced only") }
        return parts.joined(separator: " · ")
    }

    static func liveTV(_ prefs: Preferences) -> String {
        prefs.liveTVSource == .custom ? "Custom playlist" : "Jellyfin"
    }

    static func downloads(_ prefs: Preferences) -> String {
        var parts = [DownloadQualities.named(prefs.downloadQuality).menuLabel]
        if prefs.downloadsWiFiOnly { parts.append("Wi‑Fi only") }
        return parts.joined(separator: " · ")
    }

    static func libraryCopy(_ prefs: Preferences) -> String {
        guard prefs.keepsLibraryCopy else { return "Off" }
        let count = LibraryIndex.shared.itemCount
        return count > 0 ? "On · \(count.formatted()) items" : "On"
    }

    /// A language preference's name, or what an empty one means here.
    static func language(_ code: String, none: String) -> String {
        guard !code.isEmpty else { return none }
        return Languages.all.first { $0.code == code }?.name ?? Languages.name(for: code)
    }
}
