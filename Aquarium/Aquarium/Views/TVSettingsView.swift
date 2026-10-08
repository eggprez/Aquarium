//  Settings, on a television.
//
//  Laid out the way the Apple TV's own Settings app is: the settings in a
//  column on the right, and on the left a panel describing whichever one the
//  selector is on. The sentence explaining a setting is only worth reading
//  about the setting you are looking at, so that is the only one on screen.
//  The first page is a table of contents — a row per page of the shared map
//  (`SettingsPage`), with where the page stands in grey — so it fits on
//  screen; the controls are a press away, on pages of a handful of rows each.
//
//  This replaces a `Form`, and two things about a `Form` on this platform are
//  why. It draws every row as a slab of its own, which put twenty-odd panels
//  and blocks of grey prose on one page. And it only ever scrolls to bring a
//  focusable row into view — so the About section, which had nothing to press,
//  sat below the last toggle where the page would not go, and the Server
//  facts above Sign out, likewise unfocusable, kept the list from ever
//  scrolling back to its top, which is what lets a swipe up reach the tab
//  strip again. Here every row can be selected, facts included, and a page's
//  first row scrolls it right back to its top when it takes focus.

#if os(tvOS)
import SwiftUI

private typealias Copy = SettingsCopy

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        SettingsColumns(intro: SettingDescription(
            title: "Settings", symbol: "gearshape",
            notes: [SettingNote(text: "Select a setting to see what it does.")]
        )) {
            // Every row a page, so the whole page fits on screen: the
            // controls are one press away, described one at a time in the
            // panel, and the first page never scrolls under the tab strip.
            SettingGroup(nil, page: .account) {
                SettingLink(Self.row(.account), value: SettingsSummary.account(client), page: .account, isFirst: true) {
                    ServerSettingsPage()
                }
            }

            SettingGroup("Playing", symbol: "play.rectangle") {
                SettingLink(Self.row(.video), value: SettingsSummary.video(prefs), page: .video) {
                    VideoSettingsPage()
                }
                SettingLink(Self.row(.audio), value: audioSummary, page: .audio) {
                    AudioSettingsPage()
                }
                SettingLink(Self.row(.subtitles), value: SettingsSummary.subtitles(prefs), page: .subtitles) {
                    SubtitleSettingsPage()
                }
                if app.hasAudio {
                    SettingLink(Self.row(.music), page: .music) {
                        MusicSettingsPage()
                    }
                }
                SettingLink(Self.row(.liveTV), value: SettingsSummary.liveTV(prefs), page: .liveTV) {
                    LiveTVSettingsPage()
                }
            }

            SettingGroup("General", symbol: "gearshape") {
                SettingLink(Self.row(.libraryCopy), value: SettingsSummary.libraryCopy(prefs), page: .libraryCopy) {
                    LibraryCopySettingsPage()
                }
                if prefs.cloudIsAvailable {
                    SettingToggle(Copy.cloudSync, isOn: $prefs.syncsAcrossDevices)
                } else {
                    SettingInfo(Copy.cloudSync.name ?? "", value: "Unavailable", tone: Theme.warn,
                                notes: [Copy.cloudUnavailable, Copy.cloudSync])
                }
                SettingLink(Self.row(.about), value: Bundle.appVersion, page: .about) {
                    AboutSettingsPage()
                }
            }
        }
    }

    /// The language, then the offsets that are set, if either is: "40 ms
    /// earlier", and the Match Frame Rate one after it when measured.
    private var audioSummary: String {
        var parts = [SettingsSummary.language(prefs.audioLanguage, none: "File's choice")]
        if prefs.audioDelay != 0 {
            parts.append(PlayerModel.audioDelayShortName(Int((prefs.audioDelay * 1000).rounded())))
        }
        if let matched = prefs.matchedAudioDelay {
            parts.append("24 Hz \(PlayerModel.audioDelayShortName(Int((matched * 1000).rounded())))")
        }
        return parts.joined(separator: " · ")
    }

    static let audioLanguageOptions: [(String, String)] =
        [("", "Whatever the file lists first")] + Languages.all.map { ($0.code, $0.name) }
    static let subtitleLanguageOptions: [(String, String)] =
        [("", "Only when the file turns them on"), ("off", "Never — no subtitles")]
            + Languages.all.map { ($0.code, $0.name) }

    /// A first-page row: the page's name, and what it is about for the panel.
    static func row(_ page: SettingsPage) -> SettingNote {
        SettingNote(name: page.title, text: page.note)
    }

    /// What a page's panel says before any row has focus.
    static func intro(_ page: SettingsPage) -> SettingDescription {
        SettingDescription(title: page.title, symbol: page.symbol, tint: page.tint, notes: [SettingNote(text: page.note)])
    }

    /// The language rows, named for the page they are on.
    static let audioLanguageRow = SettingNote(name: "Language", text: Copy.audioLanguage.text)
    static let subtitleLanguageRow = SettingNote(name: "Language", text: Copy.subtitleLanguage.text)
}

