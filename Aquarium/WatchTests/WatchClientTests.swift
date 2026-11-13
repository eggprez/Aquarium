//  The watch's own Jellyfin client (Watch/WatchClient.swift) against a stub
//  server: signing in from the phone's hand-over, the honest offline and
//  sign-in states, every list it asks for, streaming and download
//  addresses, and telling the server what was heard.

import XCTest
@testable import AquariumWatch

final class WatchClientTests: WatchUnitTestCase {

    // MARK: Sign-in from the phone

    func testInstallSignsInAndKeepsTheTokenOutOfTheAccount() throws {
        let account = try XCTUnwrap(client.account)
        XCTAssertTrue(client.isSignedIn)
        XCTAssertEqual(account.server, WX.server)
        XCTAssertEqual(account.userId, WX.userId)
        XCTAssertEqual(account.serverId, "stub-server")
        // Test mode keeps the token in its own store, never the keychain.
        XCTAssertEqual(WatchKeychain.token(account: WX.accountKey), WX.token)
        let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: "watch_account"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(WX.token), "the token is not in the saved account")
    }

    func testTheSameAccountAgainOnlyRefreshesTheToken() async {
        WatchStub.on("/System/Info/Public", json: "{}")
        var fresh = WX.credentials
        fresh.token = "refreshed"
        client.install(fresh)
        _ = await client.checkOnline()
        XCTAssertTrue((WatchStub.requests.last?.value(forHTTPHeaderField: "Authorization") ?? "").contains(#"Token="refreshed""#))
    }

    func testSignOutForgetsAccountAndToken() {
        client.signOut()
        XCTAssertFalse(client.isSignedIn)
        XCTAssertNil(WatchKeychain.token(account: WX.accountKey))
        XCTAssertNil(UserDefaults.standard.data(forKey: "watch_account"))
    }

    func testTheWatchIsItsOwnDeviceToTheServer() async {
        WatchStub.on("/System/Info/Public", json: "{}")
        _ = await client.checkOnline()
        let auth = WatchStub.requests.last?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("MediaBrowser "), auth)
        XCTAssertTrue(auth.contains(#"Client="Aquarium""#), auth)
        XCTAssertTrue(auth.contains(#"Device="Apple Watch""#), auth)
        XCTAssertTrue(auth.contains(#"DeviceId="\#(client.deviceId)""#), auth)
        XCTAssertFalse(client.deviceId.isEmpty)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "watch_device_id"), client.deviceId)
    }

    func testNothingIsAskedSignedOut() async {
        client.signOut()
        do {
            _ = try await client.request("/Items")
            XCTFail("a request with no account")
        } catch APIError.notConfigured {
        } catch { XCTFail("\(error)") }
        let online = await client.checkOnline()
        XCTAssertFalse(online)
        XCTAssertTrue(WatchStub.requests.isEmpty)
        XCTAssertNil(client.imageURL(for: WX.song("x", imageTag: "t")))
        XCTAssertNil(client.downloadRequest(for: WX.song("x")))
    }

    // MARK: Honest states

    func testCheckOnlineAsksThePublicEndpointQuickly() async {
        WatchStub.on("/System/Info/Public", json: #"{"Id":"s"}"#)
        let online = await client.checkOnline()
        XCTAssertTrue(online)
        XCTAssertFalse(client.isOffline)
        XCTAssertNotNil(client.lastCheckedAt)
        XCTAssertEqual(WatchStub.requests.last?.timeoutInterval, 6)
    }

    func testATransportFailureIsOfflineAndAnAnswerIsBackOnline() async throws {
        WatchStub.fail("/Items", .notConnectedToInternet)
        do {
            _ = try await client.items(JellyfinClient.Query(types: "Audio"))
            XCTFail("expected a failure")
        } catch APIError.offline {
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(client.isOffline)
        // The server answers again: the next request says so.
        WatchStub.on("/Items", items: [])
        _ = try await client.items(JellyfinClient.Query(types: "Audio"))
        XCTAssertFalse(client.isOffline)
    }

    func testCheckOnlineRecoversFromOffline() async {
        WatchStub.fail("/System/Info/Public")
        var online = await client.checkOnline()
        XCTAssertFalse(online)
        XCTAssertTrue(client.isOffline)
        WatchStub.on("/System/Info/Public", json: "{}")
        online = await client.checkOnline()
        XCTAssertTrue(online)
        XCTAssertFalse(client.isOffline)
    }

    func testBestEffortRequestsDontChangeTheState() async {
        WatchStub.fail("/Sessions/Playing/Progress")
        await client.reportPlaying(started: false, itemId: "x", positionTicks: 0, paused: false, stream: nil, rate: 1)
        XCTAssertFalse(client.isOffline, "a progress report that fails isn't the server gone")
    }

    func testA401IsAnExpiredSignInNotAnOutage() async {
        WatchStub.on("/Items", status: 401, json: "")
        do {
            _ = try await client.items(JellyfinClient.Query(types: "Audio"))
            XCTFail("expected a refusal")
        } catch APIError.auth(let message) {
            XCTAssertTrue(message.contains("expired"), message)
        } catch { XCTFail("\(error)") }
        XCTAssertFalse(client.isOffline, "the server answered")
    }

    /// Regression, master-fix-list "From Apple Watch": "Settings says Server:
    /// Connected while every request gets 401 (1/1)".
    func testSettingsDoesNotSayConnectedWhileTheSignInIsRefused() async {
        WatchStub.on("/Items", status: 401, json: "")
        _ = try? await client.items(JellyfinClient.Query(types: "Audio"))
        XCTAssertNotEqual(WatchSettingsView.serverStatus(client), "Connected")
    }

    func testSettingsServerLine() async {
        XCTAssertEqual(WatchSettingsView.serverStatus(client), "Connected")
        WatchStub.fail("/System/Info/Public")
        _ = await client.checkOnline()
        XCTAssertEqual(WatchSettingsView.serverStatus(client), "Out of reach")
    }

    func testOtherErrorsCarryTheirStatus() async {
        WatchStub.on("/Items", status: 500, json: "")
        do {
            _ = try await client.items(JellyfinClient.Query(types: "Audio"))
            XCTFail("expected a failure")
        } catch APIError.server(let status, let path) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(path, "/Items")
        } catch { XCTFail("\(error)") }
    }

    func testUnreadableAnswersSaySo() async {
        WatchStub.on("/Items/x", json: "not json")
        do {
            _ = try await client.item("x")
            XCTFail("expected a failure")
        } catch APIError.message(let m) {
            XCTAssertTrue(m.contains("couldn't read"), m)
        } catch { XCTFail("\(error)") }
    }

    func testAnEmptyListAnswerIsAnEmptyList() async throws {
        WatchStub.on("/Items", body: Data())
        let r = try await client.items(JellyfinClient.Query(types: "Audio"))
        XCTAssertEqual(r.items.count, 0)
    }

    func testErrorDescriptionsAreForPeople() {
        XCTAssertTrue(APIError.notConfigured.errorDescription?.contains("iPhone") == true)
        XCTAssertEqual(APIError.server(status: 503, path: "/x").errorDescription, "Server error 503")
        XCTAssertEqual(APIError.offline("o").errorDescription, "o")
        XCTAssertEqual(APIError.auth("a").errorDescription, "a")
        XCTAssertEqual(APIError.message("m").errorDescription, "m")
    }

    // MARK: Plumbing

    func testPathIdsAreEscapedOnlyWhenTheyNeedIt() {
        XCTAssertEqual(JellyfinClient.pathId("abc-123_X"), "abc-123_X")
        XCTAssertEqual(JellyfinClient.pathId("a/b c"), "a%2Fb%20c")
    }

    func testQueriesEscapeThePlusSign() {
        let q = JellyfinClient.encode([URLQueryItem(name: "SearchTerm", value: "AC+DC & co")])
        XCTAssertTrue(q.contains("%2B"), q)
        XCTAssertFalse(q.contains("+"), q)
    }

    func testTheTokenRidesInATranscodeAddressOnce() throws {
        let url = try XCTUnwrap(URL(string: "\(WX.server)/Audio/x/main.m3u8?a=1"))
        let signed = client.authorized(url)
        XCTAssertEqual(WatchStub.query(URLRequest(url: signed))["ApiKey"], WX.token)
        XCTAssertEqual(client.authorized(signed), signed, "not added twice")
        let old = try XCTUnwrap(URL(string: "\(WX.server)/x?api_key=k"))
        XCTAssertEqual(client.authorized(old), old)
        client.signOut()
        XCTAssertEqual(client.authorized(url), url, "no token, no change")
    }

    // MARK: Lists

    func testItemsQueryCarriesEverythingAsked() async throws {
        WatchStub.on("/Items", items: [WX.song("a")])
        var q = JellyfinClient.Query(types: "Audio", parentId: "p", sortBy: "Random", descending: true, startIndex: 5, limit: 7)
        q.albumArtistIds = ["aa"]
        q.artistIds = ["ar1", "ar2"]
        q.genreIds = ["g"]
        q.searchTerm = "hello"
        q.ids = ["i1", "i2"]
        q.played = true
        let r = try await client.items(q)
        XCTAssertEqual(r.items.map(\.Id), ["a"])
        let sent = WatchStub.query(try XCTUnwrap(WatchStub.requests.last))
        XCTAssertEqual(sent["userId"], WX.userId)
        XCTAssertEqual(sent["IncludeItemTypes"], "Audio")
        XCTAssertEqual(sent["Recursive"], "true")
        XCTAssertEqual(sent["SortBy"], "Random")
        XCTAssertEqual(sent["SortOrder"], "Descending")
        XCTAssertEqual(sent["StartIndex"], "5")
        XCTAssertEqual(sent["Limit"], "7")
        XCTAssertEqual(sent["ParentId"], "p")
        XCTAssertEqual(sent["AlbumArtistIds"], "aa")
        XCTAssertEqual(sent["ArtistIds"], "ar1,ar2")
        XCTAssertEqual(sent["GenreIds"], "g")
        XCTAssertEqual(sent["Ids"], "i1,i2")
        XCTAssertEqual(sent["SearchTerm"], "hello")
        XCTAssertEqual(sent["Filters"], "IsPlayed")
        XCTAssertEqual(sent["Fields"], JellyfinClient.listFields)
    }

    func testOneItemWithEverythingAPageNeeds() async throws {
        WatchStub.on("/Items/b1", body: WX.itemJSON(WX.book("b1", chapters: [0, 150])))
        let item = try await client.item("b1")
        XCTAssertEqual(item.Chapters?.count, 2)
        let q = WatchStub.query(try XCTUnwrap(WatchStub.requests.last))
        XCTAssertEqual(q["userId"], WX.userId)
        XCTAssertTrue(q["Fields"]?.contains("Chapters") == true)
        XCTAssertTrue(q["Fields"]?.contains("MediaSources") == true)
    }

    func testItemsByIdGoFiftyAtATime() async throws {
        let ids = (0..<120).map { "id\($0)" }
        WatchStub.on("/Items", items: [WX.song("one")])
        let out = try await client.items(ids: ids, detail: true)
        let asks = WatchStub.requests(path: "/Items")
        XCTAssertEqual(asks.count, 3)
        XCTAssertEqual(asks.map { WatchStub.query($0)["Ids"]?.split(separator: ",").count }, [50, 50, 20])
        XCTAssertEqual(WatchStub.query(asks[0])["Fields"], JellyfinClient.detailFields)
        XCTAssertEqual(out.count, 3)
    }

    func testResumeAudioAsksForAudioInProgress() async throws {
        WatchStub.on("/UserItems/Resume", items: [WX.book("b"), WX.song("s")])
        let r = try await client.resumeAudio(limit: 4)
        XCTAssertEqual(r.map(\.Id), ["b", "s"])
        let q = WatchStub.query(try XCTUnwrap(WatchStub.requests(path: "/UserItems/Resume").last { WatchStub.query($0)["Limit"] == "4" }))
        XCTAssertEqual(q["MediaTypes"], "Audio")
        XCTAssertEqual(q["Limit"], "4")
    }

    func testRecentlyPlayedSongs() async throws {
        WatchStub.on("/Items", items: [])
        _ = try await client.recentlyPlayedSongs(limit: 9)
        let q = WatchStub.query(try XCTUnwrap(WatchStub.requests.last))
        XCTAssertEqual(q["SortBy"], "DatePlayed,SortName")
        XCTAssertEqual(q["Filters"], "IsPlayed")
        XCTAssertEqual(q["Limit"], "9")
    }

    func testAlbumsArtistsGenresAndSongs() async throws {
        WatchStub.on("/Items", items: [])
        WatchStub.on("/Artists/AlbumArtists", items: [WX.artist("ar")])
        WatchStub.on("/MusicGenres", items: [WX.genre("g")])
        _ = try await client.albums(startIndex: 10, limit: 20, sortBy: "DateCreated", descending: true)
        var q = WatchStub.query(WatchStub.requests.last!)
        XCTAssertEqual(q["IncludeItemTypes"], "MusicAlbum")
        XCTAssertEqual(q["SortBy"], "DateCreated")
        XCTAssertEqual(q["StartIndex"], "10")
        let artists = try await client.albumArtists()
        XCTAssertEqual(artists.items.map(\.Id), ["ar"])
        _ = try await client.albums(artistId: "ar")
        q = WatchStub.query(WatchStub.requests.last!)
        XCTAssertEqual(q["AlbumArtistIds"], "ar")
        _ = try await client.songs(artistId: "ar")
        q = WatchStub.query(WatchStub.requests.last!)
        XCTAssertEqual(q["ArtistIds"], "ar")
        XCTAssertEqual(q["IncludeItemTypes"], "Audio")
        let genres = try await client.genres()
        XCTAssertEqual(genres.map(\.Id), ["g"])
        _ = try await client.songs(genreId: "g", limit: 5)
        q = WatchStub.query(WatchStub.requests.last!)
        XCTAssertEqual(q["GenreIds"], "g")
        XCTAssertEqual(q["SortBy"], "Random")
        _ = try await client.songs(startIndex: 3, limit: 4, searchTerm: "x")
        q = WatchStub.query(WatchStub.requests.last!)
        XCTAssertEqual(q["SearchTerm"], "x")
        _ = try await client.randomSongs(limit: 6)
        q = WatchStub.query(WatchStub.requests.last!)
        XCTAssertEqual(q["SortBy"], "Random")
        XCTAssertEqual(q["Limit"], "6")
        _ = try await client.audiobooks(sortBy: "DateCreated", descending: true, searchTerm: "b")
        q = WatchStub.query(WatchStub.requests.last!)
        XCTAssertEqual(q["IncludeItemTypes"], "AudioBook")
        XCTAssertEqual(q["SearchTerm"], "b")
    }

    func testAlbumTracksComeInSleeveOrder() async throws {
        WatchStub.on("/Items", query: ["ParentId": "al"], items: [
            WX.song("d2t1", track: 1, disc: 2), WX.song("d1t2", track: 2, disc: 1), WX.song("d1t1", track: 1, disc: 1),
        ])
        let tracks = try await client.albumTracks(albumId: "al")
        XCTAssertEqual(tracks.map(\.Id), ["d1t1", "d1t2", "d2t1"])
    }

    func testPlaylistsLeaveOutOnlyWhatPlainlyIsntMusic() async throws {
        var video = WX.playlist("v"); video.MediaType = "Video"
        var unknown = WX.playlist("u"); unknown.MediaType = "Unknown"
        var unset = WX.playlist("n"); unset.MediaType = nil
        var book = WX.playlist("b"); book.MediaType = "Book"
        WatchStub.on("/Items", items: [WX.playlist("a"), video, unknown, unset, book])
        let lists = try await client.playlists()
        XCTAssertEqual(lists.map(\.Id), ["a", "u", "n"])
    }

    func testPlaylistItemsInTheirOwnOrderWithTheWebFallback() async throws {
        WatchStub.on("/Playlists/p/Items", items: [WX.song("2"), WX.song("1")])
        var songs = try await client.playlistItems(playlistId: "p")
        XCTAssertEqual(songs.map(\.Id), ["2", "1"])

        // An empty or refused strict route falls back to ParentId.
        WatchStub.on("/Playlists/q/Items", status: 404, json: "")
        WatchStub.on("/Items", query: ["ParentId": "q"], items: [WX.song("3")])
        songs = try await client.playlistItems(playlistId: "q")
        XCTAssertEqual(songs.map(\.Id), ["3"])

        // Offline is offline: no fallback.
        WatchStub.fail("/Playlists/r/Items")
        do {
            _ = try await client.playlistItems(playlistId: "r")
            XCTFail("expected offline")
        } catch APIError.offline {
        } catch { XCTFail("\(error)") }
    }

    func testSearchAsksFourWaysAndKeepsWhatAnswered() async throws {
        WatchStub.on("/Items", query: ["IncludeItemTypes": "Audio"], items: [WX.song("s")])
        WatchStub.on("/Items", query: ["IncludeItemTypes": "AudioBook"], items: [WX.book("b")])
        WatchStub.on("/Items", query: ["IncludeItemTypes": "MusicAlbum"], status: 500)
        var video = WX.playlist("v"); video.MediaType = "Video"
        WatchStub.on("/Items", query: ["IncludeItemTypes": "Playlist"], items: [WX.playlist("p"), video])
        let r = try await client.search("FX")
        XCTAssertEqual(r.songs.map(\.Id), ["s"])
        XCTAssertEqual(r.books.map(\.Id), ["b"])
        XCTAssertEqual(r.albums.map(\.Id), [], "a part that failed is empty, not the whole search")
        XCTAssertEqual(r.playlists.map(\.Id), ["p"])
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(JellyfinClient.SearchResults().isEmpty)
        XCTAssertTrue(WatchStub.requests(path: "/Items").allSatisfy { WatchStub.query($0)["SearchTerm"] == "FX" })
    }

    // MARK: Pictures

    func testImageAddressesFallBackFromItemToAlbum() throws {
        var item = WX.song("s", imageTag: "own")
        var url = try XCTUnwrap(client.imageURL(for: item, width: 150))
        XCTAssertTrue(url.absoluteString.hasPrefix("\(WX.server)/Items/s/Images/Primary?maxWidth=200&tag=own"), url.absoluteString)
        item.ImageTags = nil
        item.AlbumPrimaryImageTag = "alb"
        url = try XCTUnwrap(client.imageURL(for: item, width: 500))
        XCTAssertTrue(url.absoluteString.contains("/Items/album-1/Images/Primary?maxWidth=500&tag=alb"), url.absoluteString)
        item.AlbumPrimaryImageTag = nil
        item.PrimaryImageTag = "p"
        url = try XCTUnwrap(client.imageURL(for: item, width: 100))
        XCTAssertTrue(url.absoluteString.contains("/Items/s/Images/Primary?maxWidth=120&tag=p"), url.absoluteString)
        item.PrimaryImageTag = nil
        XCTAssertNil(client.imageURL(for: item))
    }

    // MARK: Playing

    private func playbackInfo(direct: Bool, transcodingUrl: String? = nil, container: String = "mp3") -> String {
        """
        {"PlaySessionId":"ps","MediaSources":[{"Id":"ms","Container":"\(container)","ETag":"et","SupportsDirectPlay":\(direct),"SupportsDirectStream":\(direct)\(transcodingUrl.map { #","TranscodingUrl":"\#($0)""# } ?? "")}]}
        """
    }

    func testADirectStreamIsLetInByItsHeader() async throws {
        WatchStub.on("/Items/s/PlaybackInfo", method: "POST", json: playbackInfo(direct: true))
        let stream = try await client.stream(for: WX.song("s"))
        XCTAssertFalse(stream.isTranscode)
        XCTAssertEqual(stream.url.path, "/Audio/s/stream.mp3")
        let q = WatchStub.query(URLRequest(url: stream.url))
        XCTAssertEqual(q["static"], "true")
        XCTAssertEqual(q["mediaSourceId"], "ms")
        XCTAssertEqual(q["playSessionId"], "ps")
        XCTAssertEqual(q["Tag"], "et")
        XCTAssertNil(q["ApiKey"], "the token is never in a direct file's address")
        XCTAssertTrue(stream.headers["Authorization"]?.contains(WX.token) == true)
        let body = WatchStub.body(try XCTUnwrap(WatchStub.requests.last))
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        XCTAssertEqual(profile["Name"] as? String, "Aquarium Watch")
        XCTAssertEqual(profile["MusicStreamingTranscodingBitrate"] as? Int, JellyfinClient.streamBitrate)
        XCTAssertEqual(body["UserId"] as? String, WX.userId)
    }

    func testATranscodeCarriesTheTokenInItsAddress() async throws {
        WatchStub.on("/Items/s/PlaybackInfo", method: "POST", json: playbackInfo(direct: false, transcodingUrl: "/Audio/s/main.m3u8?x=1"))
        let stream = try await client.stream(for: WX.song("s"))
        XCTAssertTrue(stream.isTranscode)
        XCTAssertEqual(stream.headers, [:])
        XCTAssertEqual(WatchStub.query(URLRequest(url: stream.url))["ApiKey"], WX.token)
        XCTAssertEqual(stream.playSessionId, "ps")
    }

    func testAStreamTheClientCantUseIsAnError() async {
        WatchStub.on("/Items/s/PlaybackInfo", method: "POST", json: playbackInfo(direct: false, transcodingUrl: "http://elsewhere/x.m3u8"))
        do { _ = try await client.stream(for: WX.song("s")); XCTFail("expected an error") } catch {}
        WatchStub.on("/Items/s/PlaybackInfo", method: "POST", json: #"{"MediaSources":[]}"#)
        do { _ = try await client.stream(for: WX.song("s")); XCTFail("expected an error") } catch APIError.message(let m) {
            XCTAssertTrue(m.contains("nothing to play"), m)
        } catch { XCTFail("\(error)") }
    }

    func testStoppingATranscodeNamesThisDeviceAndSession() async throws {
        WatchStub.on("/Videos/ActiveEncodings", method: "DELETE", json: "")
        await client.stopTranscode(playSessionId: "ps")
        let r = try XCTUnwrap(WatchStub.requests.last)
        XCTAssertEqual(r.httpMethod, "DELETE")
        XCTAssertEqual(WatchStub.query(r)["playSessionId"], "ps")
        XCTAssertEqual(WatchStub.query(r)["deviceId"], client.deviceId)
    }

    // MARK: Downloading

    func testADownloadIsAnAACEncodeWithTheTokenInAHeader() throws {
        var item = WX.song("s", seconds: 100)
        var source = MediaSource()
        source.Id = "ms"
        source.Container = "flac"
        item.MediaSources = [source]
        let (request, ext) = try XCTUnwrap(client.downloadRequest(for: item))
        XCTAssertEqual(ext, "m4a")
        XCTAssertEqual(request.url?.path, "/Audio/s/stream.m4a")
        let q = WatchStub.query(request)
        XCTAssertEqual(q["static"], "false")
        XCTAssertEqual(q["audioCodec"], "aac")
        XCTAssertEqual(q["audioBitRate"], "128000")
        XCTAssertEqual(q["mediaSourceId"], "ms")
        XCTAssertNil(q["ApiKey"])
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains(WX.token) == true)
        XCTAssertEqual(request.timeoutInterval, 120)
    }

    func testADownloadTheWatchCanPlayIsTheServersOwnFile() throws {
        var item = WX.book("b", seconds: 900)
        var source = MediaSource()
        source.Id = "ms"
        source.Container = "m4b"
        source.Size = 5_000_000
        item.MediaSources = [source]
        let (request, ext) = try XCTUnwrap(client.downloadRequest(for: item))
        XCTAssertEqual(ext, "m4b")
        XCTAssertEqual(request.url?.path, "/Audio/b/stream.m4b")
        XCTAssertEqual(WatchStub.query(request)["static"], "true")
    }

    func testTheSizeOfADownloadComesFromItsLength() {
        XCTAssertEqual(JellyfinClient.estimatedBytes(for: WX.song("s", seconds: 0)), 0)
        XCTAssertEqual(JellyfinClient.estimatedBytes(for: WX.song("s", seconds: 60)), Int64(60.0 * 128_000 / 8 * 1.03))
    }

    // MARK: Telling the server

    func testAPositionIsAStoppedReport() async throws {
        WatchStub.on("/Sessions/Playing/Stopped", method: "POST", json: "")
        try await client.reportStopped(itemId: "b", positionTicks: 42, mediaSourceId: "ms", playSessionId: "ps")
        let body = WatchStub.body(try XCTUnwrap(WatchStub.requests.last))
        XCTAssertEqual(body["ItemId"] as? String, "b")
        XCTAssertEqual(body["PositionTicks"] as? Int, 42)
        XCTAssertEqual(body["IsPaused"] as? Bool, true)
        XCTAssertEqual(body["MediaSourceId"] as? String, "ms")
    }

    func testLiveReportsNameStartAndProgress() async throws {
        WatchStub.on("/Sessions/Playing", method: "POST", json: "")
        WatchStub.on("/Sessions/Playing/Progress", method: "POST", json: "")
        let stream = WatchStream(url: URL(string: "http://x")!, headers: [:], isTranscode: true, mediaSourceId: "ms", playSessionId: "ps")
        await client.reportPlaying(started: true, itemId: "s", positionTicks: 1, paused: false, stream: stream, rate: 1.5)
        await client.reportPlaying(started: false, itemId: "s", positionTicks: 2, paused: true, stream: nil, rate: 1)
        let reports = WatchStub.requests.filter { $0.url?.path.hasPrefix("/Sessions/Playing") == true }
        XCTAssertEqual(reports.map(\.url?.path), ["/Sessions/Playing", "/Sessions/Playing/Progress"])
        guard reports.count == 2 else { return }
        let first = WatchStub.body(reports[0])
        XCTAssertEqual(first["PlayMethod"] as? String, "Transcode")
        XCTAssertEqual(first["PlaybackRate"] as? Double, 1.5)
        XCTAssertEqual(WatchStub.body(reports[1])["PlayMethod"] as? String, "DirectPlay")
        XCTAssertEqual(WatchStub.body(reports[1])["IsPaused"] as? Bool, true)
    }

    func testAPlayIsCountedWithItsDate() async throws {
        WatchStub.on("/UserPlayedItems/s", method: "POST", json: "")
        WatchStub.on("/UserPlayedItems/s", method: "DELETE", json: "")
        try await client.markPlayed(itemId: "s", at: Date(timeIntervalSince1970: 0))
        var q = WatchStub.query(try XCTUnwrap(WatchStub.requests.last))
        XCTAssertEqual(q["userId"], WX.userId)
        XCTAssertEqual(q["datePlayed"], "1970-01-01T00:00:00Z")
        try await client.markUnplayed(itemId: "s")
        q = WatchStub.query(try XCTUnwrap(WatchStub.requests.last))
        XCTAssertEqual(WatchStub.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(q["userId"], WX.userId)
    }

    // MARK: send(event): the direct route

    func testASongHeardOffTheWatchIsCountedAsAPlay() async throws {
        WatchStub.on("/UserPlayedItems/s", method: "POST", json: "")
        try await client.send(WatchProgressEvent(itemId: "s", positionTicks: 0, played: true, isAudiobook: false))
        XCTAssertEqual(WatchStub.paths, ["/UserPlayedItems/s"])
    }

    /// Regression, 1228f45 "the direct path no longer counts a streamed play
    /// twice": the server counted the stream when it started.
    func testAStreamedPlayIsAStoppedReportNotASecondPlay() async throws {
        WatchStub.on("/Sessions/Playing/Stopped", method: "POST", json: "")
        try await client.send(WatchProgressEvent(itemId: "s", positionTicks: 300, played: true, isAudiobook: false, streamed: true))
        XCTAssertEqual(WatchStub.paths, ["/Sessions/Playing/Stopped"])
    }

    /// Regression, 1228f45 "a late event older than the server's
    /// LastPlayedDate is dropped".
    func testABookPositionOlderThanTheServersLastPlayIsDropped() async throws {
        let heard = Date().addingTimeInterval(-3600)
        WatchStub.on("/Items", items: [WX.book("b", position: 100, lastPlayed: WX.serverDate(Date()))])
        try await client.send(WatchProgressEvent(itemId: "b", positionTicks: WX.ticks(50), played: false, isAudiobook: true, at: heard))
        XCTAssertEqual(WatchStub.paths, ["/Items"], "looked up, then nothing sent")
    }

    /// Regression, 1228f45 "Position 0 is sent, a re-listened finished book
    /// is marked unplayed first".
    func testRestartingAFinishedBookMarksItUnplayedFirst() async throws {
        WatchStub.on("/Items", items: [WX.book("b", seconds: 3600, played: true)])
        WatchStub.on("/UserPlayedItems/b", method: "DELETE", json: "")
        WatchStub.on("/Sessions/Playing/Stopped", method: "POST", json: "")
        try await client.send(WatchProgressEvent(itemId: "b", positionTicks: WX.ticks(60), played: false, isAudiobook: true))
        XCTAssertEqual(WatchStub.paths, ["/Items", "/UserPlayedItems/b", "/Sessions/Playing/Stopped"])
        XCTAssertEqual(WatchStub.requests(path: "/UserPlayedItems/b").first?.httpMethod, "DELETE")
    }

    func testAPositionZeroIsSent() async throws {
        WatchStub.on("/Items", items: [WX.book("b", seconds: 3600, position: 500)])
        WatchStub.on("/Sessions/Playing/Stopped", method: "POST", json: "")
        try await client.send(WatchProgressEvent(itemId: "b", positionTicks: 0, played: false, isAudiobook: true))
        let stop = try XCTUnwrap(WatchStub.requests(path: "/Sessions/Playing/Stopped").first)
        XCTAssertEqual(WatchStub.body(stop)["PositionTicks"] as? Int, 0)
    }

    func testAPositionInTheLastFiveMinutesOfAFinishedBookLeavesItFinished() async throws {
        WatchStub.on("/Items", items: [WX.book("b", seconds: 3600, played: true)])
        WatchStub.on("/Sessions/Playing/Stopped", method: "POST", json: "")
        try await client.send(WatchProgressEvent(itemId: "b", positionTicks: WX.ticks(3500), played: false, isAudiobook: true))
        XCTAssertEqual(WatchStub.paths, ["/Items", "/Sessions/Playing/Stopped"])
    }
}

/// The brief's own stub: `StubURLProtocol` from AquariumTests/Shared/Support,
/// matched by path alone.
final class WatchClientStubURLProtocolTests: WatchUnitTestCase {
    override func setUp() async throws {
        try await super.setUp()
        client.testTransport = nil
        client.useTestProtocols([StubURLProtocol.self])
    }

    func testListsDecodeFromCannedAnswers() async throws {
        StubURLProtocol.stub("/Items", json: #"{"Items":[{"Id":"a","Name":"A","Type":"Audio"},{"Id":"b","Name":"B","Type":"AudioBook"}],"TotalRecordCount":2}"#)
        let r = try await client.items(JellyfinClient.Query(types: "Audio,AudioBook"))
        XCTAssertEqual(r.items.map(\.Id), ["a", "b"])
        XCTAssertEqual(r.items.map(\.isAudiobook), [false, true])
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/Items")
    }

    func testUnstubbedIs404AndRecorded() async {
        do { _ = try await client.item("missing"); XCTFail("expected 404") } catch APIError.server(let status, _) {
            XCTAssertEqual(status, 404)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testAPlaylistsSongsDecode() async throws {
        StubURLProtocol.stub("/Playlists/p/Items", json: #"{"Items":[{"Id":"s","Name":"S","Type":"Audio"}]}"#)
        let songs = try await client.playlistItems(playlistId: "p")
        XCTAssertEqual(songs.map(\.Id), ["s"])
        XCTAssertEqual(StubURLProtocol.requests.map(\.httpMethod), ["GET"])
    }

    func testTransportFailureIsOffline() async {
        StubURLProtocol.stub("/System/Info/Public", StubURLProtocol.Response(error: .timedOut))
        let online = await client.checkOnline()
        XCTAssertFalse(online)
        XCTAssertTrue(client.isOffline)
    }
}
