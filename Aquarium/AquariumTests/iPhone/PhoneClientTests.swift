//  JellyfinClient as the phone uses it: the address helpers (pure), and the
//  requests it makes against canned answers (StubURLProtocol). The canned
//  JSON is cut down from what the QA server answers for the same calls.

#if os(iOS)
import XCTest
@testable import Aquarium

// MARK: - Address helpers (no network)

@MainActor
final class PhoneClientURLTests: PhoneUnitTestCase {
    private func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    /// Regression R-0c55b9a: every download shared the device's encode, so
    /// one restarting killed the others (500 on their next segment).
    func testEachDownloadGetsItsOwnPlaySession() {
        let url = URL(string: "http://h/Videos/1/master.m3u8?MediaSourceId=1&api_key=a%2Bb")!
        let one = JellyfinClient.withPlaySession(url)
        let two = JellyfinClient.withPlaySession(url)
        XCTAssertNotNil(JellyfinClient.playSessionId(of: one.absoluteString))
        XCTAssertNotEqual(JellyfinClient.playSessionId(of: one.absoluteString), JellyfinClient.playSessionId(of: two.absoluteString))
        XCTAssertTrue(one.absoluteString.contains("a%2Bb"), "the '+' escaping survives")
        XCTAssertEqual(JellyfinClient.withPlaySession(one), one, "a URL that has a session keeps it")
    }

    /// Regression R-469b782: a stalled stream that fetched nothing retried on
    /// the same play session and stalled again.
    func testStartingOverGetsANewPlaySession() {
        let url = URL(string: "http://h/x.m3u8?PlaySessionId=old&Static=false")!
        let fresh = JellyfinClient.withNewPlaySession(url)
        let id = JellyfinClient.playSessionId(of: fresh.absoluteString)
        XCTAssertNotNil(id)
        XCTAssertNotEqual(id, "old")
        XCTAssertEqual(fresh.absoluteString.components(separatedBy: "PlaySessionId").count, 2, "exactly one PlaySessionId")
        XCTAssertEqual(query(fresh)["Static"], "false")
    }

    /// Regression R-58b158d: the ping reads the session id case-insensitively.
    func testPlaySessionIdIsReadWhateverItsCase() {
        XCTAssertEqual(JellyfinClient.playSessionId(of: "http://h/x?playsessionid=abc"), "abc")
        XCTAssertNil(JellyfinClient.playSessionId(of: "http://h/x?a=b"))
    }

    /// Regression R-e62f2c9 (memory: hls-subtitle-timing): Jellyfin's fMP4
    /// segments start at 0 while its WebVTT maps cues to 10 s, so AVPlayer
    /// showed every line 10 s late. H.264 streams with HLS subtitles use TS.
    func testManifestSubtitlesUseTSSegmentsForH264() {
        let url = URL(string: "http://h/main.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Hls&SegmentContainer=mp4")!
        let fixed = JellyfinClient.subtitleTimedSegments(url, source: PhoneJSON.videoSource(), audioStreamIndex: nil)
        XCTAssertEqual(query(fixed)["SegmentContainer"], "ts")
    }

