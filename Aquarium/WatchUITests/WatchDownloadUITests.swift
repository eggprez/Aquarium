//  Downloads to the watch straight from the server: the route a watch takes
//  when its phone has no Aquarium (forced in test mode, see `launch` below). Downloads through
//  the phone need real hardware (transferFile never reaches the app in the
//  simulator: MANUAL.md).

import XCTest

final class WatchDownloadUITests: WatchUITestCase {
    /// The watch simulator says the phone has the app even when it hasn't,
    /// so the watch would wait on the phone for ever: launched as a watch
    /// whose phone has no app (`-AquariumTestNoCompanion YES`, test mode only).
    @discardableResult
    override func launch(reset: Bool = true, signIn: Bool = true, account: QA.Account? = QA.account(),
                         engine: String? = nil, arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        super.launch(reset: reset, signIn: signIn, account: account, engine: engine,
                     arguments: arguments + ["-AquariumTestNoCompanion", "YES"], environment: environment)
    }
    private func openAlbum(_ album: WatchFixtures.Album) {
        open(TestID.Watch.rootDoor("music"))
        open(TestID.Watch.musicDoor("albums"))
        open(TestID.Watch.album(album.id))
        app.element(TestID.Watch.collectionRoot).waitToExist()
    }

    func testASongDownloadsFromItsRowCorner() throws {
        let album = try WatchFixtures.require().album("FX Compilation")
        let song = album.tracks[0]
        launchHome()
        openAlbum(album)
        let corner = app.element(TestID.Watch.itemDownload(song.id))
        XCTAssertTrue(reach(corner))
        XCTAssertEqual(corner.label, "Download to watch")
        corner.tap()
        let done = NSPredicate(format: "label == %@", "On watch")
        let arrived = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: corner)], timeout: 90) == .completed
        XCTAssertTrue(arrived, "still \(corner.label)")
        attachScreenshot("song on watch")

        // On Watch lists it under its album.
        back(); back(); back()
        open(TestID.Watch.rootDoor("onWatch"))
        app.element(TestID.Watch.onWatchRoot).waitToExist()
        let group = app.element(TestID.Watch.onWatchGroup("album", album.id))
        XCTAssertTrue(reach(group))
        XCTAssertTrue(text(TestID.Watch.onWatchGroupNote("album", album.id)).contains("1 song"))
        XCTAssertTrue(reach(app.element(TestID.Watch.storageUsed)))
    }

    func testAnAlbumDownloadsWholeAndIsRemoved() throws {
        let album = try WatchFixtures.require().album("FX Compilation")
        launchHome()
        openAlbum(album)
        open(TestID.Watch.detailDownloadStart)
        let complete = app.element(TestID.Watch.detailDownloadComplete)
        XCTAssertTrue(complete.waitForExistence(timeout: 180), "all four arrive")
        XCTAssertTrue(text(TestID.Watch.detailDownloadComplete).contains("\(album.tracks.count) songs on watch"))
        attachScreenshot("album on watch")
        open(TestID.Watch.detailDownloadRemove)
        app.element(TestID.Watch.detailDownloadStart).waitToExist(20)
        XCTAssertFalse(app.element(TestID.Watch.detailDownloadComplete).exists)
    }

    func testRemoveEverythingEmptiesTheWatch() throws {
        let album = try WatchFixtures.require().album("FX Compilation")
        launchHome()
        openAlbum(album)
        let corner = app.element(TestID.Watch.itemDownload(album.tracks[1].id))
        XCTAssertTrue(reach(corner))
        corner.tap()
        let arrived = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "On watch"), object: corner)], timeout: 90)
        XCTAssertEqual(arrived, .completed)
        back(); back(); back()
        open(TestID.Watch.rootDoor("onWatch"))
        open(TestID.Watch.onWatchRemoveEverything)
        // The dialog's button doesn't carry its identifier on watchOS (a
        // confirmationDialog gap, like TESTING.md's known ones): by label.
        let byId = app.button(TestID.Watch.onWatchConfirmRemoveEverything)
        let byLabel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Remove ", "items")).firstMatch
        let confirm = byId.waitForExistence(timeout: 5) ? byId : byLabel
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "the confirmation")
        confirm.tap()
        app.element(TestID.Watch.statusEmpty).waitToExist(20)
        XCTAssertFalse(app.element(TestID.Watch.onWatchGroup("album", album.id)).exists)
    }

    func testABookDownloadsAndPlaysFromTheWatch() throws {
        let book = try WatchFixtures.require().book("FX Chaptered Audiobook")
        launchHome()
        open(TestID.Watch.rootDoor("books"))
        open(TestID.Watch.book(book.id))
        app.element(TestID.Watch.bookRoot).waitToExist()
        open(TestID.Watch.detailDownloadStart)
        let complete = app.element(TestID.Watch.detailDownloadComplete)
        XCTAssertTrue(complete.waitForExistence(timeout: 180), "the book arrives (an .m4b, sent as it is)")
        XCTAssertEqual(text(TestID.Watch.detailDownloadComplete), "On watch")
        // Its own copy plays: "On watch" isn't shown for a book, so check the
        // home page's On Watch row and that it opens where it was left.
        back(); back()
        open(TestID.Watch.rootDoor("onWatch"))
        XCTAssertTrue(reach(app.element(TestID.Watch.onWatchGroup("book", book.id))))
        attachScreenshot("book on watch")
    }

    func testTheQueueOrOnWatchShowsWhatIsArriving() throws {
        let album = try WatchFixtures.require().album("FX Long Tracks")
        launchHome()
        openAlbum(album)
        open(TestID.Watch.detailDownloadStart)
        // Whichever comes first: the bar on the page while it arrives, or done.
        let progress = app.element(TestID.Watch.detailDownloadProgress)
        let complete = app.element(TestID.Watch.detailDownloadComplete)
        let end = Date().addingTimeInterval(120)
        var sawProgress = false
        while Date() < end, !complete.exists {
            if progress.exists { sawProgress = true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(complete.exists, "both long tracks arrive")
        if !sawProgress { XCTContext.runActivity(named: "too quick to see the bar") { _ in } }
    }
}
