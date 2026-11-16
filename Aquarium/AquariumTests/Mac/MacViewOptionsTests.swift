//  View ▸ Bigger / Smaller / Actual Size (⌘= / ⌘- / ⌘0): `MacViewOptions`.

#if os(macOS)
import XCTest
@testable import Aquarium

@MainActor
final class MacViewOptionsTests: MacUnitTestCase {
    private var saved = 1.0
    private let key = "mac_thumbnail_size"

    override func setUp() async throws {
        saved = MacViewOptions.shared.thumbnailSize
        MacViewOptions.shared.actualSize()
    }

    override func tearDown() async throws {
        MacViewOptions.shared.thumbnailSize = saved
    }

    func testStartsAtActualSize() {
        let o = MacViewOptions.shared
        XCTAssertEqual(o.thumbnailSize, 1)
        XCTAssertTrue(o.isActualSize)
        XCTAssertTrue(o.canGrow)
        XCTAssertTrue(o.canShrink)
    }

    func testBiggerStepsByFifteenPercent() {
        MacViewOptions.shared.bigger()
        XCTAssertEqual(MacViewOptions.shared.thumbnailSize, 1.15, accuracy: 0.0001)
        XCTAssertFalse(MacViewOptions.shared.isActualSize)
    }

    func testSmallerStepsByFifteenPercent() {
        MacViewOptions.shared.smaller()
        XCTAssertEqual(MacViewOptions.shared.thumbnailSize, 0.85, accuracy: 0.0001)
    }

    func testActualSizeReturnsToOne() {
        MacViewOptions.shared.bigger()
        MacViewOptions.shared.bigger()
        MacViewOptions.shared.actualSize()
        XCTAssertEqual(MacViewOptions.shared.thumbnailSize, 1)
        XCTAssertTrue(MacViewOptions.shared.isActualSize)
    }

    func testBiggerStopsAtUpperBoundAndDisablesItself() {
        for _ in 0..<20 { MacViewOptions.shared.bigger() }
        XCTAssertEqual(MacViewOptions.shared.thumbnailSize, MacViewOptions.range.upperBound, accuracy: 0.0001)
        XCTAssertFalse(MacViewOptions.shared.canGrow, "View ▸ Bigger is disabled at the largest size")
        XCTAssertTrue(MacViewOptions.shared.canShrink)
    }

    func testSmallerStopsAtLowerBoundAndDisablesItself() {
        for _ in 0..<20 { MacViewOptions.shared.smaller() }
        XCTAssertEqual(MacViewOptions.shared.thumbnailSize, MacViewOptions.range.lowerBound, accuracy: 0.0001)
        XCTAssertFalse(MacViewOptions.shared.canShrink, "View ▸ Smaller is disabled at the smallest size")
    }

    /// Seven presses each way land back on exactly 1, not 0.9999999.
    func testRoundTripLandsExactlyOnOne() {
        for _ in 0..<3 { MacViewOptions.shared.bigger() }
        for _ in 0..<3 { MacViewOptions.shared.smaller() }
        XCTAssertEqual(MacViewOptions.shared.thumbnailSize, 1)
        XCTAssertTrue(MacViewOptions.shared.isActualSize)
    }

    func testSizeIsPersisted() {
        MacViewOptions.shared.bigger()
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 1.15, accuracy: 0.0001)
    }

    /// Regression: ThumbnailSizeClampNotSaved. A step past either end was
    /// clamped and returned before saving, so 0.6 showed on screen and the
    /// previous size came back at the next launch.
    /// Source: commit 6704c21; comment at Views/MacViewOptions.swift:28-31.
    func testBugThumbnailSizeClampNotSaved() {
        MacViewOptions.shared.thumbnailSize = 0.2
        XCTAssertEqual(MacViewOptions.shared.thumbnailSize, 0.6, accuracy: 0.0001)
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 0.6, accuracy: 0.0001, "the clamped value is the one saved")
        MacViewOptions.shared.thumbnailSize = 9
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 1.6, accuracy: 0.0001)
    }

    /// Test mode keeps this out of the real app's preferences.
    func testWritesGoToTheTestSuiteNotTheRealDefaults() {
        XCTAssertTrue(TestRuntime.isUITest, "the unit plan runs the host in test mode")
        MacViewOptions.shared.bigger()
        let suite = UserDefaults(suiteName: TestLaunch.defaultsSuite)
        XCTAssertEqual(suite?.double(forKey: key) ?? 0, 1.15, accuracy: 0.0001,
                       "UserDefaults.standard answers from the test suite")
    }
}
#endif
