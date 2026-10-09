//  Offline mode for Music and Audiobooks: the same tab, from this device.
//
//  With the server out of reach the Music tab used to be a notice and a
//  button. It is now the tab it always was — Discover, Library, search,
//  album and artist and genre pages, stations, smart playlists — drawn from
//  what is downloaded, by `OfflineMusic`. Every route the online pages push
//  has an answer here (see `MusicDestination`), so nothing that can be tapped
//  offline leads to an error page, and the whole tab changes back by itself
//  when the server returns.

import SwiftUI

#if os(iOS)

// MARK: - Staying on the device

extension AppModel {
    /// Every page here pushes through this, so that what opens from an
    /// on-device page is an on-device page — see `MusicRoute.onDevice`.
    func pushOnDevice(_ route: MusicRoute) { push(.music(.onDevice(route))) }
}

/// What an offline page says when nothing has been downloaded for it.
private struct NothingOnDevice: View {
    var books = false
    var body: some View {
        EmptyState(
            symbol: "arrow.down.circle",
            title: books ? "No audiobooks on this device" : "No music on this device",
            message: books
                ? "Next time the server is in reach, press and hold an audiobook and choose Download. It then plays here, chapters and all, with no server."
                : "Next time the server is in reach, press and hold an album or a playlist and choose Download. Stations, smart playlists and search then work here with no server."
        )
    }
}

// MARK: - Discover

struct OfflineListenNowView: View {
    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var music

    @State private var downloads = DownloadManager.shared
    @State private var index = OfflineMusicIndex.shared
    @State private var smart = SmartPlaylistStore.shared