// MARK: - The pages

private struct ServerSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client

    @State private var isSigningOut = false
    @State private var confirmSignOut = false
    @State private var chosenAccount: SavedSession?

    var body: some View {
        SettingsColumns(title: "Account", intro: SettingsView.intro(.account)) {
            SettingGroup(nil, page: .account) {
                if let session = client.session {
                    SettingInfo("Signed in as", value: session.userName, notes: [Copy.signedInAs], isFirst: true)
                    SettingInfo("Server", value: session.server, notes: [Copy.server])
                    SettingInfo("Connection", value: session.secure ? "HTTPS" : "HTTP",
                                tone: session.secure ? Theme.ok : Theme.warn,
                                notes: [Copy.connection(secure: session.secure)])
                    SettingInfo("Server identity", value: session.serverId != nil ? "Pinned" : "Unpinned",
                                tone: session.serverId != nil ? Theme.ok : Theme.warn,
                                notes: [Copy.identity(pinned: session.serverId != nil)])
                    SettingInfo("Access token", value: "Keychain", tone: Theme.ok, notes: [Copy.accessToken])
                    SettingInfo("Status", value: client.isOffline ? "Offline" : "Connected",
                                tone: client.isOffline ? Theme.warn : Theme.ok,
                                notes: [Copy.status])
                } else {
                    SettingInfo("Server", value: "Not connected", notes: [Copy.server], isFirst: true)
                }
            }
            if client.session != nil {
                SettingGroup("Accounts", symbol: "person.2") {
                    ForEach(client.accounts, id: \.accountKey) { account in
                        let isCurrent = account.accountKey == client.session?.accountKey
                        Button {
                            if isCurrent { return }
                            chosenAccount = account
                        } label: {
                            AccountRow(account: account, isCurrent: isCurrent, invertsWhenFocused: true)
                                .describes(account.userName, [Copy.accounts])
                        }
                        .buttonStyle(SettingRowStyle())
                        .disabled(app.switchingTo != nil)
                    }
                    SettingButton("Add Account…", notes: [Copy.addAccount]) {
                        app.isAddingAccount = true
                    }
                }
                SettingGroup("", page: .account) {
                    SettingButton(isSigningOut ? "Signing out…" : "Sign out", role: .destructive,
                                  notes: [Copy.signOut]) {
                        confirmSignOut = true
                    }
                    .disabled(isSigningOut)
                }
            }
        }
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
        // One press offers both things a remote can't reach by swiping.
        .confirmationDialog(
            chosenAccount?.userName ?? "",
            isPresented: Binding(get: { chosenAccount != nil }, set: { if !$0 { chosenAccount = nil } }),
            titleVisibility: .visible
        ) {
            if let account = chosenAccount {
                Button("Switch to \(account.userName)") {
                    Task { await app.switchAccount(to: account) }
                }
                Button("Sign Out of This Apple TV", role: .destructive) {
                    Task { await app.remove(account) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct VideoSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        SettingsColumns(title: "Video", intro: SettingsView.intro(.video)) {
            SettingGroup(nil, page: .video) {
                SettingChoice(Copy.defaultQuality, selection: SettingsView.bitrateBinding,
                              options: Quality.choices.map { ($0.maxBitrate, $0.label) }, isFirst: true)
                SettingToggle(Copy.adaptiveQuality, isOn: $prefs.adaptiveQuality)
            }
            SettingGroup("Picture", page: .video) {
                SettingChoice(Copy.framing, selection: $prefs.fillScreen,
                              options: [(false, "Fit — show the whole frame"), (true, "Fill — crop to the screen")],
                              also: [Copy.pictureControls])
            }
            SettingGroup("Playing", page: .video) {
                SettingToggle(Copy.resume, isOn: $prefs.resumePlayback)
                SettingToggle(Copy.autoplayNext, isOn: $prefs.autoplayNext)
            }
        }
    }
}

private struct AudioSettingsPage: View {
    @Environment(Preferences.self) private var prefs
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var prefs = prefs
        SettingsColumns(title: "Audio", intro: SettingsView.intro(.audio)) {
            SettingGroup(nil, page: .audio) {
                SettingChoice(SettingsView.audioLanguageRow, selection: $prefs.audioLanguage,
                              options: SettingsView.audioLanguageOptions, isFirst: true)
            }
            SettingGroup("Output", page: .audio) {
                SettingToggle(Copy.downmix, isOn: $prefs.stereoDownmix)
                // Apple TV only: it is the one device here that passes a Dolby
                // bitstream through to something else, and so the only one on
                // which decoding it here changes anything.
                SettingToggle(Copy.soundbar, isOn: $prefs.decodeAudioLocally)
                // The two offsets, read-only here: each is set in the
                // player, over the clip that measures it — the Sync tab.
                SettingInfo(Copy.audioDelay.name ?? "", value: delayName(prefs.audioDelay),
                            notes: [Copy.audioDelay, Copy.syncTestStandard])
                SettingInfo(Copy.matchedAudioDelay.name ?? "", value: prefs.matchedAudioDelay.map(delayName) ?? "Not set",
                            notes: [Copy.matchedAudioDelay, Copy.syncTestMatched])
            }
            SettingGroup("Sync tests", page: .audio) {
                // Each opens the player on a looped test clip at its rate;
                // the Sync tab sets the matching offset over it.
                SettingButton(Copy.syncTestStandard.name ?? "", notes: [Copy.syncTestStandard]) {
                    Task { await player.playSyncTest(.standard) }
                }
                SettingButton(Copy.syncTestMatched.name ?? "", notes: [Copy.syncTestMatched]) {
                    Task { await player.playSyncTest(.matched) }
                }
            }
        }
    }

    /// Stored in seconds like the player reads it; shown in milliseconds
    /// like the player names it.
    private func delayName(_ seconds: Double) -> String {
        PlayerModel.audioDelayName(Int((seconds * 1000).rounded()))
    }
}

private struct SubtitleSettingsPage: View {
    @Environment(Preferences.self) private var prefs
    @Environment(PlayerModel.self) private var player

    /// The steps, plus whatever size is set if it isn't one of them — a
    /// phone's slider moves in fives, and the value syncs over, so without it
    /// the row would read blank.
    private var subtitleSizeOptions: [(Double, String)] {
        var values = [60.0, 80.0, 100.0, 120.0, 150.0, 180.0]
        let current = prefs.subtitleSize
        if !values.contains(current) { values.append(current); values.sort() }
        return values.map { ($0, "\(Int($0))%") }
    }

    var body: some View {
        @Bindable var prefs = prefs
        SettingsColumns(title: "Subtitles", intro: SettingsView.intro(.subtitles)) {
            SettingGroup(nil, page: .subtitles) {
                SettingChoice(SettingsView.subtitleLanguageRow, selection: $prefs.subtitleLanguage,
                              options: SettingsView.subtitleLanguageOptions, isFirst: true)
                SettingToggle(Copy.forcedOnly, isOn: $prefs.forcedSubtitlesOnly, also: [Copy.trackMemory])
            }
            SettingGroup("Appearance", page: .subtitles) {
                // tvOS has no slider a remote can drive; the same range as a
                // set of steps is what the platform actually offers.
                SettingChoice(Copy.subtitleSize, selection: $prefs.subtitleSize,
                              options: subtitleSizeOptions)
                SettingChoice(Copy.subtitleBackground, selection: $prefs.subtitleBackground,
                              options: SubtitleBackground.allCases.map { ($0, $0.label) })
            }
        }
        .onChange(of: prefs.subtitleSize) { _, _ in player.refreshSubtitleStyling() }
        .onChange(of: prefs.subtitleBackground) { _, _ in player.refreshSubtitleStyling() }
    }
}

private struct MusicSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        SettingsColumns(title: "Music", intro: SettingsView.intro(.music)) {
            SettingGroup(nil, page: .music) {
                SettingToggle(Copy.musicAutoplay, isOn: $prefs.musicAutoplay, isFirst: true)
                SettingToggle(Copy.normalizeVolume, isOn: $prefs.normalizeVolume)
            }
            SettingGroup("Stations", page: .music) {
                SettingToggle(Copy.musicRomanize, isOn: $prefs.musicRomanizeNames)
                SettingLink(Copy.stationMix, value: prefs.mixPoints.presetName) {
                    StationMixSettingsPage()
                }
            }
        }
    }
}

