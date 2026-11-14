//  The facts kept about downloaded songs: what is taken from the server,
//  what is counted on this device, stars given with no server, and the
//  refresh that brings it all up to date. The server is a stub.

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicOfflineIndexTests: XCTestCase {
    private var index: OfflineMusicIndex { .shared }

    override func setUp() async throws {
        MusicServer.install()
        await index.ensureLoaded()
    }

    override func tearDown() async throws {
        await MusicOnDevice.forgetEverything()
        MusicServer.remove()
    }

    private func song(_ id: String = "s1", plays: Int? = 9, favorite: Bool? = true, lastPlayedDaysAgo: Double? = 3) -> BaseItem {
        var song = MusicFixture.song(
            id, "Song \(id)", artist: "Queen", artistId: "queen", album: "Album", albumId: "al1", genres: ["Rock"], year: 1975,
            plays: plays, favorite: favorite, lastPlayed: lastPlayedDaysAgo.map(MusicFixture.daysAgo),
            added: MusicFixture.daysAgo(100)
        )
        song.HasLyrics = false
        return song
    }

    /// A server that knows these songs by id and has no playlists.
    private func serve(_ songs: [BaseItem], also extra: @escaping @Sendable (MusicServer.Call) -> MusicServer.Answer? = { _ in nil }) {
        MusicServer.answer { call in
            if let answer = extra(call) { return answer }
            if call.path == "/Items", let ids = call.query["Ids"] {
                let wanted = Set(ids.split(separator: ",").map(String.init))
                return .items(songs.filter { wanted.contains($0.Id) })
            }
            if call.path == "/Items", call.query["IncludeItemTypes"] == "Playlist" { return .items([]) }
            if call.path.hasPrefix("/UserFavoriteItems/") { return .ok }
            return nil
        }
    }

    private var askedAbout: [String] {
        MusicServer.calls(to: "/Items").compactMap { $0.query["Ids"] }
    }

    // MARK: What the server says

    func testWhatTheServerSaysAboutASongIsKept() throws {
        var s = song()
        s.HasLyrics = true
        index.note([s])
        let facts = try XCTUnwrap(index.facts["s1"])
        XCTAssertEqual(facts.genres, ["Rock"])
        XCTAssertEqual(facts.artists.first?.Id, "queen")
        XCTAssertEqual(facts.albumArtists.first?.Name, "Queen")
        XCTAssertTrue(facts.favorite)
        XCTAssertEqual(facts.playCount, 9)
        XCTAssertEqual(try XCTUnwrap(facts.lastPlayed).timeIntervalSinceNow, -3 * 86_400, accuracy: 60)
        XCTAssertEqual(try XCTUnwrap(facts.dateCreated).timeIntervalSinceNow, -100 * 86_400, accuracy: 60)
        XCTAssertTrue(facts.hasLyrics)
        XCTAssertNil(facts.pendingFavorite)
        XCTAssertNotNil(facts.refreshedAt)
    }

    func testOnlySongsAreKeptFactsAbout() {
        index.note([MusicFixture.album("al9", "An Album"), MusicFixture.book("book9"), MusicFixture.artist("ar9", "Someone")])
        XCTAssertNil(index.facts["al9"])
        XCTAssertNil(index.facts["book9"])
        XCTAssertNil(index.facts["ar9"])
    }

    func testCountsAndLastPlayedOnlyEverMoveForward() {
        index.note([song(plays: 9, lastPlayedDaysAgo: 3)])
        // A play made here that the server never heard about must not be
        // erased by the server's lower number.
        index.note([song(plays: 2, lastPlayedDaysAgo: 30)])
        XCTAssertEqual(index.facts["s1"]?.playCount, 9)
        XCTAssertEqual(index.facts["s1"]?.lastPlayed?.timeIntervalSinceNow ?? 0, -3 * 86_400, accuracy: 60)
        index.note([song(plays: 12, lastPlayedDaysAgo: 1)])
        XCTAssertEqual(index.facts["s1"]?.playCount, 12)
        XCTAssertEqual(index.facts["s1"]?.lastPlayed?.timeIntervalSinceNow ?? 0, -86_400, accuracy: 60)
    }

    func testAnAnswerThatLeavesThingsOutDoesNotEraseThem() {
        index.note([song()])
        var slim = MusicFixture.song("s1", artist: nil)
        slim.Genres = []
        index.note([slim])
        let facts = index.facts["s1"]
        XCTAssertEqual(facts?.genres, ["Rock"])
        XCTAssertEqual(facts?.artists.first?.Id, "queen")
        XCTAssertEqual(facts?.favorite, true, "nothing said about the star leaves the star")
        XCTAssertNotNil(facts?.dateCreated)
    }

    func testTheServersStarReplacesTheOneHere() {
        index.note([song(favorite: true)])
        index.note([song(favorite: false)])
        XCTAssertEqual(index.facts["s1"]?.favorite, false)
    }

    func testBeingToldTheSameThingAgainIsNotAChange() {
        let s = song()
        index.note([s])
        let revision = index.revision
        index.note([s])
        XCTAssertEqual(index.revision, revision, "pages redraw on the revision; nothing moved")
        index.note([song(plays: 10)])
        XCTAssertEqual(index.revision, revision + 1)
    }

    func testFactsWrittenByAnOlderBuildStillRead() throws {
        let old = try JSONDecoder().decode(SongFacts.self, from: Data(#"{"playCount":4,"genres":["Rock"]}"#.utf8))
        XCTAssertEqual(old.playCount, 4)
        XCTAssertEqual(old.genres, ["Rock"])
        XCTAssertFalse(old.favorite)
        XCTAssertFalse(old.hasLyrics)
        XCTAssertNil(old.lastPlayed)
        XCTAssertNil(old.pendingFavorite)
        let empty = try JSONDecoder().decode(SongFacts.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, SongFacts())
        let back = try JSONDecoder().decode(SongFacts.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(back, old)
    }

    // MARK: What happens on this device

    func testASongPlayedHereIsCountedIfItIsDownloaded() throws {
        MusicOnDevice.add(song())
        index.note([song(plays: 9, lastPlayedDaysAgo: 3)])
        index.notePlayed("s1")
        let facts = try XCTUnwrap(index.facts["s1"])
        XCTAssertEqual(facts.playCount, 10)
        XCTAssertEqual(try XCTUnwrap(facts.lastPlayed).timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testASongPlayedHereThatIsNotDownloadedIsTheServersToCount() {
        index.notePlayed("streamed")
        XCTAssertNil(index.facts["streamed"])
    }

    func testAFirstPlayOfASongTheIndexNeverHeardOfStartsItsFacts() {
        MusicOnDevice.add(MusicFixture.song("fresh"))
        index.notePlayed("fresh")
        XCTAssertEqual(index.facts["fresh"]?.playCount, 1)
        XCTAssertEqual(OfflineMusic.mostPlayed().map(\.Id), ["fresh"])
    }

    // MARK: Stars with no server

    func testAStarGivenOfflineWaitsAndIsNotOverwrittenByAnOlderAnswer() {
        index.note([song(favorite: false)])
        index.setFavorite("s1", true, pending: true)
        XCTAssertEqual(index.facts["s1"]?.favorite, true)
        XCTAssertEqual(index.facts["s1"]?.pendingFavorite, true)
        index.note([song(favorite: false)])
        XCTAssertEqual(index.facts["s1"]?.favorite, true, "the server hasn't been told yet: its answer is the old one")
    }

    func testAStarTheServerAlreadyHasIsNotLeftWaiting() {
        index.setFavorite("s1", true, pending: false)
        XCTAssertEqual(index.facts["s1"]?.favorite, true)
        XCTAssertNil(index.facts["s1"]?.pendingFavorite)
    }

    func testARefreshSendsTheStarsThatWereWaiting() async {
        MusicOnDevice.add([song("s1"), song("s2")])
        index.setFavorite("s1", true, pending: true)
        index.setFavorite("s2", false, pending: true)
        serve([song("s1", favorite: true), song("s2", favorite: false)])
        await index.refresh(force: true)
        XCTAssertEqual(MusicServer.calls(to: "/UserFavoriteItems/s1", method: "POST").count, 1)
        XCTAssertEqual(MusicServer.calls(to: "/UserFavoriteItems/s2", method: "DELETE").count, 1)
        XCTAssertEqual(MusicServer.calls(to: "/UserFavoriteItems/s1").first?.query["userId"], ClientStub.userId)
        XCTAssertNil(index.facts["s1"]?.pendingFavorite)
        XCTAssertNil(index.facts["s2"]?.pendingFavorite)
        XCTAssertEqual(index.facts["s1"]?.favorite, true)
        XCTAssertEqual(index.facts["s2"]?.favorite, false)
    }

    func testAStarTheServerWouldNotTakeKeepsWaiting() async {
        MusicOnDevice.add(song())
        index.setFavorite("s1", true, pending: true)
        serve([song(favorite: false)]) { call in
            call.path.hasPrefix("/UserFavoriteItems/") ? .status(500) : nil
        }
        await index.refresh(force: true)
        XCTAssertEqual(index.facts["s1"]?.pendingFavorite, true)
        XCTAssertEqual(index.facts["s1"]?.favorite, true, "and the star stays as the listener left it")
    }

    // MARK: Refreshing

    func testARefreshAsksAboutEveryDownloadedSongAndTakesTheAnswer() async {
        MusicOnDevice.add([MusicFixture.song("s1"), MusicFixture.song("s2")])
        MusicOnDevice.add(MusicFixture.song("waiting"), status: .queued)
        serve([song("s1"), song("s2", plays: 1, favorite: false), song("waiting")])
        await index.refresh(force: true)
        let asked = Set(askedAbout.flatMap { $0.split(separator: ",").map(String.init) })
        XCTAssertTrue(asked.isSuperset(of: ["s1", "s2"]))
        XCTAssertNil(index.facts["waiting"], "only what has finished downloading")
        XCTAssertEqual(index.facts["s1"]?.genres, ["Rock"])
        XCTAssertEqual(index.facts["s1"]?.playCount, 9)
        XCTAssertEqual(index.facts["s2"]?.playCount, 1)
        XCTAssertEqual(OfflineMusic.songs.first { $0.Id == "s1" }?.Genres, ["Rock"])
    }

    func testARefreshForgetsSongsThatAreNoLongerDownloaded() async {
        MusicOnDevice.add(song("s1"))
        index.note([song("s1"), song("gone")])
        XCTAssertNotNil(index.facts["gone"])
        serve([song("s1")])
        await index.refresh(force: true)
        XCTAssertNil(index.facts["gone"])
        XCTAssertNotNil(index.facts["s1"])
    }

    func testARefreshBringsADownloadsNameAndAlbumUpToDate() async throws {
        MusicOnDevice.add(MusicFixture.song("s1", "Old Name", artist: "Queen", album: "Old Album", albumId: "al1"))
        var renamed = song("s1")
        renamed.Name = "New Name"
        renamed.Album = "New Album"
        serve([renamed])
        await index.refresh(force: true)
        let record = try XCTUnwrap(DownloadManager.shared.record(for: "s1"))
        XCTAssertEqual(record.name, "New Name")
        XCTAssertEqual(record.album, "New Album")
        XCTAssertEqual(record.status, .complete, "nothing about the file moves")
        XCTAssertEqual(OfflineMusic.songs.first { $0.Id == "s1" }?.Name, "New Name")
    }

    func testASongTheServerNoLongerHasIsLeftAsItWas() async throws {
        MusicOnDevice.add(MusicFixture.song("orphan", "Still Here"))
        serve([])
        await index.refresh(force: true)
        XCTAssertEqual(DownloadManager.shared.record(for: "orphan")?.name, "Still Here")
        XCTAssertEqual(OfflineMusic.songs.map(\.Id), ["orphan"])
    }

    func testBetweenFullReadsOnlySongsNeverAskedAboutAreAskedAbout() async {
        MusicOnDevice.add(song("s1"))
        serve([song("s1"), song("s2")])
        await index.refresh(force: true)
        let playlistReads = MusicServer.calls(to: "/Items").filter { $0.query["IncludeItemTypes"] == "Playlist" }.count
        XCTAssertEqual(playlistReads, 1)
        MusicOnDevice.add(song("s2"))
        await index.refresh()
        // Other parts of the app ask about downloads too, several at a time;
        // a question about this one song alone is the index's.
        XCTAssertEqual(askedAbout.filter { $0 == "s2" }.count, 1)
        XCTAssertEqual(index.facts["s2"]?.genres, ["Rock"])
        XCTAssertEqual(MusicServer.calls(to: "/Items").filter { $0.query["IncludeItemTypes"] == "Playlist" }.count, playlistReads, "the playlists wait for the next full read")
        await index.refresh()
        XCTAssertEqual(askedAbout.filter { $0 == "s2" }.count, 1, "nothing new: nothing asked")
    }

    func testTheWordsOfASongThatHasThemAreFetchedOnceAndKept() async throws {
        var lyrical = song("s1")
        lyrical.HasLyrics = true
        MusicOnDevice.add([lyrical, song("s2")])
        serve([lyrical, song("s2")]) { call in
            call.path == "/Audio/s1/Lyrics" ? .json(#"{"Lyrics":[{"Text":"la la","Start":0}]}"#) : nil
        }
        await index.refresh(force: true)
        XCTAssertTrue(OfflineLyrics.isKept("s1"))
        XCTAssertEqual(OfflineLyrics.load("s1")?.lines.first?.Text, "la la")
        XCTAssertTrue(MusicServer.calls(to: "/Audio/s2/Lyrics").isEmpty, "a song without words is not asked for them")
        await index.refresh(force: true)
        XCTAssertEqual(MusicServer.calls(to: "/Audio/s1/Lyrics").count, 1)
    }

    func testADownloadedBooksFullItemIsKeptBesideIt() async throws {
        let book = MusicFixture.book("b1", "A Book")
        MusicOnDevice.add(book)
        var full = MusicFixture.book("b1", "A Book", chapters: [0, 600, 1200])
        full.Overview = "About the book."
        let answer = full
        serve([]) { call in call.path == "/Items/b1" ? .item(answer) : nil }
        XCTAssertFalse(OfflineBooks.isKept("b1"))
        await index.refresh(force: true)
        XCTAssertTrue(OfflineBooks.isKept("b1"))
        XCTAssertEqual(OfflineMusic.book("b1")?.Chapters?.count, 3)
        XCTAssertEqual(OfflineMusic.book("b1")?.Overview, "About the book.")
        XCTAssertNil(index.facts["b1"], "a book is not a song")
    }

    func testTheAccountsPlaylistsAreSavedWithTheirSongsInOrder() async {
        MusicOnDevice.add(song("s1"))
        serve([song("s1")]) { call in
            switch call.path {
            case "/Items" where call.query["IncludeItemTypes"] == "Playlist":
                return .items([MusicFixture.playlist("pl1", "First"), MusicFixture.playlist("pl2", "Unreadable"), MusicFixture.playlist("pl3", "Third")])
            case "/Playlists/pl1/Items":
                return .items(MusicFixture.songs(["x", "s1", "y"]))
            case "/Playlists/pl2/Items":
                return .status(500)
            case "/Items" where call.query["ParentId"] == "pl2":
                return .status(500)
            case "/Playlists/pl3/Items":
                return .items(MusicFixture.songs(["z"]))
            default:
                return nil
            }
        }
        await index.refresh(force: true)
        XCTAssertEqual(index.playlists, [
            SavedPlaylist(id: "pl1", name: "First", itemIds: ["x", "s1", "y"]),
            SavedPlaylist(id: "pl3", name: "Third", itemIds: ["z"]),
        ], "one that would not list is left out, not the lot")
        XCTAssertEqual(OfflineMusic.playlists.map(\.list.id), ["pl1"])
    }

    func testARefreshWithNoServerAsksNothingAndKeepsWhatItHas() async throws {
        MusicOnDevice.add(song("s1"))
        index.note([song("s1"), song("gone")])
        serve([song("s1")])
        guard await MusicServer.setOffline(true) else {
            _ = await MusicServer.setOffline(false)
            throw XCTSkip("the client would not go offline here")
        }
        await index.refresh(force: true)
        let stillOffline = JellyfinClient.shared.isOffline
        let online = await MusicServer.setOffline(false)
        XCTAssertTrue(online, "back online for the tests that follow")
        try XCTSkipUnless(stillOffline, "the client came back online by itself mid-test")
        XCTAssertNotNil(index.facts["gone"], "nothing is forgotten on the word of no server")
        XCTAssertTrue(index.playlists.isEmpty)
    }
}
#endif