    @State private var recentAlbums: [BaseItem] = []
    @State private var topSongs: [BaseItem] = []
    @State private var stations: [ListenNowView.Station] = []
    @State private var newAlbums: [BaseItem] = []
    @State private var favorites: [BaseItem] = []
    @State private var randomAlbums: [BaseItem] = []
    @State private var playlists: [BaseItem] = []
    @State private var hasSongs = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                if !hasSongs {
                    NothingOnDevice()
                } else {
                    greeting
                    AlbumShelf(title: "Recently Played", items: recentAlbums) { open($0) } seeAll: {
                        app.pushOnDevice(.songList(title: "Recently Played", kind: .recentlyPlayed))
                    }
                    if !stations.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "Your Stations", subtitle: "Built from your downloads")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                                    ForEach(stations) { station in
                                        Button { play(station) } label: {
                                            MixTile(title: station.title, subtitle: station.subtitle, seed: station.seed)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(PosterButtonStyle())
                                    }
                                }
                                .padding(.horizontal, Metrics.gutter)
                            }
                        }
                    }
                    SongColumnsShelf(title: "Your Top Songs", items: topSongs, ranked: true) { song in
                        music.play(topSongs, startingAt: topSongs.position(of: song) ?? 0, title: "Top Songs")
                    } seeAll: {
                        app.pushOnDevice(.songList(title: "Most Played", kind: .mostPlayed))
                    }
                    AlbumShelf(title: "Playlists", items: playlists, subtitleFor: { Self.count($0) }) {
                        app.pushOnDevice(.playlist($0.Id))
                    } seeAll: {
                        app.pushOnDevice(.playlists)
                    }
                    smartShelf
                    AlbumShelf(title: "Recently Downloaded", items: newAlbums) { open($0) } seeAll: {
                        app.pushOnDevice(.recentlyAdded)
                    }
                    SongColumnsShelf(title: "Favorites", items: favorites) { song in
                        music.play(favorites, startingAt: favorites.position(of: song) ?? 0, title: "Favorites")
                    } seeAll: {
                        app.pushOnDevice(.favorites)
                    }
                    AlbumShelf(title: "Something Different", subtitle: "A random draw from this device", items: randomAlbums) { open($0) }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .task { load() }
        .onChange(of: downloads.records.count) { load() }
        .onChange(of: index.revision) { load(reshuffle: false) }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ListenNowView.greetingText())
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.text)
            Button { surpriseMe() } label: { Label("Surprise Me", systemImage: "shuffle") }
                .appButtonStyle(prominent: true)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// Smart playlists are rules, and a rule can be answered from anywhere.
    @ViewBuilder
    private var smartShelf: some View {
        if !smart.playlists.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                ShelfHeading(title: "Smart Playlists", subtitle: "Answered from your downloads")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                        ForEach(smart.playlists) { list in
                            Button { app.pushOnDevice(.smartPlaylist(list.id)) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: MusicMetrics.tileRadius, style: .continuous)
                                            .fill(Theme.accentSoft)
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 40, weight: .light))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    .frame(width: MusicMetrics.tileWidth, height: MusicMetrics.tileWidth)
                                    Text(list.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                }
                                .frame(width: MusicMetrics.tileWidth, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PosterButtonStyle())
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
            }
        }
    }

    static func count(_ item: BaseItem) -> String? {
        item.ChildCount.map { "\($0) song\($0 == 1 ? "" : "s") here" }
    }

    private func open(_ album: BaseItem) { app.pushOnDevice(.album(album.Id)) }

    private func play(_ station: ListenNowView.Station) {
        Task {
            let result = await MusicMixes.startStation(from: station.seed, title: station.title)
            if !result.started { app.toast("Nothing on this device to build that from", tone: .error) }
        }
    }

    private func surpriseMe() {
        Task {
            let result = await MusicMixes.startSurprise(cover: randomAlbums.randomElement(), localOnly: true)
            if !result.started { app.toast("Nothing on this device to build a mix from yet", tone: .error) }
        }
    }

    /// `reshuffle` is false when only a play count moved: the random shelf
    /// shouldn't redeal itself every time a song ends.
    private func load(reshuffle: Bool = true) {
        let all = OfflineMusic.songs
        hasSongs = !all.isEmpty
        let recent = OfflineMusic.recentlyPlayed(limit: 40)
        recentAlbums = recent.localAlbums()
        topSongs = OfflineMusic.mostPlayed(limit: 24)
        newAlbums = OfflineMusic.recentlyDownloadedAlbums(limit: 20)
        favorites = Array(OfflineMusic.favorites().prefix(24))
        playlists = OfflineMusic.playlists.map { OfflineMusic.playlistItem($0.list, songs: $0.songs) }
        if reshuffle || randomAlbums.isEmpty { randomAlbums = Array(all.shuffled().localAlbums().prefix(16)) }
        stations = Self.stations(recent: recent, top: topSongs, favorites: favorites, all: all)
    }

    /// The online page's stations, from this device's listening — and, for a
    /// device that has played nothing yet, from whatever there is most of.
    static func stations(recent: [BaseItem], top: [BaseItem], favorites: [BaseItem], all: [BaseItem]) -> [ListenNowView.Station] {
        var out = ListenNowView.stations(recent: recent, top: top, favoriteArtists: [], random: [])
        var artists = Set(out.filter { $0.seed.isArtist }.compactMap { $0.seed.Name?.lowercased() })
        var genres = Set(out.filter { $0.seed.isMusicGenre }.compactMap { $0.seed.Name.map(MusicNames.genreKey) })

        for artist in (favorites + all).localArtists() where out.count < 6 {
            guard let name = artist.Name, !artists.contains(name.lowercased()) else { continue }
            artists.insert(name.lowercased())
            out.append(.init(title: "\(name) Station", subtitle: "On this device", seed: artist))
        }
        // Every spelling of a genre counted as one, and named in English.
        let byGenre = Dictionary(grouping: all.flatMap { song in (song.Genres ?? []).map { ($0, song) } }, by: { MusicNames.genreKey($0.0) })
        for (key, entries) in byGenre.sorted(by: { $0.value.count > $1.value.count }) where out.count < 10 {
            guard entries.count >= 5, !genres.contains(key), let first = entries.first else { continue }
            genres.insert(key)
            let name = MusicNames.genreName(first.0)
            out.append(.init(title: "\(name) Mix", subtitle: "\(entries.count) songs to draw from", seed: genreSeed(name, cover: first.1)))
        }
        return out
    }

    private static func genreSeed(_ name: String, cover: BaseItem) -> BaseItem {
        var seed = BaseItem()
        seed.Id = "local-genre:\(name.lowercased())"
        seed.Name = name
        seed.type = "MusicGenre"
        seed.ExternalLogoURL = cover.ExternalLogoURL
        return seed
    }
}

// MARK: - Library

/// The Library page's doors, opening onto what is downloaded.
struct OnDeviceLibraryView: View {
    /// Library → Downloaded, with a server in reach: the same doors onto the
    /// same pages, under its own title and without the offline strip.
    var isDownloadedPage = false

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @State private var downloads = DownloadManager.shared
    @State private var recent: [BaseItem] = []

