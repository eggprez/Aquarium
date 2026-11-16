//  Settings (every platform), sign-in, Quick Connect, Live TV and the guide.
//
//  Keys used here:
//  - a settings page: `SettingsPage.rawValue` — "account", "appearance",
//    "video", "audio", "subtitles", "music", "liveTV", "downloads",
//    "libraryCopy", "watch", "about" — plus the pages a page opens,
//    "stationMix" and "customPlaylist", and the Mac's two tabs with no page of
//    their own, "general" and "storage" (`MacSettingsPane.rawValue`).
//  - an account: `SavedSession.accountKey` ("<server>|<user id>").
//  - a server on the sign-in screen: its address as listed.
//  - a channel, a programme: its Jellyfin (or playlist) id.
//
//  A settings row is named for the preference it controls and the page of the
//  shared map (`SettingsPage`) that preference belongs to, wherever a platform
//  happens to draw it: `settings.audio.language` is on the Video tab on a Mac
//  and the Video page on an Apple TV, and is still `settings.audio.language`.
//  The Apple TV's rows reuse these names; `TVSettings` holds only what a
//  television alone has.

import Foundation

extension TestID {
    // MARK: - Settings

    enum Settings {
        /// The first page: the list of pages on a phone, an iPad and an Apple
        /// TV; the whole form on a Mac when it is not drawn as tabs.
        static let root = "settings.root"
        /// The Mac's Settings window (the tab view).
        static let window = "settings.window.root"
        /// One page (or Mac tab) of settings, by page key.
        static func pageRoot(_ page: String) -> String { "settings.\(page).root" }
        /// The first page's row that opens a page, by page key.
        static func pageLink(_ page: String) -> String { "settings.page.\(page)" }
        /// One option of a picker row: the row's own name, then the option's
        /// raw value — `settings.appearance.theme.dark`. An empty raw value
        /// (the "file's choice" language) is `<row>.`.
        static func option(_ row: String, _ key: String) -> String { "\(row).\(key)" }
        /// The text beside a slider or stepper row that shows what is set.
        static func value(_ row: String) -> String { "\(row).value" }

        /// iPad, two columns: the list of pages, and the heading over the
        /// page beside it.
        static let splitList = "settings.split.list"
        static let splitPageTitle = "settings.split.pageTitle"

        // General
        static let cloudSync = "settings.general.cloudSync"
        /// What stands in for the iCloud switch's sentence when iCloud can't
        /// be used (the Apple TV's row; the footer elsewhere).
        static let cloudUnavailable = "settings.general.cloudUnavailable"

        // Account: the facts about the connection. Each is the value shown.
        static let accountSignedInAs = "settings.account.signedInAs"
        static let accountServer = "settings.account.server"
        static let accountConnection = "settings.account.connection"
        static let accountIdentity = "settings.account.identity"
        static let accountAccessToken = "settings.account.accessToken"
        static let accountStatus = "settings.account.status"
        static let accountNotConnected = "settings.account.notConnected"
        static let signOut = "settings.account.signOut"
        static let signOutBusy = "settings.account.signOutBusy"
        /// The confirmation dialog's two buttons.
        static let signOutConfirm = "settings.account.signOutConfirm"
        static let signOutCancel = "settings.account.signOutCancel"

        // Accounts on this device
        /// The Mac's table of accounts.
        static let accountsList = "settings.accounts.list"
        /// An account's row: tap (or select, on a Mac) to switch to it.
        static func account(_ key: String) -> String { "settings.accounts.account.\(key)" }
        /// The Mac's "Signed In" beside the account in use.
        static func accountSignedInMark(_ key: String) -> String { "settings.accounts.signedInMark.\(key)" }
        static func accountSwitching(_ key: String) -> String { "settings.accounts.switching.\(key)" }
        /// "Switch to <name>": the Mac's context menu, the Apple TV's dialog.
        static func accountSwitch(_ key: String) -> String { "settings.accounts.switch.\(key)" }
        /// "Sign Out of This Device": context menu, swipe action, the Apple
        /// TV's dialog.
        static func accountRemove(_ key: String) -> String { "settings.accounts.remove.\(key)" }
        static let addAccount = "settings.accounts.add"
        /// The Mac's − and Switch buttons, which act on the selected row.
        static let removeSelectedAccount = "settings.accounts.removeSelected"
        static let switchSelectedAccount = "settings.accounts.switchSelected"
        static let removeAccountConfirm = "settings.accounts.removeConfirm"
        static let removeAccountCancel = "settings.accounts.removeCancel"

