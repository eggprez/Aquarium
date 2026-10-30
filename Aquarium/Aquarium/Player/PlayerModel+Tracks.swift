//  Tracks, subtitles and the audio offset: which of a file's tracks to ask
//  for, the menus built from the server's list and the engine's, choosing one,
//  remembering the choice for the series, and moving the sound against the
//  picture.
//
//  One shape on every platform and either engine: the menus are built on
//  `PlayerTrack` lists made from the engine's own `EngineTrack` list, indexed
//  by the engine's track id, and a server stream is lined up with an engine
//  track by `EngineTrack.fileIndex`, which the engine fills in — mpv from the
//  file's own numbering, AVPlayer from the hints the model hands it. A
//  sidecar subtitle the server lists is matched by the URL it was added from
//  on an engine that takes external subtitles, and fetched when chosen.

import Foundation
import OSLog

extension PlayerModel {
    // MARK: - What to ask the server for

    /// Which of the file's tracks to ask for, from the file's own list. See
    /// `TrackPreference.preferredStreams`.
    /// The subtitle "forced only" picks from the menu as it stands, for the
    /// pickers that change the preference mid-play.
    var forcedOnlySubtitle: TrackOption? {
        let audio = audioOptions.first { $0.id == selectedAudioOption }
        return TrackPreference.forcedPick(
            subtitleOptions, audioLanguage: audio?.language, language: \.language, isForced: \.isForced
        )
    }

    func preferredStreams(in source: MediaSource, seriesId: String?) -> (audio: Int?, subtitle: Int?) {
        TrackPreference.preferredStreams(
            in: source,
            saved: seriesId.flatMap { prefs.trackChoice(seriesId: $0) },
            settings: TrackPreference.Settings(
                audioLanguage: prefs.audioLanguage,
                subtitleLanguage: prefs.subtitleLanguage,
                forcedSubtitlesOnly: prefs.forcedSubtitlesOnly))
    }

    /// What the server said this file contains, when there is a server and
    /// the file is its.
    var serverStreams: MediaSource? {
        guard !isLocal, !isExternal else { return nil }
        return source?.mediaSource
    }

    // MARK: - Appearance

    /// Size and background from Settings, applied live so a slider dragged in
    /// Settings can be judged against the picture.
    func refreshSubtitleStyling() {
        engine?.subtitleStyle = SubtitleStyle(
            size: prefs.subtitleSize, background: prefs.subtitleBackground, raised: subtitlesRaised)
    }

    /// Fit, Fill, a zoom or an aspect override, from Settings. A zoom or an
    /// aspect override is mpv's: on AVPlayer, which has Fit and Fill alone,
    /// `switchingIfNeeded` reopens the title on mpv.
    func applyFraming(switchingIfNeeded: Bool = false) {
        let framing = preferredFraming
        engine?.framing = framing
        #if os(iOS) && canImport(Libmpv)
        applyMPVOutput()
        #endif
        guard switchingIfNeeded, isActive, engine?.capabilities.contains(.zoom) == false else { return }
        switch framing {
        case .zoom, .aspect:
            if canSwitchEngine(to: .mpv) { Task { await switchEngine(to: .mpv, reason: "zoom or aspect override") } }
        case .fit, .fill:
            break
        }
    }

    /// Lift subtitles clear of the bar while it is up, and put them back at
    /// the foot of the picture when it goes.
    func raiseSubtitles(_ raised: Bool) {
        guard raised != subtitlesRaised else { return }
        subtitlesRaised = raised
        refreshSubtitleStyling()
    }

    // MARK: - The offsets the menus offer

    /// In milliseconds: fifty at a time either side of zero. Positive means
    /// the sound plays later than the picture.
    static let audioDelays: [Int] = Array(stride(from: -500, through: 500, by: 50))
    /// The furthest the Sync tab goes either way on an engine that moves
    /// the sound live; a rebuilt stream is kept to half of it.
    static let audioDelayReach = 1000

