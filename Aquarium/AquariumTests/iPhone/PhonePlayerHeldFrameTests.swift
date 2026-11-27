//  The frame a foldable's player chrome keeps while the status bar is away
//  and on its way back (`PlayerScreen.HeldFrame`): the bar's column is safe
//  area, it goes with the bar, and the system returns it a few frames after
//  the bar is asked for — so the controls jumped sideways mid-fade.

#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Aquarium

@MainActor
final class PhonePlayerHeldFrameTests: PhoneUnitTestCase {
    private let screen = CGSize(width: 951, height: 669)
    private let withColumn = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
    private let withoutColumn = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0)

    private var held: PlayerScreen.HeldFrame {
        .init(screen: screen, orientation: .landscapeRight, insets: withColumn)
    }

    private func insets(live: EdgeInsets, held: PlayerScreen.HeldFrame?, screen: CGSize? = nil,
                        orientation: UIInterfaceOrientation = .landscapeRight,
                        barHidden: Bool, barReturning: Bool) -> EdgeInsets {
        PlayerScreen.HeldFrame.insets(live: live, held: held, screen: screen ?? self.screen, orientation: orientation,
                                      barHidden: barHidden, barReturning: barReturning)
    }

    /// With the bar hidden the column has gone from the safe area and the
    /// chrome keeps it all the same.
    func testHiddenBarKeepsTheHeldInsets() {
        XCTAssertEqual(insets(live: withoutColumn, held: held, barHidden: true, barReturning: false), withColumn)
    }

    /// The stutter: the bar is asked back, the column is not back yet, and
    /// the chrome must not be laid out without it in the meantime.
    func testReturningBarKeepsTheHeldInsetsUntilTheColumnIsBack() {
        XCTAssertEqual(insets(live: withoutColumn, held: held, barHidden: false, barReturning: true), withColumn)
    }

    /// Once the return is over the live insets are believed, whatever they
    /// say.
    func testSettledBarUsesTheLiveInsets() {
        XCTAssertEqual(insets(live: withoutColumn, held: held, barHidden: false, barReturning: false), withoutColumn)
    }

    /// A frame held on another screen, or the other way up, is not kept:
    /// the two landscapes have the column on opposite sides.
    func testATurnOrAnotherScreenDropsTheHeldFrame() {
        let turned = EdgeInsets(top: 0, leading: 84, bottom: 34, trailing: 0)
        XCTAssertEqual(insets(live: turned, held: held, orientation: .landscapeLeft,
                              barHidden: false, barReturning: true), turned)
        XCTAssertEqual(insets(live: turned, held: held, orientation: .landscapeLeft,
                              barHidden: true, barReturning: true), turned)
        let front = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
        XCTAssertEqual(insets(live: front, held: held, screen: CGSize(width: 466, height: 678),
                              orientation: .portrait, barHidden: true, barReturning: false), front)
    }

    /// Nothing held yet: the live insets.
    func testNothingHeldUsesTheLiveInsets() {
        XCTAssertEqual(insets(live: withColumn, held: nil, barHidden: true, barReturning: true), withColumn)
    }

    /// The hold outlasts the chrome's quarter-second fade.
    func testTheHoldOutlastsTheFade() {
        XCTAssertGreaterThan(PlayerScreen.HeldFrame.barReturn, .milliseconds(250))
    }
}
#endif
