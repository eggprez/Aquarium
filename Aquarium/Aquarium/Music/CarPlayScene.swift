//  CarPlay: the music player on a dashboard.
//
//  Four tabs — what to play now, playlists, the library, audiobooks, each
//  only where the server has something to put in it — as the lists CarPlay
//  allows, and the system's own Now Playing screen over whatever is chosen,
//  with the buttons that suit it: shuffle, repeat and a star for a song, the
//  speed for a book, a sleep timer and Up Next for both. Everything here drives `MusicPlayer`; the lock-screen
//  card it already keeps is what the car's screen shows too.
//
//  And, parked, the films: since iOS 26.4 a car that can show video lets a
//  CarPlay app start one from a list, and carries the picture to its own
//  screen over the same route AirPlay uses — `PlayerModel`'s player already
//  allows external playback, so the tab below is the whole of it. When the
//  car says no (it is moving), the system plays the sound alone and shows
//  Now Playing instead; none of that is decided here. That tab needs the
//  CarPlay *video* entitlement as well as the audio one, and `FJCarPlayVideo`
//  set in Info.plist once Apple has granted it: a template feature used
//  without its entitlement is one more of the car's exceptions.
//
//  Needs the `com.apple.developer.carplay-audio` entitlement on the App ID
//  and in the provisioning profile before a car (or the simulator's CarPlay
//  window) will connect this scene. Until then the scene is declared in
//  Info.plist and never created: nothing here runs.

