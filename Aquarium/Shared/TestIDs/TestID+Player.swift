//  The video player's names, on every platform: the screen and the picture,
//  the title row, the centre cluster, the timeline, the pills, the cards the
//  pills drop, the panel (a sheet or popover on an iPhone, iPad or Mac; the
//  swipe-down panel with its row of tabs on an Apple TV), the moment
//  overlays, the half-folded panel, the Mac window, its inspector and its
//  menus, and the two sync screens.
//
//  One logical control has one name wherever it is drawn. An audio track is
//  `player.audio.option.<id>` in the phone's Audio card and on the Apple TV's
//  Audio tab alike; play/pause is `player.transport.playPause` over the
//  picture and below the fold. What differs is the container: a card is
//  `player.card.<menu>`, the panel `player.panel.root`.
//
//  The controls over the picture are taken out of the hierarchy when they
//  hide, so a test brings them up (a tap on `player.video`) before looking.

import Foundation

extension TestID {
    enum Player {
        // MARK: The screen

        /// The player screen itself, on every platform.
        static let root = "player.root"
        /// The picture: the engine's layer in its host view. Tap it to bring
        /// the controls up or put them away.
        static let video = "player.video"
        /// The Apple TV's remote-reading view, which holds focus while no
        /// panel or card is up.
        static let remoteInput = "player.tv.remoteInput"
        /// The Mac's player window content (the screen, or black while idle).
        static let window = "player.window.root"
        /// The transport over the picture while it is up: the title row,
        /// cluster and bottom band on iPhone, iPad and Mac; the band along
        /// the bottom on an Apple TV. Absent while the controls are hidden.
        static let controls = "player.controls.root"

        // MARK: Title row

        /// The title and the line under it, as one element. On an Apple TV
        /// it is the heading in the bottom band.
        static let title = "player.top.title"
        static let back = "player.top.back"
        static let airPlay = "player.top.airPlay"
        static let pictureInPicture = "player.top.pictureInPicture"
        /// The "…" button, which drops the More card.
        static let more = "player.top.more"

        // MARK: Transport

        /// Play/pause. Its label reads "Loading" while the stream buffers.
        static let playPause = "player.transport.playPause"
        static let skipBack = "player.transport.skipBack"
        static let skipForward = "player.transport.skipForward"
        static let channelPrevious = "player.transport.channelPrevious"
        static let channelNext = "player.transport.channelNext"

        // MARK: Timeline

        /// The whole bar, an adjustable element whose value is the position.
        static let scrubber = "player.timeline.scrubber"
        static let elapsed = "player.timeline.elapsed"
        /// The right-hand time: remaining or total. A button that flips it.
        static let remaining = "player.timeline.remaining"
        /// The trickplay thumbnail and time that ride above a scrub.
        static let scrubPreview = "player.timeline.preview"
        /// A channel's timeline: how far through the programme on now.
        static let liveTimeline = "player.timeline.live"
        /// The Apple TV band's line saying what the remote does.
        static let remoteHint = "player.tv.hint"

        // MARK: Pills

        /// The row of pills under the timeline.
        static let pillRow = "player.pill.row"
        /// `player.pill.<key>`: info, channels, audio, subtitles, quality,
        /// upNext, fill.
        static func pill(_ key: String) -> String { "player.pill.\(key)" }
        static let pillInfo = pill("info")
        static let pillChannels = pill("channels")
        static let pillAudio = pill("audio")
        static let pillSubtitles = pill("subtitles")
        static let pillQuality = pill("quality")
        static let pillUpNext = pill("upNext")
        static let pillFill = pill("fill")

        // MARK: Cards (iPhone, iPad, Mac)

        /// The open card: `player.card.<audio|subtitles|quality|upNext|more>`.
        static func card(_ key: String) -> String { "player.card.\(key)" }
        static let cardAudio = card("audio")
        static let cardSubtitles = card("subtitles")
        static let cardQuality = card("quality")
        static let cardUpNext = card("upNext")
        static let cardMore = card("more")
        /// The close button in whichever card is open.
        static let cardClose = "player.card.close"

        // MARK: Audio and subtitles (cards, and the Apple TV's tabs)

        /// The key for a track: its `TrackOption.id`.
        static func trackKey(_ id: Int) -> String { String(id) }
        static func audioOption(_ key: String) -> String { "player.audio.option.\(key)" }
        /// The sentence shown when the stream lists no audio tracks.
        static let audioEmpty = "player.audio.empty"
        static let audioLanguagePicker = "player.audio.preferredLanguage"
        /// A subtitle track by `trackKey`, or `subtitlesOffKey`.
        static func subtitleOption(_ key: String) -> String { "player.subtitles.option.\(key)" }
        static let subtitlesOffKey = "off"
        static let subtitlesOff = subtitleOption(subtitlesOffKey)
        static let subtitlesEmpty = "player.subtitles.empty"
        static let subtitleLanguagePicker = "player.subtitles.preferredLanguage"
        /// A download's subtitle file drawn by the app over the picture.
        /// Present only while one is being drawn; its text is not readable.
        static let subtitleOverlay = "player.subtitles.overlay"

