//  The smaller parts of the watch app: its own log file, pictures, the
//  model shims, the navigation stack, the On Watch page's grouping and the
//  download queue's order, and test mode itself.

import SwiftUI
import UIKit
import XCTest
@testable import AquariumWatch

final class WatchLogTests: XCTestCase {
    func testNotesGoToTheFileAndTheExportCarriesThem() async throws {
        let marker = "unit-test-marker-\(UUID().uuidString)"
        WatchLog.note("test", marker)
        WatchLog.error("test", marker + "-error")
        let text = try String(contentsOf: WatchLog.current, encoding: .utf8)
        XCTAssertTrue(text.contains("N [test] \(marker)"))
        XCTAssertTrue(text.contains("E [test] \(marker)-error"))
        let export = await WatchLog.export()
        let exported = try XCTUnwrap(export)
        let whole = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(whole.hasPrefix("Aquarium watch log, exported"))
        XCTAssertTrue(whole.contains(marker))
        XCTAssertTrue(exported.lastPathComponent.hasPrefix("AquariumWatch-"))
        XCTAssertTrue(WatchLog.folder.path.contains("AquariumUITest"), "test mode's own folder")
    }

    func testTheFileIsRotatedAtHalfAMegabyte() {
        let line = String(repeating: "x", count: 4096)
        for _ in 0..<140 { WatchLog.note("test", line) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: WatchLog.folder.appendingPathComponent("watch.1.log").path))
        let attributes = try? FileManager.default.attributesOfItem(atPath: WatchLog.current.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThan(size, 600 * 1024)
    }

    /// The crash marker: "A launch whose predecessor never said goodbye is
    /// noted as such: that is what a crash looks like from here."
    func testALaunchAfterNoGoodbyeIsNotedAsACrash() throws {
        WatchLog.foregrounded()
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "watch_log_clean_exit"), false)
        WatchLog.launched()
        let text = try String(contentsOf: WatchLog.current, encoding: .utf8)
        XCTAssertTrue(text.contains("the previous run did not go to the background"))
        WatchLog.backgrounded()
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "watch_log_clean_exit"), true)
    }

    func testMemoryAndDiskLines() {
        XCTAssertTrue(WatchLog.memory.hasPrefix("mem="))
        XCTAssertTrue(WatchLog.disk.hasPrefix("disk free="))
    }
}

