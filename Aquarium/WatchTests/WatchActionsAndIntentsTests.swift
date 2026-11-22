//  What is asked of the app from outside a screen (Watch/WatchApp.swift
//  WatchActions, Watch/WatchIntents.swift): the widget's links, Resume
//  Audiobook, Play an Audiobook, Play Music, Shuffle Music, the entities
//  Siri resolves, and the songs of a thing with and without a server.
//
//  `play` opens audio for real; each test resets the player straight after
//  looking at what it was asked to play.

import AppIntents
import XCTest
@testable import AquariumWatch

final class WatchActionsTests: WatchUnitTestCase {
    private func complete(_ items: [BaseItem], reason: String = "song") {
        downloads.enqueue(items, reason: reason)
        for item in items { downloads.testUpdate(item.Id) { $0.status = .complete } }
    }

    // MARK: Links (the widget's taps)

    func testTheWidgetsPlayLinkPlaysThatItem() async {
        complete([WX.song("s")])
        WatchActions.handle(URL(string: "aquarium://play/s")!)
        let playing = await eventually { self.player.current?.Id == "s" }
        XCTAssertTrue(playing)
        XCTAssertEqual(player.queueTitle, "Song s")
    }

    func testTheWidgetsResumeLinkResumesTheBook() async {
        complete([WX.book("b", position: 100)], reason: "book")
        downloads.testUpdate("b") { $0.positionTicks = WX.ticks(100); $0.lastPlayedAt = Date() }
        WatchStub.fail("/System/Info/Public")
        _ = await client.checkOnline()
        WatchActions.handle(URL(string: "aquarium://resume")!)
        let playing = await eventually { self.player.current?.Id == "b" }
        XCTAssertTrue(playing)
    }

    func testOtherLinksAreIgnored() async {
        WatchActions.handle(URL(string: "https://example.com/play/x")!)
        WatchActions.handle(URL(string: "aquarium://play/")!)
        WatchActions.handle(URL(string: "aquarium://elsewhere/x")!)
        await settle()
        XCTAssertFalse(player.isActive)
        XCTAssertTrue(WatchStub.requests.isEmpty)
    }

    // MARK: Resume Audiobook

    func testResumeCarriesOnAPausedBook() async {
        player.testLoad([WX.book("b")], position: 30, playing: false)
        let ok = await WatchActions.resumeBook()
        XCTAssertTrue(ok)
        XCTAssertEqual(player.current?.Id, "b")
    }

    func testResumeTakesTheServersBookInProgress() async {
        WatchStub.on("/UserItems/Resume", items: [WX.song("s", position: 5), WX.book("srv", position: 400)])
        let ok = await WatchActions.resumeBook()
        XCTAssertTrue(ok)
        XCTAssertEqual(player.current?.Id, "srv")
    }

    func testResumeOfflineTakesTheWatchsBook() async {
        complete([WX.book("local", position: 50)], reason: "book")
        downloads.testUpdate("local") { $0.positionTicks = WX.ticks(50); $0.lastPlayedAt = Date() }
        WatchStub.fail("/System/Info/Public")
        _ = await client.checkOnline()
        let ok = await WatchActions.resumeBook()
        XCTAssertTrue(ok)
        XCTAssertEqual(player.current?.Id, "local")
    }

    /// master-fix-list "From Apple Watch": "'Resume Audiobook' on the idle
    /// player does nothing and says nothing when no book is in progress". The
    /// action reports false; saying so on the idle screen is the fix branch's
    /// (352c592), checked in MANUAL.md.
    func testResumeWithNoBookSaysThereIsNone() async {
        WatchStub.on("/UserItems/Resume", items: [])
        let ok = await WatchActions.resumeBook()
        XCTAssertFalse(ok)
        XCTAssertFalse(player.isActive)
    }

    // MARK: Play by id

    func testPlayingAnAlbumOrPlaylistById() async {
        WatchStub.on("/Items/al", body: WX.itemJSON(WX.album("al")))
        WatchStub.on("/Items", query: ["ParentId": "al"], items: [WX.song("t2", track: 2), WX.song("t1", track: 1)])
        await WatchActions.play(itemId: "al")
        XCTAssertEqual(player.queue.map(\.item.Id), ["t1", "t2"])
        player.testReset()
        WatchStub.on("/Items/p", body: WX.itemJSON(WX.playlist("p")))
        WatchStub.on("/Playlists/p/Items", items: [WX.song("x"), WX.song("y")])
        await WatchActions.play(itemId: "p")
        XCTAssertEqual(player.queue.map(\.item.Id), ["x", "y"])
    }

    func testPlayingAnUnknownIdDoesNothing() async {
        await WatchActions.play(itemId: "nope")
        XCTAssertFalse(player.isActive)
    }

    // MARK: The songs of a thing

