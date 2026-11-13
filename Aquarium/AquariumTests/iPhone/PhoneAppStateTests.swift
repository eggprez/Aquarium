//  App-wide state the phone leans on: the navigation stacks, the player's
//  end-of-title arithmetic, what syncs through iCloud and what the phone
//  pins, the M3U reader, and the files a download keeps beside itself.

#if os(iOS)
import XCTest
import SwiftUI
@testable import Aquarium

@MainActor
final class PhoneNavigationTests: PhoneUnitTestCase {
    private var savedPaths: [String: NavigationPath] = [:]
    private var savedSelection: AppSection = .home

    override func setUp() async throws {
        try await super.setUp()
        savedPaths = AppModel.shared.paths
        savedSelection = AppModel.shared.selection
        AppModel.shared.selection = .home
        AppModel.shared.paths[AppSection.home.id] = NavigationPath()
    }

    override func tearDown() async throws {
        AppModel.shared.paths = savedPaths
        AppModel.shared.selection = savedSelection
        try await super.tearDown()
    }

    /// Regression R-1749d3f (memory: duo-inner-status-strip, 2026-10-25): a
    /// second tap on a poster while the first was still zooming in pushed the
    /// page twice, and Back then "did nothing" (it went to the copy beneath).
    func testPushingThePageAlreadyOnTopDoesNothing() {
        let app = AppModel.shared
        let base = app.paths[AppSection.home.id]?.count ?? 0
        app.push(.item("abc"))
        app.push(.item("abc"))
        XCTAssertEqual(app.paths[AppSection.home.id]?.count, base + 1)
        app.push(.item("def"))
        XCTAssertEqual(app.paths[AppSection.home.id]?.count, base + 2)
    }

    /// The bar's Back pops the section's own path (`AppModel.pop`), the fix
    /// for Back lighting up but not popping on the Duo's inside screen.
    func testPopRemovesOnePage() {
        let app = AppModel.shared
        app.push(.item("abc"))
        app.push(.person(id: "p", name: "Ada Fixture"))
        let before = app.paths[AppSection.home.id]?.count ?? 0
        app.pop(.home)
        XCTAssertEqual(app.paths[AppSection.home.id]?.count, before - 1)
        app.pop(.home); app.pop(.home); app.pop(.home)
        XCTAssertEqual(app.paths[AppSection.home.id]?.count, 0, "popping an empty stack is harmless")
    }

    func testSectionIdentifiersMatchTheCatalogue() {
        // TestID.Tab.item / Shell.moreRow are keyed by these ids; the UI
        // tests depend on them.
        XCTAssertEqual(AppSection.home.id, "home")
        XCTAssertEqual(AppSection.search.id, "search")
        XCTAssertEqual(AppSection.downloads.id, "downloads")
        XCTAssertEqual(AppSection.settings.id, "settings")
        XCTAssertEqual(AppSection.more.id, "more")
        XCTAssertEqual(AppSection.liveTV.id, "livetv")
    }
}

@MainActor
final class PhonePlayerArithmeticTests: PhoneUnitTestCase {
    /// Regression R-7132133 (memory: duo-front-qa-driving; qa side-notes Duo
    /// front #1): closing the player with the Up Next card up crashed on
    /// `Int(.infinity)`. With no duration, the time left is infinite and the
    /// card is never due.
    func testNoDurationMeansInfiniteTimeLeftAndNoUpNextCard() {
        let player = PlayerModel.shared
        guard player.item == nil else { return XCTFail("the player is in use") }
        let saved = (player.duration, player.position)
        defer { player.duration = saved.0; player.position = saved.1 }
        player.duration = 0
        player.position = 12
        XCTAssertEqual(player.secondsRemaining, .infinity)
        XCTAssertFalse(player.upNextIsDue())
        player.duration = 100
        player.position = 90
        XCTAssertEqual(player.secondsRemaining, 10)
        player.position = 150
        XCTAssertEqual(player.secondsRemaining, 0, "past the end is no time left, never negative")
    }

