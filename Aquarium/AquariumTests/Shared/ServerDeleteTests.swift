//  Delete from Server: when each way is offered, what each one asks of
//  Jellyfin and of Seerr, and what the dialog says.

import XCTest
@testable import Aquarium

@MainActor
final class ServerDeleteTests: XCTestCase {
    override func setUp() async throws { SeerrFixture.install() }
    override func tearDown() async throws { SeerrFixture.remove() }

    private var seerr: SeerrClient { SeerrClient.shared }
    private var client: JellyfinClient { JellyfinClient.shared }

    /// Seerr's "manage requests" bit with the plain "request" one.
    private static let manager = 16 | 32

    private func film(_ edit: (inout BaseItem) -> Void = { _ in }) -> BaseItem {
        CoreItem.movie("film1", name: "Heat") {
            $0.ProviderIds = ["Tmdb": "949"]
            edit(&$0)
        }
    }

    private func show() -> BaseItem {
        CoreItem.series("show1", name: "Severance") { $0.ProviderIds = ["Tmdb": "95396"] }
    }

    /// A Seerr whose account has `permissions`, with the given Radarr and
    /// Sonarr servers and one answer for every title page.
    private func connect(
        permissions: Int = manager,
        radarr: String = #"[{"id":0,"name":"Radarr","is4k":false,"isDefault":true}]"#,
        sonarr: String = #"[{"id":0,"name":"Sonarr","is4k":false,"isDefault":true}]"#,
        title: String = #"{"id":949,"title":"Heat","mediaInfo":{"id":41,"status":5,"serviceId":0,"externalServiceId":12,"requests":[{"id":7},{"id":9}]}}"#,
        fileStatus: Int = 204
    ) async throws {
        try await SeerrFixture.connect { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/api/v1/settings/public"): return SeerrStub.Answer(json: SeerrFixture.settings)
            case ("GET", "/api/v1/auth/me"): return SeerrStub.Answer(json: SeerrFixture.user(permissions: permissions))
            case ("GET", "/api/v1/service/radarr"): return SeerrStub.Answer(json: radarr)
            case ("GET", "/api/v1/service/sonarr"): return SeerrStub.Answer(json: sonarr)
            case ("GET", _) where path.hasPrefix("/api/v1/movie/") || path.hasPrefix("/api/v1/tv/"):
                return SeerrStub.Answer(json: title)
            case ("DELETE", _) where path.hasSuffix("/file"):
                return SeerrStub.Answer(status: fileStatus, json: fileStatus == 204 ? "" : #"{"message":"No Radarr server configured to delete media files"}"#)
            case ("DELETE", _): return SeerrStub.Answer(status: 204, json: "")
            default: return SeerrStub.Answer(status: 404)
            }
        }
        await seerr.refreshAccount()
        SeerrStub.forget()
    }

    // MARK: When Seerr's way is offered

    func testOfferedForAFilmOnRadarrToAnAccountThatManagesRequests() async throws {
        try await connect()
        let removal = await seerr.removal(for: film())
        XCTAssertEqual(removal, SeerrRemoval(kind: .movie, tmdbId: 949, mediaId: 41, copies: [false], requestIds: [7, 9]))
        XCTAssertEqual(removal?.service, "Radarr")
        XCTAssertEqual(SeerrStub.calls, ["GET /api/v1/service/radarr", "GET /api/v1/movie/949"])
    }