private struct LiveTVSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        SettingsColumns(title: "Live TV", intro: SettingsView.intro(.liveTV)) {
            SettingGroup(nil, page: .liveTV) {
                SettingChoice(Copy.liveTVSource, selection: $prefs.liveTVSource,
                              options: LiveTVSource.allCases.map { ($0, $0.label) }, isFirst: true)
            }

            if prefs.liveTVSource == .custom {
                SettingGroup("Playlist", symbol: "list.bullet.rectangle") {
                    SettingTextEntry(Copy.iptvPlaylist, text: $prefs.iptvPlaylistURL)
                    SettingTextEntry(Copy.iptvGuide, text: $prefs.iptvGuideURL)
                    SettingTextEntry(Copy.iptvUserAgent, text: $prefs.iptvUserAgent, emptyValue: "Default")
                    SettingChoice(Copy.iptvRefresh, selection: $prefs.iptvRefreshMinutes,
                                  options: SettingsView.iptvRefreshChoices.map { ($0.minutes, $0.label) })
                }
            }

            SettingGroup("", page: .liveTV) {
                SettingButton(Copy.refreshNow.name ?? "", notes: [Copy.refreshNow]) {
                    prefs.liveTVRefreshToken += 1
                    app.toast("Refreshing Live TV…", tone: .info)
                }
                if prefs.liveTVSource == .custom {
                    TVArtworkProbe()
                }
            }
        }
    }
}