    func testUpNextIsNotDueWithNothingNext() {
        let player = PlayerModel.shared
        guard player.item == nil else { return XCTFail("the player is in use") }
        let saved = (player.duration, player.position)
        defer { player.duration = saved.0; player.position = saved.1 }
        player.duration = 100
        player.position = 90
        XCTAssertFalse(player.upNextIsDue(), "no queue, no next episode")
    }
}

@MainActor
final class PhoneSettingsRulesTests: PhoneUnitTestCase {
    /// Regression R-120fea0-sync: the abandoned-episodes and Next Up settings
    /// did not travel with the account.
    func testAccountSettingsTravelThroughICloud() {
        for key in ["home_clear_abandoned", "next_up_days", "next_up_in_progress", "next_up_rewatching",
                    "audio_lang", "sub_lang", "tab_bar_order", CloudSync.sessionKey] {
            XCTAssertTrue(CloudSync.syncedKeys.contains(key), key)
        }
    }

    func testDeviceSettingsStayOnTheDevice() {
        for key in ["device_id", "volume", "last_route", "recent_searches", "audio_delay", "default_bitrate", "download_concurrency"] {
            XCTAssertFalse(CloudSync.syncedKeys.contains(key), key)
        }
    }

    /// Regression R-cd76c6f: settings the phone has no row for (engine,
    /// skip interval, picture…) arrived from a Mac or Apple TV through iCloud
    /// and changed the phone's player with no way to change them back.
    func testPhonePinsWhatItOffersNoRowFor() {
        for key in ["player_engine", "player_skip_interval", "player_hide_after", "picture_zoom", "sub_bg"] {
            XCTAssertTrue(Preferences.keysNotOfferedHere.contains(key), key)
        }
        XCTAssertFalse(Preferences.keysNotOfferedHere.contains("audio_lang"))
        XCTAssertFalse(Preferences.keysNotOfferedHere.contains("autoplay_next"))
    }

    func testPictureValuesAreClamped() {
        XCTAssertEqual(Preferences.pictureValue(250), 100)
        XCTAssertEqual(Preferences.pictureValue(-250), -100)
        XCTAssertEqual(Preferences.pictureValue(.nan), 0)
        XCTAssertEqual(Preferences.zoomValue(5), 2)
        XCTAssertEqual(Preferences.zoomValue(0), 1)
        XCTAssertEqual(Preferences.aspectValue(-1), 0)
        XCTAssertEqual(Preferences.aspectValue(10), 4)
    }

    func testNextUpDayChoicesHaveLabels() {
        for days in Preferences.nextUpDayChoices { XCTAssertFalse(Preferences.nextUpDaysLabel(days).isEmpty) }
        XCTAssertEqual(Preferences.skipIntervals, [10, 15, 30])
    }

    func testSavedSessionKeys() {
        let s = SavedSession(server: "https://jf.example:8920", userId: "u1", userName: "Ada", deviceId: "d", serverId: nil)
        XCTAssertEqual(s.accountKey, "https://jf.example:8920|u1")
        XCTAssertEqual(s.serverLabel, "jf.example:8920")
        XCTAssertTrue(s.secure)
        XCTAssertFalse(SavedSession(server: "http://h", userId: "u", userName: "", deviceId: "", serverId: nil).secure)
    }
}