        // MARK: Quality

        /// The key for a rung: its bitrate in bits per second, or
        /// `qualityOriginalKey` for Direct.
        static func qualityKey(_ maxBitrate: Int?) -> String {
            maxBitrate.map(String.init) ?? qualityOriginalKey
        }
        static let qualityAutoKey = "auto"
        static let qualityOriginalKey = "original"
        static let qualityDownloadedKey = "downloaded"
        /// `player.quality.option.<auto|downloaded|original|bitrate>`.
        static func qualityOption(_ key: String) -> String { "player.quality.option.\(key)" }
        static let qualityAuto = qualityOption(qualityAutoKey)
        static let qualityDownloaded = qualityOption(qualityDownloadedKey)
        /// The sentence saying why quality can't be chosen for this stream.
        static let qualityUnavailable = "player.quality.unavailable"
        /// The paragraph explaining Auto.
        static let qualityNote = "player.quality.note"

        // MARK: Up Next

        /// A queued or upcoming title, by Jellyfin item id (a download's by
        /// its record's item id).
        static func upNextItem(_ id: String) -> String { "player.upNext.item.\(id)" }
        static let upNextClear = "player.upNext.clear"

        // MARK: Speed, sleep, the rest of the More card

        /// The key for a speed: the rate in hundredths, `100` for normal,
        /// `125` for 1.25×.
        static func speedKey(_ rate: Double) -> String { String(Int((rate * 100).rounded())) }
        static func speedOption(_ key: String) -> String { "player.speed.option.\(key)" }
        /// The sentence saying a live channel has no speed.
        static let speedUnavailable = "player.speed.unavailable"
        /// Start a sleep timer of this many minutes.
        static func sleepOption(_ minutes: Int) -> String { "player.sleep.option.\(minutes)" }
        /// The row shown while a timer runs; choosing it cancels the timer.
        static let sleepCancel = "player.sleep.cancel"
        /// Stop after this episode / let the next one play: the More card's
        /// "After this" row and the Apple TV Info tab's Autoplay card.
        static let stopAfterThis = "player.afterThis.stop"
        /// The More card's row that opens the channel line-up.
        static let moreChannels = "player.more.channels"
        static let sharePlayStart = "player.more.sharePlay"
        static let sharePlayLeave = "player.more.sharePlayLeave"

        // MARK: The panel

        /// The panel: the Info or Channels page as a sheet or popover, or
        /// the Apple TV's swipe-down panel.
        static let panel = "player.panel.root"
        /// The close button on a phone held sideways, where the sheet fills
        /// the screen.
        static let panelClose = "player.panel.close"
        /// The page's heading, on pages other than Info.
        static let panelTitle = "player.panel.title"
        /// A tab in the Apple TV panel's row, by `PlayerTab` raw value:
        /// info, channels, audio, subtitles, quality, speed, sync, picture.
        static func panelTab(_ rawValue: String) -> String { "player.panel.tab.\(rawValue)" }

        // MARK: Info

        static let infoPoster = "player.info.poster"
        static let infoTitle = "player.info.title"
        /// The line of facts under the title (year, length, rating…), or a
        /// programme's start and end.
        static let infoDetails = "player.info.details"
        static let infoOverview = "player.info.overview"
        /// A programme coming up on this channel, by programme id.
        static func infoUpcoming(_ id: String) -> String { "player.info.upcoming.\(id)" }
        /// The Apple TV Info tab's one line about the stream: delivery,
        /// size, rate, engine, display.
        static let infoSummary = "player.info.summary"
        /// A fact row by its fixed English label run through `TestID.key`:
        /// `engine`, `delivery`, `arriving-at`, `variant`, `throughput`,
        /// `stalls`, `dropped`, `from`, `picture`, `container`, `size`,
        /// `video`, `frame`, `frame-rate`, `range`, `video-rate`, `audio`,
        /// `subtitles` (twice: the file's count, then the track playing),
        /// `position`, `left`, `buffered`, `speed`, `audio-delay`,
        /// `audio-track`, `chapter`, `sleep-timer`, `after-this`, `display`.
        /// The element's label is "<label>, <value>".
        static func infoFact(_ key: String) -> String { "player.info.fact.\(key)" }
        static let infoFactEngine = infoFact("engine")

        // MARK: Channels

