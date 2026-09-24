//  The home screen's press-and-hold menu on an iPhone or iPad.
//
//  Two entries: whatever Continue Watching would put first, named, and
//  Search. They are rewritten each time Home loads its rows, so the title on
//  the menu is the one the app would lead with. A press comes back in
//  through `SceneDelegate` (see AquariumApp.swift) as the same
//  `aquarium://` link the Apple TV's top shelf uses.

#if os(iOS)
import UIKit

@MainActor
enum QuickActions {
    static let playType = "app.aquarium.play"
    static let searchType = "app.aquarium.search"
    static let itemKey = "itemId"

    static func update(resume: [BaseItem], nextUp: [BaseItem]) {
        var items: [UIApplicationShortcutItem] = []
        if let first = resume.first ?? nextUp.first {
            let title = first.isEpisode ? (first.SeriesName ?? first.Name ?? "Continue Watching") : (first.Name ?? "Continue Watching")
            let subtitle = first.isEpisode
                ? [first.episodeLabel, first.Name].compactMap { $0 }.joined(separator: " · ")
                : "Continue watching"
            items.append(UIApplicationShortcutItem(
                type: playType,
                localizedTitle: title,
                localizedSubtitle: subtitle.isEmpty ? nil : subtitle,
                icon: UIApplicationShortcutIcon(type: .play),
                userInfo: [itemKey: first.Id as NSString]
            ))
        }
        items.append(UIApplicationShortcutItem(
            type: searchType,
            localizedTitle: "Search",
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(type: .search),
            userInfo: nil
        ))
        UIApplication.shared.shortcutItems = items
    }

    static func clear() {
        UIApplication.shared.shortcutItems = []
    }

    /// The link a pressed entry stands for, for `AppModel.handle`.
    static func url(for item: UIApplicationShortcutItem) -> URL? {
        switch item.type {
        case playType:
            guard let id = item.userInfo?[itemKey] as? String else { return nil }
            return URL(string: "aquarium://play/\(JellyfinClient.pathId(id))")
        case searchType:
            return URL(string: "aquarium://search")
        default:
            return nil
        }
    }
}
#endif