        // Appearance (General on a Mac and an Apple TV)
        static let theme = "settings.appearance.theme"
        static let appIcon = "settings.appearance.appIcon"
        static let tabBar = "settings.appearance.tabBar"
        static let hideContinueWatching = "settings.appearance.hideContinueWatching"
        static let clearAbandoned = "settings.appearance.clearAbandoned"
        static let nextUpDays = "settings.appearance.nextUpDays"
        static let nextUpInProgress = "settings.appearance.nextUpInProgress"
        static let nextUpRewatching = "settings.appearance.nextUpRewatching"

        // Video
        /// Default quality. Options: "auto", "0" (Direct Play), or the rung's
        /// bitrate.
        static let videoQuality = "settings.video.quality"
        static let videoPowerAwareQuality = "settings.video.powerAwareQuality"
        static let videoSpeedCheck = "settings.video.speedCheck"
        /// Options: "fit", "fill".
        static let videoFraming = "settings.video.framing"
        static let videoBrightness = "settings.video.brightness"
        static let videoContrast = "settings.video.contrast"
        static let videoSaturation = "settings.video.saturation"
        static let videoGamma = "settings.video.gamma"
        static let videoZoom = "settings.video.zoom"
        /// Options keyed by the ratio ("0.0" is the file's own).
        static let videoAspect = "settings.video.aspect"
        static let videoResetPicture = "settings.video.resetPicture"
        static let videoNightMode = "settings.video.nightMode"
        static let videoEngine = "settings.video.engine"
        static let videoBatterySaver = "settings.video.batterySaver"
        static let videoSkipInterval = "settings.video.skipInterval"
        static let videoHideControlsAfter = "settings.video.hideControlsAfter"
        static let videoShowsRemainingTime = "settings.video.showsRemainingTime"
        static let videoResume = "settings.video.resume"
        static let videoAutoplayNext = "settings.video.autoplayNext"

        // Audio
        /// Options keyed by language code.
        static let audioLanguage = "settings.audio.language"
        static let audioDownmix = "settings.audio.downmix"
        /// The Mac's one delay, options keyed by milliseconds. The Apple TV
        /// has a row a frame rate: `TVSettings.audioDelay`.
        static let audioDelay = "settings.audio.delay"
        /// The phone's "Measure Apple TV sync" link.
        static let audioMeasureSync = "settings.audio.measureSync"

        // Subtitles
        /// Options: a language code, "off", the forced-only value, or empty.
        static let subtitlesLanguage = "settings.subtitles.language"
        static let subtitlesForcedOnly = "settings.subtitles.forcedOnly"
        static let subtitlesSize = "settings.subtitles.size"
        static let subtitlesBackground = "settings.subtitles.background"

        // Music
        static let musicAutoplay = "settings.music.autoplay"
        static let musicNormalizeVolume = "settings.music.normalizeVolume"
        static let musicLosslessOnCellular = "settings.music.losslessOnCellular"
        static let musicMixSource = "settings.music.mixSource"
        static let musicRomanize = "settings.music.romanize"
        /// The row that opens the Station mix page.
        static let musicStationMix = "settings.music.stationMix"

        // Station mix (a section of Music on a Mac, a page elsewhere)
        /// Options keyed by `TestID.key(<preset name>)`.
        static let stationMixPreset = "settings.stationMix.preset"
        /// A dial's stepper (a list of numbers on an Apple TV), by
        /// `MixPoints.Dial.rawValue`.
        static func stationMixDial(_ dial: String) -> String { "settings.stationMix.dial.\(dial)" }
        /// The warning under a dial the library's tags can't serve.
        static func stationMixDialWarning(_ dial: String) -> String { "settings.stationMix.dialWarning.\(dial)" }
        /// "N of M points left".
        static let stationMixPointsLeft = "settings.stationMix.pointsLeft"