/// The points stations are weighed by. Each dial's list stops at what the
/// budget has left, so spending on one is taking from another.
private struct StationMixSettingsPage: View {
    @Environment(Preferences.self) private var prefs

    private static let symbol = "slider.horizontal.3"

    var body: some View {
        let points = prefs.mixPoints
        let coverage = TagCoverage.recent
        var presets = MixPoints.presets.map { ($0.name, $0.name) }
        if points.presetName == MixPoints.customName { presets.append((MixPoints.customName, MixPoints.customName)) }
        return SettingsColumns(title: Copy.stationMix.name, intro: SettingDescription(
            title: Copy.stationMix.name ?? "", symbol: Self.symbol, tint: SettingsPage.music.tint, notes: [Copy.stationMix]
        )) {
            SettingGroup(nil, symbol: Self.symbol) {
                SettingChoice(Copy.mixPreset, selection: preset, options: presets, isFirst: true)
                SettingInfo("Points left", value: "\(points.remaining) of \(MixPoints.budget)",
                            notes: [SettingNote(text: Copy.mixPointsLeft(points)), Copy.stationMix])
            }
            SettingGroup("Points", symbol: Self.symbol) {
                ForEach(MixPoints.Dial.allCases) { dial in
                    SettingChoice(
                        Copy.mixDial(dial), selection: binding(dial),
                        options: (0...(points[dial] + points.remaining)).map { ($0, "\($0)") },
                        also: coverage.note(for: dial).map { [SettingNote(text: $0)] } ?? []
                    )
                }
            }
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

private struct LibraryCopySettingsPage: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        let index = LibraryIndex.shared
        SettingsColumns(title: "Library copy", intro: SettingDescription(
            title: "Library copy", symbol: SettingsPage.libraryCopy.symbol, tint: SettingsPage.libraryCopy.tint,
            notes: [Copy.libraryCopy]
        )) {
            SettingGroup(nil, page: .libraryCopy) {
                SettingToggle(Copy.libraryCopy, isOn: $prefs.keepsLibraryCopy, isFirst: true)
            }
            if prefs.keepsLibraryCopy {
                SettingGroup("", page: .libraryCopy) {
                    SettingInfo("Status", value: LibraryCopyText.status(index), notes: [Copy.libraryCopyStatus])
                    SettingInfo("Saved", value: LibraryCopyText.contents(index), notes: [Copy.libraryCopyContents])
                }
                SettingGroup("", page: .libraryCopy) {
                    SettingButton(Copy.syncNow.name ?? "", notes: [Copy.syncNow]) {
                        Task { await LibraryIndex.shared.sync(force: true) }
                    }
                    .disabled(index.isSyncing)
                    SettingButton(Copy.deleteCopy.name ?? "", role: .destructive, notes: [Copy.deleteCopy]) {
                        LibraryIndex.shared.wipe()
                    }
                }
            }
        }
        .onChange(of: prefs.keepsLibraryCopy) { _, on in LibraryIndex.shared.setEnabled(on) }
    }
}

private struct AboutSettingsPage: View {
    var body: some View {
        SettingsColumns(title: "About", intro: SettingDescription(
            title: "About", symbol: SettingsPage.about.symbol, tint: SettingsPage.about.tint, notes: [Copy.about]
        )) {
            SettingGroup(nil, page: .about) {
                SettingInfo("Aquarium", value: "\(Bundle.appVersion) (\(Bundle.appBuild))",
                            notes: [Copy.about], isFirst: true)
                SettingInfo("Playback engine", value: "AVFoundation", notes: [Copy.playbackEngine])
            }
        }
    }
}

// MARK: - The two columns

/// What the left-hand panel says: the setting's name and the sentences about
/// it.
struct SettingDescription: Equatable {
    var title: String
    var symbol: String
    /// The colour of the symbol — the page's, where the row belongs to one.
    var tint: Color?
    var paragraphs: [String]
    /// Set on a page's first row, whose arrival has to scroll the page all the
    /// way up rather than just far enough to show the row.
    var isFirst = false

