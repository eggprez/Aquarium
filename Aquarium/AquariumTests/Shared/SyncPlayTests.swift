//  Jellyfin SyncPlay and the player's group seam, as far as they can be
//  checked without a server: what the web socket says, read into values
//  (`SyncPlayWire`); the server's clock from round trips (`SyncPlayClock`);
//  and what the player does with an order from a group (`GroupOrder`), which
//  SharePlay on the Apple TV goes through too. The messages are the ones the
//  QA server sent on 2026-11-18. The group itself, against a real server, is
//  `PhoneSyncPlayTests` and `TVSyncPlayTests`.

import XCTest
@testable import Aquarium

final class SyncPlayWireTests: XCTestCase {
    func testAJellyfinTimestampKeepsItsFraction() throws {
        let date = try XCTUnwrap(SyncPlayWire.date("2026-11-19T01:29:38.2876145Z"))
        let whole = try XCTUnwrap(SyncPlayWire.date("2026-11-19T01:29:38Z"))
        XCTAssertEqual(date.timeIntervalSince(whole), 0.2876145, accuracy: 0.000_01)
        // No zone is UTC; an offset is honoured.
        XCTAssertEqual(SyncPlayWire.date("2026-11-19T01:29:38.5"), whole.addingTimeInterval(0.5))
        XCTAssertEqual(SyncPlayWire.date("2026-11-19T02:29:38+01:00"), whole)
        XCTAssertNil(SyncPlayWire.date(nil))
        XCTAssertNil(SyncPlayWire.date("yesterday"))
    }

    func testATimestampGoesBackOutToTheMillisecond() throws {
        let date = try XCTUnwrap(SyncPlayWire.date("2026-11-19T01:29:38.250Z"))
        XCTAssertEqual(SyncPlayWire.string(date), "2026-11-19T01:29:38.250Z")
    }

    func testKeepAliveSaysHowOften() {
        let text = #"{"MessageId":"2ff1","Data":60,"MessageType":"ForceKeepAlive"}"#
        XCTAssertEqual(SyncPlayWire.event(from: text), .keepAlive(60))
    }

    func testJoiningAGroup() {
        let text = #"{"MessageId":"d7","Data":{"GroupId":"a8362222fd8a43fd95de0c785e5150b9","Data":{"GroupId":"a8362222fd8a43fd95de0c785e5150b9","GroupName":"probe group","State":"Idle","Participants":["autoqa"],"LastUpdatedAt":"2026-11-19T01:29:38.376529Z"},"Type":"GroupJoined"},"MessageType":"SyncPlayGroupUpdate"}"#
        XCTAssertEqual(SyncPlayWire.event(from: text), .joined(SyncPlayGroup(
            GroupId: "a8362222fd8a43fd95de0c785e5150b9", GroupName: "probe group", State: "Idle", Participants: ["autoqa"])))
    }

    func testTheQueueSaysWhatIsOnAndWhere() throws {
        let text = #"{"MessageId":"e7","Data":{"GroupId":"a836","Data":{"Reason":"NewPlaylist","LastUpdate":"2026-11-19T01:29:39.472467Z","Playlist":[{"ItemId":"9cd94f95847de72cdbda166c37504227","PlaylistItemId":"0141b2e2d81f4bbab81ad0ecdbc7988c"}],"PlayingItemIndex":0,"StartPositionTicks":300000000,"IsPlaying":false,"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"},"Type":"PlayQueue"},"MessageType":"SyncPlayGroupUpdate"}"#
        guard case .queue(let queue) = SyncPlayWire.event(from: text) else { return XCTFail("not a queue") }
        XCTAssertEqual(queue.reason, "NewPlaylist")
        XCTAssertEqual(queue.current, .init(itemId: "9cd94f95847de72cdbda166c37504227", playlistItemId: "0141b2e2d81f4bbab81ad0ecdbc7988c"))
        XCTAssertEqual(queue.startPositionTicks, 300_000_000)
        // Paused, the group is where the update put it however long ago that was.
        let later = queue.lastUpdate.addingTimeInterval(12)
        XCTAssertEqual(queue.position(serverNow: later), 30)
        // Playing, it has moved on by as long as it has been playing.
        var playing = queue
        playing.isPlaying = true
        XCTAssertEqual(playing.position(serverNow: later), 42, accuracy: 0.001)
    }

