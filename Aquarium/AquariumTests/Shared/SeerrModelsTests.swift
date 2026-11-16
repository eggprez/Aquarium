//  What Seerr's answers are read as: where a title stands, which seasons can
//  still be asked for, what an account may do, and the words for a refusal.

import XCTest
@testable import Aquarium

@MainActor
final class SeerrModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testSearchResultsReadFilmsAndShowsAndSkipTheRest() throws {
        let page = try decode(SeerrPage.self, #"""
        {"page":1,"totalPages":1,"totalResults":3,"results":[
          {"id":603,"mediaType":"movie","title":"The Matrix","releaseDate":"1999-03-31","posterPath":"/m.jpg"},
          {"id":1396,"mediaType":"tv","name":"Breaking Bad","firstAirDate":"2008-01-20",
           "mediaInfo":{"status":5,"jellyfinMediaId":"abc"}},
          {"id":6384,"mediaType":"person","name":"Keanu Reeves"},
          {"id":19885,"mediaType":"tv","name":"Sherlock","mediaInfo":{"status":4,"jellyfinMediaId":"def"}},
          {"id":27205,"mediaType":"movie","title":"Inception","mediaInfo":{"status":2}}
        ]}
        """#)
        let results = page.results ?? []
        XCTAssertEqual(results.prefix(3).map(\.displayTitle), ["The Matrix", "Breaking Bad", "Keanu Reeves"])
        XCTAssertEqual(results.prefix(3).map(\.year), ["1999", "2008", nil])
        XCTAssertEqual(results.prefix(3).map(\.id), ["movie-603", "tv-1396", "person-6384"])
        XCTAssertEqual(results.map(\.isRequestable), [true, false, false, false, true],
                       "not offered: in the library, not a film or a show, or partly here; offered still: asked for already")
        XCTAssertEqual(results[1].mediaInfo?.libraryItemId, "abc")
    }

    func testStandingFromATitle() {
        func standing(_ status: Int?) -> SeerrStanding { SeerrStanding(media: status.map { SeerrMediaInfo(status: $0) }) }
        XCTAssertEqual(standing(nil), .requestable)
        XCTAssertEqual(standing(1), .requestable)
        XCTAssertEqual(standing(2), .awaitingApproval)
        XCTAssertEqual(standing(3), .onItsWay)
        XCTAssertEqual(standing(4), .partlyAvailable)
        XCTAssertEqual(standing(5), .available)
        XCTAssertEqual(standing(7), .requestable, "a deleted title can be asked for again")
        XCTAssertNil(SeerrStanding.requestable.badge)
        XCTAssertEqual(SeerrStanding.awaitingApproval.badge, "Requested")
    }

    func testStandingFromARequestKnowsMoreThanItsTitle() {
        func standing(_ status: Int, media: Int = 1) -> SeerrStanding {
            SeerrStanding(request: SeerrRequest(id: 1, status: status, media: SeerrMediaInfo(status: media)))
        }
        XCTAssertEqual(standing(1), .awaitingApproval)
        XCTAssertEqual(standing(2, media: 3), .onItsWay)
        XCTAssertEqual(standing(2, media: 4), .partlyAvailable)
        XCTAssertEqual(standing(2, media: 5), .available)
        XCTAssertEqual(standing(3), .declined)
        XCTAssertEqual(standing(4), .failed)
        XCTAssertEqual(standing(5), .available)
    }

    func testSeasonsStillOpenLeaveOutWhatIsHereOrAskedFor() throws {
        let show = try decode(SeerrTitle.self, #"""
        {"id":19885,"name":"Sherlock","firstAirDate":"2010-07-25",
         "seasons":[{"seasonNumber":0,"name":"Specials"},{"seasonNumber":1},{"seasonNumber":2},
                    {"seasonNumber":3},{"seasonNumber":4},{"seasonNumber":5}],
         "mediaInfo":{"status":4,
           "seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status":5}],
           "requests":[{"id":9,"status":1,"seasons":[{"seasonNumber":3}]},
                       {"id":10,"status":3,"seasons":[{"seasonNumber":4}]},
                       {"id":11,"status":2,"seasons":[{"seasonNumber":5}]}]}}
        """#)
        XCTAssertEqual(show.realSeasons.map(\.seasonNumber), [1, 2, 3, 4, 5], "specials are not a season")
        XCTAssertEqual(show.requestableSeasons.map(\.seasonNumber), [4], "a declined request leaves its season open")
        XCTAssertEqual(show.standing(ofSeason: 1), .available)
        XCTAssertEqual(show.standing(ofSeason: 3), .awaitingApproval)
        XCTAssertEqual(show.standing(ofSeason: 4), .requestable)
        XCTAssertEqual(show.standing(ofSeason: 5), .onItsWay)
    }

    func testAShowSeerrHasNeverMetIsAllOpen() throws {
        let show = try decode(SeerrTitle.self, #"{"id":1396,"name":"Breaking Bad","seasons":[{"seasonNumber":1},{"seasonNumber":2}]}"#)
        XCTAssertEqual(show.requestableSeasons.map(\.seasonNumber), [1, 2])
    }

    func testPermissions() {
        let plain = SeerrPermissions(rawValue: 32)
        XCTAssertTrue(plain.canRequest(.movie))
        XCTAssertTrue(plain.canRequest(.tv))
        XCTAssertFalse(plain.canRequest4K(.movie))
        let filmsOnly = SeerrPermissions(rawValue: 262_144 | 2048)
        XCTAssertTrue(filmsOnly.canRequest(.movie))
        XCTAssertFalse(filmsOnly.canRequest(.tv))
        XCTAssertTrue(filmsOnly.canRequest4K(.movie))
        XCTAssertFalse(filmsOnly.canRequest4K(.tv))
        let admin = SeerrPermissions(rawValue: 2)
        XCTAssertTrue(admin.canRequest(.tv))
        XCTAssertTrue(admin.canRequest4K(.tv))
        XCTAssertFalse(SeerrPermissions(rawValue: 0).canRequest(.movie))
    }

    func testQuotaInWords() {
        XCTAssertEqual(SeerrQuota.Allowance(days: 7, limit: 5, used: 3, remaining: 2).summary, "2 of 5 requests left this week")
        XCTAssertEqual(SeerrQuota.Allowance(days: 1, limit: 1, used: 1, remaining: 0).summary, "0 of 1 request left today")
        XCTAssertEqual(SeerrQuota.Allowance(days: 30, limit: 10, used: 0, remaining: 10).summary, "10 of 10 requests left in 30 days")
        XCTAssertNil(SeerrQuota.Allowance(days: 7, limit: 0, used: 0, remaining: 0).summary, "no limit, nothing to say")
    }

    func testRefusalsInPlainWords() {
        func words(_ status: Int, _ message: String) -> String {
            SeerrClient.plainWords(status: status, body: Data(#"{"message":"\#(message)"}"#.utf8))
        }
        XCTAssertTrue(words(403, "Movie Quota exceeded.").contains("used all your requests"))
        XCTAssertEqual(words(409, "Request for this media already exists."), "That has already been requested.")
        XCTAssertTrue(words(403, "You do not have permission to make 4K requests.").contains("4K"))
        XCTAssertTrue(words(403, "You do not have permission to access this endpoint").contains("isn't allowed"))
        XCTAssertTrue(words(500, "").contains("problem"))
        XCTAssertEqual(SeerrClient.plainWords(status: 400, body: Data()), "Seerr turned that down.")
    }

    func testAConnectionSurvivesItsOwnEncoding() throws {
        let connection = SeerrConnection(server: "https://requests.example.com", cookie: "s%3Aabc", userId: 7,
                                         userName: "sam", permissions: 32,
                                         settings: SeerrPublicSettings(movie4kEnabled: true))
        let back = try JSONDecoder().decode(SeerrConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertEqual(back, connection)
        XCTAssertTrue(back.secure)
        XCTAssertEqual(back.host, "requests.example.com")
        XCTAssertFalse(SeerrConnection(server: "http://10.0.0.2:5055", cookie: "", userId: 1, userName: "", permissions: 0).secure)
    }

    func testMissingSeasonsInWords() {
        func seasons(_ numbers: Int...) -> [SeerrSeason] { numbers.map { SeerrSeason(seasonNumber: $0) } }
        XCTAssertEqual(SeerrItemHooks.list(seasons(3)), "Season 3")
        XCTAssertEqual(SeerrItemHooks.list(seasons(3, 4)), "Seasons 3 and 4")
        XCTAssertEqual(SeerrItemHooks.list(seasons(3, 4, 5)), "Seasons 3, 4 and 5")
    }

    func testAnItemsTMDBIdIsReadWhateverItsCase() throws {
        let item = try decode(BaseItem.self, #"{"Id":"a","Name":"Sherlock","Type":"Series","ProviderIds":{"Imdb":"tt1475582","TMDB":"19885"}}"#)
        XCTAssertEqual(item.tmdbId, 19885)
        XCTAssertNil(try decode(BaseItem.self, #"{"Id":"b","ProviderIds":{"Imdb":"tt1"}}"#).tmdbId)
    }
}