    init(title: String, symbol: String, tint: Color? = nil, notes: [SettingNote], isFirst: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.paragraphs = notes.map(\.text)
        self.isFirst = isFirst
    }
}

/// The page's handler, boxed. A closure in the environment is stored as it
/// is, and SwiftUI cannot compare one update's closure with the last, so an
/// `@Entry` holding one invalidates every reader on every update. A box with
/// no stored properties to compare keeps that quiet.
private struct DescribeSettingKey: EnvironmentKey {
    static let defaultValue: (SettingDescription, Bool) -> Void = { _, _ in }
}

extension EnvironmentValues {
    /// Called by a row as it takes focus, and as it loses it. The page
    /// supplies it.
    var describeSetting: (SettingDescription, _ isFocused: Bool) -> Void {
        get { self[DescribeSettingKey.self] }
        set { self[DescribeSettingKey.self] = newValue }
    }
    /// The symbol of the group a row sits in, for the panel to draw.
    @Entry var settingSectionSymbol = "gearshape"
    /// The colour of that symbol: the group's page's, or the accent.
    @Entry var settingSectionTint: Color? = nil
}

/// A settings page: the panel on the left, the rows on the right.
private struct SettingsColumns<Rows: View>: View {
    /// Shown above the rows on a page opened from another; the first page has
    /// the tab strip to say where you are.
    var title: String?
    /// What the panel says before any row has focus.
    let intro: SettingDescription
    @ViewBuilder var rows: Rows

    @State private var described: SettingDescription?

