//  Handoff: the film on the phone, picked up on the iPad or the Mac.
//
//  While something from the server is playing, an `NSUserActivity` naming it
//  and the playhead is current. Another device signed in to the same iCloud
//  account shows the app's icon in its dock or app switcher, and choosing it
//  starts the same title there, at the same point — through
//  `AppModel.continueActivity`. The position is refreshed every few seconds;
//  the other device only ever asks for the payload at the moment of pick-up.
//
//  Not on tvOS, which neither offers nor accepts Handoff.

#if !os(tvOS)
import Foundation

@MainActor
final class PlaybackHandoff {
    static let shared = PlaybackHandoff()
    /// Listed under NSUserActivityTypes in Info.plist.
    static let activityType = "app.aquarium.playing"
    static let itemKey = "itemId"
    static let positionKey = "position"

    private var activity: NSUserActivity?
    private var lastUpdate = Date.distantPast

    func begin(item: BaseItem, position: Double) {
        end()
        let a = NSUserActivity(activityType: Self.activityType)
        a.title = "Watch \(item.Name ?? "in Aquarium")"
        a.isEligibleForHandoff = true
        a.isEligibleForSearch = false
        #if os(iOS)
        a.isEligibleForPrediction = false
        #endif
        a.userInfo = [Self.itemKey: item.Id, Self.positionKey: position]
        a.requiredUserInfoKeys = [Self.itemKey]
        a.becomeCurrent()
        activity = a
        lastUpdate = Date()
    }

    /// Called on the player's time tick; rewritten at most every few seconds.
    func update(position: Double) {
        guard let activity, Date().timeIntervalSince(lastUpdate) >= 5 else { return }
        lastUpdate = Date()
        activity.addUserInfoEntries(from: [Self.positionKey: position])
    }

    func end() {
        activity?.invalidate()
        activity = nil
    }
}
#endif