        // Live TV
        static let liveTVSource = "settings.liveTV.source"
        /// The phone's row that opens the Custom playlist page.
        static let liveTVCustomPlaylist = "settings.liveTV.customPlaylist"
        static let liveTVPlaylistURL = "settings.liveTV.playlistURL"
        static let liveTVGuideURL = "settings.liveTV.guideURL"
        static let liveTVUserAgent = "settings.liveTV.userAgent"
        /// Options keyed by minutes.
        static let liveTVRefreshInterval = "settings.liveTV.refreshInterval"
        static let liveTVRefreshNow = "settings.liveTV.refreshNow"
        /// "Last read: …", what the playlist produced.
        static let liveTVPlaylistSummary = "settings.liveTV.playlistSummary"
        /// The channel-artwork check: its button, spinner, the "no channels
        /// yet" line, and a line of its report by `TestID.key(<channel>)`.
        static let liveTVArtworkCheck = "settings.liveTV.artworkCheck"
        static let liveTVArtworkBusy = "settings.liveTV.artworkBusy"
        static let liveTVArtworkEmpty = "settings.liveTV.artworkEmpty"
        static func liveTVArtworkResult(_ channel: String) -> String { "settings.liveTV.artworkResult.\(channel)" }

        // Downloads (Storage on a Mac)
        /// Options keyed by `TestID.key(<quality label>)`.
        static let downloadsQuality = "settings.downloads.quality"
        static let downloadsConcurrency = "settings.downloads.concurrency"
        static let downloadsWifiOnly = "settings.downloads.wifiOnly"
        static let downloadsShowInFinder = "settings.downloads.showInFinder"

        // Library copy (Storage on a Mac)
        static let libraryCopyKeep = "settings.libraryCopy.keep"
        static let libraryCopyStatus = "settings.libraryCopy.status"
        static let libraryCopyContents = "settings.libraryCopy.contents"
        static let libraryCopySyncNow = "settings.libraryCopy.syncNow"
        static let libraryCopySyncBusy = "settings.libraryCopy.syncBusy"
        static let libraryCopyDelete = "settings.libraryCopy.delete"
        static let libraryCopyDeleteConfirm = "settings.libraryCopy.deleteConfirm"
        static let libraryCopyDeleteCancel = "settings.libraryCopy.deleteCancel"

        // About
        static let aboutVersion = "settings.about.version"
        static let aboutEngine = "settings.about.engine"
        static let aboutText = "settings.about.text"
    }

    // MARK: - TVSettings

    /// What only the Apple TV's Settings has. Its rows are otherwise the
    /// `Settings` names, and its pages `Settings.pageRoot(<page>)`.
    enum TVSettings {
        /// The panel on the left: the title of whatever the selector is on.
        static let panel = "tvSettings.panel.root"
        static let panelTitle = "tvSettings.panel.title"
        /// The heading over a pushed page's rows.
        static let pageTitle = "tvSettings.page.title"

        /// The list a choice row opens.
        static let choiceList = "tvSettings.choice.root"
        /// One option in that list, by `String(describing:)` of its value:
        /// an enum's case name, a number ("30", "1.5"), "true"/"false", a
        /// language code, or "Optional(…)"/"nil" for the quality's bitrate.
        static func choiceOption(_ value: String) -> String { "tvSettings.choice.option.\(value)" }

        /// The audio delay row for one frame rate (24, 25, 30, 50, 60); it
        /// opens the sync test.
        static func audioDelay(_ fps: Int) -> String { "tvSettings.audio.delay.\(fps)" }
        /// The flashing-images warning before the sync test: Play the test.
        static let syncTestPlay = "tvSettings.syncTest.play"
        /// The flashing-images warning before the sync test: Cancel.
        static let syncTestCancel = "tvSettings.syncTest.cancel"