        /// A channel in the line-up, by channel id.
        static func channelRow(_ id: String) -> String { "player.channels.row.\(id)" }

        // MARK: Sync (Apple TV tab)

        /// The reading in the middle: "In step" or the offset.
        static let syncValue = "player.sync.value"
        /// A step button by its signed milliseconds as shown: -50, -5, 5, 50.
        static func syncStep(_ milliseconds: Int) -> String { "player.sync.step.\(milliseconds)" }
        static let syncReset = "player.sync.reset"
        static let syncResync = "player.sync.resync"
        static let syncReencode = "player.sync.reencode"
        /// The sentence saying why the offset can't be moved on this stream.
        static let syncUnavailable = "player.sync.unavailable"
        /// The row that hands the title to the mpv engine (Sync and Picture).
        static let switchToMpv = "player.engine.switchToMpv"

        // MARK: Picture (Apple TV tab)

        /// An adjustment by key: brightness, contrast, saturation, gamma,
        /// zoom. A slider off a television; on one, the group whose value is
        /// the setting, with `pictureDecrease` and `pictureIncrease` in it.
        static func pictureSlider(_ key: String) -> String { "player.picture.slider.\(key)" }
        static func pictureDecrease(_ key: String) -> String { "player.picture.decrease.\(key)" }
        static func pictureIncrease(_ key: String) -> String { "player.picture.increase.\(key)" }
        /// The key for an aspect override: the ratio in hundredths, `0` for
        /// the file's own, `178` for 16:9.
        static func aspectKey(_ ratio: Double) -> String { String(Int((ratio * 100).rounded())) }
        static func pictureAspect(_ key: String) -> String { "player.picture.aspect.\(key)" }
        static let pictureReset = "player.picture.reset"
        static let nightMode = "player.picture.nightMode"
        static let pictureUnavailable = "player.picture.unavailable"

        // MARK: Overlays

        /// The Apple TV's spinner in the middle of the picture. Elsewhere
        /// the play/pause button is the spinner.
        static let buffering = "player.overlay.buffering"
        static let skipIntro = "player.overlay.skipIntro"
        static let skipCredits = "player.overlay.skipCredits"
        /// The Up Next card. On an Apple TV it is one element with no
        /// buttons: a click plays, Menu cancels.
        static let upNextCard = "player.overlay.upNext"
        /// "Up next · in 12s", "Starting…".
        static let upNextCountdown = "player.overlay.upNext.countdown"
        static let upNextPlay = "player.overlay.upNext.play"
        static let upNextCancel = "player.overlay.upNext.cancel"
        /// The banner for a stream with sound and no picture.
        static let noVideoBanner = "player.overlay.noVideo"
        static let noVideoDismiss = "player.overlay.noVideo.dismiss"
        /// The notice that the stream changed bitrate on its own.
        static let bitrateBadge = "player.overlay.bitrate"

        // MARK: Error card

        static let errorCard = "player.error.root"
        static let errorMessage = "player.error.message"
        static let errorRetry = "player.error.retry"
        static let errorSmallerStream = "player.error.smallerStream"
        static let errorClose = "player.error.close"

        // MARK: Switch-to-streaming alert (a download asked for what it lacks)

        /// "Stream": leave the download and stream the title.
        static let streamSwitchConfirm = "player.streamSwitch.confirm"
        /// "Keep Download": stay on the copy on this device.
        static let streamSwitchKeepDownload = "player.streamSwitch.keepDownload"
        /// "OK" on the offline form of the alert, which offers no stream.
        static let streamSwitchOK = "player.streamSwitch.ok"

        // MARK: Gesture feedback

        /// How far a run of skips has gone: "+30 s".
        static let hudSkip = "player.hud.skip"
        /// The 2× badge while a finger holds the picture.
        static let hudDoubleSpeed = "player.hud.doubleSpeed"
        static let hudBrightness = "player.hud.brightness"
        static let hudVolume = "player.hud.volume"

        // MARK: Half-folded panel

        /// The flat half of a half-folded phone.
        static let foldPanel = "player.fold.root"
        /// What is playing, as one element.
        static let foldTitle = "player.fold.title"
        /// A chapter pill, by chapter id.
        static func foldChapter(_ id: Int) -> String { "player.fold.chapter.\(id)" }
        static let foldUpNext = "player.fold.upNext"
        static let foldSeason = "player.fold.season"
        /// The TV guide shown on a channel.
        static let foldGuide = "player.fold.guide"
        static let foldGuideLoading = "player.fold.guide.loading"

        // MARK: Mac: stream inspector

        static let streamInfo = "player.streamInfo.root"
        /// A row by key: `title`, `episode`, `details`, or a fact's label
        /// run through `TestID.key` as for `infoFact`.
        static func streamInfoRow(_ key: String) -> String { "player.streamInfo.row.\(key)" }