    static func audioDelayName(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "In step" }
        return milliseconds < 0 ? "Sound \(-milliseconds) ms earlier" : "Sound \(milliseconds) ms later"
    }

    static func audioDelayShortName(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "in step" }
        return milliseconds < 0 ? "\(-milliseconds) ms earlier" : "\(milliseconds) ms later"
    }

    var audioDelayMilliseconds: Int { Int((audioDelay * 1000).rounded()) }

    // MARK: - Remembering a choice for the series

    func rememberTrackChoice(
        audioLanguage: String? = nil, subtitleLanguage: String? = nil, subtitleOff: Bool = false
    ) {
        guard let seriesId = item?.SeriesId else { return }
        var choice = prefs.trackChoice(seriesId: seriesId) ?? .init(audio: nil, sub: nil)
        if let audioLanguage { choice.audio = audioLanguage }
        if let subtitleLanguage { choice.sub = subtitleLanguage }
        if subtitleOff { choice.sub = "off" }
        prefs.setTrackChoice(choice, seriesId: seriesId)
    }
}

// MARK: - The engine's list

extension PlayerModel {
    func onTracks(_ list: [EngineTrack]) {
        setAudioTracks(list.filter { $0.kind == .audio }.map {
            PlayerTrack(id: $0.id, label: $0.title ?? $0.label, language: $0.language, isForced: false)
        })
        setSubtitleTracks(list.filter { $0.kind == .subtitle }.map {
            PlayerTrack(id: $0.id, label: $0.title ?? $0.label, language: $0.language, isForced: $0.isForced)
        })
        setSelectedAudioTrack(list.first { $0.kind == .audio && $0.isSelected }?.id)
        setSelectedSubtitleTrack(list.first { $0.kind == .subtitle && $0.isSelected }?.id)
        // The first list of a file is the engine's own choice, and the only
        // one worth overriding rather than recording. mpv lists the video
        // track first and the rest a moment later; wait for a sound track.
        if !tracksApplied, list.contains(where: { $0.kind == .audio || $0.kind == .video }) {
            tracksApplied = true
            applyPreferredTracks()
        }
    }

    func onChapters(_ list: [EngineChapter]) {
        setChapters(list.map { Chapter(id: $0.id, start: $0.start, title: $0.title) })
    }

    /// The chapter containing `seconds`, for the scrubber's readout.
    func chapterName(at seconds: Double) -> String? {
        var found: String?
        for c in chapters {
            if c.start > seconds { break }
            found = c.title
        }
        return found
    }

    func selectAudioTrack(_ index: Int) {
        guard audioTracks.contains(where: { $0.id == index }) else { return }
        if audioDelayIsApplied {
            // The composition carries one audio track; another means building
            // it again around that one.
            guard selectedAudioTrack != index else { return }
            setSelectedAudioTrack(index)
            rememberTrackChoiceFromSelection()
            rebuildForAudioDelay()
            return
        }
        engine?.selectAudio(trackID: index)
        setSelectedAudioTrack(index)
        rememberTrackChoiceFromSelection()
    }

    /// `nil` turns subtitles off.
    func selectSubtitleTrack(_ index: Int?) {
        if let index, !subtitleTracks.contains(where: { $0.id == index }) { return }
        if audioDelayIsApplied {
            guard selectedSubtitleTrack != index else { return }
            setSelectedSubtitleTrack(index)
            rememberTrackChoiceFromSelection()
            rebuildForAudioDelay()
            return
        }
        engine?.selectSubtitle(trackID: index)
        setSelectedSubtitleTrack(index)
        rememberTrackChoiceFromSelection()
    }

    /// Put on the tracks this stream was opened for, then whatever the
    /// series or Settings prefer where the stream has them.
    private func applyPreferredTracks() {
        if applyChosenTracks() { return }
        if applyWantedTracks() { return }
        #if !os(tvOS)
        if isLocal {
            applyPreferredLocalTracks()
            return
        }
        #endif

        if let seriesId = item?.SeriesId, let saved = prefs.trackChoice(seriesId: seriesId) {
            if let wantAudio = saved.audio,
               let match = audioTracks.first(where: { Languages.matches(preference: wantAudio, tag: $0.language) }) {
                selectAudioTrack(match.id)
            }
            if saved.sub == "off" {
                selectSubtitleTrack(nil)
                return
            } else if let wantSub = saved.sub,
                      let match = subtitleTracks.first(where: { Languages.matches(preference: wantSub, tag: $0.language) }) {
                selectSubtitleTrack(match.id)
                return
            }
        }

        if !prefs.audioLanguage.isEmpty,
           let match = audioTracks.first(where: { Languages.matches(preference: prefs.audioLanguage, tag: $0.language) }) {
            selectAudioTrack(match.id)
        }

        switch prefs.subtitleLanguage {
        case "":
            break
        case "off":
            selectSubtitleTrack(nil)
        case TrackPreference.forcedOnly:
            let audio = selectedAudioTrack.flatMap { id in audioTracks.first { $0.id == id } }
            let pick = TrackPreference.forcedPick(
                subtitleTracks, audioLanguage: audio?.language, language: \.language, isForced: \.isForced
            )
            selectSubtitleTrack(pick?.id)
        case let wanted:
            let audioMatches = selectedAudioTrack
                .flatMap { id in audioTracks.first { $0.id == id } }
                .map { Languages.matches(preference: prefs.audioLanguage, tag: $0.language) } ?? false
            let candidates = subtitleTracks.filter { Languages.matches(preference: wanted, tag: $0.language) }
            if prefs.forcedSubtitlesOnly, audioMatches {
                if let forced = candidates.first(where: { $0.isForced }) {
                    selectSubtitleTrack(forced.id)
                } else {
                    selectSubtitleTrack(nil)
                }
            } else if let first = candidates.first(where: { !$0.isForced }) ?? candidates.first {
                selectSubtitleTrack(first.id)
            }
        }
    }

