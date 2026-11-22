//  The wants list and its reconcile step (memory: watch-wants-list.md;
//  commit 49da046). Every "Download to Apple Watch" on the phone is a want,
//  sent with every plan; the watch keeps what each comes to and checks it
//  against its records on every pass, queueing what is missing, retrying
//  what failed once an hour, leaving what was cancelled by hand, and telling
//  the phone how far each has got.

import XCTest
@testable import AquariumWatch

final class WatchWantsTests: WatchUnitTestCase {
    private let album = WatchDownloadRequest(kind: .album, id: "al", title: "FX Two Discs")
    private var songs: [BaseItem] { [WX.song("s1", albumId: "al"), WX.song("s2", albumId: "al")] }

    private func pass() async {
        downloads.mirror()
        await downloads.mirrorSettled(within: .seconds(5))
    }

    // MARK: Keeping a want

    func testAWantIsWrittenDownWithWhatItComesTo() {
        downloads.keep(album, items: songs + [WX.album("not-audio")])
        XCTAssertEqual(downloads.testWantContents["album:al"]?.items.map(\.Id), ["s1", "s2"])
        XCTAssertEqual(downloads.record(for: "s1")?.reasons, ["album:al"])
        XCTAssertEqual(status("s2"), .queued)
        XCTAssertNil(downloads.testWantContents["album:al"]?.items.first?.MediaSources, "kept slim for the watch")
    }

    func testAPlaylistDownloadIsAKeptPlaylistNotAWant() {
        downloads.keep(WatchDownloadRequest(kind: .playlist, id: "p", title: "Road"), items: [WX.song("a")])
        XCTAssertNil(downloads.testWantContents["playlist:p"])
        XCTAssertEqual(downloads.playlists.map(\.id), ["p"])
        XCTAssertEqual(downloads.playlists.first?.name, "Road")
        XCTAssertEqual(downloads.playlists.first?.automatic, false)
    }