    func testAnEmptyQueueHasNothingOn() {
        let text = #"{"Data":{"GroupId":"a","Data":{"Reason":"NewPlaylist","LastUpdate":"2026-11-19T01:29:39Z","Playlist":[],"PlayingItemIndex":-1,"StartPositionTicks":0,"IsPlaying":false},"Type":"PlayQueue"},"MessageType":"SyncPlayGroupUpdate"}"#
        guard case .queue(let queue) = SyncPlayWire.event(from: text) else { return XCTFail("not a queue") }
        XCTAssertNil(queue.current)
    }

    func testAnOrderCarriesItsPositionAndItsMoment() throws {
        let text = #"{"MessageId":"20","Data":{"GroupId":"a836","PlaylistItemId":"0141b2e2d81f4bbab81ad0ecdbc7988c","When":"2026-11-19T01:29:47.912986Z","PositionTicks":900000000,"Command":"Unpause","EmittedAt":"2026-11-19T01:29:46.913358Z"},"MessageType":"SyncPlayCommand"}"#
        guard case .command(let command) = SyncPlayWire.event(from: text) else { return XCTFail("not an order") }
        XCTAssertEqual(command.kind, .unpause)
        XCTAssertEqual(command.seconds, 90)
        XCTAssertEqual(command.playlistItemId, "0141b2e2d81f4bbab81ad0ecdbc7988c")
        // The server gives a second's notice, so everyone starts on the dot.
        XCTAssertEqual(command.when.timeIntervalSince(command.emittedAt), 1, accuracy: 0.01)
    }