    /// The tracks the stream was asked for, in the server's numbering — the
    /// ones `preferredStreams` resolved from the saved choice and Settings —
    /// put on where the stream carries them. Lifted from the Apple TV model.
    /// True when the stream had something to say about it.
    private func applyWantedTracks() -> Bool {
        guard let engine, let streams = serverStreams else { return false }
        var applied = false
        let audioIndex = wantedTracks.audio ?? streams.DefaultAudioStreamIndex
        if let index = audioIndex, let stream = streams.audioStreams.first(where: { $0.Index == index }),
           let id = engineTrack(for: stream, kind: .audio) {
            if id != selectedAudioTrack { engine.selectAudio(trackID: id) }
            setSelectedAudioTrack(id)
            applied = true
        }
        let subtitleIndex = wantedTracks.subtitle
            ?? streams.DefaultSubtitleStreamIndex.flatMap { $0 >= 0 ? $0 : nil }
        guard let subtitleIndex else { return applied }
        guard subtitleIndex >= 0 else {
            if selectedSubtitleTrack != nil { engine.selectSubtitle(trackID: nil) }
            setSelectedSubtitleTrack(nil)
            return true
        }
        guard let stream = streams.subtitleStreams.first(where: { $0.Index == subtitleIndex }) else { return applied }
        if let id = engineTrack(for: stream, kind: .subtitle) {
            if id != selectedSubtitleTrack { engine.selectSubtitle(trackID: id) }
            setSelectedSubtitleTrack(id)
            return true
        }
        if stream.isSidecar, addExternalSubtitle(stream) { return true }
        return applied
    }

    /// Record what is selected now against the series.
    private func rememberTrackChoiceFromSelection() {
        guard let seriesId = item?.SeriesId else { return }
        let audio = selectedAudioTrack.flatMap { id in audioTracks.first { $0.id == id }?.language }
        let sub: String? = {
            if let id = selectedSubtitleTrack, let track = subtitleTracks.first(where: { $0.id == id }) {
                return track.language ?? "und"
            }
            // A subtitle the server painted into the picture is no track
            // here, but it is the choice to remember.
            if let burned = burnedInSubtitle,
               let option = subtitleOptions.first(where: { $0.serverIndex == burned }) {
                return option.language ?? "und"
            }
            return "off"
        }()
        prefs.setTrackChoice(.init(audio: audio, sub: sub), seriesId: seriesId)
    }

    // MARK: The menus

    /// Whether the engine's `fileIndex` is the file's own numbering for this
    /// stream. mpv reads it off whatever it opens, so on a transcode it
    /// numbers the server's HLS rendition, not the file; AVPlayer takes it
    /// from the hints the model hands it, which are the file's whichever
    /// stream is playing.
    private var fileIndexIsTheFiles: Bool {
        !isTranscoding || engine?.kind == .apple
    }

    /// The engine's id for the server's track, when it is in the stream:
    /// embedded ones by their index in the file, sidecars by the URL they
    /// were added from.
    private func engineTrack(for stream: MediaStream, kind: EngineTrack.Kind) -> Int? {
        if kind == .subtitle, stream.isSidecar {
            guard let url = externalSubtitleURL(for: stream)?.absoluteString else { return nil }
            return tracks.first { $0.kind == .subtitle && $0.isExternal && $0.externalURL == url }?.id
        }
        guard fileIndexIsTheFiles, let index = stream.Index else { return nil }
        return tracks.first { $0.kind == kind && !$0.isExternal && $0.fileIndex == index }?.id
    }