    func testTheWantsListSurvivesOnDisk() async throws {
        downloads.keep(album, items: songs)
        let file = WatchDownloads.root.appendingPathComponent("wants.json")
        let written = await eventually { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(written)
        let saved = try JSONDecoder().decode([String: WatchDownloadContents].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved["album:al"]?.items.count, 2)
    }

    // MARK: Reconcile

    func testAPassQueuesWhatIsMissing() async {
        downloads.keep(album, items: songs)
        downloads.delete("s2")
        XCTAssertNil(downloads.record(for: "s2"))
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertEqual(downloads.record(for: "s2")?.reasons, ["album:al"], "put back by the check")
    }

    func testAnItemHereForSomethingElseIsClaimedForTheWantToo() async {
        downloads.enqueue([WX.song("s1", albumId: "al")], reason: "playlist:p")
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        downloads.keep(album, items: songs)
        await pass()
        XCTAssertEqual(downloads.record(for: "s1")?.reasons, ["playlist:p", "album:al"])
    }

    func testAFailedItemIsRetriedOnceAnHourNotOnEveryPass() async {
        downloads.keep(album, items: songs)
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        downloads.testUpdate("s1") { $0.status = .error; $0.errorMessage = "x" }
        downloads.testSetWantRetried("s1", at: Date().addingTimeInterval(-30 * 60))
        await pass()
        XCTAssertEqual(status("s1"), .error, "retried half an hour ago")
        downloads.testSetWantRetried("s1", at: Date().addingTimeInterval(-2 * 60 * 60))
        await pass()
        XCTAssertEqual(status("s1"), .queued)
    }

    func testAnItemTurnedAwayForRoomIsLeftToThePump() async {
        downloads.keep(album, items: songs)
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        downloads.testUpdate("s1") { $0.status = .error; $0.lackedSpace = true }
        downloads.testSetWantRetried("s1", at: nil)
        WatchDownloads.testFreeBytes = 0
        await pass()
        XCTAssertEqual(status("s1"), .error)
    }

    /// Regression, WatchDownloads.declined: "A want is checked on every pass,
    /// and without this the song cancelled from the queue was straight back
    /// in it."
    func testAnItemCancelledByHandStaysCancelled() async {
        downloads.keep(album, items: songs)
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        downloads.cancel("s1")
        XCTAssertTrue(downloads.testDeclined.contains("s1"))
        await pass()
        XCTAssertNil(downloads.record(for: "s1"))
        XCTAssertNotNil(downloads.record(for: "s2"))
    }

    func testAskedForAgainFromThePhoneUndoesTheCancel() {
        downloads.keep(album, items: songs)
        downloads.cancel("s1")
        downloads.keep(album, items: songs)
        XCTAssertFalse(downloads.testDeclined.contains("s1"))
        XCTAssertEqual(status("s1"), .queued)
    }

    func testCancellingASongWantedOnItsOwnLetsItsWantGo() {
        let song = WatchDownloadRequest(kind: .song, id: "x", title: "X")
        downloads.keep(song, items: [WX.song("x")])
        downloads.cancel("x")
        XCTAssertNil(downloads.testWantContents["song:x"])
        XCTAssertTrue(sent.contains("wantRemoved:song:x"), "\(sent)")
        XCTAssertFalse(downloads.testDeclined.contains("x"), "nothing left to decline it for")
    }

    // MARK: Contents the phone never sent

    func testAWantWithNoContentsIsLookedUpOnTheServer() async {
        WatchStub.on("/Items", query: ["ParentId": "al"], items: songs)
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertEqual(downloads.testWantContents["album:al"]?.items.count, 2)
        XCTAssertEqual(status("s1"), .queued)
        XCTAssertEqual(downloads.wantStates().first?.needsContents, false)
    }

    func testEachKindIsLookedUpTheRightWay() async {
        WatchStub.on("/Items/b", body: WX.itemJSON(WX.book("b")))
        WatchStub.on("/Items", query: ["ArtistIds": "ar"], items: [WX.song("a1")])
        WatchStub.on("/Items", query: ["GenreIds": "g"], items: [WX.song("g1")])
        let wants = [
            WatchDownloadRequest(kind: .book, id: "b", title: "B"),
            WatchDownloadRequest(kind: .artist, id: "ar", title: "Ar"),
            WatchDownloadRequest(kind: .genre, id: "g", title: "G"),
        ]
        downloads.apply(plan: WatchMirrorPlan(wants: wants))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertEqual(downloads.record(for: "b")?.reasons, ["book"])
        XCTAssertEqual(downloads.record(for: "a1")?.reasons, ["artist:ar"])
        XCTAssertEqual(downloads.record(for: "g1")?.reasons, ["genre:g"])
    }

    func testAWantThatCantBeLookedUpAsksThePhoneToSendItAgain() async {
        WatchStub.on("/Items", status: 500)
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        let state = downloads.wantStates().first
        XCTAssertEqual(state?.key, "album:al")
        XCTAssertEqual(state?.needsContents, true)
        XCTAssertTrue(downloads.records.isEmpty)
    }

    func testOfflineTheServerIsNotAsked() async {
        WatchStub.fail("/System/Info/Public")
        _ = await client.checkOnline()
        WatchStub.reset()
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertTrue(WatchStub.requests.isEmpty, "\(WatchStub.paths)")
        XCTAssertEqual(downloads.wantStates().first?.needsContents, true)
    }

    // MARK: Telling the phone

    func testWantStatesReportHowFarEachHasGot() async {
        downloads.keep(album, items: songs)
        downloads.apply(plan: WatchMirrorPlan(wants: [album, WatchDownloadRequest(kind: .playlist, id: "p", title: "P")]))
        await downloads.mirrorSettled(within: .seconds(5))
        downloads.testUpdate("s1") { $0.status = .complete }
        downloads.testUpdate("s2") { $0.status = .error }
        let states = downloads.wantStates()
        XCTAssertEqual(states, [WatchWantState(key: "album:al", count: 2, complete: 1, failed: 1, needsContents: false)],
                       "playlists are not wants")
    }

    // MARK: Letting go

    func testAWantTakenOffOnThePhoneLetsGoWithoutAWordBack() {
        downloads.keep(album, items: songs)
        link.handle(.deleteWant(album))
        XCTAssertNil(downloads.testWantContents["album:al"])
        XCTAssertNil(downloads.record(for: "s1"))
        XCTAssertFalse(sent.contains { $0.hasPrefix("wantRemoved") }, "\(sent)")
    }

    func testAWantsItemsKeptForSomethingElseStay() {
        downloads.enqueue([WX.song("s1", albumId: "al")], reason: "playlist:p")
        downloads.keep(album, items: songs)
        downloads.deleteWant(album)
        XCTAssertEqual(downloads.record(for: "s1")?.reasons, ["playlist:p"])
        XCTAssertNil(downloads.record(for: "s2"))
    }

    /// Memory watch-wants-list: "an album deleted out of an artist want drops
    /// the artist want but keeps its other albums as plain albums."
    func testRemovingAnAlbumOfAnArtistLetsTheArtistWantGoButKeepsItsOtherAlbums() async throws {
        let artist = WatchDownloadRequest(kind: .artist, id: "ar", title: "FX Band")
        downloads.keep(artist, items: [WX.song("a1", albumId: "al1"), WX.song("a2", albumId: "al2")])
        downloads.testUpdate("a2") { $0.status = .complete }
        downloads.deleteAlbum("al1")
        XCTAssertNil(downloads.record(for: "a1"))
        XCTAssertEqual(downloads.record(for: "a2")?.reasons, ["album:al2"])
        XCTAssertNil(downloads.testWantContents["artist:ar"])
        XCTAssertTrue(sent.contains("wantRemoved:artist:ar"), "\(sent)")
    }

    func testAGroupCancelledByHandForgetsItsWantButKeepsWhatArrived() {
        downloads.keep(album, items: songs)
        downloads.testUpdate("s1") { $0.status = .complete }
        downloads.forgetWants(for: .album, id: "al", among: ["s1", "s2"])
        XCTAssertNil(downloads.testWantContents["album:al"])
        XCTAssertEqual(downloads.record(for: "s1")?.reasons, ["album:al"])
        XCTAssertTrue(sent.contains("wantRemoved:album:al"))
    }

    func testAWantTakenOffHereIsntPutBackByAPlanThatStillNamesIt() async {
        WatchStub.on("/Items", query: ["ParentId": "al"], items: songs)
        downloads.keep(album, items: songs)
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        downloads.deleteAlbum("al")
        XCTAssertTrue(sent.contains("wantRemoved:album:al"))
        await pass()
        XCTAssertTrue(downloads.records.isEmpty, "the phone hasn't caught up yet")
        // Past the grace, the phone's word counts again.
        downloads.testSetDroppedWant("album:al", at: Date().addingTimeInterval(-11 * 60))
        await pass()
        XCTAssertNotNil(downloads.record(for: "s1"))
    }

    func testAPlanThatNoLongerNamesADroppedWantEndsTheGrace() async {
        WatchStub.on("/Items", query: ["ParentId": "al"], items: songs)
        downloads.keep(album, items: songs)
        downloads.deleteAlbum("al")
        downloads.apply(plan: WatchMirrorPlan())
        downloads.apply(plan: WatchMirrorPlan(wants: [album]))
        await downloads.mirrorSettled(within: .seconds(5))
        XCTAssertNotNil(downloads.record(for: "s1"), "asked for again")
    }

    // MARK: A download asked for from the phone, done here

    func testADownloadMessageLooksItUpAndKeepsIt() async {
        WatchStub.on("/Items", query: ["ParentId": "al"], items: songs)
        link.handle(.download(album))
        let kept = await eventually { self.downloads.record(for: "s2") != nil }
        XCTAssertTrue(kept)
        XCTAssertNotNil(downloads.testWantContents["album:al"])
    }

    func testADownloadThatCantBeLookedUpIsLeft() async {
        WatchStub.on("/Items", status: 500)
        await downloads.download(album)
        XCTAssertTrue(downloads.records.isEmpty)
    }
}
