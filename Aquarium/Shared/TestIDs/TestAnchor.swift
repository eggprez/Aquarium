//  A findable mark behind a screen or a region, for UI tests only.
//
//  `.accessibilityIdentifier` on a control is free: nothing reads it but a
//  test. A screen is not a control, and putting an identifier on a stack or a
//  scroll view hands it down to every child without one. So a screen (or a
//  shelf, a card, an overlay) gets an element of its own behind it, the size
//  of the thing it marks, carrying the identifier and nothing else.
//
//  An extra element is something VoiceOver could land on, so it only exists
//  in a debug build launched as a UI test (`-AquariumUITest YES`). In every
//  other launch, and in every release build, `testAnchor` returns the view
//  untouched.

import SwiftUI

// `TestRuntime.isUITest` is in TestLaunch.swift.

extension View {
    /// Mark this screen or region for UI tests. See the top of this file.
    @ViewBuilder
    func testAnchor(_ id: String) -> some View {
        #if DEBUG
        if TestRuntime.isUITest {
            background {
                Color.clear
                    .accessibilityElement()
                    .accessibilityIdentifier(id)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