    init(title: String? = nil, intro: SettingDescription, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.intro = intro
        self.rows = rows()
    }

    private static var topID: String { "settings-top" }

    /// Where the rows start, from the top of the screen: level with the panel.
    private static var listTop: CGFloat { 168 }

    /// The page's own background down to the bottom of the tab strip (about
    /// 113 points), then a short fade to nothing — laid over the rows rather
    /// than used to mask them.
    ///
    /// It was a mask, and masking a scroll view renders everything in it
    /// offscreen and composites it through the mask on every frame it moves.
    /// The background is one solid colour, so painting it over the top of the
    /// rows looks the same and costs a rectangle.
    private static var topCover: some View {
        VStack(spacing: 0) {
            Theme.background.frame(height: 120)
            LinearGradient(
                colors: [Theme.background, Theme.background.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 40)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            SettingDetailPanel(description: described ?? intro)
                .frame(width: 560)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.topID)
                        if let title {
                            Text(title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 28)
                                .padding(.top, 20)
                        }
                        rows
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 60)
                }
                // The tab strip floats over the page rather than above it, and
                // a scroll view's frame runs up underneath it whatever it is
                // told, so rows scrolled past the top were read through the
                // strip. The frame is pinned to the top of the screen on
                // purpose, the rows start where the panel does, and anything
                // above that fades out short of the strip — measured, not read
                // from the safe area, which reports zero here as often as not.
                .contentMargins(.top, Self.listTop, for: .scrollContent)
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .top) { Self.topCover }
                // What the mask also did: nothing drawn past the list's own
                // edges. A clip rectangle, which needs no offscreen pass.
                .clipped()
                .onChange(of: described) { _, new in
                    guard new?.isFirst == true else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.topID, anchor: .top)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .environment(\.describeSetting) { description, isFocused in
            if isFocused {
                described = description
            } else if described == description {
                // Focus has left the rows altogether — up to the tab strip, or
                // onto a page this one opened. Focus moving to the next row
                // replaces the description whichever order the two changes
                // arrive in, so this only sticks when nothing did.
                described = nil
            }
        }
    }
}

private struct SettingDetailPanel: View {
    let description: SettingDescription

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: description.symbol)
                .font(.system(size: 76, weight: .regular))
                .foregroundStyle(description.tint ?? Theme.accent)
                .frame(height: 96, alignment: .bottomLeading)

            Text(description.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(description.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.callout)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
        .animation(.easeOut(duration: 0.15), value: description)
    }
}

// MARK: - Groups and rows

private struct SettingGroup<Content: View>: View {
    /// Nil for no heading and no gap above — a page's first group; empty for
    /// the gap without a heading.
    let title: String?
    let symbol: String
    var tint: Color?
    @ViewBuilder var content: Content

    init(_ title: String?, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    /// A group of one page's rows: its symbol and colour in the panel.
    init(_ title: String?, page: SettingsPage, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = page.symbol
        self.tint = page.tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 28)
                    .padding(.top, title.isEmpty ? 24 : 40)
                    .padding(.bottom, title.isEmpty ? 0 : 10)
            } else {
                Spacer().frame(height: 24)
            }
            content
        }
        .environment(\.settingSectionSymbol, symbol)
        .environment(\.settingSectionTint, tint)
    }
}

/// What every row looks like: a name on the left, where it stands on the
/// right, and nothing behind it until the selector arrives — at which point it
/// turns white, the way a row does in the system's own Settings.
private struct SettingRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            configuration.label
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(isFocused ? Color.white : .clear)
                )
                .scaleEffect(isFocused ? 1.02 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: isFocused ? 12 : 0, y: isFocused ? 6 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// The inside of a row, coloured for whether it has focus.
private struct SettingRowLabel: View {
    let title: String
    var value: String?
    var tone: Color?
    var titleColour: Color?
    var chevron = false
    var checked = false

    @Environment(\.isFocused) private var isFocused

    private static let focusedText = Color(hex: 0x16161F)
    private static let focusedDim = Color(hex: 0x55556A)

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .foregroundStyle(isFocused ? Self.focusedText : (titleColour ?? Theme.text))
                .lineLimit(1)
            Spacer(minLength: 20)
            if let tone {
                Circle().fill(tone).frame(width: 12, height: 12)
            }
            if let value {
                Text(value)
                    .foregroundStyle(isFocused ? Self.focusedDim : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isFocused ? Self.focusedDim : Theme.textDim)
            }
            if checked {
                Image(systemName: "checkmark")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(isFocused ? Self.focusedText : Theme.accent)
            }
        }
    }
}

