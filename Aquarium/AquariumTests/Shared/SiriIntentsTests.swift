//  What Siri and Shortcuts can ask of the app (Core/AppIntents.swift,
//  LibraryIntents.swift, PlayerIntents.swift, MusicIntents.swift): how a
//  title, a collection or a song is described, where each lookup goes — the
//  library copy, the server, or nowhere — and what `perform()` does when it
//  can be run without a stream.
//
//  Nothing here starts playback or opens a page: the intents that would
//  (Play, Continue Watching, Show, Play a Collection, Play Music…) are only
//  taken as far as the answer they give before that, and the rest is in the
//  UI tests and MANUAL.md. The spoken dialog an intent returns cannot be read
//  back from its result, so these check the value returned and what changed.

import AppIntents
import XCTest
@testable import Aquarium

// MARK: - How a title is described

@MainActor
final class MediaItemEntityTests: XCTestCase {
    override func setUp() async throws { CoreAccount.signIn() }
    override func tearDown() async throws { await CoreAccount.signOut() }

    func testAFilm() {
        let entity = MediaItemEntity(CoreItem.movie("m1", name: "Heat") {
            $0.ProductionYear = 1995
            $0.RunTimeTicks = 170 * 600_000_000 + 290_000_000   // 170 minutes 29 seconds
            $0.Genres = ["Crime", "Drama"]
            $0.UserData = CoreItem.userData(played: true, favorite: true)
            $0.ImageTags = ["Primary": "abc"]
        })
        XCTAssertEqual(entity.id, "m1")
        XCTAssertEqual(entity.title, "Heat")
        XCTAssertEqual(entity.kind, "Movie")
        XCTAssertEqual(entity.detail, "Film · 1995")
        XCTAssertEqual(entity.year, 1995)
        XCTAssertEqual(entity.minutes, 170)
        XCTAssertTrue(entity.watched)
        XCTAssertTrue(entity.favorite)
        XCTAssertEqual(entity.genres, ["Crime", "Drama"])
        XCTAssertNil(entity.season)
        XCTAssertNil(entity.episode)
        XCTAssertEqual(entity.artwork?.path, "/Items/m1/Images/Primary", "the poster, for Siri's card")
        XCTAssertEqual(entity.artwork?.host, "stub.invalid")
    }

    func testAShowHasNoLengthOfItsOwn() {
        let entity = MediaItemEntity(CoreItem.series("s1", name: "The Wire") {
            $0.ProductionYear = 2002
            $0.RunTimeTicks = 60 * 600_000_000
        })
        XCTAssertEqual(entity.detail, "TV show · 2002")
        XCTAssertNil(entity.minutes)
        XCTAssertFalse(entity.watched)
        XCTAssertFalse(entity.favorite)
        XCTAssertEqual(entity.genres, [])
        XCTAssertNil(entity.artwork)
    }

    func testAnEpisodeIsToldApartByItsShowAndNumber() {
        let entity = MediaItemEntity(CoreItem.episode("e1", series: "s1", season: "se1", s: 2, e: 3, name: "Hot Shots", seriesName: "The Wire") {
            $0.RunTimeTicks = 58 * 600_000_000
        })
        XCTAssertEqual(entity.title, "Hot Shots")
        XCTAssertEqual(entity.detail, "The Wire · Season 2: Episode 3")
        XCTAssertEqual(entity.seriesName, "The Wire")
        XCTAssertEqual(entity.season, 2)
        XCTAssertEqual(entity.episode, 3)
        XCTAssertEqual(entity.minutes, 58)
    }

    func testWhatIsMissingIsLeftOut() {
        var bare = BaseItem()
        bare.Id = "x"
        bare.type = "Movie"
        let entity = MediaItemEntity(bare)
        XCTAssertEqual(entity.title, "Untitled")
        XCTAssertEqual(entity.detail, "Film")
        XCTAssertNil(entity.year)
        XCTAssertNil(entity.minutes)
        // A film's numbers are not an episode's.
        let numbered = MediaItemEntity(CoreItem.movie("m") {
            $0.IndexNumber = 2
            $0.ParentIndexNumber = 1
        })
        XCTAssertNil(numbered.season)
        XCTAssertNil(numbered.episode)
    }

    #if !os(tvOS)
    func testADownloadedShowStandsForItsEpisodes() {
        let entity = MediaItemEntity(seriesId: "s1", name: "The Wire", episodes: 3)
        XCTAssertEqual(entity.id, "s1")
        XCTAssertEqual(entity.kind, "Series")
        XCTAssertEqual(entity.detail, "TV show · 3 downloaded")
        XCTAssertNil(entity.artwork)
    }
    #endif

    func testACollectionOrAPlaylist() {
        let boxSet = CollectionEntity(CoreItem.make("b1", "BoxSet", name: "Bond") { $0.ChildCount = 25 })
        XCTAssertEqual(boxSet.title, "Bond")
        XCTAssertEqual(boxSet.detail, "Collection · 25 titles")
        XCTAssertFalse(boxSet.isPlaylist)
        let playlist = CollectionEntity(CoreItem.make("p1", "Playlist", name: "Friday") { $0.ChildCount = 0 })
        XCTAssertEqual(playlist.detail, "Playlist")
        XCTAssertTrue(playlist.isPlaylist)
    }

