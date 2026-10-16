//  Aquarium for Apple platforms.
//
//  One target, four systems: iPhone, iPad, Apple TV and Mac. The shared core in
//  Core/ is the same code everywhere; the shell below picks the shape each
//  platform expects — a tab bar on a phone, a sidebar on an iPad or a Mac, and
//  the top tab strip tvOS users navigate with a remote.

import SwiftUI
#if os(iOS) || os(macOS)
import CoreSpotlight
#endif
#if os(macOS)
import AppKit
#endif
#if canImport(CarPlay)
import CarPlay
#endif

@main
struct AquariumApp: App {
    @State private var app = AppModel.shared
    @State private var client = JellyfinClient.shared
    @State private var prefs = Preferences.shared
    @State private var player = PlayerModel.shared
    @State private var music = MusicPlayer.shared

    #if os(macOS)
    /// The Dock menu and the return-to-app refresh — see `MacAppDelegate`.
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    init() {
        // No window tabs: a tab is a second main window, and with one app
        // model, one player and one set of navigation paths it could only
        // mirror the first. See `MacCommands`, which drops New Window too.
        NSWindow.allowsAutomaticWindowTabbing = false
        // A film shared over FaceTime can arrive before any window is up —
        // see Core/SharePlay.swift.
        SharePlayCoordinator.shared.start()
    }
    #endif

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Here rather than in a view: a button on a Live Activity can start
        // the app with no window at all — see Core/LiveActivities.swift.
        LiveActivityCenter.shared.start()
        // And the watch, which may be sending listening to a phone in a
        // pocket — see Core/WatchLink.swift.
        WatchLink.shared.start()
        #if DEBUG
        // URLs from a script, past the system's prompt — see Core/DebugLinkHook.swift.
        DebugLinkHook.start()
        #endif
        // A film shared over FaceTime can arrive the same way — see
        // Core/SharePlay.swift.
        SharePlayCoordinator.shared.start()
        // The Control Centre buttons' intents run in this process and reach
        // the players through here — see Shared/WidgetTypes.swift.
        ControlActions.handler = { action in
            await MainActor.run {
                switch action {
                case .resumeWatching: Task { await AppModel.shared.continueWatching() }
                case .shuffleMusic: Task { await MusicActions.shuffleAll() }
                case .resumeAudiobook: Task { await MusicActions.resumeBook() }
                case .togglePlayPause: _ = PlayerActions.togglePlayPause()
                case .skipSegment: _ = PlayerActions.skipSegment()
                case .nextEpisode: Task { await PlayerActions.next() }
                }
            }
        }
    }
    #endif

    #if os(tvOS) && DEBUG
    init() {
        // Remote presses from a script — see Player/TV/RemoteDebugHook.swift.
        RemoteDebugHook.start()
    }
    #endif

    var body: some Scene {
        // "main" is `MacMainWindow.id`, which the Mac finds and reopens it by.
        WindowGroup(id: "main") {
            RootView()
                .environment(app)
                .environment(client)
                .environment(prefs)
                .environment(player)
                .environment(music)
                // Which way a foldable is being held — see DevicePose.
                .providesDevicePose()
                // tvOS has no light mode here — see Theme — so it must not be
                // told to switch to one.
                #if !os(tvOS)
                .themed(prefs.theme)
                #endif
                // Not on a Mac: there the tint is the accent colour the person
                // chose in System Settings, and a forced one overrides it on
                // every control in the app.
                #if !os(macOS)
                .tint(Theme.accent)
                #endif
                // The Apple TV home screen's top shelf comes back in here —
                // see AppModel.handle.
                .onOpenURL { app.handle($0) }
                #if os(tvOS) && DEBUG
                .task { player.playDebugStreamIfAsked() }
                #endif
                // A title picked from the system's search, and a film handed
                // over from another device — see AppModel.continueActivity.
                #if os(iOS) || os(macOS)
                .onContinueUserActivity(CSSearchableItemActionType) { app.continueActivity($0) }
                #endif
                #if !os(tvOS)
                .onContinueUserActivity(PlaybackHandoff.activityType) { app.continueActivity($0) }
                #endif
                // The smallest the main window is worth drawing at: the page
                // beside a full-width sidebar as wide as a title window's
                // smallest (see `RouteWindow`), and tall enough for the hero
                // and a shelf under it. Left to its content the window had no
                // floor worth the name, and the Library and Live TV toolbars
                // ran out of room long before it was reached.
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands {
            // The Mac expects its transport on the keyboard, not only in the
            // player's own controls.
            PlaybackCommands(player: player)
            MacCommands(app: app)
        }
        #endif

        #if os(macOS)
        // No `.tint` on any of these: the system accent colour, as above.
        Settings {
            MacSettingsWindow()
                .environment(app)
                .environment(client)
                .environment(prefs)
                .environment(player)
                .environment(music)
                .themed(prefs.theme)
        }

        // A title in a window of its own — see `ItemWindow`.
        WindowGroup("Title", id: ItemWindow.id, for: String.self) { $itemId in
            ItemWindow(itemId: itemId)
                .environment(app)
                .environment(client)
                .environment(prefs)
                .environment(player)
                .environment(music)
                .themed(prefs.theme)
        }
        .defaultSize(width: 1040, height: 780)
        .commandsRemoved()

        // A library, Favorites or a search in a window of its own, from the
        // sidebar's row menu — see `RouteWindow`.
        WindowGroup("Library", id: RouteWindow.id, for: Route.self) { $route in
            RouteWindow(route: route)
                .environment(app)
                .environment(client)
                .environment(prefs)
                .environment(player)
                .environment(music)
                .themed(prefs.theme)
        }
        .defaultSize(width: 1040, height: 780)
        .commandsRemoved()

        // The player, in a window of its own — see `PlayerWindow`.
        Window("Player", id: PlayerWindow.id) {
            PlayerWindow()
                .environment(app)
                .environment(client)
                .environment(prefs)
                .environment(player)
                .environment(music)
                .themed(prefs.theme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        // Not in the Window menu. The window opens itself when something
        // plays and closes when it stops (see `PlayerWindow`), so Window ▸
        // Player with nothing playing opened a black window that shut again
        // at once, and during Picture in Picture brought back the window the
        // floating picture had put away. While something plays it is listed
        // with the other open windows, under the title of what is playing.
        .commandsRemoved()
        #endif
    }
}

#if os(iOS)
import BackgroundTasks
import UIKit

/// What UIKit still has to answer for itself: the completion handler the
/// system hands back when it wakes the app to finish a background download,
/// and which orientations the app will accept.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Coming forward is heard here as a notification, not as
    /// `applicationDidBecomeActive`. This app runs in scenes — CarPlay needs
    /// one — and in a scene-based app UIKit never calls that on the app
    /// delegate. It used to be implemented here and did nothing: the watch
    /// was never sent a fresh sign-in on coming forward. The notification is
    /// still posted, once the app as a whole changes state.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.forgetNewEpisodeAlerts()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        return true
    }

    /// The new-episode, new-title and upgrade notifications are gone, and
    /// with them the background look behind them. What they left on a device
    /// that had them goes once: the switches, the per-account memory of what
    /// had been seen, the fingerprints of the library, and any background
    /// look still booked with the system.
    private static func forgetNewEpisodeAlerts() {
        let defaults = UserDefaults.standard
        let flag = "removed_notifications_v1"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        for key in defaults.dictionaryRepresentation().keys
        where ["new_episode_alerts", "new_title_alerts", "upgrade_alerts"].contains(key)
            || key.hasPrefix("nextup_known_") || key.hasPrefix("nextup_checked_") {
            defaults.removeObject(forKey: key)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("ContentAlerts", isDirectory: true))
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Kept per session — three can be woken at once — and stored before
        // returning, so the session's "finished" can't arrive ahead of it.
        MainActor.assumeIsolated {
            if identifier == WatchLink.fetchSessionIdentifier {
                WatchLink.shared.handleFetchEvents(completion: completionHandler)
            } else {
                DownloadManager.shared.setBackgroundCompletionHandler(completionHandler, for: identifier)
            }
        }
    }

    /// Coming forward: the watch gets a fresh sign-in and plan — a book
    /// started last night is in progress now — and whatever it handed over
    /// while the phone was asleep goes on to the server. And a holiday icon
    /// whose season is over comes off the Home Screen.
    @MainActor
    private func appBecameActive() {
        WatchLink.shared.sendContext()
        WatchLink.shared.forward()
        WatchLink.shared.resumeFetches()
        AppIconChoice.retireOutOfSeason()
    }

    /// The other job: answering which way round the app may be. The Info.plist
    /// lists every orientation the phone is *capable* of here, and this narrows
    /// it to portrait for everything but the two screens that ask — see
    /// `OrientationLock`. UIKit asks on the main thread and wants an answer
    /// there and then, so the state it reads has to be readable synchronously.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.shared.mask }
    }

    /// The scene delegate below is how a home screen quick action reaches
    /// the app; there is no SwiftUI modifier for one. CarPlay's scene names
    /// its classes here rather than trusting Info.plist to: build 72 shipped
    /// with the generated scene manifest in place of the written one, the
    /// "CarPlay" configuration came back with no delegate, and CarPlay threw
    /// the moment a car connected.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        #if canImport(CarPlay)
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.sceneClass = CPTemplateApplicationScene.self
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        #endif
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// What the window scene is told that SwiftUI has no modifier for: a quick
/// action pressed on the home screen icon. Links and activities are passed
/// on as well, in case SwiftUI's own handling of them stands down once a
/// delegate of its own is not the one installed; `AppModel` drops the
/// duplicate when both arrive.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // One window only. The app model, the player and the navigation
        // paths are single instances, so a second iPad window would only
        // mirror the first one and present the same player twice. CarPlay's
        // scene isn't a window scene, so it is never counted here.
        if session.role == .windowApplication {
            let others = UIApplication.shared.connectedScenes.filter {
                $0 !== scene && $0.session.role == .windowApplication
            }
            if !others.isEmpty {
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                return
            }
        }
        if let shortcut = connectionOptions.shortcutItem { deliver(shortcut) }
        for context in connectionOptions.urlContexts { deliver(context.url) }
        for activity in connectionOptions.userActivities { deliver(activity) }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        deliver(shortcutItem)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { deliver(context.url) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        deliver(userActivity)
    }

    private func deliver(_ item: UIApplicationShortcutItem) {
        guard let url = QuickActions.url(for: item) else { return }
        Task { @MainActor in AppModel.shared.handle(url, fromApp: true) }
    }

    private func deliver(_ url: URL) {
        Task { @MainActor in AppModel.shared.handle(url) }
    }

    private func deliver(_ activity: NSUserActivity) {
        Task { @MainActor in AppModel.shared.continueActivity(activity) }
    }
}
#endif