    var audioOptions: [TrackOption] {
        guard let streams = serverStreams?.audioStreams, !streams.isEmpty else {
            return audioTracks.map {
                TrackOption(serverIndex: nil, avIndex: $0.id, label: $0.label, language: $0.language, isForced: false)
            }
        }
        return streams.map { stream in
            TrackOption(
                serverIndex: stream.Index, avIndex: engineTrack(for: stream, kind: .audio),
                label: stream.menuLabel, language: stream.Language, isForced: false)
        }
    }

    var subtitleOptions: [TrackOption] {
        #if !os(tvOS)
        if isLocal { return localSubtitleOptions }
        #endif
        guard let streams = serverStreams?.subtitleStreams, !streams.isEmpty else {
            return subtitleTracks.map {
                TrackOption(serverIndex: nil, avIndex: $0.id, label: $0.label, language: $0.language, isForced: $0.isForced)
            }
        }
        return streams.map { stream in
            TrackOption(
                serverIndex: stream.Index,
                avIndex: engineTrack(for: stream, kind: .subtitle),
                label: stream.menuLabel, language: stream.Language, isForced: stream.isForced)
        }
    }

    var selectedAudioOption: TrackOption.ID? {
        let choices = audioOptions
        if let av = selectedAudioTrack, let match = choices.first(where: { $0.avIndex == av }) {
            return match.id
        }
        let asked = options.audioStreamIndex ?? serverStreams?.DefaultAudioStreamIndex
        if let asked, let match = choices.first(where: { $0.serverIndex == asked }) { return match.id }
        return choices.first?.id
    }

    var selectedSubtitleOption: TrackOption.ID? {
        let choices = subtitleOptions
        if let av = selectedSubtitleTrack, let match = choices.first(where: { $0.avIndex == av }) {
            return match.id
        }
        if let burned = burnedInSubtitle, let match = choices.first(where: { $0.serverIndex == burned }) {
            return match.id
        }
        return nil
    }

    /// The subtitle the server painted into the picture, if it did: one was
    /// asked for and no selectable track came back for it.
    private var burnedInSubtitle: Int? {
        guard let asked = options.subtitleStreamIndex, asked >= 0 else { return nil }
        guard !subtitleOptions.contains(where: { $0.serverIndex == asked && $0.avIndex != nil }) else { return nil }
        return asked
    }

    func selectAudio(_ option: TrackOption) {
        guard option.id != selectedAudioOption else { return }
        if let av = option.avIndex {
            selectAudioTrack(av)
            // So the progress reports carry the track that is playing.
            if let index = option.serverIndex { options.audioStreamIndex = index }
            return
        }
        guard let index = option.serverIndex else { return }
        Task { await reopen(audio: index, subtitle: subtitleRequest) }
    }

    func selectSubtitles(_ option: TrackOption?) {
        guard option?.id != selectedSubtitleOption else { return }
        guard let option else {
            if burnedInSubtitle != nil {
                Task { await reopen(audio: audioRequest, subtitle: -1) }
            } else {
                selectSubtitleTrack(nil)
                if options.subtitleStreamIndex != nil { options.subtitleStreamIndex = -1 }
            }
            return
        }
        if let av = option.avIndex {
            selectSubtitleTrack(av)
            if let index = option.serverIndex { options.subtitleStreamIndex = index }
            return
        }
        guard let index = option.serverIndex else { return }
        #if !os(tvOS)
        // A download has no server to ask; its subtitles are the files saved
        // beside it.
        if isLocal {
            if let entry = localSidecars.first(where: { $0.index == index }) { loadSidecar(entry) }
            return
        }
        #endif
        // A sidecar file the engine can take is fetched and shown, with no
        // new stream.
        if let stream = serverStreams?.subtitleStreams.first(where: { $0.Index == index }), stream.isSidecar,
           addExternalSubtitle(stream) {
            options.subtitleStreamIndex = index
            rememberTrackChoice(subtitleLanguage: option.language ?? "und")
            return
        }
        Task { await reopen(audio: audioRequest, subtitle: index, forSubtitleTheServerMustRender: true) }
    }

    private var audioRequest: Int? {
        if let av = selectedAudioTrack, let match = audioOptions.first(where: { $0.avIndex == av }) {
            return match.serverIndex
        }
        return options.audioStreamIndex
    }