    func testMusicIsDescribedByWhatItIs() {
        let album = MusicEntity(CoreItem.make("al", "MusicAlbum", name: "Blue") { $0.AlbumArtist = "Joni Mitchell" })
        XCTAssertEqual(album.detail, "Album · Joni Mitchell")
        XCTAssertEqual(album.kind, "MusicAlbum")
        let song = MusicEntity(CoreItem.make("so", "Audio", name: "River") { $0.Artists = ["Joni Mitchell", "Someone"] })
        XCTAssertEqual(song.detail, "Song · Joni Mitchell, Someone")
        XCTAssertEqual(MusicEntity(CoreItem.make("so2", "Audio", name: "Untagged")).detail, "Song")
        XCTAssertEqual(MusicEntity(CoreItem.make("ar", "MusicArtist", name: "Joni Mitchell")).detail, "Artist")
        XCTAssertEqual(MusicEntity(CoreItem.make("pl", "Playlist", name: "Friday")).detail, "Playlist")

        let book = AudiobookEntity(CoreItem.make("bk", "AudioBook", name: "Dune") { $0.AlbumArtist = "Frank Herbert" })
        XCTAssertEqual(book.title, "Dune")
        XCTAssertEqual(book.author, "Frank Herbert")
        let genre = MusicGenreEntity(CoreItem.make("g1", "MusicGenre", name: "Jazz"))
        XCTAssertEqual(genre.id, "g1")
        XCTAssertEqual(genre.name, "Jazz")
    }

    func testWhatSiriSaysWhenAPlayRequestCannotBeHonoured() {
        XCTAssertEqual(String(localized: PlaybackError.nothingPlaying.localizedStringResource), "Nothing is playing.")
        XCTAssertEqual(String(localized: PlaybackError.nothingFits.localizedStringResource), "Nothing unwatched fits that.")
        XCTAssertEqual(String(localized: PlaybackError.notDownloaded("Heat").localizedStringResource),
                       "Heat isn't downloaded, and the server can't be reached.")
    }

    func testChoicesOfferedInShortcuts() {
        XCTAssertEqual(TitleKind.anything.includeTypes, "Movie,Series")
        XCTAssertEqual(TitleKind.movies.includeTypes, "Movie")
        XCTAssertEqual(TitleKind.shows.includeTypes, "Series")
        XCTAssertEqual([PlaybackRate.x0_75, .x1, .x1_25, .x1_5, .x1_75, .x2].map(\.value), [0.75, 1, 1.25, 1.5, 1.75, 2])
        for rate in [PlaybackRate.x0_75, .x1, .x1_25, .x1_5, .x1_75, .x2] {
            XCTAssertTrue(PlayerModel.speeds.contains(rate.value), "\(rate) is a speed the video player has")
            XCTAssertTrue(MusicPlayer.speeds.contains(rate.value), "\(rate) is a speed the music player has")
        }
    }

    func testSpokenListsNameAFewAndCountTheRest() {
        let entities = ["A", "B", "C", "D", "E"].map { MediaItemEntity(CoreItem.movie($0)) }
        XCTAssertEqual(LibraryActions.spokenList(entities), "A, B, C and 2 more")
        XCTAssertEqual(LibraryActions.spokenList(Array(entities.prefix(3))), "A, B, C")
        XCTAssertEqual(LibraryActions.spokenList(entities, limit: 1), "A and 4 more")
        XCTAssertEqual(LibraryActions.spokenList([]), "")
    }
}

// MARK: - Finding a title

@MainActor
final class MediaItemQueryTests: XCTestCase {
    private let query = MediaItemQuery()
    private let library = CoreItem.library("lib", name: "Everything", type: "mixed")

    override func setUp() async throws {
        CoreAccount.signIn()
        await CoreAccount.goOnline()
    }

    override func tearDown() async throws {
        await CoreLibrary.empty()
        await CoreAccount.goOnline()
        await CoreAccount.signOut()
    }

    private var copy: [BaseItem] {
        [
            CoreItem.movie("m-heat", name: "Heat") { $0.ProductionYear = 1995 },
            CoreItem.movie("m-heatwave", name: "Heat Wave"),
            CoreItem.series("show", name: "The Wire"),
            CoreItem.season("s1", series: "show", number: 1),
            CoreItem.episode("e1", series: "show", season: "s1", s: 1, e: 1, name: "The Target", seriesName: "The Wire") {
                $0.UserData = CoreItem.userData(played: true)
            },
            CoreItem.episode("e2", series: "show", season: "s1", s: 1, e: 2, name: "The Detail", seriesName: "The Wire"),
            CoreItem.episode("e3", series: "show", season: "s1", s: 1, e: 3, name: "The Buys", seriesName: "The Wire"),
            CoreItem.make("box", "BoxSet", name: "Crime Collection"),
        ]
    }

    private func itemsRequests() -> [URLRequest] { StubURLProtocol.requests.filter { $0.url?.path == "/Items" } }

