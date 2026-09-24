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

@main
struct AquariumApp: App {
    @State private var app = AppModel.shared
    @State private var client = JellyfinClient.shared
    @State private var prefs = Preferences.shared
    @State private var player = PlayerModel.shared
    @State private var music = MusicPlayer.shared

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Here rather than in a view: a button on a Live Activity can start
        // the app with no window at all — see Core/LiveActivities.swift.
        LiveActivityCenter.shared.start()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(client)
                .environment(prefs)
                .environment(player)
                .environment(music)
                // tvOS has no light mode here — see Theme — so it must not be
                // told to switch to one.
                #if !os(tvOS)
                .themed(prefs.theme)
                #endif
                .tint(Theme.accent)
                // The Apple TV home screen's top shelf comes back in here —
                // see AppModel.handle.
                .onOpenURL { app.handle($0) }
                // A title picked from the system's search, and a film handed
                // over from another device — see AppModel.continueActivity.
                #if os(iOS) || os(macOS)
                .onContinueUserActivity(CSSearchableItemActionType) { app.continueActivity($0) }
                #endif
                #if !os(tvOS)
                .onContinueUserActivity(PlaybackHandoff.activityType) { app.continueActivity($0) }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands {
            // The Mac expects its transport on the keyboard, not only in the
            // player's own controls.
            CommandMenu("Playback") {
                Button("Play / Pause") { PlayerModel.shared.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Back 10 seconds") { PlayerModel.shared.seek(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Forward 10 seconds") { PlayerModel.shared.seek(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Slower") { PlayerModel.shared.stepSpeed(-1) }
                    .keyboardShortcut("[", modifiers: [])
                Button("Faster") { PlayerModel.shared.stepSpeed(1) }
                    .keyboardShortcut("]", modifiers: [])
                Divider()
                Button("Stop") { PlayerModel.shared.stop() }
            }
        }
        #endif
    }
}

#if os(iOS)
import UIKit

/// What UIKit still has to answer for itself: the completion handler the
/// system hands back when it wakes the app to finish a background download,
/// and which orientations the app will accept.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Kept per session — three can be woken at once — and stored before
        // returning, so the session's "finished" can't arrive ahead of it.
        MainActor.assumeIsolated {
            DownloadManager.shared.setBackgroundCompletionHandler(completionHandler, for: identifier)
        }
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
    /// the app; there is no SwiftUI modifier for one. CarPlay's scene keeps
    /// the configuration Info.plist spells out for it.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication" {
            return UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
        }
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
