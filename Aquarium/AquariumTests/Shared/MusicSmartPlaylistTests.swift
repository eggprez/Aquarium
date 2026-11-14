//  Smart playlists: the rule and the sentence that describes it, rules that
//  survive being stored by another build, where they are kept, and what a
//  rule asks the server for and settles for itself. (The same rule answered
//  from downloads is in `MusicOfflineLibraryTests`.)

#if !os(tvOS)
import XCTest
@testable import Aquarium

@MainActor
final class MusicSmartPlaylistTests: XCTestCase {
    private let key = "smart_playlists"
    private var savedRules: Data?
    private var store: SmartPlaylistStore { .shared }

    override func setUp() async throws {
        MusicServer.install()
        savedRules = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        store.reload()
    }

    override func tearDown() async throws {
        if let savedRules {
            UserDefaults.standard.set(savedRules, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        store.reload()
        MusicServer.remove()
    }

    private func rule(_ change: (inout SmartPlaylist) -> Void) -> SmartPlaylist {
        var r = SmartPlaylist()
        change(&r)
        return r
    }

    private func decode(_ json: String) throws -> SmartPlaylist {
        try JSONDecoder().decode(SmartPlaylist.self, from: Data(json.utf8))
    }

    // MARK: The sentence on its row

    func testAnEmptyRuleIsEverySong() {
        XCTAssertEqual(SmartPlaylist().summary, "Every song · random · 100")
        XCTAssertEqual(SmartPlaylist().name, "New Smart Playlist")
    }

    func testTheSummaryNamesEveryPartOfTheRule() {
        let r = rule {
            $0.genres = ["Rock", "Jazz"]
            $0.artists = [NameGuidPair(Id: "q1", Name: "Queen"), NameGuidPair(Id: "x", Name: nil)]
            $0.yearFrom = 1990
            $0.yearTo = 1980
            $0.addedWithinDays = 1
            $0.favoritesOnly = true
            $0.played = .unplayed
            $0.minPlayCount = 3
            $0.sort = .mostPlayed
            $0.limit = 50
        }
        XCTAssertEqual(
            r.summary,
            "Rock, Jazz · Queen · 1980–1990 · added in the last 1 day · favourites · never played · played 3+ times · most played · 50"
        )
    }

    func testTheSummaryReadsOneSidedYearsAndPlurals() {
        XCTAssertEqual(rule { $0.yearFrom = 1990 }.summary, "from 1990 · random · 100")
        XCTAssertEqual(rule { $0.yearTo = 2000 }.summary, "up to 2000 · random · 100")
        XCTAssertEqual(rule { $0.addedWithinDays = 30 }.summary, "added in the last 30 days · random · 100")
        XCTAssertEqual(rule { $0.played = .played; $0.sort = .name }.summary, "played before · title · 100")
        XCTAssertEqual(rule { $0.minPlayCount = 0 }.summary, "Every song · random · 100", "a floor of nothing is no rule")
    }

    // MARK: Reading rules another build wrote

    func testARuleSurvivesBeingStored() throws {
        let r = rule {
            $0.name = "Nineties"
            $0.genres = ["Rock"]
            $0.artists = [NameGuidPair(Id: "q1", Name: "Queen")]
            $0.yearFrom = 1990
            $0.yearTo = 1999
            $0.addedWithinDays = 90
            $0.favoritesOnly = true
            $0.played = .played
            $0.minPlayCount = 2
            $0.sort = .year
            $0.limit = 25
        }
        let back = try JSONDecoder().decode(SmartPlaylist.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.id, r.id)
        XCTAssertEqual(back.summary, r.summary)
        XCTAssertEqual(back.name, "Nineties")
        XCTAssertEqual(back.artists.first?.Id, "q1")
    }

    func testARuleWithFieldsMissingReadsWithTheDefaults() throws {
        let r = try decode(#"{"name":"Only a name"}"#)
        XCTAssertEqual(r.name, "Only a name")
        XCTAssertEqual(r.limit, 100)
        XCTAssertEqual(r.sort, .random)
        XCTAssertEqual(r.played, .any)
        XCTAssertFalse(r.favoritesOnly)
        XCTAssertTrue(r.genres.isEmpty)
        XCTAssertNil(r.yearFrom)
    }

    func testARuleWithValuesThisBuildDoesNotKnowKeepsTheRest() throws {
        let r = try decode("""
        {"name":"From the future","sort":"Mood","played":"sometimes","limit":0,"yearFrom":"nineteen ninety",
         "yearTo":1999,"genres":"Rock","favoritesOnly":true,"somethingNew":{"a":1}}
        """)
        XCTAssertEqual(r.name, "From the future")
        XCTAssertEqual(r.sort, .random)
        XCTAssertEqual(r.played, .any)
        XCTAssertEqual(r.limit, 100, "a limit of nothing is not a limit")
        XCTAssertNil(r.yearFrom)
        XCTAssertEqual(r.yearTo, 1999)
        XCTAssertTrue(r.genres.isEmpty)
        XCTAssertTrue(r.favoritesOnly)
    }

    func testTheSettingsReadRulesWrittenByAnotherBuild() {
        UserDefaults.standard.set(Data(#"[{"name":"Kept","sort":"Mood"},{"name":"Also kept","limit":10,"new":[1]}]"#.utf8), forKey: key)
        XCTAssertEqual(Preferences.shared.smartPlaylists.map(\.name), ["Kept", "Also kept"])
        XCTAssertEqual(Preferences.shared.smartPlaylists.map(\.limit), [100, 10])
        UserDefaults.standard.set(Data("not json".utf8), forKey: key)
        XCTAssertTrue(Preferences.shared.smartPlaylists.isEmpty)
    }

    // MARK: Where they are kept

    func testSavingARuleAddsItAndSavingItAgainReplacesIt() {
        var r = rule { $0.name = "First" }
        store.upsert(r)
        store.upsert(rule { $0.name = "Second" })
        XCTAssertEqual(store.playlists.map(\.name), ["First", "Second"])
        r.name = "First, renamed"
        r.limit = 25
        store.upsert(r)
        XCTAssertEqual(store.playlists.map(\.name), ["First, renamed", "Second"], "in place, not at the end")
        XCTAssertEqual(store.playlist(r.id)?.limit, 25)
        XCTAssertEqual(Preferences.shared.smartPlaylists.map(\.name), ["First, renamed", "Second"], "and written to the settings")
    }

    func testDeletingARule() {
        let a = rule { $0.name = "A" }, b = rule { $0.name = "B" }
        store.upsert(a)
        store.upsert(b)
        store.delete(a.id)
        XCTAssertEqual(store.playlists.map(\.name), ["B"])
        XCTAssertNil(store.playlist(a.id))
        XCTAssertEqual(Preferences.shared.smartPlaylists.map(\.name), ["B"])
        store.delete(b.id)
        XCTAssertTrue(Preferences.shared.smartPlaylists.isEmpty)
    }

    func testRulesChangedOnAnotherDeviceAreReadOnReload() {
        store.upsert(rule { $0.name = "Here" })
        UserDefaults.standard.set(Data(#"[{"name":"From the iPad","limit":10}]"#.utf8), forKey: key)
        XCTAssertEqual(store.playlists.map(\.name), ["Here"])
        store.reload()
        XCTAssertEqual(store.playlists.map(\.name), ["From the iPad"])
        XCTAssertEqual(store.playlists.first?.limit, 10)
    }

    func testAStoredListThatCannotBeReadIsNotOverwrittenWithNothing() {
        let unreadable = Data("not json".utf8)
        UserDefaults.standard.set(unreadable, forKey: key)
        store.reload()
        XCTAssertTrue(store.playlists.isEmpty)
        store.delete(UUID())
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), unreadable, "another build may read what this one can't")
        // A rule made here is a real change, and is saved.
        store.upsert(rule { $0.name = "New" })
        XCTAssertEqual(Preferences.shared.smartPlaylists.map(\.name), ["New"])
    }

    func testDeletingTheLastReadableRuleDoesNotWipeTheUnreadableOnes() throws {
        let stored = Data(#"[42,{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Readable"}]"#.utf8)
        UserDefaults.standard.set(stored, forKey: key)
        store.reload()
        XCTAssertEqual(store.playlists.map(\.name), ["Readable"])
        store.delete(try XCTUnwrap(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")))
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), stored)
    }

    // MARK: What the server is asked

    private func answerSongs(_ pages: [[BaseItem]]) {
        MusicServer.answer { call in
            guard call.path == "/Items", call.query["IncludeItemTypes"] == "Audio" else { return nil }
            let start = Int(call.query["StartIndex"] ?? "0") ?? 0
            var offset = 0
            for page in pages {
                if offset == start { return .items(page) }
                offset += page.count
            }
            return .items([])
        }
    }

    /// What the rule asked about songs. The host app is live while these run
    /// and asks `/Items` things of its own whenever an account appears: Home's
    /// rows, and, once the account is known to have a music library, Home's
    /// "recently played" music row (`HomeView.loadMusic`), which is a question
    /// about songs too. That one is told apart by its shape, which no rule
    /// here has: played songs, newest play first, thirty of them.
    private var asked: [[String: String]] {
        MusicServer.calls(to: "/Items").map(\.query).filter { q in
            guard q["IncludeItemTypes"] == "Audio" else { return false }
            let isHomesMusicRow = q["SortBy"] == "DatePlayed,SortName" && q["Limit"] == "30"
                && q["Filters"] == "IsPlayed" && q["Genres"] == nil && q["ArtistIds"] == nil && q["Years"] == nil
            return !isHomesMusicRow
        }
    }

    func testAPlainRuleIsOneQuestionTheServerAnswersWhole() async throws {
        answerSongs([MusicFixture.songs(["b", "a", "c"])])
        let r = rule {
            $0.genres = ["Rock", "Jazz"]
            $0.artists = [NameGuidPair(Id: "a1", Name: "One"), NameGuidPair(Id: nil, Name: "No id"), NameGuidPair(Id: "a2", Name: "Two")]
            $0.yearFrom = 1992
            $0.yearTo = 1990
            $0.favoritesOnly = true
            $0.played = .played
            $0.sort = .year
            $0.limit = 25
        }
        let songs = try await r.resolve()
        XCTAssertEqual(songs.map(\.Id), ["b", "a", "c"], "in the server's order")
        XCTAssertEqual(asked.count, 1, "\(asked)")
        let q = asked[0]
        XCTAssertEqual(q["IncludeItemTypes"], "Audio")
        XCTAssertEqual(q["Genres"], "Rock|Jazz")
        XCTAssertEqual(q["ArtistIds"], "a1,a2")
        XCTAssertEqual(q["Years"], "1990,1991,1992", "the years either way round")
        XCTAssertEqual(q["Filters"], "IsFavorite,IsPlayed")
        XCTAssertEqual(q["SortBy"], "ProductionYear,SortName")
        XCTAssertEqual(q["SortOrder"], "Descending")
        XCTAssertEqual(q["Limit"], "25")
        XCTAssertEqual(q["StartIndex"], "0")
        XCTAssertEqual(q["userId"], ClientStub.userId)
    }

    func testAnEmptyRuleAsksForAnySongsAtRandom() async throws {
        answerSongs([MusicFixture.songs(["a"])])
        _ = try await SmartPlaylist().resolve()
        let q = asked[0]
        XCTAssertEqual(q["SortBy"], "Random")
        XCTAssertEqual(q["Limit"], "100")
        for absent in ["Genres", "ArtistIds", "Years", "Filters"] { XCTAssertNil(q[absent], absent) }
    }

    func testYearsAndPlayedAsTheServerIsAskedThem() async throws {
        answerSongs([[]])
        _ = try await rule { $0.yearFrom = 2001; $0.played = .unplayed; $0.sort = .name }.resolve()
        _ = try await rule { $0.yearTo = 1985 }.resolve()
        _ = try await rule { $0.yearFrom = 1800; $0.yearTo = 2000 }.resolve()
        XCTAssertEqual(asked[0]["Years"], "2001", "one year given is that year")
        XCTAssertEqual(asked[0]["Filters"], "IsUnplayed")
        XCTAssertEqual(asked[0]["SortBy"], "Name", "songs by title, not by the server's track-number sort name")
        XCTAssertEqual(asked[0]["SortOrder"], "Ascending")
        XCTAssertEqual(asked[1]["Years"], "1985")
        XCTAssertNil(asked[2]["Years"], "a span too wide to list is not sent")
    }

    func testAServerThatFailsIsAnErrorNotAnEmptyPlaylist() async {
        MusicServer.answer { call in call.path == "/System/Info/Public" ? nil : .status(500) }
        do {
            _ = try await SmartPlaylist().resolve()
            XCTFail("expected an error")
        } catch {}
        do {
            _ = try await rule { $0.addedWithinDays = 7 }.resolve()
            XCTFail("expected an error")
        } catch {}
    }

    // MARK: What the rule settles for itself

    private func song(_ id: String, _ name: String, addedDaysAgo: Double, plays: Int = 0, heardDaysAgo: Double? = nil, artist: String = "Artist", year: Int? = nil) -> BaseItem {
        MusicFixture.song(
            id, name, artist: artist, year: year, plays: plays,
            lastPlayed: heardDaysAgo.map(MusicFixture.daysAgo), added: MusicFixture.daysAgo(addedDaysAgo)
        )
    }

    func testAddedWithinWalksNewestFirstUntilPastTheLineThenPutsTheRulesOrderOn() async throws {
        answerSongs([[
            song("c", "Charlie", addedDaysAgo: 1), song("a", "alpha", addedDaysAgo: 5), song("b", "Bravo", addedDaysAgo: 10),
            song("old", "Aardvark", addedDaysAgo: 60), song("older", "Abacus", addedDaysAgo: 90),
        ]])
        let songs = try await rule { $0.addedWithinDays = 30; $0.sort = .name; $0.limit = 2 }.resolve()
        XCTAssertEqual(songs.map(\.Id), ["a", "b"], "by title, the limit applied after the filter")
        XCTAssertEqual(asked.count, 1, "\(asked)")
        XCTAssertEqual(asked[0]["SortBy"], "DateCreated,SortName")
        XCTAssertEqual(asked[0]["SortOrder"], "Descending")
        XCTAssertEqual(asked[0]["Limit"], "500", "the rule's own limit would cut the walk short")
    }

    func testAPlayCountFloorWalksMostPlayedFirst() async throws {
        answerSongs([[
            song("nine", "Nine", addedDaysAgo: 400, plays: 9, heardDaysAgo: 30),
            song("seven", "Seven", addedDaysAgo: 400, plays: 7, heardDaysAgo: 1),
            song("five", "Five", addedDaysAgo: 400, plays: 5, heardDaysAgo: 10),
            song("four", "Four", addedDaysAgo: 400, plays: 4, heardDaysAgo: 0.5),
            song("one", "One", addedDaysAgo: 400, plays: 1),
        ]])
        let songs = try await rule { $0.minPlayCount = 5; $0.sort = .recentlyPlayed }.resolve()
        XCTAssertEqual(songs.map(\.Id), ["seven", "five", "nine"], "heard most recently first")
        XCTAssertEqual(asked[0]["SortBy"], "PlayCount,SortName")
        XCTAssertEqual(asked[0]["SortOrder"], "Descending")
    }

    func testAddedWithinAndAFloorTogetherSkipTheLittlePlayedAndStopAtTheLine() async throws {
        answerSongs([[
            song("n1", "N1", addedDaysAgo: 2, plays: 10), song("n2", "N2", addedDaysAgo: 3, plays: 1),
            song("n3", "N3", addedDaysAgo: 4, plays: 26), song("old", "Old", addedDaysAgo: 100, plays: 50),
        ]])
        let songs = try await rule { $0.addedWithinDays = 30; $0.minPlayCount = 5; $0.sort = .mostPlayed }.resolve()
        XCTAssertEqual(songs.map(\.Id), ["n3", "n1"])
        XCTAssertEqual(asked[0]["SortBy"], "DateCreated,SortName", "walked by date: the play count is checked song by song")
    }

    func testTheWalkGoesOnToTheNextPageWhenAPageIsFull() async throws {
        let first = (0..<500).map { song("p\($0)", "Song \($0)", addedDaysAgo: 1) }
        let second = [song("q0", "Late match", addedDaysAgo: 2), song("q1", "Too old", addedDaysAgo: 80)]
        answerSongs([first, second])
        let songs = try await rule { $0.addedWithinDays = 30; $0.sort = .recentlyAdded; $0.limit = 500 }.resolve()
        // The app asks about songs for pages of its own while an account is
        // signed in, so the walk is the questions that match its second page
        // in everything but where they start.
        func rest(_ q: [String: String]) -> [String: String] { q.filter { $0.key != "StartIndex" } }
        let later = try XCTUnwrap(asked.first { $0["StartIndex"] == "500" }, "the second page was never asked for")
        XCTAssertEqual(asked.filter { rest($0) == rest(later) }.map { $0["StartIndex"] }, ["0", "500"])
        XCTAssertEqual(songs.count, 500)
        let all = try await rule { $0.addedWithinDays = 30; $0.sort = .name; $0.limit = 1000 }.resolve()
        XCTAssertEqual(all.count, 501)
        XCTAssertTrue(all.contains { $0.Id == "q0" }, "a match on the second page is not missed")
    }

    func testTheRulesOrderIsPutOnWhatTheWalkFound() async throws {
        let found = [
            song("a", "Zebra", addedDaysAgo: 1, plays: 2, artist: "Beta", year: 1990),
            song("b", "Apple", addedDaysAgo: 2, plays: 9, artist: "Beta", year: 2005),
            song("c", "Mango", addedDaysAgo: 3, plays: 5, artist: "Alpha", year: 1975),
        ]
        answerSongs([found])
        func ids(_ sort: MusicSort) async throws -> [String] {
            try await rule { $0.addedWithinDays = 30; $0.sort = sort }.resolve().map(\.Id)
        }
        let byArtist = try await ids(.artist)
        XCTAssertEqual(byArtist, ["c", "b", "a"], "artist, then title")
        let byYear = try await ids(.year)
        XCTAssertEqual(byYear, ["b", "a", "c"], "newest first")
        let byAdded = try await ids(.recentlyAdded)
        XCTAssertEqual(byAdded, ["a", "b", "c"])
        let byPlays = try await ids(.mostPlayed)
        XCTAssertEqual(byPlays, ["b", "c", "a"])
        let shuffled = try await ids(.random)
        XCTAssertEqual(Set(shuffled), ["a", "b", "c"])
    }
}
#endif