@MainActor
final class PhoneM3UTests: PhoneUnitTestCase {
    func testPlaylistEntriesKeepTheirAttributes() {
        let entries = M3UParser.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="news.uk" tvg-logo="http://l/news.png" tvg-chno="7",News
        http://s/news.m3u8

        #EXTINF:-1,Unnamed Id
        http://s/two.m3u8
        #EXTVLCOPT:http-user-agent=x
        http://s/orphan.m3u8
        """)
        XCTAssertEqual(entries.count, 2, "a stream line with no #EXTINF before it is not a channel")
        XCTAssertEqual(entries[0].id, "news.uk")
        XCTAssertEqual(entries[0].name, "News")
        XCTAssertEqual(entries[0].channelNumber, "7")
        XCTAssertEqual(entries[0].logoURL, "http://l/news.png")
        XCTAssertEqual(entries[1].id, "auto-2")
        XCTAssertEqual(entries[1].streamURL, "http://s/two.m3u8")
    }

    func testEmptyPlaylistIsNoChannels() {
        XCTAssertTrue(M3UParser.parse("#EXTM3U\n").isEmpty)
        XCTAssertTrue(M3UParser.parse("").isEmpty)
    }
}

@MainActor
final class PhoneDownloadFilesTests: PhoneUnitTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    /// Regression R-ca154f3-dl: a stream download keeps one audio track; the
    /// list of the others is saved so the player can offer to stream them.
    func testStreamDownloadRemembersWhichAudioItCarries() {
        let source = PhoneJSON.source("""
        {"Id":"m","DefaultAudioStreamIndex":1,"MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"h264"},
          {"Index":1,"Type":"Audio","Codec":"aac","Language":"eng","DisplayTitle":"English"},
          {"Index":3,"Type":"Audio","Codec":"eac3","Language":"fra","DisplayTitle":"Francais"}]}
        """)
        DownloadAudioList.save(source: source, sourceURL: "http://h/master.m3u8?AudioStreamIndex=3", isStream: true, into: folder)
        let index = DownloadAudioList.index(in: folder)
        XCTAssertTrue(DownloadAudioList.exists(in: folder))
        XCTAssertEqual(index?.mediaSourceId, "m")
        XCTAssertEqual(index?.main?.index, 3, "the track asked for is the one carried")
        XCTAssertEqual(index?.others.map(\.index), [1])
    }

    func testFileDownloadCarriesEveryTrack() {
        DownloadAudioList.save(source: PhoneJSON.videoSource(), sourceURL: "http://h/Download", isStream: false, into: folder)
        XCTAssertNil(DownloadAudioList.index(in: folder)?.main)
        XCTAssertEqual(DownloadAudioList.index(in: folder)?.others.count, 0)
    }

    func testNothingSavedIsNothingRead() {
        XCTAssertNil(DownloadAudioList.index(in: folder))
        XCTAssertTrue(DownloadSegments.local(in: folder).isEmpty)
        XCTAssertNil(DownloadItemInfo.local(in: folder))
        XCTAssertTrue(DownloadSubtitles.local(in: folder).isEmpty)
    }

    /// Regression R-c2c110c: a cover moved to another server address was
    /// fetched again; the key ignores the host and keeps the tag.
    func testArtworkKeyIgnoresTheHost() {
        XCTAssertEqual(DownloadArtwork.key("http://a:8096/Items/1/Images/Primary?tag=t1&maxWidth=500"),
                       DownloadArtwork.key("https://b.example/Items/1/Images/Primary?tag=t1&maxWidth=500"))
        XCTAssertNotEqual(DownloadArtwork.key("http://a/Items/1/Images/Primary?tag=t1"),
                          DownloadArtwork.key("http://a/Items/1/Images/Primary?tag=t2"))
        XCTAssertNil(DownloadArtwork.key(nil))
    }
}

@MainActor
final class PhoneDownloadSegmentsTests: PhoneUnitTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        ClientStub.install()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ClientStub.remove()
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    /// Regression R-245d039: a download's Skip Intro/Credits markers were
    /// lost when a later refresh got an empty answer.
    func testAnEmptyAnswerNeverReplacesKeptMarkers() async {
        StubURLProtocol.stub("/MediaSegments/ep", json: #"{"Items":[{"Type":"Intro","StartTicks":0,"EndTicks":300000000}]}"#)
        let first = await DownloadSegments.fetch(itemId: "ep", into: folder)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(DownloadSegments.local(in: folder).count, 1)

        StubURLProtocol.stub("/MediaSegments/ep", json: #"{"Items":[]}"#)
        let second = await DownloadSegments.fetch(itemId: "ep", into: folder)
        XCTAssertEqual(second.count, 1, "the kept markers are answered")
        XCTAssertEqual(DownloadSegments.local(in: folder).first?.type, "Intro")
    }
}
#endif