    func testTheOtherUpdates() {
        func update(_ type: String, _ data: String) -> SyncPlayEvent? {
            SyncPlayWire.event(from: #"{"Data":{"GroupId":"a","Data":\#(data),"Type":"\#(type)"},"MessageType":"SyncPlayGroupUpdate"}"#)
        }
        XCTAssertEqual(update("UserJoined", #""Alex""#), .userJoined("Alex"))
        XCTAssertEqual(update("UserLeft", #""Alex""#), .userLeft("Alex"))
        XCTAssertEqual(update("GroupLeft", #""a8362222-fd8a-43fd-95de-0c785e5150b9""#), .left)
        XCTAssertEqual(update("StateUpdate", #"{"State":"Waiting","Reason":"Seek"}"#), .state("Waiting"))
        XCTAssertEqual(update("LibraryAccessDenied", #""""#), .refused("LibraryAccessDenied"))
        XCTAssertEqual(update("GroupDoesNotExist", #""""#), .refused("GroupDoesNotExist"))
    }

    func testEverythingElseOnTheSocketIsNotSyncPlays() {
        XCTAssertNil(SyncPlayWire.event(from: #"{"MessageType":"UserDataChanged","Data":{}}"#))
        XCTAssertNil(SyncPlayWire.event(from: #"{"MessageType":"KeepAlive"}"#))
        XCTAssertNil(SyncPlayWire.event(from: "not json"))
    }

    func testAnIdIsTheSameWithOrWithoutDashes() {
        XCTAssertTrue(SyncPlayWire.sameId("a8362222-FD8A-43fd-95de-0c785e5150b9", "a8362222fd8a43fd95de0c785e5150b9"))
        XCTAssertFalse(SyncPlayWire.sameId("a8362222fd8a43fd95de0c785e5150b9", "00000000000000000000000000000000"))
        XCTAssertFalse(SyncPlayWire.sameId(nil, nil))
    }

    func testTheSocketAddress() {
        XCTAssertEqual(SyncPlayWire.socketURL(server: "http://127.0.0.1:8196", deviceId: "abc")?.absoluteString,
                       "ws://127.0.0.1:8196/socket?deviceId=abc")
        XCTAssertEqual(SyncPlayWire.socketURL(server: "https://media.example.com/jellyfin/", deviceId: "abc")?.absoluteString,
                       "wss://media.example.com/jellyfin/socket?deviceId=abc")
        XCTAssertNil(SyncPlayWire.socketURL(server: "ftp://nope", deviceId: "abc"))
    }

    func testTicks() {
        XCTAssertEqual(SyncPlayWire.ticks(90), 900_000_000)
        XCTAssertEqual(SyncPlayWire.ticks(-3), 0)
    }

    func testWords() {
        XCTAssertEqual(SyncPlayCoordinator.groupName(for: "Alex"), "Alex’s group")
        XCTAssertEqual(SyncPlayCoordinator.groupName(for: nil), "Watch Together")
        XCTAssertEqual(SyncPlayGroup(GroupId: "a", GroupName: "Film night", Participants: ["Alex"]).summary, "Film night · just Alex")
        XCTAssertEqual(SyncPlayGroup(GroupId: "a", GroupName: "Film night", Participants: ["Alex", "Sam", "Zoe"]).summary, "Film night · 3 watching")
        XCTAssertEqual(SyncPlayGroup(GroupId: "a", GroupName: "Film night").summary, "Film night")
        XCTAssertTrue(SyncPlayCoordinator.refusal(APIError.server(status: 403, path: "/SyncPlay/List")).contains("isn’t allowed"))
        XCTAssertTrue(SyncPlayCoordinator.refusal("LibraryAccessDenied").contains("can’t see"))
        XCTAssertTrue(SyncPlayCopy.question(groups: 0, playing: true).hasPrefix("Nobody on your server"))
        XCTAssertTrue(SyncPlayCopy.question(groups: 2, playing: false).hasPrefix("Join a group"))
    }
}

final class SyncPlayClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAServerAheadByFiveSecondsOverAFortyMillisecondTrip() {
        // Sent at 0, arrives 20 ms later by a clock 5 s ahead, answered 2 ms
        // after that, back 20 ms later.
        let sample = SyncPlayClock.sample(
            sent: t0, serverReceived: t0.addingTimeInterval(5.020),
            serverSent: t0.addingTimeInterval(5.022), received: t0.addingTimeInterval(0.042))
        XCTAssertEqual(sample.offset, 5, accuracy: 0.0001)
        XCTAssertEqual(sample.ping, 0.020, accuracy: 0.0001)
    }

    func testTheShortestTripIsTheOneBelieved() {
        var clock = SyncPlayClock()
        XCTAssertFalse(clock.isSet)
        XCTAssertEqual(clock.offset, 0)
        clock.add(.init(offset: 5.3, ping: 0.4))
        clock.add(.init(offset: 5.0, ping: 0.02))
        clock.add(.init(offset: 4.8, ping: 0.2))
        XCTAssertEqual(clock.offset, 5.0)
        XCTAssertEqual(clock.ping, 0.02)
        XCTAssertEqual(clock.local(t0.addingTimeInterval(5)), t0)
        XCTAssertEqual(clock.server(t0), t0.addingTimeInterval(5))
    }

    func testOnlyTheLastEightSamplesAreKept() {
        var clock = SyncPlayClock()
        clock.add(.init(offset: 99, ping: 0.001))
        for _ in 0..<8 { clock.add(.init(offset: 1, ping: 0.05)) }
        XCTAssertEqual(clock.samples.count, 8)
        XCTAssertEqual(clock.offset, 1, "a good sample from long ago has aged out")
    }
}

final class GroupOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAPauseSeeksOnlyWhenItIsFarFromTheGroup() {
        let order = GroupOrder(position: 100, playing: false)
        XCTAssertEqual(order.step(now: now, clock: 100.2, rate: 1), .pause(seekTo: nil))
        XCTAssertEqual(order.step(now: now, clock: 103, rate: 1), .pause(seekTo: 100))
        XCTAssertEqual(GroupOrder(position: nil, playing: false).step(now: now, clock: 55, rate: 1), .pause(seekTo: nil))
    }

    func testAPlayOrderForAMomentFromNowLinesUpAndWaits() {
        let order = GroupOrder(position: 90, playing: true, at: now.addingTimeInterval(1))
        XCTAssertEqual(order.step(now: now, clock: 90.1, rate: 1), .playLater(seekTo: nil, after: 1))
        XCTAssertEqual(order.step(now: now, clock: 30, rate: 1), .playLater(seekTo: 90, after: 1))
    }

    func testAPlayOrderFromAMomentAgoStartsWhereTheGroupHasGotTo() {
        let order = GroupOrder(position: 90, playing: true, at: now.addingTimeInterval(-4))
        XCTAssertEqual(order.expectedPosition(now: now, rate: 1), 94)
        // Already there, near enough: just play.
        XCTAssertEqual(order.step(now: now, clock: 94.3, rate: 1), .playNow(seekTo: nil))
        // Behind where everyone is: jump to where they are now, not to where they started.
        XCTAssertEqual(order.step(now: now, clock: 90, rate: 1), .playNow(seekTo: 94))
    }

    func testAPlayOrderWithNoMomentIsNow() {
        let order = GroupOrder(position: 90, playing: true)
        XCTAssertEqual(order.step(now: now, clock: 90, rate: 1), .playNow(seekTo: nil))
        XCTAssertEqual(order.step(now: now, clock: 10, rate: 1), .playNow(seekTo: 90))
    }

    func testAStreamWithNoClockYetIsSentWhereItBelongs() {
        XCTAssertEqual(GroupOrder(position: 90, playing: false).step(now: now, clock: nil, rate: 1), .pause(seekTo: 90))
    }
}