        /// The alert a text row (a playlist address, a user agent) opens: its
        /// field, Save and Cancel. The row itself is its `Settings` name.
        static let textEntryField = "tvSettings.textEntry.field"
        static let textEntrySave = "tvSettings.textEntry.save"
        static let textEntryCancel = "tvSettings.textEntry.cancel"

        /// The dialog a press on another account opens: its Cancel. Switch
        /// and Sign Out are `Settings.accountSwitch` / `accountRemove`.
        static let accountActionsCancel = "tvSettings.accounts.actionsCancel"
    }

    // MARK: - WatchSettings

    /// Settings → Apple Watch on the phone, and the pages it opens.
    enum WatchSettings {
        static let root = "watchSettings.root"
        /// The card at the top: one combined element (title, detail, reach).
        static let statusCard = "watchSettings.status.card"
        static let kept = "watchSettings.row.kept"
        static let storage = "watchSettings.row.storage"
        static let transfers = "watchSettings.row.transfers"
        static let diagnostics = "watchSettings.row.diagnostics"
        static let syncNow = "watchSettings.sync.now"
        static let pendingEvents = "watchSettings.history.pending"
        static let lastForwarded = "watchSettings.history.lastForwarded"
        static let forwardNow = "watchSettings.history.forwardNow"
        static let sendSignIn = "watchSettings.support.sendSignIn"

        // Kept on the watch
        static let keptRoot = "watchSettings.kept.root"
        /// A row of the Sent list, by want id; its swipe action.
        static func want(_ id: String) -> String { "watchSettings.kept.want.\(id)" }
        static func wantRemove(_ id: String) -> String { "watchSettings.kept.wantRemove.\(id)" }
        static let keptSyncNow = "watchSettings.kept.syncNow"
        static let keepsBooks = "watchSettings.kept.books"
        /// "Loading playlists…" / "No playlists on this server."
        static let playlistsEmpty = "watchSettings.kept.playlistsEmpty"
        static func playlist(_ id: String) -> String { "watchSettings.kept.playlist.\(id)" }

        // Storage on the watch
        static let storageRoot = "watchSettings.storage.root"
        static let storageTotal = "watchSettings.storage.total"
        static let storageFree = "watchSettings.storage.free"
        static let storageInFlight = "watchSettings.storage.inFlight"
        /// One thing on the watch, by group id; its swipe action.
        static func storageGroup(_ id: String) -> String { "watchSettings.storage.group.\(id)" }
        static func storageGroupRemove(_ id: String) -> String { "watchSettings.storage.groupRemove.\(id)" }
        static let storageRemoveAll = "watchSettings.storage.removeAll"
        static let storageRemoveAllConfirm = "watchSettings.storage.removeAllConfirm"
        static let storageWaiting = "watchSettings.storage.waiting"

        // Transfers
        static let transfersRoot = "watchSettings.transfers.root"
        static let transfersEmpty = "watchSettings.transfers.empty"
        /// One transfer's row (a combined element), by relay item id, and
        /// its Cancel: the button in the row and the swipe action.
        static func transfer(_ id: String) -> String { "watchSettings.transfers.item.\(id)" }
        static func transferCancel(_ id: String) -> String { "watchSettings.transfers.cancel.\(id)" }
        static let transfersCancelAll = "watchSettings.transfers.cancelAll"
        static let transfersCancelAllConfirm = "watchSettings.transfers.cancelAllConfirm"
        static let transfersClearFailed = "watchSettings.transfers.clearFailed"

        // Diagnostics
        static let diagnosticsRoot = "watchSettings.diagnostics.root"
        static let fetchWatchLog = "watchSettings.diagnostics.fetchWatchLog"
        static let savePhoneLog = "watchSettings.diagnostics.savePhoneLog"
        /// A saved log's share row, by file name; its swipe action.
        static func log(_ fileName: String) -> String { "watchSettings.diagnostics.log.\(fileName)" }
        static func logDelete(_ fileName: String) -> String { "watchSettings.diagnostics.logDelete.\(fileName)" }
    }

