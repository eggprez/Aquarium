//  The watch smoke test: launch clean in test mode, sign in to the QA server
//  as suite-watch from the app itself (no phone needed), and the root list
//  shows signed in.

import XCTest

final class WatchSmokeTests: WatchUITestCase {
    func testLaunchSignsInAndShowsRoot() {
        launch()
        app.element(TestID.Watch.root).waitToExist(60)
        app.element(TestID.Watch.rootState("signedIn")).waitToExist(60)
        attachScreenshot("root")
    }
}
