//  Discover: what to play before you have decided what to look for.
//
//  Jellyfin has no recommendation engine; what it has is what you have played,
//  what you have starred, what was added, and a mix it can build from any
//  one thing. This page is those four: what you were in the middle of first,
//  then stations built from what you play most, then your own chart, then
//  the new and the loved.

import SwiftUI

#if os(iOS)

struct ListenNowView: View {
    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    @State private var recentSongs: [BaseItem] = []
    @State private var recentAlbums: [BaseItem] = []
    @State private var topSongs: [BaseItem] = []
    @State private var stations: [Station] = []
    @State private var newAlbums: [BaseItem] = []
    @State private var favoriteAlbums: [BaseItem] = []
    @State private var favoriteArtists: [BaseItem] = []
    @State private var randomAlbums: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var inFlight: Task<Void, Never>?
    @State private var isMixing = false

    /// A mix waiting to be asked for: the thing it is seeded from and what
    /// to call it.
    struct Station: Identifiable, Hashable {
        var id: String { seed.Id }
        var title: String
        var subtitle: String
        var seed: BaseItem
    }

    private var isBare: Bool {
        recentSongs.isEmpty && newAlbums.isEmpty && favoriteAlbums.isEmpty && randomAlbums.isEmpty
    }

    /// The server didn't answer, but there is music on this device: the
    /// offline page rather than an error. `MusicTabView` makes the same swap
    /// once the client has *decided* it is offline; this covers the second or
    /// two before it has, which at a launch with no network is the first
    /// thing anyone sees.
    private var fallsBackToDevice: Bool { error != nil && isBare && OfflineMusic.hasSongs }

    var body: some View {
        Group {
            if fallsBackToDevice { OfflineListenNowView() } else { page }
        }
        .task { await reload() }
        .reloadWhenItemsChange { await reload() }
        .onChange(of: client.isOffline) { _, offline in
            if !offline { Task { await reload() } }
        }
    }

    private var page: some View {
        ScrollView {
            if isLoading, isBare {
                VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    SkeletonShelf()
                    SkeletonShelf()
                    SkeletonShelf()
                }
                .padding(.top, 12)
            } else if let error, isBare {
                ErrorState(error: error) { Task { await reload() } }
            } else if isBare {
                EmptyState(
                    symbol: "music.note.list",
                    title: "Nothing to suggest yet",
                    message: "Once your music library has been scanned, and once you've played a few things, this page fills in with what to play next."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    greeting
                    AlbumShelf(title: "Recently Played", items: recentAlbums) { open($0) } seeAll: {
                        app.push(.music(.songList(title: "Recently Played", kind: .recentlyPlayed)))
                    }
                    if !stations.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                            ShelfHeading(title: "Your Stations", subtitle: "Built from what you play")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                                    ForEach(stations) { station in
                                        Button { Task { await play(station) } } label: {
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
                        app.push(.music(.songList(title: "Most Played", kind: .mostPlayed)))
                    }
                    AlbumShelf(title: "New in Your Library", items: newAlbums) { open($0) } seeAll: {
                        app.push(.music(.recentlyAdded))
                    }
                    AlbumShelf(title: "Favorite Albums", items: favoriteAlbums) { open($0) } seeAll: {
                        app.push(.music(.favorites))
                    }
                    ArtistShelf(title: "Favorite Artists", items: favoriteArtists) { app.push(.music(.artist($0.Id))) }
                    AlbumShelf(title: "Something Different", subtitle: "A random draw from the shelves", items: randomAlbums) { open($0) }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .refreshable { await reload() }
    }

    /// The time of day, and under it the one button that needs no choosing
    /// first: a mix from nothing in particular. Under rather than beside —
    /// "Good Afternoon" at this size already spans most of a phone.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.greetingText())
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.text)
            Button {
                Task { await surpriseMe() }
            } label: {
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
        }
        .padding(.horizontal, Metrics.gutter)
    }

    static func greetingText(now: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        default: return "Good Evening"
        }
    }

