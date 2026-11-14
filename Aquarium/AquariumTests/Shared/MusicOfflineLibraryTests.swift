//  The music library on this device: what the downloads and the facts kept
//  beside them answer when there is no server to ask — the shelves, albums,
//  artists, genres, playlists, search, smart playlists, books and mixes.
//
//  The downloads are records put in through the manager's test door, each
//  with a file of silence; the facts are what the server "said" about them.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicOfflineLibraryTests: XCTestCase {
    private var index: OfflineMusicIndex { .shared }

    // Five songs the index knows about, and one downloaded before there was
    // an index: a name, an artist's name and nothing else.
    private var bohemian: BaseItem {
        MusicFixture.song(
            "q1", "Bohemian Rhapsody", artist: "Queen", artistId: "queen", album: "A Night at the Opera", albumId: "al1",
            genres: ["Rock"], year: 1975, plays: 9, favorite: true, lastPlayed: MusicFixture.daysAgo(1),
            added: MusicFixture.daysAgo(400), track: 2, disc: 1
        )
    }
    private var death: BaseItem {
        MusicFixture.song(
            "q2", "Death on Two Legs", artist: "Queen", artistId: "queen", album: "A Night at the Opera", albumId: "al1",
            genres: ["Rock"], year: 1975, plays: 0, favorite: false, added: MusicFixture.daysAgo(400), track: 1, disc: 1
        )
    }
    private var pressure: BaseItem {
        var song = MusicFixture.song(
            "q3", "Under Pressure", artist: "Queen", artistId: "queen", album: "Hot Space", albumId: "al2",
            genres: ["Rock", "Pop"], year: 1982, plays: 3, favorite: false, lastPlayed: MusicFixture.daysAgo(10),
            added: MusicFixture.daysAgo(20), track: 1, disc: 1
        )
        song.ArtistItems?.append(NameGuidPair(Id: "bowie", Name: "David Bowie"))
        song.HasLyrics = true
        return song
    }
    private var dancing: BaseItem {
        MusicFixture.song(
            "a1", "Dancing Queen", artist: "ABBA", artistId: "abba", album: "Arrival", albumId: "al3",
            genres: ["Pop"], year: 1976, plays: 5, favorite: true, lastPlayed: MusicFixture.daysAgo(3),
            added: MusicFixture.daysAgo(5), track: 2, disc: 1
        )
    }
    private var soWhat: BaseItem {
        MusicFixture.song(
            "j1", "So What", artist: "Miles Davis", artistId: "miles", album: "Kind of Blue", albumId: "al4",
            genres: ["Jazz"], year: 1959, plays: 0, favorite: false, added: MusicFixture.daysAgo(2), track: 1, disc: 1
        )
    }
    private var mystery: BaseItem {
        var song = MusicFixture.song("old", "Mystery", artist: "Unknown Band")
        song.ArtistItems = nil
        song.AlbumArtists = nil
        return song
    }

    override func setUp() async throws {
        MusicServer.install()
        await index.ensureLoaded()
    }

    override func tearDown() async throws {
        MusicPlayer.shared.stop(tellServer: false)
        await MusicOnDevice.forgetEverything()
        MusicServer.remove()
    }

    /// The six songs, downloaded an hour apart with the jazz newest, and the
    /// facts for five of them.
    private func downloadLibrary() {
        let known = [death, bohemian, pressure, dancing, soWhat]
        MusicOnDevice.add(mystery, created: Date().addingTimeInterval(-6 * 3600))
        for (i, song) in known.enumerated() {
            MusicOnDevice.add(song, created: Date().addingTimeInterval(Double(i - 5) * 3600))
        }
        index.note(known)
    }

    private func ids(_ items: [BaseItem]) -> [String] { items.map(\.Id) }
    private func song(_ id: String) -> BaseItem? { OfflineMusic.songs.first { $0.Id == id } }

    // MARK: Songs

    func testNothingDownloadedIsAnEmptyLibrary() {
        XCTAssertFalse(OfflineMusic.hasSongs)
        XCTAssertTrue(OfflineMusic.songs.isEmpty)
        XCTAssertTrue(OfflineMusic.genres.isEmpty)
        XCTAssertTrue(OfflineMusic.playlists.isEmpty)
        XCTAssertTrue(OfflineMusic.mix(from: bohemian).isEmpty)
        XCTAssertNil(StationBuilder.local(from: bohemian, title: "Mix"))
    }

    func testADownloadedSongCarriesWhatTheIndexKnowsAboutIt() throws {
        downloadLibrary()
        XCTAssertTrue(OfflineMusic.hasSongs)
        XCTAssertEqual(Set(ids(OfflineMusic.songs)), ["q1", "q2", "q3", "a1", "j1", "old"])
        let q1 = try XCTUnwrap(song("q1"))
        XCTAssertEqual(q1.Name, "Bohemian Rhapsody")
        XCTAssertTrue(q1.isSong)
        XCTAssertEqual(q1.Album, "A Night at the Opera")
        XCTAssertEqual(q1.AlbumId, "al1")
        XCTAssertEqual(q1.IndexNumber, 2)
        XCTAssertEqual(q1.ProductionYear, 1975)
        XCTAssertEqual(q1.Genres, ["Rock"])
        XCTAssertEqual(q1.ArtistItems?.first?.Id, "queen")
        XCTAssertEqual(q1.AlbumArtists?.first?.Id, "queen")
        XCTAssertEqual(q1.userData.isFavorite, true)
        XCTAssertEqual(q1.userData.PlayCount, 9)
        XCTAssertTrue(q1.userData.played)
        XCTAssertEqual(song("q3")?.HasLyrics, true)
        XCTAssertEqual(song("q3")?.Artists, ["Queen", "David Bowie"])
        XCTAssertEqual(song("q2")?.userData.played, false)
    }

    func testASongTheIndexKnowsNothingAboutIsStillListedByItsRecord() throws {
        downloadLibrary()
        let old = try XCTUnwrap(song("old"))
        XCTAssertEqual(old.Name, "Mystery")
        XCTAssertEqual(old.Artists, ["Unknown Band"])
        XCTAssertNil(old.Genres)
        XCTAssertNil(old.ArtistItems)
        XCTAssertFalse(old.userData.played)
    }

    func testOnlyFinishedSongDownloadsAreTheLibrary() {
        MusicOnDevice.add(bohemian)
        MusicOnDevice.add(death, status: .queued)
        MusicOnDevice.add(pressure, status: .error)
        MusicOnDevice.add(MusicFixture.book("b1"))
        MusicOnDevice.add(MusicFixture.item("film", "A Film", type: "Movie"))
        XCTAssertEqual(ids(OfflineMusic.songs), ["q1"])
        XCTAssertEqual(ids(OfflineMusic.books), ["b1"])
    }

    func testTheSongListKeepsUpWithDownloadsAndWithTheIndex() {
        MusicOnDevice.add(bohemian)
        XCTAssertEqual(OfflineMusic.songs.count, 1)
        XCTAssertNil(song("q1")?.Genres)
        index.note([bohemian])
        XCTAssertEqual(song("q1")?.Genres, ["Rock"], "the facts arrived after the list was first built")
        MusicOnDevice.add(death)
        XCTAssertEqual(OfflineMusic.songs.count, 2)
        DownloadManager.shared.delete("q1")
        XCTAssertEqual(ids(OfflineMusic.songs), ["q2"])
    }

    // MARK: Shelves

    func testRecentlyPlayedIsNewestFirstAndOnlyWhatHasBeenPlayed() {
        downloadLibrary()
        XCTAssertEqual(ids(OfflineMusic.recentlyPlayed()), ["q1", "a1", "q3"])
        XCTAssertEqual(ids(OfflineMusic.recentlyPlayed(limit: 2)), ["q1", "a1"])
    }

    func testMostPlayedIsByCountAndLeavesOutTheNeverPlayed() {
        downloadLibrary()
        XCTAssertEqual(ids(OfflineMusic.mostPlayed()), ["q1", "a1", "q3"])
        XCTAssertEqual(ids(OfflineMusic.mostPlayed(limit: 1)), ["q1"])
    }

    func testFavouritesAreByTitle() {
        downloadLibrary()
        XCTAssertEqual(ids(OfflineMusic.favorites()), ["q1", "a1"])
    }

    func testRecentlyDownloadedAlbumsAreNewestFirstOneEntryEach() {
        downloadLibrary()
        let albums = OfflineMusic.recentlyDownloadedAlbums()
        XCTAssertEqual(ids(albums), ["al4", "al3", "al2", "al1"], "a song with no album is on no shelf of albums")
        XCTAssertEqual(albums.first?.Name, "Kind of Blue")
        XCTAssertEqual(albums.first?.AlbumArtist, "Miles Davis")
        XCTAssertTrue(albums.allSatisfy(\.isAlbum))
        XCTAssertEqual(ids(OfflineMusic.recentlyDownloadedAlbums(limit: 2)), ["al4", "al3"])
    }

    // MARK: Albums, artists, genres

    func testAnAlbumsTracksAreInSleeveOrder() {
        downloadLibrary()
        XCTAssertEqual(ids(OfflineMusic.albumTracks(albumId: "al1")), ["q2", "q1"])
        XCTAssertTrue(OfflineMusic.albumTracks(albumId: "nowhere").isEmpty)
    }

    func testAnArtistsSongsAreFoundByIdOrByName() {
        downloadLibrary()
        XCTAssertEqual(Set(ids(OfflineMusic.songs(byArtist: MusicFixture.artist("queen", "A Different Spelling")))), ["q1", "q2", "q3"])
        XCTAssertEqual(ids(OfflineMusic.songs(byArtist: MusicFixture.artist("bowie", "David Bowie"))), ["q3"], "a guest counts")
        XCTAssertEqual(ids(OfflineMusic.songs(byArtist: MusicFixture.artist("local-artist:unknown band", "Unknown Band"))), ["old"])
        XCTAssertEqual(ids(OfflineMusic.songs(byArtist: MusicFixture.artist("someone-else", "abba"))), ["a1"], "a name matches whatever its case")
    }

    func testGenresAreListedOnceInOrderAndFoundWhateverTheCase() {
        downloadLibrary()
        XCTAssertEqual(OfflineMusic.genres, ["Jazz", "Pop", "Rock"])
        XCTAssertEqual(Set(ids(OfflineMusic.songs(inGenre: "rock"))), ["q1", "q2", "q3"])
        XCTAssertEqual(Set(ids(OfflineMusic.songs(inGenre: "POP"))), ["q3", "a1"])
        XCTAssertTrue(OfflineMusic.songs(inGenre: "Polka").isEmpty)
    }

    func testWhatAMenuPlaysForEachKindOfThing() {
        downloadLibrary()
        MusicOnDevice.add(MusicFixture.book("b1", "A Book"))
        XCTAssertEqual(ids(OfflineMusic.songs(for: bohemian)), ["q1"])
        XCTAssertEqual(ids(OfflineMusic.songs(for: MusicFixture.album("al1", "A Night at the Opera"))), ["q2", "q1"])
        XCTAssertEqual(Set(ids(OfflineMusic.songs(for: MusicFixture.artist("abba", "ABBA")))), ["a1"])
        XCTAssertEqual(ids(OfflineMusic.songs(for: MusicFixture.genre("g", "Jazz"))), ["j1"])
        XCTAssertEqual(ids(OfflineMusic.songs(for: MusicFixture.book("b1"))), ["b1"])
        XCTAssertTrue(OfflineMusic.songs(for: MusicFixture.book("not-here")).isEmpty)
        XCTAssertTrue(OfflineMusic.songs(for: MusicFixture.song("not-here")).isEmpty)
        XCTAssertTrue(OfflineMusic.songs(for: MusicFixture.playlist("not-here", "Nope")).isEmpty)
        XCTAssertTrue(OfflineMusic.songs(for: MusicFixture.item("film", "A Film", type: "Movie")).isEmpty)
    }

    func testArtistsOfAListAreOneEachMostSongsFirst() {
        downloadLibrary()
        let artists = [bohemian, dancing, death, mystery, pressure].map { song($0.Id)! }.localArtists()
        XCTAssertEqual(artists.first?.Name, "Queen")
        XCTAssertEqual(Set(artists.map(\.Name)), ["Queen", "ABBA", "Unknown Band"])
        XCTAssertEqual(Set(ids(artists)), ["queen", "abba", "local-artist:unknown band"], "an artist known only by name gets an id that says so")
        XCTAssertTrue(artists.allSatisfy(\.isArtist))
    }

    func testAlbumsOfAListAreOneEachInTheOrderGiven() {
        downloadLibrary()
        let albums = [dancing, bohemian, death, mystery].map { song($0.Id)! }.localAlbums()
        XCTAssertEqual(ids(albums), ["al3", "al1"])
        XCTAssertEqual(albums.map(\.AlbumArtist), ["ABBA", "Queen"])
        XCTAssertEqual(albums[1].ProductionYear, 1975)
    }

    // MARK: Playlists

    /// The server has two playlists; only one has anything downloaded in it.
    private func learnPlaylists() async {
        let known = [death, bohemian, pressure, dancing, soWhat]
        MusicServer.answer { call in
            switch call.path {
            case "/Items" where call.query["IncludeItemTypes"] == "Playlist":
                return .items([MusicFixture.playlist("pl1", "Mix Tape"), MusicFixture.playlist("pl2", "Not Here")])
            case "/Items" where call.query["Ids"] != nil:
                let wanted = Set((call.query["Ids"] ?? "").split(separator: ",").map(String.init))
                return .items(known.filter { wanted.contains($0.Id) })
            case "/Playlists/pl1/Items":
                return .items([MusicFixture.song("a1"), MusicFixture.song("elsewhere"), MusicFixture.song("q1")])
            case "/Playlists/pl2/Items":
                return .items([MusicFixture.song("elsewhere")])
            default:
                return nil
            }
        }
        await index.refresh(force: true)
    }

    func testOnlyPlaylistsWithSomethingDownloadedAreOfferedInTheirOwnOrder() async throws {
        downloadLibrary()
        await learnPlaylists()
        XCTAssertEqual(index.playlists.map(\.id), ["pl1", "pl2"], "all are kept: which have songs here changes with every download")
        XCTAssertEqual(index.playlists.first?.itemIds, ["a1", "elsewhere", "q1"])
        let offered = OfflineMusic.playlists
        XCTAssertEqual(offered.map(\.list.name), ["Mix Tape"])
        XCTAssertEqual(ids(offered[0].songs), ["a1", "q1"])
        XCTAssertEqual(ids(OfflineMusic.playlistSongs("pl1")), ["a1", "q1"])
        XCTAssertTrue(OfflineMusic.playlistSongs("pl2").isEmpty)
        XCTAssertEqual(ids(OfflineMusic.songs(for: MusicFixture.playlist("pl1", "Mix Tape"))), ["a1", "q1"])

        let tile = OfflineMusic.playlistItem(offered[0].list, songs: offered[0].songs)
        XCTAssertEqual(tile.Id, "pl1")
        XCTAssertEqual(tile.Name, "Mix Tape")
        XCTAssertTrue(tile.isPlaylist)
        XCTAssertEqual(tile.ChildCount, 2)
        XCTAssertTrue(tile.isAudio)
    }

    // MARK: Search

    func testSearchLooksAtSongNamesAlbumNamesArtistsAndPlaylists() async {
        downloadLibrary()
        await learnPlaylists()
        let queen = OfflineMusic.search("queen")
        XCTAssertEqual(ids(queen.songs), ["a1"], "Dancing Queen, by its name")
        XCTAssertEqual(queen.artists.map(\.Name), ["Queen"])
        XCTAssertTrue(queen.albums.isEmpty)
        XCTAssertEqual(ids(OfflineMusic.search("OPERA").albums), ["al1"])
        XCTAssertEqual(OfflineMusic.search("mix").playlists.map(\.Name), ["Mix Tape"])
        XCTAssertEqual(OfflineMusic.search("mix").playlists.first?.ChildCount, 2)
        XCTAssertEqual(ids(OfflineMusic.search(" mystery ").songs), ["old"], "spaces around the term are not part of it")
    }

    func testSearchForNothingFindsNothing() {
        downloadLibrary()
        let nothing = OfflineMusic.search("   ")
        XCTAssertTrue(nothing.songs.isEmpty && nothing.albums.isEmpty && nothing.artists.isEmpty && nothing.playlists.isEmpty)
        XCTAssertTrue(OfflineMusic.search("zzzz").songs.isEmpty)
    }

    func testSearchStopsAtTheLimit() {
        downloadLibrary()
        XCTAssertEqual(OfflineMusic.search("e", limit: 2).songs.count, 2)
    }

    // MARK: Smart playlists, answered here

    private func resolve(_ change: (inout SmartPlaylist) -> Void) -> [String] {
        var rule = SmartPlaylist()
        rule.sort = .name
        change(&rule)
        return ids(OfflineMusic.resolve(rule))
    }

    func testAnEmptyRuleIsEveryDownloadedSongByTitle() {
        downloadLibrary()
        XCTAssertEqual(resolve { _ in }, ["q1", "a1", "q2", "old", "j1", "q3"])
    }

    func testARuleNarrowsByGenreAndByArtist() {
        downloadLibrary()
        XCTAssertEqual(resolve { $0.genres = ["rock"] }, ["q1", "q2", "q3"])
        XCTAssertEqual(resolve { $0.genres = ["Jazz", "Pop"] }, ["a1", "j1", "q3"], "any of them")
        XCTAssertEqual(resolve { $0.artists = [NameGuidPair(Id: "abba", Name: nil)] }, ["a1"])
        XCTAssertEqual(resolve { $0.artists = [NameGuidPair(Id: nil, Name: "Unknown Band")] }, ["old"])
        XCTAssertEqual(resolve { $0.artists = [NameGuidPair(Id: "bowie", Name: "David Bowie")]; $0.genres = ["Pop"] }, ["q3"])
    }

    func testARuleNarrowsByYearsEitherWayRound() {
        downloadLibrary()
        XCTAssertEqual(resolve { $0.yearFrom = 1976; $0.yearTo = 1975 }, ["q1", "a1", "q2"])
        XCTAssertEqual(resolve { $0.yearFrom = 1975 }, ["q1", "q2"], "one year given is that year, as the server reads it")
        XCTAssertEqual(resolve { $0.yearTo = 1959 }, ["j1"])
    }

    func testAddedWithinGoesByTheLibraryDateOrFailingThatTheDownload() {
        downloadLibrary()
        XCTAssertEqual(resolve { $0.addedWithinDays = 30 }, ["a1", "old", "j1", "q3"], "the song the index never heard of was downloaded today")
        XCTAssertEqual(resolve { $0.addedWithinDays = 3 }, ["old", "j1"])
    }

    func testARuleNarrowsByStarsAndPlays() {
        downloadLibrary()
        XCTAssertEqual(resolve { $0.favoritesOnly = true }, ["q1", "a1"])
        XCTAssertEqual(resolve { $0.played = .played }, ["q1", "a1", "q3"])
        XCTAssertEqual(resolve { $0.played = .unplayed }, ["q2", "old", "j1"])
        XCTAssertEqual(resolve { $0.minPlayCount = 4 }, ["q1", "a1"])
        XCTAssertEqual(resolve { $0.minPlayCount = 0 }.count, 6)
        XCTAssertEqual(resolve { $0.favoritesOnly = true; $0.genres = ["Pop"]; $0.minPlayCount = 5 }, ["a1"])
    }

    func testARulesOrderAndLimit() {
        downloadLibrary()
        XCTAssertEqual(resolve { $0.sort = .mostPlayed; $0.limit = 3 }, ["q1", "a1", "q3"])
        XCTAssertEqual(resolve { $0.sort = .recentlyPlayed; $0.limit = 3 }, ["q1", "a1", "q3"])
        XCTAssertEqual(resolve { $0.sort = .recentlyAdded; $0.limit = 4 }, ["old", "j1", "a1", "q3"])
        XCTAssertEqual(resolve { $0.sort = .year; $0.genres = ["Rock", "Pop", "Jazz"] }.first, "q3")
        XCTAssertEqual(resolve { $0.sort = .year; $0.genres = ["Rock", "Pop", "Jazz"] }.last, "j1")
        XCTAssertEqual(resolve { $0.sort = .artist }, ["a1", "j1", "q2", "q1", "q3", "old"], "artist, album, then the sleeve")
        XCTAssertEqual(resolve { $0.limit = 2 }, ["q1", "a1"])
        XCTAssertEqual(Set(resolve { $0.sort = .random }), ["q1", "q2", "q3", "a1", "j1", "old"])
    }

    // MARK: Mixes from what is here

    func testAMixOfADownloadedSongStartsWithItAndIsAllDownloads() {
        downloadLibrary()
        let mix = ids(OfflineMusic.mix(from: bohemian))
        XCTAssertEqual(mix.first, "q1")
        XCTAssertEqual(Set(mix).count, mix.count)
        XCTAssertEqual(Set(mix), ["q1", "q2", "q3", "a1", "j1", "old"], "a thin library is topped up with whatever else is here")
        XCTAssertEqual(ids(OfflineMusic.mix(from: bohemian, limit: 3)).count, 3)
    }

    func testAMixOfAnArtistLeadsWithTheirSongs() {
        downloadLibrary()
        let mix = ids(OfflineMusic.mix(from: MusicFixture.artist("queen", "Queen")))
        XCTAssertEqual(mix.count, 6)
        XCTAssertTrue(["q1", "q2", "q3"].contains(mix[0]), "\(mix)")
    }

    func testALocalStationKnowsItIsLocalAndReadsTheSeedFromTheDevice() throws {
        downloadLibrary()
        // The seed as a row would hand it over: no genres, no year.
        let bare = MusicFixture.song("q1", "Bohemian Rhapsody", artist: "Queen")
        let station = try XCTUnwrap(StationBuilder.local(from: bare, title: "Bohemian Rhapsody Mix"))
        XCTAssertTrue(station.isLocal)
        XCTAssertEqual(station.title, "Bohemian Rhapsody Mix")
        XCTAssertEqual(station.pool.count, 6)
        XCTAssertEqual(station.profile.genres, ["rock": 1], "what the device knows about the song beats what the seed says")
        XCTAssertEqual(station.profile.year, 1975)
        XCTAssertEqual(station.profile.songId, "q1")
    }

    func testALocalStationOfAnArtistOrAnAlbumIsMeasuredAgainstTheirSongsHere() throws {
        downloadLibrary()
        let ofArtist = try XCTUnwrap(StationBuilder.local(from: MusicFixture.artist("queen", "Queen"), title: "Queen"))
        XCTAssertTrue(ofArtist.profile.isArtistStation)
        XCTAssertEqual(ofArtist.profile.genres, ["rock": 3, "pop": 1])
        let ofAlbum = try XCTUnwrap(StationBuilder.local(from: MusicFixture.album("al3", "Arrival"), title: "Arrival"))
        XCTAssertEqual(ofAlbum.profile.albumId, "al3")
        XCTAssertEqual(ofAlbum.profile.genres, ["pop": 1])
        XCTAssertEqual(ofAlbum.profile.year, 1976)
        let ofGenre = try XCTUnwrap(StationBuilder.local(from: MusicFixture.genre("g", "Rockmusik"), title: "Rock"))
        XCTAssertEqual(ofGenre.profile.genres, ["rock": 1])
    }

    func testRediscoverHereIsStarredAndMostPlayedSongsNotHeardLately() throws {
        downloadLibrary()
        // Starred long ago and not played in months.
        let forgotten = MusicFixture.song("f1", "Forgotten", plays: 2, favorite: true, lastPlayed: MusicFixture.daysAgo(90))
        MusicOnDevice.add(forgotten)
        index.note([forgotten])
        let station = try XCTUnwrap(StationBuilder.local(from: SpecialStation.rediscover.seed(cover: nil), title: "Rediscover"))
        XCTAssertTrue(station.profile.isOpen)
        XCTAssertTrue(station.pool.keys.contains("f1"))
        XCTAssertTrue(Set(station.pool.keys).isDisjoint(with: ["q2", "j1", "old"]), "never starred, never played")
        XCTExpectFailure("bug: Rediscover from downloads never leaves out what was played lately: OfflineMusic.item (OfflineMusic.swift:566) does not carry the index's lastPlayed onto the song, so StationBuilder.isForgotten (Stations.swift:309, used at :351) always says yes") {
            XCTAssertEqual(Set(station.pool.keys), ["f1"], "everything else starred or played was heard in the last six weeks")
        }
    }

    func testDeepCutsHereIsUnplayedSongsByArtistsThatAreStarredOrPlayed() throws {
        downloadLibrary()
        let station = try XCTUnwrap(StationBuilder.local(from: SpecialStation.deepCuts.seed(cover: nil), title: "Deep Cuts"))
        XCTAssertTrue(station.profile.isOpen)
        XCTAssertEqual(Set(station.pool.keys), ["q2"], "the one Queen song never played; nobody plays Miles Davis here")
    }

    // MARK: Audiobooks

    private func downloadBooks() {
        let zen = MusicFixture.book("b1", "Zen and the Art", author: "Robert Pirsig", seconds: 36_000)
        MusicOnDevice.add(zen, positionSeconds: 600)
        MusicOnDevice.add(MusicFixture.book("b2", "Alpha Tales", author: "Douglas Adams", seconds: 7200))
        var full = MusicFixture.book("b1", "Zen and the Art of Motorcycle Maintenance", author: "Robert Pirsig", seconds: 36_000, chapters: [0, 1800, 3600], positionSeconds: 30)
        full.Overview = "An inquiry into values."
        full.MediaSources = [MediaSource(Id: "src")]
        OfflineBooks.keep(full)
    }

    func testBooksAreListedByTitleWithWhatWasKeptBesideThem() throws {
        downloadBooks()
        XCTAssertEqual(ids(OfflineMusic.books), ["b2", "b1"])
        let zen = try XCTUnwrap(OfflineMusic.book("b1"))
        XCTAssertEqual(zen.Name, "Zen and the Art of Motorcycle Maintenance", "the saved item is fuller than the record")
        XCTAssertEqual(zen.Chapters?.count, 3)
        XCTAssertEqual(zen.Overview, "An inquiry into values.")
        XCTAssertEqual(zen.userData.positionTicks, 600 * 10_000_000, "but the place in it is this device's")
        XCTAssertNil(zen.MediaSources)
        let plain = try XCTUnwrap(OfflineMusic.book("b2"))
        XCTAssertEqual(plain.Name, "Alpha Tales")
        XCTAssertNil(plain.Chapters)
        XCTAssertTrue(plain.isAudiobook)
    }

    func testOnlyADownloadedBookIsABookHere() {
        downloadBooks()
        MusicOnDevice.add(bohemian)
        XCTAssertNil(OfflineMusic.book("q1"), "a song is not a book")
        XCTAssertNil(OfflineMusic.book("nowhere"))
    }

    func testBooksInProgressAuthorsAndBookSearch() {
        downloadBooks()
        XCTAssertEqual(ids(OfflineMusic.booksInProgress), ["b1"])
        XCTAssertEqual(OfflineMusic.authors, ["Douglas Adams", "Robert Pirsig"])
        XCTAssertEqual(ids(OfflineMusic.books(byAuthor: "robert pirsig")), ["b1"])
        XCTAssertTrue(OfflineMusic.books(byAuthor: "Nobody").isEmpty)
        XCTAssertEqual(ids(OfflineMusic.searchBooks("motorcycle")), ["b1"])
        XCTAssertEqual(ids(OfflineMusic.searchBooks(" adams ")), ["b2"], "by author too")
        XCTAssertTrue(OfflineMusic.searchBooks("").isEmpty)
    }

    func testABooksSavedItemIsKeptSlimAndOnlyForBooks() throws {
        MusicOnDevice.add(MusicFixture.book("b1"))
        MusicOnDevice.add(bohemian)
        XCTAssertFalse(OfflineBooks.isKept("b1"))
        XCTAssertNil(OfflineBooks.saved("b1"))
        OfflineBooks.keep(bohemian)
        XCTAssertFalse(OfflineBooks.isKept("q1"), "a song has no saved item")
        var full = MusicFixture.book("b1", chapters: [0, 60], positionSeconds: 99)
        full.MediaSources = [MediaSource(Id: "src")]
        let before = OfflineBooks.revision.withLock { $0 }
        OfflineBooks.keep(full)
        XCTAssertTrue(OfflineBooks.isKept("b1"))
        XCTAssertEqual(OfflineBooks.revision.withLock { $0 }, before + 1)
        let saved = try XCTUnwrap(OfflineBooks.saved("b1"))
        XCTAssertEqual(saved.Chapters?.count, 2)
        XCTAssertNil(saved.MediaSources)
        XCTAssertNil(saved.UserData, "where the listener is belongs to the record")
    }

    func testTheBookListIsReadAgainWhenASavedItemArrives() {
        MusicOnDevice.add(MusicFixture.book("b1", "Short Name"))
        XCTAssertEqual(OfflineMusic.books.first?.Name, "Short Name")
        OfflineBooks.keep(MusicFixture.book("b1", "The Full Name", chapters: [0]))
        XCTAssertEqual(OfflineMusic.books.first?.Name, "The Full Name")
    }

    // MARK: Lyrics

    func testLyricsAreKeptOnlyBesideADownloadAndOnlyWhenThereAreSome() throws {
        MusicOnDevice.add(pressure)
        let words = try JSONDecoder().decode(LyricsResponse.self, from: Data(#"{"Lyrics":[{"Text":"Pressure","Start":10000000},{"Text":"Pushing down on me"}]}"#.utf8))
        let none = try JSONDecoder().decode(LyricsResponse.self, from: Data(#"{"Lyrics":[]}"#.utf8))
        XCTAssertFalse(OfflineLyrics.isKept("q3"))
        XCTAssertNil(OfflineLyrics.load("q3"))
        OfflineLyrics.keep(none, for: "q3")
        XCTAssertFalse(OfflineLyrics.isKept("q3"))
        OfflineLyrics.keep(words, for: "not-downloaded")
        XCTAssertFalse(OfflineLyrics.isKept("not-downloaded"))
        OfflineLyrics.keep(words, for: "q3")
        XCTAssertTrue(OfflineLyrics.isKept("q3"))
        let loaded = try XCTUnwrap(OfflineLyrics.load("q3"))
        XCTAssertEqual(loaded.lines.map(\.Text), ["Pressure", "Pushing down on me"])
        XCTAssertEqual(loaded.lines.first?.startSeconds, 1)
        DownloadManager.shared.delete("q3")
        XCTAssertFalse(OfflineLyrics.isKept("q3"), "they go when the download does")
    }

    // MARK: Songs with their files

    func testMusicIsAlwaysDownloadedAsTheOriginalFile() {
        XCTAssertTrue(MusicFiles.quality.original)
    }

    private func withSource(_ id: String) -> BaseItem {
        var song = MusicFixture.song(id)
        song.MediaSources = [MediaSource(Id: "src-\(id)", Container: "flac")]
        return song
    }

    private var detailCalls: [MusicServer.Call] {
        MusicServer.calls(to: "/Items").filter { $0.query["Ids"] != nil && $0.query["EnableImages"] == "true" }
    }

    func testSongsThatAlreadyHaveTheirFilesDescribedAreNotAskedAbout() async {
        let (full, missing) = await MusicFiles.withSources([withSource("a"), withSource("b")])
        XCTAssertEqual(ids(full), ["a", "b"])
        XCTAssertEqual(missing, 0)
        XCTAssertTrue(detailCalls.isEmpty)
    }

    func testSongsLackingTheirFilesAreFetchedTogetherAndTheUnanswerableCounted() async {
        let a = withSource("a"), c = withSource("c")
        MusicServer.answer { call in
            guard call.path == "/Items", call.query["Ids"] != nil else { return nil }
            // The server has a file for "a", none for "b", and "c" was never asked about.
            return .items([a, MusicFixture.song("b")])
        }
        let (full, missing) = await MusicFiles.withSources([MusicFixture.song("a"), c, MusicFixture.song("b")])
        XCTAssertEqual(ids(full), ["a", "c"], "in the order given")
        XCTAssertEqual(full.first?.MediaSources?.first?.Id, "src-a")
        XCTAssertEqual(missing, 1)
        XCTAssertEqual(detailCalls.count, 1)
        XCTAssertEqual(detailCalls.first?.query["Ids"], "a,b", "only the ones lacking, in one request")
        XCTAssertTrue(MusicServer.calls(to: "/Items/b").isEmpty, "a song the batch left out is not asked for again by itself")
    }

    func testABatchThatFailsTwiceIsAskedForOneSongAtATime() async {
        let a = withSource("a")
        MusicServer.answer { call in
            if call.path == "/Items", call.query["Ids"] != nil { return .status(500) }
            if call.path == "/Items/a" { return .item(a) }
            return nil
        }
        let (full, missing) = await MusicFiles.withSources([MusicFixture.song("a"), MusicFixture.song("b")])
        XCTAssertEqual(ids(full), ["a"])
        XCTAssertEqual(missing, 1)
        XCTAssertEqual(detailCalls.count, 2, "asked again once before giving up on the batch")
        XCTAssertEqual(MusicServer.calls(to: "/Items/a").count, 1)
        XCTAssertEqual(MusicServer.calls(to: "/Items/b").count, 1)
    }
}
#endif
