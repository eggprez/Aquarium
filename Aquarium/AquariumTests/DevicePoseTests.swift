import XCTest
@testable import Aquarium

/// The laptop waits for the hinge to stop: every opening and closing of the
/// phone passes through part-open, and the inside screen used to flash the
/// picture-above-controls split on the way.
final class DevicePoseTests: XCTestCase {
    private func pose(_ hinge: HingeStatus?, settled: Bool, crease: Bool = false) -> DevicePose {
        DevicePose.resolve(
            hinge: hinge, horizontal: .regular, vertical: .regular,
            creaseIsVertical: crease, partSettled: settled,
            override: .automatic, isPhoneIdiom: true)
    }

    func testPartOpenInsideIsTheOpenLayoutUntilSettled() {
        XCTAssertEqual(pose(.partiallyOpen, settled: false), .inside)
        XCTAssertEqual(pose(.partiallyOpen, settled: true), .halfFolded)
    }

    func testBookIsOpenLayoutEitherWay() {
        XCTAssertEqual(pose(.partiallyOpen, settled: true, crease: true), .inside)
    }

    /// Opening through part-open, the hinge moving all the while: never
    /// settles. Stopping part-open: settles after the wait. Moving off it:
    /// unsettled at once.
    @MainActor
    func testHingeSettlesOnlyOnceItStops() async throws {
        let fold = FoldState.shared
        fold.update(hinge: .closed, angle: 0)
        // Opening by hand: a few degrees every tenth of a second.
        for step in 1...12 {
            fold.update(hinge: .partiallyOpen, angle: Double(step) * 10)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(fold.partSettled, "settled while still opening, at \(step * 10)°")
        }
        fold.update(hinge: .fullyOpen, angle: 180)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertFalse(fold.partSettled)

        // Closing partway and setting it down.
        fold.update(hinge: .partiallyOpen, angle: 110)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fold.partSettled)
        fold.update(hinge: .partiallyOpen, angle: 112)  // a wobble, not a move
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(fold.partSettled)

        // A nudge once settled keeps the laptop; closing ends it at once.
        fold.update(hinge: .partiallyOpen, angle: 125)
        XCTAssertTrue(fold.partSettled)
        fold.update(hinge: .closed, angle: 0)
        XCTAssertFalse(fold.partSettled)
    }

    func testFrontScreenPosesDoNotWait() {
        let tent = DevicePose.resolve(
            hinge: .partiallyOpen, horizontal: .compact, vertical: .compact,
            partSettled: false, override: .automatic, isPhoneIdiom: true)
        XCTAssertEqual(tent, .tent)
    }
}
