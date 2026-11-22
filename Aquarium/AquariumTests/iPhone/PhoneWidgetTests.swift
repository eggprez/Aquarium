//  What the Home Screen card and the Live Activities read: the Now Playing
//  snapshot's clock and link, and the listening activity's state decoding.

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class PhoneWidgetTests: PhoneUnitTestCase {
    private func snapshot(playing: Bool, position: Double = 10, duration: Double = 100, isVideo: Bool = false,
                          updatedAt: Date) -> NowPlayingSnapshot {
        PhoneJSON.decode(NowPlayingSnapshot.self, """
        {"itemId":"i","title":"T","subtitle":"S","isVideo":\(isVideo),"isPlaying":\(playing),
         "position":\(position),"duration":\(duration),"rate":1,
         "updatedAt":\(updatedAt.timeIntervalSinceReferenceDate),"hasArtwork":false}
        """)
    }

    func testPausedCardKeepsItsPosition() {
        let s = snapshot(playing: false, updatedAt: Date().addingTimeInterval(-60))
        XCTAssertEqual(s.position(at: Date()), 10)
    }

    func testPlayingCardRunsOnButStopsAtTheEnd() {
        let now = Date()
        let s = snapshot(playing: true, updatedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(s.position(at: now), 40, accuracy: 0.5)
        XCTAssertEqual(s.position(at: now.addingTimeInterval(3600)), 100)
        XCTAssertEqual(s.fraction(at: now) ?? 0, 0.4, accuracy: 0.01)
    }

    func testMusicCardOpensNowPlaying() {
        XCTAssertEqual(snapshot(playing: true, updatedAt: Date()).link?.absoluteString, "aquarium://nowplaying")
    }

    /// Regression R-f66fe9c-la: an activity started by an older build sent a
    /// state without `isVideo`, and the whole update was dropped.
    func testListeningStateFromAnOlderBuildStillDecodes() throws {
        let json = #"{"title":"FX Chaptered Audiobook","isPlaying":true,"sleepDeadline":0}"#
        let state = try JSONDecoder().decode(ListeningActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state.title, "FX Chaptered Audiobook")
        XCTAssertFalse(state.isVideo)
        XCTAssertNil(state.skipLabel)
    }

    func testListeningStateRoundTrips() throws {
        let state = ListeningActivityAttributes.ContentState(title: "T", subtitle: "S", isPlaying: false,
                                                             sleepDeadline: Date(timeIntervalSince1970: 100), isVideo: true, skipLabel: "Skip intro")
        let back = try JSONDecoder().decode(ListeningActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
    }
}
#endif
