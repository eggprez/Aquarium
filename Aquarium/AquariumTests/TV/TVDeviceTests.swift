//  The Apple TV as a device: what it calls itself to the server, Match Frame
//  Rate where nothing can be matched (a simulator, or the setting off), and
//  the household of accounts its users share (`Keychain.Household`, kept in
//  the test defaults in UI test mode).

#if os(tvOS)
import XCTest
import CoreGraphics
@testable import Aquarium

@MainActor
final class TVDeviceTests: TVUnitTestCase {
    func testTheServerSeesAnAppleTV() {
        XCTAssertEqual(JellyfinClient.deviceName, "Apple TV")
    }

    func testFrameRateMatchingAsksNothingWhereTheSettingIsOff() async {
        // The simulator has no Match Content: tvOS answers "off", and the
        // player must not wait on a switch that will never come.
        XCTAssertFalse(DisplayMatch.isEnabled)
        let started = ContinuousClock.now
        let asked = await DisplayMatch.request(rate: 23.976, codec: "h264", size: CGSize(width: 1920, height: 1080))
        XCTAssertFalse(asked)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "waited for a display switch")
        XCTAssertNil(DisplayMatch.requested)
        XCTAssertNil(DisplayMatch.matchedRate, "mpv is not told a rate the screen isn't running at")
        DisplayMatch.reset()
        XCTAssertNil(DisplayMatch.requested)
    }

    func testTheHouseholdOffersOnlyOtherUsersAccounts() {
        let prefs = Preferences.shared
        let mine = SavedSession(server: "http://house.invalid", userId: "u1", userName: "me", deviceId: prefs.deviceId, serverId: nil)
        let theirs = SavedSession(server: "http://house.invalid", userId: "u2", userName: "them", deviceId: prefs.deviceId, serverId: nil)
        let saved = Keychain.Household.accounts
        let session = prefs.session
        defer { prefs.forgetAccount(mine); prefs.session = session; Keychain.Household.accounts = saved }
        prefs.session = mine  // remembered as one of this user's accounts
        XCTAssertTrue(prefs.accounts.contains { $0.accountKey == mine.accountKey })
        Keychain.Household.accounts = [mine, theirs]
        XCTAssertEqual(prefs.householdAccounts.map(\.userId), ["u2"], "this user's own accounts aren't offered twice")
        prefs.forgetAccount(theirs)
        XCTAssertFalse(Keychain.Household.accounts.contains { $0.userId == "u2" }, "forgetting an account forgets it for the household")
    }

    func testTestModeKeepsTheHouseholdOutOfTheSharedKeychain() {
        // The stub accounts of earlier unit runs used to greet every UI test's
        // sign-in screen on this simulator: the shared keychain outlived
        // -AquariumTestReset (fixed in this branch's Keychain.Household).
        XCTAssertTrue(TestRuntime.isUITest)
        Keychain.Household.store(Data("x".utf8), "probe")
        XCTAssertEqual(UserDefaults.standard.data(forKey: "uitest_household.probe"), Data("x".utf8))
        Keychain.Household.delete("probe")
        XCTAssertNil(Keychain.Household.read("probe"))
    }
}
#endif