    private let doors: [LibraryDoors.Door] = [
        .init(title: "Playlists", symbol: "music.note.list", route: .playlists),
        .init(title: "Artists", symbol: "music.mic", route: .artists),
        .init(title: "Albums", symbol: "square.stack", route: .albums),
        .init(title: "Songs", symbol: "music.note", route: .songs),
        .init(title: "Genres", symbol: "guitars", route: .genres),
        .init(title: "Favorites", symbol: "star", route: .favorites),
    ]

    var body: some View {
        // Titled only as a page of its own. As the offline Library it sits
        // inside the Music tab, whose title is the Discover / Library switch.
        if isDownloadedPage {
            content.navigationTitle("Downloaded").paletteBar()
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                LibraryDoors(doors: doors) { app.pushOnDevice($0) }
                    .padding(.top, 12)
                DownloadedStationsShelf()
                if !recent.isEmpty {
                    Text("Recently Downloaded")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    AlbumGrid(items: recent) { app.pushOnDevice(.album($0.Id)) }
                        .padding(.bottom, 24)
                }
            }
        }
        .task { recent = OfflineMusic.recentlyDownloadedAlbums(limit: 24) }
        .onChange(of: downloads.records.count) { recent = OfflineMusic.recentlyDownloadedAlbums(limit: 24) }
    }
}

/// The stations the offline Discover page builds from downloads, and its
/// Surprise Me, on the Downloaded page too — where they can be reached with
/// the server in reach, and are built from the downloads all the same. For
/// a flight, or a plan with a cap on it.
struct DownloadedStationsShelf: View {
    @Environment(AppModel.self) private var app
    @State private var downloads = DownloadManager.shared
    @State private var index = OfflineMusicIndex.shared
    @State private var stations: [ListenNowView.Station] = []
    @State private var albums: [BaseItem] = []
    @State private var isMixing = false

    var body: some View {
        if !stations.isEmpty || !albums.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    ShelfHeading(title: "Your Stations", subtitle: "Built from your downloads")
                    Spacer()
                    Button { surpriseMe() } label: {
                        if isMixing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Surprise Me", systemImage: "shuffle")
                        }
                    }
                    .appButtonStyle(prominent: true)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(isMixing)
                    .padding(.trailing, Metrics.gutter)
                }
                if !stations.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                            ForEach(stations) { station in
                                Button { play(station) } label: {
                                    MixTile(title: station.title, subtitle: station.subtitle, seed: station.seed)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PosterButtonStyle())
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }
                }
            }
            .padding(.top, 24)
            .task { load() }
            .onChange(of: downloads.records.count) { load() }
            .onChange(of: index.revision) { load() }
        } else {
            Color.clear.frame(height: 0)
                .task { load() }
                .onChange(of: downloads.records.count) { load() }
        }
    }

    private func load() {
        let all = OfflineMusic.songs
        guard !all.isEmpty else {
            stations = []
            albums = []
            return
        }
        let recent = OfflineMusic.recentlyPlayed(limit: 40)
        let top = OfflineMusic.mostPlayed(limit: 24)
        let favorites = Array(OfflineMusic.favorites().prefix(24))
        stations = OfflineListenNowView.stations(recent: recent, top: top, favorites: favorites, all: all)
        albums = Array(all.shuffled().localAlbums().prefix(16))
    }

    private func play(_ station: ListenNowView.Station) {
        isMixing = true
        Task {
            defer { isMixing = false }
            let result = await MusicMixes.startStation(from: station.seed, title: station.title, localOnly: true)
            if !result.started { app.toast("Nothing on this device to build that from", tone: .error) }
        }
    }

    /// Surprise Me, from downloads only: a shuffle of everything on the
    /// device that learns from what is finished and skipped.
    private func surpriseMe() {
        isMixing = true
        Task {
            defer { isMixing = false }
            let result = await MusicMixes.startSurprise(cover: albums.randomElement(), localOnly: true)
            if !result.started { app.toast("Nothing downloaded to build a mix from yet", tone: .error) }
        }
    }
}

/// One of the library's long lists, from this device.
struct OnDeviceListView: View {
    enum Kind: Hashable { case artists, albums, recentAlbums, songs, genres, playlists, favorites }
    let kind: Kind

    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var music
    @State private var smart = SmartPlaylistStore.shared
    @State private var items: [BaseItem] = []
    @State private var genres: [(name: String, count: Int)] = []

