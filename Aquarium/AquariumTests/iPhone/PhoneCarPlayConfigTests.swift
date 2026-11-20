//  CarPlay's switches. The scene itself is CPTemplates and can't be driven
//  from a test (MANUAL.md, "CarPlay"), but what a car or Apple HomeView is
//  allowed to show is decided by two files: the entitlements and
//  `FJCarPlayVideo` in Info.plist. Apple's CarPlay Developer Guide
//  (2026-10-13): "Multiple CarPlay entitlements may not be combined in a
//  single app" — so the audio entitlement stands alone, and the Video tab
//  rides on it (an audio app may offer "a mixture of audio and video").
//  A build signed with both (1.6 build 6, 2026-11-19) did not appear on
//  HomeView.
//
//  Read from the source tree, which the simulator shares with the Mac: a
//  simulator build isn't signed with the real entitlements.

#if os(iOS)
import XCTest
@testable import Aquarium

@MainActor
final class PhoneCarPlayConfigTests: PhoneUnitTestCase {
    /// Aquarium/ — two folders up from AquariumTests/iPhone/.
    private var projectFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func plist(_ name: String) throws -> [String: Any] {
        let url = projectFolder.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "source tree not reachable from this device")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Regression (2026-11-19): audio and video entitlements together are
    /// against Apple's rules, whatever the flag says.
    func testCarPlayEntitlementsAreNotCombined() throws {
        let keys = try plist("Aquarium-iOS.entitlements").keys.filter { $0.hasPrefix("com.apple.developer.carplay-") }
        XCTAssertEqual(keys, ["com.apple.developer.carplay-audio"])
    }

    /// The app the tests run in carries the flag the source says it does —
    /// `CarPlaySceneDelegate.offersVideo` reads it from the bundle.
    func testBundleCarriesTheVideoFlag() throws {
        let flagged = try plist("Info.plist")["FJCarPlayVideo"] as? Bool == true
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "FJCarPlayVideo") as? Bool == true, flagged)
    }

    /// Apple's "Preparing your iOS app for CarPlay development" has a CarPlay
    /// app name its provisioning profile itself rather than leave it to
    /// Xcode. The App Store export does that: signed by hand, with a profile
    /// named for the app and for everything it carries inside it.
    func testAppStoreExportNamesAProfileForEveryBundle() throws {
        let options = try plist("Tools/Signing/ExportOptions-iOS-AppStore.plist")
        XCTAssertEqual(options["signingStyle"] as? String, "manual")
        XCTAssertEqual(options["signingCertificate"] as? String, "Apple Distribution")
        let profiles = try XCTUnwrap(options["provisioningProfiles"] as? [String: String])
        XCTAssertEqual(Set(profiles.keys), [
            "scottai.FellyJin",
            "scottai.FellyJin.LiveActivities",
            "scottai.FellyJin.watchkitapp",
            "scottai.FellyJin.watchkitapp.widgets",
        ])
        XCTAssertFalse(profiles.values.contains { $0.isEmpty })
    }

    /// The Mac's entitlements stay free of CarPlay: App Store Connect refuses
    /// a Mac upload that carries those keys.
    func testMacEntitlementsCarryNoCarPlay() throws {
        let keys = try plist("Aquarium.entitlements").keys.filter { $0.contains("carplay") }
        XCTAssertEqual(keys, [])
    }
}
#endif