    private func open(_ album: BaseItem) {
        app.push(.music(.album(album.Id)))
    }

    private func play(_ station: Station) async {
        let result = await MusicMixes.startStation(from: station.seed, title: station.title)
        guard result.started else { return app.toast("The server couldn't build that station", tone: .error) }
        if result.isLocal { app.toast("The server didn't answer — mixed from your downloads", tone: .info) }
    }

    /// A mix with nothing picked first. One of the stations the page already
    /// worked out from what this account plays, chosen at random — and for an
    /// account that hasn't played or starred anything yet, a random album is
    /// as good a seed as any.
    private func surpriseMe() async {
        isMixing = true
        defer { isMixing = false }
        if let station = stations.randomElement() {
            await play(station)
            return
        }
        guard let album = randomAlbums.randomElement() else {
            return app.toast("Nothing in the library to build a mix from yet", tone: .error)
        }
        let result = await MusicMixes.startStation(from: album, title: "Surprise Mix")
        guard result.started else { return app.toast("The server couldn't build a mix", tone: .error) }
    }

    private func reload() async {
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await load() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func load() async {
        guard client.isSignedIn else { return }
        error = nil
        isLoading = true
        defer { isLoading = false }

        async let recentTask = client.recentlyPlayedSongs(limit: 40)
        async let topTask = client.mostPlayedSongs(limit: 24)
        async let newTask = client.music(.init(types: "MusicAlbum", sort: .recentlyAdded, limit: 20))
        async let favAlbumsTask = client.music({ var q = JellyfinClient.MusicQuery(types: "MusicAlbum", sort: .name, limit: 20); q.favorites = true; return q }())
        async let favArtistsTask = client.albumArtists(limit: 20, favorites: true)
        async let randomTask = client.music(.init(types: "MusicAlbum", sort: .random, limit: 16))

        var failure: (any Error)?
        do {
            let songs = try await recentTask
            recentSongs = songs
            recentAlbums = songs.albumsInOrder()
        } catch { failure = failure ?? error }
        do { topSongs = try await topTask } catch { failure = failure ?? error }
        do { newAlbums = try await newTask.items } catch { failure = failure ?? error }
        do { favoriteAlbums = try await favAlbumsTask.items } catch { failure = failure ?? error }
        do { favoriteArtists = try await favArtistsTask.items } catch { failure = failure ?? error }
        do { randomAlbums = try await randomTask.items } catch { failure = failure ?? error }

        let sortNames = await Self.artistSortNames(songs: topSongs + recentSongs)
        stations = Self.stations(
            recent: recentSongs, top: topSongs, favoriteArtists: favoriteArtists, random: randomAlbums, sortNames: sortNames
        )
        if let failure, isBare { error = failure.localizedDescription }
    }

    /// Stations worth offering, from what the account has done: the artists
    /// it plays most, the genres those songs are in, the artists it starred.
    /// Nothing is fetched to build these — each is a seed the server can
    /// grow when tapped.
    /// The server's sort names for the artists stations are about to be
    /// named after, when any of them is written in a non-Latin script: a
    /// MusicBrainz sort name is usually the romanised one. One request, and
    /// none at all for a library whose names are Latin already.
    static func artistSortNames(songs: [BaseItem]) async -> [String: String] {
        guard Preferences.shared.musicRomanizeNames else { return [:] }
        let pairs = songs.prefix(24).compactMap { $0.ArtistItems?.first ?? $0.AlbumArtists?.first }
        let ids = Array(Set(pairs.filter { !MusicNames.isLatin($0.Name ?? "") }.compactMap(\.Id)))
        guard !ids.isEmpty, let items = try? await JellyfinClient.shared.itemsByIds(ids, fields: "SortName") else { return [:] }
        return Dictionary(items.compactMap { i in i.SortName.map { (i.Id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    static func stations(
        recent: [BaseItem], top: [BaseItem], favoriteArtists: [BaseItem], random: [BaseItem],
        sortNames: [String: String] = [:]
    ) -> [Station] {
        var out: [Station] = []
        var seenArtists = Set<String>()
        var seenGenres = Set<String>()

        func addArtist(_ pair: NameGuidPair?, from song: BaseItem, why: String) {
            guard let pair, let id = pair.Id, let name = pair.Name, !seenArtists.contains(id) else { return }
            seenArtists.insert(id)
            var seed = BaseItem()
            seed.Id = id
            seed.Name = name
            seed.type = "MusicArtist"
            // Borrow the song's cover: an artist reached this way has no
            // picture of its own to hand, and the sleeve of a song you play
            // by them is a fair stand-in.
            seed.AlbumId = song.AlbumId
            seed.AlbumPrimaryImageTag = song.AlbumPrimaryImageTag
            seed.ImageBlurHashes = song.ImageBlurHashes
            // A downloaded song's cover is a file; see `DownloadRecord.asItem`.
            seed.ExternalLogoURL = song.ExternalLogoURL
            let shown = MusicNames.artistName(name, sortName: sortNames[id])
            out.append(Station(title: "\(shown) Station", subtitle: why, seed: seed))
        }

        for song in top.prefix(12) where out.count < 3 {
            addArtist(song.ArtistItems?.first ?? song.AlbumArtists?.first, from: song, why: "Because you play them a lot")
        }
        for song in recent.prefix(12) where out.count < 5 {
            addArtist(song.ArtistItems?.first ?? song.AlbumArtists?.first, from: song, why: "From your recent listening")
        }
        for artist in favoriteArtists.prefix(6) where out.count < 7 {
            guard !seenArtists.contains(artist.Id) else { continue }
            seenArtists.insert(artist.Id)
            let shown = MusicNames.artistName(artist.title, sortName: artist.SortName)
            out.append(Station(title: "\(shown) Station", subtitle: "A favourite of yours", seed: artist))
        }
        for song in (top + recent) where out.count < 9 {
            guard let genre = song.GenreItems?.first ?? {
                // The list query returns names only; a genre with no id can
                // still seed a mix once a song of it is the seed.
                song.Genres?.first.map { NameGuidPair(Id: nil, Name: $0) }
            }() else { continue }
            // One station per genre however many ways the tags spell it, named
            // in English, and grown from the genre itself, every spelling.
            guard let raw = genre.Name, !raw.isEmpty else { continue }
            let key = MusicNames.genreKey(raw)
            guard !seenGenres.contains(key) else { continue }
            seenGenres.insert(key)
            let name = MusicNames.genreName(raw)
            var seed = BaseItem()
            seed.Id = genre.Id ?? "\(StationBuilder.genrePrefix)\(key)"
            seed.Name = name
            seed.type = "MusicGenre"
            seed.AlbumId = song.AlbumId
            seed.AlbumPrimaryImageTag = song.AlbumPrimaryImageTag
            seed.ImageBlurHashes = song.ImageBlurHashes
            seed.ExternalLogoURL = song.ExternalLogoURL
            out.append(Station(title: "\(name) Mix", subtitle: "Songs like the ones you play", seed: seed))
        }
        // The stations about this account rather than any one thing.
        let covers = (top + recent).filter { $0.AlbumPrimaryImageTag != nil || $0.ExternalLogoURL != nil }
        for (i, special) in SpecialStation.available().enumerated() where !(top + recent).isEmpty {
            let cover = covers.isEmpty ? nil : covers[(i * 5 + 3) % covers.count]
            out.append(Station(title: special.title, subtitle: special.subtitle, seed: special.seed(cover: cover)))
        }
        if out.isEmpty, let album = random.first {
            out.append(Station(title: "\(album.title) Station", subtitle: "Somewhere to start", seed: album))
        }
        return out
    }
}

#endif