    private var subtitleRequest: Int? {
        if let av = selectedSubtitleTrack, let match = subtitleOptions.first(where: { $0.avIndex == av }) {
            return match.serverIndex
        }
        if let burned = burnedInSubtitle { return burned }
        return options.subtitleStreamIndex == nil ? nil : -1
    }

    /// Ask for this stream again, carrying different tracks.
    private func reopen(audio: Int?, subtitle: Int?, forSubtitleTheServerMustRender: Bool = false) async {
        guard let item, isActive, !isLocal, !isExternal else { return }
        var opts = options
        opts.audioStreamIndex = audio
        opts.subtitleStreamIndex = subtitle
        if forSubtitleTheServerMustRender, !opts.forceTranscode {
            opts.forceTranscode = true
            transcodingForSubtitle = true
        } else if transcodingForSubtitle, let subtitle, subtitle < 0 {
            opts.forceTranscode = false
            transcodingForSubtitle = false
        }
        opts.startSeconds = isLive ? nil : position
        pendingTrackChoice = (audio: audio, subtitle: subtitle)
        await play(item: item, options: opts, meta: StartMeta(inherited: true, quiet: true, forTracks: true))
    }

    /// Put the just-chosen tracks back on the stream that was opened for them.
    private func applyChosenTracks() -> Bool {
        guard let wanted = pendingTrackChoice else { return false }
        pendingTrackChoice = nil
        guard wanted.audio != nil || wanted.subtitle != nil else { return false }
        if let audio = wanted.audio,
           let match = audioOptions.first(where: { $0.serverIndex == audio }), let av = match.avIndex {
            selectAudioTrack(av)
        }
        guard let subtitle = wanted.subtitle else { return true }
        if subtitle < 0 {
            selectSubtitleTrack(nil)
        } else if let match = subtitleOptions.first(where: { $0.serverIndex == subtitle }), let av = match.avIndex {
            selectSubtitleTrack(av)
        } else {
            rememberTrackChoiceFromSelection()
        }
        return true
    }

    // MARK: Sidecar subtitles

    /// Where the server serves one of its sidecar subtitle files from, when
    /// it is the server this session is signed in to.
    private func externalSubtitleURL(for stream: MediaStream) -> URL? {
        guard let path = stream.DeliveryUrl, !path.isEmpty, let server = prefs.session?.server else { return nil }
        if path.hasPrefix("http"), let url = URL(string: path), client.isSessionOrigin(url) { return url }
        guard path.hasPrefix("/"), let url = URL(string: server + path), client.isSessionOrigin(url) else { return nil }
        return url
    }

    /// Show a sidecar subtitle on an engine that takes one: selected if it
    /// is already in, fetched and added if not. False when the engine
    /// cannot, or the file has no address.
    @discardableResult
    private func addExternalSubtitle(_ stream: MediaStream) -> Bool {
        guard let engine, engine.capabilities.contains(.externalSubtitles) else { return false }
        if let id = engineTrack(for: stream, kind: .subtitle) {
            engine.selectSubtitle(trackID: id)
            setSelectedSubtitleTrack(id)
            return true
        }
        guard let url = externalSubtitleURL(for: stream) else { return false }
        engine.addExternalSubtitle(url: url, language: stream.Language, title: stream.menuLabel)
        return true
    }

    // MARK: A download's subtitle files

    #if !os(tvOS)
    /// The disk read behind `localSidecars`, kept until the index changes:
    /// the menus are rebuilt on every draw.
    @MainActor private static var sidecarCache: (key: String, entries: [DownloadSubtitles.Entry])?

    /// The download's folder, while one is playing.
    private var localFolder: URL? {
        guard isLocal, let id = localRecordId else { return nil }
        return DownloadManager.folderPath(for: id)
    }