    private var title: String {
        switch kind {
        case .artists: "Artists"
        case .albums: "Albums"
        case .recentAlbums: "Recently Downloaded"
        case .songs: "Songs"
        case .genres: "Genres"
        case .playlists: "Playlists"
        case .favorites: "Favorites"
        }
    }

    var body: some View {
        #if os(iOS)
        ScrollViewReader { proxy in
            list
                .letterIndex(shown: showsLetterIndex) { letter in
                    // Local lists are whole and sorted by title: the jump is a lookup.
                    guard let hit = LetterIndex.first(in: items, atOrAfter: letter, key: { $0.title.lowercased() }) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(hit.Id, anchor: .top) }
                }
        }
        #else
        list
        #endif
    }

    #if os(iOS)
    private var showsLetterIndex: Bool {
        switch kind {
        case .artists, .albums, .songs: items.count >= LetterIndex.minimumCount
        default: false
        }
    }
    #endif

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch kind {
                case .artists:
                    ForEach(items) { artist in MusicListRow(item: artist) { app.pushOnDevice(.artist(artist.Id)) }.id(artist.Id) }
                case .albums, .recentAlbums:
                    AlbumGrid(items: items) { app.pushOnDevice(.album($0.Id)) }
                case .songs, .favorites:
                    if !items.isEmpty {
                        PlayShuffleBar {
                            music.play(items, title: title)
                        } onShuffle: {
                            music.play(items, shuffle: true, title: title)
                        }
                        .padding(.vertical, 8)
                    }
                    ForEach(items) { song in
                        SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                            music.play(items, startingAt: items.position(of: song) ?? 0, title: title)
                        }
                        .id(song.Id)
                    }
                case .genres:
                    ForEach(genres, id: \.name) { genre in
                        Button { app.pushOnDevice(.genre(id: "local-genre:\(genre.name.lowercased())", name: genre.name)) } label: {
                            HStack {
                                Text(genre.name).foregroundStyle(Theme.text)
                                Spacer()
                                Text("\(genre.count)").font(.caption).monospacedDigit().foregroundStyle(Theme.textDim)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, Metrics.gutter)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPressStyle())
                    }
                case .playlists:
                    ForEach(items) { list in
                        MusicListRow(item: list, subtitle: OfflineListenNowView.count(list)) { app.pushOnDevice(.playlist(list.Id)) }
                    }
                    if !smart.playlists.isEmpty {
                        ShelfHeading(title: "Smart Playlists").padding(.top, 20).padding(.bottom, 6)
                        ForEach(smart.playlists) { list in
                            Button { app.pushOnDevice(.smartPlaylist(list.id)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "sparkles").foregroundStyle(Theme.accent).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(list.name).foregroundStyle(Theme.text).lineLimit(1)
                                        Text(list.summary).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, Metrics.gutter)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowPressStyle())
                        }
                    }
                }
                if isEmpty {
                    EmptyState(symbol: "arrow.down.circle", title: "Nothing downloaded here", message: emptyMessage)
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(title)
        .paletteBar()
        .task { load() }
    }

    private var isEmpty: Bool {
        switch kind {
        case .genres: genres.isEmpty
        case .playlists: items.isEmpty && smart.playlists.isEmpty
        default: items.isEmpty
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .genres: "Genres are read from the server the first time a download is seen online. Nothing downloaded has been yet."
        case .playlists: "Playlists show here once a song in them is downloaded."
        case .favorites: "No downloaded song is a favourite yet. Stars given offline are kept and sent later."
        default: "Only what has been downloaded to this device is shown here."
        }
    }

    private func load() {
        let all = OfflineMusic.songs
        switch kind {
        case .artists:
            items = all.localArtists().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .albums:
            items = all.localAlbums().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentAlbums: items = OfflineMusic.recentlyDownloadedAlbums(limit: 200)
        case .songs: items = all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .favorites: items = OfflineMusic.favorites()
        case .playlists: items = OfflineMusic.playlists.map { OfflineMusic.playlistItem($0.list, songs: $0.songs) }
        case .genres:
            let counts = Dictionary(all.flatMap { $0.Genres ?? [] }.map { ($0, 1) }, uniquingKeysWith: +)
            genres = counts.map { (name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

// MARK: - Album, artist, genre, playlist

/// One collection's page, from this device: a cover, Play and Shuffle, a
/// station, and the songs of it that are here.
struct OnDeviceCollectionView: View {
    enum Kind: Hashable {
        case album(String)
        case artist(String)
        case genre(String)
        case playlist(String)
    }
    let kind: Kind

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music
    @State private var downloads = DownloadManager.shared
    @State private var subject: BaseItem?
    @State private var songs: [BaseItem] = []
    @State private var albums: [BaseItem] = []

    private var isAlbum: Bool { if case .album = kind { true } else { false } }

    var body: some View {
        ScrollView {
            if let subject {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(subject)
                    PlayShuffleBar {
                        music.play(songs, title: subject.title)
                    } onShuffle: {
                        music.play(songs, shuffle: true, title: subject.title)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    if albums.count > 1 {
                        AlbumShelf(title: "Albums", items: albums) { app.pushOnDevice(.album($0.Id)) }
                            .padding(.vertical, 12)
                        ShelfHeading(title: "Songs").padding(.bottom, 6)
                    }
                    ForEach(songs) { song in
                        SongRow(
                            song: song, style: isAlbum ? .album : .full, number: isAlbum ? song.IndexNumber : nil,
                            isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying
                        ) {
                            music.play(songs, startingAt: songs.position(of: song) ?? 0, title: subject.title)
                        }
                    }
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 14)
                }
                .padding(.bottom, 32)
            } else {
                // Reached two ways: with no server, and from Library →
                // Downloaded with one — where "out of reach" would be untrue.
                EmptyState(
                    symbol: client.showsOffline ? "wifi.slash" : "arrow.down.circle",
                    title: "Not on this device",
                    message: client.showsOffline
                        ? "None of this has been downloaded, and the server is out of reach. It opens as usual once you're back online."
                        : "None of this is downloaded any more. It is still in the library."
                )
            }
        }
        .navigationTitle(subject?.title ?? (client.showsOffline ? "Offline" : "Downloaded"))
        .navigationBarTitleDisplayMode(.inline)
        .paletteBar()
        .toolbar {
            if let subject, !songs.isEmpty {
                Menu { MusicItemMenu(item: subject) } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: kind) { load() }
        .onChange(of: downloads.records.count) { load() }
    }

    private var kicker: String {
        switch kind {
        case .album: "Album"
        case .artist: "Artist"
        case .genre: "Genre"
        case .playlist: "Playlist"
        }
    }

    private func header(_ subject: BaseItem) -> some View {
        CollectionHeader(kicker: kicker, title: subject.title, wash: subject) {
            if subject.isArtist {
                ArtistArtwork(item: subject, width: 800)
            } else {
                MusicArtwork(item: subject, width: 800, placeholderSymbol: subject.isMusicGenre ? "guitars" : "music.note")
            }
        } detail: {
            if subject.isAlbum, let artist = subject.AlbumArtist, !artist.isEmpty {
                Button {
                    if let pair = songs.first?.AlbumArtists?.first, let id = pair.Id {
                        app.pushOnDevice(.artist(id))
                    } else {
                        app.pushOnDevice(.artist("local-artist:\(artist.lowercased())"))
                    }
                } label: {
                    Text(artist).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(Theme.link)
                }
                .buttonStyle(.plain)
            }
            Button {
                Task { await MusicMixes.startStation(from: subject, title: "\(subject.title) Station") }
            } label: {
                Label("Start Station", systemImage: "dot.radiowaves.left.and.right")
            }
            .appButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    private var footer: String {
        let total = songs.reduce(0.0) { $0 + $1.runtimeSeconds }
        return "\(songs.count) song\(songs.count == 1 ? "" : "s") on this device, \(AlbumDetailView.minutes(total))"
    }

    private func load() {
        let all = OfflineMusic.songs
        switch kind {
        case .album(let id):
            songs = all.filter { $0.AlbumId == id }.sortedByTrack()
            subject = songs.localAlbums().first.map {
                var album = $0
                album.Genres = songs.first?.Genres
                return album
            }
        case .artist(let id):
            let name = id.hasPrefix("local-artist:") ? String(id.dropFirst("local-artist:".count)) : nil
            let keys = OfflineMusic.artistKeys(id: name == nil ? id : nil, name: name)
            songs = all.filter { !keys.isDisjoint(with: OfflineMusic.artistKeys(of: $0)) }
                .sorted { ($0.userData.PlayCount ?? 0, $1.title) > ($1.userData.PlayCount ?? 0, $0.title) }
            albums = songs.localAlbums()
            subject = songs.first.map { song in
                var artist = BaseItem()
                artist.Id = id
                let pairs = (song.AlbumArtists ?? []) + (song.ArtistItems ?? [])
                artist.Name = pairs.first { $0.Id == id }?.Name ?? song.AlbumArtist ?? name
                artist.type = "MusicArtist"
                artist.ExternalLogoURL = song.ExternalLogoURL
                return artist
            }
        case .genre(let name):
            songs = OfflineMusic.songs(inGenre: name)
            albums = songs.localAlbums()
            subject = songs.first.map { song in
                var genre = BaseItem()
                genre.Id = "local-genre:\(name.lowercased())"
                genre.Name = name
                genre.type = "MusicGenre"
                genre.ExternalLogoURL = song.ExternalLogoURL
                return genre
            }
        case .playlist(let id):
            if let saved = OfflineMusic.playlists.first(where: { $0.list.id == id }) {
                songs = saved.songs
                subject = OfflineMusic.playlistItem(saved.list, songs: saved.songs)
            }
        }
    }
}

// MARK: - Audiobooks

/// The Audiobooks tab with no server: what was being listened to, then every
/// book on the device, by title, with its authors above.
struct OfflineBooksView: View {
    let term: String

    @Environment(AppModel.self) private var app
    @State private var downloads = DownloadManager.shared
    @State private var books: [BaseItem] = []

    private var query: String { term.trimmingCharacters(in: .whitespaces) }
    private var inProgress: [BaseItem] { books.filter { $0.progressFraction != nil } }
    private var authors: [String] { OfflineMusic.authors }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                if books.isEmpty {
                    NothingOnDevice(books: true)
                } else if !query.isEmpty {
                    let found = OfflineMusic.searchBooks(query)
                    if found.isEmpty {
                        EmptyState(symbol: "magnifyingglass", title: "No matches", message: "No downloaded audiobook matches “\(query)”.")
                    } else {
                        AlbumGrid(items: found, subtitleFor: { $0.AlbumArtist ?? $0.artistLine }) { open($0) }
                    }
                } else {
                    AlbumShelf(title: "Continue Listening", items: inProgress, subtitleFor: { BooksTabView.progressLine($0) }) { open($0) }
                    if authors.count > 1 {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "Authors")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(authors, id: \.self) { author in
                                        Button {
                                            app.pushOnDevice(.author(id: "local-author:\(author.lowercased())", name: author))
                                        } label: {
                                            Text(author)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(Theme.text)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(Theme.raised, in: Capsule())
                                                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, Metrics.gutter)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                        ShelfHeading(title: "On This Device", subtitle: "\(books.count) title\(books.count == 1 ? "" : "s")")
                        AlbumGrid(items: books, subtitleFor: { BooksTabView.progressLine($0) ?? $0.AlbumArtist }) { open($0) }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .task { books = OfflineMusic.books }
        .onChange(of: downloads.records) { books = OfflineMusic.books }
    }

    private func open(_ book: BaseItem) { app.pushOnDevice(.audiobook(book.Id)) }
}

// MARK: - Favourites, with or without a server

/// The star on a song. Sent to the server when there is one; when there
/// isn't, kept for a downloaded song and sent by `OfflineMusicIndex.refresh`
/// the next time there is.
@MainActor
enum MusicFavorites {
    enum Outcome { case saved, keptForLater }

    static func set(_ item: BaseItem, favorite: Bool) async throws -> Outcome {
        let client = JellyfinClient.shared
        let isKept = item.isSong && DownloadManager.shared.record(for: item.Id)?.status == .complete
        if !client.isOffline {
            do {
                try await client.setFavorite(item.Id, favorite: favorite)
                if isKept { OfflineMusicIndex.shared.setFavorite(item.Id, favorite, pending: false) }
                return .saved
            } catch {
                guard isKept else { throw error }
            }
        }
        guard isKept else { throw APIError.message("Favourites for music that isn't downloaded need the server") }
        OfflineMusicIndex.shared.setFavorite(item.Id, favorite, pending: true)
        return .keptForLater
    }
}

#endif