    // MARK: - TabBarSettings

    /// Settings → Tab Bar (Sidebar on an iPad).
    enum TabBarSettings {
        static let root = "tabBarSettings.root"
        /// Home, which is always first and can't be moved.
        static let home = "tabBarSettings.row.home"
        /// A section's row, by `AppSection.id`. Drag it to reorder.
        static func row(_ section: String) -> String { "tabBarSettings.row.\(section)" }
        /// "Tab bar" or "More" at the end of that row.
        static func placement(_ section: String) -> String { "tabBarSettings.placement.\(section)" }
        static let reset = "tabBarSettings.toolbar.reset"
    }

    // MARK: - AppIconSettings

    /// Settings → App Icon.
    enum AppIconSettings {
        static let root = "appIconSettings.root"
        /// A shelf of icons, by `TestID.key(<its heading>)`.
        static func shelf(_ key: String) -> String { "appIconSettings.shelf.\(key)" }
        /// An icon's tile, by `AppIconChoice.id` (the icon's name; "AppIcon"
        /// for the original). Selected when it is the one in use.
        static func icon(_ name: String) -> String { "appIconSettings.icon.\(name)" }
    }

    // MARK: - Login

    /// The sign-in screen, as the whole window or as the add-account sheet.
    enum Login {
        static let root = "login.root"
        /// The card (the Mac's form) holding the fields.
        static let form = "login.form.root"

        // The server
        static let serverField = "login.server.field"
        static let connect = "login.server.connect"
        /// A server found on the network, by address. On a Mac the row's name
        /// carries it: click to fill the field, double-click to connect.
        static func discoveredServer(_ address: String) -> String { "login.server.discovered.\(address)" }
        /// A server signed in to before, by address.
        static func knownServer(_ address: String) -> String { "login.server.known.\(address)" }
        /// The spinner shown while the network is still being searched.
        static let discovering = "login.server.discovering"
        /// The Mac's context-menu Connect on a server row.
        static let serverMenuConnect = "login.server.menuConnect"

        // What the server answered
        static let serverBanner = "login.banner.root"
        static let serverName = "login.banner.name"
        /// "Jellyfin <version> · <address>".
        static let serverDetail = "login.banner.detail"
        /// HTTPS/HTTP (Encrypted/Not Encrypted on a Mac).
        static let serverSecurity = "login.banner.security"
        static let serverInsecureWarning = "login.banner.insecureWarning"
        /// "Use a different server": back to the address field.
        static let differentServer = "login.banner.differentServer"

        // Signing in
        static let username = "login.credentials.username"
        static let password = "login.credentials.password"
        static let signIn = "login.credentials.signIn"
        /// One of the server's users, by user id: fills the name in (and
        /// signs straight in where there is no password).
        static func user(_ id: String) -> String { "login.users.user.\(id)" }
        /// The Mac's context-menu "Sign In as …" on a user row.
        static let userMenuSignIn = "login.users.menuSignIn"
        static let error = "login.status.error"
        /// The Mac's spinner beside the buttons.
        static let busy = "login.status.busy"
        /// The add-account sheet's Cancel.
        static let cancel = "login.sheet.cancel"

        // Quick Connect
        /// "Sign in with a Quick Connect code instead" and its way back, on
        /// a phone, an iPad and an Apple TV: one button that flips.
        static let modeSwitch = "login.mode.switch"
        /// The Mac's Password / Quick Connect segmented control, and its
        /// segments ("password", "quickConnect").
        static let modePicker = "login.mode.picker"
        static func modeOption(_ mode: String) -> String { "login.mode.option.\(mode)" }
        static let quickConnectPanel = "login.quickConnect.root"
        /// The six-digit code. Its label reads the digits apart.
        static let quickConnectCode = "login.quickConnect.code"
        /// The spinner while a code is being asked for.
        static let quickConnectLoading = "login.quickConnect.loading"
        static let quickConnectWaiting = "login.quickConnect.waiting"
        static let quickConnectExpired = "login.quickConnect.expired"
        static let quickConnectNewCode = "login.quickConnect.newCode"
        /// The Mac's Copy Code.
        static let quickConnectCopy = "login.quickConnect.copy"