    /// The subtitle files saved beside the download that is playing (see
    /// `DownloadSubtitles`).
    var localSidecars: [DownloadSubtitles.Entry] {
        guard let folder = localFolder else { return [] }
        let indexPath = folder.appendingPathComponent(DownloadSubtitles.indexName).path
        let stamp = (try? FileManager.default.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(indexPath)|\(stamp)"
        if let cached = Self.sidecarCache, cached.key == key { return cached.entries }
        let entries = DownloadSubtitles.local(in: folder)
        Self.sidecarCache = (key, entries)
        return entries
    }

    /// The engine's id for a subtitle file once it has been added. mpv lists
    /// it under the URL it was given, which ends in the file's name.
    private func engineTrack(forSidecar entry: DownloadSubtitles.Entry) -> Int? {
        tracks.first {
            $0.kind == .subtitle && $0.isExternal && ($0.externalURL?.hasSuffix(entry.fileName) ?? false)
        }?.id
    }

    /// The download's own subtitle tracks, then the files beside it. A file
    /// is left out where it is a copy of a track already in the file, which
    /// is what an embedded subtitle of a file download is: matched by the
    /// file's numbering where the engine reads it, by language where it
    /// doesn't. A file the engine has taken in is listed once, as the file,
    /// keeping its id whether or not it has been loaded yet.
    private var localSubtitleOptions: [TrackOption] {
        let sidecars = localSidecars
        let loaded = Set(sidecars.compactMap { engineTrack(forSidecar: $0) })
        let inFile = tracks.filter { $0.kind == .subtitle && !loaded.contains($0.id) }
        let fileNumbered = inFile.contains { !$0.isExternal && $0.fileIndex != nil }
        var out = subtitleTracks.filter { !loaded.contains($0.id) }.map {
            TrackOption(serverIndex: nil, avIndex: $0.id, label: $0.label, language: $0.language, isForced: $0.isForced)
        }
        for entry in sidecars {
            if !entry.isExternal, inFile.contains(where: { track in
                guard !track.isExternal else { return false }
                if fileNumbered { return track.fileIndex == entry.index }
                return Languages.matches(preference: entry.language ?? "", tag: track.language)
                    && track.isForced == entry.isForced
            }) { continue }
            out.append(TrackOption(
                serverIndex: entry.index, avIndex: engineTrack(forSidecar: entry),
                label: entry.title, language: entry.language, isForced: entry.isForced))
        }
        return out
    }

    /// A subtitle file chosen on an engine that can't take one, carried
    /// across the reopen on mpv by the download it was chosen for.
    @MainActor private static var pendingSidecar: (recordId: String, index: Int)?

    /// Show one of the download's subtitle files. mpv adds it; AVPlayer has
    /// no way to take a file in, so the download is reopened on mpv at the
    /// same moment, where that is allowed, and the file put on once it opens.
    /// False when there is no way to show it here.
    @discardableResult
    private func loadSidecar(_ entry: DownloadSubtitles.Entry) -> Bool {
        guard let engine, let folder = localFolder, let recordId = localRecordId else { return false }
        if let id = engineTrack(forSidecar: entry) {
            engine.selectSubtitle(trackID: id)
            setSelectedSubtitleTrack(id)
            return true
        }
        let url = folder.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if engine.capabilities.contains(.externalSubtitles) {
            engine.addExternalSubtitle(url: url, language: entry.language, title: entry.title)
            return true
        }
        // Only for a file someone picked from the menu. Done for a Settings
        // preference, every episode opened twice, and a hand-over to Apple's
        // player for picture in picture or AirPlay re-applied it and went
        // straight back.
        guard !Self.pickingAutomatically else {
            Self.log.notice("subtitle file \(entry.fileName, privacy: .public) needs mpv; not switching for a preference")
            return false
        }
        guard canSwitchEngine(to: .mpv) else {
            Self.log.notice("subtitle file \(entry.fileName, privacy: .public) needs mpv: \(self.engineSwitchUnavailableReason(to: .mpv) ?? "", privacy: .public)")
            return false
        }
        Self.pendingSidecar = (recordId, entry.index)
        Task { await switchEngine(to: .mpv, reason: "a downloaded subtitle file") }
        return true
    }

    /// `applyPreferredTracks` for a download, which has no server to have
    /// asked: the saved choice for the series, then Settings, over the
    /// download's own tracks and the subtitle files beside it, the file's
    /// tracks first since they need nothing loaded.
    /// Set while `applyPreferredLocalTracks` picks, so a pick it makes never
    /// changes the engine. See `loadSidecar`.
    @MainActor private static var pickingAutomatically = false

    private func applyPreferredLocalTracks() {
        Self.pickingAutomatically = true
        defer { Self.pickingAutomatically = false }
        let recordId = localRecordId
        let seriesId = recordId.flatMap { DownloadManager.shared.record(for: $0)?.seriesId }
        let saved = seriesId.flatMap { prefs.trackChoice(seriesId: $0) }

        for want in [saved?.audio, prefs.audioLanguage] {
            guard let want, !want.isEmpty,
                  let match = audioTracks.first(where: { Languages.matches(preference: want, tag: $0.language) })
            else { continue }
            if match.id != selectedAudioTrack { selectAudioTrack(match.id) }
            break
        }

        let choices = localSubtitleOptions
        if let pending = Self.pendingSidecar, pending.recordId == recordId {
            Self.pendingSidecar = nil
            if let option = choices.first(where: { $0.serverIndex == pending.index }) {
                selectSubtitles(option)
                return
            }
        }

        let audioMatches = selectedAudioTrack
            .flatMap { id in audioTracks.first { $0.id == id } }
            .map { Languages.matches(preference: prefs.audioLanguage, tag: $0.language) } ?? false
        for (want, fromSettings) in [(saved?.sub, false), (prefs.subtitleLanguage, true)] {
            guard let want, !want.isEmpty else { continue }
            if want == "off" {
                selectSubtitleTrack(nil)
                return
            }
            if want == TrackPreference.forcedOnly {
                let audio = selectedAudioTrack.flatMap { id in audioTracks.first { $0.id == id } }
                if let pick = TrackPreference.forcedPick(
                    choices, audioLanguage: audio?.language, language: \.language, isForced: \.isForced
                ) {
                    selectSubtitles(pick)
                } else {
                    selectSubtitleTrack(nil)
                }
                return
            }
            let candidates = choices.filter { Languages.matches(preference: want, tag: $0.language) }
            if fromSettings, prefs.forcedSubtitlesOnly, audioMatches {
                if let forced = candidates.first(where: \.isForced) {
                    selectSubtitles(forced)
                } else {
                    selectSubtitleTrack(nil)
                }
                return
            }
            if let pick = candidates.first(where: { !$0.isForced }) ?? candidates.first {
                selectSubtitles(pick)
                return
            }
        }

        // Neither says: what the file would show. The engine has already
        // put on a track the file marks as default; a file beside it is put
        // on where the server would have sent that one.
        guard selectedSubtitleTrack == nil, let folder = localFolder,
              let index = DownloadSubtitles.index(in: folder)?.defaultIndex, index >= 0,
              let option = choices.first(where: { $0.serverIndex == index })
        else { return }
        selectSubtitles(option)
    }
    #endif

    // MARK: The audio offset

    /// The offset in force, from Settings: one for everything on an iPhone,
    /// iPad or Mac; on the Apple TV one per frame rate of what is playing,
    /// because a television's HDMI chain converts a 24 fps film differently
    /// from a 60 fps show — see `delayRate`.
    var audioDelay: Double {
        #if os(tvOS)
        prefs.audioDelay(forRate: delayRate.fps)
        #else
        prefs.audioDelay
        #endif
    }

    var appliedAudioDelay: Double { audioDelay }
    var appliedAudioDelayMilliseconds: Int { Int((appliedAudioDelay * 1000).rounded()) }

    /// What the Sync tab says the offset it is moving is for, where there is
    /// one offset per frame rate; nil where there is one for everything.
    var audioDelayScope: String? {
        #if os(tvOS)
        var parts = ["\(delayRate.name) delay"]
        if let rate = videoFrameRate { parts.append(Self.frameRateName(rate)) }
        return parts.joined(separator: " · ")
        #else
        return nil
        #endif
    }

    /// Whether the stream being set up is one an offset can be built into: a
    /// file, which the engine will hand over whole. Everything HLS is refused.
    var streamCarriesDelay: Bool {
        if engine?.capabilities.contains(.audioDelayOnAnyStream) == true { return true }
        guard !isExternal, !isLive else { return false }
        if isLocal { return true }
        guard let source else { return false }
        return !source.isTranscode
    }

    var canDelayAudio: Bool {
        guard isActive, !isOpening else { return false }
        return streamCarriesDelay
    }

    var canDelayAudioLater: Bool { isActive && streamCarriesDelay }

    /// How far the Sync tab reaches either way on this engine.
    var audioDelayReach: Int {
        engine?.capabilities.contains(.audioDelayOnAnyStream) == true ? Self.audioDelayReach : Self.audioDelayReach / 2
    }

    func setAudioDelay(milliseconds: Int) {
        guard isActive else { return }
        let seconds = Double(min(max(milliseconds, -audioDelayReach), audioDelayReach)) / 1000
        guard abs(seconds - audioDelay) > 0.0005 else { return }
        if !streamCarriesDelay {
            // An HLS stream on AVPlayer: the offset reaches it only through
            // mpv, which moves the sound on anything. Reopened there.
            guard canSwitchEngine(to: .mpv) else { return }
            storeAudioDelay(seconds)
            Task { await switchEngine(to: .mpv, reason: "audio delay on an HLS stream") }
            return
        }
        storeAudioDelay(seconds)
        if engine?.capabilities.contains(.audioDelayOnAnyStream) == true {
            engine?.audioDelay = seconds
        } else {
            rebuildForAudioDelay()
        }
    }

    func nudgeAudioDelay(by delta: Int) {
        setAudioDelay(milliseconds: audioDelayMilliseconds + delta)
    }

    private func storeAudioDelay(_ seconds: Double) {
        #if os(tvOS)
        prefs.setAudioDelay(seconds, forRate: delayRate.fps)
        #else
        prefs.audioDelay = seconds
        #endif
    }

    /// Whether the Sync tab can be used at all on this stream: directly, or
    /// by handing the stream to mpv first.
    var canDelayAudioBySwitching: Bool {
        isActive && !isOpening && !streamCarriesDelay && canSwitchEngine(to: .mpv)
    }

    /// Open the current stream again at whatever offset now applies, holding
    /// the position and whether it was paused.
    func rebuildForAudioDelay() {
        guard resolvingGeneration != generation, let url = currentStreamURL, let engine else { return }
        isBuffering = true
        generation &+= 1
        engine.audioDelay = appliedAudioDelay
        var request = EngineLoadRequest(
            url: url, headers: isLocal ? [:] : client.authHeaders(for: url),
            startAt: position, paused: isPaused, live: isLive)
        request.hints = serverStreams.map { hints(for: $0) } ?? []
        request.audioTrack = selectedAudioTrack
        request.subtitleTrack = selectedSubtitleTrack
        engine.load(request)
    }

    func hints(for source: MediaSource) -> [EngineTrackHint] {
        source.streams.compactMap { stream in
            guard let index = stream.Index, let type = stream.type else { return nil }
            let kind: EngineTrack.Kind
            switch type {
            case "Audio": kind = .audio
            case "Subtitle": kind = .subtitle
            default: return nil
            }
            return EngineTrackHint(
                fileIndex: index, kind: kind, title: stream.DisplayTitle, language: stream.Language,
                isForced: stream.isForced, isExternal: stream.IsExternal ?? false, isImage: stream.isImageSubtitle)
        }
    }

    // MARK: The audio offset, per frame rate

    /// A frame rate the app keeps a delay for on the Apple TV: any rate,
    /// rounded to a whole number. Five are presets with a sync clip in
    /// Settings; any other is learned the first time the Sync tab is used
    /// over a video at it.
    struct DelayRate: Hashable, Comparable, Identifiable {
        let fps: Int

        init(frameRate: Double?) {
            fps = frameRate.map { $0 > 0 ? Int($0.rounded()) : 60 } ?? 60
        }

        init(fps: Int) { self.fps = fps }

        static let presets = [24, 25, 30, 50, 60].map(DelayRate.init(fps:))

        var id: Int { fps }
        var name: String { "\(fps) fps" }
        var isPreset: Bool { Self.presets.contains(self) }
        var resource: String { "SyncTest-\(fps)" }

        var clipRate: Double {
            switch fps {
            case 24: 24000.0 / 1001
            case 30: 30000.0 / 1001
            default: Double(fps)
            }
        }

        static func < (a: DelayRate, b: DelayRate) -> Bool { a.fps < b.fps }
    }

    var videoFrameRate: Double? {
        if let video = source?.mediaSource.streams.first(where: { $0.type == "Video" }),
           let rate = video.RealFrameRate ?? video.AverageFrameRate, rate > 0 {
            return rate
        }
        if let syncTest { return syncTest.clipRate }
        return frameRate
    }

    var delayRate: DelayRate { DelayRate(frameRate: videoFrameRate) }

    #if DEBUG
    var debugEngineAudioDelay: Double { engine?.audioDelay ?? .nan }
    var debugAVSync: String {
        #if canImport(Libmpv)
        (engine as? MPVEngine)?.get("avsync") ?? "none"
        #else
        "none"
        #endif
    }
    #endif
}

private extension MediaStream {
    /// A subtitle file beside the video rather than a track inside it.
    var isSidecar: Bool { IsExternal == true || DeliveryMethod == "External" }
}