    /// FX Long Remux Multitrack: an MKV whose H.264 states no bitrate. The
    /// server copies a picture only when its bitrate is known and under the
    /// address's VideoBitrate, so a remux (ContainerNotSupported alone) was
    /// re-encoded at 200 Mbps, which VideoToolbox refused.
    func testRemuxOfVideoWithNoBitrateDropsTheVideoBitrate() {
        let unrated = PhoneJSON.videoSource(container: "mkv")
        let remux = URL(string: "http://h/master.m3u8?VideoCodec=h264,hevc&VideoBitrate=199808000&AudioBitrate=192000&TranscodeReasons=ContainerNotSupported")!
        let fixed = JellyfinClient.copyingVideoOfUnknownBitrate(remux, source: unrated)
        XCTAssertNil(query(fixed)["VideoBitrate"])
        XCTAssertEqual(query(fixed)["AudioBitrate"], "192000")
        XCTAssertEqual(query(fixed)["TranscodeReasons"], "ContainerNotSupported")
        // A picture that needs work keeps its ceiling.
        let encode = URL(string: "http://h/master.m3u8?VideoBitrate=199808000&TranscodeReasons=ContainerNotSupported,VideoBitDepthNotSupported")!
        XCTAssertEqual(JellyfinClient.copyingVideoOfUnknownBitrate(encode, source: unrated), encode)
        let burnIn = URL(string: "http://h/master.m3u8?VideoBitrate=199808000&TranscodeReasons=ContainerNotSupported&SubtitleMethod=Encode&SubtitleStreamIndex=14")!
        XCTAssertEqual(JellyfinClient.copyingVideoOfUnknownBitrate(burnIn, source: unrated), burnIn)
        // A stated bitrate is the server's to compare.
        let rated = PhoneJSON.source(#"{"Id":"s","Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","BitRate":4000000}]}"#)
        XCTAssertEqual(JellyfinClient.copyingVideoOfUnknownBitrate(remux, source: rated), remux)
    }

    func testSubtitleSegmentFixLeavesOtherStreamsAlone() {
        let url = URL(string: "http://h/main.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Hls&SegmentContainer=mp4")!
        XCTAssertEqual(JellyfinClient.subtitleTimedSegments(url, source: PhoneJSON.videoSource(videoCodec: "hevc"), audioStreamIndex: nil), url,
                       "HEVC reaches AVPlayer only in fMP4")
        XCTAssertEqual(JellyfinClient.subtitleTimedSegments(url, source: PhoneJSON.videoSource(audioCodec: "flac"), audioStreamIndex: nil), url,
                       "sound TS can't carry")
        let noSubs = URL(string: "http://h/main.m3u8?SubtitleStreamIndex=-1&SegmentContainer=mp4")!
        XCTAssertEqual(JellyfinClient.subtitleTimedSegments(noSubs, source: PhoneJSON.videoSource(), audioStreamIndex: nil), noSubs)
        let burnt = URL(string: "http://h/main.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode&SegmentContainer=mp4")!
        XCTAssertEqual(JellyfinClient.subtitleTimedSegments(burnt, source: PhoneJSON.videoSource(), audioStreamIndex: nil), burnt)
    }

    /// Regression R-f66fe9c-enc: ids and search terms reach the server intact.
    func testQueryEncodingKeepsPlusSigns() {
        XCTAssertEqual(JellyfinClient.encode([URLQueryItem(name: "searchTerm", value: "C++")]), "searchTerm=C%2B%2B")
        XCTAssertEqual(JellyfinClient.encode([URLQueryItem(name: "a", value: "x&y")]), "a=x%26y")
    }

    func testPathIdEscapesAnythingButAJellyfinId() {
        XCTAssertEqual(JellyfinClient.pathId("b7a2ad74f87ef390949afe560dcbd376"), "b7a2ad74f87ef390949afe560dcbd376")
        XCTAssertFalse(JellyfinClient.pathId("../Users?x=1").contains("/"))
        XCTAssertFalse(JellyfinClient.pathId("a?b").contains("?"))
    }

    func testSafeFileName() {
        XCTAssertEqual(JellyfinClient.safeFileName("A/B:C"), "A_B_C")
        XCTAssertEqual(JellyfinClient.safeFileName("   "), "download")
        XCTAssertLessThanOrEqual(JellyfinClient.safeFileName(String(repeating: "日本", count: 200)).utf8.count, 120)
    }

    func testSubtitlePath() {
        XCTAssertEqual(JellyfinClient.subtitlePath(itemId: "i", mediaSourceId: "m", index: 3, format: "srt"),
                       "/Videos/i/m/Subtitles/3/0/Stream.srt")
    }

    func testH264HDRClaimIsCaught() {
        let hdr = PhoneJSON.source(#"{"Id":"s","MediaStreams":[{"Type":"Video","Codec":"h264","VideoRange":"HDR"}]}"#)
        XCTAssertTrue(JellyfinClient.claimsHDRItCannotCarry(hdr))
        XCTAssertFalse(JellyfinClient.claimsHDRItCannotCarry(PhoneJSON.videoSource(videoCodec: "hevc")))
    }

    /// Regression R-80113a1 (master-fix-list; fixed only on the QA fix
    /// branch): the server saw every build as client version "1.0.0".
    func testClientVersionIsTheBundleVersion() {
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(JellyfinClient.clientVersion, bundle)
    }
}

// MARK: - Requests (canned answers)

@MainActor
final class PhoneClientStubTests: PhoneUnitTestCase {
    override func setUp() async throws {
        try await super.setUp()
        ClientStub.install()
    }

    override func tearDown() async throws {
        ClientStub.remove()
        try await super.tearDown()
    }

    private func queryItems(_ request: URLRequest?) -> [URLQueryItem] {
        guard let url = request?.url else { return [] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func requests(to path: String) -> [URLRequest] {
        StubURLProtocol.requests.filter { $0.url?.path == path }
    }

    /// Regression R-B3 (qa-2026-11-11-player B3): Skip Credits never showed.
    /// The server reads a comma-joined type list as its first entry alone.
    func testSegmentsAskIntroAndOutroSeparately() async throws {
        StubURLProtocol.stub("/MediaSegments/item1", json: """
        {"Items":[{"Type":"Intro","StartTicks":300000000,"EndTicks":600000000},
                  {"Type":"Outro","StartTicks":11000000000,"EndTicks":11700000000},
                  {"Type":"Intro","StartTicks":0,"EndTicks":0}]}
        """)
        let segments = try await JellyfinClient.shared.mediaSegments(itemId: "item1")
        let types = queryItems(requests(to: "/MediaSegments/item1").last).filter { $0.name == "includeSegmentTypes" }.map(\.value)
        XCTAssertEqual(types, ["Intro", "Outro"])
        XCTAssertEqual(segments.count, 2, "a zero-length segment is dropped")
        XCTAssertEqual(segments.first?.start, 30)
        XCTAssertEqual(segments.last?.end, 1170)
    }

    func testSegmentsFailQuietly() async throws {
        StubURLProtocol.stub("/MediaSegments/item1", status: 500)
        let segments = try await JellyfinClient.shared.mediaSegments(itemId: "item1")
        XCTAssertTrue(segments.isEmpty)
    }

    /// Regression R-ca154f3 / B1 (memory: jellyfin-track-index-needs-source-id):
    /// PlaybackInfo ignores AudioStreamIndex unless MediaSourceId is in the body.
    func testChosenTrackIsSentWithItsMediaSource() async throws {
        let path = "/Items/f6f6e804b2ee239f33a1131a01e91ab9/PlaybackInfo"
        StubURLProtocol.stub(path, json: """
        {"MediaSources":[{"Id":"f6f6e804b2ee239f33a1131a01e91ab9","Container":"mkv","SupportsDirectPlay":false,
          "SupportsTranscoding":true,"TranscodingUrl":"/videos/f6f6/master.m3u8?AudioStreamIndex=3&MediaSourceId=f6f6e804b2ee239f33a1131a01e91ab9",
          "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264"},{"Index":3,"Type":"Audio","Codec":"eac3","Language":"fra"}]}],
         "PlaySessionId":"ps1"}
        """)
        _ = try? await JellyfinClient.shared.resolvePlayback(
            itemId: "f6f6e804b2ee239f33a1131a01e91ab9", audioStreamIndex: 3,
            mediaSourceId: "f6f6e804b2ee239f33a1131a01e91ab9", engine: .apple)
        let sent = requests(to: path).last.flatMap(StubURLProtocol.jsonBody(of:))
        XCTAssertEqual(sent?["AudioStreamIndex"] as? Int, 3)
        XCTAssertEqual(sent?["MediaSourceId"] as? String, "f6f6e804b2ee239f33a1131a01e91ab9")
    }

    func testEmptyMediaSourceIdIsNotSent() async throws {
        let path = "/Items/abc/PlaybackInfo"
        StubURLProtocol.stub(path, json: #"{"MediaSources":[]}"#)
        _ = try? await JellyfinClient.shared.resolvePlayback(itemId: "abc", mediaSourceId: "", engine: .apple)
        let sent = requests(to: path).last.flatMap(StubURLProtocol.jsonBody(of:))
        XCTAssertNotNil(sent)
        XCTAssertNil(sent?["MediaSourceId"])
    }

    /// Regression R-120fea0: Next Up ignored the account's own settings.
    func testNextUpSendsTheAccountsSettings() async throws {
        let prefs = JellyfinClient.shared.prefs
        let saved = (prefs.nextUpDays, prefs.nextUpIncludesInProgress, prefs.nextUpRewatching)
        defer { prefs.nextUpDays = saved.0; prefs.nextUpIncludesInProgress = saved.1; prefs.nextUpRewatching = saved.2 }
        prefs.nextUpDays = 30
        prefs.nextUpIncludesInProgress = false
        prefs.nextUpRewatching = true
        StubURLProtocol.stub("/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await JellyfinClient.shared.nextUp()
        let asked = requests(to: "/Shows/NextUp")
        XCTAssertFalse(asked.isEmpty)
        let full = asked.map(queryItems).first { items in items.contains { $0.name == "nextUpDateCutoff" } }
        XCTAssertNotNil(full, "a day limit sends nextUpDateCutoff")
        XCTAssertEqual(full?.first { $0.name == "enableResumable" }?.value, "false")
        XCTAssertEqual(full?.first { $0.name == "enableRewatching" }?.value, "true")
    }

    func testNextUpWithNoDayLimitSendsNoCutoff() async throws {
        let prefs = JellyfinClient.shared.prefs
        let saved = prefs.nextUpDays
        defer { prefs.nextUpDays = saved }
        prefs.nextUpDays = 0
        StubURLProtocol.stub("/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await JellyfinClient.shared.nextUp()
        XCTAssertFalse(requests(to: "/Shows/NextUp").flatMap(queryItems).contains { $0.name == "nextUpDateCutoff" })
    }

    /// Regression R-1ccddf1: a show's Play offered S1E1 while S29E3 was in
    /// progress. The in-progress episode wins over Next Up's answer.
    func testSeriesPlayResumesTheInProgressEpisode() async throws {
        StubURLProtocol.stub("/UserItems/Resume", json: """
        {"Items":[{"Id":"film","Type":"Movie"},{"Id":"ep29","Type":"Episode","SeriesId":"show"}],"TotalRecordCount":2}
        """)
        StubURLProtocol.stub("/Shows/NextUp", json: #"{"Items":[{"Id":"ep1","Type":"Episode","SeriesId":"show"}]}"#)
        let next = try await JellyfinClient.shared.seriesNextUp(seriesId: "show")
        XCTAssertEqual(next?.Id, "ep29")
    }

    func testSeriesPlayFallsBackToNextUpWhenOnlyAFilmIsInProgress() async throws {
        StubURLProtocol.stub("/UserItems/Resume", json: #"{"Items":[{"Id":"film","Type":"Movie"}]}"#)
        StubURLProtocol.stub("/Shows/NextUp", json: #"{"Items":[{"Id":"ep1","Type":"Episode","SeriesId":"show"}]}"#)
        let next = try await JellyfinClient.shared.seriesNextUp(seriesId: "show")
        XCTAssertEqual(next?.Id, "ep1")
    }

    /// Regression R-a9528ef: Remove from Next Up wrote nothing to the server,
    /// so the show came back. Each dated episode gets the "never" date.
    func testRemoveFromNextUpClearsEveryDatedEpisode() async throws {
        StubURLProtocol.stub("/Shows/show/Episodes", json: """
        {"Items":[{"Id":"e1","Type":"Episode","SeriesId":"show","UserData":{"LastPlayedDate":"2026-11-01T10:00:00Z","Played":true}},
                  {"Id":"e2","Type":"Episode","SeriesId":"show","UserData":{"LastPlayedDate":"0001-01-01T00:00:00Z"}},
                  {"Id":"e3","Type":"Episode","SeriesId":"show","UserData":{}}]}
        """)
        StubURLProtocol.stub("/UserItems/e1/UserData", json: "{}")
        try await JellyfinClient.shared.removeFromNextUp(seriesId: "show")
        let posts = StubURLProtocol.requests.filter { $0.httpMethod == "POST" && ($0.url?.path.hasPrefix("/UserItems/") ?? false) }
        XCTAssertEqual(posts.map { $0.url?.path }, ["/UserItems/e1/UserData"])
        XCTAssertEqual(posts.first.flatMap(StubURLProtocol.jsonBody(of:))?["LastPlayedDate"] as? String, HomeRows.notPlayedDate)
    }

    /// Regression R-97171e3 (memory: jellyfin-next-up-rules): Add to Next Up
    /// dated the offered episode, so the show stayed at its old place; and a
    /// date sent alone brings back the server's stale Played state. The last
    /// *watched* episode gets today's date with its whole state.
    func testAddToNextUpDatesTheLastWatchedEpisodeWithItsWholeState() async throws {
        StubURLProtocol.stub("/Shows/show/Episodes", json: """
        {"Items":[
          {"Id":"e1","Type":"Episode","SeriesId":"show","ParentIndexNumber":1,"IndexNumber":1,
           "UserData":{"Played":true,"PlayCount":2,"LastPlayedDate":"2026-01-01T00:00:00Z"}},
          {"Id":"e2","Type":"Episode","SeriesId":"show","ParentIndexNumber":1,"IndexNumber":2,"UserData":{"Played":false}}]}
        """)
        StubURLProtocol.stub("/UserItems/e1/UserData", json: "{}")
        let offered = try await JellyfinClient.shared.addToNextUp(seriesId: "show", from: .lastWatched)
        XCTAssertEqual(offered?.Id, "e2")
        let post = StubURLProtocol.requests.last { $0.url?.path == "/UserItems/e1/UserData" }
        let body = post.flatMap(StubURLProtocol.jsonBody(of:))
        XCTAssertNotNil(body?["LastPlayedDate"])
        XCTAssertEqual(body?["Played"] as? Bool, true)
        XCTAssertEqual(body?["PlayCount"] as? Int, 2)
    }

    /// Regression R-2c520e6-routes: the user routes moved off /Users/{id}/.
    func testResumeAsksTheUserItemsRoute() async throws {
        StubURLProtocol.stub("/UserItems/Resume", json: #"{"Items":[]}"#)
        StubURLProtocol.stub("/Shows/NextUp", json: #"{"Items":[]}"#)
        _ = try? await JellyfinClient.shared.seriesNextUp(seriesId: "show")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasPrefix("/Users/\(ClientStub.userId)/") ?? false })
    }

    /// Search: what the Search tab asks for.
    func testSearchSendsTheTermAndTypes() async throws {
        StubURLProtocol.stub("/Items", json: #"{"Items":[{"Id":"a","Type":"Movie","Name":"FX Long Direct Play"}],"TotalRecordCount":1}"#)
        let result = try await JellyfinClient.shared.search("FX Long")
        XCTAssertEqual(result.items.count, 1)
        // The host app asks /Items for its own rows while a stub account is
        // signed in, so the search is picked out by its term, not by being last.
        let items = queryItems(requests(to: "/Items").last { queryItems($0).contains { $0.name == "searchTerm" } })
        XCTAssertEqual(items.first { $0.name == "searchTerm" }?.value, "FX Long")
        XCTAssertEqual(items.first { $0.name == "Recursive" }?.value, "true")
    }

    /// Regression R-PM34 (master-fix-list Pro Max #34; open on main):
    /// Search could not find collections or people.
    func testSearchIncludesCollectionsAndPeople() async throws {
        StubURLProtocol.stub("/Items", json: #"{"Items":[]}"#)
        _ = try await JellyfinClient.shared.search("FX")
        // The search's own request: other /Items requests (the Follow feed's
        // favourites) can land after it.
        let search = requests(to: "/Items").last { queryItems($0).contains { $0.name == "searchTerm" && $0.value == "FX" } }
        let types = queryItems(search).first { $0.name == "IncludeItemTypes" }?.value ?? ""
        XCTAssertTrue(types.contains("BoxSet") && types.contains("Person"), types)
    }

    /// Regression R-2c520e6-ch: channels past the first 500 were cut off.
    func testChannelsArePagedPastFiveHundred() async throws {
        let page = (0..<500).map { #"{"Id":"c\#($0)","Type":"TvChannel"}"# }.joined(separator: ",")
        StubURLProtocol.stub("/LiveTv/Channels", json: #"{"Items":[\#(page)],"TotalRecordCount":500}"#)
        let channels = try await JellyfinClient.shared.channels()
        XCTAssertEqual(channels.count, 500, "a full last page with the total reached stops")
        XCTAssertEqual(requests(to: "/LiveTv/Channels").count, 1)
    }
}
#endif

#if os(iOS)
// MARK: - Sign-in requests (canned answers)

@MainActor
final class PhoneSignInClientTests: PhoneUnitTestCase {
    override func setUp() async throws {
        try await super.setUp()
        ClientStub.install()
    }

    override func tearDown() async throws {
        ClientStub.remove()
        try await super.tearDown()
    }

    func testProbeReadsTheServersName() async throws {
        StubURLProtocol.stub("/System/Info/Public", json: #"{"Id":"qa","ServerName":"Mac-mini","Version":"12.2.0"}"#)
        let probe = try await JellyfinClient.shared.probe(server: "http://stub.invalid/")
        XCTAssertEqual(probe.serverName, "Mac-mini")
        XCTAssertEqual(probe.server, "http://stub.invalid", "the trailing slash is dropped")
        XCTAssertFalse(probe.secure)
    }

    func testProbeOfANonJellyfinAddressSaysSo() async {
        StubURLProtocol.stub("/System/Info/Public", status: 404)
        do {
            _ = try await JellyfinClient.shared.probe(server: "http://stub.invalid")
            XCTFail("a 404 is not a server")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testEmptyAddressIsRefused() async {
        do { _ = try await JellyfinClient.shared.probe(server: "  "); XCTFail("no address") } catch {
            XCTAssertEqual(error.localizedDescription, "Enter a server address")
        }
    }

    /// The password sign-in the UI form sends (the form's typing can't be
    /// driven: see PhoneSignInTests).
    func testPasswordSignInSendsTheNameAndPassword() async throws {
        StubURLProtocol.stub("/Users/AuthenticateByName", method: "POST", json: """
        {"AccessToken":"t","ServerId":"qa","User":{"Id":"u1","Name":"suite-iphone"}}
        """)
        let session = try await JellyfinClient.shared.login(server: ClientStub.server, username: "suite-iphone", password: "pw")
        XCTAssertEqual(session.userName, "suite-iphone")
        let body = StubURLProtocol.requests.last { $0.url?.path == "/Users/AuthenticateByName" }.flatMap(StubURLProtocol.jsonBody(of:))
        XCTAssertEqual(body?["Username"] as? String, "suite-iphone")
        XCTAssertEqual(body?["Pw"] as? String, "pw")
    }

    /// Wrong password (401) and a disabled account (403): an error, no session.
    func testRefusedSignInsThrow() async {
        for status in [401, 403] {
            StubURLProtocol.stub("/Users/AuthenticateByName", method: "POST", status: status)
            do {
                _ = try await JellyfinClient.shared.login(server: ClientStub.server, username: "x", password: "y")
                XCTFail("\(status) signed in")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty, "\(status)")
            }
        }
    }

    func testAnswerWithoutATokenIsNoSession() async {
        StubURLProtocol.stub("/Users/AuthenticateByName", method: "POST", json: #"{"User":{"Id":"u1"}}"#)
        do { _ = try await JellyfinClient.shared.login(server: ClientStub.server, username: "x", password: "y"); XCTFail("no token") } catch {
            XCTAssertEqual(error.localizedDescription, "The server accepted the request but returned no session")
        }
    }
}
#endif
