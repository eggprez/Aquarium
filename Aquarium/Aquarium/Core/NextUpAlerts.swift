//  A notification when a new episode of something you are watching lands.
//
//  Nothing can push to a Jellyfin client — there is no server of ours for
//  a push to come from — so the app looks for itself: every time Home has a
//  fresh Next Up, and every few hours in the background through
//  `BGAppRefreshTask`, which the system runs when it sees fit and never
//  while the phone is low or busy.
//
//  "New" is decided by the server's clock, not by the list. Next Up changes
//  every time an episode is finished — the next one takes its place — and
//  none of that is news. An episode is announced when it was *added to the
//  server* after the last look, which is exactly the one that wasn't there
//  before: a show you follow got a new episode overnight.
//
//  iPhone and iPad only: the Mac has no background refresh for an app that
//  isn't running, and the Apple TV has no notifications to show.

#if os(iOS)

import BackgroundTasks
import Foundation
import UserNotifications
import os

@MainActor
final class NextUpAlerts: NSObject {
    static let shared = NextUpAlerts()

    /// Listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let taskIdentifier = "scottai.FellyJin.nextup-refresh"
    static let category = "app.aquarium.newepisode"
    static let playAction = "app.aquarium.newepisode.play"
    static let itemKey = "itemId"

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "nextup")

    /// How far out the next background look is asked for. The system treats
    /// it as "not before", and in practice runs it a good deal later.
    private static let refreshInterval: TimeInterval = 4 * 3600
    /// How many are announced one by one before the rest become a count.
    private static let namedLimit = 4

    private var prefs: Preferences { .shared }
    private var client: JellyfinClient { .shared }
    private var registered = false

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Before the app finishes launching, as `BGTaskScheduler` requires.
    func register() {
        guard !registered else { return }
        registered = true
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        let play = UNNotificationAction(identifier: Self.playAction, title: "Play", options: [.foreground])
        centre.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [play], intentIdentifiers: []),
        ])
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in await NextUpAlerts.shared.run(task) }
        }
    }

    /// Book the next background look. Harmless to call again: a request
    /// with the same identifier replaces the one before.
    func schedule() {
        guard prefs.newEpisodeAlerts, client.isSignedIn else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(Self.refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator refuses every submission; a device refuses while
            // Background App Refresh is off. Neither is worth more than a line.
            Self.log.notice("refresh not booked: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func run(_ task: BGAppRefreshTask) async {
        // The next one first: a look that runs out of time still leaves one
        // booked.
        schedule()
        let work = Task { await self.check() }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }

    private func check() async {
        guard prefs.newEpisodeAlerts, client.isSignedIn else { return }
        guard let episodes = try? await client.nextUp() else { return }
        note(nextUp: episodes)
    }

    /// The setting going on: permission to notify, and a baseline so that
    /// what is already in Next Up isn't announced as news. False when
    /// permission was refused, in which case the setting should go back off.
    func enable() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let granted = (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        if let episodes = try? await client.nextUp() { remember(episodes) }
        schedule()
        return true
    }

    // MARK: - Spotting what's new

    private var knownKey: String? { client.session.map { "nextup_known_\($0.accountKey)" } }
    private var checkedKey: String? { client.session.map { "nextup_checked_\($0.accountKey)" } }

    /// Home has a fresh Next Up; see what in it is new. Everything older
    /// than the last look is what the list had anyway.
    func note(nextUp episodes: [BaseItem]) {
        guard prefs.newEpisodeAlerts, let knownKey, let checkedKey else { return }
        let defaults = UserDefaults.standard
        let known = Set(defaults.stringArray(forKey: knownKey) ?? [])
        let lastChecked = defaults.object(forKey: checkedKey) as? Date
        defer { remember(episodes) }
        // The first look only sets the baseline.
        guard let lastChecked else { return }
        let fresh = episodes.filter { episode in
            guard episode.isEpisode, !known.contains(episode.Id),
                  let added = Format.parseDate(episode.DateCreated) else { return false }
            return added > lastChecked
        }
        guard !fresh.isEmpty else { return }
        Self.log.notice("\(fresh.count) new episode(s) in Next Up")
        Task { await announce(fresh) }
    }

    private func remember(_ episodes: [BaseItem]) {
        guard let knownKey, let checkedKey else { return }
        let defaults = UserDefaults.standard
        defaults.set(episodes.map(\.Id), forKey: knownKey)
        // The server's clock, because `DateCreated` is in it.
        defaults.set(client.serverNow, forKey: checkedKey)
    }

    private func announce(_ episodes: [BaseItem]) async {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for episode in episodes.prefix(Self.namedLimit) {
            let content = UNMutableNotificationContent()
            content.title = "New episode of \(episode.SeriesName ?? "a show you're watching")"
            content.body = [episode.episodeLabel, episode.Name].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.threadIdentifier = episode.SeriesId ?? episode.Id
            content.userInfo = [Self.itemKey: episode.Id]
            try? await centre.add(UNNotificationRequest(identifier: "nextup-\(episode.Id)", content: content, trigger: nil))
        }
        let rest = episodes.count - Self.namedLimit
        if rest > 0 {
            let content = UNMutableNotificationContent()
            content.title = "\(rest) more new episode\(rest == 1 ? "" : "s")"
            content.body = "In Next Up, on Home."
            content.sound = .default
            try? await centre.add(UNNotificationRequest(identifier: "nextup-more-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
        }
    }
}

extension NextUpAlerts: UNUserNotificationCenterDelegate {
    /// Shown even with the app in front: Home may be the very page that
    /// found the episode, and a banner is how it says so.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tap opens the episode's page; the Play button plays it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo[Self.itemKey] as? String else { return }
        let play = response.actionIdentifier == Self.playAction
        await MainActor.run {
            if play {
                Task { await AppModel.shared.play(itemId: id) }
            } else {
                AppModel.shared.open(itemId: id)
            }
        }
    }
}

#endif