    func testSongsOfAThingFromTheServerOrTheWatch() async {
        complete([WX.song("l1", albumId: "al", artist: "FX Band")])
        downloads.keep(playlist: WX.playlist("p"), songs: [WX.song("l1", albumId: "al")])
        WatchStub.on("/Items", query: ["ParentId": "al"], items: [WX.song("r1", albumId: "al"), WX.song("r2", albumId: "al")])
        var songs = await WatchActions.songs(of: WX.album("al"))
        XCTAssertEqual(songs.map(\.Id), ["r1", "r2"], "online: the server's")
        songs = await WatchActions.songs(of: WX.song("one"))
        XCTAssertEqual(songs.map(\.Id), ["one"])

        WatchStub.fail("/System/Info/Public")
        _ = await client.checkOnline()
        songs = await WatchActions.songs(of: WX.album("al"))
        XCTAssertEqual(songs.map(\.Id), ["l1"], "offline: the watch's")
        songs = await WatchActions.songs(of: WX.playlist("p"))
        XCTAssertEqual(songs.map(\.Id), ["l1"])
        songs = await WatchActions.songs(of: WX.artist("ar", name: "FX Band"))
        XCTAssertEqual(songs.map(\.Id), ["l1"])
        songs = await WatchActions.songs(of: WX.genre("g"))
        XCTAssertEqual(songs, [])
        songs = await WatchActions.songs(of: WX.collection("x", type: "Folder"))
        XCTAssertEqual(songs, [])
    }
}

final class WatchIntentsTests: WatchUnitTestCase {
    private func complete(_ items: [BaseItem], reason: String) {
        downloads.enqueue(items, reason: reason)
        for item in items { downloads.testUpdate(item.Id) { $0.status = .complete } }
    }

    func testTheShortcutsAreDeclared() {
        XCTAssertEqual(AquariumWatchShortcuts.appShortcuts.count, 4)
        XCTAssertTrue(ResumeAudiobookIntent.openAppWhenRun)
        XCTAssertTrue(PlayAudiobookIntent.openAppWhenRun)
        XCTAssertTrue(PlayMusicIntent.openAppWhenRun)
        XCTAssertTrue(ShuffleMusicIntent.openAppWhenRun)
    }

    func testABookEntityNamesTheBookAndItsAuthor() {
        let e = WatchBookEntity(WX.book("b", name: "Frankenstein", author: "Mary Shelley"))
        XCTAssertEqual(e.id, "b")
        XCTAssertEqual(e.title, "Frankenstein")
        XCTAssertEqual(e.author, "Mary Shelley")
    }

    func testACollectionEntitySaysWhatItIs() {
        XCTAssertEqual(WatchCollectionEntity(WX.playlist("p")).detail, "Playlist")
        XCTAssertEqual(WatchCollectionEntity(WX.album("a")).detail, "FX Band")
        XCTAssertEqual(WatchCollectionEntity(WX.collection("a", type: "MusicAlbum")).detail, "Album")
    }

    func testBooksAreFoundOnTheWatchThenTheServer() async throws {
        complete([WX.book("local", name: "Frankenstein", author: "Mary Shelley")], reason: "book")
        WatchStub.on("/Items", query: ["Ids": "remote"], items: [WX.book("remote", name: "Dracula")])
        let byId = try await WatchBookQuery().entities(for: ["local", "remote"])
        XCTAssertEqual(byId.map(\.id), ["local", "remote"])

        WatchStub.on("/Items", query: ["IncludeItemTypes": "AudioBook"], items: [WX.book("local"), WX.book("srv", name: "Shelley's Other")])
        let matched = try await WatchBookQuery().entities(matching: "shelley")
        XCTAssertEqual(matched.map(\.id), ["local", "srv"], "the watch's first, then the server's, each once")
    }

