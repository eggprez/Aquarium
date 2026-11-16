//  The names UI tests find things by.
//
//  One catalogue, compiled into the apps (iPhone, iPad, Mac, Apple TV and
//  Watch) and into every UI-test bundle, so a view and the test that looks
//  for it can never disagree about a string. A view never writes an
//  identifier as a literal: it names one from here.
//
//  THE NAMING RULE
//
//      <area>.<screen or part>.<element>[.<key>]
//
//  - Segments are lowerCamelCase, joined by dots: `player.pill.audio`.
//  - `area` is the enum the name lives in, with its first letter lowered:
//    `TestID.Home.root` is "home.root".
//  - A screen's own anchor is `<area>.root` or `<area>.<screen>.root`.
//  - A name that stands for one of many (a row, a card, a tab) is a function
//    taking a stable key and puts it last: `item.card.<jellyfin id>`,
//    `settings.video.quality.<raw value>`. The key is an id or an enum's raw
//    value, never a title on screen (titles are translated and change) and an
//    index only when there is nothing else.
//  - An identifier says what a control is, not where it sits or what it
//    looks like, so it survives a redesign.
//
//  HOW A VIEW TAKES ONE
//
//  - An interactive control (Button, Toggle, Picker, Menu, Slider, TextField,
//    NavigationLink): `.accessibilityIdentifier(TestID.Area.name)` on the
//    control itself. It changes nothing VoiceOver reads.
//  - A screen, or a region that is not itself a control (a shelf, a card, an
//    overlay, an empty or error state): `.testAnchor(TestID.Area.name)`, from
//    TestAnchor.swift. Never `.accessibilityIdentifier` on a stack or a
//    scroll view: SwiftUI hands a container's identifier down to every child
//    that has none of its own.
//
//  Each area has a file of its own beside this one (`TestID+Home.swift`, …),
//  an `extension TestID`, so two people adding names seldom touch the same
//  file. See Aquarium/TESTING.md.

import Foundation

enum TestID {
    /// A key made safe for an identifier: lower case letters, digits, and
    /// dashes. For the rare name that has to be built from text (a library's
    /// collection type, a settings section title).
    static func key(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