    func testTitlesByIdComeFromTheCopyAndTheRestInOneRequest() async throws {
        await CoreLibrary.fill(copy, library: library)
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.movie("elsewhere-2", name: "Second"), CoreItem.movie("elsewhere-1", name: "First"),
        ])))
        let found = try await query.entities(for: ["elsewhere-1", "m-heat", "gone", "elsewhere-2", "e2"])
        XCTAssertEqual(found.map(\.id), ["elsewhere-1", "m-heat", "elsewhere-2", "e2"], "in the order asked, without what nobody has")
        XCTAssertEqual(found[1].detail, "Film · 1995")
        let asked = itemsRequests().compactMap { RoutedStub.query($0, "Ids") }
        XCTAssertEqual(asked, ["elsewhere-1,gone,elsewhere-2"], "only what the copy lacks, and all of it at once")
    }

    func testTitlesTheCopyHoldsNeedNoRequest() async throws {
        await CoreLibrary.fill(copy, library: library)
        let found = try await query.entities(for: ["show", "m-heatwave"])
        XCTAssertEqual(found.map(\.title), ["The Wire", "Heat Wave"])
        XCTAssertTrue(itemsRequests().filter { RoutedStub.query($0, "Ids") != nil }.isEmpty)
    }

    func testSignedOutOnlyWhatIsOnTheDeviceAnswers() async throws {
        await CoreAccount.signOut()
        let found = try await query.entities(for: ["m-heat"])
        XCTAssertTrue(found.isEmpty)
        #if os(tvOS)
        // An Apple TV has no downloads to fall back on, so with nobody signed
        // in a search by name has nowhere to go and says so: the client's
        // "Not signed in", rather than an empty list.
        do {
            _ = try await query.entities(matching: "heat")
            XCTFail("a search with nobody signed in gave an answer")
        } catch {
            guard case APIError.notConfigured = error else { return XCTFail("\(error)") }
        }
        #else
        let matching = try await query.entities(matching: "heat")
        XCTAssertTrue(matching.isEmpty, "no copy, no server: the downloads, of which there are none")
        #endif
        let suggested = try await query.suggestedEntities()
        XCTAssertTrue(suggested.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testPlayHeatIsAnsweredFromTheCopy() async throws {
        await CoreLibrary.fill(copy, library: library)
        let found = try await query.entities(matching: "  heat ")
        XCTAssertEqual(found.map(\.id), ["m-heat", "m-heatwave"])
        XCTAssertTrue(itemsRequests().filter { RoutedStub.query($0, "searchTerm") != nil }.isEmpty)
        let blank = try await query.entities(matching: "   ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testWithNoCopyTheServerIsSearchedAndOnlyTitlesAreOffered() async throws {
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.movie("m1", name: "Heat"), CoreItem.make("p1", "Person", name: "Heather"),
            CoreItem.make("b1", "BoxSet", name: "Heat Collection"), CoreItem.series("s1", name: "Heated"),
        ])))
        let found = try await query.entities(matching: "heat")
        XCTAssertEqual(found.map(\.id), ["m1", "s1"])
        let request = try XCTUnwrap(itemsRequests().last { RoutedStub.query($0, "searchTerm") != nil })
        XCTAssertEqual(RoutedStub.query(request, "searchTerm"), "heat")
        XCTAssertEqual(RoutedStub.query(request, "IncludeItemTypes"), "Movie,Series,Episode")
        XCTAssertEqual(RoutedStub.query(request, "Limit"), "12")
    }

    func testTheCopyWithNoMatchFallsThroughToTheServer() async throws {
        await CoreLibrary.fill(copy, library: library)
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([CoreItem.movie("new", name: "Zodiac")])))
        let found = try await query.entities(matching: "zodiac")
        XCTAssertEqual(found.map(\.id), ["new"], "added since the last sync, perhaps")
    }

    func testSuggestionsAreWhatHomeLeadsWith() async throws {
        let resumed = (0..<7).map { CoreItem.movie("r\($0)") }
        let upNext = [CoreItem.movie("r0")] + (0..<7).map { CoreItem.episode("n\($0)", series: "s\($0)", season: nil, s: 1, e: 2) }
        StubURLProtocol.stub("/UserItems/Resume", StubURLProtocol.Response(body: CoreItem.json(resumed)))
        StubURLProtocol.stub("/Shows/NextUp", StubURLProtocol.Response(body: CoreItem.json(upNext)))
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "n0", "n1", "n2"],
                       "part-watched, then up next, each once, ten at most")
    }

    func testSuggestionsSurviveARowThatFails() async throws {
        StubURLProtocol.stub("/UserItems/Resume", status: 500)
        StubURLProtocol.stub("/Shows/NextUp", StubURLProtocol.Response(body: CoreItem.json([CoreItem.movie("n0")])))
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["n0"])
    }

    // MARK: What an entity means in files

    func testTheItemBehindAnEntityIsTheCopysElseTheServers() async throws {
        await CoreLibrary.fill(copy, library: library)
        let kept = try await LibraryActions.item(MediaItemEntity(CoreItem.movie("m-heat")))
        XCTAssertEqual(kept.ProductionYear, 1995, "the copy's own, not the entity's")

        StubURLProtocol.stub("/Items/far-away", StubURLProtocol.Response(
            body: (try? JSONEncoder().encode(CoreItem.movie("far-away", name: "Far Away"))) ?? Data()))
        let fetched = try await LibraryActions.item(MediaItemEntity(CoreItem.movie("far-away")))
        XCTAssertEqual(fetched.Name, "Far Away")
    }

    func testPlayingAShowMeansItsUnwatchedEpisodesInOrder() async throws {
        await CoreLibrary.fill(copy, library: library)
        let show = MediaItemEntity(CoreItem.series("show"))
        var files = try await LibraryActions.playable(show)
        XCTAssertEqual(files.map(\.Id), ["e2", "e3"])

        // Every one seen: all of them, from the start.
        for id in ["e2", "e3"] { LibraryIndex.shared.patchUserData(id) { $0.Played = true } }
        files = try await LibraryActions.playable(show)
        XCTAssertEqual(files.map(\.Id), ["e1", "e2", "e3"])

        let film = try await LibraryActions.playable(MediaItemEntity(CoreItem.movie("m-heat")))
        XCTAssertEqual(film.map(\.Id), ["m-heat"])
        let boxSet = try await LibraryActions.playable(MediaItemEntity(CoreItem.make("box", "BoxSet")))
        XCTAssertTrue(boxSet.isEmpty, "a folder of things is not a file")
    }

    func testAShowTheCopyDoesNotHoldAsksTheServerForItsEpisodes() async throws {
        StubURLProtocol.stub("/Items/remote-show", StubURLProtocol.Response(
            body: (try? JSONEncoder().encode(CoreItem.series("remote-show"))) ?? Data()))
        StubURLProtocol.stub("/Shows/remote-show/Episodes", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.episode("x1", series: "remote-show", season: nil, s: 1, e: 1) { $0.UserData = CoreItem.userData(played: true) },
            CoreItem.episode("x2", series: "remote-show", season: nil, s: 1, e: 2),
        ])))
        let files = try await LibraryActions.playable(MediaItemEntity(CoreItem.series("remote-show")))
        XCTAssertEqual(files.map(\.Id), ["x2"])
    }

    func testVideoLibrariesLeaveOutMusicAndBooks() async {
        await CoreLibrary.forgetAppLibraries()
        StubURLProtocol.stub("/UserViews", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.library("films", name: "Films", type: "movies"), CoreItem.library("tv", name: "TV", type: "tvshows"),
            CoreItem.library("music", name: "Music", type: "music"), CoreItem.library("books", name: "Books", type: "books"),
            CoreItem.library("home", name: "Home Videos", type: "homevideos"), CoreItem.library("folder", name: "Folder", type: nil),
        ])))
        let libraries = await LibraryActions.videoLibraries()
        XCTAssertEqual(libraries.map(\.Id), ["films", "tv", "folder"], "films, shows and untyped folders")
    }
}