#if canImport(CarPlay)
import CarPlay
import CoreMedia
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate, CPNowPlayingTemplateObserver, CPSessionConfigurationDelegate {
    private var interfaceController: CPInterfaceController?
    /// What the car said about itself — here, whether it can show video.
    private var sessionConfiguration: CPSessionConfiguration?

    /// What the root was last built for. The car's screen is rebuilt when any
    /// of it changes — a sign-in on the phone, a switch of account, a server
    /// that turns out to have audiobooks — and left alone otherwise.
    private struct Shape: Equatable {
        var account: String?
        var music: Bool
        var books: Bool
        var video: Bool
    }
    private var shape: Shape?

    /// Whether there is a Video tab: a car that can show video, a build that
    /// holds the entitlement for it, and a server with something to watch.
    @MainActor
    private var offersVideo: Bool {
        guard #available(iOS 26.4, *),
              Bundle.main.object(forInfoDictionaryKey: "FJCarPlayVideo") as? Bool == true,
              sessionConfiguration?.supportsVideoPlayback == true
        else { return false }
        return !AppModel.shared.libraries.isEmpty || DownloadManager.shared.records.contains { !$0.isAudio && $0.status == .complete }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        Task { @MainActor in
            CPNowPlayingTemplate.shared.add(self)
            self.rebuildRoot()
            self.watch()
            // A car can start the app with no window at all, and everything
            // the window's first task does — find out whether the server
            // answers, read the library copy, ask what libraries there are —
            // is then still to do. Without it the car was shown whatever the
            // offline flag happened to say at launch.
            await LibraryIndex.shared.prepare()
            await AppModel.shared.refreshConnectivity()
            if AppModel.shared.libraries.isEmpty, !AppModel.shared.isLoadingLibraries {
                await AppModel.shared.loadLibraries()
            }
            self.rebuildRoot()
            await self.fillListenNow()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        sessionConfiguration = nil
        shape = nil
        songRows = []
        Task { @MainActor in CPNowPlayingTemplate.shared.remove(self) }
    }

    // MARK: - Root

    /// The tabs for whoever is signed in and whatever their server has. Music
    /// tabs only where there is music, the audiobook tab only where there
    /// are books; with nobody signed in, one screen that says so.
    @MainActor
    private func rebuildRoot() {
        guard let interfaceController else { return }
        let app = AppModel.shared
        let next = Shape(
            account: JellyfinClient.shared.session?.accountKey,
            music: app.hasMusic, books: app.hasBooks, video: offersVideo
        )
        guard next != shape else { return }
        shape = next
        songRows = []
        listenNow = nil
        listenNowFilledAt = .distantPast

        var tabs: [CPTemplate] = []
        if next.account == nil {
            tabs = [messageTemplate("Aquarium", "Sign in on your iPhone", "Open Aquarium on your iPhone and sign in to your Jellyfin server.")]
        } else {
            // The car has room for so many tabs and no more, and one too many
            // is an exception. Playlists is the one that can move: it becomes
            // a door in Library, where it lived before it had a tab.
            let wanted = (next.music ? 3 : 0) + (next.books ? 1 : 0) + (next.video ? 1 : 0)
            let playlistsTab = wanted <= CPTabBarTemplate.maximumTabCount
            if next.music {
                tabs.append(listenNowTemplate())
                if playlistsTab { tabs.append(playlistsTemplate()) }
                tabs.append(libraryTemplate(withPlaylists: !playlistsTab))
            }
            if next.books { tabs.append(audiobooksTemplate()) }
            if next.video { tabs.append(videoTemplate()) }
            if tabs.isEmpty {
                tabs = [messageTemplate("Aquarium", "Nothing to listen to", "This server has no music or audiobook library.")]
            }
        }
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: tabs), animated: false, completion: nil)
        configureNowPlaying()
        if next.music { Task { @MainActor in await self.fillListenNow() } }
    }

    @MainActor
    private func messageTemplate(_ title: String, _ headline: String, _ detail: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabImage = UIImage(systemName: "music.note.house")
        template.emptyViewTitleVariants = [headline]
        template.emptyViewSubtitleVariants = [detail]
        return template
    }

    /// Follow the app. `withObservationTracking` fires once, so each watcher
    /// re-arms itself for as long as the car is connected.
    @MainActor
    private func watch() {
        track({
            _ = JellyfinClient.shared.session
            _ = AppModel.shared.hasMusic
            _ = AppModel.shared.hasBooks
            _ = AppModel.shared.libraries
        }) { [weak self] in self?.rebuildRoot() }
        track({ _ = JellyfinClient.shared.isOffline }) { [weak self] in
            // Offline and online are two different Discover pages.
            self?.listenNowFilledAt = .distantPast
            Task { @MainActor in await self?.fillListenNow() }
        }
        track({
            let player = MusicPlayer.shared
            _ = player.current
            _ = player.isPlaying
            _ = player.hasUpNext
            _ = player.sleepDeadline
            _ = player.station
            _ = player.thumb
        }) { [weak self] in
            self?.markPlayingRows()
            self?.configureNowPlaying()
        }
    }

    @MainActor
    private func track(_ read: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil else { return }
                changed()
                self.track(read, changed: changed)
            }
        }
    }

    // MARK: - Coming back to a tab

    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor in
            // Discover is "what was I just listening to", and it was filled
            // once, when the car connected: an hour into a drive it was still
            // the list from the driveway.
            if aTemplate === self.listenNow { await self.fillListenNow() }
            // Continue Watching moves every time something is watched.
            if aTemplate === self.video { await self.fillVideo() }
            self.markPlayingRows()
        }
    }

    // MARK: - Discover

    private var listenNow: CPListTemplate?
    private var listenNowFilledAt = Date.distantPast
    private var isFillingListenNow = false

    @MainActor
    private func listenNowTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Discover", sections: [])
        template.tabImage = UIImage(systemName: "play.circle")
        template.emptyViewTitleVariants = ["Loading…"]
        listenNow = template
        return template
    }

    @MainActor
    private func fillListenNow() async {
        guard let listenNow, !isFillingListenNow, Date().timeIntervalSince(listenNowFilledAt) > 90 else { return }
        isFillingListenNow = true
        defer { isFillingListenNow = false }
        listenNowFilledAt = Date()
        let client = JellyfinClient.shared
        // A car is where the server is most often out of reach, and where an
        // empty screen is least welcome: the same page, from this device.
        if client.isOffline {
            listenNow.updateSections(offlineListenNow())
            listenNow.emptyViewTitleVariants = ["Nothing downloaded"]
            return
        }
        async let recent = client.recentlyPlayedSongs(limit: 30)
        async let added = client.music(.init(types: "MusicAlbum", sort: .recentlyAdded, limit: 12))
        async let books = client.resumeAudio()
        var sections: [CPListSection] = []
        if let songs = try? await recent, !songs.isEmpty {
            let albums = songs.albumsInOrder()
            sections.append(CPListSection(items: [albumRow("Recently Played", albums)]))
            sections.append(CPListSection(
                items: ListenNowView.stations(recent: songs, top: [], favoriteArtists: [], random: []).prefix(6).map { station in
                    let item = CPListItem(text: station.title, detailText: station.subtitle)
                    item.handler = { _, done in
                        Task { @MainActor in
                            await MusicMixes.startStation(from: station.seed, title: station.title)
                            self.showNowPlaying()
                            done()
                        }
                    }
                    return item
                },
                header: "Stations", sectionIndexTitle: nil
            ))
        }
        if let resumed = try? await books, !resumed.isEmpty {
            sections.append(CPListSection(
                items: resumed.prefix(6).map { songItem($0, queue: [$0], title: $0.title) },
                header: "Continue Listening", sectionIndexTitle: nil
            ))
        }
        if let albums = try? await added.items, !albums.isEmpty {
            sections.append(CPListSection(items: [albumRow("Recently Added", albums)]))
        }
        // Asked of a server that didn't answer: the downloads are still here.
        if sections.isEmpty, client.isOffline { sections = offlineListenNow() }
        listenNow.updateSections(sections)
        listenNow.emptyViewTitleVariants = ["Nothing to suggest yet"]
        listenNow.emptyViewSubtitleVariants = ["Play something and it will turn up here."]
    }

    @MainActor
    private func offlineListenNow() -> [CPListSection] {
        let all = OfflineMusic.songs
        let recent = OfflineMusic.recentlyPlayed(limit: 30)
        let top = OfflineMusic.mostPlayed(limit: 24)
        var sections: [CPListSection] = []
        let stations = OfflineListenNowView.stations(recent: recent, top: top, favorites: OfflineMusic.favorites(), all: all)
        if !stations.isEmpty {
            sections.append(CPListSection(
                items: stations.prefix(8).map { station in
                    let item = CPListItem(text: station.title, detailText: station.subtitle)
                    item.handler = { [weak self] _, done in
                        Task { @MainActor in
                            await MusicMixes.startStation(from: station.seed, title: station.title)
                            self?.showNowPlaying()
                            done()
                        }
                    }
                    return item
                },
                header: "Stations from This iPhone", sectionIndexTitle: nil
            ))
        }
        if !recent.isEmpty {
            sections.append(CPListSection(items: [albumRow("Recently Played", recent.localAlbums())]))
        }
        let books = OfflineMusic.booksInProgress
        if !books.isEmpty {
            sections.append(CPListSection(
                items: books.prefix(6).map { songItem($0, queue: [$0], title: $0.title) },
                header: "Continue Listening", sectionIndexTitle: nil
            ))
        }
        let added = OfflineMusic.recentlyDownloadedAlbums(limit: 12)
        if !added.isEmpty {
            sections.append(CPListSection(items: [albumRow("Recently Downloaded", added)]))
        }
        return sections
    }

    /// A shelf of covers: what a glance can take in, where a column of album
    /// names has to be read. The heading opens the same albums as a list, for
    /// the ones the row had no room for.
    @MainActor
    private func albumRow(_ title: String, _ albums: [BaseItem]) -> CPListImageRowItem {
        let shown = Array(albums.prefix(CPMaximumNumberOfGridImages))
        let blank = Self.blankCover
        let row = CPListImageRowItem(text: title, images: shown.map { _ in blank })
        row.listImageRowHandler = { [weak self] _, index, done in
            Task { @MainActor in
                if shown.indices.contains(index) { await self?.openAlbum(shown[index]) }
                done()
            }
        }
        row.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self else { return done() }
                let list = CPListTemplate(title: title, sections: [CPListSection(items: albums.prefix(CPListTemplate.maximumItemCount).map { self.albumItem($0) })])
                self.push(list)
                done()
            }
        }
        Task { @MainActor in
            var covers = shown.map { _ in blank }
            for (i, album) in shown.enumerated() {
                guard let url = MusicArt.url(album, width: 240), let image = await ImageLoader.shared.load(url) else { continue }
                covers[i] = image
                row.update(covers)
            }
        }
        return row
    }

    private static let blankCover: UIImage = {
        let size = CGSize(width: 120, height: 120)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.secondarySystemFill.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }()

    // MARK: - Playlists

    /// A tab of their own: in a car a playlist is what gets played, and it
    /// was two levels down behind Library.
    @MainActor
    private func playlistsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [])
        template.tabImage = UIImage(systemName: "music.note.list")
        template.emptyViewTitleVariants = ["Loading…"]
        Task { @MainActor in
            let client = JellyfinClient.shared
            let rows = await self.playlistRows()
            template.updateSections([CPListSection(items: rows)])
            template.emptyViewTitleVariants = ["No playlists"]
            template.emptyViewSubtitleVariants = [client.isOffline ? "None of your playlists are downloaded." : "Playlists you make in Aquarium or Jellyfin show up here."]
        }
        return template
    }

    @MainActor
    private func playlistRows() async -> [CPListItem] {
        let client = JellyfinClient.shared
        let cap = CPListTemplate.maximumItemCount
        var rows: [CPListItem] = []
        if !client.isOffline, let lists = try? await client.audioPlaylists() {
            rows = lists.prefix(cap).map { self.collectionItem($0, songs: { try await client.playlistItems(playlistId: $0.Id) }) }
        }
        if rows.isEmpty {
            rows = OfflineMusic.playlists.prefix(cap).map { saved in
                self.collectionItem(OfflineMusic.playlistItem(saved.list, songs: saved.songs), songs: { _ in saved.songs })
            }
        }
        return rows
    }

    // MARK: - Library

    @MainActor
    private func libraryTemplate(withPlaylists: Bool = false) -> CPListTemplate {
        let client = JellyfinClient.shared
        // Rows are built only for what the car will show. Each row starts its
        // own artwork fetch, and these doors used to build up to four hundred
        // of them — four hundred picture requests over a car's connection —
        // before the list was cut to the template's limit. A song door still
        // queues everything it found; only the rows are cut.
        let cap = CPListTemplate.maximumItemCount
        var doors: [(String, String, () async -> [CPListItem])] = []
        if withPlaylists {
            doors.append(("Playlists", "music.note.list", { [weak self] in await self?.playlistRows() ?? [] }))
        }
        doors += [
            ("Artists", "music.mic", { [weak self] in
                if client.isOffline { return OfflineMusic.songs.localArtists().prefix(cap).compactMap { self?.artistItem($0) } }
                return ((try? await client.albumArtists(limit: 400).items) ?? []).prefix(cap).compactMap { self?.artistItem($0) }
            }),
            ("Albums", "square.stack", { [weak self] in
                if client.isOffline { return OfflineMusic.songs.localAlbums().prefix(cap).compactMap { self?.albumItem($0) } }
                return ((try? await client.music(.init(types: "MusicAlbum", sort: .name, limit: 400)).items) ?? []).prefix(cap).compactMap { self?.albumItem($0) }
            }),
            ("Songs", "music.note", { [weak self] in
                let songs = client.isOffline
                    ? OfflineMusic.songs
                    : (try? await client.music(.init(types: "Audio", sort: .name, limit: 400)).items) ?? []
                return songs.prefix(cap).compactMap { self?.songItem($0, queue: songs, title: "Songs") }
            }),
            ("Genres", "guitars", { [weak self] in
                if client.isOffline {
                    return OfflineMusic.genres.prefix(cap).compactMap { name in
                        var genre = BaseItem()
                        genre.Id = "local-genre:\(name.lowercased())"
                        genre.Name = name
                        genre.type = "MusicGenre"
                        return self?.collectionItem(genre, songs: { _ in OfflineMusic.songs(inGenre: name).shuffled() })
                    }
                }
                return ((try? await client.musicGenres().items) ?? []).prefix(cap).compactMap { self?.collectionItem($0, songs: { try await client.songs(genreId: $0.Id) }) }
            }),
            ("Downloaded", "arrow.down.circle", { [weak self] in
                let records = DownloadManager.shared.records.filter { $0.isAudio && $0.status == .complete }
                let songs = records.map(\.asItem)
                return songs.prefix(cap).compactMap { self?.songItem($0, queue: songs, title: "Downloaded") }
            }),
        ]
        let items = doors.map { title, symbol, load in
            let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                Task { @MainActor in
                    let children = Array(await load().prefix(CPListTemplate.maximumItemCount))
                    // Artists and albums come back in name order, so they
                    // get the letters down the side: a swipe to "R", not
                    // three hundred rows of scrolling at a red light.
                    let lettered = title == "Artists" || title == "Albums"
                    let list = CPListTemplate(title: title, sections: lettered ? Self.byLetter(children) : [CPListSection(items: children)])
                    list.emptyViewTitleVariants = ["Nothing here"]
                    list.emptyViewSubtitleVariants = [JellyfinClient.shared.isOffline ? "Nothing downloaded to show." : "The server had nothing to list."]
                    self?.push(list)
                    done()
                }
            }
            return item
        }
        let template = CPListTemplate(title: "Library", sections: [CPListSection(items: items)])
        template.tabImage = UIImage(systemName: "books.vertical")
        return template
    }

    /// Rows that are already in name order, cut into a section per initial.
    /// Falls back to one plain section where that would be more sections
    /// than the car allows.
    @MainActor
    private static func byLetter(_ rows: [CPListItem]) -> [CPListSection] {
        var groups: [(String, [CPListItem])] = []
        for row in rows {
            let first = (row.text ?? "").trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
            let key = first.first?.isLetter == true ? first : "#"
            if groups.last?.0 == key { groups[groups.count - 1].1.append(row) } else { groups.append((key, [row])) }
        }
        guard groups.count > 1, groups.count <= CPListTemplate.maximumSectionCount else { return [CPListSection(items: rows)] }
        return groups.map { CPListSection(items: $0.1, header: $0.0, sectionIndexTitle: $0.0) }
    }

    @MainActor
    private func audiobooksTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Audiobooks", sections: [])
        template.tabImage = UIImage(systemName: "book")
        template.emptyViewTitleVariants = ["Loading…"]
        Task { @MainActor in
            let client = JellyfinClient.shared
            var books = client.isOffline ? [] : (try? await client.music(.init(types: "AudioBook", sort: .name, limit: 300)).items) ?? []
            var started = client.isOffline ? [] : (try? await client.resumeAudio())?.filter(\.isAudiobook) ?? []
            if books.isEmpty {
                books = OfflineMusic.books
                started = OfflineMusic.booksInProgress
            }
            // The book you are in the middle of is the reason the tab was
            // opened nine times in ten; it goes above the alphabet.
            var sections: [CPListSection] = []
            if !started.isEmpty {
                sections.append(CPListSection(
                    items: started.prefix(6).map { self.songItem($0, queue: [$0], title: $0.title) },
                    header: "Continue Listening", sectionIndexTitle: nil
                ))
            }
            let cap = max(0, CPListTemplate.maximumItemCount - (sections.first?.items.count ?? 0))
            if !books.isEmpty {
                sections.append(CPListSection(
                    items: books.prefix(cap).map { self.songItem($0, queue: [$0], title: $0.title) },
                    header: started.isEmpty ? nil : "All Audiobooks", sectionIndexTitle: nil
                ))
            }
            template.updateSections(sections)
            template.emptyViewTitleVariants = ["No audiobooks"]
            template.emptyViewSubtitleVariants = [client.isOffline ? "None of your audiobooks are downloaded." : ""]
        }
        return template
    }

    // MARK: - Video

    private var video: CPListTemplate?
    private var videoFilledAt = Date.distantPast
    private var isFillingVideo = false

    @MainActor
    private func videoTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Video", sections: [])
        template.tabImage = UIImage(systemName: "film")
        template.emptyViewTitleVariants = ["Loading…"]
        video = template
        videoFilledAt = .distantPast
        Task { @MainActor in await self.fillVideo() }
        return template
    }

    /// What to carry on with, then the libraries. Offline, what is on the
    /// iPhone — a charging stop is where the server is least likely to answer.
    @MainActor
    private func fillVideo() async {
        guard let video, !isFillingVideo, Date().timeIntervalSince(videoFilledAt) > 30 else { return }
        isFillingVideo = true
        defer { isFillingVideo = false }
        videoFilledAt = Date()
        let client = JellyfinClient.shared
        var sections: [CPListSection] = []
        if !client.isOffline {
            async let resumed = client.resume()
            async let next = client.nextUp()
            if let items = try? await resumed, !items.isEmpty {
                sections.append(CPListSection(items: items.prefix(6).map { videoItem($0) }, header: "Continue Watching", sectionIndexTitle: nil))
            }
            if let items = try? await next, !items.isEmpty {
                sections.append(CPListSection(items: items.prefix(6).map { videoItem($0) }, header: "Next Up", sectionIndexTitle: nil))
            }
            let libraries = AppModel.shared.libraries
            if !libraries.isEmpty {
                sections.append(CPListSection(items: libraries.map { libraryDoor($0) }, header: "Libraries", sectionIndexTitle: nil))
            }
        }
        let records = DownloadManager.shared.records.filter { !$0.isAudio && $0.status == .complete }
        if !records.isEmpty {
            let cap = client.isOffline ? CPListTemplate.maximumItemCount : 6
            sections.append(CPListSection(items: records.prefix(cap).map { downloadedVideoItem($0) }, header: "On This iPhone", sectionIndexTitle: nil))
        }
        video.updateSections(sections)
        video.emptyViewTitleVariants = ["Nothing to watch"]
        video.emptyViewSubtitleVariants = [client.isOffline ? "The server is out of reach and no video is downloaded." : ""]
    }

    /// A film or an episode: a row that plays. The car is told it is video,
    /// so it can bring its player up over the list — or, moving, Now Playing.
    @MainActor
    private func videoItem(_ item: BaseItem, showsSeries: Bool = true) -> CPListItem {
        var parts: [String] = []
        if item.isEpisode {
            if showsSeries, let series = item.SeriesName { parts.append(series) }
            if let label = item.episodeLabel { parts.append(label) }
        } else if let year = item.ProductionYear {
            parts.append(String(year))
        }
        if let done = item.progressFraction, let total = item.RunTimeTicks {
            parts.append("\(Format.ticks(Int64(Double(total) * (1 - done)))) left")
        }
        let row = CPListItem(text: item.title, detailText: parts.joined(separator: " · "))
        if let done = item.progressFraction { row.playbackProgress = CGFloat(done) }
        markAsVideo(row, elapsed: Double(item.userData.positionTicks) / 10_000_000, duration: item.runtimeSeconds)
        if let url = item.isEpisode ? Artwork.still(for: item, width: 240) : Artwork.poster(for: item, width: 160) {
            Task { if let image = await ImageLoader.shared.load(url) { row.setImage(image) } }
        }
        row.handler = { _, done in
            Task { @MainActor in
                await PlayerModel.shared.play(item: item)
                done()
            }
        }
        return row
    }

    @MainActor
    private func downloadedVideoItem(_ record: DownloadRecord) -> CPListItem {
        let row = CPListItem(text: record.title, detailText: "Downloaded")
        markAsVideo(row, elapsed: 0, duration: 0)
        row.handler = { _, done in
            Task { @MainActor in
                PlayerModel.shared.playLocal(record)
                done()
            }
        }
        return row
    }

    @MainActor
    private func markAsVideo(_ row: CPListItem, elapsed: Double, duration: Double) {
        guard #available(iOS 26.4, *) else { return }
        row.playbackConfiguration = CPPlaybackConfiguration(
            preferredPresentation: .video,
            playbackAction: .play,
            elapsedTime: CMTime(seconds: max(0, elapsed), preferredTimescale: 600),
            duration: CMTime(seconds: max(0, duration), preferredTimescale: 600)
        )
    }

    /// A library: its films to play, its shows to open.
    @MainActor
    private func libraryDoor(_ library: BaseItem) -> CPListItem {
        let row = CPListItem(text: library.title, detailText: nil, image: UIImage(systemName: library.CollectionType == "tvshows" ? "tv" : "film"))
        row.accessoryType = .disclosureIndicator
        row.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self else { return done() }
                var query = JellyfinClient.LibraryQuery()
                query.limit = CPListTemplate.maximumItemCount
                switch library.CollectionType {
                case "tvshows": query.includeTypes = "Series"
                case "movies": query.includeTypes = "Movie"
                default: query.includeTypes = "Movie,Series,Video"
                }
                let items = (try? await JellyfinClient.shared.libraryItems(parentId: library.Id, query: query).items) ?? []
                let rows = items.prefix(CPListTemplate.maximumItemCount).map { $0.isSeries ? self.seriesItem($0) : self.videoItem($0) }
                let list = CPListTemplate(title: library.title, sections: [CPListSection(items: Array(rows))])
                list.emptyViewTitleVariants = ["Nothing here"]
                list.emptyViewSubtitleVariants = ["The server had nothing to list."]
                self.push(list)
                done()
            }
        }
        return row
    }

    /// A show: its episodes, a section to a season, the next unwatched one
    /// offered first.
    @MainActor
    private func seriesItem(_ series: BaseItem) -> CPListItem {
        let row = CPListItem(text: series.title, detailText: series.ProductionYear.map(String.init))
        row.accessoryType = .disclosureIndicator
        if let url = Artwork.poster(for: series, width: 160) {
            Task { if let image = await ImageLoader.shared.load(url) { row.setImage(image) } }
        }
        row.handler = { [weak self] _, done in
            Task { @MainActor in
                guard let self else { return done() }
                let episodes = (try? await JellyfinClient.shared.episodes(seriesId: series.Id, seasonId: nil)) ?? []
                var sections: [CPListSection] = []
                var room = CPListTemplate.maximumItemCount
                if let next = episodes.first(where: { !$0.userData.played }), episodes.first?.Id != next.Id {
                    sections.append(CPListSection(items: [self.videoItem(next, showsSeries: false)], header: "Next", sectionIndexTitle: nil))
                    room -= 1
                }
                var seasons: [(Int, [BaseItem])] = []
                for episode in episodes.prefix(room) {
                    let season = episode.ParentIndexNumber ?? 1
                    if seasons.last?.0 == season { seasons[seasons.count - 1].1.append(episode) } else { seasons.append((season, [episode])) }
                }
                if seasons.count + sections.count <= CPListTemplate.maximumSectionCount {
                    sections += seasons.map { number, list in
                        CPListSection(items: list.map { self.videoItem($0, showsSeries: false) }, header: number == 0 ? "Specials" : "Season \(number)", sectionIndexTitle: nil)
                    }
                } else {
                    sections.append(CPListSection(items: seasons.flatMap(\.1).map { self.videoItem($0, showsSeries: false) }))
                }
                let list = CPListTemplate(title: series.title, sections: sections)
                list.emptyViewTitleVariants = ["No episodes"]
                self.push(list)
                done()
            }
        }
        return row
    }

    // MARK: - Items

    @MainActor
    private func albumItem(_ album: BaseItem) -> CPListItem {
        let item = CPListItem(text: album.title, detailText: album.artistLine)
        item.accessoryType = .disclosureIndicator
        loadArt(album, into: item)
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                await self?.openAlbum(album)
                done()
            }
        }
        return item
    }

    @MainActor
    private func openAlbum(_ album: BaseItem) async {
        var tracks = JellyfinClient.shared.isOffline ? [] : (try? await JellyfinClient.shared.albumTracks(albumId: album.Id)) ?? []
        if tracks.isEmpty { tracks = OfflineMusic.albumTracks(albumId: album.Id) }
        guard !tracks.isEmpty else {
            alert("Couldn't open \(album.title)", "The server didn't answer, and the album isn't downloaded.")
            return
        }
        let shuffle = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffle.handler = { [weak self] _, done in
            Task { @MainActor in
                MusicPlayer.shared.play(tracks, shuffle: true, title: album.title)
                self?.showNowPlaying()
                done()
            }
        }
        let list = CPListTemplate(title: album.title, sections: [
            CPListSection(items: [shuffle]),
            CPListSection(items: tracks.map { songItem($0, queue: tracks, title: album.title, showsArt: false) }),
        ])
        push(list)
    }

    @MainActor
    private func artistItem(_ artist: BaseItem) -> CPListItem {
        let item = CPListItem(text: artist.title, detailText: nil)
        item.accessoryType = .disclosureIndicator
        loadArt(artist, into: item)
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: .year, limit: 100)
                q.albumArtistIds = [artist.Id]
                let offline = JellyfinClient.shared.isOffline
                let albums = offline
                    ? OfflineMusic.songs(byArtist: artist).localAlbums()
                    : (try? await JellyfinClient.shared.music(q).items) ?? []
                let shuffle = CPListItem(text: "Shuffle All", detailText: nil, image: UIImage(systemName: "shuffle"))
                shuffle.handler = { _, finished in
                    Task { @MainActor in
                        let songs = offline
                            ? OfflineMusic.songs(byArtist: artist)
                            : (try? await JellyfinClient.shared.allSongs(artistId: artist.Id)) ?? []
                        if !songs.isEmpty { MusicPlayer.shared.play(songs, shuffle: true, title: artist.title) }
                        self?.showNowPlaying()
                        finished()
                    }
                }
                let list = CPListTemplate(title: artist.title, sections: [
                    CPListSection(items: [shuffle]),
                    CPListSection(items: albums.compactMap { self?.albumItem($0) }, header: "Albums", sectionIndexTitle: nil),
                ])
                self?.push(list)
                done()
            }
        }
        return item
    }

    /// A playlist or a genre: something that is played whole.
    @MainActor
    private func collectionItem(_ collection: BaseItem, songs: @escaping (BaseItem) async throws -> [BaseItem]) -> CPListItem {
        let item = CPListItem(text: collection.title, detailText: nil)
        loadArt(collection, into: item)
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                let list = (try? await songs(collection)) ?? []
                if list.isEmpty {
                    self?.alert("Nothing to play in \(collection.title)", JellyfinClient.shared.isOffline ? "None of it is downloaded." : "The server didn't answer, or it is empty.")
                } else {
                    MusicPlayer.shared.play(list, title: collection.title)
                    self?.showNowPlaying()
                }
                done()
            }
        }
        return item
    }

    /// Song rows that may be on screen, by the song they play, so the
    /// speaker mark can follow the music. Weak: the car owns the rows, and a
    /// list that has been popped takes its rows with it.
    private final class SongRow {
        let songId: String
        weak var item: CPListItem?
        init(_ songId: String, _ item: CPListItem) {
            self.songId = songId
            self.item = item
        }
    }
    private var songRows: [SongRow] = []

    @MainActor
    private func markPlayingRows() {
        songRows.removeAll { $0.item == nil }
        let playing = MusicPlayer.shared.current?.Id
        for row in songRows {
            let isIt = row.songId == playing
            if row.item?.isPlaying != isIt { row.item?.isPlaying = isIt }
        }
    }

    @MainActor
    private func songItem(_ song: BaseItem, queue: [BaseItem], title: String, showsArt: Bool = true) -> CPListItem {
        let detail: String
        if song.isAudiobook {
            // Who wrote it, and how far in — what tells two half-heard books
            // apart from the driver's seat.
            let author = song.AlbumArtist ?? song.artistLine
            if let done = song.progressFraction, let total = song.RunTimeTicks {
                let left = Format.ticks(Int64(Double(total) * (1 - done)))
                detail = author.isEmpty ? "\(left) left" : "\(author) · \(left) left"
            } else {
                detail = author
            }
        } else {
            detail = song.artistLine
        }
        let item = CPListItem(text: song.title, detailText: detail)
        item.isPlaying = MusicPlayer.shared.current?.Id == song.Id
        item.playingIndicatorLocation = .trailing
        if let done = song.progressFraction { item.playbackProgress = CGFloat(done) }
        // An album's tracks all carry the album's cover; forty copies of it
        // down the side of the list is forty fetches for no information.
        if showsArt { loadArt(song, into: item) }
        songRows.append(SongRow(song.Id, item))
        item.handler = { [weak self] _, done in
            Task { @MainActor in
                // Tapping what is already playing is "take me to it", not
                // "start it again from the top".
                if MusicPlayer.shared.current?.Id != song.Id {
                    MusicPlayer.shared.play(queue, startingAt: queue.firstIndex(of: song) ?? 0, title: title)
                }
                self?.showNowPlaying()
                done()
            }
        }
        return item
    }

    @MainActor
    private func loadArt(_ item: BaseItem, into row: CPListItem) {
        guard let url = MusicArt.url(item, width: 160) else { return }
        Task {
            if let image = await ImageLoader.shared.load(url) { row.setImage(image) }
        }
    }

    /// The car allows five templates deep and raises an exception — which
    /// is a crash — on the sixth. Library → Artists → an artist → an album
    /// → Now Playing is already five, so anything opened from Now Playing
    /// starts again from the tabs rather than going one deeper.
    private static let maximumDepth = 5

    @MainActor
    private func push(_ template: CPTemplate) {
        guard let interfaceController else { return }
        if interfaceController.templates.count >= Self.maximumDepth {
            interfaceController.popToRootTemplate(animated: false) { [weak self] _, _ in
                self?.interfaceController?.pushTemplate(template, animated: true, completion: nil)
            }
        } else {
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        }
    }

    @MainActor
    private func alert(_ title: String, _ detail: String) {
        guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        // The longest variant that fits is the one shown.
        interfaceController.presentTemplate(
            CPAlertTemplate(titleVariants: ["\(title). \(detail)", title], actions: [ok]),
            animated: true, completion: nil
        )
    }

    // MARK: - Now Playing

    /// The one Now Playing screen there is. Pushing it while it is already
    /// on the stack is another of the car's exceptions, and it used to be
    /// pushed by every row, whatever was showing.
    @MainActor
    private func showNowPlaying() {
        guard let interfaceController, MusicPlayer.shared.current != nil else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate === nowPlaying { return }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
            return
        }
        push(nowPlaying)
    }

    /// The buttons under the artwork, for what is playing: a song gets
    /// shuffle, repeat and a star; a book gets its speed instead, since
    /// nobody shuffles a novel. Both get the sleep timer. A station's songs
    /// get thumbs down and up in place of shuffle and repeat, which a
    /// station deals for itself — the car allows five buttons. The thumbs
    /// are the station's, and go with it.
    @MainActor
    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        let player = MusicPlayer.shared
        guard let current = player.current else {
            // A film playing as sound alone — the car is moving — is shown
            // on this same screen, and a song's shuffle and star are not its.
            template.updateNowPlayingButtons([])
            template.isUpNextButtonEnabled = false
            template.isAlbumArtistButtonEnabled = false
            return
        }
        var buttons: [CPNowPlayingButton] = []
        if current.isAudiobook {
            buttons.append(CPNowPlayingPlaybackRateButton { _ in MusicPlayer.shared.stepSpeed(1) })
        } else if player.canThumb {
            let thumb = player.thumb
            if let down = UIImage(systemName: thumb == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                buttons.append(CPNowPlayingImageButton(image: down) { _ in
                    Task { @MainActor in MusicPlayer.shared.setThumb(thumb == -1 ? nil : -1) }
                })
            }
            if let up = UIImage(systemName: thumb == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") {
                buttons.append(CPNowPlayingImageButton(image: up) { _ in
                    Task { @MainActor in MusicPlayer.shared.setThumb(thumb == 1 ? nil : 1) }
                })
            }
        } else {
            buttons.append(CPNowPlayingShuffleButton { _ in MusicPlayer.shared.toggleShuffle() })
            buttons.append(CPNowPlayingRepeatButton { _ in MusicPlayer.shared.repeatMode = MusicPlayer.shared.repeatMode.next })
        }
        let starred = current.userData.isFavorite
        if let star = UIImage(systemName: starred ? "star.fill" : "star") {
            buttons.append(CPNowPlayingImageButton(image: star) { [weak self] _ in
                Task { @MainActor in await self?.toggleFavorite() }
            })
        }
        if let moon = UIImage(systemName: player.sleepDeadline == nil ? "moon.zzz" : "moon.zzz.fill") {
            buttons.append(CPNowPlayingImageButton(image: moon) { [weak self] _ in
                Task { @MainActor in self?.chooseSleepTimer() }
            })
        }
        template.updateNowPlayingButtons(buttons)
        template.isUpNextButtonEnabled = player.hasUpNext
        template.upNextTitle = "Up Next"
        template.isAlbumArtistButtonEnabled = current.isSong && current.AlbumId != nil
    }

    @MainActor
    private func toggleFavorite() async {
        guard let song = MusicPlayer.shared.current else { return }
        let next = !song.userData.isFavorite
        guard (try? await MusicFavorites.set(song, favorite: next)) != nil else {
            alert("Couldn't update favorites", "The server didn't answer.")
            return
        }
        // Changes the queue's copy, which is what `watch` redraws the star from.
        MusicPlayer.shared.markFavorite(song.Id, next)
        ItemMutations.shared.changed()
    }

    @MainActor
    private func chooseSleepTimer() {
        guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
        let player = MusicPlayer.shared
        var actions = [15, 30, 45, 60].map { minutes in
            CPAlertAction(title: "\(minutes) minutes", style: .default) { [weak self] _ in
                MusicPlayer.shared.setSleepTimer(minutes: minutes)
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
        }
        if player.sleepDeadline != nil {
            actions.append(CPAlertAction(title: "Turn Off Timer", style: .destructive) { [weak self] _ in
                MusicPlayer.shared.cancelSleepTimer()
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            })
        }
        actions.append(CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        })
        var message: String?
        if let deadline = player.sleepDeadline {
            message = "Pausing at \(deadline.formatted(date: .omitted, time: .shortened))"
        }
        interfaceController.presentTemplate(
            CPActionSheetTemplate(title: "Sleep Timer", message: message, actions: actions),
            animated: true, completion: nil
        )
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            let entries = Array(MusicPlayer.shared.upNext.prefix(CPListTemplate.maximumItemCount))
            let rows = entries.map { entry in
                let row = CPListItem(text: entry.item.title, detailText: entry.item.artistLine)
                row.handler = { [weak self] _, done in
                    Task { @MainActor in
                        MusicPlayer.shared.skip(to: entry)
                        self?.showNowPlaying()
                        done()
                    }
                }
                return row
            }
            let list = CPListTemplate(title: MusicPlayer.shared.queueTitle ?? "Up Next", sections: [CPListSection(items: rows)])
            list.emptyViewTitleVariants = ["Nothing queued"]
            self?.push(list)
        }
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            guard let song = MusicPlayer.shared.current, let albumId = song.AlbumId else { return }
            var album = BaseItem()
            album.Id = albumId
            album.Name = song.Album
            album.type = "MusicAlbum"
            await self.openAlbum(album)
        }
    }
}
#endif
