//  The custom Live TV source: `IPTVSource` (fetching a playlist and a guide,
//  and turning them into channels and programmes) and `LiveTVStore` (what is
//  held, when it is fetched again, and the guide's window query). The parsers
//  themselves are tested in TVGuideTests and XMLTVEpisodeNumberTests.
//
//  The playlist and guide are served from this machine's loopback address.

import XCTest
@testable import Aquarium

private enum Feed {
    static let playlist = """
    #EXTM3U
    #EXTINF:-1 tvg-id="cnn.US" tvg-logo="" tvg-chno="" group-title="News, World",CNN
    /stream/cnn?mode=hls
    #EXTINF:-1 tvg-id="x-bbc" tvg-logo="logos/bbc.png" tvg-chno="101",BBC One
    http://streams.invalid/bbc/one.m3u8
    #EXTINF:-1 tvg-id="local",On This Device
    file:///private/var/secret.ts
    #EXTINF:-1 tvg-id="dup",Dup A
    http://streams.invalid/a.m3u8
    #EXTINF:-1 tvg-id="dup" tvg-logo="file:///etc/logo.png",Dup B
    http://streams.invalid/b.m3u8
    #EXTINF:-1,No Id
    relative/noid.ts
    """

    static let guide = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="CNN.us"><display-name>CNN International</display-name><icon src="/icons/cnn.png"/></channel>
      <channel id="bbc1"><display-name>BBC One</display-name><icon src="http://img.invalid/guide-bbc.png"/></channel>
      <channel id="unused"><display-name>Nobody Carries This</display-name></channel>
      <programme start="20270101190000 +0000" stop="20270101200000 +0000" channel="CNN.us"><title>Late News</title></programme>
      <programme start="20270101180000 +0000" stop="20270101190000 +0000" channel="CNN.us">
        <title>News</title><sub-title>Evening</sub-title><desc>The day.</desc>
        <episode-num system="onscreen">S2 E3</episode-num>
      </programme>
      <programme start="20270101180000 +0000" stop="20270101183000 +0000" channel="CNN.us"><title>Simulcast</title></programme>
      <programme start="20270101180000 +0000" stop="20270101190000 +0000" channel="bbc1"><title>Drama</title></programme>
      <programme start="20270101180000 +0000" stop="20270101190000 +0000" channel="DUP A"><title>By Name</title></programme>
      <programme start="20270101180000 +0000" stop="20270101190000 +0000" channel="unused"><title>Unwatchable</title></programme>
    </tv>
    """

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    static let sixPM = date("2027-01-01T18:00:00Z")

    /// A server with the playlist at `/lists/tv.m3u` and the guide at `/guide/epg.xml`.
    static func serve(on server: LoopbackServer) {
        server.setHandler { request in
            switch request.path {
            case "/lists/tv.m3u": .text(playlist, type: "audio/x-mpegurl")
            case "/guide/epg.xml": .text(guide, type: "application/xml")
            default: .status(404)
            }
        }
    }
}

// MARK: - IPTVSource

final class IPTVSourceTests: XCTestCase {
    private var server: LoopbackServer!

    override func setUpWithError() throws {
        server = try LoopbackServer()
        Feed.serve(on: server)
    }

    override func tearDown() { server.stop() }

    private func loaded(guide: Bool = true) async throws -> IPTVSource.Loaded {
        try await IPTVSource.load(playlistURLString: "  \(server.base)/lists/tv.m3u ",
                                  guideURLString: guide ? " \(server.base)/guide/epg.xml" : "")
    }

    func testWhatCountsAsAWebAddress() {
        XCTAssertTrue(IPTVSource.isWebURL(URL(string: "http://h/a")!))
        XCTAssertTrue(IPTVSource.isWebURL(URL(string: "HTTPS://h/a")!))
        XCTAssertFalse(IPTVSource.isWebURL(URL(string: "file:///a")!))
        XCTAssertFalse(IPTVSource.isWebURL(URL(string: "ftp://h/a")!))
        XCTAssertFalse(IPTVSource.isWebURL(URL(string: "relative/path")!))
    }

    // MARK: Fetching

    func testFetchReturnsTheBody() async throws {
        let data = try await IPTVSource.fetch(server.url("/lists/tv.m3u"), limit: IPTVSource.playlistLimit)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), Feed.playlist)
    }

    func testFetchRefusesAnAnswerThatSaysItIsTooLarge() async {
        server.setHandler { _ in .data(Data(repeating: 0x41, count: 4_000), type: "text/plain") }
        do {
            _ = try await IPTVSource.fetch(server.url("/big"), limit: 3_999)
            XCTFail("a body over the limit was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The file is too large")
        }
    }

    func testFetchGivesUpOnABodyThatGrowsPastTheLimitUnannounced() async {
        server.setHandler { _ in
            var response = LoopbackServer.Response.data(Data(repeating: 0x41, count: 200_000), type: "text/plain")
            response.sendsLength = false
            return response
        }
        do {
            _ = try await IPTVSource.fetch(server.url("/endless"), limit: 50_000)
            XCTFail("a body over the limit was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The file is too large")
        }
    }

    func testFetchAcceptsABodyExactlyAtTheLimit() async throws {
        server.setHandler { _ in .data(Data(repeating: 0x41, count: 4_000), type: "text/plain") }
        let data = try await IPTVSource.fetch(server.url("/just"), limit: 4_000)
        XCTAssertEqual(data.count, 4_000)
    }

    func testFetchReportsTheStatusOfARefusal() async {
        server.setHandler { _ in .text("gone", status: 410) }
        do {
            _ = try await IPTVSource.fetch(server.url("/gone"), limit: 1_000)
            XCTFail("a 410 was read as a playlist")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server answered 410")
        }
    }

    // MARK: Loading

    func testNoPlaylistAndBadAddressesAreSaidPlainly() async {
        func failure(_ playlist: String) async -> String? {
            do {
                _ = try await IPTVSource.load(playlistURLString: playlist, guideURLString: "")
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let none = await failure("   ")
        XCTAssertEqual(none, "Add an M3U playlist URL in Settings to use a custom Live TV source.")
        for bad in ["file:///etc/passwd", "ftp://host/list.m3u", "just words"] {
            let message = await failure(bad)
            XCTAssertEqual(message, "That M3U address doesn't look like a valid URL.", bad)
        }
        let missing = await failure("\(server.base)/nowhere.m3u")
        XCTAssertEqual(missing, "Couldn't load the playlist: The server answered 404")
        XCTAssertEqual(server.requests.map(\.path), ["/nowhere.m3u"], "nothing but a web address is ever asked for")
    }

    func testChannelsAreBuiltFromThePlaylistAndNamedByTheGuide() async throws {
        let result = try await loaded()
        let channels = result.channels
        XCTAssertEqual(channels.map(\.Id), ["iptv-0-cnn.US", "iptv-1-x-bbc", "iptv-3-dup", "iptv-4-dup", "iptv-5-auto-6"],
                       "the place in the playlist is part of the id, so a repeated tvg-id is still two rows; a file: stream is dropped")
        XCTAssertEqual(channels.map(\.Name), ["CNN International", "BBC One", "Dup A", "Dup B", "No Id"],
                       "the guide's name where the ids match, whatever their case")
        XCTAssertTrue(channels.allSatisfy { $0.type == "TvChannel" })
        XCTAssertEqual(channels.map(\.ChannelNumber), ["1", "101", "4", "5", "6"], "an empty tvg-chno is the place in the list")
    }

    func testStreamsAndLogosAreMadeAbsolute() async throws {
        let channels = try await loaded().channels
        XCTAssertEqual(channels.map(\.ExternalStreamURL), [
            "\(server.base)/stream/cnn?mode=hls",
            "http://streams.invalid/bbc/one.m3u8",
            "http://streams.invalid/a.m3u8",
            "http://streams.invalid/b.m3u8",
            "\(server.base)/lists/relative/noid.ts",
        ])
        XCTAssertEqual(channels.map(\.ExternalLogoURL), [
            "\(server.base)/icons/cnn.png",          // tvg-logo="" gives way to the guide's icon, relative to the guide
            "\(server.base)/lists/logos/bbc.png",    // the playlist's own logo wins, relative to the playlist
            nil,
            nil,                                      // a logo on this device is not a logo
            nil,
        ])
    }

    func testProgrammesAreFiledUnderTheirChannelInAirtimeOrder() async throws {
        let result = try await loaded()
        let start = Int(Feed.sixPM.timeIntervalSince1970)
        XCTAssertEqual(result.programmes.count, 5, "the programme on a channel the playlist does not carry is left out")
        let cnn = result.byChannel["iptv-0-cnn.US"] ?? []
        XCTAssertEqual(Set(cnn.prefix(2).compactMap(\.Name)), ["News", "Simulcast"])
        XCTAssertEqual(cnn.last?.Name, "Late News", "in airtime order, whatever order the feed lists them in")
        XCTAssertEqual(Set(cnn.map(\.Id)),
                       ["iptv-iptv-0-cnn.US-\(start)", "iptv-iptv-0-cnn.US-\(start)-2", "iptv-iptv-0-cnn.US-\(start + 3600)"],
                       "stable across reloads, and two at the same minute are both kept")
        XCTAssertEqual(result.byChannel["iptv-1-x-bbc"]?.map(\.Name), ["Drama"], "matched on the displayed name when the ids differ")
        XCTAssertEqual(result.byChannel["iptv-3-dup"]?.map(\.Name), ["By Name"], "a guide that files by channel name still lines up")
        XCTAssertNil(result.byChannel["iptv-4-dup"])

        let news = try XCTUnwrap(result.programmes.first { $0.Name == "News" })
        XCTAssertEqual(news.ChannelId, "iptv-0-cnn.US")
        XCTAssertEqual(news.EpisodeTitle, "Evening")
        XCTAssertEqual(news.Overview, "The day.")
        XCTAssertEqual(news.ParentIndexNumber, 2)
        XCTAssertEqual(news.IndexNumber, 3)
        XCTAssertEqual(news.programStart, Feed.sixPM)
        XCTAssertEqual(news.programEnd, Feed.sixPM.addingTimeInterval(3600))
        XCTAssertEqual(news.StartDate, "2027-01-01T18:00:00Z")
        XCTAssertEqual(news.EndDate, "2027-01-01T19:00:00Z")
    }

    func testLoadingTwiceGivesTheSameIds() async throws {
        let first = try await loaded()
        let second = try await loaded()
        XCTAssertEqual(first.channels.map(\.Id), second.channels.map(\.Id))
        XCTAssertEqual(first.programmes.map(\.Id).sorted(), second.programmes.map(\.Id).sorted())
    }

    func testChannelsStillTuneWithNoGuide() async throws {
        let result = try await loaded(guide: false)
        XCTAssertEqual(result.channels.map(\.Name), ["CNN", "BBC One", "Dup A", "Dup B", "No Id"])
        XCTAssertNil(result.channels[0].ExternalLogoURL)
        XCTAssertTrue(result.programmes.isEmpty)
        XCTAssertTrue(result.byChannel.isEmpty)
        XCTAssertEqual(server.requests.map(\.path), ["/lists/tv.m3u"])
    }

    func testAGuideThatCannotBeFetchedIsDoneWithout() async throws {
        let missing = try await IPTVSource.load(playlistURLString: "\(server.base)/lists/tv.m3u",
                                                guideURLString: "\(server.base)/guide/missing.xml")
        XCTAssertEqual(missing.channels.count, 5)
        XCTAssertTrue(missing.programmes.isEmpty)

        let notWeb = try await IPTVSource.load(playlistURLString: "\(server.base)/lists/tv.m3u",
                                               guideURLString: "file:///tmp/epg.xml")
        XCTAssertEqual(notWeb.channels.count, 5)
        XCTAssertEqual(server.requests(to: "/guide/epg.xml").count, 0)
    }
}

// MARK: - LiveTVStore

@MainActor
final class LiveTVStoreTests: XCTestCase {
    private var server: LoopbackServer!
    private var store: LiveTVStore { .shared }
    private var prefs: Preferences { .shared }
    private var saved: (source: LiveTVSource, playlist: String, guide: String, token: Int)!

    override func setUp() async throws {
        saved = (prefs.liveTVSource, prefs.iptvPlaylistURL, prefs.iptvGuideURL, prefs.liveTVRefreshToken)
        CoreAccount.signIn()
        await CoreAccount.goOnline()
        server = try LoopbackServer()
        Feed.serve(on: server)
        clearStore()
    }

    override func tearDown() async throws {
        clearStore()
        prefs.liveTVSource = saved.source
        prefs.iptvPlaylistURL = saved.playlist
        prefs.iptvGuideURL = saved.guide
        prefs.liveTVRefreshToken = saved.token
        server.stop()
        await CoreAccount.signOut()
    }

    /// `reset` leaves a custom playlist alone, so it is called as Jellyfin.
    private func clearStore() {
        prefs.liveTVSource = .jellyfin
        store.reset()
    }

    private func useCustom(playlist: String = "/lists/tv.m3u", guide: String? = "/guide/epg.xml") {
        prefs.liveTVSource = .custom
        prefs.iptvPlaylistURL = server.base + playlist
        prefs.iptvGuideURL = guide.map { server.base + $0 } ?? ""
    }

    private func stubJellyfinChannels(_ names: [String]) {
        let channels = names.enumerated().map { index, name in
            CoreItem.make("ch\(index)", "TvChannel", name: name) { $0.ChannelNumber = String(index + 1) }
        }
        StubURLProtocol.stub("/LiveTv/Channels", StubURLProtocol.Response(body: CoreItem.json(channels)))
    }

    private var channelRequests: Int { StubURLProtocol.requests.filter { $0.url?.path == "/LiveTv/Channels" }.count }

    // MARK: The key

    func testTheKeyFollowsEverythingThatDecidesALoad() async {
        prefs.liveTVSource = .jellyfin
        prefs.iptvPlaylistURL = "http://a/list.m3u"
        prefs.iptvGuideURL = ""
        let jellyfin = LiveTVStore.key
        XCTAssertTrue(jellyfin.hasSuffix("\(ClientStub.server)|\(JellyfinClient.shared.session!.userId)"),
                      "Jellyfin's channels belong to a server and a user")

        prefs.liveTVSource = .custom
        let custom = LiveTVStore.key
        XCTAssertNotEqual(custom, jellyfin)
        XCTAssertTrue(custom.hasSuffix("|"), "a custom playlist belongs to no account")

        prefs.iptvGuideURL = "http://a/epg.xml"
        let withGuide = LiveTVStore.key
        XCTAssertNotEqual(withGuide, custom)
        prefs.iptvPlaylistURL = "http://b/list.m3u"
        let otherList = LiveTVStore.key
        XCTAssertNotEqual(otherList, withGuide)
        prefs.liveTVRefreshToken += 1
        XCTAssertNotEqual(LiveTVStore.key, otherList, "Refresh in Settings is a new key")

        // Signing in elsewhere changes Jellyfin's key and not the custom one.
        let customBefore = LiveTVStore.key
        await CoreAccount.signOut()
        CoreAccount.signIn()
        XCTAssertEqual(LiveTVStore.key, customBefore)
        prefs.liveTVSource = .jellyfin
        XCTAssertFalse(LiveTVStore.key.hasSuffix(jellyfin.components(separatedBy: "|").last!))
    }

    // MARK: A custom playlist

    func testACustomPlaylistIsLoadedOnceAndSummarised() async {
        useCustom()
        XCTAssertFalse(store.isLoading)
        await store.ensureLoaded()
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.channels.count, 5)
        XCTAssertEqual(store.programmes.count, 5)
        let summary = store.summary
        XCTAssertEqual(summary?.channels, 5)
        XCTAssertEqual(summary?.withLogos, 2)
        XCTAssertEqual(summary?.programmes, 5)
        XCTAssertEqual(server.requests(to: "/lists/tv.m3u").count, 1)

        await store.ensureLoaded()
        XCTAssertEqual(server.requests(to: "/lists/tv.m3u").count, 1, "already in hand: nothing is fetched")
        XCTAssertEqual(store.summary, summary)
    }

    func testTwoCallersAtOnceShareOneFetch() async {
        useCustom()
        async let warmUp: Void = store.ensureLoaded()
        async let tabTapped: Void = store.ensureLoaded()
        _ = await (warmUp, tabTapped)
        XCTAssertEqual(server.requests(to: "/lists/tv.m3u").count, 1, "the warm-up at launch and the tab tapped a moment later")
        XCTAssertEqual(store.channels.count, 5)
        XCTAssertFalse(store.isLoading)
    }

    func testRefreshFetchesAgainAndClosingAChannelDoesNot() async {
        useCustom()
        await store.ensureLoaded()
        await store.refreshAfterPlayback()
        XCTAssertEqual(server.requests(to: "/lists/tv.m3u").count, 1, "a guide of tens of megabytes is not re-downloaded for a channel closing")
        await store.refresh()
        XCTAssertEqual(server.requests(to: "/lists/tv.m3u").count, 2)
        XCTAssertEqual(server.requests(to: "/guide/epg.xml").count, 2)
    }

    func testAChangedAddressIsANewLoad() async {
        useCustom()
        await store.ensureLoaded()
        useCustom(guide: nil)
        await store.ensureLoaded()
        XCTAssertEqual(server.requests(to: "/lists/tv.m3u").count, 2)
        XCTAssertTrue(store.programmes.isEmpty)
        XCTAssertEqual(store.summary?.programmes, 0)
        XCTAssertEqual(store.channels.first?.Name, "CNN", "no guide to rename it")
    }

    func testAFailedLoadSaysWhyAndIsTriedAgain() async {
        useCustom(playlist: "/lists/missing.m3u")
        await store.ensureLoaded()
        XCTAssertEqual(store.error, "Couldn't load the playlist: The server answered 404")
        XCTAssertTrue(store.channels.isEmpty)
        XCTAssertNil(store.summary)
        XCTAssertFalse(store.isLoading)

        await store.ensureLoaded()
        XCTAssertEqual(server.requests(to: "/lists/missing.m3u").count, 2, "an error in hand is not an answer in hand")

        useCustom()
        await store.ensureLoaded()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.channels.count, 5)
    }

    func testAFailureAfterASuccessEmptiesTheLineUp() async {
        useCustom()
        await store.ensureLoaded()
        server.setHandler { _ in .status(503) }
        await store.refresh()
        XCTAssertEqual(store.error, "Couldn't load the playlist: The server answered 503")
        XCTAssertTrue(store.channels.isEmpty)
        XCTAssertTrue(store.programmes.isEmpty)
    }

    func testSignOutKeepsACustomPlaylist() async {
        useCustom()
        await store.ensureLoaded()
        store.reset()
        XCTAssertEqual(store.channels.count, 5, "it belongs to this device's settings, not to the account")
        XCTAssertNotNil(store.summary)
    }

    func testWarmStartsTheCustomLoadInTheBackground() async {
        useCustom()
        store.warm()
        let loaded = await CoreWait.until { self.store.channels.count == 5 }
        XCTAssertTrue(loaded)
    }

    func testTheGuideIsAnsweredForAWindowAndASetOfChannels() async throws {
        useCustom()
        await store.ensureLoaded()
        let provider = try XCTUnwrap(store.programsProvider)
        let cnn = "iptv-0-cnn.US", bbc = "iptv-1-x-bbc"
        let six = Feed.sixPM

        var found = try await provider([cnn, bbc, cnn], six, six.addingTimeInterval(1800))
        XCTAssertEqual(Set(found.compactMap(\.Name)), ["News", "Simulcast", "Drama"], "what is on in the window, each once")
        XCTAssertEqual(found.count, 3)

        found = try await provider([cnn], six.addingTimeInterval(1800), six.addingTimeInterval(3600))
        XCTAssertEqual(found.compactMap(\.Name), ["News"], "one that ends as the window opens is not in it")

        found = try await provider([cnn], six.addingTimeInterval(3600), six.addingTimeInterval(7200))
        XCTAssertEqual(found.compactMap(\.Name), ["Late News"], "nor one that starts as it closes")

        found = try await provider([cnn], six.addingTimeInterval(-7200), six)
        XCTAssertTrue(found.isEmpty)
        found = try await provider(["no-such-channel"], six, six.addingTimeInterval(3600))
        XCTAssertTrue(found.isEmpty)
        found = try await provider([], six, six.addingTimeInterval(3600))
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: Jellyfin's own channels

    func testJellyfinChannelsAreAskedOfTheServerAndTrustedForAWhile() async {
        prefs.liveTVSource = .jellyfin
        stubJellyfinChannels(["One", "Two"])
        await store.ensureLoaded()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.channels.map(\.Name), ["One", "Two"])
        XCTAssertTrue(store.programmes.isEmpty)
        XCTAssertNil(store.summary)
        XCTAssertNil(store.programsProvider, "Jellyfin's guide is asked of the server")
        XCTAssertEqual(channelRequests, 1)

        await store.ensureLoaded()
        XCTAssertEqual(channelRequests, 1, "\"on now\" is trusted for ten minutes")

        stubJellyfinChannels(["One", "Two", "Three"])
        await store.refreshAfterPlayback()
        XCTAssertEqual(channelRequests, 2, "what is on has moved after watching something")
        XCTAssertEqual(store.channels.count, 3)
    }

    func testWarmDoesNothingForJellyfin() async {
        prefs.liveTVSource = .jellyfin
        stubJellyfinChannels(["One"])
        store.warm()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(channelRequests, 0)
        XCTAssertTrue(store.channels.isEmpty)
    }

    func testAJellyfinFailureKeepsTheLineUpAndIsTriedAgain() async {
        prefs.liveTVSource = .jellyfin
        stubJellyfinChannels(["One", "Two"])
        await store.ensureLoaded()
        StubURLProtocol.stub("/LiveTv/Channels", status: 500)
        await store.refresh()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.channels.count, 2, "the last line-up stays on screen")
        await store.ensureLoaded()
        XCTAssertEqual(channelRequests, 3, "with an error in hand the next appearance asks again")
    }

    func testSignOutForgetsJellyfinsChannels() async {
        prefs.liveTVSource = .jellyfin
        stubJellyfinChannels(["One"])
        await store.ensureLoaded()
        store.reset()
        XCTAssertTrue(store.channels.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isLoading)
        await store.ensureLoaded()
        XCTAssertEqual(channelRequests, 2, "the next load starts from nothing")
    }

    func testSwitchingSourceLoadsTheOther() async {
        prefs.liveTVSource = .jellyfin
        stubJellyfinChannels(["One"])
        await store.ensureLoaded()
        useCustom()
        await store.ensureLoaded()
        XCTAssertEqual(store.channels.count, 5)
        XCTAssertNotNil(store.programsProvider)
    }
}