    func testSuggestedBooksAreTheOnesInProgress() async throws {
        complete([WX.book("a"), WX.book("b")], reason: "book")
        downloads.testUpdate("a") { $0.positionTicks = WX.ticks(60); $0.lastPlayedAt = Date() }
        let suggested = try await WatchBookQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["a"])
    }

    func testAlbumsAndPlaylistsAreFoundOnTheWatchThenTheServer() async throws {
        complete([WX.song("s", albumId: "al", album: "Road Album")], reason: "album:al")
        downloads.keep(playlist: WX.playlist("p", name: "Road Trip"), songs: [])
        WatchStub.on("/Items", query: ["Ids": "srv"], items: [WX.album("srv")])
        let byId = try await WatchCollectionQuery().entities(for: ["p", "al", "srv"])
        XCTAssertEqual(byId.map(\.id), ["p", "al", "srv"])
        WatchStub.on("/Items", query: ["IncludeItemTypes": "Audio"], items: [])
        let matched = try await WatchCollectionQuery().entities(matching: "road")
        XCTAssertEqual(Set(matched.map(\.id)), ["p", "al"])
        let suggested = try await WatchCollectionQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["p", "al"])
    }

    func testResumeAudiobookIntentWithNothingToResume() async throws {
        WatchStub.on("/UserItems/Resume", items: [])
        _ = try await ResumeAudiobookIntent().perform()
        XCTAssertFalse(player.isActive)
    }

    func testPlayAudiobookIntentPlaysTheBook() async throws {
        complete([WX.book("b")], reason: "book")
        var intent = PlayAudiobookIntent()
        intent.book = WatchBookEntity(WX.book("b"))
        _ = try await intent.perform()
        XCTAssertEqual(player.current?.Id, "b")
    }

    func testPlayMusicIntentPlaysTheCollection() async throws {
        WatchStub.on("/Items/al", body: WX.itemJSON(WX.album("al")))
        WatchStub.on("/Items", query: ["ParentId": "al"], items: [WX.song("t1")])
        var intent = PlayMusicIntent()
        intent.collection = WatchCollectionEntity(WX.album("al"))
        _ = try await intent.perform()
        XCTAssertEqual(player.current?.Id, "t1")
    }

    func testShuffleMusicIntentUsesTheServerThenTheWatch() async throws {
        WatchStub.on("/Items", query: ["SortBy": "Random"], items: (0..<5).map { WX.song("r\($0)") })
        _ = try await ShuffleMusicIntent().perform()
        XCTAssertEqual(player.queue.count, 5)
        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(player.queueTitle, "Shuffle")
        player.testReset()

        complete([WX.song("l1"), WX.song("l2")], reason: "song")
        WatchStub.fail("/System/Info/Public")
        _ = await client.checkOnline()
        _ = try await ShuffleMusicIntent().perform()
        XCTAssertEqual(Set(player.queue.map(\.item.Id)), ["l1", "l2"])
    }

    func testShuffleMusicIntentWithNoMusic() async throws {
        WatchStub.on("/Items", items: [])
        _ = try await ShuffleMusicIntent().perform()
        XCTAssertFalse(player.isActive)
    }
}

// MARK: - The Smart Stack's snapshot

final class WatchWidgetSnapshotTests: WatchUnitTestCase {
    func testHowFarIn() {
        var s = ListeningSnapshot(itemId: "x", title: "t", subtitle: "s", isAudiobook: true, isPlaying: false, position: 450, duration: 900)
        XCTAssertEqual(s.fraction, 0.5)
        s.position = 0
        XCTAssertNil(s.fraction, "not started: no bar")
        s.position = 10
        s.duration = 0
        XCTAssertNil(s.fraction)
        s.duration = 5
        XCTAssertEqual(s.fraction, 1)
    }

    func testTheSnapshotRoundTrips() throws {
        let s = ListeningSnapshot(itemId: "x", title: "t", subtitle: "s", isAudiobook: false, isPlaying: true, position: 1, duration: 2)
        XCTAssertEqual(try JSONDecoder().decode(ListeningSnapshot.self, from: JSONEncoder().encode(s)), s)
        XCTAssertEqual(ListeningSnapshot.appGroup, "group.scottai.FellyJin")
    }

    private func requireAppGroup() throws {
        try XCTSkipIf(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ListeningSnapshot.appGroup) == nil,
                      "no app group container in this (ad-hoc signed) build")
    }

    func testWrittenAndReadThroughTheAppGroup() throws {
        try requireAppGroup()
        let s = ListeningSnapshot(itemId: "x", title: "t", subtitle: "s", isAudiobook: true, isPlaying: false, position: 1, duration: 2)
        ListeningSnapshot.write(s)
        XCTAssertEqual(ListeningSnapshot.read()?.itemId, "x")
        ListeningSnapshot.write(nil)
        XCTAssertNil(ListeningSnapshot.read())
    }

    func testThePlayerWritesWhatIsPlaying() async throws {
        try requireAppGroup()
        player.testLoad([WX.book("b", name: "Book", seconds: 900, chapters: [0, 100])], position: 150, playing: true)
        player.writeSnapshot()
        let written = await eventually(3) { ListeningSnapshot.read()?.itemId == "b" }
        XCTAssertTrue(written)
        let s = ListeningSnapshot.read()
        XCTAssertEqual(s?.subtitle, "Chapter 2", "a book's card names its chapter")
        XCTAssertEqual(s?.isPlaying, true)
        XCTAssertEqual(s?.duration, 900)
    }

    func testIdleTheCardShowsTheBookMostRecentlyLeft() async throws {
        try requireAppGroup()
        downloads.enqueue([WX.book("left", name: "Left Book", seconds: 900)], reason: "book")
        downloads.testUpdate("left") { $0.status = .complete; $0.positionTicks = WX.ticks(300); $0.lastPlayedAt = Date() }
        player.writeSnapshot()
        let written = await eventually(3) { ListeningSnapshot.read()?.itemId == "left" }
        XCTAssertTrue(written)
        XCTAssertEqual(ListeningSnapshot.read()?.isPlaying, false)
        XCTAssertEqual(ListeningSnapshot.read()?.position, 300)
        downloads.testReset()
        player.writeSnapshot()
        let cleared = await eventually(3) { ListeningSnapshot.read() == nil }
        XCTAssertTrue(cleared)
    }
}