        // Accounts already on this device ("Who's watching?")
        static let accounts = "login.accounts.root"
        /// A saved account, by account key: continue as them.
        static func account(_ key: String) -> String { "login.accounts.account.\(key)" }
        /// The Mac's Continue button and context-menu "Continue as …".
        static let accountContinue = "login.accounts.continue"
        static let accountMenuContinue = "login.accounts.menuContinue"
    }

    // MARK: - QuickConnect

    /// Settings → Account → Quick Connect: approving another device's code.
    enum QuickConnect {
        static let codeField = "quickConnect.approve.code"
        static let approve = "quickConnect.approve.button"
        static let busy = "quickConnect.approve.busy"
        /// The confirmation dialog's two buttons.
        static let confirm = "quickConnect.approve.confirm"
        static let cancel = "quickConnect.approve.cancel"
        /// What came of it: the pill (Approved / Not approved) and the line.
        static let outcome = "quickConnect.outcome.pill"
        static let outcomeText = "quickConnect.outcome.text"
    }

    // MARK: - LiveTV

    /// The Live TV screen around the guide. Channels and programmes are the
    /// guide's: `Guide.channel`, `Guide.programme`.
    enum LiveTV {
        static let root = "liveTV.root"
        /// The phone's and iPad's own heading.
        static let title = "liveTV.header.title"
        static let loading = "liveTV.state.loading"
        static let error = "liveTV.state.error"
        static let empty = "liveTV.state.empty"
        /// The Mac's toolbar Refresh.
        static let refresh = "liveTV.toolbar.refresh"
    }

    // MARK: - Guide

    enum Guide {
        static let root = "guide.root"
        /// The spinner while programmes load.
        static let loading = "guide.status.loading"
        /// A channel's cell in the column down the left: press to tune.
        static func channel(_ id: String) -> String { "guide.channel.cell.\(id)" }
        /// A programme's cell, by programme id: press to tune its channel.
        static func programme(_ id: String) -> String { "guide.programme.cell.\(id)" }
        /// The one cell a channel with no guide data has, by channel id.
        static func noProgramme(_ channelId: String) -> String { "guide.programme.none.\(channelId)" }
        /// A half-hour mark on the time ruler, by position (0 = the left).
        static func timeMark(_ index: Int) -> String { "guide.ruler.mark.\(index)" }

        /// "Guide unavailable": the strip over the grid, its message, Retry.
        static let errorBanner = "guide.error.banner"
        static let errorMessage = "guide.error.message"
        static let errorRetry = "guide.error.retry"
        /// The Mac's whole-grid "Guide Unavailable" and its Retry.
        static let unavailable = "guide.error.unavailable"
        static let unavailableRetry = "guide.error.unavailableRetry"
        /// Nothing in the channel list matches the Mac's filter.
        static let noMatches = "guide.state.noMatches"

        // The Mac's toolbar and header
        static let earlier = "guide.toolbar.earlier"
        static let now = "guide.toolbar.now"
        static let later = "guide.toolbar.later"
        static let datePicker = "guide.toolbar.date"
        /// "More Hours" at the end of the ruler.
        static let moreHours = "guide.ruler.moreHours"

        // The Mac's programme popover (Show Info, or the space bar)
        static let info = "guide.info.root"
        static let infoTitle = "guide.info.title"
        static let infoEpisode = "guide.info.episode"
        static let infoTime = "guide.info.time"
        static let infoChannel = "guide.info.channel"
        static let infoOverview = "guide.info.overview"
        static let infoPlay = "guide.info.play"

        // The Mac's context menu on a cell
        static let menuPlay = "guide.menu.play"
        static let menuInfo = "guide.menu.info"
        static let menuCopyTitle = "guide.menu.copyTitle"
    }
}