final class WatchImagesTests: WatchUnitTestCase {
    func testTheCoverBesideADownloadIsUsedFirst() throws {
        let item = WX.song("s", albumId: "al", imageTag: "t")
        XCTAssertEqual(WatchImages.url(for: item)?.host, "stub.invalid", "nothing on the watch: the server's")
        let albumArt = WatchDownloads.artFile("al")
        try FileManager.default.createDirectory(at: albumArt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(WatchLinkTests.png()).write(to: albumArt)
        XCTAssertEqual(WatchImages.url(for: item), albumArt, "a song borrows its album's")
        let own = WatchDownloads.artFile("s")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(WatchLinkTests.png()).write(to: own)
        XCTAssertEqual(WatchImages.url(for: item), own)
        var logo = item
        logo.ExternalLogoURL = own.absoluteString
        XCTAssertEqual(WatchImages.url(for: logo), own)
    }

    func testAFileCoverLoadsAndIsCached() async throws {
        let art = WatchDownloads.artFile("pic")
        try FileManager.default.createDirectory(at: art.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(WatchLinkTests.png()).write(to: art)
        let image = await WatchImages.shared.load(art)
        XCTAssertNotNil(image)
        XCTAssertNotNil(WatchImages.shared.cached(art))
        WatchImages.forget("pic")
        let gone = await eventually { WatchImages.shared.cached(art) == nil }
        XCTAssertTrue(gone)
    }

    func testARecordWithACoverOnDiskSaysSo() throws {
        downloads.enqueue([WX.song("s")], reason: "song")
        try FileManager.default.createDirectory(at: WatchDownloads.folder("s"), withIntermediateDirectories: true)
        try XCTUnwrap(WatchLinkTests.png()).write(to: WatchDownloads.artFile("s"))
        XCTAssertEqual(downloads.record(for: "s")?.asItem.ExternalLogoURL, WatchDownloads.artFile("s").absoluteString)
    }
}

final class WatchShimsTests: XCTestCase {
    func testTracksInSleeveOrder() {
        let items = [WX.song("c", name: "C", track: nil), WX.song("b", track: 2, disc: 1), WX.song("a", track: 1, disc: 2), WX.song("z", track: 1)]
        XCTAssertEqual(items.sortedByTrack().map(\.Id), ["z", "b", "c", "a"])
    }

    func testAlbumsOfSongsOnceEachInOrder() {
        let songs = [WX.song("1", albumId: "x", album: "X"), WX.song("2", albumId: "y", album: "Y"), WX.song("3", albumId: "x"), WX.song("4", albumId: nil)]
        let albums = songs.albumsInOrder()
        XCTAssertEqual(albums.map(\.Id), ["x", "y"])
        XCTAssertEqual(albums.first?.title, "X")
        XCTAssertTrue(albums.allSatisfy(\.isAlbum))
    }

    func testArtistsOfSongsOnceEach() {
        let songs = [WX.song("1", artist: "B Band"), WX.song("2", artist: "a band"), WX.song("3", artist: "b band")]
        let artists = songs.localArtists()
        XCTAssertEqual(artists.map(\.title), ["a band", "B Band"])
        XCTAssertEqual(artists.first?.Id, "artist:a band")
        XCTAssertTrue(artists.allSatisfy(\.isArtist))
    }

    func testLanguagesAreNamedByTheirTag() {
        XCTAssertEqual(Languages.name(for: "eng"), "ENG")
    }

    func testAKeptPlaylistAsAnItem() {
        let item = WatchPlaylist(id: "p", name: "Road", itemIds: ["a"], automatic: false, imageTag: "t").asItem
        XCTAssertEqual(item.Id, "p")
        XCTAssertTrue(item.isPlaylist)
        XCTAssertEqual(item.title, "Road")
    }

    func testTheThemeColours() {
        XCTAssertNotNil(WatchTheme.accent)
        XCTAssertNotNil(Color(hex: 0x8B5CF6))
    }
}

final class WatchNavigatorTests: XCTestCase {
    func testThePlayerIsPushedOnceAndForgottenOnlyWhenPopped() {
        let nav = WatchNavigator()
        nav.path.append(WatchRoute.books)
        nav.showPlayer()
        nav.showPlayer()
        XCTAssertEqual(nav.path.count, 2)
        XCTAssertTrue(nav.playerShown)
        nav.playerLeft()
        XCTAssertTrue(nav.playerShown, "covered, not popped")
        nav.path.removeLast()
        nav.playerLeft()
        XCTAssertFalse(nav.playerShown)
        nav.showPlayer()
        nav.popToRoot()
        XCTAssertTrue(nav.path.isEmpty)
        XCTAssertFalse(nav.playerShown)
    }

    func testRoutesCompareByWhatTheyShow() {
        XCTAssertEqual(WatchRoute.book(WX.book("b")), WatchRoute.book(WX.book("b")))
        XCTAssertNotEqual(WatchRoute.book(WX.book("b")), WatchRoute.collection(WX.book("b")))
        XCTAssertNotEqual(WatchRoute.albums, WatchRoute.songs)
    }
}

/// The On Watch page's rows and the queue's order (Views/OnWatchViews.swift).
final class WatchOnWatchGroupsTests: WatchUnitTestCase {
    func testGroupsAreWhatWasAskedForEachSongOnce() {
        downloads.enqueue([WX.book("b", name: "Book")], reason: "book")
        downloads.keep(playlist: WX.playlist("p", name: "List"), songs: [WX.song("s1", albumId: "al")])
        downloads.enqueue([WX.song("s2", albumId: "al", album: "Album", track: 2), WX.song("s3", albumId: "al", track: 1)], reason: "album:al")
        downloads.enqueue([WX.song("loose", albumId: nil)], reason: "song")
        let groups = downloads.groups()
        XCTAssertEqual(groups.map(\.kind), [.album, .book, .playlist, .songs])
        XCTAssertEqual(groups.first?.itemIds, ["s3", "s2"], "in track order, without the playlist's song")
        XCTAssertEqual(groups.last?.subtitle, "1 song")
        XCTAssertEqual(downloads.playlistName(for: downloads.record(for: "s1")!), "List")
        XCTAssertNil(downloads.playlistName(for: downloads.record(for: "s2")!))
    }

    func testRemoveCancelAndRetryByGroup() {
        downloads.keep(WatchDownloadRequest(kind: .album, id: "al", title: "A"), items: [WX.song("s1", albumId: "al"), WX.song("s2", albumId: "al")])
        downloads.testUpdate("s1") { $0.status = .error }
        let album = downloads.groups().first { $0.kind == .album }!
        downloads.retry(album)
        XCTAssertEqual(status("s1"), .queued)
        downloads.cancel(album)
        XCTAssertTrue(downloads.records.isEmpty)
        XCTAssertNil(downloads.testWantContents["album:al"], "cancelled by hand: its want goes too")
        XCTAssertTrue(sent.contains("wantRemoved:album:al"))
    }

    func testCancellingAPlaylistAskedForByHandWithNothingHereTakesItAway() {
        downloads.keep(playlist: WX.playlist("p"), songs: [WX.song("a")])
        downloads.cancel(downloads.groups().first { $0.kind == .playlist }!)
        XCTAssertTrue(downloads.playlists.isEmpty)
    }

    func testCancelAllStopsEverythingArriving() {
        downloads.enqueue([WX.book("b")], reason: "book")
        downloads.enqueue([WX.song("s")], reason: "song")
        downloads.testUpdate("s") { $0.status = .complete }
        downloads.cancelAll()
        XCTAssertNil(downloads.record(for: "b"))
        XCTAssertNotNil(downloads.record(for: "s"), "what arrived stays")
    }

    func testRemoveByGroup() {
        downloads.enqueue([WX.book("b")], reason: "book")
        downloads.remove(downloads.groups().first { $0.kind == .book }!)
        XCTAssertTrue(downloads.records.isEmpty)
    }

    func testTheQueueShowsWhatMovesThenWhatWaitsInTheOrderItWillStart() {
        link.testSetPhone(reachable: true, companion: true)
        downloads.enqueue([WX.song("slow"), WX.song("fast")], reason: "song")
        downloads.testUpdate("slow") { $0.estimatedBytes = 100 }
        downloads.testUpdate("fast") { $0.estimatedBytes = 100 }
        downloads.notePhoneProgress(itemId: "slow", fraction: 0.2)
        downloads.notePhoneProgress(itemId: "fast", fraction: 0.8)
        link.testSetPhone(reachable: false, companion: false)
        downloads.enqueue([WX.song("mirror")], reason: "playlist:p", automatic: true)
        downloads.enqueue([WX.song("tap")], reason: "song")
        let q = downloads.queue()
        XCTAssertEqual(q.moving.map(\.itemId), ["fast", "slow"])
        XCTAssertEqual(q.waiting.map(\.itemId), ["tap", "mirror"])
    }
}

final class WatchTestModeTests: XCTestCase {
    func testTheUnitHostRunsInTestMode() {
        XCTAssertTrue(TestRuntime.isUITest)
        XCTAssertTrue(AppDirectory.url(.applicationSupportDirectory).path.hasSuffix(TestLaunch.folder))
        XCTAssertTrue(WatchDownloads.root.path.contains(TestLaunch.folder))
        WatchTestMode.prepare()   // a second call changes nothing
        XCTAssertTrue(TestRuntime.isUITest)
    }

    func testTokensStayOutOfTheKeychainInTestMode() {
        WatchKeychain.store(token: "t", account: "test|x")
        XCTAssertEqual(TestKeychain.token(account: "test|x"), "t")
        WatchKeychain.delete(account: "test|x")
        XCTAssertNil(WatchKeychain.token(account: "test|x"))
    }
}
