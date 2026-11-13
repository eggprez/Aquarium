//  iPad UI tests live in this folder (owner: the iPad agent). Every file here is
//  wrapped in `#if os(iOS)` so the bundle still builds for the other platforms.
//  Subclass `PadUITestCase`. See Aquarium/TESTING.md.

#if os(iOS)
import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

class PadUITestCase: AquariumUITestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        try super.setUpWithError()
        Self.restoreResumeBaseline()
    }

    /// The two resume points of the suite's baseline (FIXTURES.md: FX Long
    /// Direct Play at 5:00, FX Long Show S01E02 at 3:20), put back before
    /// every test: a test that plays either moves it, and Continue Watching,
    /// Resume labels and the hero's first page all read it. A test that wants
    /// another point sets it after this. Quietly does nothing without the
    /// QA server or the fixtures.
    static func restoreResumeBaseline() {
        guard let fx = Fixtures.shared, let api = try? JellyfinAPI.signIn() else { return }
        if let film = fx.items["film.long_direct"] { try? api.setResume(film.id, seconds: 300) }
        let seasons = fx.items["show.long"]?.raw["seasons"] as? [[String: Any]] ?? []
        for season in seasons where season["index"] as? Int == 1 {
            for e in season["episodes"] as? [[String: Any]] ?? [] where e["index"] as? Int == 2 {
                if let id = e["id"] as? String { try? api.setResume(id, seconds: 200) }
            }
        }
    }
}
#endif