// MARK: - Library intents

@MainActor
final class LibraryIntentsTests: XCTestCase {
    private let library = CoreItem.library("lib", name: "Films", type: "movies")

    override func setUp() async throws {
        CoreAccount.signIn()
        await CoreAccount.goOnline()
    }

    override func tearDown() async throws {
        await CoreLibrary.empty()
        await CoreAccount.goOnline()
        await CoreAccount.signOut()
    }

    private func requests(_ method: String, _ path: String) -> Int {
        StubURLProtocol.requests.filter { $0.httpMethod == method && $0.url?.path == path }.count
    }

    /// The latest request to `/Items` that asks this. The app the tests are
    /// hosted in is running and asks for things of its own, so "the last
    /// request" is not necessarily the test's.
    private func asked(_ matching: (URLRequest) -> Bool) -> URLRequest? {
        StubURLProtocol.requests.last { $0.url?.path == "/Items" && matching($0) }
    }

    func testWhatsNewIsTheNewestAcrossTheVideoLibraries() async throws {
        await CoreLibrary.forgetAppLibraries()
        StubURLProtocol.stub("/UserViews", StubURLProtocol.Response(body: CoreItem.json([
            library, CoreItem.library("tv", name: "TV", type: "tvshows"), CoreItem.library("music", name: "Music", type: "music"),
        ])))
        let latest = [
            CoreItem.movie("old") { $0.DateCreated = "2026-01-01T00:00:00.0000000Z" },
            CoreItem.movie("newest") { $0.DateCreated = "2026-03-01T00:00:00.0000000Z" },
            CoreItem.movie("undated"),
            CoreItem.series("newer") { $0.DateCreated = "2026-02-01T00:00:00.0000000Z" },
            CoreItem.make("song", "Audio") { $0.DateCreated = "2026-04-01T00:00:00.0000000Z" },
        ]
        StubURLProtocol.stub("/Items/Latest", StubURLProtocol.Response(body: (try? JSONEncoder().encode(latest)) ?? Data()))

        let intent = WhatsNewIntent()
        intent.count = 3
        let value = try await intent.perform().value
        XCTAssertEqual(value?.map(\.id), ["newest", "newer", "old"], "newest first, each once though both libraries list it, no music")
        // The hosting app's Home asks for its own latest rows, sixteen at a time.
        let asked = StubURLProtocol.requests.filter { $0.url?.path == "/Items/Latest" && RoutedStub.query($0, "Limit") == "3" }
        XCTAssertEqual(Set(asked.compactMap { RoutedStub.query($0, "parentId") }), ["lib", "tv"],
                       "each video library is asked for as many as were wanted")
    }