/// Tells the panel about a row when the row takes focus. Goes on a button's
/// label, which is where the button's focus can be read.
private struct DescribesSetting: ViewModifier {
    let title: String
    let notes: [SettingNote]
    var isFirst = false
    /// The page this row opens, whose symbol and colour the panel shows
    /// instead of the group's.
    var page: SettingsPage?

    @Environment(\.describeSetting) private var describe
    @Environment(\.settingSectionSymbol) private var sectionSymbol
    @Environment(\.settingSectionTint) private var sectionTint
    /// The focus of the button this label is inside. Not a `@FocusState` on
    /// the button: that one is never told when focus leaves for the tab strip,
    /// which left the panel describing a row nobody was on.
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused) { _, focused in
                describe(SettingDescription(title: title, symbol: page?.symbol ?? sectionSymbol,
                                            tint: page?.tint ?? sectionTint, notes: notes, isFirst: isFirst), focused)
            }
    }
}

private extension View {
    func describes(_ title: String, _ notes: [SettingNote], isFirst: Bool = false, page: SettingsPage? = nil) -> some View {
        modifier(DescribesSetting(title: title, notes: notes, isFirst: isFirst, page: page))
    }
}

/// A fact: selectable so it can be read about and so the page scrolls to it,
/// and pressing it does nothing, as with the About rows in the system's own
/// Settings.
private struct SettingInfo: View {
    let title: String
    let value: String
    var tone: Color?
    let notes: [SettingNote]
    var isFirst = false

    init(_ title: String, value: String, tone: Color? = nil, notes: [SettingNote], isFirst: Bool = false) {
        self.title = title
        self.value = value
        self.tone = tone
        self.notes = notes
        self.isFirst = isFirst
    }

    var body: some View {
        Button {} label: {
            SettingRowLabel(title: title, value: value, tone: tone)
                .describes(title, notes, isFirst: isFirst)
        }
        .buttonStyle(SettingRowStyle())
    }
}

private struct SettingButton: View {
    let title: String
    var role: ButtonRole?
    let notes: [SettingNote]
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, notes: [SettingNote], action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.notes = notes
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingRowLabel(title: title, titleColour: role == .destructive ? Theme.danger : Theme.accent)
                .describes(title, notes)
        }
        .buttonStyle(SettingRowStyle())
    }
}

/// A switch, drawn as the system's Settings draws one: the row says On or Off,
/// and pressing it flips.
private struct SettingToggle: View {
    let note: SettingNote
    @Binding var isOn: Bool
    var also: [SettingNote]
    var isFirst: Bool

    init(_ note: SettingNote, isOn: Binding<Bool>, also: [SettingNote] = [], isFirst: Bool = false) {
        self.note = note
        self._isOn = isOn
        self.also = also
        self.isFirst = isFirst
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            SettingRowLabel(title: note.name ?? "", value: isOn ? "On" : "Off")
                .describes(note.name ?? "", [note] + also, isFirst: isFirst)
        }
        .buttonStyle(SettingRowStyle())
    }
}

/// A row that opens a page of its own.
private struct SettingLink<Destination: View>: View {
    let note: SettingNote
    var value: String?
    /// The page the row opens, when it is one of the map's: its tile in the
    /// panel while the selector rests here.
    var page: SettingsPage?
    var isFirst = false
    let destination: () -> Destination