    func testAShowAsksAboutSonarr() async throws {
        try await connect(title: #"{"id":95396,"name":"Severance","mediaInfo":{"id":8,"serviceId":0,"externalServiceId":3}}"#)
        let removal = await seerr.removal(for: show())
        XCTAssertEqual(removal?.service, "Sonarr")
        XCTAssertEqual(removal?.mediaId, 8)
        XCTAssertEqual(SeerrStub.calls.first, "GET /api/v1/service/sonarr")
    }

    func testNotOfferedWithoutTheRightToManageRequests() async throws {
        try await connect(permissions: 32)
        XCTAssertFalse(seerr.mightRemove(film()))
        let removal = await seerr.removal(for: film())
        XCTAssertNil(removal)
        XCTAssertEqual(SeerrStub.calls, [], "nothing is asked of Seerr for an account that couldn't do it")
    }

    func testAnAdministratorMay() async throws {
        try await connect(permissions: 2)
        XCTAssertTrue(seerr.mightRemove(film()))
    }

    func testNotOfferedWhenSeerrHasNoRadarr() async throws {
        try await connect(radarr: "[]")
        let removal = await seerr.removal(for: film())
        XCTAssertNil(removal)
    }

    func testAFilmIsNotOfferedOnTheStrengthOfSonarr() async throws {
        try await connect(radarr: "[]")
        let film = await seerr.removal(for: film())
        XCTAssertNil(film)
        let show = await seerr.removal(for: show())
        XCTAssertNotNil(show, "the show's side is its own question")
    }

    /// Seerr removes by TMDB id from its default Radarr, so a film it only
    /// knows from the Jellyfin library (put on Radarr by hand, never scanned
    /// in) is offered too. Asking for a Radarr link on the record hid Seerr's
    /// way on a real server for every such title.
    func testOfferedForALibraryTitleSeerrHasNoRadarrLinkFor() async throws {
        try await connect(title: #"{"id":949,"title":"Heat","mediaInfo":{"id":41,"status":5}}"#)
        let removal = await seerr.removal(for: film())
        XCTAssertEqual(removal?.copies, [false])
        XCTAssertEqual(removal?.mediaId, 41)
    }

    func testNotOfferedForATitleSeerrOnlyKnowsOf() async throws {
        // A record with nothing behind it: not in the library, not on Radarr.
        try await connect(title: #"{"id":949,"title":"Heat","mediaInfo":{"id":41,"status":1}}"#)
        let removal = await seerr.removal(for: film())
        XCTAssertNil(removal)
    }

    func testAnUnlinkedTitleNeedsADefaultServer() {
        let library = SeerrMediaInfo(id: 41, status: 5)
        let plain = SeerrServiceServer(id: 0, name: "Radarr", is4k: false, isDefault: false)
        XCTAssertEqual(SeerrClient.removableCopies(of: library, on: [plain]), [], "Seerr would have no server to ask")
        var named = library
        named.serviceId = 0
        XCTAssertEqual(SeerrClient.removableCopies(of: named, on: [plain]), [false], "the record names the server")
        let fourK = SeerrServiceServer(id: 1, name: "Radarr 4K", is4k: true, isDefault: true)
        XCTAssertEqual(SeerrClient.removableCopies(of: library, on: [fourK]), [], "an ordinary copy is not removed from the 4K server")
    }

    func testNotOfferedForATitleSeerrHasNeverMet() async throws {
        try await connect(title: #"{"id":949,"title":"Heat"}"#)
        let removal = await seerr.removal(for: film())
        XCTAssertNil(removal)
    }

    func testNotOfferedForSeasonsEpisodesOrWithoutATmdbId() async throws {
        try await connect()
        XCTAssertFalse(seerr.mightRemove(CoreItem.make("s1", "Season")))
        XCTAssertFalse(seerr.mightRemove(CoreItem.make("e1", "Episode")))
        let removal = await seerr.removal(for: film { $0.ProviderIds = nil })
        XCTAssertNil(removal)
    }

    func testNotOfferedWithoutSeerr() async {
        XCTAssertFalse(seerr.mightRemove(film()))
        let removal = await seerr.removal(for: film())
        XCTAssertNil(removal)
    }

    func testThe4KCopyNeedsA4KServer() async throws {
        let both = #"{"id":949,"mediaInfo":{"id":41,"serviceId":0,"serviceId4k":1}}"#
        try await connect(title: both)
        var removal = await seerr.removal(for: film())
        XCTAssertEqual(removal?.copies, [false], "no 4K Radarr, so only the ordinary copy")

        try await connect(
            radarr: #"[{"id":0,"is4k":false,"isDefault":true},{"id":1,"is4k":true,"isDefault":true}]"#, title: both
        )
        removal = await seerr.removal(for: film())
        XCTAssertEqual(removal?.copies, [false, true])
    }

    // MARK: What removing through Seerr does

    func testRemovingTakesItOffRadarrThenClearsRequestsAndTheRecord() async throws {
        try await connect()
        let removal = SeerrRemoval(kind: .movie, tmdbId: 949, mediaId: 41, copies: [false], requestIds: [7, 9])
        let before = seerr.requestsChanged
        try await seerr.remove(removal)
        XCTAssertEqual(SeerrStub.calls, [
            "DELETE /api/v1/media/41/file",
            "DELETE /api/v1/request/7",
            "DELETE /api/v1/request/9",
            "DELETE /api/v1/media/41",
        ])
        XCTAssertEqual(SeerrStub.requests.first?.url?.query, "is4k=false")
        XCTAssertGreaterThan(seerr.requestsChanged, before, "the Requests list asks again")
    }

    func testBothCopiesAreRemoved() async throws {
        try await connect()
        try await seerr.remove(SeerrRemoval(kind: .movie, tmdbId: 949, mediaId: 41, copies: [false, true], requestIds: []))
        XCTAssertEqual(SeerrStub.requests.prefix(2).map { $0.url?.query }, ["is4k=false", "is4k=true"])
    }

    func testWhenRadarrRefusesNothingElseIsTouched() async throws {
        try await connect(fileStatus: 409)
        do {
            try await seerr.remove(SeerrRemoval(kind: .movie, tmdbId: 949, mediaId: 41, copies: [false], requestIds: [7]))
            XCTFail("a refusal should be thrown")
        } catch {
            XCTAssertEqual(SeerrStub.calls, ["DELETE /api/v1/media/41/file"], "requests and the record are left as they were")
        }
    }

    // MARK: Both

    private var bothChoice: ServerDeleteChoice {
        ServerDeleteChoice(
            item: film { $0.CanDelete = true }, jellyfin: true,
            seerr: SeerrRemoval(kind: .movie, tmdbId: 949, mediaId: 41, copies: [false], requestIds: [7])
        )
    }

    func testBothRemovesThroughSeerrThenDeletesFromJellyfin() async throws {
        try await connect()
        StubURLProtocol.stub("/Items/film1", method: "DELETE", status: 204)
        await ServerDeleting.deleteFromBoth(bothChoice, client: client, seerr: seerr, app: AppModel.shared)
        XCTAssertEqual(SeerrStub.calls, ["DELETE /api/v1/media/41/file", "DELETE /api/v1/request/7", "DELETE /api/v1/media/41"])
        let sent = StubURLProtocol.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(sent.map { $0.url?.path }, ["/Items/film1"])
    }

    func testBothDeletesNothingFromJellyfinWhenSeerrRefuses() async throws {
        try await connect(fileStatus: 409)
        StubURLProtocol.stub("/Items/film1", method: "DELETE", status: 204)
        await ServerDeleting.deleteFromBoth(bothChoice, client: client, seerr: seerr, app: AppModel.shared)
        XCTAssertTrue(StubURLProtocol.requests.filter { $0.httpMethod == "DELETE" }.isEmpty,
                      "Radarr would only fetch the film again")
    }

    // MARK: Jellyfin's way

    func testDeletingAsksJellyfinToDeleteTheItem() async throws {
        StubURLProtocol.stub("/Items/film1", method: "DELETE", status: 204)
        try await client.deleteItem("film1")
        let sent = StubURLProtocol.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(sent.map { $0.url?.path }, ["/Items/film1"])
    }

    func testARefusalFromJellyfinIsThrown() async {
        StubURLProtocol.stub("/Items/film1", method: "DELETE", status: 403)
        do {
            try await client.deleteItem("film1")
            XCTFail("a refusal should be thrown")
        } catch APIError.server(let status, _) {
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTheServersWordOnDeletingIsRead() throws {
        let item = try JSONDecoder().decode(BaseItem.self, from: Data(#"{"Id":"a","Type":"Movie","CanDelete":true}"#.utf8))
        XCTAssertEqual(item.CanDelete, true)
    }

    // MARK: The menu entry

    func testTheEntryFollowsJellyfinsWordWhenSeerrIsNotConnected() {
        XCTAssertTrue(ServerDeleting.mightDelete(film { $0.CanDelete = true }, seerr: seerr))
        XCTAssertFalse(ServerDeleting.mightDelete(film { $0.CanDelete = false }, seerr: seerr))
        XCTAssertFalse(ServerDeleting.mightDelete(film(), seerr: seerr), "no word from the server is not a yes")
    }

    func testTheEntryIsThereForSeerrAloneOnAFilmButNotAnEpisode() async throws {
        try await connect()
        XCTAssertTrue(ServerDeleting.mightDelete(film { $0.CanDelete = false }, seerr: seerr))
        XCTAssertFalse(ServerDeleting.mightDelete(CoreItem.make("e1", "Episode") { $0.CanDelete = false }, seerr: seerr))
        XCTAssertTrue(ServerDeleting.mightDelete(CoreItem.make("e1", "Episode") { $0.CanDelete = true }, seerr: seerr))
    }

    func testTheEntryIsOnlyForFilmsAndTelevision() {
        for kind in ["MusicAlbum", "Audio", "BoxSet", "Playlist", "TvChannel", "CollectionFolder"] {
            XCTAssertFalse(ServerDeleting.mightDelete(CoreItem.make("x", kind) { $0.CanDelete = true }, seerr: seerr), kind)
        }
        for kind in ["Movie", "Series", "Season", "Episode"] {
            XCTAssertTrue(ServerDeleting.mightDelete(CoreItem.make("x", kind) { $0.CanDelete = true }, seerr: seerr), kind)
        }
    }

    // MARK: Asking

    func testAskingOffersBothWaysWhenBothAreOpen() async throws {
        try await connect()
        let app = AppModel.shared
        app.deletingFromServer = nil
        await ServerDeleting.ask(film { $0.CanDelete = true }, client: client, seerr: seerr, app: app)
        XCTAssertEqual(app.deletingFromServer?.jellyfin, true)
        XCTAssertEqual(app.deletingFromServer?.seerr?.mediaId, 41)
        app.deletingFromServer = nil
    }

    func testAskingOffersOnlyJellyfinWhenSeerrHasNoRadarr() async throws {
        try await connect(radarr: "[]")
        let app = AppModel.shared
        await ServerDeleting.ask(film { $0.CanDelete = true }, client: client, seerr: seerr, app: app)
        XCTAssertEqual(app.deletingFromServer?.jellyfin, true)
        XCTAssertNil(app.deletingFromServer?.seerr)
        app.deletingFromServer = nil
    }

    func testAskingWithNeitherWayOpenAsksNothing() async throws {
        try await connect(radarr: "[]")
        let app = AppModel.shared
        app.deletingFromServer = nil
        await ServerDeleting.ask(film { $0.CanDelete = false }, client: client, seerr: seerr, app: app)
        XCTAssertNil(app.deletingFromServer)
    }

    func testAGridsItemIsFetchedWholeForItsTmdbId() async throws {
        try await connect()
        StubURLProtocol.stub("/Items/film1", json: #"{"Id":"film1","Type":"Movie","Name":"Heat","CanDelete":true,"ProviderIds":{"Tmdb":"949"}}"#)
        let app = AppModel.shared
        await ServerDeleting.ask(film { $0.ProviderIds = nil; $0.CanDelete = true }, client: client, seerr: seerr, app: app)
        XCTAssertEqual(app.deletingFromServer?.seerr?.tmdbId, 949)
        app.deletingFromServer = nil
    }

    // MARK: Words

    func testNames() {
        XCTAssertEqual(ServerDeleting.name(of: film()), "Heat")
        let season = CoreItem.make("s", "Season", name: "Season 2") { $0.SeriesName = "Severance" }
        XCTAssertEqual(ServerDeleting.name(of: season), "Severance, Season 2")
    }

    func testLabelsAndSmallPrint() {
        XCTAssertEqual(ServerDeleting.jellyfinLabel, "Delete from Jellyfin")
        XCTAssertEqual(ServerDeleting.seerrLabel, "Delete from Seerr")
        XCTAssertEqual(ServerDeleting.bothLabel, "Delete from Both")
        let removal = SeerrRemoval(kind: .tv, tmdbId: 1, mediaId: 2, copies: [false], requestIds: [])

        let both = ServerDeleting.message(for: ServerDeleteChoice(item: show(), jellyfin: true, seerr: removal))
        XCTAssertTrue(both.contains("every episode"))
        XCTAssertTrue(both.contains("Sonarr"))
        XCTAssertTrue(both.contains("can't be undone"))
        XCTAssertTrue(both.contains("downloaded to your devices are kept"))

        let jellyfinOnly = ServerDeleting.message(for: ServerDeleteChoice(item: film(), jellyfin: true, seerr: nil))
        XCTAssertFalse(jellyfinOnly.contains("Seerr"))
        XCTAssertFalse(jellyfinOnly.contains("Both"))
        XCTAssertTrue(both.contains("Both does the two together"))
    }
}