    func testWhatsNewWithNoServerIsEmptyRatherThanAnError() async throws {
        await CoreAccount.goOffline()
        let intent = WhatsNewIntent()
        intent.count = 5
        let offline = try await intent.perform().value
        XCTAssertEqual(offline?.count, 0)
        XCTAssertEqual(requests("GET", "/Items/Latest"), 0)

        await CoreAccount.signOut()
        let signedOut = try await intent.perform().value
        XCTAssertEqual(signedOut?.count, 0)
    }

    func testMarkingWatchedTellsTheServerAndTheCopy() async throws {
        await CoreLibrary.fill([CoreItem.movie("m1", name: "Heat") { $0.UserData = CoreItem.userData(position: 500) }], library: library)
        StubURLProtocol.stub("/UserPlayedItems/m1", json: "{}")

        let intent = MarkWatchedIntent()
        intent.item = MediaItemEntity(CoreItem.movie("m1", name: "Heat"))
        intent.watched = true
        var value = try await intent.perform().value
        XCTAssertEqual(value?.id, "m1")
        XCTAssertEqual(value?.watched, true)
        XCTAssertEqual(requests("POST", "/UserPlayedItems/m1"), 1)
        XCTAssertEqual(LibraryIndex.shared.item("m1")?.userData.played, true)
        XCTAssertEqual(LibraryIndex.shared.item("m1")?.userData.positionTicks, 0, "watched is no longer part-watched")

        intent.watched = false
        value = try await intent.perform().value
        XCTAssertEqual(value?.watched, false)
        XCTAssertEqual(requests("DELETE", "/UserPlayedItems/m1"), 1)
        XCTAssertEqual(LibraryIndex.shared.item("m1")?.userData.played, false)
    }

    func testMarkingWatchedWhenTheServerRefusesIsAnErrorAndChangesNothing() async {
        await CoreLibrary.fill([CoreItem.movie("m1")], library: library)
        StubURLProtocol.stub("/UserPlayedItems/m1", status: 500)
        let intent = MarkWatchedIntent()
        intent.item = MediaItemEntity(CoreItem.movie("m1"))
        intent.watched = true
        do {
            _ = try await intent.perform()
            XCTFail("a refusal was reported as done")
        } catch {}
        XCTAssertEqual(LibraryIndex.shared.item("m1")?.userData.played, false)
    }

    func testStarringAndUnstarring() async throws {
        await CoreLibrary.fill([CoreItem.movie("m1")], library: library)
        StubURLProtocol.stub("/UserFavoriteItems/m1", json: "{}")
        let intent = SetFavoriteIntent()
        intent.item = MediaItemEntity(CoreItem.movie("m1"))
        intent.favorite = true
        var value = try await intent.perform().value
        XCTAssertEqual(value?.favorite, true)
        XCTAssertEqual(requests("POST", "/UserFavoriteItems/m1"), 1)
        XCTAssertEqual(LibraryIndex.shared.item("m1")?.userData.isFavorite, true)

        intent.favorite = false
        value = try await intent.perform().value
        XCTAssertEqual(value?.favorite, false)
        XCTAssertEqual(requests("DELETE", "/UserFavoriteItems/m1"), 1)
        XCTAssertEqual(LibraryIndex.shared.item("m1")?.userData.isFavorite, false)
    }

    func testStarringWithNoServerDoesNothing() async throws {
        await CoreAccount.goOffline()
        let intent = SetFavoriteIntent()
        intent.item = MediaItemEntity(CoreItem.movie("m1"))
        intent.favorite = true
        let value = try await intent.perform().value
        XCTAssertEqual(value?.favorite, false, "handed back as it was")
        XCTAssertEqual(requests("POST", "/UserFavoriteItems/m1"), 0)
    }

    func testFavouritesAreAnsweredFromTheCopyByKind() async throws {
        await CoreLibrary.fill([
            CoreItem.movie("b", name: "Brazil") { $0.UserData = CoreItem.userData(favorite: true) },
            CoreItem.movie("a", name: "Alien") { $0.UserData = CoreItem.userData(favorite: true) },
            CoreItem.movie("c", name: "Casablanca"),
            CoreItem.series("s", name: "Severance") { $0.UserData = CoreItem.userData(favorite: true) },
        ], library: library)
        let intent = GetFavoritesIntent()
        intent.kind = .anything
        intent.count = 20
        var value = try await intent.perform().value
        XCTAssertEqual(value?.map(\.id), ["a", "b", "s"], "in name order")
        intent.kind = .shows
        value = try await intent.perform().value
        XCTAssertEqual(value?.map(\.id), ["s"])
        intent.kind = .movies
        intent.count = 1
        value = try await intent.perform().value
        XCTAssertEqual(value?.map(\.id), ["a"])
    }

