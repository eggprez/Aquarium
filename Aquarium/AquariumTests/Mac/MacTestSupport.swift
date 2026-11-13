//  Small helpers for the Mac unit tests: items built from the JSON the server
//  would send, and a way to put the shared app model back the way a test
//  found it.
//
//  The unit plan hosts the tests in the app in test mode, so `AppModel.shared`,
//  `PlayerModel.shared` and the rest are the live ones the host's windows
//  read. Every test that changes one restores it in `tearDown`.

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Aquarium

enum MacFixture {
    /// A `BaseItem` from server-shaped JSON, so a test names only the fields
    /// it cares about.
    static func item(_ fields: [String: Any]) -> BaseItem {
        var json = fields
        if json["Id"] == nil { json["Id"] = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(BaseItem.self, from: data)
    }

    static func film(_ id: String, name: String = "Film", played: Bool = false, favorite: Bool = false) -> BaseItem {
        item(["Id": id, "Name": name, "Type": "Movie",
              "UserData": ["Played": played, "IsFavorite": favorite]])
    }

    static func episode(_ id: String, series: String = "Show", season: Int = 1, number: Int,
                        name: String = "Episode", played: Bool = false) -> BaseItem {
        item(["Id": id, "Name": name, "Type": "Episode", "SeriesName": series, "SeriesId": "series-\(series)",
              "ParentIndexNumber": season, "IndexNumber": number,
              "UserData": ["Played": played]])
    }

    static func channel(_ id: String, name: String, number: String? = nil) -> BaseItem {
        var f: [String: Any] = ["Id": id, "Name": name, "Type": "TvChannel"]
        if let number { f["ChannelNumber"] = number }
        return item(f)
    }

    static func library(_ id: String, name: String, type: String?) -> AppSection {
        .library(id: id, name: name, collectionType: type)
    }

    static func track(server: Int?, av: Int?, label: String, forced: Bool = false) -> TrackOption {
        TrackOption(serverIndex: server, avIndex: av, label: label, language: nil, isForced: forced)
    }
}

/// What a test changes on `AppModel.shared`, put back afterwards.
@MainActor
struct AppModelSnapshot {
    let selection: AppSection
    let paths: [String: NavigationPath]
    let keyNavigator: ItemWindowNavigator?
    let pendingAlert: AppAlert?
    let toasts: [Toast]
    let sidebarSearchTerm: String

    init() {
        let app = AppModel.shared
        selection = app.selection
        paths = app.paths
        keyNavigator = app.keyNavigator
        pendingAlert = app.pendingAlert
        toasts = app.toasts
        sidebarSearchTerm = app.sidebarSearchTerm
    }

    func restore() {
        let app = AppModel.shared
        app.selection = selection
        app.paths = paths
        app.keyNavigator = keyNavigator
        app.pendingAlert = pendingAlert
        app.toasts = toasts
        app.sidebarSearchTerm = sidebarSearchTerm
    }
}
#endif