        // MARK: Mac: the picture's right-click menu and the Playback menu's shared items

        /// `player.menu.<item>`. The shared items (`PlayerMenuItems`) carry
        /// the same name in the context menu and in the menu bar.
        static func menu(_ item: String) -> String { "player.menu.\(item)" }
        static let menuPlayPause = menu("playPause")
        static let menuSkipSegment = menu("skipSegment")
        static let menuPlayNext = menu("playNext")
        static let menuQuality = menu("quality")
        /// By `qualityKey`, or the auto and downloaded keys.
        static func menuQualityOption(_ key: String) -> String { "player.menu.quality.\(key)" }
        static let menuAudio = menu("audio")
        static func menuAudioOption(_ key: String) -> String { "player.menu.audio.\(key)" }
        static let menuSubtitles = menu("subtitles")
        /// By `trackKey`, or `subtitlesOffKey`.
        static func menuSubtitleOption(_ key: String) -> String { "player.menu.subtitles.\(key)" }
        static let menuToggleSubtitles = menu("toggleSubtitles")
        static let menuSpeed = menu("speed")
        static func menuSpeedOption(_ key: String) -> String { "player.menu.speed.\(key)" }
        static let menuUpNext = menu("upNext")
        static func menuUpNextItem(_ id: String) -> String { "player.menu.upNext.\(id)" }
        static let menuUpNextClear = menu("upNextClear")
        static let menuSharePlayStart = menu("sharePlay")
        static let menuSharePlayLeave = menu("sharePlayLeave")
        static let menuSleep = menu("sleep")
        static func menuSleepOption(_ minutes: Int) -> String { "player.menu.sleep.\(minutes)" }
        static let menuSleepCancel = menu("sleepCancel")
        static let menuStopAfterThis = menu("stopAfterThis")
        static let menuFill = menu("fill")
        static let menuStreamInfo = menu("streamInfo")
        static let menuPictureInPicture = menu("pictureInPicture")
        static let menuFullScreen = menu("fullScreen")
        // The Playback menu's own items (menu bar only).
        /// Back 10 Seconds (⌘←).
        static let menuSkipBack = menu("skipBack")
        /// Forward 10 Seconds (⌘→).
        static let menuSkipForward = menu("skipForward")
        /// Slower ([): one speed step down.
        static let menuSlower = menu("slower")
        /// Faster (]): one speed step up.
        static let menuFaster = menu("faster")
        /// Volume Up (↑).
        static let menuVolumeUp = menu("volumeUp")
        /// Volume Down (↓).
        static let menuVolumeDown = menu("volumeDown")
        /// The Mute toggle (M).
        static let menuMute = menu("mute")
        /// Show Panel (⌘K): opens or closes the panel over the picture.
        static let menuShowPanel = menu("showPanel")
        /// Stop (⌘.).
        static let menuStop = menu("stop")

        // MARK: Sync code (Apple TV) and Measure Apple TV sync (iPhone)

        /// The corner of a sync clip that carries the code.
        static let syncCode = "player.syncCode.root"
        static let syncCodeImage = "player.syncCode.image"

        static let syncMeasure = "player.syncMeasure.root"
        static let syncMeasurePreview = "player.syncMeasure.preview"
        /// What is happening, written over the camera's picture.
        static let syncMeasureStatus = "player.syncMeasure.status"
        /// A failure or "camera unavailable" message.
        static let syncMeasureMessage = "player.syncMeasure.message"
        /// The explanation shown when the beats were timed but no code read.
        static let syncMeasureNoCode = "player.syncMeasure.noCode"
        static let syncMeasureDistance = "player.syncMeasure.distance"
        /// Measure / Stop.
        static let syncMeasureStart = "player.syncMeasure.start"
        static let syncMeasureManualRate = "player.syncMeasure.manual.rate"
        static let syncMeasureManualOffset = "player.syncMeasure.manual.offset"
        static let syncMeasureManualUse = "player.syncMeasure.manual.use"
        /// "Set 24 fps to".
        static let syncMeasureResultRate = "player.syncMeasure.result.rate"
        /// The number to set the Sync tab to.
        static let syncMeasureResultValue = "player.syncMeasure.result.value"
        static let syncMeasureResultAdvice = "player.syncMeasure.result.advice"
        /// The warning that the beats disagreed.
        static let syncMeasureResultWarning = "player.syncMeasure.result.warning"
        /// A row under Readings: code, flashes, beeps, camera, microphoneLag,
        /// soundTravel, framesDropped, median, spread, sensorReadout, or
        /// `beat<n>` counting from 1.
        static func syncMeasureReading(_ key: String) -> String { "player.syncMeasure.reading.\(key)" }
    }
}