    init(_ note: SettingNote, value: String? = nil, page: SettingsPage? = nil, isFirst: Bool = false,
         @ViewBuilder destination: @escaping () -> Destination) {
        self.note = note
        self.value = value
        self.page = page
        self.isFirst = isFirst
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination) {
            SettingRowLabel(title: note.name ?? "", value: value, chevron: true)
                .describes(note.name ?? "", [note], isFirst: isFirst, page: page)
        }
        .buttonStyle(SettingRowStyle())
    }
}

/// One of a list: the row shows the current choice, and opens the list.
private struct SettingChoice<Value: Hashable>: View {
    let note: SettingNote
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var also: [SettingNote]
    var isFirst: Bool

    init(_ note: SettingNote, selection: Binding<Value>, options: [(Value, String)],
         also: [SettingNote] = [], isFirst: Bool = false) {
        self.note = note
        self._selection = selection
        self.options = options.map { (value: $0.0, label: $0.1) }
        self.also = also
        self.isFirst = isFirst
    }

    @Environment(\.settingSectionSymbol) private var symbol

    var body: some View {
        NavigationLink {
            SettingChoiceList(
                description: SettingDescription(title: note.name ?? "", symbol: symbol, notes: [note] + also),
                selection: $selection,
                options: options
            )
        } label: {
            SettingRowLabel(
                title: note.name ?? "",
                value: options.first { $0.value == selection }?.label,
                chevron: true
            )
                .describes(note.name ?? "", [note] + also, isFirst: isFirst)
        }
        .buttonStyle(SettingRowStyle())
    }
}

/// The page a choice opens onto: the setting described on the left, and the
/// options with a tick against the current one. Picking one goes straight back.
private struct SettingChoiceList<Value: Hashable>: View {
    let description: SettingDescription
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            SettingDetailPanel(description: description)
                .frame(width: 560)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button {
                            selection = option.value
                            dismiss()
                        } label: {
                            SettingRowLabel(title: option.label, checked: option.value == selection)
                        }
                        .buttonStyle(SettingRowStyle())
                        .focused($focused, equals: index)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .defaultFocus($focused, options.firstIndex { $0.value == selection } ?? 0)
    }
}

/// A line of text — a URL, a user agent. The row shows what is set; pressing
/// it asks for a new one.
private struct SettingTextEntry: View {
    let note: SettingNote
    @Binding var text: String
    var emptyValue: String

    @State private var isEditing = false
    @State private var draft = ""

    init(_ note: SettingNote, text: Binding<String>, emptyValue: String = "Not set") {
        self.note = note
        self._text = text
        self.emptyValue = emptyValue
    }

    var body: some View {
        Button {
            draft = text
            isEditing = true
        } label: {
            SettingRowLabel(title: note.name ?? "", value: text.isEmpty ? emptyValue : text, chevron: true)
                .describes(note.name ?? "", [note])
        }
        .buttonStyle(SettingRowStyle())
        .alert(note.name ?? "", isPresented: $isEditing) {
            // The system keyboard is titled with this, so it names the setting.
            TextField(note.name ?? "", text: $draft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") { text = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// "Why is the channel column empty?", answered on the device that is asking —
/// see `ArtworkProbeRow` on the other platforms. The report is printed under
/// the row; what the playlist produced last time it was read is in the panel.
private struct TVArtworkProbe: View {
    @State private var results: [ArtworkProbe.Result] = []
    @State private var isRunning = false
    @State private var hasRun = false

    private var notes: [SettingNote] {
        var notes = [Copy.artworkProbe]
        if let summary = LiveTVStore.shared.summary {
            notes.append(SettingNote(text: "Last read: " + SettingsView.playlistSummary(summary) + "."))
        }
        return notes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                Task { await run() }
            } label: {
                SettingRowLabel(
                    title: hasRun ? "Check channel artwork again" : "Check channel artwork",
                    value: isRunning ? "Checking…" : nil,
                    titleColour: Theme.accent
                )
                    .describes(Copy.artworkProbe.name ?? "", notes)
            }
            .buttonStyle(SettingRowStyle())
            .disabled(isRunning)

            if hasRun, results.isEmpty {
                Text(SettingsView.noChannelsYet)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 28)
            }

            ForEach(results) { ArtworkProbeResultView(result: $0) }
                .padding(.horizontal, 28)
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