    func testFavouritesWithNoCopyAskTheServer() async throws {
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([CoreItem.movie("x")])))
        let intent = GetFavoritesIntent()
        intent.kind = .movies
        intent.count = 7
        let value = try await intent.perform().value
        XCTAssertEqual(value?.map(\.id), ["x"])
        let request = try XCTUnwrap(asked { RoutedStub.query($0, "Filters") == "IsFavorite" })
        XCTAssertEqual(RoutedStub.query(request, "Filters"), "IsFavorite")
        XCTAssertEqual(RoutedStub.query(request, "IncludeItemTypes"), "Movie")
        XCTAssertEqual(RoutedStub.query(request, "Limit"), "7")
    }

    func testCollectionsAreFoundByNameOrListedNewestFirst() async throws {
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.make("box", "BoxSet", name: "Bond") { $0.MediaType = "Unknown" },
            CoreItem.make("video-list", "Playlist", name: "Friday Films") { $0.MediaType = "Video" },
            CoreItem.make("song-list", "Playlist", name: "Friday Songs") { $0.MediaType = "Audio" },
            CoreItem.make("untyped-list", "Playlist", name: "Friday"),
        ])))
        let query = CollectionQuery()
        let found = try await query.entities(matching: "friday")
        XCTAssertEqual(found.map(\.id), ["box", "video-list", "untyped-list"], "a playlist of songs is the music player's")
        var request = try XCTUnwrap(asked { RoutedStub.query($0, "IncludeItemTypes") == "BoxSet,Playlist" })
        XCTAssertEqual(RoutedStub.query(request, "searchTerm"), "friday")
        XCTAssertEqual(RoutedStub.query(request, "IncludeItemTypes"), "BoxSet,Playlist")
        XCTAssertNil(RoutedStub.query(request, "SortBy"))

        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.count, 3)
        request = try XCTUnwrap(asked { RoutedStub.query($0, "IncludeItemTypes") == "BoxSet,Playlist" })
        XCTAssertNil(RoutedStub.query(request, "searchTerm"))
        XCTAssertEqual(RoutedStub.query(request, "SortBy"), "DateCreated")
        XCTAssertEqual(RoutedStub.query(request, "SortOrder"), "Descending")
        XCTAssertEqual(RoutedStub.query(request, "Limit"), "10")

        let byId = try await query.entities(for: ["box"])
        XCTAssertEqual(byId.count, 4, "by id, whatever the server sends is taken")
        request = try XCTUnwrap(asked { RoutedStub.query($0, "Ids") != nil })
        XCTAssertEqual(RoutedStub.query(request, "Ids"), "box")
    }

    func testABoxSetsTitlesAreAskedForInItsOwnOrder() async throws {
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([CoreItem.movie("b2"), CoreItem.movie("b1")])))
        let titles = try await JellyfinClient.shared.boxSetItems("box")
        XCTAssertEqual(titles.map(\.Id), ["b2", "b1"])
        let request = try XCTUnwrap(asked { RoutedStub.query($0, "ParentId") == "box" })
        XCTAssertEqual(RoutedStub.query(request, "ParentId"), "box")
        XCTAssertNil(RoutedStub.query(request, "SortBy"), "no sort: the box set's order is the order")
    }

    func testCollectionsSuggestNothingWithNoServer() async throws {
        await CoreAccount.goOffline()
        let offline = try await CollectionQuery().suggestedEntities()
        XCTAssertTrue(offline.isEmpty)
        await CoreAccount.signOut()
        let signedOut = try await CollectionQuery().suggestedEntities()
        XCTAssertTrue(signedOut.isEmpty)
    }

    func testSurpriseMeSignedOutIsRefusedBeforeAnythingIsAsked() async {
        await CoreAccount.signOut()
        let intent = SurpriseMeIntent()
        intent.kind = .anything
        do {
            _ = try await intent.perform()
            XCTFail("a random pick with nobody signed in")
        } catch {
            guard case PlaybackError.nothingPlaying = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testPlaySignedOutSaysSoAndStartsNothing() async throws {
        await CoreAccount.signOut()
        let intent = PlayMediaIntent(item: MediaItemEntity(CoreItem.movie("m1", name: "Heat")))
        let value = try await intent.perform().value
        XCTAssertEqual(value?.id, "m1")
        XCTAssertFalse(PlayerModel.shared.isActive)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}

// MARK: - Player intents, with nothing playing

@MainActor
final class PlayerIntentsIdleTests: XCTestCase {
    private var savedAudio = ""
    private var savedSubtitles = ""
    private var savedQueue: [BaseItem] = []

    override func setUp() async throws {
        try XCTSkipIf(PlayerModel.shared.isActive || MusicPlayer.shared.isActive, "something is playing in the host app")
        savedAudio = Preferences.shared.audioLanguage
        savedSubtitles = Preferences.shared.subtitleLanguage
        savedQueue = PlayerModel.shared.queue
        PlayerActions.cancelSleepTimer()
    }

    override func tearDown() async throws {
        Preferences.shared.audioLanguage = savedAudio
        Preferences.shared.subtitleLanguage = savedSubtitles
        PlayerModel.shared.setQueue(savedQueue)
    }

    private func assertNothingPlaying(_ run: () async throws -> Void, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await run()
            XCTFail("\(what) did not say nothing is playing", file: file, line: line)
        } catch {
            guard case PlaybackError.nothingPlaying = error else { return XCTFail("\(what): \(error)", file: file, line: line) }
        }
    }

    func testWithNothingPlayingNoPlayerIsMeant() async {
        XCTAssertNil(PlayerActions.active)
        XCTAssertFalse(PlayerActions.isPlaying)
        XCTAssertFalse(PlayerActions.togglePlayPause())
        XCTAssertFalse(PlayerActions.setSleepTimer(minutes: 10))
        XCTAssertNil(PlayerActions.sleepMinutesRemaining, "no timer was set on a player that is not up")
        XCTAssertFalse(PlayerActions.setSpeed(1.5))
        XCTAssertEqual(PlayerModel.shared.speed, 1, accuracy: 0.001)
        XCTAssertNil(PlayerActions.skipLabel)
        XCTAssertFalse(PlayerActions.skipSegment())
        XCTAssertFalse(PlayerActions.stopAfterThis(true))
        let advanced = await PlayerActions.next()
        XCTAssertFalse(advanced)
        PlayerActions.pause()
        XCTAssertFalse(PlayerModel.shared.isPaused, "pausing nothing pauses nothing")
    }

    func testEachPlayerIntentSaysNothingIsPlaying() async {
        await assertNothingPlaying({ _ = try await SetSleepTimerIntent(minutes: 20).perform() }, "sleep timer")
        await assertNothingPlaying({
            let intent = StopAfterEpisodeIntent()
            intent.stop = true
            _ = try await intent.perform()
        }, "stop after this episode")
        await assertNothingPlaying({
            let intent = SetPlaybackSpeedIntent()
            intent.speed = .x1_5
            _ = try await intent.perform()
        }, "speed")
        await assertNothingPlaying({ _ = try await SkipSegmentIntent().perform() }, "skip intro")
        await assertNothingPlaying({ _ = try await NextEpisodeIntent().perform() }, "next episode")
        await assertNothingPlaying({ _ = try await PlayPauseIntent().perform() }, "play or pause")
        XCTAssertNil(PlayerActions.sleepMinutesRemaining)
    }

    func testTurningOffATimerThatIsNotRunningIsNotAnError() async throws {
        _ = try await CancelSleepTimerAppIntent().perform()
        XCTAssertNil(PlayerActions.sleepMinutesRemaining)
    }

    func testALanguageIsSavedForLaterWhenNothingIsPlaying() {
        XCTAssertEqual(PlayerActions.applyAudioLanguage("ger,deu"), "Saved for everything played after.")
        XCTAssertEqual(Preferences.shared.audioLanguage, "ger,deu")
        XCTAssertEqual(PlayerActions.applySubtitleLanguage("off"), "Saved for everything played after.")
        XCTAssertEqual(Preferences.shared.subtitleLanguage, "off")
        XCTAssertEqual(PlayerActions.applySubtitleLanguage(TrackPreference.forcedOnly), "Saved for everything played after.")
        XCTAssertEqual(Preferences.shared.subtitleLanguage, TrackPreference.forcedOnly)
    }

    func testTheLanguageIntentsSetThePreferenceButAudioCannotBeOff() async throws {
        Preferences.shared.audioLanguage = "eng"
        let audio = SetAudioLanguageIntent()
        audio.language = .off
        _ = try await audio.perform()
        XCTAssertEqual(Preferences.shared.audioLanguage, "eng", "\"off\" is not an audio language")
        audio.language = LanguageEntity(id: "spa", name: "Spanish")
        _ = try await audio.perform()
        XCTAssertEqual(Preferences.shared.audioLanguage, "spa")
        audio.language = .auto
        _ = try await audio.perform()
        XCTAssertEqual(Preferences.shared.audioLanguage, "", "whatever the file lists first")

        let subtitles = SetSubtitleLanguageIntent()
        subtitles.language = .off
        _ = try await subtitles.perform()
        XCTAssertEqual(Preferences.shared.subtitleLanguage, "off")
    }

    func testLanguagesCanBeFoundByNameOrCode() async throws {
        let query = LanguageQuery()
        let all = try await query.suggestedEntities()
        XCTAssertEqual(all.prefix(2).map(\.id), ["", "off"], "the file's own choice and Off lead the list")
        XCTAssertEqual(all.count, Languages.all.count + 2)

        let french = try await query.entities(matching: "FRE")
        XCTAssertEqual(french.map(\.name), ["French"])
        let byCode = try await query.entities(matching: "deu")
        XCTAssertEqual(byCode.map(\.name), ["German"])
        let off = try await query.entities(matching: "of")
        XCTAssertTrue(off.contains { $0.id == "off" })

        let byId = try await query.entities(for: ["eng", "off", "nonsense"])
        XCTAssertEqual(byId.map(\.id), ["off", "eng"], "in the list's order")
    }

    #if !os(tvOS)
    func testUpNextListsTheQueueAndClearingEmptiesIt() async throws {
        try XCTSkipIf(PlayerModel.shared.upNext != nil, "the host app has an episode up next")
        PlayerModel.shared.setQueue([])
        var value = try await GetUpNextIntent().perform().value
        XCTAssertEqual(value?.count, 0)

        PlayerModel.shared.setQueue([CoreItem.movie("q1", name: "First"), CoreItem.movie("q2", name: "Second")])
        value = try await GetUpNextIntent().perform().value
        XCTAssertEqual(value?.map(\.id), ["q1", "q2"])
        XCTAssertEqual(value?.map(\.title), ["First", "Second"])

        _ = try await ClearQueueIntent().perform()
        XCTAssertTrue(PlayerModel.shared.queue.isEmpty)
        _ = try await ClearQueueIntent().perform()   // nothing queued: not an error
        XCTAssertEqual(QueuePosition.next.rawValue, "next")
        XCTAssertEqual(QueuePosition.later.rawValue, "later")
    }
    #endif
}

// MARK: - Music intents

@MainActor
final class MusicIntentsTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipIf(PlayerModel.shared.isActive || MusicPlayer.shared.isActive, "something is playing in the host app")
        CoreAccount.signIn()
        await CoreAccount.goOnline()
    }

    override func tearDown() async throws {
        await CoreAccount.goOnline()
        await CoreAccount.signOut()
    }

    func testMusicByIdIsAskedOfTheServerWhenItIsNotOnTheDevice() async throws {
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.make("al", "MusicAlbum", name: "Blue") { $0.AlbumArtist = "Joni Mitchell" },
        ])))
        let found = try await MusicQuery().entities(for: ["al"])
        XCTAssertEqual(found.map(\.id), ["al"])
        XCTAssertEqual(found.first?.detail, "Album · Joni Mitchell")
        let request = try XCTUnwrap(StubURLProtocol.requests.last { $0.url?.path == "/Items" && RoutedStub.query($0, "Ids") != nil })
        XCTAssertEqual(RoutedStub.query(request, "Ids"), "al")
    }

    func testAudiobooksByIdLeaveOutWhatIsNotABook() async throws {
        StubURLProtocol.stub("/Items", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.make("bk", "AudioBook", name: "Dune") { $0.AlbumArtist = "Frank Herbert" },
            CoreItem.make("so", "Audio", name: "A Song"),
        ])))
        let found = try await AudiobookQuery().entities(for: ["bk", "so"])
        XCTAssertEqual(found.map(\.id), ["bk"])
        XCTAssertEqual(found.first?.author, "Frank Herbert")
    }

    func testBooksInProgressAreSuggestedFromTheServer() async throws {
        StubURLProtocol.stub("/UserItems/Resume", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.make("bk", "AudioBook", name: "Dune"), CoreItem.make("so", "Audio", name: "A Song"),
        ])))
        let suggested = try await AudiobookQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["bk"])
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.url?.path == "/UserItems/Resume" && RoutedStub.query($0, "MediaTypes") == "Audio" })
    }

    func testGenresAreMatchedByNameAndFoundById() async throws {
        StubURLProtocol.stub("/MusicGenres", StubURLProtocol.Response(body: CoreItem.json([
            CoreItem.make("g1", "MusicGenre", name: "Jazz"), CoreItem.make("g2", "MusicGenre", name: "Acid Jazz"),
            CoreItem.make("g3", "MusicGenre", name: "Folk"),
        ])))
        let query = MusicGenreQuery()
        let jazz = try await query.entities(matching: "JAZZ")
        XCTAssertEqual(jazz.map(\.name), ["Jazz", "Acid Jazz"])
        let byId = try await query.entities(for: ["g3", "missing"])
        XCTAssertEqual(byId.map(\.id), ["g3"])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.count, 3)
    }

    func testSignedOutWithNoDownloadsThereIsNothingToOffer() async throws {
        await CoreAccount.signOut()
        #if !os(tvOS)
        try XCTSkipIf(!OfflineMusic.songs.isEmpty || !OfflineMusic.books.isEmpty, "this device has downloaded audio")
        #endif
        let genres = try await MusicGenreQuery().suggestedEntities()
        XCTAssertTrue(genres.isEmpty)
        let music = try await MusicQuery().suggestedEntities()
        XCTAssertTrue(music.isEmpty)
        let found = try await MusicQuery().entities(matching: "blue")
        XCTAssertTrue(found.isEmpty)
        let books = try await AudiobookQuery().suggestedEntities()
        XCTAssertTrue(books.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)

        // And with nothing to play, the actions say so rather than starting.
        let resumed = await MusicActions.resumeBook()
        XCTAssertFalse(resumed)
        let shuffled = await MusicActions.shuffleAll()
        XCTAssertFalse(shuffled)
        let genre = await MusicActions.playGenre(id: "genre:Jazz", name: "Jazz")
        XCTAssertFalse(genre)
        await MusicActions.play(itemId: "nothing", shuffle: true)
        _ = try await ResumeAudiobookIntent().perform()
        _ = try await ShuffleMusicIntent().perform()
        XCTAssertFalse(MusicPlayer.shared.isActive)
    }
}
