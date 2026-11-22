//  The iPad smoke test: launch clean in test mode, sign in to the QA server as
//  this suite's account (no sign-in screen), and Home shows.

#if os(iOS)
import XCTest

final class PadSmokeTests: PadUITestCase {
    func testLaunchSignsInAndShowsHome() {
        launch()
        app.element(TestID.Home.root).waitToExist(60)
        XCTAssertFalse(app.element(TestID.Shell.signedOut).exists, "still at the sign-in screen")
        attachScreenshot("home")
    }
}
#endif
